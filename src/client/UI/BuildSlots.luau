--!strict
--[[
	BuildSlots (Phase 11)
	The builder's save / load slot picker in the KSP pause-dialog look: a centred dark panel over a dim backdrop with
	the green title ("Save Craft" / "Load Craft"), in Save mode a craft name box, the 10 slots as a list (slot number
	and craft name, "Empty" when free) and Cancel / Save (or Load) buttons.

	  * Save: picking a filled slot copies its name into the box; saving into a filled slot asks first
	    (Kit.confirm "Overwrite slot N?"). An empty name is fine (the server names it "Craft N").
	  * Load: empty slots are greyed out; loading over a craft that has parts asks first (it replaces the plot).
	  * Escape, Cancel or a click on the backdrop closes it; Enter in the name box saves.

	While open it holds UIState modal "BuildSlots" (so building ignores the player). Built lazily on the first open,
	in its own ScreenGui at Theme.DisplayOrder.Settings (above the builder and the HUD, below Kit.confirm dialogs and
	toasts). Pure view: it only calls onSave / onLoad.

	API:
	  BuildSlots.create(callbacks) -> SlotDialog
	    callbacks: { onSave(slot, name), onLoad(slot) }
	  SlotDialog.open(mode: "Save" | "Load")
	  SlotDialog.close()
	  SlotDialog.isOpen() -> boolean
	  SlotDialog.setSlots(names: { [number]: string })   slot -> craft name (missing = empty)
	  SlotDialog.setPartCount(count)                     parts on the plot now (asks before a load replaces them)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildInfo = require(script.Parent.BuildInfo)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)
local UIState = require(script.Parent.UIState)

--============================================================================
-- Tunables
--============================================================================
local GUI_NAME = "BuildSlots"
local MODAL_NAME = "BuildSlots" -- UIState modal while open
-- Layout (design px)
local DIALOG_SIZE = Vector2.new(420, 500) -- shrunk to fit small screens / a big UI size
local SCREEN_MARGIN = 16
local SECTION_GAP = 8
local NAME_ROW_HEIGHT = 32
local NAME_LABEL_WIDTH = 56
local NAME_BOX_PADDING = 8
local SLOT_ROW_HEIGHT = 32
local SLOT_TEXT_INSET = 12
local LIST_GAP = 4
local POP_SCALE = 0.95
-- Text
local SAVE_TITLE = "Save Craft"
local LOAD_TITLE = "Load Craft"
local SAVE_TEXT = "Save"
local LOAD_TEXT = "Load"
local CANCEL_TEXT = "Cancel"
local NAME_LABEL = "Name"
local NAME_PLACEHOLDER = "Craft %d"
--============================================================================

export type Mode = "Save" | "Load"

export type Callbacks = {
	onSave: (slot: number, name: string) -> (),
	onLoad: (slot: number) -> (),
}

export type SlotDialog = {
	open: (mode: Mode) -> (),
	close: () -> (),
	isOpen: () -> boolean,
	setSlots: (names: { [number]: string }) -> (),
	setPartCount: (count: number) -> (),
}

type View = {
	screen: ScreenGui,
	backdrop: TextButton,
	panel: Frame,
	pop: UIScale,
	title: TextLabel,
	nameRow: Frame,
	nameBox: TextBox,
	nameStroke: UIStroke,
	list: ScrollingFrame,
	rows: { TextButton },
	action: TextButton,
}

local BuildSlots = {}

local new = Kit.new

function BuildSlots.create(callbacks: Callbacks): SlotDialog
	local slotNames: { [number]: string } = {}
	local partCount = 0
	local mode: Mode = "Save"
	local selectedSlot = 1
	local isOpen = false
	local removeEscape: () -> () = function() end
	local view: View? = nil
	local cancelConfirm: (() -> ())? = nil -- CHANGED (Phase 11 review): the open Overwrite / Load question

	local function firstSlot(filled: boolean): number?
		for slot = 1, GameConfig.SAVE_SLOTS do
			if (slotNames[slot] ~= nil) == filled then
				return slot
			end
		end
		return nil
	end

	local close: () -> ()
	local performAction: () -> ()

	local function render()
		local v = view
		if v == nil then
			return
		end
		local saving = mode == "Save"
		v.title.Text = if saving then SAVE_TITLE else LOAD_TITLE
		v.action.Text = if saving then SAVE_TEXT else LOAD_TEXT
		v.nameRow.Visible = saving
		v.nameBox.PlaceholderText = string.format(NAME_PLACEHOLDER, selectedSlot)
		local listTop = Theme.Sizes.Title + SECTION_GAP + (if saving then NAME_ROW_HEIGHT + SECTION_GAP else 0)
		v.list.Position = UDim2.fromOffset(0, listTop)
		v.list.Size = UDim2.new(1, 0, 1, -(listTop + Theme.Sizes.Button + SECTION_GAP))
		for slot, row in v.rows do
			local name = slotNames[slot]
			row.Text = BuildInfo.slotLabel(slot, name)
			Kit.setButtonEnabled(row, saving or name ~= nil)
			Kit.setButtonStyle(row, if slot == selectedSlot then "Primary" else "Ghost")
		end
		Kit.setButtonEnabled(v.action, saving or slotNames[selectedSlot] ~= nil)
	end

	local function build(): View
		local screen, canvas = Kit.screen(GUI_NAME, Theme.DisplayOrder.Settings)
		screen.Enabled = false
		local backdrop = Kit.backdrop(canvas)
		backdrop.Activated:Connect(function()
			close()
		end)
		local panel = Kit.panel({
			parent = canvas,
			name = "SlotDialog",
			size = UDim2.fromOffset(DIALOG_SIZE.X, DIALOG_SIZE.Y),
			position = UDim2.fromScale(0.5, 0.5),
			anchor = Vector2.new(0.5, 0.5),
		})
		Kit.fitToCanvas(panel, canvas, DIALOG_SIZE, SCREEN_MARGIN)
		local pop: UIScale = new("UIScale", { Scale = 1 }, panel)
		local title = Kit.title(panel, SAVE_TITLE)

		-- Name row (Save mode)
		local nameRow = Kit.frame(panel, {
			name = "NameRow",
			position = UDim2.fromOffset(0, Theme.Sizes.Title + SECTION_GAP),
			size = UDim2.new(1, 0, 0, NAME_ROW_HEIGHT),
		})
		Kit.label(nameRow, NAME_LABEL, { size = UDim2.new(0, NAME_LABEL_WIDTH, 1, 0), dim = true })
		local nameBox: TextBox = new("TextBox", {
			Name = "NameBox",
			Position = UDim2.fromOffset(NAME_LABEL_WIDTH, 0),
			Size = UDim2.new(1, -NAME_LABEL_WIDTH, 1, 0),
			BackgroundColor3 = Theme.Colors.PanelInset,
			BackgroundTransparency = Theme.Transparency.Inset,
			BorderSizePixel = 0,
			ClearTextOnFocus = false,
			Font = Theme.Fonts.Medium,
			TextSize = Theme.TextSizes.Body,
			TextColor3 = Theme.Colors.Text,
			PlaceholderColor3 = Theme.Colors.TextDim,
			PlaceholderText = string.format(NAME_PLACEHOLDER, 1),
			Text = "",
			TextXAlignment = Enum.TextXAlignment.Left,
			TextTruncate = Enum.TextTruncate.AtEnd,
		}, nameRow)
		Kit.corner(nameBox, Theme.Radius.Small)
		local nameStroke = Kit.stroke(nameBox, Theme.Colors.PanelStroke, Theme.Stroke.Thin)
		new("UIPadding", {
			PaddingLeft = UDim.new(0, NAME_BOX_PADDING),
			PaddingRight = UDim.new(0, NAME_BOX_PADDING),
		}, nameBox)
		nameBox.Focused:Connect(function()
			nameStroke.Color = Theme.Colors.Title
		end)
		nameBox.FocusLost:Connect(function(enterPressed: boolean)
			nameStroke.Color = Theme.Colors.PanelStroke
			if enterPressed and isOpen then
				performAction()
			end
		end)
		nameBox:GetPropertyChangedSignal("Text"):Connect(function()
			if #nameBox.Text > CraftDesign.MAX_NAME_LENGTH then
				nameBox.Text = string.sub(nameBox.Text, 1, CraftDesign.MAX_NAME_LENGTH)
			end
		end)

		-- Slot list
		local list = Kit.scroll(panel, { name = "Slots", size = UDim2.fromScale(1, 1), gap = LIST_GAP })
		local rows: { TextButton } = {}
		for slot = 1, GameConfig.SAVE_SLOTS do
			local row = Kit.button(list, BuildInfo.slotLabel(slot, nil), function()
				selectedSlot = slot
				local name = slotNames[slot]
				if mode == "Save" and name then
					nameBox.Text = name
				end
				render()
			end, {
				name = "Slot" .. slot,
				size = UDim2.new(1, 0, 0, SLOT_ROW_HEIGHT),
				style = "Ghost",
				textSize = Theme.TextSizes.Body,
				layoutOrder = slot,
			})
			row.TextXAlignment = Enum.TextXAlignment.Left
			new("UIPadding", { PaddingLeft = UDim.new(0, SLOT_TEXT_INSET) }, row)
			rows[slot] = row
		end

		-- Buttons
		local buttons = Kit.frame(panel, {
			name = "Buttons",
			anchor = Vector2.new(0, 1),
			position = UDim2.fromScale(0, 1),
			size = UDim2.new(1, 0, 0, Theme.Sizes.Button),
		})
		local half = SECTION_GAP / 2
		Kit.button(buttons, CANCEL_TEXT, function()
			close()
		end, { name = "Cancel", size = UDim2.new(0.5, -half, 1, 0) })
		local action = Kit.button(buttons, SAVE_TEXT, function()
			performAction()
		end, {
			name = "Action",
			style = "Accent",
			size = UDim2.new(0.5, -half, 1, 0),
			position = UDim2.fromScale(1, 0),
			anchor = Vector2.new(1, 0),
		})

		return {
			screen = screen,
			backdrop = backdrop,
			panel = panel,
			pop = pop,
			title = title,
			nameRow = nameRow,
			nameBox = nameBox,
			nameStroke = nameStroke,
			list = list,
			rows = rows,
			action = action,
		}
	end

	close = function()
		-- CHANGED (Phase 11 review): a pending Overwrite / Load question goes with the dialog
		local cancel = cancelConfirm
		cancelConfirm = nil
		if cancel then
			cancel()
		end
		if not isOpen then
			return
		end
		isOpen = false
		removeEscape()
		removeEscape = function() end
		local v = view
		if v then
			v.nameBox:ReleaseFocus()
			v.screen.Enabled = false
		end
		UIState.popModal(MODAL_NAME)
	end

	performAction = function()
		local v = view
		if v == nil or not isOpen then
			return
		end
		local slot = selectedSlot
		local existing = slotNames[slot]
		if mode == "Save" then
			local name = BuildInfo.trimName(v.nameBox.Text, CraftDesign.MAX_NAME_LENGTH)
			if existing == nil then
				callbacks.onSave(slot, name)
				close()
				return
			end
			cancelConfirm = Kit.confirm({
				title = `Overwrite slot {slot}?`,
				body = `"{existing}" in slot {slot} will be replaced by the craft on your plot.`,
				confirmText = "Overwrite",
				danger = true,
			}, function(confirmed: boolean)
				cancelConfirm = nil -- CHANGED (Phase 11 review)
				if confirmed then
					callbacks.onSave(slot, name)
					close()
				end
			end)
			return
		end
		if existing == nil then
			return
		end
		if partCount == 0 then
			callbacks.onLoad(slot)
			close()
			return
		end
		cancelConfirm = Kit.confirm({
			title = `Load "{existing}"?`,
			body = "The craft on your plot will be replaced. Save it first if you want to keep it.",
			confirmText = "Load",
		}, function(confirmed: boolean)
			cancelConfirm = nil -- CHANGED (Phase 11 review)
			if confirmed then
				callbacks.onLoad(slot)
				close()
			end
		end)
	end

	return {
		open = function(newMode: Mode)
			local v = view or build()
			view = v
			mode = newMode
			if newMode == "Load" and slotNames[selectedSlot] == nil then
				selectedSlot = firstSlot(true) or selectedSlot
			elseif newMode == "Save" and not isOpen then
				v.nameBox.Text = slotNames[selectedSlot] or v.nameBox.Text
			end
			render()
			if isOpen then
				return
			end
			isOpen = true
			v.screen.Enabled = true
			UIState.pushModal(MODAL_NAME)
			removeEscape = Kit.onEscape(close)
			v.backdrop.BackgroundTransparency = 1
			Kit.tween(v.backdrop, { BackgroundTransparency = Theme.Transparency.Backdrop }, Theme.Tween.Normal)
			v.pop.Scale = POP_SCALE
			Kit.tween(v.pop, { Scale = 1 }, Theme.Tween.Normal)
		end,
		close = close,
		isOpen = function(): boolean
			return isOpen
		end,
		setSlots = function(names: { [number]: string })
			local copy: { [number]: string } = {}
			for slot, name in names do
				if type(slot) == "number" and type(name) == "string" and name ~= "" then
					copy[slot] = name
				end
			end
			slotNames = copy
			if view == nil then
				-- first slot list: start Save on the first free slot
				selectedSlot = firstSlot(false) or 1
			end
			render()
		end,
		setPartCount = function(count: number)
			partCount = count
		end,
	}
end

return table.freeze(BuildSlots)
