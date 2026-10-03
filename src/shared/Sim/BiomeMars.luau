--!strict
--!native
--[[
	BiomeMars (new file, Solar system; D51)
	Mars' look and ground shape, sampled by unit direction (x, y, z) from Mars' centre in Mars' axes. Pure and
	deterministic (Luau's math.noise, the same C code in Roblox and Lune, and our own integer hash), so the space
	view, the ground view, the props and the server's ground agree. Biome registers fields / shade as Mars' painter
	functions; Relief uses height; SurfaceHeight caches it on its lattice like Earth and the Mun.

	What is on Mars:
	  * rust-orange dust with lighter butterscotch highlands and large darker regions (albedo features), fine
	    streaks and grain; the north is a little lower than the south (the real planet's dichotomy)
	  * polar ice caps (white with a pink tint), the northern one larger, on a low dome
	  * craters at three sizes (bowl, raised rim, ejecta), duller than the Mun's: dust fills the small ones
	  * the Big Canyon: a ~50 km long chasm near the equator, ~3.3 km wide and ~1.9 km deep, flat floored with
	    steep layered walls
	  * the Big Volcano: a ~12 km wide shield rising ~4 km, with a 1 km wide caldera on top
	Heights stay inside [MIN_HEIGHT, MAX_HEIGHT] (below the 5 km rails floor: Mars' air top).

	API:
	  BiomeMars.fields(x, y, z) -> (dark, base, canyon, volcano)      low-frequency fields (painters' coarse grid)
	  BiomeMars.shade(x, y, z, dark, base, canyon, volcano, octaves) -> r, g, b, alpha, kind
	  BiomeMars.height(x, y, z) -> metres above Mars' radius
	  BiomeMars.bounds() -> (min, max) metres
	  BiomeMars.KINDS                                 every kind name shade returns
	  BiomeMars.LANDMARKS                              { { name, x, y, z } }: named landing spots (admin panel)
]]

--============================================================================
-- Tunables
--============================================================================
local RADIUS = 30000 -- m, Mars' radius (Config/Bodies MARS_RADIUS; only scales metres per radian here)
local NOISE_SCALE = 1.4 -- math.noise -> about -1..1 (as Biome / Relief)
local LACUNARITY = 2.05
local OCTAVE_SHIFT = 15.9

-- Albedo (dark regions) and large-scale ground level
local DARK_FREQ = 1.6
local DARK_OCTAVES = 4
local DARK0 = 0.08 -- fbm value where dark regions start ...
local DARK1 = 0.32 -- ... and are fully dark
local BASE_FREQ = 1.1
local BASE_OCTAVES = 3
local DICHOTOMY = 0.3 -- base level change from the south (+) to the north (-)

-- Colours (linear 0..1 RGB, stylised)
local C_DUST = { 0.76, 0.4, 0.2 }
local C_HIGH = { 0.84, 0.55, 0.32 } -- butterscotch highlands
local C_DARK = { 0.4, 0.21, 0.13 }
local C_WALL = { 0.55, 0.29, 0.18 }
local C_WALL_BAND = { 0.72, 0.45, 0.28 } -- lighter layers in the canyon walls
local C_FLOOR = { 0.68, 0.37, 0.2 }
local C_VOLCANO = { 0.58, 0.29, 0.17 }
local C_CALDERA = { 0.33, 0.17, 0.11 }
local C_ICE = { 0.96, 0.93, 0.92 }
local C_ICE_SHADE = { 0.86, 0.76, 0.72 }
local GRAIN = 0.06 -- +/- brightness
local GRAIN_FREQ = 55
local STREAK_FREQ = 9 -- wind streaks (stretched east-west)
local STREAK = 0.05

-- Polar caps (|y| = sin latitude)
local NORTH_CAP0 = 0.955 -- ~73 degrees north
local NORTH_CAP1 = 0.97
local SOUTH_CAP0 = 0.972 -- ~76 degrees south (the southern cap is smaller)
local SOUTH_CAP1 = 0.982
local CAP_NOISE = 0.015
local CAP_DOME = 220 -- m

-- Big Canyon: a great-circle arc between two points (lat, lon in degrees), with wiggle
local CANYON_A = { -7, -100 }
local CANYON_B = { -10, -0 }
local CANYON_HALF_WIDTH = 0.055 -- rad (~1.65 km)
local CANYON_WIDTH_VAR = 0.3 -- +/- share of the half width
local CANYON_FLOOR_SHARE = 0.4 -- inner share of the half width that is flat floor
local CANYON_WIGGLE = 0.016 -- rad
local CANYON_TAPER = 0.15 -- rad at each end over which the canyon narrows to nothing
local CANYON_DEPTH = 1900 -- m
local CANYON_BANDS = 9 -- layer bands in the walls

-- Big Volcano (lat, lon in degrees)
local VOLCANO = { 18, -135 }
local VOLCANO_RADIUS = 0.4 -- rad (~12 km)
local VOLCANO_HEIGHT = 4000 -- m
local VOLCANO_POWER = 1.8 -- flank shape (1 - u^p)^q
local VOLCANO_Q = 1.4
local CALDERA_RADIUS = 0.035 -- rad (~1 km)
local CALDERA_DEPTH = 420 -- m

-- Ground relief
local BASE_AMP = 700 -- m
local ROLL_FREQ = 18 -- ~1.7 km rolling ground
local ROLL_OCTAVES = 3
local ROLL_AMP = 55 -- m
local BUMP_FREQ = 90
local BUMP_AMP = 5 -- m
local MIN_HEIGHT = -2600 -- m
local MAX_HEIGHT = 4600 -- m (Mars' rails floor is its 5 km air top)

-- Craters, per scale: cells per cube-face edge, chance per cell, rim radius range (share of a cell), colour
-- strength, bowl depth / rim radius, depth cap (m), rim height / rim radius, rim cap (m)
local CRATER_CELLS = { 5, 14, 36 }
local CRATER_PROB = { 0.35, 0.3, 0.28 }
local CRATER_RMIN = { 0.16, 0.14, 0.12 }
local CRATER_RMAX = { 0.36, 0.34, 0.3 }
local CRATER_SHADE = { 0.9, 0.7, 0.5 }
local CRATER_DEPTH_FRAC = { 0.12, 0.13, 0.14 }
local CRATER_DEPTH_MAX = { 520, 260, 80 }
local CRATER_RIM_FRAC = { 0.035, 0.04, 0.045 }
local CRATER_RIM_MAX = { 130, 60, 18 }
local CRATER_EXTENT = 1.6 -- ejecta reach in rim radii
local FACE_REACH = 2.5
local CRATER_FLOOR_DARK = 0.12
local CRATER_RIM_BRIGHT = 0.14
local CRATER_SALT = 7331
--============================================================================

local BiomeMars = {}

local QUARTER_PI = math.pi / 4
local HALF_PI = math.pi / 2
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

local function clamp01(v: number): number
	if v < 0 then
		return 0
	elseif v > 1 then
		return 1
	end
	return v
end

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

-- Unit direction of a latitude / longitude in degrees (Frames.surfaceUp's convention).
local function direction(latDeg: number, lonDeg: number): (number, number, number)
	local lat, lon = math.rad(latDeg), math.rad(lonDeg)
	return math.cos(lat) * math.cos(lon), math.sin(lat), math.cos(lat) * math.sin(lon)
end

-- (a * b) mod 2^32 in doubles, and a 32-bit mixer (the same scheme as Biome.hash01)
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

local function hash(a: number, b: number, c: number, salt: number): number
	local h = mix32(bit32.bxor(a % 4294967296, salt))
	h = mix32(bit32.bxor(h, b % 4294967296))
	h = mix32(bit32.bxor(h, c % 4294967296))
	return h
end

--============================================================================
-- Landmarks
--============================================================================
local ax, ay, az = direction(CANYON_A[1], CANYON_A[2])
local bx, by, bz = direction(CANYON_B[1], CANYON_B[2])
-- canyon plane normal n = normalize(A x B), and the arc length A -> B
local cnx, cny, cnz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
do
	local len = math.sqrt(cnx * cnx + cny * cny + cnz * cnz)
	cnx, cny, cnz = cnx / len, cny / len, cnz / len
end
local canyonArc = math.acos(math.clamp(ax * bx + ay * by + az * bz, -1, 1))
local vx, vy, vz = direction(VOLCANO[1], VOLCANO[2])
local cosVolcano = math.cos(VOLCANO_RADIUS)

-- 0..1: how deep in the Big Canyon (1 on its floor) at unit direction (x, y, z).
local function canyonDepth(x: number, y: number, z: number): number
	local s = x * cnx + y * cny + z * cnz -- sin of the angle off the canyon's great circle
	if s > CANYON_HALF_WIDTH * 2 or s < -CANYON_HALF_WIDTH * 2 then
		return 0
	end
	-- angle along the arc from A: atan2((A x q) . n, A . q) with q the point projected on the plane
	local qx, qy, qz = x - s * cnx, y - s * cny, z - s * cnz
	local cx, cy, cz = ay * qz - az * qy, az * qx - ax * qz, ax * qy - ay * qx
	local along = math.atan2(cx * cnx + cy * cny + cz * cnz, ax * qx + ay * qy + az * qz)
	if along < -CANYON_TAPER or along > canyonArc + CANYON_TAPER then
		return 0
	end
	local taper = smoothstep(-CANYON_TAPER, CANYON_TAPER, along)
		* smoothstep(canyonArc + CANYON_TAPER, canyonArc - CANYON_TAPER, along)
	local wiggle = CANYON_WIGGLE * mathNoise(x * 7 + 3.1, y * 7 + 8.4, z * 7 + 1.7) * NOISE_SCALE
	local width = CANYON_HALF_WIDTH
		* (1 + CANYON_WIDTH_VAR * mathNoise(x * 4 + 6.6, y * 4 + 2.2, z * 4 + 9.5) * NOISE_SCALE)
		* taper
	if width <= 1e-4 then
		return 0
	end
	local d = math.abs(s + wiggle)
	return 1 - smoothstep(CANYON_FLOOR_SHARE * width, width, d)
end

-- (0..1 volcano shape, caldera 0..1) at unit direction (x, y, z).
local function volcanoShape(x: number, y: number, z: number): (number, number)
	local dot = x * vx + y * vy + z * vz
	if dot <= cosVolcano then
		return 0, 0
	end
	local a = math.acos(math.min(dot, 1))
	local u = a / VOLCANO_RADIUS
	local shape = (1 - u ^ VOLCANO_POWER) ^ VOLCANO_Q
	local caldera = 1 - smoothstep(CALDERA_RADIUS * 0.7, CALDERA_RADIUS * 1.15, a)
	return shape, caldera
end

-- Polar ice 0..1 at unit direction (x, y, z).
local function iceCover(x: number, y: number, z: number): number
	local n = CAP_NOISE * mathNoise(x * 8 + 2.5, y * 8 + 7.3, z * 8 + 4.9) * NOISE_SCALE
	if y > 0 then
		return smoothstep(NORTH_CAP0, NORTH_CAP1, y + n)
	end
	return smoothstep(SOUTH_CAP0, SOUTH_CAP1, -y + n)
end

--============================================================================
-- Craters
--============================================================================

--[[
	Crater relief (m) and colour change at unit direction (x, y, z), over `scales` crater sizes (largest first),
	and the smallest t = distance / rim radius seen (< 1 inside a crater bowl). One jittered crater per cell of an
	equal-angle grid on each cube face; points on neighbouring faces measure a face's craters in its extended
	coordinates, so craters straddle cube edges seamlessly (as the Mun's in Biome).
]]
local function craters(x: number, y: number, z: number, scales: number): (number, number, number)
	local relief, shade, minT = 0, 0, math.huge
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
				local n = CRATER_CELLS[k]
				local ga, gb = fa * n / HALF_PI, fb * n / HALF_PI
				local ia, ib = math.floor(ga), math.floor(gb)
				if ia >= -1 and ia <= n and ib >= -1 and ib <= n then
					local rMin = CRATER_RMIN[k]
					local rSpan = CRATER_RMAX[k] - rMin
					local reach = CRATER_EXTENT * CRATER_RMAX[k]
					local fra, frb = ga - ia, gb - ib
					local a0 = if fra < reach then ia - 1 else ia
					local a1 = if 1 - fra < reach then ia + 1 else ia
					local b0 = if frb < reach then ib - 1 else ib
					local b1 = if 1 - frb < reach then ib + 1 else ib
					local cellMetres = HALF_PI / n * RADIUS
					for ci = math.max(a0, 0), math.min(a1, n - 1) do
						for cj = math.max(b0, 0), math.min(b1, n - 1) do
							local h = hash(face * 64 + k, ci, cj, CRATER_SALT)
							if (h % 1000) / 1000 < CRATER_PROB[k] then
								local s = (math.floor(h / 1000) % 1000) / 1000
								local jx = (math.floor(h / 1000000) % 64) / 64
								local jy = (math.floor(h / 64000000) % 64) / 64
								local rr = rMin + rSpan * s * s
								local da = ga - (ci + 0.15 + 0.7 * jx)
								local db = gb - (cj + 0.15 + 0.7 * jy)
								local d2 = da * da + db * db
								local cutoff = CRATER_EXTENT * rr
								if d2 < cutoff * cutoff then
									local t = math.sqrt(d2) / rr
									local rim = rr * cellMetres
									local depth = math.min(CRATER_DEPTH_FRAC[k] * rim, CRATER_DEPTH_MAX[k])
									local rimHeight = math.min(CRATER_RIM_FRAC[k] * rim, CRATER_RIM_MAX[k])
									local strength = CRATER_SHADE[k]
									if t < 1 then
										relief += -depth + (depth + rimHeight) * t * t * t
										shade += strength * (-CRATER_FLOOR_DARK * (1 - t * t) + CRATER_RIM_BRIGHT * smoothstep(
											0.75,
											1,
											t
										))
									else
										local fall = (CRATER_EXTENT - t) / (CRATER_EXTENT - 1)
										relief += rimHeight * fall * fall
										shade += strength * CRATER_RIM_BRIGHT * 0.6 * fall * fall
									end
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
	return relief, shade, minT
end

--============================================================================
-- API
--============================================================================

-- (dark regions 0..1, base level ~-1..1, canyon depth 0..1, volcano shape 0..1)
function BiomeMars.fields(x: number, y: number, z: number): (number, number, number, number)
	local f = DARK_FREQ
	local dark = smoothstep(DARK0, DARK1, fbm(x * f + 8.3, y * f + 1.1, z * f + 5.6, DARK_OCTAVES, 0.55))
	f = BASE_FREQ
	local base = fbm(x * f + 2.9, y * f + 6.2, z * f + 9.7, BASE_OCTAVES, 0.5) - DICHOTOMY * y
	local canyon = canyonDepth(x, y, z)
	local volcano = volcanoShape(x, y, z)
	return dark, base, canyon, volcano
end

-- Ground colour (0..1), alpha 1 and the kind at unit direction (x, y, z); `octaves` = painter detail level.
function BiomeMars.shade(
	x: number,
	y: number,
	z: number,
	dark: number,
	base: number,
	canyon: number,
	volcano: number,
	octaves: number
): (number, number, number, number, string)
	local high = clamp01(0.5 + base)
	local r = C_DUST[1] + (C_HIGH[1] - C_DUST[1]) * high * 0.6
	local g = C_DUST[2] + (C_HIGH[2] - C_DUST[2]) * high * 0.6
	local b = C_DUST[3] + (C_HIGH[3] - C_DUST[3]) * high * 0.6
	local d = dark * 0.75
	r, g, b = r + (C_DARK[1] - r) * d, g + (C_DARK[2] - g) * d, b + (C_DARK[3] - b) * d
	local kind = if dark > 0.55 then "DarkDust" else "Dust"

	if volcano > 0 then
		local w = smoothstep(0, 0.35, volcano) * 0.8
		r, g, b = r + (C_VOLCANO[1] - r) * w, g + (C_VOLCANO[2] - g) * w, b + (C_VOLCANO[3] - b) * w
		local _, caldera = volcanoShape(x, y, z)
		if caldera > 0 then
			r, g, b =
				r + (C_CALDERA[1] - r) * caldera, g + (C_CALDERA[2] - g) * caldera, b + (C_CALDERA[3] - b) * caldera
		end
		if volcano > 0.25 then
			kind = "Volcano"
		end
	end
	if canyon > 0 then
		-- layered walls (bands by depth), a dusty floor
		local band = 0.5 + 0.5 * math.sin(canyon * CANYON_BANDS * math.pi + 3 * mathNoise(x * 20, y * 20, z * 20))
		local wr = C_WALL[1] + (C_WALL_BAND[1] - C_WALL[1]) * band
		local wg = C_WALL[2] + (C_WALL_BAND[2] - C_WALL[2]) * band
		local wb = C_WALL[3] + (C_WALL_BAND[3] - C_WALL[3]) * band
		local floor = smoothstep(0.85, 0.98, canyon)
		wr, wg, wb = wr + (C_FLOOR[1] - wr) * floor, wg + (C_FLOOR[2] - wg) * floor, wb + (C_FLOOR[3] - wb) * floor
		local w = smoothstep(0, 0.15, canyon)
		r, g, b = r + (wr - r) * w, g + (wg - g) * w, b + (wb - b) * w
		if canyon > 0.3 then
			kind = "Canyon"
		end
	end

	local _, crater, minT = craters(x, y, z, math.min(#CRATER_CELLS, octaves + 1))
	if minT < 1 and kind ~= "Canyon" and kind ~= "Volcano" then
		kind = "MarsCrater"
	end

	local f = GRAIN_FREQ
	local grain = GRAIN * mathNoise(x * f, y * f, z * f) * NOISE_SCALE
	local sf = STREAK_FREQ
	grain += STREAK * mathNoise(x * sf * 3 + 1.3, y * sf * 0.6 + 4.4, z * sf * 3 + 7.8) * NOISE_SCALE
	local bright = 1 + grain + crater * (1 - canyon)
	r, g, b = r * bright, g * bright, b * bright

	local ice = iceCover(x, y, z)
	if ice > 0 then
		local shadeN = 0.5 + 0.5 * mathNoise(x * 30 + 5.5, y * 30, z * 30 + 2.2) * NOISE_SCALE
		local ir = C_ICE[1] + (C_ICE_SHADE[1] - C_ICE[1]) * shadeN
		local ig = C_ICE[2] + (C_ICE_SHADE[2] - C_ICE[2]) * shadeN
		local ib = C_ICE[3] + (C_ICE_SHADE[3] - C_ICE[3]) * shadeN
		r, g, b = r + (ir - r) * ice, g + (ig - g) * ice, b + (ib - b) * ice
		if ice > 0.5 then
			kind = "PolarIce"
		end
	end
	return clamp01(r), clamp01(g), clamp01(b), 1, kind
end

-- Ground height (m above Mars' radius) at unit direction (x, y, z).
function BiomeMars.height(x: number, y: number, z: number): number
	local _, base, canyon, volcano = BiomeMars.fields(x, y, z)
	local h = BASE_AMP * base
	local f = ROLL_FREQ
	h += ROLL_AMP * fbm(x * f + 4.2, y * f + 7.7, z * f + 0.6, ROLL_OCTAVES, 0.5)
	f = BUMP_FREQ
	h += BUMP_AMP * mathNoise(x * f + 9.9, y * f + 3.3, z * f + 6.1) * NOISE_SCALE
	local craterRelief = craters(x, y, z, #CRATER_CELLS)
	h += craterRelief * (1 - canyon) * (1 - 0.8 * volcano)
	if volcano > 0 then
		local _, caldera = volcanoShape(x, y, z)
		h += (VOLCANO_HEIGHT - 0.6 * h) * volcano - CALDERA_DEPTH * caldera
	end
	if canyon > 0 then
		local floor = BASE_AMP * base - CANYON_DEPTH + 15 * mathNoise(x * 60, y * 60, z * 60) * NOISE_SCALE
		h += (floor - h) * canyon
	end
	local ice = iceCover(x, y, z)
	if ice > 0 then
		h += CAP_DOME * ice
	end
	if h < MIN_HEIGHT then
		return MIN_HEIGHT
	elseif h > MAX_HEIGHT then
		return MAX_HEIGHT
	end
	return h
end

function BiomeMars.bounds(): (number, number)
	return MIN_HEIGHT, MAX_HEIGHT
end

BiomeMars.KINDS = table.freeze({ "Dust", "DarkDust", "Canyon", "Volcano", "MarsCrater", "PolarIce" })

-- Named landing spots (unit directions): the admin panel lands near one (on the flattest ground close to it).
local function landmark(name: string, latDeg: number, lonDeg: number): { name: string, x: number, y: number, z: number }
	local x, y, z = direction(latDeg, lonDeg)
	return table.freeze({ name = name, x = x, y = y, z = z })
end
BiomeMars.LANDMARKS = table.freeze({
	landmark("Big Volcano", VOLCANO[1], VOLCANO[2]),
	landmark("Big Canyon", (CANYON_A[1] + CANYON_B[1]) / 2, (CANYON_A[2] + CANYON_B[2]) / 2),
	landmark("North Ice Cap", 80, 30),
})

return table.freeze(BiomeMars)
