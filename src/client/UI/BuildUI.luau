--!strict
--[[
	BuildUI
	The hangar builder's screen UI (Plane Crazy-inspired):
	  * bottom-centre HOTBAR: Build / Paint / Delete tools, symmetry cycle, Undo, Clear (two-click) and rotation readout
	  * left PART PANEL: category tabs + tiles with rotating 3D previews; swaps to a 4x4 PAINT PALETTE for the Paint tool
	  * right STATS CARD: mass, part count, per-stage delta-v / TWR table with totals, warnings
	  * bottom-right SAVES panel (name, 10 slots, Save / Load), Boarding toggle and the big ROLL OUT button
	  * top-centre toast (stays visible while the builder is hidden)

	Pure view: BuildController owns all state and passes callbacks in. The UI never fires remotes or reads game state;
	it only calls callbacks and renders what the set* functions give it (tab and save-slot selection are local UI state).

	Layout is authored for a 1366 x 710 design canvas (1366x768 minus the top-bar inset) and scaled uniformly with a
	UIScale so it fits any screen (1920x1080 -> about 1.4x).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Paint = require(ReplicatedStorage.Shared.Config.Paint)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)

--============================================================================
-- Tunables
--============================================================================
-- Fonts
local FONT = Enum.Font.BuilderSans
local FONT_MEDIUM = Enum.Font.BuilderSansMedium
local FONT_BOLD = Enum.Font.BuilderSansBold
local FONT_HEAVY = Enum.Font.BuilderSansExtraBold
-- Colours
local COLOR_PANEL = Color3.fromRGB(22, 26, 38)
local COLOR_PANEL_STROKE = Color3.fromRGB(78, 88, 122)
local COLOR_SURFACE = Color3.fromRGB(38, 44, 62)
local COLOR_SURFACE_HI = Color3.fromRGB(56, 65, 92)
local COLOR_DEEP = Color3.fromRGB(13, 15, 23)
local COLOR_TEXT = Color3.fromRGB(242, 244, 252)
local COLOR_TEXT_DIM = Color3.fromRGB(150, 158, 184)
local COLOR_TEXT_DARK = Color3.fromRGB(28, 22, 18)
local COLOR_ACCENT = Color3.fromRGB(255, 140, 40)
local COLOR_ACCENT_LIGHT = Color3.fromRGB(255, 192, 90)
local COLOR_GOOD = Color3.fromRGB(88, 214, 122)
local COLOR_BAD = Color3.fromRGB(240, 78, 78)
local COLOR_BAD_TEXT = Color3.fromRGB(255, 196, 190)
local COLOR_INFO = Color3.fromRGB(92, 176, 255)
local COLOR_PAINT = Color3.fromRGB(184, 112, 255)
local COLOR_SYMMETRY = Color3.fromRGB(56, 206, 222)
local GRADIENT_BOTTOM = Color3.fromRGB(205, 210, 222) -- UIGradient multiplier at the bottom of panels/buttons
local PANEL_TRANSPARENCY = 0.06
local CORNER = 12
local CORNER_SMALL = 8
local STROKE_THICKNESS = 1.5
-- Layout (design pixels on the 1366 x 710 canvas)
local DESIGN_WIDTH = 1366
local DESIGN_HEIGHT = 710
local MIN_SCALE = 0.6
local MAX_SCALE = 1.6
local MARGIN = 12
local LEFT_WIDTH = 310
local LEFT_HEIGHT = 396
local TAB_WIDTH = 84
local TAB_HEIGHT = 34
local TILE_WIDTH = 92
local TILE_HEIGHT = 108
local SWATCH_SIZE = 60
local RIGHT_WIDTH = 280
local HOTBAR_HEIGHT = 64 -- button height inside the hotbar
local TOOL_WIDTH = 72
local SYMMETRY_WIDTH = 120
local SMALL_BUTTON_WIDTH = 64
local ROTATION_WIDTH = 160
local STAGE_ROW_HEIGHT = 20
local MAX_VISIBLE_STAGES = 4 -- more stages scroll
local MAX_WARNINGS_SHOWN = 3
-- Behaviour
local TOAST_TIME_S = 3
local TOAST_FADE_S = 0.4
local CLEAR_CONFIRM_S = 2
local HOVER_SCALE = 1.04
local PRESS_SCALE = 0.94
local PREVIEW_SPIN_SPEED = 0.6 -- rad/s
local PREVIEW_FPS = 30
local PREVIEW_ELEVATION_DEG = 24
local PREVIEW_FOV = 30
local PREVIEW_MAX_SPINNING = 8
local DV = "Δv" -- delta-v label (swap for "dV" if a font lacks the glyph)
-- Content
local CATEGORY_NAMES: { [string]: string } = {
	Command = "Command",
	FuelTank = "Fuel",
	Engine = "Engines",
	Coupling = "Coupling",
	Aero = "Aero",
	Utility = "Utility",
	Structural = "Structural",
}
local CATEGORY_COLORS: { [string]: Color3 } = {
	Command = Color3.fromRGB(92, 176, 255),
	FuelTank = Color3.fromRGB(255, 176, 60),
	Engine = Color3.fromRGB(255, 104, 72),
	Coupling = Color3.fromRGB(255, 214, 72),
	Aero = Color3.fromRGB(88, 214, 122),
	Utility = Color3.fromRGB(184, 112, 255),
	Structural = Color3.fromRGB(170, 178, 196),
}
local TOOL_ORDER = { "Build", "Paint", "Delete" }
local TOOL_KEYS: { [string]: string } = { Build = "B", Paint = "P", Delete = "X" }
local TOOL_COLORS: { [string]: Color3 } = { Build = COLOR_GOOD, Paint = COLOR_PAINT, Delete = COLOR_BAD }
local SYMMETRY_ORDER = { "Off", "MirrorX", "MirrorZ", "MirrorXZ", "Radial2", "Radial4" }
local SYMMETRY_LABELS: { [string]: string } = {
	Off = "Off",
	MirrorX = "Mirror X",
	MirrorZ = "Mirror Z",
	MirrorXZ = "Mirror XZ",
	Radial2 = "Radial 2",
	Radial4 = "Radial 4",
}
local BOARDING_ORDER = { "Public", "Friends", "Private" }
local BOARDING_COLORS: { [string]: Color3 } = { Public = COLOR_GOOD, Friends = COLOR_INFO, Private = COLOR_BAD }
local BOARDING_HINTS: { [string]: string } = {
	Public = "Anyone can board",
	Friends = "Friends only",
	Private = "Only you",
}
--============================================================================

export type Tool = "Build" | "Paint" | "Delete"
export type Symmetry = "Off" | "MirrorX" | "MirrorZ" | "MirrorXZ" | "Radial2" | "Radial4"

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
	onTool: (tool: Tool) -> (),
	onSelectColor: (index: number) -> (), -- Paint.List index
	onSymmetry: (mode: Symmetry) -> (),
	onUndo: () -> (),
	onClear: () -> (),
	onSave: (slot: number, name: string) -> (),
	onLoad: (slot: number) -> (),
	onRollOut: () -> (),
	onBoarding: (mode: string) -> (), -- "Public" | "Friends" | "Private"
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
	toast: (text: string, kind: string?) -> (), -- kind "Error" | "Info" | nil
}

type Tile = {
	button: TextButton,
	stroke: UIStroke,
	name: TextLabel,
	viewport: ViewportFrame,
	partId: string,
	displayName: string,
	category: string,
	camera: Camera?,
	center: Vector3,
	distance: number,
}

type StageRowUI = {
	frame: Frame,
	stage: TextLabel,
	vac: TextLabel,
	asl: TextLabel,
	pill: Frame,
	twr: TextLabel,
}

local BuildUI = {}

local FEEDBACK_TWEEN = TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local STATE_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--============================================================================
-- Building blocks
--============================================================================
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
	new("UICorner", { CornerRadius = UDim.new(0, radius or CORNER_SMALL) }, parent)
end

local function stroke(parent: Instance, color: Color3, thickness: number?, transparency: number?): UIStroke
	return new("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = color,
		Thickness = thickness or STROKE_THICKNESS,
		Transparency = transparency or 0,
	}, parent)
end

local function gradient(parent: Instance)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.new(1, 1, 1), GRADIENT_BOTTOM),
		Rotation = 90,
	}, parent)
end

local function padding(parent: Instance, px: number)
	new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	}, parent)
end

local function listLayout(parent: Instance, horizontal: boolean, spacing: number): UIListLayout
	return new("UIListLayout", {
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		Padding = UDim.new(0, spacing),
		SortOrder = Enum.SortOrder.LayoutOrder,
		VerticalAlignment = if horizontal then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top,
	}, parent)
end

-- A rounded, outlined, input-sinking card.
local function panel(parent: Instance, props: { [string]: any }): Frame
	local frame: Frame = new("Frame", {
		BackgroundColor3 = COLOR_PANEL,
		BackgroundTransparency = PANEL_TRANSPARENCY,
		BorderSizePixel = 0,
		Active = true, -- clicks on panels must not place blocks behind them
	}, nil)
	for key, value in props do
		(frame :: any)[key] = value
	end
	corner(frame, CORNER)
	stroke(frame, COLOR_PANEL_STROKE, STROKE_THICKNESS, 0.35)
	gradient(frame)
	frame.Parent = parent
	return frame
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l: TextLabel = new("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Font = FONT_MEDIUM,
		TextSize = 14,
		TextColor3 = COLOR_TEXT,
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 18),
	}, nil)
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

-- Plain rounded button (text empty by default); hover/press scale feedback.
local function button(parent: Instance, props: { [string]: any }): TextButton
	local b: TextButton = new("TextButton", {
		AutoButtonColor = false,
		BackgroundColor3 = COLOR_SURFACE,
		BorderSizePixel = 0,
		Font = FONT_BOLD,
		TextSize = 14,
		TextColor3 = COLOR_TEXT,
		Text = "",
	}, nil)
	for key, value in props do
		(b :: any)[key] = value
	end
	corner(b, CORNER_SMALL)
	local scale: UIScale = new("UIScale", {}, b)
	local hovered = false
	local function scaleTo(value: number)
		TweenService:Create(scale, FEEDBACK_TWEEN, { Scale = value }):Play()
	end
	b.MouseEnter:Connect(function()
		hovered = true
		scaleTo(HOVER_SCALE)
	end)
	b.MouseLeave:Connect(function()
		hovered = false
		scaleTo(1)
	end)
	b.MouseButton1Down:Connect(function()
		scaleTo(PRESS_SCALE)
	end)
	b.MouseButton1Up:Connect(function()
		scaleTo(if hovered then HOVER_SCALE else 1)
	end)
	b.Parent = parent
	return b
end

-- Small keycap badge in the top-right corner of a button.
local function keyHint(parent: Instance, key: string): TextLabel
	local badge = label(parent, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -4, 0, 4),
		Size = UDim2.fromOffset(0, 14),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = COLOR_DEEP,
		BackgroundTransparency = 0.25,
		Font = FONT_BOLD,
		TextSize = 10,
		TextColor3 = COLOR_TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = key,
		ZIndex = 3,
	})
	corner(badge, 4)
	new("UIPadding", { PaddingLeft = UDim.new(0, 4), PaddingRight = UDim.new(0, 4) }, badge)
	return badge
end

local function formatInt(n: number): string
	if n ~= n then
		return "-"
	end
	if n == math.huge or n == -math.huge then
		return "inf"
	end
	local digits = tostring(math.floor(math.abs(n) + 0.5))
	local grouped = (string.gsub(string.reverse(digits), "(%d%d%d)", "%1,"))
	grouped = string.reverse(grouped)
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return (if n < 0 then "-" else "") .. grouped
end

local function formatTwr(twr: number): string
	if twr ~= twr then
		return "-"
	end
	if twr == math.huge then
		return "inf"
	end
	return string.format("%.2f", twr)
end

local function nextIn(order: { string }, current: string, step: number): string
	local index = table.find(order, current) or 1
	return order[(index - 1 + step) % #order + 1]
end

--============================================================================
-- Create
--============================================================================
function BuildUI.create(callbacks: Callbacks): BuildUI
	local player = Players.LocalPlayer
	local screen: ScreenGui = new("ScreenGui", {
		Name = "BuildUI",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Enabled = true,
	}, player:WaitForChild("PlayerGui"))

	-- Design canvas: sized in design pixels and scaled uniformly to the screen.
	local canvas: Frame = new("Frame", {
		Name = "Canvas",
		BackgroundTransparency = 1,
		Size = UDim2.fromOffset(DESIGN_WIDTH, DESIGN_HEIGHT),
	}, screen)
	local canvasScale: UIScale = new("UIScale", {}, canvas)
	local function rescale()
		local size = screen.AbsoluteSize
		if size.X < 1 or size.Y < 1 then
			return
		end
		local s = math.clamp(math.min(size.X / DESIGN_WIDTH, size.Y / DESIGN_HEIGHT), MIN_SCALE, MAX_SCALE)
		canvasScale.Scale = s
		canvas.Size = UDim2.fromOffset(size.X / s, size.Y / s)
	end
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale)
	rescale()

	local root: Frame = new("Frame", {
		Name = "Builder",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
	}, canvas)

	-- Rendered state (mirrors what the controller last told us)
	local currentTool: string = "Build"
	local currentSymmetry: string = "Off"
	local currentBoarding: string = GameConfig.DEFAULT_BOARDING
	local selectedPartId: string? = nil
	local selectedColor = 1
	-- Local UI state
	local currentCategory: string = Parts.Categories[1]
	local selectedSlot = 1
	local slotNames: { [number]: string } = {}
	local rootVisible = false

	--========================================================================
	-- Left: part panel / paint palette
	--========================================================================
	local left = panel(root, {
		Name = "PartPanel",
		Position = UDim2.fromOffset(MARGIN, MARGIN),
		Size = UDim2.fromOffset(LEFT_WIDTH, LEFT_HEIGHT),
	})
	padding(left, 12)
	local leftTitle = label(left, {
		Size = UDim2.new(0, 90, 0, 24),
		Font = FONT_HEAVY,
		TextSize = 20,
		TextColor3 = COLOR_ACCENT,
		Text = "PARTS",
	})
	local leftSubtitle = label(left, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, 3),
		Size = UDim2.new(1, -96, 0, 20),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextColor3 = COLOR_TEXT_DIM,
		TextSize = 14,
		Text = "Pick a part",
	})
	local content: Frame = new("Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, 34),
		Size = UDim2.new(1, 0, 1, -34),
	}, left)

	-- Parts view: vertical tabs + tile grid
	local partsView: Frame = new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, content)
	local tabColumn: Frame = new("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(0, TAB_WIDTH, 1, 0),
	}, partsView)
	listLayout(tabColumn, false, 4)
	local gridScroll: ScrollingFrame = new("ScrollingFrame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Position = UDim2.fromOffset(TAB_WIDTH + 10, 0),
		Size = UDim2.new(1, -(TAB_WIDTH + 10), 1, 0),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 4,
		ScrollBarImageColor3 = COLOR_PANEL_STROKE,
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, partsView)

	local tabs: { [string]: { button: TextButton, bar: Frame, stroke: UIStroke } } = {}
	local pages: { [string]: Frame } = {}
	local tilesByCategory: { [string]: { Tile } } = {}
	local tileById: { [string]: Tile } = {}
	local previewsBuilt: { [string]: boolean } = {}
	local byCategory = Parts.byCategory()

	local function buildPreview(tile: Tile)
		local block: CraftDesign.Block = { id = 0, type = tile.partId, gx = 0, gy = 0, gz = 0, rot = 0 }
		local ok, result = pcall(function(): Model
			return CraftBuilder.buildBlock(block, "Cosmetic", CFrame.identity)
		end)
		if not ok or typeof(result) ~= "Instance" or not result:IsA("Model") then
			label(tile.viewport, {
				Size = UDim2.fromScale(1, 1),
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = COLOR_TEXT_DIM,
				TextSize = 22,
				Font = FONT_HEAVY,
				Text = "?",
			})
			return
		end
		local model = result :: Model
		local cf, size = model:GetBoundingBox()
		local radius = math.max(size.Magnitude / 2, 0.5)
		local camera: Camera = new("Camera", { FieldOfView = PREVIEW_FOV }, tile.viewport)
		tile.camera = camera
		tile.center = cf.Position
		tile.distance = radius / math.sin(math.rad(PREVIEW_FOV / 2)) * 1.02
		tile.viewport.CurrentCamera = camera
		model.Parent = tile.viewport
	end

	local function poseCamera(tile: Tile, angle: number)
		local camera = tile.camera
		if camera then
			camera.CFrame = CFrame.new(tile.center)
				* CFrame.Angles(0, angle, 0)
				* CFrame.Angles(-math.rad(PREVIEW_ELEVATION_DEG), 0, 0)
				* CFrame.new(0, 0, tile.distance)
		end
	end

	local spinAngle = math.rad(35)
	local function ensurePreviews(category: string)
		if previewsBuilt[category] then
			return
		end
		previewsBuilt[category] = true
		for _, tile in tilesByCategory[category] :: { Tile } do
			buildPreview(tile)
			poseCamera(tile, spinAngle)
		end
	end

	local function selectCategory(category: string)
		currentCategory = category
		for name, tab in tabs do
			local selected = name == category
			tab.button.BackgroundColor3 = if selected then COLOR_SURFACE_HI else COLOR_SURFACE
			tab.button.BackgroundTransparency = if selected then 0 else 0.35
			tab.button.TextColor3 = if selected then COLOR_TEXT else COLOR_TEXT_DIM
			tab.bar.Size = if selected then UDim2.new(0, 5, 1, -8) else UDim2.new(0, 3, 0.5, 0)
			tab.stroke.Transparency = if selected then 0 else 1
		end
		for name, page in pages do
			page.Visible = name == category
		end
		gridScroll.CanvasPosition = Vector2.zero
		ensurePreviews(category)
	end

	for index, category: Parts.Category in Parts.Categories do
		local color = CATEGORY_COLORS[category] or COLOR_ACCENT
		local tabButton = button(tabColumn, {
			LayoutOrder = index,
			Size = UDim2.new(1, 0, 0, TAB_HEIGHT),
			Font = FONT_BOLD,
			TextSize = 13,
			Text = CATEGORY_NAMES[category] or category,
			TextXAlignment = Enum.TextXAlignment.Left,
		})
		new("UIPadding", { PaddingLeft = UDim.new(0, 13) }, tabButton)
		local bar: Frame = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.new(0, -9, 0.5, 0),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
		}, tabButton)
		corner(bar, 3)
		local tabStroke = stroke(tabButton, color, 1.5, 1)
		tabs[category] = { button = tabButton, bar = bar, stroke = tabStroke }
		tabButton.Activated:Connect(function()
			selectCategory(category)
		end)

		local page: Frame = new("Frame", {
			Name = category,
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false,
		}, gridScroll)
		new("UIGridLayout", {
			CellSize = UDim2.fromOffset(TILE_WIDTH, TILE_HEIGHT),
			CellPadding = UDim2.fromOffset(8, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, page)
		pages[category] = page

		local list: { Tile } = {}
		for order, def in byCategory[category] do
			local tileButton = button(page, { LayoutOrder = order, BackgroundColor3 = COLOR_SURFACE })
			gradient(tileButton)
			local tileStroke = stroke(tileButton, COLOR_PANEL_STROKE, 1.5, 0.6)
			local viewport: ViewportFrame = new("ViewportFrame", {
				Position = UDim2.fromOffset(4, 4),
				Size = UDim2.new(1, -8, 0, TILE_HEIGHT - 36),
				BackgroundColor3 = COLOR_DEEP,
				BackgroundTransparency = 0.35,
				BorderSizePixel = 0,
				Ambient = Color3.fromRGB(165, 170, 185),
				LightColor = Color3.new(1, 1, 1),
				LightDirection = Vector3.new(-1, -1.6, -0.8),
			}, tileButton)
			corner(viewport, 6)
			local accentLine: Frame = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0),
				Position = UDim2.new(0.5, 0, 0, TILE_HEIGHT - 31),
				Size = UDim2.new(0, 22, 0, 2),
				BackgroundColor3 = color,
				BorderSizePixel = 0,
			}, tileButton)
			corner(accentLine, 1)
			local nameLabel = label(tileButton, {
				Position = UDim2.new(0, 4, 1, -28),
				Size = UDim2.new(1, -8, 0, 26),
				Font = FONT_BOLD,
				TextSize = 12,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextYAlignment = Enum.TextYAlignment.Center,
				Text = def.DisplayName,
			})
			local tile: Tile = {
				button = tileButton,
				stroke = tileStroke,
				name = nameLabel,
				viewport = viewport,
				partId = def.Id,
				displayName = def.DisplayName,
				category = category,
				camera = nil,
				center = Vector3.zero,
				distance = 10,
			}
			table.insert(list, tile)
			tileById[def.Id] = tile
			tileButton.Activated:Connect(function()
				callbacks.onSelectPart(def.Id)
			end)
		end
		tilesByCategory[category] = list
	end

	-- Paint view: current colour + 4x4 swatches
	local paintView: Frame =
		new("Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, content)
	local paintPreview: Frame = new("Frame", {
		Size = UDim2.fromOffset(36, 36),
		BackgroundColor3 = Paint.List[1].Color,
		BorderSizePixel = 0,
	}, paintView)
	corner(paintPreview, CORNER_SMALL)
	stroke(paintPreview, Color3.new(1, 1, 1), 2, 0)
	local paintName = label(paintView, {
		Position = UDim2.fromOffset(46, 0),
		Size = UDim2.new(1, -46, 0, 20),
		Font = FONT_HEAVY,
		TextSize = 18,
		Text = Paint.List[1].Name,
	})
	label(paintView, {
		Position = UDim2.fromOffset(46, 20),
		Size = UDim2.new(1, -46, 0, 16),
		TextSize = 12,
		Font = FONT,
		TextColor3 = COLOR_TEXT_DIM,
		Text = "Click blocks to paint them",
	})
	local swatchGrid: Frame = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 46),
		Size = UDim2.fromOffset(SWATCH_SIZE * 4 + 8 * 3, SWATCH_SIZE * 4 + 8 * 3),
		BackgroundTransparency = 1,
	}, paintView)
	new("UIGridLayout", {
		CellSize = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE),
		CellPadding = UDim2.fromOffset(8, 8),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, swatchGrid)
	local swatches: { { button: TextButton, stroke: UIStroke, ring: Frame } } = {}
	for index, entry in Paint.List do
		local swatch = button(swatchGrid, { LayoutOrder = index, BackgroundColor3 = entry.Color })
		gradient(swatch)
		local swatchStroke = stroke(swatch, COLOR_DEEP, 1.5, 0.4)
		local ring: Frame = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(14, 14),
			BackgroundColor3 = Color3.new(1, 1, 1),
			BorderSizePixel = 0,
			Visible = false,
		}, swatch)
		corner(ring, 7)
		stroke(ring, COLOR_DEEP, 2, 0.2)
		swatches[index] = { button = swatch, stroke = swatchStroke, ring = ring }
		swatch.Activated:Connect(function()
			callbacks.onSelectColor(index)
		end)
	end

	--========================================================================
	-- Bottom centre: hotbar
	--========================================================================
	local hotbar = panel(root, {
		Name = "Hotbar",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -MARGIN),
		Size = UDim2.fromOffset(0, HOTBAR_HEIGHT + 20),
		AutomaticSize = Enum.AutomaticSize.X,
	})
	padding(hotbar, 10)
	listLayout(hotbar, true, 6)

	local function separator(order: number)
		local sep: Frame = new("Frame", {
			LayoutOrder = order,
			Size = UDim2.fromOffset(2, HOTBAR_HEIGHT - 16),
			BackgroundColor3 = COLOR_PANEL_STROKE,
			BackgroundTransparency = 0.4,
			BorderSizePixel = 0,
		}, hotbar)
		corner(sep, 1)
	end

	-- Caption along the bottom of a hotbar button.
	local function caption(parent: Instance, text: string): TextLabel
		return label(parent, {
			Position = UDim2.new(0, 0, 1, -20),
			Size = UDim2.new(1, 0, 0, 16),
			Font = FONT_BOLD,
			TextSize = 12,
			TextXAlignment = Enum.TextXAlignment.Center,
			Text = text,
		})
	end

	local toolButtons: { [string]: { button: TextButton, stroke: UIStroke, caption: TextLabel } } = {}
	local paintIcon: Frame? = nil
	for index, tool in TOOL_ORDER do
		local toolColor = TOOL_COLORS[tool]
		local b = button(hotbar, { LayoutOrder = index, Size = UDim2.fromOffset(TOOL_WIDTH, HOTBAR_HEIGHT) })
		gradient(b)
		local bStroke = stroke(b, COLOR_PANEL_STROKE, 1.5, 0.3)
		keyHint(b, TOOL_KEYS[tool])
		local chip: Frame = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.new(0.5, 0, 0, 7),
			Size = UDim2.fromOffset(32, 32),
			BackgroundColor3 = COLOR_DEEP,
			BackgroundTransparency = 0.1,
			BorderSizePixel = 0,
		}, b)
		corner(chip, 16)
		if tool == "Build" then
			local cube: Frame = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(18, 18),
				BackgroundColor3 = toolColor,
				BorderSizePixel = 0,
			}, chip)
			corner(cube, 4)
			gradient(cube)
			for _, size in { UDim2.fromOffset(10, 3), UDim2.fromOffset(3, 10) } do
				new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = size,
					BackgroundColor3 = COLOR_DEEP,
					BorderSizePixel = 0,
				}, cube)
			end
		elseif tool == "Paint" then
			local dot: Frame = new("Frame", {
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Size = UDim2.fromOffset(18, 18),
				BackgroundColor3 = Paint.List[1].Color,
				BorderSizePixel = 0,
			}, chip)
			corner(dot, 9)
			stroke(dot, toolColor, 2.5, 0)
			paintIcon = dot
		else
			for _, rotation in { 45, -45 } do
				local barFrame: Frame = new("Frame", {
					AnchorPoint = Vector2.new(0.5, 0.5),
					Position = UDim2.fromScale(0.5, 0.5),
					Size = UDim2.fromOffset(20, 4),
					Rotation = rotation,
					BackgroundColor3 = toolColor,
					BorderSizePixel = 0,
				}, chip)
				corner(barFrame, 2)
			end
		end
		local toolCaption = caption(b, tool)
		toolButtons[tool] = { button = b, stroke = bStroke, caption = toolCaption }
		b.Activated:Connect(function()
			callbacks.onTool(tool :: Tool)
		end)
	end

	separator(10)

	-- Symmetry: left-click cycles forward, right-click backward
	local symmetryButton = button(hotbar, { LayoutOrder = 11, Size = UDim2.fromOffset(SYMMETRY_WIDTH, HOTBAR_HEIGHT) })
	gradient(symmetryButton)
	local symmetryStroke = stroke(symmetryButton, COLOR_PANEL_STROKE, 1.5, 0.3)
	keyHint(symmetryButton, "M / 1 2 4")
	local symmetryValue = label(symmetryButton, {
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 22),
		Font = FONT_HEAVY,
		TextSize = 18,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = COLOR_TEXT_DIM,
		Text = "Off",
	})
	local symmetryCaption = caption(symmetryButton, "Symmetry")
	symmetryCaption.TextColor3 = COLOR_TEXT_DIM
	symmetryButton.Activated:Connect(function()
		callbacks.onSymmetry(nextIn(SYMMETRY_ORDER, currentSymmetry, 1) :: Symmetry)
	end)
	symmetryButton.MouseButton2Click:Connect(function()
		callbacks.onSymmetry(nextIn(SYMMETRY_ORDER, currentSymmetry, -1) :: Symmetry)
	end)

	-- Undo
	local undoButton = button(hotbar, { LayoutOrder = 12, Size = UDim2.fromOffset(SMALL_BUTTON_WIDTH, HOTBAR_HEIGHT) })
	gradient(undoButton)
	stroke(undoButton, COLOR_PANEL_STROKE, 1.5, 0.3)
	keyHint(undoButton, "Ctrl Z")
	label(undoButton, {
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 24),
		Font = FONT_HEAVY,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "Undo",
	})
	caption(undoButton, "step back").TextColor3 = COLOR_TEXT_DIM
	undoButton.Activated:Connect(callbacks.onUndo)

	-- Clear (two-click confirm)
	local clearButton = button(hotbar, { LayoutOrder = 13, Size = UDim2.fromOffset(SMALL_BUTTON_WIDTH, HOTBAR_HEIGHT) })
	gradient(clearButton)
	local clearStroke = stroke(clearButton, COLOR_BAD, 1.5, 0.5)
	local clearValue = label(clearButton, {
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 24),
		Font = FONT_HEAVY,
		TextSize = 17,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = COLOR_BAD,
		Text = "Clear",
	})
	local clearCaption = caption(clearButton, "all blocks")
	clearCaption.TextColor3 = COLOR_TEXT_DIM
	local clearArmSerial = 0
	local clearArmed = false
	local function setClearArmed(armed: boolean)
		clearArmed = armed
		clearButton.BackgroundColor3 = if armed then COLOR_BAD else COLOR_SURFACE
		clearStroke.Transparency = if armed then 0 else 0.5
		clearValue.TextColor3 = if armed then COLOR_TEXT else COLOR_BAD
		clearValue.Text = if armed then "Sure?" else "Clear"
		clearCaption.Text = if armed then "click again" else "all blocks"
		clearCaption.TextColor3 = if armed then COLOR_TEXT else COLOR_TEXT_DIM
	end
	clearButton.Activated:Connect(function()
		clearArmSerial += 1
		if clearArmed then
			setClearArmed(false)
			callbacks.onClear()
			return
		end
		setClearArmed(true)
		local serial = clearArmSerial
		task.delay(CLEAR_CONFIRM_S, function()
			if serial == clearArmSerial then
				setClearArmed(false)
			end
		end)
	end)

	separator(20)

	-- Rotation readout (not a button: rotation keys live on the keyboard)
	local rotationBox: Frame = new("Frame", {
		LayoutOrder = 21,
		Size = UDim2.fromOffset(ROTATION_WIDTH, HOTBAR_HEIGHT),
		BackgroundColor3 = COLOR_DEEP,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
		Active = true,
	}, hotbar)
	corner(rotationBox, CORNER_SMALL)
	stroke(rotationBox, COLOR_PANEL_STROKE, 1.5, 0.5)
	keyHint(rotationBox, "R / T")
	local rotationValue = label(rotationBox, {
		Position = UDim2.fromOffset(8, 18),
		Size = UDim2.new(1, -16, 0, 22),
		Font = FONT_BOLD,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "up +Y  yaw 0",
	})
	local rotationCaption = caption(rotationBox, "Rotation")
	rotationCaption.TextColor3 = COLOR_TEXT_DIM

	--========================================================================
	-- Right: stats card
	--========================================================================
	local statsCard = panel(root, {
		Name = "StatsCard",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -MARGIN, 0, MARGIN),
		Size = UDim2.fromOffset(RIGHT_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	padding(statsCard, 12)
	listLayout(statsCard, false, 8)
	label(statsCard, {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 20),
		Font = FONT_HEAVY,
		TextSize = 18,
		TextColor3 = COLOR_ACCENT,
		Text = "CRAFT STATS",
	})

	local metricRow: Frame =
		new("Frame", { LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 46) }, statsCard)
	local function metric(xScale: number, xOffset: number, title: string): TextLabel
		local tile: Frame = new("Frame", {
			Position = UDim2.new(xScale, xOffset, 0, 0),
			Size = UDim2.new(0.5, -4, 1, 0),
			BackgroundColor3 = COLOR_DEEP,
			BackgroundTransparency = 0.25,
			BorderSizePixel = 0,
		}, metricRow)
		corner(tile, CORNER_SMALL)
		label(tile, {
			Position = UDim2.fromOffset(10, 5),
			Size = UDim2.new(1, -20, 0, 14),
			Font = FONT_BOLD,
			TextSize = 11,
			TextColor3 = COLOR_TEXT_DIM,
			Text = title,
		})
		return label(tile, {
			Position = UDim2.fromOffset(10, 19),
			Size = UDim2.new(1, -20, 0, 22),
			Font = FONT_HEAVY,
			TextSize = 20,
			Text = "-",
		})
	end
	local massValue = metric(0, 0, "MASS")
	local partsValue = metric(0.5, 4, "PARTS")

	-- Stage table
	local tableFrame: Frame = new("Frame", {
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	}, statsCard)
	listLayout(tableFrame, false, 2)
	local COLUMNS = { { 0, 0.16 }, { 0.16, 0.3 }, { 0.46, 0.3 }, { 0.76, 0.24 } }
	local function cell(parent: Instance, column: number, props: { [string]: any }): TextLabel
		local l = label(parent, {
			Position = UDim2.fromScale(COLUMNS[column][1], 0),
			Size = UDim2.fromScale(COLUMNS[column][2], 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextSize = 13,
		})
		for key, value in props do
			(l :: any)[key] = value
		end
		return l
	end
	local headerRow: Frame =
		new("Frame", { LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 16) }, tableFrame)
	for column, title in { "STAGE", `{DV} VAC`, `{DV} ASL`, "TWR" } do
		cell(headerRow, column, { Font = FONT_BOLD, TextSize = 11, TextColor3 = COLOR_TEXT_DIM, Text = title })
	end
	local emptyRow = label(tableFrame, {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, STAGE_ROW_HEIGHT + 4),
		TextXAlignment = Enum.TextXAlignment.Center,
		TextSize = 13,
		TextColor3 = COLOR_TEXT_DIM,
		Text = "No stages yet: add an engine",
	})
	local stageScroll: ScrollingFrame = new("ScrollingFrame", {
		LayoutOrder = 3,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 0),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = COLOR_PANEL_STROKE,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		Visible = false,
	}, tableFrame)
	listLayout(stageScroll, false, 2)
	local totalRow: Frame = new("Frame", {
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 24),
		BackgroundColor3 = COLOR_ACCENT,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
	}, tableFrame)
	corner(totalRow, 6)
	stroke(totalRow, COLOR_ACCENT, 1, 0.5)
	cell(totalRow, 1, { Font = FONT_HEAVY, TextSize = 12, TextColor3 = COLOR_ACCENT_LIGHT, Text = "TOTAL" })
	local totalVac = cell(totalRow, 2, { Font = FONT_HEAVY, TextSize = 14, Text = "0" })
	local totalAsl = cell(totalRow, 3, { Font = FONT_HEAVY, TextSize = 14, Text = "0" })
	cell(totalRow, 4, { Font = FONT_BOLD, TextSize = 11, TextColor3 = COLOR_TEXT_DIM, Text = "m/s" })

	local stageRows: { StageRowUI } = {}
	local function stageRow(index: number): StageRowUI
		local existing = stageRows[index]
		if existing then
			return existing
		end
		local frame: Frame = new("Frame", {
			LayoutOrder = index,
			Size = UDim2.new(1, -4, 0, STAGE_ROW_HEIGHT),
			BackgroundColor3 = COLOR_SURFACE,
			BackgroundTransparency = if index % 2 == 0 then 0.55 else 0.25,
			BorderSizePixel = 0,
		}, stageScroll)
		corner(frame, 4)
		local twrHolder: Frame = new("Frame", {
			Position = UDim2.fromScale(COLUMNS[4][1], 0),
			Size = UDim2.fromScale(COLUMNS[4][2], 1),
			BackgroundTransparency = 1,
		}, frame)
		local pill: Frame = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, -10, 1, -4),
			BackgroundColor3 = COLOR_GOOD,
			BackgroundTransparency = 0.75,
			BorderSizePixel = 0,
		}, twrHolder)
		corner(pill, 8)
		local row: StageRowUI = {
			frame = frame,
			stage = cell(frame, 1, { Font = FONT_BOLD, TextColor3 = COLOR_TEXT_DIM }),
			vac = cell(frame, 2, {}),
			asl = cell(frame, 3, {}),
			pill = pill,
			twr = label(pill, {
				Size = UDim2.fromScale(1, 1),
				Font = FONT_BOLD,
				TextSize = 12,
				TextXAlignment = Enum.TextXAlignment.Center,
			}),
		}
		stageRows[index] = row
		return row
	end

	-- Warnings
	local warningBox: Frame = new("Frame", {
		LayoutOrder = 4,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = COLOR_BAD,
		BackgroundTransparency = 0.82,
		BorderSizePixel = 0,
		Visible = false,
	}, statsCard)
	corner(warningBox, CORNER_SMALL)
	stroke(warningBox, COLOR_BAD, 1.5, 0.2)
	padding(warningBox, 8)
	listLayout(warningBox, false, 2)
	label(warningBox, {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 14),
		Font = FONT_HEAVY,
		TextSize = 12,
		TextColor3 = COLOR_BAD,
		Text = "WARNINGS",
	})
	local warningText = label(warningBox, {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		TextSize = 13,
		TextColor3 = COLOR_BAD_TEXT,
	})

	--========================================================================
	-- Bottom right: saves, boarding, roll out
	--========================================================================
	local rightStack: Frame = new("Frame", {
		Name = "LaunchStack",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -MARGIN, 1, -MARGIN),
		Size = UDim2.fromOffset(RIGHT_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
	}, root)
	listLayout(rightStack, false, 8)

	local savePanel = panel(rightStack, {
		Name = "SavePanel",
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	padding(savePanel, 12)
	listLayout(savePanel, false, 8)
	local saveHeader: Frame =
		new("Frame", { LayoutOrder = 1, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 20) }, savePanel)
	label(saveHeader, {
		Size = UDim2.new(0, 70, 1, 0),
		Font = FONT_HEAVY,
		TextSize = 18,
		TextColor3 = COLOR_ACCENT,
		Text = "SAVES",
	})
	local slotInfo = label(saveHeader, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(1, -76, 1, 0),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextTruncate = Enum.TextTruncate.AtEnd,
		TextSize = 13,
		TextColor3 = COLOR_TEXT_DIM,
		Text = "Slot 1: empty",
	})

	local nameRow: Frame =
		new("Frame", { LayoutOrder = 2, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 32) }, savePanel)
	local nameBox: TextBox = new("TextBox", {
		Size = UDim2.new(1, -112, 1, 0),
		BackgroundColor3 = COLOR_DEEP,
		BackgroundTransparency = 0.15,
		BorderSizePixel = 0,
		TextColor3 = COLOR_TEXT,
		PlaceholderText = "Craft name",
		PlaceholderColor3 = COLOR_TEXT_DIM,
		Font = FONT_MEDIUM,
		TextSize = 14,
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		ClearTextOnFocus = false,
	}, nameRow)
	corner(nameBox, CORNER_SMALL)
	local nameStroke = stroke(nameBox, COLOR_PANEL_STROKE, 1.5, 0.3)
	new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingRight = UDim.new(0, 10) }, nameBox)
	nameBox.Focused:Connect(function()
		nameStroke.Color = COLOR_ACCENT
	end)
	nameBox.FocusLost:Connect(function()
		nameStroke.Color = COLOR_PANEL_STROKE
	end)
	nameBox:GetPropertyChangedSignal("Text"):Connect(function()
		if #nameBox.Text > CraftDesign.MAX_NAME_LENGTH then
			nameBox.Text = string.sub(nameBox.Text, 1, CraftDesign.MAX_NAME_LENGTH)
		end
	end)
	local saveButton = button(nameRow, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -56, 0, 0),
		Size = UDim2.new(0, 50, 1, 0),
		BackgroundColor3 = COLOR_GOOD,
		TextColor3 = COLOR_TEXT_DARK,
		Font = FONT_HEAVY,
		Text = "Save",
	})
	gradient(saveButton)
	local loadButton = button(nameRow, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, 50, 1, 0),
		BackgroundColor3 = COLOR_SURFACE_HI,
		Font = FONT_HEAVY,
		Text = "Load",
	})
	gradient(loadButton)
	local loadStroke = stroke(loadButton, COLOR_INFO, 1.5, 0.3)

	local slotGrid: Frame =
		new("Frame", { LayoutOrder = 3, BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 62) }, savePanel)
	new("UIGridLayout", {
		CellSize = UDim2.new(0.2, -5, 0, 28),
		CellPadding = UDim2.fromOffset(6, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, slotGrid)
	local slotButtons: { { button: TextButton, stroke: UIStroke, dot: Frame } } = {}
	local function refreshSlots()
		for slot, entry in slotButtons do
			local filled = slotNames[slot] ~= nil
			local selected = slot == selectedSlot
			entry.button.BackgroundColor3 = if selected
				then COLOR_ACCENT
				elseif filled then COLOR_SURFACE_HI
				else COLOR_DEEP
			entry.button.BackgroundTransparency = if selected or filled then 0 else 0.3
			entry.button.TextColor3 = if selected then COLOR_TEXT_DARK elseif filled then COLOR_TEXT else COLOR_TEXT_DIM
			entry.stroke.Color = if selected then COLOR_ACCENT_LIGHT else COLOR_PANEL_STROKE
			entry.stroke.Transparency = if selected then 0 elseif filled then 0.3 else 0.7
			entry.dot.Visible = filled
			entry.dot.BackgroundColor3 = if selected then COLOR_TEXT_DARK else COLOR_GOOD
		end
		local name = slotNames[selectedSlot]
		slotInfo.Text = `Slot {selectedSlot}: {name or "empty"}`
		slotInfo.TextColor3 = if name then COLOR_TEXT else COLOR_TEXT_DIM
		loadButton.BackgroundTransparency = if name then 0 else 0.5
		loadButton.TextTransparency = if name then 0 else 0.5
		loadStroke.Transparency = if name then 0.3 else 0.8
	end
	for slot = 1, GameConfig.SAVE_SLOTS do
		local b = button(slotGrid, { LayoutOrder = slot, Font = FONT_HEAVY, TextSize = 14, Text = tostring(slot) })
		local slotStroke = stroke(b, COLOR_PANEL_STROKE, 1.5, 0.7)
		local dot: Frame = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -3),
			Size = UDim2.fromOffset(12, 3),
			BackgroundColor3 = COLOR_GOOD,
			BorderSizePixel = 0,
			Visible = false,
		}, b)
		corner(dot, 2)
		slotButtons[slot] = { button = b, stroke = slotStroke, dot = dot }
		b.Activated:Connect(function()
			selectedSlot = slot
			local name = slotNames[slot]
			if name then
				nameBox.Text = name
			end
			refreshSlots()
		end)
	end
	saveButton.Activated:Connect(function()
		local name = string.match(nameBox.Text, "^%s*(.-)%s*$") or ""
		callbacks.onSave(selectedSlot, name)
	end)
	loadButton.Activated:Connect(function()
		callbacks.onLoad(selectedSlot)
	end)

	-- Boarding toggle
	local boardingButton = button(rightStack, {
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 38),
		BackgroundColor3 = COLOR_PANEL,
		BackgroundTransparency = PANEL_TRANSPARENCY,
	})
	gradient(boardingButton)
	stroke(boardingButton, COLOR_PANEL_STROKE, STROKE_THICKNESS, 0.35)
	label(boardingButton, {
		Position = UDim2.fromOffset(12, 4),
		Size = UDim2.new(1, -130, 0, 16),
		Font = FONT_HEAVY,
		TextSize = 13,
		TextColor3 = COLOR_TEXT_DIM,
		Text = "BOARDING",
	})
	local boardingHint = label(boardingButton, {
		Position = UDim2.fromOffset(12, 19),
		Size = UDim2.new(1, -130, 0, 14),
		Font = FONT,
		TextSize = 12,
		TextColor3 = COLOR_TEXT_DIM,
		Text = "",
	})
	local boardingPill: Frame = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(104, 26),
		BackgroundColor3 = COLOR_GOOD,
		BorderSizePixel = 0,
	}, boardingButton)
	corner(boardingPill, 13)
	gradient(boardingPill)
	local boardingValue = label(boardingPill, {
		Size = UDim2.fromScale(1, 1),
		Font = FONT_HEAVY,
		TextSize = 14,
		TextColor3 = COLOR_TEXT_DARK,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
	})
	boardingButton.Activated:Connect(function()
		callbacks.onBoarding(nextIn(BOARDING_ORDER, currentBoarding, 1))
	end)

	-- Roll out
	local rollOutButton = button(rightStack, {
		LayoutOrder = 3,
		Size = UDim2.new(1, 0, 0, 64),
		BackgroundColor3 = COLOR_ACCENT,
	})
	corner(rollOutButton, CORNER)
	new("UIGradient", {
		Color = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(235, 175, 150)),
		Rotation = 90,
	}, rollOutButton)
	stroke(rollOutButton, COLOR_ACCENT_LIGHT, 2, 0)
	label(rollOutButton, {
		Position = UDim2.fromOffset(0, 9),
		Size = UDim2.new(1, 0, 0, 28),
		Font = FONT_HEAVY,
		TextSize = 28,
		TextColor3 = COLOR_TEXT_DARK,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "ROLL OUT",
	})
	label(rollOutButton, {
		Position = UDim2.fromOffset(0, 38),
		Size = UDim2.new(1, 0, 0, 16),
		Font = FONT_BOLD,
		TextSize = 13,
		TextColor3 = COLOR_TEXT_DARK,
		TextTransparency = 0.3,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "to launch pad",
	})
	rollOutButton.Activated:Connect(callbacks.onRollOut)

	--========================================================================
	-- Toast (top centre, outside the builder root so it survives setVisible(false))
	--========================================================================
	local toastFrame: Frame = new("Frame", {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, MARGIN),
		Size = UDim2.fromOffset(0, 38),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = COLOR_PANEL,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 10,
	}, canvas)
	corner(toastFrame, 19)
	local toastStroke = stroke(toastFrame, COLOR_ACCENT, 2, 0)
	local toastScale: UIScale = new("UIScale", {}, toastFrame)
	new("UIPadding", { PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 16) }, toastFrame)
	listLayout(toastFrame, true, 10)
	local toastDot: Frame = new("Frame", {
		LayoutOrder = 1,
		Size = UDim2.fromOffset(10, 10),
		BackgroundColor3 = COLOR_ACCENT,
		BorderSizePixel = 0,
		ZIndex = 11,
	}, toastFrame)
	corner(toastDot, 5)
	local toastLabel = label(toastFrame, {
		LayoutOrder = 2,
		Size = UDim2.fromOffset(0, 38),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = FONT_BOLD,
		TextSize = 16,
		ZIndex = 11,
	})
	local toastSerial = 0
	local toastTweens: { Tween } = {}

	--========================================================================
	-- Preview spin (only while the builder is visible and on the parts view; capped to the visible tiles)
	--========================================================================
	local spinConnection: RBXScriptConnection? = nil
	local spinAccumulator = 0
	local function stopSpin()
		if spinConnection then
			spinConnection:Disconnect()
			spinConnection = nil
		end
	end
	local function startSpin()
		if spinConnection then
			return
		end
		spinConnection = RunService.RenderStepped:Connect(function(dt: number)
			spinAccumulator += dt
			if spinAccumulator < 1 / PREVIEW_FPS then
				return
			end
			spinAngle = (spinAngle + spinAccumulator * PREVIEW_SPIN_SPEED) % (2 * math.pi)
			spinAccumulator = 0
			local list = tilesByCategory[currentCategory]
			if not list then
				return
			end
			for index, tile in list do
				if index > PREVIEW_MAX_SPINNING then
					break
				end
				poseCamera(tile, spinAngle)
			end
		end)
	end
	local function refreshSpin()
		if rootVisible and partsView.Visible then
			startSpin()
		else
			stopSpin()
		end
	end

	--========================================================================
	-- Renderers
	--========================================================================
	local function refreshSubtitle()
		if currentTool == "Delete" then
			leftSubtitle.Text = "Click blocks to remove"
			leftSubtitle.TextColor3 = COLOR_BAD
		else
			local tile = if selectedPartId then tileById[selectedPartId] else nil
			local name = if tile then tile.displayName else "Pick a part"
			leftSubtitle.Text = name
			leftSubtitle.TextColor3 = if tile then COLOR_TEXT else COLOR_TEXT_DIM
		end
	end

	local function renderTool(tool: string)
		currentTool = tool
		for name, entry in toolButtons do
			local selected = name == tool
			local color = TOOL_COLORS[name]
			TweenService:Create(entry.button, STATE_TWEEN, {
				BackgroundColor3 = if selected then color else COLOR_SURFACE,
			}):Play()
			entry.stroke.Color = if selected then Color3.new(1, 1, 1) else COLOR_PANEL_STROKE
			entry.stroke.Transparency = if selected then 0 else 0.3
			entry.caption.TextColor3 = if selected then COLOR_TEXT_DARK else COLOR_TEXT
		end
		local painting = tool == "Paint"
		partsView.Visible = not painting
		paintView.Visible = painting
		leftTitle.Text = if painting then "PAINT" else "PARTS"
		leftTitle.TextColor3 = if painting then COLOR_PAINT else COLOR_ACCENT
		if painting then
			local entry = Paint.List[selectedColor]
			leftSubtitle.Text = if entry then entry.Name else ""
			leftSubtitle.TextColor3 = COLOR_TEXT
		else
			refreshSubtitle()
		end
		refreshSpin()
	end

	local function renderSelectedPart(partId: string?)
		selectedPartId = partId
		for id, tile in tileById do
			local selected = id == partId
			tile.button.BackgroundColor3 = if selected then COLOR_SURFACE_HI else COLOR_SURFACE
			tile.stroke.Color = if selected then COLOR_ACCENT else COLOR_PANEL_STROKE
			tile.stroke.Thickness = if selected then 2.5 else 1.5
			tile.stroke.Transparency = if selected then 0 else 0.6
			tile.name.TextColor3 = if selected then COLOR_ACCENT_LIGHT else COLOR_TEXT
		end
		local tile = if partId then tileById[partId] else nil
		if tile and tile.category ~= currentCategory then
			selectCategory(tile.category)
		end
		if currentTool ~= "Paint" then
			refreshSubtitle()
		end
	end

	local function renderColor(index: number)
		local entry = Paint.List[index]
		if not entry then
			return
		end
		selectedColor = index
		for i, swatch in swatches do
			local selected = i == index
			swatch.stroke.Color = if selected then Color3.new(1, 1, 1) else COLOR_DEEP
			swatch.stroke.Thickness = if selected then 3 else 1.5
			swatch.stroke.Transparency = if selected then 0 else 0.4
			swatch.ring.Visible = selected
		end
		paintPreview.BackgroundColor3 = entry.Color
		paintName.Text = entry.Name
		if paintIcon then
			paintIcon.BackgroundColor3 = entry.Color
		end
		if currentTool == "Paint" then
			leftSubtitle.Text = entry.Name
		end
	end

	local function renderSymmetry(mode: string)
		currentSymmetry = mode
		local on = mode ~= "Off"
		symmetryValue.Text = SYMMETRY_LABELS[mode] or mode
		symmetryValue.TextColor3 = if on then COLOR_SYMMETRY else COLOR_TEXT_DIM
		symmetryStroke.Color = if on then COLOR_SYMMETRY else COLOR_PANEL_STROKE
		symmetryStroke.Transparency = if on then 0 else 0.3
		symmetryCaption.TextColor3 = if on then COLOR_TEXT else COLOR_TEXT_DIM
	end

	local function renderBoarding(mode: string)
		currentBoarding = mode
		boardingValue.Text = mode
		boardingHint.Text = BOARDING_HINTS[mode] or ""
		TweenService:Create(boardingPill, STATE_TWEEN, { BackgroundColor3 = BOARDING_COLORS[mode] or COLOR_SURFACE_HI })
			:Play()
	end

	-- Initial render
	selectCategory(currentCategory)
	renderTool("Build")
	renderSelectedPart(nil)
	renderColor(1)
	renderSymmetry("Off")
	renderBoarding(currentBoarding)
	refreshSlots()

	--========================================================================
	-- API
	--========================================================================
	local ui: BuildUI = {
		setVisible = function(visible: boolean)
			rootVisible = visible
			root.Visible = visible
			refreshSpin()
		end,
		setSelectedPart = function(partId: string?)
			renderSelectedPart(partId)
		end,
		setTool = function(tool: Tool)
			if TOOL_COLORS[tool] then
				renderTool(tool)
			end
		end,
		setSelectedColor = function(index: number)
			renderColor(index)
		end,
		setSymmetry = function(mode: Symmetry)
			renderSymmetry(mode)
		end,
		setRotationText = function(text: string)
			rotationValue.Text = text
		end,
		setStats = function(stats: Stats)
			local tonnes = stats.mass / 1000
			massValue.Text = if tonnes >= 100 then string.format("%.1f t", tonnes) else string.format("%.2f t", tonnes)
			local max = GameConfig.MAX_BLOCKS_PER_CRAFT
			partsValue.Text = `{stats.parts} / {max}`
			partsValue.TextColor3 = if stats.parts >= max
				then COLOR_BAD
				elseif stats.parts >= max * 0.9 then COLOR_ACCENT
				else COLOR_TEXT

			local count = #stats.stages
			for index, data in stats.stages do
				local row = stageRow(index)
				row.frame.Visible = true
				row.stage.Text = tostring(data.stage)
				row.vac.Text = formatInt(data.dvVac)
				row.asl.Text = formatInt(data.dvAsl)
				row.twr.Text = formatTwr(data.twrAsl)
				local good = data.twrAsl >= 1
				row.pill.BackgroundColor3 = if good then COLOR_GOOD else COLOR_BAD
				row.twr.TextColor3 = if good then COLOR_GOOD else COLOR_BAD
			end
			for index = count + 1, #stageRows do
				stageRows[index].frame.Visible = false
			end
			emptyRow.Visible = count == 0
			stageScroll.Visible = count > 0
			stageScroll.Size = UDim2.new(1, 0, 0, math.min(count, MAX_VISIBLE_STAGES) * (STAGE_ROW_HEIGHT + 2) - 2)
			totalVac.Text = formatInt(stats.totalVac)
			totalAsl.Text = formatInt(stats.totalAsl)

			local warnings = stats.warnings
			warningBox.Visible = #warnings > 0
			if #warnings > 0 then
				local lines = {}
				for index = 1, math.min(#warnings, MAX_WARNINGS_SHOWN) do
					table.insert(lines, "- " .. warnings[index])
				end
				if #warnings > MAX_WARNINGS_SHOWN then
					table.insert(lines, `+{#warnings - MAX_WARNINGS_SHOWN} more`)
				end
				warningText.Text = table.concat(lines, "\n")
			end
		end,
		setSlots = function(names: { [number]: string })
			local copy: { [number]: string } = {}
			for slot, name in names do
				if type(slot) == "number" and type(name) == "string" and name ~= "" then
					copy[slot] = name
				end
			end
			slotNames = copy
			refreshSlots()
		end,
		setBoarding = function(mode: string)
			renderBoarding(mode)
		end,
		toast = function(text: string, kind: string?)
			toastSerial += 1
			local serial = toastSerial
			for _, tween in toastTweens do
				tween:Cancel()
			end
			table.clear(toastTweens)
			local isError = kind == "Error"
			local color = if isError then COLOR_BAD else COLOR_ACCENT
			toastLabel.Text = text
			toastLabel.TextColor3 = if isError then COLOR_BAD_TEXT else COLOR_TEXT
			toastLabel.TextTransparency = 0
			toastStroke.Color = color
			toastStroke.Transparency = 0
			toastDot.BackgroundColor3 = color
			toastDot.BackgroundTransparency = 0
			toastFrame.BackgroundTransparency = 0.05
			toastFrame.Visible = true
			toastScale.Scale = 0.85
			TweenService:Create(toastScale, TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
				Scale = 1,
			}):Play()
			task.delay(TOAST_TIME_S, function()
				if serial ~= toastSerial then
					return
				end
				local info = TweenInfo.new(TOAST_FADE_S)
				local fades = {
					TweenService:Create(toastLabel, info, { TextTransparency = 1 }),
					TweenService:Create(toastFrame, info, { BackgroundTransparency = 1 }),
					TweenService:Create(toastStroke, info, { Transparency = 1 }),
					TweenService:Create(toastDot, info, { BackgroundTransparency = 1 }),
				}
				for _, tween in fades do
					table.insert(toastTweens, tween)
					tween:Play()
				end
				fades[1].Completed:Connect(function(state: Enum.PlaybackState)
					if serial == toastSerial and state == Enum.PlaybackState.Completed then
						toastFrame.Visible = false
					end
				end)
			end)
		end,
	}
	return ui
end

return table.freeze(BuildUI)
