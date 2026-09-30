--!strict
--[[
	MassProps
	Mass properties and builder stats for a design (spec 7.3):
	  * mass, centre of mass (design-local), diagonal inertia about the CoM (point masses + per-block box inertia)
	  * fuel per fuel group (segment tanks) and per solid booster
	  * projected area along X, Y and Z (exact union on the integer grid), leading-block drag factor for each of
	    the 6 directions, fin area, and an area-weighted centre of pressure
	  * per-stage delta-v (sea level and vacuum), TWR on Homeworld, burn time (stageStats)

	Contact hull points arrive with the flight model in Phase 2.
	Pure module: no services.
]]

local CraftDesign = require(script.Parent.CraftDesign)
local CraftGraph = require(script.Parent.CraftGraph)
local Parts = require(script.Parent.Parent.Config.Parts)

type Design = CraftDesign.Design
type Graph = CraftGraph.Graph

--============================================================================
-- Tunables
--============================================================================
local MAX_BURN_EVENTS = 512 -- safety cap on flameout events per stage
local EPSILON_FUEL = 1e-9 -- kg
--============================================================================

export type Props = {
	mass: number, -- kg
	dryMass: number,
	fuelMass: number,
	com: Vector3, -- design-local
	inertia: Vector3, -- kg*m^2 about the CoM, design axes (diagonal)
	area: Vector3, -- projected area seen along X, Y, Z (m^2)
	leadDragFactor: { [string]: number }, -- "+X", "-X", "+Y", "-Y", "+Z", "-Z"
	finArea: number,
	cop: Vector3, -- area-weighted centre of pressure, design-local
	partCount: number,
}

export type StageStat = {
	stage: number,
	dvVac: number, -- m/s
	dvAsl: number,
	twrAsl: number, -- at ignition, on Homeworld's surface gravity
	twrVac: number,
	burnTime: number, -- s at full throttle
	massStart: number, -- kg after this stage's separations
	massEnd: number,
}

local MassProps = {}

-- Current fuel per block (kg). Missing entries mean "full".
export type FuelState = { [number]: number }

local function blockFuel(block: CraftDesign.Block, fuel: FuelState?): number
	local def = Parts.get(block.type)
	if fuel and fuel[block.id] ~= nil then
		return math.clamp(fuel[block.id], 0, def.FuelMass)
	end
	return def.FuelMass
end

-- Union area of rectangles on the integer grid (cells are 1x1).
local function unionArea(rects: { { number } }): number
	local cells: { [number]: boolean } = {}
	local count = 0
	for _, r in rects do
		for u = r[1], r[3] - 1 do
			for v = r[2], r[4] - 1 do
				local key = u * 65536 + v
				if not cells[key] then
					cells[key] = true
					count += 1
				end
			end
		end
	end
	return count
end

function MassProps.compute(design: Design, fuel: FuelState?, onlyIds: { [number]: boolean }?): Props
	local mass, dryMass, fuelMass = 0, 0, 0
	local weighted = Vector3.zero
	local blocks = {}
	for _, block in design.blocks do
		if onlyIds == nil or onlyIds[block.id] then
			table.insert(blocks, block)
		end
	end

	local finArea = 0
	local copSum = Vector3.zero
	local copWeight = 0
	local rectsX, rectsY, rectsZ = {}, {}, {}
	local lead: { [string]: { value: number, factor: number } } = {}
	for _, dir in { "+X", "-X", "+Y", "-Y", "+Z", "-Z" } do
		lead[dir] = { value = -math.huge, factor = 1 }
	end

	for _, block in blocks do
		local def = Parts.get(block.type)
		local f = blockFuel(block, fuel)
		local m = def.DryMass + f
		dryMass += def.DryMass
		fuelMass += f
		mass += m
		local center = CraftDesign.blockCenter(block)
		weighted += center * m

		local minV, maxV = CraftDesign.blockMin(block), CraftDesign.blockMax(block)
		table.insert(rectsX, { minV.Y, minV.Z, maxV.Y, maxV.Z })
		table.insert(rectsY, { minV.X, minV.Z, maxV.X, maxV.Z })
		table.insert(rectsZ, { minV.X, minV.Y, maxV.X, maxV.Y })

		local size = maxV - minV
		local faceArea = size.X * size.Y + size.Y * size.Z + size.X * size.Z
		copSum += center * (faceArea * def.DragFactor)
		copWeight += faceArea * def.DragFactor
		if def.Fin then
			finArea += def.Fin.Area
		end

		local extents: { [string]: number } = {
			["+X"] = maxV.X,
			["-X"] = -minV.X,
			["+Y"] = maxV.Y,
			["-Y"] = -minV.Y,
			["+Z"] = maxV.Z,
			["-Z"] = -minV.Z,
		}
		for dir, extent in extents do
			local entry = lead[dir]
			if extent > entry.value then
				entry.value = extent
				entry.factor = def.DragFactor
			elseif extent == entry.value then
				entry.factor = math.min(entry.factor, def.DragFactor)
			end
		end
	end

	local com = if mass > 0 then weighted / mass else Vector3.zero
	local ix, iy, iz = 0, 0, 0
	for _, block in blocks do
		local def = Parts.get(block.type)
		local m = def.DryMass + blockFuel(block, fuel)
		local size = CraftDesign.blockSize(block)
		local d = CraftDesign.blockCenter(block) - com
		ix += m * (size.Y ^ 2 + size.Z ^ 2) / 12 + m * (d.Y ^ 2 + d.Z ^ 2)
		iy += m * (size.X ^ 2 + size.Z ^ 2) / 12 + m * (d.X ^ 2 + d.Z ^ 2)
		iz += m * (size.X ^ 2 + size.Y ^ 2) / 12 + m * (d.X ^ 2 + d.Y ^ 2)
	end

	local leadDragFactor: { [string]: number } = {}
	for dir, entry in lead do
		leadDragFactor[dir] = entry.factor
	end

	return {
		mass = mass,
		dryMass = dryMass,
		fuelMass = fuelMass,
		com = com,
		inertia = Vector3.new(ix, iy, iz),
		area = Vector3.new(unionArea(rectsX), unionArea(rectsY), unionArea(rectsZ)),
		leadDragFactor = leadDragFactor,
		finArea = finArea,
		cop = if copWeight > 0 then copSum / copWeight else com,
		partCount = #blocks,
	}
end

--[[
	Per-stage delta-v and TWR, KSP-style. Simulates the stage sequence at full throttle:
	each stage fires its decouplers (dropping that segment and everything hanging from it), ignites its engines,
	then burns until every active engine has run dry. Burns are integrated exactly between flameout events
	(dv = F / mdot * ln(m0 / m1) while thrust and flow are constant).
]]
function MassProps.stageStats(graph: Graph, g0: number, surfaceGravity: number): { StageStat }
	local results: { StageStat } = {}
	local design = graph.design
	local attachedSegments: { [number]: boolean } = {}
	for _, segment in graph.segments do
		attachedSegments[segment.index] = true
	end
	local tankFuel: { [number]: number } = {}
	for _, segment in graph.segments do
		tankFuel[segment.index] = segment.tankFuel
	end
	local solidFuel: { [number]: number } = {}
	local active: { number } = {}

	local function isAttached(id: number): boolean
		local segmentIndex = graph.segmentOf[id]
		return segmentIndex ~= nil and attachedSegments[segmentIndex] == true
	end

	local function currentMass(): number
		local m = 0
		for _, block in design.blocks do
			if isAttached(block.id) then
				local def = Parts.get(block.type)
				m += def.DryMass
				if CraftGraph.isSolid(def) then
					m += solidFuel[block.id] or def.FuelMass
				end
			end
		end
		for segmentIndex, remaining in tankFuel do
			if attachedSegments[segmentIndex] then
				m += remaining
			end
		end
		return m
	end

	for stageIndex, stage in graph.stages do
		for _, decouplerId in stage.decouple do
			local segmentIndex = graph.segmentOf[decouplerId]
			if segmentIndex then
				for dropped in CraftGraph.subtree(graph, segmentIndex) do
					attachedSegments[dropped] = nil
				end
			end
		end
		for _, engineId in stage.ignite do
			if isAttached(engineId) and not table.find(active, engineId) then
				table.insert(active, engineId)
			end
		end

		local stat: StageStat = {
			stage = stageIndex,
			dvVac = 0,
			dvAsl = 0,
			twrAsl = 0,
			twrVac = 0,
			burnTime = 0,
			massStart = currentMass(),
			massEnd = 0,
		}

		local firstInterval = true
		for _ = 1, MAX_BURN_EVENTS do
			-- Which engines can burn right now, and how fast each fuel source drains.
			local totalFlow, thrustVac, thrustAsl = 0, 0, 0
			local tankFlow: { [number]: number } = {}
			local burningSolids: { number } = {}
			for _, id in active do
				if isAttached(id) then
					local def = Parts.get(graph.blockById[id].type)
					local engine = def.Engine :: Parts.EngineStats
					local flow = Parts.massFlow(engine, g0)
					local hasFuel: boolean
					if CraftGraph.isSolid(def) then
						hasFuel = (solidFuel[id] or def.FuelMass) > EPSILON_FUEL
						if hasFuel then
							table.insert(burningSolids, id)
						end
					else
						local segmentIndex = graph.segmentOf[id]
						hasFuel = tankFuel[segmentIndex] > EPSILON_FUEL
						if hasFuel then
							tankFlow[segmentIndex] = (tankFlow[segmentIndex] or 0) + flow
						end
					end
					if hasFuel then
						totalFlow += flow
						thrustVac += Parts.thrustAt(engine, 0, g0)
						thrustAsl += Parts.thrustAt(engine, 1, g0)
					end
				end
			end
			if totalFlow <= 0 then
				break
			end

			local m0 = currentMass()
			if firstInterval then
				stat.twrAsl = thrustAsl / (m0 * surfaceGravity)
				stat.twrVac = thrustVac / (m0 * surfaceGravity)
				firstInterval = false
			end

			-- Time until the first fuel source runs dry.
			local dt = math.huge
			for segmentIndex, flow in tankFlow do
				dt = math.min(dt, tankFuel[segmentIndex] / flow)
			end
			for _, id in burningSolids do
				local def = Parts.get(graph.blockById[id].type)
				local flow = Parts.massFlow(def.Engine :: Parts.EngineStats, g0)
				dt = math.min(dt, (solidFuel[id] or def.FuelMass) / flow)
			end

			local burned = totalFlow * dt
			local m1 = m0 - burned
			local logRatio = math.log(m0 / m1)
			stat.dvVac += thrustVac / totalFlow * logRatio
			stat.dvAsl += thrustAsl / totalFlow * logRatio
			stat.burnTime += dt

			for segmentIndex, flow in tankFlow do
				tankFuel[segmentIndex] = math.max(0, tankFuel[segmentIndex] - flow * dt)
			end
			for _, id in burningSolids do
				local def = Parts.get(graph.blockById[id].type)
				local flow = Parts.massFlow(def.Engine :: Parts.EngineStats, g0)
				solidFuel[id] = math.max(0, (solidFuel[id] or def.FuelMass) - flow * dt)
			end
		end

		stat.massEnd = currentMass()
		table.insert(results, stat)
	end

	return results
end

-- Total vacuum / sea-level delta-v across all stages.
function MassProps.totalDeltaV(stats: { StageStat }): (number, number)
	local vac, asl = 0, 0
	for _, stat in stats do
		vac += stat.dvVac
		asl += stat.dvAsl
	end
	return vac, asl
end

return table.freeze(MassProps)
