--!strict
--[[
	AdminPanel (new file, Solar system; D51)
	The admin panel's dialog in the game's KSP look (UI/Kit, UI/Theme): Steamy's "admin panel for now to spawn in orbit
	with a ship of what ever planet or landed with a ship" until time warp exists. A centred panel:
	  Planet   Sol | Earth | Mun | Mars                     (AdminSpawn.bodies)
	  Mode     Orbit | Landed                                (Landed is greyed out for Sol)
	  Orbit    an altitude slider (log scale between AdminSpawn.altitudeRange's min and max, starting at its
	           default) with the range under it
	  Landed   the body's spots (AdminSpawn.spots: Earth "Launch pad" / "Random", the Mun "Random", Mars "Random" and
	           its landmarks)
	  Spawn (green) and Close. Every button and the slider work with touch (phones).
	Spawn calls the `onSpawn` callback given to AdminPanel.open with the request (AdminController fires the
	AdminSpawn remote; the server checks everything again) and closes the panel. While open the panel holds UIState
	modal "Admin" (gameplay ignores the player) and Escape closes it (Kit.onEscape).

	API:
	  AdminPanel.open(onSpawn(request))
	  AdminPanel.close()
	  AdminPanel.isOpen() -> boolean
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local AdminSpawn = require(ReplicatedStorage.Shared.Sim.AdminSpawn)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)
local UIState = require(script.Parent.UIState)

--============================================================================
-- Tunables
--============================================================================
local GUI_NAME = "AdminPanel"
local MODAL_NAME = "Admin"
local PANEL_SIZE = Vector2.new(480, 430) -- S, shrunk to fit small screens / a big UI size
local SCREEN_MARGIN = 16
local POP_SCALE = 0.95
local SLIDER_STEPS = 1000 -- the altitude slider runs 0..SLIDER_STEPS, mapped onto km on a log scale
local SEGMENT_HEIGHT = 34 -- S, tall enough for a thumb
local TITLE = "Admin Panel"
local SUBTITLE = "Spawn your ship (the rocket on your plot, or the Starter Rocket) anywhere."
local DEFAULT_BODY = Bodies.MARS
--============================================================================

export type Request = AdminSpawn.Request

type Segments = { frame: Frame, buttons: { [string]: TextButton }, set: (string) -> () }

local AdminPanel = {}

local isOpen = false
local removeEscape: (() -> ())? = nil
local spawnCallback: ((Request) -> ())? = nil

type View = {
	screen: ScreenGui,
	backdrop: TextButton,
	popScale: UIScale,
	bodies: Segments,
	modes: Segments,
	orbitPage: Frame,
	landedPage: Frame,
}
local view: View? = nil

-- selection
local bodyId = DEFAULT_BODY
local mode: AdminSpawn.Mode = "Orbit"
local altitudeKm = 0
local spot = AdminSpawn.SPOT_RANDOM

-- slider value (0..SLIDER_STEPS) <-> km, logarithmic between the body's limits
local function toKm(value: number): number
	local minKm, maxKm = AdminSpawn.altitudeRange(bodyId)
	local km = minKm * (maxKm / minKm) ^ (value / SLIDER_STEPS)
	return math.clamp(math.floor(km + 0.5), minKm, maxKm)
end

local function toValue(km: number): number
	local minKm, maxKm = AdminSpawn.altitudeRange(bodyId)
	if maxKm <= minKm then
		return 0
	end
	return math.log(km / minKm) / math.log(maxKm / minKm) * SLIDER_STEPS
end

local function formatKm(km: number): string
	if km >= 10000 then
		return string.format("%d,%03d km", math.floor(km / 1000), km % 1000)
	end
	return string.format("%d km", km)
end

-- A labelled row of equal-width buttons (one selected), e.g. the planets.
local function segments(
	parent: Instance,
	label: string,
	options: { string },
	initial: string,
	onChanged: (string) -> ()
): Segments
	local block = Kit.frame(parent, { name = label, size = UDim2.new(1, 0, 0, Theme.Sizes.Section + SEGMENT_HEIGHT) })
	Kit.section(block, label)
	local row = Kit.frame(block, {
		name = "Buttons",
		position = UDim2.fromOffset(0, Theme.Sizes.Section),
		size = UDim2.new(1, 0, 0, SEGMENT_HEIGHT),
	})
	Kit.list(row, { horizontal = true, gap = Theme.Padding.Small })
	local selected = initial
	local buttons: { [string]: TextButton } = {}
	local gap = Theme.Padding.Small
	local count = math.max(#options, 1)
	local function render()
		for option, button in buttons do
			Kit.setButtonStyle(button, if option == selected then "Primary" else "Ghost")
		end
	end
	for index, option in options do
		buttons[option] = Kit.button(row, option, function()
			if option ~= selected and Kit.isButtonEnabled(buttons[option]) then
				selected = option
				render()
				onChanged(option)
			end
		end, {
			size = UDim2.new(1 / count, -gap * (count - 1) / count, 1, 0),
			layoutOrder = index,
			textSize = Theme.TextSizes.Body,
			style = "Ghost",
		})
	end
	render()
	return {
		frame = block,
		buttons = buttons,
		set = function(option: string)
			selected = option
			render()
		end,
	}
end

local function bodyNames(): ({ string }, { [string]: number })
	local names, byName = {}, {}
	for _, id in AdminSpawn.bodies() do
		local name = Bodies.get(id).DisplayName
		table.insert(names, name)
		byName[name] = id
	end
	return names, byName
end

local refreshPages: () -> ()

-- The orbit page: a fresh slider for the selected body (its range changes with the body).
local function buildOrbitPage(v: View)
	for _, child in v.orbitPage:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	local minKm, maxKm, default = AdminSpawn.altitudeRange(bodyId)
	altitudeKm = default
	Kit.section(v.orbitPage, "Orbit altitude")
	Kit.slider(v.orbitPage, "Altitude", {
		min = 0,
		max = SLIDER_STEPS,
		step = 1,
		value = toValue(default),
		format = function(value: number): string
			return formatKm(toKm(value))
		end,
	}, function(value: number)
		altitudeKm = toKm(value)
	end)
	Kit.label(
		v.orbitPage,
		`{formatKm(minKm)} to {formatKm(maxKm)} above {Bodies.get(bodyId).DisplayName} (above the air, inside its SOI)`,
		{ dim = true, wrap = true, textSize = Theme.TextSizes.Small }
	)
end

-- The landed page: the selected body's spots.
local function buildLandedPage(v: View)
	for _, child in v.landedPage:GetChildren() do
		if not child:IsA("UIListLayout") then
			child:Destroy()
		end
	end
	local spots = AdminSpawn.spots(bodyId)
	if #spots == 0 then
		Kit.label(v.landedPage, `You can't land on {Bodies.get(bodyId).DisplayName}!`, { dim = true })
		return
	end
	spot = if table.find(spots, spot) then spot else spots[1]
	local hint: TextLabel? = nil
	local function hintText(): string
		return if spot == AdminSpawn.SPOT_PAD
			then "Launch pad: your ship stands on its pad, ready to launch."
			else "Your ship stands upright on flat ground there."
	end
	segments(v.landedPage, "Landing spot", spots, spot, function(option: string)
		spot = option
		if hint then
			hint.Text = hintText()
		end
	end)
	hint = Kit.label(v.landedPage, hintText(), { dim = true, wrap = true, textSize = Theme.TextSizes.Small })
end

refreshPages = function()
	local v = view
	if v == nil then
		return
	end
	local landable = #AdminSpawn.spots(bodyId) > 0
	if not landable and mode == "Landed" then
		mode = "Orbit"
	end
	Kit.setButtonEnabled(v.modes.buttons.Landed, landable)
	v.modes.set(mode)
	buildOrbitPage(v)
	buildLandedPage(v)
	v.orbitPage.Visible = mode == "Orbit"
	v.landedPage.Visible = mode == "Landed"
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
		name = "Admin",
		size = UDim2.fromOffset(PANEL_SIZE.X, PANEL_SIZE.Y),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
	})
	Kit.fitToCanvas(panel, canvas, PANEL_SIZE, SCREEN_MARGIN)
	local popScale: UIScale = Kit.new("UIScale", {}, panel)
	local gap = Theme.Padding.Medium

	local content = Kit.frame(panel, { name = "Content", size = UDim2.new(1, 0, 1, -(Theme.Sizes.Button + gap)) })
	Kit.list(content, { gap = gap })
	Kit.title(content, TITLE)
	Kit.label(content, SUBTITLE, { dim = true, wrap = true, textSize = Theme.TextSizes.Small })

	local names, byName = bodyNames()
	local bodySegments = segments(content, "Planet", names, Bodies.get(bodyId).DisplayName, function(name: string)
		bodyId = byName[name] or bodyId
		refreshPages()
	end)
	local modeSegments = segments(content, "Mode", AdminSpawn.MODES :: { string }, mode, function(option: string)
		mode = if option == "Landed" then "Landed" else "Orbit"
		refreshPages()
	end)
	local orbitPage = Kit.frame(content, { name = "Orbit", size = UDim2.new(1, 0, 0, 110) })
	Kit.list(orbitPage, { gap = Theme.Padding.Small })
	local landedPage = Kit.frame(content, { name = "Landed", size = UDim2.new(1, 0, 0, 110) })
	Kit.list(landedPage, { gap = Theme.Padding.Small })

	local bottom = Kit.frame(panel, {
		name = "Buttons",
		position = UDim2.fromScale(0, 1),
		anchor = Vector2.new(0, 1),
		size = UDim2.new(1, 0, 0, Theme.Sizes.Button),
	})
	Kit.button(bottom, "Spawn", function()
		local callback = spawnCallback
		if callback then
			callback({ bodyId = bodyId, mode = mode, altitudeKm = altitudeKm, spot = spot })
		end
		AdminPanel.close()
	end, { name = "Spawn", style = "Accent", size = UDim2.new(0.5, -gap / 2, 1, 0) })
	Kit.button(bottom, "Close", AdminPanel.close, {
		name = "Close",
		size = UDim2.new(0.5, -gap / 2, 1, 0),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
	})

	local built: View = {
		screen = screen,
		backdrop = backdrop,
		popScale = popScale,
		bodies = bodySegments,
		modes = modeSegments,
		orbitPage = orbitPage,
		landedPage = landedPage,
	}
	view = built
	return built
end

function AdminPanel.open(onSpawn: (Request) -> ())
	spawnCallback = onSpawn
	if isOpen then
		return
	end
	local v = build()
	isOpen = true
	refreshPages()
	v.screen.Enabled = true
	v.backdrop.BackgroundTransparency = 1
	v.popScale.Scale = POP_SCALE
	Kit.tween(v.backdrop, { BackgroundTransparency = Theme.Transparency.Backdrop }, Theme.Tween.Normal)
	Kit.tween(v.popScale, { Scale = 1 }, Theme.Tween.Normal)
	UIState.pushModal(MODAL_NAME)
	removeEscape = Kit.onEscape(AdminPanel.close)
end

function AdminPanel.close()
	if not isOpen then
		return
	end
	isOpen = false
	if removeEscape then
		removeEscape()
		removeEscape = nil
	end
	local v = view
	if v then
		v.screen.Enabled = false
	end
	UIState.popModal(MODAL_NAME)
end

function AdminPanel.isOpen(): boolean
	return isOpen
end

return table.freeze(AdminPanel)
