--!strict
--[[
	MapBodiesMath (CHANGED (Map planets): new file. Steamy: "planets dont look good" on the map (M))
	The pure maths behind Render/MapBodies, testable offline (MapBodies.spec). No instances, no engine services.

	Night shading. Roblox has one global light and the map shows several bodies around Sol at once, so the map lights
	nothing: its surfaces are flat-lit (SkyLighting's map look) and every planet / moon wears a NIGHT SHELL, a black
	sphere just above its ground whose texture alpha darkens the side facing away from Sol:
	  brightness(c) = NIGHT_FLOOR + (1 - NIGHT_FLOOR) * smoothstep(TERMINATOR_IN, TERMINATOR_OUT, c)
	                  * (DAY_MIN + (1 - DAY_MIN) * max(c, 0))
	  nightAlpha(c) = 1 - brightness(c)
	with c the cosine between the ground normal and the direction to Sol: a soft terminator, a near-black night half
	and a day half that still falls off toward the terminator (Lambert-like), so the ball looks round. Alpha blending
	is linear (Roblox renders in linear light), so NIGHT_FLOOR 0.02 shows as a dark grey, not black.

	The shell is ScaledSpace's 24 cube-sphere patches (the same shared patch mesh), turned so that its +Y points at
	Sol (nightShellRotation). Patch i is the +Y face quarter turned by cube rotation M_i, so its pixel at patch-local
	direction p shades with (M_i p).y = row2(M_i) . p: only the second row of M_i matters, and that row is one of the
	six signed axes. So SIX images (shellKey / paintShell) serve all 24 patches of every body's shell, and the shell
	turns as one rigid piece when Sol moves: nothing is repainted at run time.

	Screen size: pixelRadius is the on-screen radius of a sphere (true limb, not the centre-plane radius).
	nextIconMode switches a body between its ball and a KSP-style icon (dot + name) with hysteresis (ICON_BELOW_PX /
	BALL_ABOVE_PX), so a body at the threshold does not flicker. moonIconHidden hides a moon's icon while its parent's
	icon sits right next to it on screen (the names would overlap).

	Atmosphere rim: a camera-facing image just in front of the body (frontLimbRadius sizes it so its ring lies exactly
	on the limb), radial profile rimAlpha (paintRim). rimGradient turns a UIGradient toward Sol's direction on screen:
	the sunlit limb bright, the night limb faint, an even ring when Sol is in front of or behind the body.

	Sol's glow: one smooth radial image (paintGlow), replacing stacked discs.

	API:
		MapBodiesMath.brightness(c) / nightAlpha(c): number
		MapBodiesMath.sunDirection(body: Vec3d, sol: Vec3d): Vector3?        unit, doubles subtracted first
		MapBodiesMath.nightShellRotation(sun: Vector3): CFrame               rotation, +Y = sun
		MapBodiesMath.shellKey(m): number                                    1..6: which shared shell image patch m uses
		MapBodiesMath.paintShell(m, size, buf)                               RGBA8 pixels of patch m's shell image
		MapBodiesMath.pixelRadius(distance, radius, tanHalfFov, viewportHeight): number   math.huge when inside
		MapBodiesMath.limbRadius(distance, radius): number                   limb radius in the centre's plane
		MapBodiesMath.frontLimbRadius(distance, radius): number              same in the plane through the front point
		MapBodiesMath.nextIconMode(isIcon, pixelRadius): boolean
		MapBodiesMath.moonIconHidden(parentIsIcon, screenDistance): boolean
		MapBodiesMath.rimGradient(sunCam: Vector3): (rotationDeg, tNight, tDay)
		MapBodiesMath.rimKeypoints(canvas): (number, number)                 gradient positions of the two limbs
		MapBodiesMath.rimAlpha(rho, inner, outer): number                    rho in limb radii
		MapBodiesMath.paintRim(size, color, inner, outer, peak, buf)
		MapBodiesMath.glowAlpha(t): number                                   t in glow radii
		MapBodiesMath.paintGlow(size, color, buf)
		MapBodiesMath.RIM_CANVAS
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
-- Night shading (preview-checked; scratchpad mapviews)
local NIGHT_FLOOR = 0.02 -- brightness left on the night side (linear light: a dark grey on screen)
local TERMINATOR_IN = -0.06 -- cos(angle to Sol) where the day light starts ...
local TERMINATOR_OUT = 0.25 -- ... and where the soft terminator is over
local DAY_MIN = 0.35 -- day-side brightness at the terminator, rising to 1 under Sol (looks round)
-- Ball <-> icon (on-screen radius in pixels)
local ICON_BELOW_PX = 4 -- a ball smaller than this becomes an icon ...
local BALL_ABOVE_PX = 6 -- ... and an icon larger than this a ball again
local MOON_MERGE_PX = 26 -- a moon's icon hides closer than this to its parent's icon
-- Atmosphere rim
local RIM_CANVAS = 1.3 -- the rim image's half-size in limb radii (room for the outer glow)
local RIM_OUTER_POWER = 1.4 -- outer falloff exponent (below 2: a long soft tail)
local RIM_MIN = 0.18 -- rim brightness on the night limb (1 on the sunlit limb)
local RIM_WHITEN = 0.3 -- the brightest part of the rim blends this much toward white
-- Sol's glow image
local GLOW_POWER = 2.4 -- falloff exponent of the halo
local GLOW_PEAK = 0.9 -- halo alpha at the centre
local GLOW_CORE = 0.35 -- extra alpha of the bright core ...
local GLOW_CORE_WIDTH = 0.18 -- ... over this fraction of the glow radius
local GLOW_EDGE = 0.9 -- the halo fades to zero between this fraction of its radius and its edge
local GLOW_WHITEN = 0.4 -- the core blends this much toward white
--============================================================================

local MapBodiesMath = {}

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function byte(x: number): number
	return math.clamp(math.floor(x * 255 + 0.5), 0, 255)
end

--============================================================================
-- Night shading
--============================================================================

-- Brightness 0..1 of ground whose normal makes cos `c` with the direction to Sol (header).
function MapBodiesMath.brightness(c: number): number
	local day = smoothstep(TERMINATOR_IN, TERMINATOR_OUT, c) * (DAY_MIN + (1 - DAY_MIN) * math.max(c, 0))
	return NIGHT_FLOOR + (1 - NIGHT_FLOOR) * day
end

-- Alpha of the black night shell there.
function MapBodiesMath.nightAlpha(c: number): number
	return 1 - MapBodiesMath.brightness(c)
end

-- Unit direction from a body's centre to Sol's (both relative to the same body, same axes; doubles).
function MapBodiesMath.sunDirection(body: Vec3d, sol: Vec3d): Vector3?
	local x, y, z = sol.x - body.x, sol.y - body.y, sol.z - body.z
	local length = math.sqrt(x * x + y * y + z * z)
	if length < 1e-6 then
		return nil
	end
	return Vector3.new(x / length, y / length, z / length)
end

-- Rotation whose +Y is `sun` (unit): the night shell's turn (its images are painted with Sol on local +Y).
function MapBodiesMath.nightShellRotation(sun: Vector3): CFrame
	local y = sun.Unit
	local helper = if math.abs(y.X) < 0.9 then Vector3.xAxis else Vector3.zAxis
	local z = helper:Cross(y).Unit
	local x = y:Cross(z)
	return CFrame.new(0, 0, 0, x.X, y.X, z.X, x.Y, y.Y, z.Y, x.Z, y.Z, z.Z)
end

-- Which of the six shared shell images patch `m` (row-major cube rotation) shows: from the signed axis in its second
-- row (header). 1 / 2 = +X / -X, 3 / 4 = +Y / -Y, 5 / 6 = +Z / -Z.
function MapBodiesMath.shellKey(m: { number }): number
	for axis = 1, 3 do
		local value = m[3 + axis]
		if value > 0.5 then
			return (axis - 1) * 2 + 1
		elseif value < -0.5 then
			return (axis - 1) * 2 + 2
		end
	end
	error("MapBodiesMath.shellKey: not a cube rotation", 2)
end

-- RGBA8 pixels (black, alpha = nightAlpha) of the shell image for patch `m`, in Biome's pixel <-> UV convention
-- (pixel (px, py) at UV ((px + 0.5) / size, (py + 0.5) / size)), the one ScaledSpace's patch mesh and textures use.
function MapBodiesMath.paintShell(m: { number }, size: number, buf: buffer)
	for py = 0, size - 1 do
		for px = 0, size - 1 do
			local s, t = Biome.uvToParam((px + 0.5) / size, (py + 0.5) / size)
			local _, y = Biome.patchDirection(m, s, t)
			local offset = (py * size + px) * 4
			buffer.writeu8(buf, offset, 0)
			buffer.writeu8(buf, offset + 1, 0)
			buffer.writeu8(buf, offset + 2, 0)
			buffer.writeu8(buf, offset + 3, byte(MapBodiesMath.nightAlpha(y)))
		end
	end
end

--============================================================================
-- Screen size, icons
--============================================================================

-- On-screen radius (px) of a sphere `radius` at `distance` (its centre) for a camera with tan(vertical FOV / 2).
function MapBodiesMath.pixelRadius(distance: number, radius: number, tanHalfFov: number, viewportHeight: number): number
	if distance <= radius then
		return math.huge
	end
	local s = radius / distance
	return s / math.sqrt(1 - s * s) / tanHalfFov * viewportHeight * 0.5
end

-- Radius of the limb circle measured in the plane through the centre, facing the camera.
function MapBodiesMath.limbRadius(distance: number, radius: number): number
	local s = math.min(radius / distance, 0.9999)
	return radius / math.sqrt(1 - s * s)
end

-- Same, in the plane through the sphere's point nearest the camera (distance - radius from it).
function MapBodiesMath.frontLimbRadius(distance: number, radius: number): number
	local s = math.min(radius / distance, 0.9999)
	return (distance - radius) * s / math.sqrt(1 - s * s)
end

-- Is the body drawn as an icon? `isIcon`: what it is now; hysteresis between ICON_BELOW_PX and BALL_ABOVE_PX.
function MapBodiesMath.nextIconMode(isIcon: boolean, pixelRadius: number): boolean
	if isIcon then
		return pixelRadius < BALL_ABOVE_PX
	end
	return pixelRadius < ICON_BELOW_PX
end

-- Is a moon's icon hidden? (its parent is an icon this close on screen)
function MapBodiesMath.moonIconHidden(parentIsIcon: boolean, screenDistance: number): boolean
	return parentIsIcon and screenDistance < MOON_MERGE_PX
end

--============================================================================
-- Atmosphere rim
--============================================================================

--[[
	The rim's UIGradient from Sol's direction in camera space (X right, Y up): the rotation (degrees, clockwise on
	screen, as UIGradient.Rotation) that points the gradient's end (offset 1) at Sol, and the transparency of the
	night limb / sunlit limb. The difference follows how much of Sol's direction lies across the screen: Sol in front
	of or behind the body lights the whole limb evenly.
]]
function MapBodiesMath.rimGradient(sunCam: Vector3): (number, number, number)
	local across = math.sqrt(sunCam.X * sunCam.X + sunCam.Y * sunCam.Y)
	local perp = math.clamp(across / math.max(sunCam.Magnitude, 1e-9), 0, 1)
	local rotation = if across > 1e-9 then math.deg(math.atan2(-sunCam.Y, sunCam.X)) else 0
	local nightBright = RIM_MIN + (1 - RIM_MIN) * (0.5 - 0.5 * perp)
	local dayBright = RIM_MIN + (1 - RIM_MIN) * (0.5 + 0.5 * perp)
	return rotation, 1 - nightBright, 1 - dayBright
end

-- Gradient offsets (0..1 across the image) of the two limb points on the gradient's axis.
function MapBodiesMath.rimKeypoints(canvas: number): (number, number)
	return 0.5 - 0.5 / canvas, 0.5 + 0.5 / canvas
end

-- Rim alpha profile (0..1) at `rho` limb radii from the centre: a thin band inside the limb, a soft tail outside.
function MapBodiesMath.rimAlpha(rho: number, inner: number, outer: number): number
	if rho < 1 then
		local u = (1 - rho) / inner
		return math.exp(-u * u)
	end
	return math.exp(-(((rho - 1) / outer) ^ RIM_OUTER_POWER))
end

-- RGBA8 pixels of a rim image (size x size, RIM_CANVAS limb radii to each edge).
function MapBodiesMath.paintRim(size: number, color: Color3, inner: number, outer: number, peak: number, buf: buffer)
	local half = size * 0.5
	for py = 0, size - 1 do
		for px = 0, size - 1 do
			local dx, dy = (px + 0.5 - half) / half, (py + 0.5 - half) / half
			local rho = math.sqrt(dx * dx + dy * dy) * RIM_CANVAS
			local a = peak * MapBodiesMath.rimAlpha(rho, inner, outer)
			if rho >= RIM_CANVAS then
				a = 0 -- nothing in the corners (the gradient's rotation must never show the image's square)
			end
			local c = color:Lerp(Color3.new(1, 1, 1), RIM_WHITEN * smoothstep(0.5 * peak, peak, a))
			local offset = (py * size + px) * 4
			buffer.writeu8(buf, offset, byte(c.R))
			buffer.writeu8(buf, offset + 1, byte(c.G))
			buffer.writeu8(buf, offset + 2, byte(c.B))
			buffer.writeu8(buf, offset + 3, byte(a))
		end
	end
end

--============================================================================
-- Sol's glow
--============================================================================

-- Glow alpha (0..1) at `t` glow radii from the centre (0 at and beyond the edge).
function MapBodiesMath.glowAlpha(t: number): number
	if t >= 1 then
		return 0
	end
	local x = math.max(t, 0)
	local core = x / GLOW_CORE_WIDTH
	local a = GLOW_PEAK * (1 - x) ^ GLOW_POWER + GLOW_CORE * math.exp(-core * core)
	return math.clamp(a, 0, 1) * (1 - smoothstep(GLOW_EDGE, 1, x))
end

-- RGBA8 pixels of the glow image (size x size, the glow's radius to each edge).
function MapBodiesMath.paintGlow(size: number, color: Color3, buf: buffer)
	local half = size * 0.5
	for py = 0, size - 1 do
		for px = 0, size - 1 do
			local dx, dy = (px + 0.5 - half) / half, (py + 0.5 - half) / half
			local t = math.sqrt(dx * dx + dy * dy)
			local core = t / GLOW_CORE_WIDTH
			local c = color:Lerp(Color3.new(1, 1, 1), GLOW_WHITEN * math.exp(-core * core))
			local offset = (py * size + px) * 4
			buffer.writeu8(buf, offset, byte(c.R))
			buffer.writeu8(buf, offset + 1, byte(c.G))
			buffer.writeu8(buf, offset + 2, byte(c.B))
			buffer.writeu8(buf, offset + 3, byte(MapBodiesMath.glowAlpha(t)))
		end
	end
end

MapBodiesMath.RIM_CANVAS = RIM_CANVAS
MapBodiesMath.ICON_BELOW_PX = ICON_BELOW_PX
MapBodiesMath.BALL_ABOVE_PX = BALL_ABOVE_PX

return table.freeze(MapBodiesMath)
