--!strict
--[[
	AdminSpawn (new file, Solar system; D51)
	The rules of the admin panel's "spawn my ship" (Steamy: "do a admin panel for now to spawn in orbit with a ship of
	what ever planet or landed with a ship"). Pure module (no services): the server (AdminService) validates every
	request with it, the client (UI/AdminPanel) builds its controls from the same ranges and spot lists, and the Lune
	suite tests it.

	Who is an admin: everyone in Studio; in live servers the place's owner (its creator, or for a group game the
	group's owner: AdminService looks it up) and every user id in GameConfig.ADMIN_USER_IDS (empty by default).

	A request: { bodyId, mode = "Orbit" | "Landed", altitudeKm, spot }.
	  * Orbit: a circular, equatorial, prograde orbit at altitudeKm, within altitudeRange(bodyId): above the air /
	    rails floor (and, around Sol, well outside its burn-up radius) and inside 90% of the body's SOI. The craft
	    starts over the body's day side (around Sol: opposite Earth).
	  * Landed: on the ground (not Sol), at a spot from spots(bodyId): "Launch pad" (Earth: a normal roll out),
	    "Random" (the flattest of a few dry, sunlit, not-too-polar candidates) or a named landmark (Mars: the Big
	    Volcano, the Big Canyon, the North Ice Cap: the flattest ground near it).
	validate() checks the types and ranges of an untrusted request (altitudes outside the range are refused, not
	clamped, so the panel and the server always agree).

	API:
	  AdminSpawn.isAdmin(userId, info) -> boolean
	  AdminSpawn.bodies() -> { number }                      the bodies the panel offers (Sol, Earth, Mun, Mars)
	  AdminSpawn.altitudeRange(bodyId) -> (minKm, maxKm, defaultKm)
	  AdminSpawn.spots(bodyId) -> { string }                 Landed spots (empty: not landable)
	  AdminSpawn.validate(raw: unknown) -> (Request?, string?)
	  AdminSpawn.cooldownOk(last: number?, now: number) -> boolean
	  AdminSpawn.orbitState(bodyId, altitudeKm, ut) -> (pos, vel)   relative to the body (its axes)
	  AdminSpawn.landingDirection(bodyId, spot, ut, seed) -> Vec3d? unit direction from the body's centre
	  AdminSpawn.MODES, SPOT_PAD, SPOT_RANDOM, COOLDOWN_S
]]

local Atmosphere = require(script.Parent.Atmosphere)
local Biome = require(script.Parent.Biome)
local BiomeMars = require(script.Parent.BiomeMars)
local Bodies = require(script.Parent.Parent.Config.Bodies)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local SurfaceHeight = require(script.Parent.SurfaceHeight)
local Universe = require(script.Parent.Universe)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local COOLDOWN_S = GameConfig.ADMIN_SPAWN_COOLDOWN_S
local MIN_ABOVE_FLOOR_M = 1000 -- orbits start this far above the air / rails floor
local SOI_SHARE = 0.9 -- orbits stay inside this share of the SOI
local SUN_MIN_RADII = 2 -- around Sol: at least this many burn-up radii from its centre
local SUN_MAX_RADIUS_FACTOR = 1.6 -- ... and at most this x Mars' orbit radius
local DEFAULT_ALTITUDE_KM: { [number]: number } = {
	[Bodies.SUN] = 6000, -- between Sol and Earth's orbit
	[Bodies.HOMEWORLD] = 20,
	[Bodies.MOON] = 10,
	[Bodies.MARS] = 20,
}
local SPOT_PAD = "Launch pad"
local SPOT_RANDOM = "Random"
-- Landing search
local RANDOM_CANDIDATES = 48
local RANDOM_MAX_LAT = math.rad(55) -- random spots stay out of the polar regions
local LANDMARK_CANDIDATES = 40
local LANDMARK_RADIUS_M = 1500 -- the flattest ground within this of a landmark
local FLAT_COS = math.cos(math.rad(6)) -- "flat enough" (ground normal within 6 degrees of vertical)
local DAY_ELEVATION = 0.25 -- sin of the sun's elevation that counts as daytime for a random spot
local WATER: { [string]: boolean } = { Ocean = true, Lake = true }
--============================================================================

export type Mode = "Orbit" | "Landed"

export type Request = {
	bodyId: number,
	mode: Mode,
	altitudeKm: number,
	spot: string,
}

export type AdminInfo = {
	studio: boolean,
	ownerId: number?, -- user id of the place's owner (the creator, or a group game's group owner); nil = unknown
}

local AdminSpawn = {}

AdminSpawn.MODES = table.freeze({ "Orbit", "Landed" })
AdminSpawn.SPOT_PAD = SPOT_PAD
AdminSpawn.SPOT_RANDOM = SPOT_RANDOM
AdminSpawn.COOLDOWN_S = COOLDOWN_S

local BODY_ORDER = { Bodies.SUN, Bodies.HOMEWORLD, Bodies.MOON, Bodies.MARS }

function AdminSpawn.isAdmin(userId: number, info: AdminInfo): boolean
	if info.studio then
		return true
	end
	if table.find(GameConfig.ADMIN_USER_IDS, userId) ~= nil then
		return true
	end
	return userId > 0 and userId == info.ownerId
end

function AdminSpawn.bodies(): { number }
	return table.clone(BODY_ORDER)
end

-- Allowed orbit altitudes (km above the body's radius) and the panel's default.
function AdminSpawn.altitudeRange(bodyId: number): (number, number, number)
	local body = Bodies.get(bodyId)
	local minM, maxM
	if body.Kind == "Star" then
		minM = (body.DestroyRadius or body.Radius) * SUN_MIN_RADII - body.Radius
		local mars = Bodies.get(Bodies.MARS).Orbit
		maxM = (if mars then mars.Radius else body.Radius * 200) * SUN_MAX_RADIUS_FACTOR - body.Radius
	else
		local floor = math.max(Atmosphere.top(bodyId), GameConfig.RAILS_MIN_ALTITUDE)
		minM = floor + MIN_ABOVE_FLOOR_M
		maxM = body.SoiRadius * SOI_SHARE - body.Radius
	end
	local minKm, maxKm = math.ceil(minM / 1000), math.floor(maxM / 1000)
	local default = math.clamp(DEFAULT_ALTITUDE_KM[bodyId] or minKm, minKm, maxKm)
	return minKm, maxKm, default
end

-- The Landed spots of a body (empty for Sol).
function AdminSpawn.spots(bodyId: number): { string }
	local body = Bodies.find(bodyId)
	if body == nil or not body.Landable or not Bodies.hasSurface(bodyId) then
		return {}
	end
	local list = {}
	if bodyId == Bodies.HOMEWORLD then
		table.insert(list, SPOT_PAD)
	end
	table.insert(list, SPOT_RANDOM)
	if bodyId == Bodies.MARS then
		for _, landmark in BiomeMars.LANDMARKS do
			table.insert(list, landmark.name)
		end
	end
	return list
end

local function finite(v: unknown): boolean
	return type(v) == "number" and v == v and math.abs(v) < math.huge
end

-- Checks an untrusted request; returns the clean request or an error for the player.
function AdminSpawn.validate(raw: unknown): (Request?, string?)
	if type(raw) ~= "table" then
		return nil, "Bad request"
	end
	local t = raw :: { [any]: any }
	local bodyId, mode, altitude, spot = t.bodyId, t.mode, t.altitudeKm, t.spot
	if not finite(bodyId) or not table.find(BODY_ORDER, bodyId) then
		return nil, "Pick a planet"
	end
	if mode ~= "Orbit" and mode ~= "Landed" then
		return nil, "Pick Orbit or Landed"
	end
	local body = Bodies.get(bodyId :: number)
	if mode == "Landed" then
		local spots = AdminSpawn.spots(body.Id)
		if #spots == 0 then
			return nil, `You can't land on {body.DisplayName}!`
		end
		if type(spot) ~= "string" or not table.find(spots, spot) then
			return nil, "Pick a landing spot"
		end
		return { bodyId = body.Id, mode = "Landed", altitudeKm = 0, spot = spot :: string }, nil
	end
	if not finite(altitude) then
		return nil, "Type an altitude in km"
	end
	local minKm, maxKm = AdminSpawn.altitudeRange(body.Id)
	local km = altitude :: number
	if km < minKm or km > maxKm then
		return nil, `Altitude must be {minKm} to {maxKm} km around {body.DisplayName}`
	end
	return { bodyId = body.Id, mode = "Orbit", altitudeKm = km, spot = "" }, nil
end

function AdminSpawn.cooldownOk(last: number?, now: number): boolean
	return last == nil or now - last >= COOLDOWN_S
end

--[[
	A circular, equatorial, prograde orbit (the way the planets and the Mun go round) at altitudeKm, relative to the
	body in its axes. It starts over the day side (under the sun); around Sol opposite Earth.
]]
function AdminSpawn.orbitState(bodyId: number, altitudeKm: number, ut: number): (Vec3d, Vec3d)
	local body = Bodies.get(bodyId)
	local r = body.Radius + altitudeKm * 1000
	local dir: Vec3d
	if body.Kind == "Star" then
		local earth = Universe.bodyOffset(Bodies.HOMEWORLD, bodyId, ut)
		dir = Vec3d.new(-earth.x, 0, -earth.z)
	else
		local sun = Universe.sunDirectionFrom(bodyId, Vec3d.zero(), ut)
		dir = Vec3d.new(sun.x, 0, sun.z)
	end
	if Vec3d.length(dir) < 1e-6 then
		dir = Vec3d.new(1, 0, 0)
	end
	dir = Vec3d.normalize(dir)
	local speed = Universe.circularSpeed(bodyId, r)
	return Vec3d.scale(dir, r), Vec3d.new(-dir.z * speed, 0, dir.x * speed)
end

-- Deterministic [0, 1) numbers from a seed (Park-Miller).
local function generator(seed: number): () -> number
	local state = (math.floor(math.abs(seed)) % 2147483646) + 1
	return function(): number
		state = (state * 16807) % 2147483647
		return state / 2147483647
	end
end

-- How good a landing direction is: flat (normal vs vertical), dry, optionally sunlit. Higher is better.
local function score(bodyId: number, dir: Vec3d, ut: number, wantDay: boolean): number
	local ground, normal = SurfaceHeight.groundPoint(bodyId, dir)
	local up = Vec3d.normalize(ground)
	local flat = Vec3d.dot(normal, up)
	local value = flat
	if flat < FLAT_COS then
		value -= 1
	end
	local _, _, _, kind = Biome.sample(bodyId, up.x, up.y, up.z)
	if WATER[kind] then
		value -= 4
	end
	if wantDay then
		local sun = Universe.sunDirectionFrom(bodyId, ground, ut)
		if Vec3d.dot(sun, up) < DAY_ELEVATION then
			value -= 0.5
		end
	end
	return value
end

-- Unit vectors perpendicular to `n` (any two).
local function tangents(n: Vec3d): (Vec3d, Vec3d)
	local helper = if math.abs(n.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
	local a = Vec3d.normalize(Vec3d.cross(helper, n))
	return a, Vec3d.cross(n, a)
end

--[[
	Where to land (a unit direction from the body's centre, body axes) for a Landed spot; nil for "Launch pad" (a
	normal roll out) and for bodies without ground. `seed` varies the Random spot (e.g. os.time()).
]]
function AdminSpawn.landingDirection(bodyId: number, spot: string, ut: number, seed: number): Vec3d?
	if spot == SPOT_PAD or not Bodies.hasSurface(bodyId) then
		return nil
	end
	local best: Vec3d? = nil
	local bestScore = -math.huge
	if spot == SPOT_RANDOM then
		local random = generator(seed)
		for _ = 1, RANDOM_CANDIDATES do
			local lat = math.asin((random() * 2 - 1) * math.sin(RANDOM_MAX_LAT))
			local lon = random() * 2 * math.pi
			local dir = Vec3d.new(math.cos(lat) * math.cos(lon), math.sin(lat), math.cos(lat) * math.sin(lon))
			local value = score(bodyId, dir, ut, true)
			if value > bestScore then
				best, bestScore = dir, value
			end
		end
		return best
	end
	if bodyId ~= Bodies.MARS then
		return nil
	end
	for _, landmark in BiomeMars.LANDMARKS do
		if landmark.name == spot then
			local centre = Vec3d.new(landmark.x, landmark.y, landmark.z)
			local a, b = tangents(centre)
			local reach = LANDMARK_RADIUS_M / Bodies.get(bodyId).Radius
			for k = 0, LANDMARK_CANDIDATES - 1 do
				-- a sunflower spiral around the landmark (the centre first)
				local radius = reach * math.sqrt(k / LANDMARK_CANDIDATES)
				local angle = k * 2.39996
				local dir = Vec3d.normalize(
					Vec3d.add(
						centre,
						Vec3d.add(Vec3d.scale(a, radius * math.cos(angle)), Vec3d.scale(b, radius * math.sin(angle)))
					)
				)
				-- ties go to the spot nearest the landmark
				local value = score(bodyId, dir, ut, false) - 0.05 * math.sqrt(k / LANDMARK_CANDIDATES)
				if value > bestScore then
					best, bestScore = dir, value
				end
			end
			return best
		end
	end
	return nil
end

return table.freeze(AdminSpawn)
