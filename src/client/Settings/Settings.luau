--!strict
--[[
	Settings (Phase 11)
	The client's settings store: one live SettingsSchema.Values table for the whole client. UI code reads
	Settings.current() and listens to onChanged; gameplay code reads the fields it needs when it needs them (camera
	sensitivity, units, keys through Keybinds). Every change is validated by SettingsSchema.

	Persistence is SettingsController's job: it hands in the saved values once (applyLoaded, which is not a user
	change, so it is not saved back) and saves after user changes (isDirty / clearDirty). Fields the player changed
	before the saved values arrived keep the player's value, and the store stays dirty so they get saved.

	API:
	  Settings.current() -> Values                       the live table; callers must not mutate it
	  Settings.set(field, value)                         any field except "keybinds"; validated by
	                                                     SettingsSchema.sanitizeField (numbers clamped); no-op when
	                                                     unchanged or invalid; fires onChanged(field)
	  Settings.setKeybind(action, key: Enum.KeyCode) -> (ok, swappedWith?)
	                                                     false when the action is unknown or the key not allowed; if
	                                                     another action of the same context had that key, the two
	                                                     swap keys and its id is returned; fires onChanged("keybinds")
	                                                     CHANGED (Night review): SettingsSchema.rebind: "same context"
	                                                     = listening at the same time (MapView / ToggleHUD on EVA),
	                                                     and false for E on anything that listens on EVA
	                                                     CHANGED (Night review 2): (false, blockedBy) when the key's
	                                                     holder cannot take the old key (a refused swap)
	  Settings.resetKeybinds()                           every action back to its default key
	  Settings.resetAll()                                every field back to its default
	  Settings.onChanged(fn(field)) -> RBXScriptConnection
	  Settings.isLoaded() -> boolean
	  Settings.onLoaded(fn()) -> RBXScriptConnection     fires once when the saved values arrived; if they already
	                                                     have, fn runs on the next resumption cycle (task.defer)
	  For SettingsController:
	  Settings.applyLoaded(values?)                      the saved values (nil = nothing saved); only the first
	                                                     call counts; fires onChanged for every field that changed
	  Settings.isDirty() -> boolean                      user changes not saved yet
	  Settings.clearDirty()                              call right after sending the save
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)

--============================================================================
-- Tunables
--============================================================================
local KEYBINDS_FIELD = "keybinds" -- changed through setKeybind / resetKeybinds only
--============================================================================

type Values = SettingsSchema.Values

local Settings = {}

local values: Values = SettingsSchema.defaults()
local loaded = false
local dirty = false
local editedBeforeLoad: { [string]: boolean } = {}

local changedEvent = Instance.new("BindableEvent")
local loadedEvent = Instance.new("BindableEvent")

local function sameKeybinds(a: { [string]: string }, b: { [string]: string }): boolean
	for _, action in SettingsSchema.ACTIONS do
		if a[action.id] ~= b[action.id] then
			return false
		end
	end
	return true
end

-- Replaces the keybinds in place, so a table someone got from current().keybinds stays live.
local function replaceKeybinds(source: { [string]: string })
	local binds = values.keybinds
	table.clear(binds)
	for actionId, key in source do
		binds[actionId] = key
	end
end

local function userChanged(field: string)
	dirty = true
	if not loaded then
		editedBeforeLoad[field] = true
	end
	changedEvent:Fire(field)
end

function Settings.current(): Values
	return values
end

function Settings.set(field: string, value: any)
	if field == KEYBINDS_FIELD then
		warn("[Settings] keybinds change through Settings.setKeybind / resetKeybinds")
		return
	end
	local ok, clean = SettingsSchema.sanitizeField(field, value)
	if not ok then
		warn(`[Settings] ignored an invalid value for {field}: {value}`)
		return
	end
	if SettingsSchema.getField(values, field) == clean then
		return
	end
	SettingsSchema.setField(values, field, clean)
	userChanged(field)
end

function Settings.setKeybind(action: string, key: Enum.KeyCode): (boolean, string?)
	local definition = SettingsSchema.findAction(action)
	if definition == nil or typeof(key) ~= "EnumItem" or not SettingsSchema.isAllowedKey(key.Name) then
		return false, nil
	end
	local binds = values.keybinds
	local previous = binds[action]
	if previous == key.Name then
		return true, nil
	end
	-- CHANGED (Night review): SettingsSchema.rebind (swaps across the contexts that listen together, e.g. an EVA key
	-- and MapView; E is refused for anything that listens on EVA). Was: swaps within the action's context only.
	local ok, swappedWith = SettingsSchema.rebind(binds, action, key.Name)
	if not ok then
		return false, swappedWith -- CHANGED (Night review 2): the action that blocked the swap, if any
	end
	userChanged(KEYBINDS_FIELD)
	return true, swappedWith
end

function Settings.resetKeybinds()
	local defaults = SettingsSchema.defaultKeybinds()
	if sameKeybinds(values.keybinds, defaults) then
		return
	end
	replaceKeybinds(defaults)
	userChanged(KEYBINDS_FIELD)
end

function Settings.resetAll()
	local defaults = SettingsSchema.defaults()
	for _, field in SettingsSchema.FIELDS do
		if field == KEYBINDS_FIELD then
			Settings.resetKeybinds()
		else
			local default = SettingsSchema.getField(defaults, field)
			if SettingsSchema.getField(values, field) ~= default then
				SettingsSchema.setField(values, field, default)
				userChanged(field)
			end
		end
	end
end

function Settings.onChanged(fn: (field: string) -> ()): RBXScriptConnection
	return changedEvent.Event:Connect(fn)
end

function Settings.isLoaded(): boolean
	return loaded
end

function Settings.onLoaded(fn: () -> ()): RBXScriptConnection
	if loaded then
		task.defer(fn)
	end
	return loadedEvent.Event:Connect(fn)
end

function Settings.applyLoaded(saved: Values?)
	if loaded then
		return
	end
	local source = SettingsSchema.sanitize(saved)
	local changed: { string } = {}
	for _, field in SettingsSchema.FIELDS do
		if editedBeforeLoad[field] then
			continue -- the player's own change wins
		end
		if field == KEYBINDS_FIELD then
			if not sameKeybinds(values.keybinds, source.keybinds) then
				replaceKeybinds(source.keybinds)
				table.insert(changed, field)
			end
		else
			local value = SettingsSchema.getField(source, field)
			if SettingsSchema.getField(values, field) ~= value then
				SettingsSchema.setField(values, field, value)
				table.insert(changed, field)
			end
		end
	end
	loaded = true
	dirty = next(editedBeforeLoad) ~= nil
	table.clear(editedBeforeLoad)
	for _, field in changed do
		changedEvent:Fire(field)
	end
	loadedEvent:Fire()
end

function Settings.isDirty(): boolean
	return dirty
end

function Settings.clearDirty()
	dirty = false
end

return table.freeze(Settings)
