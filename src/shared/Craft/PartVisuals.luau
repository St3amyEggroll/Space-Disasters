--!strict
--[[
	PartVisuals
	Builds the look of every part type out of plain Roblox primitives (no meshes yet, so they can be swapped in later).

	CHANGED (Phase 1 rework, Plane Crazy-style): def.Size is in BLOCKS. A model's stud size is
	S = def.Size * GameConfig.GRID_SIZE (one block = GRID_SIZE studs); every proportion below is in studs of S.

	build(def, mode) returns a NEW Model in PART-LOCAL space:
	  - centred at the origin, unrotated, extents exactly +-S/2 (only Attachments may lie outside the box)
	  - local +Y is the part's "up": engines exhaust toward -Y, nose cones point +Y, pods/cabins stand on -Y
	  - local -Z is the "front" (pod window, cabin cockpit, pilot seat facing); +Z is the back / mounting face
	    (cabin doorway, fin root, leg and radial-decoupler mounts)
	  - PrimaryPart = "Bounds", an invisible Part of exactly S at the identity CFrame. Callers place the model
	    with Model:PivotTo, so every BasePart is positioned relative to Bounds.
	  - every BasePart is Anchored (DECISIONS S9: never weld unanchored craft parts, seats included)
	  - structural parts (block, beam, deck) are plain full boxes of their size

	Modes:
	  Real      the physical craft: Bounds is raycastable (CanQuery) for exact grid faces, character-facing surfaces
	            collide, seats are Seat instances (Disabled; the server sits players through SitPrompt), the cabin
	            hatch has Enter/Exit prompts.
	  Cosmetic  a look-only copy (builder ghosts, previews, client-side visuals): nothing collides, queries or
	            touches, everything is Massless, no ProximityPrompts and no Seat instances (plain Parts instead).

	Paint:
	  The main body surfaces (hulls, shells, walls, cones, fins, decoupler bodies, structural blocks, chute canopy)
	  carry the attribute Paint = true and their default colour in BaseColor (Color3). applyPaint(model, color)
	  recolours exactly those parts; applyPaint(model, nil) restores BaseColor. Glass, neon, engine metal, hazard
	  stripes, seats and ladder rungs are never painted.

	Attachments (both modes):
	  Bounds.Exhaust     engines/boosters, at (0, -S.Y/2, 0) rotated 180 degrees about X:
	                     UpVector (SecondaryAxis) = -Y, i.e. ParticleEmitter EmissionDirection Top blows downward;
	                     Axis (RightVector) = +X, LookVector = +Z.
	  Bounds.ChuteTop    parachute, at (0, +S.Y/2, 0), unrotated.
	  Bounds.Foot        landing leg, at (0, -S.Y/2, 0), unrotated.
	  Hatch.HatchOutside / Hatch.HatchInside   cabin; teleport targets for a HumanoidRootPart. Their LookVector
	                     faces the direction the character should face after the teleport (outward / inward).

	Pure module: only Instance.new, no services. Deterministic.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Parts = require(script.Parent.Parent.Config.Parts)

--============================================================================
-- Tunables
--============================================================================
local PALETTE = table.freeze({
	Hull = Color3.fromRGB(236, 236, 232), -- white hull panels
	Accent = Color3.fromRGB(230, 110, 30), -- orange: hatches, nose tips
	Stripe = Color3.fromRGB(40, 70, 150), -- tank / booster stripe rings
	Hazard = Color3.fromRGB(245, 200, 40), -- decoupler yellow
	Dark = Color3.fromRGB(35, 35, 40), -- heat shield, decoupler band, foot pads
	Metal = Color3.fromRGB(150, 155, 160), -- rails, mounts, structural blocks
	Cap = Color3.fromRGB(110, 115, 122), -- tank end caps
	Glass = Color3.fromRGB(30, 45, 70),
	Engine = Color3.fromRGB(60, 60, 66), -- engine mounts and bells
	Neon = Color3.fromRGB(255, 130, 30), -- glow inside engine exits
	Floor = Color3.fromRGB(95, 100, 108),
	Seat = Color3.fromRGB(45, 60, 90),
	Screen = Color3.fromRGB(80, 200, 255), -- cabin console display
	Chute = Color3.fromRGB(240, 120, 30), -- parachute canopy pack
})

local HULL_MATERIAL = Enum.Material.SmoothPlastic
local METAL_MATERIAL = Enum.Material.Metal
local FLOOR_MATERIAL = Enum.Material.DiamondPlate
local GLASS_MATERIAL = Enum.Material.Glass
local NEON_MATERIAL = Enum.Material.Neon
local FABRIC_MATERIAL = Enum.Material.Fabric

local PAINT_ATTRIBUTE = "Paint"
local BASE_COLOR_ATTRIBUTE = "BaseColor"

local GLASS_TRANSPARENCY = 0.5 -- cabin windows
local POD_WINDOW_TRANSPARENCY = 0.2 -- pod windows are dark glass

local SEAT_SIZE = Vector3.new(2, 1, 2)
local SEAT_PROMPT_DISTANCE = 8
local HATCH_PROMPT_DISTANCE = 6
local PROMPT_KEY = Enum.KeyCode.E

-- Fuel tanks and boosters
local HULL_INSET = 0.15 -- hull cylinders are this much narrower than caps/stripes so the rings stand proud
local TANK_CAP_HEIGHT = 0.3
local STRIPE_HEIGHT = 0.35
local TANK_TWO_STRIPE_HEIGHT = 8 -- tanks at least this tall (studs) get two stripe rings

-- Engines (fractions of S)
local ENGINE_MOUNT_HEIGHT = 0.28 -- of S.Y
local ENGINE_MOUNT_PLATE = 0.25 -- studs, lighter top plate of the mount
local ENGINE_MOUNT_DIAMETER = 0.85 -- of S.X (the plate is full width)
local ENGINE_THROAT_HEIGHT = 0.1 -- of S.Y
local ENGINE_THROAT_DIAMETER = 0.35 -- of S.X
local ENGINE_BELL_DIAMETERS = { 0.52, 0.72, 0.9 } -- of S.X, top to bottom
local ENGINE_GLOW_DIAMETER = 0.76 -- of S.X
local GLOW_HEIGHT = 0.06 -- studs

-- Solid booster
local SRB_NOZZLE_HEIGHT = 1.4
local SRB_NOZZLE_DIAMETER = 0.7 -- of S.X
local SRB_GLOW_DIAMETER = 0.58 -- of S.X
local SRB_NOSE_HEIGHT = 3
local SRB_STRIPE_DROP = 1 -- stripe centre below the nose section
local SRB_TIP_DIAMETER = 0.2 -- of S.X

-- Stacked decoupler: hull cylinder, hazard band (yellow rings around a dark separation groove) at mid-height
local DECOUPLER_HAZARD_HEIGHT = 0.45 -- each yellow ring
local DECOUPLER_GROOVE_HEIGHT = 0.3
local DECOUPLER_GROOVE_INSET = 0.4 -- groove diameter = S.X - inset

-- Radial decoupler: plate on +Z, arm through the block, clamp pad on -Z
local RADIAL_PLATE_SIZE = Vector3.new(3.2, 3.2, 0.4)
local RADIAL_PLATE_STRIPE = Vector3.new(3.4, 0.6, 0.5) -- hazard strip across the plate
local RADIAL_ARM_WIDTH = 1.2
local RADIAL_BAND_SIZE = Vector3.new(1.5, 1.5, 0.5) -- hazard band on the arm (the separation joint)
local RADIAL_PAD_SIZE = Vector3.new(2.4, 2.4, 0.3)

-- Adapter
local ADAPTER_SECTIONS = 5

-- Nose cones
local NOSE_TIP_DIAMETER = 0.18 -- of S.X

-- Fin (root on the +Z face, tip toward -Z, swept leading edge on top)
local FIN_THICKNESS = 0.4
local FIN_TIP_CHORD = 0.375 -- of S.Y
local FIN_ROOT_PLATE = Vector3.new(1.2, 0.9, 0.3) -- X, Y (fraction of S.Y), Z thickness

-- Command pod (4x4x4 studs at one block)
local POD_SHIELD_HEIGHT = 0.25
local POD_SECTIONS = { -- diameter and height as fractions of S.X / S.Y, bottom to top above the heat shield
	{ d = 1, h = 0.25 },
	{ d = 0.85, h = 0.22 },
	{ d = 0.7, h = 0.2 },
	{ d = 0.53, h = 0.15 },
}
local POD_WINDOW_SECTION = 3
local POD_TOP_HATCH_DIAMETER = 0.35 -- of S.X
local POD_WINDOW_SIZE = Vector3.new(1.4, 0.5, 0.2)
local POD_SEAT_SIZE = Vector3.new(2, 0.5, 2)

-- Crew cabin (8x8x8 studs at two blocks; 7x7x7 interior)
local CABIN_WALL_THICKNESS = 0.5
local CABIN_FLOOR_THICKNESS = 0.5
local CABIN_ROOF_THICKNESS = 0.5
local CABIN_WINDOW_WIDTH = 3
local CABIN_WINDOW_SILL = 2.5 -- above the floor top
local CABIN_WINDOW_HEIGHT = 3
local CABIN_GLASS_THICKNESS = 0.2
local CABIN_DOOR_WIDTH = 3
local CABIN_DOOR_HEIGHT = 6
local CABIN_HATCH_THICKNESS = 0.3
local CABIN_HATCH_ATTACH_OFFSET = 1.5 -- studs from the door centre to the Outside/Inside teleport targets
local CABIN_CONSOLE_SIZE = Vector3.new(3, 2.5, 1)
local CABIN_PILOT_GAP = 0.5 -- between the console and the pilot seat
local CABIN_BACKREST_THICKNESS = 0.3
local CABIN_SIDE_SEAT_Z = -1.5 -- side seats sit forward, beside the pilot, clear of the back corner seat
local CABIN_CORNER_SEAT_GAP = 0.25 -- corner seat distance from the back wall

-- Utility
local CHUTE_BASE_HEIGHT = 0.5
local LADDER_RAIL_WIDTH = 0.2
local LADDER_RUNG_THICKNESS = 0.2
local LADDER_RUNG_SPACING = 1 -- humanoids climb rung ladders with gaps up to ~1.5 studs
local LADDER_RUNG_STANDOFF = 0.7 -- studs between the mounting face and the rung centres
local LEG_MOUNT_HEIGHT = 0.8
local LEG_STRUT_DIAMETER = 0.6
local LEG_SHOCK_DIAMETER = 1
local LEG_SHOCK_HEIGHT = 2
local LEG_FOOT_HEIGHT = 0.3
local LEG_FOOT_DIAMETER = 0.9 -- of S.X
local LEG_BRACE_THICKNESS = 0.3
local EXT_SEAT_BASE = 0.3
local EXT_SEAT_SIZE = Vector3.new(2.4, 1, 2)
local EXT_SEAT_BACKREST = Vector3.new(2.4, 3, 0.3)

local MIN_EXTENT = 1e-3 -- wall segments thinner than this are skipped
--============================================================================

export type Mode = "Real" | "Cosmetic"

type Look = {
	Color: Color3,
	Material: Enum.Material,
	Transparency: number,
	Paint: boolean,
}

local function look(color: Color3, material: Enum.Material, transparency: number?, paint: boolean?): Look
	return table.freeze({
		Color = color,
		Material = material,
		Transparency = transparency or 0,
		Paint = paint == true,
	})
end

local LOOK = table.freeze({
	Hull = look(PALETTE.Hull, HULL_MATERIAL, 0, true),
	Structure = look(PALETTE.Metal, HULL_MATERIAL, 0, true),
	Chute = look(PALETTE.Chute, FABRIC_MATERIAL, 0, true),
	Accent = look(PALETTE.Accent, HULL_MATERIAL),
	Stripe = look(PALETTE.Stripe, HULL_MATERIAL),
	Hazard = look(PALETTE.Hazard, HULL_MATERIAL),
	Dark = look(PALETTE.Dark, HULL_MATERIAL),
	Metal = look(PALETTE.Metal, METAL_MATERIAL),
	Cap = look(PALETTE.Cap, METAL_MATERIAL),
	PodGlass = look(PALETTE.Glass, GLASS_MATERIAL, POD_WINDOW_TRANSPARENCY),
	CabinGlass = look(PALETTE.Glass, GLASS_MATERIAL, GLASS_TRANSPARENCY),
	Engine = look(PALETTE.Engine, METAL_MATERIAL),
	Neon = look(PALETTE.Neon, NEON_MATERIAL),
	Floor = look(PALETTE.Floor, FLOOR_MATERIAL),
	Seat = look(PALETTE.Seat, FABRIC_MATERIAL),
	Screen = look(PALETTE.Screen, NEON_MATERIAL),
})

-- One section of a stacked cone: diameter as a fraction of the base diameter, height as a fraction of the span.
type Layer = { d: number, h: number, look: Look? }

local NOSE_LAYERS: { Layer } = {
	{ d = 1, h = 0.1, look = LOOK.Metal },
	{ d = 0.94, h = 0.26 },
	{ d = 0.74, h = 0.24 },
	{ d = 0.52, h = 0.22 },
	{ d = 0.32, h = 0.18 },
}

local SRB_NOSE_LAYERS: { Layer } = {
	{ d = 0.85, h = 0.4 },
	{ d = 0.6, h = 0.35 },
	{ d = 0.35, h = 0.25 },
}

type Ctx = {
	def: Parts.PartDef,
	size: Vector3, -- studs
	real: boolean,
	model: Model,
	bounds: Part,
}

-- A rectangle on a wall: u runs along the wall, v is height (Y).
type Rect = { u0: number, u1: number, v0: number, v1: number }

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- turns a Cylinder's X axis onto +Y
local EXHAUST_ROTATION = CFrame.Angles(math.rad(180), 0, 0) -- UpVector -> -Y
local FACE_PLUS_X = CFrame.Angles(0, -math.pi / 2, 0) -- LookVector +X
local FACE_MINUS_X = CFrame.Angles(0, math.pi / 2, 0) -- LookVector -X
local FACE_PLUS_Z = CFrame.Angles(0, math.pi, 0) -- LookVector +Z

--============================================================================
-- Primitives
--============================================================================

-- Applies the look and the mode's physics flags, then parents the part to the model.
local function finish(ctx: Ctx, part: BasePart, name: string, style: Look, collide: boolean)
	part.Name = name
	part.Color = style.Color
	part.Material = style.Material
	part.Transparency = style.Transparency
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Anchored = true
	part.CanTouch = false
	part.CanQuery = false
	part.CanCollide = ctx.real and collide
	if not ctx.real then
		part.Massless = true
	end
	if style.Material == NEON_MATERIAL or style.Transparency > 0 then
		part.CastShadow = false
	end
	if style.Paint then
		part:SetAttribute(PAINT_ATTRIBUTE, true)
		part:SetAttribute(BASE_COLOR_ATTRIBUTE, style.Color)
	end
	part.Parent = ctx.model
end

local function box(ctx: Ctx, name: string, size: Vector3, cf: CFrame, style: Look, collide: boolean): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Block
	part.Size = size
	part.CFrame = cf
	finish(ctx, part, name, style, collide)
	return part
end

-- Vertical cylinder of diameter d on the Y axis, from y0 to y1.
local function cylinder(ctx: Ctx, name: string, d: number, y0: number, y1: number, style: Look, collide: boolean): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(y1 - y0, d, d)
	part.CFrame = CFrame.new(0, (y0 + y1) / 2, 0) * UPRIGHT
	finish(ctx, part, name, style, collide)
	return part
end

local function ball(ctx: Ctx, name: string, d: number, position: Vector3, style: Look, collide: boolean): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(d, d, d)
	part.CFrame = CFrame.new(position)
	finish(ctx, part, name, style, collide)
	return part
end

-- WedgePart: full-height face on +Z, slope descending toward -Z, flat bottom on -Y.
local function wedge(ctx: Ctx, name: string, size: Vector3, cf: CFrame, style: Look, collide: boolean): WedgePart
	local part = Instance.new("WedgePart")
	part.Size = size
	part.CFrame = cf
	finish(ctx, part, name, style, collide)
	return part
end

-- Stacked cylinders from y0 to y1; each layer's diameter is baseD * layer.d (the layer's widest point).
local function stack(ctx: Ctx, prefix: string, baseD: number, y0: number, y1: number, layers: { Layer }, style: Look)
	local span = y1 - y0
	local y = y0
	for i, layer in layers do
		local top = if i == #layers then y1 else y + layer.h * span
		cylinder(ctx, `{prefix}{i}`, baseD * layer.d, y, top, layer.look or style, true)
		y = top
	end
end

local function attachment(parent: Instance, name: string, cf: CFrame): Attachment
	local att = Instance.new("Attachment")
	att.Name = name
	att.CFrame = cf
	att.Parent = parent
	return att
end

local function prompt(parent: Instance, name: string, actionText: string, objectText: string, distance: number)
	local pp = Instance.new("ProximityPrompt")
	pp.Name = name
	pp.ActionText = actionText
	pp.ObjectText = objectText
	pp.HoldDuration = 0
	pp.MaxActivationDistance = distance
	pp.RequiresLineOfSight = false
	pp.KeyboardKeyCode = PROMPT_KEY
	pp.Parent = parent
end

-- A seat whose occupant faces cf.LookVector. Real: a Disabled Seat with a SitPrompt; Cosmetic: a plain Part.
local function seat(ctx: Ctx, index: number, size: Vector3, cf: CFrame): BasePart
	local isPilot = ctx.def.PilotSeat and index == 1
	local part: BasePart
	if ctx.real then
		local realSeat = Instance.new("Seat")
		realSeat.Disabled = true
		part = realSeat
	else
		part = Instance.new("Part")
	end
	part.Size = size
	part.CFrame = cf
	finish(ctx, part, if ctx.real then `Seat{index}` else `SeatVisual{index}`, LOOK.Seat, true)
	if ctx.real then
		-- CHANGED (Phase 1 review): keep the Seat touchable like the Seat spike S9 validated; Disabled already
		-- stops touch-sitting, and CrewService enables it only for the permitted Sit.
		part.CanTouch = true
	end
	part:SetAttribute("SeatIndex", index)
	part:SetAttribute("IsPilot", isPilot)
	if ctx.real then
		prompt(part, "SitPrompt", if isPilot then "Pilot" else "Sit", ctx.def.DisplayName, SEAT_PROMPT_DISTANCE)
	end
	return part
end

-- Axis-aligned wall slab: axis is the wall's normal; u runs along Z for an "X" wall and along X for a "Z" wall.
local function wallBox(ctx: Ctx, name: string, axis: "X" | "Z", offset: number, r: Rect, thickness: number, style: Look)
	local ul, vl = r.u1 - r.u0, r.v1 - r.v0
	if ul < MIN_EXTENT or vl < MIN_EXTENT then
		return
	end
	local uc, vc = (r.u0 + r.u1) / 2, (r.v0 + r.v1) / 2
	if axis == "X" then
		box(ctx, name, Vector3.new(thickness, vl, ul), CFrame.new(offset, vc, uc), style, true)
	else
		box(ctx, name, Vector3.new(ul, vl, thickness), CFrame.new(uc, vc, offset), style, true)
	end
end

-- A wall with a rectangular opening, built from up to 4 segments around it.
local function wallWithOpening(ctx: Ctx, prefix: string, axis: "X" | "Z", offset: number, wall: Rect, hole: Rect)
	local t = CABIN_WALL_THICKNESS
	local style = LOOK.Hull
	wallBox(ctx, prefix .. "Below", axis, offset, { u0 = wall.u0, u1 = wall.u1, v0 = wall.v0, v1 = hole.v0 }, t, style)
	wallBox(ctx, prefix .. "Above", axis, offset, { u0 = wall.u0, u1 = wall.u1, v0 = hole.v1, v1 = wall.v1 }, t, style)
	wallBox(ctx, prefix .. "Left", axis, offset, { u0 = wall.u0, u1 = hole.u0, v0 = hole.v0, v1 = hole.v1 }, t, style)
	wallBox(ctx, prefix .. "Right", axis, offset, { u0 = hole.u1, u1 = wall.u1, v0 = hole.v0, v1 = hole.v1 }, t, style)
end

local function windowWall(ctx: Ctx, prefix: string, axis: "X" | "Z", offset: number, wall: Rect, hole: Rect)
	wallWithOpening(ctx, prefix, axis, offset, wall, hole)
	wallBox(ctx, prefix .. "Window", axis, offset, hole, CABIN_GLASS_THICKNESS, LOOK.CabinGlass)
end

--============================================================================
-- Builders (S = ctx.size in studs; everything stays inside +-S/2)
--============================================================================

local function buildPod(ctx: Ctx)
	local S = ctx.size
	local hy = S.Y / 2
	-- Shell parts do not collide so the seated character sits inside the capsule.
	local y = -hy + POD_SHIELD_HEIGHT
	cylinder(ctx, "HeatShield", S.X * POD_SECTIONS[1].d, -hy, y, LOOK.Dark, false)
	local windowY, windowD = 0, S.X
	for i, section in POD_SECTIONS do
		local h = S.Y * section.h
		cylinder(ctx, `Shell{i}`, S.X * section.d, y, y + h, LOOK.Hull, false)
		if i == POD_WINDOW_SECTION then
			windowY, windowD = y + h / 2, S.X * section.d
		end
		y += h
	end
	cylinder(ctx, "TopHatch", S.X * POD_TOP_HATCH_DIAMETER, y, hy, LOOK.Accent, false)
	-- Front window (-Z) on the head-height section, sunk halfway into its front surface.
	local window = POD_WINDOW_SIZE
	box(ctx, "Window", window, CFrame.new(0, windowY, -windowD / 2 + window.Z / 4), LOOK.PodGlass, false)
	if ctx.def.Seats >= 1 then
		-- Bottom centre, facing -Z; a seated R15 (about 4 studs) keeps its head just inside the capsule.
		seat(ctx, 1, POD_SEAT_SIZE, CFrame.new(0, -hy + POD_SHIELD_HEIGHT + POD_SEAT_SIZE.Y / 2, 0))
	end
end

local function buildCabin(ctx: Ctx)
	local S = ctx.size
	local hx, hy, hz = S.X / 2, S.Y / 2, S.Z / 2
	local w = CABIN_WALL_THICKNESS
	local floorTop = -hy + CABIN_FLOOR_THICKNESS
	local roofBottom = hy - CABIN_ROOF_THICKNESS
	local ix, iz = hx - w, hz - w -- inner half extents

	box(
		ctx,
		"Floor",
		Vector3.new(S.X, CABIN_FLOOR_THICKNESS, S.Z),
		CFrame.new(0, (-hy + floorTop) / 2, 0),
		LOOK.Floor,
		true
	)
	box(
		ctx,
		"Roof",
		Vector3.new(S.X, CABIN_ROOF_THICKNESS, S.Z),
		CFrame.new(0, (roofBottom + hy) / 2, 0),
		LOOK.Hull,
		true
	)

	-- Side walls span the full depth; front and back walls fit between them.
	local winHalf = CABIN_WINDOW_WIDTH / 2
	local sill = floorTop + CABIN_WINDOW_SILL
	local window: Rect = { u0 = -winHalf, u1 = winHalf, v0 = sill, v1 = sill + CABIN_WINDOW_HEIGHT }
	local sideWall: Rect = { u0 = -hz, u1 = hz, v0 = floorTop, v1 = roofBottom }
	local endWall: Rect = { u0 = -ix, u1 = ix, v0 = floorTop, v1 = roofBottom }
	windowWall(ctx, "WallLeft", "X", -hx + w / 2, sideWall, window)
	windowWall(ctx, "WallRight", "X", hx - w / 2, sideWall, window)
	windowWall(ctx, "WallFront", "Z", -hz + w / 2, endWall, window)

	-- Back wall (+Z) with the doorway, closed by the Hatch.
	local doorHalf = CABIN_DOOR_WIDTH / 2
	local door: Rect = { u0 = -doorHalf, u1 = doorHalf, v0 = floorTop, v1 = floorTop + CABIN_DOOR_HEIGHT }
	local backZ = hz - w / 2
	wallWithOpening(ctx, "WallBack", "Z", backZ, endWall, door)
	local hatch = box(
		ctx,
		"Hatch",
		Vector3.new(CABIN_DOOR_WIDTH, CABIN_DOOR_HEIGHT, CABIN_HATCH_THICKNESS),
		CFrame.new(0, (door.v0 + door.v1) / 2, backZ),
		LOOK.Accent,
		true
	)
	-- Teleport targets at the door's centre height (about HumanoidRootPart height above the floor).
	local outside = attachment(hatch, "HatchOutside", CFrame.new(0, 0, CABIN_HATCH_ATTACH_OFFSET) * FACE_PLUS_Z)
	local inside = attachment(hatch, "HatchInside", CFrame.new(0, 0, -CABIN_HATCH_ATTACH_OFFSET))
	if ctx.real then
		prompt(outside, "EnterPrompt", "Enter", "Hatch", HATCH_PROMPT_DISTANCE)
		prompt(inside, "ExitPrompt", "Exit", "Hatch", HATCH_PROMPT_DISTANCE)
	end

	-- Console under the front window, pilot seat behind it.
	local console = CABIN_CONSOLE_SIZE
	local consoleZ = -iz + console.Z / 2
	box(ctx, "Console", console, CFrame.new(0, floorTop + console.Y / 2, consoleZ), LOOK.Metal, true)
	box(
		ctx,
		"Screen",
		Vector3.new(console.X - 1, 0.1, console.Z - 0.3),
		CFrame.new(0, floorTop + console.Y + 0.05, consoleZ),
		LOOK.Screen,
		false
	)

	-- Seats: pilot front centre, two side seats forward against the side walls, one in the back-left corner.
	-- The strip in front of the doorway (|x| <= door half width, back of the cabin) stays clear.
	local seatY = floorTop + SEAT_SIZE.Y / 2
	local pilotZ = -iz + console.Z + CABIN_PILOT_GAP + SEAT_SIZE.Z / 2
	local sideX = ix - SEAT_SIZE.X / 2
	local placements: { CFrame } = {
		CFrame.new(0, seatY, pilotZ), -- pilot, faces the front (-Z)
		CFrame.new(-sideX, seatY, CABIN_SIDE_SEAT_Z) * FACE_PLUS_X, -- left wall, faces in
		CFrame.new(sideX, seatY, CABIN_SIDE_SEAT_Z) * FACE_MINUS_X, -- right wall, faces in
		CFrame.new(-sideX, seatY, iz - SEAT_SIZE.Z / 2 - CABIN_CORNER_SEAT_GAP), -- back-left corner, faces front
	}
	for i = 1, math.min(ctx.def.Seats, #placements) do
		seat(ctx, i, SEAT_SIZE, placements[i])
	end
	if ctx.def.Seats >= 1 then
		local backrestZ = pilotZ + SEAT_SIZE.Z / 2 + CABIN_BACKREST_THICKNESS / 2
		box(
			ctx,
			"PilotBackrest",
			Vector3.new(SEAT_SIZE.X, 2, CABIN_BACKREST_THICKNESS),
			CFrame.new(0, floorTop + SEAT_SIZE.Y + 1, backrestZ),
			LOOK.Seat,
			true
		)
	end
end

local function buildTank(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	cylinder(ctx, "CapBottom", d, -hy, -hy + TANK_CAP_HEIGHT, LOOK.Cap, true)
	cylinder(ctx, "Hull", d - HULL_INSET, -hy + TANK_CAP_HEIGHT, hy - TANK_CAP_HEIGHT, LOOK.Hull, true)
	cylinder(ctx, "CapTop", d, hy - TANK_CAP_HEIGHT, hy, LOOK.Cap, true)
	local count = if S.Y >= TANK_TWO_STRIPE_HEIGHT then 2 else 1
	for i = 1, count do
		local y = -hy + S.Y * i / (count + 1)
		cylinder(ctx, `Stripe{i}`, d, y - STRIPE_HEIGHT / 2, y + STRIPE_HEIGHT / 2, LOOK.Stripe, true)
	end
end

local function addExhaust(ctx: Ctx)
	attachment(ctx.bounds, "Exhaust", CFrame.new(0, -ctx.size.Y / 2, 0) * EXHAUST_ROTATION)
end

local function buildEngine(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local mountBottom = hy - S.Y * ENGINE_MOUNT_HEIGHT
	cylinder(ctx, "MountPlate", d, hy - ENGINE_MOUNT_PLATE, hy, LOOK.Metal, true)
	cylinder(ctx, "Mount", d * ENGINE_MOUNT_DIAMETER, mountBottom, hy - ENGINE_MOUNT_PLATE, LOOK.Engine, true)
	local throatBottom = mountBottom - S.Y * ENGINE_THROAT_HEIGHT
	cylinder(ctx, "Throat", d * ENGINE_THROAT_DIAMETER, throatBottom, mountBottom, LOOK.Engine, true)
	-- Bell sections widen downward; the glow disc sits under the last one, inside its rim.
	local bellBottom = -hy + GLOW_HEIGHT
	local sections = #ENGINE_BELL_DIAMETERS
	local step = (throatBottom - bellBottom) / sections
	for i, fraction in ENGINE_BELL_DIAMETERS do
		local top = throatBottom - (i - 1) * step
		local bottom = if i == sections then bellBottom else top - step
		cylinder(ctx, `Bell{i}`, d * fraction, bottom, top, LOOK.Engine, true)
	end
	cylinder(ctx, "Glow", d * ENGINE_GLOW_DIAMETER, -hy, bellBottom, LOOK.Neon, false)
	addExhaust(ctx)
end

local function buildBooster(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local nozzleTop = -hy + SRB_NOZZLE_HEIGHT
	local noseBottom = hy - SRB_NOSE_HEIGHT
	cylinder(ctx, "Body", d - HULL_INSET, nozzleTop, noseBottom, LOOK.Hull, true)
	local stripeY = noseBottom - SRB_STRIPE_DROP
	cylinder(ctx, "Stripe", d, stripeY - STRIPE_HEIGHT / 2, stripeY + STRIPE_HEIGHT / 2, LOOK.Stripe, true)
	local tipD = d * SRB_TIP_DIAMETER
	stack(ctx, "Nose", d, noseBottom, hy - tipD / 2, SRB_NOSE_LAYERS, LOOK.Hull)
	ball(ctx, "Tip", tipD, Vector3.new(0, hy - tipD / 2, 0), LOOK.Accent, false)
	cylinder(ctx, "Nozzle", d * SRB_NOZZLE_DIAMETER, -hy + GLOW_HEIGHT, nozzleTop, LOOK.Engine, true)
	cylinder(ctx, "Glow", d * SRB_GLOW_DIAMETER, -hy, -hy + GLOW_HEIGHT, LOOK.Neon, false)
	addExhaust(ctx)
end

-- A hull-coloured cylinder with a hazard band (yellow rings around a dark separation groove) at mid-height.
local function buildDecoupler(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local g = DECOUPLER_GROOVE_HEIGHT / 2
	local bandTop = g + DECOUPLER_HAZARD_HEIGHT
	cylinder(ctx, "Upper", d - HULL_INSET, bandTop, hy, LOOK.Hull, true)
	cylinder(ctx, "HazardUpper", d, g, bandTop, LOOK.Hazard, true)
	cylinder(ctx, "Band", d - DECOUPLER_GROOVE_INSET, -g, g, LOOK.Dark, true)
	cylinder(ctx, "HazardLower", d, -bandTop, -g, LOOK.Hazard, true)
	cylinder(ctx, "Lower", d - HULL_INSET, -hy, -bandTop, LOOK.Hull, true)
end

-- Mounting plate on +Z (against the parent), an arm with a hazard band through the block, clamp pad on -Z.
local function buildRadialDecoupler(ctx: Ctx)
	local S = ctx.size
	local hz = S.Z / 2
	local plate = RADIAL_PLATE_SIZE
	local plateZ = hz - plate.Z / 2
	box(ctx, "MountPlate", plate, CFrame.new(0, 0, plateZ), LOOK.Hull, true)
	local stripe = RADIAL_PLATE_STRIPE
	box(ctx, "PlateStripe", stripe, CFrame.new(0, 0, hz - stripe.Z / 2), LOOK.Hazard, true)
	local pad = RADIAL_PAD_SIZE
	local padZ = -hz + pad.Z / 2
	box(ctx, "Pad", pad, CFrame.new(0, 0, padZ), LOOK.Hull, true)
	local armZ0, armZ1 = -hz + pad.Z, hz - plate.Z
	box(
		ctx,
		"Arm",
		Vector3.new(RADIAL_ARM_WIDTH, RADIAL_ARM_WIDTH, armZ1 - armZ0),
		CFrame.new(0, 0, (armZ0 + armZ1) / 2),
		LOOK.Metal,
		true
	)
	box(ctx, "Band", RADIAL_BAND_SIZE, CFrame.new(0, 0, (armZ0 + armZ1) / 2), LOOK.Hazard, true)
end

-- Tapers from the full diameter at the bottom to one block (the small stack size) at the top.
local function buildAdapter(ctx: Ctx)
	local S = ctx.size
	local d = math.min(S.X, S.Z)
	local topFraction = math.min(GameConfig.GRID_SIZE, d) / d
	local layers: { Layer } = {}
	for i = 1, ADAPTER_SECTIONS do
		local t = (i - 1) / (ADAPTER_SECTIONS - 1)
		local edge = i == 1 or i == ADAPTER_SECTIONS
		layers[i] = { d = 1 + (topFraction - 1) * t, h = 1 / ADAPTER_SECTIONS, look = if edge then LOOK.Metal else nil }
	end
	stack(ctx, "Section", d, -S.Y / 2, S.Y / 2, layers, LOOK.Hull)
end

local function buildNose(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local tipD = math.min(d * NOSE_TIP_DIAMETER, S.Y / 2)
	stack(ctx, "Cone", d, -hy, hy - tipD / 2, NOSE_LAYERS, LOOK.Hull)
	ball(ctx, "Tip", tipD, Vector3.new(0, hy - tipD / 2, 0), LOOK.Accent, false)
end

local function buildFin(ctx: Ctx)
	local S = ctx.size
	local hy, hz = S.Y / 2, S.Z / 2
	local t = math.min(FIN_THICKNESS, S.X)
	local tipChord = S.Y * FIN_TIP_CHORD
	local rootT = FIN_ROOT_PLATE.Z
	local z0, z1 = -hz, hz - rootT -- blade from the tip to the root plate
	local span, zc = z1 - z0, (z0 + z1) / 2
	box(ctx, "Blade", Vector3.new(t, tipChord, span), CFrame.new(0, -hy + tipChord / 2, zc), LOOK.Hull, true)
	local sweepH = S.Y - tipChord
	wedge(ctx, "Sweep", Vector3.new(t, sweepH, span), CFrame.new(0, -hy + tipChord + sweepH / 2, zc), LOOK.Hull, true)
	box(
		ctx,
		"RootPlate",
		Vector3.new(math.min(FIN_ROOT_PLATE.X, S.X), S.Y * FIN_ROOT_PLATE.Y, rootT),
		CFrame.new(0, 0, hz - rootT / 2),
		LOOK.Metal,
		true
	)
end

local function buildChute(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local baseTop = -hy + CHUTE_BASE_HEIGHT
	cylinder(ctx, "Base", d, -hy, baseTop, LOOK.Metal, true)
	local packTop = baseTop + (hy - baseTop) * 0.45
	cylinder(ctx, "Pack", d * 0.87, baseTop, packTop, LOOK.Chute, true)
	local capTop = packTop + (hy - baseTop) * 0.27
	cylinder(ctx, "Cap", d * 0.6, packTop, capTop, LOOK.Hull, true)
	local domeD = math.min(d * 0.4, (hy - packTop) * 2 - 0.2)
	ball(ctx, "Dome", domeD, Vector3.new(0, hy - domeD / 2, 0), LOOK.Chute, false)
	attachment(ctx.bounds, "ChuteTop", CFrame.new(0, hy, 0))
end

local function buildLeg(ctx: Ctx)
	local S = ctx.size
	local hy, hz = S.Y / 2, S.Z / 2
	local footTop = -hy + LEG_FOOT_HEIGHT
	local mountH = LEG_MOUNT_HEIGHT
	-- Mount block on the +Z (mounting) face at the top, reaching back to the strut.
	box(ctx, "Mount", Vector3.new(S.X * 0.6, mountH, hz), CFrame.new(0, hy - mountH / 2, hz / 2), LOOK.Metal, true)
	cylinder(ctx, "Strut", LEG_STRUT_DIAMETER, footTop, hy, LOOK.Metal, true)
	cylinder(ctx, "Shock", LEG_SHOCK_DIAMETER, footTop, footTop + LEG_SHOCK_HEIGHT, LOOK.Engine, true)
	-- Diagonal brace from the back of the mount down to the strut.
	local top = Vector3.new(0, hy - mountH, hz - 0.3)
	local bottom = Vector3.new(0, -hy * 0.3, 0)
	local delta = top - bottom
	local angle = math.atan2(delta.Z, delta.Y) -- rotation about X that tilts +Y toward +Z
	box(
		ctx,
		"Brace",
		Vector3.new(LEG_BRACE_THICKNESS, delta.Magnitude, LEG_BRACE_THICKNESS),
		CFrame.new((top + bottom) / 2) * CFrame.Angles(angle, 0, 0),
		LOOK.Metal,
		false
	)
	cylinder(ctx, "Foot", math.min(S.X, S.Z) * LEG_FOOT_DIAMETER, -hy, footTop, LOOK.Dark, true)
	attachment(ctx.bounds, "Foot", CFrame.new(0, -hy, 0))
end

local function buildLadder(ctx: Ctx)
	local S = ctx.size
	local hx, hy, hz = S.X / 2, S.Y / 2, S.Z / 2
	local railX = hx - LADDER_RAIL_WIDTH / 2
	-- CHANGED (Phase 1 rework): hug the +Z (mounting) face so the ladder sits against what it is attached to;
	-- the rungs stand a little off the face so hands and feet fit behind them.
	local railZ = hz - LADDER_RAIL_WIDTH / 2
	local rungZ = hz - LADDER_RUNG_STANDOFF
	local rail = Vector3.new(LADDER_RAIL_WIDTH, S.Y, LADDER_RAIL_WIDTH)
	box(ctx, "RailLeft", rail, CFrame.new(-railX, 0, railZ), LOOK.Metal, true)
	box(ctx, "RailRight", rail, CFrame.new(railX, 0, railZ), LOOK.Metal, true)
	-- Rungs every LADDER_RUNG_SPACING, offset half a spacing from the ends so stacked ladders keep the rhythm.
	local rungSize = Vector3.new(S.X - 2 * LADDER_RAIL_WIDTH, LADDER_RUNG_THICKNESS, LADDER_RUNG_THICKNESS)
	local count = math.floor(S.Y / LADDER_RUNG_SPACING + 0.5)
	for i = 1, count do
		local y = -hy + (i - 0.5) * LADDER_RUNG_SPACING
		box(ctx, `Rung{i}`, rungSize, CFrame.new(0, y, rungZ), LOOK.Metal, true)
	end
end

-- Base plate across the cell, seat on it, backrest on the +Z (mounting) side.
local function buildExternalSeat(ctx: Ctx)
	local S = ctx.size
	local hy, hz = S.Y / 2, S.Z / 2
	local baseTop = -hy + EXT_SEAT_BASE
	box(ctx, "Base", Vector3.new(S.X, EXT_SEAT_BASE, S.Z), CFrame.new(0, (-hy + baseTop) / 2, 0), LOOK.Metal, true)
	local back = EXT_SEAT_BACKREST
	local seatSize = EXT_SEAT_SIZE
	local seatZ = hz - back.Z - seatSize.Z / 2
	seat(ctx, 1, seatSize, CFrame.new(0, baseTop + seatSize.Y / 2, seatZ))
	box(ctx, "Backrest", back, CFrame.new(0, baseTop + back.Y / 2, hz - back.Z / 2), LOOK.Seat, true)
end

-- Plane Crazy-style building block: a plain full box of its size.
local function buildStructural(ctx: Ctx)
	box(ctx, "Block", ctx.size, CFrame.new(), LOOK.Structure, true)
end

-- Unknown / new part types: a plain hull block of the right size.
local function buildFallback(ctx: Ctx)
	box(ctx, "Block", ctx.size, CFrame.new(), LOOK.Hull, true)
end

local BUILDERS: { [string]: (Ctx) -> () } = {
	pod_mk1 = buildPod,
	cabin_l = buildCabin,
	tank_s_short = buildTank,
	tank_s_long = buildTank,
	tank_l_short = buildTank,
	tank_l_long = buildTank,
	engine_s = buildEngine,
	engine_l = buildEngine,
	srb_s = buildBooster,
	decoupler_s = buildDecoupler,
	decoupler_l = buildDecoupler,
	decoupler_r = buildRadialDecoupler,
	adapter_s_l = buildAdapter,
	nose_s = buildNose,
	nose_l = buildNose,
	fin = buildFin,
	chute_s = buildChute,
	leg = buildLeg,
	ladder = buildLadder,
	seat_ext = buildExternalSeat,
	block_1 = buildStructural,
	beam_4 = buildStructural,
	plate_4 = buildStructural,
}

--============================================================================
-- Public API
--============================================================================
local PartVisuals = {}

PartVisuals.PALETTE = PALETTE

-- Builds a new Model for the part in part-local space (see the header). The caller parents and pivots it.
function PartVisuals.build(def: Parts.PartDef, mode: Mode): Model
	local real = mode == "Real"
	local size = def.Size * GameConfig.GRID_SIZE
	local model = Instance.new("Model")
	model.Name = def.Id
	model:SetAttribute("PartId", def.Id)

	local bounds = Instance.new("Part")
	bounds.Name = "Bounds"
	bounds.Size = size
	bounds.CFrame = CFrame.identity
	bounds.Transparency = 1
	bounds.Anchored = true
	bounds.CanCollide = false
	bounds.CanTouch = false
	bounds.CanQuery = real
	bounds.CastShadow = false
	if not real then
		bounds.Massless = true
	end
	bounds.Parent = model
	model.PrimaryPart = bounds

	local ctx: Ctx = { def = def, size = size, real = real, model = model, bounds = bounds }
	local builder = BUILDERS[def.Id] or buildFallback
	builder(ctx)
	return model
end

-- Recolours every paintable part (Paint = true) of a built model; nil restores each part's BaseColor.
function PartVisuals.applyPaint(model: Model, color: Color3?)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant:GetAttribute(PAINT_ATTRIBUTE) == true then
			local target = color or descendant:GetAttribute(BASE_COLOR_ATTRIBUTE)
			if typeof(target) == "Color3" then
				descendant.Color = target
			end
		end
	end
end

return table.freeze(PartVisuals)
