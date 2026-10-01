--!strict
--[[
	Surface
	Render layer 3 (spec 7.6), v1: the true-scale ground near the camera as a cap of flat tangent tiles, plus a
	cosmetic copy of the launch site when the camera is near it but not in the base pocket.

	Tiles: every SurfaceHeight lattice tile of the dominant body whose centre lies within NEAR_CAP_RADIUS (+ half a
	tile) of the point on the surface under the camera. The set is found by sampling directions on a grid around
	the nadir (so it crosses cube-face edges correctly) and is only rebuilt when the nadir moved more than
	RESAMPLE_DISTANCE or the dominant body changed. Each tile is a pooled, anchored Part whose TOP face sits
	TILE_TOP_GAP below the true tile plane, so the real site's Ground (top exactly on the plane) never z-fights.
	Tiles collide only within TILE_COLLIDE_RADIUS of the local player's HumanoidRootPart.

	Launch site copy: HomeBase.build() is built once (lazily), stripped to cosmetic, and moved with the rigid
	base-pocket -> current-pocket transform (one BulkMoveTo over its cached parts, only when that transform changed).

	Positions are kept in doubles relative to their body and converted with Frames only after the reference is
	subtracted (invariant I1).

	CHANGED (Phase 2a feedback): the ground matches the planet seen from space. Each tile Part is coloured and
	given a material from Biome at its centre; on top of that, tiles get a Biome texture: a pooled MeshPart box
	(clone of one shared EditableMesh, same pose and size as the tile Part) carrying a TILE_TEXTURE_SIZE
	EditableImage painted over the tile's footprint. Textures are painted nearest-first from a queue with a
	per-frame time budget; while a tile is textured its Part is invisible (Transparency 1) but still collides.
	Images of released tiles are cached (LRU, MAX_TILE_IMAGES in total) so coming back costs nothing. Without
	EditableMesh / EditableImage the flat biome-coloured Parts remain. Near-camera props: SurfaceProps.

	API:
		Surface.init(parent)                   -- parent = workspace.ClientUniverse.Surface
		Surface.update(ctx, surfaceMode)       -- every frame; surfaceMode from ScaledSpace.isSurfaceMode()
		                                         -- (also drives SurfaceProps)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HomeBase = require(ReplicatedStorage.Shared.Sites.HomeBase)
local RenderContext = require(script.Parent.RenderContext)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local SurfaceProps = require(script.Parent.SurfaceProps)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d
type Frame = Frames.Frame
type TileId = SurfaceHeight.TileId

--============================================================================
-- Tunables
--============================================================================
local CAP_RADIUS = GameConfig.NEAR_CAP_RADIUS -- m, tiles whose centre is within this (+ margin) of the nadir
local CAP_MARGIN = GameConfig.TILE_SIZE / 2 -- m, half a tile
local SAMPLE_STEP = 850 -- m, nadir sampling spacing; must stay below the smallest tile's inscribed diameter (1200 misses corner tiles)
local RESAMPLE_DISTANCE = 200 -- m, nadir movement that triggers a tile-set rebuild
local TILE_THICKNESS = GameConfig.TILE_THICKNESS -- studs
local TILE_TOP_GAP = 0.1 -- studs, tile top face below the true tile plane
local MAX_TILE_EXTENT = 2048 -- studs, Roblox part size limit
local COLLIDE_RADIUS = GameConfig.TILE_COLLIDE_RADIUS -- studs, tile nearest point to the local player's root
local SHADOW_RADIUS = 1000 -- studs, tiles farther than this from the camera cast no shadow
local POOL_PREWARM = 100 -- tile parts created at init (a full cap is 69-93 tiles)

-- CHANGED (Phase 2a feedback): biome-textured tiles
local TEXTURED_TILES_ENABLED = true
local TILE_TEXTURE_SIZE = 64 -- pixels per tile side (~32 m per pixel)
local TILE_TEXTURE_CELLS = 8 -- Biome coarse grid cells per tile side
local TILE_TEXTURE_DETAIL = 3 -- Biome detail level (finer than the scaled-space textures)
local TILE_TEXTURE_BUDGET_S = 0.002 -- painting work per frame
local MAX_TILE_IMAGES = 48 -- EditableImages for tiles: in use + cached for tiles you may come back to
local TILE_MESH_MATERIAL = Enum.Material.SmoothPlastic
local OCEAN_TILE_FRACTION = 0.5 -- textured tiles with more water than this get OCEAN_REFLECTANCE
local OCEAN_REFLECTANCE = 0.08
local BODY_KEY_STRIDE = 134217728 -- tile keys are < 2^27: bodyId * stride + tileKey is unique per body

local BASE_POCKET_ID = 0
local SITE_LATITUDE = 0 -- rad, the base pocket's surface point (PocketService)
local SITE_LONGITUDE = 0
local SITE_VIEW_DISTANCE = 25000 -- m, true camera distance to the site below which the copy is shown

local BULK_MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged

-- CHANGED (Phase 2a feedback): untextured tiles take the Biome colour at their centre and this material
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
--============================================================================

type ActiveTile = {
	key: number,
	part: Part,
	pos: Vec3d, -- part centre relative to the body centre (doubles)
	rot: CFrame, -- universe rotation
	half: Vector3, -- half size
	collide: boolean,
	shadow: boolean,
	-- CHANGED (Phase 2a feedback): texture state
	tile: TileId,
	bodyId: number,
	imageKey: number, -- body-qualified tile key (texture cache)
	mesh: MeshPart?, -- textured box drawn instead of the Part
	image: EditableImage?,
	ocean: boolean,
	dist: number, -- m from the nadir at the last rebuild (texture priority)
}

local Surface = {}

--============================================================================
-- Pure helpers
--============================================================================

-- Unit tangent axes perpendicular to a unit direction.
local function tangentBasis(d: Vec3d): (Vec3d, Vec3d)
	local ref = if math.abs(d.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
	local e1 = Vec3d.normalize(Vec3d.cross(ref, d))
	local e2 = Vec3d.cross(d, e1)
	return e1, e2
end

--[[
	Every tile of `bodyId` whose centre (on its plane) is within CAP_RADIUS + CAP_MARGIN of the surface point
	along `nadirDir`, sorted by tile key. Samples an azimuthal-equidistant grid around the nadir (sample spacing
	on the sphere <= SAMPLE_STEP), so tiles on neighbouring cube faces are found too.
]]
local function collectTiles(bodyId: number, nadirDir: Vec3d): { TileId }
	local radius = Bodies.get(bodyId).Radius
	local d = Vec3d.normalize(nadirDir)
	local reach = CAP_RADIUS + CAP_MARGIN
	local reachUnitSq = (reach / radius) * (reach / radius)
	local maxArc = 2 * radius * math.asin(math.min(1, reach / (2 * radius))) + SAMPLE_STEP
	maxArc = math.min(maxArc, math.pi * radius)
	local e1, e2 = tangentBasis(d)
	local steps = math.ceil(maxArc / SAMPLE_STEP)
	local seen: { [number]: boolean } = {}
	local result: { TileId } = {}
	local dir = Vec3d.zero()
	for ia = -steps, steps do
		local a = ia * SAMPLE_STEP
		for ib = -steps, steps do
			local b = ib * SAMPLE_STEP
			local r = math.sqrt(a * a + b * b)
			if r <= maxArc then
				if r < 1e-9 then
					Vec3d.copyInto(dir, d)
				else
					local angle = r / radius
					local c = math.cos(angle)
					local s = math.sin(angle) / r
					Vec3d.set(
						dir,
						d.x * c + (e1.x * a + e2.x * b) * s,
						d.y * c + (e1.y * a + e2.y * b) * s,
						d.z * c + (e1.z * a + e2.z * b) * s
					)
				end
				local tile = SurfaceHeight.tileOf(bodyId, dir)
				local key = SurfaceHeight.tileKey(tile)
				if not seen[key] then
					seen[key] = true
					local center = SurfaceHeight.tileCenter(bodyId, tile)
					if Vec3d.distanceSq(center, d) <= reachUnitSq then
						table.insert(result, tile)
					end
				end
			end
		end
	end
	table.sort(result, function(x: TileId, y: TileId): boolean
		return SurfaceHeight.tileKey(x) < SurfaceHeight.tileKey(y)
	end)
	return result
end

-- A tile part's centre (relative to the body, doubles), universe rotation and size (top face TILE_TOP_GAP below the plane).
local function tilePose(bodyId: number, tile: TileId): (Vec3d, CFrame, Vector3)
	local radius = Bodies.get(bodyId).Radius
	local up = SurfaceHeight.tileCenter(bodyId, tile)
	local pos = Vec3d.scale(up, radius - TILE_THICKNESS / 2 - TILE_TOP_GAP)
	local rot = SurfaceHeight.tileRotation(bodyId, tile)
	local ex, ez = SurfaceHeight.tileExtent(bodyId, tile)
	return pos, rot, Vector3.new(math.min(ex, MAX_TILE_EXTENT), TILE_THICKNESS, math.min(ez, MAX_TILE_EXTENT))
end

-- CHANGED (Phase 2a feedback): the Biome colour, material and kind at a tile's centre (untextured look).
local function tileLook(bodyId: number, tile: TileId): (Color3, Enum.Material, Biome.Kind)
	local up = SurfaceHeight.tileCenter(bodyId, tile)
	local r, g, b, kind = Biome.sample(bodyId, up.x, up.y, up.z)
	return Color3.new(r, g, b), KIND_MATERIALS[kind] or FALLBACK_MATERIAL, kind :: Biome.Kind
end

-- Distance from a point to an oriented box (0 inside).
local function boxDistance(cf: CFrame, half: Vector3, p: Vector3): number
	local l = cf:PointToObjectSpace(p)
	local dx = math.max(math.abs(l.X) - half.X, 0)
	local dy = math.max(math.abs(l.Y) - half.Y, 0)
	local dz = math.max(math.abs(l.Z) - half.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- abs(bodyId) - abs(frame reference body) at UT, nil when they are the same body.
local function bodyOffsetFor(bodyId: number, frame: Frame, ut: number): Vec3d?
	if bodyId == frame.refBodyId then
		return nil
	end
	return Universe.bodyOffset(bodyId, frame.refBodyId, ut)
end

local SITE_UP = Frames.surfaceUp(SITE_LATITUDE, SITE_LONGITUDE)
local SITE_POS = Vec3d.scale(SITE_UP, Bodies.get(Bodies.HOMEWORLD).Radius)
local SITE_FRAME = Frames.new(Bodies.HOMEWORLD, SITE_POS, Frames.surfaceRotation(SITE_UP), Vector3.zero)

-- Rigid transform from base-pocket workspace coordinates to the current pocket's workspace coordinates.
local function siteTransform(frame: Frame, ut: number): CFrame
	return Frames.relativeTransform(SITE_FRAME, frame, bodyOffsetFor(Bodies.HOMEWORLD, frame, ut))
end

--============================================================================
-- State
--============================================================================
local root: Folder? = nil
local tilesFolder: Folder? = nil
local pool: { Part } = {}
local active: { ActiveTile } = {}
local activeByKey: { [number]: ActiveTile } = {}
local tileParts: { BasePart } = {}
local tileCFrames: { CFrame } = {}
local tileBodyId: number? = nil
local tileNadir: Vec3d = Vec3d.zero() -- nadir surface point (body-relative) at the last rebuild
local tilesDirty = true

-- last transform inputs (skip BulkMoveTo when nothing moved)
local lastRefX, lastRefY, lastRefZ = 0, 0, 0
local lastOffX, lastOffY, lastOffZ = 0, 0, 0
local lastSlot: Vector3 = Vector3.zero
local lastRot: CFrame = CFrame.identity

-- CHANGED (Phase 2a feedback): tile textures
type CachedImage = { image: EditableImage, ocean: boolean, stamp: number }
local texturesEnabled = TEXTURED_TILES_ENABLED -- false once EditableMesh / EditableImage failed
local tileTemplate: MeshPart? = nil -- unparented source of every tile box (kept, never destroyed)
local tileMeshKeepAlive: { EditableMesh } = {} -- MeshParts vanish when their EditableMesh is destroyed
local meshPool: { MeshPart } = {}
local imageCache: { [number]: CachedImage } = {} -- images of released tiles, by imageKey
local freeImages: { EditableImage } = {}
local allImages: { EditableImage } = {} -- every image created (keeps them alive)
local imageStamp = 0
local painter: Biome.Painter? = nil
local paintTile: ActiveTile? = nil
local paintImage: EditableImage? = nil
local meshParts: { BasePart } = {}
local meshCFrames: { CFrame } = {}

local siteModel: Model? = nil
local siteParts: { BasePart } = {}
local siteBaseCFrames: { CFrame } = {}
local siteCFrames: { CFrame } = {}
local siteLastTransform: CFrame? = nil

--============================================================================
-- Tile pool
--============================================================================
local function newTilePart(): Part
	local p = Instance.new("Part")
	p.Name = "Tile"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function acquirePart(): Part
	local p = table.remove(pool)
	if p then
		return p
	end
	return newTilePart()
end

local function releasePart(p: Part)
	p.Parent = nil
	p.CanCollide = false
	p.CanQuery = false
	p.CastShadow = false
	table.insert(pool, p)
end

--============================================================================
-- Tile textures (CHANGED Phase 2a feedback)
--============================================================================
local function disableTextures(reason: string)
	if texturesEnabled then
		texturesEnabled = false
		warn("[Surface] biome ground textures are unavailable (" .. reason .. "); tiles stay flat biome colours.")
	end
end

-- Unit box (-0.5 .. 0.5) whose top face carries the tile texture (Biome texture space: s along X, t along Z);
-- the sides stretch the edge pixels down. No bottom face.
local function buildTileTemplate(): (EditableMesh, MeshPart)
	local AssetService = game:GetService("AssetService")
	local mesh = AssetService:CreateEditableMesh()
	local ok, err = pcall(function()
		local function uvOf(x: number, z: number): Vector2
			local u, v = Biome.paramToUV(x + 0.5, z + 0.5)
			return Vector2.new(u, v)
		end
		local function quad(corners: { Vector3 }, uvs: { Vector2 }, normal: Vector3)
			local normalId = mesh:AddNormal(normal)
			local ids: { number } = {}
			local uvIds: { number } = {}
			for i = 1, 4 do
				ids[i] = mesh:AddVertex(corners[i])
				uvIds[i] = mesh:AddUV(uvs[i])
			end
			-- counter-clockwise seen from outside: (b - a) x (c - a) along the outward normal
			local flip = (corners[2] - corners[1]):Cross(corners[3] - corners[1]):Dot(normal) < 0
			local function triangle(i: number, j: number, k: number)
				if flip then
					j, k = k, j
				end
				local face = mesh:AddTriangle(ids[i], ids[j], ids[k])
				mesh:SetFaceNormals(face, { normalId, normalId, normalId })
				mesh:SetFaceUVs(face, { uvIds[i], uvIds[j], uvIds[k] })
			end
			triangle(1, 2, 3)
			triangle(1, 3, 4)
		end
		local h = 0.5
		local top = { Vector3.new(-h, h, -h), Vector3.new(h, h, -h), Vector3.new(h, h, h), Vector3.new(-h, h, h) }
		quad(top, { uvOf(-h, -h), uvOf(h, -h), uvOf(h, h), uvOf(-h, h) }, Vector3.yAxis)
		for i = 1, 4 do
			local a, b = top[i], top[i % 4 + 1]
			local mid = (a + b) / 2
			local uvA, uvB = uvOf(a.X, a.Z), uvOf(b.X, b.Z)
			quad(
				{ a, b, b - Vector3.yAxis, a - Vector3.yAxis },
				{ uvA, uvB, uvB, uvA },
				Vector3.new(mid.X, 0, mid.Z).Unit
			)
		end
	end)
	if not ok then
		mesh:Destroy()
		error(err, 0)
	end
	local partOk, part = pcall(function(): MeshPart
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)
	if not partOk then
		mesh:Destroy()
		error(tostring(part), 0)
	end
	return mesh, part
end

local function acquireMesh(): MeshPart?
	local m = table.remove(meshPool)
	if m then
		return m
	end
	local template = tileTemplate
	if template == nil then
		return nil
	end
	local clone = template:Clone()
	clone.Name = "TileTexture"
	clone.Anchored = true
	clone.CanCollide = false
	clone.CanQuery = false
	clone.CanTouch = false
	clone.CastShadow = false
	clone.Massless = true
	clone.Locked = true
	clone.Material = TILE_MESH_MATERIAL
	return clone
end

-- Shows `image` on the tile (its Part turns invisible but keeps colliding).
local function attachTexture(t: ActiveTile, image: EditableImage, ocean: boolean)
	local mesh = acquireMesh()
	if mesh == nil then
		table.insert(freeImages, image)
		return
	end
	local ok, err = pcall(function()
		mesh.TextureContent = Content.fromObject(image)
	end)
	if not ok then
		table.insert(meshPool, mesh)
		table.insert(freeImages, image)
		disableTextures(tostring(err))
		return
	end
	mesh.Size = t.half * 2
	mesh.CFrame = t.part.CFrame -- right place this frame; BulkMoveTo takes over from the next one
	mesh.Reflectance = if ocean then OCEAN_REFLECTANCE else 0
	mesh.CastShadow = t.shadow
	mesh.Parent = tilesFolder
	t.part.Transparency = 1
	t.mesh = mesh
	t.image = image
	t.ocean = ocean
	tilesDirty = true
end

-- Takes the texture off a tile that is being released; its image goes to the cache.
local function detachTexture(t: ActiveTile)
	local mesh = t.mesh
	if mesh then
		mesh.Parent = nil
		table.insert(meshPool, mesh)
		t.mesh = nil
	end
	t.part.Transparency = 0
	local image = t.image
	if image then
		imageStamp += 1
		imageCache[t.imageKey] = { image = image, ocean = t.ocean, stamp = imageStamp }
		t.image = nil
	end
	if paintTile == t then
		-- abort the job: its image is free again
		paintTile = nil
		local pending = paintImage
		if pending then
			table.insert(freeImages, pending)
			paintImage = nil
		end
	end
end

-- A free image: unused, newly created (below the cap), or the least recently used cached one.
local function acquireImage(): EditableImage?
	local free = table.remove(freeImages)
	if free then
		return free
	end
	if #allImages < MAX_TILE_IMAGES then
		local ok, result = pcall(function(): EditableImage
			local AssetService = game:GetService("AssetService")
			return AssetService:CreateEditableImage({ Size = Vector2.new(TILE_TEXTURE_SIZE, TILE_TEXTURE_SIZE) })
		end)
		if not ok then
			disableTextures(tostring(result))
			return nil
		end
		table.insert(allImages, result)
		return result
	end
	local oldestKey: number? = nil
	local oldestStamp = math.huge
	for key, entry in imageCache do
		if entry.stamp < oldestStamp then
			oldestKey, oldestStamp = key, entry.stamp
		end
	end
	if oldestKey then
		local entry = imageCache[oldestKey]
		imageCache[oldestKey] = nil
		return entry.image
	end
	return nil
end

-- At the image cap: takes the image of the farthest textured tile if it is farther than `wanted`.
local function stealImage(wanted: ActiveTile): EditableImage?
	local victim: ActiveTile? = nil
	for _, t in active do
		if t.image ~= nil and t.dist > wanted.dist and (victim == nil or t.dist > (victim :: ActiveTile).dist) then
			victim = t
		end
	end
	if victim == nil then
		return nil
	end
	local v = victim :: ActiveTile
	local image = v.image
	local mesh = v.mesh
	if mesh then
		mesh.Parent = nil
		table.insert(meshPool, mesh)
		v.mesh = nil
	end
	v.part.Transparency = 0
	v.image = nil
	tilesDirty = true
	return image
end

-- Paints tile textures nearest-first within the frame budget.
local function processTextures()
	if not texturesEnabled or tileTemplate == nil then
		return
	end
	local p = painter
	if p == nil then
		local fresh = Biome.newPainter(
			TILE_TEXTURE_SIZE,
			TILE_TEXTURE_CELLS,
			buffer.create(TILE_TEXTURE_SIZE * TILE_TEXTURE_SIZE * 4)
		)
		painter = fresh
		p = fresh
	end
	assert(p)
	local start = os.clock()
	while os.clock() - start < TILE_TEXTURE_BUDGET_S do
		local job = paintTile
		if job == nil then
			-- nearest untextured tile
			local best: ActiveTile? = nil
			for _, t in active do
				if t.image == nil and (best == nil or t.dist < (best :: ActiveTile).dist) then
					best = t
				end
			end
			if best == nil then
				return
			end
			local t = best :: ActiveTile
			local image = acquireImage() or stealImage(t)
			if image == nil then
				return
			end
			local radius = Bodies.get(t.bodyId).Radius
			local up = SurfaceHeight.tileCenter(t.bodyId, t.tile)
			local ax, az = t.rot.XVector, t.rot.ZVector
			Biome.beginRect(
				p,
				t.bodyId,
				"Ground",
				up.x * radius,
				up.y * radius,
				up.z * radius,
				ax.X,
				ax.Y,
				ax.Z,
				az.X,
				az.Y,
				az.Z,
				t.half.X * 2,
				t.half.Z * 2,
				TILE_TEXTURE_DETAIL
			)
			paintTile = t
			paintImage = image
			job = t
		end
		assert(job)
		if Biome.paintStep(p) then
			local image = paintImage :: EditableImage
			paintTile = nil
			paintImage = nil
			local ok, err = pcall(function()
				image:WritePixelsBuffer(Vector2.zero, image.Size, p.buf)
			end)
			if not ok then
				table.insert(freeImages, image)
				disableTextures(tostring(err))
				return
			end
			local total = TILE_TEXTURE_SIZE * TILE_TEXTURE_SIZE
			attachTexture(job, image, p.oceanPixels > OCEAN_TILE_FRACTION * total)
		end
	end
end

local function releaseAll()
	for _, t in active do
		detachTexture(t) -- CHANGED (Phase 2a feedback)
		releasePart(t.part)
	end
	table.clear(active)
	table.clear(activeByKey)
	table.clear(tileParts)
	table.clear(tileCFrames)
	tileBodyId = nil
	tilesDirty = true
end

local function rebuildTiles(bodyId: number, nadirDir: Vec3d, folder: Folder)
	if tileBodyId ~= bodyId then
		releaseAll()
	end
	local newActive: { ActiveTile } = {}
	local newByKey: { [number]: ActiveTile } = {}
	for _, tile in collectTiles(bodyId, nadirDir) do
		local key = SurfaceHeight.tileKey(tile)
		local t = activeByKey[key]
		if t == nil then
			local pos, rot, size = tilePose(bodyId, tile)
			local p = acquirePart()
			p.Size = size
			-- CHANGED (Phase 2a feedback): Biome colour and material instead of one flat look per body
			local color, material, kind = tileLook(bodyId, tile)
			p.Color = color
			p.Material = material
			p.Reflectance = if kind == "Ocean" then OCEAN_REFLECTANCE else 0
			p.Transparency = 0
			p.Parent = folder
			local fresh: ActiveTile = {
				key = key,
				part = p,
				pos = pos,
				rot = rot,
				half = size / 2,
				collide = false,
				shadow = false,
				tile = tile,
				bodyId = bodyId,
				imageKey = bodyId * BODY_KEY_STRIDE + key,
				mesh = nil,
				image = nil,
				ocean = kind == "Ocean",
				dist = 0,
			}
			-- a texture painted on an earlier visit
			local cached = imageCache[fresh.imageKey]
			if cached and texturesEnabled and tileTemplate ~= nil then
				imageCache[fresh.imageKey] = nil
				attachTexture(fresh, cached.image, cached.ocean)
			end
			t = fresh
		end
		local kept = t :: ActiveTile
		kept.dist = Vec3d.distance(SurfaceHeight.tileCenter(bodyId, tile), nadirDir) * Bodies.get(bodyId).Radius
		table.insert(newActive, kept)
		newByKey[key] = kept
	end
	for key, t in activeByKey do
		if newByKey[key] == nil then
			detachTexture(t) -- CHANGED (Phase 2a feedback)
			releasePart(t.part)
		end
	end
	active = newActive
	activeByKey = newByKey
	table.clear(tileParts)
	table.clear(tileCFrames)
	for i, t in active do
		tileParts[i] = t.part
		tileCFrames[i] = CFrame.identity
	end
	tileBodyId = bodyId
	Vec3d.scaleInto(tileNadir, nadirDir, Bodies.get(bodyId).Radius)
	tilesDirty = true
end

local function hideTiles()
	local folder = tilesFolder
	if folder and folder.Parent ~= nil then
		folder.Parent = nil
	end
	for _, t in active do
		if t.collide then
			t.part.CanCollide = false
			t.part.CanQuery = false
			t.collide = false
		end
	end
end

local function localRootPosition(): Vector3?
	local player = Players.LocalPlayer
	local character = player and player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		return hrp.Position
	end
	return nil
end

local function updateTiles(ctx: RenderContext.RenderContext)
	local folder = tilesFolder
	local parent = root
	if folder == nil or parent == nil then
		return
	end
	local bodyId = ctx.dominantBodyId
	local radius = Bodies.get(bodyId).Radius
	if radius <= 0 or Vec3d.lengthSq(ctx.cameraDominant) < 1 then
		hideTiles()
		return
	end
	local nadirDir = Vec3d.normalize(ctx.cameraDominant)
	if tileBodyId ~= bodyId or Vec3d.distance(Vec3d.scale(nadirDir, radius), tileNadir) > RESAMPLE_DISTANCE then
		rebuildTiles(bodyId, nadirDir, folder)
	end
	if folder.Parent ~= parent then
		folder.Parent = parent
		tilesDirty = true
	end

	-- positions: only when the frame, the body offset or the tile set changed
	local frame = ctx.frame
	local offset = bodyOffsetFor(bodyId, frame, ctx.ut)
	local ox, oy, oz = 0, 0, 0
	if offset then
		ox, oy, oz = offset.x, offset.y, offset.z
	end
	local ref = frame.refPos
	if
		tilesDirty
		or ref.x ~= lastRefX
		or ref.y ~= lastRefY
		or ref.z ~= lastRefZ
		or ox ~= lastOffX
		or oy ~= lastOffY
		or oz ~= lastOffZ
		or frame.slotOrigin ~= lastSlot
		or frame.refRot ~= lastRot
	then
		-- CHANGED (Phase 2a feedback): textured boxes share their tile's pose
		table.clear(meshParts)
		table.clear(meshCFrames)
		for i, t in active do
			local cf = Frames.cframeToWorkspace(frame, t.pos, t.rot, offset)
			tileCFrames[i] = cf
			local mesh = t.mesh
			if mesh then
				table.insert(meshParts, mesh)
				table.insert(meshCFrames, cf)
			end
		end
		if #tileParts > 0 then
			Workspace:BulkMoveTo(tileParts, tileCFrames, BULK_MOVE_MODE)
		end
		if #meshParts > 0 then
			Workspace:BulkMoveTo(meshParts, meshCFrames, BULK_MOVE_MODE)
		end
		lastRefX, lastRefY, lastRefZ = ref.x, ref.y, ref.z
		lastOffX, lastOffY, lastOffZ = ox, oy, oz
		lastSlot = frame.slotOrigin
		lastRot = frame.refRot
		tilesDirty = false
	end

	-- collision near the local player, shadows near the camera
	local rootPos = localRootPosition()
	local cameraPos = ctx.camera.Position
	for i, t in active do
		local cf = tileCFrames[i]
		local collide = rootPos ~= nil and boxDistance(cf, t.half, rootPos) <= COLLIDE_RADIUS
		if collide ~= t.collide then
			t.collide = collide
			t.part.CanCollide = collide
			t.part.CanQuery = collide
		end
		local shadow = boxDistance(cf, t.half, cameraPos) <= SHADOW_RADIUS
		if shadow ~= t.shadow then
			t.shadow = shadow
			t.part.CastShadow = shadow
			local mesh = t.mesh
			if mesh then
				mesh.CastShadow = shadow
			end
		end
	end

	processTextures() -- CHANGED (Phase 2a feedback)
end

--============================================================================
-- Launch site copy
--============================================================================
local function buildSiteCopy(): Model
	local model = HomeBase.build()
	model.Name = "HomeBaseView"
	local doomed: { Instance } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.Locked = true
			if d:IsA("SpawnLocation") then
				d.Enabled = false
			end
			table.insert(siteParts, d)
			table.insert(siteBaseCFrames, d.CFrame)
			table.insert(siteCFrames, d.CFrame)
		elseif d:IsA("ProximityPrompt") or d:IsA("ClickDetector") or d:IsA("BaseScript") then
			table.insert(doomed, d)
		end
	end
	for _, d in doomed do
		d:Destroy()
	end
	return model
end

local function hideSite()
	local model = siteModel
	if model and model.Parent ~= nil then
		model.Parent = nil
		siteLastTransform = nil
	end
end

local function updateSite(ctx: RenderContext.RenderContext, surfaceMode: boolean)
	local parent = root
	local wanted = parent ~= nil
		and surfaceMode
		and ctx.pocketId ~= BASE_POCKET_ID
		and ctx.dominantBodyId == Bodies.HOMEWORLD
		and Vec3d.distanceSq(ctx.cameraDominant, SITE_POS) <= SITE_VIEW_DISTANCE * SITE_VIEW_DISTANCE
	if not wanted or parent == nil then
		hideSite()
		return
	end
	local model = siteModel
	if model == nil then
		model = buildSiteCopy()
		siteModel = model
	end
	assert(model)
	local m = siteTransform(ctx.frame, ctx.ut)
	if model.Parent ~= parent then
		model.Parent = parent
		siteLastTransform = nil
	end
	if siteLastTransform ~= m then
		for i, base in siteBaseCFrames do
			siteCFrames[i] = m * base
		end
		Workspace:BulkMoveTo(siteParts, siteCFrames, BULK_MOVE_MODE)
		siteLastTransform = m
	end
end

--============================================================================
-- API
--============================================================================
function Surface.init(parent: Folder)
	root = parent
	local folder = Instance.new("Folder")
	folder.Name = "Tiles"
	tilesFolder = folder
	for _ = 1, POOL_PREWARM do
		table.insert(pool, newTilePart())
	end
	-- CHANGED (Phase 2a feedback): props, and the textured tile box template (CreateMeshPartAsync yields)
	SurfaceProps.init(parent)
	if texturesEnabled then
		task.spawn(function()
			local ok, meshOrError, part = pcall(buildTileTemplate)
			if ok then
				table.insert(tileMeshKeepAlive, meshOrError)
				tileTemplate = part
			else
				disableTextures(tostring(meshOrError))
			end
		end)
	end
end

function Surface.update(ctx: RenderContext.RenderContext, surfaceMode: boolean)
	if surfaceMode then
		updateTiles(ctx)
	else
		hideTiles()
	end
	updateSite(ctx, surfaceMode)
	SurfaceProps.update(ctx, surfaceMode) -- CHANGED (Phase 2a feedback)
end

-- Test hook: pure helpers for the offline tests.
Surface._test = table.freeze({
	collectTiles = collectTiles,
	tilePose = tilePose,
	tileLook = tileLook, -- CHANGED (Phase 2a feedback): replaces tileColor / hash01
	boxDistance = boxDistance,
	siteTransform = siteTransform,
	siteFrame = SITE_FRAME,
	sitePos = SITE_POS,
	tileWorkspaceCFrame = function(frame: Frame, bodyId: number, tile: TileId, ut: number): (CFrame, Vector3)
		local pos, rot, size = tilePose(bodyId, tile)
		return Frames.cframeToWorkspace(frame, pos, rot, bodyOffsetFor(bodyId, frame, ut)), size
	end,
	CAP_RADIUS = CAP_RADIUS,
	CAP_MARGIN = CAP_MARGIN,
	TILE_TOP_GAP = TILE_TOP_GAP,
})

return table.freeze(Surface)
