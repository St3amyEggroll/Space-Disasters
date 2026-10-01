--!strict
--[[
	FlightHUD
	The flight HUD (spec 7.11). CHANGED (Phase 11): rebuilt in the Kerbal Space Program 1.x layout with UI/Kit and
	UI/Theme (the earlier BuildUI-styled cluster is gone; every piece of information it showed is still here):
	  * TOP CENTRE   the ALTIMETER: odometer digit wheels on a gunmetal plate (the last wheel rolls smoothly, higher
	                 wheels roll only while the lower ones pass 9 -> 0) with the unit (m / km / ft / mi, from the
	                 units setting), a SEA LVL / RADAR switch (click) and the SOI body's name; an ATMOSPHERE depth bar
	                 under it (air pressure: full at sea level, empty in vacuum); beside it a small VERTICAL SPEED
	                 needle gauge (log scaled, up / down) with the value under it
	  * BOTTOM CENTRE the NAVBALL (UI/Navball) in a round gunmetal bezel; above it the SPEED plate ("Surface" /
	                 "Orbit", picked by altitude like KSP, click to switch; green digital speed); on the bezel's left
	                 the SAS button (lit green while SAS is on; click = callbacks.onToggleSAS, pilot only) and a
	                 curved THROTTLE arc of segments lit amber up to the throttle; under the ball "HDG 017°" with the
	                 pitch; right of the bezel an Ap / Pe plate (altitude and time to each) while they are known.
	                 The navball shows "ON RAILS" while the craft coasts on rails.
	  * RIGHT        the STAGE STACK: craft name and role (Pilot / Passenger), one card per remaining stage, the
	                 next stage at the bottom with a green border (number, delta-v, fuel bar); total delta-v and TWR
	                 under it, and a "Stage: <key>" hint
	  * BOTTOM LEFT  vertical THROTTLE and FUEL gauges (fuel = the stage that is burning or fires next) and the
	                 status lamps SAS, LEGS (landing legs deployed) and ENGINES (burning)
	  * TOP RIGHT    "Settings" (UI/SettingsPanel) and "End Flight" (callbacks.onEndFlight; it asks first). Anyone
	                 aboard who is neither the pilot nor the craft's owner sees "Leave Flight" instead.
	  * banners      "PRESS <Stage key> TO LAUNCH" (pilot) / "Waiting for the pilot..." (passenger) on the pad and a big
	                 countdown number while the launch countdown runs
	  * key hints    (Settings hints on) a small card above the gauges, the SAS key beside the SAS button and the
	                 stage key under the stack, all built from Keybinds labels, so a rebind updates them at once
	  * a HINT pill above the navball (setHint); it lives outside the HUD root, so it also shows while the HUD is
	    hidden

	Visibility: the whole HUD hides with Settings hudVisible = false (the ToggleHUD key flips it), and the ScreenGui is
	disabled while the main menu is open (UIState). The map view (MapViewController) keeps the HUD up.

	Pure view: update(data) renders a HudData snapshot (nil hides the HUD). It is called every frame, so it only
	writes properties, and only when a value actually changed (a per-property cache); every instance, including a
	fixed pool of stage cards, is created once in create(). The panels do not sink input (Active = false), so the
	pilot can still drag the right mouse button almost anywhere to orbit the chase camera; only the buttons do.

	Layout: design pixels on the Kit canvas (Theme.Canvas, scaled to the screen and the "UI size" setting), anchored
	to the screen's edges and centre, so it survives other aspect ratios. The top-right buttons stay below the Roblox
	top bar (GuiService.TopbarInset).

	API:
	  FlightHUD.create(callbacks: { onEndFlight: () -> (), onToggleSAS: () -> () }) -> FlightHUD
	  hud.update(data: HudData?)     call every frame; nil hides the HUD
	  hud.setHint(text: string?)     nil hides the hint
]]

local GuiService = game:GetService("GuiService")

local HudData = require(script.Parent.Parent.Render.HudData)
local Format = require(script.Parent.Format)
local HudMath = require(script.Parent.HudMath)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local Kit = require(script.Parent.Kit)
local Navball = require(script.Parent.Navball)
local Settings = require(script.Parent.Parent.Settings.Settings)
local SettingsPanel = require(script.Parent.SettingsPanel)
local Theme = require(script.Parent.Theme)
local UIState = require(script.Parent.UIState)

--============================================================================
-- Tunables
--============================================================================
local GUI_NAME = "FlightHUD"
local MARGIN = 12 -- S, from the screen edges
-- Altimeter (top centre)
local ALTIMETER_TOP = 6
local WHEEL_COUNT = 6
local WHEEL_WIDTH = 20
local WHEEL_HEIGHT = 30
local WHEEL_GAP = 2
local WHEEL_TEXT_SIZE = 22
local WHEEL_QUANTUM = 60 -- wheel positions are rounded to 1/this of a digit (fewer property writes)
local WHEEL_SHADE = 0.35 -- transparency of the dark shading at a wheel's top and bottom edge
local PLATE_PADDING = 7
local SIGN_WIDTH = 10
local UNIT_WIDTH = 30
local ALTIMETER_ROW = 16 -- the SEA LVL / RADAR switch and body name row
local MODE_BUTTON_WIDTH = 58
local ATMOSPHERE_HEIGHT = 20
local ATMOSPHERE_LABEL_WIDTH = 74
local ATMOSPHERE_VALUE_WIDTH = 44
local PLATE_GAP = 4
-- Vertical speed gauge (right of the altimeter)
local VSI_SIZE = 64
local VSI_GAP = 8
local VSI_MAX = 2000 -- m/s at full deflection (log scale)
local VSI_SWEEP = 150 -- degrees the needle swings each way from 9 o'clock (0 m/s)
local VSI_TICKS = { 0, 10, 100, 1000 } -- m/s, mirrored up and down
local VSI_ANGLE_QUANTUM = 0.5 -- degrees
local VS_DEADBAND = 0.05 -- m/s; below this the vertical speed reads as neutral 0
-- Navball cluster (bottom centre)
local NAV_BOTTOM = 4
local BEZEL_SIZE = 172
local SPEED_PLATE_SIZE = Vector2.new(148, 40)
local SPEED_TEXT_SIZE = 20
local SAS_SIZE = Vector2.new(46, 24)
local SAS_ANGLE = 218 -- degrees, screen angle (clockwise from +X, y down) of the SAS button around the bezel
local SAS_RADIUS = BEZEL_SIZE / 2 + 28
local ARC_SEGMENTS = 20
local ARC_START = 120 -- degrees (lower left), throttle zero
local ARC_END = 200 -- degrees (just above left), full throttle
local ARC_RADIUS = BEZEL_SIZE / 2 + 9 -- centre of the segments
local ARC_SEGMENT_SIZE = Vector2.new(10, 4) -- radial length x tangential width
local HEADING_SIZE = Vector2.new(124, 16)
local APSIS_SIZE = Vector2.new(150, 70)
local APSIS_GAP = 14
-- Stage stack (right)
local STAGE_WIDTH = 196
local STAGE_CARD_HEIGHT = 38
local MAX_STAGE_CARDS = 5 -- more stages collapse into "+N more"
local STAGE_BADGE = 26
local LOW_FUEL = 0.2 -- fuel bars turn red below this fraction
-- Gauges and lamps (bottom left)
local GAUGES_SIZE = Vector2.new(204, 132)
local GAUGE_COLUMN = 36
local LAMP_HEIGHT = 30
-- Top right buttons
local TOP_BUTTON_HEIGHT = 28
local SETTINGS_BUTTON_WIDTH = 92
local END_BUTTON_WIDTH = 112
-- Banners
local BANNER_Y = 170 -- S, below the altimeter and the toasts' first line
local BANNER_HEIGHT = 40
local COUNTDOWN_SIZE = 84
local COUNTDOWN_PULSE = 0.3 -- extra scale of the countdown number right after it ticks
local BANNER_PULSE_SPEED = 4 -- rad/s of the "press space" outline pulse
-- Hint pill
local HINT_HEIGHT = 30
-- Text
local NOT_AVAILABLE = "--"
local DV = "dV" -- delta-v label (ASCII: Roblox fonts may lack a delta glyph)
local DEGREE = "°"
--============================================================================

export type Callbacks = {
	onEndFlight: () -> (),
	onToggleSAS: () -> (),
}

export type FlightHUD = {
	update: (data: HudData.HudData?) -> (), -- nil hides the HUD; call every frame
	setHint: (text: string?) -> (), -- nil hides the hint
}

type StageCard = {
	frame: Frame,
	stroke: UIStroke,
	badge: Frame,
	badgeText: TextLabel,
	dv: TextLabel,
	fuelText: TextLabel,
	fuel: Kit.Bar,
}

type Lamp = { frame: Frame, stroke: UIStroke, text: TextLabel, litColor: Color3 }

local FlightHUD = {}

--============================================================================
-- Small builders (HUD only: nothing here sinks input except buttons)
--============================================================================
local new = Kit.new

local function passive<T>(instance: T): T
	(instance :: any).Active = false
	return instance
end

local function text(parent: Instance, props: { [string]: any }): TextLabel
	local label: TextLabel = new("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = false,
		Font = Theme.Fonts.Bold,
		TextSize = Theme.TextSizes.Small,
		TextColor3 = Theme.Colors.Text,
		Text = "",
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Size = UDim2.new(1, 0, 0, 16),
	}, nil)
	for key, value in props do
		(label :: any)[key] = value
	end
	label.Parent = parent
	return label
end

local function richEscape(s: string): string
	return (string.gsub(string.gsub(string.gsub(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
end

local function colorHex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.floor(color.R * 255 + 0.5),
		math.floor(color.G * 255 + 0.5),
		math.floor(color.B * 255 + 0.5)
	)
end

-- A key name in hint text (RichText).
local function keyText(action: string): string
	return `<font color="{colorHex(Theme.Colors.Title)}"><b>{richEscape(Keybinds.label(action))}</b></font>`
end

local function quantize(value: number, steps: number): number
	return math.floor(value * steps + 0.5) / steps
end

--============================================================================
-- Create
--============================================================================
function FlightHUD.create(callbacks: Callbacks): FlightHUD
	local screen, canvas = Kit.screen(GUI_NAME, Theme.DisplayOrder.HUD)
	screen.Enabled = not UIState.isMenuOpen()
	UIState.onMenuChanged(function(open: boolean)
		screen.Enabled = not open
	end)

	local root = Kit.frame(canvas, { name = "HUD" })
	root.Visible = false

	-- Per-property write cache: update() runs every frame, so only write what changed.
	local written: { [Instance]: { [string]: any } } = {}
	local function set(instance: Instance, property: string, value: any)
		local props = written[instance]
		if not props then
			props = {}
			written[instance] = props
		end
		if props[property] ~= value then
			props[property] = value;
			(instance :: any)[property] = value
		end
	end

	local function plate(parent: Instance, size: Vector2, position: UDim2, anchor: Vector2): Frame
		return passive(Kit.plate(parent, UDim2.fromOffset(size.X, size.Y), position, anchor))
	end

	local function hudPanel(parent: Instance, name: string, size: UDim2, position: UDim2, anchor: Vector2): Frame
		return passive(Kit.panel({
			parent = parent,
			name = name,
			size = size,
			position = position,
			anchor = anchor,
			padding = Theme.Padding.Medium,
		}))
	end

	-- Changes the padding Kit.panel gave a panel (a second UIPadding would be ignored).
	local function panelPadding(panel: Frame, vertical: number, horizontal: number)
		local pad = panel:FindFirstChildOfClass("UIPadding")
		if pad then
			pad.PaddingTop = UDim.new(0, vertical)
			pad.PaddingBottom = UDim.new(0, vertical)
			pad.PaddingLeft = UDim.new(0, horizontal)
			pad.PaddingRight = UDim.new(0, horizontal)
		end
	end

	--========================================================================
	-- Top centre: altimeter
	--========================================================================
	local wheelsWidth = WHEEL_COUNT * WHEEL_WIDTH + (WHEEL_COUNT - 1) * WHEEL_GAP
	local altimeterWidth = PLATE_PADDING * 2 + SIGN_WIDTH + wheelsWidth + PLATE_GAP + UNIT_WIDTH
	local altimeterHeight = PLATE_PADDING * 2 + WHEEL_HEIGHT + PLATE_GAP + ALTIMETER_ROW
	local altimeter = Kit.frame(root, {
		name = "Altimeter",
		size = UDim2.fromOffset(altimeterWidth, altimeterHeight + PLATE_GAP + ATMOSPHERE_HEIGHT),
		position = UDim2.new(0.5, 0, 0, ALTIMETER_TOP),
		anchor = Vector2.new(0.5, 0),
	})
	local altPlate = plate(altimeter, Vector2.new(altimeterWidth, altimeterHeight), UDim2.new(), Vector2.zero)
	local signText = text(altPlate, {
		Position = UDim2.fromOffset(PLATE_PADDING, PLATE_PADDING),
		Size = UDim2.fromOffset(SIGN_WIDTH, WHEEL_HEIGHT),
		Font = Theme.Fonts.Digits,
		TextSize = WHEEL_TEXT_SIZE,
		TextColor3 = Theme.Colors.DigitText,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
	})
	local strips: { Frame } = {}
	for index = 1, WHEEL_COUNT do
		local window: Frame = new("Frame", {
			Name = "Wheel" .. index,
			Position = UDim2.fromOffset(
				PLATE_PADDING + SIGN_WIDTH + (index - 1) * (WHEEL_WIDTH + WHEEL_GAP),
				PLATE_PADDING
			),
			Size = UDim2.fromOffset(WHEEL_WIDTH, WHEEL_HEIGHT),
			BackgroundColor3 = Theme.Colors.DigitWheel,
			BorderSizePixel = 0,
			ClipsDescendants = true,
			Active = false,
		}, altPlate)
		Kit.corner(window, Theme.Radius.Small)
		-- the 0-9-0 strip: eleven digits, each one window high; Position.Y = -wheel position (in window heights)
		local strip: Frame = new("Frame", {
			Name = "Strip",
			Size = UDim2.fromScale(1, 11),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Active = false,
		}, window)
		for digit = 0, 10 do
			text(strip, {
				Position = UDim2.fromScale(0, digit / 11),
				Size = UDim2.fromScale(1, 1 / 11),
				Font = Theme.Fonts.Digits,
				TextSize = WHEEL_TEXT_SIZE,
				TextColor3 = Theme.Colors.DigitText,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextTruncate = Enum.TextTruncate.None,
				Text = tostring(digit % 10),
			})
		end
		-- the drum's curvature: darker towards its top and bottom edges
		local shade: Frame = new("Frame", {
			Name = "Shade",
			Size = UDim2.fromScale(1, 1),
			BackgroundColor3 = Theme.Colors.Backdrop,
			BorderSizePixel = 0,
			Active = false,
			ZIndex = 2,
		}, window)
		new("UIGradient", {
			Rotation = 90,
			Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, WHEEL_SHADE),
				NumberSequenceKeypoint.new(0.3, 1),
				NumberSequenceKeypoint.new(0.7, 1),
				NumberSequenceKeypoint.new(1, WHEEL_SHADE),
			}),
		}, shade)
		strips[index] = strip
	end
	local unitText = text(altPlate, {
		Position = UDim2.fromOffset(PLATE_PADDING + SIGN_WIDTH + wheelsWidth + PLATE_GAP, PLATE_PADDING),
		Size = UDim2.fromOffset(UNIT_WIDTH, WHEEL_HEIGHT),
		Font = Theme.Fonts.Digits,
		TextSize = Theme.TextSizes.Large,
		TextColor3 = Theme.Colors.DigitText,
		Text = "m",
	})

	local radarMode = false -- false: altitude above sea level; true: above the ground under the craft
	local modeButton: TextButton
	modeButton = Kit.button(altPlate, "SEA LVL", function()
		radarMode = not radarMode
		modeButton.Text = if radarMode then "RADAR" else "SEA LVL"
	end, {
		name = "AltitudeMode",
		style = "Ghost",
		size = UDim2.fromOffset(MODE_BUTTON_WIDTH, ALTIMETER_ROW),
		position = UDim2.fromOffset(PLATE_PADDING, PLATE_PADDING + WHEEL_HEIGHT + PLATE_GAP),
		textSize = Theme.TextSizes.Tiny,
	})
	local bodyText = text(altPlate, {
		Position = UDim2.fromOffset(
			PLATE_PADDING + MODE_BUTTON_WIDTH + PLATE_GAP,
			PLATE_PADDING + WHEEL_HEIGHT + PLATE_GAP
		),
		Size = UDim2.new(1, -(PLATE_PADDING * 2 + MODE_BUTTON_WIDTH + PLATE_GAP), 0, ALTIMETER_ROW),
		TextSize = Theme.TextSizes.Small,
		TextColor3 = Theme.Colors.Title,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	-- Atmosphere depth bar
	local atmoPlate = plate(
		altimeter,
		Vector2.new(altimeterWidth, ATMOSPHERE_HEIGHT),
		UDim2.fromOffset(0, altimeterHeight + PLATE_GAP),
		Vector2.zero
	)
	text(atmoPlate, {
		Position = UDim2.fromOffset(PLATE_PADDING, 0),
		Size = UDim2.new(0, ATMOSPHERE_LABEL_WIDTH, 1, 0),
		TextSize = Theme.TextSizes.Tiny,
		TextColor3 = Theme.Colors.TextDim,
		Text = "ATMOSPHERE",
	})
	local atmoBar = Kit.bar(atmoPlate, {
		name = "Atmosphere",
		size = UDim2.new(1, -(PLATE_PADDING * 2 + ATMOSPHERE_LABEL_WIDTH + ATMOSPHERE_VALUE_WIDTH + PLATE_GAP), 0, 8),
		position = UDim2.new(0, PLATE_PADDING + ATMOSPHERE_LABEL_WIDTH, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		color = Theme.Colors.NavSky,
	})
	local atmoText = text(atmoPlate, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -PLATE_PADDING, 0, 0),
		Size = UDim2.new(0, ATMOSPHERE_VALUE_WIDTH, 1, 0),
		TextSize = Theme.TextSizes.Tiny,
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	-- Vertical speed needle gauge
	local vsiBezel, vsiFace = Kit.gaugeBezel(
		altimeter,
		UDim2.fromOffset(VSI_SIZE, VSI_SIZE),
		UDim2.new(1, VSI_GAP, 0, altimeterHeight / 2),
		Vector2.new(0, 0.5)
	)
	passive(vsiBezel)
	passive(vsiFace)
	-- A needle-shaped frame through the face's centre: the visible arm is its right half; Rotation turns it.
	local function radial(
		parent: Instance,
		angle: number,
		inner: number,
		width: number,
		color: Color3,
		z: number
	): Frame
		local holder: Frame = new("Frame", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.new(1, 0, 0, width),
			BackgroundTransparency = 1,
			BorderSizePixel = 0,
			Active = false,
			Rotation = angle,
			ZIndex = z,
		}, parent)
		new("Frame", {
			Position = UDim2.fromScale(0.5 + inner / 2, 0),
			Size = UDim2.fromScale(0.5 - inner / 2, 1),
			BackgroundColor3 = color,
			BorderSizePixel = 0,
			Active = false,
			ZIndex = z,
		}, holder)
		return holder
	end
	for _, tick in VSI_TICKS do
		local f = HudMath.verticalSpeedFraction(tick, VSI_MAX)
		radial(vsiFace, 180 + VSI_SWEEP * f, 0.78, 1, Theme.Colors.GaugeMetalLight, 1)
		if tick ~= 0 then
			radial(vsiFace, 180 - VSI_SWEEP * f, 0.78, 1, Theme.Colors.GaugeMetalLight, 1)
		end
	end
	text(vsiFace, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.24),
		Size = UDim2.fromOffset(16, 12),
		TextSize = Theme.TextSizes.Tiny,
		TextColor3 = Theme.Colors.Accent,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "+",
	})
	text(vsiFace, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.76),
		Size = UDim2.fromOffset(16, 12),
		TextSize = Theme.TextSizes.Tiny,
		TextColor3 = Theme.Colors.Danger,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "-",
	})
	text(vsiFace, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.72, 0.5),
		Size = UDim2.fromOffset(20, 12),
		TextSize = Theme.TextSizes.Tiny,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "VS",
	})
	local needle = radial(vsiFace, 180, 0, 2, Theme.Colors.DigitText, 3)
	local hub: Frame = new("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(7, 7),
		BackgroundColor3 = Theme.Colors.GaugeMetalLight,
		BorderSizePixel = 0,
		Active = false,
		ZIndex = 4,
	}, vsiFace)
	Kit.round(hub)
	local vsText = text(altimeter, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(1, VSI_GAP + VSI_SIZE / 2, 0, altimeterHeight / 2 + VSI_SIZE / 2 + 2),
		Size = UDim2.fromOffset(VSI_SIZE + 40, 14),
		Font = Theme.Fonts.Digits,
		TextSize = Theme.TextSizes.Small,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextStrokeTransparency = 0.5,
	})

	--========================================================================
	-- Bottom centre: navball cluster
	--========================================================================
	local nav = Kit.frame(root, {
		name = "NavCluster",
		size = UDim2.fromOffset(BEZEL_SIZE, BEZEL_SIZE),
		position = UDim2.new(0.5, 0, 1, -NAV_BOTTOM),
		anchor = Vector2.new(0.5, 1),
	})
	local bezel, face = Kit.gaugeBezel(nav, UDim2.fromScale(1, 1))
	passive(bezel)
	passive(face)
	local ballSize = math.floor(BEZEL_SIZE * (1 - Theme.Sizes.BezelFraction * 2))
	local navball = Navball.create(face, ballSize)

	-- Speed plate (above the bezel); clicking its mode line switches Surface / Orbit
	local speedPlate = plate(nav, SPEED_PLATE_SIZE, UDim2.new(0.5, 0, 0, -PLATE_GAP), Vector2.new(0.5, 1))
	local speedOverride: boolean? = nil -- nil = automatic (by altitude); true = Orbit, false = Surface
	local lastAutoOrbit: boolean? = nil
	local showingOrbit = false
	local speedModeButton: TextButton = new("TextButton", {
		Name = "SpeedMode",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, 15),
		Position = UDim2.fromOffset(0, 2),
		Font = Theme.Fonts.Bold,
		TextSize = Theme.TextSizes.Small,
		TextColor3 = Theme.Colors.Text,
		Text = "Surface",
	}, speedPlate)
	speedModeButton.Activated:Connect(function()
		speedOverride = not showingOrbit
	end)
	speedModeButton.MouseEnter:Connect(function()
		speedModeButton.TextColor3 = Theme.Colors.Title
	end)
	speedModeButton.MouseLeave:Connect(function()
		speedModeButton.TextColor3 = Theme.Colors.Text
	end)
	local speedText = text(speedPlate, {
		Position = UDim2.fromOffset(0, 16),
		Size = UDim2.new(1, 0, 0, 22),
		Font = Theme.Fonts.Digits,
		TextSize = SPEED_TEXT_SIZE,
		TextColor3 = Theme.Colors.DigitalGreen,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "0.0 m/s",
	})

	-- Throttle arc along the bezel's left side
	local arcSegments: { Frame } = {}
	for index = 1, ARC_SEGMENTS do
		local angle = HudMath.arcAngle(index, ARC_SEGMENTS, ARC_START, ARC_END)
		local x, y = HudMath.arcPoint(angle, ARC_RADIUS)
		local segment: Frame = new("Frame", {
			Name = "Throttle" .. index,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, x, 0.5, y),
			Size = UDim2.fromOffset(ARC_SEGMENT_SIZE.X, ARC_SEGMENT_SIZE.Y),
			Rotation = angle,
			BackgroundColor3 = Theme.Colors.GaugeMetalDark,
			BorderSizePixel = 0,
			Active = false,
		}, nav)
		Kit.corner(segment, 1)
		Kit.stroke(segment, Theme.Colors.GaugeFace, Theme.Stroke.Thin, 0.3)
		arcSegments[index] = segment
	end

	-- SAS button on the bezel's left
	local sasX, sasY = HudMath.arcPoint(SAS_ANGLE, SAS_RADIUS)
	local isPilotNow = false -- from the last update: only the pilot's clicks toggle SAS
	local sasButton = Kit.button(nav, "SAS", function()
		if isPilotNow then
			callbacks.onToggleSAS()
		end
	end, {
		name = "SAS",
		style = "Ghost",
		size = UDim2.fromOffset(SAS_SIZE.X, SAS_SIZE.Y),
		position = UDim2.new(0.5, sasX, 0.5, sasY),
		anchor = Vector2.new(0.5, 0.5),
		textSize = Theme.TextSizes.Small,
	})
	local sasStyle: Kit.ButtonStyle = "Ghost"
	local sasKey = Kit.keycap(nav, "T", {
		position = UDim2.new(0.5, sasX - SAS_SIZE.X / 2 - Theme.Padding.Small, 0.5, sasY),
		anchor = Vector2.new(1, 0.5),
	})
	sasKey.Visible = false

	-- Heading box under the ball
	local headingPlate = plate(nav, HEADING_SIZE, UDim2.new(0.5, 0, 1, -6), Vector2.new(0.5, 1))
	headingPlate.ZIndex = 2
	local headingText = text(headingPlate, {
		Size = UDim2.fromScale(1, 1),
		Font = Theme.Fonts.Digits,
		TextSize = Theme.TextSizes.Tiny + 1,
		TextColor3 = Theme.Colors.DigitText,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 2,
	})

	-- Ap / Pe plate right of the bezel
	local apsisPlate = plate(nav, APSIS_SIZE, UDim2.new(1, APSIS_GAP, 0.5, 0), Vector2.new(0, 0.5))
	Kit.padding(apsisPlate, Theme.Padding.Small)
	local function apsisRow(row: number, caption: string, captionColor: Color3): TextLabel
		local y = (row - 1) * 15 + 1
		text(apsisPlate, {
			Position = UDim2.fromOffset(2, y),
			Size = UDim2.new(0, 34, 0, 15),
			TextSize = Theme.TextSizes.Small,
			TextColor3 = captionColor,
			Text = caption,
		})
		return text(apsisPlate, {
			Position = UDim2.fromOffset(36, y),
			Size = UDim2.new(1, -38, 0, 15),
			Font = Theme.Fonts.Digits,
			TextSize = Theme.TextSizes.Small,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = NOT_AVAILABLE,
		})
	end
	local apText = apsisRow(1, "Ap", Theme.Colors.Title)
	local apTimeText = apsisRow(2, "T-Ap", Theme.Colors.TextDim)
	local peText = apsisRow(3, "Pe", Theme.Colors.Title)
	local peTimeText = apsisRow(4, "T-Pe", Theme.Colors.TextDim)

	--========================================================================
	-- Right: stage stack
	--========================================================================
	local stagePanel =
		hudPanel(root, "Stages", UDim2.fromOffset(STAGE_WIDTH, 0), UDim2.new(1, -MARGIN, 1, -MARGIN), Vector2.new(1, 1))
	stagePanel.AutomaticSize = Enum.AutomaticSize.Y
	Kit.list(stagePanel, { gap = Theme.Padding.Small })

	local header = Kit.frame(stagePanel, { name = "Header", size = UDim2.new(1, 0, 0, 34), layoutOrder = 1 })
	local craftNameText = text(header, {
		Size = UDim2.new(1, 0, 0, 18),
		Font = Theme.Fonts.Title,
		TextSize = Theme.TextSizes.Button,
		TextColor3 = Theme.Colors.Title,
	})
	local roleText = text(header, {
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 14),
		Font = Theme.Fonts.Body,
		TextSize = Theme.TextSizes.Small,
		TextColor3 = Theme.Colors.TextDim,
	})
	local stageCountText = text(header, {
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = Theme.TextSizes.Tiny,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Right,
	})
	local moreText = text(stagePanel, {
		Name = "More",
		LayoutOrder = 2,
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = Theme.TextSizes.Tiny,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
	})

	local cards: { StageCard } = {}
	for index = 1, MAX_STAGE_CARDS do
		-- the next stage (index 1) sits at the bottom of the stack, like KSP's
		local card: Frame = new("Frame", {
			Name = "Stage" .. index,
			LayoutOrder = 10 + MAX_STAGE_CARDS - index,
			Size = UDim2.new(1, 0, 0, STAGE_CARD_HEIGHT),
			BackgroundColor3 = Theme.Colors.PanelRaised,
			BorderSizePixel = 0,
			Active = false,
			Visible = false,
		}, stagePanel)
		Kit.corner(card, Theme.Radius.Small)
		local cardStroke = Kit.stroke(card, Theme.Colors.PanelStroke, Theme.Stroke.Thin)
		Kit.padding(card, Theme.Padding.Small + 2)
		local badge: Frame = new("Frame", {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromOffset(STAGE_BADGE, STAGE_BADGE),
			BackgroundColor3 = Theme.Colors.GaugeFace,
			BorderSizePixel = 0,
			Active = false,
		}, card)
		Kit.corner(badge, Theme.Radius.Small)
		local badgeText = text(badge, {
			Size = UDim2.fromScale(1, 1),
			Font = Theme.Fonts.ExtraBold,
			TextSize = Theme.TextSizes.Body,
			TextXAlignment = Enum.TextXAlignment.Center,
		})
		local inset = STAGE_BADGE + Theme.Padding.Medium
		local dv = text(card, {
			Position = UDim2.fromOffset(inset, 0),
			Size = UDim2.new(1, -inset, 0, 14),
			Font = Theme.Fonts.Medium,
			TextSize = Theme.TextSizes.Small,
		})
		local fuelText = text(card, {
			Position = UDim2.fromOffset(inset, 0),
			Size = UDim2.new(1, -inset, 0, 14),
			TextSize = Theme.TextSizes.Tiny,
			TextColor3 = Theme.Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Right,
		})
		local fuel = Kit.bar(card, {
			name = "Fuel",
			size = UDim2.new(1, -inset, 0, 7),
			position = UDim2.new(0, inset, 1, 0),
			anchor = Vector2.new(0, 1),
			color = Theme.Colors.Accent,
		})
		cards[index] = {
			frame = card,
			stroke = cardStroke,
			badge = badge,
			badgeText = badgeText,
			dv = dv,
			fuelText = fuelText,
			fuel = fuel,
		}
	end
	local noStagesText = text(stagePanel, {
		Name = "NoStages",
		LayoutOrder = 50,
		Size = UDim2.new(1, 0, 0, 16),
		Font = Theme.Fonts.Medium,
		TextColor3 = Theme.Colors.TextDim,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
	})
	new("Frame", {
		Name = "Divider",
		LayoutOrder = 60,
		Size = UDim2.new(1, 0, 0, 1),
		BackgroundColor3 = Theme.Colors.PanelStroke,
		BorderSizePixel = 0,
		Active = false,
	}, stagePanel)
	local function statRow(order: number, caption: string): TextLabel
		local row = Kit.frame(stagePanel, { name = caption, size = UDim2.new(1, 0, 0, 16), layoutOrder = order })
		text(row, { Size = UDim2.fromScale(0.5, 1), TextColor3 = Theme.Colors.TextDim, Text = caption })
		return text(row, {
			Position = UDim2.fromScale(0.4, 0),
			Size = UDim2.fromScale(0.6, 1),
			Font = Theme.Fonts.Digits,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = NOT_AVAILABLE,
		})
	end
	local dvText = statRow(61, "Total " .. DV)
	local twrText = statRow(62, "TWR")
	local stageHintRow = Kit.frame(stagePanel, { name = "StageHint", size = UDim2.new(1, 0, 0, 20), layoutOrder = 63 })
	stageHintRow.Visible = false
	Kit.list(stageHintRow, { horizontal = true, gap = Theme.Padding.Small, align = Enum.HorizontalAlignment.Center })
	text(stageHintRow, {
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(0, 20),
		TextColor3 = Theme.Colors.TextDim,
		Text = "Stage:",
		LayoutOrder = 1,
	})
	local stageKey = Kit.keycap(stageHintRow, "Space", { layoutOrder = 2 })

	--========================================================================
	-- Bottom left: throttle and fuel gauges, status lamps
	--========================================================================
	local gauges = hudPanel(
		root,
		"Gauges",
		UDim2.fromOffset(GAUGES_SIZE.X, GAUGES_SIZE.Y),
		UDim2.new(0, MARGIN, 1, -MARGIN),
		Vector2.new(0, 1)
	)
	local function gaugeColumn(x: number, caption: string, color: Color3): (Kit.Bar, TextLabel)
		local column = Kit.frame(gauges, {
			name = caption,
			size = UDim2.new(0, GAUGE_COLUMN, 1, 0),
			position = UDim2.fromOffset(x, 0),
		})
		text(column, {
			Size = UDim2.new(1, 0, 0, 12),
			TextSize = Theme.TextSizes.Tiny,
			TextColor3 = Theme.Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Center,
			Text = caption,
		})
		local bar = Kit.bar(column, {
			name = caption,
			size = UDim2.new(0, 18, 1, -32),
			position = UDim2.new(0.5, 0, 0, 14),
			anchor = Vector2.new(0.5, 0),
			color = color,
			vertical = true,
		})
		local value = text(column, {
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.fromScale(0, 1),
			Size = UDim2.new(1, 0, 0, 14),
			Font = Theme.Fonts.Digits,
			TextSize = Theme.TextSizes.Small,
			TextXAlignment = Enum.TextXAlignment.Center,
			TextTruncate = Enum.TextTruncate.None,
			Text = "0%",
		})
		return bar, value
	end
	local throttleBar, throttleText = gaugeColumn(0, "THR", Theme.Colors.Warning)
	local fuelBar, fuelText = gaugeColumn(GAUGE_COLUMN + Theme.Padding.Gap, "FUEL", Theme.Colors.Accent)
	local lampsX = (GAUGE_COLUMN + Theme.Padding.Gap) * 2 + Theme.Padding.Small
	local lampsColumn = Kit.frame(gauges, {
		name = "Lamps",
		size = UDim2.new(1, -lampsX, 1, 0),
		position = UDim2.fromOffset(lampsX, 0),
	})
	Kit.list(lampsColumn, { gap = Theme.Padding.Gap, valign = Enum.VerticalAlignment.Center })
	local function lamp(caption: string, litColor: Color3): Lamp
		local frame: Frame = new("Frame", {
			Name = caption,
			Size = UDim2.new(1, 0, 0, LAMP_HEIGHT),
			BackgroundColor3 = Theme.Colors.GaugeMetalDark,
			BorderSizePixel = 0,
			Active = false,
		}, lampsColumn)
		Kit.corner(frame, Theme.Radius.Small)
		local lampStroke = Kit.stroke(frame, Theme.Colors.GaugeFace, Theme.Stroke.Thin)
		local label = text(frame, {
			Size = UDim2.fromScale(1, 1),
			Font = Theme.Fonts.ExtraBold,
			TextSize = Theme.TextSizes.Small,
			TextColor3 = Theme.Colors.TextDim,
			TextXAlignment = Enum.TextXAlignment.Center,
			Text = caption,
		})
		return { frame = frame, stroke = lampStroke, text = label, litColor = litColor }
	end
	local sasLamp = lamp("SAS", Theme.Colors.Accent)
	local legsLamp = lamp("LEGS", Theme.Colors.Accent)
	local enginesLamp = lamp("ENGINES", Theme.Colors.Warning)
	local function setLamp(l: Lamp, lit: boolean, available: boolean)
		set(l.frame, "BackgroundColor3", if lit then l.litColor else Theme.Colors.GaugeMetalDark)
		set(l.stroke, "Color", if lit then Theme.Colors.DigitText else Theme.Colors.GaugeFace)
		set(l.stroke, "Transparency", if lit then 0.5 else 0)
		set(
			l.text,
			"TextColor3",
			if lit then Theme.Colors.ButtonText elseif available then Theme.Colors.TextDim else Theme.Colors.GaugeMetal
		)
	end

	--========================================================================
	-- Key hints (above the gauges)
	--========================================================================
	local hintsPanel = hudPanel(
		root,
		"KeyHints",
		UDim2.new(),
		UDim2.new(0, MARGIN, 1, -(MARGIN + GAUGES_SIZE.Y + Theme.Padding.Gap)),
		Vector2.new(0, 1)
	)
	hintsPanel.AutomaticSize = Enum.AutomaticSize.XY
	hintsPanel.BackgroundTransparency = 0.35
	local hintsText = text(hintsPanel, {
		Size = UDim2.new(),
		AutomaticSize = Enum.AutomaticSize.XY,
		Font = Theme.Fonts.Medium,
		TextSize = Theme.TextSizes.Small,
		TextColor3 = Theme.Colors.Text,
		TextTruncate = Enum.TextTruncate.None,
		TextYAlignment = Enum.TextYAlignment.Top,
		LineHeight = 1.2,
		RichText = true,
	})
	local hintsFor: boolean? = nil -- the role the hint text was built for (nil = rebuild)
	local function buildHints(isPilot: boolean)
		hintsFor = isPilot
		local lines: { string }
		if isPilot then
			lines = {
				`{keyText("PitchDown")}/{keyText("PitchUp")} pitch   {keyText("YawLeft")}/{keyText("YawRight")} yaw   {keyText(
					"RollLeft"
				)}/{keyText("RollRight")} roll`,
				`{keyText("ThrottleUp")}/{keyText("ThrottleDown")} throttle   {keyText("ThrottleFull")} full   {keyText(
					"ThrottleCut"
				)} cut`,
				`{keyText("Stage")} stage   {keyText("ToggleSAS")} SAS   {keyText("ToggleGear")} legs   {keyText(
					"LeaveSeat"
				)} leave seat`,
				`{keyText("ToggleCamera")} camera   {keyText("MapView")} map   {keyText("ToggleHUD")} hide HUD`,
				"Right-drag: orbit camera   Wheel: zoom",
			}
		else
			lines = {
				`{keyText("MapView")} map   {keyText("ToggleHUD")} hide HUD`,
				"Right-drag: orbit camera   Wheel: zoom",
			}
		end
		hintsText.Text = table.concat(lines, "\n")
		sasKey.Text = Keybinds.label("ToggleSAS")
		stageKey.Text = Keybinds.label("Stage")
	end
	Keybinds.onChanged(function()
		hintsFor = nil -- rebuilt on the next update
	end)

	--========================================================================
	-- Top right: Settings and End Flight
	--========================================================================
	local topButtons = Kit.frame(root, {
		name = "TopButtons",
		size = UDim2.fromOffset(0, TOP_BUTTON_HEIGHT),
		position = UDim2.new(1, -MARGIN, 0, MARGIN),
		anchor = Vector2.new(1, 0),
	})
	topButtons.AutomaticSize = Enum.AutomaticSize.X
	Kit.list(topButtons, { horizontal = true, gap = Theme.Padding.Gap, align = Enum.HorizontalAlignment.Right })
	Kit.button(topButtons, "Settings", function()
		SettingsPanel.open()
	end, {
		name = "Settings",
		size = UDim2.fromOffset(SETTINGS_BUTTON_WIDTH, TOP_BUTTON_HEIGHT),
		layoutOrder = 1,
	})
	local endButton = Kit.button(topButtons, "End Flight", function()
		callbacks.onEndFlight()
	end, {
		name = "EndFlight",
		style = "Danger",
		size = UDim2.fromOffset(END_BUTTON_WIDTH, TOP_BUTTON_HEIGHT),
		layoutOrder = 2,
	})
	-- keep the buttons below the Roblox top bar (Kit screens ignore the GUI inset)
	local function placeTopButtons()
		local screenHeight = screen.AbsoluteSize.Y
		local inset = GuiService.TopbarInset.Height
		local designInset = if screenHeight > 0 then inset * canvas.Size.Y.Offset / screenHeight else inset
		topButtons.Position = UDim2.new(1, -MARGIN, 0, designInset + Theme.Padding.Medium)
	end
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(placeTopButtons)
	canvas:GetPropertyChangedSignal("Size"):Connect(placeTopButtons)
	placeTopButtons()

	--========================================================================
	-- Top centre: pre-launch banner + countdown
	--========================================================================
	local banner = hudPanel(
		root,
		"Banner",
		UDim2.fromOffset(0, BANNER_HEIGHT),
		UDim2.new(0.5, 0, 0, BANNER_Y),
		Vector2.new(0.5, 0)
	)
	banner.AutomaticSize = Enum.AutomaticSize.X
	banner.Visible = false
	local bannerStroke = banner:FindFirstChildOfClass("UIStroke") :: UIStroke
	panelPadding(banner, 0, Theme.Padding.Huge)
	local bannerText = text(banner, {
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = Theme.Fonts.ExtraBold,
		TextSize = Theme.TextSizes.Title + 2,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.None,
		RichText = true,
	})
	local countdownText = text(root, {
		Name = "Countdown",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, BANNER_Y + BANNER_HEIGHT + Theme.Padding.Medium),
		Size = UDim2.fromOffset(260, COUNTDOWN_SIZE),
		Font = Theme.Fonts.Logo,
		TextSize = COUNTDOWN_SIZE,
		TextColor3 = Theme.Colors.Title,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.None,
		Visible = false,
	})
	new("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Color = Theme.Colors.GaugeFace,
		Thickness = Theme.Stroke.Thick,
		Transparency = 0.1,
	}, countdownText)
	local countdownScale: UIScale = new("UIScale", {}, countdownText)

	--========================================================================
	-- Hint pill (outside the HUD root: stays usable while the HUD is hidden)
	--========================================================================
	local hint = hudPanel(
		canvas,
		"Hint",
		UDim2.fromOffset(0, HINT_HEIGHT),
		UDim2.new(0.5, 0, 1, -(NAV_BOTTOM + BEZEL_SIZE + PLATE_GAP + SPEED_PLATE_SIZE.Y + Theme.Padding.Large)),
		Vector2.new(0.5, 1)
	)
	hint.AutomaticSize = Enum.AutomaticSize.X
	hint.Visible = false
	hint.ZIndex = 5
	local hintStroke = hint:FindFirstChildOfClass("UIStroke")
	if hintStroke then
		hintStroke.Color = Theme.Colors.Title
	end
	panelPadding(hint, 0, Theme.Padding.Large)
	local hintText = text(hint, {
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		TextSize = Theme.TextSizes.Body,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.None,
		ZIndex = 6,
	})

	--========================================================================
	-- Update
	--========================================================================
	local function renderAltimeter(data: HudData.HudData)
		local altitude = if radarMode then data.radarAltitude else data.altitude
		local whole, unit, fraction = Format.altitudeParts(altitude)
		local positions = HudMath.wheelPositions(whole, fraction, WHEEL_COUNT)
		for index, strip in strips do
			set(strip, "Position", UDim2.fromScale(0, -quantize(positions[index], WHEEL_QUANTUM)))
		end
		set(signText, "Text", if whole < 0 then "-" else "")
		set(unitText, "Text", unit)
		set(bodyText, "Text", data.bodyName)

		local pressure = math.clamp(data.pressure, 0, 1)
		if data.inAtmosphere then
			atmoBar.set(quantize(pressure, 200))
			set(atmoText, "Text", Format.percent(pressure))
			set(atmoText, "TextColor3", Theme.Colors.NavSky)
		else
			atmoBar.set(0)
			set(atmoText, "Text", "VACUUM")
			set(atmoText, "TextColor3", Theme.Colors.TextDim)
		end

		local vs = data.verticalSpeed
		local f = HudMath.verticalSpeedFraction(vs, VSI_MAX)
		set(needle, "Rotation", quantize(180 + VSI_SWEEP * f, 1 / VSI_ANGLE_QUANTUM))
		if vs >= VS_DEADBAND then
			set(vsText, "Text", "+" .. Format.speed(vs))
			set(vsText, "TextColor3", Theme.Colors.Accent)
		elseif vs <= -VS_DEADBAND then
			set(vsText, "Text", Format.speed(vs))
			set(vsText, "TextColor3", Theme.Colors.Danger)
		else
			set(vsText, "Text", Format.speed(0))
			set(vsText, "TextColor3", Theme.Colors.TextDim)
		end
	end

	local function renderNavball(data: HudData.HudData)
		-- speed plate: automatic by altitude; a manual choice lasts until the automatic mode changes (like KSP)
		local auto = data.orbitMode
		if auto ~= lastAutoOrbit then
			lastAutoOrbit = auto
			speedOverride = nil
		end
		local override = speedOverride
		showingOrbit = if override ~= nil then override else auto
		set(speedModeButton, "Text", if showingOrbit then "Orbit" else "Surface")
		set(speedText, "Text", Format.speed(if showingOrbit then data.orbitalSpeed else data.surfaceSpeed))

		-- SAS button: lit while SAS is on (everyone aboard sees it; only the pilot's clicks count)
		isPilotNow = data.isPilot
		local style: Kit.ButtonStyle = if data.sas then "Accent" else "Ghost"
		if style ~= sasStyle then
			sasStyle = style
			Kit.setButtonStyle(sasButton, style)
		end

		-- throttle arc
		local lit = HudMath.litSegments(data.throttle, ARC_SEGMENTS)
		for index, segment in arcSegments do
			set(segment, "BackgroundColor3", if index <= lit then Theme.Colors.Warning else Theme.Colors.GaugeMetalDark)
		end

		-- ball, heading and pitch
		local heading, pitch = navball.update(data.attitude, data.horizon, data.velocity)
		navball.setRails(data.onRails)
		if data.attitude then
			set(headingText, "Text", `HDG {HudMath.headingText(heading)}  PIT {HudMath.pitchText(pitch)}`)
		else
			set(headingText, "Text", `HDG {NOT_AVAILABLE}{DEGREE}`)
		end

		-- apoapsis / periapsis
		local ap, pe = data.apoapsis, data.periapsis
		set(apsisPlate, "Visible", data.attitude ~= nil and (ap ~= nil or pe ~= nil))
		set(apText, "Text", if ap then Format.distance(ap) else NOT_AVAILABLE)
		set(peText, "Text", if pe then Format.distance(pe) else NOT_AVAILABLE)
		set(peText, "TextColor3", if pe ~= nil and pe < 0 then Theme.Colors.Danger else Theme.Colors.Text)
		local tAp, tPe = data.timeToApoapsis, data.timeToPeriapsis
		set(apTimeText, "Text", if tAp then Format.duration(math.max(0, tAp)) else NOT_AVAILABLE)
		set(peTimeText, "Text", if tPe then Format.duration(math.max(0, tPe)) else NOT_AVAILABLE)
	end

	local function renderStages(data: HudData.HudData)
		set(craftNameText, "Text", data.craftName)
		set(roleText, "Text", if data.isPilot then "Pilot" else "Passenger")
		local stages = data.stages
		local count = #stages
		for index, card in cards do
			local info = stages[index]
			set(card.frame, "Visible", info ~= nil)
			if info then
				local fuel = math.clamp(info.fuelFraction, 0, 1)
				local isNext = info.isNext
				set(card.stroke, "Color", if isNext then Theme.Colors.Accent else Theme.Colors.PanelStroke)
				set(card.stroke, "Thickness", if isNext then Theme.Stroke.Medium else Theme.Stroke.Thin)
				set(card.badge, "BackgroundColor3", if isNext then Theme.Colors.Accent else Theme.Colors.GaugeFace)
				set(card.badgeText, "TextColor3", if isNext then Theme.Colors.ButtonText else Theme.Colors.Text)
				set(card.badgeText, "Text", tostring(info.stage))
				set(card.dv, "Text", `{DV} {Format.speed(info.dvVac)}`)
				set(card.dv, "TextColor3", if isNext then Theme.Colors.Text else Theme.Colors.TextDim)
				set(card.fuelText, "Text", if fuel <= 0 then "EMPTY" else Format.percent(fuel))
				set(card.fuelText, "TextColor3", if fuel < LOW_FUEL then Theme.Colors.Danger else Theme.Colors.TextDim)
				card.fuel.set(quantize(fuel, 200))
				card.fuel.setColor(if fuel < LOW_FUEL then Theme.Colors.Danger else Theme.Colors.Accent)
			end
		end
		local hidden = count - MAX_STAGE_CARDS
		set(moreText, "Visible", hidden > 0)
		if hidden > 0 then
			set(moreText, "Text", `+{hidden} more`)
		end
		set(noStagesText, "Visible", count == 0)
		set(noStagesText, "Text", if data.isPilot then "No stages left" else "Staging is up to the pilot")
		set(stageCountText, "Text", if count == 1 then "1 stage" else `{count} stages`)
		local known = data.isPilot or data.prelaunch or count > 0
		set(dvText, "Text", if known then Format.speed(data.dvRemaining) else NOT_AVAILABLE)
		local twr = data.twr
		local twrKnown = twr == twr and twr > 0 and twr ~= math.huge
		set(twrText, "Text", if twrKnown then string.format("%.2f", twr) else NOT_AVAILABLE)
		set(
			twrText,
			"TextColor3",
			if not twrKnown then Theme.Colors.TextDim elseif twr < 1 then Theme.Colors.Danger else Theme.Colors.Text
		)
	end

	local function renderGauges(data: HudData.HudData)
		local throttle = math.clamp(data.throttle, 0, 1)
		throttleBar.set(quantize(throttle, 200))
		set(throttleText, "Text", Format.percent(throttle))
		set(throttleText, "TextColor3", if throttle > 0 then Theme.Colors.Text else Theme.Colors.TextDim)
		local fuel = data.fuel
		if fuel then
			local f = math.clamp(fuel, 0, 1)
			fuelBar.set(quantize(f, 200))
			fuelBar.setColor(if f < LOW_FUEL then Theme.Colors.Danger else Theme.Colors.Accent)
			set(fuelText, "Text", Format.percent(f))
			set(fuelText, "TextColor3", if f < LOW_FUEL then Theme.Colors.Danger else Theme.Colors.Text)
		else
			fuelBar.set(0)
			set(fuelText, "Text", NOT_AVAILABLE)
			set(fuelText, "TextColor3", Theme.Colors.TextDim)
		end
		setLamp(sasLamp, data.sas, true)
		setLamp(legsLamp, data.hasLegs and data.gearDown, data.hasLegs)
		setLamp(enginesLamp, data.burning, true)
	end

	local function renderBanner(data: HudData.HudData)
		local countdown = data.countdown
		if countdown then
			set(banner, "Visible", true)
			set(bannerText, "Text", "LIFTOFF IN")
			set(bannerText, "TextColor3", Theme.Colors.Text)
			set(bannerStroke, "Color", Theme.Colors.Title)
			set(bannerStroke, "Transparency", 0)
			local whole = math.ceil(countdown)
			set(countdownText, "Visible", true)
			set(countdownText, "Text", if whole <= 0 then "GO!" else tostring(whole))
			local frac = math.clamp(countdown - math.floor(countdown), 0, 1)
			set(countdownScale, "Scale", quantize(1 + COUNTDOWN_PULSE * frac ^ 4, 100)) -- big right after each tick
		elseif data.prelaunch then
			set(banner, "Visible", true)
			set(countdownText, "Visible", false)
			if data.isPilot then
				set(bannerText, "Text", `PRESS {keyText("Stage")} TO LAUNCH`)
				set(bannerText, "TextColor3", Theme.Colors.Text)
				set(bannerStroke, "Color", Theme.Colors.Title)
				-- gentle outline pulse to draw the eye (quantised, so it only writes when visible)
				local pulse = 0.45 - 0.45 * math.cos(os.clock() * BANNER_PULSE_SPEED)
				set(bannerStroke, "Transparency", quantize(pulse, 50))
			else
				set(bannerText, "Text", "Waiting for the pilot...")
				set(bannerText, "TextColor3", Theme.Colors.TextDim)
				set(bannerStroke, "Color", Theme.Colors.PanelStroke)
				set(bannerStroke, "Transparency", 0)
			end
		else
			set(banner, "Visible", false)
			set(countdownText, "Visible", false)
		end
	end

	local function update(data: HudData.HudData?)
		if not data or not Settings.current().hudVisible then
			set(root, "Visible", false)
			return
		end
		set(root, "Visible", true)
		renderAltimeter(data)
		renderNavball(data)
		renderStages(data)
		renderGauges(data)
		renderBanner(data)

		-- key hints (Settings hints)
		local hints = Settings.current().hints
		if hints and hintsFor ~= data.isPilot then
			buildHints(data.isPilot)
		end
		set(hintsPanel, "Visible", hints)
		set(sasKey, "Visible", hints and data.isPilot)
		set(stageHintRow, "Visible", hints and data.isPilot)

		-- End Flight: the pilot or the owner ends it for everyone; anyone else only leaves
		set(endButton, "Text", if data.isPilot or data.isOwner then "End Flight" else "Leave Flight")
	end

	local function setHint(textValue: string?)
		if textValue and textValue ~= "" then
			hintText.Text = textValue
			hint.Visible = true
		else
			hint.Visible = false
		end
	end

	return {
		update = update,
		setHint = setHint,
	}
end

return table.freeze(FlightHUD)
