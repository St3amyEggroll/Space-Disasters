--!strict
--[[
	Bodies
	Celestial body definitions. Ids are stable and used on the wire; names are for code, DisplayName is for players.

	Universe frame: origin at Homeworld's center, +Y = Homeworld north pole axis, the Moon orbits in the XZ plane.
	Planets do not rotate in v1 (CHANGED (Solar system): each body's axes turn with its Spin, see below).

	Scale (CHANGED (Physics feel)): KSP-like sizes divided by 10 (Earth 60 km, Mun 15 km at 450 km), so low Earth
	orbit is ~710 m/s at 10 km. Distances are true metres (1 stud = 1 m) for gravity, orbits and the ground tiles;
	only aerodynamic areas use the parts' visual size (GameConfig.AERO_METERS_PER_STUD).

	CHANGED (Solar system): Steamy: "make the solar system and mars". Sol (id 0) is now the real ROOT body: it has
	gravity, an infinite SOI and a radius, and Earth (id 1, with the Mun, id 2) and Mars (id 3, new) move on circular
	orbits around it in Sol's XZ plane. Nothing about the Earth-Mun system changed (sizes, Mun orbit, air, day length).
	  * Sizes (D51): Earth orbits at 10,000 km. Sol's mu is chosen so that Earth's Laplace SOI is exactly
	    EARTH_SOI_TARGET (1,000 km, 2.2x the Mun's 450 km orbit): mu = 1.117e13, a 59,460 s (16.5 h) Earth year.
	    Mars orbits at 15,000 km (109,200 s year), SOI ~586 km. A Hohmann transfer Earth -> Mars takes ~41,500 s:
	    ~14 minutes at 50x warp. "A few minutes at 50x" (D39's plan) cannot keep the Mun at 450 km inside Earth's
	    SOI (the Mun's 2.8 h month needs an Earth year many times longer), so time warp should offer 100x-1000x.
	  * Spin (body axes): every body has its own axes. A body with `Spin` turns so that the sun circles its +Y axis
	    once per DayLengthS at a fixed declination (TiltDeg) and starts at hour angle PhaseAtUT0: exactly the old
	    Earth sun (30 deg at UT 0, 15 deg above the equator, 20 min days), so Earth's day / night is unchanged.
	    Bodies without Spin share their parent's axes (the Mun moves with Earth's axes, as before). Physics inside
	    each SOI treats the body's axes as inertial (as it always did on Earth); Universe converts positions,
	    velocities and attitudes between bodies with their axes (SOI changes, rendering, the map).
	  * Mars: half Earth's radius (30 km), 0.38 g, a thin, low atmosphere (2% of Earth's density at the ground,
	    5 km top), a butterscotch sky, a 1230 s day.
	  * Sol is not landable: a craft closer than its DestroyRadius burns up (server).
	Universe frame (Universe.bodyPosition and the "absolute" positions of Bubbles): still Earth's centre and axes.

	Pure module (no services) so it can be required by the offline test runner.
]]

local GameConfig = require(script.Parent.GameConfig)

--============================================================================
-- Tunables
--============================================================================
-- CHANGED (Physics feel): Earth and Mun are back to the spec's full size (60 km / 15 km, Mun orbit 450 km). D27 had
-- halved them; with drag now sized to how parts look and engines x1.5 (GameConfig.AERO_METERS_PER_STUD, Parts),
-- rockets are fast enough that the half-size planet felt cramped, so Steamy chose the 60 km planet again.
local HOMEWORLD_RADIUS = 60000 -- m
local HOMEWORLD_SURFACE_G = 9.81 -- m/s^2
local HOMEWORLD_ATMO_TOP = 8000 -- m (CHANGED (Physics feel): 7000 on the half-size planet)
local HOMEWORLD_ATMO_RHO0 = 1.225 -- kg/m^3
local HOMEWORLD_ATMO_SCALE_HEIGHT = 1100 -- m (CHANGED (Physics feel): 1000 on the half-size planet)

local MOON_RADIUS = 15000 -- m (CHANGED (Physics feel): 7500 on the half-size planet)
local MOON_SURFACE_G = 1.62 -- m/s^2
local MOON_ORBIT_RADIUS = 450000 -- m, circular and equatorial (CHANGED (Physics feel): 220000 on the half-size planet)
local MOON_ORBIT_PHASE_AT_UT0 = 0 -- rad, angle from +X toward +Z at UT 0

-- CHANGED (Solar system): Sol is the root body, Earth and Mars orbit it (D51)
local SUN_RADIUS = 100000 -- m: ~0.57 deg seen from Earth, about the disc the sky always drew (0.6 deg minimum)
local SUN_DESTROY_RADII = 2.5 -- crafts closer than this many Sol radii from its centre burn up ("too hot")
local EARTH_ORBIT_RADIUS = 10000000 -- m (10,000 km)
local EARTH_SOI_TARGET = 1000000 -- m: Sol's mu is derived so Earth's Laplace SOI is exactly this (2.2x Mun orbit)
local EARTH_ORBIT_PHASE_AT_UT0 = math.rad(180) -- rad around Sol from +X toward +Z (Earth on Sol's -X side)
-- CHANGED (No tilt): Steamy: "get rid of the solar system tilt, dont like it". Every planet's equator lies in the plane of
-- the orbits around Sol, so the map shows one flat solar system (was 15 deg: the old SUN_ELEVATION)
local EARTH_DAY_TILT_DEG = 0 -- the sun's declination over Earth's equator
local EARTH_DAY_PHASE_AT_UT0 = math.rad(30) -- the sun's hour angle at UT 0 (the old SUN_PHASE_AT_UT0: morning)
local MARS_RADIUS = 30000 -- m, half of Earth's
local MARS_SURFACE_G = 3.73 -- m/s^2, 0.38 g
local MARS_ORBIT_RADIUS = 15000000 -- m (1.5 x Earth's, like the real ratio 1.52)
-- Mars leads Earth by the Hohmann phase angle at UT 0 (180 - 360 * 41,500 / 109,200 = 43 deg): a launch window is
-- open when a server starts
local MARS_ORBIT_PHASE_AT_UT0 = math.rad(180 + 43)
local MARS_ATMO_TOP = 5000 -- m: thin and low ...
local MARS_ATMO_RHO0 = 0.025 -- kg/m^3 (2% of Earth's: drag and heating are weak but there)
local MARS_ATMO_SCALE_HEIGHT = 1000 -- m
local MARS_HEAT_SPEED_SCALE = 0.44 -- re-entry glow speed gate x this (Mars' orbit speed is 0.44 x Earth's)
local MARS_DAY_S = 1230 -- s: a Mars day is a little longer than Earth's, as in real life
local MARS_DAY_TILT_DEG = 0 -- the sun's declination over Mars' equator (CHANGED (No tilt): was 20)
local MARS_DAY_PHASE_AT_UT0 = math.rad(-20)
--============================================================================

export type BodyKind = "Star" | "Planet" | "Moon"

export type Atmosphere = {
	Top: number, -- m above sea level where density reaches zero
	Rho0: number, -- kg/m^3 at sea level
	ScaleHeight: number, -- m
	HeatSpeedScale: number, -- CHANGED (Solar system): re-entry glow speed gate x this (1 on Earth)
	SkyColor: Color3?, -- CHANGED (Solar system): a daytime sky painted over Roblox's blue one (nil: Roblox's sky)
}

-- Circular, equatorial orbit around Parent (v1 keeps every orbiting body circular).
export type CircularOrbit = {
	ParentId: number,
	Radius: number, -- m
	PhaseAtUT0: number, -- rad
	AngularRate: number, -- rad/s (derived)
	Period: number, -- s (derived)
}

-- CHANGED (Solar system): the body's own axes turn so the sun circles its +Y axis once per DayLengthS (Universe).
export type Spin = {
	DayLengthS: number, -- s from noon to noon
	TiltDeg: number, -- the sun's (constant) declination above the equator
	PhaseAtUT0: number, -- rad, the sun's hour angle at UT 0 (from +X toward +Z)
}

export type Body = {
	Id: number,
	Name: string, -- code name, stable
	DisplayName: string, -- player-facing name
	Kind: BodyKind,
	ParentId: number?, -- nil for the root (CHANGED (Solar system): Sol)
	VisualOnly: boolean, -- CHANGED (Solar system): false for every body now (Sol has gravity and an SOI)
	Radius: number, -- m
	SurfaceGravity: number, -- m/s^2
	Mu: number, -- m^3/s^2
	SoiRadius: number, -- m (math.huge for the root)
	Atmosphere: Atmosphere?,
	Orbit: CircularOrbit?,
	Spin: Spin?, -- CHANGED (Solar system): nil = the parent's axes (root: fixed axes)
	Landable: boolean, -- CHANGED (Solar system): false for Sol (no ground, admin "Landed" refuses it)
	DestroyRadius: number?, -- CHANGED (Solar system): crafts closer than this to the centre are destroyed (Sol)
	AngularRadiusDeg: number?, -- unused since the Solar system (Sol's size is its Radius)
	DayLengthS: number?, -- CHANGED (Solar system): mirror of Spin.DayLengthS (nil without a spin)
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
-- CHANGED (Solar system): soiRadius(EARTH_ORBIT_RADIUS, homeworldMu, sunMu) == EARTH_SOI_TARGET exactly
local sunMu = homeworldMu * (EARTH_ORBIT_RADIUS / EARTH_SOI_TARGET) ^ 2.5 -- 1.1168e13
local marsMu = MARS_SURFACE_G * MARS_RADIUS * MARS_RADIUS -- 3.357e9

local Bodies = {}

Bodies.SUN = 0
Bodies.HOMEWORLD = 1
Bodies.MOON = 2
Bodies.MARS = 3 -- CHANGED (Solar system)
-- CHANGED (Solar system): the root of the SOI tree is Sol now. The universe FRAME (Universe.bodyPosition) is still
-- Earth's centre and axes: UNIVERSE_FRAME.
Bodies.ROOT = 0
Bodies.UNIVERSE_FRAME = 1

local list: { Body } = {
	table.freeze({
		Id = 0,
		Name = "Sun",
		DisplayName = "Sol",
		Kind = "Star" :: BodyKind,
		ParentId = nil,
		VisualOnly = false, -- CHANGED (Solar system): a real body
		Radius = SUN_RADIUS,
		SurfaceGravity = sunMu / (SUN_RADIUS * SUN_RADIUS),
		Mu = sunMu,
		SoiRadius = math.huge,
		Atmosphere = nil,
		Orbit = nil,
		Spin = nil,
		Landable = false,
		DestroyRadius = SUN_RADIUS * SUN_DESTROY_RADII,
		AngularRadiusDeg = nil,
		DayLengthS = nil,
		Color = Color3.fromRGB(255, 236, 190),
		AtmosphereColor = nil,
	}),
	table.freeze({
		Id = 1,
		Name = "Homeworld",
		DisplayName = "Earth",
		Kind = "Planet" :: BodyKind,
		ParentId = 0, -- CHANGED (Solar system): orbits Sol
		VisualOnly = false,
		Radius = HOMEWORLD_RADIUS,
		SurfaceGravity = HOMEWORLD_SURFACE_G,
		Mu = homeworldMu,
		SoiRadius = soiRadius(EARTH_ORBIT_RADIUS, homeworldMu, sunMu), -- CHANGED (Solar system): 1,000 km
		Atmosphere = table.freeze({
			Top = HOMEWORLD_ATMO_TOP,
			Rho0 = HOMEWORLD_ATMO_RHO0,
			ScaleHeight = HOMEWORLD_ATMO_SCALE_HEIGHT,
			HeatSpeedScale = 1,
			SkyColor = nil,
		}),
		-- CHANGED (Solar system): period ~59,460 s
		Orbit = circularOrbit(sunMu, 0, EARTH_ORBIT_RADIUS, EARTH_ORBIT_PHASE_AT_UT0),
		Spin = table.freeze({
			DayLengthS = GameConfig.DAY_LENGTH_S,
			TiltDeg = EARTH_DAY_TILT_DEG,
			PhaseAtUT0 = EARTH_DAY_PHASE_AT_UT0,
		}),
		Landable = true,
		DestroyRadius = nil,
		AngularRadiusDeg = nil,
		DayLengthS = GameConfig.DAY_LENGTH_S,
		Color = Color3.fromRGB(86, 142, 88),
		AtmosphereColor = Color3.fromRGB(120, 170, 255),
	}),
	table.freeze({
		Id = 2,
		Name = "Moon",
		DisplayName = "Mun",
		Kind = "Moon" :: BodyKind,
		ParentId = 1,
		VisualOnly = false,
		Radius = MOON_RADIUS,
		SurfaceGravity = MOON_SURFACE_G,
		Mu = moonMu,
		SoiRadius = soiRadius(MOON_ORBIT_RADIUS, moonMu, homeworldMu), -- ~72,200 m
		Atmosphere = nil,
		Orbit = circularOrbit(homeworldMu, 1, MOON_ORBIT_RADIUS, MOON_ORBIT_PHASE_AT_UT0), -- period ~10,090 s
		Spin = nil, -- Earth's axes (unchanged: the Mun's sky turns with Earth's day)
		Landable = true,
		DestroyRadius = nil,
		AngularRadiusDeg = nil,
		DayLengthS = nil,
		Color = Color3.fromRGB(150, 146, 140),
		AtmosphereColor = nil,
	}),
	-- CHANGED (Solar system): Mars
	table.freeze({
		Id = 3,
		Name = "Mars",
		DisplayName = "Mars",
		Kind = "Planet" :: BodyKind,
		ParentId = 0,
		VisualOnly = false,
		Radius = MARS_RADIUS,
		SurfaceGravity = MARS_SURFACE_G,
		Mu = marsMu,
		SoiRadius = soiRadius(MARS_ORBIT_RADIUS, marsMu, sunMu), -- ~586 km
		Atmosphere = table.freeze({
			Top = MARS_ATMO_TOP,
			Rho0 = MARS_ATMO_RHO0,
			ScaleHeight = MARS_ATMO_SCALE_HEIGHT,
			HeatSpeedScale = MARS_HEAT_SPEED_SCALE,
			SkyColor = Color3.fromRGB(214, 168, 120), -- butterscotch
		}),
		Orbit = circularOrbit(sunMu, 0, MARS_ORBIT_RADIUS, MARS_ORBIT_PHASE_AT_UT0), -- period ~109,200 s
		Spin = table.freeze({
			DayLengthS = MARS_DAY_S,
			TiltDeg = MARS_DAY_TILT_DEG,
			PhaseAtUT0 = MARS_DAY_PHASE_AT_UT0,
		}),
		Landable = true,
		DestroyRadius = nil,
		AngularRadiusDeg = nil,
		DayLengthS = MARS_DAY_S,
		Color = Color3.fromRGB(188, 92, 52),
		AtmosphereColor = Color3.fromRGB(226, 160, 120), -- pinkish-butterscotch haze
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
-- CHANGED (Solar system): "sun" finds Sol too
function Bodies.findByName(name: string): Body?
	local lower = string.lower(name)
	for _, body in list do
		if string.lower(body.Name) == lower or string.lower(body.DisplayName) == lower then
			return body
		end
	end
	return byName[name]
end

-- Bodies that have gravity and can contain crafts (CHANGED (Solar system): every body, Sol included).
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

-- CHANGED (Solar system): the body whose Spin sets this body's axes (itself, an ancestor, or the root).
function Bodies.axesBody(id: number): number
	local body = Bodies.get(id)
	while body.Spin == nil and body.ParentId ~= nil do
		body = Bodies.get(body.ParentId :: number)
	end
	return body.Id
end

-- CHANGED (Solar system): bodies with a ground (lattice terrain, landings): everything but stars.
function Bodies.hasSurface(id: number): boolean
	local body = byId[id]
	return body ~= nil and body.Kind ~= "Star" and body.Radius > 0
end

return table.freeze(Bodies)
