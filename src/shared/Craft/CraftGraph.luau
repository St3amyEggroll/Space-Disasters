--!strict
--[[
	CraftGraph
	Connectivity, segments, auto staging, fuel groups and splits for a design (spec 7.3). Deterministic: the same
	design always gives the same result on every machine (neighbour lists and queues are ordered by block id),
	so client staging prediction and the server agree.

	Rules:
	  * Blocks attach when their boxes share a face with non-zero overlap area (CraftDesign.touches).
	  * The root is the command part with the lowest block id.
	  * Segments are separated by decouplers. A decoupler belongs to the segment FARTHER from the root and starts
	    it, so it drops with the spent stage. Segment depth = number of decouplers between it and the root.
	  * Auto staging: stage 1 ignites engines in depth-D segments; each following stage fires the decouplers at
	    depth d and ignites engines in depth d-1 (d = D..1); a final stage deploys parachutes. Stage overrides
	    move a block's action to a given stage. Stages with no actions are dropped.
	  * Each segment is a fuel group: liquid engines draw only from tanks in their own segment. Solid boosters
	    (non-throttleable engines with their own fuel) burn only their own fuel.
]]

local CraftDesign = require(script.Parent.CraftDesign)
local Parts = require(script.Parent.Parent.Config.Parts)

type Block = CraftDesign.Block
type Design = CraftDesign.Design

--============================================================================
-- Tunables
--============================================================================
local MAX_STAGES = 64
--============================================================================

export type Segment = {
	index: number,
	depth: number,
	decouplerId: number?, -- the decoupler that starts this segment (nil for the root segment)
	parent: number?, -- index of the segment it hangs from (nil for the root segment)
	blockIds: { number },
	tankFuel: number, -- kg of liquid fuel in this segment's tanks
}

export type Stage = {
	ignite: { number }, -- engine block ids
	decouple: { number }, -- decoupler block ids
	deploy: { number }, -- parachute block ids (armed; they open when conditions allow)
}

export type Graph = {
	design: Design,
	blockById: { [number]: Block },
	neighbors: { [number]: { number } },
	rootId: number?,
	attached: { [number]: boolean }, -- reachable from the root
	looseIds: { number }, -- blocks not connected to the root (sorted)
	segmentOf: { [number]: number },
	segments: { Segment },
	maxDepth: number,
	stages: { Stage },
	engineIds: { number },
	chuteIds: { number },
	warnings: { string },
}

local CraftGraph = {}

local function isDecoupler(block: Block): boolean
	return Parts.get(block.type).Decoupler ~= nil
end

-- True for engines that burn only their own fuel (solid boosters).
function CraftGraph.isSolid(def: Parts.PartDef): boolean
	local engine = def.Engine
	return engine ~= nil and not engine.Throttleable and def.FuelMass > 0
end

-- Neighbour lists (sorted by id) for every block.
function CraftGraph.adjacency(design: Design): { [number]: { number } }
	local blocks = table.clone(design.blocks)
	table.sort(blocks, function(a, b)
		return a.id < b.id
	end)
	local neighbors: { [number]: { number } } = {}
	for _, block in blocks do
		neighbors[block.id] = {}
	end
	for i = 1, #blocks do
		local a = blocks[i]
		for j = i + 1, #blocks do
			local b = blocks[j]
			if CraftDesign.touches(a, b) then
				table.insert(neighbors[a.id], b.id)
				table.insert(neighbors[b.id], a.id)
			end
		end
	end
	return neighbors
end

-- Connected components (each sorted by id), ignoring the removed block ids. Components are ordered by their
-- smallest block id, except that the component containing `rootId` (if given and present) comes first.
function CraftGraph.components(
	design: Design,
	neighbors: { [number]: { number } },
	removed: { [number]: boolean }?,
	rootId: number?
): { { number } }
	local skip = removed or {}
	local ids: { number } = {}
	for _, block in design.blocks do
		if not skip[block.id] then
			table.insert(ids, block.id)
		end
	end
	table.sort(ids)
	local seen: { [number]: boolean } = {}
	local result: { { number } } = {}
	for _, start in ids do
		if not seen[start] then
			local component = {}
			local queue = { start }
			seen[start] = true
			local head = 1
			while head <= #queue do
				local id = queue[head]
				head += 1
				table.insert(component, id)
				local list: { number } = neighbors[id] or {}
				for _, n in list do
					if not seen[n] and not skip[n] then
						seen[n] = true
						table.insert(queue, n)
					end
				end
			end
			table.sort(component)
			table.insert(result, component)
		end
	end
	if rootId then
		for index, component in result do
			if table.find(component, rootId) then
				table.remove(result, index)
				table.insert(result, 1, component)
				break
			end
		end
	end
	return result
end

local function buildSegments(graph: Graph)
	local rootId = graph.rootId
	if rootId == nil then
		return
	end
	local blockById = graph.blockById
	type Pending = { start: number, depth: number, decouplerId: number?, parent: number? }
	local pending: { Pending } = { { start = rootId, depth = 0, decouplerId = nil, parent = nil } }
	local pendingHead = 1
	while pendingHead <= #pending do
		local job = pending[pendingHead]
		pendingHead += 1
		if graph.segmentOf[job.start] ~= nil then
			continue
		end
		local segment: Segment = {
			index = #graph.segments + 1,
			depth = job.depth,
			decouplerId = job.decouplerId,
			parent = job.parent,
			blockIds = {},
			tankFuel = 0,
		}
		table.insert(graph.segments, segment)
		graph.maxDepth = math.max(graph.maxDepth, job.depth)
		local queue = { job.start }
		graph.segmentOf[job.start] = segment.index
		local head = 1
		while head <= #queue do
			local id = queue[head]
			head += 1
			table.insert(segment.blockIds, id)
			for _, n in graph.neighbors[id] do
				if graph.segmentOf[n] == nil then
					if isDecoupler(blockById[n]) then
						table.insert(
							pending,
							{ start = n, depth = job.depth + 1, decouplerId = n, parent = segment.index }
						)
					else
						graph.segmentOf[n] = segment.index
						table.insert(queue, n)
					end
				end
			end
		end
		table.sort(segment.blockIds)
		for _, id in segment.blockIds do
			local def = Parts.get(blockById[id].type)
			if def.FuelMass > 0 and def.Engine == nil then
				segment.tankFuel += def.FuelMass
			end
		end
	end
end

local function buildStages(graph: Graph)
	local byDepthEngines: { [number]: { number } } = {}
	local byDepthDecouplers: { [number]: { number } } = {}
	for depth = 0, graph.maxDepth do
		byDepthEngines[depth] = {}
		byDepthDecouplers[depth] = {}
	end
	for _, segment in graph.segments do
		if segment.decouplerId then
			table.insert(byDepthDecouplers[segment.depth], segment.decouplerId :: number)
		end
	end
	for _, id in graph.engineIds do
		local segmentIndex = graph.segmentOf[id]
		if segmentIndex then
			table.insert(byDepthEngines[graph.segments[segmentIndex].depth], id)
		end
	end

	local stages: { Stage } = {}
	local D = graph.maxDepth
	table.insert(stages, { ignite = byDepthEngines[D], decouple = {}, deploy = {} })
	for d = D, 1, -1 do
		table.insert(stages, { ignite = byDepthEngines[d - 1], decouple = byDepthDecouplers[d], deploy = {} })
	end
	local attachedChutes = {}
	for _, id in graph.chuteIds do
		if graph.attached[id] then
			table.insert(attachedChutes, id)
		end
	end
	if #attachedChutes > 0 then
		table.insert(stages, { ignite = {}, decouple = {}, deploy = attachedChutes })
	end

	-- Stage overrides: move each overridden action to its requested stage.
	for _, block in graph.design.blocks do
		local target = block.stageOverride
		if target and graph.attached[block.id] then
			target = math.clamp(target, 1, MAX_STAGES)
			for _, stage in stages do
				for _, list in { stage.ignite, stage.decouple, stage.deploy } do
					local index = table.find(list, block.id)
					if index then
						table.remove(list, index)
					end
				end
			end
			while #stages < target do
				table.insert(stages, { ignite = {}, decouple = {}, deploy = {} })
			end
			local def = Parts.get(block.type)
			local stage = stages[target]
			if def.Engine then
				table.insert(stage.ignite, block.id)
			elseif def.Decoupler then
				table.insert(stage.decouple, block.id)
			elseif def.Chute then
				table.insert(stage.deploy, block.id)
			end
		end
	end

	for _, stage in stages do
		table.sort(stage.ignite)
		table.sort(stage.decouple)
		table.sort(stage.deploy)
		if #stage.ignite + #stage.decouple + #stage.deploy > 0 then
			table.insert(graph.stages, stage)
		end
	end
end

local function collectWarnings(graph: Graph)
	local warnings = graph.warnings
	if graph.rootId == nil then
		table.insert(warnings, "No command part (add a Command Pod or Crew Cabin)")
	end
	if #graph.engineIds == 0 then
		table.insert(warnings, "No engine")
	end
	if #graph.looseIds > 0 then
		table.insert(warnings, `{#graph.looseIds} block(s) not attached to the command part`)
	end
	local reported: { [string]: boolean } = {}
	for _, id in graph.engineIds do
		local def = Parts.get(graph.blockById[id].type)
		local segmentIndex = graph.segmentOf[id]
		if not CraftGraph.isSolid(def) and segmentIndex and graph.segments[segmentIndex].tankFuel <= 0 then
			local key = def.DisplayName .. "@" .. segmentIndex
			if not reported[key] then
				reported[key] = true
				table.insert(warnings, `{def.DisplayName} can't reach any fuel (no tank in its stage)`)
			end
		end
	end
end

function CraftGraph.build(design: Design): Graph
	local blockById: { [number]: Block } = {}
	local engineIds: { number } = {}
	local chuteIds: { number } = {}
	for _, block in design.blocks do
		blockById[block.id] = block
		local def = Parts.get(block.type)
		if def.Engine then
			table.insert(engineIds, block.id)
		end
		if def.Chute then
			table.insert(chuteIds, block.id)
		end
	end
	table.sort(engineIds)
	table.sort(chuteIds)

	local root = CraftDesign.rootBlock(design)
	local graph: Graph = {
		design = design,
		blockById = blockById,
		neighbors = CraftGraph.adjacency(design),
		rootId = if root then root.id else nil,
		attached = {},
		looseIds = {},
		segmentOf = {},
		segments = {},
		maxDepth = 0,
		stages = {},
		engineIds = engineIds,
		chuteIds = chuteIds,
		warnings = {},
	}

	if graph.rootId then
		local components = CraftGraph.components(design, graph.neighbors, nil, graph.rootId)
		for _, id in components[1] do
			graph.attached[id] = true
		end
		for index = 2, #components do
			for _, id in components[index] do
				table.insert(graph.looseIds, id)
			end
		end
		table.sort(graph.looseIds)
	else
		for _, block in design.blocks do
			table.insert(graph.looseIds, block.id)
		end
		table.sort(graph.looseIds)
	end

	buildSegments(graph)
	if graph.rootId then
		buildStages(graph)
	end
	collectWarnings(graph)
	return graph
end

-- Segment indices that hang (directly or indirectly) from the given segment, including itself.
function CraftGraph.subtree(graph: Graph, segmentIndex: number): { [number]: boolean }
	local result: { [number]: boolean } = { [segmentIndex] = true }
	local changed = true
	while changed do
		changed = false
		for _, segment in graph.segments do
			if not result[segment.index] and segment.parent and result[segment.parent :: number] then
				result[segment.index] = true
				changed = true
			end
		end
	end
	return result
end

return table.freeze(CraftGraph)
