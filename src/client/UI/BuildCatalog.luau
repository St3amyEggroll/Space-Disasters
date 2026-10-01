--!strict
--[[
	BuildCatalog (Phase 11)
	The builder's left side panel in the KSP skin (UI/Theme, UI/Kit):
	  * PARTS: a column of category tabs, a recessed grid of part tiles with slowly turning 3D previews (ViewportFrames
	    built from the game's own part visuals through CraftBuilder.buildBlock) and an info card under the grid with
	    the hovered (or selected) part's name and short stats (BuildInfo.partLines, units from Settings via Format)
	  * PAINT: while the Paint tool is active the grid becomes the paint palette (current colour + 4 x 4 swatches)

	Pure view like the rest of BuildUI: it only calls its callbacks and shows what the set* functions give it. The
	previews of a category are built the first time it is shown and turn only while the catalog is active (the
	builder is on screen) and showing parts; at most PREVIEW_MAX_SPINNING tiles per category turn.

	API:
	  BuildCatalog.WIDTH: number               the panel's width (design px)
	  BuildCatalog.create(parent, callbacks) -> Catalog
	    callbacks: { onSelectPart(partId), onSelectColor(index) }
	  Catalog.frame: Frame                     the panel; BuildUI sets its Position and Size
	  Catalog.setTool(tool)                    "Paint" shows the palette, "Delete" says so in the header
	  Catalog.setSelectedPart(partId?)         highlights the tile (switching to its category) and fills the info card
	  Catalog.setSelectedColor(index)          Paint.List index
	  Catalog.setActive(active)                previews turn only while active
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Paint = require(ReplicatedStorage.Shared.Config.Paint)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local BuildInfo = require(script.Parent.BuildInfo)
local Format = require(script.Parent.Format)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

--============================================================================
-- Tunables
--============================================================================
-- Layout (design px)
local PANEL_PADDING = 10
local HEADER_HEIGHT = 24
local TITLE_WIDTH = 80
local BODY_GAP = 8 -- between header, body and info card
local TAB_WIDTH = 84
local TAB_HEIGHT = 28
local TAB_GAP = 4
local GRID_GAP = 8 -- between the tab column and the grid
local GRID_PADDING = 6
local TILE_WIDTH = 92
local TILE_HEIGHT = 100
local TILE_GAP = 6
local TILE_COLUMNS = 2
local TILE_INSET = 4
local TILE_VIEW_HEIGHT = 64
local INFO_HEIGHT = 112
local INFO_PADDING = 8
local INFO_NAME_HEIGHT = 22
local INFO_LINE_HEIGHT = 16
local INFO_LINES = 4
local SWATCH_SIZE = 56
local SWATCH_GAP = 8
local SWATCH_COLUMNS = 4
local SWATCH_RING = 14
local PAINT_HEADER_HEIGHT = 40
local PAINT_PREVIEW_SIZE = 36
-- Look
local VIEW_TRANSPARENCY = 0.2 -- tile preview background (GaugeFace)
local VIEW_AMBIENT = Color3.fromRGB(165, 170, 185)
local VIEW_LIGHT = Color3.new(1, 1, 1)
local VIEW_LIGHT_DIRECTION = Vector3.new(-1, -1.6, -0.8)
local SWATCH_SELECTED_COLOR = Theme.Colors.Text
-- Previews
local PREVIEW_SPIN_SPEED = 0.6 -- rad/s
local PREVIEW_FPS = 30
local PREVIEW_START_ANGLE_DEG = 35
local PREVIEW_ELEVATION_DEG = 24
local PREVIEW_FOV = 30
local PREVIEW_FILL = 1.02 -- camera distance factor around the bounding sphere
local PREVIEW_MIN_RADIUS = 0.5
local PREVIEW_MAX_SPINNING = 8
-- Text
local TITLE_PARTS = "PARTS"
local TITLE_PAINT = "PAINT"
local PICK_TEXT = "Pick a part"
local DELETE_TEXT = "Click blocks to remove"
local PAINT_HINT = "Click blocks to paint them"
local PREVIEW_FAILED_TEXT = "?"
--============================================================================

export type Callbacks = {
	onSelectPart: (partId: string) -> (),
	onSelectColor: (index: number) -> (),
}

export type Catalog = {
	frame: Frame,
	setTool: (tool: BuildInfo.Tool) -> (),
	setSelectedPart: (partId: string?) -> (),
	setSelectedColor: (index: number) -> (),
	setActive: (active: boolean) -> (),
}

type Tile = {
	button: TextButton,
	stroke: UIStroke,
	name: TextLabel,
	viewport: ViewportFrame,
	def: Parts.PartDef,
	category: string,
	camera: Camera?,
	center: Vector3,
	distance: number,
}

type Swatch = { button: TextButton, stroke: UIStroke, ring: Frame }

local BuildCatalog = {}

-- The panel width that fits TILE_COLUMNS tiles next to the tab column (the grid keeps room for its scroll bar).
local PANEL_WIDTH = PANEL_PADDING * 2
	+ TAB_WIDTH
	+ GRID_GAP
	+ GRID_PADDING * 2
	+ Theme.Sizes.ScrollBar
	+ TILE_WIDTH * TILE_COLUMNS
	+ TILE_GAP * (TILE_COLUMNS - 1)
BuildCatalog.WIDTH = PANEL_WIDTH

local new = Kit.new

-- A turning preview of one part, built from the game's own visuals.
local function buildPreview(tile: Tile)
	local block: CraftDesign.Block = { id = 0, type = tile.def.Id, gx = 0, gy = 0, gz = 0, rot = 0 }
	local ok, result = pcall(function(): Model
		return CraftBuilder.buildBlock(block, "Cosmetic", CFrame.identity)
	end)
	if not ok or typeof(result) ~= "Instance" or not result:IsA("Model") then
		Kit.label(tile.viewport, PREVIEW_FAILED_TEXT, {
			size = UDim2.fromScale(1, 1),
			align = Enum.TextXAlignment.Center,
			textSize = Theme.TextSizes.Title,
			bold = true,
			dim = true,
		})
		return
	end
	local model = result :: Model
	local cf, size = model:GetBoundingBox()
	local radius = math.max(size.Magnitude / 2, PREVIEW_MIN_RADIUS)
	local camera: Camera = new("Camera", { FieldOfView = PREVIEW_FOV }, tile.viewport)
	tile.camera = camera
	tile.center = cf.Position
	tile.distance = radius / math.sin(math.rad(PREVIEW_FOV / 2)) * PREVIEW_FILL
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

function BuildCatalog.create(parent: Instance, callbacks: Callbacks): Catalog
	local panel = Kit.panel({
		parent = parent,
		name = "PartCatalog",
		size = UDim2.new(0, PANEL_WIDTH, 1, 0),
		padding = PANEL_PADDING,
	})

	-- State (mirrors what BuildUI last told us; the category is local UI state)
	local currentTool: BuildInfo.Tool = "Build"
	local selectedPartId: string? = nil
	local hoveredPartId: string? = nil
	local selectedColor = 1
	local currentCategory: string = Parts.Categories[1]
	local active = false

	--========================================================================
	-- Header
	--========================================================================
	local title = Kit.label(panel, TITLE_PARTS, {
		size = UDim2.new(0, TITLE_WIDTH, 0, HEADER_HEIGHT),
		bold = true,
		textSize = Theme.TextSizes.Title,
		color = Theme.Colors.Title,
	})
	local subtitle = Kit.label(panel, PICK_TEXT, {
		size = UDim2.new(1, -TITLE_WIDTH, 0, HEADER_HEIGHT),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
		dim = true,
	})

	local body = Kit.frame(panel, { name = "Body", position = UDim2.fromOffset(0, HEADER_HEIGHT + BODY_GAP) })

	--========================================================================
	-- Parts view: category tabs + tile grid
	--========================================================================
	local partsView = Kit.frame(body, { name = "Parts" })
	local tabColumn = Kit.frame(partsView, { name = "Tabs", size = UDim2.new(0, TAB_WIDTH, 1, 0) })
	Kit.list(tabColumn, { gap = TAB_GAP })
	local grid: ScrollingFrame = new("ScrollingFrame", {
		Name = "Grid",
		Position = UDim2.fromOffset(TAB_WIDTH + GRID_GAP, 0),
		Size = UDim2.new(1, -(TAB_WIDTH + GRID_GAP), 1, 0),
		BackgroundColor3 = Theme.Colors.PanelInset,
		BackgroundTransparency = Theme.Transparency.Inset,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = Theme.Sizes.ScrollBar,
		ScrollBarImageColor3 = Theme.Colors.PanelStroke,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
	}, partsView)
	Kit.corner(grid, Theme.Radius.Small)
	Kit.padding(grid, GRID_PADDING)

	local tabs: { [string]: TextButton } = {}
	local pages: { [string]: Frame } = {}
	local tilesByCategory: { [string]: { Tile } } = {}
	local tileById: { [string]: Tile } = {}
	local previewsBuilt: { [string]: boolean } = {}
	local byCategory = Parts.byCategory()
	local spinAngle = math.rad(PREVIEW_START_ANGLE_DEG)

	--========================================================================
	-- Info card (hovered or selected part)
	--========================================================================
	local info: Frame = new("Frame", {
		Name = "PartInfo",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, INFO_HEIGHT),
		BackgroundColor3 = Theme.Colors.PanelRaised,
		BorderSizePixel = 0,
	}, panel)
	Kit.corner(info, Theme.Radius.Small)
	Kit.stroke(info, Theme.Colors.PanelStroke, Theme.Stroke.Thin)
	Kit.padding(info, INFO_PADDING)
	local infoName = Kit.label(info, "", {
		size = UDim2.new(0.62, 0, 0, INFO_NAME_HEIGHT),
		bold = true,
		textSize = Theme.TextSizes.Large,
	})
	local infoCategory = Kit.label(info, "", {
		size = UDim2.new(0.38, 0, 0, INFO_NAME_HEIGHT),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
		textSize = Theme.TextSizes.Small,
		color = Theme.Colors.Title,
	})
	local infoLines: { TextLabel } = {}
	for index = 1, INFO_LINES do
		infoLines[index] = Kit.label(info, "", {
			size = UDim2.new(1, 0, 0, INFO_LINE_HEIGHT),
			position = UDim2.fromOffset(0, INFO_NAME_HEIGHT + (index - 1) * INFO_LINE_HEIGHT),
			textSize = Theme.TextSizes.Small,
			dim = true,
		})
	end

	local function renderInfo()
		local id = hoveredPartId or selectedPartId
		local tile = if id then tileById[id] else nil
		if tile == nil then
			infoName.Text = PICK_TEXT
			infoName.TextColor3 = Theme.Colors.TextDim
			infoCategory.Text = ""
			for _, line in infoLines do
				line.Text = ""
			end
			return
		end
		infoName.Text = tile.def.DisplayName
		infoName.TextColor3 = Theme.Colors.Text
		infoCategory.Text = string.upper(BuildInfo.categoryName(tile.category))
		local lines = BuildInfo.partLines(tile.def, Format.units(), GameConfig.G0)
		for index, line in infoLines do
			line.Text = lines[index] or ""
		end
	end

	--========================================================================
	-- Paint view: current colour + swatches
	--========================================================================
	local paintView = Kit.frame(body, { name = "Paint" })
	paintView.Visible = false
	local paintPreview: Frame = new("Frame", {
		Name = "Current",
		Size = UDim2.fromOffset(PAINT_PREVIEW_SIZE, PAINT_PREVIEW_SIZE),
		BackgroundColor3 = Paint.List[1].Color,
		BorderSizePixel = 0,
	}, paintView)
	Kit.corner(paintPreview, Theme.Radius.Button)
	Kit.stroke(paintPreview, SWATCH_SELECTED_COLOR, Theme.Stroke.Medium)
	local textLeft = PAINT_PREVIEW_SIZE + Theme.Padding.Medium
	local paintName = Kit.label(paintView, Paint.List[1].Name, {
		size = UDim2.new(1, -textLeft, 0, PAINT_HEADER_HEIGHT / 2),
		position = UDim2.fromOffset(textLeft, 0),
		bold = true,
		textSize = Theme.TextSizes.Large,
	})
	Kit.label(paintView, PAINT_HINT, {
		size = UDim2.new(1, -textLeft, 0, PAINT_HEADER_HEIGHT / 2),
		position = UDim2.fromOffset(textLeft, PAINT_HEADER_HEIGHT / 2),
		textSize = Theme.TextSizes.Small,
		dim = true,
	})
	local swatchSpan = SWATCH_SIZE * SWATCH_COLUMNS + SWATCH_GAP * (SWATCH_COLUMNS - 1)
	local swatchGrid = Kit.frame(paintView, {
		name = "Swatches",
		anchor = Vector2.new(0.5, 0),
		position = UDim2.new(0.5, 0, 0, PAINT_HEADER_HEIGHT + BODY_GAP),
		size = UDim2.fromOffset(swatchSpan, swatchSpan),
	})
	new("UIGridLayout", {
		CellSize = UDim2.fromOffset(SWATCH_SIZE, SWATCH_SIZE),
		CellPadding = UDim2.fromOffset(SWATCH_GAP, SWATCH_GAP),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, swatchGrid)
	local swatches: { Swatch } = {}
	for index, entry in Paint.List do
		local swatch: TextButton = new("TextButton", {
			Name = entry.Name,
			AutoButtonColor = false,
			BackgroundColor3 = entry.Color,
			BorderSizePixel = 0,
			Text = "",
			LayoutOrder = index,
		}, swatchGrid)
		Kit.corner(swatch, Theme.Radius.Button)
		Kit.gradient(swatch, Color3.new(1, 1, 1), Theme.Colors.ButtonShade)
		local swatchStroke = Kit.stroke(swatch, Theme.Colors.ButtonStroke, Theme.Stroke.Thin)
		local ring: Frame = new("Frame", {
			Name = "Ring",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(SWATCH_RING, SWATCH_RING),
			BackgroundColor3 = SWATCH_SELECTED_COLOR,
			BorderSizePixel = 0,
			Visible = false,
		}, swatch)
		Kit.round(ring)
		Kit.stroke(ring, Theme.Colors.ButtonStroke, Theme.Stroke.Medium)
		swatches[index] = { button = swatch, stroke = swatchStroke, ring = ring }
		swatch.Activated:Connect(function()
			callbacks.onSelectColor(index)
		end)
	end

	--========================================================================
	-- Tiles
	--========================================================================
	local function renderTiles()
		for id, tile in tileById do
			local selected = id == selectedPartId
			local hovered = id == hoveredPartId
			tile.button.BackgroundColor3 = if hovered then Theme.Colors.GhostHover else Theme.Colors.PanelRaised
			tile.stroke.Color = if selected then Theme.Colors.Title else Theme.Colors.PanelStroke
			tile.stroke.Thickness = if selected then Theme.Stroke.Medium else Theme.Stroke.Thin
			tile.name.TextColor3 = if selected then Theme.Colors.Title else Theme.Colors.Text
		end
	end

	local function ensurePreviews(category: string)
		if previewsBuilt[category] then
			return
		end
		previewsBuilt[category] = true
		local list = tilesByCategory[category]
		if list == nil then
			return
		end
		for _, tile in list do
			buildPreview(tile)
			poseCamera(tile, spinAngle)
		end
	end

	local function selectCategory(category: string)
		currentCategory = category
		for name, tab in tabs do
			Kit.setButtonStyle(tab, if name == category then "Primary" else "Ghost")
		end
		for name, page in pages do
			page.Visible = name == category
		end
		grid.CanvasPosition = Vector2.zero
		ensurePreviews(category)
	end

	for index, category: Parts.Category in Parts.Categories do
		local tabName: string = category
		tabs[category] = Kit.button(tabColumn, BuildInfo.categoryName(category), function()
			selectCategory(category)
		end, {
			name = tabName,
			size = UDim2.new(1, 0, 0, TAB_HEIGHT),
			style = "Ghost",
			textSize = Theme.TextSizes.Small,
			layoutOrder = index,
		})

		local page: Frame = new("Frame", {
			Name = category,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Visible = false,
		}, grid)
		new("UIGridLayout", {
			CellSize = UDim2.fromOffset(TILE_WIDTH, TILE_HEIGHT),
			CellPadding = UDim2.fromOffset(TILE_GAP, TILE_GAP),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}, page)
		pages[category] = page

		local list: { Tile } = {}
		for order, def in byCategory[category] do
			local tileButton: TextButton = new("TextButton", {
				Name = def.Id,
				AutoButtonColor = false,
				BackgroundColor3 = Theme.Colors.PanelRaised,
				BorderSizePixel = 0,
				Text = "",
				LayoutOrder = order,
			}, page)
			Kit.corner(tileButton, Theme.Radius.Small)
			local tileStroke = Kit.stroke(tileButton, Theme.Colors.PanelStroke, Theme.Stroke.Thin)
			local viewport: ViewportFrame = new("ViewportFrame", {
				Name = "Preview",
				Position = UDim2.fromOffset(TILE_INSET, TILE_INSET),
				Size = UDim2.new(1, -TILE_INSET * 2, 0, TILE_VIEW_HEIGHT),
				BackgroundColor3 = Theme.Colors.GaugeFace,
				BackgroundTransparency = VIEW_TRANSPARENCY,
				BorderSizePixel = 0,
				Ambient = VIEW_AMBIENT,
				LightColor = VIEW_LIGHT,
				LightDirection = VIEW_LIGHT_DIRECTION,
			}, tileButton)
			Kit.corner(viewport, Theme.Radius.Small)
			local nameTop = TILE_INSET * 2 + TILE_VIEW_HEIGHT
			local nameLabel = Kit.label(tileButton, def.DisplayName, {
				position = UDim2.fromOffset(TILE_INSET, nameTop),
				size = UDim2.new(1, -TILE_INSET * 2, 1, -(nameTop + TILE_INSET)),
				align = Enum.TextXAlignment.Center,
				textSize = Theme.TextSizes.Small,
				bold = true,
			})
			nameLabel.TextWrapped = true
			nameLabel.TextTruncate = Enum.TextTruncate.None
			local tile: Tile = {
				button = tileButton,
				stroke = tileStroke,
				name = nameLabel,
				viewport = viewport,
				def = def,
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
			tileButton.MouseEnter:Connect(function()
				hoveredPartId = def.Id
				renderTiles()
				renderInfo()
			end)
			tileButton.MouseLeave:Connect(function()
				if hoveredPartId == def.Id then
					hoveredPartId = nil
					renderTiles()
					renderInfo()
				end
			end)
		end
		tilesByCategory[category] = list
	end

	--========================================================================
	-- Preview spin (only while active and showing parts)
	--========================================================================
	local spinConnection: RBXScriptConnection? = nil
	local spinAccumulator = 0
	local function refreshSpin()
		local shouldSpin = active and partsView.Visible
		if shouldSpin and spinConnection == nil then
			spinConnection = RunService.RenderStepped:Connect(function(dt: number)
				spinAccumulator += dt
				if spinAccumulator < 1 / PREVIEW_FPS then
					return
				end
				spinAngle = (spinAngle + spinAccumulator * PREVIEW_SPIN_SPEED) % (2 * math.pi)
				spinAccumulator = 0
				local list = tilesByCategory[currentCategory]
				if list == nil then
					return
				end
				for index, tile in list do
					if index > PREVIEW_MAX_SPINNING then
						break
					end
					poseCamera(tile, spinAngle)
				end
			end)
		elseif not shouldSpin and spinConnection then
			spinConnection:Disconnect()
			spinConnection = nil
		end
	end

	--========================================================================
	-- Renderers
	--========================================================================
	local function renderHeader()
		if currentTool == "Paint" then
			title.Text = TITLE_PAINT
			local entry = Paint.List[selectedColor]
			subtitle.Text = if entry then entry.Name else ""
			subtitle.TextColor3 = Theme.Colors.Text
		elseif currentTool == "Delete" then
			title.Text = TITLE_PARTS
			subtitle.Text = DELETE_TEXT
			subtitle.TextColor3 = Theme.Colors.Danger
		else
			title.Text = TITLE_PARTS
			local tile = if selectedPartId then tileById[selectedPartId] else nil
			subtitle.Text = if tile then tile.def.DisplayName else PICK_TEXT
			subtitle.TextColor3 = if tile then Theme.Colors.Text else Theme.Colors.TextDim
		end
	end

	local function renderTool(tool: BuildInfo.Tool)
		currentTool = tool
		local painting = tool == "Paint"
		partsView.Visible = not painting
		paintView.Visible = painting
		info.Visible = not painting
		local bottom = if painting then 0 else INFO_HEIGHT + BODY_GAP
		body.Size = UDim2.new(1, 0, 1, -(HEADER_HEIGHT + BODY_GAP + bottom))
		renderHeader()
		refreshSpin()
	end

	local function renderSelectedPart(partId: string?)
		selectedPartId = partId
		local tile = if partId then tileById[partId] else nil
		if tile and tile.category ~= currentCategory then
			selectCategory(tile.category)
		end
		renderTiles()
		renderInfo()
		renderHeader()
	end

	local function renderColor(index: number)
		local entry = Paint.List[index]
		if not entry then
			return
		end
		selectedColor = index
		for i, swatch in swatches do
			local selected = i == index
			swatch.stroke.Color = if selected then SWATCH_SELECTED_COLOR else Theme.Colors.ButtonStroke
			swatch.stroke.Thickness = if selected then Theme.Stroke.Thick else Theme.Stroke.Thin
			swatch.ring.Visible = selected
		end
		paintPreview.BackgroundColor3 = entry.Color
		paintName.Text = entry.Name
		renderHeader()
	end

	Format.onUnitsChanged(function()
		renderInfo()
	end)

	selectCategory(currentCategory)
	renderTool("Build")
	renderSelectedPart(nil)
	renderColor(1)

	return {
		frame = panel,
		setTool = renderTool,
		setSelectedPart = renderSelectedPart,
		setSelectedColor = renderColor,
		setActive = function(isActive: boolean)
			active = isActive
			if not isActive and hoveredPartId then
				hoveredPartId = nil -- MouseLeave does not fire when the panel is hidden
				renderTiles()
				renderInfo()
			end
			refreshSpin()
		end,
	}
end

return table.freeze(BuildCatalog)
