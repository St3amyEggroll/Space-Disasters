--!strict
--[[
	HomeBase
	Builds the Space Disasters Inc.: the home base site in base-pocket coordinates (= workspace
	coordinates, ground level y = 0). All plot, pad and spawn geometry comes from BaseLayout so the server and
	client code that uses BaseLayout matches what is drawn here exactly.

	Plane Crazy style: every plot is an open, raised baseplate with the block grid painted on it, and the
	launch pads are shared in a launch area north of the plots. Nothing is ever built above a plot's baseplate
	(its build volume) or above a pad.

	HomeBase.build() returns a new, unparented Model named "HomeBase":
	  Ground              ground plate, top at y = 0
	  Spawn               SpawnLocation at BaseLayout.SPAWN_POSITION (top at y = 0.5)
	  Street              road strip along X through the middle
	  Plots/Plot_<i>      per plot (attribute PlotIndex):
	    BuildFloor        the baseplate; its top face (y = PLOT_TOP) is the build grid floor, footprint = build size
	    GridLine          painted block grid on the baseplate (every GRID studs from buildOrigin; visual only)
	    Border            coloured strips just outside the footprint
	    Ramp              wedge from the ground up onto the baseplate on the street side
	    Sign              plot sign facing the street (beside the plate); SurfaceGui "SignGui" with TextLabels
	                      "Title" and "Owner" (filled by the server)
	  LaunchArea/Pad_<i>  per pad (attribute PadIndex): Pad slab (top at y = PAD_HEIGHT) with painted markings,
	                      front ramp and a launch tower behind the pad
	  LaunchArea          also the road from the street to the pads, the front road and the "LAUNCH AREA" arch
	  Decor               street lines, lamps, fuel tanks, the entrance arch and the control building
	Model attribute PartCount = number of BaseParts. Everything is anchored; no scripts. Deterministic, so
	clients in other pockets can build the identical site as part of the planet surface.
]]

local BaseLayout = require(script.Parent.Parent.Config.BaseLayout)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)

type PlotInfo = BaseLayout.PlotInfo
type PadInfo = BaseLayout.PadInfo

--============================================================================
-- Tunables
--============================================================================
local PART_BUDGET = 1400 -- hard error above this (or GameConfig.HOME_BASE_MAX_PARTS if lower)
local GROUND_TOP = 0
local GROUND_THICKNESS = 20
local GRID_LINE_WIDTH = 0.12
local GRID_LINE_HEIGHT_X = 0.05 -- lines running along X
local GRID_LINE_HEIGHT_Z = 0.06 -- lines running along Z (slightly taller so the crossings do not z-fight)
local GRID_LINE_TRANSPARENCY = 0.35
local BORDER_WIDTH = 1
local RAMP_DEPTH = 6 -- plot and pad ramps: studs of run for the 1-stud rise
local SIGN_SIZE = Vector3.new(9, 4.5, 0.4)
local SIGN_SIDE_OFFSET = 5.5 -- sign centre, studs beyond the plate's side edge (in the gap between plots)
local SIGN_STREET_OFFSET = 1.5 -- sign centre, studs beyond the plate's street-side edge
local SIGN_BOTTOM = 3
local STREET_ROAD_HALF_WIDTH = 14
local STREET_HALF_LENGTH = 410
local ROAD_TOP = 0.05
local MARKING_TOP = 0.08 -- painted lines on the roads
local LAUNCH_ROAD_CLEARANCE = 3 -- launch road edge to the plot footprints on either side of it
local FRONT_ROAD_WIDTH = 14 -- road along the front of the pads
local FRONT_ROAD_OVERHANG = 6 -- front road extends this far past the outer pads
local PAD_MARK_THICKNESS = 0.04
local PAD_RING_RADIUS = 30
local PAD_RING_SEGMENTS = 16
local PAD_RING_WIDTH = 1.5
local PAD_EDGE_INSET = 1.5
local PAD_EDGE_WIDTH = 1.5
local PAD_NUMBER_SIZE = 24
-- CHANGED (Physics feel): a taller tower closer to the rocket, so a climbing craft has something to pass. It stays
-- outside the pad footprint (rockets up to the full 80-stud build footprint are centred on the pad).
local TOWER_GAP = 4 -- studs from the pad's back edge to the tower centre (was 5; base stays 1 stud off the pad)
local TOWER_SIDE_OFFSET = 20 -- tower centre, studs along X from the pad centre (was 30)
local TOWER_HEIGHT = 80 -- was 40
local TOWER_BAND_HEIGHT = 10 -- the column alternates orange / white segments this tall
local TOWER_ARM_HEIGHT = 32 -- service arm height (where it was on the 40-stud tower)
local TOWER_BEACON_FRACTIONS = { 0.3, 0.6 } -- beacons on the pad side of the column at these heights, plus the top
local TOWER_BEACON_DIAMETER = 1.6
local TOWER_BEACON_LIGHT_RANGE = 14 -- studs, PointLight of the top beacon
local TOWER_BEACON_LIGHT_BRIGHTNESS = 2
local LAMP_XS = { -300, -200, -100, 100, 200, 300 } -- street lamps (in the gaps between plot columns)
local LAMP_HEIGHT = 16
local LAUNCH_LAMP_ZS = { 150, 190 }
local ENTRANCE_ARCH_Z = -26 -- south of the spawn, facing it
local ENTRANCE_ARCH_HALF_SPAN = 24
local ENTRANCE_ARCH_HEIGHT = 20 -- underside of the sign beam
local ENTRANCE_ARCH_BEAM = Vector3.new(54, 8, 3)
local LAUNCH_ARCH_SETBACK = 14 -- studs south of the front road
local LAUNCH_ARCH_HEIGHT = 18
local LAUNCH_ARCH_BEAM = Vector3.new(30, 6, 3)
local TANK_DIAMETER = 12
local TANK_HEIGHT = 24
local TANK_SITES = { -- absolute pocket positions (clear of plots, pads and roads)
	Vector3.new(345, 0, 40),
	Vector3.new(375, 0, 60),
	Vector3.new(345, 0, 80),
	Vector3.new(-345, 0, -40),
	Vector3.new(-375, 0, -60),
	Vector3.new(-345, 0, -80),
}
local TANK_FARM = { -- relative to (launch road centre X, 0, north plot row's far edge Z)
	Vector3.new(-28, 0, 30),
	Vector3.new(-46, 0, 30),
	Vector3.new(-37, 0, 48),
}
local CONTROL_MIN = Vector3.new(18, 0, 22) -- relative to (launch road centre X, 0, north plot row's far edge Z)
local CONTROL_MAX = Vector3.new(54, 12, 46)

local COLOR_GROUND = Color3.fromRGB(99, 102, 107)
local COLOR_PLATE = Color3.fromRGB(232, 235, 240)
local COLOR_GRID = Color3.fromRGB(150, 160, 176)
local COLOR_ORANGE = Color3.fromRGB(255, 140, 26)
local COLOR_WHITE = Color3.fromRGB(242, 242, 236)
local COLOR_METAL = Color3.fromRGB(163, 168, 174)
local COLOR_DARK = Color3.fromRGB(52, 55, 61)
local COLOR_ASPHALT = Color3.fromRGB(58, 60, 66)
local COLOR_PAD = Color3.fromRGB(176, 178, 180)
local COLOR_GLASS = Color3.fromRGB(190, 222, 240)
local COLOR_YELLOW = Color3.fromRGB(255, 205, 60)
local COLOR_LAMP = Color3.fromRGB(255, 236, 190)
local COLOR_BEACON = Color3.fromRGB(255, 70, 50)

local SIGN_FONT = Enum.Font.FredokaOne
--============================================================================

local HomeBase = {}

-- Anchored, smooth part with a CFrame (centre) and size.
local function part(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

-- Axis-aligned part spanning two corners.
local function box(
	parent: Instance,
	name: string,
	minCorner: Vector3,
	maxCorner: Vector3,
	color: Color3,
	material: Enum.Material
): Part
	return part(parent, name, maxCorner - minCorner, CFrame.new((minCorner + maxCorner) / 2), color, material)
end

-- Ramp rising by `size.Y` over `size.Z`; its high edge is on the side of `highDirection` (a horizontal unit
-- vector). A WedgePart's slope faces its front (-Z), so its high edge is at local +Z = -LookVector.
local function ramp(
	parent: Instance,
	name: string,
	size: Vector3,
	center: Vector3,
	highDirection: Vector3,
	color: Color3,
	material: Enum.Material
): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.Size = size
	-- Yaw about Y maps local +Z to (sin yaw, 0, cos yaw). (Avoids CFrame.lookAt, which Lune gets backwards.)
	w.CFrame = CFrame.new(center) * CFrame.Angles(0, math.atan2(highDirection.X, highDirection.Z), 0)
	w.Color = color
	w.Material = material
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	w.Parent = parent
	return w
end

-- Purely visual part: no collision, queries or touches.
local function decal(p: Part): Part
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

-- Vertical cylinder centred on `center` (Roblox cylinders run along their local X axis).
local function cylinder(
	parent: Instance,
	name: string,
	center: Vector3,
	height: number,
	diameter: number,
	color: Color3,
	material: Enum.Material
): Part
	local p = part(
		parent,
		name,
		Vector3.new(height, diameter, diameter),
		CFrame.new(center) * CFrame.Angles(0, 0, math.pi / 2),
		color,
		material
	)
	p.Shape = Enum.PartType.Cylinder
	return p
end

local function ball(
	parent: Instance,
	name: string,
	center: Vector3,
	diameter: number,
	color: Color3,
	material: Enum.Material
): Part
	local p = part(parent, name, Vector3.new(diameter, diameter, diameter), CFrame.new(center), color, material)
	p.Shape = Enum.PartType.Ball
	return p
end

local function label(parent: Instance, name: string, text: string, y: number, height: number, color: Color3): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromScale(0.05, y)
	t.Size = UDim2.fromScale(0.9, height)
	t.Font = SIGN_FONT
	t.Text = text
	t.TextScaled = true
	t.TextColor3 = color
	t.Parent = parent
	return t
end

local function surfaceGui(parent: Instance, name: string, face: Enum.NormalId): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Name = name
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.LightInfluence = 0.5
	gui.Parent = parent
	return gui
end

-- Face of an axis-aligned part whose outward normal is `direction` (+Z or -Z).
local function faceTowardZ(direction: number): Enum.NormalId
	return if direction > 0 then Enum.NormalId.Back else Enum.NormalId.Front
end

local function lampPost(parent: Instance, base: Vector3, armDirection: Vector3)
	local lamp = Instance.new("Model")
	lamp.Name = "LampPost"
	lamp.Parent = parent
	local x, z = base.X, base.Z
	box(
		lamp,
		"Pole",
		Vector3.new(x - 0.4, GROUND_TOP, z - 0.4),
		Vector3.new(x + 0.4, LAMP_HEIGHT, z + 0.4),
		COLOR_DARK,
		Enum.Material.Metal
	)
	local armEnd = base + armDirection * 3.5
	local lo = Vector3.new(math.min(x, armEnd.X) - 0.3, LAMP_HEIGHT - 0.6, math.min(z, armEnd.Z) - 0.3)
	local hi = Vector3.new(math.max(x, armEnd.X) + 0.3, LAMP_HEIGHT, math.max(z, armEnd.Z) + 0.3)
	box(lamp, "Arm", lo, hi, COLOR_DARK, Enum.Material.Metal)
	local head = decal(
		part(
			lamp,
			"Light",
			Vector3.new(1.6, 0.6, 1.6),
			CFrame.new(armEnd.X, LAMP_HEIGHT - 0.9, armEnd.Z),
			COLOR_LAMP,
			Enum.Material.Neon
		)
	)
	local light = Instance.new("PointLight")
	light.Range = 28
	light.Brightness = 1.2
	light.Color = COLOR_LAMP
	light.Parent = head
end

-- Two white pillars and an orange sign beam spanning along X, text on both Z faces.
local function arch(
	parent: Instance,
	name: string,
	center: Vector3,
	halfSpan: number,
	height: number,
	beamSize: Vector3,
	text: string
)
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	local x, z = center.X, center.Z
	for _, xSign in { -1, 1 } do
		local px = x + xSign * halfSpan
		box(
			model,
			"ArchPillar",
			Vector3.new(px - 1.5, GROUND_TOP, z - 1.5),
			Vector3.new(px + 1.5, height, z + 1.5),
			COLOR_WHITE,
			Enum.Material.Metal
		)
	end
	local beam = part(
		model,
		"ArchSign",
		beamSize,
		CFrame.new(x, height + beamSize.Y / 2, z),
		COLOR_ORANGE,
		Enum.Material.SmoothPlastic
	)
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = surfaceGui(beam, `ArchGui{face.Name}`, face)
		label(gui, "Title", text, 0.12, 0.76, COLOR_WHITE)
	end
	box(
		model,
		"ArchTrim",
		Vector3.new(x - beamSize.X / 2 - 0.2, height + beamSize.Y, z - beamSize.Z / 2 - 0.2),
		Vector3.new(x + beamSize.X / 2 + 0.2, height + beamSize.Y + 0.8, z + beamSize.Z / 2 + 0.2),
		COLOR_WHITE,
		Enum.Material.SmoothPlastic
	)
end

--============================================================================
-- Site geometry derived from BaseLayout
--============================================================================

type SiteGeometry = {
	launchSide: number, -- +1 if the launch area is at +Z of the spawn
	roadCenterX: number, -- launch road centre (in the plot-column gap nearest the spawn)
	roadHalfWidth: number,
	rowFarZ: number, -- far edge (from the street) of the plot row on the launch side
	padFrontZ: number, -- pads' street-facing edge
	frontRoadMinZ: number,
	frontRoadMaxZ: number,
	padMinX: number,
	padMaxX: number,
}

local function siteGeometry(): SiteGeometry
	local spawnX = BaseLayout.SPAWN_POSITION.X
	local launchSide = if BaseLayout.LAUNCH_AREA_Z > BaseLayout.SPAWN_POSITION.Z then 1 else -1

	-- Gap between the launch-side plot columns on either side of the spawn.
	local gapLo, gapHi = -math.huge, math.huge
	local rowFarZ = 0
	for _, info in BaseLayout.Plots do
		if (info.center.Z - BaseLayout.SPAWN_POSITION.Z) * launchSide > 0 then
			local o, s = info.buildOrigin, info.buildSize
			if o.X + s.X <= spawnX then
				gapLo = math.max(gapLo, o.X + s.X)
			elseif o.X >= spawnX then
				gapHi = math.min(gapHi, o.X)
			end
			local far = if launchSide > 0 then o.Z + s.Z else o.Z
			rowFarZ = if launchSide > 0 then math.max(rowFarZ, far) else math.min(rowFarZ, far)
		end
	end
	assert(gapLo > -math.huge and gapHi < math.huge, "HomeBase: no plot gap for the launch road")

	local padMinX, padMaxX = math.huge, -math.huge
	for _, pad in BaseLayout.Pads do
		padMinX = math.min(padMinX, pad.top.X - pad.size / 2)
		padMaxX = math.max(padMaxX, pad.top.X + pad.size / 2)
	end
	local padFrontZ = BaseLayout.LAUNCH_AREA_Z - launchSide * BaseLayout.PAD_SIZE / 2
	local roadNear = padFrontZ - launchSide * RAMP_DEPTH
	local roadFar = roadNear - launchSide * FRONT_ROAD_WIDTH

	return {
		launchSide = launchSide,
		roadCenterX = (gapLo + gapHi) / 2,
		roadHalfWidth = (gapHi - gapLo) / 2 - LAUNCH_ROAD_CLEARANCE,
		rowFarZ = rowFarZ,
		padFrontZ = padFrontZ,
		frontRoadMinZ = math.min(roadNear, roadFar),
		frontRoadMaxZ = math.max(roadNear, roadFar),
		padMinX = padMinX,
		padMaxX = padMaxX,
	}
end

--============================================================================
-- Plots
--============================================================================

local function buildBaseplate(model: Model, info: PlotInfo)
	local o = info.buildOrigin
	local s = info.buildSize
	local plateTop = o.Y

	local floor = box(
		model,
		"BuildFloor",
		Vector3.new(o.X, GROUND_TOP, o.Z),
		Vector3.new(o.X + s.X, plateTop, o.Z + s.Z),
		COLOR_PLATE,
		Enum.Material.SmoothPlastic
	)
	floor.CanCollide = true
	floor.CanQuery = true

	-- Block grid: one line on every multiple of GRID from the build origin, edges included.
	local g = BaseLayout.GRID
	for i = 0, math.round(s.X / g) do
		local line = decal(
			part(
				model,
				"GridLine",
				Vector3.new(GRID_LINE_WIDTH, GRID_LINE_HEIGHT_Z, s.Z),
				CFrame.new(o.X + i * g, plateTop + GRID_LINE_HEIGHT_Z / 2, o.Z + s.Z / 2),
				COLOR_GRID,
				Enum.Material.SmoothPlastic
			)
		)
		line.Transparency = GRID_LINE_TRANSPARENCY
	end
	for j = 0, math.round(s.Z / g) do
		local line = decal(
			part(
				model,
				"GridLine",
				Vector3.new(s.X, GRID_LINE_HEIGHT_X, GRID_LINE_WIDTH),
				CFrame.new(o.X + s.X / 2, plateTop + GRID_LINE_HEIGHT_X / 2, o.Z + j * g),
				COLOR_GRID,
				Enum.Material.SmoothPlastic
			)
		)
		line.Transparency = GRID_LINE_TRANSPARENCY
	end

	-- Border just outside the footprint, flush with the plate top.
	local w = BORDER_WIDTH
	local strips = {
		{ Vector3.new(o.X - w, GROUND_TOP, o.Z - w), Vector3.new(o.X + s.X + w, plateTop, o.Z) },
		{ Vector3.new(o.X - w, GROUND_TOP, o.Z + s.Z), Vector3.new(o.X + s.X + w, plateTop, o.Z + s.Z + w) },
		{ Vector3.new(o.X - w, GROUND_TOP, o.Z), Vector3.new(o.X, plateTop, o.Z + s.Z) },
		{ Vector3.new(o.X + s.X, GROUND_TOP, o.Z), Vector3.new(o.X + s.X + w, plateTop, o.Z + s.Z) },
	}
	for _, strip in strips do
		box(model, "Border", strip[1], strip[2], COLOR_ORANGE, Enum.Material.SmoothPlastic)
	end

	-- Ramp from the ground up onto the plate on the street side (outside the border).
	local f = info.facingStreet
	local streetEdgeZ = if f.Z > 0 then o.Z + s.Z else o.Z
	local rampZ = streetEdgeZ + f.Z * (w + RAMP_DEPTH / 2)
	ramp(
		model,
		"Ramp",
		Vector3.new(s.X, plateTop - GROUND_TOP, RAMP_DEPTH),
		Vector3.new(o.X + s.X / 2, (GROUND_TOP + plateTop) / 2, rampZ),
		-f,
		COLOR_PLATE,
		Enum.Material.SmoothPlastic
	)
end

local function buildSign(model: Model, info: PlotInfo)
	local o = info.buildOrigin
	local s = info.buildSize
	local f = info.facingStreet.Z
	local streetEdgeZ = if f > 0 then o.Z + s.Z else o.Z
	local z = streetEdgeZ + f * SIGN_STREET_OFFSET
	-- Beside the plate, on the side away from the spawn (keeps the centre gaps free for the roads).
	local side = if info.center.X < BaseLayout.SPAWN_POSITION.X then -1 else 1
	local x = (if side < 0 then o.X else o.X + s.X) + side * SIGN_SIDE_OFFSET
	local signTop = SIGN_BOTTOM + SIGN_SIZE.Y

	local sign = part(
		model,
		"Sign",
		SIGN_SIZE,
		CFrame.new(x, SIGN_BOTTOM + SIGN_SIZE.Y / 2, z),
		COLOR_ORANGE,
		Enum.Material.SmoothPlastic
	)
	local gui = surfaceGui(sign, "SignGui", faceTowardZ(f))
	label(gui, "Title", `PLOT {info.index}`, 0.05, 0.5, COLOR_WHITE)
	label(gui, "Owner", "", 0.58, 0.36, COLOR_DARK)

	local postZ = z - f * (SIGN_SIZE.Z / 2 + 0.2)
	for _, dx in { -SIGN_SIZE.X / 2 + 1, SIGN_SIZE.X / 2 - 1 } do
		box(
			model,
			"SignPost",
			Vector3.new(x + dx - 0.2, GROUND_TOP, postZ - 0.2),
			Vector3.new(x + dx + 0.2, signTop, postZ + 0.2),
			COLOR_METAL,
			Enum.Material.Metal
		)
	end
end

local function buildPlot(parent: Instance, info: PlotInfo)
	local model = Instance.new("Model")
	model.Name = `Plot_{info.index}`
	model:SetAttribute("PlotIndex", info.index)
	buildBaseplate(model, info)
	buildSign(model, info)
	model.Parent = parent
end

--============================================================================
-- Launch area
--============================================================================

local function buildPad(parent: Instance, info: PadInfo, site: SiteGeometry)
	local model = Instance.new("Model")
	model.Name = `Pad_{info.index}`
	model:SetAttribute("PadIndex", info.index)

	local size = info.size
	local h = BaseLayout.PAD_HEIGHT
	local top = info.top
	local pad = part(
		model,
		"Pad",
		Vector3.new(size, h, size),
		CFrame.new(top.Position - Vector3.new(0, h / 2, 0)),
		COLOR_PAD,
		Enum.Material.Concrete
	)
	pad.CanCollide = true
	pad.CanQuery = true

	-- Painted markings lying on the top face (visual only; rockets rest on the slab).
	local markY = PAD_MARK_THICKNESS / 2
	local chord = 2 * PAD_RING_RADIUS * math.tan(math.pi / PAD_RING_SEGMENTS) + 0.3
	for i = 0, PAD_RING_SEGMENTS - 1 do
		local angle = i * 2 * math.pi / PAD_RING_SEGMENTS
		decal(
			part(
				model,
				"PadRing",
				Vector3.new(chord, PAD_MARK_THICKNESS, PAD_RING_WIDTH),
				top * CFrame.Angles(0, angle, 0) * CFrame.new(0, markY, -PAD_RING_RADIUS),
				COLOR_ORANGE,
				Enum.Material.SmoothPlastic
			)
		)
	end
	local edge = size / 2 - PAD_EDGE_INSET - PAD_EDGE_WIDTH / 2
	local long = size - 2 * PAD_EDGE_INSET
	local short = long - 2 * PAD_EDGE_WIDTH
	local edgeStrips = {
		{ Vector3.new(long, PAD_MARK_THICKNESS, PAD_EDGE_WIDTH), Vector3.new(0, markY, -edge) },
		{ Vector3.new(long, PAD_MARK_THICKNESS, PAD_EDGE_WIDTH), Vector3.new(0, markY, edge) },
		{ Vector3.new(PAD_EDGE_WIDTH, PAD_MARK_THICKNESS, short), Vector3.new(-edge, markY, 0) },
		{ Vector3.new(PAD_EDGE_WIDTH, PAD_MARK_THICKNESS, short), Vector3.new(edge, markY, 0) },
	}
	for _, strip in edgeStrips do
		decal(part(model, "PadEdge", strip[1], top * CFrame.new(strip[2]), COLOR_YELLOW, Enum.Material.SmoothPlastic))
	end
	local number = decal(
		part(
			model,
			"PadNumber",
			Vector3.new(PAD_NUMBER_SIZE, PAD_MARK_THICKNESS, PAD_NUMBER_SIZE),
			top * CFrame.new(0, markY, 0),
			COLOR_DARK,
			Enum.Material.SmoothPlastic
		)
	)
	number.Transparency = 1
	local numberGui = surfaceGui(number, "NumberGui", Enum.NormalId.Top)
	numberGui.PixelsPerStud = 10
	local numberLabel = label(numberGui, "Number", tostring(info.index), 0.05, 0.9, COLOR_DARK)
	numberLabel.TextTransparency = 0.1

	-- Ramp from the front road up onto the pad (outside the pad footprint).
	local towardPad = Vector3.new(0, 0, site.launchSide)
	ramp(
		model,
		"PadRamp",
		Vector3.new(size, h, RAMP_DEPTH),
		Vector3.new(top.X, GROUND_TOP + h / 2, site.padFrontZ - site.launchSide * RAMP_DEPTH / 2),
		towardPad,
		COLOR_PAD,
		Enum.Material.Concrete
	)

	-- Launch tower behind the pad (outside its footprint, not in the walkways between pads).
	local tower = Instance.new("Model")
	tower.Name = "LaunchTower"
	tower.Parent = model
	local backEdgeZ = top.Z + site.launchSide * size / 2
	local tx = top.X + TOWER_SIDE_OFFSET
	local tz = backEdgeZ + site.launchSide * TOWER_GAP
	box(
		tower,
		"TowerBase",
		Vector3.new(tx - 3, GROUND_TOP, tz - 3),
		Vector3.new(tx + 3, GROUND_TOP + 1, tz + 3),
		COLOR_DARK,
		Enum.Material.Concrete
	)
	-- CHANGED (Physics feel): the column is stacked from alternating orange / white segments (was one orange
	-- column with two white bands), so its height reads at a glance
	local columnBottom = GROUND_TOP + 1
	local segment = 0
	local y0 = columnBottom
	while y0 < TOWER_HEIGHT - 1e-6 do
		local y1 = math.min(y0 + TOWER_BAND_HEIGHT, TOWER_HEIGHT)
		box(
			tower,
			if segment % 2 == 0 then "TowerColumn" else "TowerBand",
			Vector3.new(tx - 1.5, y0, tz - 1.5),
			Vector3.new(tx + 1.5, y1, tz + 1.5),
			if segment % 2 == 0 then COLOR_ORANGE else COLOR_WHITE,
			Enum.Material.Metal
		)
		segment += 1
		y0 = y1
	end
	-- Service arm reaching toward the pad; stops half a stud short of the footprint.
	local armFar = backEdgeZ + site.launchSide * 0.5
	local armNear = tz - site.launchSide * 1.5
	box(
		tower,
		"TowerArm",
		Vector3.new(tx - 0.5, TOWER_ARM_HEIGHT, math.min(armFar, armNear)), -- CHANGED (Physics feel): fixed height
		Vector3.new(tx + 0.5, TOWER_ARM_HEIGHT + 1, math.max(armFar, armNear)),
		COLOR_WHITE,
		Enum.Material.Metal
	)
	-- CHANGED (Physics feel): lit beacons up the column on the pad side (still outside the pad footprint), and the
	-- top one casts light
	local beaconZ = tz - site.launchSide * (1.5 + TOWER_BEACON_DIAMETER / 2 - 0.2)
	for _, fraction in TOWER_BEACON_FRACTIONS do
		ball(
			tower,
			"TowerBeacon",
			Vector3.new(tx, TOWER_HEIGHT * fraction, beaconZ),
			TOWER_BEACON_DIAMETER,
			COLOR_BEACON,
			Enum.Material.Neon
		)
	end
	local topBeacon = ball(
		tower,
		"TowerBeacon",
		Vector3.new(tx, TOWER_HEIGHT + TOWER_BEACON_DIAMETER / 2, tz),
		TOWER_BEACON_DIAMETER,
		COLOR_BEACON,
		Enum.Material.Neon
	)
	local light = Instance.new("PointLight")
	light.Color = COLOR_BEACON
	light.Range = TOWER_BEACON_LIGHT_RANGE
	light.Brightness = TOWER_BEACON_LIGHT_BRIGHTNESS
	light.Shadows = false
	light.Parent = topBeacon

	model.Parent = parent
end

local function buildLaunchArea(root: Model, site: SiteGeometry)
	local area = Instance.new("Folder")
	area.Name = "LaunchArea"
	area.Parent = root

	for _, info in BaseLayout.Pads do
		buildPad(area, info, site)
	end

	-- Road from the street edge through the plot gap to the front road.
	local cx, hw = site.roadCenterX, site.roadHalfWidth
	local streetEdgeZ = site.launchSide * STREET_ROAD_HALF_WIDTH
	local frontNearZ = if site.launchSide > 0 then site.frontRoadMinZ else site.frontRoadMaxZ
	local zLo, zHi = math.min(streetEdgeZ, frontNearZ), math.max(streetEdgeZ, frontNearZ)
	decal(
		box(
			area,
			"LaunchRoad",
			Vector3.new(cx - hw, ROAD_TOP - 1, zLo),
			Vector3.new(cx + hw, ROAD_TOP, zHi),
			COLOR_ASPHALT,
			Enum.Material.Asphalt
		)
	)
	decal(
		box(
			area,
			"RoadLine",
			Vector3.new(cx - 0.4, MARKING_TOP - 0.1, zLo),
			Vector3.new(cx + 0.4, MARKING_TOP, zHi),
			COLOR_ORANGE,
			Enum.Material.SmoothPlastic
		)
	)

	-- Front road along the pads.
	local x0, x1 = site.padMinX - FRONT_ROAD_OVERHANG, site.padMaxX + FRONT_ROAD_OVERHANG
	decal(
		box(
			area,
			"FrontRoad",
			Vector3.new(x0, ROAD_TOP - 1, site.frontRoadMinZ),
			Vector3.new(x1, ROAD_TOP, site.frontRoadMaxZ),
			COLOR_ASPHALT,
			Enum.Material.Asphalt
		)
	)
	local midZ = (site.frontRoadMinZ + site.frontRoadMaxZ) / 2
	decal(
		box(
			area,
			"RoadLine",
			Vector3.new(x0, MARKING_TOP - 0.1, midZ - 0.4),
			Vector3.new(x1, MARKING_TOP, midZ + 0.4),
			COLOR_ORANGE,
			Enum.Material.SmoothPlastic
		)
	)

	-- "LAUNCH AREA" arch over the launch road, just before the front road.
	arch(
		area,
		"LaunchArch",
		Vector3.new(cx, GROUND_TOP, frontNearZ - site.launchSide * LAUNCH_ARCH_SETBACK),
		hw + 2.5,
		LAUNCH_ARCH_HEIGHT,
		LAUNCH_ARCH_BEAM,
		"LAUNCH AREA"
	)
end

--============================================================================
-- Street and decor
--============================================================================

local function buildStreet(root: Model, decor: Folder)
	local l = STREET_HALF_LENGTH
	local w = STREET_ROAD_HALF_WIDTH
	decal(
		box(
			root,
			"Street",
			Vector3.new(-l, ROAD_TOP - 1, -w),
			Vector3.new(l, ROAD_TOP, w),
			COLOR_ASPHALT,
			Enum.Material.Asphalt
		)
	)
	local lines: { { z: number, width: number, color: Color3 } } = {
		{ z = -w + 0.5, width = 0.5, color = COLOR_WHITE },
		{ z = w - 1, width = 0.5, color = COLOR_WHITE },
		{ z = -0.4, width = 0.8, color = COLOR_ORANGE },
	}
	for _, line in lines do
		local z0, width, color = line.z, line.width, line.color
		decal(
			box(
				decor,
				"StreetLine",
				Vector3.new(-l, MARKING_TOP - 0.1, z0),
				Vector3.new(l, MARKING_TOP, z0 + width),
				color,
				Enum.Material.SmoothPlastic
			)
		)
	end
end

local function buildFuelTank(decor: Folder, site: Vector3)
	local tank = Instance.new("Model")
	tank.Name = "FuelTank"
	tank.Parent = decor
	cylinder(
		tank,
		"Tank",
		site + Vector3.new(0, TANK_HEIGHT / 2, 0),
		TANK_HEIGHT,
		TANK_DIAMETER,
		COLOR_WHITE,
		Enum.Material.Metal
	)
	cylinder(
		tank,
		"Band",
		site + Vector3.new(0, TANK_HEIGHT * 0.7, 0),
		3,
		TANK_DIAMETER + 0.4,
		COLOR_ORANGE,
		Enum.Material.SmoothPlastic
	)
	ball(tank, "Dome", site + Vector3.new(0, TANK_HEIGHT, 0), TANK_DIAMETER, COLOR_WHITE, Enum.Material.Metal)
end

local function buildControlBuilding(decor: Folder, lo: Vector3, hi: Vector3)
	local building = Instance.new("Model")
	building.Name = "ControlBuilding"
	building.Parent = decor
	local cx = (lo.X + hi.X) / 2
	-- Faces -Z (toward the street; the building sits north of it).
	box(building, "Body", lo, hi, COLOR_WHITE, Enum.Material.Concrete)
	box(
		building,
		"Windows",
		Vector3.new(lo.X + 2, 5, lo.Z - 0.3),
		Vector3.new(hi.X - 2, 9, lo.Z),
		COLOR_GLASS,
		Enum.Material.Glass
	)
	box(
		building,
		"Door",
		Vector3.new(cx - 2.5, lo.Y, lo.Z - 0.2),
		Vector3.new(cx + 2.5, lo.Y + 4.5, lo.Z),
		COLOR_ORANGE,
		Enum.Material.SmoothPlastic
	)
	box(
		building,
		"Roof",
		Vector3.new(lo.X - 0.5, hi.Y, lo.Z - 0.5),
		Vector3.new(hi.X + 0.5, hi.Y + 0.8, hi.Z + 0.5),
		COLOR_ORANGE,
		Enum.Material.SmoothPlastic
	)
	local nameplate = box(
		building,
		"Nameplate",
		Vector3.new(cx - 12, 9.5, lo.Z - 0.3),
		Vector3.new(cx + 12, 11.5, lo.Z),
		COLOR_DARK,
		Enum.Material.SmoothPlastic
	)
	local gui = surfaceGui(nameplate, "NameplateGui", Enum.NormalId.Front)
	label(gui, "Title", "MISSION CONTROL (MOSTLY)", 0.1, 0.8, COLOR_ORANGE)

	-- Tower with a glass cab, an antenna and a dish.
	local tx, tz = hi.X - 6, hi.Z - 6
	box(
		building,
		"Tower",
		Vector3.new(tx - 3, hi.Y + 0.8, tz - 3),
		Vector3.new(tx + 3, hi.Y + 14, tz + 3),
		COLOR_WHITE,
		Enum.Material.Concrete
	)
	local cab = box(
		building,
		"Cab",
		Vector3.new(tx - 4.5, hi.Y + 14, tz - 4.5),
		Vector3.new(tx + 4.5, hi.Y + 19, tz + 4.5),
		COLOR_GLASS,
		Enum.Material.Glass
	)
	cab.Transparency = 0.3
	box(
		building,
		"CabRoof",
		Vector3.new(tx - 5, hi.Y + 19, tz - 5),
		Vector3.new(tx + 5, hi.Y + 20, tz + 5),
		COLOR_ORANGE,
		Enum.Material.SmoothPlastic
	)
	box(
		building,
		"Antenna",
		Vector3.new(tx - 0.2, hi.Y + 20, tz - 0.2),
		Vector3.new(tx + 0.2, hi.Y + 28, tz + 0.2),
		COLOR_METAL,
		Enum.Material.Metal
	)
	local dish = part(
		building,
		"Dish",
		Vector3.new(0.6, 7, 7),
		CFrame.new(lo.X + 6, hi.Y + 4, hi.Z - 6) * CFrame.Angles(0, 0, math.rad(35)),
		COLOR_WHITE,
		Enum.Material.Metal
	)
	dish.Shape = Enum.PartType.Cylinder
	box(
		building,
		"DishMount",
		Vector3.new(lo.X + 5.5, hi.Y + 0.8, hi.Z - 6.5),
		Vector3.new(lo.X + 6.5, hi.Y + 3, hi.Z - 5.5),
		COLOR_METAL,
		Enum.Material.Metal
	)
end

local function buildDecor(root: Model, site: SiteGeometry)
	local decor = Instance.new("Folder")
	decor.Name = "Decor"
	decor.Parent = root
	buildStreet(root, decor)

	-- Street lamps on both kerbs, arms over the street.
	local kerb = STREET_ROAD_HALF_WIDTH + 3
	for _, x in LAMP_XS do
		lampPost(decor, Vector3.new(x, 0, -kerb), Vector3.new(0, 0, 1))
		lampPost(decor, Vector3.new(x, 0, kerb), Vector3.new(0, 0, -1))
	end
	-- Launch road lamps, arms over the road.
	local lampOffset = site.roadHalfWidth + 5
	for _, z in LAUNCH_LAMP_ZS do
		local lz = z * site.launchSide
		lampPost(decor, Vector3.new(site.roadCenterX - lampOffset, 0, lz), Vector3.new(1, 0, 0))
		lampPost(decor, Vector3.new(site.roadCenterX + lampOffset, 0, lz), Vector3.new(-1, 0, 0))
	end

	-- Base name arch on the far side of the street from the launch road, facing the spawn.
	local spawn = BaseLayout.SPAWN_POSITION
	arch(
		decor,
		"EntranceArch",
		Vector3.new(spawn.X, GROUND_TOP, spawn.Z + site.launchSide * ENTRANCE_ARCH_Z),
		ENTRANCE_ARCH_HALF_SPAN,
		ENTRANCE_ARCH_HEIGHT,
		ENTRANCE_ARCH_BEAM,
		GameConfig.BASE_SITE_NAME
	)

	for _, tankSite in TANK_SITES do
		buildFuelTank(decor, tankSite)
	end
	local anchor = Vector3.new(site.roadCenterX, GROUND_TOP, site.rowFarZ)
	local zSign = Vector3.new(1, 1, site.launchSide)
	for _, offset in TANK_FARM do
		buildFuelTank(decor, anchor + offset * zSign)
	end
	local a, b = anchor + CONTROL_MIN * zSign, anchor + CONTROL_MAX * zSign
	buildControlBuilding(decor, a:Min(b), a:Max(b))
end

--============================================================================
-- Build
--============================================================================

local function countParts(root: Instance): number
	local count = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			count += 1
		end
	end
	return count
end

function HomeBase.build(): Model
	local root = Instance.new("Model")
	root.Name = "HomeBase"

	local e = BaseLayout.SITE_HALF_EXTENT
	local ground = box(
		root,
		"Ground",
		Vector3.new(-e, GROUND_TOP - GROUND_THICKNESS, -e),
		Vector3.new(e, GROUND_TOP, e),
		COLOR_GROUND,
		Enum.Material.Concrete
	)
	ground.CanCollide = true
	root.PrimaryPart = ground

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(12, 1, 12)
	spawn.CFrame = CFrame.new(BaseLayout.SPAWN_POSITION)
	spawn.Color = COLOR_ORANGE
	spawn.Material = Enum.Material.Metal
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.Enabled = true
	spawn.Parent = root

	local site = siteGeometry()

	local plots = Instance.new("Folder")
	plots.Name = "Plots"
	plots.Parent = root
	for _, info in BaseLayout.Plots do
		buildPlot(plots, info)
	end

	buildLaunchArea(root, site)
	buildDecor(root, site)

	local count = countParts(root)
	local limit = math.min(PART_BUDGET, GameConfig.HOME_BASE_MAX_PARTS)
	if count > limit then
		error(`HomeBase has {count} parts, over the budget of {limit}`)
	end
	root:SetAttribute("PartCount", count)
	return root
end

return table.freeze(HomeBase)
