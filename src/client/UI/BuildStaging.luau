--!strict
--[[
	BuildStaging (Phase 11)
	The builder's right column in the KSP skin, top to bottom:
	  * STAGING: a KSP-style staging list, one card per stage in firing order with the first stage to fire at the
	    BOTTOM (KSP order). Each card: stage number badge, delta-v at sea level and in vacuum, TWR on the home world
	    (red when the first stage's TWR is below 1: it cannot lift off), burn time and chips for what the stage does
	    (engines ignited, decouplers fired, parachutes armed). The list fills the free height and scrolls.
	  * CRAFT stats card: total mass, part count (amber near the limit, red at it), total delta-v ASL / vacuum and the
	    craft's warnings in amber.
	  * a big green ROLL OUT button.

	Every quantity is formatted through UI/Format, so it follows the units setting (redrawn live on a change).
	Pure view: it shows the Stats it is given and calls onRollOut.

	API:
	  BuildStaging.WIDTH: number                     the column width (design px)
	  BuildStaging.create(parent, callbacks) -> Staging
	    callbacks: { onRollOut() }
	  Staging.frame: Frame                           the column (BuildUI sets its Position and Size)
	  Staging.panels: { GuiObject }                  the visible blocks (staging list, stats card, roll out button)
	  Staging.setStats(stats: BuildInfo.Stats)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UnitFormat = require(ReplicatedStorage.Shared.Util.UnitFormat)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local BuildInfo = require(script.Parent.BuildInfo)
local Format = require(script.Parent.Format)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

--============================================================================
-- Tunables
--============================================================================
-- Layout (design px)
local COLUMN_WIDTH = 280
local COLUMN_GAP = 8
local PANEL_PADDING = 10
local HEADER_HEIGHT = 22
local HEADER_GAP = 6
local LIST_PADDING = 6
local CARD_GAP = 4
local PIN_TOLERANCE = 2 -- CHANGED (Phase 11 review): px from the bottom that still count as "at the first stage"
local CARD_HEIGHT = 62
local CARD_PADDING = 6
local BADGE_SIZE = 30
local BADGE_GAP = 8
local CARD_LINE_HEIGHT = 16
local CARD_LINE_GAP = 1
local TWR_WIDTH = 74
local BURN_WIDTH = 56
local CHIP_HEIGHT = 15
local CHIP_PADDING = 5
local CHIP_GAP = 4
local MAX_CHIPS = 3
local STATS_GAP = 2
local STAT_ROW_HEIGHT = 18
local MAX_WARNINGS = 3
local ROLL_OUT_HEIGHT = 52
local STAGING_MIN_HEIGHT = 120 -- before the flex layout gives the list its share
-- Thresholds
local PARTS_WARNING_FRACTION = 0.9 -- part count turns amber here
-- Look
local CHIP_COLORS: { [string]: Color3 } = {
	Engine = Theme.Colors.Warning,
	Decoupler = Theme.Colors.Danger,
	Chute = Theme.Colors.NavSky,
}
local FIRST_STAGE_STROKE = Theme.Colors.Title
-- Text
local STAGING_TITLE = "STAGING"
local STATS_TITLE = "CRAFT"
local EMPTY_TEXT = "No stages yet: add an engine"
local STAGE_TEXT = "STAGE %d"
local STAGES_ONE = "1 stage"
local STAGES_MANY = "%d stages"
local FIRES_FIRST = "(launch)" -- after the first stage's title
local TWR_PREFIX = "TWR "
local ASL_PREFIX = "ASL "
local VAC_PREFIX = "VAC "
local MASS_LABEL = "Mass"
local PARTS_LABEL = "Parts"
local TOTAL_ASL_LABEL = "Total dV (ASL)"
local TOTAL_VAC_LABEL = "Total dV (vac)"
local ROLL_OUT_TEXT = "ROLL OUT"
--============================================================================

export type Callbacks = {
	onRollOut: () -> (),
}

export type Staging = {
	frame: Frame,
	panels: { GuiObject },
	setStats: (stats: BuildInfo.Stats) -> (),
}

type Card = {
	frame: Frame,
	stroke: UIStroke,
	badge: TextLabel,
	title: TextLabel,
	twr: TextLabel,
	asl: TextLabel,
	vac: TextLabel,
	chips: { { frame: Frame, label: TextLabel, stroke: UIStroke } },
	burn: TextLabel,
}

local BuildStaging = {}

BuildStaging.WIDTH = COLUMN_WIDTH

local new = Kit.new
local DIM_HEX = "#" .. Theme.Colors.TextDim:ToHex()

-- Dim text inside a RichText label.
local function dim(text: string): string
	return `<font color="{DIM_HEX}">{text}</font>`
end

-- "<dim>PREFIX</dim>value" for a RichText label.
local function prefixed(prefix: string, value: string): string
	return dim(prefix) .. value
end

function BuildStaging.create(parent: Instance, callbacks: Callbacks): Staging
	local column = Kit.frame(parent, { name = "StagingColumn", anchor = Vector2.new(1, 0) })
	Kit.list(column, { gap = COLUMN_GAP })

	--========================================================================
	-- Staging list
	--========================================================================
	local stagingPanel = Kit.panel({
		parent = column,
		name = "Staging",
		size = UDim2.new(1, 0, 0, STAGING_MIN_HEIGHT),
		padding = PANEL_PADDING,
	})
	stagingPanel.LayoutOrder = 1
	new("UIFlexItem", { FlexMode = Enum.UIFlexMode.Fill }, stagingPanel)
	Kit.label(stagingPanel, STAGING_TITLE, {
		size = UDim2.new(0.5, 0, 0, HEADER_HEIGHT),
		bold = true,
		textSize = Theme.TextSizes.Large,
		color = Theme.Colors.Title,
	})
	local stageCount = Kit.label(stagingPanel, "", {
		size = UDim2.new(0.5, 0, 0, HEADER_HEIGHT),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
		textSize = Theme.TextSizes.Small,
		dim = true,
	})
	local listTop = HEADER_HEIGHT + HEADER_GAP
	local list = Kit.scroll(stagingPanel, {
		name = "Stages",
		position = UDim2.fromOffset(0, listTop),
		size = UDim2.new(1, 0, 1, -listTop),
		padding = LIST_PADDING,
		gap = CARD_GAP,
	})
	local listLayout = list:FindFirstChildOfClass("UIListLayout")
	if listLayout then
		listLayout.VerticalAlignment = Enum.VerticalAlignment.Bottom -- KSP: the first stage sits at the bottom
	end
	-- CHANGED (Phase 11 review): keep the first stage (bottom) in view whenever the list or its window changes size
	-- (new stages are added at the top, the stats card under the panel grows and shrinks), unless the player has
	-- scrolled up; scrolling back to the bottom pins it again
	local pinned = true
	local pinning = false
	local function bottomY(): number
		return math.max(0, list.AbsoluteCanvasSize.Y - list.AbsoluteWindowSize.Y)
	end
	local function pin()
		if not pinned then
			return
		end
		pinning = true
		list.CanvasPosition = Vector2.new(0, bottomY())
		pinning = false
	end
	list:GetPropertyChangedSignal("AbsoluteCanvasSize"):Connect(pin)
	list:GetPropertyChangedSignal("AbsoluteWindowSize"):Connect(pin)
	list:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
		if not pinning then
			pinned = list.CanvasPosition.Y >= bottomY() - PIN_TOLERANCE
		end
	end)
	local emptyText = Kit.label(stagingPanel, EMPTY_TEXT, {
		position = UDim2.fromOffset(0, listTop),
		size = UDim2.new(1, 0, 1, -listTop),
		align = Enum.TextXAlignment.Center,
		textSize = Theme.TextSizes.Small,
		dim = true,
	})
	emptyText.ZIndex = 2

	local cards: { Card } = {}
	local function card(index: number): Card
		local existing = cards[index]
		if existing then
			return existing
		end
		local frame: Frame = new("Frame", {
			Name = "Stage" .. index,
			Size = UDim2.new(1, 0, 0, CARD_HEIGHT),
			BackgroundColor3 = Theme.Colors.PanelRaised,
			BorderSizePixel = 0,
		}, list)
		Kit.corner(frame, Theme.Radius.Small)
		local stroke = Kit.stroke(frame, Theme.Colors.PanelStroke, Theme.Stroke.Thin)
		Kit.padding(frame, CARD_PADDING)
		local plate = Kit.plate(frame, UDim2.fromOffset(BADGE_SIZE, BADGE_SIZE))
		local badge = Kit.label(plate, "", {
			size = UDim2.fromScale(1, 1),
			align = Enum.TextXAlignment.Center,
			textSize = Theme.TextSizes.Large,
			color = Theme.Colors.DigitText,
		})
		badge.Font = Theme.Fonts.Digits
		local left = BADGE_SIZE + BADGE_GAP
		local function line(row: number): number
			return (row - 1) * (CARD_LINE_HEIGHT + CARD_LINE_GAP)
		end
		local title = Kit.label(frame, "", {
			position = UDim2.fromOffset(left, line(1)),
			size = UDim2.new(1, -(left + TWR_WIDTH), 0, CARD_LINE_HEIGHT),
			bold = true,
			textSize = Theme.TextSizes.Small,
		})
		title.RichText = true
		local twr = Kit.label(frame, "", {
			position = UDim2.new(1, 0, 0, line(1)),
			anchor = Vector2.new(1, 0),
			size = UDim2.fromOffset(TWR_WIDTH, CARD_LINE_HEIGHT),
			align = Enum.TextXAlignment.Right,
			bold = true,
			textSize = Theme.TextSizes.Small,
		})
		twr.RichText = true
		local asl = Kit.label(frame, "", {
			position = UDim2.fromOffset(left, line(2)),
			size = UDim2.new(0.5, -left / 2, 0, CARD_LINE_HEIGHT),
			textSize = Theme.TextSizes.Small,
		})
		asl.RichText = true
		local vac = Kit.label(frame, "", {
			position = UDim2.new(1, 0, 0, line(2)),
			anchor = Vector2.new(1, 0),
			size = UDim2.new(0.5, -left / 2, 0, CARD_LINE_HEIGHT),
			align = Enum.TextXAlignment.Right,
			textSize = Theme.TextSizes.Small,
		})
		vac.RichText = true
		local chipRow = Kit.frame(frame, {
			name = "Chips",
			position = UDim2.fromOffset(left, line(3)),
			size = UDim2.new(1, -(left + BURN_WIDTH), 0, CHIP_HEIGHT),
		})
		chipRow.ClipsDescendants = true
		Kit.list(chipRow, { horizontal = true, gap = CHIP_GAP })
		local chips = {}
		for chipIndex = 1, MAX_CHIPS do
			local chip: Frame = new("Frame", {
				Name = "Chip" .. chipIndex,
				Size = UDim2.fromOffset(0, CHIP_HEIGHT),
				AutomaticSize = Enum.AutomaticSize.X,
				BackgroundColor3 = Theme.Colors.PanelInset,
				BorderSizePixel = 0,
				LayoutOrder = chipIndex,
				Visible = false,
			}, chipRow)
			Kit.corner(chip, Theme.Radius.Small)
			local chipStroke = Kit.stroke(chip, Theme.Colors.PanelStroke, Theme.Stroke.Thin)
			new("UIPadding", {
				PaddingLeft = UDim.new(0, CHIP_PADDING),
				PaddingRight = UDim.new(0, CHIP_PADDING),
			}, chip)
			local chipLabel = Kit.label(chip, "", {
				size = UDim2.fromScale(0, 1),
				bold = true,
				textSize = Theme.TextSizes.Tiny,
			})
			chipLabel.AutomaticSize = Enum.AutomaticSize.X
			chips[chipIndex] = { frame = chip, label = chipLabel, stroke = chipStroke }
		end
		local burn = Kit.label(frame, "", {
			position = UDim2.new(1, 0, 0, line(3)),
			anchor = Vector2.new(1, 0),
			size = UDim2.fromOffset(BURN_WIDTH, CHIP_HEIGHT),
			align = Enum.TextXAlignment.Right,
			textSize = Theme.TextSizes.Tiny,
			dim = true,
		})
		local created: Card = {
			frame = frame,
			stroke = stroke,
			badge = badge,
			title = title,
			twr = twr,
			asl = asl,
			vac = vac,
			chips = chips,
			burn = burn,
		}
		cards[index] = created
		return created
	end

	--========================================================================
	-- Craft stats card
	--========================================================================
	local statsCard = Kit.panel({
		parent = column,
		name = "CraftStats",
		size = UDim2.fromScale(1, 0),
		padding = PANEL_PADDING,
	})
	statsCard.LayoutOrder = 2
	statsCard.AutomaticSize = Enum.AutomaticSize.Y
	Kit.list(statsCard, { gap = STATS_GAP })
	Kit.label(statsCard, STATS_TITLE, {
		size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		bold = true,
		textSize = Theme.TextSizes.Large,
		color = Theme.Colors.Title,
	})
	local function statRow(text: string): TextLabel
		local row = Kit.row(statsCard, STAT_ROW_HEIGHT)
		Kit.label(row, text, { size = UDim2.fromScale(0.5, 1), dim = true, textSize = Theme.TextSizes.Small })
		return Kit.label(row, "", {
			size = UDim2.fromScale(0.5, 1),
			position = UDim2.fromScale(1, 0),
			anchor = Vector2.new(1, 0),
			align = Enum.TextXAlignment.Right,
			bold = true,
		})
	end
	local massValue = statRow(MASS_LABEL)
	local partsValue = statRow(PARTS_LABEL)
	local totalAslValue = statRow(TOTAL_ASL_LABEL)
	local totalVacValue = statRow(TOTAL_VAC_LABEL)
	local warningLabels: { TextLabel } = {}
	for _ = 1, MAX_WARNINGS + 1 do -- + the "+N more" line
		local warning = Kit.label(statsCard, "", {
			wrap = true,
			textSize = Theme.TextSizes.Small,
			color = Theme.Colors.Warning,
		})
		warning.Size = UDim2.fromScale(1, 0)
		warning.Visible = false
		table.insert(warningLabels, warning)
	end

	--========================================================================
	-- Roll out
	--========================================================================
	local rollOut = Kit.button(column, ROLL_OUT_TEXT, callbacks.onRollOut, {
		name = "RollOut",
		style = "Accent",
		size = UDim2.new(1, 0, 0, ROLL_OUT_HEIGHT),
		textSize = Theme.TextSizes.Title,
		layoutOrder = 3,
	})
	rollOut.Font = Theme.Fonts.ExtraBold

	--========================================================================
	-- Render
	--========================================================================
	local lastStats: BuildInfo.Stats? = nil
	local lastCount = -1

	local function render(stats: BuildInfo.Stats)
		local count = #stats.stages
		for index, row in stats.stages do
			local c = card(index)
			local isFirst = row.stage == 1
			c.frame.Visible = true
			c.frame.LayoutOrder = BuildInfo.stageLayoutOrder(row.stage)
			c.stroke.Color = if isFirst then FIRST_STAGE_STROKE else Theme.Colors.PanelStroke
			c.badge.Text = tostring(row.stage)
			local stageText = string.format(STAGE_TEXT, row.stage)
			c.title.Text = if isFirst then `{stageText} {dim(FIRES_FIRST)}` else stageText
			local burns = BuildInfo.hasBurn(row)
			c.twr.Text = prefixed(TWR_PREFIX, BuildInfo.twrText(row.twrAsl))
			c.twr.TextColor3 = if BuildInfo.isTwrLow(row, isFirst)
				then Theme.Colors.Danger
				elseif isFirst then Theme.Colors.Accent
				else Theme.Colors.Text
			c.asl.Text = prefixed(ASL_PREFIX, if burns then Format.speed(row.dvAsl) else UnitFormat.NOT_AVAILABLE)
			c.vac.Text = prefixed(VAC_PREFIX, if burns then Format.speed(row.dvVac) else UnitFormat.NOT_AVAILABLE)
			c.burn.Text = if row.burnTime > 0 then Format.duration(row.burnTime) else ""
			local chips = BuildInfo.stageChips(row)
			for chipIndex, chipView in c.chips do
				local chip = chips[chipIndex]
				chipView.frame.Visible = chip ~= nil
				if chip then
					local color = CHIP_COLORS[chip.kind] or Theme.Colors.TextDim
					chipView.label.Text = chip.text
					chipView.label.TextColor3 = color
					chipView.stroke.Color = color
				end
			end
		end
		for index = count + 1, #cards do
			cards[index].frame.Visible = false
		end
		emptyText.Visible = count == 0
		stageCount.Text = if count == 0 then "" elseif count == 1 then STAGES_ONE else string.format(STAGES_MANY, count)
		if count ~= lastCount then
			lastCount = count
			-- show the first stage (bottom) once the layout has settled
			-- CHANGED (Phase 11 review): and keep it there (pin) while the sizes settle
			pinned = true
			task.defer(pin)
		end

		massValue.Text = Format.mass(stats.mass)
		local maxParts = GameConfig.MAX_BLOCKS_PER_CRAFT
		partsValue.Text = BuildInfo.partCountText(stats.parts, maxParts)
		partsValue.TextColor3 = if stats.parts >= maxParts
			then Theme.Colors.Danger
			elseif stats.parts >= maxParts * PARTS_WARNING_FRACTION then Theme.Colors.Warning
			else Theme.Colors.Text
		totalAslValue.Text = Format.speed(stats.totalAsl)
		totalVacValue.Text = Format.speed(stats.totalVac)

		local lines = BuildInfo.warningLines(stats.warnings, MAX_WARNINGS)
		for index, label in warningLabels do
			local text = lines[index]
			label.Visible = text ~= nil
			label.Text = text or ""
		end
	end

	Format.onUnitsChanged(function()
		local stats = lastStats
		if stats then
			render(stats)
		end
	end)

	render({ mass = 0, parts = 0, stages = {}, totalVac = 0, totalAsl = 0, warnings = {} })

	return {
		frame = column,
		panels = { stagingPanel, statsCard, rollOut },
		setStats = function(stats: BuildInfo.Stats)
			lastStats = stats
			render(stats)
		end,
	}
end

return table.freeze(BuildStaging)
