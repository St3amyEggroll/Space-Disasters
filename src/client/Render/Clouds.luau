--!strict
--[[
	Clouds (CHANGED (Physics feel): new)
	A cosmetic cloud deck to fly through, as a speed cue: soft white Ball clusters between CLOUD_BASE_FRACTION and
	CLOUD_TOP_FRACTION of the atmosphere top (about 1.5 to 2.5 km on a 7 km atmosphere), drawn within DRAW_RADIUS
	of the camera, only on bodies with an atmosphere. The band is a fraction of the atmosphere top so it still sits
	in the lower air if a body's size or air changes.

	Placement is deterministic, like SurfaceProps: each SurfaceHeight tile of the body is cut into CELL_SIZE cells
	in its own plane coordinates (origin at the tile centre, axes = the tile's X / Z). A cell holds at most one
	cluster, decided by hashing (body, tile, cell): its chance, altitude, width, puff count and every puff's offset,
	size and transparency. The cluster centre is the cell point pushed out radially to its altitude, so the deck
	follows the planet's curve. The same clouds appear on every visit and for every player.

	Clusters are drawn from pooled Ball parts (MAX_CLOUD_PARTS hard cap), nearest first, moved with one BulkMoveTo
	whenever the frame or the assignment changes. The visible set is re-chosen when the camera moved
	REFRESH_DISTANCE; clusters fade out toward the edge of the draw radius (transparency, written on refresh only).
	All parts are Anchored, CanCollide / CanQuery / CanTouch false, CastShadow false: purely cosmetic.

	Driven by UniverseRenderer after Surface. Its layer folder (workspace.ClientUniverse.Clouds) is hidden in the
	map view and under the main menu view (UniverseRenderer hides layers per reason); this module only parents its
	own "Puffs" folder in or out when there is nothing to draw.

	API:
		Clouds.init(parent)                 -- parent = workspace.ClientUniverse.Clouds
		Clouds.update(ctx, surfaceMode)     -- every frame; surfaceMode from ScaledSpace.isSurfaceMode()
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

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
-- Deck altitude band, as fractions of the body's atmosphere top (Earth 7 km: 1.5 .. 2.5 km)
local CLOUD_BASE_FRACTION = 1.5 / 7
local CLOUD_TOP_FRACTION = 2.5 / 7
local DRAW_RADIUS = 3000 -- m (= studs), clusters farther than this from the camera are not drawn
local FADE_START = 0.7 -- fraction of DRAW_RADIUS where clusters start fading out
local CELL_SIZE = 420 -- m, one cluster at most per cell
local COVER = 0.32 -- chance that a cell holds a cluster
local CLUSTER_WIDTH_MIN = 60 -- studs across a whole cluster
local CLUSTER_WIDTH_MAX = 200
local PUFFS_MIN = 3 -- balls per cluster
local PUFFS_MAX = 6
local PUFF_SIZE_MIN = 0.35 -- puff diameter, fraction of the cluster width
local PUFF_SIZE_MAX = 0.6
local PUFF_SPREAD = 0.32 -- puff centres within this fraction of the width from the cluster centre (horizontally)
local PUFF_RISE = 0.12 -- puff centres up to this fraction of the width above / below the centre
local TRANSPARENCY_MIN = 0.35
local TRANSPARENCY_MAX = 0.55
local TINT_MIN = 0.92 -- brightness factor of a cluster's grey-white (shaded puffs read as volume)
local CLOUD_COLOR = Color3.fromRGB(250, 251, 255)
local CLOUD_MATERIAL = Enum.Material.SmoothPlastic
local MAX_CLOUD_PARTS = 450 -- hard cap on pooled parts in use
local REFRESH_DISTANCE = 120 -- m of camera movement before the cluster set is re-chosen
local TRANSPARENCY_WRITE_EPSILON = 0.02 -- fade changes smaller than this are not written
local TILE_SEARCH_STEPS = 4 -- tiles are found on a (2n + 1)^2 direction grid over the draw disc
local TILE_EDGE_MARGIN = 0 -- m, cluster centres must be inside their tile by this much
local CACHE_MAX = 600 -- cached clusters before ones not in view are dropped
local HASH_SALT = 52711
local POOL_PREWARM = 120 -- parts created at init
local BULK_MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged
--============================================================================

type Puff = {
	offset: Vec3d, -- from the cluster centre (m, universe axes)
	size: number, -- studs (diameter)
	transparency: number, -- at full visibility
}

type Cluster = {
	id: number,
	centre: Vec3d, -- body-relative (doubles)
	puffs: { Puff },
	color: Color3,
	stamp: number,
}

type TileInfo = {
	key: number,
	tile: TileId,
	centre: Vec3d, -- tile plane centre (m, body-relative)
	up: Vec3d,
	ax: Vec3d,
	az: Vec3d,
	ex: number,
	ez: number,
}

type Assigned = {
	cluster: Cluster,
	parts: { Part },
	fade: number, -- 0 = full, 1 = gone (last written)
}

type Candidate = { cluster: Cluster, dist: number }

local Clouds = {}

--============================================================================
-- Pure helpers
--============================================================================

local function cellKey(bodyId: number, tileKey: number, ci: number, cj: number): number
	return ((bodyId * 134217728 + tileKey) * 64 + (ci + 32)) * 64 + (cj + 32)
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Deck altitudes (m above sea level) for a body, or nil when it has no atmosphere.
local function band(bodyId: number): (number?, number?)
	local body = Bodies.find(bodyId)
	local atmosphere = if body then body.Atmosphere else nil
	if atmosphere == nil then
		return nil, nil
	end
	return atmosphere.Top * CLOUD_BASE_FRACTION, atmosphere.Top * CLOUD_TOP_FRACTION
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
		ex = ex,
		ez = ez,
	}
end

-- The deterministic cluster of one cell, or nil when the cell is clear (or its point lies outside the tile).
local function generateCluster(bodyId: number, info: TileInfo, ci: number, cj: number): Cluster?
	local salt = HASH_SALT + bodyId * 7
	local key = info.key
	if Biome.hash01(key, ci, cj, salt) >= COVER then
		return nil
	end
	local low, high = band(bodyId)
	if low == nil or high == nil then
		return nil
	end
	local x = (ci + 0.1 + 0.8 * Biome.hash01(key, ci, cj, salt + 1)) * CELL_SIZE
	local z = (cj + 0.1 + 0.8 * Biome.hash01(key, ci, cj, salt + 2)) * CELL_SIZE
	if math.abs(x) > info.ex / 2 - TILE_EDGE_MARGIN or math.abs(z) > info.ez / 2 - TILE_EDGE_MARGIN then
		return nil
	end
	local c, ax, az, up = info.centre, info.ax, info.az, info.up
	local px, py, pz = c.x + x * ax.x + z * az.x, c.y + x * ax.y + z * az.y, c.z + x * ax.z + z * az.z
	local len = math.sqrt(px * px + py * py + pz * pz)
	local altitude = lerp(low, high, Biome.hash01(key, ci, cj, salt + 3))
	local r = (Bodies.get(bodyId).Radius + altitude) / len
	local centre = Vec3d.new(px * r, py * r, pz * r)

	local width = lerp(CLUSTER_WIDTH_MIN, CLUSTER_WIDTH_MAX, Biome.hash01(key, ci, cj, salt + 4))
	local count = PUFFS_MIN + math.floor(Biome.hash01(key, ci, cj, salt + 5) * (PUFFS_MAX - PUFFS_MIN + 1))
	count = math.min(count, PUFFS_MAX)
	local puffs: { Puff } = table.create(count)
	for k = 1, count do
		local s = salt + 16 + k * 8
		local angle = Biome.hash01(key, ci, cj, s) * 2 * math.pi
		-- the first puff sits at the centre, so every cluster has a core
		local spread = if k == 1 then 0 else PUFF_SPREAD * width * math.sqrt(Biome.hash01(key, ci, cj, s + 1))
		local ox, oz = math.cos(angle) * spread, math.sin(angle) * spread
		local oy = (Biome.hash01(key, ci, cj, s + 2) * 2 - 1) * PUFF_RISE * width
		local size = width * lerp(PUFF_SIZE_MIN, PUFF_SIZE_MAX, Biome.hash01(key, ci, cj, s + 3))
		if k == 1 then
			size = width * PUFF_SIZE_MAX
		end
		table.insert(puffs, {
			offset = Vec3d.new(
				ox * ax.x + oy * up.x + oz * az.x,
				ox * ax.y + oy * up.y + oz * az.y,
				ox * ax.z + oy * up.z + oz * az.z
			),
			size = size,
			transparency = lerp(TRANSPARENCY_MIN, TRANSPARENCY_MAX, Biome.hash01(key, ci, cj, s + 4)),
		})
	end
	local tint = lerp(TINT_MIN, 1, Biome.hash01(key, ci, cj, salt + 6))
	return {
		id = cellKey(bodyId, key, ci, cj),
		centre = centre,
		puffs = puffs,
		color = Color3.new(CLOUD_COLOR.R * tint, CLOUD_COLOR.G * tint, CLOUD_COLOR.B * tint),
		stamp = 0,
	}
end

-- 0 = fully visible, 1 = faded out, by distance from the camera.
local function fadeAt(dist: number): number
	return smoothstep(FADE_START * DRAW_RADIUS, DRAW_RADIUS, dist)
end

-- abs(bodyId) - abs(frame reference body) at UT, nil when they are the same body.
local function bodyOffsetFor(bodyId: number, frame: Frame, ut: number): Vec3d?
	if bodyId == frame.refBodyId then
		return nil
	end
	return Universe.bodyOffset(bodyId, frame.refBodyId, ut)
end

--============================================================================
-- State
--============================================================================
local root: Folder? = nil
local puffsFolder: Folder? = nil
local pool: { Part } = {}
local partsInUse = 0

local tileInfos: { [number]: TileInfo } = {} -- by body-qualified tile key
local NO_CLUSTER: Cluster = { id = -1, centre = Vec3d.zero(), puffs = {}, color = CLOUD_COLOR, stamp = 0 } -- clear cell
local cache: { [number]: Cluster } = {} -- by cell key; NO_CLUSTER for a clear cell
local cacheCount = 0
local stampCounter = 0
local assigned: { [number]: Assigned } = {}

local currentBodyId: number? = nil
local lastRefreshPos: Vec3d = Vec3d.new(math.huge, 0, 0)
local needsRefresh = true

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
local function newPart(): Part
	local p = Instance.new("Part")
	p.Name = "Cloud"
	p.Shape = Enum.PartType.Ball
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Locked = true
	p.Massless = true
	p.Material = CLOUD_MATERIAL
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	return p
end

local function acquirePart(): Part
	partsInUse += 1
	return table.remove(pool) or newPart()
end

local function releasePart(p: Part)
	partsInUse -= 1
	p.Parent = nil
	table.insert(pool, p)
end

local function releaseCluster(a: Assigned)
	for _, p in a.parts do
		releasePart(p)
	end
end

local function puffTransparency(puff: Puff, fade: number): number
	return puff.transparency + (1 - puff.transparency) * fade
end

local function assignCluster(cluster: Cluster, fade: number, folder: Folder): Assigned
	local parts: { Part } = table.create(#cluster.puffs)
	for i, puff in cluster.puffs do
		local p = acquirePart()
		p.Size = Vector3.one * puff.size
		p.Color = cluster.color
		p.Transparency = puffTransparency(puff, fade)
		p.Parent = folder
		parts[i] = p
	end
	return { cluster = cluster, parts = parts, fade = fade }
end

local function releaseAll()
	for _, a in assigned do
		releaseCluster(a)
	end
	table.clear(assigned)
	table.clear(moveParts)
	table.clear(moveCFrames)
	moveDirty = true
	needsRefresh = true
end

--============================================================================
-- Visible set
--============================================================================

-- Tiles whose cells may hold clusters within DRAW_RADIUS of the camera (horizontally).
local function nearbyTiles(bodyId: number, camera: Vec3d): { TileInfo }
	local result: { TileInfo } = {}
	local seen: { [number]: boolean } = {}
	local radius = Bodies.get(bodyId).Radius
	local d = Vec3d.normalize(camera)
	local ref = if math.abs(d.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
	local e1 = Vec3d.normalize(Vec3d.cross(ref, d))
	local e2 = Vec3d.cross(d, e1)
	local step = DRAW_RADIUS / TILE_SEARCH_STEPS / radius
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

local function byDist(a: Candidate, b: Candidate): boolean
	return a.dist < b.dist
end

-- Every cluster within DRAW_RADIUS of the camera, nearest first.
local function collectClusters(bodyId: number, camera: Vec3d): { Candidate }
	local candidates: { Candidate } = {}
	stampCounter += 1
	local radiusSq = DRAW_RADIUS * DRAW_RADIUS
	local camDir = Vec3d.normalize(camera)
	for _, info in nearbyTiles(bodyId, camera) do
		-- the camera's foot on the tile plane (along its radial direction)
		local cosine = Vec3d.dot(camDir, info.up)
		if cosine <= 0.5 then
			continue
		end
		local foot = Vec3d.sub(Vec3d.scale(camDir, Vec3d.dot(info.centre, info.up) / cosine), info.centre)
		local cx, cz = Vec3d.dot(foot, info.ax), Vec3d.dot(foot, info.az)
		local maxX = math.floor(info.ex / 2 / CELL_SIZE)
		local maxZ = math.floor(info.ez / 2 / CELL_SIZE)
		local i0 = math.max(math.floor((cx - DRAW_RADIUS) / CELL_SIZE), -maxX - 1)
		local i1 = math.min(math.floor((cx + DRAW_RADIUS) / CELL_SIZE), maxX)
		local j0 = math.max(math.floor((cz - DRAW_RADIUS) / CELL_SIZE), -maxZ - 1)
		local j1 = math.min(math.floor((cz + DRAW_RADIUS) / CELL_SIZE), maxZ)
		for ci = i0, i1 do
			for cj = j0, j1 do
				local id = cellKey(bodyId, info.key, ci, cj)
				local cluster = cache[id]
				if cluster == nil then
					cluster = generateCluster(bodyId, info, ci, cj) or NO_CLUSTER
					cache[id] = cluster
					cacheCount += 1
				end
				if cluster ~= NO_CLUSTER then
					cluster.stamp = stampCounter
					local distSq = Vec3d.distanceSq(cluster.centre, camera)
					if distSq <= radiusSq then
						table.insert(candidates, { cluster = cluster, dist = math.sqrt(distSq) })
					end
				end
			end
		end
	end
	table.sort(candidates, byDist)
	return candidates
end

-- Drops cached clusters that were not seen in the last collection when the cache is over its size.
local function trimCache()
	if cacheCount <= CACHE_MAX then
		return
	end
	for id, cached in cache do
		if cached == NO_CLUSTER or cached.stamp ~= stampCounter then
			cache[id] = nil
			cacheCount -= 1
		end
	end
end

-- Chooses the clusters to draw (nearest first, up to the part cap), (re)assigns parts and updates the fades.
local function assignVisible(candidates: { Candidate }, folder: Folder)
	local wanted: { [number]: Candidate } = {}
	local budget = MAX_CLOUD_PARTS
	for _, candidate in candidates do
		local n = #candidate.cluster.puffs
		if n > budget then
			break
		end
		wanted[candidate.cluster.id] = candidate
		budget -= n
	end
	local changed = false
	for id, a in assigned do
		if wanted[id] == nil then
			releaseCluster(a)
			assigned[id] = nil
			changed = true
		end
	end
	for id, candidate in wanted do
		local fade = fadeAt(candidate.dist)
		local a = assigned[id]
		if a == nil then
			assigned[id] = assignCluster(candidate.cluster, fade, folder)
			changed = true
		elseif math.abs(a.fade - fade) >= TRANSPARENCY_WRITE_EPSILON then
			a.fade = fade
			for i, p in a.parts do
				p.Transparency = puffTransparency(a.cluster.puffs[i], fade)
			end
		end
	end
	if changed then
		-- placeAll refills both lists in assignment order
		table.clear(moveParts)
		table.clear(moveCFrames)
		moveDirty = true
	end
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
		local c = a.cluster.centre
		for k, puff in a.cluster.puffs do
			local o = puff.offset
			i += 1
			moveCFrames[i] =
				CFrame.new(Frames.pointToWorkspaceXYZ(frame, c.x + o.x + ox, c.y + o.y + oy, c.z + o.z + oz))
			moveParts[i] = a.parts[k]
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

local function hide()
	local folder = puffsFolder
	if folder and folder.Parent ~= nil then
		folder.Parent = nil
	end
end

--============================================================================
-- API
--============================================================================
function Clouds.init(parent: Folder)
	root = parent
	local folder = Instance.new("Folder")
	folder.Name = "Puffs"
	puffsFolder = folder
	for _ = 1, POOL_PREWARM do
		table.insert(pool, newPart())
	end
end

function Clouds.update(ctx: RenderContext.RenderContext, surfaceMode: boolean)
	local folder = puffsFolder
	local parent = root
	if folder == nil or parent == nil then
		return
	end
	local bodyId = ctx.dominantBodyId
	local body = Bodies.find(bodyId)
	local low, high = band(bodyId)
	if
		not surfaceMode
		or body == nil
		or body.Radius <= 0
		or low == nil
		or high == nil
		or Vec3d.lengthSq(ctx.cameraDominant) < 1
	then
		hide()
		return
	end
	if currentBodyId ~= bodyId then
		releaseAll()
		currentBodyId = bodyId
	end
	local camera = ctx.cameraDominant
	-- far above or below the deck nothing is in reach: keep what is assigned but skip the work
	if ctx.altitude > high + DRAW_RADIUS or ctx.altitude < low - DRAW_RADIUS then
		hide()
		return
	end
	if folder.Parent ~= parent then
		folder.Parent = parent
		moveDirty = true
	end
	if needsRefresh or Vec3d.distanceSq(camera, lastRefreshPos) > REFRESH_DISTANCE * REFRESH_DISTANCE then
		assignVisible(collectClusters(bodyId, camera), folder)
		trimCache()
		Vec3d.copyInto(lastRefreshPos, camera)
		needsRefresh = false
	end
	placeAll(ctx, bodyId)
end

-- Test hook / debug.
Clouds._test = table.freeze({
	generateCluster = generateCluster,
	tileInfo = tileInfo,
	band = band,
	fadeAt = fadeAt,
	partsInUse = function(): number
		return partsInUse
	end,
	DRAW_RADIUS = DRAW_RADIUS,
	CELL_SIZE = CELL_SIZE,
	CLUSTER_WIDTH_MIN = CLUSTER_WIDTH_MIN,
	CLUSTER_WIDTH_MAX = CLUSTER_WIDTH_MAX,
	TRANSPARENCY_MIN = TRANSPARENCY_MIN,
	TRANSPARENCY_MAX = TRANSPARENCY_MAX,
})

return table.freeze(Clouds)
