--!strict
--[[
	Navball (Phase 5, spec 7.11 HUD additions)
	A KSP-style attitude ball in a ViewportFrame: blue sky (top) / brown ground (bottom) hemispheres of the LOCAL
	HORIZON frame (radial up, north = universe +Y projected, Frames.surfaceRotation), a white horizon line and the
	north-south / east-west meridians, turned by the craft's attitude relative to that frame. The craft's nose is
	the fixed centre reticle; screen up is the craft's +Z and screen right its +X (the directions W/S and A/D move
	the nose). Prograde / retrograde markers (orbital velocity) and N/E/S/W letters are 2D overlays placed with the
	same camera projection, so they are crisp at any size.

	Viewing a ball from outside mirrors it left-right relative to what the pilot sees; the ball's parts are
	symmetric under the east-west flip, so they are simply posed with that flip folded into a proper rotation,
	and the overlays are projected with the true (mirrored) mapping.

	Built from primitives only: one Ball for the sky, GROUND_BANDS cylinder slices for the ground hemisphere (a
	thin outer layer over the ball), and thin cylinder rings for the lines. Client-only, about 30 parts; the ball
	is re-posed only when the attitude changed by more than POSE_EPSILON.

	CHANGED (Phase 11): restyled for the KSP flight HUD (UI/Theme): the ball sits centred in its parent (the face of a
	Kit.gaugeBezel), with no frame or outline of its own; sky / ground come from Theme.Colors.NavSky / NavGround, the
	nose reticle is amber, the prograde markers yellow-green and the "ON RAILS" pill is a green lamp. The maths is
	unchanged.

	API:
	  Navball.create(parent, size) -> Navball         CHANGED (Phase 11): centred in parent, size = diameter (px)
	  navball.update(attitude?, horizon?, velocity?)   attitude: craft -> universe rotation; horizon: local horizon
	                                                   rotation (X east, Y up, Z north); velocity: universe axes.
	                                                   Returns heading (deg, 0..360) and pitch (deg).
]]

local Theme = require(script.Parent.Theme) -- CHANGED (Phase 11)

--============================================================================
-- Tunables
--============================================================================
local FIELD_OF_VIEW = 20 -- degrees; a narrow lens keeps the ball close to an orthographic view
local FILL = 0.97 -- fraction of the frame the ball's silhouette fills
local GROUND_BANDS = 24 -- latitude slices of the ground hemisphere
local GROUND_SCALE = 1.004 -- the ground layer sits just outside the sky ball
local LINE_SCALE = 1.008 -- rings sit just outside the ground layer
local HORIZON_THICKNESS = 0.035
local MERIDIAN_THICKNESS = 0.014
-- CHANGED (Phase 11): colours and fonts from UI/Theme
local SKY_COLOR = Theme.Colors.NavSky
local GROUND_COLOR = Theme.Colors.NavGround
local HORIZON_COLOR = Color3.fromRGB(255, 255, 255)
local MERIDIAN_COLOR = Color3.fromRGB(225, 232, 245)
local RETICLE_COLOR = Theme.Colors.Warning -- KSP's amber nose marker
local PROGRADE_COLOR = Theme.Colors.Title -- KSP's yellow-green prograde marker
local CARDINAL_COLOR = Theme.Colors.DigitText
local RAILS_COLOR = Theme.Colors.Accent -- the "ON RAILS" lamp
local RAILS_TEXT_COLOR = Theme.Colors.ButtonText
local MARKER_SIZE = 22 -- pixels at the design size
local MARKER_DESIGN_SIZE = 140 -- ball diameter MARKER_SIZE is meant for
local POSE_EPSILON = math.rad(0.15) -- re-pose the ball only beyond this attitude change
local FONT_BOLD = Theme.Fonts.Bold
local FONT_HEAVY = Theme.Fonts.ExtraBold
--============================================================================

export type Navball = {
	frame: Frame,
	update: (attitude: CFrame?, horizon: CFrame?, velocity: Vector3?) -> (number, number),
	setRails: (onRails: boolean) -> (),
}

local Navball = {}

local TAN_HALF = math.tan(math.rad(FIELD_OF_VIEW) / 2)
local CAMERA_DISTANCE = 1 / math.sin(math.atan(FILL * TAN_HALF))

local function part(className: string, props: { [string]: any }, parent: Instance): BasePart
	local p = Instance.new(className) :: BasePart
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

-- A flat cylinder (disc) whose axis is `axis` (unit Vector3 in model space), centred at `center`.
local function disc(model: Model, center: Vector3, axis: Vector3, radius: number, thickness: number, color: Color3)
	local p = part("Part", {
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(thickness, radius * 2, radius * 2),
		Color = color,
	}, model)
	-- a cylinder's axis is its local X
	local up = if math.abs(axis.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
	local z = axis:Cross(up).Unit
	local y = z:Cross(axis)
	p.CFrame = CFrame.fromMatrix(center, axis, y, z)
end

local function buildBall(model: Model)
	part("Part", {
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 2,
		Color = SKY_COLOR,
		CFrame = CFrame.identity,
	}, model)
	-- ground: latitude bands from the south pole to the horizon; each band's radius is the sphere's radius at its
	-- top edge (the widest), so the bands cover the sky ball's lower half completely
	local step = (math.pi / 2) / GROUND_BANDS
	for k = 0, GROUND_BANDS - 1 do
		local latBottom = -math.pi / 2 + step * k
		local latTop = latBottom + step
		local yBottom, yTop = math.sin(latBottom), math.sin(latTop)
		disc(
			model,
			Vector3.new(0, (yBottom + yTop) / 2 * GROUND_SCALE, 0),
			Vector3.yAxis,
			math.cos(latTop) * GROUND_SCALE,
			(yTop - yBottom) * GROUND_SCALE,
			GROUND_COLOR
		)
	end
	disc(model, Vector3.zero, Vector3.yAxis, LINE_SCALE, HORIZON_THICKNESS, HORIZON_COLOR)
	disc(model, Vector3.zero, Vector3.xAxis, LINE_SCALE, MERIDIAN_THICKNESS, MERIDIAN_COLOR) -- north-south
	disc(model, Vector3.zero, Vector3.zAxis, LINE_SCALE, MERIDIAN_THICKNESS, MERIDIAN_COLOR) -- east-west
end

-- Craft-axes direction -> viewport direction as the pilot sees it (screen right = +X, up = +Z, toward us = nose).
local function toView(dc: Vector3): Vector3
	return Vector3.new(dc.X, dc.Z, dc.Y)
end

local function newLabel(parent: Instance, props: { [string]: any }): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.Active = false
	l.Selectable = false
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	for key, value in props do
		(l :: any)[key] = value
	end
	l.Parent = parent
	return l
end

local function ring(parent: Instance, size: number, color: Color3, thickness: number): Frame
	local f = Instance.new("Frame")
	f.AnchorPoint = Vector2.new(0.5, 0.5)
	f.Size = UDim2.fromOffset(size, size)
	f.BackgroundTransparency = 1
	f.Active = false
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = f
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness
	stroke.Parent = f
	f.Parent = parent
	return f
end

function Navball.create(parent: Instance, size: number): Navball
	-- CHANGED (Phase 11): centred in the bezel's face, which draws the black backing and the rim
	local container = Instance.new("Frame")
	container.Name = "Navball"
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.Position = UDim2.fromScale(0.5, 0.5)
	container.Size = UDim2.fromOffset(size, size)
	container.BackgroundTransparency = 1
	container.BorderSizePixel = 0
	container.Active = false
	container.Parent = parent

	local viewport = Instance.new("ViewportFrame")
	viewport.Size = UDim2.fromScale(1, 1)
	viewport.BackgroundTransparency = 1
	viewport.Ambient = Color3.fromRGB(170, 170, 170)
	viewport.LightColor = Color3.fromRGB(255, 255, 255)
	viewport.LightDirection = Vector3.new(-0.3, -0.4, -1).Unit
	viewport.Active = false
	viewport.Parent = container

	local camera = Instance.new("Camera")
	camera.FieldOfView = FIELD_OF_VIEW
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 0, CAMERA_DISTANCE), Vector3.zero, Vector3.yAxis)
	camera.Parent = viewport
	viewport.CurrentCamera = camera

	local model = Instance.new("Model")
	model.Name = "Ball"
	buildBall(model)
	model.WorldPivot = CFrame.identity
	model.Parent = viewport

	-- overlays
	local overlay = Instance.new("Frame")
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.BackgroundTransparency = 1
	overlay.Active = false
	overlay.ZIndex = 2
	overlay.Parent = container

	local cardinals: { { label: TextLabel, dir: string } } = {}
	for _, letter in { "N", "E", "S", "W" } do
		local label = newLabel(overlay, {
			Size = UDim2.fromOffset(16, 16),
			Font = FONT_HEAVY,
			TextSize = 13,
			TextColor3 = CARDINAL_COLOR,
			TextStrokeTransparency = 0.4,
			Text = letter,
			Visible = false,
			ZIndex = 3,
		})
		table.insert(cardinals, { label = label, dir = letter })
	end

	local markerSize = math.floor(MARKER_SIZE * size / MARKER_DESIGN_SIZE + 0.5)
	local prograde = ring(overlay, markerSize, PROGRADE_COLOR, 2.5)
	prograde.ZIndex = 4
	prograde.Visible = false
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(5, 5)
	dot.BackgroundColor3 = PROGRADE_COLOR
	dot.BorderSizePixel = 0
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(0.5, 0)
	dotCorner.Parent = dot
	dot.Parent = prograde
	local retrograde = ring(overlay, markerSize, PROGRADE_COLOR, 2.5)
	retrograde.ZIndex = 4
	retrograde.Visible = false
	newLabel(retrograde, {
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(1, 1),
		Font = FONT_HEAVY,
		TextSize = markerSize,
		TextColor3 = PROGRADE_COLOR,
		Text = "x",
		ZIndex = 5,
	})

	-- fixed centre reticle: a small ring with two wings (the nose)
	local reticle = ring(overlay, 10, RETICLE_COLOR, 2.5)
	reticle.Position = UDim2.fromScale(0.5, 0.5)
	reticle.ZIndex = 6
	for _, side in { -1, 1 } do
		local wing = Instance.new("Frame")
		wing.AnchorPoint = Vector2.new(0.5, 0.5)
		wing.Position = UDim2.new(0.5, side * 13, 0.5, 0)
		wing.Size = UDim2.fromOffset(12, 3)
		wing.BackgroundColor3 = RETICLE_COLOR
		wing.BorderSizePixel = 0
		wing.ZIndex = 6
		wing.Parent = reticle
	end

	local railsPill = newLabel(container, {
		-- CHANGED (Phase 11): at the top of the ball (the HUD's heading box covers its bottom)
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(62, 15),
		BackgroundTransparency = 0,
		BackgroundColor3 = RAILS_COLOR, -- CHANGED (Phase 11)
		Font = FONT_BOLD,
		TextSize = Theme.TextSizes.Tiny,
		TextColor3 = RAILS_TEXT_COLOR,
		Text = "ON RAILS",
		Visible = false,
		ZIndex = 7,
	})
	local pillCorner = Instance.new("UICorner")
	pillCorner.CornerRadius = UDim.new(0.5, 0)
	pillCorner.Parent = railsPill

	local lastPose: CFrame? = nil

	-- Places an overlay at a viewport direction (unit); hidden on the far side of the ball.
	local function place(object: GuiObject, view: Vector3)
		local z = view.Z
		if z <= 1 / CAMERA_DISTANCE then
			object.Visible = false
			return
		end
		local depth = (CAMERA_DISTANCE - z) * TAN_HALF
		object.Position = UDim2.fromScale(0.5 + 0.5 * view.X / depth, 0.5 - 0.5 * view.Y / depth)
		object.Visible = true
	end

	local function update(attitude: CFrame?, horizon: CFrame?, velocity: Vector3?): (number, number)
		if attitude == nil or horizon == nil then
			container.Visible = false
			return 0, 0
		end
		container.Visible = true
		local rot = attitude :: CFrame
		local h = horizon :: CFrame
		local east, up, north = h.XVector, h.YVector, h.ZVector
		local function view(d: Vector3): Vector3
			return toView(rot:VectorToObjectSpace(d))
		end
		-- the ball's pose with the east-west flip folded in (the parts are symmetric under it)
		local pose = CFrame.fromMatrix(Vector3.zero, view(-east), view(up), view(north))
		local previous = lastPose
		if previous == nil or select(2, (previous:Inverse() * pose):ToAxisAngle()) > POSE_EPSILON then
			lastPose = pose
			model:PivotTo(pose)
		end
		for _, entry in cardinals do
			local d = if entry.dir == "N"
				then north
				elseif entry.dir == "S" then -north
				elseif entry.dir == "E" then east
				else -east
			place(entry.label, view(d))
		end
		if velocity and velocity.Magnitude > 0.1 then
			local v = (velocity :: Vector3).Unit
			place(prograde, view(v))
			place(retrograde, view(-v))
		else
			prograde.Visible = false
			retrograde.Visible = false
		end
		local nose = rot.YVector
		local heading = math.deg(math.atan2(nose:Dot(east), nose:Dot(north))) % 360
		local pitch = math.deg(math.asin(math.clamp(nose:Dot(up), -1, 1)))
		return heading, pitch
	end

	local function setRails(onRails: boolean)
		railsPill.Visible = onRails
	end

	return { frame = container, update = update, setRails = setRails }
end

return table.freeze(Navball)
