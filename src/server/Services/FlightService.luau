--!strict
--[[
	FlightService (Phase 2a)
	Server side of flying: launch, staging, the pilot's state stream, crashes and crew safety.

	Flight start (spec 7.5; CHANGED Phase 2a feedback: real physics on the pad): as soon as a pilot sits in a
	Prelaunch craft (Roll Out seats the owner automatically), the server allocates a HORIZON_ALIGNED flight pocket
	(D31) whose reference is the craft's root position and the local horizon, moves the real craft model into it with one rigid transform M (seated
	crew ride along with their anchored seats, S9), sends PocketTransfer to every crew member (unseated ones move
	themselves by M and ack; the server teleports them after 3 s without an ack), creates the simulation and hands
	it to the pilot's client (FlightStart, no stage fired). The craft then stands on its pad under real physics;
	Space ignites stage 1. Leaving the pilot seat before ignition returns the craft to the base pocket as Prelaunch
	(so friends can board), and sitting down again restarts the flight.

	In flight the pilot's client simulates; its PilotState (20 Hz) is validated and becomes the server copy's
	state. Staging and part destruction are applied to the server copy (authoritative): separated pieces become
	server-simulated debris (CraftService.spawnDebris), their block models are removed from the real model, and
	every client is told (CraftStaged / PartsDestroyed). If the pilot leaves or dies, the server takes over the
	simulation (ServerSimService).

	CHANGED (Phase 3): pilot hand-over.
	  * The pilot leaving the pilot seat (F, another seat, death, disconnect) after ignition hands the craft to the
	    server: ServerSimService continues uncrewed physics with ZERO input and the throttle CUT TO ZERO (safety:
	    an abandoned rocket must not keep accelerating; solid boosters still burn out, as in KSP). The former pilot's
	    client is told with FlightEnd and from then on follows the craft through the CraftStates stream, like
	    every passenger. Before ignition, leaving still returns the craft to the pad.
	  * Anyone (boarding permission already checked by CrewService) who sits down in the pilot seat of a flying,
	    server-simulated craft takes it back: FlightStart carries the current state plus a `resume` table (stage
	    list and index, ignited engines, fuel left) so the client continues exactly where the server was.
	  * The join snapshot moved to CraftService (RequestSnapshot).

	CHANGED (Phase 11): End Flight (remote EndFlight, from the flight HUD's confirmation dialog; there is no pause
	menu). The craft is the one whose seat the sender sits in.
	  * Its pilot (pilot seat, or the client simulating it) or its owner aboard ends the flight for EVERYONE: every
	    crew member and every player in its flight pocket is unseated, stood at their own plot spawn by the server
	    and moved to the base pocket with an identity PocketTransfer (exactly like the pilot stepping off the pad in
	    returnToPad), the craft is taken off rails and removed (CraftService.remove: CraftRemoved for every client)
	    and its flight pocket released. The others are told "Flight ended by <name>". Works the same for a craft
	    still on its pad (Prelaunch, base pocket: no transfer needed) or not yet ignited. The design in the
	    owner's hangar is untouched (Roll Out never clears it).
	  * Anyone else (a passenger) only leaves: they alone go back to their plot; the craft flies on.

	CHANGED (Boarding): cross-pocket boarding (remote BoardCraft, rules in Shared/Craft/Boarding). Once its pilot
	sat down a craft lives in its flight pocket, and players in the base only see a cosmetic copy without seats, so
	nobody could board it, not even on the pad. The client now puts seat prompts on the copy; the server checks the
	request (rate limit, player alive, on foot and in the base pocket, craft flying and not debris, boarding
	permission, a free Seat in the real model, the player within the craft's radius + BOARD_RANGE of its state and
	the craft slower than BOARD_MAX_SPEED), takes a server craft off rails, seats the player with CrewService.sitIn
	(the SitPrompt seat entry: it moves the character into the flight pocket) and sends an identity PocketTransfer
	base -> flight pocket (the server placed the character, so the client must not move it again). Pilot seat: the
	usual onSeated path applies (handBack hands a server-simulated craft to the new pilot). Leaving is unchanged:
	the boarded player is an ordinary passenger (or pilot) of the craft.
	CHANGED (Night review): an uncrewed craft WITHOUT a real model (announced in pocket 0: e.g. landed near the base
	after its crew went home, its pocket released) can be boarded too: the server gives it a Craft pocket and a real
	model first (giveRealModel), and releases that pocket again if the boarding fails.

	CHANGED (Phase 6): EVA (BubbleService and EvaService do the bubbles; this service the seats).
	  * Leaving a seat in flight (F for everyone now, or the jump key) starts an EVA: the player is unseated and
	    stays in the pocket; their client puts the astronaut outside the hatch and flies the jetpack. Before
	    ignition a PASSENGER still steps off beside the pad into the base pocket (the pilot's F still returns the
	    whole craft to the pad).
	  * End Flight from an astronaut on EVA sends only them home ("Return to plot" on the EVA HUD). A pilot / owner
	    ending a flight sends home everyone aboard that craft, plus everyone in its pocket only when no other craft
	    shares the pocket (merged bubbles keep the other crews); the pocket itself is re-pointed or released by
	    BubbleService (CraftService.onRemoving).
	    CHANGED (Night review): "everyone in its pocket" is now the astronauts whose last craft (lastCraft: the seat
	    they last sat in) is this one; the "another craft shares the pocket" test is gone (endFlight).
	  * A craft whose reference block is destroyed kills only the players SEATED in it; anyone else in the pocket
	    (astronauts, other crews) lives on.
	  * When a pocket is released every craft whose model was in it (primary and secondaries) goes back to an
	    uncrewed, server-simulated craft.
	  * Exported for BubbleService / EvaService: sendTransfer (also pins the player's PocketId, PocketService.pin),
	    bumpPoseEpoch, seatedIn, isBusy, sendHome.

	CHANGED (Solar system): Sol is not landable. Every BURN_CHECK_S the server looks at every craft (flying, server
	simulated, debris or on rails); one closer to a body's centre than its DestroyRadius (Sol: 2.5 radii) burns up:
	it is taken off rails and every block is destroyed (applyDestruction: PartsDestroyed explosions for everyone,
	the seated crew dies, the craft is removed).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- CHANGED (Night review): Workspace (the Phase 3 crew detection raycast) is no longer needed: crewOf is seated only

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local CraftService = require(script.Parent.CraftService)
local CrewService = require(script.Parent.CrewService)
local PlotService = require(script.Parent.PlotService) -- CHANGED (Phase 11): End Flight sends players home
local PocketService = require(script.Parent.PocketService)
local RailsService = require(script.Parent.RailsService) -- CHANGED (Phase 5)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails) -- CHANGED (Phase 5)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight) -- CHANGED (Phase 8)
local Boarding = require(ReplicatedStorage.Shared.Craft.Boarding) -- CHANGED (Boarding)

type CraftRecord = CraftService.CraftRecord

--============================================================================
-- Tunables
--============================================================================
local ACK_TIMEOUT_S = GameConfig.POCKET_TRANSFER_ACK_TIMEOUT
-- CHANGED (Night review): CREW_BOUNDS_MARGIN / CREW_STAND_RAY removed with the standing-crew detection (crewOf)
local POSITION_TOLERANCE = 50 -- m: |dpos - vel*dt| allowed between pilot states
-- CHANGED (Physics feel): was 250. With engines x1.5 a Solid Booster pushes 292.5 kN against its 600 kg dry mass
-- (~490 m/s^2), so a cluster of boosters near burnout could legitimately exceed 250 and collect strikes.
local MAX_ACCEL = 500 -- m/s^2 of velocity change allowed between pilot states (above any part's thrust / dry mass)
local VELOCITY_SLACK = 2 -- m/s
local STRIKE_LIMIT = 3
local STRIKE_WINDOW_S = 5
local CRASH_ALTITUDE_SLACK = 150 -- m above the craft's size where a reported crash is still plausible
local LAUNCH_THROTTLE = 1
local SEATED_START_DELAY_S = 0.3 -- s between a pilot sitting down and the flight starting
local PAD_STEP_OFF = 6 -- studs beyond the pad edge where a pilot who leaves the seat on the pad is put
local RAILS_HANDOFF_DT = 0.05 -- CHANGED (Phase 5): s before a pilot's first off-rails state the rail is validated at
local END_FLIGHT_COOLDOWN_S = 1 -- CHANGED (Phase 11): EndFlight requests closer together than this are ignored
local BOARD_COOLDOWN_S = 1 -- CHANGED (Boarding): BoardCraft requests closer together than this are ignored
local BURN_CHECK_S = 0.5 -- CHANGED (Solar system): s between "too close to Sol" checks
--============================================================================

local FlightService = {}

type Strikes = { count: number, since: number }
type PendingTransfer = { player: Player, m: CFrame, deadline: number }

local launching: { [number]: boolean } = {}
local returning: { [number]: boolean } = {} -- CHANGED (Phase 3): re-entrancy guard for returnToPad
local ending: { [number]: boolean } = {} -- CHANGED (Phase 11): re-entrancy guard for endFlight
local lastEndFlight: { [Player]: number } = {} -- CHANGED (Phase 11): EndFlight rate limit
local lastBoard: { [Player]: number } = {} -- CHANGED (Boarding): BoardCraft rate limit
-- CHANGED (Night review): the craft each player last sat in (kept after leaving the seat): an astronaut on EVA
-- belongs to that craft's flight, so its End Flight sends him home (and nobody else floating in the pocket)
local lastCraft: { [Player]: number } = {}
local lastValid: { [number]: { state: FlightModel.CraftState, fuel: number } } = {}
local strikes: { [number]: Strikes } = {}
local pendingTransfers: { [number]: PendingTransfer } = {}
local nextTransferId = 1
local remotes: { [string]: RemoteEvent } = {}

--============================================================================
-- Helpers
--============================================================================

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function craftModelOf(instance: Instance): Model?
	local node: Instance? = instance
	while node do
		if node:IsA("Model") and node:GetAttribute("CraftId") ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- The craft record whose pilot seat the player occupies.
local function pilotSeatCraft(player: Player): CraftRecord?
	local humanoid = humanoidOf(player)
	local seat = if humanoid then humanoid.SeatPart else nil
	if seat == nil or seat:GetAttribute("IsPilot") ~= true then
		return nil
	end
	local model = craftModelOf(seat)
	local id = if model then model:GetAttribute("CraftId") else nil
	return if type(id) == "number" then CraftService.get(id) else nil
end

-- Players aboard a real craft model: seated in it.
-- CHANGED (Night review): seated only. It also counted players standing inside the bounding box on the craft
-- (Phase 3), for the Crew Cabin; that part is gone (D34), and a player standing on a rocket at launch was pulled into
-- the flight pocket on foot, became an astronaut on EVA there and was sent back by the bubbles a moment later.
local function crewOf(model: Model): { Player }
	return FlightService.seatedIn(model)
end

local function unseat(humanoid: Humanoid)
	local seat = humanoid.SeatPart
	if seat then
		local weld = seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		humanoid.Sit = false
	end
end

local function kill(player: Player)
	local humanoid = humanoidOf(player)
	if humanoid then
		humanoid.Health = 0
	end
end

local function destroyBlockModels(record: CraftRecord, ids: { number })
	local model = record.model
	if model == nil then
		return
	end
	for _, id in ids do
		local block = CraftBuilder.findBlockModel(model, id)
		if block then
			block:Destroy()
		end
	end
end

-- Kills players seated in, or standing inside, a (command) block that is about to be destroyed.
local function killOccupants(record: CraftRecord, blockId: number)
	local model = record.model
	local block = if model then CraftBuilder.findBlockModel(model, blockId) else nil
	if block == nil then
		return
	end
	local cf, size = block:GetBoundingBox()
	local half = size / 2 + Vector3.one
	for _, player in Players:GetPlayers() do
		local humanoid = humanoidOf(player)
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if humanoid and root and root:IsA("BasePart") then
			local seat = humanoid.SeatPart
			local inside = seat ~= nil and seat:IsDescendantOf(block)
			if not inside then
				local p = cf:PointToObjectSpace(root.Position)
				inside = math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z
			end
			if inside then
				kill(player)
			end
		end
	end
end

-- CHANGED (Phase 2a feedback, D31): clients pose flying craft models themselves; every server-side move of a
-- real model bumps this attribute (replicated in order with the move, S8) so clients re-read the new pose.
local function bumpPoseEpoch(model: Model)
	local epoch = model:GetAttribute("PoseEpoch")
	model:SetAttribute("PoseEpoch", (if type(epoch) == "number" then epoch else 0) + 1)
end

-- CHANGED (Night review): `absolute` = where the server already put the character (sendHome); the client places an
-- unseated character there instead of moving it by m (see PocketController.onTransfer).
local function sendTransfer(player: Player, source: number, dest: number, m: CFrame, epoch: number, absolute: CFrame?)
	if player.Parent == nil then
		return -- CHANGED (Phase 3): the player already left
	end
	local id = nextTransferId
	nextTransferId += 1
	player:SetAttribute("PocketId", dest)
	PocketService.pin(player, dest) -- CHANGED (Phase 6): the replicated position lags the transfer
	pendingTransfers[id] = { player = player, m = m, deadline = os.clock() + ACK_TIMEOUT_S }
	remotes.PocketTransfer:FireClient(player, id, source, dest, m, epoch, absolute)
end

--============================================================================
-- Staging and destruction (authoritative, on the server copy)
--============================================================================

local function applyStageResult(record: CraftRecord, result: FlightModel.StageResult)
	local sim = record.sim :: FlightModel.Craft
	local debrisInfo = {}
	for _, debris in result.debris do
		local piece = CraftService.spawnDebris(record, debris)
		table.insert(debrisInfo, { craftId = piece.id, blockIds = debris.blockIds })
		destroyBlockModels(record, debris.blockIds)
	end
	remotes.CraftStaged:FireAllClients(
		record.id,
		result.stage,
		sim.state.ut,
		result.ignited,
		result.decoupled,
		debrisInfo
	)
end

-- Removes destroyed blocks from a flying craft: kills occupants of destroyed command parts, turns separated
-- pieces into debris, retires the craft (and kills its crew) if its reference block is gone.
function FlightService.applyDestruction(record: CraftRecord, ids: { number })
	local sim = record.sim
	if sim == nil or #ids == 0 then
		return
	end
	for _, id in ids do
		local block = sim.physics.graph.blockById[id]
		if block and Parts.isCommand(Parts.get(block.type)) then
			killOccupants(record, id)
		end
	end
	local pieces, originLost = FlightModel.removeBlocks(sim, ids)
	destroyBlockModels(record, ids)
	local piecesInfo = {}
	for _, piece in pieces do
		local debris = CraftService.spawnDebris(record, piece)
		table.insert(piecesInfo, { craftId = debris.id, blockIds = piece.blockIds })
		destroyBlockModels(record, piece.blockIds)
	end
	remotes.PartsDestroyed:FireAllClients(record.id, ids, sim.state.ut, piecesInfo)
	if originLost then
		-- CHANGED (Phase 6): only the players seated in it (was: everyone in its pocket). Astronauts on EVA and the
		-- crews of other crafts sharing the pocket live on; BubbleService re-points or releases the pocket.
		local model = record.model
		if model then
			for _, player in FlightService.seatedIn(model) do
				kill(player)
			end
		end
		CraftService.remove(record.id)
	end
end

-- CHANGED (Phase 6): the players seated in a craft model.
function FlightService.seatedIn(model: Model): { Player }
	local seated = {}
	for _, player in Players:GetPlayers() do
		local humanoid = humanoidOf(player)
		local seat = if humanoid then humanoid.SeatPart else nil
		if seat and seat:IsDescendantOf(model) then
			table.insert(seated, player)
		end
	end
	return seated
end

--============================================================================
-- Flight start / return to the pad
--============================================================================

-- CHANGED (Phase 2a feedback): runs when a pilot sits down in a Prelaunch craft; the craft then stands on its pad
-- under real physics until Space ignites stage 1 (no countdown, no automatic staging).
function FlightService.startFlight(player: Player, record: CraftRecord)
	local model = record.model
	if model == nil or launching[record.id] or record.state ~= "Prelaunch" then
		return
	end
	launching[record.id] = true
	model:SetAttribute("State", "Launching")

	-- The root block's true pose (craft axes = design axes, placed with record.origin in the base pocket).
	local root = CraftDesign.rootBlock(record.design) :: CraftDesign.Block
	local rootWorld = record.origin * CFrame.new(CraftDesign.blockCenter(root) * CraftDesign.GRID)
	local baseFrame = PocketService.baseFrame()
	local pos, rot = Frames.cframeFromWorkspace(baseFrame, rootWorld)

	-- CHANGED (Phase 2a feedback, D31): pocket axes = the local horizon, not the craft
	local horizon = Universe.pocketRotation(Bodies.HOMEWORLD, pos, UniverseTime.now())
	local pocket = PocketService.createFlightPocket(record.id, Bodies.HOMEWORLD, pos, horizon)
	if pocket == nil then
		launching[record.id] = nil
		model:SetAttribute("State", "Prelaunch")
		remotes.Notify:FireClient(player, "No free flight slot, try again soon", "Error")
		return
	end
	local newFrame = Frames.new(Bodies.HOMEWORLD, pos, horizon, pocket.slotOrigin, 0)
	local m = Frames.relativeTransform(baseFrame, newFrame)

	local crew = crewOf(model)
	model:PivotTo(m * model:GetPivot())
	bumpPoseEpoch(model)
	model:SetAttribute("FlightPocket", pocket.id) -- clients pose the model only while in this pocket
	model.Parent = pocket.folder:FindFirstChild("Crafts")
	record.origin = m * record.origin
	record.pocketId = pocket.id
	for _, member in crew do
		sendTransfer(member, 0, pocket.id, m, 0)
	end

	local state: FlightModel.CraftState = {
		bodyId = Bodies.HOMEWORLD,
		pos = pos,
		vel = Vec3d.zero(),
		rot = rot,
		angVel = Vector3.zero,
		throttle = LAUNCH_THROTTLE,
		flags = 0,
		ut = UniverseTime.now(),
	}
	local sim = FlightModel.newCraft(record.design, state)
	record.sim = sim
	record.state = "Flying"
	model:SetAttribute("State", "Flying")
	launching[record.id] = nil

	if pilotSeatCraft(player) == record then
		record.pilot = player
		record.serverSim = false
	else
		record.pilot = nil
		record.serverSim = true
	end
	lastValid[record.id] = { state = FlightModel.copyState(sim.state), fuel = FlightModel.totalFuel(sim) }
	if record.pilot then
		remotes.FlightStart:FireClient(
			player,
			record.id,
			Protocol.encodeState(record.id, sim.state),
			0,
			CraftDesign.toBuffer(record.design)
		)
	end
	CraftService.announce(record)
end

-- Can this craft still go back to Prelaunch? Only before ignition and with every block intact.
-- CHANGED (Phase 6): and only while it is still at the launch site (within BASE_BUBBLE): a craft moved away without
-- igniting (the /orbit debug command) is in flight, and leaving its seat starts an EVA there.
local function canReturnToPad(record: CraftRecord): boolean
	local sim = record.sim
	return sim ~= nil
		and record.pocketId ~= nil
		and record.model ~= nil
		and not record.isDebris
		and sim.stageIndex == 1
		and sim.state.bodyId == Bodies.HOMEWORLD
		and #sim.physics.design.blocks == #record.design.blocks
		and Vec3d.distance(sim.state.pos, PocketService.baseFrame().refPos) < GameConfig.BASE_BUBBLE
end

-- CHANGED (Phase 2a feedback): the pilot stood up before ignition. Moves the craft (where it stands now, even if
-- it tipped over) and its crew back into the base pocket as a Prelaunch craft, and releases the flight pocket.
-- CHANGED (Phase 3): `pilot` is nil when the pilot is not to be stood beside the pad (they left the game, or moved
-- to another seat of the same craft and ride back with it like the rest of the crew).
local function returnToPad(record: CraftRecord, pilot: Player?)
	local sim = record.sim :: FlightModel.Craft
	local model = record.model :: Model
	local pocketId = record.pocketId :: number
	local pocket = PocketService.flightPocket(pocketId)
	if pocket == nil or returning[record.id] then
		return
	end
	returning[record.id] = true
	local crew = crewOf(model)
	-- (CHANGED (Phase 6) note: astronauts on EVA in the pocket go back too, moved by M like unseated crew; no other
	-- craft can share this pocket, BubbleService never merges pockets inside BASE_BUBBLE of the launch site)
	for _, player in PocketService.playersIn(pocketId) do
		if not table.find(crew, player) then
			table.insert(crew, player)
		end
	end
	-- CHANGED (Phase 2a feedback, D31): on the server the real model stays where it was placed at flight start
	-- (clients pose it every frame), so it is moved by "craft frame now (in base) * craft frame on the server^-1".
	-- Unseated crew are in the client-side pocket, whose frame is the horizon frame at the craft's state now.
	local baseFrame = PocketService.baseFrame()
	local craftNow = Frames.cframeToWorkspace(baseFrame, sim.state.pos, sim.state.rot)
	local root = CraftDesign.rootBlock(record.design) :: CraftDesign.Block
	local craftOnServer = record.origin * CFrame.new(CraftDesign.blockCenter(root) * CraftDesign.GRID)
	local modelMove = craftNow * craftOnServer:Inverse()
	local horizonNow = Frames.new(
		sim.state.bodyId,
		sim.state.pos,
		Universe.pocketRotation(sim.state.bodyId, sim.state.pos, sim.state.ut),
		pocket.slotOrigin,
		0
	)
	local m = Frames.relativeTransform(horizonNow, baseFrame)

	-- The pilot stands up first and is placed directly beside the pad by the server, so their transfer below
	-- carries the identity transform (the client must not move an unseated character by M a second time).
	local pilotHumanoid = if pilot then humanoidOf(pilot) else nil
	if pilotHumanoid then
		unseat(pilotHumanoid)
	end

	model:SetAttribute("FlightPocket", nil) -- clients stop posing before the move below reaches them
	model:PivotTo(modelMove * model:GetPivot())
	bumpPoseEpoch(model)
	model.Parent = PocketService.baseCrafts()
	record.origin = modelMove * record.origin
	record.pocketId = nil
	record.sim = nil
	record.pilot = nil
	record.serverSim = false
	record.state = "Prelaunch"
	model:SetAttribute("State", "Prelaunch")
	lastValid[record.id] = nil
	strikes[record.id] = nil
	remotes.CraftRemoved:FireAllClients(record.id)
	CraftService.announce(record) -- CHANGED (Phase 3): back on the pad, still visible from other pockets

	local character = if pilot then pilot.Character else nil
	if pilotHumanoid and character then
		local cf, size = model:GetBoundingBox()
		local padIndex = CraftService.padOf(record.id)
		local target = if padIndex
			then BaseLayout.pad(padIndex).top.Position + Vector3.new(BaseLayout.PAD_SIZE / 2 + PAD_STEP_OFF, 3, 0)
			else Vector3.new(cf.Position.X + size.X / 2 + PAD_STEP_OFF, 3, cf.Position.Z)
		character:PivotTo(CFrame.lookAt(target, Vector3.new(cf.Position.X, target.Y, cf.Position.Z)))
	end
	for _, member in crew do
		sendTransfer(member, pocketId, 0, if member == pilot then CFrame.identity else m, 0)
	end
	if pilot and not table.find(crew, pilot) then
		sendTransfer(pilot, pocketId, 0, CFrame.identity, 0)
	end
	PocketService.releaseFlightPocket(pocketId)
	returning[record.id] = nil
end

--============================================================================
-- CHANGED (Phase 3): pilot hand-over between a client and the server simulation
--============================================================================

-- The server simulates the craft from now on: zero input, throttle cut (see the header). `notify` tells the former
-- pilot's client to stop simulating (FlightEnd).
local function takeOver(record: CraftRecord, notify: boolean)
	local sim = record.sim
	local former = record.pilot
	record.pilot = nil
	record.serverSim = true
	if sim == nil then
		return
	end
	FlightModel.setControls(sim, 0, 0, 0, 0, false)
	sim.sasTarget = nil
	lastValid[record.id] = { state = FlightModel.copyState(sim.state), fuel = FlightModel.totalFuel(sim) }
	strikes[record.id] = nil
	if notify and former and former.Parent ~= nil then
		remotes.FlightEnd:FireClient(former, record.id)
	end
end

-- A player sat down in the pilot seat of a craft already in flight: hand the simulation to their client.
local function handBack(player: Player, record: CraftRecord)
	local sim = record.sim
	-- CHANGED (Phase 3/5 merge): a server craft coasting on rails leaves them so its new pilot can fly it
	if sim and record.state == "OnRails" and record.pilot == nil then
		RailsService.takeOffRails(record)
	end
	if sim == nil or record.state ~= "Flying" or record.pilot ~= nil then
		return
	end
	record.pilot = player
	record.serverSim = false
	sim.sasTarget = nil
	lastValid[record.id] = { state = FlightModel.copyState(sim.state), fuel = FlightModel.totalFuel(sim) }
	strikes[record.id] = nil
	local fuel = {}
	for blockId, kg in sim.fuel do
		table.insert(fuel, { blockId, kg })
	end
	local active = {}
	for blockId in sim.active do
		table.insert(active, blockId)
	end
	local resume = { stageIndex = sim.stageIndex, stages = sim.stages, active = active, fuel = fuel }
	remotes.FlightStart:FireClient(
		player,
		record.id,
		Protocol.encodeState(record.id, sim.state),
		sim.stageIndex - 1,
		CraftDesign.toBuffer(sim.physics.design),
		resume
	)
end

-- The pilot of `record` is no longer in its pilot seat. `gone` = they left the game.
local function pilotLeft(record: CraftRecord, player: Player, gone: boolean)
	if record.pilot ~= player or returning[record.id] or ending[record.id] then -- CHANGED (Phase 11): ending guard
		return
	end
	if canReturnToPad(record) then
		-- before ignition the craft goes back to the pad; a pilot who moved to another seat of the same craft
		-- rides back with it instead of being stood beside the pad
		local humanoid = humanoidOf(player)
		local seat = if humanoid then humanoid.SeatPart else nil
		local model = record.model
		local stillAboard = seat ~= nil and model ~= nil and seat:IsDescendantOf(model)
		returnToPad(record, if gone or stillAboard then nil else player)
	else
		takeOver(record, not gone)
	end
end

-- Checks every craft the player pilots against the seat they are in now (seat changes, deaths, leaving).
local function checkPilotSeat(player: Player, gone: boolean)
	for _, record in CraftService.all() do
		if record.pilot == player and (gone or pilotSeatCraft(player) ~= record) then
			pilotLeft(record, player, gone)
		end
	end
end

--============================================================================
-- Remote handlers
--============================================================================

local function onRequestStage(player: Player, craftId: unknown)
	if type(craftId) ~= "number" then
		return
	end
	local record = CraftService.get(craftId)
	if record == nil then
		return
	end
	if record.state == "Prelaunch" then
		if pilotSeatCraft(player) == record then
			task.spawn(FlightService.startFlight, player, record)
		end
		return
	end
	local sim = record.sim
	if sim == nil or record.pilot ~= player then
		return
	end
	RailsService.takeOffRails(record) -- CHANGED (Phase 5): staging ends rails (no-op when not on rails)
	local result = FlightModel.stage(sim)
	if result then
		CraftService.freePad(record.id) -- CHANGED (Phase 2a feedback): the pad is free once engines are lit
		applyStageResult(record, result)
	end
end

local function scaleFuel(sim: FlightModel.Craft, total: number)
	local current = FlightModel.totalFuel(sim)
	if current <= 0 then
		return
	end
	local factor = math.clamp(total / current, 0, 1)
	for id, amount in sim.fuel do
		sim.fuel[id] = amount * factor
	end
	sim.mass = sim.physics.dryMass + FlightModel.totalFuel(sim)
end

local function strike(record: CraftRecord)
	local now = os.clock()
	local entry = strikes[record.id]
	if entry == nil or now - entry.since > STRIKE_WINDOW_S then
		entry = { count = 0, since = now }
		strikes[record.id] = entry
	end
	entry.count += 1
	if entry.count >= STRIKE_LIMIT then
		strikes[record.id] = nil
		local valid = lastValid[record.id]
		local pilot = record.pilot
		if valid and pilot then
			remotes.FlightOverride:FireClient(pilot, record.id, Protocol.encodeState(record.id, valid.state), false)
		end
	end
end

local function onPilotState(player: Player, packet: unknown)
	local craftId, state, fuel = Protocol.decodePilotState(packet)
	if craftId == nil or state == nil or fuel == nil then
		return
	end
	local record = CraftService.get(craftId)
	local sim = if record then record.sim else nil
	if record == nil or sim == nil or record.pilot ~= player then
		return
	end
	-- CHANGED (Phase 5): a pilot state newer than the rail's epoch means the pilot left rails (input or thrust).
	-- Older ones were sent before the craft went on rails and are dropped. The first state off rails is checked
	-- against the rail itself.
	if record.state == "OnRails" then
		local rails = record.rails
		if rails == nil or state.ut <= rails.epochUT then
			return
		end
		local handoff = math.max(rails.epochUT, state.ut - RAILS_HANDOFF_DT)
		local previous = lastValid[record.id]
		RailsService.takeOffRails(record, handoff)
		lastValid[record.id] = {
			state = Rails.stateAt(rails, handoff),
			fuel = if previous then previous.fuel else FlightModel.totalFuel(sim),
		}
	end
	local valid = lastValid[record.id]
	if valid then
		if state.ut <= valid.state.ut then
			return -- stale or duplicate
		end
		local dt = state.ut - valid.state.ut
		if state.bodyId == valid.state.bodyId and dt < 2 then
			local expected = Vec3d.addScaled(valid.state.pos, valid.state.vel, dt)
			local posError = Vec3d.distance(expected, state.pos)
			local dv = Vec3d.distance(state.vel, valid.state.vel)
			if posError > POSITION_TOLERANCE + 0.5 * MAX_ACCEL * dt * dt or dv > MAX_ACCEL * dt + VELOCITY_SLACK then
				strike(record)
				return
			end
		end
		if fuel > valid.fuel + 1 then
			strike(record)
			return
		end
	end
	sim.state = {
		bodyId = state.bodyId,
		pos = state.pos,
		vel = state.vel,
		rot = state.rot,
		angVel = state.angVel,
		throttle = state.throttle,
		flags = state.flags,
		ut = state.ut,
	}
	scaleFuel(sim, fuel)
	lastValid[record.id] = { state = FlightModel.copyState(sim.state), fuel = fuel }
end

local function onReportDestroyed(player: Player, craftId: unknown, ids: unknown, _ut: unknown)
	if type(craftId) ~= "number" or type(ids) ~= "table" then
		return
	end
	local record = CraftService.get(craftId)
	local sim = if record then record.sim else nil
	if record == nil or sim == nil or record.pilot ~= player then
		return
	end
	-- plausibility: the craft must be near the ground
	-- CHANGED (Phase 8): height above the heightmap ground (hills, mountains, craters), not sea level
	local altitude = SurfaceHeight.height(sim.state.bodyId, sim.state.pos)
	if altitude > sim.physics.boundingRadius + CRASH_ALTITUDE_SLACK then
		return
	end
	local clean = {}
	for _, id in ids :: { any } do
		if type(id) == "number" and sim.physics.blockPos[id] and not table.find(clean, id) then
			table.insert(clean, id)
		end
	end
	FlightService.applyDestruction(record, clean)
end

-- CHANGED (Phase 6): the craft record whose seat (any seat) the player occupies (forward: defined with End Flight).
local seatedCraft: (player: Player) -> CraftRecord?

--[[
	CHANGED (Phase 6): a passenger leaves a craft that still waits on its pad (in its flight pocket, nothing ignited):
	they step off beside the pad into the base pocket, placed by the server (identity transfer), like the pilot in
	returnToPad. Anywhere else, leaving a seat starts an EVA.
]]
local function standBesidePad(player: Player, record: CraftRecord)
	local humanoid = humanoidOf(player)
	local character = player.Character
	local pocketId = record.pocketId
	if humanoid == nil or character == nil or pocketId == nil then
		return
	end
	unseat(humanoid)
	local padIndex = CraftService.padOf(record.id)
	local origin = record.origin
	local target = if padIndex
		then BaseLayout.pad(padIndex).top.Position + Vector3.new(-(BaseLayout.PAD_SIZE / 2 + PAD_STEP_OFF), 3, 0)
		else PlotService.spawnCFrame(player).Position
	local look = if padIndex then BaseLayout.pad(padIndex).top.Position else origin.Position
	character:PivotTo(CFrame.lookAt(target, Vector3.new(look.X, target.Y, look.Z)))
	sendTransfer(player, pocketId, PocketService.BASE_POCKET_ID, CFrame.identity, 0)
end

local function onLeaveSeat(player: Player)
	-- CHANGED (Phase 2a feedback): before ignition, standing up puts the craft back on the pad
	local record = pilotSeatCraft(player)
	if record and record.pilot == player and canReturnToPad(record) then
		RailsService.takeOffRails(record) -- CHANGED (Phase 5): a craft on rails leaves them before going to the pad
		returnToPad(record, player)
		return
	end
	-- CHANGED (Phase 6): a passenger of a craft still on its pad steps off beside the pad (base pocket)
	local seated = seatedCraft(player)
	if seated and seated.pilot ~= player and seated.pocketId ~= nil and canReturnToPad(seated) then
		standBesidePad(player, seated)
		return
	end
	local humanoid = humanoidOf(player)
	if humanoid then
		unseat(humanoid)
	end
	-- CHANGED (Phase 3): after ignition the server takes the craft over
	-- CHANGED (Phase 6): and the player is on EVA (their client puts them outside the hatch)
	checkPilotSeat(player, false)
end

-- CHANGED (Phase 2a feedback): a pilot sitting down in a Prelaunch craft starts its flight (physics on the pad).
local function onSeated(player: Player, seat: Seat)
	if seat:GetAttribute("IsPilot") ~= true then
		return
	end
	-- let the seat weld replicate first, so the pilot's client treats itself as seated during the transfer
	task.wait(SEATED_START_DELAY_S)
	local record = pilotSeatCraft(player)
	if record and record.state == "Prelaunch" then
		FlightService.startFlight(player, record)
	elseif record and (record.state == "Flying" or record.state == "OnRails") and record.pilot == nil then
		handBack(player, record) -- CHANGED (Phase 3): a pilot took a server-simulated craft back
	end
end

local function onTransferAck(player: Player, transferId: unknown)
	if type(transferId) ~= "number" then
		return
	end
	local pending = pendingTransfers[transferId]
	if pending and pending.player == player then
		pendingTransfers[transferId] = nil
	end
end

--============================================================================
-- CHANGED (Phase 11): End Flight
--============================================================================

-- The craft record whose seat (any seat) the player occupies, or nil.
-- CHANGED (Phase 6): assigned to the forward declaration above (onLeaveSeat uses it too)
seatedCraft = function(player: Player): CraftRecord?
	local humanoid = humanoidOf(player)
	local seat = if humanoid then humanoid.SeatPart else nil
	local model = if seat then craftModelOf(seat) else nil
	local id = if model then model:GetAttribute("CraftId") else nil
	local record = if type(id) == "number" then CraftService.get(id) else nil
	if record == nil or record.model ~= model then
		return nil
	end
	return record
end

-- Sends one player back to their plot: unseated, stood at their plot spawn by the server, and (from a flight pocket)
-- moved to the base pocket with the identity transform, like the pilot stepping off the pad in returnToPad (the
-- client must not move an already placed character a second time).
-- CHANGED (Night review): the destination is ABSOLUTE for everyone. An astronaut on EVA moves himself (his client
-- places his character every frame, so this server teleport may be overwritten for a frame); the transfer carries
-- the spawn CFrame and his client puts him there (PocketController.onTransfer). Was: an M built from the server's
-- lagging copy of his position, which landed him off by his motion over the lag (km after a recent merge / rebase).
local function sendHome(player: Player, fromPocket: number?)
	local humanoid = humanoidOf(player)
	local character = player.Character
	local home = PlotService.spawnCFrame(player)
	if humanoid and character then
		unseat(humanoid)
		character:PivotTo(home)
	end
	if fromPocket then
		sendTransfer(player, fromPocket, PocketService.BASE_POCKET_ID, CFrame.identity, 0, home)
	end
end

-- The pilot (or the owner aboard) ends the flight: everyone aboard goes home and the craft is removed.
local function endFlight(record: CraftRecord, ender: Player)
	local id = record.id
	if ending[id] or returning[id] or launching[id] then
		return
	end
	ending[id] = true
	RailsService.takeOffRails(record) -- no-op unless the craft is on rails
	local pocketId = record.pocketId
	local model = record.model
	local aboard: { Player } = if model then crewOf(model) else {}
	-- CHANGED (Night review): of the others in its pocket only the astronauts who got out of THIS craft (the craft they
	-- last sat in). Was: everyone in the pocket unless another craft shared it, which sent home an astronaut from
	-- another craft who had floated over (his own craft left uncrewed) and stranded this craft's own astronauts when
	-- an uncrewed craft happened to be in the pocket. Whoever stays gets a new primary or a solo pocket from
	-- BubbleService (CraftService.onRemoving).
	if pocketId then
		for _, player in PocketService.playersIn(pocketId) do
			local humanoid = humanoidOf(player)
			local onFoot = humanoid ~= nil and humanoid.SeatPart == nil
			if onFoot and lastCraft[player] == id and not table.find(aboard, player) then
				table.insert(aboard, player)
			end
		end
	end
	if not table.find(aboard, ender) then
		table.insert(aboard, ender)
	end
	-- nobody pilots it any more: the deferred seat checks of the unseating below must not hand it to the server
	record.pilot = nil
	record.serverSim = false
	for _, player in aboard do
		sendHome(player, pocketId)
	end
	lastValid[id] = nil
	strikes[id] = nil
	CraftService.remove(id) -- CraftRemoved: every client drops its simulation / copy of the craft
	-- CHANGED (Phase 6): BubbleService (CraftService.onRemoving) already re-pointed a shared pocket or released an
	-- empty one; release what is left only if nobody is in it
	if pocketId and PocketService.flightPocket(pocketId) and #PocketService.playersIn(pocketId) == 0 then
		PocketService.releaseFlightPocket(pocketId) -- its release listener finds the craft already gone
	end
	for _, player in aboard do
		if player ~= ender and player.Parent ~= nil then
			remotes.Notify:FireClient(player, `Flight ended by {ender.DisplayName}`, "Info")
		end
	end
	ending[id] = nil
end

local function onEndFlight(player: Player)
	local now = os.clock()
	local last = lastEndFlight[player]
	if last and now - last < END_FLIGHT_COOLDOWN_S then
		return
	end
	lastEndFlight[player] = now
	local record = seatedCraft(player)
	if record == nil then
		-- CHANGED (Phase 6): an astronaut on EVA ("Return to plot") goes home alone
		local humanoid = humanoidOf(player)
		local pocketId = player:GetAttribute("PocketId")
		if
			humanoid
			and humanoid.SeatPart == nil
			and type(pocketId) == "number"
			and pocketId ~= PocketService.BASE_POCKET_ID
		then
			sendHome(player, pocketId)
		end
		return
	end
	if record.isDebris or record.state == "Destroyed" then
		return
	end
	local isPilot = record.pilot == player or pilotSeatCraft(player) == record
	local isOwner = record.ownerUserId == player.UserId
	if isPilot or isOwner then
		endFlight(record, player)
	else
		-- a passenger only leaves; the craft flies on (or stays on its pad)
		sendHome(player, record.pocketId)
	end
end

-- Hands a player's piloted crafts to the server simulation (pilot left, died, or lost the craft).
-- CHANGED (Phase 3): through pilotLeft (cut throttle, FlightEnd; before ignition: back to the pad).
local function releasePilot(player: Player, gone: boolean)
	checkPilotSeat(player, gone)
end

--============================================================================
-- CHANGED (Boarding): boarding a craft in another pocket from the base
--============================================================================

-- The craft's state now: the server copy, or its rail sampled now while it coasts on rails.
local function currentState(record: CraftRecord): FlightModel.CraftState?
	if record.state == "OnRails" then
		local rails = record.rails
		return if rails then Rails.stateAt(rails, UniverseTime.now()) else nil
	end
	local sim = record.sim
	return if sim then sim.state else nil
end

-- The Seat of a block of a real craft model (every seat part has exactly one seat), or nil.
local function seatOfBlock(model: Model, blockId: number): Seat?
	local block = CraftBuilder.findBlockModel(model, blockId)
	if block == nil then
		return nil
	end
	for _, descendant in block:GetDescendants() do
		if descendant:IsA("Seat") then
			return descendant
		end
	end
	return nil
end

--[[
	CHANGED (Night review): gives an uncrewed flying craft that has no real model (`state` = its state now) a Craft
	pocket of its own with its real model in it, placed like BubbleService's AddCraft places one, so its seats can be
	boarded. Returns the new pocket's id, nil when every slot is taken (or the craft has no command part).
]]
local function giveRealModel(record: CraftRecord, state: FlightModel.CraftState): number?
	local sim = record.sim
	local root = if sim then CraftDesign.rootBlock(sim.physics.design) else nil
	if root == nil then
		return nil
	end
	local ut = UniverseTime.now()
	local horizon = Universe.pocketRotation(state.bodyId, state.pos, ut)
	local pocket = PocketService.createFlightPocket(record.id, state.bodyId, state.pos, horizon)
	if pocket == nil then
		return nil
	end
	local frame = Frames.new(state.bodyId, state.pos, horizon, pocket.slotOrigin, PocketService.frameEpoch(pocket.id))
	local craftCFrame = Frames.cframeToWorkspace(frame, state.pos, state.rot)
	local origin = craftCFrame * CFrame.new(-(CraftDesign.blockCenter(root) * CraftDesign.GRID))
	CraftService.buildFlightModel(record, origin, pocket.id, pocket.folder:FindFirstChild("Crafts") or pocket.folder)
	CraftService.announce(record) -- clients learn which pocket draws it now
	return pocket.id
end

local function onBoardCraft(player: Player, craftIdArg: unknown, seatBlockIdArg: unknown)
	local now = os.clock()
	if not Boarding.cooldownOver(lastBoard[player], now, BOARD_COOLDOWN_S) then
		return
	end
	lastBoard[player] = now
	local craftId, seatBlockId = Boarding.validId(craftIdArg), Boarding.validId(seatBlockIdArg)
	if craftId == nil or seatBlockId == nil then
		return
	end

	-- the player: alive, on foot, in the base pocket
	local humanoid = humanoidOf(player)
	local character = player.Character
	local rootPart = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if humanoid == nil or character == nil or rootPart == nil or not rootPart:IsA("BasePart") then
		return
	end
	local root = rootPart :: BasePart
	if humanoid.SeatPart ~= nil or PocketService.pocketAt(root.Position) ~= PocketService.BASE_POCKET_ID then
		return
	end

	-- the craft: flying in its own flight pocket with its real model, not debris, not mid-transition
	local record = CraftService.get(craftId)
	if record == nil or record.isDebris or not Boarding.boardableState(record.state) then
		return
	end
	if launching[craftId] or returning[craftId] or ending[craftId] then
		return
	end
	local sim = record.sim
	if sim == nil then
		return
	end

	-- slow, and close enough (universe positions relative to the base pocket's body)
	-- CHANGED (Night review): checked before the seat (an uncrewed craft may have no real model yet, below)
	local state = currentState(record)
	local baseFrame = PocketService.baseFrame()
	if state == nil or state.bodyId ~= baseFrame.refBodyId then
		return
	end
	if not Boarding.slowEnough(Vec3d.length(state.vel)) then
		remotes.Notify:FireClient(player, "The craft is moving too fast to board", "Error")
		return
	end
	local here = Frames.pointFromWorkspace(baseFrame, root.Position)
	if not Boarding.inRange(Vec3d.distance(here, state.pos), sim.physics.boundingRadius) then
		remotes.Notify:FireClient(player, "You are too far from the craft to board it", "Error")
		return
	end

	-- CHANGED (Night review): an uncrewed craft near the base has no real model (its pocket was released when its
	-- last astronaut went home, and the bubbles never pull crafts near the base into a pocket), so it could never be
	-- boarded again. It gets a Craft pocket of its own with a real model now, like BubbleService's AddCraft; the
	-- pocket is released again if the boarding fails below.
	local created: number? = nil
	if record.model == nil then
		if record.pocketId ~= nil or not CraftService.isBoardable(record) then
			return
		end
		created = giveRealModel(record, state)
		if created == nil then
			remotes.Notify:FireClient(player, "No free flight slot, try again soon", "Error")
			return
		end
	end
	local function abandon()
		local id = created
		if id and PocketService.flightPocket(id) and #PocketService.playersIn(id) == 0 then
			PocketService.releaseFlightPocket(id) -- its release listener takes the model away again
		end
	end

	local model, pocketId = record.model, record.pocketId
	if
		model == nil
		or pocketId == nil
		or PocketService.flightPocket(pocketId) == nil
		or model:GetAttribute("FlightPocket") ~= pocketId
	then
		abandon()
		return
	end

	-- the seat: a free Seat of the real model
	local seat = seatOfBlock(model, seatBlockId)
	if seat == nil then
		abandon()
		return
	end
	if seat.Occupant ~= nil then
		remotes.Notify:FireClient(player, "That seat is taken", "Error")
		return
	end

	-- permission (may yield on the friend check: everything that can change is checked again below)
	if not CrewService.canBoard(player, seat) then
		remotes.Notify:FireClient(player, "The owner hasn't allowed you to board this craft", "Error")
		abandon()
		return
	end
	if
		CraftService.get(craftId) ~= record
		or record.model ~= model
		or record.pocketId ~= pocketId
		or seat.Parent == nil
		or seat.Occupant ~= nil
		or humanoid.SeatPart ~= nil
		or humanoidOf(player) ~= humanoid
	then
		abandon() -- CHANGED (Night review)
		return
	end

	-- a server craft coasting on rails leaves them first (as in handBack); a pilot's rails stay theirs
	if record.state == "OnRails" and record.pilot == nil then
		RailsService.takeOffRails(record)
	end

	-- the SitPrompt seat entry: the character is moved onto the seat in the flight pocket and sits down (a pilot
	-- seat then goes through onSeated: handBack hands a server-simulated craft to this player)
	local before = character:GetPivot()
	if not CrewService.sitIn(player, seat) then
		-- the seat was taken at the last moment: put the character back where it stood if it was already moved
		if humanoid.SeatPart == nil and PocketService.pocketAt(root.Position) ~= PocketService.BASE_POCKET_ID then
			character:PivotTo(before)
		end
		remotes.Notify:FireClient(player, "That seat is taken", "Error")
		abandon() -- CHANGED (Night review)
		return
	end
	-- the server placed the character itself: identity transform, so the client does not move it a second time
	sendTransfer(player, PocketService.BASE_POCKET_ID, pocketId, CFrame.identity, 0)

	local owner = Players:GetPlayerByUserId(record.ownerUserId)
	if owner and owner ~= player then
		remotes.Notify:FireClient(owner, `{player.DisplayName} boarded your craft`, "Info")
	end
end

--============================================================================
-- CHANGED (Solar system): crafts that fly too close to Sol burn up
--============================================================================

-- Every craft closer to a body's centre than its DestroyRadius loses every block (header).
local function burnUpCheck()
	local ut = UniverseTime.now()
	local doomed: { CraftRecord } = {}
	for _, record in CraftService.all() do
		local sim = record.sim
		if sim == nil or ending[record.id] or launching[record.id] then
			continue
		end
		local rails = record.rails
		local s = if record.state == "OnRails" and rails then Rails.stateAt(rails, ut) else sim.state
		local limit = Bodies.get(s.bodyId).DestroyRadius
		if limit and Vec3d.lengthSq(s.pos) < limit * limit then
			table.insert(doomed, record)
		end
	end
	for _, record in doomed do
		local sim = record.sim
		if sim == nil or CraftService.get(record.id) ~= record then
			continue
		end
		RailsService.takeOffRails(record)
		local ids: { number } = {}
		for _, block in sim.physics.design.blocks do
			table.insert(ids, block.id)
		end
		if #ids > 0 then
			local owner = Players:GetPlayerByUserId(record.ownerUserId)
			if owner and not record.isDebris then
				remotes.Notify:FireClient(owner, `{record.design.name} flew too close to Sol and burned up!`, "Error")
			end
			FlightService.applyDestruction(record, ids)
		else
			CraftService.remove(record.id)
		end
	end
end

--============================================================================
-- Lifecycle
--============================================================================

function FlightService.Init()
	for _, name in
		{
			"RequestStage",
			"LeaveSeat",
			"ReportPartsDestroyed",
			"FlightStart",
			"FlightOverride",
			"CraftStaged",
			"PartsDestroyed",
			"PocketTransfer",
			"PocketTransferAck",
			"Notify",
			"FlightEnd", -- CHANGED (Phase 3)
			"EndFlight", -- CHANGED (Phase 11)
			"BoardCraft", -- CHANGED (Boarding)
		}
	do
		remotes[name] = Remotes.event(name)
	end
end

function FlightService.Start()
	CrewService.onSeated(onSeated)
	remotes.RequestStage.OnServerEvent:Connect(onRequestStage)
	remotes.ReportPartsDestroyed.OnServerEvent:Connect(onReportDestroyed)
	remotes.LeaveSeat.OnServerEvent:Connect(onLeaveSeat)
	remotes.PocketTransferAck.OnServerEvent:Connect(onTransferAck)
	remotes.EndFlight.OnServerEvent:Connect(onEndFlight) -- CHANGED (Phase 11)
	remotes.BoardCraft.OnServerEvent:Connect(onBoardCraft) -- CHANGED (Boarding)
	Remotes.unreliable("PilotState").OnServerEvent:Connect(onPilotState)

	Players.PlayerRemoving:Connect(function(player: Player)
		releasePilot(player, true)
		lastEndFlight[player] = nil -- CHANGED (Phase 11)
		lastBoard[player] = nil -- CHANGED (Boarding)
		lastCraft[player] = nil -- CHANGED (Night review)
	end)
	local function watchCharacter(player: Player, character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				releasePilot(player, false)
			end)
			-- CHANGED (Phase 3): any way of leaving the pilot seat hands the craft over (deferred, so the code that
			-- unseated the pilot finishes first, e.g. returnToPad)
			humanoid:GetPropertyChangedSignal("SeatPart"):Connect(function()
				-- CHANGED (Night review): remember the craft the player sits in (End Flight: whose astronauts go home)
				local seat = humanoid.SeatPart
				local model = if seat then craftModelOf(seat) else nil
				local id = if model then model:GetAttribute("CraftId") else nil
				if type(id) == "number" then
					lastCraft[player] = id
				end
				task.defer(checkPilotSeat, player, false)
			end)
		end
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(function(character: Model)
			watchCharacter(player, character)
		end)
		if player.Character then
			task.spawn(watchCharacter, player, player.Character)
		end
		-- CHANGED (Phase 3): the join snapshot is sent by CraftService when the client asks (RequestSnapshot)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end

	-- When a flight pocket empties, its craft carries on uncrewed as a server-simulated craft.
	-- CHANGED (Phase 6): every craft whose model is in it (primary and secondaries); a Solo pocket may have none
	PocketService.onReleased(function(pocket)
		local inPocket: { CraftRecord } = {}
		for _, record in CraftService.all() do
			if record.pocketId == pocket.id then -- gone, or already moved back to the pad (returnToPad), are skipped
				table.insert(inPocket, record)
			end
		end
		for _, record in inPocket do
			if record.model then
				(record.model :: Model):Destroy()
				record.model = nil
			end
			record.pocketId = nil
			takeOver(record, true) -- CHANGED (Phase 3): uncrewed: zero input, throttle cut
			CraftService.announce(record)
		end
	end)

	-- CHANGED (Solar system): crafts too close to Sol burn up
	task.spawn(function()
		while true do
			task.wait(BURN_CHECK_S)
			local ok, err = pcall(function()
				burnUpCheck()
			end)
			if not ok then
				warn(`[FlightService] burn-up check failed: {err}`)
			end
		end
	end)

	-- Transfer acks: teleport unseated crew the server never heard back from.
	task.spawn(function()
		while true do
			task.wait(0.5)
			local now = os.clock()
			for id, pending in pendingTransfers do
				if now > pending.deadline then
					pendingTransfers[id] = nil
					local humanoid = humanoidOf(pending.player)
					local character = pending.player.Character
					local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
					if humanoid and humanoid.SeatPart == nil and root and root:IsA("BasePart") then
						root.CFrame = pending.m * root.CFrame
					end
				end
			end
		end
	end)
end

--============================================================================
-- CHANGED (Phase 6): for BubbleService and EvaService
--============================================================================

-- Sends a PocketTransfer (and moves the player's PocketId, pinned for a moment: PocketService.pin).
-- CHANGED (Night review): `absolute` = where the server already put the character (see sendTransfer).
function FlightService.sendTransfer(
	player: Player,
	source: number,
	dest: number,
	m: CFrame,
	epoch: number,
	absolute: CFrame?
)
	sendTransfer(player, source, dest, m, epoch, absolute)
end

-- Bumps a real craft model's PoseEpoch after a server-side move (clients re-read the part offsets).
function FlightService.bumpPoseEpoch(model: Model)
	bumpPoseEpoch(model)
end

-- Is a craft in the middle of launching, returning to its pad or ending its flight? (Leave it alone then.)
function FlightService.isBusy(craftId: number): boolean
	return launching[craftId] == true or returning[craftId] == true or ending[craftId] == true
end

-- Sends one player back to their plot (base pocket), from `fromPocket` (nil = already in the base).
function FlightService.sendHome(player: Player, fromPocket: number?)
	sendHome(player, fromPocket)
end

return FlightService
