--!strict
--[[
	UniverseRenderer (spec 7.6)
	Once per render frame, after the camera has moved: refresh the pocket frame (PocketController), build the
	RenderContext and hand it to every render layer in order:
	  ScaledSpace          sun, planets and moons as scaled proxies (and the surface-mode handover)
	  Surface              the tile cap under the camera and the cosmetic Space Disasters Inc. copy
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

	CHANGED (Phase 11): view override for the main menu (setViewOverride, driven by Render/MenuScene). While a frame
	is set, ScaledSpace, Surface, SkyCube (automatic opacity) and SkyLighting are drawn with THAT frame and the real
	camera CFrame, so Earth, the Mun and Sol appear around the menu camera, seen from a viewpoint in space. The
	RemoteCrafts copies and the Effects folder are hidden like in map mode (effects keep ageing with the pocket's
	own context). The pocket frame itself is untouched. Layers hidden by the map view and by the override are
	tracked per reason, so either can end first.

	API:
	  UniverseRenderer.setMapMode(enabled, cubeHalfSize?)   MapViewController
	  UniverseRenderer.isMapMode() -> boolean
	  UniverseRenderer.drawDistance() -> number
	  UniverseRenderer.setViewOverride(frame?)              CHANGED (Phase 11): nil restores the normal view
	  UniverseRenderer.hasViewOverride() -> boolean         CHANGED (Phase 11)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local DebugOverlay = require(script.Parent.DebugOverlay)
local Effects = require(script.Parent.Parent.Render.Effects) -- CHANGED (Phase 10)
local PocketController = require(script.Parent.PocketController)
local RemoteCraftRenderer = require(script.Parent.RemoteCraftRenderer)
local RenderContext = require(script.Parent.Parent.Render.RenderContext)
local ScaledSpace = require(script.Parent.Parent.Render.ScaledSpace)
local SkyCube = require(script.Parent.Parent.Render.SkyCube)
local SkyLighting = require(script.Parent.Parent.Render.SkyLighting)
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
	drawDistance = DRAW_DISTANCE_BY_QUALITY[level] or DEFAULT_DRAW_DISTANCE
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
	target.sunDirection = Frames.vectorToWorkspace(frame, Universe.sunDirection(ut)).Unit
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
	fillContext(viewCtx, override, camera.CFrame, ctx.ut, dt)
	timed("ScaledSpace", function()
		ScaledSpace.update(viewCtx)
	end)
	timed("Surface", function()
		Surface.update(viewCtx, ScaledSpace.isSurfaceMode())
	end)
	SkyCube.update(viewCtx, ScaledSpace.isSurfaceMode(), ScaledSpace.proxyMinAltitude(viewCtx.dominantBodyId))
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

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	refreshDrawDistance(dt)
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
			SkyLighting.update(ctx)
		end)
		-- CHANGED (Phase 10): effects keep ageing (their folder is hidden in map view)
		timed("Effects", function()
			Effects.step(ctx, PocketController.frameVelocity())
		end)
		lastSummary = "Universe: map view"
		return
	end

	timed("ScaledSpace", function()
		ScaledSpace.update(ctx)
	end)
	timed("Surface", function()
		Surface.update(ctx, ScaledSpace.isSurfaceMode())
	end)
	-- CHANGED (Phase 2a playtest 4): black starry space in front of Roblox's sky
	SkyCube.update(ctx, ScaledSpace.isSurfaceMode(), ScaledSpace.proxyMinAltitude(ctx.dominantBodyId))
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
]]
function UniverseRenderer.setViewOverride(frame: Frames.Frame?)
	local wasSet = viewOverride ~= nil
	viewOverride = frame
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
	-- EditableMesh creation can yield; the update is a no-op until init finishes.
	task.spawn(ScaledSpace.init, scaledFolder)

	DebugOverlay.addLine("universe", 22, function()
		return lastSummary
	end)
	DebugOverlay.addLine("effects", 24.5, Effects.summary) -- CHANGED (Phase 10): after "map" (24)
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
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
end

return UniverseRenderer
