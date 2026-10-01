--!strict
--[[
	SettingsController (Phase 11)
	Loads the player's settings from the server once, saves them after the player changes them, and applies the
	audio settings. The settings themselves live in Settings/Settings (the store); UI code changes them there.

	Sound groups: Init creates (or adopts) SoundService.Music and SoundService.Effects and keeps their Volume equal to
	the musicVolume / effectsVolume settings, live. EVERY sound added to the game must play through one of them
	(Sound.SoundGroup = SettingsController.musicGroup() or effectsGroup(); on the server, the groups of the same
	names under SoundService) or the volume sliders will not reach it.

	Load: Start connects SettingsData, then fires RequestSettings; if nothing arrives within RETRY_AFTER_S it asks
	once more, and if still nothing arrives within GIVE_UP_AFTER_S it starts from the defaults (with a warning).
	The answer goes to Settings.applyLoaded, which is not a user change, so nothing is saved back.
	Save: after a user change (Settings.isDirty) it waits for SAVE_DEBOUNCE_S without further changes (at most
	SAVE_MAX_DELAY_S after the first unsaved change, so dragging a slider for a long time still saves), then fires
	SaveSettings(SettingsSchema.encode(current)). Clients cannot save while the game closes, so the debounce stays
	short. Nothing is sent before the saved values arrived (early changes are merged over them, then saved).

	API:
	  SettingsController.musicGroup() -> SoundGroup
	  SettingsController.effectsGroup() -> SoundGroup
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local Settings = require(script.Parent.Parent.Settings.Settings)

--============================================================================
-- Tunables
--============================================================================
local MUSIC_GROUP_NAME = "Music"
local EFFECTS_GROUP_NAME = "Effects"
local RETRY_AFTER_S = 5 -- ask again when the first request got no answer in this time
local GIVE_UP_AFTER_S = 40 -- then use the defaults (the server waits up to 30 s for a player's saves)
local POLL_S = 0.25
local SAVE_DEBOUNCE_S = 1.5 -- quiet time after the last change before saving
local SAVE_MAX_DELAY_S = 6 -- a save goes out at most this long after the first unsaved change
--============================================================================

local SettingsController = {}

local musicGroup: SoundGroup
local effectsGroup: SoundGroup
local saveRemote: RemoteEvent? = nil
local saveToken = 0
local firstUnsavedAt: number? = nil -- os.clock() of the first change since the last save

local function soundGroup(name: string): SoundGroup
	local existing = SoundService:FindFirstChild(name)
	if existing and existing:IsA("SoundGroup") then
		return existing
	end
	local group = Instance.new("SoundGroup")
	group.Name = name
	group.Parent = SoundService
	return group
end

local function applyVolumes()
	local values = Settings.current()
	musicGroup.Volume = values.musicVolume
	effectsGroup.Volume = values.effectsVolume
end

local function saveNow()
	local remote = saveRemote
	if remote == nil or not Settings.isLoaded() or not Settings.isDirty() then
		return
	end
	local json = SettingsSchema.encode(Settings.current())
	Settings.clearDirty()
	firstUnsavedAt = nil
	remote:FireServer(json)
end

-- Debounced save after a user change.
local function scheduleSave()
	if not Settings.isLoaded() or not Settings.isDirty() then
		return
	end
	local now = os.clock()
	local first = firstUnsavedAt or now
	firstUnsavedAt = first
	saveToken += 1
	local token = saveToken
	local delay = math.clamp(first + SAVE_MAX_DELAY_S - now, 0, SAVE_DEBOUNCE_S)
	task.delay(delay, function()
		if token == saveToken then
			saveNow()
		end
	end)
end

local function waitForLoad(seconds: number)
	local deadline = os.clock() + seconds
	while not Settings.isLoaded() and os.clock() < deadline do
		task.wait(POLL_S)
	end
end

function SettingsController.musicGroup(): SoundGroup
	return musicGroup
end

function SettingsController.effectsGroup(): SoundGroup
	return effectsGroup
end

function SettingsController.Init()
	musicGroup = soundGroup(MUSIC_GROUP_NAME)
	effectsGroup = soundGroup(EFFECTS_GROUP_NAME)
	applyVolumes()
	Settings.onChanged(function(field: string)
		if field == "musicVolume" or field == "effectsVolume" then
			applyVolumes()
		end
		scheduleSave()
	end)
end

function SettingsController.Start()
	saveRemote = Remotes.event("SaveSettings")
	local requestRemote = Remotes.event("RequestSettings")
	Remotes.event("SettingsData").OnClientEvent:Connect(function(json: unknown)
		if Settings.isLoaded() then
			return -- only the first answer counts (a retry may be answered twice)
		end
		Settings.applyLoaded(if type(json) == "string" then SettingsSchema.decode(json) else nil)
		scheduleSave() -- changes made before the answer arrived
	end)

	requestRemote:FireServer()
	waitForLoad(RETRY_AFTER_S)
	if not Settings.isLoaded() then
		requestRemote:FireServer()
		waitForLoad(GIVE_UP_AFTER_S)
	end
	if not Settings.isLoaded() then
		warn("[SettingsController] the server never sent the saved settings; using the defaults")
		Settings.applyLoaded(nil)
		scheduleSave()
	end
end

return SettingsController
