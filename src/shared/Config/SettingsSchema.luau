--!strict
--[[
	SettingsSchema (Phase 11)
	The player's settings: every field with its range and default, the rebindable key actions, and the tolerant
	sanitizer and JSON codec both sides use (the client's Settings store, the server's SettingsService). Pure Luau
	with no engine services and no Enum use, so the offline Lune tests run it: keys are Enum.KeyCode NAMES.

	Fields (Values):
	  mouseSensitivity  number   camera drag multiplier (chase camera, map view)
	  invertY           boolean  dragging the mouse up tilts the camera the other way
	  cameraSmoothing   number   0 = snappy .. 1 = very smooth (0.5 = the Phase 2a feel)
	  cameraShake       boolean  subtle chase-camera shake while engines burn and in thick fast air
	                             (CHANGED (Physics feel))
	  uiScale           number   UI size multiplier
	  hudVisible        boolean  flight HUD shown (the ToggleHUD key flips it)
	  units             Units    "Metric" | "Imperial"
	  hints             boolean  key hints and tips shown
	  musicVolume       number   0..1 (SoundService.Music)
	  effectsVolume     number   0..1 (SoundService.Effects)
	  keybinds          map      action id -> Enum.KeyCode name, one entry for every action in ACTIONS

	Keybinds: ACTIONS lists every rebindable action (Flight, then Build) in display order. Only names in
	ALLOWED_KEYS can be bound; RESERVED_KEYS never can (Roblox menu, chat, player list, console, debug overlay,
	fullscreen). Ctrl+Z (builder undo), F3 (debug overlay) and Escape are fixed. A key is used at most once per
	context; one key may serve a Flight and a Build action (M: map view / mirror symmetry).
	Flight defaults reproduce the Phase 2a controls exactly. FlightModel commands torque (-pitch, -roll, -yaw) about
	craft X / Y / Z, so the positive pitch input (W) moves the nose toward -Z, the navball's bottom: pitch DOWN;
	the positive yaw input (D) moves it toward +X: yaw RIGHT; and the positive roll input (E) turns +X toward +Z,
	counter-clockwise seen from behind: roll LEFT (KSP's E rolls the other way). The labels say what the keys do.

	Sanitizing is tolerant: a wrong type gives the default, numbers must be finite and are clamped into range,
	unknown fields and actions are dropped, a disallowed key gives the action's default. A key used twice in one
	context: the later action (ACTIONS order) gets its default back; if that still collides, the whole context
	resets to its defaults.

	JSON: encode writes the scalar fields, a format version and only the keybinds that differ from the defaults
	(so a default changed in a later version reaches everyone who never rebound that action). decode never errors:
	garbage, non-objects and anything longer than MAX_JSON_BYTES give the defaults.

	API:
	  SettingsSchema.ACTIONS: { Action }                      display order (Flight first)
	  SettingsSchema.CONTEXTS: { Context }
	  SettingsSchema.ALLOWED_KEYS: { string }                 bindable Enum.KeyCode names
	  SettingsSchema.RESERVED_KEYS: { string }                never bindable
	  SettingsSchema.FIELDS: { string }                       every field of Values ("keybinds" last)
	  SettingsSchema.RANGES: { [string]: Range }              the numeric fields
	  SettingsSchema.UNITS: { Units }
	  SettingsSchema.MAX_JSON_BYTES
	  SettingsSchema.isAllowedKey(name) -> boolean
	  SettingsSchema.findAction(id) -> Action?
	  SettingsSchema.actionsFor(context) -> { Action }        display order
	  SettingsSchema.defaultKeybinds() -> { [string]: string } fresh table
	  SettingsSchema.defaults() -> Values                     fresh table
	  SettingsSchema.sanitize(raw: unknown) -> Values         fresh table, never shares tables with raw
	  SettingsSchema.sanitizeKeybinds(raw: unknown) -> { [string]: string }
	  SettingsSchema.sanitizeField(field, value: unknown) -> (ok, clean)
	                                    false for an unknown field or a value of the wrong type (or not finite);
	                                    numbers come back clamped, "keybinds" comes back sanitized
	  SettingsSchema.getField(values, field) -> any           nil for an unknown field
	  SettingsSchema.setField(values, field, clean) -> boolean  writes an already sanitized value; false if unknown
	  SettingsSchema.encode(values) -> string                 sanitizes first, so it never errors
	  SettingsSchema.decode(json) -> Values
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Json = require(ReplicatedStorage.Shared.Util.Json)

--============================================================================
-- Tunables
--============================================================================
local FORMAT_VERSION = 1 -- written into the JSON as "v" (for future migrations)
local MAX_JSON_BYTES = 4096 -- largest accepted settings JSON (SaveSettings payload and stored value)
local MOUSE_SENSITIVITY: Range = { min = 0.2, max = 3, default = 1 }
local CAMERA_SMOOTHING: Range = { min = 0, max = 1, default = 0.5 }
local UI_SCALE: Range = { min = 0.7, max = 1.4, default = 1 }
local MUSIC_VOLUME: Range = { min = 0, max = 1, default = 0.5 }
local EFFECTS_VOLUME: Range = { min = 0, max = 1, default = 0.8 }
local DEFAULT_INVERT_Y = false
local DEFAULT_CAMERA_SHAKE = true -- CHANGED (Physics feel): camera shake toggle
local DEFAULT_HUD_VISIBLE = true
local DEFAULT_UNITS: Units = "Metric"
local DEFAULT_HINTS = true
local ACTIONS: { Action } = {
	-- Flight (defaults = the Phase 2a controls; see the header for the pitch / yaw / roll directions)
	{ id = "PitchDown", label = "Pitch down", context = "Flight", default = "W" },
	{ id = "PitchUp", label = "Pitch up", context = "Flight", default = "S" },
	{ id = "YawLeft", label = "Yaw left", context = "Flight", default = "A" },
	{ id = "YawRight", label = "Yaw right", context = "Flight", default = "D" },
	{ id = "RollLeft", label = "Roll left", context = "Flight", default = "E" },
	{ id = "RollRight", label = "Roll right", context = "Flight", default = "Q" },
	{ id = "ThrottleUp", label = "Throttle up", context = "Flight", default = "LeftShift" },
	{ id = "ThrottleDown", label = "Throttle down", context = "Flight", default = "LeftControl" },
	{ id = "ThrottleFull", label = "Full throttle", context = "Flight", default = "Z" },
	{ id = "ThrottleCut", label = "Cut throttle", context = "Flight", default = "X" },
	{ id = "ToggleSAS", label = "SAS on / off", context = "Flight", default = "T" },
	{ id = "ToggleGear", label = "Landing legs", context = "Flight", default = "G" },
	{ id = "Stage", label = "Stage / launch", context = "Flight", default = "Space" },
	{ id = "ToggleCamera", label = "Chase camera on / off", context = "Flight", default = "V" },
	{ id = "LeaveSeat", label = "Leave seat", context = "Flight", default = "F" },
	{ id = "MapView", label = "Map view", context = "Flight", default = "M" },
	{ id = "ToggleHUD", label = "HUD on / off", context = "Flight", default = "F2" },
	-- Build
	{ id = "RotateY", label = "Rotate part (yaw)", context = "Build", default = "R" },
	{ id = "RotateX", label = "Rotate part (pitch)", context = "Build", default = "T" },
	{ id = "ToolBuild", label = "Build tool", context = "Build", default = "B" },
	{ id = "ToolPaint", label = "Paint tool", context = "Build", default = "P" },
	{ id = "ToolDelete", label = "Delete tool", context = "Build", default = "X" },
	{ id = "SymmetryOff", label = "Symmetry off", context = "Build", default = "One" },
	{ id = "SymmetryRadial2", label = "Radial symmetry x2", context = "Build", default = "Two" },
	{ id = "SymmetryRadial4", label = "Radial symmetry x4", context = "Build", default = "Four" },
	{ id = "SymmetryMirror", label = "Mirror symmetry (cycle)", context = "Build", default = "M" },
}
local ALLOWED_KEYS: { string } = {
	"A",
	"B",
	"C",
	"D",
	"E",
	"F",
	"G",
	"H",
	"I",
	"J",
	"K",
	"L",
	"M",
	"N",
	"O",
	"P",
	"Q",
	"R",
	"S",
	"T",
	"U",
	"V",
	"W",
	"X",
	"Y",
	"Z",
	"One",
	"Two",
	"Three",
	"Four",
	"Five",
	"Six",
	"Seven",
	"Eight",
	"Nine",
	"Zero",
	"F1",
	"F2",
	"F4",
	"F5",
	"F6",
	"F7",
	"F8",
	"F10",
	"F12",
	"Space",
	"LeftShift",
	"RightShift",
	"LeftControl",
	"RightControl",
	"LeftAlt",
	"RightAlt",
	"Up",
	"Down",
	"Left",
	"Right",
	"Comma",
	"Period",
	"Semicolon",
	"Quote",
	"LeftBracket",
	"RightBracket",
	"Minus",
	"Equals",
	"BackSlash",
	"Insert",
	"Delete",
	"Home",
	"End",
	"PageUp",
	"PageDown",
	"KeypadZero",
	"KeypadOne",
	"KeypadTwo",
	"KeypadThree",
	"KeypadFour",
	"KeypadFive",
	"KeypadSix",
	"KeypadSeven",
	"KeypadEight",
	"KeypadNine",
	"KeypadPlus",
	"KeypadMinus",
	"CapsLock",
	"Return",
	"Backspace",
}
local RESERVED_KEYS: { string } = { "Escape", "Slash", "Backquote", "Tab", "F3", "F9", "F11" }
--============================================================================

export type Units = "Metric" | "Imperial"
export type Context = "Flight" | "Build"

export type Values = {
	mouseSensitivity: number,
	invertY: boolean,
	cameraSmoothing: number,
	cameraShake: boolean, -- CHANGED (Physics feel): camera shake toggle
	uiScale: number,
	hudVisible: boolean,
	units: Units,
	hints: boolean,
	musicVolume: number,
	effectsVolume: number,
	keybinds: { [string]: string }, -- action id -> Enum.KeyCode name
}

export type Action = {
	id: string,
	label: string, -- settings screen text (ASCII)
	context: Context,
	default: string, -- Enum.KeyCode name
}

export type Range = { min: number, max: number, default: number }

type FieldKind = "Number" | "Boolean" | "Units" | "Keybinds"

local SettingsSchema = {}

local CONTEXTS: { Context } = { "Flight", "Build" }
local UNITS: { Units } = { "Metric", "Imperial" }
local FIELDS: { string } = {
	"mouseSensitivity",
	"invertY",
	"cameraSmoothing",
	"cameraShake", -- CHANGED (Physics feel): camera shake toggle
	"uiScale",
	"hudVisible",
	"units",
	"hints",
	"musicVolume",
	"effectsVolume",
	"keybinds",
}
local RANGES: { [string]: Range } = {
	mouseSensitivity = MOUSE_SENSITIVITY,
	cameraSmoothing = CAMERA_SMOOTHING,
	uiScale = UI_SCALE,
	musicVolume = MUSIC_VOLUME,
	effectsVolume = EFFECTS_VOLUME,
}
local KINDS: { [string]: FieldKind } = {
	mouseSensitivity = "Number",
	invertY = "Boolean",
	cameraSmoothing = "Number",
	cameraShake = "Boolean", -- CHANGED (Physics feel): camera shake toggle
	uiScale = "Number",
	hudVisible = "Boolean",
	units = "Units",
	hints = "Boolean",
	musicVolume = "Number",
	effectsVolume = "Number",
	keybinds = "Keybinds",
}

local allowedSet: { [string]: boolean } = {}
for _, name in ALLOWED_KEYS do
	allowedSet[name] = true
end
local actionById: { [string]: Action } = {}
for _, action in ACTIONS do
	table.freeze(action)
	actionById[action.id] = action
end
for _, range in RANGES do
	table.freeze(range)
end

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

local function isUnits(value: unknown): boolean
	return value == "Metric" or value == "Imperial"
end

-- A finite number clamped into the range, or nil for anything else.
local function cleanNumber(value: unknown, range: Range): number?
	if type(value) ~= "number" or not isFinite(value) then
		return nil
	end
	return math.clamp(value, range.min, range.max)
end

local function numberOr(value: unknown, range: Range): number
	local clean = cleanNumber(value, range)
	return if clean == nil then range.default else clean
end

local function booleanOr(value: unknown, default: boolean): boolean
	return if type(value) == "boolean" then value else default
end

function SettingsSchema.isAllowedKey(name: string): boolean
	return type(name) == "string" and allowedSet[name] == true
end

function SettingsSchema.findAction(id: string): Action?
	return actionById[id]
end

function SettingsSchema.actionsFor(context: Context): { Action }
	local list: { Action } = {}
	for _, action in ACTIONS do
		if action.context == context then
			table.insert(list, action)
		end
	end
	return list
end

function SettingsSchema.defaultKeybinds(): { [string]: string }
	local binds: { [string]: string } = {}
	for _, action in ACTIONS do
		binds[action.id] = action.default
	end
	return binds
end

function SettingsSchema.defaults(): Values
	return {
		mouseSensitivity = MOUSE_SENSITIVITY.default,
		invertY = DEFAULT_INVERT_Y,
		cameraSmoothing = CAMERA_SMOOTHING.default,
		cameraShake = DEFAULT_CAMERA_SHAKE, -- CHANGED (Physics feel): camera shake toggle
		uiScale = UI_SCALE.default,
		hudVisible = DEFAULT_HUD_VISIBLE,
		units = DEFAULT_UNITS,
		hints = DEFAULT_HINTS,
		musicVolume = MUSIC_VOLUME.default,
		effectsVolume = EFFECTS_VOLUME.default,
		keybinds = SettingsSchema.defaultKeybinds(),
	}
end

-- Every action gets a bindable key; within a context no key is used twice (see the header for the rules).
function SettingsSchema.sanitizeKeybinds(raw: unknown): { [string]: string }
	local source: { [any]: any } = if type(raw) == "table" then raw :: { [any]: any } else {}
	local result: { [string]: string } = {}
	for _, context in CONTEXTS do
		local used: { [string]: boolean } = {}
		local collided = false
		for _, action in ACTIONS do
			if action.context ~= context then
				continue
			end
			local wanted = source[action.id]
			local key = if type(wanted) == "string" and allowedSet[wanted] then wanted else action.default
			if used[key] then
				key = action.default -- the later action gives way
			end
			if used[key] then
				collided = true
				break
			end
			used[key] = true
			result[action.id] = key
		end
		if collided then
			for _, action in ACTIONS do
				if action.context == context then
					result[action.id] = action.default
				end
			end
		end
	end
	return result
end

function SettingsSchema.sanitize(raw: unknown): Values
	if type(raw) ~= "table" then
		return SettingsSchema.defaults()
	end
	local source = raw :: { [any]: any }
	return {
		mouseSensitivity = numberOr(source.mouseSensitivity, MOUSE_SENSITIVITY),
		invertY = booleanOr(source.invertY, DEFAULT_INVERT_Y),
		cameraSmoothing = numberOr(source.cameraSmoothing, CAMERA_SMOOTHING),
		cameraShake = booleanOr(source.cameraShake, DEFAULT_CAMERA_SHAKE), -- CHANGED (Physics feel): camera shake toggle
		uiScale = numberOr(source.uiScale, UI_SCALE),
		hudVisible = booleanOr(source.hudVisible, DEFAULT_HUD_VISIBLE),
		units = if isUnits(source.units) then source.units else DEFAULT_UNITS,
		hints = booleanOr(source.hints, DEFAULT_HINTS),
		musicVolume = numberOr(source.musicVolume, MUSIC_VOLUME),
		effectsVolume = numberOr(source.effectsVolume, EFFECTS_VOLUME),
		keybinds = SettingsSchema.sanitizeKeybinds(source.keybinds),
	}
end

function SettingsSchema.sanitizeField(field: string, value: unknown): (boolean, any)
	local kind = KINDS[field]
	if kind == "Number" then
		local clean = cleanNumber(value, RANGES[field])
		return clean ~= nil, clean
	elseif kind == "Boolean" then
		return type(value) == "boolean", if type(value) == "boolean" then value else nil
	elseif kind == "Units" then
		return isUnits(value), if isUnits(value) then value else nil
	elseif kind == "Keybinds" then
		if type(value) ~= "table" then
			return false, nil
		end
		return true, SettingsSchema.sanitizeKeybinds(value)
	end
	return false, nil
end

function SettingsSchema.getField(values: Values, field: string): any
	if field == "mouseSensitivity" then
		return values.mouseSensitivity
	elseif field == "invertY" then
		return values.invertY
	elseif field == "cameraSmoothing" then
		return values.cameraSmoothing
	elseif field == "cameraShake" then -- CHANGED (Physics feel): camera shake toggle
		return values.cameraShake
	elseif field == "uiScale" then
		return values.uiScale
	elseif field == "hudVisible" then
		return values.hudVisible
	elseif field == "units" then
		return values.units
	elseif field == "hints" then
		return values.hints
	elseif field == "musicVolume" then
		return values.musicVolume
	elseif field == "effectsVolume" then
		return values.effectsVolume
	elseif field == "keybinds" then
		return values.keybinds
	end
	return nil
end

-- Writes a value that already went through sanitizeField. Returns false for an unknown field.
function SettingsSchema.setField(values: Values, field: string, clean: any): boolean
	if field == "mouseSensitivity" then
		values.mouseSensitivity = clean
	elseif field == "invertY" then
		values.invertY = clean
	elseif field == "cameraSmoothing" then
		values.cameraSmoothing = clean
	elseif field == "cameraShake" then -- CHANGED (Physics feel): camera shake toggle
		values.cameraShake = clean
	elseif field == "uiScale" then
		values.uiScale = clean
	elseif field == "hudVisible" then
		values.hudVisible = clean
	elseif field == "units" then
		values.units = clean
	elseif field == "hints" then
		values.hints = clean
	elseif field == "musicVolume" then
		values.musicVolume = clean
	elseif field == "effectsVolume" then
		values.effectsVolume = clean
	elseif field == "keybinds" then
		values.keybinds = clean
	else
		return false
	end
	return true
end

function SettingsSchema.encode(values: Values): string
	local clean = SettingsSchema.sanitize(values)
	local changedBinds: { [string]: string } = {}
	for _, action in ACTIONS do
		local key = clean.keybinds[action.id]
		if key ~= action.default then
			changedBinds[action.id] = key
		end
	end
	return Json.encode({
		v = FORMAT_VERSION,
		mouseSensitivity = clean.mouseSensitivity,
		invertY = clean.invertY,
		cameraSmoothing = clean.cameraSmoothing,
		cameraShake = clean.cameraShake, -- CHANGED (Physics feel): camera shake toggle
		uiScale = clean.uiScale,
		hudVisible = clean.hudVisible,
		units = clean.units,
		hints = clean.hints,
		musicVolume = clean.musicVolume,
		effectsVolume = clean.effectsVolume,
		keybinds = changedBinds,
	})
end

function SettingsSchema.decode(json: string): Values
	if type(json) ~= "string" or #json > MAX_JSON_BYTES then
		return SettingsSchema.defaults()
	end
	local ok, raw = pcall(Json.decode, json)
	if not ok then
		return SettingsSchema.defaults()
	end
	return SettingsSchema.sanitize(raw)
end

SettingsSchema.ACTIONS = table.freeze(ACTIONS)
SettingsSchema.CONTEXTS = table.freeze(CONTEXTS)
SettingsSchema.ALLOWED_KEYS = table.freeze(ALLOWED_KEYS)
SettingsSchema.RESERVED_KEYS = table.freeze(RESERVED_KEYS)
SettingsSchema.FIELDS = table.freeze(FIELDS)
SettingsSchema.RANGES = table.freeze(RANGES)
SettingsSchema.UNITS = table.freeze(UNITS)
SettingsSchema.MAX_JSON_BYTES = MAX_JSON_BYTES

return table.freeze(SettingsSchema)
