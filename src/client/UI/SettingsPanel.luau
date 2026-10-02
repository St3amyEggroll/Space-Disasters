--!strict
--[[
	SettingsPanel (Phase 11)
	The settings dialog, in the KSP pause-dialog look: a centred dark panel with the green "Settings" title, three
	tabs, a scrolling page and a bottom row with "Reset to defaults" (asks first) and "Close". Opened from the main
	menu (and later from the HUD / builder); a singleton built on first open in its own ScreenGui
	(Theme.DisplayOrder.Settings: above the menu and the HUD, below confirm dialogs and toasts).

	Pages:
	  Controls & Camera  mouse sensitivity, invert Y, camera smoothing, camera shake (CHANGED (Physics feel));
	                     every rebindable key (SettingsSchema.ACTIONS, grouped Flight / Builder): click a key button, then press the new key ("Press a key...";
	                     Escape or clicking it again cancels; a reserved / unbindable key shows a toast and keeps
	                     listening; taking another action's key swaps the two and says so); "Reset keys"
	  Interface          UI size, Show HUD (with its live key), units, hints
	  Audio              music and effects volume

	Every control writes through Settings (validated there) and mirrors Settings.current(): refreshed on open and
	live on every change (e.g. the saved settings arriving from the server while the panel is open).

	Input: while open the panel holds UIState modal "Settings", so gameplay ignores the player. Escape closes it
	(through Kit.onEscape, so a confirm dialog on top closes first, and while a key is being captured Escape only
	cancels the capture). The key capture listens to UserInputService.InputBegan and ignores gameProcessed on
	purpose: keys bound with ContextActionService (the pilot's controls) arrive processed.

	API:
	  SettingsPanel.open()
	  SettingsPanel.close()
	  SettingsPanel.isOpen() -> boolean
	  SettingsPanel.onClosed(fn()) -> RBXScriptConnection   after every close
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local Kit = require(script.Parent.Kit)
local Settings = require(script.Parent.Parent.Settings.Settings)
local Theme = require(script.Parent.Theme)
local UIState = require(script.Parent.UIState)

--============================================================================
-- Tunables
--============================================================================
local GUI_NAME = "SettingsPanel"
local MODAL_NAME = "Settings" -- UIState modal while open
local PANEL_SIZE = Vector2.new(620, 520) -- S, shrunk to fit small screens / a big UI size
local SCREEN_MARGIN = 16 -- S, kept free around the panel when it shrinks
local POP_SCALE = 0.95 -- the panel grows from this to 1 when it opens
local SLIDER_STEP = 0.05
local KEY_BUTTON_STYLE: Kit.ButtonStyle = "Primary"
local CAPTURE_STYLE: Kit.ButtonStyle = "Accent"
local RESET_KEYS_WIDTH = 160 -- S
-- Text
local TITLE = "Settings"
local TAB_CONTROLS = "Controls & Camera"
local TAB_INTERFACE = "Interface"
local TAB_AUDIO = "Audio"
local TABS = { TAB_CONTROLS, TAB_INTERFACE, TAB_AUDIO }
-- CHANGED (Phase 6): the EVA (spacewalk) keys get their own group
local CONTEXT_TITLES: { [string]: string } = { Flight = "Flight", EVA = "Spacewalk (EVA)", Build = "Builder" }
local CAPTURE_TEXT = "Press a key..."
local FIXED_KEYS_NOTE = "Ctrl+Z (undo) and F3 (debug overlay) are fixed and cannot be rebound."
local HUD_NOTE = "Press %s in flight to show or hide the HUD."
local HINTS_NOTE = "Key hints and tips on screen."
local AUDIO_NOTE = "Sounds are coming in a later update."
local RESERVED_TOAST = "%s is reserved. Press another key (Escape cancels)."
local UNBINDABLE_TOAST = "%s can't be bound. Press another key (Escape cancels)."
local SWAPPED_TOAST = "Swapped with %s"
local KEYS_RESET_TOAST = "Keys reset to defaults"
local ALL_RESET_TOAST = "Settings reset to defaults"
local RESET_DIALOG: Kit.ConfirmOptions = {
	title = "Reset settings?",
	body = "Every setting, including your key bindings, goes back to its default.",
	confirmText = "Reset",
	cancelText = "Cancel",
	danger = true,
}
--============================================================================

type View = {
	screen: ScreenGui,
	backdrop: TextButton,
	popScale: UIScale,
	tabs: Kit.Tabs,
	pages: { [string]: ScrollingFrame },
}

local SettingsPanel = {}

local view: View? = nil
local isOpen = false
local selectedTab = TABS[1]
local removeEscape: (() -> ())? = nil
local closedEvent = Instance.new("BindableEvent")

-- field -> redraw its control from Settings.current()
local refreshers: { [string]: () -> () } = {}
local keyButtons: { [string]: TextButton } = {}
local keyNotes: { () -> () } = {} -- texts that show a key label (redrawn on rebinds)

-- Key capture
local capturing: string? = nil -- the action whose key button is listening
local captureConnection: RBXScriptConnection? = nil
local removeCaptureEscape: (() -> ())? = nil

local function percent(value: number): string
	return `{math.round(value * 100)}%`
end

local function refreshKeyButton(action: string)
	local button: TextButton? = keyButtons[action]
	if not button then
		return
	end
	if capturing == action then
		button.Text = CAPTURE_TEXT
		Kit.setButtonStyle(button, CAPTURE_STYLE)
	else
		button.Text = Keybinds.label(action)
		Kit.setButtonStyle(button, KEY_BUTTON_STYLE)
	end
end

local function refreshKeys()
	for action in keyButtons do
		refreshKeyButton(action)
	end
	for _, refresh in keyNotes do
		refresh()
	end
end

local function refreshAll()
	for _, refresh in refreshers do
		refresh()
	end
	refreshKeys()
end

--============================================================================
-- Key capture
--============================================================================
local function endCapture()
	local action = capturing
	if action == nil then
		return
	end
	capturing = nil
	if captureConnection then
		captureConnection:Disconnect()
		captureConnection = nil
	end
	if removeCaptureEscape then
		removeCaptureEscape()
		removeCaptureEscape = nil
	end
	refreshKeyButton(action)
end

-- gameProcessed is ignored on purpose: keys bound with ContextActionService arrive processed.
local function onCaptureInput(input: InputObject, _gameProcessed: boolean)
	local action = capturing
	if action == nil or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	local key = input.KeyCode
	if key == Enum.KeyCode.Escape or key == Keybinds.UNBOUND then
		return -- Escape cancels through the escape stack
	end
	if not SettingsSchema.isAllowedKey(key.Name) then
		local reserved = table.find(SettingsSchema.RESERVED_KEYS, key.Name) ~= nil
		Kit.toast(
			string.format(if reserved then RESERVED_TOAST else UNBINDABLE_TOAST, Keybinds.keyLabel(key)),
			"Warning"
		)
		return -- keep listening
	end
	endCapture()
	local ok, swappedWith = Settings.setKeybind(action, key)
	if not ok then
		Kit.toast(string.format(UNBINDABLE_TOAST, Keybinds.keyLabel(key)), "Error")
	elseif swappedWith then
		local other = SettingsSchema.findAction(swappedWith)
		Kit.toast(string.format(SWAPPED_TOAST, if other then other.label else swappedWith), "Info")
	end
end

local function beginCapture(action: string)
	if capturing == action then
		endCapture() -- clicking the listening button again cancels
		return
	end
	endCapture()
	capturing = action
	refreshKeyButton(action)
	removeCaptureEscape = Kit.onEscape(endCapture)
	captureConnection = UserInputService.InputBegan:Connect(onCaptureInput)
end

--============================================================================
-- Pages
--============================================================================
local function addSlider(page: Instance, label: string, field: string, format: (number) -> string, live: boolean)
	local range = SettingsSchema.RANGES[field]
	local current = SettingsSchema.getField(Settings.current(), field)
	local slider = Kit.slider(page, label, {
		min = range.min,
		max = range.max,
		step = SLIDER_STEP,
		value = if type(current) == "number" then current else range.default,
		format = format,
		live = live,
	}, function(value: number)
		Settings.set(field, value)
	end)
	refreshers[field] = function()
		local value = SettingsSchema.getField(Settings.current(), field)
		if type(value) == "number" then
			slider.set(value)
		end
	end
end

local function addToggle(page: Instance, label: string, field: string)
	local toggle = Kit.toggle(page, label, SettingsSchema.getField(Settings.current(), field) == true, function(on)
		Settings.set(field, on)
	end)
	refreshers[field] = function()
		toggle.set(SettingsSchema.getField(Settings.current(), field) == true)
	end
end

local function addNote(page: Instance, text: string): TextLabel
	return Kit.label(page, text, { dim = true, wrap = true, textSize = Theme.TextSizes.Small })
end

local function buildControls(page: ScrollingFrame)
	Kit.section(page, "Camera")
	addSlider(page, "Mouse sensitivity", "mouseSensitivity", function(value: number): string
		return string.format("%.2fx", value)
	end, true)
	addToggle(page, "Invert Y", "invertY")
	local smoothing = SettingsSchema.RANGES.cameraSmoothing
	addSlider(page, "Camera smoothing", "cameraSmoothing", function(value: number): string
		if value <= smoothing.min then
			return "Off"
		elseif value >= smoothing.max then
			return "Max"
		end
		return percent(value)
	end, true)
	addToggle(page, "Camera shake", "cameraShake") -- CHANGED (Physics feel): subtle shake while engines burn

	for _, context: SettingsSchema.Context in SettingsSchema.CONTEXTS do
		Kit.section(page, CONTEXT_TITLES[context] or context)
		for _, action in SettingsSchema.actionsFor(context) do
			local row = Kit.row(page)
			Kit.label(row, action.label, {
				size = UDim2.new(1, -(Theme.Sizes.KeyButton + Theme.Padding.Medium), 1, 0),
			})
			local actionId = action.id
			keyButtons[actionId] = Kit.button(row, Keybinds.label(actionId), function()
				beginCapture(actionId)
			end, {
				name = actionId,
				style = KEY_BUTTON_STYLE,
				size = UDim2.fromOffset(Theme.Sizes.KeyButton, Theme.Sizes.ButtonSmall),
				position = UDim2.fromScale(1, 0.5),
				anchor = Vector2.new(1, 0.5),
				textSize = Theme.TextSizes.Body,
			})
		end
	end

	local resetRow = Kit.row(page, Theme.Sizes.Button)
	Kit.button(resetRow, "Reset keys", function()
		endCapture()
		Settings.resetKeybinds()
		Kit.toast(KEYS_RESET_TOAST, "Info")
	end, { size = UDim2.new(0, RESET_KEYS_WIDTH, 1, 0) })
	addNote(page, FIXED_KEYS_NOTE)
end

local function buildInterface(page: ScrollingFrame)
	Kit.section(page, "Display")
	addSlider(page, "UI size", "uiScale", percent, false) -- applied on release: the panel itself rescales
	addToggle(page, "Show HUD", "hudVisible")
	local hudNote = addNote(page, "")
	table.insert(keyNotes, function()
		hudNote.Text = string.format(HUD_NOTE, Keybinds.label("ToggleHUD"))
	end)

	local unitOptions: { string } = {}
	for _, units in SettingsSchema.UNITS do
		table.insert(unitOptions, units)
	end
	local unitsChoice = Kit.choice(page, "Units", unitOptions, Settings.current().units, function(option: string)
		Settings.set("units", option)
	end)
	refreshers.units = function()
		unitsChoice.set(Settings.current().units)
	end

	Kit.section(page, "Help")
	addToggle(page, "Hints", "hints")
	addNote(page, HINTS_NOTE)
end

local function buildAudio(page: ScrollingFrame)
	Kit.section(page, "Volume")
	addSlider(page, "Music", "musicVolume", percent, true)
	addSlider(page, "Effects", "effectsVolume", percent, true)
	addNote(page, AUDIO_NOTE)
end

local function selectTab(name: string)
	local v = view
	if v == nil then
		return
	end
	if name ~= selectedTab then
		endCapture()
	end
	selectedTab = name
	v.tabs.set(name)
	for tab, page in v.pages do
		page.Visible = tab == name
	end
end

--============================================================================
-- Build
--============================================================================
local function build(): View
	local existing = view
	if existing then
		return existing
	end
	local screen, canvas = Kit.screen(GUI_NAME, Theme.DisplayOrder.Settings)
	screen.Enabled = false
	local backdrop = Kit.backdrop(canvas)

	local panel = Kit.panel({
		parent = canvas,
		name = "Settings",
		size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	Kit.fitToCanvas(panel, canvas, PANEL_SIZE, SCREEN_MARGIN)
	local popScale: UIScale = Kit.new("UIScale", {}, panel)

	local gap = Theme.Padding.Medium
	Kit.title(panel, TITLE)
	local tabs = Kit.tabs(panel, TABS, selectedTab, function(name: string)
		selectTab(name)
	end)
	tabs.frame.Position = UDim2.fromOffset(0, Theme.Sizes.Title + gap)

	local pagesTop = Theme.Sizes.Title + gap + Theme.Sizes.Tab + gap
	local pagesBottom = Theme.Sizes.Button + gap
	local pages: { [string]: ScrollingFrame } = {}
	local builders: { [string]: (ScrollingFrame) -> () } = {
		[TAB_CONTROLS] = buildControls,
		[TAB_INTERFACE] = buildInterface,
		[TAB_AUDIO] = buildAudio,
	}
	for _, name in TABS do
		local page = Kit.scroll(panel, {
			name = name,
			position = UDim2.fromOffset(0, pagesTop),
			size = UDim2.new(1, 0, 1, -(pagesTop + pagesBottom)),
		})
		page.Visible = false
		pages[name] = page
		builders[name](page)
	end

	local bottom = Kit.frame(panel, {
		name = "Buttons",
		position = UDim2.fromScale(0, 1),
		anchor = Vector2.new(0, 1),
		size = UDim2.new(1, 0, 0, Theme.Sizes.Button),
	})
	Kit.button(bottom, "Reset to defaults", function()
		endCapture()
		Kit.confirm(RESET_DIALOG, function(confirmed: boolean)
			if confirmed then
				Settings.resetAll()
				Kit.toast(ALL_RESET_TOAST, "Info")
			end
		end)
	end, { name = "Reset", size = UDim2.new(0.5, -gap / 2, 1, 0) })
	Kit.button(bottom, "Close", SettingsPanel.close, {
		name = "Close",
		size = UDim2.new(0.5, -gap / 2, 1, 0),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
	})

	-- Live mirror of the store (the panel lives for the whole session).
	local connections: { RBXScriptConnection } = {
		Settings.onChanged(function(field: string)
			local refresh = refreshers[field]
			if refresh then
				refresh()
			end
		end),
		Keybinds.onChanged(refreshKeys),
	}
	screen.Destroying:Connect(function()
		for _, connection in connections do
			connection:Disconnect()
		end
	end)

	local built: View = {
		screen = screen,
		backdrop = backdrop,
		popScale = popScale,
		tabs = tabs,
		pages = pages,
	}
	view = built
	return built
end

--============================================================================
-- API
--============================================================================
function SettingsPanel.open()
	if isOpen then
		return
	end
	local v = build()
	isOpen = true
	refreshAll()
	selectTab(selectedTab)
	v.screen.Enabled = true
	v.backdrop.BackgroundTransparency = 1
	v.popScale.Scale = POP_SCALE
	Kit.tween(v.backdrop, { BackgroundTransparency = Theme.Transparency.Backdrop }, Theme.Tween.Normal)
	Kit.tween(v.popScale, { Scale = 1 }, Theme.Tween.Normal)
	UIState.pushModal(MODAL_NAME)
	removeEscape = Kit.onEscape(SettingsPanel.close)
end

function SettingsPanel.close()
	if not isOpen then
		return
	end
	isOpen = false
	endCapture()
	if removeEscape then
		removeEscape()
		removeEscape = nil
	end
	local v = view
	if v then
		v.screen.Enabled = false
	end
	UIState.popModal(MODAL_NAME)
	closedEvent:Fire()
end

function SettingsPanel.isOpen(): boolean
	return isOpen
end

function SettingsPanel.onClosed(fn: () -> ()): RBXScriptConnection
	return closedEvent.Event:Connect(fn)
end

return table.freeze(SettingsPanel)
