--!strict
--[[
	SurfaceHeight
	The ground, v1 (spec 7.6 layer 3): each body's surface is a fixed lattice of flat tiles on an equi-angular
	cube-sphere, each tile tangent to the sphere at its own centre. The height of a point is its signed distance
	above the plane of the tile under it, so contact physics matches the visible ground exactly.
	Phase 8 replaces this with heightmap terrain behind the same height() API.

	Faces: 1 +X, 2 -X, 3 +Y, 4 -Y, 5 +Z, 6 -Z (universe axes; planets do not rotate). Each face is split into
	N x N tiles with N odd, so a tile is centred on each face centre (the launch site at lat 0 / lon 0 is the
	centre of face +X and sits on one flat tile).

	Pure module.
]]

local BaseLayout = require(script.Parent.Parent.Config.BaseLayout)
local Bodies = require(script.Parent.Parent.Config.Bodies)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local TARGET_TILE_SIZE = GameConfig.TILE_SIZE -- m, tile edge length at a face centre
local SITE_CHECK_HEIGHT = 50 -- m; launch-site platforms are only looked up below this height above the plane
local SITE_CHECK_RADIUS = 2000 -- m; ... and this close to the site (the base pocket's surface point)
--============================================================================

export type TileId = { face: number, i: number, j: number }

local SurfaceHeight = {}

-- Face frames: normal n, and in-face axes u, v (all unit, universe axes).
local FACES: { { n: Vec3d, u: Vec3d, v: Vec3d } } = {
	{ n = Vec3d.new(1, 0, 0), u = Vec3d.new(0, 0, 1), v = Vec3d.new(0, 1, 0) },
	{ n = Vec3d.new(-1, 0, 0), u = Vec3d.new(0, 0, -1), v = Vec3d.new(0, 1, 0) },
	{ n = Vec3d.new(0, 1, 0), u = Vec3d.new(1, 0, 0), v = Vec3d.new(0, 0, 1) },
	{ n = Vec3d.new(0, -1, 0), u = Vec3d.new(1, 0, 0), v = Vec3d.new(0, 0, -1) },
	{ n = Vec3d.new(0, 0, 1), u = Vec3d.new(-1, 0, 0), v = Vec3d.new(0, 1, 0) },
	{ n = Vec3d.new(0, 0, -1), u = Vec3d.new(1, 0, 0), v = Vec3d.new(0, 1, 0) },
}

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

local function faceOf(d: Vec3d): number
	local ax, ay, az = math.abs(d.x), math.abs(d.y), math.abs(d.z)
	if ax >= ay and ax >= az then
		return if d.x >= 0 then 1 else 2
	elseif ay >= az then
		return if d.y >= 0 then 3 else 4
	end
	return if d.z >= 0 then 5 else 6
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

local function directionAt(bodyId: number, face: number, a: number, b: number): Vec3d
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

-- CHANGED (Phase 2a feedback): the launch site (lat 0 / lon 0 on Kablamo, centre of face +X) has raised pads and
-- plot baseplates that rockets stand on. Base-pocket axes there: X = east = universe +Z, Y = up = universe +X,
-- Z = north = universe +Y
-- (Frames.surfaceRotation at lat 0 / lon 0); the face-centre tile's plane is the base pocket's y = 0.
local SITE_RADIUS = Bodies.get(Bodies.HOMEWORLD).Radius

local function sitePlatform(pos: Vec3d): number
	local dx = pos.x - SITE_RADIUS
	if dx > SITE_CHECK_HEIGHT or math.abs(pos.y) > SITE_CHECK_RADIUS or math.abs(pos.z) > SITE_CHECK_RADIUS then
		return 0
	end
	return BaseLayout.platformHeight(pos.z, pos.y)
end

--[[
	Height of a body-relative position above the ground under it (negative = below ground), and the ground's
	up normal there.
]]
function SurfaceHeight.height(bodyId: number, pos: Vec3d): (number, Vec3d)
	local tile = SurfaceHeight.tileOf(bodyId, pos)
	local up = SurfaceHeight.tileCenter(bodyId, tile)
	local h = Vec3d.dot(pos, up) - Bodies.get(bodyId).Radius
	if bodyId == Bodies.HOMEWORLD and up.x > 0.9999999 then
		h -= sitePlatform(pos)
	end
	return h, up
end

return table.freeze(SurfaceHeight)
