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

	API:
		Surface.init(parent)                   -- parent = workspace.ClientUniverse.Surface
		Surface.update(ctx, surfaceMode)       -- every frame; surfaceMode from ScaledSpace.isSurfaceMode()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HomeBase = require(ReplicatedStorage.Shared.Sites.HomeBase)
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
local TINT_BRIGHTNESS = 0.035 -- +/- fraction of per-tile brightness variation
local TINT_HUE = 0.02 -- +/- fraction of per-tile green/red balance variation
local HASH_SALT = 7919 -- second hash stream for the hue variation

local BASE_POCKET_ID = 0
local SITE_LATITUDE = 0 -- rad, the base pocket's surface point (PocketService)
local SITE_LONGITUDE = 0
local SITE_VIEW_DISTANCE = 25000 -- m, true camera distance to the site below which the copy is shown

local BULK_MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged

type Look = { color: Color3, material: Enum.Material }
local LOOKS: { [number]: Look } = {
	[Bodies.HOMEWORLD] = { color = Color3.fromRGB(88, 134, 64), material = Enum.Material.Grass },
	[Bodies.MOON] = { color = Color3.fromRGB(128, 128, 126), material = Enum.Material.Slate },
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

-- (a * b) mod 2^32 without losing precision in doubles (a < 2^32, b < 2^27).
local function mul32(a: number, b: number): number
	local lo = bit32.band(a, 0xFFFF)
	local hi = bit32.rshift(a, 16)
	return ((hi * b) % 65536 * 65536 + lo * b) % 4294967296
end

-- Deterministic hash of an integer key to [0, 1).
local function hash01(key: number): number
	local h = key % 4294967296
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x045D9F3B)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x045D9F3B)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h / 4294967296
end

local function lookOf(bodyId: number): Look
	local look = LOOKS[bodyId]
	if look then
		return look
	end
	return { color = Bodies.get(bodyId).Color, material = FALLBACK_MATERIAL }
end

-- The body's ground colour with a slight deterministic per-tile tint so tile edges are readable.
local function tileColor(bodyId: number, key: number): Color3
	local base = lookOf(bodyId).color
	local brightness = 1 + TINT_BRIGHTNESS * (hash01(key) * 2 - 1)
	local hue = TINT_HUE * (hash01(key + HASH_SALT) * 2 - 1)
	return Color3.new(
		math.clamp(base.R * brightness * (1 - hue), 0, 1),
		math.clamp(base.G * brightness * (1 + hue), 0, 1),
		math.clamp(base.B * brightness, 0, 1)
	)
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

local function releaseAll()
	for _, t in active do
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
	local look = lookOf(bodyId)
	local newActive: { ActiveTile } = {}
	local newByKey: { [number]: ActiveTile } = {}
	for _, tile in collectTiles(bodyId, nadirDir) do
		local key = SurfaceHeight.tileKey(tile)
		local t = activeByKey[key]
		if t == nil then
			local pos, rot, size = tilePose(bodyId, tile)
			local p = acquirePart()
			p.Size = size
			p.Color = tileColor(bodyId, key)
			p.Material = look.material
			p.Parent = folder
			t = {
				key = key,
				part = p,
				pos = pos,
				rot = rot,
				half = size / 2,
				collide = false,
				shadow = false,
			}
		end
		local kept = t :: ActiveTile
		table.insert(newActive, kept)
		newByKey[key] = kept
	end
	for key, t in activeByKey do
		if newByKey[key] == nil then
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
		for i, t in active do
			tileCFrames[i] = Frames.cframeToWorkspace(frame, t.pos, t.rot, offset)
		end
		if #tileParts > 0 then
			Workspace:BulkMoveTo(tileParts, tileCFrames, BULK_MOVE_MODE)
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
		end
	end
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
end

function Surface.update(ctx: RenderContext.RenderContext, surfaceMode: boolean)
	if surfaceMode then
		updateTiles(ctx)
	else
		hideTiles()
	end
	updateSite(ctx, surfaceMode)
end

-- Test hook: pure helpers for the offline tests.
Surface._test = table.freeze({
	collectTiles = collectTiles,
	tilePose = tilePose,
	tileColor = tileColor,
	hash01 = hash01,
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
