--!strict
--[[
	FlightController (spec 7.4, 7.11)
	The pilot's side of flying: input, the local FlightModel simulation of the piloted craft, staging (predicted
	locally, confirmed by the server), crash reports, the PilotState stream (20 Hz), the flight HUD, the chase
	camera and the local craft's engine plumes.

	Piloting = sitting in a craft's pilot seat (Seat with IsPilot).
	  CHANGED (Phase 2a feedback): sitting in the pilot seat starts the flight (the server hands this client the
	  simulation with no stage fired), so on the pad the rocket already has real physics and every control works;
	  Space ignites stage 1. F before ignition puts the craft back on the pad (server side).
	  (Fallback: if the craft is still "Prelaunch", Space asks the server to start the flight.)
	  In flight: the server's FlightStart hands this client the simulation. Controls: W/S pitch, A/D yaw,
	  Q/E roll, Shift/Ctrl throttle up/down, Z full, X cut, Space stage, T SAS, V camera, F leave seat.
	The simulation keeps running while this client owns it, even if the pilot stands up (controls go to zero).
	Passengers get a HUD from the streamed state.
]]

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Atmosphere = require(ReplicatedStorage.Shared.Sim.Atmosphere)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftGraph = require(ReplicatedStorage.Shared.Craft.CraftGraph)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MassProps = require(ReplicatedStorage.Shared.Craft.MassProps)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local ChaseCamera = require(script.Parent.Parent.Render.ChaseCamera)
local FlightHUD = require(script.Parent.Parent.UI.FlightHUD)
local HudData = require(script.Parent.Parent.Render.HudData)
local Plumes = require(script.Parent.Parent.Render.Plumes)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local DebugOverlay = require(script.Parent.DebugOverlay)
local PocketController = require(script.Parent.PocketController)
local RemoteCraftRenderer = require(script.Parent.RemoteCraftRenderer)

type Craft = FlightModel.Craft
type State = FlightModel.CraftState

--============================================================================
-- Tunables
--============================================================================
local STEP = FlightModel.STEP
local MAX_STEPS_PER_FRAME = GameConfig.SIM_MAX_STEPS_PER_FRAME
local SEND_INTERVAL = 1 / GameConfig.PILOT_STATE_RATE
local THROTTLE_RATE = GameConfig.THROTTLE_RATE
local UT_RESYNC_THRESHOLD = 0.25 -- s; the local sim's UT snaps to UniverseTime beyond this drift
local STAGE_STATS_INTERVAL = 0.5 -- s
local ACTION_PRIORITY = Enum.ContextActionPriority.High.Value + 10
-- CHANGED (Phase 2a feedback): camera "up" is gravity up low down and the solar plane's normal in space
local CAMERA_GRAVITY_UP_MIN_ALT = 2000 -- m; gravity up below max(this, atmosphere top)
local CAMERA_UP_BLEND_HEIGHT = 3000 -- m above that over which up blends to the solar-plane normal
local SOLAR_PLANE_NORMAL = Vector3.yAxis -- universe axes: every orbit lies in the XZ plane
local FLIGHT_KEYS = {
	Enum.KeyCode.W,
	Enum.KeyCode.A,
	Enum.KeyCode.S,
	Enum.KeyCode.D,
	Enum.KeyCode.Q,
	Enum.KeyCode.E,
	Enum.KeyCode.LeftShift,
	Enum.KeyCode.LeftControl,
	Enum.KeyCode.Z,
	Enum.KeyCode.X,
	Enum.KeyCode.T,
	Enum.KeyCode.G, -- CHANGED (Phase 2a remodel): landing legs up / down
	Enum.KeyCode.V,
	Enum.KeyCode.F,
	Enum.KeyCode.Space,
}
--============================================================================

local FlightController = {}

local player = Players.LocalPlayer
local remotes: { [string]: RemoteEvent } = {}
local pilotStateRemote: UnreliableRemoteEvent
local hud: FlightHUD.FlightHUD

local craftId: number? = nil -- craft this client simulates
local sim: Craft? = nil
local accumulator = 0
local sendTimer = 0
local throttle = 1
local sasOn = false
local chaseEnabled = true
local bound = false
local stageStatsTimer = 0
local stageStatsCache: { MassProps.StageStat } = {}
local predictedHidden: { [number]: boolean } = {} -- blocks hidden locally until the server removes them

--============================================================================
-- Seat detection
--============================================================================

type SeatInfo = { craftModel: Model, craftId: number, isPilot: boolean, state: string }

local function currentSeat(): SeatInfo?
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local seat = if humanoid then humanoid.SeatPart else nil
	if seat == nil then
		return nil
	end
	local node: Instance? = seat
	while node and node:GetAttribute("CraftId") == nil do
		node = node.Parent
	end
	if node == nil or not node:IsA("Model") then
		return nil
	end
	local id = node:GetAttribute("CraftId")
	local state = node:GetAttribute("State")
	return {
		craftModel = node,
		craftId = id :: number,
		isPilot = seat:GetAttribute("IsPilot") == true,
		state = if type(state) == "string" then state else "Prelaunch",
	}
end

local function craftModelById(id: number): Model?
	local pockets = workspace:FindFirstChild("Pockets")
	if pockets == nil then
		return nil
	end
	for _, pocket in pockets:GetChildren() do
		local crafts = pocket:FindFirstChild("Crafts")
		local model = if crafts then crafts:FindFirstChild(`Craft_{id}`) else nil
		if model and model:IsA("Model") then
			return model
		end
	end
	return nil
end

--============================================================================
-- Input
--============================================================================

local function axis(positive: Enum.KeyCode, negative: Enum.KeyCode): number
	local value = 0
	if UserInputService:IsKeyDown(positive) then
		value += 1
	end
	if UserInputService:IsKeyDown(negative) then
		value -= 1
	end
	return value
end

local function hideBlocksLocally(ids: { number })
	local model = if craftId then craftModelById(craftId :: number) else nil
	for _, id in ids do
		predictedHidden[id] = true
		local block = if model then CraftBuilder.findBlockModel(model, id) else nil
		if block then
			for _, part in block:GetDescendants() do
				if part:IsA("BasePart") then
					part.LocalTransparencyModifier = 1
					part.CanCollide = false
				end
			end
		end
	end
end

local function stage()
	local seatInfo = currentSeat()
	if seatInfo == nil or not seatInfo.isPilot then
		return
	end
	if seatInfo.state == "Prelaunch" then
		remotes.RequestStage:FireServer(seatInfo.craftId)
		return
	end
	local craft = sim
	if craft == nil or craftId ~= seatInfo.craftId then
		return
	end
	-- predict locally; the server repeats the same deterministic stage and confirms with CraftStaged
	local result = FlightModel.stage(craft)
	if result then
		for _, debris in result.debris do
			hideBlocksLocally(debris.blockIds)
		end
		stageStatsTimer = STAGE_STATS_INTERVAL
	end
	remotes.RequestStage:FireServer(seatInfo.craftId)
end

local function onAction(
	_actionName: string,
	inputState: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	if inputState ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Sink
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.Space then
		stage()
	elseif key == Enum.KeyCode.T then
		sasOn = not sasOn
	elseif key == Enum.KeyCode.G then
		local craft = sim
		if craft then
			FlightModel.setGearUp(craft, not FlightModel.isGearUp(craft.state.flags))
		end
	elseif key == Enum.KeyCode.Z then
		throttle = 1
	elseif key == Enum.KeyCode.X then
		throttle = 0
	elseif key == Enum.KeyCode.V then
		chaseEnabled = not chaseEnabled
	elseif key == Enum.KeyCode.F then
		remotes.LeaveSeat:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local function bindKeys(enable: boolean)
	if enable == bound then
		return
	end
	bound = enable
	if enable then
		ContextActionService:BindActionAtPriority(
			"SpaceDisastersFlight",
			onAction,
			false,
			ACTION_PRIORITY,
			table.unpack(FLIGHT_KEYS)
		)
	else
		ContextActionService:UnbindAction("SpaceDisastersFlight")
	end
end

--============================================================================
-- Simulation
--============================================================================

local function applyControls(craft: Craft, dt: number, piloting: boolean)
	if piloting and not UserInputService:GetFocusedTextBox() then
		throttle =
			math.clamp(throttle + axis(Enum.KeyCode.LeftShift, Enum.KeyCode.LeftControl) * THROTTLE_RATE * dt, 0, 1)
		FlightModel.setControls(
			craft,
			axis(Enum.KeyCode.W, Enum.KeyCode.S),
			axis(Enum.KeyCode.D, Enum.KeyCode.A),
			axis(Enum.KeyCode.E, Enum.KeyCode.Q),
			throttle,
			sasOn
		)
	else
		FlightModel.setControls(craft, 0, 0, 0, throttle, sasOn)
	end
end

local function reportDestroyed(craft: Craft)
	if #craft.destroyed == 0 or craftId == nil then
		return
	end
	local destroyed = craft.destroyed
	craft.destroyed = {}
	remotes.ReportPartsDestroyed:FireServer(craftId, destroyed, craft.state.ut)
	local _, originLost = FlightModel.removeBlocks(craft, destroyed)
	hideBlocksLocally(destroyed)
	if originLost then
		sim = nil
	end
end

local function stepSimulation(dt: number)
	local craft = sim
	if craft == nil then
		return
	end
	local seatInfo = currentSeat()
	local piloting = seatInfo ~= nil and seatInfo.isPilot and seatInfo.craftId == craftId
	accumulator += dt
	local steps = 0
	while accumulator >= STEP and steps < MAX_STEPS_PER_FRAME do
		applyControls(craft, STEP, piloting)
		FlightModel.step(craft)
		reportDestroyed(craft)
		if sim == nil then
			return
		end
		accumulator -= STEP
		steps += 1
	end
	if steps >= MAX_STEPS_PER_FRAME then
		accumulator = 0 -- drop the backlog instead of spiralling
	end
	-- keep simulation time locked to Universal Time
	local now = UniverseTime.now()
	if math.abs(craft.state.ut - now) > UT_RESYNC_THRESHOLD then
		craft.state.ut = now
	end
	sendTimer += dt
	if sendTimer >= SEND_INTERVAL and craftId then
		sendTimer = 0
		pilotStateRemote:FireServer(
			Protocol.encodePilotState(craftId :: number, craft.state, FlightModel.totalFuel(craft))
		)
	end
end

--============================================================================
-- HUD data
--============================================================================

local function refreshStageStats(craft: Craft)
	local stats =
		MassProps.stageStats(craft.physics.graph, GameConfig.G0, Bodies.get(craft.state.bodyId).SurfaceGravity)
	-- stageStats assumes full tanks; scale by what is left overall
	local fraction = FlightModel.remainingFuelFraction(craft)
	for _, stat in stats do
		stat.dvVac *= fraction
		stat.dvAsl *= fraction
	end
	stageStatsCache = stats
end

local function hudFromState(state: Protocol.State, name: string, isPilot: boolean, craft: Craft?): HudData.HudData
	local body = Bodies.get(state.bodyId)
	local r = Vec3d.length(state.pos)
	local altitude = r - body.Radius
	local up = Vec3d.scale(state.pos, 1 / r)
	local radar = SurfaceHeight.height(state.bodyId, state.pos)
	local speed = Vec3d.length(state.vel)
	local pressure = Atmosphere.pressureRatio(state.bodyId, altitude)
	local data: HudData.HudData = {
		craftName = name,
		isPilot = isPilot,
		-- CHANGED (Phase 2a feedback): "on the pad" = simulating but nothing ignited yet
		prelaunch = craft ~= nil and isPilot and craft.stageIndex == 1,
		countdown = nil,
		bodyName = body.DisplayName,
		altitude = altitude,
		radarAltitude = radar,
		verticalSpeed = Vec3d.dot(state.vel, up),
		surfaceSpeed = speed,
		orbitalSpeed = speed,
		throttle = state.throttle,
		sas = bit32.band(state.flags, FlightModel.FLAG_SAS) ~= 0,
		twr = 0,
		dvRemaining = 0,
		stages = {},
		burning = bit32.band(state.flags, FlightModel.FLAG_BURNING) ~= 0,
		inAtmosphere = Atmosphere.isInside(state.bodyId, altitude),
		pressure = pressure,
	}
	if craft then
		local thrust = 0
		for _, engine in craft.physics.engines do
			if craft.active[engine.blockId] then
				thrust += Parts.thrustAt(engine.stats, pressure, GameConfig.G0)
			end
		end
		local g = body.Mu / (r * r)
		data.twr = thrust / (craft.mass * g)
		local total = 0
		for index, stat in stageStatsCache do
			if index >= craft.stageIndex - 1 then
				total += stat.dvVac
			end
		end
		data.dvRemaining = total
		for stageNumber = craft.stageIndex, #craft.stages do
			local stat = stageStatsCache[stageNumber]
			table.insert(data.stages, {
				stage = stageNumber,
				dvVac = if stat then stat.dvVac else 0,
				fuelFraction = FlightModel.remainingFuelFraction(craft),
				isNext = stageNumber == craft.stageIndex,
			})
		end
	end
	return data
end

local function hudData(): HudData.HudData?
	local seatInfo = currentSeat()
	local craft = sim
	if craft and craftId then
		local model = craftModelById(craftId :: number)
		local name = if model then (model:GetAttribute("DesignName") or model.Name) :: string else "Craft"
		return hudFromState(craft.state, name, seatInfo ~= nil and seatInfo.isPilot, craft)
	end
	if seatInfo then
		if seatInfo.state == "Prelaunch" or seatInfo.state == "Launching" then
			local design = CraftBuilder.readDesign(seatInfo.craftModel)
			local name = (seatInfo.craftModel:GetAttribute("DesignName") or "Craft") :: string
			local body = Bodies.get(Bodies.HOMEWORLD)
			local stats = MassProps.stageStats(CraftGraph.build(design), GameConfig.G0, body.SurfaceGravity)
			local stages = {}
			local total = 0
			for _, stat in stats do
				total += stat.dvVac
				table.insert(
					stages,
					{ stage = stat.stage, dvVac = stat.dvVac, fuelFraction = 1, isNext = stat.stage == 1 }
				)
			end
			return {
				craftName = name,
				isPilot = seatInfo.isPilot,
				prelaunch = seatInfo.state == "Prelaunch",
				countdown = if seatInfo.state == "Launching" then 1 else nil,
				bodyName = body.DisplayName,
				altitude = 0,
				radarAltitude = 0,
				verticalSpeed = 0,
				surfaceSpeed = 0,
				orbitalSpeed = 0,
				throttle = throttle,
				sas = sasOn,
				twr = if stats[1] then stats[1].twrAsl else 0,
				dvRemaining = total,
				stages = stages,
				burning = false,
				inAtmosphere = true,
				pressure = 1,
			}
		end
		-- passenger in flight: streamed state
		local state = RemoteCraftRenderer.sampleState(seatInfo.craftId, UniverseTime.now() - GameConfig.INTERP_DELAY)
		if state then
			return hudFromState(
				state,
				(seatInfo.craftModel:GetAttribute("DesignName") or "Craft") :: string,
				false,
				nil
			)
		end
	end
	return nil
end

--============================================================================
-- Camera and plumes
--============================================================================

-- CHANGED (Phase 2a feedback): the camera orbits in universe axes with a gravity / solar-plane up (ChaseCamera).
local function cameraUp(frame: Frames.Frame): Vector3
	local body = Bodies.get(frame.refBodyId)
	local r = Vec3d.length(frame.refPos)
	if r < 1 then
		return SOLAR_PLANE_NORMAL
	end
	local radial = Vec3d.toVector3(Vec3d.scale(frame.refPos, 1 / r))
	local atmosphere = body.Atmosphere
	local low = math.max(CAMERA_GRAVITY_UP_MIN_ALT, if atmosphere then atmosphere.Top else 0)
	local t = math.clamp((r - body.Radius - low) / CAMERA_UP_BLEND_HEIGHT, 0, 1)
	t = t * t * (3 - 2 * t) -- smoothstep
	local up = radial:Lerp(SOLAR_PLANE_NORMAL, t)
	if up.Magnitude < 1e-3 then
		return SOLAR_PLANE_NORMAL
	end
	return up.Unit
end

local function cameraTarget(): ChaseCamera.Target?
	local seatInfo = currentSeat()
	if seatInfo == nil then
		return nil
	end
	local com = if sim and craftId == seatInfo.craftId then (sim :: Craft).physics.com else Vector3.zero
	local position: Vector3
	local craftFrame = PocketController.primaryCraftCFrame()
	if craftFrame and seatInfo.state ~= "Prelaunch" then
		-- CHANGED (Phase 2a feedback, D31): the craft turns inside its horizon-aligned pocket
		position = craftFrame:PointToWorldSpace(com)
	else
		local model = seatInfo.craftModel
		local design = CraftBuilder.readDesign(model)
		local root = CraftDesign.rootBlock(design)
		local rootModel = if root then CraftBuilder.findBlockModel(model, root.id) else nil
		local bounds = if rootModel then rootModel.PrimaryPart else nil
		position = if bounds then (bounds :: BasePart).Position else model:GetBoundingBox().Position
	end
	local frame = PocketController.frame()
	return { position = position, up = cameraUp(frame), toWorkspace = frame.refRotInv }
end

local plumedModel: Model? = nil -- the real model this client last drew plumes on

-- CHANGED (Phase 2a feedback): each engine's flame follows exactly what the simulation does with that engine,
-- and every flame goes out when this client stops simulating the craft.
local function updatePlumes()
	local craft = sim
	local model = if craft and craftId then craftModelById(craftId :: number) else nil
	local previous = plumedModel
	if previous and previous ~= model then
		Plumes.clear(previous)
		plumedModel = nil
	end
	if craft == nil or model == nil then
		return
	end
	plumedModel = model
	local burning: { [number]: number } = {}
	for _, engine in craft.physics.engines do
		if FlightModel.engineBurning(craft, engine) then
			burning[engine.blockId] = FlightModel.engineThrottle(craft, engine)
		end
	end
	Plumes.update(model, burning)
end

--============================================================================
-- Network
--============================================================================

local function onFlightStart(id: unknown, stateBuffer: unknown, stagesFired: unknown, designBuffer: unknown)
	if type(id) ~= "number" or typeof(designBuffer) ~= "buffer" then
		return
	end
	local _, state = Protocol.decodeState(stateBuffer)
	local design = CraftDesign.fromBuffer(designBuffer :: buffer)
	if state == nil or design == nil then
		return
	end
	local craft = FlightModel.newCraft(design, state :: any)
	for _ = 1, if type(stagesFired) == "number" then stagesFired else 0 do
		FlightModel.stage(craft)
	end
	throttle = state.throttle
	sasOn = false
	accumulator = 0
	predictedHidden = {}
	craftId = id
	sim = craft
	stageStatsTimer = STAGE_STATS_INTERVAL
end

local function onOverride(id: unknown, stateBuffer: unknown, refuel: unknown)
	local craft = sim
	if craft == nil or id ~= craftId then
		return
	end
	if stateBuffer ~= nil then
		local _, state = Protocol.decodeState(stateBuffer)
		if state then
			craft.state = state :: any
			craft.sasTarget = nil
		end
	end
	if refuel == true then
		for blockId, amount in FlightModel.fullFuel(craft.physics.design) do
			craft.fuel[blockId] = amount
		end
		craft.mass = craft.physics.dryMass + FlightModel.totalFuel(craft)
	end
end

local function onStaged(id: unknown, stageIndex: unknown)
	local craft = sim
	if craft == nil or id ~= craftId or type(stageIndex) ~= "number" then
		return
	end
	-- the server fired a stage we did not predict (e.g. stage 1 at launch is replayed via FlightStart)
	while craft.stageIndex <= stageIndex do
		local result = FlightModel.stage(craft)
		if result == nil then
			break
		end
		for _, debris in result.debris do
			hideBlocksLocally(debris.blockIds)
		end
	end
end

local function onDestroyed(id: unknown, ids: unknown, _ut: unknown, pieces: unknown)
	local craft = sim
	if craft == nil or id ~= craftId or type(ids) ~= "table" then
		return
	end
	local missing = {}
	for _, blockId in ids :: { any } do
		if type(blockId) == "number" and craft.physics.blockPos[blockId] then
			table.insert(missing, blockId)
		end
	end
	if type(pieces) == "table" then
		for _, piece in pieces :: { any } do
			if type(piece) == "table" and type(piece.blockIds) == "table" then
				for _, blockId in piece.blockIds do
					if type(blockId) == "number" and craft.physics.blockPos[blockId] then
						table.insert(missing, blockId)
					end
				end
			end
		end
	end
	if #missing > 0 then
		local _, originLost = FlightModel.removeBlocks(craft, missing)
		if originLost then
			sim = nil
		end
	end
end

local function onRemoved(id: unknown)
	if id == craftId then
		sim = nil
		craftId = nil
	end
end

--============================================================================
-- Lifecycle
--============================================================================

function FlightController.Init()
	for _, name in { "RequestStage", "LeaveSeat", "ReportPartsDestroyed" } do
		remotes[name] = Remotes.event(name)
	end
	pilotStateRemote = Remotes.unreliable("PilotState")
	hud = FlightHUD.create()
	PocketController.registerPrimaryProvider(function(id: number): PocketController.PrimaryState?
		if sim and id == craftId then
			return (sim :: Craft).state
		end
		return nil
	end)
	DebugOverlay.addLine("flight", 21, function()
		local craft = sim
		if craft == nil then
			return "Flight: not simulating"
		end
		local s = craft.state
		return string.format(
			"Flight: craft %d  alt %.0f m  v %.1f m/s  fuel %.0f kg  stage %d/%d",
			craftId or 0,
			Vec3d.length(s.pos) - Bodies.get(s.bodyId).Radius,
			Vec3d.length(s.vel),
			FlightModel.totalFuel(craft),
			craft.stageIndex - 1,
			#craft.stages
		)
	end)
end

function FlightController.Start()
	Remotes.event("FlightStart").OnClientEvent:Connect(onFlightStart)
	Remotes.event("FlightOverride").OnClientEvent:Connect(onOverride)
	Remotes.event("CraftStaged").OnClientEvent:Connect(onStaged)
	Remotes.event("PartsDestroyed").OnClientEvent:Connect(onDestroyed)
	Remotes.event("CraftRemoved").OnClientEvent:Connect(onRemoved)

	RunService.PreSimulation:Connect(function(dt: number)
		local t0 = os.clock()
		stepSimulation(dt)
		DebugOverlay.recordTiming("FlightSim", (os.clock() - t0) * 1000)
	end)

	RunService.RenderStepped:Connect(function(dt: number)
		local seatInfo = currentSeat()
		local piloting = seatInfo ~= nil and seatInfo.isPilot
		bindKeys(piloting)
		-- CHANGED (Phase 2a feedback): everyone aboard a flying craft gets the level camera, not only the pilot
		local aboardFlying = seatInfo ~= nil and seatInfo.state ~= "Prelaunch"
		if aboardFlying and chaseEnabled then
			ChaseCamera.start(cameraTarget)
		elseif ChaseCamera.isActive() then
			ChaseCamera.stop()
		end
		local craft = sim
		if craft then
			stageStatsTimer += dt
			if stageStatsTimer >= STAGE_STATS_INTERVAL then
				stageStatsTimer = 0
				refreshStageStats(craft)
			end
		end
		hud.update(hudData())
		updatePlumes()
	end)
end

-- The craft this client simulates (pilot), or nil.
function FlightController.simulatedCraft(): (number?, Craft?)
	return craftId, sim
end

return FlightController
