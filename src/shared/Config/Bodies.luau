--!strict
--[[
	Bodies
	Celestial body definitions. Ids are stable and used on the wire; names are for code, DisplayName is for players.

	Universe frame: origin at Homeworld's center, +Y = Homeworld north pole axis, the Moon orbits in the XZ plane.
	Planets do not rotate in v1.

	Pure module (no services) so it can be required by the offline test runner.
]]

local GameConfig = require(script.Parent.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local HOMEWORLD_RADIUS = 60000 -- m
local HOMEWORLD_SURFACE_G = 9.81 -- m/s^2
local HOMEWORLD_ATMO_TOP = 8000 -- m
local HOMEWORLD_ATMO_RHO0 = 1.225 -- kg/m^3
local HOMEWORLD_ATMO_SCALE_HEIGHT = 1100 -- m

local MOON_RADIUS = 15000 -- m
local MOON_SURFACE_G = 1.62 -- m/s^2
local MOON_ORBIT_RADIUS = 450000 -- m, circular and equatorial
local MOON_ORBIT_PHASE_AT_UT0 = 0 -- rad, angle from +X toward +Z at UT 0

local SUN_ANGULAR_RADIUS_DEG = 0.27
--============================================================================

export type BodyKind = "Star" | "Planet" | "Moon"

export type Atmosphere = {
	Top: number, -- m above sea level where density reaches zero
	Rho0: number, -- kg/m^3 at sea level
	ScaleHeight: number, -- m
}

-- Circular, equatorial orbit around Parent (v1 keeps every orbiting body circular).
export type CircularOrbit = {
	ParentId: number,
	Radius: number, -- m
	PhaseAtUT0: number, -- rad
	AngularRate: number, -- rad/s (derived)
	Period: number, -- s (derived)
}

export type Body = {
	Id: number,
	Name: string, -- code name, stable
	DisplayName: string, -- player-facing name
	Kind: BodyKind,
	ParentId: number?, -- nil for the root (Homeworld) and for the visual-only Sun
	VisualOnly: boolean, -- true for the Sun: no gravity, no SOI, only a lighting/visual body
	Radius: number, -- m (0 for visual-only bodies)
	SurfaceGravity: number, -- m/s^2
	Mu: number, -- m^3/s^2
	SoiRadius: number, -- m (math.huge for the root)
	Atmosphere: Atmosphere?,
	Orbit: CircularOrbit?,
	AngularRadiusDeg: number?, -- visual-only bodies: apparent angular radius
	DayLengthS: number?, -- Sun: seconds for the sun direction to circle +Y
	Color: Color3, -- placeholder surface / glow color until textures exist
	AtmosphereColor: Color3?,
}

local function circularOrbit(parentMu: number, parentId: number, radius: number, phase: number): CircularOrbit
	local angularRate = math.sqrt(parentMu / (radius * radius * radius))
	return table.freeze({
		ParentId = parentId,
		Radius = radius,
		PhaseAtUT0 = phase,
		AngularRate = angularRate,
		Period = 2 * math.pi / angularRate,
	})
end

-- Laplace sphere-of-influence radius: a * (m / M)^(2/5)
local function soiRadius(orbitRadius: number, childMu: number, parentMu: number): number
	return orbitRadius * (childMu / parentMu) ^ 0.4
end

local homeworldMu = HOMEWORLD_SURFACE_G * HOMEWORLD_RADIUS * HOMEWORLD_RADIUS -- 3.5316e10
local moonMu = MOON_SURFACE_G * MOON_RADIUS * MOON_RADIUS -- 3.645e8

local Bodies = {}

Bodies.SUN = 0
Bodies.HOMEWORLD = 1
Bodies.MOON = 2
Bodies.ROOT = 1 -- the body whose center is the universe origin

local list: { Body } = {
	table.freeze({
		Id = 0,
		Name = "Sun",
		DisplayName = "Big Toasty",
		Kind = "Star" :: BodyKind,
		ParentId = nil,
		VisualOnly = true,
		Radius = 0,
		SurfaceGravity = 0,
		Mu = 0,
		SoiRadius = 0,
		Atmosphere = nil,
		Orbit = nil,
		AngularRadiusDeg = SUN_ANGULAR_RADIUS_DEG,
		DayLengthS = GameConfig.DAY_LENGTH_S,
		Color = Color3.fromRGB(255, 236, 190),
		AtmosphereColor = nil,
	}),
	table.freeze({
		Id = 1,
		Name = "Homeworld",
		DisplayName = "Kablamo",
		Kind = "Planet" :: BodyKind,
		ParentId = nil,
		VisualOnly = false,
		Radius = HOMEWORLD_RADIUS,
		SurfaceGravity = HOMEWORLD_SURFACE_G,
		Mu = homeworldMu,
		SoiRadius = math.huge,
		Atmosphere = table.freeze({
			Top = HOMEWORLD_ATMO_TOP,
			Rho0 = HOMEWORLD_ATMO_RHO0,
			ScaleHeight = HOMEWORLD_ATMO_SCALE_HEIGHT,
		}),
		Orbit = nil,
		AngularRadiusDeg = nil,
		DayLengthS = nil,
		Color = Color3.fromRGB(86, 142, 88),
		AtmosphereColor = Color3.fromRGB(120, 170, 255),
	}),
	table.freeze({
		Id = 2,
		Name = "Moon",
		DisplayName = "Dent",
		Kind = "Moon" :: BodyKind,
		ParentId = 1,
		VisualOnly = false,
		Radius = MOON_RADIUS,
		SurfaceGravity = MOON_SURFACE_G,
		Mu = moonMu,
		SoiRadius = soiRadius(MOON_ORBIT_RADIUS, moonMu, homeworldMu), -- ~72,200 m
		Atmosphere = nil,
		Orbit = circularOrbit(homeworldMu, 1, MOON_ORBIT_RADIUS, MOON_ORBIT_PHASE_AT_UT0), -- period ~10,090 s
		AngularRadiusDeg = nil,
		DayLengthS = nil,
		Color = Color3.fromRGB(150, 146, 140),
		AtmosphereColor = nil,
	}),
}

local byId: { [number]: Body } = {}
local byName: { [string]: Body } = {}
for _, body in list do
	assert(byId[body.Id] == nil, "Duplicate body id " .. body.Id)
	byId[body.Id] = body
	byName[body.Name] = body
end

Bodies.List = table.freeze(list)

-- Returns the body with this id, or errors (ids come from our own data and packets that were already validated).
function Bodies.get(id: number): Body
	local body = byId[id]
	if body == nil then
		error(`Unknown body id {id}`, 2)
	end
	return body
end

-- Returns the body with this id or nil (use for untrusted input).
function Bodies.find(id: number): Body?
	return byId[id]
end

-- Case-insensitive lookup by code name or display name (debug commands).
function Bodies.findByName(name: string): Body?
	local lower = string.lower(name)
	for _, body in list do
		if string.lower(body.Name) == lower or string.lower(body.DisplayName) == lower then
			return body
		end
	end
	return byName[name]
end

-- Bodies that have gravity and can contain crafts (everything except visual-only ones).
function Bodies.physicalBodies(): { Body }
	local out = {}
	for _, body in list do
		if not body.VisualOnly then
			table.insert(out, body)
		end
	end
	return out
end

-- Direct children (bodies orbiting this one).
function Bodies.children(parentId: number): { Body }
	local out = {}
	for _, body in list do
		if body.ParentId == parentId and not body.VisualOnly then
			table.insert(out, body)
		end
	end
	return out
end

return table.freeze(Bodies)
