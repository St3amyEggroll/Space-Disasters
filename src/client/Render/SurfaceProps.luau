--!strict
--[[
	SurfaceProps
	Cosmetic ground clutter near the camera while the Surface layer draws (surface mode): stylised round trees,
	pines, snowy pines, cacti, bushes and rocks on Earth; boulders and small crater rims on Mun.

	Placement is deterministic: each SurfaceHeight tile is cut into CELL_SIZE cells in its own plane coordinates
	(origin at the tile centre, axes = the tile's X / Z), grouped in CHUNK_CELLS x CHUNK_CELLS chunks. A cell
	holds at most one prop, decided by hashing (body, tile, cell) and the Biome kind under it, so the same props
	appear on every visit. Props stand ON the tile plane (the physical ground), so they touch it exactly.
	CHANGED (Phase 8): the ground is now the heightmap terrain: each prop is moved along the radial line from its cell
	point down (or up) to SurfaceHeight's ground, stands upright (radial up) and sinks a little more on slopes; no
	trees on ground steeper than MAX_TREE_SLOPE_DEG (rocks still). Radius, part cap and density follow the Quality
	tier through setDetail (Surface).
	CHANGED (Physics feel): trees and rocks now grow right up to the launch site, as a speed reference for a
	climbing rocket: only a square of SITE_CLEAR_HALF_EXTENT (the site's ground plate plus SITE_CLEAR_MARGIN) in the
	site's tangent plane is kept clear (was an 800 m sphere), so nothing stands on the plate, pads, plots or roads,
	which all lie on the plate (BaseLayout). PROP_RADIUS and MAX_PROP_PARTS grew to match.

	Chunks are generated lazily (nearest first, GEN_BUDGET_S per frame) and cached. Props are drawn from pooled
	parts (MAX_PROP_PARTS hard cap), nearest chunks first, moved with one BulkMoveTo whenever the frame or the
	assignment changes. All parts are Anchored, CanCollide / CanQuery / CanTouch false: purely cosmetic.

	CHANGED (Night review): mobile / quality pass.
	  * The shadow radius follows the Quality tier too (setDetail's shadowRadius: Low 0 = no prop shadows).
	  * In a moving flight pocket (the frame's reference moves, so every prop part is re-posed every frame) the props
	    are drawn within the tier's smaller moving radius / part cap (setDetail's moving*), until the frame has been
	    still for MOVING_HOLD_S.

	CHANGED (Night review): terrain review: a prop disc reaching past the true-scale terrain stood props on scaled
	ground (drawn nearer than it is, so the props floated in front of it). A ground filter (setGroundFilter; Surface:
	TerrainMesh.isTrueScaleAt) now drops every chunk not wholly over true-scale ground, re-checked whenever the
	terrain changes (update's version).

	API (driven by Surface):
		SurfaceProps.init(parent)
		SurfaceProps.update(ctx, surfaceMode, version?)     CHANGED (Night review): version of the filter's ground
		SurfaceProps.setGroundFilter(filter?)               CHANGED (Night review)
		SurfaceProps.setDetail(radius, maxParts, density, shadowRadius?, movingRadius?, movingMaxParts?)
		                                                    CHANGED (Phase 8): Quality tier
		                                                    CHANGED (Night review): + shadows, moving-pocket detail
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout) -- CHANGED (Physics feel)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local RenderContext = require(script.Parent.RenderContext)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d
type Frame = Frames.Frame
type TileId = SurfaceHeight.TileId

--============================================================================
-- Tunables
--============================================================================
local PROP_RADIUS = 1000 -- m (= studs), props farther than this from the camera are not drawn -- CHANGED (Physics feel): was 750
-- CHANGED (Phase 8): PROP_RADIUS and MAX_PROP_PARTS are the defaults; setDetail (Quality tier) overrides them
local CELL_SIZE = 28 -- m, one prop at most per cell
local CHUNK_CELLS = 8 -- cells per chunk side (224 m chunks)
local MAX_PROP_PARTS = 1000 -- hard cap on pooled parts in use -- CHANGED (Physics feel): was 600
local SHADOW_RADIUS = 220 -- m, props nearer than this cast shadows (CHANGED (Night review): default; setDetail)
local MOVING_HOLD_S = 2 -- CHANGED (Night review): s the frame must stay still before the full detail returns
local REFRESH_DISTANCE = 35 -- m of camera movement before the prop set is re-chosen
local GEN_BUDGET_S = 0.001 -- chunk generation work per frame
local CHUNK_CACHE_MAX = 400 -- cached chunks before far ones are dropped -- CHANGED (Physics feel): was 300 (bigger radius)
-- CHANGED (Physics feel): square clearing just outside the site plate (was an 800 m sphere)
local SITE_CLEAR_MARGIN = 20 -- m beyond the plate edge (more than the widest prop's reach from its centre)
local SITE_CLEAR_HALF_EXTENT = BaseLayout.SITE_HALF_EXTENT + SITE_CLEAR_MARGIN -- m, in the site's tangent plane
local SITE_CLEAR_DEPTH = 200 -- m, only points this close to the site's plane count (not the far side of Earth)
local TILE_EDGE_MARGIN = 8 -- m, no props this close to a tile edge (neighbouring planes diverge there)
local PROP_SINK = 0.3 -- studs props are sunk into the ground
local SCALE_MIN = 0.75
local SCALE_MAX = 1.35
local TINT_AMOUNT = 0.12 -- +/- colour brightness variation of tinted parts
local TILE_SEARCH_STEPS = 2 -- tiles are found on a (2n + 1)^2 direction grid over the prop disc
local HASH_SALT = 9173
local POOL_PREWARM = 120 -- parts created at init
-- CHANGED (Phase 8): props on the heightmap terrain
local MAX_TREE_SLOPE_DEG = 32 -- no trees, cacti or bushes on steeper ground
local MAX_ROCK_SLOPE_DEG = 50 -- no props at all on steeper ground
local SLOPE_SINK = 1.6 -- studs of extra sink per unit of slope tangent (the low side of the trunk stays buried)

local SITE_LATITUDE = 0 -- rad, the base pocket's surface point (PocketService)
local SITE_LONGITUDE = 0
local BULK_MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged

local TRUNK = Color3.fromRGB(107, 74, 46)
local LEAF = Color3.fromRGB(70, 140, 52)
local LEAF_LIGHT = Color3.fromRGB(104, 172, 70)
local PINE = Color3.fromRGB(34, 98, 58)
local SNOW_PINE = Color3.fromRGB(52, 92, 78)
local SNOW = Color3.fromRGB(236, 243, 252)
local CACTUS = Color3.fromRGB(78, 140, 72)
local STONE = Color3.fromRGB(118, 112, 104)
local MOON_STONE = Color3.fromRGB(132, 128, 122)
--============================================================================

type Shape = "Block" | "Ball" | "Cylinder"

type PartSpec = {
	shape: Shape,
	size: Vector3, -- at scale 1 (studs)
	offset: CFrame, -- from the prop's ground point, at scale 1
	color: Color3,
	material: Enum.Material,
	tint: boolean, -- gets the prop's colour variation
}

type Prop = {
	id: number,
	kind: Biome.PropKind,
	pos: Vec3d, -- ground point relative to the body centre (doubles)
	rot: CFrame, -- universe rotation (radial up, then yaw) -- CHANGED (Phase 8): was the tile's axes
	sink: number, -- CHANGED (Phase 8): extra studs sunk into sloped ground
	scale: number,
	tint: number, -- brightness factor
	partCount: number,
}

type Chunk = {
	key: number,
	props: { Prop },
	stamp: number,
}

type TileInfo = {
	key: number,
	tile: TileId,
	centre: Vec3d, -- tile plane centre (m, body-relative)
	up: Vec3d,
	ax: Vec3d, -- tile X axis (universe)
	az: Vec3d, -- tile Z axis (universe)
	rot: CFrame,
	ex: number,
	ez: number,
}

type PendingChunk = {
	key: number,
	info: TileInfo,
	ci: number,
	cj: number,
	dist: number,
}

type VisibleChunk = { chunk: Chunk, dist: number }

type Assigned = {
	prop: Prop,
	parts: { Part },
	offsets: { CFrame }, -- scaled part offsets from the prop root
}

local SurfaceProps = {}

--============================================================================
-- Prop shapes
--============================================================================
local Z90 = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis (X) -> vertical

local function spec(
	shape: Shape,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	material: Enum.Material,
	tint: boolean
): PartSpec
	return { shape = shape, size = size, offset = offset, color = color, material = material, tint = tint }
end

local function pineSpecs(tier: Color3, top: Color3, topMaterial: Enum.Material): { PartSpec }
	return {
		spec("Cylinder", Vector3.new(3, 1.1, 1.1), CFrame.new(0, 1.5, 0) * Z90, TRUNK, Enum.Material.Wood, false),
		spec("Block", Vector3.new(6, 2.6, 6), CFrame.new(0, 3.8, 0), tier, Enum.Material.Grass, true),
		spec(
			"Block",
			Vector3.new(4.4, 2.4, 4.4),
			CFrame.new(0, 6, 0) * CFrame.Angles(0, math.pi / 4, 0),
			tier,
			Enum.Material.Grass,
			true
		),
		spec("Block", Vector3.new(2.8, 2.2, 2.8), CFrame.new(0, 8, 0), top, topMaterial, true),
	}
end

local function craterRimSpecs(): { PartSpec }
	local specs: { PartSpec } = {}
	for k = 0, 7 do
		table.insert(
			specs,
			spec(
				"Block",
				Vector3.new(3.4, 1.2, 1.8),
				CFrame.Angles(0, k * math.pi / 4, 0) * CFrame.new(0, 0.3, -7) * CFrame.Angles(0.35, 0, 0),
				MOON_STONE,
				Enum.Material.Slate,
				true
			)
		)
	end
	return specs
end

local PROP_SPECS: { [string]: { PartSpec } } = {
	RoundTree = {
		spec("Cylinder", Vector3.new(6, 1.4, 1.4), CFrame.new(0, 3, 0) * Z90, TRUNK, Enum.Material.Wood, false),
		spec("Ball", Vector3.one * 8, CFrame.new(0, 8, 0), LEAF, Enum.Material.Grass, true),
		spec("Ball", Vector3.one * 5.5, CFrame.new(1.8, 10.2, 0.8), LEAF_LIGHT, Enum.Material.Grass, true),
	},
	PineTree = pineSpecs(PINE, PINE, Enum.Material.Grass),
	SnowPine = pineSpecs(SNOW_PINE, SNOW, Enum.Material.Snow),
	Cactus = {
		spec(
			"Cylinder",
			Vector3.new(6, 1.4, 1.4),
			CFrame.new(0, 3, 0) * Z90,
			CACTUS,
			Enum.Material.SmoothPlastic,
			true
		),
		spec(
			"Cylinder",
			Vector3.new(1.3, 0.8, 0.8),
			CFrame.new(1.05, 2.9, 0),
			CACTUS,
			Enum.Material.SmoothPlastic,
			true
		),
		spec(
			"Cylinder",
			Vector3.new(2.2, 0.9, 0.9),
			CFrame.new(1.6, 3.8, 0) * Z90,
			CACTUS,
			Enum.Material.SmoothPlastic,
			true
		),
		spec(
			"Cylinder",
			Vector3.new(1.3, 0.8, 0.8),
			CFrame.new(-1.05, 2.4, 0),
			CACTUS,
			Enum.Material.SmoothPlastic,
			true
		),
		spec(
			"Cylinder",
			Vector3.new(1.8, 0.9, 0.9),
			CFrame.new(-1.6, 3.1, 0) * Z90,
			CACTUS,
			Enum.Material.SmoothPlastic,
			true
		),
	},
	Rock = {
		spec(
			"Block",
			Vector3.new(3, 2, 2.5),
			CFrame.new(0, 0.6, 0) * CFrame.Angles(0.3, 0.7, 0.2),
			STONE,
			Enum.Material.Slate,
			true
		),
		spec(
			"Block",
			Vector3.new(1.4, 1, 1.2),
			CFrame.new(1.9, 0.3, 0.7) * CFrame.Angles(0.5, 0.2, 0.4),
			STONE,
			Enum.Material.Slate,
			true
		),
	},
	Bush = {
		spec("Ball", Vector3.one * 3, CFrame.new(0, 0.8, 0), LEAF, Enum.Material.Grass, true),
	},
	Boulder = {
		spec("Ball", Vector3.one * 4.5, CFrame.new(0, 1.2, 0), MOON_STONE, Enum.Material.Slate, true),
		spec("Ball", Vector3.one * 2, CFrame.new(2.6, 0.4, 0.8), MOON_STONE, Enum.Material.Slate, true),
	},
	CraterRim = craterRimSpecs(),
}

--============================================================================
-- Pure helpers
--============================================================================

local CHUNK_SIZE = CELL_SIZE * CHUNK_CELLS
local COS_TREE_SLOPE = math.cos(math.rad(MAX_TREE_SLOPE_DEG)) -- CHANGED (Phase 8)
local COS_ROCK_SLOPE = math.cos(math.rad(MAX_ROCK_SLOPE_DEG))
local ROCKY: { [string]: boolean } = { Rock = true, Boulder = true, CraterRim = true }
local CELL_AREA_HA = CELL_SIZE * CELL_SIZE / 10000
local MAX_CELL_CHANCE = Biome.propDensity("Forest") * CELL_AREA_HA -- densest biome: skip the Biome sample above it

local SITE_UP = Frames.surfaceUp(SITE_LATITUDE, SITE_LONGITUDE)
local SITE_POS = Vec3d.scale(SITE_UP, Bodies.get(Bodies.HOMEWORLD).Radius)
-- CHANGED (Physics feel): the site's east / north axes (= base-pocket X / Z) for the square clearing
local SITE_ROT = Frames.surfaceRotation(SITE_UP)
local SITE_EAST = Vec3d.fromVector3(SITE_ROT.XVector)
local SITE_NORTH = Vec3d.fromVector3(SITE_ROT.ZVector)

-- CHANGED (Physics feel): is a body-relative ground point on Earth inside the launch site's square clearing?
local function inSiteClearing(px: number, py: number, pz: number): boolean
	local dx, dy, dz = px - SITE_POS.x, py - SITE_POS.y, pz - SITE_POS.z
	local h = dx * SITE_UP.x + dy * SITE_UP.y + dz * SITE_UP.z
	if math.abs(h) > SITE_CLEAR_DEPTH then
		return false
	end
	local e = dx * SITE_EAST.x + dy * SITE_EAST.y + dz * SITE_EAST.z
	local n = dx * SITE_NORTH.x + dy * SITE_NORTH.y + dz * SITE_NORTH.z
	return math.abs(e) <= SITE_CLEAR_HALF_EXTENT and math.abs(n) <= SITE_CLEAR_HALF_EXTENT
end

local function chunkKey(bodyId: number, tileKey: number, ci: number, cj: number): number
	return ((bodyId * 134217728 + tileKey) * 64 + (ci + 32)) * 64 + (cj + 32)
end

local function tileInfo(bodyId: number, tile: TileId): TileInfo
	local radius = Bodies.get(bodyId).Radius
	local up = SurfaceHeight.tileCenter(bodyId, tile)
	local rot = SurfaceHeight.tileRotation(bodyId, tile)
	local ex, ez = SurfaceHeight.tileExtent(bodyId, tile)
	return {
		key = SurfaceHeight.tileKey(tile),
		tile = tile,
		centre = Vec3d.scale(up, radius),
		up = up,
		ax = Vec3d.normalize(Vec3d.fromVector3(rot.XVector)),
		az = Vec3d.normalize(Vec3d.fromVector3(rot.ZVector)),
		rot = rot,
		ex = ex,
		ez = ez,
	}
end

-- CHANGED (Phase 8): share of Biome's prop density that is placed, draw radius and part cap (Quality tier, setDetail)
local densityScale = 1
-- CHANGED (Night review): propRadius / maxPropParts are the values in use: the tier's detail* values, or its moving*
-- values while the pocket frame moves
local propRadius = PROP_RADIUS
local maxPropParts = MAX_PROP_PARTS
local detailRadius = PROP_RADIUS
local detailMaxParts = MAX_PROP_PARTS
local movingRadius = PROP_RADIUS
local movingMaxParts = MAX_PROP_PARTS
local shadowRadius = SHADOW_RADIUS
local movingTimer = 0 -- s of moving-frame detail left
local watchedPocket = -1 -- the pocket / frame epoch / reference the moving test last saw
local watchedEpoch = -1
local watchedRefX, watchedRefY, watchedRefZ = 0, 0, 0
local watchedRot: CFrame = CFrame.identity

-- Deterministic props of one chunk (cells ci * CHUNK_CELLS .. + CHUNK_CELLS - 1 along X, same for cj along Z).
local function generateChunk(bodyId: number, info: TileInfo, ci: number, cj: number): { Prop }
	local props: { Prop } = {}
	local halfX, halfZ = info.ex / 2 - TILE_EDGE_MARGIN, info.ez / 2 - TILE_EDGE_MARGIN
	local salt = HASH_SALT + bodyId * 7
	local c, ax, az = info.centre, info.ax, info.az
	local baseKey = chunkKey(bodyId, info.key, ci, cj) * 64
	for a = 0, CHUNK_CELLS - 1 do
		local cellX = ci * CHUNK_CELLS + a
		for b = 0, CHUNK_CELLS - 1 do
			local cellZ = cj * CHUNK_CELLS + b
			-- CHANGED (Phase 8): the density scale thins every biome alike (same props stay, deterministic)
			local presence = Biome.hash01(info.key, cellX, cellZ, salt) / densityScale
			if presence >= MAX_CELL_CHANCE then
				continue
			end
			local x = (cellX + 0.15 + 0.7 * Biome.hash01(info.key, cellX, cellZ, salt + 1)) * CELL_SIZE
			local z = (cellZ + 0.15 + 0.7 * Biome.hash01(info.key, cellX, cellZ, salt + 2)) * CELL_SIZE
			if math.abs(x) > halfX or math.abs(z) > halfZ then
				continue
			end
			local px, py, pz = c.x + x * ax.x + z * az.x, c.y + x * ax.y + z * az.y, c.z + x * ax.z + z * az.z
			if bodyId == Bodies.HOMEWORLD and inSiteClearing(px, py, pz) then -- CHANGED (Physics feel)
				continue
			end
			local len = math.sqrt(px * px + py * py + pz * pz)
			local _, _, _, kind = Biome.sample(bodyId, px / len, py / len, pz / len)
			if presence >= Biome.propDensity(kind) * CELL_AREA_HA then
				continue
			end
			local propKind = Biome.propKind(kind, Biome.hash01(info.key, cellX, cellZ, salt + 3))
			if propKind == nil then
				continue
			end
			-- CHANGED (Phase 8): stand on the heightmap ground, upright, not on steep slopes
			local ground, normal = SurfaceHeight.groundPoint(bodyId, Vec3d.new(px, py, pz))
			local glen = Vec3d.length(ground)
			local upX, upY, upZ = ground.x / glen, ground.y / glen, ground.z / glen
			local cosSlope = normal.x * upX + normal.y * upY + normal.z * upZ
			if cosSlope < COS_ROCK_SLOPE or (cosSlope < COS_TREE_SLOPE and not ROCKY[propKind]) then
				continue
			end
			local tanSlope = math.sqrt(math.max(1 - cosSlope * cosSlope, 0)) / math.max(cosSlope, 1e-3)
			local up = Vector3.new(upX, upY, upZ)
			local tileX = info.rot.XVector
			local xAxis = (tileX - up * tileX:Dot(up)).Unit
			local upright = CFrame.fromMatrix(Vector3.zero, xAxis, up, xAxis:Cross(up))
			local yaw = Biome.hash01(info.key, cellX, cellZ, salt + 4) * 2 * math.pi
			local scaleRoll = Biome.hash01(info.key, cellX, cellZ, salt + 5)
			local tintRoll = Biome.hash01(info.key, cellX, cellZ, salt + 6)
			table.insert(props, {
				id = baseKey + a * CHUNK_CELLS + b,
				kind = propKind :: Biome.PropKind,
				pos = ground,
				rot = upright * CFrame.Angles(0, yaw, 0),
				sink = SLOPE_SINK * tanSlope * (SCALE_MIN + (SCALE_MAX - SCALE_MIN) * scaleRoll),
				scale = SCALE_MIN + (SCALE_MAX - SCALE_MIN) * scaleRoll,
				tint = 1 + TINT_AMOUNT * (tintRoll * 2 - 1),
				partCount = #PROP_SPECS[propKind],
			})
		end
	end
	return props
end

-- abs(bodyId) - abs(frame reference body) at UT, nil when they are the same body.
local function bodyOffsetFor(bodyId: number, frame: Frame, ut: number): Vec3d?
	if bodyId == frame.refBodyId then
		return nil
	end
	return Universe.bodyOffset(bodyId, frame.refBodyId, ut)
end

local function tintColor(color: Color3, factor: number): Color3
	return Color3.new(
		math.clamp(color.R * factor, 0, 1),
		math.clamp(color.G * factor, 0, 1),
		math.clamp(color.B * factor, 0, 1)
	)
end

--============================================================================
-- State
--============================================================================
local root: Folder? = nil
local propsFolder: Folder? = nil
local pools: { [string]: { Part } } = { Block = {}, Ball = {}, Cylinder = {} }
local partsInUse = 0

local chunks: { [number]: Chunk } = {}
local chunkCount = 0
local stampCounter = 0
local tileInfos: { [number]: TileInfo } = {} -- by body-qualified tile key
local pending: { PendingChunk } = {}
local visibleChunks: { VisibleChunk } = {}
local assigned: { [number]: Assigned } = {}

local currentBodyId: number? = nil
local lastRefreshPos: Vec3d = Vec3d.new(math.huge, 0, 0)
local needsRefresh = true
-- CHANGED (Night review): which chunks stand on true-scale ground (setGroundFilter), and the ground's version
local groundFilter: ((pos: Vec3d, margin: number) -> boolean)? = nil
local groundVersion: number? = nil

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local moveDirty = true
local lastRefX, lastRefY, lastRefZ = 0, 0, 0
local lastOffX, lastOffY, lastOffZ = 0, 0, 0
local lastSlot: Vector3 = Vector3.zero
local lastRot: CFrame = CFrame.identity

--============================================================================
-- Part pool
--============================================================================
local function newPart(shape: Shape): Part
	local p = Instance.new("Part")
	p.Name = "Prop"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape == "Ball" then
		p.Shape = Enum.PartType.Ball
	elseif shape == "Cylinder" then
		p.Shape = Enum.PartType.Cylinder
	end
	return p
end

local function acquirePart(shape: Shape): Part
	partsInUse += 1
	local p = table.remove(pools[shape])
	if p then
		return p
	end
	return newPart(shape)
end

local function releasePart(shape: Shape, p: Part)
	partsInUse -= 1
	p.Parent = nil
	table.insert(pools[shape], p)
end

local function releaseProp(a: Assigned)
	local specs = PROP_SPECS[a.prop.kind]
	for i, p in a.parts do
		releasePart(specs[i].shape, p)
	end
end

local function assignProp(prop: Prop, shadow: boolean, folder: Folder): Assigned
	local specs = PROP_SPECS[prop.kind]
	local parts: { Part } = table.create(#specs)
	local offsets: { CFrame } = table.create(#specs)
	local s = prop.scale
	for i, sp in specs do
		local p = acquirePart(sp.shape)
		p.Size = sp.size * s
		p.Color = if sp.tint then tintColor(sp.color, prop.tint) else sp.color
		p.Material = sp.material
		p.CastShadow = shadow
		p.Parent = folder
		parts[i] = p
		local o = sp.offset
		offsets[i] = CFrame.new(o.Position * s + Vector3.new(0, -PROP_SINK - prop.sink, 0)) * o.Rotation -- CHANGED (Phase 8)
	end
	return { prop = prop, parts = parts, offsets = offsets }
end

local function releaseAll()
	for _, a in assigned do
		releaseProp(a)
	end
	table.clear(assigned)
	table.clear(pending)
	table.clear(visibleChunks)
	table.clear(moveParts)
	table.clear(moveCFrames)
	moveDirty = true
	needsRefresh = true
end

--============================================================================
-- Visible set
--============================================================================

-- Tiles whose plane may hold props within propRadius of the camera.
local function nearbyTiles(bodyId: number, camera: Vec3d): { TileInfo }
	local result: { TileInfo } = {}
	local seen: { [number]: boolean } = {}
	local radius = Bodies.get(bodyId).Radius
	local d = Vec3d.normalize(camera)
	local ref = if math.abs(d.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
	local e1 = Vec3d.normalize(Vec3d.cross(ref, d))
	local e2 = Vec3d.cross(d, e1)
	local step = propRadius / TILE_SEARCH_STEPS / radius
	for ia = -TILE_SEARCH_STEPS, TILE_SEARCH_STEPS do
		for ib = -TILE_SEARCH_STEPS, TILE_SEARCH_STEPS do
			local dir = Vec3d.add(d, Vec3d.add(Vec3d.scale(e1, ia * step), Vec3d.scale(e2, ib * step)))
			local tile = SurfaceHeight.tileOf(bodyId, dir)
			local key = SurfaceHeight.tileKey(tile)
			if not seen[key] then
				seen[key] = true
				local infoKey = bodyId * 134217728 + key
				local info = tileInfos[infoKey]
				if info == nil then
					info = tileInfo(bodyId, tile)
					tileInfos[infoKey] = info
				end
				table.insert(result, info :: TileInfo)
			end
		end
	end
	return result
end

local function byDist(a: VisibleChunk, b: VisibleChunk): boolean
	return a.dist < b.dist
end

local function byPendingDist(a: PendingChunk, b: PendingChunk): boolean
	return a.dist < b.dist
end

-- Rebuilds the visible chunk list and the generation queue around the camera.
-- CHANGED (Phase 8): `h` is the camera's height above the terrain (the tile planes are only the cell grid now).
local function collectChunks(bodyId: number, camera: Vec3d, h: number)
	table.clear(visibleChunks)
	table.clear(pending)
	stampCounter += 1
	if math.abs(h) >= propRadius then
		return
	end
	local reach = math.sqrt(propRadius * propRadius - h * h)
	for _, info in nearbyTiles(bodyId, camera) do
		local rel = Vec3d.sub(camera, info.centre)
		local cx, cz = Vec3d.dot(rel, info.ax), Vec3d.dot(rel, info.az)
		local maxChunkX = math.floor(info.ex / 2 / CHUNK_SIZE)
		local maxChunkZ = math.floor(info.ez / 2 / CHUNK_SIZE)
		local i0 = math.max(math.floor((cx - reach) / CHUNK_SIZE), -maxChunkX - 1)
		local i1 = math.min(math.floor((cx + reach) / CHUNK_SIZE), maxChunkX)
		local j0 = math.max(math.floor((cz - reach) / CHUNK_SIZE), -maxChunkZ - 1)
		local j1 = math.min(math.floor((cz + reach) / CHUNK_SIZE), maxChunkZ)
		for ci = i0, i1 do
			-- distance from the camera's foot to the chunk rectangle (on the plane), plus height
			local dx = math.max(ci * CHUNK_SIZE - cx, 0, cx - (ci + 1) * CHUNK_SIZE)
			for cj = j0, j1 do
				local dz = math.max(cj * CHUNK_SIZE - cz, 0, cz - (cj + 1) * CHUNK_SIZE)
				local distSq = dx * dx + dz * dz + h * h
				if distSq > propRadius * propRadius then
					continue
				end
				-- CHANGED (Night review): only chunks over true-scale ground (a scaled terrain band is drawn nearer
				-- than it is: props there would float in front of it)
				local filter = groundFilter
				if filter then
					-- the chunk's centre and four corners (on its tile plane: the filter looks at lattice cells)
					local inside = true
					for corner = 0, 4 do
						local a = if corner == 0 then 0.5 else (corner - 1) % 2
						local b = if corner == 0 then 0.5 else (corner - 1) // 2
						local point = Vec3d.add(
							info.centre,
							Vec3d.add(
								Vec3d.scale(info.ax, (ci + a) * CHUNK_SIZE),
								Vec3d.scale(info.az, (cj + b) * CHUNK_SIZE)
							)
						)
						if not filter(point, 0) then
							inside = false
							break
						end
					end
					if not inside then
						continue
					end
				end
				local key = chunkKey(bodyId, info.key, ci, cj)
				local chunk = chunks[key]
				local dist = math.sqrt(distSq)
				if chunk then
					chunk.stamp = stampCounter
					table.insert(visibleChunks, { chunk = chunk, dist = dist })
				else
					table.insert(pending, { key = key, info = info, ci = ci, cj = cj, dist = dist })
				end
			end
		end
	end
	table.sort(visibleChunks, byDist)
	table.sort(pending, byPendingDist)
end

-- Drops cached chunks that are not visible when the cache is over its size.
local function trimCache()
	if chunkCount <= CHUNK_CACHE_MAX then
		return
	end
	for key, chunk in chunks do
		if chunk.stamp ~= stampCounter then
			chunks[key] = nil
			chunkCount -= 1
		end
	end
end

-- Chooses the props to draw (nearest chunks first, up to the part cap) and (re)assigns parts.
local function assignVisible(camera: Vec3d, folder: Folder)
	local wanted: { [number]: Prop } = {}
	local budget = maxPropParts
	local radiusSq = propRadius * propRadius
	for _, vc in visibleChunks do
		for _, prop in vc.chunk.props do
			if prop.partCount > budget then
				continue
			end
			if Vec3d.distanceSq(prop.pos, camera) <= radiusSq then
				wanted[prop.id] = prop
				budget -= prop.partCount
			end
		end
		if budget <= 0 then
			break
		end
	end
	local changed = false
	for id, a in assigned do
		if wanted[id] == nil then
			releaseProp(a)
			assigned[id] = nil
			changed = true
		end
	end
	local shadowSq = shadowRadius * shadowRadius -- CHANGED (Night review): per tier
	for id, prop in wanted do
		local shadow = Vec3d.distanceSq(prop.pos, camera) <= shadowSq
		local a = assigned[id]
		if a == nil then
			assigned[id] = assignProp(prop, shadow, folder)
			changed = true
		elseif a.parts[1].CastShadow ~= shadow then
			for _, p in a.parts do
				p.CastShadow = shadow
			end
		end
	end
	if changed then
		table.clear(moveParts)
		table.clear(moveCFrames)
		for _, a in assigned do
			for _, p in a.parts do
				table.insert(moveParts, p)
				table.insert(moveCFrames, CFrame.identity)
			end
		end
		moveDirty = true
	end
end

-- Generates pending chunks nearest first within the frame budget. Returns true if any finished.
local function generatePending(bodyId: number): boolean
	if #pending == 0 then
		return false
	end
	local start = os.clock()
	local any = false
	while #pending > 0 and os.clock() - start < GEN_BUDGET_S do
		local job = table.remove(pending, 1) :: PendingChunk
		if chunks[job.key] == nil then
			chunks[job.key] = {
				key = job.key,
				props = generateChunk(bodyId, job.info, job.ci, job.cj),
				stamp = stampCounter,
			}
			chunkCount += 1
			any = true
		end
	end
	return any
end

--============================================================================
-- Placement
--============================================================================
local function placeAll(ctx: RenderContext.RenderContext, bodyId: number)
	local frame = ctx.frame
	local offset = bodyOffsetFor(bodyId, frame, ctx.ut)
	local ox, oy, oz = 0, 0, 0
	if offset then
		ox, oy, oz = offset.x, offset.y, offset.z
	end
	local ref = frame.refPos
	if
		not moveDirty
		and ref.x == lastRefX
		and ref.y == lastRefY
		and ref.z == lastRefZ
		and ox == lastOffX
		and oy == lastOffY
		and oz == lastOffZ
		and frame.slotOrigin == lastSlot
		and frame.refRot == lastRot
	then
		return
	end
	local i = 0
	for _, a in assigned do
		local rootCFrame = Frames.cframeToWorkspace(frame, a.prop.pos, a.prop.rot, offset)
		for k = 1, #a.parts do
			i += 1
			moveCFrames[i] = rootCFrame * a.offsets[k]
		end
	end
	if i > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, BULK_MOVE_MODE)
	end
	lastRefX, lastRefY, lastRefZ = ref.x, ref.y, ref.z
	lastOffX, lastOffY, lastOffZ = ox, oy, oz
	lastSlot = frame.slotOrigin
	lastRot = frame.refRot
	moveDirty = false
end

-- CHANGED (Night review): the radius / part cap in use (the tier's, or its moving-pocket values); a change re-chooses
-- the drawn props.
local function applyActiveDetail()
	local moving = movingTimer > 0
	local radius = if moving then math.min(movingRadius, detailRadius) else detailRadius
	local parts = if moving then math.min(movingMaxParts, detailMaxParts) else detailMaxParts
	if radius ~= propRadius or parts ~= maxPropParts then
		propRadius = radius
		maxPropParts = parts
		needsRefresh = true
	end
end

local function hide()
	local folder = propsFolder
	if folder and folder.Parent ~= nil then
		folder.Parent = nil
	end
end

--============================================================================
-- API
--============================================================================
function SurfaceProps.init(parent: Folder)
	root = parent
	local folder = Instance.new("Folder")
	folder.Name = "Props"
	propsFolder = folder
	for _ = 1, POOL_PREWARM do
		table.insert(pools.Block, newPart("Block"))
	end
end

-- CHANGED (Night review): `version` changes whenever the ground the filter (setGroundFilter) checks changes.
function SurfaceProps.update(ctx: RenderContext.RenderContext, surfaceMode: boolean, version: number?)
	local folder = propsFolder
	local parent = root
	if folder == nil or parent == nil then
		return
	end
	if version ~= groundVersion then
		groundVersion = version
		needsRefresh = true
	end
	local bodyId = ctx.dominantBodyId
	local body = Bodies.find(bodyId)
	if not surfaceMode or body == nil or body.Radius <= 0 or Vec3d.lengthSq(ctx.cameraDominant) < 1 then
		hide()
		return
	end
	if currentBodyId ~= bodyId then
		releaseAll()
		currentBodyId = bodyId
	end
	-- CHANGED (Night review): while the pocket frame moves (a flight pocket's reference follows its craft) every prop
	-- part is re-posed each frame, so fewer, nearer props are drawn. A pocket switch or rebase does not count.
	local frame = ctx.frame
	local ref = frame.refPos
	if ctx.pocketId ~= watchedPocket or frame.frameEpoch ~= watchedEpoch then
		watchedPocket, watchedEpoch = ctx.pocketId, frame.frameEpoch
	elseif ref.x ~= watchedRefX or ref.y ~= watchedRefY or ref.z ~= watchedRefZ or frame.refRot ~= watchedRot then
		movingTimer = MOVING_HOLD_S
	else
		movingTimer = math.max(movingTimer - math.max(ctx.dt, 0), 0)
	end
	watchedRefX, watchedRefY, watchedRefZ, watchedRot = ref.x, ref.y, ref.z, frame.refRot
	applyActiveDetail()

	local camera = ctx.cameraDominant
	-- far above the ground nothing is in reach: keep what is assigned but skip the work
	-- CHANGED (Phase 8): height above the terrain, not sea level (props on mountains)
	local height = SurfaceHeight.height(bodyId, camera)
	if height > propRadius then
		hide()
		return
	end
	if folder.Parent ~= parent then
		folder.Parent = parent
		moveDirty = true
	end
	if needsRefresh or Vec3d.distanceSq(camera, lastRefreshPos) > REFRESH_DISTANCE * REFRESH_DISTANCE then
		collectChunks(bodyId, camera, height)
		trimCache()
		assignVisible(camera, folder)
		Vec3d.copyInto(lastRefreshPos, camera)
		needsRefresh = false
	end
	if generatePending(bodyId) then
		-- new chunks are in the cache: re-collect next frame so they get drawn
		needsRefresh = true
	end
	placeAll(ctx, bodyId)
end

--[[
	CHANGED (Phase 8): detail from the Quality tier (Surface): draw radius (m), part cap and density (share of Biome's
	props per hectare, 0..1). A new density regenerates the cached chunks.
	CHANGED (Night review): + shadowRadius (m, props nearer than this cast shadows; 0 = none) and the radius / part
	cap used while the pocket frame moves (each defaults to the still value).
]]
function SurfaceProps.setDetail(
	radius: number,
	maxParts: number,
	density: number,
	newShadowRadius: number?,
	newMovingRadius: number?,
	newMovingMaxParts: number?
)
	detailRadius = radius
	detailMaxParts = maxParts
	movingRadius = newMovingRadius or radius
	movingMaxParts = newMovingMaxParts or maxParts
	shadowRadius = newShadowRadius or SHADOW_RADIUS
	propRadius = -1 -- re-chosen below (forces a refresh)
	applyActiveDetail()
	-- shadows are rewritten on the refresh for assigned props whose CastShadow no longer matches
	local scale = math.clamp(density, 0.05, 1)
	if scale ~= densityScale then
		densityScale = scale
		releaseAll()
		table.clear(chunks)
		chunkCount = 0
	end
	needsRefresh = true
end

--[[
	CHANGED (Night review): `filter(pos, margin)`: whether the ground within `margin` m of body-relative `pos` is drawn
	at true scale (Surface: TerrainMesh.isTrueScaleAt). Chunks failing it get no props; nil draws them all.
]]
function SurfaceProps.setGroundFilter(filter: ((pos: Vec3d, margin: number) -> boolean)?)
	groundFilter = filter
	needsRefresh = true
end

-- Test hook / debug.
SurfaceProps._test = table.freeze({
	generateChunk = generateChunk,
	tileInfo = tileInfo,
	partsInUse = function(): number
		return partsInUse
	end,
	PROP_SPECS = PROP_SPECS,
	inSiteClearing = inSiteClearing, -- CHANGED (Physics feel)
	SITE_CLEAR_HALF_EXTENT = SITE_CLEAR_HALF_EXTENT,
})

return table.freeze(SurfaceProps)
