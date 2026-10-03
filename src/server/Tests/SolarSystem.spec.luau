--!strict
-- New file (Solar system, D51): Sol as the root body, Earth and Mars around it, body axes and the sun direction,
-- patched conics Earth -> Sol -> Mars, the admin panel's rules and Mars' ground.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local AdminSpawn = require(ReplicatedStorage.Shared.Sim.AdminSpawn)
local Atmosphere = require(ReplicatedStorage.Shared.Sim.Atmosphere)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local BiomeMars = require(ReplicatedStorage.Shared.Sim.BiomeMars)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local EffectsMath = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render.EffectsMath)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails)
local Relief = require(ReplicatedStorage.Shared.Sim.Relief)
local StarterCraft = require(ReplicatedStorage.Shared.Craft.StarterCraft)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

local SUN = Bodies.get(Bodies.SUN)
local EARTH = Bodies.get(Bodies.HOMEWORLD)
local MUN = Bodies.get(Bodies.MOON)
local MARS = Bodies.get(Bodies.MARS)
local EARTH_ORBIT = EARTH.Orbit :: Bodies.CircularOrbit
local MARS_ORBIT = MARS.Orbit :: Bodies.CircularOrbit
local MUN_ORBIT = MUN.Orbit :: Bodies.CircularOrbit

local function craftState(bodyId: number, pos: Vec3d, vel: Vec3d, ut: number): FlightModel.CraftState
	return {
		bodyId = bodyId,
		pos = pos,
		vel = vel,
		rot = CFrame.Angles(0.3, 0.2, 0.1),
		angVel = Vector3.new(0, 0.01, 0),
		throttle = 0,
		flags = 0,
		ut = ut,
	}
end

-- Heliocentric position / velocity of a body-relative state (the frame every SOI hands over through).
local function helio(bodyId: number, pos: Vec3d, ut: number): Vec3d
	return Universe.toBody(bodyId, Bodies.SUN, ut, pos)
end

local function helioVel(bodyId: number, vel: Vec3d, ut: number): Vec3d
	return Universe.velocityToBody(bodyId, Bodies.SUN, ut, vel)
end

local function rotationAngle(a: CFrame, b: CFrame): number
	local _, angle = (a:Inverse() * b):ToAxisAngle()
	return math.abs(angle)
end

return function(t: TestKit.Context)
	t.test("Sol is the root; Earth and Mars orbit it; periods and SOI sizes", function()
		t.expectEqual(Bodies.ROOT, Bodies.SUN)
		t.expectTrue(SUN.ParentId == nil and SUN.SoiRadius == math.huge and SUN.Mu > 0, "Sol is the root")
		t.expectTrue(SUN.Kind == "Star" and not SUN.Landable, "Sol is a star you cannot land on")
		t.expectTrue((SUN.DestroyRadius or 0) > SUN.Radius, "a burn-up radius beyond the surface")
		t.expectEqual(EARTH.ParentId, Bodies.SUN)
		t.expectEqual(MARS.ParentId, Bodies.SUN)
		t.expectEqual(MUN.ParentId, Bodies.HOMEWORLD)
		-- Earth's SOI: 1,000 km, comfortably around the Mun's orbit and its SOI
		t.expectRelNear(EARTH.SoiRadius, 1000000, 1e-9)
		t.expectTrue(EARTH.SoiRadius > 1.5 * (MUN_ORBIT.Radius + MUN.SoiRadius), "Earth SOI holds the Mun")
		-- periods (D51)
		t.expectNear(EARTH_ORBIT.Period, 59460, 100)
		t.expectNear(MARS_ORBIT.Period, 109230, 300)
		-- Mars' SOI holds low and high orbits
		t.expectNear(MARS.SoiRadius, 586000, 10000)
		local low = MARS.Radius + Atmosphere.top(Bodies.MARS) + 1000
		local high = MARS.Radius + 300000
		t.expectTrue(MARS.SoiRadius > 1.5 * high and high > low, "low and high Mars orbits fit")
		-- Mars: half Earth's size, 0.38 g, thin low air
		t.expectRelNear(MARS.Radius, EARTH.Radius / 2, 1e-12)
		t.expectNear(MARS.SurfaceGravity / EARTH.SurfaceGravity, 0.38, 0.01)
		local air = MARS.Atmosphere :: Bodies.Atmosphere
		local earthAir = EARTH.Atmosphere :: Bodies.Atmosphere
		t.expectTrue(air.Rho0 < 0.05 * earthAir.Rho0 and air.Top < earthAir.Top, "Mars' air is thin and low")
		t.expectTrue(air.SkyColor ~= nil, "Mars paints its own sky")
		-- nothing about the Earth-Mun system changed
		t.expectRelNear(EARTH.Radius, 60000, 1e-12)
		t.expectRelNear(EARTH.Mu, 3.5316e10, 1e-9)
		t.expectRelNear(MUN_ORBIT.Radius, 450000, 1e-12)
		t.expectNear(MUN_ORBIT.Period, 10090, 20)
		t.expectNear(MUN.SoiRadius, 72200, 200)
	end)

	t.test("an Earth -> Mars Hohmann transfer takes ~41,500 s (~14 min at 50x warp)", function()
		local a1, a2 = EARTH_ORBIT.Radius, MARS_ORBIT.Radius
		local transfer = math.pi * math.sqrt(((a1 + a2) / 2) ^ 3 / SUN.Mu)
		t.expectNear(transfer, 41550, 500)
		t.expectTrue(transfer / 50 < 15 * 60, "under 15 minutes at 50x")
		-- the Mun's month stays far inside Earth's Hill sphere (its period at the Hill radius is year / sqrt 3)
		t.expectTrue(MUN_ORBIT.Period < EARTH_ORBIT.Period / math.sqrt(3) / 2, "Mun orbit stable")
	end)

	t.test(
		"lighting: Sol's real direction from Earth is exactly the old Earth sun (day and night unchanged)",
		function()
			for _, ut in { 0, 123.4, 600, 5000, 40000, 123456.7 } do
				local fromEarth = Universe.sunDirectionFrom(Bodies.HOMEWORLD, Vec3d.zero(), ut)
				local phi = math.rad(30) + 2 * math.pi * ut / 1200
				local c = math.cos(math.rad(15))
				local old = Vec3d.new(c * math.cos(phi), math.sin(math.rad(15)), c * math.sin(phi))
				t.expectNear(Vec3d.distance(fromEarth, old), 0, 1e-9)
				t.expectNear(Vec3d.distance(Universe.sunDirection(ut), old), 0, 1e-12)
			end
			-- noon / midnight at the base, seen from the base itself (0.3 degrees of parallax at most)
			local base = Vec3d.scale(Frames.surfaceUp(0, 0), EARTH.Radius)
			local ut = 777
			Universe.setSunPhaseOffset(Universe.sunOffsetForBaseHour(12, ut))
			t.expectTrue(Vec3d.dot(Universe.sunDirectionFrom(Bodies.HOMEWORLD, base, ut), Vec3d.new(1, 0, 0)) > 0.9)
			Universe.setSunPhaseOffset(Universe.sunOffsetForBaseHour(0, ut))
			t.expectTrue(Vec3d.dot(Universe.sunDirectionFrom(Bodies.HOMEWORLD, base, ut), Vec3d.new(1, 0, 0)) < -0.9)
			Universe.setSunPhaseOffset(0)
		end
	)

	t.test("lighting: Mars has days, the Mun shares Earth's sky, Sol lights everything around it", function()
		local day = (MARS.Spin :: Bodies.Spin).DayLengthS
		local d0 = Universe.sunDirectionFrom(Bodies.MARS, Vec3d.zero(), 300)
		local d1 = Universe.sunDirectionFrom(Bodies.MARS, Vec3d.zero(), 300 + day)
		t.expectNear(Vec3d.distance(d0, d1), 0, 1e-9)
		local half = Universe.sunDirectionFrom(Bodies.MARS, Vec3d.zero(), 300 + day / 2)
		t.expectTrue(Vec3d.dot(d0, half) < 0, "half a day later the sun is on the other side")
		-- a spot on Mars' equator sees day and night within one Mars day
		local spot = Vec3d.scale(Vec3d.new(1, 0, 0), MARS.Radius)
		local lit, dark = false, false
		for k = 0, 11 do
			local sun = Universe.sunDirectionFrom(Bodies.MARS, spot, 300 + day * k / 12)
			local elevation = Vec3d.dot(sun, Vec3d.new(1, 0, 0))
			lit = lit or elevation > 0.5
			dark = dark or elevation < -0.5
		end
		t.expectTrue(lit and dark, "day and night on Mars")
		-- the Mun: Earth's axes, the sun within the parallax of its 450 km orbit
		local fromMun = Universe.sunDirectionFrom(Bodies.MOON, Vec3d.zero(), 1000)
		t.expectTrue(Vec3d.dot(fromMun, Universe.sunDirection(1000)) > math.cos(math.rad(3)), "Mun sky")
		-- around Sol: toward its centre, and the pocket's up is that direction
		local pos = Vec3d.new(3e6, 1e5, -2e6)
		local toSun = Vec3d.normalize(Vec3d.scale(pos, -1))
		t.expectNear(Vec3d.distance(Universe.sunDirectionFrom(Bodies.SUN, pos, 5), toSun), 0, 1e-12)
		t.expectNear(Vec3d.distance(Universe.pocketUp(Bodies.SUN, pos, 5), toSun), 0, 1e-12)
	end)

	t.test("body axes: conversions are exact round trips and keep distances and attitudes", function()
		local ut = 4321.5
		local p = Vec3d.new(123456, -2345, 98765)
		local q = Vec3d.new(-40000, 5000, 70000)
		local onMars = Universe.toBody(Bodies.HOMEWORLD, Bodies.MARS, ut, p)
		t.expectNear(Vec3d.distance(Universe.toBody(Bodies.MARS, Bodies.HOMEWORLD, ut, onMars), p), 0, 1e-6)
		local qMars = Universe.toBody(Bodies.HOMEWORLD, Bodies.MARS, ut, q)
		t.expectNear(Vec3d.distance(onMars, qMars), Vec3d.distance(p, q), 1e-6)
		local v = Vec3d.new(100, 20, -300)
		local vMars = Universe.velocityToBody(Bodies.HOMEWORLD, Bodies.MARS, ut, v)
		t.expectNear(Vec3d.distance(Universe.velocityToBody(Bodies.MARS, Bodies.HOMEWORLD, ut, vMars), v), 0, 1e-6)
		local there = Universe.axesRotation(Bodies.HOMEWORLD, Bodies.MARS, ut)
		local back = Universe.axesRotation(Bodies.MARS, Bodies.HOMEWORLD, ut)
		t.expectNear(rotationAngle(back * there, CFrame.identity), 0, 1e-5)
		-- inside the Earth-Mun system nothing turns: offsets are the old translations
		t.expectTrue(Universe.sameAxes(Bodies.HOMEWORLD, Bodies.MOON), "the Mun shares Earth's axes")
		t.expectEqual(Universe.axesRotation(Bodies.MOON, Bodies.HOMEWORLD, ut), CFrame.identity)
		local mun = Universe.bodyOffset(Bodies.MOON, Bodies.HOMEWORLD, ut)
		local angle = MUN_ORBIT.PhaseAtUT0 + MUN_ORBIT.AngularRate * ut
		t.expectNear(mun.x, MUN_ORBIT.Radius * math.cos(angle), 1e-6)
		t.expectNear(mun.z, MUN_ORBIT.Radius * math.sin(angle), 1e-6)
		-- Earth's centre is where its orbit says, in Sol's frame
		local earth = Universe.bodyOffset(Bodies.HOMEWORLD, Bodies.SUN, ut)
		t.expectNear(Vec3d.length(earth), EARTH_ORBIT.Radius, 1e-6)
	end)

	t.test("patched conics on rails: low Earth orbit -> Sol, continuous in Sol's frame (attitude too)", function()
		local r = EARTH.Radius + 100000
		local escape = math.sqrt(2 * EARTH.Mu / r)
		local s = craftState(Bodies.HOMEWORLD, Vec3d.new(r, 0, 0), Vec3d.new(0, 0, escape * 1.3), 1000)
		local rails = Rails.fromState(s, Vector3.zero, false)
		local out = Rails.advance(rails, 1000, 1000 + 20000)
		t.expectTrue(out ~= nil, "left Earth's SOI")
		local sol = out :: Rails.Rails
		t.expectEqual(sol.bodyId, Bodies.SUN)
		local tc = sol.epochUT
		local before = Rails.stateAt(rails, tc)
		t.expectNear(Vec3d.length(before.pos), EARTH.SoiRadius, 50)
		local a, b = helio(Bodies.HOMEWORLD, before.pos, tc), helio(Bodies.SUN, sol.r0, tc)
		t.expectNear(Vec3d.distance(a, b), 0, 1e-3)
		local va, vb = helioVel(Bodies.HOMEWORLD, before.vel, tc), helioVel(Bodies.SUN, sol.v0, tc)
		t.expectNear(Vec3d.distance(va, vb), 0, 1e-6)
		local rotA = Universe.axesRotation(Bodies.HOMEWORLD, Bodies.SUN, tc) * before.rot
		t.expectNear(rotationAngle(rotA, sol.rot), 0, 1e-4)
		-- a flying craft (FlightModel) crossing the same boundary changes body the same way
		local craft = FlightModel.newCraft(StarterCraft.design(), Rails.stateAt(rails, tc - 0.5))
		for _ = 1, 60 do
			FlightModel.step(craft)
		end
		t.expectEqual(craft.state.bodyId, Bodies.SUN)
	end)

	t.test("patched conics: a Hohmann transfer from near Earth meets Mars (predict and rails)", function()
		local a1, a2 = EARTH_ORBIT.Radius, MARS_ORBIT.Radius
		local lead = 0.15 -- start this far (rad) ahead of Earth: outside its SOI
		local nE, nM = EARTH_ORBIT.AngularRate, MARS_ORBIT.AngularRate
		-- the UT at which Mars leads the start point by the Hohmann phase angle (as it leads Earth at UT 0)
		local ut0 = (2 * math.pi - lead) / (nE - nM)
		local theta = EARTH_ORBIT.PhaseAtUT0 + nE * ut0 + lead
		local vp = math.sqrt(SUN.Mu / a1) * math.sqrt(2 * a2 / (a1 + a2))
		local pos = Vec3d.new(a1 * math.cos(theta), 0, a1 * math.sin(theta))
		local vel = Vec3d.new(-vp * math.sin(theta), 0, vp * math.cos(theta))
		local patches = Rails.predict(Bodies.SUN, pos, vel, ut0, { maxPatches = 3 })
		t.expectTrue(#patches >= 2, "more than one patch")
		t.expectEqual(patches[1].endReason, "Enter")
		t.expectEqual(patches[1].nextBodyId, Bodies.MARS)
		local flight = patches[1].endUT - ut0
		t.expectTrue(flight > 30000 and flight < 45000, `arrives after {flight} s`)
		local second = patches[2]
		t.expectEqual(second.bodyId, Bodies.MARS)
		t.expectNear(Vec3d.length(second.r0), MARS.SoiRadius, 100)
		-- the hand-over is continuous in Sol's frame
		local endPos = Rails.stateAt(
			Rails.new(Bodies.SUN, ut0, pos, vel, CFrame.identity, Vector3.zero, Vector3.zero, 0, 0),
			second.startUT
		).pos
		t.expectNear(Vec3d.distance(helio(Bodies.MARS, second.r0, second.startUT), endPos), 0, 1e-2)
		-- on rails the craft ends up in Mars' SOI too
		local rails = Rails.new(Bodies.SUN, ut0, pos, vel, CFrame.identity, Vector3.zero, Vector3.zero, 0, 0)
		local arrived = Rails.advance(rails, ut0, patches[1].endUT + 60) -- (a flyby leaves Mars' SOI again later)
		t.expectTrue(arrived ~= nil and (arrived :: Rails.Rails).bodyId == Bodies.MARS, "on rails into Mars' SOI")
	end)

	t.test("admin: who may use the panel", function()
		t.expectTrue(AdminSpawn.isAdmin(5, { studio = true, ownerId = nil }), "everyone in Studio")
		t.expectTrue(AdminSpawn.isAdmin(5, { studio = false, ownerId = 5 }), "the owner")
		t.expectTrue(not AdminSpawn.isAdmin(6, { studio = false, ownerId = 5 }), "not someone else")
		t.expectTrue(not AdminSpawn.isAdmin(6, { studio = false, ownerId = nil }), "unknown owner: nobody")
		t.expectTrue(not AdminSpawn.isAdmin(0, { studio = false, ownerId = 0 }), "no guest ids")
	end)

	t.test("admin: requests are checked (bodies, modes, ranges, spots)", function()
		t.expectTrue(AdminSpawn.validate(nil) == nil, "nil")
		t.expectTrue(AdminSpawn.validate("orbit") == nil, "not a table")
		t.expectTrue(AdminSpawn.validate({ bodyId = 99, mode = "Orbit", altitudeKm = 20 }) == nil, "unknown body")
		t.expectTrue(AdminSpawn.validate({ bodyId = 1, mode = "Fly", altitudeKm = 20 }) == nil, "unknown mode")
		t.expectTrue(AdminSpawn.validate({ bodyId = 0, mode = "Landed", spot = "Random" }) == nil, "no landing on Sol")
		t.expectTrue(AdminSpawn.validate({ bodyId = 2, mode = "Landed", spot = "Launch pad" }) == nil, "no Mun pad")
		t.expectTrue(AdminSpawn.validate({ bodyId = 1, mode = "Orbit", altitudeKm = 0 / 0 }) == nil, "NaN")
		t.expectTrue(AdminSpawn.validate({ bodyId = 1, mode = "Orbit", altitudeKm = "20" }) == nil, "a string")
		for _, id in AdminSpawn.bodies() do
			local minKm, maxKm, default = AdminSpawn.altitudeRange(id)
			t.expectTrue(minKm < default and default < maxKm, `{id}: default inside the range`)
			t.expectTrue(AdminSpawn.validate({ bodyId = id, mode = "Orbit", altitudeKm = minKm - 1 }) == nil, "low")
			t.expectTrue(AdminSpawn.validate({ bodyId = id, mode = "Orbit", altitudeKm = maxKm + 1 }) == nil, "high")
			local ok = AdminSpawn.validate({ bodyId = id, mode = "Orbit", altitudeKm = default })
			t.expectTrue(ok ~= nil and ok.altitudeKm == default, `{id}: default accepted`)
			-- the range sits above the air / rails floor (or Sol's burn-up radius) and inside the SOI
			local body = Bodies.get(id)
			local floorM = math.max(Rails.minAltitude(id), (body.DestroyRadius or 0) - body.Radius)
			t.expectTrue(minKm * 1000 > floorM, `{id}: above the floor`)
			t.expectTrue(body.Radius + maxKm * 1000 < body.SoiRadius, `{id}: inside the SOI`)
		end
		local mars = AdminSpawn.validate({ bodyId = 3, mode = "Landed", spot = "Big Volcano" })
		t.expectTrue(mars ~= nil and mars.spot == "Big Volcano", "Mars landmark")
		t.expectTrue(AdminSpawn.validate({ bodyId = 1, mode = "Landed", spot = "Launch pad" }) ~= nil, "Earth pad")
		t.expectTrue(AdminSpawn.validate({ bodyId = 3, mode = "Landed", spot = "Nowhere" }) == nil, "unknown spot")
		t.expectTrue(AdminSpawn.cooldownOk(nil, 10) and not AdminSpawn.cooldownOk(9, 10), "cooldown")
		t.expectTrue(AdminSpawn.cooldownOk(10 - AdminSpawn.COOLDOWN_S, 10), "cooldown over")
	end)

	t.test("admin: orbit and landing placements", function()
		local ut = 2000
		for _, id in AdminSpawn.bodies() do
			local _, _, default = AdminSpawn.altitudeRange(id)
			local pos, vel = AdminSpawn.orbitState(id, default, ut)
			local body = Bodies.get(id)
			t.expectNear(Vec3d.length(pos), body.Radius + default * 1000, 1e-6)
			t.expectNear(Vec3d.length(vel), Universe.circularSpeed(id, Vec3d.length(pos)), 1e-6)
			t.expectNear(Vec3d.dot(pos, vel), 0, 1e-3)
			-- prograde: the same sense as every orbit in the game (from +X toward +Z)
			t.expectTrue(Vec3d.cross(pos, vel).y < 0, `{id}: prograde`)
		end
		-- around Sol it starts far from Earth
		local solPos = AdminSpawn.orbitState(Bodies.SUN, 6000, ut)
		local earth = Universe.bodyOffset(Bodies.HOMEWORLD, Bodies.SUN, ut)
		t.expectTrue(Vec3d.distance(solPos, earth) > EARTH.SoiRadius * 5, "away from Earth")
		-- landings: flat, dry ground; the volcano spot near its top; the pad is a roll out
		local dir = AdminSpawn.landingDirection(Bodies.MARS, AdminSpawn.SPOT_RANDOM, ut, 42) :: Vec3d
		t.expectTrue(dir ~= nil, "a random Mars spot")
		local _, normal = SurfaceHeight.groundPoint(Bodies.MARS, dir)
		t.expectTrue(Vec3d.dot(normal, dir) > math.cos(math.rad(10)), "flat enough")
		local again = AdminSpawn.landingDirection(Bodies.MARS, AdminSpawn.SPOT_RANDOM, ut, 42) :: Vec3d
		t.expectNear(Vec3d.distance(dir, again), 0, 1e-12)
		local volcano = AdminSpawn.landingDirection(Bodies.MARS, "Big Volcano", ut, 1) :: Vec3d
		t.expectTrue(Relief.height(Bodies.MARS, volcano.x, volcano.y, volcano.z) > 3000, "on the volcano")
		local earthSpot = AdminSpawn.landingDirection(Bodies.HOMEWORLD, AdminSpawn.SPOT_RANDOM, ut, 7) :: Vec3d
		local _, _, _, kind = Biome.sample(Bodies.HOMEWORLD, earthSpot.x, earthSpot.y, earthSpot.z)
		t.expectTrue(kind ~= "Ocean" and kind ~= "Lake", "Earth: on land")
		t.expectTrue(AdminSpawn.landingDirection(Bodies.HOMEWORLD, AdminSpawn.SPOT_PAD, ut, 1) == nil, "pad")
		t.expectTrue(AdminSpawn.landingDirection(Bodies.SUN, AdminSpawn.SPOT_RANDOM, ut, 1) == nil, "Sol")
		-- the starter rocket can fly (a command pod on top)
		local starter = StarterCraft.design()
		t.expectEqual(#starter.blocks, 5)
	end)

	t.test("Mars' ground: heights, landmarks and terrain lattice", function()
		local minH, maxH = Relief.bounds(Bodies.MARS)
		t.expectTrue(maxH < Rails.minAltitude(Bodies.MARS), "every peak under the rails floor")
		local count, lowest, highest = 400, math.huge, -math.huge
		local golden = math.pi * (3 - math.sqrt(5))
		for i = 0, count - 1 do
			local y = 1 - (i + 0.5) * 2 / count
			local rr = math.sqrt(1 - y * y)
			local h = Relief.height(Bodies.MARS, rr * math.cos(golden * i), y, rr * math.sin(golden * i))
			t.expectTrue(h >= minH and h <= maxH, "inside the bounds")
			lowest, highest = math.min(lowest, h), math.max(highest, h)
		end
		t.expectTrue(highest - lowest > 600, "the ground is not flat")
		local landmarks: { [string]: Vec3d } = {}
		for _, mark in BiomeMars.LANDMARKS do
			landmarks[mark.name] = Vec3d.new(mark.x, mark.y, mark.z)
		end
		local top = landmarks["Big Volcano"]
		t.expectTrue(Relief.height(Bodies.MARS, top.x, top.y, top.z) > 3200, "the Big Volcano rises ~4 km")
		-- the Big Canyon: somewhere near its middle the ground drops over 1 km
		local canyon = landmarks["Big Canyon"]
		local deepest = math.huge
		local north = Vec3d.new(0, 1, 0)
		for k = -20, 20 do
			local d = Vec3d.normalize(Vec3d.add(canyon, Vec3d.scale(north, k * 0.005)))
			deepest = math.min(deepest, Relief.height(Bodies.MARS, d.x, d.y, d.z))
		end
		t.expectTrue(deepest < -1000, `the Big Canyon is deep ({deepest} m)`)
		-- the terrain lattice (the same ~23 m cells as Earth and the Mun); Sol has none
		t.expectTrue(SurfaceHeight.latticeSize(Bodies.MARS) > 0, "Mars has ground")
		t.expectEqual(SurfaceHeight.latticeSize(Bodies.SUN), 0)
		local up = Vec3d.normalize(Vec3d.new(0.3, 0.2, -0.9))
		local ground, normal = SurfaceHeight.groundPoint(Bodies.MARS, up)
		local h = SurfaceHeight.height(Bodies.MARS, Vec3d.add(ground, Vec3d.scale(up, 50)))
		t.expectNear(h, 50 * Vec3d.dot(normal, up), 0.5) -- height above the (sloped) ground triangle
	end)

	t.test("Mars' look: rust-red dust, darker regions, polar ice, craters, canyon and volcano kinds", function()
		local kinds: { [string]: boolean } = {}
		local sr, sg, sb, n = 0, 0, 0, 0
		local count = 1500
		local golden = math.pi * (3 - math.sqrt(5))
		for i = 0, count - 1 do
			local y = 1 - (i + 0.5) * 2 / count
			local rr = math.sqrt(1 - y * y)
			local r, g, b, kind = Biome.sample(Bodies.MARS, rr * math.cos(golden * i), y, rr * math.sin(golden * i))
			kinds[kind] = true
			if kind ~= "PolarIce" then
				sr, sg, sb, n = sr + r, sg + g, sb + b, n + 1
			end
		end
		t.expectTrue(sr / n > sg / n and sg / n > sb / n, "reddish on average")
		for _, kind in { "Dust", "DarkDust", "PolarIce", "MarsCrater" } do
			t.expectTrue(kinds[kind] == true, `has {kind}`)
		end
		local r, g, b, kind = Biome.sample(Bodies.MARS, 0, 1, 0)
		t.expectEqual(kind, "PolarIce")
		t.expectTrue(r > 0.8 and g > 0.8 and b > 0.8, "the ice cap is white")
		for _, mark in BiomeMars.LANDMARKS do
			local _, _, _, here = Biome.sample(Bodies.MARS, mark.x, mark.y, mark.z)
			if mark.name == "Big Volcano" then
				t.expectEqual(here, "Volcano")
			end
		end
		t.expectTrue(Biome.propKind("Dust", 0.5) == "RedBoulder", "red boulders")
	end)

	t.test("Mars' thin air: weak drag, near-vacuum engines, a faint re-entry glow", function()
		t.expectNear(Atmosphere.density(Bodies.MARS, 0), 0.025, 1e-12)
		t.expectTrue(Atmosphere.pressureRatio(Bodies.MARS, 0) < 0.03, "engines run near their vacuum Isp")
		t.expectNear(Atmosphere.pressureRatio(Bodies.HOMEWORLD, 0), 1, 1e-12)
		t.expectEqual(Atmosphere.density(Bodies.MARS, 5000), 0)
		local scale = (MARS.Atmosphere :: Bodies.Atmosphere).HeatSpeedScale
		local rho = Atmosphere.density(Bodies.MARS, 2000)
		local glow = EffectsMath.heatFactor(rho, 450, scale)
		t.expectTrue(glow > 0 and glow < 0.6, `weak but present ({glow})`)
		t.expectEqual(EffectsMath.heatFactor(rho, 450), 0)
	end)
end
