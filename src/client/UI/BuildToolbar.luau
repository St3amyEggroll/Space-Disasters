--!strict
--[[
	BuildToolbar (Phase 11)
	The builder's slim top toolbar in the KSP skin, left to right:
	  Menu | Build  Paint  Delete (with their keys) | Symmetry | Rotate  Tilt  rotation readout | Undo  Clear |
	  Save  Load | Boarding | Settings
	Tool and symmetry buttons light up (Accent; the Delete tool in Danger red) when on. Key badges come from
	Settings/Keybinds and follow rebinding live. The symmetry button cycles forward on click and backward on right
	click; the boarding button cycles Public -> Friends -> Private.

	Pure view: every button only calls its callback (BuildUI decides what happens: menus, dialogs, confirmations).
	The toolbar's natural width is known up front (naturalWidth, design px); BuildUI shrinks it with setFit when the
	canvas is narrower (small screens or a big UI size setting).

	API:
	  BuildToolbar.HEIGHT: number                    toolbar height (design px)
	  BuildToolbar.create(parent, callbacks) -> Toolbar
	    callbacks: { onMenu(), onTool(tool), onSymmetry(mode), onAction(actionId), onUndo(), onClear(), onSave(),
	                 onLoad(), onBoarding(mode), onSettings() }
	  Toolbar.frame: Frame                           the panel (BuildUI sets its Position)
	  Toolbar.naturalWidth: number                   design px at fit 1
	  Toolbar.setFit(scale)                          uniform shrink (<= 1)
	  Toolbar.setTool(tool)
	  Toolbar.setSymmetry(mode)
	  Toolbar.setRotationText(text)
	  Toolbar.setBoarding(mode)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local BuildInfo = require(script.Parent.BuildInfo)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

--============================================================================
-- Tunables
--============================================================================
-- Layout (design px)
local PADDING = 6
local ITEM_GAP = 4
local BUTTON_HEIGHT = Theme.Sizes.Button
local SEPARATOR_WIDTH = 1
local SEPARATOR_HEIGHT = 22
local KEY_PADDING_LEFT = 8 -- text inset on buttons that carry a key badge
local KEY_PADDING_RIGHT = 5
local DOT_SIZE = 10
local DOT_INSET = 10
local MENU_WIDTH = 64
local TOOL_WIDTHS: { [string]: number } = { Build = 80, Paint = 78, Delete = 84 }
local SYMMETRY_WIDTH = 140
local ROTATE_WIDTH = 78
local TILT_WIDTH = 66
local READOUT_WIDTH = 124
local UNDO_WIDTH = 92
local CLEAR_WIDTH = 60
local SAVE_WIDTH = 60
local LOAD_WIDTH = 60
local BOARDING_WIDTH = 140
local SETTINGS_WIDTH = 82
-- Look
local TOOL_ON_STYLES: { [string]: Kit.ButtonStyle } = { Build = "Accent", Paint = "Accent", Delete = "Danger" }
local BOARDING_COLORS: { [string]: Color3 } = {
	Public = Theme.Colors.Accent,
	Friends = Theme.Colors.NavSky,
	Private = Theme.Colors.Danger,
}
-- Keys
local TOOL_ACTIONS: { [string]: string } = { Build = "ToolBuild", Paint = "ToolPaint", Delete = "ToolDelete" }
local ROTATE_ACTION = "RotateY"
local TILT_ACTION = "RotateX"
local UNDO_KEY_TEXT = "Ctrl+Z" -- fixed, not rebindable
-- Text
local MENU_TEXT = "Menu"
local SYMMETRY_TEXT = "Sym: %s"
local ROTATE_TEXT = "Rotate"
local TILT_TEXT = "Tilt"
local UNDO_TEXT = "Undo"
local CLEAR_TEXT = "Clear"
local SAVE_TEXT = "Save"
local LOAD_TEXT = "Load"
local BOARDING_TEXT = "Board: %s"
local SETTINGS_TEXT = "Settings"
local DEFAULT_ROTATION_TEXT = "up +Y  yaw 0"
--============================================================================

export type Callbacks = {
	onMenu: () -> (),
	onTool: (tool: BuildInfo.Tool) -> (),
	onSymmetry: (mode: BuildInfo.Symmetry) -> (),
	onAction: (actionId: string) -> (),
	onUndo: () -> (),
	onClear: () -> (),
	onSave: () -> (),
	onLoad: () -> (),
	onBoarding: (mode: string) -> (),
	onSettings: () -> (),
}

export type Toolbar = {
	frame: Frame,
	naturalWidth: number,
	setFit: (scale: number) -> (),
	setTool: (tool: BuildInfo.Tool) -> (),
	setSymmetry: (mode: BuildInfo.Symmetry) -> (),
	setRotationText: (text: string) -> (),
	setBoarding: (mode: string) -> (),
}

local BuildToolbar = {}

BuildToolbar.HEIGHT = BUTTON_HEIGHT + PADDING * 2

function BuildToolbar.create(parent: Instance, callbacks: Callbacks): Toolbar
	local panel = Kit.panel({
		parent = parent,
		name = "Toolbar",
		size = UDim2.fromOffset(0, BuildToolbar.HEIGHT),
		anchor = Vector2.new(0.5, 0),
		padding = PADDING,
	})
	Kit.list(panel, { horizontal = true, gap = ITEM_GAP })
	local fit: UIScale = Kit.new("UIScale", {}, panel)

	local naturalWidth = PADDING * 2
	local itemCount = 0
	local function addWidth(width: number)
		naturalWidth += width + (if itemCount > 0 then ITEM_GAP else 0)
		itemCount += 1
	end

	local function separator(): Frame
		addWidth(SEPARATOR_WIDTH)
		local line: Frame = Kit.new("Frame", {
			Name = "Separator",
			Size = UDim2.fromOffset(SEPARATOR_WIDTH, SEPARATOR_HEIGHT),
			BackgroundColor3 = Theme.Colors.PanelStroke,
			BorderSizePixel = 0,
			LayoutOrder = itemCount,
		}, panel)
		return line
	end

	local function button(text: string, width: number, onActivated: () -> (), style: Kit.ButtonStyle?): TextButton
		addWidth(width)
		return Kit.button(panel, text, onActivated, {
			name = text,
			size = UDim2.fromOffset(width, BUTTON_HEIGHT),
			style = style or "Ghost",
			textSize = Theme.TextSizes.Body,
			layoutOrder = itemCount,
		})
	end

	-- A button with a key badge on its right; the badge text is refreshed from Keybinds.
	local keyBadges: { { cap: TextLabel, action: string } } = {}
	local function withKey(target: TextButton, keyText: string, action: string?): TextLabel
		target.TextXAlignment = Enum.TextXAlignment.Left
		Kit.new("UIPadding", {
			PaddingLeft = UDim.new(0, KEY_PADDING_LEFT),
			PaddingRight = UDim.new(0, KEY_PADDING_RIGHT),
		}, target)
		local cap = Kit.keycap(target, keyText, { position = UDim2.fromScale(1, 0.5), anchor = Vector2.new(1, 0.5) })
		if action then
			table.insert(keyBadges, { cap = cap, action = action })
		end
		return cap
	end

	local currentSymmetry: BuildInfo.Symmetry = "Off"
	local currentBoarding: string = GameConfig.DEFAULT_BOARDING

	-- Menu
	button(MENU_TEXT, MENU_WIDTH, callbacks.onMenu)
	separator()

	-- Tools
	local toolButtons: { [string]: TextButton } = {}
	for _, tool: BuildInfo.Tool in BuildInfo.TOOLS do
		local b = button(tool, TOOL_WIDTHS[tool], function()
			callbacks.onTool(tool)
		end)
		withKey(b, Keybinds.label(TOOL_ACTIONS[tool]), TOOL_ACTIONS[tool])
		toolButtons[tool] = b
	end
	separator()

	-- Symmetry: click = next mode, right click = previous
	local symmetryButton = button(
		string.format(SYMMETRY_TEXT, BuildInfo.symmetryLabel("Off")),
		SYMMETRY_WIDTH,
		function()
			callbacks.onSymmetry(BuildInfo.nextIn(BuildInfo.SYMMETRY_ORDER, currentSymmetry, 1) :: BuildInfo.Symmetry)
		end
	)
	symmetryButton.MouseButton2Click:Connect(function()
		callbacks.onSymmetry(BuildInfo.nextIn(BuildInfo.SYMMETRY_ORDER, currentSymmetry, -1) :: BuildInfo.Symmetry)
	end)
	separator()

	-- Rotation
	local rotateButton = button(ROTATE_TEXT, ROTATE_WIDTH, function()
		callbacks.onAction(ROTATE_ACTION)
	end)
	withKey(rotateButton, Keybinds.label(ROTATE_ACTION), ROTATE_ACTION)
	local tiltButton = button(TILT_TEXT, TILT_WIDTH, function()
		callbacks.onAction(TILT_ACTION)
	end)
	withKey(tiltButton, Keybinds.label(TILT_ACTION), TILT_ACTION)
	addWidth(READOUT_WIDTH)
	local readout = Kit.plate(panel, UDim2.fromOffset(READOUT_WIDTH, BUTTON_HEIGHT))
	readout.Name = "Rotation"
	readout.LayoutOrder = itemCount
	local rotationText = Kit.label(readout, DEFAULT_ROTATION_TEXT, {
		size = UDim2.fromScale(1, 1),
		mono = true,
		textSize = Theme.TextSizes.Small,
		color = Theme.Colors.DigitalGreen,
		align = Enum.TextXAlignment.Center,
	})
	separator()

	-- Undo / Clear
	local undoButton = button(UNDO_TEXT, UNDO_WIDTH, callbacks.onUndo)
	withKey(undoButton, UNDO_KEY_TEXT, nil)
	button(CLEAR_TEXT, CLEAR_WIDTH, callbacks.onClear)
	separator()

	-- Saves
	button(SAVE_TEXT, SAVE_WIDTH, callbacks.onSave)
	button(LOAD_TEXT, LOAD_WIDTH, callbacks.onLoad)
	separator()

	-- Boarding permission
	local boardingButton = button(string.format(BOARDING_TEXT, currentBoarding), BOARDING_WIDTH, function()
		callbacks.onBoarding(BuildInfo.nextIn(BuildInfo.BOARDING_ORDER, currentBoarding, 1))
	end)
	boardingButton.TextXAlignment = Enum.TextXAlignment.Left
	Kit.new("UIPadding", { PaddingLeft = UDim.new(0, DOT_INSET * 2 + DOT_SIZE / 2) }, boardingButton)
	local boardingDot: Frame = Kit.new("Frame", {
		Name = "Dot",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, -DOT_INSET, 0.5, 0),
		Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE),
		BackgroundColor3 = BOARDING_COLORS[currentBoarding] or Theme.Colors.TextDim,
		BorderSizePixel = 0,
	}, boardingButton)
	Kit.round(boardingDot)
	Kit.stroke(boardingDot, Theme.Colors.ButtonStroke, Theme.Stroke.Thin)
	separator()

	-- Settings
	button(SETTINGS_TEXT, SETTINGS_WIDTH, callbacks.onSettings)

	panel.Size = UDim2.fromOffset(naturalWidth, BuildToolbar.HEIGHT)

	Keybinds.onChanged(function()
		for _, badge in keyBadges do
			badge.cap.Text = Keybinds.label(badge.action)
		end
	end)

	return {
		frame = panel,
		naturalWidth = naturalWidth,
		setFit = function(scale: number)
			fit.Scale = scale
		end,
		setTool = function(tool: BuildInfo.Tool)
			for name, b in toolButtons do
				Kit.setButtonStyle(b, if name == tool then TOOL_ON_STYLES[name] or "Accent" else "Ghost")
			end
		end,
		setSymmetry = function(mode: BuildInfo.Symmetry)
			currentSymmetry = mode
			symmetryButton.Text = string.format(SYMMETRY_TEXT, BuildInfo.symmetryLabel(mode))
			Kit.setButtonStyle(symmetryButton, if mode == "Off" then "Ghost" else "Accent")
		end,
		setRotationText = function(text: string)
			rotationText.Text = text
		end,
		setBoarding = function(mode: string)
			currentBoarding = mode
			boardingButton.Text = string.format(BOARDING_TEXT, mode)
			boardingDot.BackgroundColor3 = BOARDING_COLORS[mode] or Theme.Colors.TextDim
		end,
	}
end

return table.freeze(BuildToolbar)
