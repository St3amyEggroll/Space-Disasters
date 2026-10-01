--!strict
-- Tests for UI/Theme (Phase 11): every token group exists, is frozen and holds sane values, and the ScreenGui display
-- orders stack Builder < Map < HUD < Menu < Settings < Dialog < Toast < Debug.

local TestKit = require(script.Parent.TestKit)
local Theme = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.UI.Theme)

--============================================================================
-- Tunables
--============================================================================
local COLOR_TOKENS = {
	"Panel",
	"PanelStroke",
	"PanelInset",
	"PanelRaised",
	"Title",
	"Text",
	"TextDim",
	"Button",
	"ButtonHover",
	"ButtonPressed",
	"ButtonText",
	"ButtonShade",
	"ButtonStroke",
	"ButtonDisabled",
	"ButtonDisabledText",
	"Ghost",
	"GhostHover",
	"GhostPressed",
	"Accent",
	"AccentHover",
	"AccentDark",
	"Warning",
	"Danger",
	"DangerHover",
	"DangerDark",
	"GaugeMetal",
	"GaugeMetalDark",
	"GaugeMetalLight",
	"GaugeFace",
	"DigitWheel",
	"DigitText",
	"DigitalGreen",
	"NavSky",
	"NavGround",
	"Track",
	"Backdrop",
}
local DISPLAY_ORDER = { "Builder", "Map", "HUD", "Menu", "Settings", "Dialog", "Toast", "Debug" }
local GROUPS = {
	"Colors",
	"Transparency",
	"Fonts",
	"TextSizes",
	"Radius",
	"Padding",
	"Stroke",
	"Sizes",
	"Tween",
	"DisplayOrder",
	"Canvas",
}
local MIN_CONTRAST = 0.35 -- brightness gap between a button and its text
--============================================================================

local function brightness(color: Color3): number
	return 0.299 * color.R + 0.587 * color.G + 0.114 * color.B
end

return function(t: TestKit.Context)
	local theme = Theme :: any

	t.test("every group exists and is frozen", function()
		t.expectTrue(table.isfrozen(theme), "Theme")
		for _, group in GROUPS do
			t.expectTrue(type(theme[group]) == "table", group)
			t.expectTrue(table.isfrozen(theme[group]), group .. " frozen")
		end
	end)

	t.test("every colour token is a Color3", function()
		for _, name in COLOR_TOKENS do
			t.expectEqual(typeof(theme.Colors[name]), "Color3", name)
		end
		for name, value in theme.Colors do
			t.expectTrue(table.find(COLOR_TOKENS, name) ~= nil, `untested colour {name}`)
			t.expectEqual(typeof(value), "Color3", name)
		end
	end)

	t.test("the KSP pause dialog colours", function()
		local function hex(color: Color3): string
			return string.format(
				"%02X%02X%02X",
				math.round(color.R * 255),
				math.round(color.G * 255),
				math.round(color.B * 255)
			)
		end
		t.expectEqual(hex(Theme.Colors.Panel), "1E2226")
		t.expectEqual(hex(Theme.Colors.Title), "A6D64A")
		t.expectEqual(hex(Theme.Colors.Button), "C8CCD0")
		t.expectEqual(hex(Theme.Colors.ButtonText), "1C1F22")
		t.expectNear(Theme.Transparency.Panel, 0.15, 0.05)
	end)

	t.test("buttons keep readable contrast", function()
		local c = Theme.Colors
		t.expectTrue(brightness(c.Button) - brightness(c.ButtonText) > MIN_CONTRAST, "Primary")
		t.expectTrue(brightness(c.Accent) - brightness(c.ButtonText) > MIN_CONTRAST, "Accent")
		t.expectTrue(brightness(c.Text) - brightness(c.Ghost) > MIN_CONTRAST, "Ghost")
		t.expectTrue(brightness(c.Text) - brightness(c.Danger) > 0, "Danger")
		t.expectTrue(brightness(c.ButtonHover) > brightness(c.Button), "hover is lighter")
		t.expectTrue(brightness(c.ButtonPressed) < brightness(c.Button), "pressed is darker")
	end)

	t.test("transparencies are within 0..1", function()
		for name, value in theme.Transparency do
			t.expectTrue(type(value) == "number" and value >= 0 and value <= 1, name)
		end
	end)

	t.test("fonts are Enum.Font items", function()
		for name, value in theme.Fonts do
			t.expectEqual(typeof(value), "EnumItem", name)
		end
	end)

	t.test("sizes, paddings, radii, strokes and tweens are positive numbers", function()
		for _, group in { "TextSizes", "Radius", "Padding", "Stroke", "Sizes", "Tween", "Canvas" } do
			for name, value in theme[group] do
				t.expectTrue(type(value) == "number" and value > 0, `{group}.{name}`)
			end
		end
		t.expectTrue(Theme.Sizes.BezelFraction < 0.5, "a bezel ring leaves a face")
		t.expectTrue(Theme.Canvas.MinFit <= 1 and Theme.Canvas.MaxFit >= 1, "fit clamp contains 1")
	end)

	t.test("text sizes grow from Tiny to Logo", function()
		local s = Theme.TextSizes
		local order = { s.Tiny, s.Small, s.Body, s.Button, s.Large, s.Title, s.Huge, s.Logo }
		for i = 2, #order do
			t.expectTrue(order[i] > order[i - 1], `text size {i}`)
		end
	end)

	t.test("display orders stack every screen correctly", function()
		for i, name in DISPLAY_ORDER do
			t.expectTrue(type(theme.DisplayOrder[name]) == "number", name)
			if i > 1 then
				local below = DISPLAY_ORDER[i - 1]
				t.expectTrue(theme.DisplayOrder[name] > theme.DisplayOrder[below], `{below} < {name}`)
			end
		end
	end)
end
