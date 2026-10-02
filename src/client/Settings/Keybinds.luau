--!strict
--[[
	Keybinds (Phase 11)
	The player's key bindings as Enum.KeyCodes (Settings keybinds, by SettingsSchema action id) plus short key labels
	for the UI and hints. Gameplay code asks "is this action held" / "which action is this key" instead of comparing
	KeyCodes, so a rebind in the settings changes every control at once.

	isDown(action) is false while UIState.isInputBlocked() (main menu or a dialog open) or a TextBox has focus.
	Fixed keys that are not actions: Ctrl+Z (builder undo), F3 (debug overlay), Escape.

	API:
	  Keybinds.UNBOUND: Enum.KeyCode                 Enum.KeyCode.Unknown (also the KeyCode of mouse input)
	  Keybinds.key(action) -> Enum.KeyCode           UNBOUND for an unknown action
	  Keybinds.label(action) -> string               short key text: "Space", "Shift", "Ctrl", "W", "F2", "1"
	  Keybinds.keyLabel(key) -> string
	  Keybinds.isDown(action) -> boolean
	  Keybinds.keysFor(context) -> { Enum.KeyCode }  the keys of that context's actions (ACTIONS order)
	  Keybinds.pilotKeys() -> { Enum.KeyCode }       CHANGED (Phase 11 review): Flight keys + SettingsSchema
	                                                 PILOT_SINK_KEYS (what the pilot's binding captures)
	  Keybinds.actionFor(context, key) -> string?    the action bound to that key in that context
	  Keybinds.onChanged(fn()) -> RBXScriptConnection  after any keybind change (rebind, reset, saved values loaded)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local UIState = require(script.Parent.Parent.UI.UIState)
local Settings = require(script.Parent.Settings)

--============================================================================
-- Tunables
--============================================================================
local UNBOUND_LABEL = "None" -- label of UNBOUND
local KEY_LABELS: { [string]: string } = { -- short labels; every other key shows its Enum name ("W", "F2")
	LeftShift = "Shift",
	RightShift = "RShift",
	LeftControl = "Ctrl",
	RightControl = "RCtrl",
	LeftAlt = "Alt",
	RightAlt = "RAlt",
	One = "1",
	Two = "2",
	Three = "3",
	Four = "4",
	Five = "5",
	Six = "6",
	Seven = "7",
	Eight = "8",
	Nine = "9",
	Zero = "0",
	Comma = ",",
	Period = ".",
	Semicolon = ";",
	Quote = "'",
	LeftBracket = "[",
	RightBracket = "]",
	Minus = "-",
	Equals = "=",
	BackSlash = "\\",
	Insert = "Ins",
	Delete = "Del",
	PageUp = "PgUp",
	PageDown = "PgDn",
	KeypadZero = "Num0",
	KeypadOne = "Num1",
	KeypadTwo = "Num2",
	KeypadThree = "Num3",
	KeypadFour = "Num4",
	KeypadFive = "Num5",
	KeypadSix = "Num6",
	KeypadSeven = "Num7",
	KeypadEight = "Num8",
	KeypadNine = "Num9",
	KeypadPlus = "Num+",
	KeypadMinus = "Num-",
	CapsLock = "Caps",
	Return = "Enter",
	Backspace = "Bksp",
}
--============================================================================

local Keybinds = {}

-- Enum.KeyCode.Unknown (KeyCode 0) is missing from the Luau type definitions, hence the one cast.
local UNBOUND: Enum.KeyCode = (Enum.KeyCode :: any).Unknown

local keyByName: { [string]: Enum.KeyCode } = {}
for _, item in Enum.KeyCode:GetEnumItems() do
	keyByName[item.Name] = item
end

function Keybinds.key(action: string): Enum.KeyCode
	local name = Settings.current().keybinds[action]
	local key = if name then keyByName[name] else nil
	return key or UNBOUND
end

function Keybinds.keyLabel(key: Enum.KeyCode): string
	if key == UNBOUND then
		return UNBOUND_LABEL
	end
	return KEY_LABELS[key.Name] or key.Name
end

function Keybinds.label(action: string): string
	return Keybinds.keyLabel(Keybinds.key(action))
end

function Keybinds.isDown(action: string): boolean
	if UIState.isInputBlocked() or UserInputService:GetFocusedTextBox() then
		return false
	end
	local key = Keybinds.key(action)
	return key ~= UNBOUND and UserInputService:IsKeyDown(key)
end

function Keybinds.keysFor(context: SettingsSchema.Context): { Enum.KeyCode }
	local keys: { Enum.KeyCode } = {}
	for _, action in SettingsSchema.ACTIONS do
		if action.context == context then
			local key = Keybinds.key(action.id)
			if key ~= UNBOUND then
				table.insert(keys, key)
			end
		end
	end
	return keys
end

-- CHANGED (Phase 11 review): the keys the pilot's binding captures (SettingsSchema.pilotKeys: every Flight action's
-- key plus the old flight keys, so a key freed by a rebind, e.g. Space, never reaches the default jump).
function Keybinds.pilotKeys(): { Enum.KeyCode }
	local keys: { Enum.KeyCode } = {}
	for _, name in SettingsSchema.pilotKeys(Settings.current().keybinds) do
		local key = keyByName[name]
		if key and key ~= UNBOUND then
			table.insert(keys, key)
		end
	end
	return keys
end

function Keybinds.actionFor(context: SettingsSchema.Context, key: Enum.KeyCode): string?
	if key == UNBOUND then
		return nil
	end
	for _, action in SettingsSchema.ACTIONS do
		if action.context == context and Keybinds.key(action.id) == key then
			return action.id
		end
	end
	return nil
end

function Keybinds.onChanged(fn: () -> ()): RBXScriptConnection
	return Settings.onChanged(function(field: string)
		if field == "keybinds" then
			fn()
		end
	end)
end

Keybinds.UNBOUND = UNBOUND

return table.freeze(Keybinds)
