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
	  explosionScale(blockSize)               size factor of a block's explosion (1 = one 4-stud block)
	  fade(age, duration)                     0..1 ease-out progress of a one-shot effect

	CHANGED (Effects v2): Steamy: "the plasma needs to look better ... should go with graphics quality". The old
	qualityScale(SavedQualityLevel) is gone: Render/Quality is the one tier every client layer follows.
	  budget(tier)                            per-tier caps (emitters, active effects, lights) for Render/Effects
	  worstCaseEmitters(budget)               emitters Effects can have alive at once under a budget (plumes aside)
	  plumeLoad(budget, engines)              CHANGED (Night review): worst-case beams, emitters and PointLights the
	                                          plumes of `engines` burning engines use (budget.plumes are drawn in full,
	                                          the rest as core + glow beams only)
	  plasma(heat)                            re-entry intensity curves (shell opacity, flame length, streaks, embers)
	  heatColor(heat, t)                      plasma colour ramp: t = 0 at the shock front, 1 at the flame tails
	  heatSoak(current, target, dt)           part heat glow: fast to heat up, slow to cool down
	  flicker(time, seed, amplitude)          deterministic 1 +- amplitude wobble (no Random, no allocation)
	  machDiamondKeys(count, strength)        transparency keypoints of a shock-diamond beam (<= 20 keypoints)
	  plumeTint(vacuum, solid)                engine flame colours: orange at sea level, pale blue-white in vacuum
	  airCoupling(pressure)                   0..1 how much loose smoke / debris is carried by the air (vs momentum)
	  blastScale(extent, count)               size factor of a crash's main blast from the wrecked span and blocks
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
-- CHANGED (Effects v2): the graphics-quality tunables went with qualityScale (Render/Quality + BUDGETS below)
-- Explosions
local EXPLOSION_REFERENCE = 4 * math.sqrt(3) -- diagonal of one 4-stud block
local EXPLOSION_SCALE_MIN = 0.6
local EXPLOSION_SCALE_MAX = 3
-- CHANGED (Effects v2): a crash's main blast grows with the wrecked span and the number of blocks lost
local BLAST_COUNT_GAIN = 0.25 -- x ln(blocks)
local BLAST_SCALE_MAX = 4.5
-- CHANGED (Effects v2): re-entry plasma curves (heat = EffectsMath.heatFactor, 0..1)
local PLASMA_SHELL_OPACITY = 0.7 -- inner shock-layer shell at full heat
local PLASMA_GLOW_OPACITY = 0.4 -- outer (edge-tinted) shell at full heat
local PLASMA_SHELL_DEPTH0 = 0.35 -- shell bulge ahead of the craft, x leading radius, at the first glow
local PLASMA_SHELL_DEPTH1 = 0.8 -- ... at full heat
local PLASMA_TONGUE_LENGTH0 = 1 -- flame tongue length beyond the craft, x leading radius, at the first glow
local PLASMA_TONGUE_LENGTH1 = 5 -- ... at full heat
local PLASMA_TONGUE_WIDTH0 = 0.3 -- tongue root width, x leading radius
local PLASMA_TONGUE_WIDTH1 = 0.7
local PLASMA_STREAK_START, PLASMA_STREAK_FULL = 0.12, 0.7 -- heat band where streaks come in
local PLASMA_EMBER_START, PLASMA_EMBER_FULL = 0.3, 0.95 -- heat band where embers peel off
-- Plasma colour ramp: heat -> colour at the shock front, mid flame and flame edge / tail ({heat, R, G, B} 0..255)
local HEAT_FRONT_KEYS = {
	{ 0, 215, 60, 25 },
	{ 0.35, 255, 125, 45 },
	{ 0.65, 255, 195, 120 },
	{ 1, 255, 250, 242 }, -- white hot
}
local HEAT_MID_KEYS = {
	{ 0, 200, 55, 20 },
	{ 0.5, 255, 120, 40 },
	{ 1, 255, 165, 85 },
}
local HEAT_EDGE_KEYS = {
	{ 0, 170, 40, 20 },
	{ 0.45, 255, 85, 50 },
	{ 0.8, 255, 105, 165 }, -- pinkish
	{ 1, 185, 140, 255 }, -- blue-violet tint at the hottest
}
local HEAT_MID_AT = 0.45 -- t of the mid colour along the flame
-- Part heat glow: time constants (s)
local HEAT_SOAK_RISE_S = 1.2
local HEAT_SOAK_COOL_S = 5
-- Shock diamonds
local DIAMOND_MAX = 6 -- 2 + 3 * 6 = 20 keypoints, the NumberSequence limit
local DIAMOND_HALF_WIDTH = 0.33 -- x spacing, half the bright band
local DIAMOND_FADE = 0.12 -- each diamond downstream is this much fainter
local DIAMOND_BETWEEN = 0.15 -- opacity between diamonds (x strength)
-- Engine flame colours ({R, G, B} 0..255): core tip, glow start, glow end; sea level and vacuum; liquid and solid
local PLUME_LIQUID_SEA = { { 255, 150, 50 }, { 255, 175, 75 }, { 255, 95, 30 } }
local PLUME_LIQUID_VACUUM = { { 220, 230, 255 }, { 255, 220, 200 }, { 165, 175, 255 } }
local PLUME_SOLID_SEA = { { 255, 160, 45 }, { 255, 160, 55 }, { 235, 80, 20 } }
local PLUME_SOLID_VACUUM = { { 255, 200, 130 }, { 255, 200, 150 }, { 210, 160, 175 } }
-- Loose smoke / debris: pressure ratios between which the air takes over from the craft's momentum
local AIR_COUPLING_START = 0.0005 -- ~8 km on Earth: smoke keeps the craft's velocity
local AIR_COUPLING_FULL = 0.05 -- ~3.3 km: smoke stops in the air at once
-- Per-tier budgets (Render/Quality tier). Particle RATES are also multiplied by Quality.scale().
-- Phones are at most Medium, and Medium has no PointLights.
local BUDGETS = {
	Low = {
		trails = 2, -- smoke trails alive at once
		trailLifetimeMax = 4, -- s; shorter smoke columns (fewer big puffs to overdraw)
		dust = 1, -- launch-dust rings
		dustEmitters = 3, -- emitters per ring
		aero = 1, -- crafts with re-entry / vapour effects at once
		shellGlow = false, -- second, edge-tinted plasma shell
		tongues = 3, -- plasma flame tongues per heated craft
		tongueLength = 0.55, -- x flame length (short flames)
		streaks = false, -- plasma streak particles
		embers = false, -- embers peeling off
		heatTint = 0, -- leading blocks given a heat glow per craft
		vaporCollar = false, -- vapour collar particles (the cone beam is always there)
		bursts = 6, -- one-shot burst pool (smoke + fire + sparks each)
		fireballs = 3,
		debris = 8, -- glowing debris bits alive at once
		debrisPerExplosion = 2,
		explosionsPerEvent = 2,
		classicExplosion = false,
		plumeHalo = false, -- third, widest flame layer
		machDiamonds = false,
		plumeFlicker = false,
		-- CHANGED (Night review): engines drawn in full per frame (emitter, halo, diamonds, flicker, light); the rest
		-- get a cheap plume (core + glow beams only), and Ignite / Cutoff bursts handled per frame
		plumes = 6,
		plumeEvents = 2,
		plumeLights = 0, -- PointLights
		heatLights = 0,
		flashLights = 0,
	},
	Medium = {
		trails = 4,
		trailLifetimeMax = 6,
		dust = 2,
		dustEmitters = 4,
		aero = 2,
		shellGlow = true,
		tongues = 5,
		tongueLength = 0.8,
		streaks = true,
		embers = false,
		heatTint = 0,
		vaporCollar = true,
		bursts = 10,
		fireballs = 6,
		debris = 20,
		debrisPerExplosion = 4,
		explosionsPerEvent = 4,
		classicExplosion = false,
		plumeHalo = true,
		machDiamonds = true,
		plumeFlicker = true,
		plumes = 12, -- CHANGED (Night review)
		plumeEvents = 4,
		plumeLights = 0,
		heatLights = 0,
		flashLights = 0,
	},
	High = {
		trails = 6,
		trailLifetimeMax = 8,
		dust = 4,
		dustEmitters = 6,
		aero = 4,
		shellGlow = true,
		tongues = 8,
		tongueLength = 1,
		streaks = true,
		embers = true,
		heatTint = 4,
		vaporCollar = true,
		bursts = 16,
		fireballs = 10,
		debris = 40,
		debrisPerExplosion = 6,
		explosionsPerEvent = 6,
		classicExplosion = true,
		plumeHalo = true,
		machDiamonds = true,
		plumeFlicker = true,
		plumes = 24, -- CHANGED (Night review)
		plumeEvents = 8,
		plumeLights = 4,
		heatLights = 2,
		flashLights = 4,
	},
}
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

-- CHANGED (Effects v2)
export type Tier = "Low" | "Medium" | "High"

export type Budget = {
	trails: number,
	trailLifetimeMax: number,
	dust: number,
	dustEmitters: number,
	aero: number,
	shellGlow: boolean,
	tongues: number,
	tongueLength: number,
	streaks: boolean,
	embers: boolean,
	heatTint: number,
	vaporCollar: boolean,
	bursts: number,
	fireballs: number,
	debris: number,
	debrisPerExplosion: number,
	explosionsPerEvent: number,
	classicExplosion: boolean,
	plumeHalo: boolean,
	machDiamonds: boolean,
	plumeFlicker: boolean,
	plumes: number, -- CHANGED (Night review)
	plumeEvents: number, -- CHANGED (Night review)
	plumeLights: number,
	heatLights: number,
	flashLights: number,
}

export type PlasmaShape = {
	shellOpacity: number, -- 0..1 inner shock-layer shell
	glowOpacity: number, -- 0..1 outer, edge-tinted shell
	shellDepth: number, -- x leading radius: how far the shell bulges ahead
	tongueLength: number, -- x leading radius: how far the flames stream beyond the craft
	tongueWidth: number, -- x leading radius: flame root width
	streakRate: number, -- 0..1 of the streak rate
	emberRate: number, -- 0..1 of the ember rate
	light: number, -- 0..1 of the heat light
}

local EffectsMath = {}

local frozenBudgets: { [string]: Budget } = {}
for _, tier in { "Low", "Medium", "High" } do
	frozenBudgets[tier] = table.freeze((BUDGETS :: any)[tier])
end

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
-- CHANGED (Effects v2): optional maxLifetime (the tier's Budget.trailLifetimeMax) lowers the TRAIL_LIFETIME_MAX cap.
function EffectsMath.trailLifetime(airSpeed: number, maxLifetime: number?): number
	local cap = math.clamp(maxLifetime or TRAIL_LIFETIME_MAX, TRAIL_LIFETIME_MIN, TRAIL_LIFETIME_MAX)
	return math.clamp(TRAIL_MAX_LENGTH / math.max(airSpeed, 1), TRAIL_LIFETIME_MIN, cap)
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
-- CHANGED (Solar system): `speedScale` (the body's Atmosphere.HeatSpeedScale, default 1) scales the speed gate:
-- Mars' entries are slower (its orbit speed is 0.44 x Earth's), so its thin air still glows a little
function EffectsMath.heatFactor(density: number, speed: number, speedScale: number?): number
	local k = speedScale or 1
	if density <= 0 or speed <= HEAT_SPEED_MIN * k then
		return 0
	end
	local flux = density * speed * speed * speed
	if flux <= HEAT_FLUX_MIN then
		return 0
	end
	local fluxGate = math.clamp(math.log(flux / HEAT_FLUX_MIN) / math.log(HEAT_FLUX_FULL / HEAT_FLUX_MIN), 0, 1)
	return EffectsMath.smoothstep(HEAT_SPEED_MIN * k, HEAT_SPEED_FULL * k, speed) * fluxGate
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

-- Explosion size factor for a block of the given size (studs): 1 for one 4-stud block.
function EffectsMath.explosionScale(blockSize: Vector3): number
	return math.clamp(blockSize.Magnitude / EXPLOSION_REFERENCE, EXPLOSION_SCALE_MIN, EXPLOSION_SCALE_MAX)
end

-- Ease-out progress (0..1) of a one-shot effect `age` seconds into `duration`.
function EffectsMath.fade(age: number, duration: number): number
	local t = math.clamp(age / math.max(duration, 1e-3), 0, 1)
	return 1 - (1 - t) * (1 - t)
end

--============================================================================
-- CHANGED (Effects v2): budgets, plasma, colours and helpers
--============================================================================

-- The caps for a Render/Quality tier (an unknown tier gets Low). Frozen.
function EffectsMath.budget(tier: string): Budget
	return frozenBudgets[tier] or frozenBudgets.Low
end

-- Most ParticleEmitters Effects keeps (enabled or bursting) under a budget, engine plumes aside (one per lit engine;
-- designs decide that). Per heated craft: shell glow puffs, streaks, embers and the vapour collar.
function EffectsMath.worstCaseEmitters(budget: Budget): number
	local perAero = 1
		+ (if budget.streaks then 1 else 0)
		+ (if budget.embers then 1 else 0)
		+ (if budget.vaporCollar then 1 else 0)
	return budget.trails + budget.dust * budget.dustEmitters + budget.aero * perAero + budget.bursts * 3
end

--[[
	CHANGED (Night review): worst-case plume load for `engines` burning engines under a budget (Render/Plumes): every
	engine has a core and a glow beam; only the first budget.plumes per frame are drawn in full (+ particle emitter,
	halo beam, shock-diamond beam, PointLight while the light budget lasts). Returns beams, emitters, lights.
]]
function EffectsMath.plumeLoad(budget: Budget, engines: number): (number, number, number)
	local count = math.max(math.floor(engines), 0)
	local full = math.min(count, budget.plumes)
	local extraBeams = (if budget.plumeHalo then 1 else 0) + (if budget.machDiamonds then 1 else 0)
	return 2 * count + full * extraBeams, full, math.min(full, budget.plumeLights)
end

function EffectsMath.plasma(heat: number): PlasmaShape
	local h = math.clamp(heat, 0, 1)
	return {
		shellOpacity = PLASMA_SHELL_OPACITY * EffectsMath.smoothstep(0, 0.6, h),
		glowOpacity = PLASMA_GLOW_OPACITY * EffectsMath.smoothstep(0.1, 0.9, h),
		shellDepth = lerp(PLASMA_SHELL_DEPTH0, PLASMA_SHELL_DEPTH1, h),
		tongueLength = lerp(PLASMA_TONGUE_LENGTH0, PLASMA_TONGUE_LENGTH1, h ^ 0.8),
		tongueWidth = lerp(PLASMA_TONGUE_WIDTH0, PLASMA_TONGUE_WIDTH1, math.sqrt(h)),
		streakRate = EffectsMath.smoothstep(PLASMA_STREAK_START, PLASMA_STREAK_FULL, h),
		emberRate = EffectsMath.smoothstep(PLASMA_EMBER_START, PLASMA_EMBER_FULL, h),
		light = math.sqrt(h),
	}
end

-- Piecewise-linear lookup in { {x, R, G, B} } keys (x ascending, RGB 0..255).
local function rampColor(keys: { { number } }, x: number): Color3
	local first = keys[1]
	if x <= first[1] then
		return Color3.new(first[2] / 255, first[3] / 255, first[4] / 255)
	end
	for index = 2, #keys do
		local b = keys[index]
		if x <= b[1] then
			local a = keys[index - 1]
			local t = (x - a[1]) / math.max(b[1] - a[1], 1e-9)
			return Color3.new(lerp(a[2], b[2], t) / 255, lerp(a[3], b[3], t) / 255, lerp(a[4], b[4], t) / 255)
		end
	end
	local last = keys[#keys]
	return Color3.new(last[2] / 255, last[3] / 255, last[4] / 255)
end

local function mix(a: Color3, b: Color3, t: number): Color3
	return Color3.new(lerp(a.R, b.R, t), lerp(a.G, b.G, t), lerp(a.B, b.B, t))
end

--[[
	Re-entry plasma colour at heat 0..1 and position t along the flame (0 = the shock front on the craft's windward
	side, 1 = the far tips of the flames): dull orange-red when it first glows; at the hottest a white-hot front
	with pinkish / blue-violet edges.
]]
function EffectsMath.heatColor(heat: number, t: number): Color3
	local h = math.clamp(heat, 0, 1)
	local x = math.clamp(t, 0, 1)
	local front = rampColor(HEAT_FRONT_KEYS, h)
	local mid = rampColor(HEAT_MID_KEYS, h)
	if x <= HEAT_MID_AT then
		return mix(front, mid, x / HEAT_MID_AT)
	end
	return mix(mid, rampColor(HEAT_EDGE_KEYS, h), (x - HEAT_MID_AT) / (1 - HEAT_MID_AT))
end

-- Part heat glow 0..1 following the heat: heats up in about HEAT_SOAK_RISE_S, cools in about HEAT_SOAK_COOL_S.
function EffectsMath.heatSoak(current: number, target: number, dt: number): number
	local goal = math.clamp(target, 0, 1)
	local tau = if goal > current then HEAT_SOAK_RISE_S else HEAT_SOAK_COOL_S
	local alpha = 1 - math.exp(-math.max(dt, 0) / tau)
	return math.clamp(current + (goal - current) * alpha, 0, 1)
end

-- A smooth, deterministic flicker in [1 - amplitude, 1 + amplitude] (three incommensurate sines).
function EffectsMath.flicker(time: number, seed: number, amplitude: number): number
	local wave = 0.5 * math.sin(13.1 * time + seed)
		+ 0.3 * math.sin(29.7 * time + 2.3 * seed)
		+ 0.2 * math.sin(53.3 * time + 4.1 * seed)
	return 1 + amplitude * wave
end

--[[
	Transparency keypoints { {time, transparency} } for a beam that shows `count` bright shock diamonds along its
	length, each fainter than the one before, transparent at both ends. strength 0..1 scales the opacity. At most
	20 keypoints (count is clamped to 1..DIAMOND_MAX), times strictly increasing.
]]
function EffectsMath.machDiamondKeys(count: number, strength: number): { { number } }
	local n = math.clamp(math.floor(count), 1, DIAMOND_MAX)
	local s = math.clamp(strength, 0, 1)
	local spacing = 1 / n
	local half = DIAMOND_HALF_WIDTH * spacing
	local between = 1 - s * DIAMOND_BETWEEN
	local keys: { { number } } = { { 0, 1 } }
	for index = 1, n do
		local center = (index - 0.5) * spacing
		local peak = 1 - s * math.max(1 - DIAMOND_FADE * (index - 1), 0)
		table.insert(keys, { center - half, between })
		table.insert(keys, { center, peak })
		table.insert(keys, { center + half, between })
	end
	table.insert(keys, { 1, 1 })
	return keys
end

-- Engine flame colours for a vacuum factor (EffectsMath.vacuumFactor): core tip, glow start, glow end.
function EffectsMath.plumeTint(vacuum: number, solid: boolean): (Color3, Color3, Color3)
	local v = math.clamp(vacuum, 0, 1)
	local sea = if solid then PLUME_SOLID_SEA else PLUME_LIQUID_SEA
	local space = if solid then PLUME_SOLID_VACUUM else PLUME_LIQUID_VACUUM
	local function at(index: number): Color3
		local a, b = sea[index], space[index]
		return Color3.new(lerp(a[1], b[1], v) / 255, lerp(a[2], b[2], v) / 255, lerp(a[3], b[3], v) / 255)
	end
	return at(1), at(2), at(3)
end

-- 0..1: how much loose smoke and debris move with the air (1) rather than keep the craft's velocity (0, vacuum).
function EffectsMath.airCoupling(pressure: number): number
	return EffectsMath.smoothstep(AIR_COUPLING_START, AIR_COUPLING_FULL, pressure)
end

-- Size factor of a crash's main blast: `extent` = diagonal (studs) of the wrecked blocks, `count` = blocks lost.
function EffectsMath.blastScale(extent: number, count: number): number
	local base = math.sqrt(math.max(extent, 0) / EXPLOSION_REFERENCE)
	local k = base * (1 + BLAST_COUNT_GAIN * math.log(math.max(count, 1)))
	return math.clamp(k, EXPLOSION_SCALE_MIN, BLAST_SCALE_MAX)
end

return table.freeze(EffectsMath)
