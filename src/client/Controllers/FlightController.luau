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
	CHANGED (Phase 3): the simulation runs while this client is the craft's pilot. When the pilot leaves the seat in
	flight (or dies) the server takes the craft over and sends FlightEnd: this client stops simulating, seeds the
	stream buffer with its last local state, and from then on follows the craft like any passenger. Sitting back in
	the pilot seat hands it back (FlightStart with a `resume` table: the current design, stages, engines and fuel).
	Passengers get a HUD from the streamed state.

	CHANGED (Phase 5): rails (spec 7.8). After RAILS_IDLE_TIME without input while Rails.eligible (out of the air,
	no thrust, no contact, SAS settled), this client proposes a rail (RequestRails) and immediately follows it
	analytically: no integration and NO PilotState packets. Every SOI_CHECK_INTERVAL it mirrors SOI changes
	(Rails.advance); the server's CraftRails replaces the local rail. Any flight key, thrust, staging or reaching
	the rail's exitUT leaves rails at once: the simulation resumes from the rail's state and the next PilotState
	(newer than the rail's epoch) tells the server. A refusal (CraftOffRails) makes it wait RAILS_RETRY_S.
	The HUD also gets apoapsis / periapsis (Kepler) and the navball attitude.

	CHANGED (Phase 10): the own craft's effects go through Render/Effects: every frame the simulated craft is reported
	(model, design, state, burning engines; source "Local", so it wins over the stream), and predicted staging and
	crash reports call Effects.blockEvent (separation puffs, explosions) before the blocks are removed.
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
local Kepler = require(ReplicatedStorage.Shared.Sim.Kepler) -- CHANGED (Phase 5)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails) -- CHANGED (Phase 5)
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
local Effects = require(script.Parent.Parent.Render.Effects) -- CHANGED (Phase 10): replaces direct Plumes calls
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local DebugOverlay = require(script.Parent.DebugOverlay)
local MapViewController = require(script.Parent.MapViewController) -- CHANGED (Phase 5)
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
-- CHANGED (Phase 5): rails
local RAILS_IDLE_TIME = GameConfig.RAILS_IDLE_TIME
local RAILS_RETRY_S = GameConfig.RAILS_RETRY_S
local SOI_CHECK_INTERVAL = GameConfig.SOI_CHECK_INTERVAL
local HELD_INPUT_KEYS = {
	Enum.KeyCode.W,
	Enum.KeyCode.A,
	Enum.KeyCode.S,
	Enum.KeyCode.D,
	Enum.KeyCode.Q,
	Enum.KeyCode.E,
	Enum.KeyCode.LeftShift,
	Enum.KeyCode.LeftControl,
}
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
-- CHANGED (Phase 5): rails
local rails: Rails.Rails? = nil -- non-nil while the own craft follows a rail (proposed or confirmed)
local railsCheckUT = 0 -- UT of the last local SOI check on the rail
local idleTime = 0 -- s the craft has been eligible without input
local railsRetryAt = 0 -- os.clock() before which no new rail is proposed
local inputPulse = false -- a discrete flight key was pressed since the last simulation step
local leaveRails: () -> () -- defined in the rails section below (stage() needs it first)
local separationEffects: (craft: Craft) -> () -- CHANGED (Phase 10): defined next to stage()

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

-- CHANGED (Phase 10): separation puffs at the decouplers the next stage fires (call before FlightModel.stage).
separationEffects = function(craft: Craft)
	local id = craftId
	local next = craft.stages[craft.stageIndex]
	if id == nil or next == nil or #next.decouple == 0 then
		return
	end
	Effects.blockEvent(id :: number, "Separate", craft.physics.design, next.decouple, "Local")
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
	leaveRails() -- CHANGED (Phase 5): staging ends rails (the server does the same on RequestStage)
	separationEffects(craft) -- CHANGED (Phase 10)
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
	if key ~= Enum.KeyCode.V and key ~= Enum.KeyCode.F then
		inputPulse = true -- CHANGED (Phase 5): pilot input ends rails and restarts the idle timer
	end
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

--============================================================================
-- CHANGED (Phase 5): rails
--============================================================================

-- Leaves rails now: the simulation continues from the rail's state (no-op when not on rails).
leaveRails = function()
	local current = rails
	local craft = sim
	rails = nil
	idleTime = 0
	if current == nil or craft == nil then
		return
	end
	local now = UniverseTime.now()
	local s = Rails.stateAt(current, now)
	s.throttle = craft.state.throttle
	s.flags = craft.state.flags
	craft.state = s
	craft.sasTarget = nil
	accumulator = 0
	sendTimer = SEND_INTERVAL -- report right away: the server learns we left rails from the next PilotState
end

local function enterRails(craft: Craft)
	local id = craftId
	if id == nil then
		return
	end
	local proposal = Rails.fromState(FlightModel.copyState(craft.state), craft.physics.com, craft.controls.sas)
	rails = proposal
	railsCheckUT = proposal.epochUT
	idleTime = 0
	remotes.RequestRails:FireServer(Protocol.encodeRails(id :: number, proposal))
end

local function heldInput(piloting: boolean): boolean
	if not piloting or UserInputService:GetFocusedTextBox() then
		return false
	end
	for _, key in HELD_INPUT_KEYS do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
end

-- One frame on rails: returns false when the craft just left rails (the caller then simulates normally).
local function stepRails(craft: Craft, piloting: boolean, dt: number): boolean
	local current = rails :: Rails.Rails
	applyControls(craft, dt, piloting)
	local now = UniverseTime.now()
	local input = inputPulse or heldInput(piloting)
	inputPulse = false
	if input or Rails.wouldThrust(craft) or now >= current.exitUT then
		leaveRails()
		return false
	end
	if now - railsCheckUT >= SOI_CHECK_INTERVAL then
		local changed = Rails.advance(current, railsCheckUT, now)
		railsCheckUT = now
		if changed then
			current = changed
			rails = changed
		end
	end
	local s = Rails.stateAt(current, now)
	s.throttle = craft.state.throttle
	s.flags = bit32.band(craft.state.flags, bit32.bnot(bit32.bor(FlightModel.FLAG_BURNING, FlightModel.FLAG_CONTACT)))
	craft.state = s
	return true
end

local function reportDestroyed(craft: Craft)
	if #craft.destroyed == 0 or craftId == nil then
		return
	end
	local destroyed = craft.destroyed
	craft.destroyed = {}
	remotes.ReportPartsDestroyed:FireServer(craftId, destroyed, craft.state.ut)
	Effects.blockEvent(craftId :: number, "Explode", craft.physics.design, destroyed, "Local") -- CHANGED (Phase 10)
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
	-- CHANGED (Phase 5): on rails nothing is integrated or sent
	if rails and stepRails(craft, piloting, dt) then
		return
	end
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
	-- CHANGED (Phase 5): propose rails after RAILS_IDLE_TIME of eligible coasting without input
	local input = inputPulse or heldInput(piloting)
	inputPulse = false
	if not input and Rails.eligible(craft) then
		idleTime += dt
	else
		idleTime = 0
	end
	if idleTime >= RAILS_IDLE_TIME and os.clock() >= railsRetryAt then
		enterRails(craft)
		return
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

-- CHANGED (Phase 5): apoapsis / periapsis and navball inputs from a state.
local function orbitInfo(state: Protocol.State): (number?, number?, number?, number?, CFrame)
	local body = Bodies.get(state.bodyId)
	local horizon = Frames.surfaceRotation(state.pos)
	local landed = bit32.band(state.flags, FlightModel.FLAG_CONTACT) ~= 0 or Vec3d.length(state.vel) < 1
	if landed then
		return nil, nil, nil, nil, horizon
	end
	local el = Kepler.elements(body.Mu, state.pos, state.vel)
	local apoapsis = if el.kind == "Elliptic" then el.apoapsis - body.Radius else nil
	return apoapsis, el.periapsis - body.Radius, el.timeToApoapsis, el.timeToPeriapsis, horizon
end

local function hudFromState(
	state: Protocol.State,
	name: string,
	isPilot: boolean,
	craft: Craft?,
	onRails: boolean
): HudData.HudData
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
		-- CHANGED (Phase 5)
		apoapsis = nil,
		periapsis = nil,
		timeToApoapsis = nil,
		timeToPeriapsis = nil,
		onRails = onRails,
		attitude = state.rot,
		horizon = nil,
		velocity = Vec3d.toVector3(state.vel),
	}
	data.apoapsis, data.periapsis, data.timeToApoapsis, data.timeToPeriapsis, data.horizon = orbitInfo(state)
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
		return hudFromState(craft.state, name, seatInfo ~= nil and seatInfo.isPilot, craft, rails ~= nil)
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
				-- CHANGED (Phase 5): on the pad there is no orbit and no navball yet
				apoapsis = nil,
				periapsis = nil,
				timeToApoapsis = nil,
				timeToPeriapsis = nil,
				onRails = false,
				attitude = nil,
				horizon = nil,
				velocity = nil,
			}
		end
		-- passenger in flight: streamed state
		local state = RemoteCraftRenderer.sampleState(seatInfo.craftId, UniverseTime.now() - GameConfig.INTERP_DELAY)
		if state then
			return hudFromState(
				state,
				(seatInfo.craftModel:GetAttribute("DesignName") or "Craft") :: string,
				false,
				nil,
				RemoteCraftRenderer.railsOf(seatInfo.craftId) ~= nil -- CHANGED (Phase 5)
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

-- CHANGED (Phase 2a feedback): each engine's flame follows exactly what the simulation does with that engine,
-- and every flame goes out when this client stops simulating the craft.
-- CHANGED (Phase 10): reported to Render/Effects (plumes, trail, dust, heating), which drops the effects by itself
-- once the craft is no longer reported.
local function reportEffects()
	local craft = sim
	local id = craftId
	local model = if craft and id then craftModelById(id :: number) else nil
	if craft == nil or id == nil or model == nil then
		return
	end
	local burning: { [number]: number } = {}
	for _, engine in craft.physics.engines do
		if FlightModel.engineBurning(craft, engine) then
			burning[engine.blockId] = FlightModel.engineThrottle(craft, engine)
		end
	end
	Effects.reportCraft(id :: number, {
		source = "Local",
		model = model,
		design = craft.physics.design,
		state = craft.state,
		burning = burning,
		craftCFrame = nil, -- from the state through the pocket frame, exactly as PocketController poses it
	})
end

--============================================================================
-- Network
--============================================================================

-- CHANGED (Phase 3): a list of numbers from the network, or nil if malformed.
local function numberList(value: unknown): { number }?
	if type(value) ~= "table" then
		return nil
	end
	local list = {}
	for _, item in value :: { any } do
		if type(item) ~= "number" then
			return nil
		end
		table.insert(list, item)
	end
	return list
end

-- CHANGED (Phase 3): rebuilds a craft already in flight from the server's resume table (pilot hand-back).
local function resumeCraft(design: CraftDesign.Design, state: State, resume: { [string]: any }): Craft?
	local stageIndex = resume.stageIndex
	if type(stageIndex) ~= "number" or type(resume.stages) ~= "table" or type(resume.fuel) ~= "table" then
		return nil
	end
	local stages: { CraftGraph.Stage } = {}
	for _, stage in resume.stages :: { any } do
		if type(stage) ~= "table" then
			return nil
		end
		local ignite, decouple, deploy = numberList(stage.ignite), numberList(stage.decouple), numberList(stage.deploy)
		if ignite == nil or decouple == nil or deploy == nil then
			return nil
		end
		table.insert(stages, { ignite = ignite, decouple = decouple, deploy = deploy })
	end
	local fuel: { [number]: number } = {}
	for _, pair in resume.fuel :: { any } do
		if type(pair) == "table" and type(pair[1]) == "number" and type(pair[2]) == "number" then
			fuel[pair[1]] = pair[2]
		end
	end
	local craft = FlightModel.newCraft(design, state, fuel, stages, stageIndex)
	local active: { number } = numberList(resume.active) or {}
	for _, engineId in active do
		if craft.physics.blockPos[engineId] then
			craft.active[engineId] = true
		end
	end
	return craft
end

local function onFlightStart(
	id: unknown,
	stateBuffer: unknown,
	stagesFired: unknown,
	designBuffer: unknown,
	resume: unknown
)
	if type(id) ~= "number" or typeof(designBuffer) ~= "buffer" then
		return
	end
	local _, state = Protocol.decodeState(stateBuffer)
	local design = CraftDesign.fromBuffer(designBuffer :: buffer)
	if state == nil or design == nil then
		return
	end
	local craft: Craft
	if type(resume) == "table" then
		-- CHANGED (Phase 3): taking over a craft already in flight
		local resumed = resumeCraft(design, state :: any, resume :: { [string]: any })
		if resumed == nil then
			return
		end
		craft = resumed
	else
		craft = FlightModel.newCraft(design, state :: any)
		for _ = 1, if type(stagesFired) == "number" then stagesFired else 0 do
			FlightModel.stage(craft)
		end
	end
	throttle = state.throttle
	sasOn = false
	accumulator = 0
	rails = nil -- CHANGED (Phase 5)
	idleTime = 0
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
			rails = nil -- CHANGED (Phase 5): the override replaces any rail (and may go on rails again at once)
			idleTime = 0
			railsRetryAt = 0
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
		separationEffects(craft) -- CHANGED (Phase 10)
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
	local destroyed = {} -- CHANGED (Phase 10): the destroyed ids only (pieces fly on as debris)
	for _, blockId in ids :: { any } do
		if type(blockId) == "number" and craft.physics.blockPos[blockId] then
			table.insert(missing, blockId)
			table.insert(destroyed, blockId)
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
		-- CHANGED (Phase 10): explosions for blocks the server destroyed that we did not predict (the destroyed ids
		-- only; split-off pieces fly on as debris). Already-shown blocks are skipped by Effects.
		Effects.blockEvent(id :: number, "Explode", craft.physics.design, destroyed, "Local")
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
		rails = nil -- CHANGED (Phase 5)
	end
end

-- CHANGED (Phase 3): the server took our craft over (we left the pilot seat in flight, or died).
local function onFlightEnd(id: unknown)
	local craft = sim
	if craft == nil or id ~= craftId then
		return
	end
	RemoteCraftRenderer.seedState(id :: number, craft.state)
	sim = nil
	craftId = nil
	sasOn = false
	rails = nil -- CHANGED (Phase 3/5 merge): the server owns the craft (and its rail) now
end

-- CHANGED (Phase 5): the server accepted our rail, or moved it into another SOI. Adopted only while this client
-- is still on rails (if it already left, its next PilotState takes the server off rails too).
local function onCraftRails(packet: unknown)
	local id, data = Protocol.decodeRails(packet)
	if id == nil or data == nil or id ~= craftId or rails == nil then
		return
	end
	local adopted = Rails.fromData(data)
	if adopted then
		rails = adopted
		railsCheckUT = math.max(adopted.epochUT, UniverseTime.now())
	end
end

-- CHANGED (Phase 5): the server refused our rail or ended it (debug command, rails floor).
local function onCraftOffRails(id: unknown, _ut: unknown)
	if id ~= craftId then
		return
	end
	-- only a refusal / server-ended rail delays the next proposal; the echo of our own leaving (rails already nil)
	-- must not hold the craft off rails for RAILS_RETRY_S
	if rails then
		leaveRails()
		railsRetryAt = os.clock() + RAILS_RETRY_S
	end
end

--============================================================================
-- Lifecycle
--============================================================================

function FlightController.Init()
	for _, name in { "RequestStage", "LeaveSeat", "ReportPartsDestroyed", "RequestRails" } do -- CHANGED (Phase 5)
		remotes[name] = Remotes.event(name)
	end
	pilotStateRemote = Remotes.unreliable("PilotState")
	hud = FlightHUD.create()
	-- CHANGED (Phase 5): the map view draws this client's own craft from the exact local state
	MapViewController.setOwnCraftProvider(function(): (number?, Protocol.State?)
		local craft = sim
		if craft and craftId then
			return craftId, craft.state
		end
		return nil, nil
	end)
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
			"Flight: craft %d  alt %.0f m  v %.1f m/s  fuel %.0f kg  stage %d/%d  %s",
			craftId or 0,
			Vec3d.length(s.pos) - Bodies.get(s.bodyId).Radius,
			Vec3d.length(s.vel),
			FlightModel.totalFuel(craft),
			craft.stageIndex - 1,
			#craft.stages,
			if rails then "ON RAILS" else string.format("idle %.1f s", idleTime) -- CHANGED (Phase 5)
		)
	end)
end

function FlightController.Start()
	Remotes.event("FlightStart").OnClientEvent:Connect(onFlightStart)
	Remotes.event("FlightOverride").OnClientEvent:Connect(onOverride)
	Remotes.event("CraftStaged").OnClientEvent:Connect(onStaged)
	Remotes.event("PartsDestroyed").OnClientEvent:Connect(onDestroyed)
	Remotes.event("CraftRemoved").OnClientEvent:Connect(onRemoved)
	Remotes.event("FlightEnd").OnClientEvent:Connect(onFlightEnd) -- CHANGED (Phase 3)
	Remotes.event("CraftRails").OnClientEvent:Connect(onCraftRails) -- CHANGED (Phase 5)
	Remotes.event("CraftOffRails").OnClientEvent:Connect(onCraftOffRails)

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
		-- CHANGED (Phase 5): the map view drives the camera while it is open
		if aboardFlying and chaseEnabled and not MapViewController.isOpen() then
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
		reportEffects() -- CHANGED (Phase 10)
	end)
end

-- The craft this client simulates (pilot), or nil.
function FlightController.simulatedCraft(): (number?, Craft?)
	return craftId, sim
end

return FlightController
