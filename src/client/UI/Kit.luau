--!strict
--[[
	Kit (Phase 11)
	The KSP-skinned widget kit every Phase 11 screen is built from (main menu, settings, flight HUD, builder), so they
	all look and behave the same. Colours, fonts and sizes come from UI/Theme; the maths (slider snapping, the screen
	scale, toast lifetimes) from UI/KitMath. No game logic: widgets only call the callbacks they are given.

	Conventions:
	  * Sizes are DESIGN PIXELS. Kit.screen returns (ScreenGui, canvas): parent everything to the CANVAS, which is
	    sized in design px and scaled with a UIScale to fit the screen (the 1366 x 710 design canvas, clamped), times
	    the player's "UI size" setting, live. Scale-based sizes still fill the screen.
	  * Every widget gets a LayoutOrder from a creation counter (unless given one), so inside a UIListLayout widgets
	    appear in the order they were created.
	  * Control widgets (toggle, slider, choice, tabs) call onChanged only for the PLAYER's changes; their set()
	    updates the view silently. Every set() is safe to call with the current value.
	  * Buttons fire on .Activated (mouse, touch and gamepad); hover / press feedback is a colour tween.
	  * Nothing leaks: widgets only connect to their own instances' signals, except the slider (UserInputService,
	    only while dragging) and Kit.screen (Settings), which disconnect on Destroying.
	  * Escape: Kit keeps ONE stack of escape handlers (Kit.onEscape); a press runs only the top one, so a dialog
	    over the settings over the menu closes one layer per press. Escape always opens the Roblox menu as well
	    (Roblox does that and it cannot be stopped); GuiService.MenuOpened is handled as Escape too, debounced.

	API (S = design px):
	  Screens
	    Kit.screen(name, displayOrder) -> (ScreenGui, Frame)   ResetOnSpawn false, IgnoreGuiInset true, Sibling
	                                     ZIndex, in PlayerGui; the Frame is the scaled canvas (parent content there).
	                                     Use Theme.DisplayOrder.*.
	    Kit.backdrop(parent) -> TextButton            full-screen dim that swallows clicks and frees a first-person
	                                                  mouse (Modal); ZIndex 0, so create it first
	    Kit.fitToCanvas(frame, canvas, maxSize: Vector2, margin?) -> ()  keeps frame at maxSize (S), shrunk to fit
	                                                  the canvas minus margin on every side (small screens / big UI)
	  Containers
	    Kit.panel({ parent, name?, size, position?, anchor?, padding?, transparency? }) -> Frame
	                                                  dark translucent rounded panel with a 1 px lighter border and
	                                                  inner padding (default Theme.Padding.Panel); Active (sinks clicks)
	    Kit.frame(parent, { name?, size?, position?, anchor?, layoutOrder? }?) -> Frame    invisible container
	    Kit.row(parent, height?) -> Frame             invisible full-width row (default Theme.Sizes.Row)
	    Kit.scroll(parent, { name?, size, position?, anchor?, padding?, gap? }) -> ScrollingFrame
	                                                  recessed vertical scroll list (UIListLayout + UIPadding inside,
	                                                  canvas grows with the content)
	    Kit.plate(parent, size, position?, anchor?) -> Frame        small dark gunmetal readout plate
	    Kit.gaugeBezel(parent, size, position?, anchor?) -> (Frame, Frame)
	                                                  round gunmetal bezel (stays round: aspect 1) and its black face;
	                                                  put the navball / needle inside the face (2nd return, "Face")
	  Text
	    Kit.title(parent, text) -> TextLabel          yellow-green panel title, full width, centred
	    Kit.label(parent, text, { size?, position?, anchor?, bold?, dim?, mono?, textSize?, align?, color?, wrap?,
	              layoutOrder? }?) -> TextLabel       default: full width, one line (truncated); wrap = grows down
	    Kit.section(parent, text) -> Frame            group header (upper case, Title colour) with a divider
	    Kit.keycap(parent, text, { position?, anchor?, layoutOrder? }?) -> TextLabel   light key badge ("Space")
	  Buttons
	    Kit.button(parent, text, onActivated, { style?, size?, position?, anchor?, layoutOrder?, textSize?, name? }?)
	              -> TextButton                       style "Primary" (KSP light grey, dark text; default),
	                                                  "Accent" (green), "Danger" (red), "Ghost" (dark)
	    Kit.setButtonEnabled(button, enabled)         disabled: greyed, ignores activation
	    Kit.isButtonEnabled(button) -> boolean
	    Kit.setButtonStyle(button, style)             e.g. selected tab = "Primary", others "Ghost"
	  Controls (rows of Theme.Sizes.Row, label on the left)
	    Kit.toggle(parent, label, initial, onChanged(boolean)) -> Toggle { frame, set(boolean), get() }
	    Kit.slider(parent, label, { min, max, step, value, format(number) -> string, live? }, onChanged(number))
	              -> Slider { frame, set(number), get() }   drag or click the track (mouse / touch); values snap to
	                                                  min + k * step; live = false reports only on release
	    Kit.choice(parent, label, options, initial, onChanged(string)) -> Choice { frame, set(string), get() }
	                                                  segmented buttons
	    Kit.tabs(parent, names, initial, onChanged(string)) -> Tabs { frame, set(string), get() }
	                                                  full-width tab strip (Theme.Sizes.Tab high)
	  Instruments
	    Kit.bar(parent, { size, position?, anchor?, color, vertical?, name?, layoutOrder? })
	              -> Bar { frame, set(fraction), setColor(Color3) }  fill bar (vertical fills upward); cheap to
	                                                  call every frame (writes only on change)
	  Dialogs and feedback
	    Kit.confirm({ title, body, confirmText, cancelText?, danger? }, onResult(confirmed))
	                                                  modal dialog in its own top ScreenGui (Theme.DisplayOrder.Dialog)
	                                                  with a dim backdrop; Escape / Cancel = false. Registers
	                                                  UIState modal "KitConfirm" while open. One at a time: a call
	                                                  while one is open is answered false at once (warns).
	                                                  CHANGED (Phase 11 review): returns cancel() (answers false and
	                                                  closes it if still open; a no-op afterwards)
	    Kit.isConfirmOpen() -> boolean
	    Kit.toast(text, kind?)                        "Info" | "Warning" | "Error"; top-centre stack that fades out
	                                                  (Theme.DisplayOrder.Toast); the same text again refreshes it
	    Kit.onEscape(handler) -> remove()             push an Escape handler; call remove() when the layer closes
	  Animation
	    Kit.tween(instance, props, time?) -> Tween    played at once; Quad Out, default Theme.Tween.Normal
	    Kit.fadeCanvas(group: CanvasGroup, visible, time?, onDone?)  fades GroupTransparency (Visible false when
	                                                  faded out); a newer fade of the same group supersedes the old
	                                                  one (its onDone never runs)
	  Low-level helpers (for custom widgets in the same style)
	    Kit.new(className, props, parent?) -> T       create + set properties + parent
	    Kit.corner(parent, radius?) -> UICorner       radius px (default Theme.Radius.Button)
	    Kit.round(parent) -> UICorner                 pill / circle
	    Kit.stroke(parent, color?, thickness?, transparency?) -> UIStroke
	    Kit.gradient(parent, top, bottom, rotation?) -> UIGradient   vertical colour multiplier (rotation 90)
	    Kit.padding(parent, px) -> UIPadding
	    Kit.list(parent, { horizontal?, gap?, align?, valign? }?) -> UIListLayout   LayoutOrder sorted
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local KitMath = require(script.Parent.KitMath)
local Settings = require(script.Parent.Parent.Settings.Settings)
local Theme = require(script.Parent.Theme)
local UIState = require(script.Parent.UIState)

--============================================================================
-- Tunables
--============================================================================
local UI_SCALE_FIELD = "uiScale" -- the Settings field Kit screens follow
local CANVAS_NAME = "Canvas"
local EASING_STYLE = Enum.EasingStyle.Quad
local EASING_DIRECTION = Enum.EasingDirection.Out
local LINE_HEIGHT = 1.4 -- a one-line label is this many times its text size high
local ROW_LABEL_FRACTION = 0.42 -- share of a control row taken by its label (slider, choice)
local SLIDER_VALUE_WIDTH = 72 -- S, the value text right of a slider
local KNOB_INSET = 3 -- S, gap between a toggle's knob and its track edge
local KEYCAP_PADDING = 5 -- S, left / right inside a keycap
local SECTION_DIVIDER = 1 -- S, divider line under a section header
local STYLE_ATTRIBUTE = "KitStyle" -- button style lives in an attribute, so setButtonStyle needs no registry
local ENABLED_ATTRIBUTE = "KitEnabled"
local FADE_ATTRIBUTE = "KitFadeToken"
local ESCAPE_DEBOUNCE_S = 0.35 -- one Escape press can arrive as InputBegan and MenuOpened
-- Confirm dialog
local DIALOG_GUI_NAME = "KitDialog"
local DIALOG_MODAL = "KitConfirm" -- UIState modal name while a confirm dialog is open
local DIALOG_WIDTH = 400 -- S
local DIALOG_POP_SCALE = 0.94 -- the dialog grows from this to 1 when it opens
local DIALOG_DEFAULT_CANCEL = "Cancel"
-- Toasts
local TOAST_GUI_NAME = "KitToasts"
local TOAST_BASE_S = 2.2 -- every toast stays at least this long
local TOAST_PER_CHAR_S = 0.05 -- plus this per character
local TOAST_MAX_S = 6
local TOAST_MAX_COUNT = 4 -- older toasts are dismissed beyond this
local TOAST_STRIP = 4 -- S, colour strip on the toast's left edge
local BUTTON_STYLES: {
	[string]: { base: Color3, hover: Color3, pressed: Color3, text: Color3, stroke: Color3 },
} = {
	Primary = {
		base = Theme.Colors.Button,
		hover = Theme.Colors.ButtonHover,
		pressed = Theme.Colors.ButtonPressed,
		text = Theme.Colors.ButtonText,
		stroke = Theme.Colors.ButtonStroke,
	},
	Accent = {
		base = Theme.Colors.Accent,
		hover = Theme.Colors.AccentHover,
		pressed = Theme.Colors.AccentDark,
		text = Theme.Colors.ButtonText,
		stroke = Theme.Colors.AccentDark,
	},
	Danger = {
		base = Theme.Colors.Danger,
		hover = Theme.Colors.DangerHover,
		pressed = Theme.Colors.DangerDark,
		text = Theme.Colors.Text,
		stroke = Theme.Colors.DangerDark,
	},
	Ghost = {
		base = Theme.Colors.Ghost,
		hover = Theme.Colors.GhostHover,
		pressed = Theme.Colors.GhostPressed,
		text = Theme.Colors.Text,
		stroke = Theme.Colors.PanelStroke,
	},
}
local TOAST_COLORS: { [string]: Color3 } = {
	Info = Theme.Colors.Title,
	Warning = Theme.Colors.Warning,
	Error = Theme.Colors.Danger,
}
--============================================================================

export type ButtonStyle = "Primary" | "Accent" | "Danger" | "Ghost"
export type ToastKind = "Info" | "Warning" | "Error"

export type PanelProps = {
	parent: Instance,
	name: string?,
	size: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	padding: number?,
	transparency: number?,
}

export type FrameProps = {
	name: string?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	layoutOrder: number?,
}

export type LabelProps = {
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	bold: boolean?,
	dim: boolean?,
	mono: boolean?,
	textSize: number?,
	align: Enum.TextXAlignment?,
	color: Color3?,
	wrap: boolean?,
	layoutOrder: number?,
}

export type KeycapProps = {
	position: UDim2?,
	anchor: Vector2?,
	layoutOrder: number?,
}

export type ButtonProps = {
	style: ButtonStyle?,
	size: UDim2?,
	position: UDim2?,
	anchor: Vector2?,
	layoutOrder: number?,
	textSize: number?,
	name: string?,
}

export type ScrollProps = {
	name: string?,
	size: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	padding: number?,
	gap: number?,
}

export type ListOptions = {
	horizontal: boolean?,
	gap: number?,
	align: Enum.HorizontalAlignment?,
	valign: Enum.VerticalAlignment?,
}

export type SliderOptions = {
	min: number,
	max: number,
	step: number,
	value: number,
	format: (number) -> string,
	live: boolean?, -- default true: onChanged while dragging; false: only on release
}

export type BarProps = {
	size: UDim2,
	position: UDim2?,
	anchor: Vector2?,
	color: Color3,
	vertical: boolean?,
	name: string?,
	layoutOrder: number?,
}

export type ConfirmOptions = {
	title: string,
	body: string,
	confirmText: string,
	cancelText: string?,
	danger: boolean?,
}

export type Toggle = { frame: Frame, set: (boolean) -> (), get: () -> boolean }
export type Slider = { frame: Frame, set: (number) -> (), get: () -> number }
export type Choice = { frame: Frame, set: (string) -> (), get: () -> string }
export type Tabs = { frame: Frame, set: (string) -> (), get: () -> string }
export type Bar = { frame: Frame, set: (fraction: number) -> (), setColor: (Color3) -> () }

type ToastEntry = {
	group: CanvasGroup,
	text: string,
	expires: number,
	closing: boolean,
}

type EscapeEntry = { handler: () -> () }

local Kit = {}

local nextLayoutOrder = 0
local escapeStack: { EscapeEntry } = {}
local escapeConnected = false
local lastEscape = -math.huge
local confirmOpen = false
local toastHolder: Frame? = nil
local toasts: { ToastEntry } = {}

local function layoutOrder(explicit: number?): number
	if explicit then
		return explicit
	end
	nextLayoutOrder += 1
	return nextLayoutOrder
end

--============================================================================
-- Low-level helpers
--============================================================================
function Kit.new<T>(className: string, props: { [string]: any }, parent: Instance?): T
	local instance = Instance.new(className)
	for key, value in props do
		(instance :: any)[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return (instance :: any) :: T
end

local new = Kit.new

function Kit.corner(parent: Instance, radius: number?): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0, radius or Theme.Radius.Button) }, parent)
end

function Kit.round(parent: Instance): UICorner
	return new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, parent)
end

function Kit.stroke(parent: Instance, color: Color3?, thickness: number?, transparency: number?): UIStroke
	return new("UIStroke", {
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		Color = color or Theme.Colors.PanelStroke,
		Thickness = thickness or Theme.Stroke.Thin,
		Transparency = transparency or 0,
	}, parent)
end

function Kit.gradient(parent: Instance, top: Color3, bottom: Color3, rotation: number?): UIGradient
	return new("UIGradient", { Color = ColorSequence.new(top, bottom), Rotation = rotation or 90 }, parent)
end

function Kit.padding(parent: Instance, px: number): UIPadding
	return new("UIPadding", {
		PaddingTop = UDim.new(0, px),
		PaddingBottom = UDim.new(0, px),
		PaddingLeft = UDim.new(0, px),
		PaddingRight = UDim.new(0, px),
	}, parent)
end

function Kit.list(parent: Instance, options: ListOptions?): UIListLayout
	local o: ListOptions = options or {}
	local horizontal = o.horizontal == true
	return new("UIListLayout", {
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		Padding = UDim.new(0, o.gap or Theme.Padding.Gap),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = o.align or Enum.HorizontalAlignment.Left,
		VerticalAlignment = o.valign
			or (if horizontal then Enum.VerticalAlignment.Center else Enum.VerticalAlignment.Top),
	}, parent)
end

function Kit.tween(instance: Instance, props: { [string]: any }, time: number?): Tween
	local tween =
		TweenService:Create(instance, TweenInfo.new(time or Theme.Tween.Normal, EASING_STYLE, EASING_DIRECTION), props)
	tween:Play()
	return tween
end

function Kit.fadeCanvas(group: CanvasGroup, visible: boolean, time: number?, onDone: (() -> ())?)
	local previous = group:GetAttribute(FADE_ATTRIBUTE)
	local token = (if type(previous) == "number" then previous else 0) + 1
	group:SetAttribute(FADE_ATTRIBUTE, token)
	if visible then
		group.Visible = true
	end
	local tween = Kit.tween(group, { GroupTransparency = if visible then 0 else 1 }, time or Theme.Tween.Fade)
	tween.Completed:Connect(function()
		if group:GetAttribute(FADE_ATTRIBUTE) ~= token then
			return -- a newer fade took over
		end
		if not visible then
			group.Visible = false
		end
		if onDone then
			onDone()
		end
	end)
end

--============================================================================
-- Escape stack
--============================================================================
local function fireEscape()
	local now = os.clock()
	if now - lastEscape < ESCAPE_DEBOUNCE_S then
		return
	end
	lastEscape = now
	local top = escapeStack[#escapeStack]
	if top then
		top.handler()
	end
end

local function connectEscape()
	if escapeConnected then
		return
	end
	escapeConnected = true
	-- gameProcessed is ignored: Roblox processes Escape itself (it opens its menu)
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.Escape then
			fireEscape()
		end
	end)
	GuiService.MenuOpened:Connect(fireEscape)
end

function Kit.onEscape(handler: () -> ()): () -> ()
	connectEscape()
	local entry: EscapeEntry = { handler = handler }
	table.insert(escapeStack, entry)
	return function()
		local index = table.find(escapeStack, entry)
		if index then
			table.remove(escapeStack, index)
		end
	end
end

--============================================================================
-- Screens
--============================================================================
function Kit.screen(name: string, displayOrder: number): (ScreenGui, Frame)
	local screen: ScreenGui = new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = displayOrder,
	}, nil)
	local canvas: Frame = new("Frame", {
		Name = CANVAS_NAME,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(Theme.Canvas.Width, Theme.Canvas.Height),
	}, screen)
	local canvasScale: UIScale = new("UIScale", {}, canvas)

	local function rescale()
		local size = screen.AbsoluteSize
		local s = KitMath.screenScale(
			size.X,
			size.Y,
			Settings.current().uiScale,
			Theme.Canvas.Width,
			Theme.Canvas.Height,
			Theme.Canvas.MinFit,
			Theme.Canvas.MaxFit
		)
		canvasScale.Scale = s
		if size.X >= 1 and size.Y >= 1 then
			canvas.Size = UDim2.fromOffset(size.X / s, size.Y / s)
		end
	end
	screen:GetPropertyChangedSignal("AbsoluteSize"):Connect(rescale)
	local settingsConnection = Settings.onChanged(function(field: string)
		if field == UI_SCALE_FIELD then
			rescale()
		end
	end)
	screen.Destroying:Connect(function()
		settingsConnection:Disconnect()
	end)

	screen.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	rescale()
	return screen, canvas
end

function Kit.backdrop(parent: Instance): TextButton
	return new("TextButton", {
		Name = "Backdrop",
		AutoButtonColor = false,
		BackgroundColor3 = Theme.Colors.Backdrop,
		BackgroundTransparency = Theme.Transparency.Backdrop,
		BorderSizePixel = 0,
		Modal = true, -- frees the mouse if the camera is in first person
		Selectable = false,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		ZIndex = 0,
	}, parent)
end

function Kit.fitToCanvas(frame: GuiObject, canvas: Frame, maxSize: Vector2, margin: number?)
	local m = margin or Theme.Padding.Huge
	local function fit()
		local available = canvas.Size
		local width = math.max(0, math.min(maxSize.X, available.X.Offset - m * 2))
		local height = math.max(0, math.min(maxSize.Y, available.Y.Offset - m * 2))
		frame.Size = UDim2.fromOffset(width, height)
	end
	local connection = canvas:GetPropertyChangedSignal("Size"):Connect(fit)
	frame.Destroying:Connect(function()
		connection:Disconnect()
	end)
	fit()
end

--============================================================================
-- Containers
--============================================================================
function Kit.panel(props: PanelProps): Frame
	local panel: Frame = new("Frame", {
		Name = props.name or "Panel",
		Size = props.size,
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchor or Vector2.zero,
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = props.transparency or Theme.Transparency.Panel,
		BorderSizePixel = 0,
		Active = true, -- clicks on panels must not reach the world behind them
		LayoutOrder = layoutOrder(nil),
	}, nil)
	Kit.corner(panel, Theme.Radius.Panel)
	Kit.stroke(panel, Theme.Colors.PanelStroke, Theme.Stroke.Thin)
	Kit.padding(panel, props.padding or Theme.Padding.Panel)
	panel.Parent = props.parent
	return panel
end

function Kit.frame(parent: Instance, props: FrameProps?): Frame
	local p: FrameProps = props or {}
	return new("Frame", {
		Name = p.name or "Frame",
		Size = p.size or UDim2.fromScale(1, 1),
		Position = p.position or UDim2.new(),
		AnchorPoint = p.anchor or Vector2.zero,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		LayoutOrder = layoutOrder(p.layoutOrder),
	}, parent)
end

function Kit.row(parent: Instance, height: number?): Frame
	return Kit.frame(parent, { name = "Row", size = UDim2.new(1, 0, 0, height or Theme.Sizes.Row) })
end

function Kit.scroll(parent: Instance, props: ScrollProps): ScrollingFrame
	local scroll: ScrollingFrame = new("ScrollingFrame", {
		Name = props.name or "Scroll",
		Size = props.size,
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchor or Vector2.zero,
		BackgroundColor3 = Theme.Colors.PanelInset,
		BackgroundTransparency = Theme.Transparency.Inset,
		BorderSizePixel = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = Theme.Sizes.ScrollBar,
		ScrollBarImageColor3 = Theme.Colors.PanelStroke,
		VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar,
		LayoutOrder = layoutOrder(nil),
	}, nil)
	Kit.corner(scroll, Theme.Radius.Small)
	Kit.padding(scroll, props.padding or Theme.Padding.Medium)
	Kit.list(scroll, { gap = props.gap or Theme.Padding.Small })
	scroll.Parent = parent
	return scroll
end

function Kit.plate(parent: Instance, size: UDim2, position: UDim2?, anchor: Vector2?): Frame
	local plate: Frame = new("Frame", {
		Name = "Plate",
		Size = size,
		Position = position or UDim2.new(),
		AnchorPoint = anchor or Vector2.zero,
		BackgroundColor3 = Color3.new(1, 1, 1), -- the gradient below carries the colour
		BackgroundTransparency = Theme.Transparency.Plate,
		BorderSizePixel = 0,
		LayoutOrder = layoutOrder(nil),
	}, nil)
	Kit.corner(plate, Theme.Radius.Small)
	Kit.gradient(plate, Theme.Colors.GaugeMetal, Theme.Colors.GaugeMetalDark)
	Kit.stroke(plate, Theme.Colors.GaugeFace, Theme.Stroke.Thin)
	plate.Parent = parent
	return plate
end

function Kit.gaugeBezel(parent: Instance, size: UDim2, position: UDim2?, anchor: Vector2?): (Frame, Frame)
	local bezel: Frame = new("Frame", {
		Name = "Bezel",
		Size = size,
		Position = position or UDim2.new(),
		AnchorPoint = anchor or Vector2.zero,
		BackgroundColor3 = Color3.new(1, 1, 1), -- the gradient carries the metal
		BorderSizePixel = 0,
		LayoutOrder = layoutOrder(nil),
	}, nil)
	new("UIAspectRatioConstraint", { AspectRatio = 1 }, bezel)
	Kit.round(bezel)
	new("UIGradient", {
		Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Theme.Colors.GaugeMetalLight),
			ColorSequenceKeypoint.new(0.45, Theme.Colors.GaugeMetal),
			ColorSequenceKeypoint.new(1, Theme.Colors.GaugeMetalDark),
		}),
		Rotation = 60, -- light from the top left
	}, bezel)
	Kit.stroke(bezel, Theme.Colors.GaugeMetalDark, Theme.Stroke.Medium)
	local faceScale = 1 - Theme.Sizes.BezelFraction * 2
	local face: Frame = new("Frame", {
		Name = "Face",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(faceScale, faceScale),
		BackgroundColor3 = Theme.Colors.GaugeFace,
		BorderSizePixel = 0,
	}, bezel)
	Kit.round(face)
	Kit.stroke(face, Theme.Colors.GaugeMetalDark, Theme.Stroke.Thin)
	bezel.Parent = parent
	return bezel, face
end

--============================================================================
-- Text
--============================================================================
function Kit.title(parent: Instance, text: string): TextLabel
	return new("TextLabel", {
		Name = "Title",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.new(1, 0, 0, Theme.Sizes.Title),
		Font = Theme.Fonts.Title,
		TextSize = Theme.TextSizes.Title,
		TextColor3 = Theme.Colors.Title,
		TextXAlignment = Enum.TextXAlignment.Center,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = text,
		LayoutOrder = layoutOrder(nil),
	}, parent)
end

function Kit.label(parent: Instance, text: string, props: LabelProps?): TextLabel
	local p: LabelProps = props or {}
	local textSize = p.textSize or Theme.TextSizes.Body
	local wrap = p.wrap == true
	local font = if p.mono then Theme.Fonts.Mono elseif p.bold then Theme.Fonts.Bold else Theme.Fonts.Body
	local color = p.color or (if p.dim then Theme.Colors.TextDim else Theme.Colors.Text)
	local label: TextLabel = new("TextLabel", {
		Name = "Label",
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = p.size or UDim2.new(1, 0, 0, math.ceil(textSize * LINE_HEIGHT)),
		Position = p.position or UDim2.new(),
		AnchorPoint = p.anchor or Vector2.zero,
		AutomaticSize = if wrap then Enum.AutomaticSize.Y else Enum.AutomaticSize.None,
		Font = font,
		TextSize = textSize,
		TextColor3 = color,
		TextXAlignment = p.align or Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
		TextWrapped = wrap,
		TextTruncate = if wrap then Enum.TextTruncate.None else Enum.TextTruncate.AtEnd,
		Text = text,
		LayoutOrder = layoutOrder(p.layoutOrder),
	}, parent)
	return label
end

function Kit.section(parent: Instance, text: string): Frame
	local section = Kit.frame(parent, { name = "Section", size = UDim2.new(1, 0, 0, Theme.Sizes.Section) })
	Kit.label(section, string.upper(text), {
		size = UDim2.new(1, 0, 1, -SECTION_DIVIDER),
		bold = true,
		textSize = Theme.TextSizes.Small,
		color = Theme.Colors.Title,
	})
	new("Frame", {
		Name = "Divider",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.new(1, 0, 0, SECTION_DIVIDER),
		BackgroundColor3 = Theme.Colors.PanelStroke,
		BorderSizePixel = 0,
	}, section)
	return section
end

function Kit.keycap(parent: Instance, text: string, props: KeycapProps?): TextLabel
	local p: KeycapProps = props or {}
	local cap: TextLabel = new("TextLabel", {
		Name = "Keycap",
		AutomaticSize = Enum.AutomaticSize.X,
		Size = UDim2.fromOffset(Theme.Sizes.Keycap, Theme.Sizes.Keycap),
		Position = p.position or UDim2.new(),
		AnchorPoint = p.anchor or Vector2.zero,
		BackgroundColor3 = Theme.Colors.Button,
		BorderSizePixel = 0,
		Font = Theme.Fonts.Bold,
		TextSize = Theme.TextSizes.Small,
		TextColor3 = Theme.Colors.ButtonText,
		Text = text,
		LayoutOrder = layoutOrder(p.layoutOrder),
	}, nil)
	Kit.corner(cap, Theme.Radius.Small)
	Kit.stroke(cap, Theme.Colors.ButtonStroke, Theme.Stroke.Thin)
	new("UIPadding", {
		PaddingLeft = UDim.new(0, KEYCAP_PADDING),
		PaddingRight = UDim.new(0, KEYCAP_PADDING),
	}, cap)
	cap.Parent = parent
	return cap
end

--============================================================================
-- Buttons
--============================================================================
local function styleOf(button: GuiObject)
	local style = button:GetAttribute(STYLE_ATTRIBUTE)
	return BUTTON_STYLES[if type(style) == "string" then style else "Primary"] or BUTTON_STYLES.Primary
end

function Kit.button(parent: Instance, text: string, onActivated: () -> (), props: ButtonProps?): TextButton
	local p: ButtonProps = props or {}
	local button: TextButton = new("TextButton", {
		Name = p.name or "Button",
		AutoButtonColor = false,
		BorderSizePixel = 0,
		Size = p.size or UDim2.new(1, 0, 0, Theme.Sizes.Button),
		Position = p.position or UDim2.new(),
		AnchorPoint = p.anchor or Vector2.zero,
		Font = Theme.Fonts.Bold,
		TextSize = p.textSize or Theme.TextSizes.Button,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Text = text,
		LayoutOrder = layoutOrder(p.layoutOrder),
	}, nil)
	button:SetAttribute(STYLE_ATTRIBUTE, p.style or "Primary")
	button:SetAttribute(ENABLED_ATTRIBUTE, true)
	Kit.corner(button, Theme.Radius.Button)
	Kit.gradient(button, Color3.new(1, 1, 1), Theme.Colors.ButtonShade) -- the slight KSP vertical gradient
	local buttonStroke = Kit.stroke(button, styleOf(button).stroke, Theme.Stroke.Thin)

	local hovered = false
	local pressed = false
	local function render(animate: boolean)
		local enabled = Kit.isButtonEnabled(button)
		local colors = styleOf(button)
		local background = if not enabled
			then Theme.Colors.ButtonDisabled
			elseif pressed then colors.pressed
			elseif hovered then colors.hover
			else colors.base
		button.TextColor3 = if enabled then colors.text else Theme.Colors.ButtonDisabledText
		buttonStroke.Color = colors.stroke
		if animate then
			Kit.tween(button, { BackgroundColor3 = background }, Theme.Tween.Fast)
		else
			button.BackgroundColor3 = background
		end
	end
	local function isPress(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
	end

	button.MouseEnter:Connect(function()
		hovered = true
		render(true)
	end)
	button.MouseLeave:Connect(function()
		hovered = false
		pressed = false
		render(true)
	end)
	button.InputBegan:Connect(function(input: InputObject)
		if isPress(input) then
			pressed = true
			render(true)
		end
	end)
	button.InputEnded:Connect(function(input: InputObject)
		if isPress(input) then
			pressed = false
			if input.UserInputType == Enum.UserInputType.Touch then
				hovered = false -- touch has no hover
			end
			render(true)
		end
	end)
	button:GetAttributeChangedSignal(STYLE_ATTRIBUTE):Connect(function()
		render(true)
	end)
	button:GetAttributeChangedSignal(ENABLED_ATTRIBUTE):Connect(function()
		render(true)
	end)
	button.Activated:Connect(function()
		if Kit.isButtonEnabled(button) then
			onActivated()
		end
	end)

	render(false)
	button.Parent = parent
	return button
end

function Kit.setButtonEnabled(button: TextButton, enabled: boolean)
	button:SetAttribute(ENABLED_ATTRIBUTE, enabled)
end

function Kit.isButtonEnabled(button: TextButton): boolean
	return button:GetAttribute(ENABLED_ATTRIBUTE) ~= false
end

function Kit.setButtonStyle(button: TextButton, style: ButtonStyle)
	button:SetAttribute(STYLE_ATTRIBUTE, style)
end

--============================================================================
-- Controls
--============================================================================
function Kit.toggle(parent: Instance, label: string, initial: boolean, onChanged: (boolean) -> ()): Toggle
	local value = initial
	local row = Kit.row(parent)
	row.Name = "Toggle"
	local width = Theme.Sizes.ToggleWidth
	local height = Theme.Sizes.ToggleHeight
	local knobSize = height - KNOB_INSET * 2
	Kit.label(row, label, { size = UDim2.new(1, -(width + Theme.Padding.Medium), 1, 0) })

	local track: Frame = new("Frame", {
		Name = "Switch",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(width, height),
		BorderSizePixel = 0,
	}, row)
	Kit.round(track)
	Kit.stroke(track, Theme.Colors.PanelStroke, Theme.Stroke.Thin)
	local knob: Frame = new("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0, 0.5),
		Size = UDim2.fromOffset(knobSize, knobSize),
		BackgroundColor3 = Theme.Colors.Button,
		BorderSizePixel = 0,
	}, track)
	Kit.round(knob)
	Kit.stroke(knob, Theme.Colors.ButtonStroke, Theme.Stroke.Thin)

	-- The whole row is the hit area (easier to hit, touch friendly).
	local hit: TextButton = new("TextButton", {
		Name = "Hit",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Text = "",
		ZIndex = 2,
	}, row)

	local function render(animate: boolean)
		local position = if value
			then UDim2.new(1, -(knobSize + KNOB_INSET), 0.5, 0)
			else UDim2.new(0, KNOB_INSET, 0.5, 0)
		local color = if value then Theme.Colors.Accent else Theme.Colors.Track
		if animate then
			Kit.tween(knob, { Position = position }, Theme.Tween.Normal)
			Kit.tween(track, { BackgroundColor3 = color }, Theme.Tween.Normal)
		else
			knob.Position = position
			track.BackgroundColor3 = color
		end
	end

	hit.MouseEnter:Connect(function()
		Kit.tween(knob, { BackgroundColor3 = Theme.Colors.ButtonHover }, Theme.Tween.Fast)
	end)
	hit.MouseLeave:Connect(function()
		Kit.tween(knob, { BackgroundColor3 = Theme.Colors.Button }, Theme.Tween.Fast)
	end)
	hit.Activated:Connect(function()
		value = not value
		render(true)
		onChanged(value)
	end)
	render(false)

	return {
		frame = row,
		set = function(newValue: boolean)
			if newValue ~= value then
				value = newValue
				render(true)
			end
		end,
		get = function(): boolean
			return value
		end,
	}
end

function Kit.slider(parent: Instance, label: string, opts: SliderOptions, onChanged: (number) -> ()): Slider
	local min, max, step = opts.min, opts.max, opts.step
	local live = opts.live ~= false
	local value = KitMath.snap(opts.value, min, max, step)
	local reported = value -- the last value handed to onChanged (or set from outside)
	local knobSize = Theme.Sizes.SliderKnob

	local row = Kit.row(parent)
	row.Name = "Slider"
	Kit.label(row, label, { size = UDim2.new(ROW_LABEL_FRACTION, -Theme.Padding.Medium, 1, 0) })
	local valueLabel = Kit.label(row, opts.format(value), {
		size = UDim2.new(0, SLIDER_VALUE_WIDTH, 1, 0),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
		align = Enum.TextXAlignment.Right,
		bold = true,
	})

	-- Hit area: the full row height between the label and the value, so it is easy to grab on touch.
	local area: TextButton = new("TextButton", {
		Name = "Track",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Position = UDim2.fromScale(ROW_LABEL_FRACTION, 0),
		Size = UDim2.new(1 - ROW_LABEL_FRACTION, -(SLIDER_VALUE_WIDTH + Theme.Padding.Medium), 1, 0),
		Text = "",
	}, row)
	local track: Frame = new("Frame", {
		Name = "Rail",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, knobSize / 2, 0.5, 0),
		Size = UDim2.new(1, -knobSize, 0, Theme.Sizes.SliderTrack),
		BackgroundColor3 = Theme.Colors.Track,
		BorderSizePixel = 0,
	}, area)
	Kit.round(track)
	Kit.stroke(track, Theme.Colors.PanelStroke, Theme.Stroke.Thin, 0.4)
	local fill: Frame = new("Frame", {
		Name = "Fill",
		BackgroundColor3 = Theme.Colors.Accent,
		BorderSizePixel = 0,
	}, track)
	Kit.round(fill)
	local knob: Frame = new("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(knobSize, knobSize),
		BackgroundColor3 = Theme.Colors.Button,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, track)
	Kit.round(knob)
	Kit.stroke(knob, Theme.Colors.ButtonStroke, Theme.Stroke.Thin)

	local function render()
		local f = KitMath.fraction(value, min, max)
		fill.Size = UDim2.fromScale(f, 1)
		fill.Visible = f > 0
		knob.Position = UDim2.fromScale(f, 0.5)
		valueLabel.Text = opts.format(value)
	end

	local function report()
		if value ~= reported then
			reported = value
			onChanged(value)
		end
	end

	local function setFromX(x: number)
		local width = track.AbsoluteSize.X
		if width <= 0 then
			return
		end
		local newValue = KitMath.fromFraction((x - track.AbsolutePosition.X) / width, min, max, step)
		if newValue ~= value then
			value = newValue
			render()
			if live then
				report()
			end
		end
	end

	local moveConnection: RBXScriptConnection? = nil
	local endConnection: RBXScriptConnection? = nil
	local function disconnectDrag()
		if moveConnection then
			moveConnection:Disconnect()
			moveConnection = nil
		end
		if endConnection then
			endConnection:Disconnect()
			endConnection = nil
		end
	end

	area.InputBegan:Connect(function(input: InputObject)
		local inputType = input.UserInputType
		if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
			return
		end
		if moveConnection then
			return -- already dragging (a second finger)
		end
		setFromX(input.Position.X)
		moveConnection = UserInputService.InputChanged:Connect(function(changed: InputObject)
			if inputType == Enum.UserInputType.Touch then
				if changed == input then
					setFromX(changed.Position.X)
				end
			elseif changed.UserInputType == Enum.UserInputType.MouseMovement then
				setFromX(changed.Position.X)
			end
		end)
		endConnection = UserInputService.InputEnded:Connect(function(ended: InputObject)
			if ended.UserInputType == inputType then
				disconnectDrag()
				report()
			end
		end)
	end)
	area.MouseEnter:Connect(function()
		Kit.tween(knob, { BackgroundColor3 = Theme.Colors.ButtonHover }, Theme.Tween.Fast)
	end)
	area.MouseLeave:Connect(function()
		Kit.tween(knob, { BackgroundColor3 = Theme.Colors.Button }, Theme.Tween.Fast)
	end)
	row.Destroying:Connect(disconnectDrag)
	render()

	return {
		frame = row,
		set = function(newValue: number)
			local clean = KitMath.snap(newValue, min, max, step)
			reported = clean
			if clean ~= value then
				value = clean
				render()
			end
		end,
		get = function(): number
			return value
		end,
	}
end

function Kit.choice(
	parent: Instance,
	label: string,
	options: { string },
	initial: string,
	onChanged: (string) -> ()
): Choice
	local selected = initial
	local row = Kit.row(parent)
	row.Name = "Choice"
	Kit.label(row, label, { size = UDim2.new(ROW_LABEL_FRACTION, -Theme.Padding.Medium, 1, 0) })
	local group = Kit.frame(row, {
		name = "Segments",
		position = UDim2.fromScale(ROW_LABEL_FRACTION, 0),
		size = UDim2.fromScale(1 - ROW_LABEL_FRACTION, 1),
	})
	Kit.list(group, { horizontal = true, gap = Theme.Padding.Small, align = Enum.HorizontalAlignment.Right })

	local buttons: { [string]: TextButton } = {}
	local function render()
		for option, button in buttons do
			Kit.setButtonStyle(button, if option == selected then "Primary" else "Ghost")
		end
	end
	for index, option in options do
		buttons[option] = Kit.button(group, option, function()
			if option ~= selected then
				selected = option
				render()
				onChanged(option)
			end
		end, {
			size = UDim2.fromOffset(Theme.Sizes.Segment, Theme.Sizes.ButtonSmall),
			layoutOrder = index,
			textSize = Theme.TextSizes.Body,
			style = "Ghost",
		})
	end
	render()

	return {
		frame = row,
		set = function(option: string)
			if buttons[option] and option ~= selected then
				selected = option
				render()
			end
		end,
		get = function(): string
			return selected
		end,
	}
end

function Kit.tabs(parent: Instance, names: { string }, initial: string, onChanged: (string) -> ()): Tabs
	local selected = initial
	local strip = Kit.frame(parent, { name = "Tabs", size = UDim2.new(1, 0, 0, Theme.Sizes.Tab) })
	local gap = Theme.Padding.Small
	Kit.list(strip, { horizontal = true, gap = gap })
	local count = math.max(#names, 1)
	local buttons: { [string]: TextButton } = {}
	local function render()
		for name, button in buttons do
			Kit.setButtonStyle(button, if name == selected then "Primary" else "Ghost")
		end
	end
	for index, name in names do
		buttons[name] = Kit.button(strip, name, function()
			if name ~= selected then
				selected = name
				render()
				onChanged(name)
			end
		end, {
			size = UDim2.new(1 / count, -gap * (count - 1) / count, 1, 0),
			layoutOrder = index,
			style = "Ghost",
		})
	end
	render()

	return {
		frame = strip,
		set = function(name: string)
			if buttons[name] and name ~= selected then
				selected = name
				render()
			end
		end,
		get = function(): string
			return selected
		end,
	}
end

--============================================================================
-- Instruments
--============================================================================
function Kit.bar(parent: Instance, props: BarProps): Bar
	local vertical = props.vertical == true
	local frame: Frame = new("Frame", {
		Name = props.name or "Bar",
		Size = props.size,
		Position = props.position or UDim2.new(),
		AnchorPoint = props.anchor or Vector2.zero,
		BackgroundColor3 = Theme.Colors.Track,
		BorderSizePixel = 0,
		LayoutOrder = layoutOrder(props.layoutOrder),
	}, nil)
	Kit.corner(frame, Theme.Radius.Small)
	Kit.stroke(frame, Theme.Colors.GaugeMetalDark, Theme.Stroke.Thin)
	local fill: Frame = new("Frame", {
		Name = "Fill",
		AnchorPoint = if vertical then Vector2.new(0, 1) else Vector2.zero,
		Position = if vertical then UDim2.fromScale(0, 1) else UDim2.new(),
		Size = UDim2.fromScale(0, 0),
		BackgroundColor3 = props.color,
		BorderSizePixel = 0,
		Visible = false,
	}, frame)
	Kit.corner(fill, Theme.Radius.Small)
	frame.Parent = parent

	local current = -1
	local function set(fraction: number)
		local f = KitMath.clamp01(fraction)
		if f == current then
			return
		end
		current = f
		fill.Size = if vertical then UDim2.fromScale(1, f) else UDim2.fromScale(f, 1)
		fill.Visible = f > 0
	end
	set(0)

	return {
		frame = frame,
		set = set,
		setColor = function(color: Color3)
			if fill.BackgroundColor3 ~= color then
				fill.BackgroundColor3 = color
			end
		end,
	}
end

--============================================================================
-- Dialogs and feedback
--============================================================================
function Kit.isConfirmOpen(): boolean
	return confirmOpen
end

-- CHANGED (Phase 11 review): returns a cancel function (answers no and closes the dialog, if still open), so a
-- screen that goes away can take its pending question with it.
function Kit.confirm(opts: ConfirmOptions, onResult: (confirmed: boolean) -> ()): () -> ()
	if confirmOpen then
		warn(`[Kit] a confirm dialog is already open; "{opts.title}" was answered no`)
		task.defer(onResult, false)
		return function() end
	end
	confirmOpen = true

	local screen, canvas = Kit.screen(DIALOG_GUI_NAME, Theme.DisplayOrder.Dialog)
	local backdrop = Kit.backdrop(canvas)
	local dialog = Kit.panel({
		parent = canvas,
		name = "Dialog",
		size = UDim2.fromOffset(DIALOG_WIDTH, 0),
		position = UDim2.fromScale(0.5, 0.5),
		anchor = Vector2.new(0.5, 0.5),
		padding = Theme.Padding.Large,
	})
	dialog.AutomaticSize = Enum.AutomaticSize.Y
	local popScale: UIScale = new("UIScale", { Scale = DIALOG_POP_SCALE }, dialog)
	Kit.list(dialog, { gap = Theme.Padding.Large })
	Kit.title(dialog, opts.title)
	Kit.label(dialog, opts.body, { wrap = true, align = Enum.TextXAlignment.Center })
	local buttons = Kit.row(dialog, Theme.Sizes.Button)

	local finished = false
	local removeEscape: () -> () = function() end
	local function finish(confirmed: boolean)
		if finished then
			return
		end
		finished = true
		removeEscape()
		UIState.popModal(DIALOG_MODAL)
		confirmOpen = false
		screen:Destroy()
		onResult(confirmed)
	end

	local half = Theme.Padding.Medium / 2
	Kit.button(buttons, opts.cancelText or DIALOG_DEFAULT_CANCEL, function()
		finish(false)
	end, { name = "Cancel", size = UDim2.new(0.5, -half, 1, 0) })
	Kit.button(buttons, opts.confirmText, function()
		finish(true)
	end, {
		name = "Confirm",
		style = if opts.danger then "Danger" else "Primary",
		size = UDim2.new(0.5, -half, 1, 0),
		position = UDim2.fromScale(1, 0),
		anchor = Vector2.new(1, 0),
	})

	removeEscape = Kit.onEscape(function()
		finish(false)
	end)
	UIState.pushModal(DIALOG_MODAL)

	backdrop.BackgroundTransparency = 1
	Kit.tween(backdrop, { BackgroundTransparency = Theme.Transparency.Backdrop }, Theme.Tween.Normal)
	Kit.tween(popScale, { Scale = 1 }, Theme.Tween.Normal)
	return function()
		finish(false)
	end
end

local function getToastHolder(): Frame
	local holder = toastHolder
	if holder and holder.Parent and holder:FindFirstAncestorOfClass("PlayerGui") then
		return holder
	end
	local _, canvas = Kit.screen(TOAST_GUI_NAME, Theme.DisplayOrder.Toast)
	local created = Kit.frame(canvas, {
		name = "Toasts",
		position = UDim2.new(0.5, 0, 0, Theme.Sizes.ToastTop),
		anchor = Vector2.new(0.5, 0),
		size = UDim2.fromOffset(Theme.Sizes.Toast, 0),
	})
	created.AutomaticSize = Enum.AutomaticSize.Y
	Kit.list(created, { gap = Theme.Padding.Gap, align = Enum.HorizontalAlignment.Center })
	toastHolder = created
	table.clear(toasts)
	return created
end

local function dismissToast(entry: ToastEntry)
	if entry.closing then
		return
	end
	entry.closing = true
	local index = table.find(toasts, entry)
	if index then
		table.remove(toasts, index)
	end
	local group = entry.group
	Kit.fadeCanvas(group, false, Theme.Tween.Fade, function()
		group:Destroy()
	end)
end

function Kit.toast(text: string, kind: ToastKind?)
	local holder = getToastHolder()
	local seconds = KitMath.toastSeconds(text, TOAST_BASE_S, TOAST_PER_CHAR_S, TOAST_MAX_S)
	for _, entry in toasts do
		if entry.text == text then
			entry.expires = os.clock() + seconds -- the same message again: keep it up longer
			return
		end
	end

	local group: CanvasGroup = new("CanvasGroup", {
		Name = "Toast",
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Theme.Colors.Panel,
		BackgroundTransparency = Theme.Transparency.Panel,
		BorderSizePixel = 0,
		GroupTransparency = 1,
		LayoutOrder = layoutOrder(nil),
	}, nil)
	Kit.corner(group, Theme.Radius.Panel)
	Kit.stroke(group, Theme.Colors.PanelStroke, Theme.Stroke.Thin)
	new("Frame", {
		Name = "Strip",
		Size = UDim2.new(0, TOAST_STRIP, 1, 0),
		BackgroundColor3 = TOAST_COLORS[kind or "Info"] or TOAST_COLORS.Info,
		BorderSizePixel = 0,
	}, group)
	local body = Kit.frame(group, {
		name = "Body",
		position = UDim2.fromOffset(TOAST_STRIP, 0),
		size = UDim2.new(1, -TOAST_STRIP, 0, 0),
	})
	body.AutomaticSize = Enum.AutomaticSize.Y
	new("UIPadding", {
		PaddingTop = UDim.new(0, Theme.Padding.Medium),
		PaddingBottom = UDim.new(0, Theme.Padding.Medium),
		PaddingLeft = UDim.new(0, Theme.Padding.Large),
		PaddingRight = UDim.new(0, Theme.Padding.Large),
	}, body)
	Kit.label(body, text, { wrap = true, align = Enum.TextXAlignment.Center })
	group.Parent = holder

	local entry: ToastEntry = { group = group, text = text, expires = os.clock() + seconds, closing = false }
	table.insert(toasts, entry)
	while #toasts > TOAST_MAX_COUNT do
		dismissToast(toasts[1])
	end
	Kit.fadeCanvas(group, true, Theme.Tween.Normal)

	task.spawn(function()
		while not entry.closing and os.clock() < entry.expires do
			task.wait(entry.expires - os.clock())
		end
		dismissToast(entry)
	end)
end

return table.freeze(Kit)
