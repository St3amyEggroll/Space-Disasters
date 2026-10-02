--!strict
--!native
--[[
	TerrainMath (CHANGED (Phase 8): surface terrain)
	Pure helpers of the terrain renderer (Render/TerrainMesh), testable offline:

	  * Quadtree: every cube face of a body is a quadtree whose depth-d node (face, d, x, y) covers the lattice cells
	    of SurfaceHeight [x, x + 1) * CHUNK * 2^(maxDepth - d) along i (same along j). A leaf is drawn as a CHUNK x CHUNK
	    grid of quads at that stride, so the deepest leaves use every lattice node: they ARE the physics ground.
	  * select(): nodes beyond the horizon are dropped; a node splits while the camera is closer than splitK times its
	    size (mergeK, a little larger, for nodes that were split last time: hysteresis); the whole selection is retried
	    with a smaller splitK while it has more than maxLeaves leaves.
	  * Bands: leaves are drawn in batches (one mesh each), one per level of detail: band id = levels above the
	    deepest (0 = the physics resolution), except that every level from mergeLevel up shares one band (the mesh
	    budget). A level's leaves form a ring around the camera about twice as far out as it is in, so each band is
	    either small enough to draw at true scale (the finest) or is drawn uniformly scaled down about the camera
	    (bandScale) to fit the draw distance and the 2048-stud part limit; thin rings keep that scale close between
	    neighbouring bands, so depth stays nearly in order and far bands stay well behind the craft.
	  * Chunk geometry (buildChunk): CHUNK + 1 squared vertices on the lattice (same triangles and diagonal as
	    SurfaceHeight), smooth normals from the neighbouring nodes (also across chunk and face edges), Biome vertex
	    colours (Earth: steep slopes turn to rock), and a skirt hanging below every edge, deep enough to cover the
	    crack to a neighbour up to two levels coarser. Positions are relative to the chunk's centre point and sit
	    RENDER_DROP below the true ground (no z-fighting with the launch site's ground plate).
	  * Collision: the lattice triangles near a point (collisionTriangles) and the two WedgeParts that fill a triangle
	    (wedgePair), solid below it.

	All positions are body-relative metres (body axes = universe axes) in doubles.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local CHUNK = SurfaceHeight.LATTICE_CHUNK -- quads per chunk edge (8)
local HORIZON_MARGIN = 0.02 -- rad beyond the geometric horizon that is still drawn
local NODE_RADIUS_PAD = 0.15 -- bounding radius allowance per metre of node size (relief inside the node)
local FLAT_TOLERANCE = 0.05 -- m: a node whose nine samples agree this well is flat (open sea)
local FLAT_SPLIT_FACTOR = 0.4 -- flat nodes split at this fraction of the usual distance
local TOP_PAD = 0.3 -- a node's highest ground is taken as its highest sample + this x its size (unsampled peaks)
local MAX_BAND_LEAVES = 95 -- leaves of one level at most (EditableMesh: 20,000 triangles per mesh; 192 per leaf)
local MAX_SELECT_RETRIES = 5
local RETRY_FACTOR = 0.8 -- splitK multiplier per retry when there are too many leaves
local SKIRT_MIN = 2 -- m
local SKIRT_ERROR_MULT = 1.5 -- x the largest gap to a 2x / 4x coarser or 2x finer neighbour's edge
local SKIRT_ERROR_PAD = 1 -- m (skirts stay short: a deep skirt of a scaled-down band would cover nearer ground)
local RENDER_DROP = 0.12 -- m the drawn ground sits below the true ground
local ROCK_SLOPE0 = 0.2 -- 1 - cos(slope): steep Earth ground starts turning to rock here (~37 deg)
local ROCK_SLOPE1 = 0.42 -- fully rock (~55 deg)
local ROCK_COLOR = { 0.47, 0.43, 0.39 }
-- the launch site's ground plate (HomeBase "Ground", 99 / 102 / 107) painted into the terrain, so the base still shows
-- as a grey square from high up, where its parts are not drawn (Surface hides the site copy over scaled terrain)
local SITE_PLATE_COLOR = { 99 / 255, 102 / 255, 107 / 255 }
local SITE_PLATE_HALF = BaseLayout.SITE_HALF_EXTENT -- m, in the site's tangent plane
local NODE_CACHE_MAX = 6000 -- cached quadtree nodes before the cache is cleared (a selection visits ~1000)
local MIN_SCALE = 1e-4 -- smallest band scale factor
local VERTEX_BYTES = 36 -- chunk vertex record: position, normal, colour (9 f32)
--============================================================================

export type Config = {
	bodyId: number,
	radius: number, -- m
	n: number, -- lattice cells per face edge
	maxDepth: number, -- deepest quadtree level (its leaves use stride 1)
	cellArc: number, -- m, lattice cell edge at a face centre
	minHeight: number,
	maxHeight: number,
}

export type Node = {
	key: number,
	face: number,
	depth: number,
	x: number,
	y: number,
	i0: number, -- first lattice index along u
	j0: number, -- along v
	stride: number, -- lattice cells per chunk quad
	size: number, -- m, edge length
	cx: number, -- centre ground point (body-relative, m)
	cy: number,
	cz: number,
	dx: number, -- unit direction of the centre
	dy: number,
	dz: number,
	radius: number, -- m, bounding radius around the centre point
	flat: boolean, -- all nine samples (corners, edge middles, centre) at the same height (open sea): splits later
	top: number, -- m, highest ground the node may hold (samples + TOP_PAD x size, at most the body's maximum)
}

export type Params = {
	splitK: number,
	mergeK: number,
	maxLeaves: number,
	maxLeafSize: number?, -- m: nodes bigger than this always split (Part fallback: Part size limit)
	maxDistance: number?, -- m: nodes farther than this from the camera are dropped
	pause: (() -> ())?, -- called for every node visited (a caller in a thread may yield there)
	bandCount: number?, -- bands the leaves will be drawn in (TerrainMath.bandOf): none may exceed MAX_BAND_LEAVES
	horizonLead: number?, -- m: the horizon is taken this much higher than the camera (it climbs while meshes build)
}

export type Selection = {
	leaves: { Node },
	split: { [number]: boolean },
	splitK: number, -- the splitK that was finally used
}

export type Chunk = {
	key: number,
	depth: number,
	ox: number, -- origin = the node's centre ground point (body-relative, m)
	oy: number,
	oz: number,
	vertexCount: number,
	triangleCount: number,
	data: buffer, -- per vertex VERTEX_BYTES: position (relative to the origin), unit normal, colour (9 f32)
	tris: { number }, -- vertex index triples (1-based), counter-clockwise seen from above (shared: never modify)
	skirt: number, -- m
	minX: number, -- bounding box of the vertices (relative to the origin)
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number,
}

export type Triangle = { number } -- ax, ay, az, bx, by, bz, cx, cy, cz (body-relative, m), counter-clockwise from above

local TerrainMath = {}

TerrainMath.CHUNK = CHUNK
TerrainMath.MAX_BAND_LEAVES = MAX_BAND_LEAVES
TerrainMath.RENDER_DROP = RENDER_DROP

local function smoothstep(e0: number, e1: number, v: number): number
	local t = (v - e0) / (e1 - e0)
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end

--============================================================================
-- Quadtree
--============================================================================
local configs: { [number]: Config } = {}
local noConfig: { [number]: boolean } = {}

-- The terrain configuration of a body (nil for bodies without a surface).
function TerrainMath.config(bodyId: number): Config?
	local cached = configs[bodyId]
	if cached then
		return cached
	elseif noConfig[bodyId] then
		return nil
	end
	local n = SurfaceHeight.latticeSize(bodyId)
	if n <= 0 then
		noConfig[bodyId] = true
		return nil
	end
	local radius = Bodies.get(bodyId).Radius
	local minHeight, maxHeight = SurfaceHeight.bounds(bodyId)
	local config: Config = {
		bodyId = bodyId,
		radius = radius,
		n = n,
		maxDepth = math.round(math.log(n / CHUNK, 2)),
		cellArc = radius * (math.pi / 2) / n,
		minHeight = minHeight,
		maxHeight = maxHeight,
	}
	configs[bodyId] = config
	return config
end

-- A stable number for a node: (body, face, depth, x, y), x and y < 2^15.
function TerrainMath.nodeKey(bodyId: number, face: number, depth: number, x: number, y: number): number
	return (((bodyId * 8 + face) * 32 + depth) * 32768 + x) * 32768 + y
end

local nodeCaches: { [number]: { [number]: Node } } = {}
local nodeCounts: { [number]: number } = {}

local function groundPoint(bodyId: number, radius: number, face: number, i: number, j: number): (number, number, number)
	local x, y, z = SurfaceHeight.nodeDirection(bodyId, face, i, j)
	local r = radius + SurfaceHeight.nodeHeight(bodyId, face, i, j)
	return x * r, y * r, z * r
end

-- The quadtree node (face, depth, x, y) of a body (cached).
function TerrainMath.node(config: Config, face: number, depth: number, x: number, y: number): Node
	local bodyId = config.bodyId
	local key = TerrainMath.nodeKey(bodyId, face, depth, x, y)
	local cache = nodeCaches[bodyId]
	if cache == nil then
		cache = {}
		nodeCaches[bodyId] = cache
		nodeCounts[bodyId] = 0
	end
	assert(cache)
	local hit = cache[key]
	if hit then
		return hit
	end
	local stride = 2 ^ (config.maxDepth - depth)
	local span = CHUNK * stride
	local i0, j0 = x * span, y * span
	local half = span / 2
	local radius = config.radius
	local dx, dy, dz = SurfaceHeight.nodeDirection(bodyId, face, i0 + half, j0 + half)
	local cx, cy, cz = groundPoint(bodyId, radius, face, i0 + half, j0 + half)
	local reach = 0
	local centreHeight = SurfaceHeight.nodeHeight(bodyId, face, i0 + half, j0 + half)
	local flat = true
	local top = centreHeight
	for sample = 0, 8 do
		local si = i0 + (sample % 3) * half
		local sj = j0 + math.floor(sample / 3) * half
		local px, py, pz = groundPoint(bodyId, radius, face, si, sj)
		local d = math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2 + (pz - cz) ^ 2)
		if d > reach then
			reach = d
		end
		local h = SurfaceHeight.nodeHeight(bodyId, face, si, sj)
		if math.abs(h - centreHeight) > FLAT_TOLERANCE then
			flat = false
		end
		if h > top then
			top = h
		end
	end
	local size = span * config.cellArc
	-- highest ground the node may hold: its samples plus an allowance for peaks between them
	top = math.min(top + (if flat then 0 else TOP_PAD * size), config.maxHeight)
	local node: Node = {
		key = key,
		face = face,
		depth = depth,
		x = x,
		y = y,
		i0 = i0,
		j0 = j0,
		stride = stride,
		size = size,
		cx = cx,
		cy = cy,
		cz = cz,
		dx = dx,
		dy = dy,
		dz = dz,
		radius = reach + NODE_RADIUS_PAD * size,
		flat = flat,
		top = top,
	}
	if nodeCounts[bodyId] >= NODE_CACHE_MAX then
		table.clear(cache)
		nodeCounts[bodyId] = 0
	end
	cache[key] = node
	nodeCounts[bodyId] += 1
	return node
end

--[[
	Angle (rad) from the camera's nadir within which ground up to `top` m high can be seen over the horizon (plus
	HORIZON_MARGIN). The horizon is taken at the body's lowest ground, so this never hides anything visible.
]]
function TerrainMath.horizonAngle(config: Config, cameraRadius: number, top: number?): number
	local low = config.radius + config.minHeight
	local high = config.radius + math.max(top or config.maxHeight, config.minHeight)
	local fromCamera = if cameraRadius > low then math.acos(low / cameraRadius) else 0
	return fromCamera + math.acos(math.min(low / high, 1)) + HORIZON_MARGIN
end

local function selectOnce(
	config: Config,
	cam: Vec3d,
	params: Params,
	splitK: number,
	prevSplit: { [number]: boolean }?
): ({ Node }, { [number]: boolean })
	local leaves: { Node } = {}
	local split: { [number]: boolean } = {}
	local rc = Vec3d.length(cam)
	local cdx, cdy, cdz = cam.x / rc, cam.y / rc, cam.z / rc
	local low = config.radius + config.minHeight
	local rcHorizon = rc + (params.horizonLead or 0)
	local fromCamera = (if rcHorizon > low then math.acos(low / rcHorizon) else 0) + HORIZON_MARGIN
	local invRadius = 1 / config.radius
	local maxDepth = config.maxDepth
	local mergeK = math.max(params.mergeK * splitK / params.splitK, splitK)
	local maxLeafSize = params.maxLeafSize or math.huge
	local maxDistance = params.maxDistance or math.huge
	local pause = params.pause
	local function visit(face: number, depth: number, x: number, y: number)
		if pause then
			pause()
		end
		local node = TerrainMath.node(config, face, depth, x, y)
		local cosA = node.dx * cdx + node.dy * cdy + node.dz * cdz
		if cosA > 1 then
			cosA = 1
		elseif cosA < -1 then
			cosA = -1
		end
		-- over the horizon: the node's highest ground cannot be seen from the camera
		local beyond = math.acos(low / (config.radius + math.max(node.top, config.minHeight)))
		if math.acos(cosA) - node.radius * invRadius > fromCamera + beyond then
			return
		end
		local ex, ey, ez = cam.x - node.cx, cam.y - node.cy, cam.z - node.cz
		local dist = math.sqrt(ex * ex + ey * ey + ez * ez) - node.radius
		if dist < 0 then
			dist = 0
		end
		if dist > maxDistance then
			return
		end
		local k = if prevSplit and prevSplit[node.key] then mergeK else splitK
		if node.flat then
			k *= FLAT_SPLIT_FACTOR
		end
		if depth < maxDepth and (dist < k * node.size or node.size > maxLeafSize) then
			split[node.key] = true
			local cx, cy = 2 * x, 2 * y
			visit(face, depth + 1, cx, cy)
			visit(face, depth + 1, cx + 1, cy)
			visit(face, depth + 1, cx, cy + 1)
			visit(face, depth + 1, cx + 1, cy + 1)
		else
			table.insert(leaves, node)
		end
	end
	for face = 1, 6 do
		visit(face, 0, 0, 0)
	end
	return leaves, split
end

-- Is any level over MAX_BAND_LEAVES?
-- Would any band (one per level, levels from the finest + bandCount - 1 up merged) hold over MAX_BAND_LEAVES?
local function crowded(config: Config, leaves: { Node }, bandCount: number): boolean
	local merge = TerrainMath.mergeLevel(config, leaves, bandCount)
	local perBand: { [number]: number } = {}
	for _, node in leaves do
		local band = math.min(config.maxDepth - node.depth, merge)
		local count = (perBand[band] or 0) + 1
		if count > MAX_BAND_LEAVES then
			return true
		end
		perBand[band] = count
	end
	return false
end

--[[
	The leaves to draw for a camera at `cam` (body-relative). `prevSplit` is the previous selection's split set
	(hysteresis). Retries with a smaller splitK while there are more than params.maxLeaves leaves (or more than
	MAX_BAND_LEAVES in one level).
]]
function TerrainMath.select(config: Config, cam: Vec3d, params: Params, prevSplit: { [number]: boolean }?): Selection
	local splitK = params.splitK
	local leaves, split = selectOnce(config, cam, params, splitK, prevSplit)
	local tries = 1
	local bandCount = params.bandCount or math.huge
	while (#leaves > params.maxLeaves or crowded(config, leaves, bandCount)) and tries < MAX_SELECT_RETRIES do
		splitK *= RETRY_FACTOR
		leaves, split = selectOnce(config, cam, params, splitK, prevSplit)
		tries += 1
	end
	return { leaves = leaves, split = split, splitK = splitK }
end

-- Levels above the deepest (0 = the physics resolution) of a node.
function TerrainMath.levelOf(config: Config, node: Node): number
	return config.maxDepth - node.depth
end

--[[
	First level that shares a band for a selection drawn with `bandCount` bands: the finest level present plus
	bandCount - 1 (every coarser level joins that last band).
]]
function TerrainMath.mergeLevel(config: Config, leaves: { Node }, bandCount: number): number
	local finest = math.huge
	for _, node in leaves do
		local level = config.maxDepth - node.depth
		if level < finest then
			finest = level
		end
	end
	if finest == math.huge then
		finest = 0
	end
	return finest + math.max(bandCount, 1) - 1
end

-- Band id of a leaf: its level, or mergeLevel for every coarser level.
function TerrainMath.bandOf(config: Config, node: Node, mergeLevel: number): number
	return math.min(config.maxDepth - node.depth, mergeLevel)
end

-- Key of the parent of node (face, depth, x, y) (nil at depth 0).
function TerrainMath.parentKey(bodyId: number, face: number, depth: number, x: number, y: number): number?
	if depth <= 0 then
		return nil
	end
	return TerrainMath.nodeKey(bodyId, face, depth - 1, x // 2, y // 2)
end

--[[
	Uniform scale about the camera for a band whose box centre is `distCentre` m away, whose farthest point is
	`distFar` m away and whose box is `extent` m across at most: 1 (true scale) when it fits. The engine culls a part
	by where it is (its centre within the draw budget keeps it drawn, vertices and all: S11), the far end must stay
	inside `farLimit` (the farthest anything is drawn at the best quality) and the part size limit always holds.
]]
function TerrainMath.bandScale(
	distCentre: number,
	distFar: number,
	extent: number,
	budget: number,
	farLimit: number,
	partLimit: number
): number
	local k = 1
	if distCentre * k > budget then
		k = budget / distCentre
	end
	if distFar * k > farLimit then
		k = farLimit / distFar
	end
	if extent * k > partLimit then
		k = partLimit / extent
	end
	if k < MIN_SCALE then
		k = MIN_SCALE
	end
	return k
end

--============================================================================
-- Chunk geometry
--============================================================================

-- Largest radial gap (m) between an edge's heights and the same edge seen by a neighbour `factor` times coarser.
--[[
	Largest radial gap (m) between an edge's ground points (ex, ey, ez: CHUNK + 1 points) and the straight edge a
	neighbour `factor` times coarser draws through every factor-th of them (chord sag included).
]]
local function edgeGap(ex: { number }, ey: { number }, ez: { number }, factor: number): number
	local worst = 0
	for k = 0, CHUNK do
		local k0 = math.floor(k / factor) * factor
		if k0 == k then
			continue
		end
		local k1 = math.min(k0 + factor, CHUNK)
		local t = (k - k0) / (k1 - k0)
		local cx = ex[k0 + 1] + (ex[k1 + 1] - ex[k0 + 1]) * t
		local cy = ey[k0 + 1] + (ey[k1 + 1] - ey[k0 + 1]) * t
		local cz = ez[k0 + 1] + (ez[k1 + 1] - ez[k0 + 1]) * t
		local px, py, pz = ex[k + 1], ey[k + 1], ez[k + 1]
		local gap = math.abs(math.sqrt(px * px + py * py + pz * pz) - math.sqrt(cx * cx + cy * cy + cz * cz))
		if gap > worst then
			worst = gap
		end
	end
	return worst
end

-- Grid position (a, b) of the k-th vertex along chunk edge 1 (a = 0), 2 (a = CHUNK), 3 (b = 0) or 4 (b = CHUNK).
local function edgeVertex(edge: number, k: number): (number, number)
	if edge == 1 then
		return 0, k
	elseif edge == 2 then
		return CHUNK, k
	elseif edge == 3 then
		return k, 0
	end
	return k, CHUNK
end

local templates: { [number]: { number } } = {}

--[[
	Triangle indices of a chunk (every chunk has the same topology): bit 0 of `mask` flips the ground triangles'
	winding, bit `edge` flips that edge's skirt quads. Shared and frozen.
]]
local function triangleTemplate(mask: number): { number }
	local cached = templates[mask]
	if cached then
		return cached
	end
	local tris: { number } = table.create(3 * (2 * CHUNK * CHUNK + 8 * CHUNK))
	local function vertex(a: number, b: number): number
		return a * (CHUNK + 1) + b + 1
	end
	local flip = mask % 2 == 1
	local function tri(a: number, b: number, c: number)
		if flip then
			b, c = c, b
		end
		table.insert(tris, a)
		table.insert(tris, b)
		table.insert(tris, c)
	end
	for a = 0, CHUNK - 1 do
		for b = 0, CHUNK - 1 do
			-- same split as SurfaceHeight: (a, b) -> (a + 1, b + 1)
			local v00, v10, v11, v01 = vertex(a, b), vertex(a + 1, b), vertex(a + 1, b + 1), vertex(a, b + 1)
			tri(v00, v10, v11)
			tri(v00, v11, v01)
		end
	end
	local surfaceCount = (CHUNK + 1) * (CHUNK + 1)
	for edge = 1, 4 do
		local first = surfaceCount + (edge - 1) * (CHUNK + 1) + 1
		local skirtFlip = math.floor(mask / 2 ^ edge) % 2 == 1
		for k = 0, CHUNK - 1 do
			local a0, b0 = edgeVertex(edge, k)
			local a1, b1 = edgeVertex(edge, k + 1)
			local A, B = vertex(a0, b0), vertex(a1, b1)
			local D, C = first + k, first + k + 1
			if skirtFlip then
				table.insert(tris, A)
				table.insert(tris, C)
				table.insert(tris, B)
				table.insert(tris, A)
				table.insert(tris, D)
				table.insert(tris, C)
			else
				table.insert(tris, A)
				table.insert(tris, B)
				table.insert(tris, C)
				table.insert(tris, A)
				table.insert(tris, C)
				table.insert(tris, D)
			end
		end
	end
	table.freeze(tris)
	templates[mask] = tris
	return tris
end

--[[
	Geometry of a leaf: (CHUNK + 1)^2 ground vertices plus a skirt along each edge. Vertex index of ground vertex
	(a, b) (a along u, b along v, 0 .. CHUNK) is a * (CHUNK + 1) + b + 1.
]]
function TerrainMath.buildChunk(config: Config, node: Node): Chunk
	local bodyId = config.bodyId
	local radius = config.radius
	local face, i0, j0, s = node.face, node.i0, node.j0, node.stride
	local side = CHUNK + 3 -- grid with one ring of neighbours for the normals
	local count = side * side
	local gx: { number } = table.create(count, 0)
	local gy: { number } = table.create(count, 0)
	local gz: { number } = table.create(count, 0)
	local hx: { number } = table.create(count, 0)
	local dxs: { number } = table.create(count, 0)
	local dys: { number } = table.create(count, 0)
	local dzs: { number } = table.create(count, 0)
	for a = -1, CHUNK + 1 do
		for b = -1, CHUNK + 1 do
			local idx = (a + 1) * side + (b + 1) + 1
			local i, j = i0 + a * s, j0 + b * s
			local x, y, z = SurfaceHeight.nodeDirection(bodyId, face, i, j)
			local h = SurfaceHeight.nodeHeight(bodyId, face, i, j)
			local r = radius + h
			gx[idx], gy[idx], gz[idx] = x * r, y * r, z * r
			hx[idx] = h
			dxs[idx], dys[idx], dzs[idx] = x, y, z
		end
	end
	local function g(a: number, b: number): number
		return (a + 1) * side + (b + 1) + 1
	end
	local ox, oy, oz = node.cx, node.cy, node.cz

	local surfaceCount = (CHUNK + 1) * (CHUNK + 1)
	local total = surfaceCount + 4 * (CHUNK + 1)
	local px: { number } = table.create(total, 0)
	local py: { number } = table.create(total, 0)
	local pz: { number } = table.create(total, 0)
	local nx: { number } = table.create(total, 0)
	local ny: { number } = table.create(total, 0)
	local nz: { number } = table.create(total, 0)
	local cr: { number } = table.create(total, 0)
	local cg: { number } = table.create(total, 0)
	local cb: { number } = table.create(total, 0)
	local earth = bodyId == Bodies.HOMEWORLD
	for a = 0, CHUNK do
		for b = 0, CHUNK do
			local idx = g(a, b)
			local v = a * (CHUNK + 1) + b + 1
			local dx, dy, dz = dxs[idx], dys[idx], dzs[idx]
			px[v] = gx[idx] - dx * RENDER_DROP - ox
			py[v] = gy[idx] - dy * RENDER_DROP - oy
			pz[v] = gz[idx] - dz * RENDER_DROP - oz
			-- smooth normal from the neighbouring nodes (central differences)
			local ia, ib = g(a + 1, b), g(a - 1, b)
			local ja, jb = g(a, b + 1), g(a, b - 1)
			local ux, uy, uz = gx[ia] - gx[ib], gy[ia] - gy[ib], gz[ia] - gz[ib]
			local wx, wy, wz = gx[ja] - gx[jb], gy[ja] - gy[jb], gz[ja] - gz[jb]
			local cx, cy, cz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
			local len = math.sqrt(cx * cx + cy * cy + cz * cz)
			if len <= 0 then
				cx, cy, cz, len = dx, dy, dz, 1
			end
			if cx * dx + cy * dy + cz * dz < 0 then
				len = -len
			end
			cx, cy, cz = cx / len, cy / len, cz / len
			nx[v], ny[v], nz[v] = cx, cy, cz
			local r, gg, bb = Biome.sample(bodyId, dx, dy, dz)
			if
				earth
				and dx > 0
				and math.abs(dy) <= SITE_PLATE_HALF * dx / radius
				and math.abs(dz) <= SITE_PLATE_HALF * dx / radius
			then
				-- base-pocket axes at lat 0 / lon 0: east = universe +Z, north = universe +Y, up = +X
				r, gg, bb = SITE_PLATE_COLOR[1], SITE_PLATE_COLOR[2], SITE_PLATE_COLOR[3]
			elseif earth then
				local rock = smoothstep(ROCK_SLOPE0, ROCK_SLOPE1, 1 - (cx * dx + cy * dy + cz * dz))
				if rock > 0 then
					r += (ROCK_COLOR[1] - r) * rock
					gg += (ROCK_COLOR[2] - gg) * rock
					bb += (ROCK_COLOR[3] - bb) * rock
				end
			end
			cr[v], cg[v], cb[v] = r, gg, bb
		end
	end

	--[[
		skirt depth: covers the crack along any edge to a neighbour up to 4x coarser (whose straight edge may pass
		below this one's vertices), and to a 2x finer one (whose extra vertices may dip below this edge)
	]]
	local ex: { number } = table.create(CHUNK + 1, 0)
	local ey: { number } = table.create(CHUNK + 1, 0)
	local ez: { number } = table.create(CHUNK + 1, 0)
	local worst = 0
	local half = s / 2
	for edge = 1, 4 do
		for k = 0, CHUNK do
			local idx = g(edgeVertex(edge, k))
			ex[k + 1], ey[k + 1], ez[k + 1] = gx[idx], gy[idx], gz[idx]
		end
		worst = math.max(worst, edgeGap(ex, ey, ez, 2), edgeGap(ex, ey, ez, 4))
		if s >= 2 then
			for k = 0, CHUNK - 1 do
				local a0, b0 = edgeVertex(edge, k)
				local a1, b1 = edgeVertex(edge, k + 1)
				local i = i0 + a0 * s + (a1 - a0) * half
				local j = j0 + b0 * s + (b1 - b0) * half
				local x, y, z = groundPoint(bodyId, radius, face, i, j)
				local cx, cy, cz = (ex[k + 1] + ex[k + 2]) / 2, (ey[k + 1] + ey[k + 2]) / 2, (ez[k + 1] + ez[k + 2]) / 2
				local gap = math.abs(math.sqrt(x * x + y * y + z * z) - math.sqrt(cx * cx + cy * cy + cz * cz))
				if gap > worst then
					worst = gap
				end
			end
		end
	end
	local skirt = math.max(SKIRT_MIN, SKIRT_ERROR_MULT * worst + SKIRT_ERROR_PAD)

	local function vertex(a: number, b: number): number
		return a * (CHUNK + 1) + b + 1
	end
	-- winding: (B - A) x (C - A) must point up (outward) for the cell (0, 0) triangle (00, 10, 11)
	local mask = 0
	do
		local A, B, C = vertex(0, 0), vertex(1, 0), vertex(1, 1)
		local ux, uy, uz = px[B] - px[A], py[B] - py[A], pz[B] - pz[A]
		local wx, wy, wz = px[C] - px[A], py[C] - py[A], pz[C] - pz[A]
		local cx, cy, cz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
		if cx * node.dx + cy * node.dy + cz * node.dz < 0 then
			mask += 1
		end
	end

	-- skirts: a copy of each edge lowered by `skirt`, joined to it with quads facing outward
	local nextVertex = surfaceCount
	for edge = 1, 4 do
		local first = nextVertex + 1
		for k = 0, CHUNK do
			local a, b = edgeVertex(edge, k)
			local src = vertex(a, b)
			local idx = g(a, b)
			nextVertex += 1
			px[nextVertex] = px[src] - dxs[idx] * skirt
			py[nextVertex] = py[src] - dys[idx] * skirt
			pz[nextVertex] = pz[src] - dzs[idx] * skirt
			nx[nextVertex], ny[nextVertex], nz[nextVertex] = nx[src], ny[src], nz[src]
			cr[nextVertex], cg[nextVertex], cb[nextVertex] = cr[src], cg[src], cb[src]
		end
		-- does the quad (A, B, C) face outward (from the chunk centre toward the edge's middle)?
		local ma, mb = edgeVertex(edge, CHUNK / 2)
		local mid, centre = vertex(ma, mb), vertex(CHUNK / 2, CHUNK / 2)
		local outX, outY, outZ = px[mid] - px[centre], py[mid] - py[centre], pz[mid] - pz[centre]
		local a0, b0 = edgeVertex(edge, 0)
		local a1, b1 = edgeVertex(edge, 1)
		local A, B, C = vertex(a0, b0), vertex(a1, b1), first + 1
		local ux, uy, uz = px[B] - px[A], py[B] - py[A], pz[B] - pz[A]
		local wx, wy, wz = px[C] - px[A], py[C] - py[A], pz[C] - pz[A]
		local cx, cy, cz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
		if cx * outX + cy * outY + cz * outZ < 0 then
			mask += 2 ^ edge
		end
	end

	-- pack the vertices (f32: positions are small offsets from the origin)
	local data = buffer.create(nextVertex * VERTEX_BYTES)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for v = 1, nextVertex do
		local x, y, z = px[v], py[v], pz[v]
		if x < minX then
			minX = x
		end
		if x > maxX then
			maxX = x
		end
		if y < minY then
			minY = y
		end
		if y > maxY then
			maxY = y
		end
		if z < minZ then
			minZ = z
		end
		if z > maxZ then
			maxZ = z
		end
		local o = (v - 1) * VERTEX_BYTES
		buffer.writef32(data, o, x)
		buffer.writef32(data, o + 4, y)
		buffer.writef32(data, o + 8, z)
		buffer.writef32(data, o + 12, nx[v])
		buffer.writef32(data, o + 16, ny[v])
		buffer.writef32(data, o + 20, nz[v])
		buffer.writef32(data, o + 24, cr[v])
		buffer.writef32(data, o + 28, cg[v])
		buffer.writef32(data, o + 32, cb[v])
	end
	local tris = triangleTemplate(mask)
	return {
		key = node.key,
		depth = node.depth,
		ox = ox,
		oy = oy,
		oz = oz,
		vertexCount = nextVertex,
		triangleCount = #tris / 3,
		data = data,
		tris = tris,
		skirt = skirt,
		minX = minX,
		minY = minY,
		minZ = minZ,
		maxX = maxX,
		maxY = maxY,
		maxZ = maxZ,
	}
end

-- Vertex v of a chunk: position (relative to the chunk origin), unit normal and colour.
function TerrainMath.chunkVertex(
	chunk: Chunk,
	v: number
): (number, number, number, number, number, number, number, number, number)
	local data, o = chunk.data, (v - 1) * VERTEX_BYTES
	return buffer.readf32(data, o),
		buffer.readf32(data, o + 4),
		buffer.readf32(data, o + 8),
		buffer.readf32(data, o + 12),
		buffer.readf32(data, o + 16),
		buffer.readf32(data, o + 20),
		buffer.readf32(data, o + 24),
		buffer.readf32(data, o + 28),
		buffer.readf32(data, o + 32)
end

--[[
	Bounding box of a set of chunks (body-relative): its centre (the band mesh's origin) and size, and the radius of
	its bounding sphere around that centre.
]]
function TerrainMath.bandBounds(chunks: { Chunk }): (Vec3d, Vector3, number)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, c in chunks do
		minX = math.min(minX, c.ox + c.minX)
		minY = math.min(minY, c.oy + c.minY)
		minZ = math.min(minZ, c.oz + c.minZ)
		maxX = math.max(maxX, c.ox + c.maxX)
		maxY = math.max(maxY, c.oy + c.maxY)
		maxZ = math.max(maxZ, c.oz + c.maxZ)
	end
	if minX > maxX then
		return Vec3d.zero(), Vector3.zero, 0
	end
	local centre = Vec3d.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	local size = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
	local radius = math.sqrt((maxX - minX) ^ 2 + (maxY - minY) ^ 2 + (maxZ - minZ) ^ 2) / 2
	return centre, size, radius
end

--============================================================================
-- Collision
--============================================================================

--[[
	The lattice triangles (the physics ground) of the cells within `radius` m of body-relative `pos`, on the face
	under it. Appends to `out` (cleared first) and returns it.
]]
function TerrainMath.collisionTriangles(config: Config, pos: Vec3d, radius: number, out: { Triangle }): { Triangle }
	table.clear(out)
	local bodyId = config.bodyId
	local face, fi, fj = SurfaceHeight.latticeCoords(bodyId, pos)
	local n = config.n
	local reach = math.ceil(radius / config.cellArc)
	local ci, cj = math.floor(fi), math.floor(fj)
	local r = config.radius
	for i = math.max(ci - reach, 0), math.min(ci + reach, n - 1) do
		for j = math.max(cj - reach, 0), math.min(cj + reach, n - 1) do
			local di, dj = (i + 0.5 - fi) * config.cellArc, (j + 0.5 - fj) * config.cellArc
			if di * di + dj * dj > (radius + config.cellArc) ^ 2 then
				continue
			end
			local ax, ay, az = groundPoint(bodyId, r, face, i, j)
			local bx, by, bz = groundPoint(bodyId, r, face, i + 1, j)
			local cx, cy, cz = groundPoint(bodyId, r, face, i + 1, j + 1)
			local dx, dy, dz = groundPoint(bodyId, r, face, i, j + 1)
			table.insert(out, { ax, ay, az, bx, by, bz, cx, cy, cz })
			table.insert(out, { ax, ay, az, cx, cy, cz, dx, dy, dz })
		end
	end
	return out
end

--[[
	Two WedgeParts (CFrame, Size each) that together fill triangle (a, b, c), `thickness` studs thick, with the
	triangle as their top face and their bulk below it (on the side opposite `up`). Returns nil for degenerate
	triangles.
]]
function TerrainMath.wedgePair(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	up: Vector3,
	thickness: number
): (CFrame?, Vector3?, CFrame?, Vector3?)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	-- make bc the longest edge (a is then opposite it and its foot on bc splits the triangle in two right triangles)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local normal = ac:Cross(ab)
	if normal.Magnitude < 1e-6 or bc.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end
	local right = normal.Unit
	local upAxis = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(upAxis))
	if height < 1e-4 then
		return nil, nil, nil, nil
	end
	-- the wedges straddle the triangle's plane; move them below it
	local shift = (if right:Dot(up) >= 0 then -right else right) * (thickness / 2)
	local size0 = Vector3.new(thickness, height, math.abs(ab:Dot(back)))
	local cf0 = CFrame.fromMatrix((a + b) / 2 + shift, right, upAxis, back)
	local size1 = Vector3.new(thickness, height, math.abs(ac:Dot(back)))
	local cf1 = CFrame.fromMatrix((a + c) / 2 + shift, -right, upAxis, -back)
	return cf0, size0, cf1, size1
end

return table.freeze(TerrainMath)
