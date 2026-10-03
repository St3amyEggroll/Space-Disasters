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

	CHANGED (Night review): terrain review fixes.
	  * The site copy is no longer hidden over scaled terrain (it vanished 400-600 m into every launch and blinked on
	    Medium). It is drawn like the terrain under it: scaled about the camera by that terrain's factor
	    (TerrainMesh.scaleAt; same place and size on screen, only nearer), rounded down on a ladder of
	    SITE_SCALE_RATIO steps (TerrainMath.scaleStep) so it is rebuilt about once per 6% of change: part sizes, weld
	    offsets, light ranges and SurfaceGui resolutions (records taken when the copy is built). TerrainMesh keeps the
	    whole site inside its true-scale near band while the camera is near it (keepNear), so on the pad and in the
	    climb the copy and the craft standing on it are both at true scale. It shows up to SITE_VIEW_DISTANCE again,
	    as before Phase 8.
	  * Props: only chunks over true-scale ground are drawn (SurfaceProps' ground filter, TerrainMesh.isTrueScaleAt),
	    re-checked whenever the displayed terrain bands change (TerrainMesh.version).

	CHANGED (Terrain polish): Steamy's Studio test ("the base is broken"): the copy was drawn at the factor of the
	ground under it, but the hills and mountains behind the site are drawn at smaller factors (nearer than the
	site), so they covered it (pieces of the site "stuck in" a ridge), and in the base pocket there was no copy at
	all: when the camera was far from the site (on foot outside it, or after a jump) the ground under the real base
	was a scaled band, drawn (1 - k) x the camera height above the base's plate, covering pads, plots and roads.
	Now (siteWantedScale): when the ground under the site is at true scale nothing changes (the real base, or the
	copy at true scale in a flight pocket, with a craft on its pad); when it is scaled, the copy is drawn in every
	pocket (in the base pocket it covers the real base exactly: same image, nearer) at the smaller of that factor
	and TerrainMesh.depthScale, so nothing behind the site is ever drawn in front of it. Its ground plate is thin
	(the real one's 20-stud sides would show as a dark rim). Surface.isReady (the main menu's Play fade).

	CHANGED (Review 3): review of the terrain polish.
	  * The copy hid what is really there: drawn nearer than it is, it covers every true-scale thing in front of
	    its image. In the base pocket that was the player's own character for seconds after every End Flight
	    (stale meshes put the copy's plate 4-8 studs from the camera) and, 700 m out on foot, other players, the
	    rockets on the pads and the plots (copy 14 studs away). Now the base pocket never draws it while the
	    camera is near the site (SITE_NEAR_HALF / SITE_NEAR_HEIGHT): TerrainMesh keeps the real plate in its
	    true-scale near band out to there (keepNear with SITE_KEEP_HALF / SITE_KEEP_RANGE), and while it does not
	    (a jump home, until the near band is rebuilt) the scaled bands under the plate are hidden instead
	    (TerrainMesh.hideScaledAt: the real plate fills the hole). Farther out the copy stays (the engine culls
	    the real base's small parts there, and scaled ground would cover it).
	  * Wherever it is drawn scaled, the copy is never nearer than the protected depth the scaled bands keep
	    (TerrainMath.objectScale with TerrainMesh.protectDepth): a craft hovering over the site, its smoke trail
	    or a dropped stage are no longer covered by the pads and towers (they were drawn 110-180 studs away in
	    the climb, against 160 for the ground).
	  * "Is the ground under the site at true scale" is asked over the real plate's outline (TerrainMesh.scaleOver,
	    SITE_PLATE_*), not at 4 points 600 m out (often in the ring band past the plate: the copy was drawn over
	    a correct real base).
	  * The copy's content follows the Quality tier in every pocket (the base pocket forced High: a full ~1000-part
	    rebuild at every launch on phones).

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
		Surface.isReady(): boolean                          -- CHANGED (Terrain polish): ground meshes on screen
		Surface.isSettled(): boolean                        -- CHANGED (Memory budget): ground built, no plan running
		Surface.setLoadBoost(mode?)                         -- CHANGED (Memory budget): "Menu" / "Cover" / nil
		Surface.setDebugTint(on) / Surface.debugTint()      -- CHANGED (Far slabs fix): the /bands debug view

	CHANGED (Far slabs fix): Steamy's screenshot over the pads showed big dark-green rectangles with lighter lines
	between them on the grass beside the site. A copy drawn scaled about the camera (whenever part of the plate's
	ground is in a scaled band) floats between the camera and the ground, and Roblox's sun shadows of its plate,
	plots and pads fell on the true-scale near ground below it, offset along the sun: rectangles that are not in the
	true scene. The copy casts no shadow while it is scaled (ShadowGate, its own reason; back at true scale it does).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout) -- CHANGED (Review 3)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local HomeBase = require(ReplicatedStorage.Shared.Sites.HomeBase)
local Quality = require(script.Parent.Quality) -- CHANGED (Phase 8)
local RenderContext = require(script.Parent.RenderContext)
local SiteLights = require(script.Parent.SiteLights) -- CHANGED (Night review)
local ShadowGate = require(script.Parent.ShadowGate) -- CHANGED (Far slabs fix)
local SurfaceProps = require(script.Parent.SurfaceProps)
local TerrainCollision = require(script.Parent.TerrainCollision) -- CHANGED (Phase 8)
local TerrainMath = require(script.Parent.TerrainMath) -- CHANGED (Night review)
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
local PREBUILD_FACTOR = 1.4 -- CHANGED (Phase 8): build the terrain below this x the proxy handover altitude
-- CHANGED (Night review): the copy drawn scaled like the terrain under it
local SITE_SCALE_RATIO = 0.94 -- rescale steps (TerrainMath.scaleStep)
-- CHANGED (Review 3): was 600 (the slack of the near band's leaves left the plate's edge in a ring band): the plate
-- (SITE_PLATE_HALF) + half the near band's largest leaf (400 m; the near band takes leaves by their centre)
local SITE_KEEP_HALF = 630 -- m: TerrainMesh keeps this square around the site inside its near band while it can ...
-- CHANGED (Review 3): ... while the camera's nadir is within this of fitting it (the near square's room is
-- 760 - SITE_KEEP_HALF = 130 m, so the plate stays in it out to 730 m > SITE_NEAR_HALF; the camera's nadir is then
-- still >= 160 m inside the near band)
local SITE_KEEP_RANGE = 600 -- m
-- CHANGED (Terrain polish): the copy whenever the ground under the site is scaled (the base pocket too)
-- CHANGED (Review 3): SITE_TRUE_SCALE removed (TerrainMath.siteCopyScale judges true scale)
local SITE_REACH = 610 -- m from the site centre to its farthest part (plate corner +-420, 80-stud towers)
local SITE_COPY_PLATE_THICKNESS = 0.6 -- studs: the copy's ground plate (the real one is 20 thick, sunk in the ground)
-- CHANGED (Review 3): the ground under the site is judged over the real plate's outline (TerrainMesh.scaleOver)
local SITE_PLATE_HALF = BaseLayout.SITE_HALF_EXTENT + 10 -- m: the real ground plate (+-420) and a margin
local SITE_PLATE_STEPS = 8 -- outline samples per plate edge (~108 m apart: finer than any leaf next to it)
-- CHANGED (Review 3): the base pocket never draws the copy while the camera is this near the site (site tangent
-- x / z, and height above it): the real base is drawn, with everything standing on it
local SITE_NEAR_HALF = 700 -- m
local SITE_NEAR_HEIGHT = 300 -- m
-- CHANGED (Far slabs fix): a copy drawn scaled about the camera floats between the camera and the ground; its sun
-- shadows (plots, pads, the plate) landed on the true-scale ground beside it as dark rectangles. Off while scaled.
local SITE_SHADOW_REASON = "SiteCopyScaled" -- ShadowGate reason
local SITE_TINT = Color3.fromRGB(0, 230, 255) -- CHANGED (Far slabs fix): the copy in the /bands view
local SITE_TINT_NAME = "SiteTint"

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

-- CHANGED (Review 3): body-relative points on the real ground plate's outline (and its centre), for
-- TerrainMesh.scaleOver / hideScaledAt.
local function plateOutline(): { Vec3d }
	local points: { Vec3d } = { SITE_POS }
	for step = 0, SITE_PLATE_STEPS - 1 do
		local a = -SITE_PLATE_HALF + 2 * SITE_PLATE_HALF * step / SITE_PLATE_STEPS
		for _, p in
			{
				Vector3.new(a, 0, -SITE_PLATE_HALF),
				Vector3.new(SITE_PLATE_HALF, 0, a),
				Vector3.new(-a, 0, SITE_PLATE_HALF),
				Vector3.new(-SITE_PLATE_HALF, 0, -a),
			}
		do
			table.insert(points, Frames.pointFromWorkspace(SITE_FRAME, p))
		end
	end
	return points
end
local SITE_PLATE_OUTLINE = plateOutline()

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
-- CHANGED (Night review): what scaling the copy rewrites (taken at build time, at scale 1)
type SiteScaleRecords = {
	parts: { BasePart },
	sizes: { Vector3 },
	welds: { Weld },
	offsets: { CFrame }, -- C0
	backs: { CFrame }, -- C1
	lights: { PointLight },
	ranges: { number },
	guis: { SurfaceGui },
	pixels: { number },
}
local siteRecords: SiteScaleRecords? = nil
local siteScale = 1 -- the scale the copy is built at now
local siteTint = false -- CHANGED (Far slabs fix): the /bands view is on (setDebugTint)
local siteLastCamera: Vector3? = nil

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
	-- CHANGED (Terrain polish): a thin ground plate (same top). The copy is drawn in front of the terrain around it
	-- when scaled, so the real plate's 20-stud sides (hidden in the ground at the base) would show as a dark rim.
	local plateTop = rootPart.CFrame * CFrame.new(0, rootPart.Size.Y / 2, 0)
	rootPart.Size = Vector3.new(rootPart.Size.X, SITE_COPY_PLATE_THICKNESS, rootPart.Size.Z)
	rootPart.CFrame = plateTop * CFrame.new(0, -SITE_COPY_PLATE_THICKNESS / 2, 0)
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

-- CHANGED (Night review): the scale-1 values scaling the copy rewrites (call before SiteLights unparents lights).
local function collectScaleRecords(model: Model): SiteScaleRecords
	local records: SiteScaleRecords = {
		parts = {},
		sizes = {},
		welds = {},
		offsets = {},
		backs = {},
		lights = {},
		ranges = {},
		guis = {},
		pixels = {},
	}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(records.parts, d)
			table.insert(records.sizes, d.Size)
		elseif d:IsA("Weld") then
			table.insert(records.welds, d)
			table.insert(records.offsets, d.C0)
			table.insert(records.backs, d.C1)
		elseif d:IsA("PointLight") then
			table.insert(records.lights, d)
			table.insert(records.ranges, d.Range)
		elseif d:IsA("SurfaceGui") then
			table.insert(records.guis, d)
			table.insert(records.pixels, d.PixelsPerStud)
		end
	end
	return records
end

-- CHANGED (Night review): rebuilds the copy at scale `s` (about its root; updateSite places the root).
local function applySiteScale(records: SiteScaleRecords, s: number)
	for index, part in records.parts do
		part.Size = records.sizes[index] * s
	end
	for index, weld in records.welds do
		local c0, c1 = records.offsets[index], records.backs[index]
		weld.C0 = CFrame.new(c0.Position * s) * c0.Rotation
		weld.C1 = CFrame.new(c1.Position * s) * c1.Rotation
	end
	for index, light in records.lights do
		light.Range = records.ranges[index] * s
	end
	for index, gui in records.guis do
		gui.PixelsPerStud = records.pixels[index] / s -- the same canvas on a smaller part
	end
	-- CHANGED (Far slabs fix): no sun shadows while scaled (they fell on the true-scale ground beside the copy)
	for _, part in records.parts do
		if s < 1 then
			ShadowGate.suppress(part, SITE_SHADOW_REASON)
		else
			ShadowGate.release(part, SITE_SHADOW_REASON)
		end
	end
end

-- CHANGED (Far slabs fix): the copy's flat cyan tint in the /bands view (on), or none.
local function tintSite(model: Model, on: boolean)
	local existing = model:FindFirstChild(SITE_TINT_NAME)
	if not on then
		if existing then
			existing:Destroy()
		end
		return
	end
	if existing == nil then
		local highlight = Instance.new("Highlight")
		highlight.Name = SITE_TINT_NAME
		highlight.FillColor = SITE_TINT
		highlight.FillTransparency = 0
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = model
	end
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
	siteRecords = nil -- CHANGED (Night review)
	siteScale = 1
end

--[[
	CHANGED (Terrain polish): which copy to draw (nil: none) and at what wanted scale.
	  * the ground under the site at true scale: the base pocket needs nothing (the real base is right); elsewhere
	    the copy is drawn at true scale (a craft on its pad stands on it)
	  * the ground under the site drawn scaled about the camera (the camera is far from the site, or high above
	    it): the real base would be drawn behind that ground (it hides the base's lower (1 - k) x camera height:
	    Steamy's "a flat green surface slices through the base"), so the copy is drawn in every pocket, scaled
	    like that ground or less: TerrainMesh.depthScale keeps it in front of every scaled band behind it (the
	    hills and mountains drawn nearer than they are), so nothing behind the site covers it
	CHANGED (Review 3): returns (wanted scale or nil, hide the scaled ground under the plate):
	  * in the base pocket near the site (nearSite) never a copy: when the plate's ground is scaled anyway (a jump
	    home, before the near band holds it) the scaled bands under it are hidden instead
	  * a scaled copy is never nearer than the protected depth (TerrainMath.objectScale)
]]
local function nearSite(ctx: RenderContext.RenderContext): boolean
	local p = Frames.pointToWorkspace(SITE_FRAME, ctx.cameraDominant)
	return math.max(math.abs(p.X), math.abs(p.Z)) <= SITE_NEAR_HALF and p.Y <= SITE_NEAR_HEIGHT
end

local function siteWantedScale(
	ctx: RenderContext.RenderContext,
	terrainScale: number,
	siteDistance: number
): (number?, boolean)
	local inBase = ctx.pocketId == BASE_POCKET_ID
	-- CHANGED (Review 3): the rules are TerrainMath.siteCopyScale (pure, tested offline)
	return TerrainMath.siteCopyScale(
		terrainScale,
		inBase,
		inBase and nearSite(ctx),
		TerrainMesh.depthScale(siteDistance + SITE_REACH),
		TerrainMesh.protectDepth(),
		siteDistance - SITE_REACH
	)
end

-- CHANGED (Review 3): returns the points under which TerrainMesh must hide its scaled bands (nil: none).
local function updateSite(ctx: RenderContext.RenderContext, surfaceMode: boolean): { Vec3d }?
	local parent = root
	-- CHANGED (Night review): shown over scaled terrain too (drawn scaled like it, below); the terrain under it only
	-- has to be drawn at all (scaleAt nil: no band holds it, e.g. beyond the horizon)
	-- CHANGED (Terrain polish): in the base pocket too, whenever the ground under the site is scaled
	local siteDistanceSq = Vec3d.distanceSq(ctx.cameraDominant, SITE_POS)
	local wanted = parent ~= nil
		and surfaceMode
		and ctx.dominantBodyId == Bodies.HOMEWORLD
		and siteDistanceSq <= SITE_VIEW_DISTANCE * SITE_VIEW_DISTANCE
	-- CHANGED (Review 3): over the real plate's outline (was scaleAt(SITE_POS, 600): 4 points past the plate)
	local terrainScale = if wanted then TerrainMesh.scaleOver(SITE_PLATE_OUTLINE) else nil
	if not wanted or parent == nil then
		hideSite()
		return nil
	end
	if terrainScale == nil then
		hideSite()
		-- CHANGED (Review 3): part of the plate in no band (stale meshes after a jump): in the base pocket near the
		-- site the scaled bands under the rest of it are hidden all the same
		return if ctx.pocketId == BASE_POCKET_ID and nearSite(ctx) then SITE_PLATE_OUTLINE else nil
	end
	local wantedScale, hole = siteWantedScale(ctx, terrainScale, math.sqrt(siteDistanceSq))
	if wantedScale == nil then
		hideSite()
		return if hole then SITE_PLATE_OUTLINE else nil
	end
	local model, rootPart = siteModel, siteRoot
	if model == nil or rootPart == nil then
		-- CHANGED (Review 3): the Quality tier's content in every pocket (Quality.onChanged drops the copy)
		local built, builtRoot = buildSiteCopy(Quality.tier()) -- CHANGED (Night review)
		model, rootPart = built, builtRoot
		siteModel, siteRoot = built, builtRoot
		siteRootBase = builtRoot.CFrame
		siteRecords = collectScaleRecords(built) -- CHANGED (Night review): before SiteLights unparents lights
		siteScale = 1
		siteUntrackLights = SiteLights.track(built) -- CHANGED (Night review): lights on High only
		if siteTint then
			tintSite(built, true) -- CHANGED (Far slabs fix): the /bands view
		end
	end
	assert(model and rootPart)
	-- CHANGED (Night review): drawn like the terrain under it (at or a step in front of its scale factor)
	-- CHANGED (Terrain polish): ... and in front of every scaled band behind it (siteWantedScale)
	local scale = TerrainMath.scaleStep(wantedScale, siteScale, SITE_SCALE_RATIO)
	local records = siteRecords
	if scale ~= siteScale and records then
		applySiteScale(records, scale)
		siteScale = scale
		siteLastTransform = nil
	end
	local m = siteTransform(ctx.frame, ctx.ut)
	if model.Parent ~= parent then
		model.Parent = parent
		siteLastTransform = nil
	end
	local camera = ctx.camera.Position
	if siteLastTransform ~= m or (siteScale < 1 and siteLastCamera ~= camera) then
		-- CHANGED (Night review): only the root moves; the welded parts follow (was 1004 CFrames + BulkMoveTo)
		-- CHANGED (Night review): scaled about the camera when the copy is scaled (same image, nearer)
		local pose = m * siteRootBase
		if siteScale < 1 then
			pose = CFrame.new(camera + (pose.Position - camera) * siteScale) * pose.Rotation
		end
		rootPart.CFrame = pose
		siteLastTransform = m
		siteLastCamera = camera
	end
	return nil
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
	-- CHANGED (Night review): the site at true scale; CHANGED (Review 3): + SITE_KEEP_RANGE
	TerrainMesh.keepNear(Bodies.HOMEWORLD, SITE_POS, SITE_KEEP_HALF, SITE_KEEP_RANGE)
	TerrainCollision.init(parent)
	SurfaceProps.init(parent)
	SurfaceProps.setGroundFilter(TerrainMesh.isTrueScaleAt) -- CHANGED (Night review): props on true-scale ground only
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
	-- CHANGED (Review 3): + the scaled ground hidden under the real base's plate (near the site, base pocket)
	TerrainMesh.hideScaledAt(updateSite(ctx, surfaceMode))
	-- props only while the terrain around the camera is drawn at true scale
	-- CHANGED (Night review): and only on chunks over true-scale ground (the ground filter), re-checked on changes
	SurfaceProps.update(ctx, surfaceMode and TerrainMesh.isTrueScaleAt(ctx.cameraDominant, 0), TerrainMesh.version())
end

-- CHANGED (Phase 8): builds (without drawing) the ground around ctx's camera; the main menu calls this for the base.
function Surface.prebuild(ctx: RenderContext.RenderContext)
	TerrainMesh.update(ctx, false, true)
end

-- CHANGED (Terrain polish): whether the ground is on screen as meshes (or can only be plates); the main menu holds
-- its Play fade on it.
function Surface.isReady(): boolean
	return TerrainMesh.isReady()
end

-- CHANGED (Memory budget): the terrain around the camera is built (ScaledSpace holds its other textures until then).
function Surface.isSettled(): boolean
	return TerrainMesh.isSettled()
end

-- CHANGED (Memory budget): "Menu" / "Cover" (the main menu / its black cover is up: build the ground faster) / nil.
function Surface.setLoadBoost(mode: string?)
	TerrainMesh.setLoadBoost(mode)
end

-- CHANGED (Phase 8): F3 debug line.
-- CHANGED (Far slabs fix): + the /bands legend while that view is on
function Surface.summary(): string
	return TerrainMesh.summary()
		.. string.format("  colliders %d", TerrainCollision.partCount())
		.. (
			if siteTint
				then "\n/bands: near = own colours, 1 blue, 2 red, 3 yellow, 4+ magenta, plates white, site cyan"
				else ""
		)
end

--[[
	CHANGED (Far slabs fix): the /bands debug view (chat command, DebugService -> DebugView remote): each terrain band
	in a flat colour (TerrainMesh.setDebugTint), the fallback plates white and the launch-site copy cyan, so a
	screenshot shows which band draws what. Toggles; off by default (nothing is created while off).
]]
function Surface.setDebugTint(on: boolean)
	siteTint = on
	TerrainMesh.setDebugTint(on)
	local model = siteModel
	if model then
		tintSite(model, on)
	end
end

function Surface.debugTint(): boolean
	return siteTint
end

-- Test hook: pure helpers for the offline tests.
Surface._test = table.freeze({
	siteTransform = siteTransform,
	siteFrame = SITE_FRAME,
	sitePos = SITE_POS,
	buildSiteCopy = buildSiteCopy, -- CHANGED (Night review)
	plateOutline = SITE_PLATE_OUTLINE, -- CHANGED (Review 3)
	PROPS_BY_TIER = PROPS_BY_TIER, -- CHANGED (Night review)
})

return table.freeze(Surface)
