--!strict
--!native
--[[
	SurfaceHeight
	The ground (spec 7.6 layer 3). CHANGED (Phase 8): heightmap terrain behind the same height() API.

	Each body's ground is a fixed triangle lattice on an equi-angular cube-sphere: every cube face is cut into N x N
	cells (N = latticeSize, a power of two times 8, ~23 m cells), each cell split into two triangles along its
	(i, j) -> (i + 1, j + 1) diagonal. A lattice node's height comes from Relief (noise and features: hills,
	mountains and a flat sea on Earth, maria and craters on the Mun, the launch-site plane at lat 0 / lon 0) and is
	cached. The ground is the piecewise-flat surface through the nodes: height() returns the signed distance of a
	position above the plane of the triangle under it and that triangle's up normal. The terrain renderer draws these
	exact triangles at its finest level of detail, so contact physics matches the visible ground.

	Faces: 1 +X, 2 -X, 3 +Y, 4 -Y, 5 +Z, 6 -Z (universe axes; planets do not rotate), each with axes (u, v); cell
	(i, j) spans angles a in [-pi/4 + i step, +step] along u and b along v (step = (pi/2) / N). Nodes on a cube edge
	are computed by both faces from the same direction (equal up to rounding), so the ground is continuous across
	faces.

	The launch site (Earth, lat 0 / lon 0, centre of face +X): Relief makes the ground exactly the plane x = R there
	(the base pocket's y = 0), and the pads and plot baseplates are raised platforms on it (BaseLayout), so the base
	stands where it always did.

	The tile API (tilesPerFace, tileOf, tileKey, tileCenter, tileRotation, tileExtent) is the coarse v1 lattice of
	~2 km tangent tiles, kept as a placement grid (SurfaceProps cuts it into prop cells).

	Pure module. Deterministic: server and clients compute the same heights.
]]

local BaseLayout = require(script.Parent.Parent.Config.BaseLayout)
local Bodies = require(script.Parent.Parent.Config.Bodies)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)
local Relief = require(script.Parent.Relief) -- CHANGED (Phase 8)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local TARGET_TILE_SIZE = GameConfig.TILE_SIZE -- m, tile edge length at a face centre
local SITE_CHECK_HEIGHT = 50 -- m; launch-site platforms are only looked up below this height above the plane
local SITE_CHECK_RADIUS = 2000 -- m; ... and this close to the site (the base pocket's surface point)
-- CHANGED (Phase 8): the heightmap lattice
local LATTICE_CHUNK = 8 -- the cell count per face edge is LATTICE_CHUNK * 2^k (renderer chunks are 8 x 8 cells)
local TARGET_CELL_SIZE = 23 -- m, lattice cell edge (Earth and Mun: 94.2 km / 4096 and 23.6 km / 1024)
local CACHE_MAX = 80000 -- cached node heights per body (~3 MB); the cache is cleared when it grows past this
local TRIANGLE_CACHE = 64 -- recently used ground triangles remembered per body (direct-mapped)
--============================================================================

export type TileId = { face: number, i: number, j: number }

-- CHANGED (Phase 8): one body's lattice
type Lattice = {
	bodyId: number,
	radius: number,
	n: number, -- cells per face edge
	step: number, -- rad per cell
	invStep: number,
	tan: { number }, -- tan(-pi/4 + i step), index i + 1, i = 0 .. n
	cache: { [number]: number }, -- node key -> height
	cached: number,
	stride: number, -- n + 1
	faceStride: number, -- (n + 1)^2
	minHeight: number,
	maxHeight: number,
	triangles: TriangleCache,
}

-- CHANGED (Phase 8): recently used ground triangles (a corner and the normal), by triangle key
type TriangleCache = {
	key: { number },
	p0x: { number },
	p0y: { number },
	p0z: { number },
	nx: { number },
	ny: { number },
	nz: { number },
}

local SurfaceHeight = {}

local QUARTER_PI = math.pi / 4

-- Face frames: normal n, and in-face axes u, v (all unit, universe axes).
local FACES: { { n: Vec3d, u: Vec3d, v: Vec3d } } = {
	{ n = Vec3d.new(1, 0, 0), u = Vec3d.new(0, 0, 1), v = Vec3d.new(0, 1, 0) },
	{ n = Vec3d.new(-1, 0, 0), u = Vec3d.new(0, 0, -1), v = Vec3d.new(0, 1, 0) },
	{ n = Vec3d.new(0, 1, 0), u = Vec3d.new(1, 0, 0), v = Vec3d.new(0, 0, 1) },
	{ n = Vec3d.new(0, -1, 0), u = Vec3d.new(1, 0, 0), v = Vec3d.new(0, 0, -1) },
	{ n = Vec3d.new(0, 0, 1), u = Vec3d.new(-1, 0, 0), v = Vec3d.new(0, 1, 0) },
	{ n = Vec3d.new(0, 0, -1), u = Vec3d.new(1, 0, 0), v = Vec3d.new(0, 1, 0) },
}

-- CHANGED (Phase 8): flat copies of the face frames for the hot path
local FNX, FNY, FNZ, FUX, FUY, FUZ, FVX, FVY, FVZ = {}, {}, {}, {}, {}, {}, {}, {}, {}
for index, f in FACES do
	FNX[index], FNY[index], FNZ[index] = f.n.x, f.n.y, f.n.z
	FUX[index], FUY[index], FUZ[index] = f.u.x, f.u.y, f.u.z
	FVX[index], FVY[index], FVZ[index] = f.v.x, f.v.y, f.v.z
end

local tilesPerFaceCache: { [number]: number } = {}

-- Tiles along each face edge (odd).
function SurfaceHeight.tilesPerFace(bodyId: number): number
	local cached = tilesPerFaceCache[bodyId]
	if cached then
		return cached
	end
	local radius = Bodies.get(bodyId).Radius
	local n = math.max(1, math.round(radius * (math.pi / 2) / TARGET_TILE_SIZE))
	if n % 2 == 0 then
		n += 1
	end
	tilesPerFaceCache[bodyId] = n
	return n
end

local function faceOfXYZ(x: number, y: number, z: number): number
	local ax, ay, az = math.abs(x), math.abs(y), math.abs(z)
	if ax >= ay and ax >= az then
		return if x >= 0 then 1 else 2
	elseif ay >= az then
		return if y >= 0 then 3 else 4
	end
	return if z >= 0 then 5 else 6
end

local function faceOf(d: Vec3d): number
	return faceOfXYZ(d.x, d.y, d.z)
end

-- The tile under a direction (or any position relative to the body centre).
function SurfaceHeight.tileOf(bodyId: number, d: Vec3d): TileId
	local n = SurfaceHeight.tilesPerFace(bodyId)
	local face = faceOf(d)
	local f = FACES[face]
	local major = Vec3d.dot(d, f.n)
	local a = math.atan(Vec3d.dot(d, f.u) / major)
	local b = math.atan(Vec3d.dot(d, f.v) / major)
	local step = (math.pi / 2) / n
	local i = math.clamp(math.floor((a + math.pi / 4) / step), 0, n - 1)
	local j = math.clamp(math.floor((b + math.pi / 4) / step), 0, n - 1)
	return { face = face, i = i, j = j }
end

-- A stable number for a tile (for caches / pools).
function SurfaceHeight.tileKey(tile: TileId): number
	return (tile.face * 4096 + tile.i) * 4096 + tile.j
end

local function directionAt(_bodyId: number, face: number, a: number, b: number): Vec3d
	local f = FACES[face]
	local ta, tb = math.tan(a), math.tan(b)
	return Vec3d.normalize(
		Vec3d.new(f.n.x + ta * f.u.x + tb * f.v.x, f.n.y + ta * f.u.y + tb * f.v.y, f.n.z + ta * f.u.z + tb * f.v.z)
	)
end

-- Unit direction from the body centre to the tile's centre (the tile's "up").
function SurfaceHeight.tileCenter(bodyId: number, tile: TileId): Vec3d
	local n = SurfaceHeight.tilesPerFace(bodyId)
	local step = (math.pi / 2) / n
	return directionAt(bodyId, tile.face, -math.pi / 4 + (tile.i + 0.5) * step, -math.pi / 4 + (tile.j + 0.5) * step)
end

--[[
	Tile orientation (rotation only): Y = the tile's up, X = the face's u axis projected onto the tile plane,
	Z = X x Y. Tile edges run along X and Z.
]]
function SurfaceHeight.tileRotation(bodyId: number, tile: TileId): CFrame
	local up = SurfaceHeight.tileCenter(bodyId, tile)
	local u = FACES[tile.face].u
	local x = Vec3d.normalize(Vec3d.sub(u, Vec3d.scale(up, Vec3d.dot(u, up))))
	local z = Vec3d.cross(x, up)
	return CFrame.fromMatrix(Vector3.zero, Vec3d.toVector3(x), Vec3d.toVector3(up), Vec3d.toVector3(z))
end

-- Edge lengths (m) of the tile along its X and Z axes, measured on its plane between opposite edge midpoints.
function SurfaceHeight.tileExtent(bodyId: number, tile: TileId): (number, number)
	local radius = Bodies.get(bodyId).Radius
	local n = SurfaceHeight.tilesPerFace(bodyId)
	local step = (math.pi / 2) / n
	local a0 = -math.pi / 4 + tile.i * step
	local b0 = -math.pi / 4 + tile.j * step
	local ac, bc = a0 + step / 2, b0 + step / 2
	local up = SurfaceHeight.tileCenter(bodyId, tile)
	local function planePoint(d: Vec3d): Vec3d
		-- where the ray along d meets the tile plane (radius along up)
		return Vec3d.scale(d, radius / Vec3d.dot(d, up))
	end
	local left = planePoint(directionAt(bodyId, tile.face, a0, bc))
	local right = planePoint(directionAt(bodyId, tile.face, a0 + step, bc))
	local bottom = planePoint(directionAt(bodyId, tile.face, ac, b0))
	local top = planePoint(directionAt(bodyId, tile.face, ac, b0 + step))
	return Vec3d.distance(left, right), Vec3d.distance(bottom, top)
end

--============================================================================
-- Heightmap lattice (CHANGED Phase 8)
--============================================================================
local lattices: { [number]: Lattice } = {}
local noLattice: { [number]: boolean } = {} -- bodies without a surface (CHANGED (Solar system): Sol, a star)

-- The lattice of a body with a surface (nil for the visual-only Sun).
local function latticeOf(bodyId: number): Lattice?
	local cached = lattices[bodyId]
	if cached then
		return cached
	elseif noLattice[bodyId] then
		return nil
	end
	local body = Bodies.get(bodyId)
	if not Bodies.hasSurface(bodyId) then -- CHANGED (Solar system): Sol has a radius but no ground
		noLattice[bodyId] = true
		return nil
	end
	local arc = body.Radius * math.pi / 2
	local levels = math.max(0, math.round(math.log(arc / (LATTICE_CHUNK * TARGET_CELL_SIZE), 2)))
	local n = LATTICE_CHUNK * 2 ^ levels
	local step = (math.pi / 2) / n
	local tan: { number } = table.create(n + 1, 0)
	for i = 0, n do
		tan[i + 1] = math.tan(-QUARTER_PI + i * step)
	end
	-- exact values where the angle is a multiple of pi/4 (edges and centre)
	tan[1], tan[n / 2 + 1], tan[n + 1] = -1, 0, 1
	local minHeight, maxHeight = Relief.bounds(bodyId)
	local lattice: Lattice = {
		bodyId = bodyId,
		radius = body.Radius,
		n = n,
		step = step,
		invStep = 1 / step,
		tan = tan,
		cache = {},
		cached = 0,
		stride = n + 1,
		faceStride = (n + 1) * (n + 1),
		minHeight = minHeight,
		maxHeight = maxHeight,
		triangles = {
			key = table.create(TRIANGLE_CACHE, -1),
			p0x = table.create(TRIANGLE_CACHE, 0),
			p0y = table.create(TRIANGLE_CACHE, 0),
			p0z = table.create(TRIANGLE_CACHE, 0),
			nx = table.create(TRIANGLE_CACHE, 0),
			ny = table.create(TRIANGLE_CACHE, 0),
			nz = table.create(TRIANGLE_CACHE, 0),
		},
	}
	lattices[bodyId] = lattice
	return lattice
end

-- tan of the lattice angle of index i (any integer: beyond 0 .. n reaches onto the neighbouring faces).
local function latticeTan(l: Lattice, i: number): number
	if i >= 0 and i <= l.n then
		return l.tan[i + 1]
	end
	return math.tan(-QUARTER_PI + i * l.step)
end

-- Unit direction of lattice node (face, i, j).
local function nodeDirection(l: Lattice, face: number, i: number, j: number): (number, number, number)
	local ta, tb = latticeTan(l, i), latticeTan(l, j)
	local x = FNX[face] + ta * FUX[face] + tb * FVX[face]
	local y = FNY[face] + ta * FUY[face] + tb * FVY[face]
	local z = FNZ[face] + ta * FUZ[face] + tb * FVZ[face]
	local inv = 1 / math.sqrt(x * x + y * y + z * z)
	return x * inv, y * inv, z * inv
end

-- Height (m) of lattice node (face, i, j); cached inside the face, computed directly beyond it.
local function nodeHeight(l: Lattice, face: number, i: number, j: number): number
	local n = l.n
	if i < 0 or i > n or j < 0 or j > n then
		local x, y, z = nodeDirection(l, face, i, j)
		return Relief.height(l.bodyId, x, y, z)
	end
	local key = (face - 1) * l.faceStride + i * l.stride + j
	local cache = l.cache
	local hit = cache[key]
	if hit then
		return hit
	end
	local x, y, z = nodeDirection(l, face, i, j)
	local h = Relief.height(l.bodyId, x, y, z)
	if l.cached >= CACHE_MAX then
		table.clear(cache)
		l.cached = 0
	end
	cache[key] = h
	l.cached += 1
	return h
end

-- Body-relative position (m) of lattice node (face, i, j) on the ground.
local function nodePoint(l: Lattice, face: number, i: number, j: number): (number, number, number)
	local x, y, z = nodeDirection(l, face, i, j)
	local r = l.radius + nodeHeight(l, face, i, j)
	return x * r, y * r, z * r
end

--[[
	The ground triangle under body-relative position (x, y, z): one of its corners (body-relative, m) and its unit up
	normal. Shared by height() and groundPoint(). The last TRIANGLE_CACHE triangles used are remembered (hull points
	of a landed craft keep hitting the same few).
]]
local function triangleUnder(
	l: Lattice,
	x: number,
	y: number,
	z: number
): (number, number, number, number, number, number)
	local face = faceOfXYZ(x, y, z)
	local major = x * FNX[face] + y * FNY[face] + z * FNZ[face]
	local a = math.atan((x * FUX[face] + y * FUY[face] + z * FUZ[face]) / major)
	local b = math.atan((x * FVX[face] + y * FVY[face] + z * FVZ[face]) / major)
	local n = l.n
	local gx = (a + QUARTER_PI) * l.invStep
	local gy = (b + QUARTER_PI) * l.invStep
	local i = math.floor(gx)
	local j = math.floor(gy)
	if i < 0 then
		i = 0
	elseif i > n - 1 then
		i = n - 1
	end
	if j < 0 then
		j = 0
	elseif j > n - 1 then
		j = n - 1
	end
	local upper = gx - i >= gy - j
	local key = ((face - 1) * l.faceStride + i * l.stride + j) * 2 + (if upper then 1 else 0)
	local slot = key % TRIANGLE_CACHE + 1
	local tri = l.triangles
	if tri.key[slot] == key then
		return tri.p0x[slot], tri.p0y[slot], tri.p0z[slot], tri.nx[slot], tri.ny[slot], tri.nz[slot]
	end
	local p0x, p0y, p0z = nodePoint(l, face, i, j)
	local p1x, p1y, p1z, p2x, p2y, p2z
	if upper then
		p1x, p1y, p1z = nodePoint(l, face, i + 1, j)
		p2x, p2y, p2z = nodePoint(l, face, i + 1, j + 1)
	else
		p1x, p1y, p1z = nodePoint(l, face, i + 1, j + 1)
		p2x, p2y, p2z = nodePoint(l, face, i, j + 1)
	end
	local e1x, e1y, e1z = p1x - p0x, p1y - p0y, p1z - p0z
	local e2x, e2y, e2z = p2x - p0x, p2y - p0y, p2z - p0z
	local nx = e1y * e2z - e1z * e2y
	local ny = e1z * e2x - e1x * e2z
	local nz = e1x * e2y - e1y * e2x
	local inv = 1 / math.sqrt(nx * nx + ny * ny + nz * nz)
	if nx * p0x + ny * p0y + nz * p0z < 0 then
		inv = -inv
	end
	nx, ny, nz = nx * inv, ny * inv, nz * inv
	tri.key[slot] = key
	tri.p0x[slot], tri.p0y[slot], tri.p0z[slot] = p0x, p0y, p0z
	tri.nx[slot], tri.ny[slot], tri.nz[slot] = nx, ny, nz
	return p0x, p0y, p0z, nx, ny, nz
end

-- CHANGED (Phase 2a feedback): the launch site (lat 0 / lon 0 on Earth, centre of face +X) has raised pads and
-- plot baseplates that rockets stand on. Base-pocket axes there: X = east = universe +Z, Y = up = universe +X,
-- Z = north = universe +Y
-- (Frames.surfaceRotation at lat 0 / lon 0); the ground there is the plane x = R, the base pocket's y = 0.
local SITE_RADIUS = Bodies.get(Bodies.HOMEWORLD).Radius

local function sitePlatform(x: number, y: number, z: number): number
	local dx = x - SITE_RADIUS
	if dx > SITE_CHECK_HEIGHT or math.abs(y) > SITE_CHECK_RADIUS or math.abs(z) > SITE_CHECK_RADIUS then
		return 0
	end
	return BaseLayout.platformHeight(z, y)
end

--[[
	Height of a body-relative position above the ground under it (negative = below ground), and the ground's
	up normal there. CHANGED (Phase 8): the ground is the heightmap lattice (the triangle under the position).
]]
function SurfaceHeight.height(bodyId: number, pos: Vec3d): (number, Vec3d)
	local l = latticeOf(bodyId)
	local x, y, z = pos.x, pos.y, pos.z
	if l == nil then
		local r = math.sqrt(x * x + y * y + z * z)
		local radius = Bodies.get(bodyId).Radius
		if r <= 0 then
			return -radius, Vec3d.new(0, 1, 0)
		end
		return r - radius, Vec3d.new(x / r, y / r, z / r)
	end
	local p0x, p0y, p0z, nx, ny, nz = triangleUnder(l, x, y, z)
	local h = (x - p0x) * nx + (y - p0y) * ny + (z - p0z) * nz
	if bodyId == Bodies.HOMEWORLD and x > 0 then
		h -= sitePlatform(x, y, z)
	end
	return h, Vec3d.new(nx, ny, nz)
end

--[[
	CHANGED (Phase 8): where the ray from the body centre along `dir` meets the ground (body-relative, m), and the
	ground's up normal there. Platforms are not included.
]]
function SurfaceHeight.groundPoint(bodyId: number, dir: Vec3d): (Vec3d, Vec3d)
	local l = latticeOf(bodyId)
	local len = Vec3d.length(dir)
	local dx, dy, dz = dir.x / len, dir.y / len, dir.z / len
	if l == nil then
		local radius = Bodies.get(bodyId).Radius
		return Vec3d.new(dx * radius, dy * radius, dz * radius), Vec3d.new(dx, dy, dz)
	end
	local p0x, p0y, p0z, nx, ny, nz = triangleUnder(l, dx, dy, dz)
	local t = (p0x * nx + p0y * ny + p0z * nz) / (dx * nx + dy * ny + dz * nz)
	return Vec3d.new(dx * t, dy * t, dz * t), Vec3d.new(nx, ny, nz)
end

-- CHANGED (Phase 8): cells per face edge of a body's heightmap lattice (0 for bodies without a surface).
function SurfaceHeight.latticeSize(bodyId: number): number
	local l = latticeOf(bodyId)
	return if l then l.n else 0
end

-- CHANGED (Phase 8): cells per face edge are LATTICE_CHUNK * 2^k.
SurfaceHeight.LATTICE_CHUNK = LATTICE_CHUNK

-- CHANGED (Phase 8): height (m) of lattice node (face, i, j); i, j outside 0 .. latticeSize reach onto the
-- neighbouring faces (evaluated directly, not cached).
function SurfaceHeight.nodeHeight(bodyId: number, face: number, i: number, j: number): number
	local l = latticeOf(bodyId)
	if l == nil then
		return 0
	end
	return nodeHeight(l, face, i, j)
end

-- CHANGED (Phase 8): unit direction of lattice node (face, i, j).
function SurfaceHeight.nodeDirection(bodyId: number, face: number, i: number, j: number): (number, number, number)
	local l = latticeOf(bodyId)
	if l == nil then
		return FNX[face], FNY[face], FNZ[face]
	end
	return nodeDirection(l, face, i, j)
end

-- CHANGED (Phase 8): lattice coordinates of a body-relative position: face and fractional (i, j) (cell = floor).
function SurfaceHeight.latticeCoords(bodyId: number, pos: Vec3d): (number, number, number)
	local l = latticeOf(bodyId)
	local face = faceOf(pos)
	if l == nil then
		return face, 0, 0
	end
	local major = Vec3d.dot(pos, FACES[face].n)
	local a = math.atan(Vec3d.dot(pos, FACES[face].u) / major)
	local b = math.atan(Vec3d.dot(pos, FACES[face].v) / major)
	return face, (a + QUARTER_PI) * l.invStep, (b + QUARTER_PI) * l.invStep
end

-- CHANGED (Phase 8): lowest and highest ground (m above the body radius), platforms excluded.
function SurfaceHeight.bounds(bodyId: number): (number, number)
	local l = latticeOf(bodyId)
	if l == nil then
		return 0, 0
	end
	return l.minHeight, l.maxHeight
end

-- CHANGED (Phase 8): the face frames (unit normal n and in-face axes u, v), for the terrain renderer.
function SurfaceHeight.faceFrame(face: number): (Vec3d, Vec3d, Vec3d)
	local f = FACES[face]
	return f.n, f.u, f.v
end

-- CHANGED (Phase 8): node heights cached so far (debug / tests).
function SurfaceHeight.cacheSize(bodyId: number): number
	local l = latticeOf(bodyId)
	return if l then l.cached else 0
end

return table.freeze(SurfaceHeight)
