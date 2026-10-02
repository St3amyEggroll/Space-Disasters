--!strict
--[[
	Surface
	Render layer 3 (spec 7.6): the true-scale ground near the camera, plus a cosmetic copy of the launch site when
	the camera is near it but not in the base pocket.

	CHANGED (Phase 8): heightmap terrain. The v1 cap of flat tangent tiles (and their biome textures) is replaced by:
	  * TerrainMesh: the dominant body's SurfaceHeight ground drawn as cube-sphere quadtree chunks batched into a few
	    EditableMeshes (bands; far bands are scaled about the camera so they fit the draw distance), with Part plates
	    as the fallback when EditableMesh is unavailable and as the placeholder while the first meshes build
	  * TerrainCollision: invisible wedges on the lattice triangles around the local character
	  * SurfaceProps: trees and rocks standing on the terrain
	Detail follows Render/Quality (phones at most "Medium"). Below PREBUILD_FACTOR x the proxy handover altitude the
	terrain is built in the background while ScaledSpace still draws the planet, so it is ready when surface mode
	starts.

	Launch site copy: HomeBase.build() is built once (lazily), stripped to cosmetic, and moved with the rigid
	base-pocket -> current-pocket transform (one BulkMoveTo over its cached parts, only when that transform changed).
	CHANGED (Phase 8): it is only shown while the terrain under it is drawn at true scale (a scaled-down terrain band
	would be drawn in front of it).

	Positions are kept in doubles relative to their body and converted with Frames only after the reference is
	subtracted (invariant I1).

	API:
		Surface.init(parent)                                -- parent = workspace.ClientUniverse.Surface
		Surface.update(ctx, surfaceMode, proxyMinAltitude?, prebuildAllowed?)
		                                                    -- every frame; surfaceMode from ScaledSpace.isSurfaceMode(),
		                                                    -- proxyMinAltitude from ScaledSpace (enables prebuilding)
		Surface.prebuild(ctx)                               -- CHANGED (Phase 8): build the ground for ctx's camera
		                                                    -- without drawing it (the main menu builds the base's)
		Surface.summary(): string                           -- CHANGED (Phase 8): F3 debug line
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local HomeBase = require(ReplicatedStorage.Shared.Sites.HomeBase)
local Quality = require(script.Parent.Quality) -- CHANGED (Phase 8)
local RenderContext = require(script.Parent.RenderContext)
local SurfaceProps = require(script.Parent.SurfaceProps)
local TerrainCollision = require(script.Parent.TerrainCollision) -- CHANGED (Phase 8)
local TerrainMesh = require(script.Parent.TerrainMesh) -- CHANGED (Phase 8)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d
type Frame = Frames.Frame

--============================================================================
-- Tunables
--============================================================================
local BASE_POCKET_ID = 0
local SITE_LATITUDE = 0 -- rad, the base pocket's surface point (PocketService)
local SITE_LONGITUDE = 0
local SITE_VIEW_DISTANCE = 25000 -- m, true camera distance to the site below which the copy is shown
local SITE_MARGIN = 600 -- m, the site copy needs true-scale terrain this far around the site centre (plate +-420)
local PREBUILD_FACTOR = 1.4 -- CHANGED (Phase 8): build the terrain below this x the proxy handover altitude

-- CHANGED (Phase 8): props per Quality tier: draw radius (m; at most ~0.7 x TerrainMesh's near-disc radius, so props
-- only stand on true-scale terrain), part cap and density (share of Biome's props per hectare)
local PROPS_BY_TIER: { [string]: { radius: number, maxParts: number, density: number } } = {
	Low = { radius = 400, maxParts = 300, density = 0.4 },
	Medium = { radius = 520, maxParts = 600, density = 0.7 },
	High = { radius = 650, maxParts = 1000, density = 1 },
}

local BULK_MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged
--============================================================================

local Surface = {}

--============================================================================
-- Pure helpers
--============================================================================

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

local siteModel: Model? = nil
local siteParts: { BasePart } = {}
local siteBaseCFrames: { CFrame } = {}
local siteCFrames: { CFrame } = {}
local siteLastTransform: CFrame? = nil

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
		and TerrainMesh.isTrueScaleAt(SITE_POS, SITE_MARGIN) -- CHANGED (Phase 8)
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

-- CHANGED (Phase 8): prop detail follows the Quality tier.
local function applyPropTier(tier: string)
	local props = PROPS_BY_TIER[tier] or PROPS_BY_TIER.High
	SurfaceProps.setDetail(props.radius, props.maxParts, props.density)
end

function Surface.init(parent: Folder)
	root = parent
	-- CHANGED (Phase 8): terrain meshes / plates, collision near the character, props
	TerrainMesh.init(parent)
	TerrainCollision.init(parent)
	SurfaceProps.init(parent)
	applyPropTier(Quality.tier())
	Quality.onChanged(function(tier: Quality.Tier)
		applyPropTier(tier)
	end)
end

--[[
	CHANGED (Phase 8): `proxyMinAltitude` (ScaledSpace.proxyMinAltitude of the dominant body) lets the terrain build
	in the background before surface mode starts; `prebuildAllowed` false (the main menu's view) never builds.
]]
function Surface.update(
	ctx: RenderContext.RenderContext,
	surfaceMode: boolean,
	proxyMinAltitude: number?,
	prebuildAllowed: boolean?
)
	local prebuild = prebuildAllowed ~= false
		and proxyMinAltitude ~= nil
		and ctx.altitude < PREBUILD_FACTOR * (proxyMinAltitude :: number)
	TerrainMesh.update(ctx, surfaceMode, prebuild)
	TerrainCollision.update(ctx)
	updateSite(ctx, surfaceMode)
	-- props only while the terrain around the camera is drawn at true scale (their radius stays inside the near disc)
	SurfaceProps.update(ctx, surfaceMode and TerrainMesh.isTrueScaleAt(ctx.cameraDominant, 0))
end

-- CHANGED (Phase 8): builds (without drawing) the ground around ctx's camera; the main menu calls this for the base.
function Surface.prebuild(ctx: RenderContext.RenderContext)
	TerrainMesh.update(ctx, false, true)
end

-- CHANGED (Phase 8): F3 debug line.
function Surface.summary(): string
	return TerrainMesh.summary() .. string.format("  colliders %d", TerrainCollision.partCount())
end

-- Test hook: pure helpers for the offline tests.
Surface._test = table.freeze({
	siteTransform = siteTransform,
	siteFrame = SITE_FRAME,
	sitePos = SITE_POS,
})

return table.freeze(Surface)
