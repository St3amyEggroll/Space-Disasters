--!strict
--[[
	EffectsMath (Phase 10)
	The pure maths behind the rocket effects (Render/Effects, Render/Plumes): no instances, no services, so the
	offline Lune specs can test every curve (src/server/Tests/EffectsMath.spec.luau).

	  plumeShape(throttle, pressure, solid)   engine flame shape: narrow, bright and tight at sea level; a wide, faint,
	                                          expanding cone in vacuum. Solid boosters are thicker and smokier.
	  trailStrength(pressure)                 0..1 smoke-trail density; fades out on a log scale with altitude
	  trailLifetime(airSpeed)                 s; trail particles live long enough for a fixed trail length
	  trailSize(airSpeed, rate, width)        studs; trail puffs grow with speed so the trail stays continuous
	  dustStrength(height, thrustFraction)    0..1 launch/landing dust under the craft
	  heatFactor(density, speed)              0..1 re-entry heating (rho * v^3 on a log scale, gated by speed)
	  vaporFactor(speed, pressure)            0..1 transonic vapour cone (around Mach 1, in all but the thinnest air)
	  driftEmission(drift, randomSpeed)       how to aim a ParticleEmitter so its particles move with `drift` plus a
	                                          random velocity of up to `randomSpeed` in any direction
	  frameWithUp(position, up)               a CFrame whose UpVector is `up` (ParticleEmitter EmissionDirection Top)
	  leadingExtent(halfSize, direction)      support distance and cross-section radius of a box along a direction
	  qualityScale(level)                     particle-rate multiplier for a SavedQualityLevel (0 = Automatic)
	  explosionScale(blockSize)               size factor of a block's explosion (1 = one 4-stud block)
	  fade(age, duration)                     0..1 ease-out progress of a one-shot effect
]]

--============================================================================
-- Tunables
--============================================================================
-- Engine plumes (lengths in studs for the reference 4-stud nozzle at model scale 1; Plumes scales them)
local FLAME_LENGTH_MIN = 3 -- at minimum throttle
local FLAME_LENGTH_MAX = 16 -- at full throttle -- CHANGED (Physics feel): was 9; longer flames read as more power
local VACUUM_LENGTH_MULT = 1.6 -- the vacuum plume is this much longer
local SOLID_LENGTH_MULT = 1.35 -- solid boosters get a longer flame
local CORE_WIDTH0 = 0.55 -- x nozzle diameter, at the nozzle
local CORE_WIDTH1_SEA = 0.08 -- x diameter, at the core tip, sea level (pinched)
local CORE_WIDTH1_VACUUM = 0.45 -- x diameter, at the core tip, vacuum (opens up)
local CORE_LENGTH_VACUUM = 0.55 -- the bright core is this fraction of the flame length in vacuum (1 at sea level)
local GLOW_WIDTH0 = 0.85
local GLOW_WIDTH1_SEA = 0.3
local GLOW_WIDTH1_VACUUM = 2.6 -- the vacuum glow is a cone that widens to this x diameter
local SOLID_WIDTH_MULT = 1.25 -- boosters are thicker
local VACUUM_FADE = 0.35 -- extra transparency of the whole vacuum plume (fainter)
local CORE_BRIGHTNESS_SEA = 3
local CORE_BRIGHTNESS_VACUUM = 1.6
local GLOW_BRIGHTNESS_SEA = 1.5
local GLOW_BRIGHTNESS_VACUUM = 0.9
local SPREAD_SEA_DEG = 7
local SPREAD_VACUUM_DEG = 24
local SOLID_SPREAD_MULT = 1.3
local PARTICLE_SPEED_MIN = 30 -- studs/s at minimum throttle
local PARTICLE_SPEED_MAX = 58 -- studs/s at full throttle
local VACUUM_SPEED_MULT = 1.25
local VACUUM_PARTICLE_SIZE_MULT = 1.5
local SOLID_PARTICLE_SIZE_MULT = 1.3
local LIGHT_BRIGHTNESS_MAX = 3
local VACUUM_LIGHT_MULT = 0.7
-- Smoke trail
-- CHANGED (Physics feel): altitudes in these comments are for the 60 km Earth (1.1 km scale height)
local TRAIL_PRESSURE_FULL = 0.3 -- full trail at or below this altitude's pressure ratio (~1.3 km on Earth)
local TRAIL_PRESSURE_NONE = 0.004 -- no trail above this altitude (~6.1 km on Earth)
local TRAIL_MAX_LENGTH = 900 -- studs of trail behind a fast craft
local TRAIL_LIFETIME_MIN = 1.2 -- s
local TRAIL_LIFETIME_MAX = 8 -- s (slow crafts: the smoke column lingers this long) -- CHANGED (Physics feel): was 5; a longer column to climb past
local TRAIL_OVERLAP = 1.6 -- puff size / spacing between puffs, so the trail never breaks into dots
local TRAIL_SIZE_MAX = 45 -- studs
-- Launch / landing dust
local DUST_MAX_HEIGHT = 70 -- m above the ground (exhaust height) where the dust starts -- CHANGED (Physics feel): was 40; dust lingers longer under the climb
local DUST_THRUST_CAP = 1.5 -- thrust fraction above which the dust stops growing
local DUST_HEIGHT_POWER = 1.5 -- stronger the closer the nozzle is to the ground
-- Re-entry heating
-- CHANGED (Physics feel): recalibrated for the 60 km Earth (low orbit ~710 m/s; re-entries measured with the flight
-- model pass 7 km at ~710-740 m/s, 5 km at ~670-700) and the faster ascents of the new aero scale / engines x1.5
-- (gravity turns measured at 450 m/s at 3 km, up to ~620 m/s at 5 km for the most aggressive two-stage rocket).
-- Was 380 / 460 m/s and 1.5e5 / 3e6 on the half-size Earth.
local HEAT_SPEED_MIN = 600 -- m/s; nothing below this (a normal ascent stays under it in thick air)
local HEAT_SPEED_FULL = 700 -- m/s; full speed gate (low orbit on the 60 km Earth is ~710 m/s)
local HEAT_FLUX_MIN = 3e5 -- rho * v^3 where the glow starts (~8 km, the air's top, at 700 m/s)
local HEAT_FLUX_FULL = 5e6 -- rho * v^3 of full glow (~4.9 km at 700 m/s)
-- Transonic vapour cone
local SPEED_OF_SOUND = 340 -- m/s (no temperature model: one value everywhere)
local VAPOR_MACH_START = 0.85 -- CHANGED (Physics feel): was 0.93; the cone builds up earlier and lasts longer
local VAPOR_MACH_PEAK = 1.0
local VAPOR_MACH_END = 1.12
-- CHANGED (Physics feel): was 0.15 / 0.5, which no real ascent could reach (rockets pass Mach 1 well above 2 km);
-- now the cone shows in all but the thinnest air (nothing above ~5.3 km on the 7 km-top Earth)
local VAPOR_PRESSURE_MIN = 0.005
local VAPOR_PRESSURE_FULL = 0.05
-- Graphics quality
local QUALITY_SCALE_MIN = 0.3 -- at quality 1
local QUALITY_SCALE_AUTOMATIC = 0.8
-- Explosions
local EXPLOSION_REFERENCE = 4 * math.sqrt(3) -- diagonal of one 4-stud block
local EXPLOSION_SCALE_MIN = 0.6
local EXPLOSION_SCALE_MAX = 3
--============================================================================

export type PlumeShape = {
	length: number, -- studs (reference nozzle, scale 1)
	coreLength: number, -- fraction of `length` the bright core reaches
	coreWidth0: number, -- x nozzle diameter
	coreWidth1: number,
	glowWidth0: number,
	glowWidth1: number,
	fade: number, -- extra transparency 0..1 added to the whole plume
	coreBrightness: number,
	glowBrightness: number,
	spreadDeg: number,
	particleSpeed: number, -- studs/s (reference nozzle)
	particleSize: number, -- x nozzle diameter multiplier for the particle size curve
	light: number, -- PointLight brightness
}

local EffectsMath = {}

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function EffectsMath.smoothstep(edge0: number, edge1: number, x: number): number
	if edge1 == edge0 then
		return if x >= edge1 then 1 else 0
	end
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- How "vacuum-like" a plume is (0 at sea level, 1 in vacuum). The square root spreads the change over the lower
-- few kilometres, where Earth's thin (1.1 km scale height) air actually changes.
function EffectsMath.vacuumFactor(pressure: number): number
	return 1 - math.sqrt(math.clamp(pressure, 0, 1))
end

function EffectsMath.plumeShape(throttle: number, pressure: number, solid: boolean): PlumeShape
	local t = math.clamp(throttle, 0, 1)
	local burn = math.sqrt(t) -- low throttles still read as a flame
	local vac = EffectsMath.vacuumFactor(pressure)
	local widthMult = if solid then SOLID_WIDTH_MULT else 1
	return {
		length = lerp(FLAME_LENGTH_MIN, FLAME_LENGTH_MAX, t) * lerp(1, VACUUM_LENGTH_MULT, vac) * (if solid
			then SOLID_LENGTH_MULT
			else 1),
		coreLength = lerp(1, CORE_LENGTH_VACUUM, vac),
		coreWidth0 = CORE_WIDTH0 * (0.7 + 0.3 * burn) * widthMult,
		coreWidth1 = lerp(CORE_WIDTH1_SEA, CORE_WIDTH1_VACUUM, vac) * widthMult,
		glowWidth0 = GLOW_WIDTH0 * (0.7 + 0.3 * burn) * widthMult,
		glowWidth1 = lerp(GLOW_WIDTH1_SEA * burn, GLOW_WIDTH1_VACUUM * (0.6 + 0.4 * burn), vac) * widthMult,
		fade = VACUUM_FADE * vac,
		coreBrightness = lerp(CORE_BRIGHTNESS_SEA, CORE_BRIGHTNESS_VACUUM, vac),
		glowBrightness = lerp(GLOW_BRIGHTNESS_SEA, GLOW_BRIGHTNESS_VACUUM, vac),
		spreadDeg = lerp(SPREAD_SEA_DEG, SPREAD_VACUUM_DEG, vac) * (if solid then SOLID_SPREAD_MULT else 1),
		particleSpeed = lerp(PARTICLE_SPEED_MIN, PARTICLE_SPEED_MAX, t) * lerp(1, VACUUM_SPEED_MULT, vac),
		particleSize = (0.6 + 0.4 * burn) * lerp(1, VACUUM_PARTICLE_SIZE_MULT, vac) * (if solid
			then SOLID_PARTICLE_SIZE_MULT
			else 1),
		light = LIGHT_BRIGHTNESS_MAX * burn * lerp(1, VACUUM_LIGHT_MULT, vac),
	}
end

-- 0..1 smoke-trail density for a pressure ratio, log-scaled so it fades smoothly with altitude.
function EffectsMath.trailStrength(pressure: number): number
	if pressure <= TRAIL_PRESSURE_NONE then
		return 0
	end
	local t = (math.log(pressure) - math.log(TRAIL_PRESSURE_NONE))
		/ (math.log(TRAIL_PRESSURE_FULL) - math.log(TRAIL_PRESSURE_NONE))
	return EffectsMath.smoothstep(0, 1, t)
end

-- Trail particles are at rest in the air, so the trail behind the craft is airSpeed * lifetime long.
function EffectsMath.trailLifetime(airSpeed: number): number
	return math.clamp(TRAIL_MAX_LENGTH / math.max(airSpeed, 1), TRAIL_LIFETIME_MIN, TRAIL_LIFETIME_MAX)
end

-- Puffs are emitted airSpeed / rate studs apart; they must be bigger than that gap.
function EffectsMath.trailSize(airSpeed: number, rate: number, width: number): number
	local spacing = math.max(airSpeed, 0) / math.max(rate, 1)
	return math.clamp(math.max(width, spacing * TRAIL_OVERLAP), 0.5, TRAIL_SIZE_MAX)
end

-- 0..1 dust under a craft whose lowest burning nozzle is `height` m above the ground, at `thrustFraction` of the
-- reference thrust.
function EffectsMath.dustStrength(height: number, thrustFraction: number): number
	if height >= DUST_MAX_HEIGHT or thrustFraction <= 0 then
		return 0
	end
	local closeness = 1 - math.clamp(height / DUST_MAX_HEIGHT, 0, 1)
	return math.clamp(thrustFraction, 0, DUST_THRUST_CAP) / DUST_THRUST_CAP * closeness ^ DUST_HEIGHT_POWER
end

EffectsMath.DUST_MAX_HEIGHT = DUST_MAX_HEIGHT
EffectsMath.TRAIL_LIFETIME_MAX = TRAIL_LIFETIME_MAX -- CHANGED (Physics feel): exposed so the spec follows the tunable

-- 0..1 re-entry heating: rho * v^3 on a log scale, times a speed gate so a normal ascent does not glow.
function EffectsMath.heatFactor(density: number, speed: number): number
	if density <= 0 or speed <= HEAT_SPEED_MIN then
		return 0
	end
	local flux = density * speed * speed * speed
	if flux <= HEAT_FLUX_MIN then
		return 0
	end
	local fluxGate = math.clamp(math.log(flux / HEAT_FLUX_MIN) / math.log(HEAT_FLUX_FULL / HEAT_FLUX_MIN), 0, 1)
	return EffectsMath.smoothstep(HEAT_SPEED_MIN, HEAT_SPEED_FULL, speed) * fluxGate
end

-- 0..1 transonic vapour cone: a bump around Mach 1, only in thick air.
function EffectsMath.vaporFactor(speed: number, pressure: number): number
	local mach = speed / SPEED_OF_SOUND
	if mach <= VAPOR_MACH_START or mach >= VAPOR_MACH_END then
		return 0
	end
	local bump = if mach < VAPOR_MACH_PEAK
		then EffectsMath.smoothstep(VAPOR_MACH_START, VAPOR_MACH_PEAK, mach)
		else 1 - EffectsMath.smoothstep(VAPOR_MACH_PEAK, VAPOR_MACH_END, mach)
	return bump * EffectsMath.smoothstep(VAPOR_PRESSURE_MIN, VAPOR_PRESSURE_FULL, pressure)
end

--[[
	A ParticleEmitter gives each particle Speed (a random value in a range) along a random direction within
	SpreadAngle of its emission direction. To make particles move with a shared velocity `drift` (e.g. the air
	streaming past a flight pocket) plus a random velocity of up to `randomSpeed`, aim along the drift and open the
	cone just wide enough. Returns (unit direction, speed min, speed max, spread in degrees).
]]
function EffectsMath.driftEmission(drift: Vector3, randomSpeed: number): (Vector3, number, number, number)
	local d = drift.Magnitude
	local r = math.max(randomSpeed, 0)
	if d < 1e-3 then
		return Vector3.yAxis, 0.35 * r, r, 180
	end
	local direction = drift / d
	if r >= d then
		return direction, math.max(0.2 * r, 0), d + r, 180
	end
	return direction, d - r, d + r, math.deg(math.asin(r / d))
end

-- A CFrame at `position` whose UpVector is `up` (unit). The other axes are any stable perpendicular pair.
function EffectsMath.frameWithUp(position: Vector3, up: Vector3): CFrame
	local u = if up.Magnitude > 1e-6 then up.Unit else Vector3.yAxis
	local helper = if math.abs(u.Z) < 0.9 then Vector3.zAxis else Vector3.xAxis
	local right = u:Cross(helper).Unit
	local back = right:Cross(u) -- right-handed: X = right, Y = up, Z = back
	return CFrame.fromMatrix(position, right, u, back)
end

--[[
	For a box of half size `halfSize` and a unit `direction` (both in the box's axes): how far the box reaches
	along the direction from its centre (support distance), and the radius of its cross-section perpendicular to it.
]]
function EffectsMath.leadingExtent(halfSize: Vector3, direction: Vector3): (number, number)
	local d = if direction.Magnitude > 1e-6 then direction.Unit else Vector3.yAxis
	local reach = math.abs(d.X) * halfSize.X + math.abs(d.Y) * halfSize.Y + math.abs(d.Z) * halfSize.Z
	local radius = math.sqrt(math.max(halfSize:Dot(halfSize) - reach * reach, 0))
	return reach, math.max(radius, 0.5)
end

-- Particle-rate multiplier for UserGameSettings.SavedQualityLevel.Value (0 = Automatic, 1..10).
function EffectsMath.qualityScale(level: number): number
	if level <= 0 then
		return QUALITY_SCALE_AUTOMATIC
	end
	return lerp(QUALITY_SCALE_MIN, 1, math.clamp((level - 1) / 9, 0, 1))
end

-- Explosion size factor for a block of the given size (studs): 1 for one 4-stud block.
function EffectsMath.explosionScale(blockSize: Vector3): number
	return math.clamp(blockSize.Magnitude / EXPLOSION_REFERENCE, EXPLOSION_SCALE_MIN, EXPLOSION_SCALE_MAX)
end

-- Ease-out progress (0..1) of a one-shot effect `age` seconds into `duration`.
function EffectsMath.fade(age: number, duration: number): number
	local t = math.clamp(age / math.max(duration, 1e-3), 0, 1)
	return 1 - (1 - t) * (1 - t)
end

return table.freeze(EffectsMath)
