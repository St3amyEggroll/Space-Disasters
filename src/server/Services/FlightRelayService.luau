--!strict
--[[
	FlightRelayService (Phase 2a; CHANGED Phase 3: per-client interest management)
	Streams flying crafts' states to clients over the unreliable CraftStates remote, batched by Protocol
	(<= MAX_STATES_PER_PACKET per packet, under the unreliable payload limit). Passengers use the stream for their
	pocket frame; everyone else for cosmetic copies, markers and puppets.

	Every relay tick (CRAFT_STATE_RATE) each streamable craft's state is encoded ONCE; then, per client:
	  * the craft's tier (Shared/Net/Interest): in the client's pocket, or within INTEREST_NEAR (50 km true distance,
	    doubles, across bodies) of the client's pocket reference -> 20 Hz; same SOI beyond that -> 2 Hz;
	    everything else -> 0.5 Hz;
	  * Interest.allocate keeps the client under CRAFT_STATES_BUDGET (nearest crafts stay at full rate);
	  * a per-(client, craft) send credit (Interest.advance) decides whether this tick carries the craft;
	  * the due states are packed (Protocol.packStateBlocks) and fired to that client only.
	A pilot is never sent its own craft (its client simulates it); it gets the stream again the moment the server
	takes the craft over.

	Stream predicate: a craft is streamed only while it is simulated and "Flying". Crafts "OnRails" (Phase 5) are
	NEVER streamed (clients propagate rails themselves); other systems can add exclusions with addStreamFilter.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Interest = require(ReplicatedStorage.Shared.Net.Interest)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local CraftService = require(script.Parent.CraftService)
local PocketService = require(script.Parent.PocketService)

type CraftRecord = CraftService.CraftRecord

--============================================================================
-- Tunables
--============================================================================
local INTERVAL_S = 1 / GameConfig.CRAFT_STATE_RATE
local MAX_TICK_DT = 0.25 -- s; a long server hitch does not turn into a burst of sends
local BUDGET = GameConfig.CRAFT_STATES_BUDGET -- payload bytes per second per client
local CLEANUP_INTERVAL_S = 5 -- s between sweeps of send credits for crafts that are gone
--============================================================================

export type StreamFilter = (record: CraftRecord) -> boolean

type ClientState = {
	credits: { [number]: number }, -- craft id -> send credit (Interest.advance)
	bytes: number, -- payload bytes sent in the current second
	bytesPerSecond: number, -- last full second
	windowStart: number,
}

local FlightRelayService = {}

local remote: UnreliableRemoteEvent
local elapsed = 0
local cleanupTimer = 0
local clients: { [Player]: ClientState } = {}
local streamFilters: { StreamFilter } = {}

-- Is this craft streamed at all? (Before interest management.)
function FlightRelayService.shouldStream(record: CraftRecord): boolean
	if record.sim == nil or record.state ~= "Flying" then
		return false -- Prelaunch, Landed (sleeping), OnRails (Phase 5: clients propagate rails), Destroyed
	end
	for _, filter in streamFilters do
		if not filter(record) then
			return false
		end
	end
	return true
end

-- Adds a predicate a craft must pass to be streamed (e.g. Phase 5 rails bookkeeping).
function FlightRelayService.addStreamFilter(filter: StreamFilter)
	table.insert(streamFilters, filter)
end

-- CraftStates payload bytes sent to a player during the last full second (debug / budget checks).
function FlightRelayService.bytesPerSecond(player: Player): number
	local client = clients[player]
	return if client then client.bytesPerSecond else 0
end

local function clientOf(player: Player): ClientState
	local client = clients[player]
	if client == nil then
		client = { credits = {}, bytes = 0, bytesPerSecond = 0, windowStart = os.clock() }
		clients[player] = client
	end
	return client
end

-- The reference of the pocket a player is in: (pocket id, body id, position relative to that body).
local function pocketReference(player: Player): (number, number, Vec3d.Vec3d)
	local id = player:GetAttribute("PocketId")
	local pocketId = if type(id) == "number" then id else PocketService.BASE_POCKET_ID
	if pocketId ~= PocketService.BASE_POCKET_ID then
		local pocket = PocketService.flightPocket(pocketId)
		-- CHANGED (Phase 6): a craft pocket's primary craft (craftId is nil for an astronaut's solo pocket)
		local craftId = if pocket then pocket.craftId else nil
		local record = if craftId then CraftService.get(craftId) else nil
		local sim = if record then record.sim else nil
		if sim then
			return pocketId, sim.state.bodyId, sim.state.pos
		end
		-- CHANGED (Phase 6): a solo pocket's reference
		local bodyId, pos = PocketService.soloReference(pocketId, UniverseTime.now())
		if bodyId and pos then
			return pocketId, bodyId, pos
		end
	end
	local base = PocketService.baseFrame()
	return pocketId, base.refBodyId, base.refPos
end

local function broadcast(dt: number)
	local now = os.clock()
	local ut = UniverseTime.now()

	-- Encode every streamable craft once for all clients.
	local records: { CraftRecord } = {}
	local blocks: { buffer } = {}
	for id, record in CraftService.all() do
		local sim = record.sim
		if sim and FlightRelayService.shouldStream(record) then
			table.insert(records, record)
			table.insert(blocks, Protocol.encodeState(id, sim.state))
		end
	end

	-- body offsets are shared by every client this tick
	local offsets: { [string]: Vec3d.Vec3d } = {}
	local function bodyOffset(from: number, to: number): Vec3d.Vec3d
		local key = `{from}>{to}`
		local cached = offsets[key]
		if cached == nil then
			cached = Universe.bodyOffset(from, to, ut)
			offsets[key] = cached
		end
		return cached
	end

	for _, player in Players:GetPlayers() do
		local client = clientOf(player)
		if now - client.windowStart >= 1 then
			client.bytesPerSecond = client.bytes / (now - client.windowStart)
			client.bytes = 0
			client.windowStart = now
		end
		if #records == 0 then
			continue
		end
		local pocketId, refBody, refPos = pocketReference(player)
		local demands: { Interest.Demand } = {}
		local indices: { number } = {}
		for index, record in records do
			local sim = record.sim
			if sim == nil or record.pilot == player then
				continue -- its own client simulates it
			end
			local state = sim.state
			local distance: number
			if state.bodyId == refBody then
				distance = Vec3d.distance(state.pos, refPos)
			else
				local offset = bodyOffset(state.bodyId, refBody)
				local dx = state.pos.x + offset.x - refPos.x
				local dy = state.pos.y + offset.y - refPos.y
				local dz = state.pos.z + offset.z - refPos.z
				distance = math.sqrt(dx * dx + dy * dy + dz * dz)
			end
			local samePocket = record.pocketId ~= nil and record.pocketId == pocketId
			table.insert(demands, {
				tier = Interest.classify(samePocket, state.bodyId == refBody, distance),
				distance = distance,
				debris = record.isDebris,
			})
			table.insert(indices, index)
		end
		if #demands == 0 then
			continue
		end
		local rates = Interest.allocate(demands, BUDGET)
		local due: { buffer } = {}
		for k, index in indices do
			local id = records[index].id
			local credit = client.credits[id]
			if credit == nil then
				credit = Interest.initialCredit(id, demands[k].tier)
			end
			local send
			credit, send = Interest.advance(credit, rates[k], dt)
			client.credits[id] = credit
			if send then
				table.insert(due, blocks[index])
			end
		end
		for _, packet in Protocol.packStateBlocks(due) do
			remote:FireClient(player, packet)
			client.bytes += buffer.len(packet)
		end
	end
end

-- Forgets send credits of crafts that no longer exist.
local function cleanup()
	local crafts = CraftService.all()
	for _, client in clients do
		for id in client.credits do
			if crafts[id] == nil then
				client.credits[id] = nil
			end
		end
	end
end

function FlightRelayService.Init()
	remote = Remotes.unreliable("CraftStates")
end

function FlightRelayService.Start()
	Players.PlayerRemoving:Connect(function(player: Player)
		clients[player] = nil
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		cleanupTimer += dt
		if elapsed >= INTERVAL_S then
			local tickDt = math.min(elapsed, MAX_TICK_DT)
			elapsed = 0
			broadcast(tickDt)
		end
		if cleanupTimer >= CLEANUP_INTERVAL_S then
			cleanupTimer = 0
			cleanup()
		end
	end)
end

return FlightRelayService
