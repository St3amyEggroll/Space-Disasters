--!strict
--[[
	TerrainMesh (CHANGED (Phase 8): surface terrain)
	Draws the dominant body's heightmap ground (SurfaceHeight) around the camera while the Surface layer draws.

	Mesh mode (EditableMesh): the cube-sphere quadtree leaves chosen by TerrainMath.select are drawn in bands, one per
	level of detail (TerrainMath.bandOf: the finest bandCount - 1 levels get their own band, coarser levels share the
	last one), each band ONE EditableMesh + MeshPart (spike S12: an experience only gets ~8 EditableMeshes, so one
	mesh per chunk is impossible; one mesh also holds at most 20,000 triangles). Every frame a band whose box exceeds
	the 2048-stud part limit, whose centre lies beyond the draw budget (engine culling, S11) or whose far edge lies
	beyond FAR_LIMIT is drawn uniformly scaled down about the camera (factor k, TerrainMath.bandScale): its image on
	screen is exact (same directions, so band edges stay glued on screen), only its depth shrinks. The finest band
	(the ground under a landing craft, its props and the launch site) is small enough to stay at true scale. Known
	limit: a near hill can be drawn behind the next, scaled band where that band's ground lies a little beyond it.
	Chunk geometry is cached; a band is rebuilt only when its leaf set changes.

	Rebuilds never leave holes and need only ONE spare mesh: when the quadtree changes, a plan swaps the changed
	bands one at a time, each built in a background thread with a per-frame time budget (Quality tier). A band only
	drops leaves once the leaves replacing them are on screen (its dependencies); when two bands wait on each other
	(splits ahead of a moving camera, merges behind it) one is first rebuilt as a "union" that also keeps its
	outgoing leaves, sunk UNION_DROP below the ground. Bands still showing outgoing leaves are drawn PUSH_BACK
	farther (again an exact uniform scale about the camera), so the new geometry wins wherever both overlap.

	Plates: when meshes are unavailable (unpublished place, "Allow Mesh / Image APIs" off, refused by the budget:
	one warning, then plates for the session) or not ready yet (first build, a teleport), the same quadtree (leaves of
	at most PLATE_MAX_SIZE, out to PLATE_MAX_DISTANCE) is drawn as one tilted, biome-coloured Part per leaf, fitted to
	the leaf's corners.

	Positions are kept in doubles relative to the body and converted only after subtracting the camera (I1).

	API (driven by Surface):
		TerrainMesh.init(parent)
		TerrainMesh.update(ctx, show, prebuild)   show: draw this frame (surface mode); prebuild: build but keep hidden
		TerrainMesh.isTrueScaleAt(pos, margin)     is body-relative `pos` (dominant body) drawn at true scale?
		TerrainMesh.summary(): string              F3 debug line
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Quality = require(script.Parent.Quality)
local RenderContext = require(script.Parent.RenderContext)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local TerrainMath = require(script.Parent.TerrainMath)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d
type Node = TerrainMath.Node
type Chunk = TerrainMath.Chunk
type Config = TerrainMath.Config
type Selection = TerrainMath.Selection

--============================================================================
-- Tunables
--============================================================================
local MAX_BANDS = 6 -- bands (meshes) shown at once; one more is built at a time (S12: ~8 per experience, ScaledSpace 1)
local MIN_BANDS = 2 -- after budget refusals the band count drops, but never below this
local MAX_MESH_LEAVES = 100 -- leaves per mesh (192 triangles each: under EditableMesh's 20,000 triangles)
local PART_LIMIT = 2040 -- studs per MeshPart axis (engine limit 2048)
local MESH_STORE_EXTENT = 512 -- mesh units across a band's box (vertices are stored normalised; Size scales them)
local BUDGET_FRACTION = 0.85 -- band centres stay within this fraction of the draw distance (culling, S11)
local FAR_LIMIT = 17000 -- studs: no band reaches farther (0.85 x the 20,000 studs drawn at quality 10)
local DRAW_DISTANCE_CAP = 20000 -- studs
local PUSH_BACK = 0.004 -- bands still showing outgoing leaves are drawn this much farther (exact, about the camera)
local UNION_DROP = 2.5 -- m: outgoing leaves kept in a union mesh sit this far below the ground ...
local UNION_DROP_PER_SPACING = 0.15 -- ... plus this x their vertex spacing
local RESELECT_INTERVAL = 0.2 -- s between quadtree selections
local RESELECT_MIN_MOVE = 3 -- m the camera must move before a new selection ...
local RESELECT_MOVE_FRACTION = 0.01 -- ... or this fraction of its height above the ground
local HORIZON_LEAD_MIN = 30 -- m: meshes reach the horizon seen from this much higher than the camera ...
local HORIZON_LEAD_FRACTION = 0.15 -- ... or this fraction of its height (it may climb while they build)
local STALE_MIN = 1500 -- m: the displayed meshes cover the view while the camera stays this close to where ...
local STALE_HEIGHT_FRACTION = 0.6 -- ... they were chosen, or this fraction of its height (else plates show)
local CHUNK_CACHE_MAX = 600 -- cached chunk geometries (~4 KB each)
local MAX_MESH_FAILURES = 3 -- failed builds in a row (at the same band count) before plates for the session
local RETRY_DELAY = 4 -- s after a failed build
local HIDDEN_RELEASE_S = 15 -- s neither shown nor prebuilt before the meshes are released
local SIZE_REWRITE_FRACTION = 0.0005 -- relative change before a band's Size is rewritten
local TRUE_SCALE = 0.9999 -- a band with k at or above this counts as true scale
local MESH_MATERIAL = Enum.Material.SmoothPlastic
local MERGE_FACTOR = 1.15 -- hysteresis: split nodes merge back only this much farther out
local MIN_BAND_RADIUS = 1 -- m

-- Detail per Quality tier: splitK (LOD distance in node sizes), leaf cap, build time per frame (s), and whether the
-- finest band casts shadows.
type TierParams = { splitK: number, maxLeaves: number, budgetS: number, shadows: boolean }
local TIERS: { [string]: TierParams } = {
	Low = { splitK = 0.8, maxLeaves = 180, budgetS = 0.0015, shadows = false },
	Medium = { splitK = 1.05, maxLeaves = 240, budgetS = 0.002, shadows = false },
	High = { splitK = 1.4, maxLeaves = 320, budgetS = 0.003, shadows = true },
}

-- Plates (fallback and placeholder)
local PLATE_MAX_SIZE = 1500 -- m, plates must stay under the 2048-stud part limit
local PLATE_MAX_DISTANCE = 9000 -- m
local PLATE_SPLIT_K = 0.8
local PLATE_MAX_LEAVES = 200
local PLATE_THICKNESS = 12 -- studs ...
local PLATE_THICKNESS_PER_M = 0.03 -- ... plus this per metre of plate size (hides the steps between plates)
local PLATE_OVERLAP = 1.03 -- plates are this much larger than their leaf
local PLATE_DROP = 0.15 -- m, plate tops below the true ground
local PLATE_MAX_EXTENT = 2048
local PLATES_PER_FRAME = 40 -- new plates created per frame at most (nearest first)
local OCEAN_REFLECTANCE = 0.08
local KIND_MATERIALS: { [string]: Enum.Material } = {
	Ocean = Enum.Material.SmoothPlastic,
	Beach = Enum.Material.Sand,
	Grass = Enum.Material.Grass,
	Forest = Enum.Material.Grass,
	Desert = Enum.Material.Sand,
	Rock = Enum.Material.Rock,
	Snow = Enum.Material.Snow,
	Mare = Enum.Material.Slate,
	Highland = Enum.Material.Slate,
	Crater = Enum.Material.Slate,
	Ray = Enum.Material.Slate,
}
local FALLBACK_MATERIAL = Enum.Material.SmoothPlastic
local BULK_MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged
--============================================================================

type BandMesh = {
	id: number,
	mesh: EditableMesh,
	part: MeshPart,
	origin: Vec3d, -- body-relative centre of the mesh's box
	size: Vector3, -- box size (m)
	radius: number, -- bounding-sphere radius (m)
	maxExtent: number,
	leaves: { [number]: Node }, -- by key: every leaf in the mesh (outgoing ones of a union included)
	count: number,
	triangles: number,
	stale: boolean, -- shows outgoing leaves at full height (drawn PUSH_BACK farther)
	scale: number, -- k used this frame
	appliedScale: number, -- k its Size was last written for
}

type Plan = {
	bodyId: number,
	config: Config,
	cam: Vec3d,
	selection: Selection?, -- chosen by the plan's own thread (time-sliced)
	target: { [number]: { [number]: Node } }, -- band id -> key -> leaf
	pending: { [number]: boolean }, -- band ids that still need their final swap
	covered: { [number]: boolean }, -- band ids whose new leaves are on screen
	deps: { [number]: { [number]: boolean } }, -- band id -> bands holding the replacements of its outgoing leaves
	finished: boolean,
	failed: boolean,
	aborted: boolean,
	error: string?,
	builds: number, -- meshes built so far
	steps: number, -- meshes this plan needs at least
	current: string, -- what is being built (debug)
	buildingMesh: EditableMesh?, -- the mesh being built (released if the plan stops)
	buildingPart: MeshPart?,
}

type Plate = {
	part: Part,
	pos: Vec3d, -- centre (body-relative)
	rot: CFrame, -- universe rotation
}

local TerrainMesh = {}

--============================================================================
-- State
--============================================================================
local root: Folder? = nil
local meshFolder: Folder? = nil
local plateFolder: Folder? = nil

local meshEnabled = true -- false after EditableMesh failed for good: plates only
local warned = false
local failures = 0
local retryAt = 0
local bandCount = MAX_BANDS
local liveMeshes = 0

local bodyId: number? = nil
local bands: { [number]: BandMesh } = {} -- by band id
local split: { [number]: boolean } = {}
local displayedCam: Vec3d? = nil
local coverageBroken = false
local plan: Plan? = nil
local lastSelectTime = -math.huge
local lastSelectCam: Vec3d? = nil
local forceSelect = true
local hiddenSince: number? = nil

local chunkCache: { [number]: Chunk } = {}
local chunkStamp: { [number]: number } = {}
local chunkCount = 0
local stamp = 0

local plates: { [number]: Plate } = {}
local plateSplit: { [number]: boolean } = {}
local platePool: { Part } = {}
local plateParts: { BasePart } = {}
local plateCFrames: { CFrame } = {}
local plateBodyId: number? = nil
local plateLastCam: Vec3d? = nil
local plateLastTime = -math.huge
local platesDirty = true
local platesShown = false
local plateWanted: { [number]: Node }? = nil -- the latest plate selection, until every plate of it exists
local plateQueue: { Node } = {} -- plates still to create (farthest first: popped from the end)
local lastPlateRef: Vec3d = Vec3d.zero()
local lastPlateRot: CFrame = CFrame.identity
local lastPlateSlot: Vector3 = Vector3.zero

local tier: TierParams = TIERS.High
local tierName = "High"

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local scratch: Vec3d = Vec3d.zero()
local meshesShown = false

--============================================================================
-- Helpers
--============================================================================
local function params(): TerrainMath.Params
	return { splitK = tier.splitK, mergeK = tier.splitK * MERGE_FACTOR, maxLeaves = tier.maxLeaves }
end

local function disableMeshes(reason: string)
	meshEnabled = false
	if not warned then
		warned = true
		warn(
			"[TerrainMesh] EditableMesh terrain is unavailable ("
				.. reason
				.. "); the ground is drawn with Part plates instead. Enable Game Settings > Security > 'Allow Mesh /"
				.. " Image APIs' for smooth terrain."
		)
	end
end

local function destroyBand(bm: BandMesh)
	bm.part:Destroy()
	bm.mesh:Destroy()
	liveMeshes -= 1
end

-- Drops the mesh a plan's builder was working on.
local function releaseBuilding(p: Plan)
	local part = p.buildingPart
	if part then
		part:Destroy()
		p.buildingPart = nil
	end
	local mesh = p.buildingMesh
	if mesh then
		mesh:Destroy()
		p.buildingMesh = nil
		liveMeshes -= 1
	end
end

local function releaseAllBands()
	for id, bm in bands do
		destroyBand(bm)
		bands[id] = nil
	end
	displayedCam = nil
	coverageBroken = false
end

local function abortPlan()
	local p = plan
	if p then
		p.aborted = true
		plan = nil
		-- the builder thread drops its unfinished mesh when it next wakes up
	end
end

local function trimChunkCache(keep: { [number]: boolean })
	if chunkCount <= CHUNK_CACHE_MAX then
		return
	end
	-- drop the least recently used chunks that are not needed
	local entries: { { key: number, stamp: number } } = {}
	for key, s in chunkStamp do
		if not keep[key] then
			table.insert(entries, { key = key, stamp = s })
		end
	end
	table.sort(entries, function(a, b)
		return a.stamp < b.stamp
	end)
	local excess = chunkCount - CHUNK_CACHE_MAX
	for index = 1, math.min(excess, #entries) do
		local key = entries[index].key
		chunkCache[key] = nil
		chunkStamp[key] = nil
		chunkCount -= 1
	end
end

-- Height (m) of the camera above the body's lowest possible ground (cheap, for thresholds).
local function heightAboveGround(config: Config, cam: Vec3d): number
	return Vec3d.length(cam) - config.radius - math.max(config.minHeight, 0)
end

--============================================================================
-- Mesh building (background thread)
--============================================================================

--[[
	Adds a chunk to an EditableMesh: vertices offset by (offX, offY, offZ), sunk `drop` m along (dx, dy, dz), then
	divided by `store` (meshes are stored about MESH_STORE_EXTENT units across; the part's Size scales them back).
]]
local function addChunk(
	mesh: EditableMesh,
	c: Chunk,
	offX: number,
	offY: number,
	offZ: number,
	drop: number,
	dx: number,
	dy: number,
	dz: number,
	store: number
)
	local count = c.vertexCount
	local vids: { number } = table.create(count, 0)
	local nids: { number } = table.create(count, 0)
	local cids: { number } = table.create(count, 0)
	offX -= dx * drop
	offY -= dy * drop
	offZ -= dz * drop
	local inv = 1 / store
	for v = 1, count do
		local px, py, pz, nx, ny, nz, r, g, b = TerrainMath.chunkVertex(c, v)
		vids[v] = mesh:AddVertex(Vector3.new((px + offX) * inv, (py + offY) * inv, (pz + offZ) * inv))
		nids[v] = mesh:AddNormal(Vector3.new(nx, ny, nz))
		cids[v] = mesh:AddColor(Color3.new(r, g, b), 1)
	end
	local tris = c.tris
	for t = 1, #tris, 3 do
		local a, b, d = tris[t], tris[t + 1], tris[t + 2]
		local face = mesh:AddTriangle(vids[a], vids[b], vids[d])
		mesh:SetFaceNormals(face, { nids[a], nids[b], nids[d] })
		mesh:SetFaceColors(face, { cids[a], cids[b], cids[d] })
	end
end

local function configureBandPart(part: MeshPart, id: number)
	part.Name = "TerrainBand" .. id
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Locked = true
	part.CastShadow = id == 0 and tier.shadows
	part.Material = MESH_MATERIAL
	part.Color = Color3.new(1, 1, 1) -- vertex colours carry the biome
	part.Transparency = 0
end

--[[
	Builds one band mesh from `leaves` (those in `sunk` are lowered: outgoing leaves of a union). Yields whenever the
	frame's time budget is spent. Returns the BandMesh, or nil (with p.failed / p.error set unless aborted).
]]
local function buildBand(p: Plan, id: number, leaves: { [number]: Node }, sunk: { [number]: boolean }?): BandMesh?
	local sliceStart = os.clock()
	local function due(): boolean
		if os.clock() - sliceStart >= tier.budgetS then
			task.wait()
			sliceStart = os.clock()
		end
		return p.aborted
	end
	-- 1. chunk geometry (cached across plans)
	local chunks: { Chunk } = {}
	local nodes: { Node } = {}
	for key, node in leaves do
		local chunk = chunkCache[key]
		if chunk == nil then
			local fresh = TerrainMath.buildChunk(p.config, node)
			chunkCache[key] = fresh
			chunkCount += 1
			chunk = fresh
			if due() then
				return nil
			end
		end
		stamp += 1
		chunkStamp[key] = stamp
		table.insert(chunks, chunk :: Chunk)
		table.insert(nodes, node)
	end
	-- 2. the mesh
	local origin, size, radius = TerrainMath.bandBounds(chunks)
	local store = math.max(size.X, size.Y, size.Z, 1) / MESH_STORE_EXTENT
	local created, mesh = pcall(function(): EditableMesh
		return AssetService:CreateEditableMesh()
	end)
	if not created or (mesh :: any) == nil then
		p.failed = true
		p.error = if created then "CreateEditableMesh returned nil" else tostring(mesh)
		return nil
	end
	liveMeshes += 1
	p.buildingMesh = mesh
	local triangles = 0
	for index, c in chunks do
		local node = nodes[index]
		local drop = 0
		if sunk and sunk[node.key] then
			drop = UNION_DROP + UNION_DROP_PER_SPACING * node.stride * p.config.cellArc
		end
		local ok, err = pcall(function()
			addChunk(mesh, c, c.ox - origin.x, c.oy - origin.y, c.oz - origin.z, drop, node.dx, node.dy, node.dz, store)
		end)
		if not ok then
			p.failed = true
			p.error = tostring(err)
			releaseBuilding(p)
			return nil
		end
		triangles += c.triangleCount
		if due() then
			releaseBuilding(p)
			return nil
		end
	end
	local made, part = pcall(function(): MeshPart
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)
	if made then
		p.buildingPart = part
	end
	if p.aborted then
		releaseBuilding(p)
		return nil
	end
	if not made then
		p.failed = true
		p.error = tostring(part)
		releaseBuilding(p)
		return nil
	end
	configureBandPart(part, id)
	p.buildingMesh = nil
	p.buildingPart = nil
	-- the engine's own idea of the mesh's box (union meshes have sunk vertices below the chunks' boxes)
	local okSize, meshSize = pcall(function(): Vector3
		return part.MeshSize
	end)
	if okSize and meshSize.X > 0 and meshSize.Y > 0 and meshSize.Z > 0 then
		size = meshSize * store
	end
	local count = 0
	for _ in leaves do
		count += 1
	end
	return {
		id = id,
		mesh = mesh,
		part = part,
		origin = origin,
		size = size,
		radius = math.max(radius, MIN_BAND_RADIUS),
		maxExtent = math.max(size.X, size.Y, size.Z),
		leaves = leaves,
		count = count,
		triangles = triangles,
		stale = false,
		scale = 1,
		appliedScale = 0,
	}
end

-- Puts a freshly built band on screen in place of the old one with the same id (nil: the band is gone).
local function swapIn(bm: BandMesh?, id: number)
	local old = bands[id]
	if old then
		destroyBand(old)
		bands[id] = nil
	end
	if bm then
		bands[id] = bm -- parented by placeBands once it has its first pose
	end
end

-- Builds band `id` from `leaves` (sunk: outgoing leaves of a union) and swaps it in. False when the plan stopped.
local function buildAndSwap(p: Plan, id: number, leaves: { [number]: Node }, sunk: { [number]: boolean }?): boolean
	local bm: BandMesh? = nil
	if next(leaves) ~= nil then
		p.current = (if sunk then "union " else "band ") .. id
		bm = buildBand(p, id, leaves, sunk)
		if bm == nil then
			releaseBuilding(p)
			if not p.aborted then
				p.finished = true
			end
			return false
		end
		p.builds += 1
	end
	if p.aborted then
		-- the plan was dropped while this mesh was finishing
		if bm then
			bm.part:Destroy()
			bm.mesh:Destroy()
			liveMeshes -= 1
		end
		return false
	end
	swapIn(bm, id)
	return true
end

-- Runs a plan: builds and swaps the changed bands one at a time, in an order that never leaves holes.
local function runPlan(p: Plan)
	while next(p.pending) ~= nil do
		if p.aborted then
			releaseBuilding(p)
			return
		end
		-- a band whose replacements are all on screen gets its final mesh; bands that go away first, then bands
		-- that are replaced, new bands last (fewest meshes alive at once)
		local chosen: number? = nil
		local rank = math.huge
		for id in p.pending do
			local ready = true
			for dep in p.deps[id] do
				if not p.covered[dep] then
					ready = false
					break
				end
			end
			if ready then
				local r = if next(p.target[id]) == nil then 1 elseif bands[id] then 2 else 3
				if r < rank then
					chosen, rank = id, r
				end
			end
		end
		if chosen then
			local id = chosen :: number
			if not buildAndSwap(p, id, p.target[id], nil) then
				return
			end
			p.covered[id] = true
			p.pending[id] = nil
			continue
		end
		-- bands waiting on each other: show one band's new leaves first, keeping its outgoing ones (sunk)
		local unionId: number? = nil
		for id in p.pending do
			if not p.covered[id] and (unionId == nil or bands[id] ~= nil) then
				unionId = id
			end
		end
		if unionId == nil then
			break -- nothing can make progress (should not happen): keep what is on screen
		end
		local id = unionId :: number
		local old = bands[id]
		local leaves: { [number]: Node } = {}
		local sunk: { [number]: boolean } = {}
		local count = 0
		for key, node in p.target[id] do
			leaves[key] = node
			count += 1
		end
		if old then
			for key, node in old.leaves do
				if leaves[key] == nil then
					leaves[key] = node
					sunk[key] = true
					count += 1
				end
			end
		end
		if next(sunk) == nil then
			-- nothing outgoing to keep: this is already the band's final mesh
			if not buildAndSwap(p, id, p.target[id], nil) then
				return
			end
			p.pending[id] = nil
		elseif count > MAX_MESH_LEAVES then
			-- too big for one mesh: drop the old band instead (plates cover the gap until the plan is done)
			if old then
				destroyBand(old)
				bands[id] = nil
			end
			coverageBroken = true
			if not buildAndSwap(p, id, p.target[id], nil) then
				return
			end
			p.pending[id] = nil
		elseif not buildAndSwap(p, id, leaves, sunk) then
			return
		end
		p.covered[id] = true
	end
	p.finished = true
end

-- Bands (ids) that hold, in the target selection, the replacements of a leaf that leaves the screen.
local function replacementBands(
	config: Config,
	node: Node,
	targetBand: { [number]: number },
	underBands: { [number]: { [number]: boolean } },
	out: { [number]: boolean }
)
	-- the same leaf, in another band
	local same = targetBand[node.key]
	if same then
		out[same] = true
		return
	end
	-- split: its descendants
	local below = underBands[node.key]
	if below then
		for id in below do
			out[id] = true
		end
		return
	end
	-- merged: its nearest ancestor that is a leaf now
	local face, depth, x, y = node.face, node.depth, node.x, node.y
	while depth > 0 do
		depth -= 1
		x //= 2
		y //= 2
		local id = targetBand[TerrainMath.nodeKey(config.bodyId, face, depth, x, y)]
		if id then
			out[id] = true
			return
		end
	end
end

-- Works out which bands change for `selection` and what each one waits for (fills the plan).
local function preparePlan(p: Plan, selection: Selection)
	local config = p.config
	local mergeLevel = TerrainMath.mergeLevel(config, selection.leaves, bandCount)
	local target: { [number]: { [number]: Node } } = {}
	local targetBand: { [number]: number } = {}
	local underBands: { [number]: { [number]: boolean } } = {}
	for _, node in selection.leaves do
		local id = TerrainMath.bandOf(config, node, mergeLevel)
		local set = target[id]
		if set == nil then
			local fresh: { [number]: Node } = {}
			target[id] = fresh
			set = fresh
		end
		(set :: { [number]: Node })[node.key] = node
		targetBand[node.key] = id
		-- every ancestor knows which bands hold leaves under it (for splits)
		local face, depth, x, y = node.face, node.depth, node.x, node.y
		while depth > 0 do
			depth -= 1
			x //= 2
			y //= 2
			local key = TerrainMath.nodeKey(config.bodyId, face, depth, x, y)
			local under = underBands[key]
			if under == nil then
				local fresh: { [number]: boolean } = {}
				underBands[key] = fresh
				under = fresh
			end
			(under :: { [number]: boolean })[id] = true
		end
	end
	local pending = p.pending
	local covered = p.covered
	local deps = p.deps
	local ids: { [number]: boolean } = {}
	for id in bands do
		ids[id] = true
	end
	for id in target do
		ids[id] = true
	end
	local steps = 0
	for id in ids do
		local old = bands[id]
		local new: { [number]: Node } = target[id] or {}
		target[id] = new
		local added, removed = false, false
		for key in new do
			if old == nil or old.leaves[key] == nil then
				added = true
				break
			end
		end
		local dep: { [number]: boolean } = {}
		if old then
			for key, node in old.leaves do
				if new[key] == nil then
					removed = true
					replacementBands(config, node, targetBand, underBands, dep)
				end
			end
		end
		dep[id] = nil
		if added or removed then
			pending[id] = true
			covered[id] = not added
			deps[id] = dep
			steps += 1
			if old and removed then
				old.stale = true -- drawn a little farther until it is rebuilt
			end
		end
	end
	p.selection = selection
	p.target = target
	p.steps = steps
end

-- The plan's thread: chooses the leaves (time-sliced), then builds and swaps the changed bands.
local function selectAndRun(p: Plan)
	local sliceStart = os.clock()
	local selectParams = params()
	selectParams.bandCount = bandCount
	selectParams.horizonLead = math.max(HORIZON_LEAD_MIN, HORIZON_LEAD_FRACTION * heightAboveGround(p.config, p.cam))
	selectParams.pause = function()
		if os.clock() - sliceStart >= tier.budgetS then
			task.wait()
			sliceStart = os.clock()
		end
	end
	local selection = TerrainMath.select(p.config, p.cam, selectParams, split)
	if p.aborted then
		return
	end
	preparePlan(p, selection)
	if p.aborted then
		return
	end
	runPlan(p)
end

-- Wraps up a finished plan (or handles its failure).
local function finishPlan()
	local p = plan
	if p == nil or not p.finished then
		return
	end
	plan = nil
	-- after real work the camera has moved on: look again right away
	forceSelect = p.steps > 0
	if p.failed then
		failures += 1
		retryAt = os.clock() + RETRY_DELAY
		if liveMeshes == 0 or bandCount <= MIN_BANDS or failures >= MAX_MESH_FAILURES then
			-- no mesh at all (API off, unpublished place), or still failing with the fewest bands
			releaseAllBands()
			disableMeshes(p.error or "unknown error")
		else
			-- probably the experience-wide mesh budget: hold fewer bands and start over (plates meanwhile)
			bandCount -= 1
			failures = 0
			releaseAllBands()
			table.clear(split)
		end
		return
	end
	failures = 0
	local selection = p.selection
	if selection then
		split = selection.split
	end
	displayedCam = p.cam
	coverageBroken = false
	for _, bm in bands do
		bm.stale = false
	end
	local keep: { [number]: boolean } = {}
	for _, bm in bands do
		for key in bm.leaves do
			keep[key] = true
		end
	end
	trimChunkCache(keep)
end

-- Re-selects the quadtree when the camera moved enough; starts a plan when the leaves changed.
local function maybeSelect(config: Config, cam: Vec3d)
	if plan ~= nil or os.clock() < retryAt then
		return
	end
	local now = os.clock()
	local lastCam = lastSelectCam
	if not forceSelect then
		if now - lastSelectTime < RESELECT_INTERVAL then
			return
		end
		if lastCam then
			local threshold = math.max(RESELECT_MIN_MOVE, RESELECT_MOVE_FRACTION * heightAboveGround(config, cam))
			if Vec3d.distance(cam, lastCam) < threshold then
				return
			end
		end
	end
	forceSelect = false
	lastSelectTime = now
	lastSelectCam = Vec3d.clone(cam)
	local p: Plan = {
		bodyId = config.bodyId,
		config = config,
		cam = Vec3d.clone(cam),
		selection = nil,
		target = {},
		pending = {},
		covered = {},
		deps = {},
		finished = false,
		failed = false,
		aborted = false,
		error = nil,
		builds = 0,
		steps = 0,
		current = "selecting",
		buildingMesh = nil,
		buildingPart = nil,
	}
	plan = p
	task.spawn(selectAndRun, p)
end

local function meshCoverage(config: Config, cam: Vec3d): boolean
	local at = displayedCam
	if at == nil or coverageBroken or next(bands) == nil then
		return false
	end
	local allowed = math.max(STALE_MIN, STALE_HEIGHT_FRACTION * heightAboveGround(config, cam))
	return Vec3d.distance(cam, at) <= allowed
end

local function setMeshesShown(shown: boolean)
	if meshesShown == shown then
		return
	end
	meshesShown = shown
	if not shown then
		for _, bm in bands do
			bm.part.Parent = nil
		end
	end
	-- shown: placeBands parents each band after posing it
end

-- Places every band: true scale, or uniformly scaled about the camera to fit the draw budget / part limit.
local function placeBands(ctx: RenderContext.RenderContext)
	local frame = ctx.frame
	local cam = ctx.cameraDominant
	local camWs = ctx.camera.Position
	local dd = ctx.drawDistance
	if dd ~= dd or dd <= 0 or dd > DRAW_DISTANCE_CAP then
		dd = DRAW_DISTANCE_CAP
	end
	local budget = BUDGET_FRACTION * dd
	local rotWs = Frames.rotationToWorkspace(frame, CFrame.identity)
	table.clear(moveParts)
	table.clear(moveCFrames)
	for _, bm in bands do
		Vec3d.subInto(scratch, bm.origin, cam)
		local dist = Vec3d.length(scratch)
		local k = TerrainMath.bandScale(dist, dist + bm.radius, bm.maxExtent, budget, FAR_LIMIT, PART_LIMIT)
		bm.scale = k
		if bm.stale then
			-- outgoing leaves lose every overlap with the incoming ones (exact: same image, a little deeper)
			local pushed = k * (1 + PUSH_BACK)
			if bm.maxExtent * pushed <= PART_LIMIT then
				k = pushed
			end
		end
		local applied = bm.appliedScale
		if applied <= 0 or math.abs(k - applied) > SIZE_REWRITE_FRACTION * applied then
			bm.part.Size = bm.size * k
			bm.appliedScale = k
		end
		local v = Frames.vectorToWorkspace(frame, scratch)
		table.insert(moveParts, bm.part)
		table.insert(moveCFrames, CFrame.new(camWs + v * bm.appliedScale) * rotWs)
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, BULK_MOVE_MODE)
	end
	local folder = meshFolder
	for _, bm in bands do
		if bm.part.Parent ~= folder then
			bm.part.Parent = folder
		end
	end
end

--============================================================================
-- Plates
--============================================================================
local function acquirePlate(): Part
	local p = table.remove(platePool)
	if p then
		return p
	end
	local part = Instance.new("Part")
	part.Name = "TerrainPlate"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Locked = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function releasePlate(plate: Plate)
	plate.part.Parent = nil
	table.insert(platePool, plate.part)
end

local function releaseAllPlates()
	for key, plate in plates do
		releasePlate(plate)
		plates[key] = nil
	end
	table.clear(plateParts)
	table.clear(plateCFrames)
	plateBodyId = nil
	plateLastCam = nil
	table.clear(plateSplit)
	table.clear(plateQueue)
	plateWanted = nil
	platesDirty = true
end

local function groundAt(config: Config, face: number, i: number, j: number): Vec3d
	local x, y, z = SurfaceHeight.nodeDirection(config.bodyId, face, i, j)
	local r = config.radius + SurfaceHeight.nodeHeight(config.bodyId, face, i, j)
	return Vec3d.new(x * r, y * r, z * r)
end

-- A plate for a leaf: a box whose top is the plane fitted to the leaf's corners and centre.
local function newPlate(config: Config, node: Node, folder: Folder): Plate
	local span = TerrainMath.CHUNK * node.stride
	local face = node.face
	local p00 = groundAt(config, face, node.i0, node.j0)
	local p10 = groundAt(config, face, node.i0 + span, node.j0)
	local p11 = groundAt(config, face, node.i0 + span, node.j0 + span)
	local p01 = groundAt(config, face, node.i0, node.j0 + span)
	local pc = Vec3d.new(node.cx, node.cy, node.cz)
	local up = Vec3d.cross(Vec3d.sub(p11, p00), Vec3d.sub(p01, p10))
	if Vec3d.dot(up, pc) < 0 then
		up = Vec3d.scale(up, -1)
	end
	up = Vec3d.normalize(up)
	local alongU = Vec3d.sub(Vec3d.add(p10, p11), Vec3d.add(p00, p01))
	local x = Vec3d.normalize(Vec3d.sub(alongU, Vec3d.scale(up, Vec3d.dot(alongU, up))))
	local z = Vec3d.cross(x, up)
	-- top plane through the mean of the five points, along `up`
	local mean = Vec3d.scale(Vec3d.add(Vec3d.add(Vec3d.add(p00, p10), Vec3d.add(p11, p01)), pc), 0.2)
	local sizeX =
		math.min(0.5 * (Vec3d.distance(p00, p10) + Vec3d.distance(p01, p11)) * PLATE_OVERLAP, PLATE_MAX_EXTENT)
	local sizeZ =
		math.min(0.5 * (Vec3d.distance(p00, p01) + Vec3d.distance(p10, p11)) * PLATE_OVERLAP, PLATE_MAX_EXTENT)
	local thickness = math.min(PLATE_THICKNESS + PLATE_THICKNESS_PER_M * math.max(sizeX, sizeZ), PLATE_MAX_EXTENT)
	local centre = Vec3d.sub(mean, Vec3d.scale(up, thickness / 2 + PLATE_DROP))
	local part = acquirePlate()
	part.Size = Vector3.new(sizeX, thickness, sizeZ)
	local dir = Vec3d.normalize(pc)
	local r, g, b, kind = Biome.sample(config.bodyId, dir.x, dir.y, dir.z)
	part.Color = Color3.new(r, g, b)
	part.Material = KIND_MATERIALS[kind] or FALLBACK_MATERIAL
	part.Reflectance = if kind == "Ocean" then OCEAN_REFLECTANCE else 0
	part.Parent = folder
	return {
		part = part,
		pos = centre,
		rot = CFrame.fromMatrix(Vector3.zero, Vec3d.toVector3(x), Vec3d.toVector3(up), Vec3d.toVector3(z)),
	}
end

local function updatePlates(ctx: RenderContext.RenderContext, config: Config)
	local folder = plateFolder
	local parent = root
	if folder == nil or parent == nil then
		return
	end
	if plateBodyId ~= config.bodyId then
		releaseAllPlates()
		plateBodyId = config.bodyId
	end
	local cam = ctx.cameraDominant
	local now = os.clock()
	local last = plateLastCam
	local moved = last == nil
		or Vec3d.distance(cam, last :: Vec3d)
			> math.max(RESELECT_MIN_MOVE, RESELECT_MOVE_FRACTION * heightAboveGround(config, cam))
	if moved and now - plateLastTime >= RESELECT_INTERVAL then
		plateLastTime = now
		plateLastCam = Vec3d.clone(cam)
		local selection = TerrainMath.select(config, cam, {
			splitK = PLATE_SPLIT_K,
			mergeK = PLATE_SPLIT_K * MERGE_FACTOR,
			maxLeaves = PLATE_MAX_LEAVES,
			maxLeafSize = PLATE_MAX_SIZE,
			maxDistance = PLATE_MAX_DISTANCE,
		}, plateSplit)
		plateSplit = selection.split
		local wanted: { [number]: Node } = {}
		for _, node in selection.leaves do
			wanted[node.key] = node
		end
		plateWanted = wanted
		-- nearest first
		table.clear(plateQueue)
		for key, node in wanted do
			if plates[key] == nil then
				table.insert(plateQueue, node)
			end
		end
		table.sort(plateQueue, function(a: Node, b: Node): boolean
			local da = (a.cx - cam.x) ^ 2 + (a.cy - cam.y) ^ 2 + (a.cz - cam.z) ^ 2
			local db = (b.cx - cam.x) ^ 2 + (b.cy - cam.y) ^ 2 + (b.cz - cam.z) ^ 2
			return da > db -- popped from the end
		end)
	end
	-- a few new plates per frame; the old ones go once every wanted plate exists (no holes meanwhile)
	local changed = false
	for _ = 1, PLATES_PER_FRAME do
		local node = table.remove(plateQueue)
		if node == nil then
			break
		end
		if plates[node.key] == nil then
			plates[node.key] = newPlate(config, node, folder)
			changed = true
		end
	end
	local wanted = plateWanted
	if wanted and #plateQueue == 0 then
		for key, plate in plates do
			if wanted[key] == nil then
				releasePlate(plate)
				plates[key] = nil
				changed = true
			end
		end
		plateWanted = nil
	end
	if changed then
		table.clear(plateParts)
		for _, plate in plates do
			table.insert(plateParts, plate.part)
		end
		platesDirty = true
	end
	if folder.Parent ~= parent then
		folder.Parent = parent
		platesDirty = true
	end
	platesShown = true
	local frame = ctx.frame
	if
		platesDirty
		or frame.refPos.x ~= lastPlateRef.x
		or frame.refPos.y ~= lastPlateRef.y
		or frame.refPos.z ~= lastPlateRef.z
		or frame.refRot ~= lastPlateRot
		or frame.slotOrigin ~= lastPlateSlot
	then
		-- relative to the camera (the terrain is the dominant body's; body offsets cancel)
		local camWs = ctx.camera.Position
		local rotWs = Frames.rotationToWorkspace(frame, CFrame.identity)
		table.clear(plateCFrames)
		local i = 0
		for _, plate in plates do
			i += 1
			plateParts[i] = plate.part
			Vec3d.subInto(scratch, plate.pos, cam)
			plateCFrames[i] = CFrame.new(camWs + Frames.vectorToWorkspace(frame, scratch)) * rotWs * plate.rot
		end
		if i > 0 then
			Workspace:BulkMoveTo(plateParts, plateCFrames, BULK_MOVE_MODE)
		end
		Vec3d.copyInto(lastPlateRef, frame.refPos)
		lastPlateRot = frame.refRot
		lastPlateSlot = frame.slotOrigin
		platesDirty = false
	end
end

local function hidePlates()
	if not platesShown then
		return
	end
	platesShown = false
	local folder = plateFolder
	if folder then
		folder.Parent = nil
	end
end

--============================================================================
-- API
--============================================================================
function TerrainMesh.init(parent: Folder)
	root = parent
	local meshes = Instance.new("Folder")
	meshes.Name = "TerrainMesh"
	meshes.Parent = parent
	meshFolder = meshes
	local platesFolderInstance = Instance.new("Folder")
	platesFolderInstance.Name = "TerrainPlates"
	plateFolder = platesFolderInstance
	local function applyTier(name: string)
		local wanted = TIERS[name] or TIERS.High
		if wanted ~= tier then
			tier = wanted
			tierName = name
			forceSelect = true
			for _, bm in bands do
				bm.part.CastShadow = bm.id == 0 and tier.shadows
			end
		end
	end
	applyTier(Quality.tier())
	Quality.onChanged(function(name: Quality.Tier)
		applyTier(name)
	end)
end

function TerrainMesh.update(ctx: RenderContext.RenderContext, show: boolean, prebuild: boolean)
	local config = TerrainMath.config(ctx.dominantBodyId)
	if config == nil or Vec3d.lengthSq(ctx.cameraDominant) < 1 or not (show or prebuild) then
		setMeshesShown(false)
		hidePlates()
		local now = os.clock()
		local since = hiddenSince
		if since == nil then
			hiddenSince = now
		elseif now - since > HIDDEN_RELEASE_S and (next(bands) ~= nil or plan ~= nil) then
			-- far from any ground for a while: give the meshes back
			abortPlan()
			releaseAllBands()
			table.clear(split)
			forceSelect = true
		end
		return
	end
	hiddenSince = nil
	if bodyId ~= config.bodyId then
		abortPlan()
		releaseAllBands()
		table.clear(split)
		bodyId = config.bodyId
		forceSelect = true
	end
	local cam = ctx.cameraDominant
	if meshEnabled then
		finishPlan()
		if meshEnabled then
			maybeSelect(config, cam)
		end
	end
	local covered = meshEnabled and meshCoverage(config, cam)
	if show and covered then
		setMeshesShown(true)
		placeBands(ctx)
		hidePlates()
	elseif show then
		setMeshesShown(false)
		updatePlates(ctx, config)
	else
		setMeshesShown(false)
		hidePlates()
	end
end

-- Band showing the leaf under body-relative `pos` (nil when none is displayed there).
local function bandAt(config: Config, pos: Vec3d): BandMesh?
	local face, fi, fj = SurfaceHeight.latticeCoords(config.bodyId, pos)
	local x, y = math.floor(fi / TerrainMath.CHUNK), math.floor(fj / TerrainMath.CHUNK)
	local depth = config.maxDepth
	local keys: { number } = {}
	while depth >= 0 do
		table.insert(keys, TerrainMath.nodeKey(config.bodyId, face, depth, x, y))
		depth -= 1
		x //= 2
		y //= 2
	end
	for _, bm in bands do
		for _, key in keys do
			if bm.leaves[key] then
				return bm
			end
		end
	end
	return nil
end

--[[
	Is body-relative `pos` (the dominant body) drawn at true scale this frame, `margin` m around it included? Plates
	are always true scale; meshes only where the band under every checked point is unscaled.
]]
function TerrainMesh.isTrueScaleAt(pos: Vec3d, margin: number): boolean
	if not meshesShown then
		return true
	end
	local id = bodyId
	local config = if id then TerrainMath.config(id) else nil
	if config == nil then
		return true
	end
	local up = Vec3d.normalize(pos)
	local ref = if math.abs(up.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
	local e1 = Vec3d.normalize(Vec3d.cross(ref, up))
	local e2 = Vec3d.cross(up, e1)
	for index = 0, 4 do
		local p = pos
		if index > 0 and margin > 0 then
			local axis = if index <= 2 then e1 else e2
			p = Vec3d.add(pos, Vec3d.scale(axis, if index % 2 == 0 then margin else -margin))
		end
		local bm = bandAt(config, p)
		if bm == nil or bm.scale < TRUE_SCALE then
			return false
		end
	end
	return true
end

-- F3 debug line.
function TerrainMesh.summary(): string
	if not meshEnabled then
		local count = 0
		for _ in plates do
			count += 1
		end
		return string.format("Terrain: plates %d (EditableMesh unavailable)", count)
	end
	local ids: { number } = {}
	for id in bands do
		table.insert(ids, id)
	end
	table.sort(ids)
	local parts: { string } = {}
	local leaves, triangles = 0, 0
	for _, id in ids do
		local bm = bands[id]
		leaves += bm.count
		triangles += bm.triangles
		table.insert(parts, string.format("%d:%d x%.2f%s", id, bm.count, bm.scale, if bm.stale then "*" else ""))
	end
	local p = plan
	return string.format(
		"Terrain: %s  %d leaves  %.1fk tris  [%s]  %s  meshes %d (bands <= %d)  cache %d%s",
		tierName,
		leaves,
		triangles / 1000,
		table.concat(parts, " "),
		if p then string.format("building %s (%d/%d)", p.current, p.builds, p.steps) else "idle",
		liveMeshes,
		bandCount,
		chunkCount,
		if meshesShown then "" elseif platesShown then "  (plates)" else ""
	)
end

-- Test hook: what is on screen (leaf key -> band id, and band id -> scale), for offline simulations.
TerrainMesh._test = table.freeze({
	displayed = function(): ({ [number]: number }, { [number]: number }, boolean, boolean)
		local leaves: { [number]: number } = {}
		local scales: { [number]: number } = {}
		for id, bm in bands do
			scales[id] = bm.scale
			for key in bm.leaves do
				leaves[key] = id
			end
		end
		return leaves, scales, meshesShown, platesShown
	end,
	liveMeshes = function(): number
		return liveMeshes
	end,
})

return table.freeze(TerrainMesh)
