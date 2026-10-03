--!strict
--[[
	UniverseRenderer (spec 7.6)
	Once per render frame, after the camera has moved: refresh the pocket frame (PocketController; CHANGED (Rocket
	shudder): already computed before the camera, this reuses it), build the RenderContext and hand it to every
	render layer in order:
	  ScaledSpace          sun, planets and moons as scaled proxies (and the surface-mode handover)
	  Surface              the ground under the camera (CHANGED Phase 8: heightmap terrain, collision near the player,
	                       props) and the cosmetic Space Disasters Inc. copy
	  SkyCube              black starry space in front of Roblox's sky above the air (CHANGED Phase 2a playtest 4)
	  SkyLighting          sun direction, shadow side and planet shadow
	  RemoteCraftRenderer  other crafts in this pocket (interpolated stream)
	  Effects              CHANGED (Phase 10): plumes, smoke trails, dust, separation, explosions, re-entry heat
	                       for every craft reported this frame (FlightController, RemoteCraftRenderer)

	All layers live under workspace.ClientUniverse, which exists only on this client.

	CHANGED (Phase 5): map mode (setMapMode, driven by MapViewController). The flight layers are hidden (the
	ScaledSpace and Surface folders and the RemoteCrafts copies are unparented and not updated) and the SkyCube
	becomes a fully opaque starry box of a fixed size around the map camera, in universe axes. SkyLighting keeps
	lighting the pocket as seen from the craft.
	CHANGED (Map planets): in map mode SkyLighting gives the map its flat light instead (SkyLighting.updateMap: the
	map's planets carry their own day / night shading, Render/MapBodies); the pocket is hidden behind the star box.

	CHANGED (Phase 11): view override for the main menu (setViewOverride, driven by Render/MenuScene). While a frame
	is set, ScaledSpace, Surface, SkyCube (automatic opacity) and SkyLighting are drawn with THAT frame and the real
	camera CFrame, so Earth, the Mun and Sol appear around the menu camera, seen from a viewpoint in space. The
	RemoteCrafts copies and the Effects folder are hidden like in map mode (effects keep ageing with the pocket's
	own context). The pocket frame itself is untouched. Layers hidden by the map view and by the override are
	tracked per reason, so either can end first.
	CHANGED (Phase 11 review): the override may carry its own UT (the main menu shows the universe at its own time so
	the Mun can be framed); the override's layers, SkyLighting included, are drawn at that UT.

	CHANGED (Steamy): the Physics-feel cloud deck was removed ("they look bad").

	CHANGED (Phase 8): Surface gets the dominant body's proxy handover altitude, so the terrain is built in the
	background before surface mode starts; under the main menu view the pocket's own ground (the base) is prebuilt.
	F3 shows a "Terrain:" line.

	CHANGED (Night review): mobile / quality pass. Automatic graphics quality on a phone / tablet assumes
	MOBILE_AUTOMATIC_DRAW_DISTANCE (Roblox draws much less far there than on a desktop's Automatic), and the real
	base's lights follow the Quality tier (Render/SiteLights.watchBase, started here).
	CHANGED (Night review): the main menu view is always drawn in scaled mode (ScaledSpace.update's forceScaled) with
	no surface: at quality 1 the proxy handover altitude (~10.4 km) is above the menu's 10 km viewpoint, which put
	the view in surface mode (no Earth) and made the view and the base prebuild drive the terrain with two cameras.

	API:
	  UniverseRenderer.setMapMode(enabled, cubeHalfSize?)   MapViewController
	  UniverseRenderer.isMapMode() -> boolean
	  UniverseRenderer.drawDistance() -> number
	  UniverseRenderer.setViewOverride(frame?, ut?)         CHANGED (Phase 11): nil restores the normal view;
	                                                        ut (Phase 11 review): the override's UT (default: renderUT)
	  UniverseRenderer.hasViewOverride() -> boolean         CHANGED (Phase 11)
]]

local Players = game:GetService("Players") -- CHANGED (Rocket shudder / orbit shadows): characters' shadows
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes) -- CHANGED (Far slabs fix): /bands
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local DebugOverlay = require(script.Parent.DebugOverlay)
local EditableBudget = require(script.Parent.Parent.Render.EditableBudget) -- CHANGED (Memory budget)
local Effects = require(script.Parent.Parent.Render.Effects) -- CHANGED (Phase 10)
local FarLayer = require(script.Parent.Parent.Render.FarLayer) -- CHANGED (Far layer): /farground
local PocketController = require(script.Parent.PocketController)
local RemoteCraftRenderer = require(script.Parent.RemoteCraftRenderer)
local RenderContext = require(script.Parent.Parent.Render.RenderContext)
local ScaledSpace = require(script.Parent.Parent.Render.ScaledSpace)
local ShadowGate = require(script.Parent.Parent.Render.ShadowGate) -- CHANGED (Rocket shudder / orbit shadows)
local SkyCube = require(script.Parent.Parent.Render.SkyCube)
local SkyLighting = require(script.Parent.Parent.Render.SkyLighting)
local Quality = require(script.Parent.Parent.Render.Quality) -- CHANGED (Night review)
local SiteLights = require(script.Parent.Parent.Render.SiteLights) -- CHANGED (Night review)
local Surface = require(script.Parent.Parent.Render.Surface)

--============================================================================
-- Tunables
--============================================================================
local RENDER_STEP_NAME = "UniverseRenderer"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 10 -- after ChaseCamera (Camera + 1)
local ROOT_NAME = "ClientUniverse"
local MAX_SOI_HOPS = 4 -- nested SOI checks per frame (sun -> planet -> moon needs 2)
-- Studs the engine keeps drawing at each saved graphics quality level (spike S11), keyed by
-- Enum.SavedQualitySetting.Value (0 = Automatic, which we treat as a mid-high level).
local DRAW_DISTANCE_BY_QUALITY: { [number]: number } = {
	[0] = 3000,
	[1] = 1250,
	[2] = 1400,
	[3] = 1500,
	[4] = 1500,
	[5] = 1500,
	[6] = 2200,
	[7] = 3000,
	[8] = 5000,
	[9] = 8000,
	[10] = 20000,
}
local DEFAULT_DRAW_DISTANCE = 3000
-- CHANGED (Night review): Automatic (level 0) on a phone / tablet (Quality.isMobile); Roblox picks a low level there
local MOBILE_AUTOMATIC_DRAW_DISTANCE = 1400
local QUALITY_POLL_S = 1
local HIDE_MAP = "Map" -- CHANGED (Phase 11): hide reasons (hideLayer)
local HIDE_MENU = "Menu"
--============================================================================

type RenderContext = RenderContext.RenderContext

local UniverseRenderer = {}

local userGameSettings = UserSettings():GetService("UserGameSettings")
local drawDistance = DEFAULT_DRAW_DISTANCE
local qualityTimer = math.huge
local lastSummary = "Universe: waiting for first frame"

-- CHANGED (Phase 5): map mode
local mapMode = false
local mapFrame = Frames.new(Bodies.HOMEWORLD, Vec3d.zero(), CFrame.identity, Vector3.zero, 0) -- map axes = universe
local layerRoot: Folder? = nil
-- CHANGED (Phase 11): each hidden layer keeps its parent and every reason it is hidden for (map view, main menu)
type HiddenLayer = { parent: Instance?, reasons: { [string]: boolean } }
local hiddenLayers: { [Instance]: HiddenLayer } = {}

-- CHANGED (Phase 11): main menu view override (setViewOverride)
local viewOverride: Frames.Frame? = nil
local viewOverrideUT: number? = nil -- CHANGED (Phase 11 review): the override's own UT (nil = the pocket's)

-- CHANGED (Phase 11): one factory for the pocket context and the menu view context
local function newContext(): RenderContext
	return {
		frame = PocketController.frame(),
		ut = 0,
		camera = CFrame.identity,
		cameraAbs = Vec3d.new(0, 0, 0),
		dominantBodyId = Bodies.HOMEWORLD,
		cameraDominant = Vec3d.new(0, 0, 0),
		altitude = 0,
		sunDirection = Vector3.yAxis,
		pocketId = 0,
		drawDistance = DEFAULT_DRAW_DISTANCE,
		dt = 0,
	}
end

local ctx: RenderContext = newContext()
local viewCtx: RenderContext = newContext() -- CHANGED (Phase 11): the main menu view

local function refreshDrawDistance(dt: number)
	qualityTimer += dt
	if qualityTimer < QUALITY_POLL_S then
		return
	end
	qualityTimer = 0
	local level = userGameSettings.SavedQualityLevel.Value
	if level == 0 and Quality.isMobile() then
		drawDistance = MOBILE_AUTOMATIC_DRAW_DISTANCE -- CHANGED (Night review)
	else
		drawDistance = DRAW_DISTANCE_BY_QUALITY[level] or DEFAULT_DRAW_DISTANCE
	end
end

-- Walks the SOI tree from the pocket's reference body to the body that actually contains the camera.
local function dominantBody(bodyId: number, pos: Vec3d.Vec3d, ut: number): (number, Vec3d.Vec3d)
	local current, rel = bodyId, pos
	for _ = 1, MAX_SOI_HOPS do
		local nextId, nextRel = Universe.soiTransition(current, rel, ut)
		if nextId == current then
			break
		end
		current, rel = nextId, nextRel
	end
	return current, rel
end

local function timed(name: string, fn: () -> ())
	local t0 = os.clock()
	fn()
	DebugOverlay.recordTiming(name, (os.clock() - t0) * 1000)
end

-- CHANGED (Phase 11): fills a context for `frame` seen from `cameraCF` (was inline in step)
local function fillContext(target: RenderContext, frame: Frames.Frame, cameraCF: CFrame, ut: number, dt: number)
	local cameraAbs = Frames.pointFromWorkspace(frame, cameraCF.Position, target.cameraAbs)
	local dominantId, cameraDominant = dominantBody(frame.refBodyId, cameraAbs, ut)

	target.frame = frame
	target.ut = ut
	target.camera = cameraCF
	target.cameraAbs = cameraAbs
	target.dominantBodyId = dominantId
	target.cameraDominant = cameraDominant
	target.altitude = Vec3d.length(cameraDominant) - Bodies.get(dominantId).Radius
	-- CHANGED (Solar system): from the camera toward Sol's real position (Earth's day / night is unchanged)
	target.sunDirection =
		Frames.vectorToWorkspace(frame, Universe.sunDirectionFrom(frame.refBodyId, cameraAbs, ut)).Unit
	target.pocketId = PocketController.pocketId()
	target.drawDistance = drawDistance
	target.dt = dt
end

-- CHANGED (Phase 11): hides a layer for a reason (it stays hidden until every reason is gone)
local function hideLayer(layer: Instance?, reason: string)
	if layer == nil then
		return
	end
	local entry = hiddenLayers[layer]
	if entry == nil then
		entry = { parent = layer.Parent, reasons = {} }
		hiddenLayers[layer] = entry
		layer.Parent = nil
	end
	assert(entry)
	entry.reasons[reason] = true
end

-- CHANGED (Phase 11): drops one hide reason everywhere and re-parents the layers nothing hides any more
local function showLayers(reason: string)
	for layer, entry in hiddenLayers do
		if entry.reasons[reason] then
			entry.reasons[reason] = nil
			if next(entry.reasons) == nil then
				hiddenLayers[layer] = nil
				layer.Parent = entry.parent
			end
		end
	end
end

-- CHANGED (Phase 11): the main menu view (header): the universe drawn from the override frame around the camera
local function stepViewOverride(override: Frames.Frame, camera: Camera, dt: number)
	fillContext(viewCtx, override, camera.CFrame, viewOverrideUT or ctx.ut, dt) -- CHANGED (Phase 11 review): own UT
	timed("ScaledSpace", function()
		-- CHANGED (Night review): always scaled here. At quality 1 the handover altitude (~10.4 km) is above the
		-- view's 10 km, so the menu lost Earth and the terrain was driven by two cameras (this view and the base's
		-- prebuild below), rebuilding forever.
		ScaledSpace.update(viewCtx, true)
	end)
	timed("Surface", function()
		-- CHANGED (Night review): no surface in the menu view (surfaceMode false): only the prebuild drives the terrain
		Surface.update(viewCtx, false, nil, false) -- CHANGED (Phase 8): never prebuilds here
		Surface.prebuild(ctx) -- CHANGED (Phase 8): the ground the player returns to (the base) is ready after Play
	end)
	SkyCube.update(viewCtx, false, ScaledSpace.proxyMinAltitude(viewCtx.dominantBodyId)) -- CHANGED (Night review)
	timed("SkyLighting", function()
		SkyLighting.update(viewCtx)
	end)
	-- effects keep ageing in the pocket (their folder is hidden)
	timed("Effects", function()
		Effects.step(ctx, PocketController.frameVelocity())
	end)
	lastSummary = string.format(
		"Universe: main menu view  alt %.0f m  %s",
		viewCtx.altitude,
		if ScaledSpace.isSurfaceMode() then "surface" else "scaled"
	)
end

--[[
	CHANGED (Rocket shudder / orbit shadows): Steamy in orbit: "still a shaddow forming" (five rocket-shaped shadows on
	the planet). Above the handover the ground is a ScaledSpace proxy (and its nested atmosphere shells) a few hundred
	studs away, and the true-scale craft's sun shadow fell on it and on every shell. While the ground is a proxy,
	nothing true-scale casts a shadow (Render/ShadowGate): this pocket's crafts, the RemoteCrafts folder (copies,
	markers, puppets), the effects and every player's character; back in surface mode every original CastShadow is
	restored, so shadows on the real terrain near the ground stay. Free in surface mode; in scaled mode a lookup per
	root and frame (parts are only touched on the mode change and when added).
]]
local shadowRoots: { Instance } = {}
local function updateShadowGate()
	-- never in the base pocket: it is always at the launch site (and its folder holds every plot: no sweep over it
	-- while ScaledSpace is still initialising and reports scaled mode)
	local scaled = not ScaledSpace.isSurfaceMode() and PocketController.pocketId() ~= 0
	if not scaled and not ShadowGate.isScaledMode() then
		return
	end
	table.clear(shadowRoots)
	if scaled then
		local pockets = Workspace:FindFirstChild("Pockets")
		local pocket = if pockets then pockets:FindFirstChild(`Pocket_{PocketController.pocketId()}`) else nil
		if pocket then
			table.insert(shadowRoots, pocket)
		end
		local remote = Workspace:FindFirstChild("RemoteCrafts")
		if remote then
			table.insert(shadowRoots, remote)
		end
		table.insert(shadowRoots, Effects.folder())
		for _, player in Players:GetPlayers() do
			local character = player.Character
			if character then
				table.insert(shadowRoots, character)
			end
		end
	end
	ShadowGate.setScaledMode(scaled, shadowRoots)
end

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	refreshDrawDistance(dt)
	-- CHANGED (EVA shake): computed once per render frame; on EVA EvaController already did it before the camera, so
	-- this reuses that frame (the astronaut, the crafts and the world are drawn with one frame and one render UT)
	-- CHANGED (Rocket shudder): PocketController now computes it itself at Camera - 2, before every camera, so this
	-- call only reuses that frame (the chase camera, the craft poses and the world share one render UT)
	PocketController.update()

	local frame = PocketController.frame()
	local ut = PocketController.renderUT()
	-- CHANGED (Phase 5): in map mode the universe is evaluated at the craft (the camera is at the map)
	-- CHANGED (Phase 11): same under the main menu view (the camera is at the menu scene)
	local override = viewOverride
	local cameraCF = if mapMode or override then CFrame.new(frame.slotOrigin) else camera.CFrame
	fillContext(ctx, frame, cameraCF, ut, dt) -- CHANGED (Phase 11): shared with the menu view

	-- CHANGED (Phase 11): main menu view
	if override then
		stepViewOverride(override, camera, dt)
		return
	end

	-- CHANGED (Phase 5): map mode: only the star box (around the map camera) and the pocket's lighting
	if mapMode then
		local mapCtx = table.clone(ctx)
		mapCtx.frame = mapFrame
		mapCtx.camera = camera.CFrame
		SkyCube.update(mapCtx, false, 0)
		timed("SkyLighting", function()
			SkyLighting.updateMap(ctx) -- CHANGED (Map planets): the map's flat light
		end)
		-- CHANGED (Phase 10): effects keep ageing (their folder is hidden in map view)
		timed("Effects", function()
			Effects.step(ctx, PocketController.frameVelocity())
		end)
		lastSummary = "Universe: map view"
		return
	end

	timed("ScaledSpace", function()
		-- CHANGED (Behind the ground): last frame's reach
		-- CHANGED (Far layer fix): or the far ground backdrop's panels (their farthest corner) while it is shown: a
		-- proxy beyond them is hidden by the picture's ground and seen through its clear sky (groundReach itself is 0
		-- then, for the SkyCube)
		ScaledSpace.setGroundReach(math.max(Surface.groundReach(), FarLayer.reach()))
		ScaledSpace.update(ctx)
	end)
	updateShadowGate() -- CHANGED (Rocket shudder / orbit shadows)
	timed("Surface", function()
		-- CHANGED (Phase 8): the handover altitude lets the terrain build before surface mode
		Surface.update(ctx, ScaledSpace.isSurfaceMode(), ScaledSpace.proxyMinAltitude(ctx.dominantBodyId))
	end)
	-- CHANGED (Phase 2a playtest 4): black starry space in front of Roblox's sky
	-- CHANGED (Far layer): + how far the 3D ground reaches (an airless body's sky is space on the ground too)
	SkyCube.update(
		ctx,
		ScaledSpace.isSurfaceMode(),
		ScaledSpace.proxyMinAltitude(ctx.dominantBodyId),
		Surface.groundReach()
	)
	timed("SkyLighting", function()
		SkyLighting.update(ctx)
	end)
	timed("RemoteCrafts", function()
		RemoteCraftRenderer.render(ctx)
	end)
	-- CHANGED (Phase 10): after the copies are posed, so attached effects follow them this frame
	timed("Effects", function()
		Effects.step(ctx, PocketController.frameVelocity())
	end)

	lastSummary = string.format(
		"Universe: near %s  alt %.0f m  %s  draw %d  base time %05.2f h",
		Bodies.get(ctx.dominantBodyId).DisplayName, -- CHANGED (Phase 11): the id now lives in ctx (fillContext)
		ctx.altitude,
		if ScaledSpace.isSurfaceMode() then "surface" else "scaled",
		drawDistance,
		Universe.baseHour(ctx.ut)
	)
end

--[[
	CHANGED (Phase 5): enters / leaves map mode. `cubeHalfSize` is the star box's half-size in studs while mapping.
]]
function UniverseRenderer.setMapMode(enabled: boolean, cubeHalfSize: number?)
	if enabled == mapMode then
		return
	end
	mapMode = enabled
	if enabled then
		-- CHANGED (Phase 11): hidden per reason (hideLayer / showLayers), so the menu view can overlap
		hideLayer(if layerRoot then layerRoot:FindFirstChild("ScaledSpace") else nil, HIDE_MAP)
		hideLayer(if layerRoot then layerRoot:FindFirstChild("Surface") else nil, HIDE_MAP)
		hideLayer(Workspace:FindFirstChild("RemoteCrafts"), HIDE_MAP)
		hideLayer(Effects.folder(), HIDE_MAP) -- CHANGED (Phase 10)
		SkyCube.setOverride(1, cubeHalfSize)
	else
		showLayers(HIDE_MAP) -- CHANGED (Phase 11)
		SkyCube.setOverride(nil)
	end
end

--[[
	CHANGED (Phase 11): the main menu view (header). `frame` maps the menu camera's surroundings to a viewpoint in
	space (Render/MenuScene updates it in place every frame, before this renderer's step); nil restores the normal
	view. While set, the other crafts' copies and the effects are hidden.
	CHANGED (Phase 11 review): `ut` is the UT the override view is drawn at (nil = the pocket's renderUT); MenuScene
	calls this every frame with its menu time.
]]
function UniverseRenderer.setViewOverride(frame: Frames.Frame?, ut: number?)
	local wasSet = viewOverride ~= nil
	viewOverride = frame
	viewOverrideUT = if frame then ut else nil -- CHANGED (Phase 11 review)
	if frame and not wasSet then
		hideLayer(Workspace:FindFirstChild("RemoteCrafts"), HIDE_MENU)
		hideLayer(Effects.folder(), HIDE_MENU)
	elseif frame == nil and wasSet then
		showLayers(HIDE_MENU)
	end
end

-- CHANGED (Phase 11)
function UniverseRenderer.hasViewOverride(): boolean
	return viewOverride ~= nil
end

function UniverseRenderer.isMapMode(): boolean
	return mapMode
end

-- CHANGED (Phase 5): draw distance (studs) at the current quality level, for the map view.
function UniverseRenderer.drawDistance(): number
	return drawDistance
end

--============================================================================
-- Lifecycle
--============================================================================

function UniverseRenderer.Init()
	local existing = Workspace:FindFirstChild(ROOT_NAME)
	if existing then
		existing:Destroy()
	end
	local root = Instance.new("Folder")
	root.Name = ROOT_NAME
	local scaledFolder = Instance.new("Folder")
	scaledFolder.Name = "ScaledSpace"
	scaledFolder.Parent = root
	local surfaceFolder = Instance.new("Folder")
	surfaceFolder.Name = "Surface"
	surfaceFolder.Parent = root
	root.Parent = Workspace
	layerRoot = root -- CHANGED (Phase 5)

	SkyLighting.init()
	Surface.init(surfaceFolder)
	Effects.init(root) -- CHANGED (Phase 10)
	task.spawn(SkyCube.init, root) -- paints star images (EditableImage)
	-- CHANGED (Memory budget): at join, ScaledSpace paints only the dominant body's base images until the terrain
	-- around the camera is built (the base under the main menu), so nothing hidden competes with the base's ground
	ScaledSpace.setExtrasGate(Surface.isSettled)
	-- EditableMesh creation can yield; the update is a no-op until init finishes.
	task.spawn(ScaledSpace.init, scaledFolder)

	DebugOverlay.addLine("universe", 22, function()
		return lastSummary
	end)
	DebugOverlay.addLine("effects", 24.5, Effects.summary) -- CHANGED (Phase 10): after "map" (24)
	DebugOverlay.addLine("terrain", 22.5, Surface.summary) -- CHANGED (Phase 8): after "universe" (22)
	DebugOverlay.addLine("farlayer", 22.6, FarLayer.details) -- CHANGED (Far layer fix): the backdrop's diagnostics
	DebugOverlay.addLine("editable", 22.7, EditableBudget.summary) -- CHANGED (Memory budget): Editable memory in use
end

function UniverseRenderer.Start()
	-- CHANGED (Phase 2a playtest 4): follow the server's /time sun offset
	local globals = ReplicatedStorage:WaitForChild("Globals")
	local function applySunOffset()
		local offset = globals:GetAttribute(Universe.SUN_OFFSET_ATTRIBUTE)
		Universe.setSunPhaseOffset(if type(offset) == "number" then offset else 0)
	end
	globals:GetAttributeChangedSignal(Universe.SUN_OFFSET_ATTRIBUTE):Connect(applySunOffset)
	applySunOffset()
	SiteLights.watchBase() -- CHANGED (Night review): the base's lamps and beacons on High only
	-- CHANGED (Far slabs fix): DebugService's /bands toggles the terrain band view (Surface.setDebugTint)
	Remotes.event("DebugView").OnClientEvent:Connect(function(view: unknown)
		if view == "bands" then
			Surface.setDebugTint(not Surface.debugTint())
		elseif view == "farground" then
			-- CHANGED (Far layer): far ground as the backdrop layer ("layer") or as scaled 3D bands ("mesh"); the
			-- terrain rebuilds its bands for the mode, the F3 "Terrain:" line shows it
			print("[Terrain] /farground: far ground drawn as " .. FarLayer.toggle())
		elseif view == "farground test" then
			-- CHANGED (Far layer fix): reference objects in the backdrop (turns the layer on); F3 / Output tell
			local on = FarLayer.toggleTest()
			print("[Terrain] /farground test: " .. (if on then "on (far ground: " .. FarLayer.mode() .. ")" else "off"))
		elseif view == "farground tex" then
			-- CHANGED (Far layer fix): the backdrop copies' white texture on / off
			print("[Terrain] /farground tex: white texture " .. (if FarLayer.toggleTexture() then "on" else "off"))
		end
	end)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
end

return UniverseRenderer
