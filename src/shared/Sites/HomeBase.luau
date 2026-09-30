--!strict
--[[
	HomeBase
	Builds the Oopsie Point Launch Complex: the home base site in base-pocket coordinates (= workspace
	coordinates, ground level y = 0). All plot, pad and spawn geometry comes from BaseLayout so the server and
	client code that uses BaseLayout matches what is drawn here exactly.

	HomeBase.build() returns a new, unparented Model named "HomeBase":
	  Ground            ground plate, top at y = 0
	  Spawn             SpawnLocation at BaseLayout.SPAWN_POSITION (top at y = 0.5)
	  Street            road strip along X through the middle
	  Plots/Plot_<i>    per plot (attribute PlotIndex):
	    BuildFloor      top face = the build grid floor (y = 0) over the build footprint
	    Hangar          frame around the build volume; street side and pad side open; never inside the volume
	    Pad             launch pad slab, top at y = PAD_HEIGHT (painted markings on top do not collide)
	    Sign            plot sign facing the street; SurfaceGui with TextLabel "Owner" (filled by the server)
	    PadPath         visual path from the hangar's pad-side edge to the pad
	  Decor             lamps, fuel tanks, the entrance arch and the control building
	Model attribute PartCount = number of BaseParts. Everything is anchored; no scripts. Deterministic, so
	clients in other pockets can build the identical site as part of the planet surface.
]]

local BaseLayout = require(script.Parent.Parent.Config.BaseLayout)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)

type PlotInfo = BaseLayout.PlotInfo

--============================================================================
-- Tunables
--============================================================================
local PART_BUDGET = 1300 -- soft budget; GameConfig.HOME_BASE_MAX_PARTS is the hard cap
local GROUND_THICKNESS = 20
local FLOOR_THICKNESS = 0.4
local FLOOR_BORDER_WIDTH = 0.8 -- painted strips just outside the build footprint
local STREET_HALF_WIDTH = 12
local STREET_HALF_LENGTH = 410
local STREET_TOP = 0.05
local APRON_TOP = 0.03 -- concrete apron from the street to each hangar
local MARKING_TOP = 0.08 -- painted lines on the street and pad paths
local BORDER_TOP = 0.06
local PATH_TOP = 0.05
local PATH_WIDTH = 24
local HANGAR_HEIGHT = 124 -- pillar tops; the build volume is 120 tall
local PILLAR_SIZE = 2
local WALL_THICKNESS = 0.5
local WALL_GAP = 0.9 -- clearance between the build footprint and the wall panel
local GIRT_THICKNESS = 0.8
local PAD_MARK_THICKNESS = 0.04
local PAD_RING_RADIUS = 16
local PAD_RING_SEGMENTS = 12
local PAD_RING_WIDTH = 1.2
local PAD_TOWER_OFFSET = 6 -- studs from the pad edge to the tower centre
local PAD_TOWER_HEIGHT = 40
local SIGN_SIZE = Vector3.new(10, 5, 0.4)
local SIGN_STREET_OFFSET = 4 -- studs from the hangar's street-side edge toward the street
local SIGN_SIDE_OFFSET = 6 -- studs beyond the hangar's +X edge
local SIGN_BOTTOM = 5.5
local LAMP_XS = { -300, -200, -100, 100, 200, 300 }
local LAMP_HEIGHT = 16
local ARCH_HEIGHT = 26 -- underside of the arch beam
local ARCH_BEAM = Vector3.new(3, 7, 42)
local TANK_DIAMETER = 12
local TANK_HEIGHT = 24
local TANK_SITES = {
	Vector3.new(345, 0, 40),
	Vector3.new(375, 0, 60),
	Vector3.new(345, 0, 80),
	Vector3.new(-345, 0, -40),
	Vector3.new(-375, 0, -60),
	Vector3.new(-345, 0, -80),
}
local CONTROL_MIN = Vector3.new(-18, 0, 30) -- control building footprint (between the middle plot columns)
local CONTROL_MAX = Vector3.new(18, 12, 52)

local COLOR_GROUND = Color3.fromRGB(99, 102, 107)
local COLOR_ORANGE = Color3.fromRGB(255, 140, 26)
local COLOR_WHITE = Color3.fromRGB(242, 242, 236)
local COLOR_METAL = Color3.fromRGB(163, 168, 174)
local COLOR_DARK = Color3.fromRGB(52, 55, 61)
local COLOR_ASPHALT = Color3.fromRGB(58, 60, 66)
local COLOR_APRON = Color3.fromRGB(128, 131, 136)
local COLOR_PAD = Color3.fromRGB(176, 178, 180)
local COLOR_GLASS = Color3.fromRGB(190, 222, 240)
local COLOR_YELLOW = Color3.fromRGB(255, 205, 60)
local COLOR_LAMP = Color3.fromRGB(255, 236, 190)

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

-- Purely visual part: no collision, queries or touches.
local function decal(p: Part): Part
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

-- Vertical cylinder standing on `baseY` (Roblox cylinders run along their local X axis).
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

--============================================================================
-- Plots
--============================================================================

local function buildFloor(model: Model, info: PlotInfo)
	local o = info.buildOrigin
	local s = info.buildSize
	-- Same look as the ground so the coplanar top faces cannot visibly z-fight; the border strips mark it.
	local floor = box(
		model,
		"BuildFloor",
		Vector3.new(o.X, -FLOOR_THICKNESS, o.Z),
		Vector3.new(o.X + s.X, 0, o.Z + s.Z),
		COLOR_GROUND,
		Enum.Material.Concrete
	)
	floor.CanCollide = true
	floor.CanQuery = true

	-- Painted border just outside the footprint (never inside the build volume).
	local w = FLOOR_BORDER_WIDTH
	local bottom = BORDER_TOP - 0.1
	local strips = {
		{ Vector3.new(o.X - w, bottom, o.Z - w), Vector3.new(o.X, BORDER_TOP, o.Z + s.Z + w) },
		{ Vector3.new(o.X + s.X, bottom, o.Z - w), Vector3.new(o.X + s.X + w, BORDER_TOP, o.Z + s.Z + w) },
		{ Vector3.new(o.X, bottom, o.Z - w), Vector3.new(o.X + s.X, BORDER_TOP, o.Z) },
		{ Vector3.new(o.X, bottom, o.Z + s.Z), Vector3.new(o.X + s.X, BORDER_TOP, o.Z + s.Z + w) },
	}
	for _, strip in strips do
		decal(box(model, "FloorBorder", strip[1], strip[2], COLOR_YELLOW, Enum.Material.SmoothPlastic))
	end
end

local function buildHangarWall(hangar: Model, info: PlotInfo, side: number)
	-- side = -1: wall at x = origin.X (outside, toward -X); side = 1: wall at x = origin.X + size.X
	local o = info.buildOrigin
	local s = info.buildSize
	local edgeX = if side < 0 then o.X else o.X + s.X
	local panelX = edgeX + side * (WALL_GAP + WALL_THICKNESS / 2)
	local frameX = edgeX + side * (WALL_GAP + WALL_THICKNESS + GIRT_THICKNESS / 2)
	local midZ = o.Z + s.Z / 2
	local wallHeight = HANGAR_HEIGHT - PILLAR_SIZE

	local panel = part(
		hangar,
		"WallPanel",
		Vector3.new(WALL_THICKNESS, wallHeight, s.Z),
		CFrame.new(panelX, wallHeight / 2, midZ),
		COLOR_GLASS,
		Enum.Material.SmoothPlastic
	)
	panel.Transparency = 0.55
	panel.CastShadow = false

	-- Horizontal girts (orange stripes) every 30 studs.
	for level = 1, 3 do
		part(
			hangar,
			"Girt",
			Vector3.new(GIRT_THICKNESS, 1.5, s.Z),
			CFrame.new(frameX, level * 30, midZ),
			if level == 2 then COLOR_ORANGE else COLOR_WHITE,
			Enum.Material.Metal
		)
	end

	-- X brace across the lowest 30-stud bay (rotations about X keep the x extent unchanged).
	local bayHeight = 30
	local length = math.sqrt(s.Z * s.Z + bayHeight * bayHeight)
	local angle = math.atan2(bayHeight, s.Z)
	for _, sign in { 1, -1 } do
		part(
			hangar,
			"Brace",
			Vector3.new(GIRT_THICKNESS, 1, length),
			CFrame.new(frameX, bayHeight / 2, midZ) * CFrame.Angles(sign * angle, 0, 0),
			COLOR_METAL,
			Enum.Material.Metal
		)
	end
end

local function buildHangar(model: Model, info: PlotInfo)
	local hangar = Instance.new("Model")
	hangar.Name = "Hangar"
	hangar.Parent = model

	local o = info.buildOrigin
	local s = info.buildSize
	local p = PILLAR_SIZE
	local streetIsMaxZ = info.facingStreet.Z > 0

	-- Corner pillars, fully outside the footprint.
	for _, x in { o.X - p, o.X + s.X } do
		for _, z in { o.Z - p, o.Z + s.Z } do
			box(
				hangar,
				"Pillar",
				Vector3.new(x, 0, z),
				Vector3.new(x + p, HANGAR_HEIGHT, z + p),
				COLOR_WHITE,
				Enum.Material.Metal
			)
		end
	end

	buildHangarWall(hangar, info, -1)
	buildHangarWall(hangar, info, 1)

	-- Roof frame: edge beams on top of the pillars, cross beams just above the 120-stud volume.
	local beamBottom = HANGAR_HEIGHT - p
	local xMin, xMax = o.X - p, o.X + s.X + p
	local zMin, zMax = o.Z - p, o.Z + s.Z + p
	box(
		hangar,
		"RoofBeam",
		Vector3.new(xMin, beamBottom, o.Z),
		Vector3.new(o.X, HANGAR_HEIGHT, o.Z + s.Z),
		COLOR_WHITE,
		Enum.Material.Metal
	)
	box(
		hangar,
		"RoofBeam",
		Vector3.new(o.X + s.X, beamBottom, o.Z),
		Vector3.new(xMax, HANGAR_HEIGHT, o.Z + s.Z),
		COLOR_WHITE,
		Enum.Material.Metal
	)
	-- Street-side header in orange (the entrance), pad-side header in white.
	box(
		hangar,
		"RoofBeam",
		Vector3.new(xMin, beamBottom, zMin),
		Vector3.new(xMax, HANGAR_HEIGHT, o.Z),
		if streetIsMaxZ then COLOR_WHITE else COLOR_ORANGE,
		Enum.Material.Metal
	)
	box(
		hangar,
		"RoofBeam",
		Vector3.new(xMin, beamBottom, o.Z + s.Z),
		Vector3.new(xMax, HANGAR_HEIGHT, zMax),
		if streetIsMaxZ then COLOR_ORANGE else COLOR_WHITE,
		Enum.Material.Metal
	)
	local crossBottom = s.Y + 1
	for i = 1, 3 do
		local z = o.Z + i * s.Z / 4
		box(
			hangar,
			"RoofTruss",
			Vector3.new(o.X, crossBottom, z - 0.75),
			Vector3.new(o.X + s.X, crossBottom + 1.5, z + 0.75),
			COLOR_METAL,
			Enum.Material.Metal
		)
	end
	local roof = box(
		hangar,
		"RoofPanel",
		Vector3.new(xMin, HANGAR_HEIGHT, zMin),
		Vector3.new(xMax, HANGAR_HEIGHT + 0.4, zMax),
		COLOR_GLASS,
		Enum.Material.SmoothPlastic
	)
	roof.Transparency = 0.6
	roof.CastShadow = false
end

local function buildPad(model: Model, info: PlotInfo)
	local size = info.padSize
	local h = BaseLayout.PAD_HEIGHT
	local top = info.padTop
	local center = top.Position - Vector3.new(0, h / 2, 0)

	local pad = part(model, "Pad", Vector3.new(size, h, size), CFrame.new(center), COLOR_PAD, Enum.Material.Concrete)
	pad.CanCollide = true
	pad.CanQuery = true

	-- Painted ring and cross lying on the top face (visual only; rockets rest on the slab).
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
	local crossLength = 2 * (PAD_RING_RADIUS - PAD_RING_WIDTH)
	for _, angle in { 0, math.pi / 2 } do
		decal(
			part(
				model,
				"PadCross",
				Vector3.new(crossLength, PAD_MARK_THICKNESS, PAD_RING_WIDTH),
				top * CFrame.Angles(0, angle, 0) * CFrame.new(0, markY, 0),
				COLOR_WHITE,
				Enum.Material.SmoothPlastic
			)
		)
	end

	-- Little launch tower beside the pad (+X side, outside the pad footprint).
	local towerX = top.X + size / 2 + PAD_TOWER_OFFSET
	local towerZ = top.Z
	box(
		model,
		"TowerBase",
		Vector3.new(towerX - 3, 0, towerZ - 3),
		Vector3.new(towerX + 3, 1, towerZ + 3),
		COLOR_DARK,
		Enum.Material.Concrete
	)
	box(
		model,
		"TowerColumn",
		Vector3.new(towerX - 1.5, 1, towerZ - 1.5),
		Vector3.new(towerX + 1.5, PAD_TOWER_HEIGHT, towerZ + 1.5),
		COLOR_ORANGE,
		Enum.Material.Metal
	)
	box(
		model,
		"TowerArm",
		Vector3.new(towerX - 4.5, PAD_TOWER_HEIGHT - 8, towerZ - 0.5),
		Vector3.new(towerX - 1.5, PAD_TOWER_HEIGHT - 7, towerZ + 0.5),
		COLOR_WHITE,
		Enum.Material.Metal
	)
	local beacon = part(
		model,
		"TowerBeacon",
		Vector3.new(1.6, 1.6, 1.6),
		CFrame.new(towerX, PAD_TOWER_HEIGHT + 0.8, towerZ),
		Color3.fromRGB(255, 70, 50),
		Enum.Material.Neon
	)
	beacon.Shape = Enum.PartType.Ball
end

local function buildSign(model: Model, info: PlotInfo)
	local o = info.buildOrigin
	local s = info.buildSize
	local f = info.facingStreet.Z
	local streetEdgeZ = if f > 0 then o.Z + s.Z else o.Z
	local z = streetEdgeZ + f * SIGN_STREET_OFFSET
	local x = o.X + s.X + SIGN_SIDE_OFFSET
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
			Vector3.new(x + dx - 0.2, 0, postZ - 0.2),
			Vector3.new(x + dx + 0.2, signTop, postZ + 0.2),
			COLOR_METAL,
			Enum.Material.Metal
		)
	end
end

local function buildPaths(model: Model, info: PlotInfo)
	local o = info.buildOrigin
	local s = info.buildSize
	local f = info.facingStreet.Z
	local cx = o.X + s.X / 2

	-- Pad path: hangar's pad-side edge -> pad's near edge.
	local padSideZ = if f > 0 then o.Z else o.Z + s.Z
	local padNearZ = info.padTop.Z + f * info.padSize / 2
	local zLo, zHi = math.min(padSideZ, padNearZ), math.max(padSideZ, padNearZ)
	local half = PATH_WIDTH / 2
	decal(
		box(
			model,
			"PadPath",
			Vector3.new(cx - half, PATH_TOP - 0.1, zLo),
			Vector3.new(cx + half, PATH_TOP, zHi),
			COLOR_APRON,
			Enum.Material.Concrete
		)
	)
	for _, edgeX in { cx - half, cx + half - 0.6 } do
		decal(
			box(
				model,
				"PathStripe",
				Vector3.new(edgeX, MARKING_TOP - 0.1, zLo),
				Vector3.new(edgeX + 0.6, MARKING_TOP, zHi),
				COLOR_ORANGE,
				Enum.Material.SmoothPlastic
			)
		)
	end

	-- Apron: street edge -> hangar's street-side edge.
	local streetSideZ = if f > 0 then o.Z + s.Z else o.Z
	local roadEdgeZ = -f * STREET_HALF_WIDTH
	decal(
		box(
			model,
			"Apron",
			Vector3.new(o.X - PILLAR_SIZE, APRON_TOP - 0.2, math.min(streetSideZ, roadEdgeZ)),
			Vector3.new(o.X + s.X + PILLAR_SIZE, APRON_TOP, math.max(streetSideZ, roadEdgeZ)),
			COLOR_APRON,
			Enum.Material.Concrete
		)
	)
end

local function buildPlot(parent: Instance, info: PlotInfo)
	local model = Instance.new("Model")
	model.Name = `Plot_{info.index}`
	model:SetAttribute("PlotIndex", info.index)
	buildFloor(model, info)
	buildHangar(model, info)
	buildPad(model, info)
	buildSign(model, info)
	buildPaths(model, info)
	model.Parent = parent
end

--============================================================================
-- Site
--============================================================================

local function buildStreet(root: Model, decor: Folder)
	local l = STREET_HALF_LENGTH
	local w = STREET_HALF_WIDTH
	decal(
		box(
			root,
			"Street",
			Vector3.new(-l, STREET_TOP - 1, -w),
			Vector3.new(l, STREET_TOP, w),
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

local function buildLamp(decor: Folder, x: number, z: number, armDirection: number)
	local lamp = Instance.new("Model")
	lamp.Name = "LampPost"
	lamp.Parent = decor
	box(
		lamp,
		"Pole",
		Vector3.new(x - 0.4, 0, z - 0.4),
		Vector3.new(x + 0.4, LAMP_HEIGHT, z + 0.4),
		COLOR_DARK,
		Enum.Material.Metal
	)
	local armEnd = z + armDirection * 4
	box(
		lamp,
		"Arm",
		Vector3.new(x - 0.3, LAMP_HEIGHT - 0.6, math.min(z, armEnd)),
		Vector3.new(x + 0.3, LAMP_HEIGHT, math.max(z, armEnd)),
		COLOR_DARK,
		Enum.Material.Metal
	)
	local head = decal(
		part(
			lamp,
			"Light",
			Vector3.new(1.6, 0.6, 2.4),
			CFrame.new(x, LAMP_HEIGHT - 0.9, armEnd),
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

local function buildArch(decor: Folder)
	local arch = Instance.new("Model")
	arch.Name = "EntranceArch"
	arch.Parent = decor
	local x = BaseLayout.SPAWN_POSITION.X
	local halfSpan = ARCH_BEAM.Z / 2
	for _, zSign in { -1, 1 } do
		local z = zSign * (halfSpan - 1.5)
		box(
			arch,
			"ArchPillar",
			Vector3.new(x - 1.5, 0, z - 1.5),
			Vector3.new(x + 1.5, ARCH_HEIGHT, z + 1.5),
			COLOR_WHITE,
			Enum.Material.Metal
		)
	end
	local beam = part(
		arch,
		"ArchSign",
		ARCH_BEAM,
		CFrame.new(x, ARCH_HEIGHT + ARCH_BEAM.Y / 2, 0),
		COLOR_ORANGE,
		Enum.Material.SmoothPlastic
	)
	for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
		local gui = surfaceGui(beam, `ArchGui{face.Name}`, face)
		label(gui, "Title", GameConfig.BASE_SITE_NAME, 0.12, 0.76, COLOR_WHITE)
	end
	box(
		arch,
		"ArchTrim",
		Vector3.new(x - 1.7, ARCH_HEIGHT + ARCH_BEAM.Y, -halfSpan - 0.2),
		Vector3.new(x + 1.7, ARCH_HEIGHT + ARCH_BEAM.Y + 0.8, halfSpan + 0.2),
		COLOR_WHITE,
		Enum.Material.SmoothPlastic
	)
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
	local dome = part(
		tank,
		"Dome",
		Vector3.new(TANK_DIAMETER, TANK_DIAMETER, TANK_DIAMETER),
		CFrame.new(site + Vector3.new(0, TANK_HEIGHT, 0)),
		COLOR_WHITE,
		Enum.Material.Metal
	)
	dome.Shape = Enum.PartType.Ball
end

local function buildControlBuilding(decor: Folder)
	local building = Instance.new("Model")
	building.Name = "ControlBuilding"
	building.Parent = decor
	local lo, hi = CONTROL_MIN, CONTROL_MAX
	-- Faces the street (-Z side, since the building sits north of it).
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
		Vector3.new(-2.5, 0, lo.Z - 0.2),
		Vector3.new(2.5, 4.5, lo.Z),
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
		Vector3.new(-12, 9.5, lo.Z - 0.3),
		Vector3.new(12, 11.5, lo.Z),
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
		Vector3.new(-e, -GROUND_THICKNESS, -e),
		Vector3.new(e, 0, e),
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

	local plots = Instance.new("Folder")
	plots.Name = "Plots"
	plots.Parent = root
	for _, info in BaseLayout.Plots do
		buildPlot(plots, info)
	end

	local decor = Instance.new("Folder")
	decor.Name = "Decor"
	decor.Parent = root
	buildStreet(root, decor)
	for _, x in LAMP_XS do
		buildLamp(decor, x, -(STREET_HALF_WIDTH + 2), 1)
		buildLamp(decor, x, STREET_HALF_WIDTH + 2, -1)
	end
	buildArch(decor)
	for _, site in TANK_SITES do
		buildFuelTank(decor, site)
	end
	buildControlBuilding(decor)

	local count = countParts(root)
	local limit = math.min(PART_BUDGET, GameConfig.HOME_BASE_MAX_PARTS)
	if count > limit then
		error(`HomeBase has {count} parts, over the budget of {limit}`)
	end
	root:SetAttribute("PartCount", count)
	return root
end

return table.freeze(HomeBase)
