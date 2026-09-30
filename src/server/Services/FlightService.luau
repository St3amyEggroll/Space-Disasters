--!strict
--[[
	FlightService (Phase 2a)
	Server side of flying: launch, staging, the pilot's state stream, crashes and crew safety.

	Launch (spec 7.5): the seated pilot of a Prelaunch craft presses Space (RequestStage). The server allocates a
	CRAFT_ALIGNED flight pocket whose reference is the craft's root pose, moves the real craft model into it with
	one rigid transform M (seated crew ride along with their anchored seats, S9), sends PocketTransfer to every
	crew member (unseated ones move themselves by M and ack; the server teleports them after 3 s without an ack),
	waits LAUNCH_COUNTDOWN_S, then creates the simulation, fires stage 1 and hands the simulation to the pilot's
	client (FlightStart).

	In flight the pilot's client simulates; its PilotState (20 Hz) is validated and becomes the server copy's
	state. Staging and part destruction are applied to the server copy (authoritative): separated pieces become
	server-simulated debris (CraftService.spawnDebris), their block models are removed from the real model, and
	every client is told (CraftStaged / PartsDestroyed). If the pilot leaves or dies, the server takes over the
	simulation (ServerSimService).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local CraftService = require(script.Parent.CraftService)
local PocketService = require(script.Parent.PocketService)

type CraftRecord = CraftService.CraftRecord

--============================================================================
-- Tunables
--============================================================================
local COUNTDOWN_S = GameConfig.LAUNCH_COUNTDOWN_S
local ACK_TIMEOUT_S = GameConfig.POCKET_TRANSFER_ACK_TIMEOUT
local CREW_BOUNDS_MARGIN = 4 -- studs around a craft's bounding box that count as "aboard"
local POSITION_TOLERANCE = 50 -- m: |dpos - vel*dt| allowed between pilot states
local MAX_ACCEL = 250 -- m/s^2 of velocity change allowed between pilot states (generous)
local VELOCITY_SLACK = 2 -- m/s
local STRIKE_LIMIT = 3
local STRIKE_WINDOW_S = 5
local CRASH_ALTITUDE_SLACK = 150 -- m above the craft's size where a reported crash is still plausible
local LAUNCH_THROTTLE = 1
--============================================================================

local FlightService = {}

type Strikes = { count: number, since: number }
type PendingTransfer = { player: Player, m: CFrame, deadline: number }

local launching: { [number]: boolean } = {}
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

-- Players aboard a real craft model: seated in it, or standing inside its bounding box.
local function crewOf(model: Model): { Player }
	local crew = {}
	local cf, size = model:GetBoundingBox()
	local half = size / 2 + Vector3.one * CREW_BOUNDS_MARGIN
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = humanoidOf(player)
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if humanoid and root and root:IsA("BasePart") then
			local seat = humanoid.SeatPart
			local aboard = seat ~= nil and seat:IsDescendantOf(model)
			if not aboard then
				local p = cf:PointToObjectSpace(root.Position)
				aboard = math.abs(p.X) <= half.X and math.abs(p.Y) <= half.Y and math.abs(p.Z) <= half.Z
			end
			if aboard then
				table.insert(crew, player)
			end
		end
	end
	return crew
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

local function sendTransfer(player: Player, source: number, dest: number, m: CFrame, epoch: number)
	local id = nextTransferId
	nextTransferId += 1
	player:SetAttribute("PocketId", dest)
	pendingTransfers[id] = { player = player, m = m, deadline = os.clock() + ACK_TIMEOUT_S }
	remotes.PocketTransfer:FireClient(player, id, source, dest, m, epoch)
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
		if record.pocketId then
			for _, player in PocketService.playersIn(record.pocketId :: number) do
				kill(player)
			end
		end
		CraftService.remove(record.id)
	end
end

--============================================================================
-- Launch
--============================================================================

local function launch(player: Player, record: CraftRecord)
	local model = record.model
	if model == nil or launching[record.id] then
		return
	end
	launching[record.id] = true
	model:SetAttribute("State", "Launching")

	-- The root block's true pose on the pad (craft axes = design axes, placed with record.origin).
	local root = CraftDesign.rootBlock(record.design) :: CraftDesign.Block
	local rootWorld = record.origin * CFrame.new(CraftDesign.blockCenter(root) * CraftDesign.GRID)
	local baseFrame = PocketService.baseFrame()
	local pos, rot = Frames.cframeFromWorkspace(baseFrame, rootWorld)

	local pocket = PocketService.createFlightPocket(record.id, Bodies.HOMEWORLD, pos, rot)
	if pocket == nil then
		launching[record.id] = nil
		model:SetAttribute("State", "Prelaunch")
		remotes.Notify:FireClient(player, "No free flight slot, try again soon", "Error")
		return
	end
	local newFrame = Frames.new(Bodies.HOMEWORLD, pos, rot, pocket.slotOrigin, 0)
	local m = Frames.relativeTransform(baseFrame, newFrame)

	local crew = crewOf(model)
	model:PivotTo(m * model:GetPivot())
	model.Parent = pocket.folder:FindFirstChild("Crafts")
	record.pocketId = pocket.id
	CraftService.freePad(record.id)
	for _, member in crew do
		sendTransfer(member, 0, pocket.id, m, 0)
	end

	task.wait(COUNTDOWN_S)
	launching[record.id] = nil
	if CraftService.get(record.id) ~= record then
		return -- removed during the countdown
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

	local pilotRecord = pilotSeatCraft(player)
	if pilotRecord == record then
		record.pilot = player
		record.serverSim = false
	else
		record.pilot = nil
		record.serverSim = true
	end

	local result = FlightModel.stage(sim)
	lastValid[record.id] = { state = FlightModel.copyState(sim.state), fuel = FlightModel.totalFuel(sim) }
	if record.pilot then
		remotes.FlightStart:FireClient(
			player,
			record.id,
			Protocol.encodeState(record.id, sim.state),
			1,
			CraftDesign.toBuffer(record.design)
		)
	end
	CraftService.announce(record)
	if result then
		applyStageResult(record, result)
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
			task.spawn(launch, player, record)
		end
		return
	end
	local sim = record.sim
	if sim == nil or record.pilot ~= player then
		return
	end
	local result = FlightModel.stage(sim)
	if result then
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
	local altitude = Vec3d.length(sim.state.pos) - Bodies.get(sim.state.bodyId).Radius
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

local function onLeaveSeat(player: Player)
	local humanoid = humanoidOf(player)
	if humanoid then
		unseat(humanoid)
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

-- Hands a player's piloted crafts to the server simulation (pilot left, died, or lost the craft).
local function releasePilot(player: Player)
	for _, record in CraftService.all() do
		if record.pilot == player then
			record.pilot = nil
			record.serverSim = true
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
		}
	do
		remotes[name] = Remotes.event(name)
	end
end

function FlightService.Start()
	remotes.RequestStage.OnServerEvent:Connect(onRequestStage)
	remotes.ReportPartsDestroyed.OnServerEvent:Connect(onReportDestroyed)
	remotes.LeaveSeat.OnServerEvent:Connect(onLeaveSeat)
	remotes.PocketTransferAck.OnServerEvent:Connect(onTransferAck)
	Remotes.unreliable("PilotState").OnServerEvent:Connect(onPilotState)

	Players.PlayerRemoving:Connect(releasePilot)
	local function watchCharacter(player: Player, character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				releasePilot(player)
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
		-- join snapshot: every craft already in flight
		for _, record in CraftService.all() do
			if record.sim then
				CraftService.announce(record, player)
			end
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end

	-- When a flight pocket empties, its craft carries on uncrewed as a server-simulated craft.
	PocketService.onReleased(function(pocket)
		local record = CraftService.get(pocket.craftId)
		if record == nil then
			return
		end
		if record.model then
			(record.model :: Model):Destroy()
			record.model = nil
		end
		record.pocketId = nil
		record.pilot = nil
		record.serverSim = true
		CraftService.announce(record)
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

return FlightService
