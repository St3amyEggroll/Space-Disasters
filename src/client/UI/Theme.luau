--!strict
--[[
	Theme (Phase 11)
	The Kerbal Space Program 1.x look as design tokens, shared by every screen built with UI/Kit:
	  * the pause dialog: a near-black grey panel (#1E2226, ~85% opaque) with a 1 px lighter grey border, a yellow-green
	    title (#A6D64A) and stacked light grey buttons (#C8CCD0, a slight vertical gradient) with dark text (#1C1F22)
	  * the instruments: gunmetal bezels and plates, black gauge faces, odometer wheels (white digits on dark wheels),
	    green digital readouts and the navball's blue sky and orange-brown ground
	Pure data (Color3, Enum.Font and numbers only) and frozen, so the offline Lune spec can check it
	(src/server/Tests/Theme.spec.luau). Never mutate it; add a token here instead of hard-coding a colour elsewhere.

	Sizes are DESIGN PIXELS: a Kit screen lays its content out on a Canvas.Width x Canvas.Height design canvas and
	scales it uniformly to the screen (clamped to Canvas.MinFit..Canvas.MaxFit), times the player's "UI size" setting.

	Tokens:
	  Theme.Colors
	    Panel, PanelStroke, PanelInset (recessed areas: lists, scroll pages), PanelRaised (rows on a panel)
	    Title (yellow-green panel titles), Text, TextDim
	    Button, ButtonHover, ButtonPressed, ButtonText, ButtonShade (gradient multiplier at a button's bottom),
	    ButtonStroke, ButtonDisabled, ButtonDisabledText
	    Ghost, GhostHover, GhostPressed (dark buttons: unselected tabs and segments)
	    Accent (lit SAS green / primary action), AccentHover, AccentDark
	    Warning (amber), Danger (red), DangerHover, DangerDark
	    GaugeMetal, GaugeMetalDark, GaugeMetalLight (gunmetal bezels and plates), GaugeFace (black gauge faces)
	    DigitWheel, DigitText (odometer), DigitalGreen (speed readouts)
	    NavSky, NavGround (navball), Track (empty part of bars and sliders), Backdrop (modal dim)
	  Theme.Transparency   Panel, Inset, Backdrop, Plate
	  Theme.Fonts          Title, Body, Medium, Bold, ExtraBold, Mono, Digits, Logo
	  Theme.TextSizes      Tiny, Small, Body, Button, Large, Title, Huge, Logo
	  Theme.Radius         Panel, Button, Small (corner radius, px)
	  Theme.Padding        Tiny, Small, Medium, Large, Huge, Panel (inside a panel), Gap (between list items)
	  Theme.Stroke         Thin, Medium, Thick (UIStroke thickness, px)
	  Theme.Sizes          Button, ButtonSmall, Row, Title, Tab, Section, SliderTrack, SliderKnob, ToggleWidth,
	                       ToggleHeight, Segment, KeyButton, ScrollBar, Keycap, Toast, ToastTop (px), BezelFraction
	                       (the bezel's metal ring as a fraction of its diameter, per side)
	  Theme.Tween          Fast (hover / press), Normal (state changes, pop-ins), Fade (fades), Slow (seconds)
	  Theme.DisplayOrder   Builder < Map < HUD < Menu < Settings < Dialog < Toast < Debug (ScreenGui.DisplayOrder)
	  Theme.Canvas         Width, Height (design canvas), MinFit, MaxFit (screen fit clamp)
]]

--============================================================================
-- Tunables
--============================================================================
-- Panels (KSP pause dialog)
local PANEL = Color3.fromRGB(30, 34, 38) -- #1E2226
local PANEL_STROKE = Color3.fromRGB(88, 94, 100) -- the 1 px lighter border
local PANEL_INSET = Color3.fromRGB(18, 21, 24) -- recessed areas: scroll pages, lists
local PANEL_RAISED = Color3.fromRGB(44, 49, 54) -- rows and cards on a panel
local TITLE = Color3.fromRGB(166, 214, 74) -- #A6D64A ("Game Paused")
local TEXT = Color3.fromRGB(226, 229, 232)
local TEXT_DIM = Color3.fromRGB(142, 149, 156)
-- Buttons (KSP light grey with dark text)
local BUTTON = Color3.fromRGB(200, 204, 208) -- #C8CCD0
local BUTTON_HOVER = Color3.fromRGB(224, 228, 232)
local BUTTON_PRESSED = Color3.fromRGB(160, 165, 170)
local BUTTON_TEXT = Color3.fromRGB(28, 31, 34) -- #1C1F22
local BUTTON_SHADE = Color3.fromRGB(204, 208, 212) -- UIGradient multiplier at the bottom (the slight gradient)
local BUTTON_STROKE = Color3.fromRGB(20, 22, 25)
local BUTTON_DISABLED = Color3.fromRGB(78, 83, 88)
local BUTTON_DISABLED_TEXT = Color3.fromRGB(134, 139, 144)
local GHOST = Color3.fromRGB(44, 49, 54) -- dark buttons (unselected tabs / segments)
local GHOST_HOVER = Color3.fromRGB(60, 66, 72)
local GHOST_PRESSED = Color3.fromRGB(24, 27, 30)
-- Status
local ACCENT = Color3.fromRGB(118, 206, 58) -- the lit SAS button
local ACCENT_HOVER = Color3.fromRGB(146, 226, 88)
local ACCENT_DARK = Color3.fromRGB(62, 112, 32)
local WARNING = Color3.fromRGB(240, 178, 44)
local DANGER = Color3.fromRGB(204, 60, 48)
local DANGER_HOVER = Color3.fromRGB(226, 86, 72)
local DANGER_DARK = Color3.fromRGB(122, 34, 28)
-- Instruments (navball cluster, altimeter)
local GAUGE_METAL = Color3.fromRGB(66, 71, 76) -- gunmetal
local GAUGE_METAL_DARK = Color3.fromRGB(32, 35, 38)
local GAUGE_METAL_LIGHT = Color3.fromRGB(126, 132, 138)
local GAUGE_FACE = Color3.fromRGB(12, 14, 16)
local DIGIT_WHEEL = Color3.fromRGB(22, 24, 26)
local DIGIT_TEXT = Color3.fromRGB(242, 242, 236)
local DIGITAL_GREEN = Color3.fromRGB(98, 232, 84)
local NAV_SKY = Color3.fromRGB(64, 148, 230) -- same as UI/Navball's sky
local NAV_GROUND = Color3.fromRGB(150, 96, 52) -- same as UI/Navball's ground
local TRACK = Color3.fromRGB(12, 14, 16) -- empty part of bars and slider tracks
local BACKDROP = Color3.fromRGB(0, 0, 0)
-- Transparency
local PANEL_TRANSPARENCY = 0.15 -- ~85% opaque
local INSET_TRANSPARENCY = 0.25
local BACKDROP_TRANSPARENCY = 0.45
local PLATE_TRANSPARENCY = 0
-- Fonts
local FONT_TITLE = Enum.Font.BuilderSansBold
local FONT_BODY = Enum.Font.BuilderSans
local FONT_MEDIUM = Enum.Font.BuilderSansMedium
local FONT_BOLD = Enum.Font.BuilderSansBold
local FONT_EXTRA_BOLD = Enum.Font.BuilderSansExtraBold
local FONT_MONO = Enum.Font.RobotoMono
local FONT_DIGITS = Enum.Font.RobotoMono -- odometer wheels and digital readouts
local FONT_LOGO = Enum.Font.Michroma -- "SPACE DISASTERS INC." wordmark
-- Text sizes (design px)
local TEXT_TINY = 10
local TEXT_SMALL = 12
local TEXT_BODY = 14
local TEXT_BUTTON = 15
local TEXT_LARGE = 18
local TEXT_TITLE = 20
local TEXT_HUGE = 32
local TEXT_LOGO = 44
-- Corner radii (px)
local RADIUS_PANEL = 6
local RADIUS_BUTTON = 4
local RADIUS_SMALL = 3
-- Paddings (px)
local PAD_TINY = 2
local PAD_SMALL = 4
local PAD_MEDIUM = 8
local PAD_LARGE = 12
local PAD_HUGE = 20
local PAD_PANEL = 12 -- inside a panel
local PAD_GAP = 6 -- between list items
-- Strokes (px)
local STROKE_THIN = 1
local STROKE_MEDIUM = 2
local STROKE_THICK = 3
-- Widget sizes (design px)
local SIZE_BUTTON = 32 -- full-width dialog buttons
local SIZE_BUTTON_SMALL = 26 -- buttons inside rows (key buttons, segments)
local SIZE_ROW = 32 -- one settings control row
local SIZE_TITLE = 28 -- panel title line
local SIZE_TAB = 30
local SIZE_SECTION = 26 -- section header line
local SIZE_SLIDER_TRACK = 6
local SIZE_SLIDER_KNOB = 16
local SIZE_TOGGLE_WIDTH = 42
local SIZE_TOGGLE_HEIGHT = 22
local SIZE_SEGMENT = 92 -- one choice segment's width
local SIZE_KEY_BUTTON = 120 -- key rebinding button width
local SIZE_SCROLL_BAR = 6
local SIZE_KEYCAP = 18 -- keycap badge height
local SIZE_TOAST = 380 -- toast width
local SIZE_TOAST_TOP = 116 -- toasts start this far from the top (below the altimeter)
local BEZEL_FRACTION = 0.08 -- a gauge bezel's metal ring, per side, as a fraction of its diameter
-- Tween times (s)
local TWEEN_FAST = 0.08
local TWEEN_NORMAL = 0.15
local TWEEN_FADE = 0.35
local TWEEN_SLOW = 0.6
-- ScreenGui.DisplayOrder (Map = MapViewController's overlay and Debug = DebugOverlay, both existing)
local ORDER_BUILDER = 1
local ORDER_MAP = 9
local ORDER_HUD = 10
local ORDER_MENU = 20
local ORDER_SETTINGS = 30
local ORDER_DIALOG = 40
local ORDER_TOAST = 50
local ORDER_DEBUG = 1000
-- Design canvas (BuildUI / FlightHUD use the same 1366 x 710 canvas)
local CANVAS_WIDTH = 1366
local CANVAS_HEIGHT = 710
local CANVAS_MIN_FIT = 0.6
local CANVAS_MAX_FIT = 1.6
--============================================================================

local Theme = {
	Colors = table.freeze({
		Panel = PANEL,
		PanelStroke = PANEL_STROKE,
		PanelInset = PANEL_INSET,
		PanelRaised = PANEL_RAISED,
		Title = TITLE,
		Text = TEXT,
		TextDim = TEXT_DIM,
		Button = BUTTON,
		ButtonHover = BUTTON_HOVER,
		ButtonPressed = BUTTON_PRESSED,
		ButtonText = BUTTON_TEXT,
		ButtonShade = BUTTON_SHADE,
		ButtonStroke = BUTTON_STROKE,
		ButtonDisabled = BUTTON_DISABLED,
		ButtonDisabledText = BUTTON_DISABLED_TEXT,
		Ghost = GHOST,
		GhostHover = GHOST_HOVER,
		GhostPressed = GHOST_PRESSED,
		Accent = ACCENT,
		AccentHover = ACCENT_HOVER,
		AccentDark = ACCENT_DARK,
		Warning = WARNING,
		Danger = DANGER,
		DangerHover = DANGER_HOVER,
		DangerDark = DANGER_DARK,
		GaugeMetal = GAUGE_METAL,
		GaugeMetalDark = GAUGE_METAL_DARK,
		GaugeMetalLight = GAUGE_METAL_LIGHT,
		GaugeFace = GAUGE_FACE,
		DigitWheel = DIGIT_WHEEL,
		DigitText = DIGIT_TEXT,
		DigitalGreen = DIGITAL_GREEN,
		NavSky = NAV_SKY,
		NavGround = NAV_GROUND,
		Track = TRACK,
		Backdrop = BACKDROP,
	}),
	Transparency = table.freeze({
		Panel = PANEL_TRANSPARENCY,
		Inset = INSET_TRANSPARENCY,
		Backdrop = BACKDROP_TRANSPARENCY,
		Plate = PLATE_TRANSPARENCY,
	}),
	Fonts = table.freeze({
		Title = FONT_TITLE,
		Body = FONT_BODY,
		Medium = FONT_MEDIUM,
		Bold = FONT_BOLD,
		ExtraBold = FONT_EXTRA_BOLD,
		Mono = FONT_MONO,
		Digits = FONT_DIGITS,
		Logo = FONT_LOGO,
	}),
	TextSizes = table.freeze({
		Tiny = TEXT_TINY,
		Small = TEXT_SMALL,
		Body = TEXT_BODY,
		Button = TEXT_BUTTON,
		Large = TEXT_LARGE,
		Title = TEXT_TITLE,
		Huge = TEXT_HUGE,
		Logo = TEXT_LOGO,
	}),
	Radius = table.freeze({
		Panel = RADIUS_PANEL,
		Button = RADIUS_BUTTON,
		Small = RADIUS_SMALL,
	}),
	Padding = table.freeze({
		Tiny = PAD_TINY,
		Small = PAD_SMALL,
		Medium = PAD_MEDIUM,
		Large = PAD_LARGE,
		Huge = PAD_HUGE,
		Panel = PAD_PANEL,
		Gap = PAD_GAP,
	}),
	Stroke = table.freeze({
		Thin = STROKE_THIN,
		Medium = STROKE_MEDIUM,
		Thick = STROKE_THICK,
	}),
	Sizes = table.freeze({
		Button = SIZE_BUTTON,
		ButtonSmall = SIZE_BUTTON_SMALL,
		Row = SIZE_ROW,
		Title = SIZE_TITLE,
		Tab = SIZE_TAB,
		Section = SIZE_SECTION,
		SliderTrack = SIZE_SLIDER_TRACK,
		SliderKnob = SIZE_SLIDER_KNOB,
		ToggleWidth = SIZE_TOGGLE_WIDTH,
		ToggleHeight = SIZE_TOGGLE_HEIGHT,
		Segment = SIZE_SEGMENT,
		KeyButton = SIZE_KEY_BUTTON,
		ScrollBar = SIZE_SCROLL_BAR,
		Keycap = SIZE_KEYCAP,
		Toast = SIZE_TOAST,
		ToastTop = SIZE_TOAST_TOP,
		BezelFraction = BEZEL_FRACTION,
	}),
	Tween = table.freeze({
		Fast = TWEEN_FAST,
		Normal = TWEEN_NORMAL,
		Fade = TWEEN_FADE,
		Slow = TWEEN_SLOW,
	}),
	DisplayOrder = table.freeze({
		Builder = ORDER_BUILDER,
		Map = ORDER_MAP,
		HUD = ORDER_HUD,
		Menu = ORDER_MENU,
		Settings = ORDER_SETTINGS,
		Dialog = ORDER_DIALOG,
		Toast = ORDER_TOAST,
		Debug = ORDER_DEBUG,
	}),
	Canvas = table.freeze({
		Width = CANVAS_WIDTH,
		Height = CANVAS_HEIGHT,
		MinFit = CANVAS_MIN_FIT,
		MaxFit = CANVAS_MAX_FIT,
	}),
}

return table.freeze(Theme)
