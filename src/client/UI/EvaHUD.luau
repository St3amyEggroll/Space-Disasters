--!strict
--[[
	EvaHUD (Phase 6)
	The small HUD of an astronaut on EVA (a spacewalk), in the Phase 11 KSP look (UI/Kit, UI/Theme):
	  * BOTTOM CENTRE  a panel: "SPACEWALK" and the mode (FLOATING / WALKING), the JETPACK fuel bar (red when low),
	                   the NEAREST craft (name, distance, speed relative to it), the height above the GROUND with the
	                   body's name, and two lamps: JETPACK (firing) and LIGHT (helmet light on)
	  * above it       a BOARD pill while a seat prompt is in reach ("Press E to Pilot: Command Pod")
	  * BOTTOM LEFT    key hints (Settings hints), built from Keybinds, so a rebind updates them at once; they change
	                   with the mode (floating: jetpack directions and brake; walking: walk, jump, hop)
	  * TOP RIGHT      "Settings" and "Return to plot" (callbacks.onReturn; EvaController asks first)
	Hidden with the hudVisible setting (F2), and while the main menu is open.

	Pure view, like FlightHUD: update(data) is called every frame (nil hides it) and only writes properties that
	changed; every instance is created once in create().

	API:
	  EvaHUD.create(callbacks: { onReturn: () -> () }) -> EvaHUD
	  hud.update(data: Data?)
]]

local GuiService = game:GetService("GuiService")

local Format = require(script.Parent.Format)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local Kit = require(script.Parent.Kit)
local Settings = require(script.Parent.Parent.Settings.Settings)
local SettingsPanel = require(script.Parent.SettingsPanel)
local Theme = require(script.Parent.Theme)
local UIState = require(script.Parent.UIState)

--============================================================================
-- Tunables
--============================================================================
local GUI_NAME = "EvaHUD"
local MARGIN = 12 -- design px from the screen edges
local PANEL_SIZE = Vector2.new(380, 124)
local ROW_HEIGHT = 16
local LABEL_WIDTH = 74
local VALUE_WIDTH = 48
local LAMP_SIZE = Vector2.new(84, 20)
local BOARD_HEIGHT = 30
local TOP_BUTTON_HEIGHT = 28
local SETTINGS_BUTTON_WIDTH = 92
local RETURN_BUTTON_WIDTH = 128
local LOW_FUEL = 0.2 -- the bar turns red below this
local NOT_AVAILABLE = "--"
--============================================================================

export type Mode = "Float" | "Walk"

export type Data = {
	mode: Mode,
	fuel: number, -- 0..1
	thrusting: boolean,
	light: boolean,
	bodyName: string,
	groundHeight: number?, -- m of the feet above the ground (nil far from any ground)
	targetName: string?, -- the nearest craft
	targetDistance: number?, -- m
	targetSpeed: number?, -- m/s relative to it
	boardText: string?, -- "Press E to Pilot: Command Pod" while a seat prompt is shown
}

export type Callbacks = {
	onReturn: () -> (),
}

export type EvaHUD = {
	update: (data: Data?) -> (),
}

type Lamp = { frame: Frame, stroke: UIStroke, text: TextLabel, litColor: Color3 }

local EvaHUD = {}

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
		Size = UDim2.new(1, 0, 0, ROW_HEIGHT),
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

function EvaHUD.create(callbacks: Callbacks): EvaHUD
	local screen, canvas = Kit.screen(GUI_NAME, Theme.DisplayOrder.HUD)
	screen.Enabled = not UIState.isMenuOpen()
	UIState.onMenuChanged(function(open: boolean)
		screen.Enabled = not open
	end)
	local root = Kit.frame(canvas, { name = "EVA" })
	root.Visible = false

	-- per-property write cache (update runs every frame)
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
	-- Bottom centre: the panel
	--========================================================================
	local panel = passive(Kit.panel({
		parent = root,
		name = "Spacewalk",
		size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y),
		position = UDim2.new(0.5, 0, 1, -MARGIN),
		anchor = Vector2.new(0.5, 1),
		padding = Theme.Padding.Medium,
	}))
	text(panel, {
		Text = "SPACEWALK",
		TextColor3 = Theme.Colors.Title,
		Font = Theme.Fonts.ExtraBold,
		TextSize = Theme.TextSizes.Body,
		Size = UDim2.new(0.5, 0, 0, 18),
	})
	local modeText = text(panel, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0.5, 0, 0, 18),
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = Theme.Colors.TextDim,
	})

	local function row(y: number, label: string): (TextLabel, number)
		text(panel, {
			Position = UDim2.fromOffset(0, y),
			Size = UDim2.fromOffset(LABEL_WIDTH, ROW_HEIGHT),
			TextSize = Theme.TextSizes.Tiny,
			TextColor3 = Theme.Colors.TextDim,
			Text = label,
		})
		local value = text(panel, {
			Position = UDim2.fromOffset(LABEL_WIDTH, y),
			Size = UDim2.new(1, -LABEL_WIDTH, 0, ROW_HEIGHT),
		})
		return value, y
	end

	-- jetpack fuel
	local fuelY = 24
	text(panel, {
		Position = UDim2.fromOffset(0, fuelY),
		Size = UDim2.fromOffset(LABEL_WIDTH, ROW_HEIGHT),
		TextSize = Theme.TextSizes.Tiny,
		TextColor3 = Theme.Colors.TextDim,
		Text = "JETPACK",
	})
	local fuelBar = Kit.bar(panel, {
		name = "Fuel",
		size = UDim2.new(1, -(LABEL_WIDTH + VALUE_WIDTH + Theme.Padding.Small), 0, 8),
		position = UDim2.fromOffset(LABEL_WIDTH, fuelY + ROW_HEIGHT / 2),
		anchor = Vector2.new(0, 0.5),
		color = Theme.Colors.Accent,
	})
	local fuelText = text(panel, {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, 0, 0, fuelY),
		Size = UDim2.fromOffset(VALUE_WIDTH, ROW_HEIGHT),
		TextXAlignment = Enum.TextXAlignment.Right,
	})

	local targetText = row(fuelY + 20, "NEAREST")
	local groundText = row(fuelY + 40, "GROUND")

	-- lamps
	local lampY = fuelY + 62
	local function lamp(index: number, label: string, litColor: Color3): Lamp
		local frame: Frame = new("Frame", {
			Name = label,
			Position = UDim2.fromOffset((index - 1) * (LAMP_SIZE.X + Theme.Padding.Small), lampY),
			Size = UDim2.fromOffset(LAMP_SIZE.X, LAMP_SIZE.Y),
			BackgroundColor3 = Theme.Colors.GaugeMetalDark,
			BorderSizePixel = 0,
			Active = false,
		}, panel)
		Kit.corner(frame, Theme.Radius.Small)
		local stroke = Kit.stroke(frame, Theme.Colors.GaugeFace, Theme.Stroke.Thin)
		local t = text(frame, {
			Size = UDim2.fromScale(1, 1),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextSize = Theme.TextSizes.Tiny,
			TextColor3 = Theme.Colors.TextDim,
			Text = label,
		})
		return { frame = frame, stroke = stroke, text = t, litColor = litColor }
	end
	local thrustLamp = lamp(1, "JETPACK", Theme.Colors.Warning)
	local lightLamp = lamp(2, "LIGHT", Theme.Colors.Accent)
	local function setLamp(l: Lamp, lit: boolean)
		set(l.frame, "BackgroundColor3", if lit then l.litColor else Theme.Colors.GaugeMetalDark)
		set(l.stroke, "Color", if lit then Theme.Colors.DigitText else Theme.Colors.GaugeFace)
		set(l.text, "TextColor3", if lit then Theme.Colors.ButtonText else Theme.Colors.TextDim)
	end

	--========================================================================
	-- Board pill (above the panel)
	--========================================================================
	local board = passive(Kit.panel({
		parent = root,
		name = "Board",
		size = UDim2.fromOffset(0, BOARD_HEIGHT),
		position = UDim2.new(0.5, 0, 1, -(MARGIN + PANEL_SIZE.Y + Theme.Padding.Medium)),
		anchor = Vector2.new(0.5, 1),
		padding = Theme.Padding.Small,
	}))
	board.AutomaticSize = Enum.AutomaticSize.X
	board.Visible = false
	local boardStroke = board:FindFirstChildOfClass("UIStroke")
	if boardStroke then
		boardStroke.Color = Theme.Colors.Title
	end
	local boardText = text(board, {
		Size = UDim2.new(0, 0, 1, 0),
		AutomaticSize = Enum.AutomaticSize.X,
		TextSize = Theme.TextSizes.Body,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.None,
	})

	--========================================================================
	-- Bottom left: key hints
	--========================================================================
	local hintsPanel = passive(Kit.panel({
		parent = root,
		name = "KeyHints",
		size = UDim2.new(),
		position = UDim2.new(0, MARGIN, 1, -MARGIN),
		anchor = Vector2.new(0, 1),
		padding = Theme.Padding.Medium,
	}))
	hintsPanel.AutomaticSize = Enum.AutomaticSize.XY
	hintsPanel.BackgroundTransparency = 0.35
	local hintsText = text(hintsPanel, {
		Size = UDim2.new(),
		AutomaticSize = Enum.AutomaticSize.XY,
		Font = Theme.Fonts.Medium,
		TextSize = Theme.TextSizes.Small,
		TextTruncate = Enum.TextTruncate.None,
		TextYAlignment = Enum.TextYAlignment.Top,
		LineHeight = 1.2,
		RichText = true,
	})
	local hintsFor: Mode? = nil -- the mode the hints were built for (nil = rebuild)
	local function buildHints(mode: Mode)
		hintsFor = mode
		local lines: { string }
		if mode == "Float" then
			lines = {
				`{keyText("EvaForward")}{keyText("EvaLeft")}{keyText("EvaBack")}{keyText("EvaRight")} jetpack (where you look)`,
				`{keyText("EvaUp")} / {keyText("EvaDown")} up / down   {keyText("EvaBrake")} brake (stop drifting)`,
				`<b>E</b> board a seat   {keyText("EvaLight")} light   {keyText("MapView")} map   {keyText("ToggleHUD")} hide HUD`,
				"Right-drag: turn the camera   Wheel: zoom",
			}
		else
			lines = {
				`WASD walk   Space jump   hold {keyText("EvaUp")} jetpack hop`,
				`<b>E</b> board a seat   {keyText("EvaLight")} light   {keyText("MapView")} map   {keyText("ToggleHUD")} hide HUD`,
			}
		end
		hintsText.Text = table.concat(lines, "\n")
	end
	Keybinds.onChanged(function()
		hintsFor = nil
	end)

	--========================================================================
	-- Top right: Settings and Return to plot
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
	Kit.button(topButtons, "Return to plot", function()
		callbacks.onReturn()
	end, {
		name = "ReturnToPlot",
		style = "Danger",
		size = UDim2.fromOffset(RETURN_BUTTON_WIDTH, TOP_BUTTON_HEIGHT),
		layoutOrder = 2,
	})
	-- below the Roblox top bar (Kit screens ignore the GUI inset), like FlightHUD
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
	-- Update
	--========================================================================
	local function update(data: Data?)
		if data == nil or not Settings.current().hudVisible then
			set(root, "Visible", false)
			return
		end
		local d = data :: Data
		set(root, "Visible", true)
		set(modeText, "Text", if d.mode == "Float" then "FLOATING" else "WALKING")

		local fuel = math.clamp(d.fuel, 0, 1)
		local low = fuel < LOW_FUEL
		fuelBar.set(math.floor(fuel * 200 + 0.5) / 200)
		fuelBar.setColor(if low then Theme.Colors.Danger else Theme.Colors.Accent)
		set(fuelText, "Text", if fuel <= 0 then "EMPTY" else Format.percent(fuel))
		set(fuelText, "TextColor3", if low then Theme.Colors.Danger else Theme.Colors.Text)

		local name, distance, speed = d.targetName, d.targetDistance, d.targetSpeed
		if name and distance and speed then
			set(targetText, "Text", `{name}   {Format.distance(distance)}   {Format.speed(speed)}`)
			set(targetText, "TextColor3", Theme.Colors.Text)
		else
			set(targetText, "Text", "no craft nearby")
			set(targetText, "TextColor3", Theme.Colors.TextDim)
		end
		local height = d.groundHeight
		set(
			groundText,
			"Text",
			if height then `{Format.distance(math.max(height, 0))}   {d.bodyName}` else `{NOT_AVAILABLE}   {d.bodyName}`
		)

		setLamp(thrustLamp, d.thrusting)
		setLamp(lightLamp, d.light)

		local boarding = d.boardText
		set(board, "Visible", boarding ~= nil)
		if boarding then
			set(boardText, "Text", boarding)
		end

		local hints = Settings.current().hints
		if hints and hintsFor ~= d.mode then
			buildHints(d.mode)
		end
		set(hintsPanel, "Visible", hints)
	end

	return { update = update }
end

return table.freeze(EvaHUD)
