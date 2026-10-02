--!strict
--!native
--[[
	Relief (CHANGED (Phase 8): surface terrain)
	The deterministic shape of each body's ground: metres above its reference radius (Bodies Radius) at a unit
	direction (x, y, z) from the body centre (body axes = universe axes; planets do not rotate). Pure module.
	SurfaceHeight samples it on a fixed lattice and caches the nodes; that lattice is the ground everything collides
	with and the terrain renderer draws, so this function only runs once per lattice node.

	Earth, from Biome.reliefFields (the coast-level elevation ee and the mountain mask Biome colours with):
	  * ocean (ee <= 0): exactly sea level (0 m) and flat
	  * land: LAND_SCALE * ee (a gentle rise from the coast), rolling hills (fBm, ~1.2 km wavelength) and small
	    bumps faded in over the first COAST_FADE of elevation (beaches stay low), and mountains where the mountain mask
	    is high (Biome's rock and snowy peaks sit on them), with ridged detail; never below LAND_FLOOR * ee
	  * the launch site: inside SITE_FLAT_RADIUS (distance in the site's tangent plane at lat 0 / lon 0) the ground
	    IS that plane (radius R / x along the direction), which is the base pocket's y = 0, so the site, pads and plots
	    stand exactly where they always did; a smoothstep blend reaches the relief at SITE_BLEND_RADIUS
	Mun, from Biome.reliefFields (mare, highland variation) and Biome.craterSum (the craters Biome paints):
	  * maria sink, highlands roll, and every crater gets a bowl, a raised rim and an ejecta apron
	  * clamped to [MOON_MIN, MOON_MAX]: the 500 m rails floor (Rails.minAltitude) stays above every peak
	Other bodies: 0.
	CHANGED (Terrain polish): gentler ground: longer, lower hills, smaller bumps, and mountains with rounded summits
	and feet (a second smoothstep over Biome's mask, whose own ridges are now smooth too) and soft-crested detail
	(smooth |n| ridged noise) instead of knife-edged ridges. Biome keeps a mountain-free plain within ~11 km of the
	site, so from the base nothing beyond ~4 km rises over the 60 km planet's horizon.
	CHANGED (Planet detail): Earth's lakes (Biome.reliefFields' lake value, from Sim/BiomeDetail) are water at the
	land's base level (LAND_SCALE x the smooth continent elevation, LAKE_SINK lower, never below LAKE_MIN_LEVEL): no
	hills or bumps, only the continent's own gentle rise (median slope ~0.5%, at most ~2.5%), with a bank blending the
	ground down to it; the mid-scale coast wiggle comes in through ee as before. Both stay
	out of the launch site's plain (BiomeDetail.featureWeight), so the site and the ground around it are unchanged.

	API:
		Relief.height(bodyId, x, y, z): number    metres above the body radius
		Relief.bounds(bodyId): (number, number)   lowest / highest possible height (m)
		Relief.heightFn(bodyId)                   CHANGED (Planet detail): (x, y, z) -> Relief.height(bodyId, ...)
		Relief.siteWeight(x, y, z): number        Earth: 1 on the launch-site plane, 0 outside the blend
		Relief.SITE_FLAT_RADIUS, Relief.SITE_BLEND_RADIUS (m)
]]

local Biome = require(script.Parent.Biome)
local BiomeDetail = require(script.Parent.BiomeDetail) -- CHANGED (Planet detail)
local Bodies = require(script.Parent.Parent.Config.Bodies)

--============================================================================
-- Tunables
--============================================================================
-- Noise (Luau's math.noise, the same C code in Roblox and Lune)
local NOISE_SCALE = 1.4 -- matches Biome's spread of math.noise
local LACUNARITY = 2.03
local OCTAVE_SHIFT = 13.7

-- Earth (frequencies are per unit of the unit sphere: wavelength = 60 km / frequency)
local LAND_SCALE = 260 -- m per unit of coast-level elevation (ee 0.13 at the site -> ~34 m)
local LAND_FLOOR = 0.3 -- land never dips below this fraction of LAND_SCALE * ee (no dry pits below the sea)
local COAST_FADE = 0.12 -- elevation over which hills and bumps fade in from the coast
-- CHANGED (Terrain polish): gentler, smoother ground (Steamy: "the terrain looks bad"): longer, lower hills with
-- softer octaves, smaller bumps, mountains with rounded summits and feet (a second smoothstep over the mask) and
-- soft-crested detail (smooth |n|) instead of knife-edged ridged noise
local HILL_FREQ = 40 -- ~1.5 km rolling hills (was 50)
local HILL_OCTAVES = 3
local HILL_GAIN = 0.4 -- was 0.45
local HILL_AMP = 45 -- m (was 55)
local BUMP_FREQ = 170 -- ~350 m bumps (was 190)
local BUMP_AMP = 3.5 -- m (was 6)
local MOUNT_M0 = 0.3 -- mountain mask where mountains start rising (Biome rock starts at 0.52)
local MOUNT_M1 = 0.88 -- was 0.95: the crests of the mask sit on the rounded top of the curve
local MOUNT_POWER = 1.3 -- was 1.5
local MOUNT_AMP = 1150 -- m at the top of the mask (was 1250)
local MOUNT_DETAIL_FREQ = 45 -- ~1.3 km soft ridges on the mountains (was 70, sharp)
local MOUNT_DETAIL_OCTAVES = 2
local MOUNT_DETAIL = 0.14 -- share of the mountain height that is ridged detail
local MOUNT_DETAIL_SOFT = 0.22 -- smooth |n| width of the detail crests (0 = knife edge)
local EARTH_MAX = 1800 -- m, hard cap
-- CHANGED (Planet detail): lakes
local LAKE_SINK = 12 -- m the water lies below the land's base level
local LAKE_MIN_LEVEL = 2 -- m above sea level at least (lakes never reach down to the sea)

-- Earth launch site (the plane of the base pocket)
local SITE_FLAT_RADIUS = 900 -- m in the site's tangent plane: exactly the plane inside (the site plate is +-420)
local SITE_BLEND_RADIUS = 2600 -- m: pure relief outside

-- Mun (frequencies per unit sphere: wavelength = 15 km / frequency)
local MARE_DEPTH = 150 -- m, maria sit this much lower
local HIGHLAND_AMP = 70 -- m, highland variation
local ROLL_FREQ = 15 -- ~1 km rolling ground
local ROLL_OCTAVES = 3
local ROLL_AMP = 22 -- m
local MARE_CALM = 0.6 -- maria roll this much less
-- craters per Biome scale (index 1 = ray craters, 2.. = cell scales 1..3, largest first)
local CRATER_DEPTH_FRAC = { 0.18, 0.12, 0.17, 0.2 } -- bowl depth / rim radius
local CRATER_DEPTH_MAX = { 160, 190, 130, 60 } -- m
local CRATER_RIM_FRAC = { 0.05, 0.03, 0.04, 0.05 } -- rim height / rim radius
local CRATER_RIM_MAX = { 45, 60, 30, 14 } -- m
local CRATER_POWER = { 2.5, 3, 2.5, 2 } -- bowl shape (higher = flatter floor, steeper walls)
local MOON_MIN = -600 -- m
local MOON_MAX = 320 -- m (Rails.minAltitude is 500 m on the Mun)
--============================================================================

local Relief = {}

local HOMEWORLD = Bodies.HOMEWORLD
local MOON = Bodies.MOON
local EARTH_RADIUS = Bodies.get(HOMEWORLD).Radius
local MOON_RADIUS = Bodies.get(MOON).Radius
local CRATER_EXTENT = Biome.CRATER_EXTENT
local LAKE_BANK = BiomeDetail.LAKE_BANK -- CHANGED (Planet detail)

local mathNoise = math.noise

local function smoothstep(e0: number, e1: number, v: number): number
	local t = (v - e0) / (e1 - e0)
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end

-- Fractal sum normalised to the noise range (about -1..1).
local function fbm(x: number, y: number, z: number, octaves: number, gain: number): number
	local sum, amp, norm = 0, 1, 0
	for _ = 1, octaves do
		sum += amp * mathNoise(x, y, z) * NOISE_SCALE
		norm += amp
		x = x * LACUNARITY + OCTAVE_SHIFT
		y = y * LACUNARITY + OCTAVE_SHIFT
		z = z * LACUNARITY + OCTAVE_SHIFT
		amp *= gain
	end
	return sum / norm
end

-- Ridged fractal in 0..1 (1 on the ridge lines).
-- CHANGED (Terrain polish): soft crests: |n| is smoothed to sqrt(n^2 + soft^2) - soft (soft 0: the old knife edge)
local function ridged(x: number, y: number, z: number, octaves: number, soft: number): number
	local sum, amp, norm = 0, 1, 0
	for _ = 1, octaves do
		local v = mathNoise(x, y, z) * NOISE_SCALE
		local n = 1 - (math.sqrt(v * v + soft * soft) - soft)
		if n < 0 then
			n = 0
		end
		sum += amp * n * n
		norm += amp
		x = x * LACUNARITY + OCTAVE_SHIFT
		y = y * LACUNARITY + OCTAVE_SHIFT
		z = z * LACUNARITY + OCTAVE_SHIFT
		amp *= 0.5
	end
	return sum / norm
end

--============================================================================
-- Earth
--============================================================================
local function earthRelief(x: number, y: number, z: number): number
	local ee, mountain, lake, e = Biome.reliefFields(HOMEWORLD, x, y, z)
	if ee <= 0 then
		return 0
	end
	local base = LAND_SCALE * ee
	local fade = smoothstep(0, COAST_FADE, ee)
	local h = base
	if fade > 0 then
		local f = HILL_FREQ
		h += HILL_AMP * fade * fbm(x * f + 3.7, y * f + 9.2, z * f + 1.4, HILL_OCTAVES, HILL_GAIN)
		f = BUMP_FREQ
		h += BUMP_AMP * fade * mathNoise(x * f + 7.1, y * f + 2.6, z * f + 5.3) * NOISE_SCALE
	end
	local m = smoothstep(MOUNT_M0, MOUNT_M1, mountain)
	if m > 0 then
		m = m * m * (3 - 2 * m) -- CHANGED (Terrain polish): rounded summits and feet
		local f = MOUNT_DETAIL_FREQ
		local ridge = ridged(x * f + 4.4, y * f + 8.1, z * f + 2.2, MOUNT_DETAIL_OCTAVES, MOUNT_DETAIL_SOFT)
		h += MOUNT_AMP * m ^ MOUNT_POWER * (1 - MOUNT_DETAIL + MOUNT_DETAIL * 2 * ridge)
	end
	local floor = LAND_FLOOR * base
	if h < floor then
		h = floor
	elseif h > EARTH_MAX then
		h = EARTH_MAX
	end
	-- CHANGED (Planet detail): a lake is flat at its level where the lake value is >= 0 (Biome paints it there); the
	-- bank (value -LAKE_BANK .. 0) blends the ground down (or up) to that level
	if lake > -LAKE_BANK then
		local level = math.max(LAKE_MIN_LEVEL, LAND_SCALE * e - LAKE_SINK)
		h += (level - h) * smoothstep(-LAKE_BANK, 0, lake)
	end
	return h
end

-- Launch-site plane weight (1 inside SITE_FLAT_RADIUS) and the plane's height above the sphere along (x, y, z).
local function siteWeight(x: number, y: number, z: number): (number, number)
	if x <= 0 then
		return 0, 0
	end
	local rho = EARTH_RADIUS * math.sqrt(y * y + z * z) / x -- distance from the site in its tangent plane
	if rho >= SITE_BLEND_RADIUS then
		return 0, 0
	end
	local plane = EARTH_RADIUS / x - EARTH_RADIUS
	if rho <= SITE_FLAT_RADIUS then
		return 1, plane
	end
	return smoothstep(SITE_BLEND_RADIUS, SITE_FLAT_RADIUS, rho), plane
end

--============================================================================
-- Mun
--============================================================================

-- Height (m) a crater adds at t = distance / rim radius; scale 0 = ray crater, 1..3 = cell scales.
local function craterProfile(t: number, radius: number, scale: number): number
	local s = scale + 1
	local rim = radius * MOON_RADIUS
	local depth = math.min(CRATER_DEPTH_FRAC[s] * rim, CRATER_DEPTH_MAX[s])
	local rimHeight = math.min(CRATER_RIM_FRAC[s] * rim, CRATER_RIM_MAX[s])
	if t < 1 then
		return -depth + (depth + rimHeight) * t ^ CRATER_POWER[s]
	end
	local k = (CRATER_EXTENT - t) / (CRATER_EXTENT - 1)
	return rimHeight * k * k
end

local function moonRelief(x: number, y: number, z: number): number
	local mare, hv = Biome.reliefFields(MOON, x, y, z)
	local h = -MARE_DEPTH * mare + HIGHLAND_AMP * hv * (1 - mare)
	local f = ROLL_FREQ
	h += ROLL_AMP * (1 - MARE_CALM * mare) * fbm(x * f + 6.2, y * f + 1.9, z * f + 8.4, ROLL_OCTAVES, 0.5)
	h += Biome.craterSum(x, y, z, craterProfile)
	if h < MOON_MIN then
		return MOON_MIN
	elseif h > MOON_MAX then
		return MOON_MAX
	end
	return h
end

--============================================================================
-- API
--============================================================================

-- Height (m) above the body's radius at unit direction (x, y, z).
function Relief.height(bodyId: number, x: number, y: number, z: number): number
	if bodyId == HOMEWORLD then
		local w, plane = siteWeight(x, y, z)
		if w >= 1 then
			return plane
		end
		local h = earthRelief(x, y, z)
		if w > 0 then
			h += (plane - h) * w
		end
		return h
	elseif bodyId == MOON then
		return moonRelief(x, y, z)
	end
	return 0
end

-- CHANGED (Planet detail): Relief.height for one body as a plain (x, y, z) -> m function (cached per body), for
-- painters that bake the relief shade (Biome.beginPatch's height).
local heightFns: { [number]: (number, number, number) -> number } = {}
function Relief.heightFn(bodyId: number): (number, number, number) -> number
	local fn = heightFns[bodyId]
	if fn == nil then
		local created = function(x: number, y: number, z: number): number
			return Relief.height(bodyId, x, y, z)
		end
		heightFns[bodyId] = created
		return created
	end
	return fn
end

-- Lowest and highest possible height (m) of a body's ground.
function Relief.bounds(bodyId: number): (number, number)
	if bodyId == HOMEWORLD then
		-- the site plane rises to (sec(angle) - 1) R at the blend edge: far below the mountains
		return 0, EARTH_MAX
	elseif bodyId == MOON then
		return MOON_MIN, MOON_MAX
	end
	return 0, 0
end

-- Earth: 1 on the launch-site plane, falling to 0 at SITE_BLEND_RADIUS.
function Relief.siteWeight(x: number, y: number, z: number): number
	local w = siteWeight(x, y, z)
	return w
end

Relief.SITE_FLAT_RADIUS = SITE_FLAT_RADIUS
Relief.SITE_BLEND_RADIUS = SITE_BLEND_RADIUS

return table.freeze(Relief)
