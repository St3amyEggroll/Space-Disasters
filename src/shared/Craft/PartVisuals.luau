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

local SEAT_PROMPT_DISTANCE = 8
local PROMPT_KEY = Enum.KeyCode.E
local PILOT_SEAT_ACTION = "Pilot" -- CHANGED (Boarding): named, shared with the client's boarding prompts
local SEAT_ACTION = "Sit"

-- Fuel tanks and boosters
local HULL_INSET = 0.15 -- hull cylinders are this much narrower than caps/stripes so the rings stand proud
local TANK_CAP_HEIGHT = 0.3
local STRIPE_HEIGHT = 0.35
local TANK_TWO_STRIPE_HEIGHT = 8 -- tanks at least this tall (studs) get two stripe rings

-- CHANGED (Phase 2a remodel): faceted shells. Cones and bells are exact n-sided frusta (a centre plate plus two
-- right-triangle wedges per side, so sides meet edge to edge) instead of stacked cylinders.
local FACET_THICKNESS = 0.12 -- studs

-- Engines (diameters / radii as fractions of the part diameter d, heights as fractions of S.Y below the top)
local ENGINE_PLATE_DIAMETER = 0.97 -- dark mounting plate (the mating face)
local ENGINE_PLATE_HEIGHT = 0.05
local ENGINE_STRUT_TOP_RADIUS = 0.33 -- thrust frame: four struts from the plate to the chamber
local ENGINE_STRUT_BOTTOM_RADIUS = 0.13
local ENGINE_STRUT_DIAMETER = 0.05
local ENGINE_CHAMBER_DIAMETER = 0.3
local ENGINE_CHAMBER_TOP = 0.15
local ENGINE_CHAMBER_BOTTOM = 0.36
local ENGINE_CHAMBER_BAND = 0.05 -- dark band around the middle of the chamber
local ENGINE_PUMP_DIAMETER = 0.13 -- turbopump beside the chamber (+X)
local ENGINE_PUMP_OFFSET = 0.27
local ENGINE_PUMP_TOP = 0.08
local ENGINE_PUMP_BOTTOM = 0.3
local ENGINE_PIPE_DIAMETER = 0.05
local ENGINE_ACTUATOR_DIAMETER = 0.045 -- two gimbal actuators from the plate to the top of the bell
local ENGINE_ACTUATOR_TOP_RADIUS = 0.3
local ENGINE_THROAT_DIAMETER = 0.2
local ENGINE_THROAT_BOTTOM = 0.42
local ENGINE_NECK = { { d = 0.26, h = 0.04 }, { d = 0.33, h = 0.05 } } -- flare from the throat into the bell
local ENGINE_BELL_FACETS = 10
local ENGINE_BELL_TOP_APOTHEM = 0.165
local ENGINE_BELL_EXIT_APOTHEM = 0.465
local ENGINE_GLOW_DIAMETER = 0.2
local GLOW_HEIGHT = 0.06 -- studs
local BOTTOM_CLEARANCE = 0.1 -- studs between a bell exit and the bottom face of the cell (room for the tilted plates)

-- Solid booster (flat top: put a nose cone on it as a separate part). Studs unless noted.
local SRB_COLLAR_HEIGHT = 0.25 -- dark mating collar on top
local SRB_BODY_INSET = 0.3 -- body diameter = d - inset (leaves room for the lugs)
local SRB_JOINT_HEIGHT = 0.2 -- dark segment joints
local SRB_JOINTS = 3
local SRB_BAND_HEIGHT = 0.45 -- safety orange band near the top
local SRB_BAND_DROP = 1.1 -- band centre below the top
local SRB_ROLL_PANEL = Vector3.new(0.9, 2.4, 0.08) -- dark roll-pattern panels near the top, on +X and -X
local SRB_LUG_SIZE = Vector3.new(0.9, 0.55, 0.25) -- attach lugs on the +Z face, half sunk into the body
local SRB_LUG_DROP = 2 -- lug centres this far from each end
local SRB_AFT_RING_HEIGHT = 0.3
local SRB_NOZZLE_HEIGHT = 1.15
local SRB_NOZZLE_FACETS = 8
local SRB_NOZZLE_TOP_APOTHEM = 0.17 -- of d
local SRB_NOZZLE_EXIT_APOTHEM = 0.34 -- of d
local SRB_GLOW_DIAMETER = 0.22 -- of d

-- Stacked decoupler: dark collars, a hazard band (yellow with black slashes) under a dark separation groove with a
-- ring of explosive bolts. Studs unless noted.
local DECOUPLER_COLLAR_HEIGHT = 0.18
local DECOUPLER_BODY_INSET = 0.12
local DECOUPLER_BAND_BOTTOM = -0.8
local DECOUPLER_BAND_TOP = 0.12
local DECOUPLER_GROOVE_HEIGHT = 0.24
local DECOUPLER_GROOVE_INSET = 0.3
local DECOUPLER_SLASH_SIZE = Vector3.new(0.28, 0.95, 0.06)
local DECOUPLER_SLASH_SPACING = 1.5 -- studs of circumference per slash
local DECOUPLER_BOLT_DIAMETER = 0.26
local DECOUPLER_BOLT_SPACING = 1.5 -- studs of circumference per bolt

-- Radial decoupler: hull plate on +Z with bolts, a piston with a hazard collar through the block, four struts, and
-- a dark clamp pad on -Z. Studs.
local RADIAL_PLATE_SIZE = Vector3.new(3, 3, 0.35)
local RADIAL_BOLT_INSET = 0.4
local RADIAL_BOLT_DIAMETER = 0.3
local RADIAL_PISTON_DIAMETER = 1
local RADIAL_COLLAR_DIAMETER = 1.4
local RADIAL_COLLAR_LENGTH = 0.6
local RADIAL_SEAM_LENGTH = 0.14
local RADIAL_STRUT_DIAMETER = 0.28
local RADIAL_STRUT_PLATE = 1.05 -- strut ends on the plate (x, y offsets)
local RADIAL_STRUT_PAD = 0.75 -- strut ends on the pad
local RADIAL_PAD_SIZE = Vector3.new(2.6, 2.6, 0.3)

-- Size adapter
local ADAPTER_FACETS = 12
local ADAPTER_COLLAR_HEIGHT = 0.18 -- studs

-- Nose cones: an ogive of two faceted bands on a dark collar, with an orange tip
local NOSE_FACETS = 8
local NOSE_COLLAR_HEIGHT = 0.045 -- of S.Y
local NOSE_PROFILE = { -- height above the bottom (fraction of S.Y), side apothem (fraction of d)
	{ y = 0.045, a = 0.46 },
	{ y = 0.46, a = 0.32 },
	{ y = 0.9, a = 0.055 },
}
local NOSE_TIP_CAP_DIAMETER = 0.13 -- of d, covers the top opening
local NOSE_TIP_CAP_TOP = 0.93 -- of S.Y
local NOSE_TIP_DIAMETER = 0.12 -- of d

-- Fin (root on the +Z face, tip toward -Z, swept leading edge on top)
local FIN_THICKNESS = 0.4
local FIN_TIP_CHORD = 0.375 -- of S.Y
local FIN_ROOT_PLATE = Vector3.new(1.2, 0.9, 0.3) -- X, Y (fraction of S.Y), Z thickness

-- Command pod (4x4x4 studs at one block). CHANGED (Phase 2a remodel): a simple octagonal capsule on a heat
-- shield, one framed window on the front, a docking ring and an orange hatch on top.
local POD_FACETS = 8
local POD_SHIELD_DIAMETER = 0.975 -- of d
local POD_SHIELD_HEIGHT = 0.32 -- studs
local POD_BASE_APOTHEM = 0.45 -- of d
local POD_TOP_APOTHEM = 0.235 -- of d
local POD_SHELL_TOP = 0.32 -- of S.Y above the centre
local POD_RING_DIAMETER = 0.53 -- of d (covers the octagon's top opening)
local POD_RING_HEIGHT = 0.2 -- studs
local POD_HATCH_DIAMETER = 0.34 -- of d
local POD_HATCH_HEIGHT = 0.15 -- studs
local POD_WINDOW_SIZE = Vector2.new(0.75, 0.5) -- studs
local POD_WINDOW_AT = 0.5 -- fraction up the front side
local POD_WINDOW_FRAME = 0.08 -- studs of dark frame around the glass
local POD_SEAT_SIZE = Vector3.new(2, 0.5, 2)

-- Utility
local CHUTE_BASE_HEIGHT = 0.5
-- Landing leg (4x8x4 studs, mount on +Z). CHANGED (Phase 2a remodel): a sleeve on a hinged bracket with a piston
-- and foot pad that slide down out of it. Parts that move carry GEAR_STOWED_ATTRIBUTE (their part-local
-- CFrame when the leg is stowed; the built pose is deployed), animated on clients (Render/Gear).
local GEAR_STOWED_ATTRIBUTE = "GearStowed"
local LEG_AXIS_Z = 0.15 -- strut axis, studs from the centre toward the mount
local LEG_MOUNT_SIZE = Vector3.new(1.6, 1.4, 1.2)
local LEG_MOUNT_TOP = 0.3 -- studs below the top
local LEG_HINGE_DIAMETER = 0.5
local LEG_HINGE_LENGTH = 1.9
local LEG_SLEEVE_DIAMETER = 0.95
local LEG_SLEEVE_TOP = 3.3 -- studs above the centre
local LEG_SLEEVE_BOTTOM = 0
local LEG_COLLAR_DIAMETER = 1.1
local LEG_COLLAR_HEIGHT = 0.2
local LEG_BRACE_DIAMETER = 0.32
local LEG_PISTON_DIAMETER = 0.62
local LEG_PISTON_TOP = 0.3
local LEG_SPRING_DIAMETER = 0.82
local LEG_SPRING_HEIGHT = 0.35
local LEG_ANKLE_DIAMETER = 0.7
local LEG_FOOT_DIAMETER = 2.6
local LEG_FOOT_HEIGHT = 0.28
local LEG_STROKE = 3 -- studs the moving parts rise when stowed
local EXT_SEAT_BASE = 0.3
local EXT_SEAT_SIZE = Vector3.new(2.4, 1, 2)
local EXT_SEAT_BACKREST = Vector3.new(2.4, 3, 0.3)

local MIN_EXTENT = 1e-3 -- facet triangles narrower than this are skipped
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

type Ctx = {
	def: Parts.PartDef,
	size: Vector3, -- studs
	real: boolean,
	model: Model,
	bounds: Part,
}

local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- turns a Cylinder's X axis onto +Y
local EXHAUST_ROTATION = CFrame.Angles(math.rad(180), 0, 0) -- UpVector -> -Y

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

-- CHANGED (Phase 2a remodel): shaping helpers for the remodelled parts.

-- Horizontal unit vectors at azimuth a: 0 points to the front (-Z), pi/2 to +X.
local function radialAt(a: number): Vector3
	return Vector3.new(math.sin(a), 0, -math.cos(a))
end

local function tangentAt(a: number): Vector3
	return Vector3.new(math.cos(a), 0, math.sin(a))
end

-- Cylinder of diameter d whose axis runs from a to b.
local function rod(ctx: Ctx, name: string, d: number, a: Vector3, b: Vector3, style: Look, collide: boolean): Part
	local axis = b - a
	local x = axis.Unit
	local hint = if math.abs(x.Y) < 0.9 then Vector3.yAxis else Vector3.xAxis
	local z = x:Cross(hint).Unit
	local y = z:Cross(x)
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Cylinder
	part.Size = Vector3.new(axis.Magnitude, d, d)
	part.CFrame = CFrame.fromMatrix((a + b) / 2, x, y, z)
	finish(ctx, part, name, style, collide)
	return part
end

--[[
	Exact faceted frustum: n flat sides between a ring of apothem a0 at height y0 and a ring of apothem a1 at y1
	(the apothem is the distance from the axis to the middle of a side). Each side is a centre plate as wide as the
	narrow end plus a right-triangle wedge on each edge, so neighbouring sides meet edge to edge with no gaps or
	overlaps. Side 1 faces the front (-Z). The outer faces lie exactly on the n-gon; plates are FACET_THICKNESS
	thick, inward. Keep the circumradius a / cos(pi / n) inside the part's box.
]]
local function facets(
	ctx: Ctx,
	prefix: string,
	n: number,
	y0: number,
	a0: number,
	y1: number,
	a1: number,
	style: Look,
	collide: boolean
)
	local dy, da = y1 - y0, a1 - a0
	local length = math.sqrt(dy * dy + da * da)
	local halfTan = math.tan(math.pi / n)
	local w0, w1 = 2 * a0 * halfTan, 2 * a1 * halfTan
	local narrow = math.min(w0, w1)
	local delta = math.abs(w0 - w1) / 2
	local t = FACET_THICKNESS
	for k = 0, n - 1 do
		local az = 2 * math.pi * k / n
		local u, tangent = radialAt(az), tangentAt(az)
		local slope = (u * da + Vector3.yAxis * dy) / length
		local normal = (u * dy - Vector3.yAxis * da) / length
		local mid = u * a0 + Vector3.yAxis * y0 + slope * (length / 2) - normal * (t / 2)
		box(
			ctx,
			`{prefix}{k + 1}`,
			Vector3.new(narrow, length, t),
			CFrame.fromMatrix(mid, tangent, slope, tangent:Cross(slope)),
			style,
			collide
		)
		if delta > MIN_EXTENT then
			-- the triangle's right angle sits at the wide end, against the plate's edge
			local wy = if w0 >= w1 then slope else -slope
			for _, side in { 1, -1 } do
				local wz = tangent * -side
				local centre = mid + tangent * (side * (narrow + delta) / 2)
				wedge(
					ctx,
					`{prefix}{k + 1}{if side > 0 then "R" else "L"}`,
					Vector3.new(t, length, delta),
					CFrame.fromMatrix(centre, wy:Cross(wz), wy, wz),
					style,
					collide
				)
			end
		end
	end
end

-- A point on side 1 (the front, -Z) of a faceted frustum, `at` of the way up it, `proud` studs out of the surface,
-- as a CFrame whose X runs along the side and Y up the slope (Z points into the part).
local function frontFacetFrame(y0: number, a0: number, y1: number, a1: number, at: number, proud: number): CFrame
	local dy, da = y1 - y0, a1 - a0
	local length = math.sqrt(dy * dy + da * da)
	local u, tangent = radialAt(0), tangentAt(0)
	local slope = (u * da + Vector3.yAxis * dy) / length
	local normal = (u * dy - Vector3.yAxis * da) / length
	local position = u * a0 + Vector3.yAxis * y0 + slope * (length * at) + normal * proud
	return CFrame.fromMatrix(position, tangent, slope, tangent:Cross(slope))
end

-- Count balls of diameter d evenly around the Y axis at radius r and height y.
local function boltRing(ctx: Ctx, prefix: string, count: number, r: number, y: number, d: number, style: Look)
	for i = 1, count do
		local a = 2 * math.pi * (i - 0.5) / count
		ball(ctx, `{prefix}{i}`, d, radialAt(a) * r + Vector3.new(0, y, 0), style, false)
	end
end

local function attachment(parent: Instance, name: string, cf: CFrame): Attachment
	local att = Instance.new("Attachment")
	att.Name = name
	att.CFrame = cf
	att.Parent = parent
	return att
end

-- CHANGED (Boarding): returns the prompt (the client's boarding prompts on cosmetic copies are built the same way)
local function prompt(
	parent: Instance,
	name: string,
	actionText: string,
	objectText: string,
	distance: number
): ProximityPrompt
	local pp = Instance.new("ProximityPrompt")
	pp.Name = name
	pp.ActionText = actionText
	pp.ObjectText = objectText
	pp.HoldDuration = 0
	pp.MaxActivationDistance = distance
	pp.RequiresLineOfSight = false
	pp.KeyboardKeyCode = PROMPT_KEY
	pp.Parent = parent
	return pp
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
		prompt(
			part,
			"SitPrompt",
			if isPilot then PILOT_SEAT_ACTION else SEAT_ACTION,
			ctx.def.DisplayName,
			SEAT_PROMPT_DISTANCE
		)
	end
	return part
end

--============================================================================
-- Builders (S = ctx.size in studs; everything stays inside +-S/2)
--============================================================================

-- CHANGED (Phase 2a remodel): a simple octagonal capsule on a dark heat shield, one framed window on the front,
-- docking ring and orange hatch on top. Shell parts do not collide so the seated character sits inside.
local function buildPod(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local shieldTop = -hy + POD_SHIELD_HEIGHT
	cylinder(ctx, "HeatShield", d * POD_SHIELD_DIAMETER, -hy, shieldTop, LOOK.Dark, false)
	local y0, a0 = shieldTop, d * POD_BASE_APOTHEM
	local y1, a1 = S.Y * POD_SHELL_TOP, d * POD_TOP_APOTHEM
	facets(ctx, "Shell", POD_FACETS, y0, a0, y1, a1, LOOK.Hull, false)
	cylinder(ctx, "DockingRing", d * POD_RING_DIAMETER, y1, y1 + POD_RING_HEIGHT, LOOK.Dark, false)
	cylinder(
		ctx,
		"Hatch",
		d * POD_HATCH_DIAMETER,
		y1 + POD_RING_HEIGHT,
		y1 + POD_RING_HEIGHT + POD_HATCH_HEIGHT,
		LOOK.Accent,
		false
	)
	local window = POD_WINDOW_SIZE
	local frame = POD_WINDOW_FRAME
	box(
		ctx,
		"WindowFrame",
		Vector3.new(window.X + 2 * frame, window.Y + 2 * frame, 0.04),
		frontFacetFrame(y0, a0, y1, a1, POD_WINDOW_AT, 0.01),
		LOOK.Dark,
		false
	)
	box(
		ctx,
		"Window",
		Vector3.new(window.X, window.Y, 0.05),
		frontFacetFrame(y0, a0, y1, a1, POD_WINDOW_AT, 0.03),
		LOOK.PodGlass,
		false
	)
	if ctx.def.Seats >= 1 then
		-- Bottom centre, facing -Z; a seated R15 (about 4 studs) keeps its head just inside the capsule.
		seat(ctx, 1, POD_SEAT_SIZE, CFrame.new(0, shieldTop + POD_SEAT_SIZE.Y / 2, 0))
	end
end

local function addExhaust(ctx: Ctx)
	attachment(ctx.bounds, "Exhaust", CFrame.new(0, -ctx.size.Y / 2, 0) * EXHAUST_ROTATION)
end

-- CHANGED (Phase 2a remodel): mounting plate, thrust frame, combustion chamber with a turbopump, gimbal actuators,
-- and a faceted bell that flares from the throat. The bell is hollow: from below you see its dark inside and the
-- glow deep in the throat.
local function buildEngine(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local function below(fraction: number): number
		return hy - S.Y * fraction
	end
	local plateBottom = below(ENGINE_PLATE_HEIGHT)
	cylinder(ctx, "MountPlate", d * ENGINE_PLATE_DIAMETER, plateBottom, hy, LOOK.Dark, true)
	local chamberTop, chamberBottom = below(ENGINE_CHAMBER_TOP), below(ENGINE_CHAMBER_BOTTOM)
	for i = 1, 4 do
		local a = math.pi / 4 + (i - 1) * math.pi / 2
		rod(
			ctx,
			`Strut{i}`,
			d * ENGINE_STRUT_DIAMETER,
			radialAt(a) * (d * ENGINE_STRUT_TOP_RADIUS) + Vector3.new(0, plateBottom, 0),
			radialAt(a) * (d * ENGINE_STRUT_BOTTOM_RADIUS) + Vector3.new(0, chamberTop, 0),
			LOOK.Dark,
			false
		)
	end
	cylinder(ctx, "Chamber", d * ENGINE_CHAMBER_DIAMETER, chamberBottom, chamberTop, LOOK.Metal, true)
	local bandMid = (chamberTop + chamberBottom) / 2
	local band = S.Y * ENGINE_CHAMBER_BAND / 2
	cylinder(ctx, "ChamberBand", d * ENGINE_CHAMBER_DIAMETER + 0.06, bandMid - band, bandMid + band, LOOK.Dark, false)
	-- turbopump on +X with a feed pipe into the chamber
	local pumpX = d * ENGINE_PUMP_OFFSET
	local pumpTop, pumpBottom = below(ENGINE_PUMP_TOP), below(ENGINE_PUMP_BOTTOM)
	rod(
		ctx,
		"Turbopump",
		d * ENGINE_PUMP_DIAMETER,
		Vector3.new(pumpX, pumpTop, 0),
		Vector3.new(pumpX, pumpBottom, 0),
		LOOK.Metal,
		false
	)
	rod(
		ctx,
		"FeedPipe",
		d * ENGINE_PIPE_DIAMETER,
		Vector3.new(pumpX, pumpBottom + 0.05 * S.Y, 0),
		Vector3.new(d * ENGINE_CHAMBER_DIAMETER / 2, bandMid - band - 0.04 * S.Y, 0),
		LOOK.Dark,
		false
	)
	-- throat and the neck flaring into the bell
	local throatBottom = below(ENGINE_THROAT_BOTTOM)
	cylinder(ctx, "Throat", d * ENGINE_THROAT_DIAMETER, throatBottom, chamberBottom, LOOK.Engine, true)
	local y = throatBottom
	for i, neck in ENGINE_NECK do
		local h = S.Y * neck.h
		cylinder(ctx, `Neck{i}`, d * neck.d, y - h, y, LOOK.Engine, true)
		y -= h
	end
	local bellTop, bellBottom = y, -hy + BOTTOM_CLEARANCE
	facets(
		ctx,
		"Bell",
		ENGINE_BELL_FACETS,
		bellBottom,
		d * ENGINE_BELL_EXIT_APOTHEM,
		bellTop,
		d * ENGINE_BELL_TOP_APOTHEM,
		LOOK.Engine,
		true
	)
	cylinder(ctx, "Glow", d * ENGINE_GLOW_DIAMETER, bellTop - GLOW_HEIGHT, bellTop, LOOK.Neon, false)
	-- gimbal actuators from the plate down to the top of the bell (front and back, clear of the pump)
	for i, a in { 0, math.pi } do
		rod(
			ctx,
			`Actuator{i}`,
			d * ENGINE_ACTUATOR_DIAMETER,
			radialAt(a) * (d * ENGINE_ACTUATOR_TOP_RADIUS) + Vector3.new(0, plateBottom, 0),
			radialAt(a) * (d * ENGINE_BELL_TOP_APOTHEM * 1.15) + Vector3.new(0, bellTop - 0.02 * S.Y, 0),
			LOOK.Metal,
			false
		)
	end
	addExhaust(ctx)
end

-- CHANGED (Phase 2a remodel): a segmented booster with a FLAT top (a nose cone is a separate part): dark top collar,
-- joint rings, an orange band and roll-pattern panels near the top, attach lugs on +Z, and a short faceted nozzle.
local function buildBooster(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local bodyD = d - SRB_BODY_INSET
	local collarBottom = hy - SRB_COLLAR_HEIGHT
	local nozzleTop = -hy + SRB_NOZZLE_HEIGHT
	local aftTop = nozzleTop + SRB_AFT_RING_HEIGHT
	cylinder(ctx, "TopCollar", d * 0.98, collarBottom, hy, LOOK.Dark, true)
	cylinder(ctx, "Body", bodyD, aftTop, collarBottom, LOOK.Hull, true)
	cylinder(ctx, "AftRing", d * 0.98, nozzleTop, aftTop, LOOK.Dark, true)
	local span = collarBottom - aftTop
	for i = 1, SRB_JOINTS do
		local y = aftTop + span * i / (SRB_JOINTS + 1)
		cylinder(ctx, `Joint{i}`, bodyD + 0.08, y - SRB_JOINT_HEIGHT / 2, y + SRB_JOINT_HEIGHT / 2, LOOK.Dark, false)
	end
	local bandY = hy - SRB_BAND_DROP
	cylinder(ctx, "Band", bodyD + 0.06, bandY - SRB_BAND_HEIGHT / 2, bandY + SRB_BAND_HEIGHT / 2, LOOK.Accent, false)
	local panel = SRB_ROLL_PANEL
	local panelY = bandY - SRB_BAND_HEIGHT / 2 - panel.Y / 2 - 0.15
	for i, a in { math.pi / 2, -math.pi / 2 } do
		local u = radialAt(a)
		box(
			ctx,
			`RollPanel{i}`,
			panel,
			CFrame.fromMatrix(
				u * (bodyD / 2 + panel.Z / 2 - 0.02) + Vector3.new(0, panelY, 0),
				tangentAt(a),
				Vector3.yAxis
			),
			LOOK.Dark,
			false
		)
	end
	local lug = SRB_LUG_SIZE
	for i, y in { hy - SRB_LUG_DROP, -hy + SRB_LUG_DROP } do
		box(ctx, `Lug{i}`, lug, CFrame.new(0, y, S.Z / 2 - lug.Z / 2), LOOK.Metal, true)
	end
	local nozzleBottom = -hy + BOTTOM_CLEARANCE
	facets(
		ctx,
		"Nozzle",
		SRB_NOZZLE_FACETS,
		nozzleBottom,
		d * SRB_NOZZLE_EXIT_APOTHEM,
		nozzleTop,
		d * SRB_NOZZLE_TOP_APOTHEM,
		LOOK.Engine,
		true
	)
	cylinder(ctx, "Glow", d * SRB_GLOW_DIAMETER, nozzleTop - GLOW_HEIGHT, nozzleTop, LOOK.Neon, false)
	addExhaust(ctx)
end

-- CHANGED (Phase 2a remodel): dark collars on both mating faces, a hazard band (yellow with black slashes) and
-- a dark separation groove carrying a ring of explosive bolts.
local function buildDecoupler(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local bodyD = d - DECOUPLER_BODY_INSET
	local c = DECOUPLER_COLLAR_HEIGHT
	local grooveTop = DECOUPLER_BAND_TOP + DECOUPLER_GROOVE_HEIGHT
	cylinder(ctx, "CollarTop", d * 0.98, hy - c, hy, LOOK.Dark, true)
	cylinder(ctx, "Upper", bodyD, grooveTop, hy - c, LOOK.Hull, true)
	local grooveD = d - DECOUPLER_GROOVE_INSET
	cylinder(ctx, "Groove", grooveD, DECOUPLER_BAND_TOP, grooveTop, LOOK.Dark, true)
	cylinder(ctx, "Band", bodyD, DECOUPLER_BAND_BOTTOM, DECOUPLER_BAND_TOP, LOOK.Hazard, true)
	cylinder(ctx, "Lower", bodyD, -hy + c, DECOUPLER_BAND_BOTTOM, LOOK.Hull, true)
	cylinder(ctx, "CollarBottom", d * 0.98, -hy, -hy + c, LOOK.Dark, true)
	-- black slashes leaning 45 degrees around the band
	local slash = DECOUPLER_SLASH_SIZE
	local count = math.max(6, math.floor(math.pi * bodyD / DECOUPLER_SLASH_SPACING))
	local bandY = (DECOUPLER_BAND_BOTTOM + DECOUPLER_BAND_TOP) / 2
	for i = 1, count do
		local a = 2 * math.pi * (i - 0.5) / count
		local surface = CFrame.fromMatrix(
			radialAt(a) * (bodyD / 2 + slash.Z / 2 - 0.01) + Vector3.new(0, bandY, 0),
			tangentAt(a),
			Vector3.yAxis
		)
		box(ctx, `Slash{i}`, slash, surface * CFrame.Angles(0, 0, math.rad(45)), LOOK.Dark, false)
	end
	local bolts = math.max(6, math.floor(math.pi * grooveD / DECOUPLER_BOLT_SPACING))
	boltRing(ctx, "Bolt", bolts, grooveD / 2, (DECOUPLER_BAND_TOP + grooveTop) / 2, DECOUPLER_BOLT_DIAMETER, LOOK.Metal)
end

-- CHANGED (Phase 2a remodel): hull plate with bolts on +Z (against the parent), a piston with a hazard collar and a
-- black joint seam through the block, four struts, and a dark clamp pad on -Z.
local function buildRadialDecoupler(ctx: Ctx)
	local S = ctx.size
	local hz = S.Z / 2
	local plate = RADIAL_PLATE_SIZE
	local plateFront = hz - plate.Z
	box(ctx, "MountPlate", plate, CFrame.new(0, 0, hz - plate.Z / 2), LOOK.Hull, true)
	local inset = plate.X / 2 - RADIAL_BOLT_INSET
	local i = 0
	for _, x in { -inset, inset } do
		for _, y in { -inset, inset } do
			i += 1
			ball(ctx, `Bolt{i}`, RADIAL_BOLT_DIAMETER, Vector3.new(x, y, plateFront), LOOK.Metal, false)
		end
	end
	local pad = RADIAL_PAD_SIZE
	local padBack = -hz + pad.Z
	box(ctx, "Pad", pad, CFrame.new(0, 0, -hz + pad.Z / 2), LOOK.Dark, true)
	rod(
		ctx,
		"Piston",
		RADIAL_PISTON_DIAMETER,
		Vector3.new(0, 0, padBack),
		Vector3.new(0, 0, plateFront),
		LOOK.Metal,
		true
	)
	local mid = (padBack + plateFront) / 2
	local collar = RADIAL_COLLAR_LENGTH / 2
	rod(
		ctx,
		"Collar",
		RADIAL_COLLAR_DIAMETER,
		Vector3.new(0, 0, mid - collar),
		Vector3.new(0, 0, mid + collar),
		LOOK.Hazard,
		false
	)
	local seam = RADIAL_SEAM_LENGTH / 2
	rod(
		ctx,
		"Seam",
		RADIAL_COLLAR_DIAMETER + 0.04,
		Vector3.new(0, 0, mid - seam),
		Vector3.new(0, 0, mid + seam),
		LOOK.Dark,
		false
	)
	local k = 0
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			k += 1
			rod(
				ctx,
				`Strut{k}`,
				RADIAL_STRUT_DIAMETER,
				Vector3.new(sx * RADIAL_STRUT_PLATE, sy * RADIAL_STRUT_PLATE, plateFront),
				Vector3.new(sx * RADIAL_STRUT_PAD, sy * RADIAL_STRUT_PAD, padBack),
				LOOK.Dark,
				false
			)
		end
	end
end

-- CHANGED (Phase 2a remodel): a faceted taper from the full diameter at the bottom to one block (the small stack
-- size) at the top, with dark collars on both mating faces.
local function buildAdapter(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	local topD = math.min(GameConfig.GRID_SIZE, d)
	local c = ADAPTER_COLLAR_HEIGHT
	local fit = math.cos(math.pi / ADAPTER_FACETS) -- apothem that keeps the n-gon's corners inside the circle
	cylinder(ctx, "CollarBottom", d * 0.985, -hy, -hy + c, LOOK.Dark, true)
	cylinder(ctx, "CollarTop", topD * 0.985, hy - c, hy, LOOK.Dark, true)
	facets(ctx, "Shell", ADAPTER_FACETS, -hy + c, d / 2 * fit - 0.03, hy - c, topD / 2 * fit - 0.03, LOOK.Hull, true)
end

-- CHANGED (Phase 2a remodel): an ogive of two faceted bands on a dark collar, with an orange tip.
local function buildNose(ctx: Ctx)
	local S = ctx.size
	local hy, d = S.Y / 2, math.min(S.X, S.Z)
	cylinder(ctx, "Collar", d * 0.98, -hy, -hy + S.Y * NOSE_COLLAR_HEIGHT, LOOK.Dark, true)
	for i = 1, #NOSE_PROFILE - 1 do
		local lower, upper = NOSE_PROFILE[i], NOSE_PROFILE[i + 1]
		facets(
			ctx,
			`Cone{i}_`,
			NOSE_FACETS,
			-hy + S.Y * lower.y,
			d * lower.a,
			-hy + S.Y * upper.y,
			d * upper.a,
			LOOK.Hull,
			true
		)
	end
	local coneTop = -hy + S.Y * NOSE_PROFILE[#NOSE_PROFILE].y
	local capTop = -hy + S.Y * NOSE_TIP_CAP_TOP
	cylinder(ctx, "TipCap", d * NOSE_TIP_CAP_DIAMETER, coneTop, capTop, LOOK.Accent, false)
	local tipD = d * NOSE_TIP_DIAMETER
	ball(ctx, "Tip", tipD, Vector3.new(0, math.min(capTop, hy - tipD / 2), 0), LOOK.Accent, false)
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

-- CHANGED (Phase 2a remodel): bracket and hinge on the +Z face, a white sleeve with a brace, and a piston, spring
-- collar, ankle and foot pad that slide down out of it. The moving parts carry their stowed pose in
-- GEAR_STOWED_ATTRIBUTE (part-local CFrame; the built pose is deployed); clients animate them (Render/Gear).
local function buildLeg(ctx: Ctx)
	local S = ctx.size
	local hy, hz = S.Y / 2, S.Z / 2
	local z = LEG_AXIS_Z
	local mount = LEG_MOUNT_SIZE
	local mountY = hy - LEG_MOUNT_TOP - mount.Y / 2
	box(ctx, "Mount", mount, CFrame.new(0, mountY, hz - mount.Z / 2), LOOK.Dark, true)
	local hingeY = LEG_SLEEVE_TOP - LEG_HINGE_DIAMETER / 2
	box(
		ctx,
		"HingePin",
		Vector3.new(LEG_HINGE_LENGTH, LEG_HINGE_DIAMETER, LEG_HINGE_DIAMETER),
		CFrame.new(0, hingeY, z),
		LOOK.Metal,
		false
	).Shape =
		Enum.PartType.Cylinder
	cylinder(ctx, "Sleeve", LEG_SLEEVE_DIAMETER, LEG_SLEEVE_BOTTOM, LEG_SLEEVE_TOP, LOOK.Hull, true).CFrame += Vector3.new(
		0,
		0,
		z
	)
	cylinder(
		ctx,
		"SleeveCollar",
		LEG_COLLAR_DIAMETER,
		LEG_SLEEVE_BOTTOM,
		LEG_SLEEVE_BOTTOM + LEG_COLLAR_HEIGHT,
		LOOK.Dark,
		false
	).CFrame += Vector3.new(
		0,
		0,
		z
	)
	rod(
		ctx,
		"Brace",
		LEG_BRACE_DIAMETER,
		Vector3.new(0, mountY - mount.Y / 2 + 0.1, hz - 0.35),
		Vector3.new(0, LEG_SLEEVE_BOTTOM + 0.9, z + LEG_SLEEVE_DIAMETER / 2 - 0.1),
		LOOK.Dark,
		false
	)
	-- moving parts: built deployed, stowed = raised by LEG_STROKE
	local footTop = -hy + 0.02 + LEG_FOOT_HEIGHT
	local ankleY = footTop + LEG_ANKLE_DIAMETER / 2 - 0.1
	local stroke = Vector3.new(0, LEG_STROKE, 0)
	local function moving(part: BasePart, stowed: CFrame)
		part:SetAttribute(GEAR_STOWED_ATTRIBUTE, stowed)
	end
	local piston = cylinder(ctx, "Piston", LEG_PISTON_DIAMETER, ankleY, LEG_PISTON_TOP, LOOK.Metal, true)
	piston.CFrame += Vector3.new(0, 0, z)
	moving(piston, piston.CFrame + stroke)
	local springY = LEG_SLEEVE_BOTTOM - LEG_SPRING_HEIGHT / 2 - 0.05
	local spring = cylinder(
		ctx,
		"Spring",
		LEG_SPRING_DIAMETER,
		springY - LEG_SPRING_HEIGHT / 2,
		springY + LEG_SPRING_HEIGHT / 2,
		LOOK.Accent,
		false
	)
	spring.CFrame += Vector3.new(0, 0, z)
	moving(spring, spring.CFrame + stroke)
	local ankle = ball(ctx, "Ankle", LEG_ANKLE_DIAMETER, Vector3.new(0, ankleY, z), LOOK.Dark, false)
	moving(ankle, ankle.CFrame + stroke)
	local foot = cylinder(ctx, "Foot", LEG_FOOT_DIAMETER, footTop - LEG_FOOT_HEIGHT, footTop, LOOK.Dark, true)
	foot.CFrame += Vector3.new(0, 0, z)
	moving(foot, foot.CFrame + stroke) -- stowed: the whole lower leg retracts up into the sleeve
	attachment(ctx.bounds, "Foot", CFrame.new(0, -hy, 0))
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
PartVisuals.GEAR_STOWED_ATTRIBUTE = GEAR_STOWED_ATTRIBUTE

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

--[[
	CHANGED (Boarding): a seat prompt that looks and behaves exactly like a real seat's SitPrompt ("Pilot" on a pilot
	seat, "Sit" otherwise, the part's name, same key and range), named `name` and parented to `parent`. The client
	puts these on the seats of cosmetic copies of crafts in other pockets (Render/BoardPrompts).
]]
function PartVisuals.seatPrompt(parent: Instance, name: string, isPilot: boolean, objectText: string): ProximityPrompt
	return prompt(parent, name, if isPilot then PILOT_SEAT_ACTION else SEAT_ACTION, objectText, SEAT_PROMPT_DISTANCE)
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
