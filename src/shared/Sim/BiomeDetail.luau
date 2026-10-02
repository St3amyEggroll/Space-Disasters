--!strict
--!native
--[[
	BiomeDetail (CHANGED (Planet detail): Steamy: "when i am in orbit i feel like the planet is a small little planet
	by the level of detail on it")
	Earth's small-scale features, at the 0.1 - 5 km scales that read as size from 10 - 100 km up, and the relief
	shade baked into the scaled-space planet textures. Pure and deterministic (Luau's math.noise, the same C code in
	Roblox and Lune). Biome calls these from its Earth shader and its relief hook, so the planet texture, the ground
	tile colours (Biome.sample) and the physics ground (Sim/Relief) all agree.

	Physics features (Relief reads them through Biome.reliefFields, so the ground has the same shape everywhere):
	  * coastOffset: a mid-scale (2 - 4 km) wiggle of the coast-level elevation near coasts only: bays, headlands
	    and small offshore islands
	  * lakeValue: small lakes (0.3 - 3 km) on wet, low, mountain-free land, most in the cool wet north; where the
	    value is >= 0 Relief lays the water at the land's smooth base level (a basin without hills or bumps)
	Colour-only features (they change Biome's colour / kind, never the ground's shape):
	  * river: thin meandering river lines on wet lowland (kind "Lake": water, no props), detail levels >= 2
	  * farmland: a patchwork of ~600 m fields in temperate farm regions
	  * mottle: 1 - 3 km patchiness for forests (clearings), grass (lush / dry) and deserts
	Every feature fades out near the launch site (featureWeight: 0 within FEATURE_INNER_M, 1 beyond
	FEATURE_OUTER_M), so the base's grassland plain, its coast to the east and the calm ring (D45) stay as they were.

	Relief shade (texture bake, no per-frame cost): BiomeDetail.reliefShade(height, x, y, z, eps, radius) samples
	the ground height at the point and four points `eps` (rad) away along the local east / north axes (a frame that
	depends on the direction only, so neighbouring patches agree on shared edges) and returns a brightness factor:
	hollows (valleys, crater bowls) darker and crests lighter (cavity), steep ground darker (slope), and a soft
	direction-free-ish relief light from the north-west (cartographic hillshade, weak so it never fights the sun).

	API:
		BiomeDetail.featureWeight(x, y, z): number
		BiomeDetail.coastOffset(x, y, z, e, w): number                       added to Earth's coast-level elevation
		BiomeDetail.lakeValue(x, y, z, e, moist, mountain, heat, w): number  >= 0 inside a lake, < 0 outside
		BiomeDetail.river(x, y, z, ee, moist, mountain, heat, w, level): number  0..1 river cover
		BiomeDetail.farmland(x, y, z, e, moist, mountain, heat, w): (weight, r, g, b)
		BiomeDetail.mottle(x, y, z): number                                  about -1..1
		BiomeDetail.reliefShade(height, x, y, z, eps, radius): number         brightness factor
		BiomeDetail.LAKE_BANK                                                 lake value where Relief's bank starts
]]

local Bodies = require(script.Parent.Parent.Config.Bodies)

--============================================================================
-- Tunables
--============================================================================
local NOISE_SCALE = 1.4 -- math.noise -> Biome's noise spread
-- launch site: features fade in between these distances (m) from the pad (lat 0 / lon 0)
local FEATURE_INNER_M = 5500
local FEATURE_OUTER_M = 12000
-- coasts (elevation units of Biome's coast-level elevation; 0 = sea level)
local COAST_FREQ = 16 -- ~3.7 km bays and headlands
local COAST_AMP = 0.05
local COAST_FREQ2 = 37 -- ~1.6 km
local COAST_AMP2 = 0.025
local COAST_BAND0 = 0.05 -- full wiggle within this elevation of the coast ...
local COAST_BAND1 = 0.13 -- ... none beyond (inland plains and the open sea keep their shape)
-- lakes
local LAKE_FREQ = 46 -- ~1.3 km blobs
local LAKE_GAIN = 0.55
local LAKE_LACUNARITY = 2.3
local LAKE_THRESHOLD = 0.34 -- noise level of a lake's shore on ideal ground (higher = fewer, smaller lakes)
local LAKE_COLD_BONUS = 0.12 -- lower threshold in the cool north (heat below LAKE_COLD_HEAT)
local LAKE_COLD_HEAT = 0.55
local LAKE_E0 = 0.04 -- no lakes this close to the sea ...
local LAKE_E1 = 0.09
local LAKE_HIGH0 = 0.3 -- ... nor on high ground
local LAKE_HIGH1 = 0.42
local LAKE_MOUNT0 = 0.12 -- nor in mountains (Biome's mountain mask)
local LAKE_MOUNT1 = 0.24
local LAKE_MOIST0 = 0.36 -- nor in dry land
local LAKE_MOIST1 = 0.52
local LAKE_HEAT0 = 0.1 -- nor under the polar ice
local LAKE_HEAT1 = 0.18
local LAKE_BANK = 0.12 -- lake value where Relief's bank (the blend to the lake floor) starts
-- rivers (colour only): the zero lines of a warped noise, at a constant width (distance = |n| / |grad n|)
local RIVER_FREQ = 8.5 -- ~7 km bends
local RIVER_WARP_FREQ = 23 -- meanders ...
local RIVER_WARP = 0.012
local RIVER_WARP_FREQ2 = 60 -- ... and small wiggles
local RIVER_WARP2 = 0.004
local RIVER_HALF_WIDTH_M = 40 -- inland
local RIVER_MOUTH_HALF_WIDTH_M = 70 -- near the coast
local RIVER_GRAD_STEP = 0.0004 -- unit-sphere step of the finite-difference gradient (~24 m)
local RIVER_MASK_FREQ = 2.6 -- river country vs none
local RIVER_MASK0 = -0.15
local RIVER_MASK1 = 0.05
-- farmland (colour only): districts of DISTRICT_FIELDS x DISTRICT_FIELDS fields, each district with its own grid
-- angle and field size, so the patchwork never lines up across a continent
local FARM_CELLS = 150 -- fields per cube-face edge (~630 m) at field scale 1
local FARM_DISTRICT_FIELDS = 9
local FARM_ANGLES = { 0, 0.42, -0.31, 0.9, -0.75 } -- rad, grid angle choices per district
local FARM_SCALE_MIN = 0.7 -- field size range per district
local FARM_SCALE_MAX = 1.35
local FARM_REGION_FREQ = 4.5 -- farm regions (~13 km)
local FARM_REGION0 = -0.05
local FARM_REGION1 = 0.2
local FARM_HEAT0 = 0.42
local FARM_HEAT1 = 0.52
local FARM_MOIST0 = 0.36
local FARM_MOIST1 = 0.44
local FARM_WET0 = 0.6 -- forests take over above this moisture
local FARM_WET1 = 0.66
local FARM_SHARE = 0.72 -- share of cells that are fields
local FARM_MIX = 0.5 -- how strongly a field's crop colour replaces the grass
local FARM_COLORS: { { number } } = {
	{ 0.56, 0.63, 0.29 }, -- young crop
	{ 0.74, 0.67, 0.37 }, -- wheat
	{ 0.52, 0.43, 0.3 }, -- ploughed
	{ 0.36, 0.56, 0.24 }, -- pasture
	{ 0.64, 0.66, 0.34 }, -- hay
}
-- level of detail: texture pixel size (m) per Biome detail level (1, 2, 3); thin features are anti-aliased over it
local LEVEL_PIXEL_M = { 184, 92, 46 }
-- mottle
local MOTTLE_FREQ = 27 -- ~2.2 km
local MOTTLE_FREQ2 = 71 -- ~850 m
-- relief shade
local SHADE_LIGHT = { -0.55, 0.55, 0.63 } -- (east, north, up) of the relief light (north-west, ~40 deg high)
local SHADE_DIRECTIONAL = 0.22 -- strength of the relief light
local SHADE_SLOPE = 0.16 -- steep ground this much darker ...
local SHADE_SLOPE_FULL = 0.3 -- ... at this 1 - cos(slope) (~45 deg)
local SHADE_CAVITY = 0.2 -- hollows this much darker, crests this much lighter ...
local SHADE_CAVITY_FULL = 0.05 -- ... at this depth below the neighbours' mean per metre of offset
local SHADE_MIN = 0.55
local SHADE_MAX = 1.3
--============================================================================

local BiomeDetail = {}

local homeRadius = Bodies.get(Bodies.HOMEWORLD).Radius
local featureInner = FEATURE_INNER_M / homeRadius
local featureOuter = FEATURE_OUTER_M / homeRadius
local mathNoise = math.noise
local QUARTER_PI = math.pi / 4
local HALF_PI = math.pi / 2
local lightLen = math.sqrt(SHADE_LIGHT[1] ^ 2 + SHADE_LIGHT[2] ^ 2 + SHADE_LIGHT[3] ^ 2)
local LIGHT_E, LIGHT_N, LIGHT_U = SHADE_LIGHT[1] / lightLen, SHADE_LIGHT[2] / lightLen, SHADE_LIGHT[3] / lightLen

local function smoothstep(e0: number, e1: number, v: number): number
	local t = (v - e0) / (e1 - e0)
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end

-- 1 away from the launch site, 0 near it.
function BiomeDetail.featureWeight(x: number, y: number, z: number): number
	local sx = x - 1
	return smoothstep(featureInner, featureOuter, math.sqrt(sx * sx + y * y + z * z))
end

-- Mid-scale coast wiggle (elevation units), only near coasts (|e| < COAST_BAND1); w = featureWeight.
function BiomeDetail.coastOffset(x: number, y: number, z: number, e: number, w: number): number
	if w <= 0 then
		return 0
	end
	local band = 1 - smoothstep(COAST_BAND0, COAST_BAND1, math.abs(e))
	if band <= 0 then
		return 0
	end
	local f, f2 = COAST_FREQ, COAST_FREQ2
	local n = COAST_AMP * mathNoise(x * f + 3.1, y * f + 8.7, z * f + 5.9)
		+ COAST_AMP2 * mathNoise(x * f2 + 9.4, y * f2 + 1.6, z * f2 + 7.3)
	return n * NOISE_SCALE * band * w
end

--[[
	Lake value: >= 0 inside a lake (its water), < 0 outside; -1 where no lake can be. Inputs are Biome's smooth
	continent elevation e (not the coast-level one, so a lake does not follow the small coast noise), moisture, the
	mountain mask, heat and the feature weight.
]]
function BiomeDetail.lakeValue(
	x: number,
	y: number,
	z: number,
	e: number,
	moist: number,
	mountain: number,
	heat: number,
	w: number
): number
	local suit = w
		* smoothstep(LAKE_E0, LAKE_E1, e)
		* (1 - smoothstep(LAKE_HIGH0, LAKE_HIGH1, e))
		* (1 - smoothstep(LAKE_MOUNT0, LAKE_MOUNT1, mountain))
		* smoothstep(LAKE_MOIST0, LAKE_MOIST1, moist)
		* smoothstep(LAKE_HEAT0, LAKE_HEAT1, heat)
	if suit <= 0 then
		return -1
	end
	local f = LAKE_FREQ
	local n = mathNoise(x * f + 12.7, y * f + 4.3, z * f + 9.1)
	f *= LAKE_LACUNARITY
	n = (n + LAKE_GAIN * mathNoise(x * f + 2.2, y * f + 15.8, z * f + 6.6)) / (1 + LAKE_GAIN)
	local threshold = LAKE_THRESHOLD - LAKE_COLD_BONUS * smoothstep(LAKE_COLD_HEAT, LAKE_COLD_HEAT - 0.25, heat)
	-- unsuitable ground raises the shore level beyond reach (the value still falls smoothly toward the edges)
	return n * NOISE_SCALE - threshold - (1 - suit) * 0.6
end

--[[
	River cover 0..1 (colour only): thin warped zero lines of a low-frequency noise inside river country, on land
	(coast-level elevation ee > 0) that is not mountains, desert or ice. The width is constant (distance to the zero
	line from |n| / |grad n|), anti-aliased over the texture pixel of detail level `level`.
]]
function BiomeDetail.river(
	x: number,
	y: number,
	z: number,
	ee: number,
	moist: number,
	mountain: number,
	heat: number,
	w: number,
	level: number
): number
	if w <= 0 or ee <= 0 then
		return 0
	end
	local suit = w
		* (1 - smoothstep(0.1, 0.22, mountain))
		* smoothstep(0.32, 0.45, moist)
		* smoothstep(0.12, 0.2, heat)
		* (1 - smoothstep(0.32, 0.42, ee))
	if suit <= 0 then
		return 0
	end
	local mf = RIVER_MASK_FREQ
	local mask = smoothstep(RIVER_MASK0, RIVER_MASK1, mathNoise(x * mf + 21.5, y * mf + 3.3, z * mf + 14.1))
	if mask <= 0 then
		return 0
	end
	local wf, wf2 = RIVER_WARP_FREQ, RIVER_WARP_FREQ2
	local f = RIVER_FREQ
	local qx = (
		x
		+ RIVER_WARP * mathNoise(x * wf + 1.7, y * wf + 6.2, z * wf + 3.8)
		+ RIVER_WARP2 * mathNoise(x * wf2 + 4.9, y * wf2 + 8.8, z * wf2 + 0.4)
	) * f
	local qy = y * f
	local qz = (
		z
		+ RIVER_WARP * mathNoise(x * wf + 7.9, y * wf + 2.4, z * wf + 11.6)
		+ RIVER_WARP2 * mathNoise(x * wf2 + 10.2, y * wf2 + 3.1, z * wf2 + 6.7)
	) * f
	local n0 = mathNoise(qx + 5.5, qy + 17.2, qz + 2.9)
	local pixel = LEVEL_PIXEL_M[math.clamp(level, 1, #LEVEL_PIXEL_M)]
	local halfWidth = RIVER_HALF_WIDTH_M
		+ (RIVER_MOUTH_HALF_WIDTH_M - RIVER_HALF_WIDTH_M) * (1 - smoothstep(0.02, 0.15, ee))
	local reach = (halfWidth + pixel) / homeRadius -- unit-sphere distance beyond which nothing is drawn
	-- cheap reject: |n| grows at most ~2.5 per unit of noise space
	if math.abs(n0) > 2.5 * reach * f then
		return 0
	end
	local d = RIVER_GRAD_STEP * f
	local gx = mathNoise(qx + d + 5.5, qy + 17.2, qz + 2.9) - n0
	local gy = mathNoise(qx + 5.5, qy + d + 17.2, qz + 2.9) - n0
	local gz = mathNoise(qx + 5.5, qy + 17.2, qz + d + 2.9) - n0
	local grad = math.sqrt(gx * gx + gy * gy + gz * gz) / RIVER_GRAD_STEP -- per unit-sphere distance
	local dist = math.abs(n0) / math.max(grad, 0.3 * f) * homeRadius -- m from the river's centre line
	local cover = math.clamp((halfWidth + pixel * 0.5 - dist) / pixel, 0, 1)
	return cover * mask * suit
end

--[[
	Farmland: weight 0..1 and the crop colour of the field at (x, y, z). Fields are cells of an equal-angle grid on
	the cube face the point is on (wobbled a little), each with its own crop (or none), and some cells split in two.
]]
function BiomeDetail.farmland(
	x: number,
	y: number,
	z: number,
	e: number,
	moist: number,
	mountain: number,
	heat: number,
	w: number
): (number, number, number, number)
	local suit = w
		* smoothstep(FARM_HEAT0, FARM_HEAT1, heat)
		* smoothstep(FARM_MOIST0, FARM_MOIST1, moist)
		* (1 - smoothstep(FARM_WET0, FARM_WET1, moist))
		* smoothstep(0.03, 0.07, e)
		* (1 - smoothstep(0.26, 0.36, e))
		* (1 - smoothstep(0.1, 0.2, mountain))
	if suit <= 0 then
		return 0, 0, 0, 0
	end
	local rf = FARM_REGION_FREQ
	suit *= smoothstep(FARM_REGION0, FARM_REGION1, mathNoise(x * rf + 31.3, y * rf + 7.7, z * rf + 19.9) * NOISE_SCALE)
	if suit <= 0 then
		return 0, 0, 0, 0
	end
	-- the cube face and the equal-angle coordinates on it
	local ax, ay, az = math.abs(x), math.abs(y), math.abs(z)
	local face, dn, du, dv
	if ax >= ay and ax >= az then
		face, dn, du, dv = if x > 0 then 1 else 2, ax, z, y
	elseif ay >= az then
		face, dn, du, dv = if y > 0 then 3 else 4, ay, x, z
	else
		face, dn, du, dv = if z > 0 then 5 else 6, az, x, y
	end
	local fa = (math.atan(du / dn) + QUARTER_PI) / HALF_PI * FARM_CELLS
	local fb = (math.atan(dv / dn) + QUARTER_PI) / HALF_PI * FARM_CELLS
	-- the district: its own grid angle and field size (cell hashes: noise at far-apart lattice-offset points is
	-- uncorrelated between neighbouring cells)
	local district = FARM_DISTRICT_FIELDS
	local da, db = math.floor(fa / district), math.floor(fb / district)
	local hd1 = mathNoise(da * 7.31 + 0.13, db * 5.17 + 0.71, face * 3.3 + 0.37) * NOISE_SCALE
	local hd2 = mathNoise(da * 3.77 + 0.59, db * 8.41 + 0.29, face * 2.9 + 0.83) * NOISE_SCALE
	local angle = FARM_ANGLES[math.clamp(math.floor((hd1 * 0.5 + 0.5) * #FARM_ANGLES) + 1, 1, #FARM_ANGLES)]
	local scale = FARM_SCALE_MIN + (FARM_SCALE_MAX - FARM_SCALE_MIN) * math.clamp(hd2 * 0.5 + 0.5, 0, 1)
	local ca, sa = math.cos(angle), math.sin(angle)
	local ra, rb = (fa * ca - fb * sa) / scale, (fa * sa + fb * ca) / scale
	local ia, ib = math.floor(ra), math.floor(rb)
	local h1 = mathNoise(ia * 7.31 + 0.13, ib * 5.17 + 0.71, face * 3.3 + da * 0.61 + 0.37) * NOISE_SCALE
	local h2 = mathNoise(ia * 3.77 + 0.59, ib * 8.41 + 0.29, face * 2.9 + db * 0.67 + 0.83) * NOISE_SCALE
	-- some fields are split in two along one axis: the far part gets its own crop
	local h3 = mathNoise(ia * 6.13 + 0.47, ib * 4.57 + 0.11, face * 4.1 + 0.67) * NOISE_SCALE
	if math.abs(h3) > 0.2 then
		local split = 0.5 + 0.25 * h2
		if (if h3 > 0 then ra - ia else rb - ib) > split then
			h1 = mathNoise(ia * 5.29 + 0.31, ib * 7.93 + 0.53, face * 3.7 + 0.19) * NOISE_SCALE
		end
	end
	if (h2 + 1) * 0.5 > FARM_SHARE then
		return 0, 0, 0, 0 -- left wild
	end
	local pick = math.floor(((h1 * 1.7 + 1) * 0.5 % 1) * #FARM_COLORS) + 1
	local c = FARM_COLORS[math.clamp(pick, 1, #FARM_COLORS)]
	return suit * FARM_MIX, c[1], c[2], c[3]
end

-- Patchiness noise, about -1..1 (two octaves: ~2.2 km and ~850 m).
function BiomeDetail.mottle(x: number, y: number, z: number): number
	local f, f2 = MOTTLE_FREQ, MOTTLE_FREQ2
	return (
		mathNoise(x * f + 6.6, y * f + 13.4, z * f + 2.1)
		+ 0.5 * mathNoise(x * f2 + 17.9, y * f2 + 5.2, z * f2 + 10.4)
	) * NOISE_SCALE
end

-- Height at the direction of (x, y, z) (not unit).
local function offsetHeight(height: (number, number, number) -> number, x: number, y: number, z: number): number
	local inv = 1 / math.sqrt(x * x + y * y + z * z)
	return height(x * inv, y * inv, z * inv)
end

--[[
	Relief shade factor at unit direction (x, y, z) for a ground height function height(x, y, z) (m above the
	radius), sampled `eps` rad away along the local east / north axes. radius: the body radius (m).
]]
function BiomeDetail.reliefShade(
	height: (number, number, number) -> number,
	x: number,
	y: number,
	z: number,
	eps: number,
	radius: number
): number
	-- local frame from the direction only: north = +Y projected on the tangent plane, east = north x up
	local nx, ny, nz = -x * y, 1 - y * y, -z * y
	local len = math.sqrt(nx * nx + ny * ny + nz * nz)
	if len < 1e-6 then
		nx, ny, nz, len = 1, 0, 0, 1 -- at a pole any tangent frame will do
	end
	nx, ny, nz = nx / len, ny / len, nz / len
	local ex, ey, ez = ny * z - nz * y, nz * x - nx * z, nx * y - ny * x
	local h0 = height(x, y, z)
	local hE = offsetHeight(height, x + eps * ex, y + eps * ey, z + eps * ez)
	local hW = offsetHeight(height, x - eps * ex, y - eps * ey, z - eps * ez)
	local hN = offsetHeight(height, x + eps * nx, y + eps * ny, z + eps * nz)
	local hS = offsetHeight(height, x - eps * nx, y - eps * ny, z - eps * nz)
	local step = eps * radius
	local gx, gy = (hE - hW) / (2 * step), (hN - hS) / (2 * step)
	local nl = math.sqrt(gx * gx + gy * gy + 1)
	local slope = 1 - 1 / nl
	local lit = (-gx * LIGHT_E - gy * LIGHT_N + LIGHT_U) / nl
	local cavity = ((hE + hW + hN + hS) * 0.25 - h0) / step
	local shade = 1
		+ SHADE_DIRECTIONAL * (lit - LIGHT_U) / LIGHT_U
		- SHADE_SLOPE * smoothstep(0, SHADE_SLOPE_FULL, slope)
		- SHADE_CAVITY * math.clamp(cavity / SHADE_CAVITY_FULL, -1, 1)
	return math.clamp(shade, SHADE_MIN, SHADE_MAX)
end

BiomeDetail.LAKE_BANK = LAKE_BANK

return table.freeze(BiomeDetail)
