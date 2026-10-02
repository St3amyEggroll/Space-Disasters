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

	CHANGED (Night review): mobile / quality pass. In a flight pocket within SITE_VIEW_DISTANCE of the site the
	pocket frame moves every frame, and the copy's 1004 parts were re-posed every frame (1004 CFrames + a BulkMoveTo).
	Now the copy is one assembly: its Ground plate (the PrimaryPart) is the only anchored part and every other part is
	welded to it (unanchored, Massless, no collision / queries / touches), so only the root's CFrame is written. By
	tier: the Plots (612 parts) and the Decor (lamps, tanks, control building, street lines: 93) are only in the copy
	on High, and the site's lights only shine on High (Render/SiteLights, which also handles the real base). A tier
	change rebuilds the copy the next time it is shown. Props get a shadow radius and a smaller radius / part cap while
	the pocket frame moves, per tier (PROPS_BY_TIER, SurfaceProps.setDetail).

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

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local HomeBase = require(ReplicatedStorage.Shared.Sites.HomeBase)
local Quality = require(script.Parent.Quality) -- CHANGED (Phase 8)
local RenderContext = require(script.Parent.RenderContext)
local SiteLights = require(script.Parent.SiteLights) -- CHANGED (Night review)
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
-- CHANGED (Night review): + shadowRadius (m; props nearer than this cast shadows) and the radius / part cap while the
-- pocket frame moves (every drawn prop part is re-posed each frame then)
type PropDetail = {
	radius: number,
	maxParts: number,
	density: number,
	shadowRadius: number,
	movingRadius: number,
	movingMaxParts: number,
}
local PROPS_BY_TIER: { [string]: PropDetail } = {
	Low = { radius = 400, maxParts = 300, density = 0.4, shadowRadius = 0, movingRadius = 250, movingMaxParts = 120 },
	Medium = {
		radius = 520,
		maxParts = 600,
		density = 0.7,
		shadowRadius = 100,
		movingRadius = 320,
		movingMaxParts = 240,
	},
	High = {
		radius = 650,
		maxParts = 1000,
		density = 1,
		shadowRadius = 220,
		movingRadius = 500,
		movingMaxParts = 500,
	},
}
-- CHANGED (Night review): launch-site copy content that is only built on this tier (HomeBase top-level folders)
local SITE_FULL_TIER = "High"
local SITE_FULL_ONLY: { string } = { "Plots", "Decor" }
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
-- CHANGED (Night review): one anchored root (the Ground plate) with every other part welded to it (was every part
-- anchored and moved with BulkMoveTo)
local siteRoot: BasePart? = nil
local siteRootBase: CFrame = CFrame.identity -- the root's base-pocket CFrame
local siteLastTransform: CFrame? = nil
local siteUntrackLights: (() -> ())? = nil

--============================================================================
-- Launch site copy
--============================================================================
-- CHANGED (Night review): the copy for a Quality tier, as one welded assembly; returns the model and its root.
local function buildSiteCopy(tier: string): (Model, BasePart)
	local model = HomeBase.build()
	model.Name = "HomeBaseView"
	if tier ~= SITE_FULL_TIER then
		for _, name in SITE_FULL_ONLY do
			local folder = model:FindFirstChild(name)
			if folder then
				folder:Destroy()
			end
		end
	end
	local rootPart = model.PrimaryPart
	assert(rootPart, "HomeBase.build() has no PrimaryPart")
	local rootCFrame = rootPart.CFrame
	local doomed: { Instance } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.Locked = true
			if d:IsA("SpawnLocation") then
				d.Enabled = false
			end
			if d == rootPart then
				d.Anchored = true
			else
				-- explicit offsets (not a WeldConstraint) so the joint is right whatever the copy's parent is
				d.Anchored = false
				local weld = Instance.new("Weld")
				weld.Name = "SiteWeld"
				weld.Part0 = rootPart
				weld.Part1 = d
				weld.C0 = rootCFrame:ToObjectSpace(d.CFrame)
				weld.C1 = CFrame.identity
				weld.Parent = d
			end
		elseif d:IsA("ProximityPrompt") or d:IsA("ClickDetector") or d:IsA("BaseScript") then
			table.insert(doomed, d)
		end
	end
	for _, d in doomed do
		d:Destroy()
	end
	return model, rootPart
end

local function hideSite()
	local model = siteModel
	if model and model.Parent ~= nil then
		model.Parent = nil
		siteLastTransform = nil
	end
end

-- CHANGED (Night review): a tier change drops the copy; it is rebuilt for the new tier the next time it is shown.
local function destroySite()
	local model = siteModel
	if model == nil then
		return
	end
	local untrack = siteUntrackLights
	if untrack then
		untrack()
	end
	siteUntrackLights = nil
	model:Destroy()
	siteModel = nil
	siteRoot = nil
	siteLastTransform = nil
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
	local model, rootPart = siteModel, siteRoot
	if model == nil or rootPart == nil then
		local built, builtRoot = buildSiteCopy(Quality.tier()) -- CHANGED (Night review)
		model, rootPart = built, builtRoot
		siteModel, siteRoot = built, builtRoot
		siteRootBase = builtRoot.CFrame
		siteUntrackLights = SiteLights.track(built) -- CHANGED (Night review): lights on High only
	end
	assert(model and rootPart)
	local m = siteTransform(ctx.frame, ctx.ut)
	if model.Parent ~= parent then
		model.Parent = parent
		siteLastTransform = nil
	end
	if siteLastTransform ~= m then
		-- CHANGED (Night review): only the root moves; the welded parts follow (was 1004 CFrames + BulkMoveTo)
		rootPart.CFrame = m * siteRootBase
		siteLastTransform = m
	end
end

--============================================================================
-- API
--============================================================================

-- CHANGED (Phase 8): prop detail follows the Quality tier.
-- CHANGED (Night review): + shadow radius and the moving-pocket radius / part cap.
local function applyPropTier(tier: string)
	local props = PROPS_BY_TIER[tier] or PROPS_BY_TIER.High
	SurfaceProps.setDetail(
		props.radius,
		props.maxParts,
		props.density,
		props.shadowRadius,
		props.movingRadius,
		props.movingMaxParts
	)
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
		destroySite() -- CHANGED (Night review): the copy's content depends on the tier
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
	buildSiteCopy = buildSiteCopy, -- CHANGED (Night review)
	PROPS_BY_TIER = PROPS_BY_TIER, -- CHANGED (Night review)
})

return table.freeze(Surface)
