--!strict
--[[
	MainMenu (Phase 11)
	The main menu's screen, in the KSP look (UI/Kit): the "SPACE DISASTERS INC." logo top-left with a short tagline,
	a dark translucent panel on the left with the green "Main Menu" title and stacked buttons (Play in green,
	Settings, Credits / Updates), the version line (the newest Config/Updates entry) bottom-left and "Created by
	St3amyEggroll" bottom-right, plus a key hint ("Enter  Play") bottom-centre while hints are on (Settings).

	Layers in its ScreenGui (Theme.DisplayOrder.Menu, ZIndexBehavior Sibling):
	  FlareLayer  full screen, behind everything (ZIndex 0): Render/MenuScene draws the lens flare in it
	  Canvas      Kit's scaled design canvas with the "Content" CanvasGroup (fades as one)
	  Cover       full-screen black on top (ZIndex 10): fades the scene in / out
	  MouseUnlock an invisible Modal button that frees a first-person mouse while the menu shows
	No game logic: buttons only call the callbacks MainMenuController gives (named functions, so touch buttons or
	other entry points can call the same).

	API:
	  MainMenu.build(callbacks: { play: () -> (), settings: () -> (), credits: () -> () }) -> View
	  view.screen: ScreenGui
	  view.flareLayer: Frame
	  view.setEnabled(enabled)                     ScreenGui.Enabled and the mouse unlock
	  view.fadeContent(visible, time?)             the logo, panel and corner texts
	  view.fadeCover(opacity, time, onDone?)       black cover: 1 = black; a newer fade cancels onDone
	  view.setButtonsEnabled(enabled)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Updates = require(ReplicatedStorage.Shared.Config.Updates)
local Kit = require(script.Parent.Kit)
local Settings = require(script.Parent.Parent.Settings.Settings)
local Theme = require(script.Parent.Theme)

--============================================================================
-- Tunables
--============================================================================
local GUI_NAME = "MainMenu"
local LOGO_TEXT = "SPACE DISASTERS INC."
local TAGLINE_TEXT = "Build. Launch. Explode."
local PANEL_TITLE = "Main Menu"
local PLAY_TEXT = "Play"
local SETTINGS_TEXT = "Settings"
local CREDITS_TEXT = "Credits / Updates"
local CREATOR_TEXT = "Created by St3amyEggroll"
local HINT_KEY = "Enter"
local HINT_TEXT = "Play"
local HINTS_FIELD = "hints"
local MARGIN = 48 -- S, logo and panel distance from the left / top edges
local CORNER_MARGIN = 20 -- S, corner texts from the edges
local LOGO_TOP = 40 -- S
local LOGO_STROKE_TRANSPARENCY = 0.55 -- dark outline so the logo reads over Earth
local UNDERLINE_SIZE = Vector2.new(140, 3) -- S, the green bar under the logo
local PANEL_WIDTH = 280 -- S
local PANEL_TOP = 0.55 -- vertical centre of the panel (fraction of the screen)
local PLAY_HEIGHT = 42 -- S, the Play button is taller than the others
local CORNER_TEXT_SIZE = Theme.TextSizes.Small
local CORNER_WIDTH = 420 -- S
local HINT_BOTTOM = 18 -- S
local COVER_ZINDEX = 10
local COVER_COLOR = Color3.new(0, 0, 0)
--============================================================================

export type Callbacks = {
	play: () -> (),
	settings: () -> (),
	credits: () -> (),
}

export type View = {
	screen: ScreenGui,
	flareLayer: Frame,
	setEnabled: (enabled: boolean) -> (),
	fadeContent: (visible: boolean, time: number?) -> (),
	fadeCover: (opacity: number, time: number, onDone: (() -> ())?) -> (),
	setButtonsEnabled: (enabled: boolean) -> (),
}

local MainMenu = {}

local function buildLogo(content: Frame)
	local logo = Kit.frame(content, {
		name = "Logo",
		position = UDim2.fromOffset(MARGIN, LOGO_TOP),
		size = UDim2.fromOffset(0, 0),
	})
	logo.AutomaticSize = Enum.AutomaticSize.XY
	Kit.list(logo, { gap = Theme.Padding.Small })
	local title = Kit.label(logo, LOGO_TEXT, {
		textSize = Theme.TextSizes.Logo,
		size = UDim2.fromOffset(0, math.ceil(Theme.TextSizes.Logo * 1.3)),
		color = Theme.Colors.Text,
	})
	title.Font = Theme.Fonts.Logo
	title.AutomaticSize = Enum.AutomaticSize.X
	title.TextStrokeColor3 = COVER_COLOR
	title.TextStrokeTransparency = LOGO_STROKE_TRANSPARENCY
	local underline =
		Kit.frame(logo, { name = "Underline", size = UDim2.fromOffset(UNDERLINE_SIZE.X, UNDERLINE_SIZE.Y) })
	underline.BackgroundTransparency = 0
	underline.BackgroundColor3 = Theme.Colors.Title
	local tagline = Kit.label(logo, TAGLINE_TEXT, {
		textSize = Theme.TextSizes.Large,
		size = UDim2.fromOffset(0, math.ceil(Theme.TextSizes.Large * 1.4)),
		color = Theme.Colors.Title,
		bold = true,
	})
	tagline.AutomaticSize = Enum.AutomaticSize.X
	tagline.TextStrokeColor3 = COVER_COLOR
	tagline.TextStrokeTransparency = LOGO_STROKE_TRANSPARENCY
end

local function buildPanel(content: Frame, callbacks: Callbacks): { TextButton }
	local panel = Kit.panel({
		parent = content,
		name = "MenuPanel",
		size = UDim2.fromOffset(PANEL_WIDTH, 0),
		position = UDim2.new(0, MARGIN, PANEL_TOP, 0),
		anchor = Vector2.new(0, 0.5),
	})
	panel.AutomaticSize = Enum.AutomaticSize.Y
	Kit.list(panel, { gap = Theme.Padding.Medium })
	Kit.title(panel, PANEL_TITLE)
	return {
		Kit.button(panel, PLAY_TEXT, callbacks.play, {
			name = "Play",
			style = "Accent",
			size = UDim2.new(1, 0, 0, PLAY_HEIGHT),
			textSize = Theme.TextSizes.Large,
		}),
		Kit.button(panel, SETTINGS_TEXT, callbacks.settings, { name = "Settings" }),
		Kit.button(panel, CREDITS_TEXT, callbacks.credits, { name = "Credits" }),
	}
end

local function buildCorners(content: Frame)
	local version = Kit.label(content, Updates.versionLine(), {
		textSize = CORNER_TEXT_SIZE,
		dim = true,
		size = UDim2.fromOffset(CORNER_WIDTH, math.ceil(CORNER_TEXT_SIZE * 1.4)),
		position = UDim2.new(0, CORNER_MARGIN, 1, -CORNER_MARGIN),
		anchor = Vector2.new(0, 1),
	})
	version.Name = "Version"
	local creator = Kit.label(content, CREATOR_TEXT, {
		textSize = CORNER_TEXT_SIZE,
		dim = true,
		size = UDim2.fromOffset(CORNER_WIDTH, math.ceil(CORNER_TEXT_SIZE * 1.4)),
		position = UDim2.new(1, -CORNER_MARGIN, 1, -CORNER_MARGIN),
		anchor = Vector2.new(1, 1),
		align = Enum.TextXAlignment.Right,
	})
	creator.Name = "Creator"
end

local function buildHint(content: Frame): Frame
	local hint = Kit.frame(content, {
		name = "Hint",
		size = UDim2.fromOffset(0, Theme.Sizes.Keycap),
		position = UDim2.new(0.5, 0, 1, -HINT_BOTTOM),
		anchor = Vector2.new(0.5, 1),
	})
	hint.AutomaticSize = Enum.AutomaticSize.X
	Kit.list(hint, { horizontal = true, gap = Theme.Padding.Medium })
	Kit.keycap(hint, HINT_KEY)
	local label = Kit.label(hint, HINT_TEXT, {
		textSize = Theme.TextSizes.Small,
		size = UDim2.fromOffset(0, Theme.Sizes.Keycap),
	})
	label.AutomaticSize = Enum.AutomaticSize.X
	return hint
end

function MainMenu.build(callbacks: Callbacks): View
	local screen, canvas = Kit.screen(GUI_NAME, Theme.DisplayOrder.Menu)
	screen.Enabled = false

	local flareLayer: Frame = Kit.new("Frame", {
		Name = "FlareLayer",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 0,
	}, screen)

	local content: CanvasGroup = Kit.new("CanvasGroup", {
		Name = "Content",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		GroupTransparency = 1,
		Visible = false,
	}, canvas)
	local contentFrame = Kit.frame(content, { name = "Layout" })
	buildLogo(contentFrame)
	local buttons = buildPanel(contentFrame, callbacks)
	buildCorners(contentFrame)
	local hint = buildHint(contentFrame)
	local function refreshHint()
		hint.Visible = Settings.current().hints
	end
	refreshHint()
	local settingsConnection = Settings.onChanged(function(field: string)
		if field == HINTS_FIELD then
			refreshHint()
		end
	end)
	screen.Destroying:Connect(function()
		settingsConnection:Disconnect()
	end)

	local cover: Frame = Kit.new("Frame", {
		Name = "Cover",
		BackgroundColor3 = COVER_COLOR,
		BackgroundTransparency = 0,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		ZIndex = COVER_ZINDEX,
	}, screen)

	local mouseUnlock: TextButton = Kit.new("TextButton", {
		Name = "MouseUnlock",
		BackgroundTransparency = 1,
		Text = "",
		Size = UDim2.fromOffset(0, 0),
		Modal = true, -- frees the mouse if the camera was in first person
		Selectable = false,
	}, screen)

	local coverToken = 0
	local function fadeCover(opacity: number, time: number, onDone: (() -> ())?)
		coverToken += 1
		local token = coverToken
		local target = 1 - math.clamp(opacity, 0, 1)
		if time <= 0 then
			cover.BackgroundTransparency = target
			if onDone then
				task.defer(function()
					if coverToken == token then
						onDone()
					end
				end)
			end
			return
		end
		local tween = Kit.tween(cover, { BackgroundTransparency = target }, time)
		tween.Completed:Connect(function()
			if coverToken == token and onDone then
				onDone()
			end
		end)
	end

	return {
		screen = screen,
		flareLayer = flareLayer,
		setEnabled = function(enabled: boolean)
			screen.Enabled = enabled
			mouseUnlock.Visible = enabled
		end,
		fadeContent = function(visible: boolean, time: number?)
			Kit.fadeCanvas(content, visible, time)
		end,
		fadeCover = fadeCover,
		setButtonsEnabled = function(enabled: boolean)
			for _, button in buttons do
				Kit.setButtonEnabled(button, enabled)
			end
		end,
	}
end

return table.freeze(MainMenu)
