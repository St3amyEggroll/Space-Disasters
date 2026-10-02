--!strict
--[[
	BuildUI
	The hangar builder's screen UI. CHANGED (Phase 11): rebuilt in the Kerbal Space Program skin with UI/Theme and
	UI/Kit and split into Build* modules:
	  * TOP: a slim toolbar (BuildToolbar): Menu, the Build / Paint / Delete tools with their keys, symmetry, rotate /
	    tilt and the rotation readout, Undo, Clear (asks first: Kit.confirm "Clear the whole craft?"), Save / Load
	    (the slot picker dialog, BuildSlots), boarding permission and Settings (SettingsPanel)
	    CHANGED (Phase 11 review): a boarding change made with the button toasts what the mode means
	    (BuildInfo.boardingHint), and hiding the builder cancels a pending Clear / Overwrite / Load question
	  * LEFT: the part catalog (BuildCatalog): category tabs, part tiles with 3D previews, an info card with the
	    hovered / selected part's stats; the paint palette while the Paint tool is active
	  * RIGHT: a KSP-style staging list (first stage to fire at the bottom) with delta-v, TWR and what each stage
	    does, the craft stats card under it and the big green ROLL OUT button (BuildStaging)
	  * BOTTOM: key hints for the current tool (BuildHints; only while the "hints" setting is on)
	  * toasts go through Kit.toast (their own top layer, so they stay visible while the builder is hidden)

	Pure view: BuildController owns all state and passes callbacks in. The UI never fires remotes or reads game state;
	it only calls callbacks and renders what the set* functions give it (catalog tab, save-slot selection and the
	dialogs are local UI state). The whole builder UI is hidden while the main menu is open (UIState) and whenever
	the controller says so (not on the plot / in flight). Its panels sink clicks, and isPointerOverUI() lets the
	controller hide the ghost and ignore clicks over them.

	Layout: a Kit screen (the 1366 x 710 design canvas, scaled to the screen times the player's UI size). The toolbar
	sits just under the Roblox top bar (GuiService.TopbarInset) and shrinks to fit narrow canvases; the side panels
	fill the height below it.

	API:
	  BuildUI.create(callbacks: Callbacks) -> BuildUI
	  Callbacks: onSelectPart(partId), onTool(tool), onSelectColor(index), onSymmetry(mode), onUndo(), onClear()
	             (already confirmed), onSave(slot, name), onLoad(slot), onRollOut(), onBoarding(mode),
	             onAction(actionId) (CHANGED Phase 11: rotate / tilt buttons, a SettingsSchema Build action id)
	  BuildUI: setVisible(visible), setSelectedPart(partId?), setTool(tool), setSelectedColor(index),
	           setSymmetry(mode), setRotationText(text), setStats(stats), setSlots(names), setBoarding(mode),
	           toast(text, kind?), isPointerOverUI() -> boolean (CHANGED Phase 11)
]]

local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

local BuildCatalog = require(script.Parent.BuildCatalog)
local BuildHints = require(script.Parent.BuildHints)
local BuildInfo = require(script.Parent.BuildInfo)
local BuildSlots = require(script.Parent.BuildSlots)
local BuildStaging = require(script.Parent.BuildStaging)
local BuildToolbar = require(script.Parent.BuildToolbar)
local Kit = require(script.Parent.Kit)
local SettingsPanel = require(script.Parent.SettingsPanel)
local Theme = require(script.Parent.Theme)
local UIState = require(script.Parent.UIState)

--============================================================================
-- Tunables
--============================================================================
local GUI_NAME = "BuildUI"
-- Layout (design px)
local MARGIN = 12 -- from the canvas edges
local TOOLBAR_TOP_GAP = 6 -- under the Roblox top bar
local PANEL_GAP = 8 -- toolbar to the side panels
local HINTS_BOTTOM = 12
local HINTS_MIN_ROOM = 480 -- the hint strip is hidden when the gap between the side panels is narrower
local TOOLBAR_MIN_FIT = 0.5 -- the toolbar never shrinks below this
-- Dialogs
local CLEAR_DIALOG: Kit.ConfirmOptions = {
	title = "Clear the whole craft?",
	body = "Every block on your plot is removed. This cannot be undone.",
	confirmText = "Clear",
	cancelText = "Cancel",
	danger = true,
}
local TOAST_KINDS: { [string]: Kit.ToastKind } = { Error = "Error", Warning = "Warning", Info = "Info" }
local BOARDING_TOAST = "Boarding: %s. %s." -- CHANGED (Phase 11 review): mode, BuildInfo.boardingHint(mode)
--============================================================================

export type Tool = BuildInfo.Tool
export type Symmetry = BuildInfo.Symmetry
export type StageRow = BuildInfo.StageRow
export type Stats = BuildInfo.Stats

export type Callbacks = {
	onSelectPart: (partId: string) -> (),
	onTool: (tool: Tool) -> (),
	onSelectColor: (index: number) -> (), -- Paint.List index
	onSymmetry: (mode: Symmetry) -> (),
	onUndo: () -> (),
	onClear: () -> (), -- CHANGED (Phase 11): called after the player confirmed
	onSave: (slot: number, name: string) -> (),
	onLoad: (slot: number) -> (),
	onRollOut: () -> (),
	onBoarding: (mode: string) -> (), -- "Public" | "Friends" | "Private"
	onAction: (actionId: string) -> (), -- CHANGED (Phase 11): a Build action by SettingsSchema id (rotate / tilt)
}

export type BuildUI = {
	setVisible: (visible: boolean) -> (), -- whole builder UI (toasts stay visible regardless)
	setSelectedPart: (partId: string?) -> (),
	setTool: (tool: Tool) -> (),
	setSelectedColor: (index: number) -> (),
	setSymmetry: (mode: Symmetry) -> (),
	setRotationText: (text: string) -> (), -- e.g. "up +Y  yaw 90"
	setStats: (stats: Stats) -> (),
	setSlots: (names: { [number]: string }) -> (),
	setBoarding: (mode: string) -> (),
	toast: (text: string, kind: string?) -> (), -- kind "Error" | "Warning" | "Info" | nil
	isPointerOverUI: () -> boolean, -- CHANGED (Phase 11): the mouse is over a builder panel
}

local BuildUI = {}

local function contains(object: GuiObject, point: Vector2): boolean
	if not object.Visible then
		return false
	end
	local position, size = object.AbsolutePosition, object.AbsoluteSize
	return point.X >= position.X
		and point.Y >= position.Y
		and point.X <= position.X + size.X
		and point.Y <= position.Y + size.Y
end

function BuildUI.create(callbacks: Callbacks): BuildUI
	local _, canvas = Kit.screen(GUI_NAME, Theme.DisplayOrder.Builder)
	local root = Kit.frame(canvas, { name = "Builder" })
	root.Visible = false

	local wanted = false -- the controller's setVisible
	local cancelClear: (() -> ())? = nil -- CHANGED (Phase 11 review): the open "Clear the whole craft?" question
	local boardingClicked = false -- CHANGED (Phase 11 review): the next boarding change came from the button

	--========================================================================
	-- Pieces
	--========================================================================
	local slots = BuildSlots.create({
		onSave = callbacks.onSave,
		onLoad = callbacks.onLoad,
	})

	local toolbar = BuildToolbar.create(root, {
		onMenu = function()
			UIState.requestMenu()
		end,
		onTool = callbacks.onTool,
		onSymmetry = callbacks.onSymmetry,
		onAction = callbacks.onAction,
		onUndo = callbacks.onUndo,
		onClear = function()
			-- CHANGED (Phase 11 review): kept, so hiding the builder can cancel the question
			cancelClear = Kit.confirm(CLEAR_DIALOG, function(confirmed: boolean)
				cancelClear = nil
				if confirmed then
					callbacks.onClear()
				end
			end)
		end,
		onSave = function()
			slots.open("Save")
		end,
		onLoad = function()
			slots.open("Load")
		end,
		onBoarding = function(mode: string)
			boardingClicked = true -- CHANGED (Phase 11 review): say what the new mode means once it is set
			callbacks.onBoarding(mode)
		end,
		onSettings = function()
			SettingsPanel.open()
		end,
	})

	local catalog = BuildCatalog.create(root, {
		onSelectPart = callbacks.onSelectPart,
		onSelectColor = callbacks.onSelectColor,
	})

	local staging = BuildStaging.create(root, { onRollOut = callbacks.onRollOut })

	local hints = BuildHints.create(root)

	--========================================================================
	-- Layout (under the Roblox top bar; the toolbar shrinks to fit)
	--========================================================================
	local canvasScale = canvas:FindFirstChildOfClass("UIScale")
	local function layout()
		local scale = if canvasScale and canvasScale.Scale > 0 then canvasScale.Scale else 1
		local topbar = GuiService.TopbarInset.Max.Y / scale
		local top = math.max(MARGIN, math.ceil(topbar) + TOOLBAR_TOP_GAP)
		local available = canvas.Size.X.Offset - MARGIN * 2
		local fit = BuildInfo.fitScale(available, toolbar.naturalWidth, TOOLBAR_MIN_FIT)
		toolbar.setFit(fit)
		toolbar.frame.Position = UDim2.new(0.5, 0, 0, top)

		local below = top + math.ceil(BuildToolbar.HEIGHT * fit) + PANEL_GAP
		catalog.frame.Position = UDim2.fromOffset(MARGIN, below)
		catalog.frame.Size = UDim2.new(0, BuildCatalog.WIDTH, 1, -(below + MARGIN))
		staging.frame.Position = UDim2.new(1, -MARGIN, 0, below)
		staging.frame.Size = UDim2.new(0, BuildStaging.WIDTH, 1, -(below + MARGIN))
		-- hints: centred in the gap between the two side panels
		local centreShift = (BuildCatalog.WIDTH - BuildStaging.WIDTH) / 2
		hints.frame.Position = UDim2.new(0.5, centreShift, 1, -HINTS_BOTTOM)
		local room = canvas.Size.X.Offset - MARGIN * 2 - BuildCatalog.WIDTH - BuildStaging.WIDTH - PANEL_GAP * 2
		hints.setHasRoom(room >= HINTS_MIN_ROOM)
	end
	canvas:GetPropertyChangedSignal("Size"):Connect(layout)
	if canvasScale then
		canvasScale:GetPropertyChangedSignal("Scale"):Connect(layout)
	end
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(layout)
	layout()

	--========================================================================
	-- Visibility (the controller's wish, and never over the main menu)
	--========================================================================
	local function refreshVisible()
		local visible = wanted and not UIState.isMenuOpen()
		root.Visible = visible
		catalog.setActive(visible)
		if not visible then
			-- CHANGED (Phase 11 review): a pending Clear question goes with the builder (slots.close cancels its own)
			local cancel = cancelClear
			cancelClear = nil
			if cancel then
				cancel()
			end
			slots.close()
		end
	end
	UIState.onMenuChanged(refreshVisible)

	--========================================================================
	-- API
	--========================================================================
	local ui: BuildUI = {
		setVisible = function(visible: boolean)
			wanted = visible
			refreshVisible()
		end,
		setSelectedPart = function(partId: string?)
			catalog.setSelectedPart(partId)
		end,
		setTool = function(tool: Tool)
			if table.find(BuildInfo.TOOLS, tool) then
				toolbar.setTool(tool)
				catalog.setTool(tool)
				hints.setTool(tool)
			end
		end,
		setSelectedColor = function(index: number)
			catalog.setSelectedColor(index)
		end,
		setSymmetry = function(mode: Symmetry)
			toolbar.setSymmetry(mode)
		end,
		setRotationText = function(text: string)
			toolbar.setRotationText(text)
		end,
		setStats = function(stats: Stats)
			staging.setStats(stats)
			slots.setPartCount(stats.parts)
		end,
		setSlots = function(names: { [number]: string })
			slots.setSlots(names)
		end,
		setBoarding = function(mode: string)
			toolbar.setBoarding(mode)
			-- CHANGED (Phase 11 review): the pre-Phase-11 hint ("Anyone can board" ...) after a click on the button
			if boardingClicked then
				boardingClicked = false
				Kit.toast(string.format(BOARDING_TOAST, mode, BuildInfo.boardingHint(mode)), "Info")
			end
		end,
		toast = function(text: string, kind: string?)
			Kit.toast(text, TOAST_KINDS[kind or "Info"] or "Info")
		end,
		isPointerOverUI = function(): boolean
			if not root.Visible then
				return false
			end
			-- GetMouseLocation is in full-screen pixels; the canvas covers the full screen (Kit screens ignore the
			-- GUI inset), so adding its AbsolutePosition moves the mouse into AbsolutePosition space whether or not
			-- that space starts under the top bar.
			local mouse = UserInputService:GetMouseLocation() + canvas.AbsolutePosition
			if contains(toolbar.frame, mouse) or contains(catalog.frame, mouse) or contains(hints.frame, mouse) then
				return true
			end
			for _, panel in staging.panels do
				if contains(panel, mouse) then
					return true
				end
			end
			return false
		end,
	}
	return ui
end

return table.freeze(BuildUI)
