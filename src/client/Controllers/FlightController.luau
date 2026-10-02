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

	CHANGED (Phase 11): keys come from Settings/Keybinds (SettingsSchema "Flight" actions; the defaults are the keys
	above, plus M map view and F2 HUD on / off). While piloting, ONE ContextActionService binding captures every
	Flight action's key (so none, e.g. a map key moved to Space, can reach the default jump and throw the pilot out of
	the seat) and is re-bound whenever the keybinds change. CHANGED (Phase 11 review): it also captures the old flight
	keys that no action uses any more (Keybinds.pilotKeys), so a freed Space cannot reach the default jump either. While UIState.isInputBlocked() (main menu or a dialog)
	the binding ignores the keys (still sinking them, for the same reason) and held keys read as released, so the
	throttle does not move either. The map key is handled here while piloting and by MapViewController otherwise;
	ToggleHUD (flips Settings hudVisible; the HUD itself reads that setting) works for everyone aboard.
	For clickable HUD controls and future touch buttons:
	  FlightController.performAction(actionId) -> boolean  runs a discrete Flight action exactly like its key
	                                                       (false for held or unknown actions); not blocked by UIState
	  FlightController.setHeld(actionId, held) -> boolean  holds a held action (pitch / yaw / roll / throttle up and
	                                                       down) like its key; released when piloting stops

	CHANGED (Phase 11): the KSP-style FlightHUD gets its callbacks from here (SAS button -> performAction("ToggleSAS"),
	End Flight button -> endFlight) and HudData carries isOwner, hasLegs, gearDown, fuel (the fuel feeding the
	stage that burns, or fires next) and orbitMode (HudMath). There is no pause menu: End Flight asks first (Kit.confirm)
	and fires the EndFlight remote. The pilot or the craft's owner ends the flight for everyone (the server removes the
	craft and puts everyone aboard back at their plot); anyone else only leaves it. Leaving flight mode afterwards is
	the usual path: the server unseats the player (bindKeys(false), ChaseCamera.stop, HUD hidden), CraftRemoved clears
	the simulation (onRemoved) and the identity PocketTransfer moves PocketController to the base pocket.
	  FlightController.endFlight()                         asks to end (or leave) the flight, like the HUD button

	CHANGED (Phase 6): EVA. LeaveSeat (F) works for passengers too: in flight the player gets out for a spacewalk
	(EvaController takes over once unseated), before launch a passenger steps off beside the pad. The chase camera and
	the own craft's effects use PocketController.craftCFrame (the seat's craft may be a secondary craft of a merged
	bubble, drawn at the pocket's render UT).
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
local HudMath = require(script.Parent.Parent.UI.HudMath) -- CHANGED (Phase 11)
local Kit = require(script.Parent.Parent.UI.Kit) -- CHANGED (Phase 11): End Flight confirmation
local Keybinds = require(script.Parent.Parent.Settings.Keybinds) -- CHANGED (Phase 11)
local Settings = require(script.Parent.Parent.Settings.Settings) -- CHANGED (Phase 11)
local UIState = require(script.Parent.Parent.UI.UIState) -- CHANGED (Phase 11)
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
-- CHANGED (Physics feel): camera speed cues (ChaseCamera zoom fit and shake)
local CAMERA_SHAKE_GROUND_HEIGHT = 120 -- m above the ground where the extra near-ground shake has faded out
-- CHANGED (Phase 5): rails
local RAILS_IDLE_TIME = GameConfig.RAILS_IDLE_TIME
local RAILS_RETRY_S = GameConfig.RAILS_RETRY_S
local SOI_CHECK_INTERVAL = GameConfig.SOI_CHECK_INTERVAL
-- CHANGED (Phase 11): flight keys are SettingsSchema action ids now (keys from Keybinds)
local ACTION_NAME = "SpaceDisastersFlight"
local HELD_ACTIONS = { -- continuous actions: any of them held counts as pilot input (rails)
	"PitchDown",
	"PitchUp",
	"YawLeft",
	"YawRight",
	"RollLeft",
	"RollRight",
	"ThrottleUp",
	"ThrottleDown",
}
local NO_PULSE_ACTIONS: { [string]: boolean } = { -- discrete actions that do not count as pilot input (rails)
	ToggleCamera = true,
	LeaveSeat = true,
	MapView = true,
	ToggleHUD = true,
}
-- CHANGED (Phase 11): HUD extras and End Flight
local LEGS_CHECK_INTERVAL = 1 -- s between scans of the craft model for landing legs (HUD LEGS lamp)
local END_FLIGHT_TEXT = {
	ownerTitle = "End flight?",
	ownerBody = "Your craft will be removed and everyone aboard goes back to their plot. Your design stays in your hangar.",
	pilotTitle = "End flight?",
	pilotBody = "The craft will be removed and everyone aboard goes back to their plot. Its design stays in its owner's hangar.",
	endConfirm = "End Flight",
	passengerTitle = "Leave flight?",
	passengerBody = "You go back to your plot. The craft keeps flying.",
	passengerPadBody = "You go back to your plot. The craft stays on its pad.",
	leaveConfirm = "Leave Flight",
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
local virtualHeld: { [string]: boolean } = {} -- CHANGED (Phase 11): held actions from setHeld (touch buttons)
-- CHANGED (Phase 11): landing legs of the craft model the HUD shows (one model at a time)
local legsModel: Model? = nil
local legsValue = false
local legsCheckedAt = -math.huge

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

-- CHANGED (Phase 11): a held action's key (Keybinds: released while UIState blocks input) or a setHeld hold.
local function held(action: string): boolean
	if virtualHeld[action] and not UIState.isInputBlocked() then
		return true
	end
	return Keybinds.isDown(action)
end

-- CHANGED (Phase 11): actions instead of keys.
local function axis(positive: string, negative: string): number
	local value = 0
	if held(positive) then
		value += 1
	end
	if held(negative) then
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
local function separationEffects(craft: Craft)
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

-- CHANGED (Phase 11): the discrete flight actions by id (keys, clickable HUD controls, future touch buttons).
local function performAction(action: string): boolean
	if action == "Stage" then
		stage()
	elseif action == "ToggleSAS" then
		sasOn = not sasOn
	elseif action == "ToggleGear" then
		local craft = sim
		if craft then
			FlightModel.setGearUp(craft, not FlightModel.isGearUp(craft.state.flags))
		end
	elseif action == "ThrottleFull" then
		throttle = 1
	elseif action == "ThrottleCut" then
		throttle = 0
	elseif action == "ToggleCamera" then
		chaseEnabled = not chaseEnabled
	elseif action == "LeaveSeat" then
		remotes.LeaveSeat:FireServer()
	elseif action == "MapView" then
		MapViewController.toggle()
	elseif action == "ToggleHUD" then
		Settings.set("hudVisible", not Settings.current().hudVisible)
	else
		return false
	end
	if not NO_PULSE_ACTIONS[action] then
		inputPulse = true -- CHANGED (Phase 5): pilot input ends rails and restarts the idle timer
	end
	return true
end

local function onAction(
	_actionName: string,
	inputState: Enum.UserInputState,
	input: InputObject
): Enum.ContextActionResult
	-- CHANGED (Phase 11): ignored while a menu or dialog is open, but still sunk (Pass would hand Space to the
	-- default jump action, which throws the pilot out of the seat)
	if inputState ~= Enum.UserInputState.Begin or UIState.isInputBlocked() then
		return Enum.ContextActionResult.Sink
	end
	-- CHANGED (Phase 11): the key's Flight action from Keybinds
	local action = Keybinds.actionFor("Flight", input.KeyCode)
	if action and table.find(HELD_ACTIONS, action) then
		inputPulse = true -- CHANGED (Phase 5): pilot input ends rails (a tap shorter than a frame still counts)
	elseif action then
		performAction(action)
	end
	return Enum.ContextActionResult.Sink
end

-- CHANGED (Phase 11): every Flight action's current key.
-- CHANGED (Phase 11 review): plus the old flight keys (Keybinds.pilotKeys), so a key freed by a rebind (Space after
-- Stage moved, LeftShift after ThrottleUp moved) is still sunk (onAction sinks keys without an action) instead of
-- reaching the default jump (out of the seat) or the shift lock.
local function bindAction()
	ContextActionService:BindActionAtPriority(
		ACTION_NAME,
		onAction,
		false,
		ACTION_PRIORITY,
		table.unpack(Keybinds.pilotKeys())
	)
end

local function bindKeys(enable: boolean)
	if enable == bound then
		return
	end
	bound = enable
	MapViewController.setPilotBinding(enable) -- CHANGED (Phase 11): the map key comes through onAction meanwhile
	if enable then
		bindAction()
	else
		ContextActionService:UnbindAction(ACTION_NAME)
		table.clear(virtualHeld) -- CHANGED (Phase 11): touch holds end with piloting
	end
end

--============================================================================
-- Simulation
--============================================================================

local function applyControls(craft: Craft, dt: number, piloting: boolean)
	if piloting and not UserInputService:GetFocusedTextBox() then
		-- CHANGED (Phase 11): actions (SettingsSchema explains the directions: W = pitch down, E = roll left)
		throttle = math.clamp(throttle + axis("ThrottleUp", "ThrottleDown") * THROTTLE_RATE * dt, 0, 1)
		FlightModel.setControls(
			craft,
			axis("PitchDown", "PitchUp"),
			axis("YawRight", "YawLeft"),
			axis("RollLeft", "RollRight"),
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
	for _, action in HELD_ACTIONS do -- CHANGED (Phase 11): actions (Keybinds) instead of fixed keys
		if held(action) then
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

-- CHANGED (Phase 11): does the craft model have landing legs? (rescanned every LEGS_CHECK_INTERVAL)
local function hasLegs(model: Model?): boolean
	if model == nil then
		return false
	end
	local now = os.clock()
	if model == legsModel and now - legsCheckedAt < LEGS_CHECK_INTERVAL then
		return legsValue
	end
	local found = false
	for _, child in model:GetChildren() do
		local partId = child:GetAttribute("PartId")
		local def = if type(partId) == "string" then Parts.find(partId) else nil
		if def and def.Leg then
			found = true
			break
		end
	end
	legsModel = model
	legsValue = found
	legsCheckedAt = now
	return found
end

-- CHANGED (Phase 11): is the local player the craft model's owner?
local function isOwnerOf(model: Model?): boolean
	return model ~= nil and model:GetAttribute("OwnerUserId") == player.UserId
end

-- CHANGED (Phase 11): fuel left (0..1) in what feeds the stage that is burning (its engines' tanks and solid
-- boosters), or the stage that fires next when nothing burns; the whole craft's fuel when that is unknown.
local function stageFuelFraction(craft: Craft): number
	local engines: { [number]: boolean } = {}
	for id in craft.active do
		engines[id] = true
	end
	if next(engines) == nil then
		local upcoming = craft.stages[craft.stageIndex]
		if upcoming then
			for _, id in upcoming.ignite do
				engines[id] = true
			end
		end
	end
	local physics = craft.physics
	local sources: { [number]: boolean } = {}
	for _, engine in physics.engines do
		if engines[engine.blockId] then
			if engine.solid then
				sources[engine.blockId] = true
			else
				local group = physics.groupOf[engine.blockId]
				local tanks: { number } = if group then physics.groups[group] or {} else {}
				for _, tank in tanks do
					sources[tank] = true
				end
			end
		end
	end
	local now, full = 0, 0
	for id in sources do
		local block = physics.graph.blockById[id]
		if block then
			full += Parts.get(block.type).FuelMass
			now += craft.fuel[id] or 0
		end
	end
	if full <= 0 then
		return FlightModel.remainingFuelFraction(craft)
	end
	return math.clamp(now / full, 0, 1)
end

local function hudFromState(
	state: Protocol.State,
	name: string,
	isPilot: boolean,
	craft: Craft?,
	onRails: boolean,
	model: Model? -- CHANGED (Phase 11): the craft's real model (owner, legs)
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
		-- CHANGED (Phase 11)
		isOwner = isOwnerOf(model),
		hasLegs = hasLegs(model),
		gearDown = not FlightModel.isGearUp(state.flags),
		fuel = if craft then stageFuelFraction(craft) else nil,
		orbitMode = HudMath.isOrbitMode(altitude, if body.Atmosphere then body.Atmosphere.Top else nil, body.Radius),
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
		return hudFromState(craft.state, name, seatInfo ~= nil and seatInfo.isPilot, craft, rails ~= nil, model)
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
				-- CHANGED (Phase 11)
				isOwner = isOwnerOf(seatInfo.craftModel),
				hasLegs = hasLegs(seatInfo.craftModel),
				gearDown = true, -- legs are built deployed
				fuel = 1,
				orbitMode = false,
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
				RemoteCraftRenderer.railsOf(seatInfo.craftId) ~= nil, -- CHANGED (Phase 5)
				seatInfo.craftModel -- CHANGED (Phase 11)
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

-- CHANGED (Physics feel): bounding radius (studs) of the seat's craft, from its design (cached per model).
local cameraSizeModel: Model? = nil
local cameraSizeValue = 0
local function cameraCraftSize(seatInfo: SeatInfo): number
	local model = seatInfo.craftModel
	if model ~= cameraSizeModel then
		local design = if sim and craftId == seatInfo.craftId
			then (sim :: Craft).physics.design
			else CraftBuilder.readDesign(model)
		local minV, maxV = CraftDesign.bounds(design)
		cameraSizeModel = model
		cameraSizeValue = (maxV - minV).Magnitude * CraftDesign.GRID / 2
	end
	return cameraSizeValue
end

--[[
	CHANGED (Physics feel): ChaseCamera shake inputs for the seat's craft: (thrust fraction 0..1, near-ground
	factor 0..1, dynamic pressure Pa). The pilot uses the local simulation (thrust of the burning engines over that
	of every active engine); passengers use the streamed state (burning flag and throttle; a burning craft at
	zero throttle runs solid boosters, which burn at full).
]]
local function cameraShakeInputs(seatInfo: SeatInfo): (number, number, number)
	local craft = if sim and craftId == seatInfo.craftId then sim :: Craft else nil
	local state: Protocol.State? = if craft
		then craft.state
		else RemoteCraftRenderer.sampleState(seatInfo.craftId, UniverseTime.now() - GameConfig.INTERP_DELAY)
	if state == nil then
		return 0, 0, 0
	end
	local thrustFraction = 0
	if craft then
		local produced, available = 0, 0
		for _, engine in craft.physics.engines do
			if craft.active[engine.blockId] then
				available += engine.stats.ThrustVac
				if FlightModel.engineBurning(craft, engine) then
					produced += engine.stats.ThrustVac * FlightModel.engineThrottle(craft, engine)
				end
			end
		end
		thrustFraction = if available > 0 then produced / available else 0
	elseif bit32.band(state.flags, FlightModel.FLAG_BURNING) ~= 0 then
		thrustFraction = if state.throttle > 0 then state.throttle else 1
	end
	local body = Bodies.get(state.bodyId)
	local altitude = Vec3d.length(state.pos) - body.Radius
	local height = SurfaceHeight.height(state.bodyId, state.pos)
	local nearGround = 1 - math.clamp(height / CAMERA_SHAKE_GROUND_HEIGHT, 0, 1)
	local speed = Vec3d.length(state.vel)
	local dynamicPressure = 0.5 * Atmosphere.density(state.bodyId, altitude) * speed * speed
	return thrustFraction, nearGround, dynamicPressure
end

local cameraGroundScratch = Vec3d.zero() -- CHANGED (Phase 8)

local function cameraTarget(): ChaseCamera.Target?
	local seatInfo = currentSeat()
	if seatInfo == nil then
		return nil
	end
	local com = if sim and craftId == seatInfo.craftId then (sim :: Craft).physics.com else Vector3.zero
	local position: Vector3
	-- CHANGED (Phase 6): the seat's own craft as posed this frame (it may be a secondary craft of a merged bubble)
	local craftFrame = PocketController.craftCFrame(seatInfo.craftId)
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
	-- CHANGED (Physics feel): craft size for the zoom fit, thrust / air / ground for the shake
	local thrustFraction, nearGround, dynamicPressure = cameraShakeInputs(seatInfo)
	return {
		position = position,
		up = cameraUp(frame),
		toWorkspace = frame.refRotInv,
		key = seatInfo.craftId,
		size = cameraCraftSize(seatInfo),
		thrustFraction = thrustFraction,
		nearGround = nearGround,
		dynamicPressure = dynamicPressure,
		-- CHANGED (Phase 8): keeps the chase camera out of hills
		groundHeight = function(point: Vector3): number
			local h =
				SurfaceHeight.height(frame.refBodyId, Frames.pointFromWorkspace(frame, point, cameraGroundScratch))
			return h
		end,
	}
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
		-- CHANGED (Phase 6): a secondary craft of a merged bubble exactly where PocketController posed it (at the
		-- pocket's render UT, not at the simulation's); the primary as before, from the state through the pocket frame
		craftCFrame = if PocketController.primaryCraftId() == id
			then nil
			else PocketController.craftCFrame(id :: number),
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
-- CHANGED (Phase 11): End Flight (no pause menu)
--============================================================================

-- Asks first (Kit.confirm), then tells the server. The pilot or the craft's owner ends the flight for everyone;
-- anyone else only leaves it. Nothing happens when not aboard a craft or while another dialog is open.
local function endFlight()
	local seatInfo = currentSeat()
	if seatInfo == nil or Kit.isConfirmOpen() then
		return
	end
	local id = seatInfo.craftId
	local owner = isOwnerOf(seatInfo.craftModel)
	local options: Kit.ConfirmOptions
	if owner then
		options = {
			title = END_FLIGHT_TEXT.ownerTitle,
			body = END_FLIGHT_TEXT.ownerBody,
			confirmText = END_FLIGHT_TEXT.endConfirm,
			danger = true,
		}
	elseif seatInfo.isPilot then
		options = {
			title = END_FLIGHT_TEXT.pilotTitle,
			body = END_FLIGHT_TEXT.pilotBody,
			confirmText = END_FLIGHT_TEXT.endConfirm,
			danger = true,
		}
	else
		options = {
			title = END_FLIGHT_TEXT.passengerTitle,
			body = if seatInfo.state == "Prelaunch"
				then END_FLIGHT_TEXT.passengerPadBody
				else END_FLIGHT_TEXT.passengerBody,
			confirmText = END_FLIGHT_TEXT.leaveConfirm,
			danger = true,
		}
	end
	Kit.confirm(options, function(confirmed: boolean)
		local now = currentSeat()
		if confirmed and now ~= nil and now.craftId == id then
			remotes.EndFlight:FireServer()
		end
	end)
end

--============================================================================
-- Lifecycle
--============================================================================

function FlightController.Init()
	-- CHANGED (Phase 5): RequestRails; CHANGED (Phase 11): EndFlight
	for _, name in { "RequestStage", "LeaveSeat", "ReportPartsDestroyed", "RequestRails", "EndFlight" } do
		remotes[name] = Remotes.event(name)
	end
	pilotStateRemote = Remotes.unreliable("PilotState")
	-- CHANGED (Phase 11): the KSP-style HUD's clickable controls
	hud = FlightHUD.create({
		onEndFlight = endFlight,
		onToggleSAS = function()
			performAction("ToggleSAS")
		end,
	})
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
	-- CHANGED (Phase 11): a rebind takes effect at once while piloting
	Keybinds.onChanged(function()
		if bound then
			ContextActionService:UnbindAction(ACTION_NAME)
			bindAction()
		end
	end)
	-- CHANGED (Phase 11): ToggleHUD for passengers (the pilot's binding handles it while piloting)
	-- CHANGED (Phase 6): and LeaveSeat: passengers get out too (an EVA in flight, beside the pad before launch)
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or bound or UIState.isInputBlocked() or currentSeat() == nil then
			return
		end
		local key = Keybinds.key("ToggleHUD")
		if key ~= Keybinds.UNBOUND and input.KeyCode == key then
			performAction("ToggleHUD")
		end
		local leave = Keybinds.key("LeaveSeat")
		if leave ~= Keybinds.UNBOUND and input.KeyCode == leave then
			performAction("LeaveSeat")
		end
	end)

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

-- CHANGED (Phase 11): runs a discrete Flight action (SettingsSchema id) exactly like its key: Stage, ToggleSAS,
-- ToggleGear, ThrottleFull, ThrottleCut, ToggleCamera, LeaveSeat, MapView, ToggleHUD. Returns false for held or
-- unknown actions. Not blocked by UIState (the caller is an explicit control); callers show pilot controls only to
-- the pilot (HudData.isPilot).
function FlightController.performAction(actionId: string): boolean
	return performAction(actionId)
end

-- CHANGED (Phase 11): asks to end the flight (pilot / owner: for everyone) or to leave it (passengers), exactly like the
-- HUD's End Flight button (for future touch buttons).
function FlightController.endFlight()
	endFlight()
end

-- CHANGED (Phase 11): holds or releases a held Flight action (PitchDown, PitchUp, YawLeft, YawRight, RollLeft,
-- RollRight, ThrottleUp, ThrottleDown) like its key, for touch buttons. Released automatically when piloting stops;
-- reads as released while UIState blocks input. Returns false for any other action.
function FlightController.setHeld(actionId: string, isHeld: boolean): boolean
	if not table.find(HELD_ACTIONS, actionId) then
		return false
	end
	if isHeld then
		virtualHeld[actionId] = true
		inputPulse = true -- like the key press (ends rails)
	else
		virtualHeld[actionId] = nil
	end
	return true
end

return FlightController
