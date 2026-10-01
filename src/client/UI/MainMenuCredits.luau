--!strict
--[[
	MainMenuCredits (Phase 11)
	The main menu's "Credits / Updates" dialog, in the KSP pause-dialog look (same build as UI/SettingsPanel): a
	centred dark panel with a green title, two tabs and a scrolling page, and a "Close" button.
	  Credits  Space Disasters Inc., Created by St3amyEggroll, Made with Roblox, Rojo and Luau, Inspired by Kerbal
	           Space Program
	  Updates  Config/Updates, newest first: one section per entry ("Phase 11: New look") with its short notes

	A singleton built on first open in its own ScreenGui at Theme.DisplayOrder.Settings (above the menu). While open
	it holds UIState modal "Credits"; Escape closes it (Kit.onEscape).

	API:
	  MainMenuCredits.open()
	  MainMenuCredits.close()
	  MainMenuCredits.isOpen() -> boolean
	  MainMenuCredits.onClosed(fn()) -> RBXScriptConnection   after every close
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Updates = require(ReplicatedStorage.Shared.Config.Updates)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)
local UIState = require(script.Parent.UIState)

--============================================================================
-- Tunables
--============================================================================
local GUI_NAME = "MainMenuCredits"
local MODAL_NAME = "Credits" -- UIState modal while open
local PANEL_SIZE = Vector2.new(560, 480) -- S, shrunk to fit small screens / a big UI size
local SCREEN_MARGIN = 16 -- S
local POP_SCALE = 0.95 -- the panel grows from this to 1 when it opens
local TITLE = "Credits / Updates"
local TAB_CREDITS = "Credits"
local TAB_UPDATES = "Updates"
local TABS = { TAB_CREDITS, TAB_UPDATES }
local CREDIT_LINES: { { text: string, size: number, color: Color3, logo: boolean } } = {
	{ text = "Space Disasters Inc.", size = Theme.TextSizes.Title, color = Theme.Colors.Title, logo = true },
	{ text = "Created by St3amyEggroll", size = Theme.TextSizes.Large, color = Theme.Colors.Text, logo = false },
	{
		text = "Made with Roblox, Rojo and Luau",
		size = Theme.TextSizes.Body,
		color = Theme.Colors.TextDim,
		logo = false,
	},
	{
		text = "Inspired by Kerbal Space Program",
		size = Theme.TextSizes.Body,
		color = Theme.Colors.TextDim,
		logo = false,
	},
}
local CREDITS_TOP_GAP = 24 -- S, space above the first credit line
local NOTE_BULLET = "- "
--============================================================================

type View = {
	screen: ScreenGui,
	backdrop: TextButton,
	popScale: UIScale,
	tabs: Kit.Tabs,
	pages: { [string]: ScrollingFrame },
}

local MainMenuCredits = {}

local view: View? = nil
local isOpen = false
local selectedTab = TAB_CREDITS
local removeEscape: (() -> ())? = nil
local closedEvent = Instance.new("BindableEvent")

local function selectTab(name: string)
	selectedTab = name
	local v = view
	if v == nil then
		return
	end
	v.tabs.set(name)
	for pageName, page in v.pages do
		page.Visible = pageName == name
	end
end

local function buildCredits(page: ScrollingFrame)
	Kit.frame(page, { name = "Gap", size = UDim2.new(1, 0, 0, CREDITS_TOP_GAP) })
	for _, line in CREDIT_LINES do
		local label = Kit.label(page, line.text, {
			textSize = line.size,
			color = line.color,
			align = Enum.TextXAlignment.Center,
			bold = not line.logo,
		})
		if line.logo then
			label.Font = Theme.Fonts.Logo
		end
	end
end

local function buildUpdates(page: ScrollingFrame)
	for _, entry in Updates.ENTRIES do
		Kit.section(page, Updates.heading(entry))
		for _, note in entry.notes do
			Kit.label(page, NOTE_BULLET .. note, { wrap = true, textSize = Theme.TextSizes.Body })
		end
	end
end

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
		name = "Credits",
		size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	Kit.fitToCanvas(panel, canvas, PANEL_SIZE, SCREEN_MARGIN)
	local popScale: UIScale = Kit.new("UIScale", {}, panel)

	local gap = Theme.Padding.Medium
	Kit.title(panel, TITLE)
	local tabs = Kit.tabs(panel, TABS, selectedTab, selectTab)
	tabs.frame.Position = UDim2.fromOffset(0, Theme.Sizes.Title + gap)

	local pagesTop = Theme.Sizes.Title + gap + Theme.Sizes.Tab + gap
	local pagesBottom = Theme.Sizes.Button + gap
	local pages: { [string]: ScrollingFrame } = {}
	local builders: { [string]: (ScrollingFrame) -> () } = {
		[TAB_CREDITS] = buildCredits,
		[TAB_UPDATES] = buildUpdates,
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

	Kit.button(panel, "Close", MainMenuCredits.close, {
		name = "Close",
		size = UDim2.new(1, 0, 0, Theme.Sizes.Button),
		position = UDim2.fromScale(0, 1),
		anchor = Vector2.new(0, 1),
	})

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
function MainMenuCredits.open()
	if isOpen then
		return
	end
	local v = build()
	isOpen = true
	selectTab(selectedTab)
	v.screen.Enabled = true
	v.backdrop.BackgroundTransparency = 1
	v.popScale.Scale = POP_SCALE
	Kit.tween(v.backdrop, { BackgroundTransparency = Theme.Transparency.Backdrop }, Theme.Tween.Normal)
	Kit.tween(v.popScale, { Scale = 1 }, Theme.Tween.Normal)
	UIState.pushModal(MODAL_NAME)
	removeEscape = Kit.onEscape(MainMenuCredits.close)
end

function MainMenuCredits.close()
	if not isOpen then
		return
	end
	isOpen = false
	local remove = removeEscape
	if remove then
		remove()
		removeEscape = nil
	end
	local v = view
	if v then
		v.screen.Enabled = false
	end
	UIState.popModal(MODAL_NAME)
	closedEvent:Fire()
end

function MainMenuCredits.isOpen(): boolean
	return isOpen
end

function MainMenuCredits.onClosed(fn: () -> ()): RBXScriptConnection
	return closedEvent.Event:Connect(fn)
end

return table.freeze(MainMenuCredits)
