--!strict
--[[
	MapViewController (Phase 5, spec 7.11 "Map view")
	M toggles the map (in a flight pocket only); M or Esc closes it. The craft keeps flying (flight keys still work)
	and the flight HUD stays.

	Where it is drawn: a client-only folder (Workspace.MapView) around a MAP ORIGIN MAP_ORIGIN_OFFSET studs above
	(or, for high slots, below) the current pocket's slot origin, so everything stays inside the +-12,000-stud
	pocket rules. UniverseRenderer's map mode hides the flight layers (scaled space, surface, other crafts' copies)
	and turns the SkyCube into an opaque star box around the map camera, which also hides the pocket itself.

	Scale and camera: the map is in universe axes (workspace +Y = the north pole, orbits lie flat). The focus
	(a body or a craft) sits at the map origin; positions are (true position - focus) * scale, subtracted in
	doubles first (I1). The camera always orbits the origin at MAP_CAMERA_DISTANCE studs: drag (left or right
	mouse) orbits, the wheel ZOOMS BY CHANGING THE SCALE logarithmically (MAP_SCALE_MIN..MAX), so everything worth
	seeing stays within MAP_EXTENT studs of the camera and inside draw distance at every zoom. Click a body (or
	any body / craft label) to focus it.

	What is drawn
	  * bodies: Neon balls at scale, Earth's atmosphere shell, Mun's SOI sphere, a "ghost" Mun where the
	    tracked craft will meet it
	  * orbit lines (pooled Beams between Attachments on one anchored part per line, so a whole line moves with
	    one CFrame write): the tracked craft's trajectory as up to MAP_PREDICT_PATCHES conic patches through SOI
	    changes (Rails.predict), MAP_ORBIT_SEGMENTS segments each; Mun's orbit; other crafts' current orbits
	    (MAP_OTHER_ORBIT_SEGMENTS). Each patch is anchored to its body: the first patch to the body now, later
	    patches to where their body will be when the craft gets there, so the patches join up.
	  * BillboardGui markers (in PlayerGui so they are clickable): every craft, every body, apoapsis / periapsis
	    of the tracked craft (with the time to each), periapsis inside the next SOI.
	The tracked craft is the focused craft, else the craft this client flies (or rides).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Kepler = require(ReplicatedStorage.Shared.Sim.Kepler)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local DebugOverlay = require(script.Parent.DebugOverlay)
local PocketController = require(script.Parent.PocketController)
local RemoteCraftRenderer = require(script.Parent.RemoteCraftRenderer)
local UniverseRenderer = require(script.Parent.UniverseRenderer)

type Vec3d = Vec3d.Vec3d
type State = Protocol.State

--============================================================================
-- Tunables
--============================================================================
local MAP_SCALE = GameConfig.MAP_SCALE
local SCALE_MIN = GameConfig.MAP_SCALE_MIN
local SCALE_MAX = GameConfig.MAP_SCALE_MAX
local ZOOM_STEP = GameConfig.MAP_ZOOM_STEP
local CAMERA_DISTANCE = GameConfig.MAP_CAMERA_DISTANCE
local EXTENT = GameConfig.MAP_EXTENT
local ORIGIN_OFFSET = GameConfig.MAP_ORIGIN_OFFSET
local FOCUS_SEGMENTS = GameConfig.MAP_ORBIT_SEGMENTS
local OTHER_SEGMENTS = GameConfig.MAP_OTHER_ORBIT_SEGMENTS
local MAX_PATCHES = GameConfig.MAP_PREDICT_PATCHES
local INTERP_DELAY = GameConfig.INTERP_DELAY
local RENDER_STEP_NAME = "MapView"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 5 -- after ChaseCamera / Roblox camera, before UniverseRenderer
local FIELD_OF_VIEW = 70
local CUBE_MARGIN = 120 -- studs between the map extent and the star box
local CUBE_DRAW_FRACTION = 0.75 -- the star box never exceeds this fraction of the draw distance
local HIGH_SLOT_Y = 6000 -- slots above this put the map below them (keeps |y| <= 12,000)
local ROTATE_SENSITIVITY = math.rad(0.3) -- rad per pixel of drag
local PITCH_LIMIT = math.rad(88)
local DEFAULT_YAW = math.rad(35)
local DEFAULT_PITCH = math.rad(50) -- looking down on the orbit plane
local CLICK_PIXELS = 5 -- a press that moves less than this is a click
local PREDICT_INTERVAL = 0.5 -- s between trajectory predictions of the tracked craft
local OTHER_INTERVAL = 1 -- s between other crafts' orbit refreshes
local LINE_REFRESH = 0.1 -- s between line layouts (also on every zoom step)
local MAX_OTHER_ORBITS = 12
local ANCHOR_LIMIT = 9000 -- studs; a line whose body is farther than this from the map origin is hidden
local OPEN_DRAW_FACTOR = 1.5 -- open orbits are drawn out to this times the farthest moon orbit (or the SOI)
local DENT_ORBIT_SEGMENTS = 128
local MAX_BALL_SIZE = 2040 -- studs (part size limit 2048)
local LINE_WIDTH_FOCUS = 0.7 -- studs (the camera distance is fixed, so this is ~2 px)
local LINE_WIDTH_OTHER = 0.4
local BODY_BRIGHTNESS = 0.55 -- Neon colour multiplier for bodies (unlit, readable day or night)
local PATCH_COLORS = {
	Color3.fromRGB(80, 200, 255),
	Color3.fromRGB(255, 170, 60),
	Color3.fromRGB(220, 110, 255),
}
local OTHER_COLOR = Color3.fromRGB(150, 160, 190)
local MOON_ORBIT_COLOR = Color3.fromRGB(110, 112, 125)
local ATMOSPHERE_COLOR = Color3.fromRGB(120, 170, 255)
local SOI_COLOR = Color3.fromRGB(180, 180, 200)
local OWN_COLOR = Color3.fromRGB(255, 140, 40)
local CRAFT_COLOR = Color3.fromRGB(242, 244, 252)
local DEBRIS_COLOR = Color3.fromRGB(150, 158, 184)
local APSIS_COLOR = Color3.fromRGB(80, 200, 255)
local PANEL_COLOR = Color3.fromRGB(22, 26, 38)
local TEXT_DIM = Color3.fromRGB(150, 158, 184)
local FONT_BOLD = Enum.Font.BuilderSansBold
local FONT_HEAVY = Enum.Font.BuilderSansExtraBold
--============================================================================

type FocusKind = "Body" | "Craft"
type Focus = { kind: FocusKind, id: number }

type Line = {
	anchor: Part,
	attachments: { Attachment },
	beams: { Beam },
	capacity: number,
	points: { Vec3d }, -- metres, relative to the anchor body's centre
	count: number, -- points in use (0 = hidden)
	bodyId: number,
	anchorUT: number?, -- nil = the body's position now
	offset: Vector3, -- anchor offset from the map origin this frame
}

type BodyVisual = {
	body: Bodies.Body,
	ball: Part,
	shell: Part?,
	soi: Part?,
	ghost: Part?,
	gui: BillboardGui,
}

type Marker = {
	gui: BillboardGui,
	attachment: Attachment,
	button: TextButton,
	dot: Frame,
}

type Apsis = {
	marker: Marker,
	active: boolean,
	bodyId: number,
	anchorUT: number?,
	rel: Vec3d, -- relative to the body
	ut: number, -- when the craft gets there
	altitude: number,
	kind: string,
}

local MapViewController = {}

local player = Players.LocalPlayer
local isOpen = false
local built = false
local folder: Folder
local root: Part
local origin = Vector3.zero
local scale = MAP_SCALE
local yaw = DEFAULT_YAW
local pitch = DEFAULT_PITCH
local focus: Focus? = nil
local ownProvider: (() -> (number?, State?))? = nil
local savedFieldOfView = 70
local savedCameraType = Enum.CameraType.Custom

local bodyVisuals: { [number]: BodyVisual } = {}
local patchLines: { Line } = {}
local otherLines: { Line } = {}
local moonLines: { [number]: Line } = {}
local craftMarkers: { [number]: Marker } = {}
local apsides: { Apsis } = {}
local patches: { Rails.Patch } = {}
local trackedId: number? = nil
local otherAssigned: { [number]: number } = {} -- other line index -> craft id

local predictTimer = math.huge
local otherTimer = math.huge
local lineTimer = math.huge
local layoutScale = 0 -- scale the lines were last laid out at

local overlay: ScreenGui
local focusLabel: TextLabel
local scaleLabel: TextLabel

local dragging: Enum.UserInputType? = nil
local dragDistance = 0
local cachedOwnId: number? = nil -- own craft, resolved once per frame
local cachedOwnState: State? = nil

--============================================================================
-- Instances
--============================================================================

local function newPart(props: { [string]: any }, parent: Instance?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = parent
	return p
end

local function dim(color: Color3, factor: number): Color3
	return Color3.new(color.R * factor, color.G * factor, color.B * factor)
end

local function newLine(capacity: number, color: Color3, width: number): Line
	local anchor = newPart({ Name = "Line", Size = Vector3.one * 0.2, Transparency = 1 }, folder)
	local attachments: { Attachment } = table.create(capacity + 1)
	for index = 1, capacity + 1 do
		local attachment = Instance.new("Attachment")
		attachment.Parent = anchor
		attachments[index] = attachment
	end
	local beams: { Beam } = table.create(capacity)
	local colorSequence = ColorSequence.new(color)
	local transparency = NumberSequence.new(0)
	for index = 1, capacity do
		local beam = Instance.new("Beam")
		beam.Attachment0 = attachments[index]
		beam.Attachment1 = attachments[index + 1]
		beam.Width0 = width
		beam.Width1 = width
		beam.FaceCamera = true
		beam.Segments = 1
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Color = colorSequence
		beam.Transparency = transparency
		beam.Enabled = false
		beam.Parent = anchor
		beams[index] = beam
	end
	return {
		anchor = anchor,
		attachments = attachments,
		beams = beams,
		capacity = capacity,
		points = {},
		count = 0,
		bodyId = Bodies.HOMEWORLD,
		anchorUT = nil,
		offset = Vector3.zero,
	}
end

local function hideLine(line: Line)
	if line.count > 0 then
		line.count = 0
		for _, beam in line.beams do
			beam.Enabled = false
		end
	end
end

local function newMarker(name: string, color: Color3, clickable: boolean): Marker
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Parent = root
	local gui = Instance.new("BillboardGui")
	gui.Name = "MapMarker_" .. name
	gui.Adornee = attachment
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = math.huge
	gui.Size = UDim2.fromOffset(160, 44)
	gui.ResetOnSpawn = false
	gui.Enabled = false
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(9, 9)
	dot.BackgroundColor3 = color
	dot.BorderSizePixel = 0
	dot.Rotation = 45
	dot.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 1
	stroke.Transparency = 0.3
	stroke.Parent = dot
	local button = Instance.new("TextButton")
	button.AnchorPoint = Vector2.new(0.5, 0)
	button.Position = UDim2.new(0.5, 0, 0.5, 8)
	button.Size = UDim2.new(1, 0, 0.5, -8)
	button.BackgroundTransparency = 1
	button.Font = FONT_BOLD
	button.TextSize = 13
	button.TextColor3 = color
	button.TextStrokeTransparency = 0.35
	button.AutoButtonColor = false
	button.Active = clickable
	button.Text = ""
	button.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	return { gui = gui, attachment = attachment, button = button, dot = dot }
end

local function destroyMarker(marker: Marker)
	marker.gui:Destroy()
	marker.attachment:Destroy()
end

local function buildOverlay()
	local gui = Instance.new("ScreenGui")
	gui.Name = "MapViewUI"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 9 -- under the flight HUD (10)
	gui.Enabled = false
	local panel = Instance.new("Frame")
	panel.AnchorPoint = Vector2.new(0.5, 0)
	panel.Position = UDim2.new(0.5, 0, 0, 12)
	panel.Size = UDim2.fromOffset(0, 46)
	panel.AutomaticSize = Enum.AutomaticSize.X
	panel.BackgroundColor3 = PANEL_COLOR
	panel.BackgroundTransparency = 0.12
	panel.BorderSizePixel = 0
	panel.Active = false
	panel.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 12)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = OWN_COLOR
	stroke.Thickness = 1.5
	stroke.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 16)
	pad.PaddingRight = UDim.new(0, 16)
	pad.Parent = panel
	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.fromOffset(0, 26)
	title.AutomaticSize = Enum.AutomaticSize.X
	title.Font = FONT_HEAVY
	title.TextSize = 20
	title.TextColor3 = Color3.new(1, 1, 1)
	title.RichText = true
	title.Text = ""
	title.Parent = panel
	focusLabel = title
	local help = Instance.new("TextLabel")
	help.BackgroundTransparency = 1
	help.Position = UDim2.fromOffset(0, 26)
	help.Size = UDim2.fromOffset(0, 16)
	help.AutomaticSize = Enum.AutomaticSize.X
	help.Font = FONT_BOLD
	help.TextSize = 12
	help.TextColor3 = TEXT_DIM
	help.Text = "Drag: rotate   Wheel: zoom   Click a body or craft: focus   M / Esc: close"
	help.Parent = panel
	scaleLabel = Instance.new("TextLabel")
	scaleLabel.BackgroundTransparency = 1
	scaleLabel.AnchorPoint = Vector2.new(0.5, 0)
	scaleLabel.Position = UDim2.new(0.5, 0, 0, 62)
	scaleLabel.Size = UDim2.fromOffset(240, 16)
	scaleLabel.Font = FONT_BOLD
	scaleLabel.TextSize = 12
	scaleLabel.TextColor3 = TEXT_DIM
	scaleLabel.TextStrokeTransparency = 0.5
	scaleLabel.Text = ""
	scaleLabel.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	overlay = gui
end

local function setFocus(kind: FocusKind, id: number)
	focus = { kind = kind, id = id }
	predictTimer = math.huge
	otherTimer = math.huge
	lineTimer = math.huge
end

local function buildMap()
	if built then
		return
	end
	built = true
	folder = Instance.new("Folder")
	folder.Name = "MapView"
	root = newPart({ Name = "MapRoot", Size = Vector3.one * 0.2, Transparency = 1 }, folder)
	for _, body in Bodies.physicalBodies() do
		local color = dim(body.Color, BODY_BRIGHTNESS)
		local ball = newPart({
			Name = body.Name,
			Shape = Enum.PartType.Ball,
			Size = Vector3.one,
			Color = color,
			CanQuery = true, -- picked by clicks (raycasts include only this folder)
		}, folder)
		ball:SetAttribute("BodyId", body.Id)
		local shell: Part? = nil
		if body.Atmosphere then
			shell = newPart({
				Name = body.Name .. "Air",
				Shape = Enum.PartType.Ball,
				Size = Vector3.one,
				Color = dim(body.AtmosphereColor or ATMOSPHERE_COLOR, 0.6),
				Transparency = 0.82,
			}, folder)
		end
		local soi: Part? = nil
		local ghost: Part? = nil
		if body.Orbit then
			soi = newPart({
				Name = body.Name .. "Soi",
				Shape = Enum.PartType.Ball,
				Size = Vector3.one,
				Color = dim(SOI_COLOR, 0.35),
				Transparency = 0.9,
			}, folder)
			ghost = newPart({
				Name = body.Name .. "Encounter",
				Shape = Enum.PartType.Ball,
				Size = Vector3.one,
				Color = color,
				Transparency = 0.6,
			}, folder)
			moonLines[body.Id] = newLine(DENT_ORBIT_SEGMENTS, MOON_ORBIT_COLOR, LINE_WIDTH_OTHER)
		end
		local marker = newMarker(body.Name, CRAFT_COLOR, true)
		marker.attachment:Destroy()
		marker.gui.Adornee = ball
		marker.dot.Visible = false
		marker.button.Position = UDim2.fromScale(0.5, 0)
		marker.button.Size = UDim2.fromScale(1, 0.5)
		marker.button.Text = body.DisplayName
		marker.button.TextColor3 = Color3.new(1, 1, 1)
		local bodyId = body.Id
		marker.button.Activated:Connect(function()
			setFocus("Body", bodyId)
		end)
		bodyVisuals[body.Id] = { body = body, ball = ball, shell = shell, soi = soi, ghost = ghost, gui = marker.gui }
	end
	for index = 1, MAX_PATCHES do
		patchLines[index] = newLine(FOCUS_SEGMENTS, PATCH_COLORS[(index - 1) % #PATCH_COLORS + 1], LINE_WIDTH_FOCUS)
	end
	for index = 1, MAX_OTHER_ORBITS do
		otherLines[index] = newLine(OTHER_SEGMENTS, OTHER_COLOR, LINE_WIDTH_OTHER)
	end
	for _, kind in { "Ap", "Pe", "Pe2", "Pe3" } do
		local marker = newMarker(kind, APSIS_COLOR, false)
		marker.dot.Size = UDim2.fromOffset(7, 7)
		marker.button.TextSize = 12
		table.insert(apsides, {
			marker = marker,
			active = false,
			bodyId = Bodies.HOMEWORLD,
			anchorUT = nil,
			rel = Vec3d.zero(),
			ut = 0,
			altitude = 0,
			kind = string.sub(kind, 1, 2),
		})
	end
	buildOverlay()
end

--============================================================================
-- Universe -> map
--============================================================================

local function absolute(bodyId: number, pos: Vec3d, ut: number): Vec3d
	local b = Universe.bodyPosition(bodyId, ut)
	return Vec3d.new(b.x + pos.x, b.y + pos.y, b.z + pos.z)
end

-- Map offset (studs, relative to the map origin) of an absolute position, given the focus position.
local function toMap(abs: Vec3d, focusAbs: Vec3d): Vector3
	return Vector3.new((abs.x - focusAbs.x) * scale, (abs.y - focusAbs.y) * scale, (abs.z - focusAbs.z) * scale)
end

local function resolveOwnCraft(): (number?, State?)
	local provider = ownProvider
	if provider then
		local id, state = provider()
		if id and state then
			return id, state
		end
	end
	-- passengers: the pocket's primary craft
	local pockets = Workspace:FindFirstChild("Pockets")
	local pocket = if pockets then pockets:FindFirstChild(`Pocket_{PocketController.pocketId()}`) else nil
	local primary = if pocket then pocket:GetAttribute("PrimaryId") else nil
	if type(primary) == "number" then
		return primary, RemoteCraftRenderer.sampleState(primary, UniverseTime.now() - INTERP_DELAY)
	end
	return nil, nil
end

local function ownCraft(): (number?, State?)
	return cachedOwnId, cachedOwnState
end

local function craftState(id: number, ut: number): State?
	local ownId, ownState = ownCraft()
	if id == ownId and ownState then
		return ownState
	end
	local sampleUT = if RemoteCraftRenderer.railsOf(id) then ut else ut - INTERP_DELAY
	return RemoteCraftRenderer.sampleState(id, sampleUT)
end

local function focusAbsolute(ut: number): (Vec3d, string)
	local f = focus
	if f and f.kind == "Craft" then
		local state = craftState(f.id, ut)
		if state then
			local design = RemoteCraftRenderer.design(f.id)
			return absolute(state.bodyId, state.pos, ut), if design then design.name else "Craft"
		end
		focus = nil
		f = nil
	end
	if f and f.kind == "Body" then
		return Universe.bodyPosition(f.id, ut), Bodies.get(f.id).DisplayName
	end
	local id = ownCraft()
	if id then
		setFocus("Craft", id)
		local state = craftState(id, ut)
		if state then
			return absolute(state.bodyId, state.pos, ut), "Your craft"
		end
	end
	setFocus("Body", Bodies.HOMEWORLD)
	return Universe.bodyPosition(Bodies.HOMEWORLD, ut), Bodies.get(Bodies.HOMEWORLD).DisplayName
end

--============================================================================
-- Lines
--============================================================================

local function anchorOffset(line: Line, ut: number, focusAbs: Vec3d): Vector3
	local anchorAbs = Universe.bodyPosition(line.bodyId, line.anchorUT or ut)
	return toMap(anchorAbs, focusAbs)
end

-- Writes attachment positions at the current scale and enables the segments near the focus.
local function layoutLine(line: Line, ut: number, focusAbs: Vec3d)
	if line.count < 2 then
		return
	end
	local offset = anchorOffset(line, ut, focusAbs)
	line.offset = offset
	local beams, attachments, points = line.beams, line.attachments, line.points
	if offset.Magnitude > ANCHOR_LIMIT then
		for _, beam in beams do
			beam.Enabled = false
		end
		return
	end
	local previousNear = false
	for index = 1, line.count do
		local p = points[index]
		local localPos = Vector3.new(p.x * scale, p.y * scale, p.z * scale)
		attachments[index].Position = localPos
		local near = (offset + localPos).Magnitude <= EXTENT
		if index > 1 then
			beams[index - 1].Enabled = near or previousNear
		end
		previousNear = near
	end
	for index = line.count, line.capacity do
		beams[index].Enabled = false
	end
end

local function placeLine(line: Line, ut: number, focusAbs: Vec3d)
	if line.count < 2 then
		return
	end
	local offset = anchorOffset(line, ut, focusAbs)
	line.offset = offset
	line.anchor.CFrame = CFrame.new(origin + offset)
end

-- How far an open orbit around a body is drawn (m from its centre).
local function openDrawRadius(body: Bodies.Body): number
	if body.SoiRadius < math.huge then
		return body.SoiRadius
	end
	local farthest = body.Radius * 4
	for _, child in Bodies.children(body.Id) do
		local orbit = child.Orbit
		if orbit then
			farthest = math.max(farthest, orbit.Radius)
		end
	end
	return farthest * OPEN_DRAW_FACTOR
end

-- Fills `line` with the conic from t0 to t1 seconds after (r0, v0); returns false if there is nothing to draw.
local function fillConic(
	line: Line,
	bodyId: number,
	anchorUT: number?,
	r0: Vec3d,
	v0: Vec3d,
	t0: number,
	t1: number,
	segments: number
): boolean
	if not (t1 > t0) then
		hideLine(line)
		return false
	end
	local mu = Bodies.get(bodyId).Mu
	Kepler.conicPoints(mu, r0, v0, t0, t1, segments, line.points)
	line.count = segments + 1
	line.bodyId = bodyId
	line.anchorUT = anchorUT
	return true
end

-- End time (s after the state) for drawing a patch with no event: a full ellipse, or out to the draw radius.
local function openEnd(bodyId: number, r0: Vec3d, v0: Vec3d, el: Kepler.Elements, t0: number): number
	if el.kind == "Elliptic" and el.apoapsis < openDrawRadius(Bodies.get(bodyId)) then
		return t0 + el.period
	end
	local body = Bodies.get(bodyId)
	local t = Kepler.findRadiusCrossing(body.Mu, r0, v0, openDrawRadius(body), t0, t0 + 1e7, body.Radius)
	return t or (t0 + 20000)
end

local function setApsis(apsis: Apsis, kind: string, patch: Rails.Patch, anchorUT: number?, dt: number)
	local body = Bodies.get(patch.bodyId)
	local rel = Kepler.propagate(body.Mu, patch.r0, patch.v0, dt)
	apsis.active = true
	apsis.kind = kind
	apsis.bodyId = patch.bodyId
	apsis.anchorUT = anchorUT
	apsis.rel = rel
	apsis.ut = patch.startUT + dt
	apsis.altitude = Vec3d.length(rel) - body.Radius
end

local function refreshTracked(ut: number)
	local f = focus
	local id: number? = if f and f.kind == "Craft" then f.id else (ownCraft())
	trackedId = id
	for _, apsis in apsides do
		apsis.active = false
	end
	local state = if id then craftState(id, ut) else nil
	if state == nil then
		patches = {}
		for _, line in patchLines do
			hideLine(line)
		end
		return
	end
	local s = state :: State
	patches = Rails.predict(s.bodyId, s.pos, s.vel, ut, { maxPatches = MAX_PATCHES })
	local nextApsis = 1
	for index, line in patchLines do
		local patch = patches[index]
		if patch == nil then
			hideLine(line)
			continue
		end
		local el = patch.elements
		local anchorUT = if index == 1 then nil else patch.startUT
		local t0 = if index == 1 then math.max(0, ut - patch.startUT) else 0
		local t1 = if patch.endUT < math.huge
			then patch.endUT - patch.startUT
			else openEnd(patch.bodyId, patch.r0, patch.v0, el, t0)
		fillConic(line, patch.bodyId, anchorUT, patch.r0, patch.v0, t0, t1, FOCUS_SEGMENTS)
		-- apsides inside this patch
		local span = patch.endUT - patch.startUT
		if index == 1 and el.kind == "Elliptic" and el.timeToApoapsis and (el.timeToApoapsis :: number) < span then
			setApsis(apsides[nextApsis], "Ap", patch, anchorUT, el.timeToApoapsis :: number)
			nextApsis += 1
		end
		local toPe = el.timeToPeriapsis
		if toPe and toPe < span and nextApsis <= #apsides then
			setApsis(apsides[nextApsis], "Pe", patch, anchorUT, toPe)
			nextApsis += 1
		end
	end
end

local function refreshOthers(ut: number, focusAbs: Vec3d)
	table.clear(otherAssigned)
	local candidates: { { id: number, distance: number, state: State } } = {}
	for _, id in RemoteCraftRenderer.craftIds() do
		local design = RemoteCraftRenderer.design(id)
		if id ~= trackedId and design and not RemoteCraftRenderer.isDebris(id) then
			local state = craftState(id, ut)
			if state then
				local distance = Vec3d.distance(absolute(state.bodyId, state.pos, ut), focusAbs)
				table.insert(candidates, { id = id, distance = distance, state = state })
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.distance < b.distance
	end)
	for index, line in otherLines do
		local candidate = candidates[index]
		if candidate == nil then
			hideLine(line)
			continue
		end
		local s = candidate.state
		local body = Bodies.get(s.bodyId)
		local el = Kepler.elements(body.Mu, s.pos, s.vel)
		local t1 = openEnd(s.bodyId, s.pos, s.vel, el, 0)
		local impact = if el.periapsis < body.Radius
			then Kepler.findRadiusCrossing(body.Mu, s.pos, s.vel, body.Radius, 0, t1, body.Radius * 0.5)
			else nil
		fillConic(line, s.bodyId, nil, s.pos, s.vel, 0, impact or t1, OTHER_SEGMENTS)
		otherAssigned[index] = candidate.id
	end
end

local function refreshMoonOrbits()
	for bodyId, line in moonLines do
		local orbit = Bodies.get(bodyId).Orbit :: Bodies.CircularOrbit
		for index = 1, DENT_ORBIT_SEGMENTS + 1 do
			local angle = (index - 1) / DENT_ORBIT_SEGMENTS * 2 * math.pi
			local p = line.points[index]
			local x, z = orbit.Radius * math.cos(angle), orbit.Radius * math.sin(angle)
			if p then
				Vec3d.set(p, x, 0, z)
			else
				line.points[index] = Vec3d.new(x, 0, z)
			end
		end
		line.count = DENT_ORBIT_SEGMENTS + 1
		line.bodyId = orbit.ParentId
		line.anchorUT = nil
	end
end

--============================================================================
-- Per frame
--============================================================================

local function setBall(part: Part?, center: Vector3, radius: number, visible: boolean)
	if part == nil then
		return
	end
	local diameter = radius * 2
	local show = visible and diameter <= MAX_BALL_SIZE and center.Magnitude - radius <= EXTENT and diameter > 0.05
	if show then
		if math.abs(part.Size.X - diameter) > diameter * 1e-3 then
			part.Size = Vector3.one * diameter
		end
		part.CFrame = CFrame.new(origin + center)
		part.Parent = folder
	else
		part.Parent = nil
	end
end

local function updateBodies(ut: number, focusAbs: Vec3d)
	local encounterUT: { [number]: number } = {}
	for index, patch in patches do
		if index > 1 and encounterUT[patch.bodyId] == nil then
			encounterUT[patch.bodyId] = patch.startUT
		end
	end
	for id, visual in bodyVisuals do
		local body = visual.body
		local center = toMap(Universe.bodyPosition(id, ut), focusAbs)
		setBall(visual.ball, center, body.Radius * scale, true)
		local atmosphere = body.Atmosphere
		if atmosphere then
			setBall(visual.shell, center, (body.Radius + atmosphere.Top) * scale, true)
		end
		if body.SoiRadius < math.huge then
			setBall(visual.soi, center, body.SoiRadius * scale, true)
		end
		local meet = encounterUT[id]
		if visual.ghost then
			if meet and body.Orbit then
				setBall(visual.ghost, toMap(Universe.bodyPosition(id, meet), focusAbs), body.Radius * scale, true)
			else
				setBall(visual.ghost, Vector3.zero, 0, false)
			end
		end
		visual.gui.Enabled = visual.ball.Parent ~= nil
	end
end

local function formatDistance(m: number): string
	if math.abs(m) < 10000 then
		return string.format("%d m", math.floor(m + 0.5))
	end
	return string.format("%.1f km", m / 1000)
end

local function formatTime(seconds: number): string
	local t = math.max(0, seconds)
	if t < 60 then
		return string.format("%.0f s", t)
	elseif t < 3600 then
		return string.format("%dm %02ds", math.floor(t / 60), math.floor(t % 60))
	end
	return string.format("%dh %02dm", math.floor(t / 3600), math.floor(t % 3600 / 60))
end

local function updateMarkers(ut: number, focusAbs: Vec3d)
	local ownId = ownCraft()
	local seen: { [number]: boolean } = {}
	local ids = RemoteCraftRenderer.craftIds()
	if ownId and not table.find(ids, ownId) then
		table.insert(ids, ownId)
	end
	for _, id in ids do
		local state = craftState(id, ut)
		if state == nil then
			continue
		end
		seen[id] = true
		local marker = craftMarkers[id]
		local design = RemoteCraftRenderer.design(id)
		local name = if design then design.name else "Craft"
		local isDebris = RemoteCraftRenderer.isDebris(id)
		if marker == nil then
			local color = if id == ownId then OWN_COLOR elseif isDebris then DEBRIS_COLOR else CRAFT_COLOR
			local created = newMarker(`Craft{id}`, color, true)
			created.button.Text = if isDebris then "" else name
			if isDebris then
				created.dot.Size = UDim2.fromOffset(5, 5)
			end
			local craftId = id
			created.button.Activated:Connect(function()
				setFocus("Craft", craftId)
			end)
			craftMarkers[id] = created
			marker = created
		end
		local m = marker :: Marker
		local offset = toMap(absolute(state.bodyId, state.pos, ut), focusAbs)
		local visible = offset.Magnitude <= EXTENT
		m.gui.Enabled = visible
		if visible then
			m.attachment.Position = offset
		end
	end
	for id, marker in craftMarkers do
		if not seen[id] then
			destroyMarker(marker)
			craftMarkers[id] = nil
		end
	end
	for _, apsis in apsides do
		local marker = apsis.marker
		if not apsis.active then
			marker.gui.Enabled = false
			continue
		end
		local bodyPos = Universe.bodyPosition(apsis.bodyId, apsis.anchorUT or ut)
		local offset = toMap(Vec3d.add(bodyPos, apsis.rel), focusAbs)
		local visible = offset.Magnitude <= EXTENT and apsis.ut >= ut
		marker.gui.Enabled = visible
		if visible then
			marker.attachment.Position = offset
			marker.button.Text = `{apsis.kind} {formatDistance(apsis.altitude)}  {formatTime(apsis.ut - ut)}`
		end
	end
end

local function updateCamera()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = FIELD_OF_VIEW
	local orbit = CFrame.Angles(0, yaw, 0) * CFrame.Angles(-pitch, 0, 0)
	camera.CFrame = CFrame.new(origin) * orbit * CFrame.new(0, 0, CAMERA_DISTANCE)
	camera.Focus = CFrame.new(origin)
end

local function step(dt: number)
	if not isOpen then
		return
	end
	if PocketController.pocketId() == 0 then
		MapViewController.close()
		return
	end
	local t0 = os.clock()
	local ut = UniverseTime.now()
	cachedOwnId, cachedOwnState = resolveOwnCraft()
	local focusAbs, focusName = focusAbsolute(ut)

	predictTimer += dt
	otherTimer += dt
	lineTimer += dt
	local relayout = false
	if predictTimer >= PREDICT_INTERVAL then
		predictTimer = 0
		refreshTracked(ut)
		relayout = true
	end
	if otherTimer >= OTHER_INTERVAL then
		otherTimer = 0
		refreshOthers(ut, focusAbs)
		relayout = true
	end
	if relayout or lineTimer >= LINE_REFRESH or layoutScale ~= scale then
		lineTimer = 0
		layoutScale = scale
		for _, line in moonLines do
			layoutLine(line, ut, focusAbs)
		end
		for _, line in patchLines do
			layoutLine(line, ut, focusAbs)
		end
		for _, line in otherLines do
			layoutLine(line, ut, focusAbs)
		end
	end
	for _, line in moonLines do
		placeLine(line, ut, focusAbs)
	end
	for _, line in patchLines do
		placeLine(line, ut, focusAbs)
	end
	for _, line in otherLines do
		placeLine(line, ut, focusAbs)
	end
	updateBodies(ut, focusAbs)
	updateMarkers(ut, focusAbs)
	updateCamera()

	focusLabel.Text = `MAP  <font color="#FFC05A">{focusName}</font>`
	scaleLabel.Text = string.format("1 stud = %s", formatDistance(1 / scale))
	DebugOverlay.recordTiming("MapView", (os.clock() - t0) * 1000)
end

--============================================================================
-- Input
--============================================================================

local function pick()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder }
	local hit = Workspace:Raycast(ray.Origin, ray.Direction * (CAMERA_DISTANCE + EXTENT * 2), params)
	local bodyId = if hit then hit.Instance:GetAttribute("BodyId") else nil
	if type(bodyId) == "number" then
		setFocus("Body", bodyId)
	end
end

local function onInputBegan(input: InputObject, processed: boolean)
	if input.KeyCode == Enum.KeyCode.Escape and isOpen then
		MapViewController.close()
		return
	end
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.M then
		if isOpen then
			MapViewController.close()
		else
			MapViewController.open()
		end
		return
	end
	if not isOpen then
		return
	end
	local kind = input.UserInputType
	if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.MouseButton2 then
		dragging = kind
		dragDistance = 0
		if kind == Enum.UserInputType.MouseButton2 then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end
end

local function onInputChanged(input: InputObject, processed: boolean)
	if not isOpen then
		return
	end
	local kind = input.UserInputType
	if kind == Enum.UserInputType.MouseMovement and dragging then
		local delta = input.Delta
		dragDistance += math.abs(delta.X) + math.abs(delta.Y)
		yaw -= delta.X * ROTATE_SENSITIVITY
		pitch = math.clamp(pitch + delta.Y * ROTATE_SENSITIVITY, -PITCH_LIMIT, PITCH_LIMIT)
	elseif kind == Enum.UserInputType.MouseWheel and not processed then
		local notches = input.Position.Z
		scale = math.clamp(scale * ZOOM_STEP ^ notches, SCALE_MIN, SCALE_MAX)
	end
end

local function onInputEnded(input: InputObject, _processed: boolean)
	local kind = input.UserInputType
	if dragging ~= nil and kind == dragging then
		if kind == Enum.UserInputType.MouseButton2 then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if isOpen and kind == Enum.UserInputType.MouseButton1 and dragDistance < CLICK_PIXELS then
			pick()
		end
		dragging = nil
	end
end

--============================================================================
-- API
--============================================================================

function MapViewController.isOpen(): boolean
	return isOpen
end

-- The flight controller registers the craft it simulates (id and exact state), so the map uses its own state.
function MapViewController.setOwnCraftProvider(provider: () -> (number?, State?))
	ownProvider = provider
end

function MapViewController.open()
	if isOpen or PocketController.pocketId() == 0 then
		return
	end
	buildMap()
	isOpen = true
	local slot = PocketController.frame().slotOrigin
	origin = slot + Vector3.new(0, if slot.Y > HIGH_SLOT_Y then -ORIGIN_OFFSET else ORIGIN_OFFSET, 0)
	root.CFrame = CFrame.new(origin)
	scale = MAP_SCALE
	yaw, pitch = DEFAULT_YAW, DEFAULT_PITCH
	focus = nil
	predictTimer, otherTimer, lineTimer = math.huge, math.huge, math.huge
	refreshMoonOrbits()
	local camera = Workspace.CurrentCamera
	if camera then
		savedFieldOfView = camera.FieldOfView
		savedCameraType = camera.CameraType
	end
	folder.Parent = Workspace
	overlay.Enabled = true
	local cube = math.min(EXTENT + CAMERA_DISTANCE + CUBE_MARGIN, UniverseRenderer.drawDistance() * CUBE_DRAW_FRACTION)
	UniverseRenderer.setMapMode(true, cube)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
end

function MapViewController.close()
	if not isOpen then
		return
	end
	isOpen = false
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	UniverseRenderer.setMapMode(false)
	folder.Parent = nil
	overlay.Enabled = false
	for _, marker in craftMarkers do
		destroyMarker(marker)
	end
	table.clear(craftMarkers)
	for _, apsis in apsides do
		apsis.marker.gui.Enabled = false
	end
	for _, visual in bodyVisuals do
		visual.gui.Enabled = false
	end
	if dragging == Enum.UserInputType.MouseButton2 then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	dragging = nil
	local camera = Workspace.CurrentCamera
	if camera then
		camera.FieldOfView = savedFieldOfView
		camera.CameraType = savedCameraType
		if savedCameraType == Enum.CameraType.Custom then
			local character = player.Character
			local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
			if humanoid then
				camera.CameraSubject = humanoid
			end
		end
	end
end

--============================================================================
-- Lifecycle
--============================================================================

function MapViewController.Init()
	DebugOverlay.addLine("map", 24, function()
		if not isOpen then
			return "Map: closed (M)"
		end
		local f = focus
		return string.format(
			"Map: focus %s %d  scale %.5f stud/m  patches %d",
			if f then f.kind else "-",
			if f then f.id else 0,
			scale,
			#patches
		)
	end)
end

function MapViewController.Start()
	UserInputService.InputBegan:Connect(onInputBegan)
	UserInputService.InputChanged:Connect(onInputChanged)
	UserInputService.InputEnded:Connect(onInputEnded)
	GuiService.MenuOpened:Connect(function()
		MapViewController.close()
	end)
	PocketController.onPocketChanged(function(id: number)
		if id == 0 then
			MapViewController.close()
		end
	end)
end

return MapViewController
