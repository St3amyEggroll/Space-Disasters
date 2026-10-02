--!strict
--!native
--[[
	Biome
	Deterministic planet appearance, sampled by unit direction from the body centre (body axes = universe axes;
	planets do not rotate). Pure module: the scaled-space textures, the ground tile textures, the surface props and
	the offline tests all run this exact code, so every view of a planet agrees. Noise is Luau's built-in
	math.noise (the same C implementation in Roblox and Lune, ~20x faster than noise written in Luau); set
	USE_BUILTIN_NOISE = false to use the seeded pure-Luau gradient noise below instead (same spread, other
	continents). Cell hashes for craters and props are our own seeded tables / integer hash.

	Point samples:
	  Biome.sample(bodyId, x, y, z)       -> r, g, b (0..1), kind     full-quality sample of the ground
	  Biome.clouds(bodyId, x, y, z)       -> alpha (0..1)             cloud cover (0 for bodies without clouds)
	  Biome.hasClouds(bodyId)             -> boolean
	  Biome.averageColor(bodyId)          -> r, g, b                  mean ground colour (fallback visuals)
	  Biome.propDensity(kind)             -> props per hectare
	  Biome.propKind(kind, roll)          -> PropKind?                roll in [0, 1)
	  Biome.hash01(a, b, c, salt)         -> [0, 1)                   integer hash for deterministic placement

	Model (two levels):
	  fields  low-frequency and expensive: domain-warped fractal noise for continents, moisture, mountains and
	          heat (Earth), maria (Mun), cloud cover. Painters evaluate them on a coarse grid and interpolate.
	  shade   cheap, per pixel: high-frequency detail (coastline wiggle, colour grain, dunes), polar caps, beaches,
	          shallow water, and on Mun the craters and ray craters.
	sample() evaluates both exactly at the given direction.

	Earth: ~60% ocean. Land is forced around the launch site (+X, lat 0 / lon 0): the ground is flat grassland
	within SITE_FLAT_INNER_M, and a sea is biased in to the east (+Z) so a coastline is in view from the pad.

	Texture space (shared by ScaledSpace patches and Surface tile boxes):
	  Every textured surface is parametrised by (s, t) in [0, 1]^2. Mesh UVs are
	      u = UV_INSET + s * (1 - 2 UV_INSET),  v = UV_INSET + t * (1 - 2 UV_INSET)  (v mirrored if UV_FLIP_V)
	  and image pixel (px, py) (buffer row py) has its centre at uv ((px + 0.5) / S, (py + 0.5) / S), i.e. UV (0, 0)
	  is the top-left of the image. The inset keeps the bilinear filter at a patch edge on this texture's own
	  pixels; the padding pixels beyond the edge are painted with the true directions just outside the patch, so
	  they match the neighbour.
	  Patch (s, t): local direction normalize(tan(s pi/4 - pi/4), 1, tan(t pi/4 - pi/4)) (equal-angle spacing on the
	  +Y cube-face quarter x, z in [-1, 0]), rotated into body axes by the patch's cube rotation M (row-major,
	  body = M * local). Rect (s, t): centre + (s - 1/2) * ex * A + (t - 1/2) * ez * B, normalised.

	Painters: Biome.newPainter(size, cells, buf) allocates once; beginPatch / beginRect aim it at a surface;
	paintStep does one small unit of work (one grid row or one pixel row) and returns true when the RGBA buffer
	is complete. No allocation per step.

	CHANGED (Phase 8): relief hooks for the terrain heightmap (Sim/Relief), so the ground's shape follows the colours:
	  Biome.reliefFields(bodyId, x, y, z)  -> (ee, mountain) on Earth, (mare, highland variation) on Mun
	  Biome.craterSum(x, y, z, visit)      -> sum of visit(t, radius, scale) over the Mun craters reaching (x, y, z)
	Colours are unchanged.
	CHANGED (Terrain polish): the ridge field's lines are rounded (smooth |n|), and the mountains are kept out of a
	plain around the launch site (SITE_CALM_INNER_M / SITE_CALM_OUTER_M).
]]

local Bodies = require(script.Parent.Parent.Config.Bodies)

--============================================================================
-- Tunables
--============================================================================
local SEED = 424242 -- 1 .. 2^31 - 2, Park-Miller generator seed for the noise tables

-- Texture space
local UV_INSET = 1 / 64 -- fraction of the texture kept as padding on each side
local UV_FLIP_V = false -- set true if textures show mirrored inside each patch (engine V runs bottom-up)

-- Noise
local USE_BUILTIN_NOISE = true -- Luau's math.noise (same C code in Roblox and Lune, ~20x faster than ours)
local BUILTIN_NOISE_SCALE = 1.4 -- matches math.noise's spread (std 0.27) to the seeded noise below (std 0.38)
local LACUNARITY = 2.07 -- frequency step between octaves
local OCTAVE_SHIFT = 17.31 -- coordinate offset between octaves (decorrelates them)

-- Earth: continents
local K_WARP_FREQ = 1.1
local K_WARP_OCTAVES = 2
local K_WARP_STRENGTH = 0.3 -- unit-sphere units
local K_CONT_FREQ = 1.45
local K_CONT_OCTAVES = 5
local K_CONT_GAIN = 0.52
local K_SEA_LEVEL = 0.1 -- continent noise level of the coast; raise for more ocean
-- Earth: climate
local K_MOIST_FREQ = 2.1
local K_MOIST_OCTAVES = 3
local K_MOIST_SCALE = 1.5 -- noise -> moisture spread around 0.5
local K_DRY_BAND_LAT = 0.42 -- |sin(lat)| of the subtropical dry band
local K_DRY_BAND_WIDTH = 0.13
local K_DRY_BAND_STRENGTH = 0.3
local K_EQUATOR_WET = 0.08 -- extra moisture at the equator
local K_RIDGE_FREQ = 2.7
local K_RIDGE_OCTAVES = 3
local K_RIDGE_SOFT = 0.12 -- CHANGED (Terrain polish): rounds the ridge lines (smooth |n|: no knife-edge creases)
local K_HEAT_NOISE_FREQ = 3.1
local K_HEAT_NOISE = 0.05 -- noisy polar-cap edge
-- Earth: per-pixel detail
local K_DETAIL_FREQ = 46
local K_DETAIL_OCTAVES = 3 -- detail level of sample(); painters pass their own (Mun: level + 1 crater scales)
local K_COAST_DETAIL = 0.03 -- elevation wiggle (sharpens coastlines)
local K_COAST_AA = 0.004 -- water / land colour blend band (elevation units) against jagged coastlines
local K_POLAR_DETAIL = 0.02
local K_GRAIN = 0.07 -- +/- brightness variation
-- Earth: classification (elevation is relative to sea level)
local K_SNOW_HEAT = 0.1 -- heat (1 - |sin lat| + noise) below this is polar ice
local K_SNOW_EDGE = 0.012
local K_TUNDRA_HEAT0 = 0.16 -- fully tundra-coloured below this heat
local K_TUNDRA_HEAT1 = 0.3
local K_SHALLOW_DEPTH = 0.05 -- turquoise -> mid blue over this depth
local K_DEEP_DEPTH = 0.22 -- mid blue -> deep blue by this depth
local K_BEACH_WIDTH = 0.018
local K_FOREST_M0 = 0.6 -- moisture where forest starts
local K_FOREST_M1 = 0.7
local K_DESERT_M0 = 0.3 -- moisture where desert starts (drier = more desert)
local K_DESERT_M1 = 0.22
local K_DESERT_HEAT = 0.45 -- no desert colder than this
local K_MOUNT_E0 = 0.05 -- mountains only this far above sea level
local K_MOUNT_E1 = 0.2
local K_ROCK0 = 0.52 -- ridge * inland mask where rock starts
local K_ROCK1 = 0.64
local K_PEAK0 = 0.74 -- snowy peaks
local K_PEAK1 = 0.8
-- Earth: launch site shaping (metres along the surface)
local SITE_FLAT_INNER_M = 3500 -- always flat grassland inside this
local SITE_FLAT_OUTER_M = 5500
local SITE_LAND_RADIUS_M = 7500
local SITE_LAND_BIAS = 0.3
local SITE_SEA_OFFSET_M = 12500 -- sea centre, east (+Z) of the site
local SITE_SEA_RADIUS_M = 7500
local SITE_SEA_BIAS = 0.45
local SITE_ELEV = 0.13 -- elevation (above sea) forced at the site
local SITE_MOIST = 0.48
local SITE_RIDGE = 0.1
-- CHANGED (Terrain polish): no mountains within SITE_CALM_INNER_M of the pad, back to the natural ridges by
-- SITE_CALM_OUTER_M. The site sits in a broad plain: from the ground there, the curvature of the 60 km planet hides
-- everything past ~4 km, so no far (scaled) terrain band is ever drawn behind the base (Render/TerrainMesh), and
-- the first mountains rise near the horizon instead of right behind the pads.
local SITE_CALM_INNER_M = 11000
local SITE_CALM_OUTER_M = 18000

-- Earth colours (linear 0..1 RGB, stylised)
local C_DEEP = { 0.06, 0.2, 0.47 }
local C_MID = { 0.1, 0.36, 0.66 }
local C_SHALLOW = { 0.2, 0.68, 0.72 }
local C_BEACH = { 0.91, 0.84, 0.6 }
local C_GRASS_LUSH = { 0.34, 0.64, 0.24 }
local C_GRASS_DRY = { 0.6, 0.64, 0.3 }
local C_TUNDRA = { 0.52, 0.55, 0.44 }
local C_FOREST = { 0.14, 0.42, 0.19 }
local C_BOREAL = { 0.16, 0.33, 0.24 }
local C_DESERT = { 0.9, 0.75, 0.46 }
local C_DUNE = { 0.8, 0.6, 0.34 }
local C_ROCK = { 0.5, 0.46, 0.42 }
local C_ROCK_DARK = { 0.35, 0.32, 0.3 }
local C_SNOW = { 0.95, 0.97, 1.0 }
local C_SNOW_SHADE = { 0.8, 0.87, 0.95 }

-- Earth clouds
local CLOUD_WARP_FREQ = 1.6
local CLOUD_WARP_STRENGTH = 0.25
local CLOUD_FREQ = 2.3
local CLOUD_OCTAVES = 4
local CLOUD_GAIN = 0.55
local CLOUD_DETAIL_FREQ = 30
local CLOUD_DETAIL = 0.09
local CLOUD_COVER0 = 0.08 -- field value where clouds start
local CLOUD_COVER1 = 0.34 -- field value of full cover
local CLOUD_MAX_ALPHA = 0.85
local CLOUD_BAND = 0.1 -- extra cover at the equator and mid-latitudes, less in the subtropics
local CLOUD_BAND_WIDTH = 0.16
local CLOUD_MIDLAT = 0.68

-- Mun
local D_MARE_FREQ = 1.3
local D_MARE_OCTAVES = 3
local D_MARE0 = 0.06
local D_MARE1 = 0.16
local D_HIGHLAND_FREQ = 3.7
local D_HIGHLAND_OCTAVES = 2
local D_HIGHLAND_VAR = 0.12
local D_DETAIL_FREQ = 60
local D_GRAIN = 0.05
local C_HIGHLAND = { 0.62, 0.6, 0.57 }
local C_MARE = { 0.37, 0.37, 0.4 }
local C_RAY = { 0.9, 0.9, 0.88 }
-- Mun craters, per scale: cells per cube-face edge (equal-angle grid), probability that a cell holds a crater,
-- rim radius range as a fraction of the cell, brightness strength. CRATER_EXTENT * max radius must stay below 1
-- cell so the 3x3 cell search finds every crater.
local CRATER_FACE_CELLS = { 4, 12, 36 }
local CRATER_PROB = { 0.75, 0.8, 0.85 }
local CRATER_RMIN = { 0.18, 0.14, 0.12 }
local CRATER_RMAX = { 0.42, 0.4, 0.38 }
local CRATER_STRENGTH = { 1.0, 0.85, 0.65 }
local CRATER_FLOOR = 0.14 -- floor darkening
local CRATER_RIM = 0.2 -- rim brightening
local CRATER_EJECTA = 0.07
local CRATER_EXTENT = 1.7 -- ejecta reach in rim radii
local FACE_REACH = 2.5 -- tan of the widest angle (face half-width + one large cell) a face's craters reach
local RAY_CRATERS = 5
local RAY_RADIUS_MIN = 0.035 -- rad
local RAY_RADIUS_MAX = 0.06
local RAY_REACH = 11 -- ray length in crater radii
local RAY_STRENGTH = 0.55
local RAY_KIND_LEVEL = 0.18 -- ray brightness above which the ground counts as "Ray"

-- Props (per hectare) and their mix per biome
local PROP_DENSITY: { [string]: number } = {
	Ocean = 0,
	Beach = 0.25,
	Grass = 1.6,
	Forest = 9,
	Desert = 0.9,
	Rock = 2.5,
	Snow = 0.8,
	Mare = 0.45,
	Highland = 0.9,
	Crater = 1.6,
	Ray = 1.2,
	Plain = 0,
}
--============================================================================

export type Kind =
	"Ocean"
	| "Beach"
	| "Grass"
	| "Forest"
	| "Desert"
	| "Rock"
	| "Snow"
	| "Mare"
	| "Highland"
	| "Crater"
	| "Ray"
	| "Plain"

export type PropKind = "RoundTree" | "PineTree" | "SnowPine" | "Cactus" | "Rock" | "Bush" | "Boulder" | "CraterRim"

export type Layer = "Ground" | "Clouds"

type FieldsFn = (x: number, y: number, z: number) -> (number, number, number, number)
type ShadeFn = (
	x: number,
	y: number,
	z: number,
	f1: number,
	f2: number,
	f3: number,
	f4: number,
	octaves: number
) -> (number, number, number, number, Kind)

export type Painter = {
	size: number, -- pixels per side
	cells: number, -- coarse grid cells per unit of (s, t)
	nodes: number, -- grid nodes per side (cells + 3: params -1/cells .. 1 + 1/cells)
	buf: buffer, -- RGBA, at least size * size * 4 bytes
	colI: { number }, -- per pixel column: grid cell index (0-based) and fraction
	colF: { number },
	nodeX: { number },
	nodeY: { number },
	nodeZ: { number },
	nodeF1: { number },
	nodeF2: { number },
	nodeF3: { number },
	nodeF4: { number },
	-- current job
	fields: FieldsFn,
	shade: ShadeFn,
	octaves: number,
	rect: boolean,
	m: { number }, -- patch rotation (row-major 3x3)
	cx: number, -- rect centre (m, body-relative)
	cy: number,
	cz: number,
	ax: number, -- rect s axis (unit) and t axis (unit)
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number,
	ex: number, -- rect extents (m)
	ez: number,
	nodeRow: number, -- grid rows done
	pixelRow: number, -- pixel rows done
	done: boolean,
	-- statistics of the finished image
	oceanPixels: number,
	sumR: number,
	sumG: number,
	sumB: number,
}

local Biome = {}

local HOMEWORLD = Bodies.HOMEWORLD
local MOON = Bodies.MOON
local QUARTER_PI = math.pi / 4
local HALF_PI = math.pi / 2

--============================================================================
-- Seeded tables
--============================================================================
local rngState = SEED
local function nextRandom(): number
	rngState = (rngState * 16807) % 2147483647
	return rngState / 2147483647
end

local PERM: { number } = table.create(512, 0) -- values 0..255, 1-based, duplicated so p[a] + b needs no mask
local GRAD_X: { number } = table.create(256, 0)
local GRAD_Y: { number } = table.create(256, 0)
local GRAD_Z: { number } = table.create(256, 0)
local RAND_P: { number } = table.create(256, 0)
local RAND_X: { number } = table.create(256, 0)
local RAND_Y: { number } = table.create(256, 0)
local RAND_Z: { number } = table.create(256, 0)
local RAND_S: { number } = table.create(256, 0)

do
	local p: { number } = table.create(256, 0)
	for i = 0, 255 do
		p[i + 1] = i
	end
	for i = 256, 2, -1 do
		local j = math.floor(nextRandom() * i) + 1
		p[i], p[j] = p[j], p[i]
	end
	for i = 1, 256 do
		PERM[i] = p[i]
		PERM[i + 256] = p[i]
	end
	for i = 1, 256 do
		-- uniform unit vectors
		local zz = nextRandom() * 2 - 1
		local phi = nextRandom() * 2 * math.pi
		local rr = math.sqrt(1 - zz * zz)
		GRAD_X[i], GRAD_Y[i], GRAD_Z[i] = rr * math.cos(phi), rr * math.sin(phi), zz
		RAND_P[i], RAND_X[i], RAND_Y[i], RAND_Z[i], RAND_S[i] =
			nextRandom(), nextRandom(), nextRandom(), nextRandom(), nextRandom()
	end
end

--============================================================================
-- Small math
--============================================================================
local function clamp01(v: number): number
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

-- Hermite step from e0 to e1 (e0 > e1 gives a falling step).
local function smoothstep(e0: number, e1: number, v: number): number
	local t = (v - e0) / (e1 - e0)
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end

--============================================================================
-- Noise
--============================================================================

-- Improved-Perlin-style 3D gradient noise with random unit gradients, roughly in [-1.3, 1.3] (std 0.38). Fully
-- seeded and pure Luau; used when USE_BUILTIN_NOISE is false.
local function gradientNoise3(x: number, y: number, z: number): number
	local fx, fy, fz = math.floor(x), math.floor(y), math.floor(z)
	local xi, yi, zi = fx % 256, fy % 256, fz % 256
	x -= fx
	y -= fy
	z -= fz
	local u = x * x * x * (x * (x * 6 - 15) + 10)
	local v = y * y * y * (y * (y * 6 - 15) + 10)
	local w = z * z * z * (z * (z * 6 - 15) + 10)
	local a = PERM[xi + 1] + yi
	local b = PERM[xi + 2] + yi
	local aa = PERM[a + 1] + zi
	local ab = PERM[a + 2] + zi
	local ba = PERM[b + 1] + zi
	local bb = PERM[b + 2] + zi
	local x1, y1, z1 = x - 1, y - 1, z - 1
	local g = PERM[aa + 1] + 1
	local n000 = GRAD_X[g] * x + GRAD_Y[g] * y + GRAD_Z[g] * z
	g = PERM[ba + 1] + 1
	local n100 = GRAD_X[g] * x1 + GRAD_Y[g] * y + GRAD_Z[g] * z
	g = PERM[ab + 1] + 1
	local n010 = GRAD_X[g] * x + GRAD_Y[g] * y1 + GRAD_Z[g] * z
	g = PERM[bb + 1] + 1
	local n110 = GRAD_X[g] * x1 + GRAD_Y[g] * y1 + GRAD_Z[g] * z
	g = PERM[aa + 2] + 1
	local n001 = GRAD_X[g] * x + GRAD_Y[g] * y + GRAD_Z[g] * z1
	g = PERM[ba + 2] + 1
	local n101 = GRAD_X[g] * x1 + GRAD_Y[g] * y + GRAD_Z[g] * z1
	g = PERM[ab + 2] + 1
	local n011 = GRAD_X[g] * x + GRAD_Y[g] * y1 + GRAD_Z[g] * z1
	g = PERM[bb + 2] + 1
	local n111 = GRAD_X[g] * x1 + GRAD_Y[g] * y1 + GRAD_Z[g] * z1
	local nx00 = n000 + u * (n100 - n000)
	local nx10 = n010 + u * (n110 - n010)
	local nx01 = n001 + u * (n101 - n001)
	local nx11 = n011 + u * (n111 - n011)
	local nxy0 = nx00 + v * (nx10 - nx00)
	local nxy1 = nx01 + v * (nx11 - nx01)
	return 2 * (nxy0 + w * (nxy1 - nxy0))
end

local mathNoise = math.noise

local function builtinNoise3(x: number, y: number, z: number): number
	return mathNoise(x, y, z) * BUILTIN_NOISE_SCALE
end

local noise3: (number, number, number) -> number = if USE_BUILTIN_NOISE then builtinNoise3 else gradientNoise3

-- Fractal sum, normalised to the noise range.
local function fbm(x: number, y: number, z: number, octaves: number, gain: number): number
	local sum, amp, norm = 0, 1, 0
	for _ = 1, octaves do
		sum += amp * noise3(x, y, z)
		norm += amp
		x = x * LACUNARITY + OCTAVE_SHIFT
		y = y * LACUNARITY + OCTAVE_SHIFT
		z = z * LACUNARITY + OCTAVE_SHIFT
		amp *= gain
	end
	return sum / norm
end

-- Ridged fractal in [0, 1]: 1 on the ridge lines.
-- CHANGED (Terrain polish): |n| is smoothed (sqrt(n^2 + s^2) - s), so the ridge lines (and the mountains Relief
-- raises on them) are rounded instead of knife-edged
local function ridged(x: number, y: number, z: number, octaves: number): number
	local sum, amp, norm = 0, 1, 0
	for _ = 1, octaves do
		local v = noise3(x, y, z)
		local n = 1 - (math.sqrt(v * v + K_RIDGE_SOFT * K_RIDGE_SOFT) - K_RIDGE_SOFT)
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
-- Integer hash (placement)
--============================================================================

-- (a * b) mod 2^32 without losing precision in doubles (a < 2^32, b < 2^27).
local function mul32(a: number, b: number): number
	local lo = a % 65536
	local hi = (a - lo) / 65536
	return ((hi * b) % 65536 * 65536 + lo * b) % 4294967296
end

local function mix32(h: number): number
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x045D9F3B)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = mul32(h, 0x045D9F3B)
	return bit32.bxor(h, bit32.rshift(h, 16))
end

-- Deterministic hash of four integers to [0, 1).
function Biome.hash01(a: number, b: number, c: number, salt: number): number
	local h = mix32(bit32.bxor(a % 4294967296, salt % 4294967296))
	h = mix32(bit32.bxor(h, b % 4294967296))
	h = mix32(bit32.bxor(h, c % 4294967296))
	return h / 4294967296
end

--============================================================================
-- Earth
--============================================================================
local homeRadius = Bodies.get(HOMEWORLD).Radius
local siteFlatInner = SITE_FLAT_INNER_M / homeRadius -- chord lengths on the unit sphere (~ angles here)
local siteFlatOuter = SITE_FLAT_OUTER_M / homeRadius
local siteLandRadius = SITE_LAND_RADIUS_M / homeRadius
local seaAngle = SITE_SEA_OFFSET_M / homeRadius
local seaX, seaZ = math.cos(seaAngle), math.sin(seaAngle) -- east of lat 0 / lon 0 is +Z
local seaRadius = SITE_SEA_RADIUS_M / homeRadius
local siteCalmInner = SITE_CALM_INNER_M / homeRadius -- CHANGED (Terrain polish)
local siteCalmOuter = SITE_CALM_OUTER_M / homeRadius

-- (elevation above sea level, moisture ~0..1, ridge 0..1, heat ~0 at the poles .. 1 at the equator)
local function earthFields(x: number, y: number, z: number): (number, number, number, number)
	local wx = fbm(x * K_WARP_FREQ + 5.2, y * K_WARP_FREQ + 1.3, z * K_WARP_FREQ + 7.7, K_WARP_OCTAVES, 0.5)
	local wy = fbm(x * K_WARP_FREQ + 9.1, y * K_WARP_FREQ + 3.9, z * K_WARP_FREQ + 2.4, K_WARP_OCTAVES, 0.5)
	local wz = fbm(x * K_WARP_FREQ + 4.6, y * K_WARP_FREQ + 8.8, z * K_WARP_FREQ + 6.1, K_WARP_OCTAVES, 0.5)
	local px, py, pz = x + K_WARP_STRENGTH * wx, y + K_WARP_STRENGTH * wy, z + K_WARP_STRENGTH * wz

	local elev = fbm(px * K_CONT_FREQ, py * K_CONT_FREQ, pz * K_CONT_FREQ, K_CONT_OCTAVES, K_CONT_GAIN) - K_SEA_LEVEL
	local moist = 0.5
		+ 0.5
			* K_MOIST_SCALE
			* fbm(px * K_MOIST_FREQ + 11.3, py * K_MOIST_FREQ + 2.2, pz * K_MOIST_FREQ + 5.9, K_MOIST_OCTAVES, 0.5)
	local ay = math.abs(y)
	local band = (ay - K_DRY_BAND_LAT) / K_DRY_BAND_WIDTH
	moist += K_EQUATOR_WET * (1 - ay) - K_DRY_BAND_STRENGTH * math.exp(-band * band)
	local ridge = ridged(px * K_RIDGE_FREQ + 3.3, py * K_RIDGE_FREQ + 7.1, pz * K_RIDGE_FREQ + 1.7, K_RIDGE_OCTAVES)
	local heat = 1 - ay + K_HEAT_NOISE * noise3(x * K_HEAT_NOISE_FREQ, y * K_HEAT_NOISE_FREQ, z * K_HEAT_NOISE_FREQ)

	-- launch site: land around the pad, a sea to the east, flat grassland on the pad itself
	local sx, sz = x - 1, z
	local siteDist = math.sqrt(sx * sx + y * y + sz * sz)
	local land = 1 - siteDist * siteDist / (siteLandRadius * siteLandRadius)
	if land > 0 then
		elev += SITE_LAND_BIAS * land * land
	end
	local qx, qz = x - seaX, z - seaZ
	local sea = 1 - (qx * qx + y * y + qz * qz) / (seaRadius * seaRadius)
	if sea > 0 then
		elev -= SITE_SEA_BIAS * sea * sea
	end
	local flat = smoothstep(siteFlatOuter, siteFlatInner, siteDist)
	if flat > 0 then
		elev += (SITE_ELEV - elev) * flat
		moist += (SITE_MOIST - moist) * flat
		ridge += (SITE_RIDGE - ridge) * flat
	end
	-- CHANGED (Terrain polish): the mountain-free plain around the site
	local calm = smoothstep(siteCalmOuter, siteCalmInner, siteDist)
	if calm > 0 then
		ridge += (SITE_RIDGE - ridge) * calm
	end
	return elev, moist, ridge, heat
end

local function earthShade(
	x: number,
	y: number,
	z: number,
	e: number,
	m: number,
	rg: number,
	heat: number,
	octaves: number
): (number, number, number, number, Kind)
	-- per-pixel detail
	local f = K_DETAIL_FREQ
	local d1 = noise3(x * f, y * f, z * f)
	local detail = d1
	if octaves >= 2 then
		f *= 2.3
		detail += 0.5 * noise3(x * f + 31.7, y * f + 12.9, z * f + 4.4)
	end
	if octaves >= 3 then
		f *= 2.3
		detail += 0.25 * noise3(x * f + 8.3, y * f + 27.1, z * f + 19.5)
	end
	local ee = e + K_COAST_DETAIL * detail
	local hh = heat + K_POLAR_DETAIL * detail
	local snowW = smoothstep(K_SNOW_HEAT + K_SNOW_EDGE, K_SNOW_HEAT - K_SNOW_EDGE, hh)
	local r, g, b
	local kind: Kind = "Ocean"
	-- water and land colours are blended over a thin band so coastlines are anti-aliased
	local landW = smoothstep(-K_COAST_AA, K_COAST_AA, ee)
	local wr, wg, wb = 0, 0, 0
	if landW < 1 then
		-- water: turquoise shallows -> blue -> deep blue
		local depth = math.max(-ee, 0)
		local t1 = smoothstep(0, K_SHALLOW_DEPTH, depth)
		local t2 = smoothstep(K_SHALLOW_DEPTH, K_DEEP_DEPTH, depth)
		r = C_SHALLOW[1] + (C_MID[1] - C_SHALLOW[1]) * t1
		g = C_SHALLOW[2] + (C_MID[2] - C_SHALLOW[2]) * t1
		b = C_SHALLOW[3] + (C_MID[3] - C_SHALLOW[3]) * t1
		r += (C_DEEP[1] - r) * t2
		g += (C_DEEP[2] - g) * t2
		b += (C_DEEP[3] - b) * t2
		local grain = 1 + 0.5 * K_GRAIN * detail
		wr, wg, wb = r * grain, g * grain, b * grain
		r, g, b = wr, wg, wb
	end
	if landW > 0 then
		local cold = smoothstep(K_TUNDRA_HEAT1, K_TUNDRA_HEAT0, hh)
		-- grass: dry -> lush with moisture, greyer toward the poles
		local lush = clamp01(m * 1.6 - 0.3)
		r = C_GRASS_DRY[1] + (C_GRASS_LUSH[1] - C_GRASS_DRY[1]) * lush
		g = C_GRASS_DRY[2] + (C_GRASS_LUSH[2] - C_GRASS_DRY[2]) * lush
		b = C_GRASS_DRY[3] + (C_GRASS_LUSH[3] - C_GRASS_DRY[3]) * lush
		r += (C_TUNDRA[1] - r) * cold
		g += (C_TUNDRA[2] - g) * cold
		b += (C_TUNDRA[3] - b) * cold
		kind = "Grass"
		-- forest
		local forestW = smoothstep(K_FOREST_M0, K_FOREST_M1, m + 0.08 * detail)
		if forestW > 0 then
			local fr = C_FOREST[1] + (C_BOREAL[1] - C_FOREST[1]) * cold
			local fg = C_FOREST[2] + (C_BOREAL[2] - C_FOREST[2]) * cold
			local fb = C_FOREST[3] + (C_BOREAL[3] - C_FOREST[3]) * cold
			r += (fr - r) * forestW
			g += (fg - g) * forestW
			b += (fb - b) * forestW
			if forestW >= 0.5 then
				kind = "Forest"
			end
		end
		-- desert
		local desertW = smoothstep(K_DESERT_M0, K_DESERT_M1, m + 0.06 * detail) * smoothstep(0.35, K_DESERT_HEAT, hh)
		if desertW > 0 then
			local dune = 0.5 + 0.5 * d1
			local dr = C_DESERT[1] + (C_DUNE[1] - C_DESERT[1]) * dune
			local dg = C_DESERT[2] + (C_DUNE[2] - C_DESERT[2]) * dune
			local db = C_DESERT[3] + (C_DUNE[3] - C_DESERT[3]) * dune
			r += (dr - r) * desertW
			g += (dg - g) * desertW
			b += (db - b) * desertW
			if desertW >= 0.5 then
				kind = "Desert"
			end
		end
		-- mountains
		local mountain = rg * smoothstep(K_MOUNT_E0, K_MOUNT_E1, ee) + 0.06 * detail
		local rockW = smoothstep(K_ROCK0, K_ROCK1, mountain)
		if rockW > 0 then
			local shade = 0.5 + 0.5 * d1
			local rr = C_ROCK[1] + (C_ROCK_DARK[1] - C_ROCK[1]) * shade
			local rgg = C_ROCK[2] + (C_ROCK_DARK[2] - C_ROCK[2]) * shade
			local rb = C_ROCK[3] + (C_ROCK_DARK[3] - C_ROCK[3]) * shade
			r += (rr - r) * rockW
			g += (rgg - g) * rockW
			b += (rb - b) * rockW
			if rockW >= 0.5 then
				kind = "Rock"
			end
		end
		snowW = math.max(snowW, smoothstep(K_PEAK0, K_PEAK1, mountain))
		-- beaches
		local beachW = smoothstep(K_BEACH_WIDTH, K_BEACH_WIDTH * 0.35, ee) * (1 - cold)
		if beachW > 0 then
			r += (C_BEACH[1] - r) * beachW
			g += (C_BEACH[2] - g) * beachW
			b += (C_BEACH[3] - b) * beachW
			if beachW >= 0.5 then
				kind = "Beach"
			end
		end
		local grain = 1 + K_GRAIN * detail
		r, g, b = r * grain, g * grain, b * grain
		if landW < 1 then
			r += (wr - r) * (1 - landW)
			g += (wg - g) * (1 - landW)
			b += (wb - b) * (1 - landW)
		end
		if ee < 0 then
			kind = "Ocean"
		end
	end
	-- polar ice (over land and sea) and snowy peaks
	if snowW > 0 then
		local shade = 0.5 + 0.5 * d1
		local sr = C_SNOW[1] + (C_SNOW_SHADE[1] - C_SNOW[1]) * shade
		local sg = C_SNOW[2] + (C_SNOW_SHADE[2] - C_SNOW[2]) * shade
		local sb = C_SNOW[3] + (C_SNOW_SHADE[3] - C_SNOW[3]) * shade
		r += (sr - r) * snowW
		g += (sg - g) * snowW
		b += (sb - b) * snowW
		if snowW >= 0.5 then
			kind = "Snow"
		end
	end
	return clamp01(r), clamp01(g), clamp01(b), 1, kind
end

-- Cloud cover field (before the per-pixel threshold).
local function cloudFields(x: number, y: number, z: number): (number, number, number, number)
	local wf = CLOUD_WARP_FREQ
	local wx = noise3(x * wf + 2.7, y * wf + 6.6, z * wf + 1.1)
	local wy = noise3(x * wf + 7.4, y * wf + 0.8, z * wf + 3.3)
	local wz = noise3(x * wf + 5.5, y * wf + 4.2, z * wf + 9.9)
	local px, py, pz = x + CLOUD_WARP_STRENGTH * wx, y + CLOUD_WARP_STRENGTH * wy, z + CLOUD_WARP_STRENGTH * wz
	local c = fbm(px * CLOUD_FREQ + 13.1, py * CLOUD_FREQ + 3.7, pz * CLOUD_FREQ + 8.2, CLOUD_OCTAVES, CLOUD_GAIN)
	local ay = math.abs(y)
	local e = ay / CLOUD_BAND_WIDTH
	local mid = (ay - CLOUD_MIDLAT) / CLOUD_BAND_WIDTH
	c += CLOUD_BAND * (math.exp(-e * e) + math.exp(-mid * mid) - 0.6)
	return c, 0, 0, 0
end

local function cloudShade(
	x: number,
	y: number,
	z: number,
	c: number,
	_f2: number,
	_f3: number,
	_f4: number,
	_octaves: number
): (number, number, number, number, Kind)
	local f = CLOUD_DETAIL_FREQ
	local d = noise3(x * f, y * f, z * f)
	local alpha = smoothstep(CLOUD_COVER0, CLOUD_COVER1, c + CLOUD_DETAIL * d) * CLOUD_MAX_ALPHA
	return 1, 1, 1, alpha, "Plain"
end

--============================================================================
-- Mun
--============================================================================
type RayCrater = {
	x: number,
	y: number,
	z: number,
	e1x: number,
	e1y: number,
	e1z: number,
	e2x: number,
	e2y: number,
	e2z: number,
	radius: number, -- rad
	cosReach: number,
	k1: number,
	k2: number,
	ph1: number,
	ph2: number,
}

local rayCraters: { RayCrater } = {}
do
	for _ = 1, RAY_CRATERS do
		local zz = nextRandom() * 2 - 1
		local phi = nextRandom() * 2 * math.pi
		local rr = math.sqrt(1 - zz * zz)
		local x, y, z = rr * math.cos(phi), rr * math.sin(phi), zz
		-- tangent basis: e1 = normalize(ref x d), e2 = d x e1
		local refX, refY, refZ = 0, 1, 0
		if math.abs(y) > 0.9 then
			refX, refY = 1, 0
		end
		local e1x, e1y, e1z = refY * z - refZ * y, refZ * x - refX * z, refX * y - refY * x
		local len = math.sqrt(e1x * e1x + e1y * e1y + e1z * e1z)
		e1x, e1y, e1z = e1x / len, e1y / len, e1z / len
		local e2x, e2y, e2z = y * e1z - z * e1y, z * e1x - x * e1z, x * e1y - y * e1x
		local radius = RAY_RADIUS_MIN + (RAY_RADIUS_MAX - RAY_RADIUS_MIN) * nextRandom()
		table.insert(rayCraters, {
			x = x,
			y = y,
			z = z,
			e1x = e1x,
			e1y = e1y,
			e1z = e1z,
			e2x = e2x,
			e2y = e2y,
			e2z = e2z,
			radius = radius,
			cosReach = math.cos(radius * RAY_REACH),
			k1 = 5 + math.floor(nextRandom() * 5),
			k2 = 11 + math.floor(nextRandom() * 7),
			ph1 = nextRandom() * 2 * math.pi,
			ph2 = nextRandom() * 2 * math.pi,
		})
	end
end

-- Brightness change of a crater at t = distance / rim radius.
local function craterProfile(t: number): number
	if t < 0.8 then
		return -CRATER_FLOOR * (1 - 0.4 * t * t)
	elseif t < 1 then
		local k = (t - 0.8) / 0.2
		return -CRATER_FLOOR * 0.74 + (CRATER_RIM + CRATER_FLOOR * 0.74) * k
	elseif t < 1.15 then
		local k = (t - 1) / 0.15
		return CRATER_RIM + (CRATER_EJECTA - CRATER_RIM) * k
	end
	return CRATER_EJECTA * (1 - (t - 1.15) / (CRATER_EXTENT - 1.15))
end

-- (mare mask 0..1, highland variation ~-1..1)
local function dentFields(x: number, y: number, z: number): (number, number, number, number)
	local mf = D_MARE_FREQ
	local mare = smoothstep(D_MARE0, D_MARE1, fbm(x * mf + 4.1, y * mf + 9.3, z * mf + 2.8, D_MARE_OCTAVES, 0.5))
	local hf = D_HIGHLAND_FREQ
	local hv = fbm(x * hf + 1.9, y * hf + 6.4, z * hf + 3.2, D_HIGHLAND_OCTAVES, 0.5)
	return mare, hv, 0, 0
end

local function dentShade(
	x: number,
	y: number,
	z: number,
	mare: number,
	hv: number,
	_f3: number,
	_f4: number,
	octaves: number
): (number, number, number, number, Kind)
	local hvv = 1 + D_HIGHLAND_VAR * hv
	local r = (C_HIGHLAND[1] + (C_MARE[1] - C_HIGHLAND[1]) * mare) * hvv
	local g = (C_HIGHLAND[2] + (C_MARE[2] - C_HIGHLAND[2]) * mare) * hvv
	local b = (C_HIGHLAND[3] + (C_MARE[3] - C_HIGHLAND[3]) * mare) * hvv

	-- craters: one jittered crater per cell of an equal-angle grid on each cube face. A crater belongs to the face
	-- of its cell, but points on neighbouring faces measure it in that face's (extended) coordinates too, so
	-- craters straddle cube edges seamlessly.
	local delta = 0
	local minT = math.huge
	local scales = math.min(#CRATER_FACE_CELLS, octaves + 1) -- the smallest craters only on detailed textures
	for axis = 1, 3 do
		-- only the three faces on this point's side can own a crater that reaches it
		local face, dn, du, dv
		if axis == 1 then
			if x >= 0 then
				face, dn, du, dv = 1, x, z, y
			else
				face, dn, du, dv = 2, -x, -z, y
			end
		elseif axis == 2 then
			if y >= 0 then
				face, dn, du, dv = 3, y, x, z
			else
				face, dn, du, dv = 4, -y, x, -z
			end
		else
			if z >= 0 then
				face, dn, du, dv = 5, z, -x, y
			else
				face, dn, du, dv = 6, -z, x, y
			end
		end
		if dn > 0.05 and math.abs(du) < FACE_REACH * dn and math.abs(dv) < FACE_REACH * dn then
			local fa = math.atan(du / dn) + QUARTER_PI -- 0 .. pi/2 on this face, beyond it on neighbours
			local fb = math.atan(dv / dn) + QUARTER_PI
			for k = 1, scales do
				local n = CRATER_FACE_CELLS[k]
				local ga, gb = fa * n / HALF_PI, fb * n / HALF_PI
				local ia, ib = math.floor(ga), math.floor(gb)
				if ia >= -1 and ia <= n and ib >= -1 and ib <= n then
					local prob = CRATER_PROB[k]
					local rMin = CRATER_RMIN[k]
					local rSpan = CRATER_RMAX[k] - rMin
					local strength = CRATER_STRENGTH[k]
					local salt = face * 41 + k * 97
					-- only neighbour cells whose craters can reach this point
					local reach = CRATER_EXTENT * CRATER_RMAX[k]
					local fra, frb = ga - ia, gb - ib
					local a0 = if fra < reach then ia - 1 else ia
					local a1 = if 1 - fra < reach then ia + 1 else ia
					local b0 = if frb < reach then ib - 1 else ib
					local b1 = if 1 - frb < reach then ib + 1 else ib
					for ci = math.max(a0, 0), math.min(a1, n - 1) do
						local hi = PERM[(ci + salt) % 256 + 1]
						for cj = math.max(b0, 0), math.min(b1, n - 1) do
							local h = PERM[hi + cj % 256 + 1] + 1
							if RAND_P[h] < prob then
								local s = RAND_S[h]
								local rr = rMin + rSpan * s * s
								local da = ga - (ci + RAND_X[h])
								local db = gb - (cj + RAND_Y[h])
								local d2 = da * da + db * db
								local cutoff = CRATER_EXTENT * rr
								if d2 < cutoff * cutoff then
									local t = math.sqrt(d2) / rr
									delta += strength * craterProfile(t)
									if t < minT then
										minT = t
									end
								end
							end
						end
					end
				end
			end
		end
	end

	-- young bright craters with rays
	local ray = 0
	for _, rc in rayCraters do
		local dp = x * rc.x + y * rc.y + z * rc.z
		if dp > rc.cosReach then
			local t = math.acos(math.min(dp, 1)) / rc.radius
			if t < 1.15 then
				delta += craterProfile(t) * 0.5
				ray += RAY_STRENGTH * 0.6
				if t < minT then
					minT = t
				end
			else
				local az = math.atan2(x * rc.e2x + y * rc.e2y + z * rc.e2z, x * rc.e1x + y * rc.e1y + z * rc.e1z)
				local spokes = (0.5 + 0.5 * math.cos(rc.k1 * az + rc.ph1)) * (0.5 + 0.5 * math.cos(rc.k2 * az + rc.ph2))
				local fall = 1 - (t - 1.15) / (RAY_REACH - 1.15)
				ray += RAY_STRENGTH * spokes * spokes * fall * fall
			end
		end
	end

	local f = D_DETAIL_FREQ
	local grain = 1 + D_GRAIN * noise3(x * f, y * f, z * f) + delta
	r, g, b = r * grain, g * grain, b * grain
	if ray > 0 then
		local w = clamp01(ray)
		r += (C_RAY[1] - r) * w
		g += (C_RAY[2] - g) * w
		b += (C_RAY[3] - b) * w
	end
	local kind: Kind
	if minT < 1 then
		kind = "Crater"
	elseif ray > RAY_KIND_LEVEL then
		kind = "Ray"
	elseif mare >= 0.5 then
		kind = "Mare"
	else
		kind = "Highland"
	end
	return clamp01(r), clamp01(g), clamp01(b), 1, kind
end

--============================================================================
-- Relief hooks (CHANGED (Phase 8): Sim/Relief shapes the terrain from these exact fields and craters, so hills,
-- coasts, mountains, maria and craters stand where this module paints them)
--============================================================================

-- cos of the angle within which a ray crater's relief (bowl, rim, ejecta: CRATER_EXTENT rim radii) reaches
local rayReliefCos: { number } = {}
for index, rc in rayCraters do
	rayReliefCos[index] = math.cos(rc.radius * CRATER_EXTENT)
end

--[[
	The two low-frequency numbers the ground shape is built from, at unit direction (x, y, z):
	  Earth: (ee, mountain) = coast-level elevation (< 0 is ocean, exactly where sample() says "Ocean"), computed
	         exactly as earthShade does at sample()'s detail level, and the smooth mountain mask (earthShade's
	         mountain value without its per-pixel jitter and coast detail: rock from about K_ROCK0, snowy peaks from
	         about K_PEAK0)
	  Mun:   (mare 0..1, highland variation ~-1..1)
	  other: (0, 0)
]]
function Biome.reliefFields(bodyId: number, x: number, y: number, z: number): (number, number)
	if bodyId == HOMEWORLD then
		local e, _, rg, _ = earthFields(x, y, z)
		-- same detail sum as earthShade at K_DETAIL_OCTAVES (3)
		local f = K_DETAIL_FREQ
		local detail = noise3(x * f, y * f, z * f)
		f *= 2.3
		detail += 0.5 * noise3(x * f + 31.7, y * f + 12.9, z * f + 4.4)
		f *= 2.3
		detail += 0.25 * noise3(x * f + 8.3, y * f + 27.1, z * f + 19.5)
		local ee = e + K_COAST_DETAIL * detail
		return ee, rg * smoothstep(K_MOUNT_E0, K_MOUNT_E1, e)
	elseif bodyId == MOON then
		local mare, hv = dentFields(x, y, z)
		return mare, hv
	end
	return 0, 0
end

export type CraterVisitor = (t: number, radius: number, scale: number) -> number

--[[
	Sum of visit(t, radius, scale) over every Mun crater whose relief reaches unit direction (x, y, z): t = distance /
	rim radius (< CRATER_EXTENT), radius = rim radius in radians, scale = 1 .. 3 for the cell craters (largest first)
	and 0 for the young ray craters. Same cells, jitter, sizes and cube-edge handling as the painted craters
	(dentShade), at every scale.
]]
function Biome.craterSum(x: number, y: number, z: number, visit: CraterVisitor): number
	local sum = 0
	local scales = #CRATER_FACE_CELLS
	for axis = 1, 3 do
		local face, dn, du, dv
		if axis == 1 then
			if x >= 0 then
				face, dn, du, dv = 1, x, z, y
			else
				face, dn, du, dv = 2, -x, -z, y
			end
		elseif axis == 2 then
			if y >= 0 then
				face, dn, du, dv = 3, y, x, z
			else
				face, dn, du, dv = 4, -y, x, -z
			end
		else
			if z >= 0 then
				face, dn, du, dv = 5, z, -x, y
			else
				face, dn, du, dv = 6, -z, x, y
			end
		end
		if dn > 0.05 and math.abs(du) < FACE_REACH * dn and math.abs(dv) < FACE_REACH * dn then
			local fa = math.atan(du / dn) + QUARTER_PI
			local fb = math.atan(dv / dn) + QUARTER_PI
			for k = 1, scales do
				local n = CRATER_FACE_CELLS[k]
				local ga, gb = fa * n / HALF_PI, fb * n / HALF_PI
				local ia, ib = math.floor(ga), math.floor(gb)
				if ia >= -1 and ia <= n and ib >= -1 and ib <= n then
					local prob = CRATER_PROB[k]
					local rMin = CRATER_RMIN[k]
					local rSpan = CRATER_RMAX[k] - rMin
					local salt = face * 41 + k * 97
					local reach = CRATER_EXTENT * CRATER_RMAX[k]
					local fra, frb = ga - ia, gb - ib
					local a0 = if fra < reach then ia - 1 else ia
					local a1 = if 1 - fra < reach then ia + 1 else ia
					local b0 = if frb < reach then ib - 1 else ib
					local b1 = if 1 - frb < reach then ib + 1 else ib
					local cellAngle = HALF_PI / n
					for ci = math.max(a0, 0), math.min(a1, n - 1) do
						local hi = PERM[(ci + salt) % 256 + 1]
						for cj = math.max(b0, 0), math.min(b1, n - 1) do
							local h = PERM[hi + cj % 256 + 1] + 1
							if RAND_P[h] < prob then
								local s = RAND_S[h]
								local rr = rMin + rSpan * s * s
								local da = ga - (ci + RAND_X[h])
								local db = gb - (cj + RAND_Y[h])
								local d2 = da * da + db * db
								local cutoff = CRATER_EXTENT * rr
								if d2 < cutoff * cutoff then
									sum += visit(math.sqrt(d2) / rr, rr * cellAngle, k)
								end
							end
						end
					end
				end
			end
		end
	end
	for index, rc in rayCraters do
		local dp = x * rc.x + y * rc.y + z * rc.z
		if dp > rayReliefCos[index] then
			sum += visit(math.acos(math.min(dp, 1)) / rc.radius, rc.radius, 0)
		end
	end
	return sum
end

Biome.CRATER_EXTENT = CRATER_EXTENT -- CHANGED (Phase 8): relief reach in rim radii (Sim/Relief)

--============================================================================
-- Other bodies: flat body colour
--============================================================================
local function plainFields(_x: number, _y: number, _z: number): (number, number, number, number)
	return 0, 0, 0, 0
end

local plainColors: { [number]: { number } } = {}
for _, body in Bodies.List do
	plainColors[body.Id] = { body.Color.R, body.Color.G, body.Color.B }
end

local function plainShadeFor(bodyId: number): ShadeFn
	local c = plainColors[bodyId] or { 0.5, 0.5, 0.5 }
	return function(
		_x: number,
		_y: number,
		_z: number,
		_f1: number,
		_f2: number,
		_f3: number,
		_f4: number,
		_octaves: number
	): (number, number, number, number, Kind)
		return c[1], c[2], c[3], 1, "Plain"
	end
end

local function noClouds(
	_x: number,
	_y: number,
	_z: number,
	_f1: number,
	_f2: number,
	_f3: number,
	_f4: number,
	_octaves: number
): (number, number, number, number, Kind)
	return 1, 1, 1, 0, "Plain"
end

local groundFields: { [number]: FieldsFn } = {}
local groundShade: { [number]: ShadeFn } = {}
for _, body in Bodies.List do
	if body.Id == HOMEWORLD then
		groundFields[body.Id], groundShade[body.Id] = earthFields, earthShade
	elseif body.Id == MOON then
		groundFields[body.Id], groundShade[body.Id] = dentFields, dentShade
	else
		groundFields[body.Id], groundShade[body.Id] = plainFields, plainShadeFor(body.Id)
	end
end

local function fieldsFor(bodyId: number, layer: Layer): FieldsFn
	if layer == "Clouds" then
		return if bodyId == HOMEWORLD then cloudFields else plainFields
	end
	return groundFields[bodyId] or plainFields
end

local function shadeFor(bodyId: number, layer: Layer): ShadeFn
	if layer == "Clouds" then
		return if bodyId == HOMEWORLD then cloudShade else noClouds
	end
	return groundShade[bodyId] or plainShadeFor(bodyId)
end

--============================================================================
-- Point samples
--============================================================================

-- Ground colour (0..1) and biome kind at unit direction (x, y, z) from the body centre (body axes).
function Biome.sample(bodyId: number, x: number, y: number, z: number): (number, number, number, Kind)
	local fields: FieldsFn = groundFields[bodyId] or plainFields
	local shade: ShadeFn = groundShade[bodyId] or plainShadeFor(bodyId)
	local f1, f2, f3, f4 = fields(x, y, z)
	local r, g, b, _, kind = shade(x, y, z, f1, f2, f3, f4, K_DETAIL_OCTAVES)
	return r, g, b, kind :: Kind
end

function Biome.hasClouds(bodyId: number): boolean
	return bodyId == HOMEWORLD
end

-- Cloud opacity (0..1) at unit direction (x, y, z).
function Biome.clouds(bodyId: number, x: number, y: number, z: number): number
	if bodyId ~= HOMEWORLD then
		return 0
	end
	local c = cloudFields(x, y, z)
	local _, _, _, alpha = cloudShade(x, y, z, c, 0, 0, 0, 1)
	return alpha
end

local averageCache: { [number]: { number } } = {}

-- Mean ground colour over the sphere (Fibonacci-sphere samples), cached.
function Biome.averageColor(bodyId: number): (number, number, number)
	local cached = averageCache[bodyId]
	if cached then
		return cached[1], cached[2], cached[3]
	end
	local count = 400
	local golden = math.pi * (3 - math.sqrt(5))
	local sr, sg, sb = 0, 0, 0
	for i = 0, count - 1 do
		local y = 1 - (i + 0.5) * 2 / count
		local rr = math.sqrt(1 - y * y)
		local phi = golden * i
		local r, g, b = Biome.sample(bodyId, rr * math.cos(phi), y, rr * math.sin(phi))
		sr += r
		sg += g
		sb += b
	end
	local result = { sr / count, sg / count, sb / count }
	averageCache[bodyId] = result
	return result[1], result[2], result[3]
end

--============================================================================
-- Props
--============================================================================
local PROP_MIX: { [string]: { { kind: PropKind, weight: number } } } = {
	Beach = { { kind = "Rock", weight = 1 } },
	Grass = {
		{ kind = "RoundTree", weight = 0.42 },
		{ kind = "Bush", weight = 0.36 },
		{ kind = "Rock", weight = 0.12 },
		{ kind = "PineTree", weight = 0.1 },
	},
	Forest = {
		{ kind = "RoundTree", weight = 0.45 },
		{ kind = "PineTree", weight = 0.45 },
		{ kind = "Bush", weight = 0.1 },
	},
	Desert = { { kind = "Cactus", weight = 0.65 }, { kind = "Rock", weight = 0.35 } },
	Rock = { { kind = "Rock", weight = 0.8 }, { kind = "PineTree", weight = 0.2 } },
	Snow = { { kind = "SnowPine", weight = 0.7 }, { kind = "Rock", weight = 0.3 } },
	Mare = { { kind = "Boulder", weight = 0.9 }, { kind = "CraterRim", weight = 0.1 } },
	Highland = { { kind = "Boulder", weight = 0.85 }, { kind = "CraterRim", weight = 0.15 } },
	Crater = { { kind = "Boulder", weight = 0.6 }, { kind = "CraterRim", weight = 0.4 } },
	Ray = { { kind = "Boulder", weight = 1 } },
}

-- Expected props per hectare (10,000 m^2) on this kind of ground.
function Biome.propDensity(kind: string): number
	return PROP_DENSITY[kind] or 0
end

-- Which prop grows here, for a uniform roll in [0, 1); nil when this ground has none.
function Biome.propKind(kind: string, roll: number): PropKind?
	local mix = PROP_MIX[kind]
	if mix == nil then
		return nil
	end
	local acc = 0
	for _, entry in mix do
		acc += entry.weight
		if roll < acc then
			return entry.kind
		end
	end
	return mix[#mix].kind
end

--============================================================================
-- Texture space
--============================================================================

-- Surface parameter (s, t) -> mesh UV.
function Biome.paramToUV(s: number, t: number): (number, number)
	local span = 1 - 2 * UV_INSET
	local u, v = UV_INSET + s * span, UV_INSET + t * span
	if UV_FLIP_V then
		v = 1 - v
	end
	return u, v
end

-- Mesh UV -> surface parameter (s, t) (inverse of paramToUV).
function Biome.uvToParam(u: number, v: number): (number, number)
	if UV_FLIP_V then
		v = 1 - v
	end
	local span = 1 - 2 * UV_INSET
	return (u - UV_INSET) / span, (v - UV_INSET) / span
end

-- Patch-local cube coordinate (x or z in [-1, 0] on the +Y face quarter) -> parameter, and back.
function Biome.cubeToParam(c: number): number
	return (math.atan(c) + QUARTER_PI) / QUARTER_PI
end

function Biome.paramToCube(p: number): number
	return math.tan(p * QUARTER_PI - QUARTER_PI)
end

-- Unit direction (body axes) of patch parameter (s, t) for the patch rotated by `m` (row-major 3x3).
function Biome.patchDirection(m: { number }, s: number, t: number): (number, number, number)
	local lx, ly, lz = math.tan(s * QUARTER_PI - QUARTER_PI), 1, math.tan(t * QUARTER_PI - QUARTER_PI)
	local inv = 1 / math.sqrt(lx * lx + ly * ly + lz * lz)
	lx, ly, lz = lx * inv, ly * inv, lz * inv
	return m[1] * lx + m[2] * ly + m[3] * lz, m[4] * lx + m[5] * ly + m[6] * lz, m[7] * lx + m[8] * ly + m[9] * lz
end

-- The 24 proper rotations of the cube (signed permutation matrices with determinant +1), row-major 3x3, in a fixed
-- order. Patch i of every body is the +Y face quarter rotated by matrix i.
function Biome.cubeRotations(): { { number } }
	local permutations = { { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 }, { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 } }
	local parity = { 1, -1, -1, 1, 1, -1 }
	local matrices: { { number } } = {}
	for index, permutation in permutations do
		for mask = 0, 7 do
			local signs = {
				if mask % 2 == 1 then -1 else 1,
				if math.floor(mask / 2) % 2 == 1 then -1 else 1,
				if math.floor(mask / 4) % 2 == 1 then -1 else 1,
			}
			if parity[index] * signs[1] * signs[2] * signs[3] == 1 then
				local m = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }
				for row = 1, 3 do
					m[(row - 1) * 3 + permutation[row]] = signs[row]
				end
				table.insert(matrices, m)
			end
		end
	end
	return matrices
end

--============================================================================
-- Painters
--============================================================================
local IDENTITY = { 1, 0, 0, 0, 1, 0, 0, 0, 1 }

-- A reusable painter for size x size images with a coarse grid of `cells` per side (cells <= size / 2, and
-- 1 / cells >= UV_INSET so the grid covers the padding pixels).
function Biome.newPainter(size: number, cells: number, buf: buffer): Painter
	assert(buffer.len(buf) >= size * size * 4, "Biome.newPainter: buffer too small")
	assert(Biome.uvToParam(0.5 / size, 0.5) >= -1 / cells - 1e-9, "Biome.newPainter: grid does not cover the padding")
	local nodes = cells + 3
	local count = nodes * nodes
	local colI: { number } = table.create(size, 0)
	local colF: { number } = table.create(size, 0)
	for px = 0, size - 1 do
		local s = Biome.uvToParam((px + 0.5) / size, 0.5)
		local gs = s * cells + 1
		local i0 = math.clamp(math.floor(gs), 0, nodes - 2)
		colI[px + 1] = i0
		colF[px + 1] = gs - i0
	end
	return {
		size = size,
		cells = cells,
		nodes = nodes,
		buf = buf,
		colI = colI,
		colF = colF,
		nodeX = table.create(count, 0),
		nodeY = table.create(count, 0),
		nodeZ = table.create(count, 0),
		nodeF1 = table.create(count, 0),
		nodeF2 = table.create(count, 0),
		nodeF3 = table.create(count, 0),
		nodeF4 = table.create(count, 0),
		fields = plainFields,
		shade = noClouds,
		octaves = 1,
		rect = false,
		m = IDENTITY,
		cx = 0,
		cy = 0,
		cz = 0,
		ax = 1,
		ay = 0,
		az = 0,
		bx = 0,
		by = 0,
		bz = 1,
		ex = 1,
		ez = 1,
		nodeRow = 0,
		pixelRow = 0,
		done = true,
		oceanPixels = 0,
		sumR = 0,
		sumG = 0,
		sumB = 0,
	}
end

local function beginJob(p: Painter, bodyId: number, layer: Layer, octaves: number)
	p.fields = fieldsFor(bodyId, layer)
	p.shade = shadeFor(bodyId, layer)
	p.octaves = octaves
	p.nodeRow = 0
	p.pixelRow = 0
	p.done = false
	p.oceanPixels = 0
	p.sumR, p.sumG, p.sumB = 0, 0, 0
end

-- Aims the painter at scaled-space patch `m` (row-major cube rotation) of `bodyId`.
function Biome.beginPatch(p: Painter, bodyId: number, layer: Layer, m: { number }, octaves: number)
	beginJob(p, bodyId, layer, octaves)
	p.rect = false
	p.m = m
end

--[[
	Aims the painter at a flat rectangle: centre (cx, cy, cz) in metres from the body centre, unit axes A (along s)
	and B (along t), extents ex, ez (m). Pixels sample the direction of the rectangle point under them.
]]
function Biome.beginRect(
	p: Painter,
	bodyId: number,
	layer: Layer,
	cx: number,
	cy: number,
	cz: number,
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number,
	ex: number,
	ez: number,
	octaves: number
)
	beginJob(p, bodyId, layer, octaves)
	p.rect = true
	p.cx, p.cy, p.cz = cx, cy, cz
	p.ax, p.ay, p.az = ax, ay, az
	p.bx, p.by, p.bz = bx, by, bz
	p.ex, p.ez = ex, ez
end

-- Unit direction of surface parameter (s, t) for the painter's current job.
local function jobDirection(p: Painter, s: number, t: number): (number, number, number)
	if p.rect then
		local u, w = (s - 0.5) * p.ex, (t - 0.5) * p.ez
		local x = p.cx + u * p.ax + w * p.bx
		local y = p.cy + u * p.ay + w * p.by
		local z = p.cz + u * p.az + w * p.bz
		local inv = 1 / math.sqrt(x * x + y * y + z * z)
		return x * inv, y * inv, z * inv
	end
	return Biome.patchDirection(p.m, s, t)
end

-- Test hook: the exact direction the painter assigns to parameter (s, t).
function Biome.painterDirection(p: Painter, s: number, t: number): (number, number, number)
	return jobDirection(p, s, t)
end

local function toByte(v: number): number
	local b = math.floor(v * 255 + 0.5)
	if b < 0 then
		return 0
	elseif b > 255 then
		return 255
	end
	return b
end

-- One unit of work: a grid row, or a pixel row. Returns true when the image is complete.
function Biome.paintStep(p: Painter): boolean
	if p.done then
		return true
	end
	local nodes = p.nodes
	local cells = p.cells
	if p.nodeRow < nodes then
		local k = p.nodeRow
		local t = (k - 1) / cells
		local fields = p.fields
		local nx, ny, nz = p.nodeX, p.nodeY, p.nodeZ
		local n1, n2, n3, n4 = p.nodeF1, p.nodeF2, p.nodeF3, p.nodeF4
		local base = k * nodes
		for i = 0, nodes - 1 do
			local x, y, z = jobDirection(p, (i - 1) / cells, t)
			local idx = base + i + 1
			nx[idx], ny[idx], nz[idx] = x, y, z
			n1[idx], n2[idx], n3[idx], n4[idx] = fields(x, y, z)
		end
		p.nodeRow = k + 1
		return false
	end

	local size = p.size
	local py = p.pixelRow
	local _, t = Biome.uvToParam(0.5, (py + 0.5) / size)
	local gt = t * cells + 1
	local j0 = math.clamp(math.floor(gt), 0, nodes - 2)
	local fv = gt - j0
	local gv = 1 - fv
	local shade = p.shade
	local octaves = p.octaves
	local colI, colF = p.colI, p.colF
	local nx, ny, nz = p.nodeX, p.nodeY, p.nodeZ
	local n1, n2, n3, n4 = p.nodeF1, p.nodeF2, p.nodeF3, p.nodeF4
	local buf = p.buf
	local rowBase = j0 * nodes + 1
	local offset = py * size * 4
	local ocean, sumR, sumG, sumB = 0, 0, 0, 0
	for px = 1, size do
		local fu = colF[px]
		local gu = 1 - fu
		local k00 = rowBase + colI[px]
		local k10 = k00 + 1
		local k01 = k00 + nodes
		local k11 = k01 + 1
		local w00, w10, w01, w11 = gu * gv, fu * gv, gu * fv, fu * fv
		local x = nx[k00] * w00 + nx[k10] * w10 + nx[k01] * w01 + nx[k11] * w11
		local y = ny[k00] * w00 + ny[k10] * w10 + ny[k01] * w01 + ny[k11] * w11
		local z = nz[k00] * w00 + nz[k10] * w10 + nz[k01] * w01 + nz[k11] * w11
		local inv = 1 / math.sqrt(x * x + y * y + z * z)
		x, y, z = x * inv, y * inv, z * inv
		local r, g, b, a, kind = shade(
			x,
			y,
			z,
			n1[k00] * w00 + n1[k10] * w10 + n1[k01] * w01 + n1[k11] * w11,
			n2[k00] * w00 + n2[k10] * w10 + n2[k01] * w01 + n2[k11] * w11,
			n3[k00] * w00 + n3[k10] * w10 + n3[k01] * w01 + n3[k11] * w11,
			n4[k00] * w00 + n4[k10] * w10 + n4[k01] * w01 + n4[k11] * w11,
			octaves
		)
		if kind == "Ocean" then
			ocean += 1
		end
		sumR += r
		sumG += g
		sumB += b
		buffer.writeu32(buf, offset, toByte(r) + toByte(g) * 256 + toByte(b) * 65536 + toByte(a) * 16777216)
		offset += 4
	end
	p.oceanPixels += ocean
	p.sumR += sumR
	p.sumG += sumG
	p.sumB += sumB
	p.pixelRow = py + 1
	if py + 1 >= size then
		p.done = true
		return true
	end
	return false
end

Biome.UV_INSET = UV_INSET
Biome._test = { gradientNoise3 = gradientNoise3, noise3 = noise3 }

return table.freeze(Biome)
