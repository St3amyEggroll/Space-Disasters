--!strict
--[[
	BuildUI
	The hangar builder's screen UI: part palette (by category), toolbar, live stats panel, save/load slots,
	Roll Out and boarding-permission buttons, a controls hint and toast notifications.

	Pure view: BuildController owns the state and passes callbacks in; the UI never talks to the server itself.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)

--============================================================================
-- Tunables
--============================================================================
local FONT = Enum.Font.GothamMedium
local FONT_BOLD = Enum.Font.GothamBold
local BG = Color3.fromRGB(22, 25, 34)
local BG_LIGHT = Color3.fromRGB(38, 43, 58)
local ACCENT = Color3.fromRGB(255, 140, 40)
local TEXT = Color3.fromRGB(235, 237, 245)
local TEXT_DIM = Color3.fromRGB(160, 166, 184)
local WARN = Color3.fromRGB(255, 110, 90)
local GOOD = Color3.fromRGB(120, 220, 140)
local PANEL_TRANSPARENCY = 0.12
local PALETTE_WIDTH = 190
local STATS_WIDTH = 270
local TOAST_TIME_S = 3
local CATEGORY_NAMES: { [string]: string } = {
	Command = "Command",
	FuelTank = "Fuel tanks",
	Engine = "Engines",
	Coupling = "Coupling",
	Aero = "Aero",
	Utility = "Utility",
	Structural = "Structural",
}
local BOARDING_ORDER = { "Public", "Friends", "Private" }
--============================================================================

export type StageRow = { stage: number, dvVac: number, dvAsl: number, twrAsl: number }

export type Stats = {
	mass: number,
	parts: number,
	stages: { StageRow },
	totalVac: number,
	totalAsl: number,
	warnings: { string },
}

export type Callbacks = {
	onSelectPart: (partId: string) -> (),
	onUndo: () -> (),
	onToggleDelete: () -> (),
	onSymmetry: (count: number) -> (),
	onClear: () -> (),
	onSave: (slot: number, name: string) -> (),
	onLoad: (slot: number) -> (),
	onRollOut: () -> (),
	onBoarding: (mode: string) -> (),
}

export type BuildUI = {
	setVisible: (visible: boolean) -> (),
	setSelected: (partId: string?) -> (),
	setMode: (deleteMode: boolean, symmetry: number, rotationText: string) -> (),
	setStats: (stats: Stats) -> (),
	setSlots: (names: { [number]: string }) -> (),
	setBoarding: (mode: string) -> (),
	toast: (text: string, kind: string?) -> (),
}

local BuildUI = {}

local function new<T>(className: string, props: { [string]: any }, parent: Instance?): T
	local instance = Instance.new(className)
	for key, value in props do
		(instance :: any)[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return (instance :: any) :: T
end

local function corner(parent: Instance, radius: number?)
	new("UICorner", { CornerRadius = UDim.new(0, radius or 6) }, parent)
end

local function padding(parent: Instance, px: number)
	new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	}, parent)
end

local function panel(parent: Instance, props: { [string]: any }): Frame
	local frame: Frame = new("Frame", props, parent)
	frame.BackgroundColor3 = BG
	frame.BackgroundTransparency = PANEL_TRANSPARENCY
	frame.BorderSizePixel = 0
	frame.Active = true -- clicks on panels must not place blocks behind them
	corner(frame, 8)
	return frame
end

local function label(parent: Instance, text: string, size: number, props: { [string]: any }?): TextLabel
	local l: TextLabel = new("TextLabel", {
		BackgroundTransparency = 1,
		Font = FONT,
		TextSize = size,
		TextColor3 = TEXT,
		Text = text,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, size + 6),
	}, parent)
	if props then
		for key, value in props do
			(l :: any)[key] = value
		end
	end
	return l
end

local function button(parent: Instance, text: string, props: { [string]: any }?): TextButton
	local b: TextButton = new("TextButton", {
		BackgroundColor3 = BG_LIGHT,
		AutoButtonColor = true,
		Font = FONT,
		TextSize = 14,
		TextColor3 = TEXT,
		Text = text,
		Size = UDim2.new(1, 0, 0, 28),
	}, parent)
	corner(b, 5)
	if props then
		for key, value in props do
			(b :: any)[key] = value
		end
	end
	return b
end

local function list(parent: Instance, spacing: number)
	new("UIListLayout", {
		Padding = UDim.new(0, spacing),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, parent)
end

function BuildUI.create(callbacks: Callbacks): BuildUI
	local player = Players.LocalPlayer
	local screen: ScreenGui = new("ScreenGui", {
		Name = "BuildUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = true,
	}, player:WaitForChild("PlayerGui"))

	local root: Frame =
		new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, screen)

	--========================================================================
	-- Palette (left)
	--========================================================================
	local palette = panel(root, {
		Position = UDim2.new(0, 10, 0, 10),
		Size = UDim2.new(0, PALETTE_WIDTH, 1, -70),
	})
	padding(palette, 8)
	label(palette, "PARTS", 16, { Font = FONT_BOLD, TextColor3 = ACCENT })
	local scroll: ScrollingFrame = new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.new(0, 0, 0, 26),
		Size = UDim2.new(1, 0, 1, -26),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
	}, palette)
	list(scroll, 4)

	local partButtons: { [string]: TextButton } = {}
	local order = 0
	local byCategory = Parts.byCategory()
	for _, category: Parts.Category in Parts.Categories do
		order += 1
		label(scroll, CATEGORY_NAMES[category] or category, 13, {
			LayoutOrder = order,
			TextColor3 = TEXT_DIM,
			Font = FONT_BOLD,
		})
		for _, def in byCategory[category] do
			order += 1
			local b = button(scroll, def.DisplayName, {
				LayoutOrder = order,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, -6, 0, 26),
			})
			new("UIPadding", { PaddingLeft = UDim.new(0, 8) }, b)
			b.Activated:Connect(function()
				callbacks.onSelectPart(def.Id)
			end)
			partButtons[def.Id] = b
		end
	end

	--========================================================================
	-- Toolbar (top centre)
	--========================================================================
	local toolbar = panel(root, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 10),
		Size = UDim2.new(0, 520, 0, 44),
	})
	padding(toolbar, 7)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		VerticalAlignment = Enum.VerticalAlignment.Center,
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, toolbar)
	local modeLabel = label(toolbar, "BUILD", 14, {
		LayoutOrder = 1,
		Size = UDim2.new(0, 170, 1, 0),
		Font = FONT_BOLD,
		TextColor3 = GOOD,
	})
	local deleteButton = button(toolbar, "Delete (X)", { LayoutOrder = 2, Size = UDim2.new(0, 84, 1, 0) })
	deleteButton.Activated:Connect(callbacks.onToggleDelete)
	local symmetryButton = button(toolbar, "Sym 1x", { LayoutOrder = 3, Size = UDim2.new(0, 64, 1, 0) })
	local symmetryCycle = { 1, 2, 4 }
	local currentSymmetry = 1
	symmetryButton.Activated:Connect(function()
		local index = table.find(symmetryCycle, currentSymmetry) or 1
		callbacks.onSymmetry(symmetryCycle[index % #symmetryCycle + 1])
	end)
	local undoButton = button(toolbar, "Undo", { LayoutOrder = 4, Size = UDim2.new(0, 56, 1, 0) })
	undoButton.Activated:Connect(callbacks.onUndo)
	local clearButton = button(toolbar, "Clear", { LayoutOrder = 5, Size = UDim2.new(0, 56, 1, 0) })
	local clearArmed = false
	clearButton.Activated:Connect(function()
		if clearArmed then
			clearArmed = false
			clearButton.Text = "Clear"
			callbacks.onClear()
		else
			clearArmed = true
			clearButton.Text = "Sure?"
			task.delay(2, function()
				clearArmed = false
				clearButton.Text = "Clear"
			end)
		end
	end)

	--========================================================================
	-- Stats (right)
	--========================================================================
	local statsPanel = panel(root, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0, 10),
		Size = UDim2.new(0, STATS_WIDTH, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	padding(statsPanel, 10)
	list(statsPanel, 2)
	label(statsPanel, "CRAFT STATS", 16, { Font = FONT_BOLD, TextColor3 = ACCENT, LayoutOrder = 1 })
	local summary = label(statsPanel, "", 14, { LayoutOrder = 2 })
	local stageText = label(statsPanel, "", 13, {
		LayoutOrder = 3,
		Font = Enum.Font.Code,
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})
	local warningText = label(statsPanel, "", 13, {
		LayoutOrder = 4,
		TextColor3 = WARN,
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
	})

	--========================================================================
	-- Save / load / roll out (bottom right)
	--========================================================================
	local savePanel = panel(root, {
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -10, 1, -60),
		Size = UDim2.new(0, STATS_WIDTH, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	padding(savePanel, 10)
	list(savePanel, 6)
	label(savePanel, "SAVES", 16, { Font = FONT_BOLD, TextColor3 = ACCENT, LayoutOrder = 1 })
	local nameBox: TextBox = new("TextBox", {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 28),
		BackgroundColor3 = BG_LIGHT,
		TextColor3 = TEXT,
		PlaceholderText = "Craft name",
		PlaceholderColor3 = TEXT_DIM,
		Font = FONT,
		TextSize = 14,
		Text = "",
		ClearTextOnFocus = false,
	}, savePanel)
	corner(nameBox, 5)
	local slotGrid: Frame = new("Frame", {
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, savePanel)
	new("UIGridLayout", {
		CellSize = UDim2.new(0.2, -4, 0, 28),
		CellPadding = UDim2.new(0, 4, 0, 4),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, slotGrid)
	local slotLabel = label(savePanel, "Slot 1: empty", 13, { LayoutOrder = 4, TextColor3 = TEXT_DIM })
	local selectedSlot = 1
	local slotNames: { [number]: string } = {}
	local slotButtons: { TextButton } = {}
	local function refreshSlots()
		for slot, b in slotButtons do
			local filled = slotNames[slot] ~= nil
			b.BackgroundColor3 = if slot == selectedSlot then ACCENT elseif filled then BG_LIGHT else BG
			b.TextColor3 = if slot == selectedSlot then Color3.new(0, 0, 0) else TEXT
		end
		slotLabel.Text = `Slot {selectedSlot}: {slotNames[selectedSlot] or "empty"}`
	end
	for slot = 1, GameConfig.SAVE_SLOTS do
		local b = button(slotGrid, tostring(slot), { LayoutOrder = slot })
		b.Activated:Connect(function()
			selectedSlot = slot
			if slotNames[slot] then
				nameBox.Text = slotNames[slot]
			end
			refreshSlots()
		end)
		slotButtons[slot] = b
	end
	local saveRow: Frame =
		new("Frame", { LayoutOrder = 5, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 28) }, savePanel)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Horizontal,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, saveRow)
	local saveButton = button(saveRow, "Save", { LayoutOrder = 1, Size = UDim2.new(0.5, -3, 1, 0) })
	saveButton.Activated:Connect(function()
		callbacks.onSave(selectedSlot, nameBox.Text)
	end)
	local loadButton = button(saveRow, "Load", { LayoutOrder = 2, Size = UDim2.new(0.5, -3, 1, 0) })
	loadButton.Activated:Connect(function()
		callbacks.onLoad(selectedSlot)
	end)
	local boardingButton = button(savePanel, "Boarding: Public", { LayoutOrder = 6 })
	local boardingMode = "Public"
	boardingButton.Activated:Connect(function()
		local index = table.find(BOARDING_ORDER, boardingMode) or 1
		callbacks.onBoarding(BOARDING_ORDER[index % #BOARDING_ORDER + 1])
	end)
	local rollOutButton = button(savePanel, "ROLL OUT", {
		LayoutOrder = 7,
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = ACCENT,
		TextColor3 = Color3.new(0, 0, 0),
		Font = FONT_BOLD,
		TextSize = 18,
	})
	rollOutButton.Activated:Connect(callbacks.onRollOut)
	refreshSlots()

	--========================================================================
	-- Controls hint (bottom centre) and toast (top centre, always visible)
	--========================================================================
	local hint = panel(root, {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -10),
		Size = UDim2.new(0, 640, 0, 30),
	})
	label(hint, "Click: place   R / T: rotate   X: delete mode   1 / 2 / 4: symmetry   Ctrl+Z: undo", 13, {
		Size = UDim2.fromScale(1, 1),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = TEXT_DIM,
	})

	local toastLabel: TextLabel = new("TextLabel", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 62),
		Size = UDim2.new(0, 0, 0, 30),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = BG,
		BackgroundTransparency = 0.1,
		Font = FONT,
		TextSize = 15,
		TextColor3 = TEXT,
		Text = "",
		Visible = false,
	}, screen)
	corner(toastLabel, 6)
	new("UIPadding", { PaddingLeft = UDim.new(0, 12), PaddingRight = UDim.new(0, 12) }, toastLabel)
	local toastSerial = 0

	--========================================================================
	-- API
	--========================================================================
	local ui: BuildUI = {
		setVisible = function(visible: boolean)
			root.Visible = visible
		end,
		setSelected = function(partId: string?)
			for id, b in partButtons do
				b.BackgroundColor3 = if id == partId then ACCENT else BG_LIGHT
				b.TextColor3 = if id == partId then Color3.new(0, 0, 0) else TEXT
			end
		end,
		setMode = function(deleteMode: boolean, symmetry: number, rotationText: string)
			currentSymmetry = symmetry
			modeLabel.Text = if deleteMode then "DELETE" else `BUILD  {rotationText}`
			modeLabel.TextColor3 = if deleteMode then WARN else GOOD
			deleteButton.BackgroundColor3 = if deleteMode then WARN else BG_LIGHT
			symmetryButton.Text = `Sym {symmetry}x`
		end,
		setStats = function(stats: Stats)
			summary.Text = string.format(
				"Mass %.2f t   Parts %d/%d\nTotal dv  %d m/s vac  |  %d m/s ASL",
				stats.mass / 1000,
				stats.parts,
				GameConfig.MAX_BLOCKS_PER_CRAFT,
				math.floor(stats.totalVac + 0.5),
				math.floor(stats.totalAsl + 0.5)
			)
			summary.Size = UDim2.new(1, 0, 0, 0)
			summary.AutomaticSize = Enum.AutomaticSize.Y
			summary.TextWrapped = true
			local lines = { "Stage   dv vac   dv ASL   TWR" }
			for _, row in stats.stages do
				table.insert(
					lines,
					string.format(
						"%5d  %7d  %7d  %5.2f",
						row.stage,
						math.floor(row.dvVac + 0.5),
						math.floor(row.dvAsl + 0.5),
						row.twrAsl
					)
				)
			end
			if #stats.stages == 0 then
				table.insert(lines, "  (no stages yet)")
			end
			stageText.Text = table.concat(lines, "\n")
			warningText.Text = if #stats.warnings > 0 then "! " .. table.concat(stats.warnings, "\n! ") else ""
			warningText.Visible = #stats.warnings > 0
		end,
		setSlots = function(names: { [number]: string })
			slotNames = names
			refreshSlots()
		end,
		setBoarding = function(mode: string)
			boardingMode = mode
			boardingButton.Text = `Boarding: {mode}`
		end,
		toast = function(text: string, kind: string?)
			toastSerial += 1
			local serial = toastSerial
			toastLabel.Text = text
			toastLabel.TextColor3 = if kind == "Error" then WARN else TEXT
			toastLabel.Visible = true
			toastLabel.TextTransparency = 0
			task.delay(TOAST_TIME_S, function()
				if serial == toastSerial then
					local tween = TweenService:Create(toastLabel, TweenInfo.new(0.4), { TextTransparency = 1 })
					tween:Play()
					tween.Completed:Wait()
					if serial == toastSerial then
						toastLabel.Visible = false
					end
				end
			end)
		end,
	}
	return ui
end

return table.freeze(BuildUI)
