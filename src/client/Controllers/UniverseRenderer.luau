--!strict
--[[
	UniverseRenderer (spec 7.6)
	Once per render frame, after the camera has moved: refresh the pocket frame (PocketController), build the
	RenderContext and hand it to every render layer in order:
	  ScaledSpace          sun, planets and moons as scaled proxies (and the surface-mode handover)
	  Surface              the tile cap under the camera and the cosmetic Oopsie Point copy
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
local hiddenLayers: { Instance } = {}
local hiddenParents: { Instance? } = {}

local ctx: RenderContext = {
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
	local cameraCF = if mapMode then CFrame.new(frame.slotOrigin) else camera.CFrame
	local cameraAbs = Frames.pointFromWorkspace(frame, cameraCF.Position, ctx.cameraAbs)
	local dominantId, cameraDominant = dominantBody(frame.refBodyId, cameraAbs, ut)

	ctx.frame = frame
	ctx.ut = ut
	ctx.camera = cameraCF
	ctx.cameraAbs = cameraAbs
	ctx.dominantBodyId = dominantId
	ctx.cameraDominant = cameraDominant
	ctx.altitude = Vec3d.length(cameraDominant) - Bodies.get(dominantId).Radius
	ctx.sunDirection = Frames.vectorToWorkspace(frame, Universe.sunDirection(ut)).Unit
	ctx.pocketId = PocketController.pocketId()
	ctx.drawDistance = drawDistance
	ctx.dt = dt

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
		Bodies.get(dominantId).DisplayName,
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
		table.clear(hiddenLayers)
		table.clear(hiddenParents)
		local candidates: { Instance? } = {
			if layerRoot then layerRoot:FindFirstChild("ScaledSpace") else nil,
			if layerRoot then layerRoot:FindFirstChild("Surface") else nil,
			Workspace:FindFirstChild("RemoteCrafts"),
			Effects.folder(), -- CHANGED (Phase 10)
		}
		for _, layer in candidates do
			if layer then
				table.insert(hiddenLayers, layer)
				table.insert(hiddenParents, layer.Parent)
				layer.Parent = nil
			end
		end
		SkyCube.setOverride(1, cubeHalfSize)
	else
		for index, layer in hiddenLayers do
			layer.Parent = hiddenParents[index]
		end
		table.clear(hiddenLayers)
		table.clear(hiddenParents)
		SkyCube.setOverride(nil)
	end
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
