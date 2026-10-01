--!strict
--[[
	FlightHUD
	The flight HUD (spec 7.11, HUD v1), styled like the hangar builder (BuildUI) so both read as the same game:
	  * bottom-centre INSTRUMENT CLUSTER: vertical throttle bar | altitude (sea level, big) + radar altitude + SOI
	    body | vertical / surface / orbital speed | ENGINES light, SAS (key T), TWR, delta-v left, atmosphere bar
	  * bottom-right STAGE STACK: craft name and role, one card per remaining stage (next first, highlighted with
	    its SPACE key), each with a fuel bar and its delta-v
	  * top-centre BANNER: "PRESS SPACE TO LAUNCH" (pilot) / "Waiting for the pilot" (passenger) on the pad, and a
	    big pulsing countdown number while the launch countdown runs
	  * bottom-left CONTROLS card (pilot only), always visible, compact
	  * a HINT pill above the cluster (setHint); it lives outside the HUD root so it also shows while the HUD is hidden
	  * CHANGED (Phase 5): an ORBIT panel above the cluster: apoapsis and periapsis (altitude + time to each, "—" when
	    not applicable) either side of the NAVBALL (UI/Navball), with heading and pitch under them and an
	    "ON RAILS" pill on the ball while the craft coasts on rails

	Pure view: update(data) renders a HudData snapshot (nil hides the HUD). It is called every frame, so it only
	writes properties, and only when a value actually changed (a per-property cache); every instance, including a
	fixed pool of stage cards, is created once in create().

	Nothing here sinks input (every GuiObject is Active = false and there are no buttons): the pilot drags the right
	mouse button anywhere on screen to orbit the chase camera.

	Layout is authored for the same 1366 x 710 design canvas as BuildUI and scaled uniformly with a UIScale.
]]

local Players = game:GetService("Players")

local HudData = require(script.Parent.Parent.Render.HudData)
local Navball = require(script.Parent.Navball) -- CHANGED (Phase 5)

--============================================================================
-- Tunables
--============================================================================
-- Fonts (same family as BuildUI)
local FONT = Enum.Font.BuilderSans
local FONT_MEDIUM = Enum.Font.BuilderSansMedium
local FONT_BOLD = Enum.Font.BuilderSansBold
local FONT_HEAVY = Enum.Font.BuilderSansExtraBold
-- Colours (BuildUI palette)
local COLOR_PANEL = Color3.fromRGB(22, 26, 38)
local COLOR_PANEL_STROKE = Color3.fromRGB(78, 88, 122)
local COLOR_SURFACE = Color3.fromRGB(38, 44, 62)
local COLOR_DEEP = Color3.fromRGB(13, 15, 23)
local COLOR_TEXT = Color3.fromRGB(242, 244, 252)
local COLOR_TEXT_DIM = Color3.fromRGB(150, 158, 184)
local COLOR_TEXT_DARK = Color3.fromRGB(28, 22, 18)
local COLOR_ACCENT = Color3.fromRGB(255, 140, 40)
local COLOR_ACCENT_LIGHT = Color3.fromRGB(255, 192, 90)
local COLOR_GOOD = Color3.fromRGB(88, 214, 122)
local COLOR_BAD = Color3.fromRGB(240, 78, 78)
local COLOR_INFO = Color3.fromRGB(92, 176, 255)
local COLOR_ATMOSPHERE = Color3.fromRGB(120, 200, 255)
local GRADIENT_BOTTOM = Color3.fromRGB(205, 210, 222) -- UIGradient multiplier at the bottom of panels
local KEY_HEX = "#FFC05A" -- key names in the controls card (COLOR_ACCENT_LIGHT)
local PANEL_TRANSPARENCY = 0.12 -- a touch more see-through than the builder: the world matters in flight
local CORNER = 12
local CORNER_SMALL = 8
local STROKE_THICKNESS = 1.5
-- Layout (design pixels on the 1366 x 710 canvas)
local DESIGN_WIDTH = 1366
local DESIGN_HEIGHT = 710
local MIN_SCALE = 0.6
local MAX_SCALE = 1.6
local MARGIN = 12
local CLUSTER_PADDING = 12
local CLUSTER_INNER_WIDTH = 684
local CLUSTER_INNER_HEIGHT = 100
local THROTTLE_WIDTH = 46
local ALTITUDE_WIDTH = 214
local SPEEDS_WIDTH = 170
local STATUS_WIDTH = 190
local SECTION_GAP = 18 -- between sections; a 2 px divider sits in the middle
local STAGE_WIDTH = 210
local STAGE_CARD_HEIGHT = 56
local MAX_STAGE_CARDS = 5 -- more stages collapse into "+N more"
local CONTROLS_WIDTH = 300
local BANNER_Y = 62 -- below the builder's top-centre toast
-- CHANGED (Phase 5): orbit panel (apoapsis | navball | periapsis) above the cluster
local ORBIT_PANEL_WIDTH = 470
local ORBIT_PANEL_HEIGHT = 150
local ORBIT_PANEL_PADDING = 10
local ORBIT_PANEL_GAP = 8 -- between the cluster and the orbit panel
local NAVBALL_SIZE = 130
local NOT_APPLICABLE = "—" -- shown for an apsis / time that does not exist
local BANNER_HEIGHT = 48
local COUNTDOWN_SIZE = 110
-- Behaviour / formatting
local KM_THRESHOLD = 10000 -- m; altitudes at or above this are shown in km
local VS_DEADBAND = 0.05 -- m/s; below this vertical speed shows as neutral 0
local VS_UP_PREFIX = "+" -- swap for "▲" if the font has the glyph
local VS_DOWN_PREFIX = "-" -- swap for "▼"
local LOW_FUEL = 0.2 -- fuel bars turn red below this fraction
local THROTTLE_QUANTUM = 0.005 -- throttle bar resolution (avoids rewriting sizes for invisible changes)
local COUNTDOWN_PULSE = 0.3 -- extra scale of the countdown number right after it ticks
local BANNER_PULSE_SPEED = 4 -- rad/s of the "press space" outline pulse
local DV = "Δv" -- delta-v label (swap for "dV" if a font lacks the glyph)
local CONTROLS_TEXT = table.concat({
	`<font color="{KEY_HEX}"><b>W/S</b></font> pitch   <font color="{KEY_HEX}"><b>A/D</b></font> yaw   <font color="{KEY_HEX}"><b>Q/E</b></font> roll`,
	`<font color="{KEY_HEX}"><b>Shift/Ctrl</b></font> throttle   <font color="{KEY_HEX}"><b>Z</b></font> full   <font color="{KEY_HEX}"><b>X</b></font> cut`,
	`<font color="{KEY_HEX}"><b>Space</b></font> stage   <font color="{KEY_HEX}"><b>T</b></font> SAS   <font color="{KEY_HEX}"><b>G</b></font> legs   <font color="{KEY_HEX}"><b>V</b></font> camera   <font color="{KEY_HEX}"><b>F</b></font> leave seat`, -- CHANGED (Phase 2a remodel): G legs
	`<font color="{KEY_HEX}"><b>Right-drag</b></font> orbit camera   <font color="{KEY_HEX}"><b>Wheel</b></font> zoom`,
}, "\n")
--============================================================================

export type FlightHUD = {
	update: (data: HudData.HudData?) -> (), -- nil hides the HUD; call every frame
	setHint: (text: string?) -> (), -- nil hides the hint
}

type StageCard = {
	frame: Frame,
	stroke: UIStroke,
	badge: Frame,
	badgeText: TextLabel,
	title: TextLabel,
	key: TextLabel,
	dv: TextLabel,
	fuelText: TextLabel,
	fuelFill: Frame,
}

local FlightHUD = {}

--============================================================================
-- Building blocks (BuildUI style, but nothing is Active)
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

local function frame(parent: Instance, props: { [string]: any }): Frame
	local f: Frame = new("Frame", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
	}, nil)
	for key, value in props do
		(f :: any)[key] = value
	end
	f.Parent = parent
	return f
end

-- A rounded, outlined card that does NOT sink input.
local function panel(parent: Instance, props: { [string]: any }): Frame
	local f = frame(parent, {
		BackgroundColor3 = COLOR_PANEL,
		BackgroundTransparency = PANEL_TRANSPARENCY,
	})
	for key, value in props do
		(f :: any)[key] = value
	end
	corner(f, CORNER)
	stroke(f, COLOR_PANEL_STROKE, STROKE_THICKNESS, 0.35)
	gradient(f)
	return f
end

local function label(parent: Instance, props: { [string]: any }): TextLabel
	local l: TextLabel = new("TextLabel", {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Active = false,
		Selectable = false,
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

-- Small caption in the dim label style (e.g. "ALTITUDE").
local function caption(parent: Instance, props: { [string]: any }): TextLabel
	local l =
		label(parent, { Font = FONT_BOLD, TextSize = 11, TextColor3 = COLOR_TEXT_DIM, Size = UDim2.new(1, 0, 0, 14) })
	for key, value in props do
		(l :: any)[key] = value
	end
	return l
end

-- Keycap badge (BuildUI keyHint look).
local function keycap(parent: Instance, text: string, props: { [string]: any }): TextLabel
	local badge = label(parent, {
		Size = UDim2.fromOffset(0, 16),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = COLOR_DEEP,
		BackgroundTransparency = 0.25,
		Font = FONT_BOLD,
		TextSize = 11,
		TextColor3 = COLOR_TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = text,
		ZIndex = 3,
	})
	for key, value in props do
		(badge :: any)[key] = value
	end
	corner(badge, 4)
	new("UIPadding", { PaddingLeft = UDim.new(0, 5), PaddingRight = UDim.new(0, 5) }, badge)
	return badge
end

-- Horizontal or vertical bar: a deep track with a coloured fill anchored at the bottom / left.
local function bar(parent: Instance, props: { [string]: any }, vertical: boolean, color: Color3): (Frame, Frame)
	local track = frame(parent, { BackgroundColor3 = COLOR_DEEP, BackgroundTransparency = 0.2 })
	for key, value in props do
		(track :: any)[key] = value
	end
	corner(track, 4)
	stroke(track, COLOR_PANEL_STROKE, 1, 0.5)
	local fill = frame(track, {
		AnchorPoint = if vertical then Vector2.new(0, 1) else Vector2.zero,
		Position = if vertical then UDim2.fromScale(0, 1) else UDim2.new(),
		Size = if vertical then UDim2.fromScale(1, 0) else UDim2.fromScale(0, 1),
		BackgroundColor3 = color,
		BackgroundTransparency = 0,
	})
	corner(fill, 4)
	gradient(fill)
	return track, fill
end

local function divider(parent: Instance, x: number)
	local d = frame(parent, {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0, x, 0.5, 0),
		Size = UDim2.new(0, 2, 1, -12),
		BackgroundColor3 = COLOR_PANEL_STROKE,
		BackgroundTransparency = 0.4,
	})
	corner(d, 1)
end

--============================================================================
-- Formatting
--============================================================================
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

-- Metres below KM_THRESHOLD, km above (more decimals while the number is small).
local function formatDistance(m: number): string
	if m ~= m then
		return "-"
	end
	local a = math.abs(m)
	if a < KM_THRESHOLD then
		return formatInt(m) .. " m"
	elseif a < 100000 then
		return string.format("%.2f km", m / 1000)
	elseif a < 1000000 then
		return string.format("%.1f km", m / 1000)
	end
	return formatInt(m / 1000) .. " km"
end

local function formatSpeed(v: number): string
	if v ~= v then
		return "-"
	end
	if math.abs(v) < 100 then
		return string.format("%.1f m/s", v)
	end
	return formatInt(v) .. " m/s"
end

-- CHANGED (Phase 5): durations for time to apoapsis / periapsis.
local function formatDuration(seconds: number?): string
	if seconds == nil or seconds ~= seconds or seconds == math.huge then
		return NOT_APPLICABLE
	end
	local t = math.max(0, seconds :: number)
	if t < 60 then
		return string.format("%.1f s", t)
	elseif t < 3600 then
		return string.format("%dm %02ds", math.floor(t / 60), math.floor(t % 60))
	elseif t < 86400 then
		return string.format("%dh %02dm", math.floor(t / 3600), math.floor(t % 3600 / 60))
	end
	return string.format("%dd %02dh", math.floor(t / 86400), math.floor(t % 86400 / 3600))
end

local function formatApsis(altitude: number?): string
	if altitude == nil then
		return NOT_APPLICABLE
	end
	return formatDistance(altitude :: number)
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

--============================================================================
-- Create
--============================================================================
function FlightHUD.create(): FlightHUD
	local player = Players.LocalPlayer
	local screen: ScreenGui = new("ScreenGui", {
		Name = "FlightHUD",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 10, -- above the builder UI (0), below debug overlays
		Enabled = true,
	}, player:WaitForChild("PlayerGui"))

	-- Design canvas: sized in design pixels and scaled uniformly to the screen (same approach as BuildUI).
	local canvas = frame(screen, { Name = "Canvas", Size = UDim2.fromOffset(DESIGN_WIDTH, DESIGN_HEIGHT) })
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

	local root = frame(canvas, { Name = "HUD", Size = UDim2.fromScale(1, 1), Visible = false })

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

	--========================================================================
	-- Bottom centre: instrument cluster
	--========================================================================
	local cluster = panel(root, {
		Name = "Cluster",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -MARGIN),
		Size = UDim2.fromOffset(CLUSTER_INNER_WIDTH + CLUSTER_PADDING * 2, CLUSTER_INNER_HEIGHT + CLUSTER_PADDING * 2),
	})
	padding(cluster, CLUSTER_PADDING)

	local x = 0
	local function section(width: number, name: string): Frame
		local f = frame(cluster, { Name = name, Position = UDim2.fromOffset(x, 0), Size = UDim2.new(0, width, 1, 0) })
		x += width
		return f
	end
	local function gap()
		divider(cluster, x + SECTION_GAP / 2)
		x += SECTION_GAP
	end

	-- Throttle: vertical bar with percentage
	local throttleSection = section(THROTTLE_WIDTH, "Throttle")
	caption(throttleSection, { Text = "THR", TextXAlignment = Enum.TextXAlignment.Center })
	local _throttleTrack, throttleFill = bar(throttleSection, {
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 17),
		Size = UDim2.new(0, 20, 1, -39),
	}, true, COLOR_ACCENT)
	local throttleText = label(throttleSection, {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, 18),
		Font = FONT_HEAVY,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "0%",
	})
	gap()

	-- Altitude: body pill, big sea-level altitude, radar altitude
	local altitudeSection = section(ALTITUDE_WIDTH, "Altitude")
	caption(altitudeSection, { Position = UDim2.fromOffset(0, 1), Text = "ALTITUDE" })
	local bodyPill = label(altitudeSection, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.fromOffset(0, 18),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = COLOR_INFO,
		BackgroundTransparency = 0.75,
		Font = FONT_BOLD,
		TextSize = 12,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
	})
	corner(bodyPill, 9)
	stroke(bodyPill, COLOR_INFO, 1, 0.3)
	new("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8) }, bodyPill)
	local altitudeText = label(altitudeSection, {
		Position = UDim2.fromOffset(0, 18),
		Size = UDim2.new(1, 0, 0, 48),
		Font = FONT_HEAVY,
		TextSize = 44,
		TextScaled = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "0 m",
	})
	caption(altitudeSection, { Position = UDim2.fromOffset(0, 78), Size = UDim2.fromOffset(52, 18), Text = "RADAR" })
	local radarText = label(altitudeSection, {
		Position = UDim2.fromOffset(52, 78),
		Size = UDim2.new(1, -52, 0, 18),
		Font = FONT_BOLD,
		TextSize = 15,
		Text = "0 m",
	})
	gap()

	-- Speeds: caption left, value right
	local speedsSection = section(SPEEDS_WIDTH, "Speeds")
	local function speedRow(index: number, text: string): TextLabel
		local y = (index - 1) * 34 + 2
		caption(speedsSection, { Position = UDim2.fromOffset(0, y), Size = UDim2.new(1, 0, 0, 28), Text = text })
		return label(speedsSection, {
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.new(1, 0, 0, 28),
			Font = FONT_HEAVY,
			TextSize = 19,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "0.0 m/s",
		})
	end
	local verticalText = speedRow(1, "VERTICAL")
	local surfaceText = speedRow(2, "SURFACE")
	local orbitalText = speedRow(3, "ORBITAL")
	gap()

	-- Status: ENGINES light + SAS, TWR + delta-v, atmosphere bar
	local statusSection = section(STATUS_WIDTH, "Status")
	local halfWidth = (STATUS_WIDTH - 6) / 2
	local enginesPill = frame(statusSection, {
		Size = UDim2.fromOffset(halfWidth, 26),
		BackgroundColor3 = COLOR_SURFACE,
		BackgroundTransparency = 0,
	})
	corner(enginesPill, 13)
	local enginesStroke = stroke(enginesPill, COLOR_PANEL_STROKE, 1.5, 0.4)
	gradient(enginesPill)
	local enginesDot = frame(enginesPill, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 9, 0.5, 0),
		Size = UDim2.fromOffset(8, 8),
		BackgroundColor3 = COLOR_TEXT_DIM,
		BackgroundTransparency = 0,
	})
	corner(enginesDot, 4)
	local enginesText = label(enginesPill, {
		Position = UDim2.fromOffset(22, 0),
		Size = UDim2.new(1, -26, 1, 0),
		Font = FONT_HEAVY,
		TextSize = 13,
		TextColor3 = COLOR_TEXT_DIM,
		Text = "ENGINES",
	})

	local sasPill = frame(statusSection, {
		Position = UDim2.fromOffset(halfWidth + 6, 0),
		Size = UDim2.fromOffset(halfWidth, 26),
		BackgroundColor3 = COLOR_SURFACE,
		BackgroundTransparency = 0,
	})
	corner(sasPill, 13)
	local sasStroke = stroke(sasPill, COLOR_PANEL_STROKE, 1.5, 0.4)
	gradient(sasPill)
	local sasText = label(sasPill, {
		Position = UDim2.fromOffset(10, 0),
		Size = UDim2.new(1, -36, 1, 0),
		Font = FONT_HEAVY,
		TextSize = 13,
		TextColor3 = COLOR_TEXT_DIM,
		Text = "SAS OFF",
	})
	local sasKey = keycap(sasPill, "T", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -5, 0.5, 0),
	})

	local function statBox(column: number, text: string): TextLabel
		local box = frame(statusSection, {
			Position = UDim2.fromOffset((column - 1) * (halfWidth + 6), 32),
			Size = UDim2.fromOffset(halfWidth, 34),
		})
		caption(box, { Position = UDim2.fromOffset(2, 0), Size = UDim2.new(1, -2, 0, 12), Text = text })
		return label(box, {
			Position = UDim2.fromOffset(2, 13),
			Size = UDim2.new(1, -2, 0, 20),
			Font = FONT_HEAVY,
			TextSize = 18,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = "-",
		})
	end
	local twrText = statBox(1, "TWR")
	local dvText = statBox(2, DV .. " LEFT")

	caption(statusSection, { Position = UDim2.fromOffset(2, 72), Size = UDim2.new(1, -2, 0, 12), Text = "ATMOSPHERE" })
	local pressureText = caption(statusSection, {
		Position = UDim2.fromOffset(0, 72),
		Size = UDim2.new(1, 0, 0, 12),
		TextXAlignment = Enum.TextXAlignment.Right,
		Text = "",
	})
	local _pressureTrack, pressureFill = bar(statusSection, {
		Position = UDim2.fromOffset(0, 89),
		Size = UDim2.new(1, 0, 0, 9),
	}, false, COLOR_ATMOSPHERE)

	--========================================================================
	-- CHANGED (Phase 5): orbit panel with the navball, above the cluster
	--========================================================================
	local orbitPanel = panel(root, {
		Name = "Orbit",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -(MARGIN + CLUSTER_INNER_HEIGHT + CLUSTER_PADDING * 2 + ORBIT_PANEL_GAP)),
		Size = UDim2.fromOffset(ORBIT_PANEL_WIDTH, ORBIT_PANEL_HEIGHT),
	})
	padding(orbitPanel, ORBIT_PANEL_PADDING)
	local columnWidth = (ORBIT_PANEL_WIDTH - ORBIT_PANEL_PADDING * 2 - NAVBALL_SIZE) / 2 - 8
	local function orbitColumn(x: number, align: Enum.TextXAlignment, title: string, timeTitle: string, footer: string)
		local column = frame(orbitPanel, { Position = UDim2.fromOffset(x, 0), Size = UDim2.new(0, columnWidth, 1, 0) })
		caption(column, { Position = UDim2.fromOffset(0, 0), Text = title, TextXAlignment = align })
		local value = label(column, {
			Position = UDim2.fromOffset(0, 14),
			Size = UDim2.new(1, 0, 0, 28),
			Font = FONT_HEAVY,
			TextSize = 24,
			TextXAlignment = align,
			TextTruncate = Enum.TextTruncate.AtEnd,
			Text = NOT_APPLICABLE,
		})
		caption(column, { Position = UDim2.fromOffset(0, 46), Text = timeTitle, TextXAlignment = align })
		local time = label(column, {
			Position = UDim2.fromOffset(0, 60),
			Size = UDim2.new(1, 0, 0, 20),
			Font = FONT_BOLD,
			TextSize = 17,
			TextXAlignment = align,
			Text = NOT_APPLICABLE,
		})
		caption(column, { Position = UDim2.fromOffset(0, 92), Text = footer, TextXAlignment = align })
		local foot = label(column, {
			Position = UDim2.fromOffset(0, 106),
			Size = UDim2.new(1, 0, 0, 22),
			Font = FONT_HEAVY,
			TextSize = 19,
			TextXAlignment = align,
			TextColor3 = COLOR_ACCENT_LIGHT,
			Text = "-",
		})
		return value, time, foot
	end
	local inner = ORBIT_PANEL_WIDTH - ORBIT_PANEL_PADDING * 2
	local apText, apTimeText, headingText =
		orbitColumn(0, Enum.TextXAlignment.Left, "APOAPSIS", "TIME TO AP", "HEADING")
	local peText, peTimeText, pitchText =
		orbitColumn(inner - columnWidth, Enum.TextXAlignment.Right, "PERIAPSIS", "TIME TO PE", "PITCH")
	local navballHolder = frame(orbitPanel, {
		Name = "NavballHolder",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(NAVBALL_SIZE, NAVBALL_SIZE),
	})
	local navball = Navball.create(navballHolder, NAVBALL_SIZE)

	--========================================================================
	-- Bottom right: stage stack
	--========================================================================
	local stagePanel = panel(root, {
		Name = "Stages",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -MARGIN, 1, -MARGIN),
		Size = UDim2.fromOffset(STAGE_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
	})
	padding(stagePanel, 10)
	new("UIListLayout", {
		FillDirection = Enum.FillDirection.Vertical,
		Padding = UDim.new(0, 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
	}, stagePanel)

	local craftHeader = frame(stagePanel, { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 36) })
	local craftNameText = label(craftHeader, {
		Size = UDim2.new(1, 0, 0, 22),
		Font = FONT_HEAVY,
		TextSize = 19,
		TextColor3 = COLOR_ACCENT,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = "",
	})
	local roleText = label(craftHeader, {
		Position = UDim2.fromOffset(0, 21),
		Size = UDim2.new(1, 0, 0, 15),
		Font = FONT,
		TextSize = 12,
		TextColor3 = COLOR_TEXT_DIM,
		Text = "",
	})

	local stagesHeader = frame(stagePanel, { LayoutOrder = 2, Size = UDim2.new(1, 0, 0, 14) })
	caption(stagesHeader, { Text = "STAGES" })
	local stageCountText = caption(stagesHeader, { TextXAlignment = Enum.TextXAlignment.Right, Text = "" })

	local cards: { StageCard } = {}
	for index = 1, MAX_STAGE_CARDS do
		local card = frame(stagePanel, {
			Name = "Stage" .. index,
			LayoutOrder = 2 + index,
			Size = UDim2.new(1, 0, 0, STAGE_CARD_HEIGHT),
			BackgroundColor3 = COLOR_SURFACE,
			BackgroundTransparency = 0.2,
			Visible = false,
		})
		corner(card, CORNER_SMALL)
		local cardStroke = stroke(card, COLOR_PANEL_STROKE, 1.5, 0.6)
		gradient(card)
		padding(card, 8)
		local badge = frame(card, {
			AnchorPoint = Vector2.new(0, 0.5),
			Position = UDim2.fromScale(0, 0.5),
			Size = UDim2.fromOffset(30, 30),
			BackgroundColor3 = COLOR_DEEP,
			BackgroundTransparency = 0.1,
		})
		corner(badge, 15)
		local badgeText = label(badge, {
			Size = UDim2.fromScale(1, 1),
			Font = FONT_HEAVY,
			TextSize = 16,
			TextXAlignment = Enum.TextXAlignment.Center,
			Text = "",
		})
		local title = label(card, {
			Position = UDim2.fromOffset(38, 0),
			Size = UDim2.new(1, -38, 0, 16),
			Font = FONT_BOLD,
			TextSize = 13,
			Text = "",
		})
		local key = keycap(card, "SPACE", {
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.fromScale(1, 0),
			BackgroundColor3 = COLOR_ACCENT,
			BackgroundTransparency = 0,
			TextColor3 = COLOR_TEXT_DARK,
			Visible = false,
		})
		local dv = label(card, {
			Position = UDim2.fromOffset(38, 17),
			Size = UDim2.new(1, -38, 0, 14),
			Font = FONT_MEDIUM,
			TextSize = 12,
			TextColor3 = COLOR_TEXT_DIM,
			Text = "",
		})
		local fuelText = label(card, {
			Position = UDim2.fromOffset(38, 17),
			Size = UDim2.new(1, -38, 0, 14),
			Font = FONT_BOLD,
			TextSize = 12,
			TextColor3 = COLOR_TEXT_DIM,
			TextXAlignment = Enum.TextXAlignment.Right,
			Text = "",
		})
		local _fuelTrack, fuelFill = bar(card, {
			Position = UDim2.fromOffset(38, 33),
			Size = UDim2.new(1, -38, 0, 7),
		}, false, COLOR_ACCENT_LIGHT)
		cards[index] = {
			frame = card,
			stroke = cardStroke,
			badge = badge,
			badgeText = badgeText,
			title = title,
			key = key,
			dv = dv,
			fuelText = fuelText,
			fuelFill = fuelFill,
		}
	end
	local moreText = label(stagePanel, {
		LayoutOrder = 3 + MAX_STAGE_CARDS,
		Size = UDim2.new(1, 0, 0, 14),
		Font = FONT_BOLD,
		TextSize = 12,
		TextColor3 = COLOR_TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
	})
	local noStagesText = label(stagePanel, {
		LayoutOrder = 4 + MAX_STAGE_CARDS,
		Size = UDim2.new(1, 0, 0, 16),
		Font = FONT_MEDIUM,
		TextSize = 13,
		TextColor3 = COLOR_TEXT_DIM,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "No stages left",
		Visible = false,
	})

	--========================================================================
	-- Bottom left: controls (pilot only)
	--========================================================================
	local controls = panel(root, {
		Name = "Controls",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, MARGIN, 1, -MARGIN),
		Size = UDim2.fromOffset(CONTROLS_WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.3,
		Visible = false,
	})
	new("UIPadding", {
		PaddingTop = UDim.new(0, 8),
		PaddingBottom = UDim.new(0, 8),
		PaddingLeft = UDim.new(0, 12),
		PaddingRight = UDim.new(0, 12),
	}, controls)
	label(controls, {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Font = FONT_MEDIUM,
		TextSize = 13,
		TextColor3 = COLOR_TEXT,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		LineHeight = 1.15,
		RichText = true,
		Text = CONTROLS_TEXT,
	})

	--========================================================================
	-- Top centre: pre-launch banner + countdown
	--========================================================================
	local banner = frame(root, {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, BANNER_Y),
		Size = UDim2.fromOffset(0, BANNER_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = COLOR_PANEL,
		BackgroundTransparency = 0.08,
		Visible = false,
	})
	corner(banner, BANNER_HEIGHT // 2)
	local bannerStroke = stroke(banner, COLOR_ACCENT, 2, 0)
	gradient(banner)
	new("UIPadding", { PaddingLeft = UDim.new(0, 26), PaddingRight = UDim.new(0, 26) }, banner)
	local bannerText = label(banner, {
		Size = UDim2.fromOffset(0, BANNER_HEIGHT),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = FONT_HEAVY,
		TextSize = 26,
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Center,
		Text = "",
	})

	local countdownText = label(root, {
		Name = "Countdown",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, BANNER_Y + BANNER_HEIGHT + 6),
		Size = UDim2.fromOffset(260, COUNTDOWN_SIZE),
		Font = FONT_HEAVY,
		TextSize = COUNTDOWN_SIZE,
		TextColor3 = COLOR_ACCENT_LIGHT,
		TextXAlignment = Enum.TextXAlignment.Center,
		Visible = false,
	})
	new("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual,
		Color = COLOR_DEEP,
		Thickness = 4,
		Transparency = 0.1,
	}, countdownText)
	local countdownScale: UIScale = new("UIScale", {}, countdownText)

	--========================================================================
	-- Hint (outside the HUD root: stays usable while the HUD is hidden)
	--========================================================================
	local hint = frame(canvas, {
		Name = "Hint",
		AnchorPoint = Vector2.new(0.5, 1),
		-- CHANGED (Phase 5): above the orbit panel
		Position = UDim2.new(
			0.5,
			0,
			1,
			-(MARGIN + CLUSTER_INNER_HEIGHT + CLUSTER_PADDING * 2 + ORBIT_PANEL_GAP + ORBIT_PANEL_HEIGHT + 10)
		),
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		BackgroundColor3 = COLOR_PANEL,
		BackgroundTransparency = 0.08,
		Visible = false,
		ZIndex = 5,
	})
	corner(hint, 16)
	stroke(hint, COLOR_INFO, 1.5, 0.1)
	new("UIPadding", { PaddingLeft = UDim.new(0, 16), PaddingRight = UDim.new(0, 16) }, hint)
	local hintText = label(hint, {
		Size = UDim2.fromOffset(0, 32),
		AutomaticSize = Enum.AutomaticSize.X,
		Font = FONT_BOLD,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Center,
		ZIndex = 6,
	})

	--========================================================================
	-- Update
	--========================================================================
	local function renderStages(data: HudData.HudData)
		local stages = data.stages
		local count = #stages
		for index, card in cards do
			local info = stages[index]
			set(card.frame, "Visible", info ~= nil)
			if info then
				local fuel = math.clamp(info.fuelFraction, 0, 1)
				local isNext = info.isNext
				set(card.stroke, "Color", if isNext then COLOR_ACCENT else COLOR_PANEL_STROKE)
				set(card.stroke, "Transparency", if isNext then 0 else 0.6)
				set(card.badge, "BackgroundColor3", if isNext then COLOR_ACCENT else COLOR_DEEP)
				set(card.badgeText, "TextColor3", if isNext then COLOR_TEXT_DARK else COLOR_TEXT)
				set(card.badgeText, "Text", tostring(info.stage))
				set(card.title, "Text", "STAGE " .. info.stage)
				set(card.title, "TextColor3", if isNext then COLOR_TEXT else COLOR_TEXT_DIM)
				set(card.key, "Visible", isNext and data.isPilot)
				set(card.dv, "Text", DV .. " " .. formatInt(info.dvVac) .. " m/s")
				set(
					card.fuelText,
					"Text",
					if fuel <= 0 then "EMPTY" else string.format("%d%%", math.floor(fuel * 100 + 0.5))
				)
				set(card.fuelText, "TextColor3", if fuel < LOW_FUEL then COLOR_BAD else COLOR_TEXT_DIM)
				set(card.fuelFill, "Size", UDim2.fromScale(math.floor(fuel * 200 + 0.5) / 200, 1))
				set(card.fuelFill, "BackgroundColor3", if fuel < LOW_FUEL then COLOR_BAD else COLOR_ACCENT_LIGHT)
			end
		end
		local hidden = count - MAX_STAGE_CARDS
		set(moreText, "Visible", hidden > 0)
		if hidden > 0 then
			set(moreText, "Text", `+{hidden} more`)
		end
		set(noStagesText, "Visible", count == 0)
		set(stageCountText, "Text", if count == 1 then "1 left" else `{count} left`)
	end

	local function update(data: HudData.HudData?)
		if not data then
			set(root, "Visible", false)
			return
		end
		set(root, "Visible", true)
		local isPilot = data.isPilot

		-- Throttle
		local throttle = math.clamp(data.throttle, 0, 1)
		local quantized = math.floor(throttle / THROTTLE_QUANTUM + 0.5) * THROTTLE_QUANTUM
		set(throttleFill, "Size", UDim2.fromScale(1, quantized))
		set(throttleText, "Text", string.format("%d%%", math.floor(throttle * 100 + 0.5)))
		set(throttleText, "TextColor3", if throttle > 0 then COLOR_TEXT else COLOR_TEXT_DIM)

		-- Altitude
		set(bodyPill, "Text", data.bodyName)
		set(altitudeText, "Text", formatDistance(data.altitude))
		set(radarText, "Text", formatDistance(data.radarAltitude))

		-- Speeds
		local vs = data.verticalSpeed
		if vs >= VS_DEADBAND then
			set(verticalText, "Text", VS_UP_PREFIX .. formatSpeed(vs))
			set(verticalText, "TextColor3", COLOR_GOOD)
		elseif vs <= -VS_DEADBAND then
			set(verticalText, "Text", VS_DOWN_PREFIX .. formatSpeed(-vs))
			set(verticalText, "TextColor3", COLOR_BAD)
		else
			set(verticalText, "Text", formatSpeed(0))
			set(verticalText, "TextColor3", COLOR_TEXT_DIM)
		end
		set(surfaceText, "Text", formatSpeed(data.surfaceSpeed))
		set(orbitalText, "Text", formatSpeed(data.orbitalSpeed))

		-- Engines light
		local burning = data.burning
		set(enginesPill, "BackgroundColor3", if burning then COLOR_ACCENT else COLOR_SURFACE)
		set(enginesStroke, "Color", if burning then COLOR_ACCENT_LIGHT else COLOR_PANEL_STROKE)
		set(enginesStroke, "Transparency", if burning then 0 else 0.4)
		set(enginesDot, "BackgroundColor3", if burning then Color3.new(1, 1, 1) else COLOR_TEXT_DIM)
		set(enginesText, "TextColor3", if burning then COLOR_TEXT_DARK else COLOR_TEXT_DIM)

		-- SAS
		local sas = data.sas
		set(sasPill, "BackgroundColor3", if sas then COLOR_GOOD else COLOR_SURFACE)
		set(sasStroke, "Color", if sas then COLOR_GOOD else COLOR_PANEL_STROKE)
		set(sasStroke, "Transparency", if sas then 0 else 0.4)
		set(sasText, "Text", if sas then "SAS ON" else "SAS OFF")
		set(sasText, "TextColor3", if sas then COLOR_TEXT_DARK else COLOR_TEXT_DIM)
		set(sasKey, "Visible", isPilot)

		-- TWR / delta-v
		local twr = data.twr
		set(twrText, "Text", formatTwr(twr))
		set(
			twrText,
			"TextColor3",
			if twr ~= twr or twr <= 0 then COLOR_TEXT_DIM elseif twr < 1 then COLOR_BAD else COLOR_TEXT
		)
		set(dvText, "Text", formatInt(data.dvRemaining) .. " m/s")

		-- Atmosphere
		local pressure = math.clamp(data.pressure, 0, 1)
		if data.inAtmosphere then
			set(pressureText, "Text", string.format("%d%%", math.floor(pressure * 100 + 0.5)))
			set(pressureText, "TextColor3", COLOR_ATMOSPHERE)
			set(pressureFill, "Size", UDim2.fromScale(math.floor(pressure * 200 + 0.5) / 200, 1))
		else
			set(pressureText, "Text", "VACUUM")
			set(pressureText, "TextColor3", COLOR_TEXT_DIM)
			set(pressureFill, "Size", UDim2.fromScale(0, 1))
		end

		-- CHANGED (Phase 5): orbit panel and navball
		set(apText, "Text", formatApsis(data.apoapsis))
		set(peText, "Text", formatApsis(data.periapsis))
		local pe = data.periapsis
		set(peText, "TextColor3", if pe ~= nil and pe < 0 then COLOR_BAD else COLOR_TEXT)
		set(apTimeText, "Text", formatDuration(data.timeToApoapsis))
		set(peTimeText, "Text", formatDuration(data.timeToPeriapsis))
		set(orbitPanel, "Visible", data.attitude ~= nil)
		local heading, pitch = navball.update(data.attitude, data.horizon, data.velocity)
		navball.setRails(data.onRails)
		set(headingText, "Text", string.format("%03d°", math.floor(heading + 0.5) % 360))
		set(pitchText, "Text", string.format("%+d°", math.floor(pitch + 0.5)))

		-- Stage stack
		set(craftNameText, "Text", data.craftName)
		set(roleText, "Text", if isPilot then "Pilot" else "Passenger")
		renderStages(data)

		-- Controls help
		set(controls, "Visible", isPilot)

		-- Banner / countdown
		local countdown = data.countdown
		if countdown then
			set(banner, "Visible", true)
			set(bannerText, "Text", "LIFTOFF IN")
			set(bannerText, "TextColor3", COLOR_TEXT)
			set(bannerStroke, "Color", COLOR_ACCENT)
			set(bannerStroke, "Transparency", 0)
			local whole = math.ceil(countdown)
			set(countdownText, "Visible", true)
			set(countdownText, "Text", if whole <= 0 then "GO!" else tostring(whole))
			local frac = math.clamp(countdown - math.floor(countdown), 0, 1)
			countdownScale.Scale = 1 + COUNTDOWN_PULSE * frac ^ 4 -- big right after each tick, settles to 1
		elseif data.prelaunch then
			set(banner, "Visible", true)
			set(countdownText, "Visible", false)
			if isPilot then
				set(bannerText, "Text", `PRESS <font color="{KEY_HEX}">SPACE</font> TO LAUNCH`)
				set(bannerText, "TextColor3", COLOR_TEXT)
				set(bannerStroke, "Color", COLOR_ACCENT)
				-- Gentle outline pulse to draw the eye (quantised, so it only writes when visible).
				local pulse = 0.45 - 0.45 * math.cos(os.clock() * BANNER_PULSE_SPEED)
				set(bannerStroke, "Transparency", math.floor(pulse * 50 + 0.5) / 50)
			else
				set(bannerText, "Text", "Waiting for the pilot...")
				set(bannerText, "TextColor3", COLOR_TEXT_DIM)
				set(bannerStroke, "Color", COLOR_PANEL_STROKE)
				set(bannerStroke, "Transparency", 0.2)
			end
		else
			set(banner, "Visible", false)
			set(countdownText, "Visible", false)
		end
	end

	local function setHint(text: string?)
		if text and text ~= "" then
			hintText.Text = text
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
