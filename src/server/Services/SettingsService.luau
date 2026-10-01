--!strict
--[[
	SettingsService (Phase 11)
	Keeps each player's settings (SettingsSchema JSON) with the rest of their saves (SaveService `settings`, written
	to the DataStore on leave / shutdown).

	RequestSettings (client -> server, ()): waits until the player's saves are loaded, then answers SettingsData
	  with the stored JSON re-sanitized (decode + encode), or nil when nothing is stored or the saves could not be
	  loaded. One request at a time per player, at most one per REQUEST_COOLDOWN_S (extra requests are dropped; the
	  pending one answers).
	SaveSettings (client -> server, (json)): must be a string of at most SettingsSchema.MAX_JSON_BYTES. It is decoded,
	  sanitized and re-encoded before it is stored, so only valid settings are ever saved. At most one payload per
	  SAVE_INTERVAL_S is applied per player: newer payloads that arrive sooner replace the pending one, which is
	  applied when the interval has passed (by one worker thread per player, so they are applied in order). A
	  pending payload is handed in before the player's data is flushed on leave (SaveService leave hook) or on
	  shutdown (shutdown hook). Saves that arrive before the player's saves are loaded wait for the load.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local SaveService = require(script.Parent.SaveService)

--============================================================================
-- Tunables
--============================================================================
local SAVE_INTERVAL_S = 1 -- at most one stored settings payload per player per this many seconds
local REQUEST_COOLDOWN_S = 1 -- RequestSettings accepted at most this often per player
local MAX_JSON_BYTES = SettingsSchema.MAX_JSON_BYTES
--============================================================================

type PlayerState = {
	pending: string?, -- latest valid payload not stored yet
	working: boolean, -- a worker thread is applying pending payloads
	lastSave: number, -- os.clock() of the last stored payload
	requesting: boolean, -- a RequestSettings is waiting for the load
	lastRequest: number,
}

local SettingsService = {}

local dataRemote: RemoteEvent
local states: { [Player]: PlayerState } = {}

local function stateFor(player: Player): PlayerState
	local state = states[player]
	if state == nil then
		state = { pending = nil, working = false, lastSave = -math.huge, requesting = false, lastRequest = -math.huge }
		states[player] = state
	end
	return state :: PlayerState
end

-- Sanitizes and stores one payload (never yields).
local function store(player: Player, json: string)
	SaveService.setSettings(player, SettingsSchema.encode(SettingsSchema.decode(json)))
end

-- Applies the latest pending payload, then waits out the interval before the next one; exits when none is left.
local function work(player: Player, state: PlayerState)
	if not SaveService.waitForLoad(player) then
		state.pending = nil
		state.working = false
		return
	end
	while state.pending ~= nil and states[player] == state do
		local remaining = state.lastSave + SAVE_INTERVAL_S - os.clock()
		if remaining > 0 then
			task.wait(remaining)
		end
		local json = state.pending
		if states[player] ~= state or json == nil then
			break -- the player left: the leave hook already handed the payload in
		end
		state.pending = nil
		state.lastSave = os.clock()
		store(player, json)
	end
	state.working = false
end

local function onSave(player: Player, json: unknown)
	if player.Parent == nil or type(json) ~= "string" or #json > MAX_JSON_BYTES then
		return
	end
	local state = stateFor(player)
	state.pending = json
	if not state.working then
		state.working = true
		task.spawn(work, player, state)
	end
end

local function onRequest(player: Player)
	if player.Parent == nil then
		return
	end
	local state = stateFor(player)
	local now = os.clock()
	if state.requesting or now - state.lastRequest < REQUEST_COOLDOWN_S then
		return
	end
	state.requesting = true
	state.lastRequest = now
	local loaded = SaveService.waitForLoad(player)
	state.requesting = false
	if states[player] ~= state then
		return -- the player left (the leave hook dropped the state)
	end
	local stored = if loaded then SaveService.getSettings(player) else nil
	dataRemote:FireClient(player, if stored then SettingsSchema.encode(SettingsSchema.decode(stored)) else nil)
end

-- Hands a pending payload in before SaveService writes the player's data out.
local function handInPending(player: Player)
	local state = states[player]
	local json = if state then state.pending else nil
	if state and json then
		state.pending = nil
		store(player, json)
	end
end

function SettingsService.Init()
	dataRemote = Remotes.event("SettingsData")
end

function SettingsService.Start()
	Remotes.event("RequestSettings").OnServerEvent:Connect(onRequest)
	Remotes.event("SaveSettings").OnServerEvent:Connect(onSave)
	SaveService.addLeaveHook(function(player: Player)
		handInPending(player)
		states[player] = nil
	end)
	SaveService.addShutdownHook(function()
		for player in states do
			handInPending(player)
		end
	end)
end

return SettingsService
