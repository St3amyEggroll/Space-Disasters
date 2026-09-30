--!strict
--[[
	SaveService
	Persists craft designs (spec 7.12). DataStore "Designs_v1", key "U_<userId>":
	  { version = 1, slots = { ["1"] .. ["10"] = <design JSON> }, current = <design JSON>? }
	`slots` are the player's 10 save slots. `current` (addition, see DECISIONS D12) is the hangar contents,
	saved on leave and restored on the next join.

	Data is loaded on join, cached in memory, and written with UpdateAsync on explicit saves, on leave and on
	shutdown, with retries and exponential backoff. If DataStores are unavailable (e.g. Studio without API
	access), everything keeps working in memory for the session and a warning is printed once.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local STORE_NAME = "Designs_v1"
local DATA_VERSION = 1
local MAX_ATTEMPTS = 5
local BACKOFF_BASE_S = 1 -- 1, 2, 4, 8 s between attempts
local LOAD_WAIT_TIMEOUT_S = 30
--============================================================================

export type SaveData = {
	version: number,
	slots: { [string]: string },
	current: string?,
}

type Entry = {
	data: SaveData,
	loaded: boolean,
	loadFailed: boolean, -- never write over stored data we could not read
	dirty: boolean,
	loadedSignal: BindableEvent,
}

local SaveService = {}

local store: DataStore? = nil
local storeUnavailableWarned = false
local entries: { [Player]: Entry } = {}
local pendingWrites = 0
local memory: { [number]: SaveData } = {} -- session-only copy used when DataStores are unavailable
local shutdownHooks: { () -> () } = {}

local function emptyData(): SaveData
	return { version = DATA_VERSION, slots = {}, current = nil }
end

local function key(userId: number): string
	return `U_{userId}`
end

local function sanitize(raw: any): SaveData
	local data = emptyData()
	if type(raw) ~= "table" then
		return data
	end
	if type(raw.slots) == "table" then
		for slotKey, json in raw.slots do
			local slot = tonumber(slotKey)
			if slot and slot >= 1 and slot <= GameConfig.SAVE_SLOTS and slot % 1 == 0 and type(json) == "string" then
				data.slots[tostring(slot)] = json
			end
		end
	end
	if type(raw.current) == "string" then
		data.current = raw.current
	end
	return data
end

-- Errors that mean "DataStores cannot work in this session at all" (unpublished place / Studio API access off).
local FATAL_PATTERNS = { "API Services", "StudioAccessToApisNotAllowed", "unpublished", "not allowed" }

local function isFatal(message: string): boolean
	for _, pattern in FATAL_PATTERNS do
		if string.find(message, pattern, 1, true) then
			return true
		end
	end
	return false
end

local warnUnavailable: (reason: string) -> ()

local function withRetries<T>(label: string, action: () -> T): (boolean, T?)
	for attempt = 1, MAX_ATTEMPTS do
		local ok, result = pcall(action)
		if ok then
			return true, result
		end
		if isFatal(tostring(result)) then
			store = nil
			warnUnavailable(tostring(result))
			return false, nil
		end
		warn(`[SaveService] {label} failed (attempt {attempt}/{MAX_ATTEMPTS}): {result}`)
		if attempt < MAX_ATTEMPTS then
			task.wait(BACKOFF_BASE_S * 2 ^ (attempt - 1))
		end
	end
	return false, nil
end

warnUnavailable = function(reason: string)
	if not storeUnavailableWarned then
		storeUnavailableWarned = true
		warn(
			`[SaveService] DataStores unavailable ({reason}). Saves will only last this session. In Studio: `
				.. "Game Settings > Security > Enable Studio Access to API Services (the place must be published)."
		)
	end
end

local function load(player: Player)
	local entry: Entry = {
		data = emptyData(),
		loaded = false,
		loadFailed = false,
		dirty = false,
		loadedSignal = Instance.new("BindableEvent"),
	}
	entries[player] = entry
	local activeStore = store
	if activeStore then
		local ok, raw = withRetries(`load {player.UserId}`, function()
			return activeStore:GetAsync(key(player.UserId))
		end)
		if ok then
			entry.data = sanitize(raw)
		elseif store ~= nil then
			entry.loadFailed = true
			warn(`[SaveService] could not load saves for {player.Name}; saving is disabled for them this session`)
		end
	end
	if store == nil and memory[player.UserId] then
		entry.data = memory[player.UserId]
	end
	entry.loaded = true
	entry.loadedSignal:Fire()
end

local function write(userId: number, data: SaveData): boolean
	local activeStore = store
	if activeStore == nil then
		return false
	end
	pendingWrites += 1
	local ok = withRetries(`save {userId}`, function()
		activeStore:UpdateAsync(key(userId), function(old: any)
			-- merge over whatever is stored so a slot we never loaded can't be wiped
			local merged = sanitize(old)
			for slotKey, json in data.slots do
				merged.slots[slotKey] = json
			end
			merged.current = data.current
			return { version = DATA_VERSION, slots = merged.slots, current = merged.current }
		end)
		return true
	end)
	pendingWrites -= 1
	return ok
end

local function flush(player: Player)
	local entry = entries[player]
	if entry and store == nil and entry.loaded then
		memory[player.UserId] = entry.data
	end
	if entry and entry.loaded and entry.dirty and not entry.loadFailed then
		entry.dirty = false
		if not write(player.UserId, entry.data) and store ~= nil then
			entry.dirty = true
		end
	end
end

function SaveService.Init()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warnUnavailable(tostring(result))
	end
end

function SaveService.Start()
	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		if entries[player] == nil then
			task.spawn(load, player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		flush(player)
		local entry = entries[player]
		entries[player] = nil
		if entry then
			entry.loadedSignal:Fire() -- release anyone still waiting in waitForLoad
			entry.loadedSignal:Destroy()
		end
	end)
	game:BindToClose(function()
		for _, hook in shutdownHooks do
			pcall(hook)
		end
		for player in entries do
			task.spawn(flush, player)
		end
		-- give the writes time to finish (BindToClose allows up to 30 s)
		local deadline = os.clock() + 25
		while os.clock() < deadline do
			local busy = pendingWrites > 0
			for _, entry in entries do
				if entry.dirty and store ~= nil and not entry.loadFailed then
					busy = true
				end
			end
			if not busy then
				break
			end
			task.wait(0.5)
		end
	end)
end

-- Yields until the player's saves are loaded (or the timeout passes). Returns false if not loaded.
function SaveService.waitForLoad(player: Player): boolean
	local entry = entries[player]
	local deadline = os.clock() + LOAD_WAIT_TIMEOUT_S
	while entry == nil and os.clock() < deadline and player.Parent do
		task.wait(0.1)
		entry = entries[player]
	end
	if entry == nil then
		return false
	end
	if not entry.loaded and entries[player] == entry then
		entry.loadedSignal.Event:Wait()
	end
	return entry.loaded and entries[player] == entry
end

-- Slot index -> design name for the filled slots (names read from the saved JSON's "name" field by the caller).
function SaveService.getSlots(player: Player): { [number]: string }
	local entry = entries[player]
	local result: { [number]: string } = {}
	if entry then
		for slotKey, json in entry.data.slots do
			local slot = tonumber(slotKey)
			if slot then
				result[slot] = json
			end
		end
	end
	return result
end

function SaveService.getSlot(player: Player, slot: number): string?
	local entry = entries[player]
	return if entry then entry.data.slots[tostring(slot)] else nil
end

-- Stores a design JSON in a slot and writes it out (yields).
function SaveService.setSlot(player: Player, slot: number, json: string): boolean
	local entry = entries[player]
	if entry == nil or not entry.loaded then
		return false
	end
	entry.data.slots[tostring(slot)] = json
	entry.dirty = true
	flush(player)
	return true
end

function SaveService.getCurrent(player: Player): string?
	local entry = entries[player]
	return if entry then entry.data.current else nil
end

-- Remembers the hangar contents; written on leave/shutdown (not immediately).
function SaveService.setCurrent(player: Player, json: string?)
	local entry = entries[player]
	if entry and entry.loaded then
		entry.data.current = json
		entry.dirty = true
	end
end

-- Runs before the final flush on server shutdown (e.g. to capture hangar contents into `current`).
function SaveService.addShutdownHook(hook: () -> ())
	table.insert(shutdownHooks, hook)
end

-- True when saves persist beyond this server session.
function SaveService.isPersistent(): boolean
	return store ~= nil
end

return SaveService
