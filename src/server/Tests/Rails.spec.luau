--!strict
-- Tests for Shared/Sim/Rails: analytic coasting, eligibility, the rails floor, SOI transitions and prediction.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Fixtures = require(script.Parent.CraftFixtures)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local Kepler = require(ReplicatedStorage.Shared.Sim.Kepler)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight) -- CHANGED (Night review)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

local HOME = Bodies.get(Bodies.HOMEWORLD)
local MOON = Bodies.get(Bodies.MOON)
local MOON_ORBIT = MOON.Orbit :: Bodies.CircularOrbit

local function state(bodyId: number, pos: Vec3d, vel: Vec3d, ut: number): FlightModel.CraftState
	return {
		bodyId = bodyId,
		pos = pos,
		vel = vel,
		rot = CFrame.Angles(0.3, 0.2, 0.1),
		angVel = Vector3.zero,
		throttle = 0,
		flags = 0,
		ut = ut,
	}
end

-- Absolute (universe) position of a body-relative position.
local function absolute(bodyId: number, pos: Vec3d, ut: number): Vec3d
	return Vec3d.add(pos, Universe.bodyPosition(bodyId, ut))
end

-- A Hohmann transfer from a 10 km orbit (leaving +X toward +Z) that meets Mun; returns (ut0, r0, v0, transferTime).
local function dentTransfer(): (number, Vec3d, Vec3d, number)
	local r1 = HOME.Radius + 10000
	local r2 = MOON_ORBIT.Radius - 15000 -- aim inside the SOI, short of the centre
	local aT = (r1 + r2) / 2
	local vT = math.sqrt(HOME.Mu * (2 / r1 - 1 / aT))
	local transferTime = math.pi * math.sqrt(aT ^ 3 / HOME.Mu)
	local ut0 = (math.pi - MOON_ORBIT.PhaseAtUT0 - MOON_ORBIT.AngularRate * transferTime) / MOON_ORBIT.AngularRate
	return ut0, Vec3d.new(r1, 0, 0), Vec3d.new(0, 0, vT), transferTime
end

return function(t: TestKit.Context)
	t.test("the rail reproduces its epoch state, including a spinning craft's offset CoM", function()
		local s = state(Bodies.HOMEWORLD, Vec3d.new(HOME.Radius + 20000, 0, 0), Vec3d.new(0, 0, 450), 100)
		s.angVel = Vector3.new(0.1, 0.3, -0.2)
		local rails = Rails.fromState(s, Vector3.new(0, -4, 1), false)
		local back = Rails.stateAt(rails, 100)
		t.expectNear(Vec3d.distance(back.pos, s.pos), 0, 1e-9)
		t.expectNear(Vec3d.distance(back.vel, s.vel), 0, 1e-9)
		t.expectNear((back.rot.LookVector - s.rot.LookVector).Magnitude, 0, 1e-6)
	end)

	t.test("rails match the flight model coasting a spinning craft for 60 s", function()
		local design = Fixtures.sanity()
		local r = HOME.Radius + 20000
		local s = state(Bodies.HOMEWORLD, Vec3d.new(r, 0, 0), Vec3d.new(0, 30, math.sqrt(HOME.Mu / r)), 0)
		s.angVel = Vector3.new(0.05, 0.2, 0)
		local craft = FlightModel.newCraft(design, s)
		local rails = Rails.fromState(FlightModel.copyState(craft.state), craft.physics.com, false)
		for _ = 1, 60 * 60 do
			FlightModel.step(craft)
		end
		local onRails = Rails.stateAt(rails, craft.state.ut)
		t.expectTrue(
			Vec3d.distance(onRails.pos, craft.state.pos) < 1,
			"position differs by " .. Vec3d.distance(onRails.pos, craft.state.pos)
		)
		-- CHANGED (Studio fix): Roblox's CFrame math is single precision, so 60 s of integrated spin drifts a little
		-- more there (1.4e-3 measured in Studio) than in Lune; 5e-3 rad is still a tiny attitude error
		t.expectNear((onRails.rot.UpVector - craft.state.rot.UpVector).Magnitude, 0, 5e-3)
	end)

	t.test("holding attitude freezes rotation without changing the orbit", function()
		local s = state(Bodies.HOMEWORLD, Vec3d.new(HOME.Radius + 20000, 0, 0), Vec3d.new(0, 0, 450), 0)
		s.angVel = Vector3.new(0, 0.04, 0)
		local com = Vector3.new(0, -6, 0)
		local spinning = Rails.fromState(s, com, false)
		local held = Rails.fromState(s, com, true)
		t.expectEqual(held.angVel, Vector3.zero)
		t.expectNear(Vec3d.distance(spinning.comPos0, held.comPos0), 0, 1e-9)
		t.expectNear(Vec3d.distance(spinning.comVel0, held.comVel0), 0, 1e-9)
	end)

	t.test("a coasting orbit stays within 1 m of the analytic path after 10 orbits", function()
		local r = HOME.Radius + 12000
		local s = state(Bodies.HOMEWORLD, Vec3d.new(r, 0, 0), Vec3d.new(0, 20, math.sqrt(HOME.Mu / r) * 1.05), 0)
		local rails = Rails.fromState(s, Vector3.new(0, -3, 0), true)
		local el = Kepler.elements(HOME.Mu, rails.comPos0, rails.comVel0)
		local final = 10 * el.period
		-- re-epoch the rail every 100 s (what repeated SOI checks / rebases would do) and compare
		local hopping = rails
		local ut = 0
		while ut < final do
			ut = math.min(final, ut + 100)
			hopping = Rails.rebase(hopping, ut)
		end
		local direct = Rails.stateAt(rails, final)
		local chained = Rails.stateAt(hopping, final)
		t.expectTrue(Vec3d.distance(direct.pos, chained.pos) < 1, "drift " .. Vec3d.distance(direct.pos, chained.pos))
		t.expectTrue(Vec3d.distance(direct.pos, s.pos) < 1, "back at the start after 10 periods")
	end)

	t.test("eligibility: idle in orbit yes; in the air, burning or steering no", function()
		local design = Fixtures.sanity()
		local r = HOME.Radius + 15000
		local craft = FlightModel.newCraft(design, state(Bodies.HOMEWORLD, Vec3d.new(r, 0, 0), Vec3d.new(0, 0, 480), 0))
		FlightModel.setControls(craft, 0, 0, 0, 0, false)
		t.expectTrue(Rails.eligible(craft), "coasting in vacuum")
		FlightModel.setControls(craft, 1, 0, 0, 0, false)
		t.expectTrue(not Rails.eligible(craft), "pitch input")
		FlightModel.setControls(craft, 0, 0, 0, 1, false)
		t.expectTrue(Rails.eligible(craft), "throttle up but no engine ignited")
		FlightModel.stage(craft)
		t.expectTrue(not Rails.eligible(craft) and Rails.wouldThrust(craft), "engine ignited at full throttle")
		FlightModel.setControls(craft, 0, 0, 0, 0, true)
		craft.state.angVel = Vector3.new(0, 0.5, 0)
		t.expectTrue(not Rails.eligible(craft), "SAS still damping a spin")
		craft.state.angVel = Vector3.zero
		t.expectTrue(Rails.eligible(craft), "SAS settled")
		craft.state.pos = Vec3d.new(HOME.Radius + 5000, 0, 0)
		t.expectTrue(not Rails.eligible(craft), "inside the atmosphere")
	end)

	-- CHANGED (Physics feel): speeds for the 60 km Earth (periapsis ~4 km, inside the 8 km air; the second orbit
	-- is just above circular at 20 km)
	t.test("rails end where the orbit enters the atmosphere", function()
		local s = state(Bodies.HOMEWORLD, Vec3d.new(HOME.Radius + 30000, 0, 0), Vec3d.new(-100, 0, 580), 50)
		local rails = Rails.fromState(s, Vector3.zero, true)
		t.expectTrue(rails.exitUT < math.huge, "dips into the air")
		local atExit = Rails.stateAt(rails, rails.exitUT)
		local altitude = Vec3d.length(atExit.pos) - HOME.Radius
		t.expectNear(altitude, Rails.minAltitude(Bodies.HOMEWORLD), 3)
		local circular = Rails.fromState(
			state(Bodies.HOMEWORLD, Vec3d.new(HOME.Radius + 20000, 0, 0), Vec3d.new(0, 0, 680), 0),
			Vector3.zero,
			true
		)
		t.expectEqual(circular.exitUT, math.huge)
		t.expectTrue(Rails.isSuborbital(Bodies.HOMEWORLD, s.pos, s.vel), "suborbital")
		t.expectTrue(not Rails.isSuborbital(Bodies.HOMEWORLD, circular.r0, circular.v0), "orbital")
	end)

	t.test("SOI entry into Mun: bisected to 0.01 s, continuous in absolute position and velocity", function()
		local ut0, r0, v0, transferTime = dentTransfer()
		local rails = Rails.fromState(state(Bodies.HOMEWORLD, r0, v0, ut0), Vector3.zero, true)
		local entered = Rails.advance(rails, ut0, ut0 + transferTime + 200)
		t.expectTrue(entered ~= nil, "transition happened")
		local inMoon = entered :: Rails.Rails
		t.expectEqual(inMoon.bodyId, Bodies.MOON)
		local tc = inMoon.epochUT
		t.expectTrue(Vec3d.length(inMoon.r0) <= MOON.SoiRadius, "inside Mun's SOI at the new epoch")
		local before = Rails.stateAt(rails, tc - 0.011)
		local moonPos = Universe.bodyOffset(Bodies.MOON, Bodies.HOMEWORLD, tc - 0.011)
		t.expectTrue(Vec3d.distance(before.pos, moonPos) > MOON.SoiRadius, "outside 0.011 s earlier")
		local old = Rails.stateAt(rails, tc)
		local new = Rails.stateAt(inMoon, tc)
		t.expectNear(
			Vec3d.distance(absolute(Bodies.HOMEWORLD, old.pos, tc), absolute(Bodies.MOON, new.pos, tc)),
			0,
			1e-6
		)
		local vAbsOld = Vec3d.add(old.vel, Universe.bodyVelocity(Bodies.HOMEWORLD, tc))
		local vAbsNew = Vec3d.add(new.vel, Universe.bodyVelocity(Bodies.MOON, tc))
		t.expectNear(Vec3d.distance(vAbsOld, vAbsNew), 0, 1e-9)
	end)

	t.test("SOI exit from Mun back to Earth", function()
		local r = MOON.Radius + 15000
		-- CHANGED (Physics feel): full-size Mun: escape speed at 15 km altitude is ~156 m/s
		local s = state(Bodies.MOON, Vec3d.new(r, 0, 0), Vec3d.new(0, 0, 220), 1000) -- above Mun's escape speed
		local rails = Rails.fromState(s, Vector3.zero, true)
		local left = Rails.advance(rails, 1000, 1000 + 5000)
		t.expectTrue(left ~= nil, "escaped")
		local out = left :: Rails.Rails
		t.expectEqual(out.bodyId, Bodies.HOMEWORLD)
		local tc = out.epochUT
		local inside = Rails.stateAt(rails, tc - 0.011)
		t.expectTrue(Vec3d.length(inside.pos) < MOON.SoiRadius, "inside 0.011 s earlier")
		local old = Rails.stateAt(rails, tc)
		t.expectNear(
			Vec3d.distance(absolute(Bodies.MOON, old.pos, tc), absolute(Bodies.HOMEWORLD, out.r0, tc)),
			0,
			1e-6
		)
		-- no further change while it coasts away
		t.expectTrue(Rails.advance(out, tc, tc + 30) == nil, "stays with Earth")
	end)

	t.test("prediction: closed orbit, impact, and a Mun encounter in patches", function()
		local r = HOME.Radius + 10000
		local circle = Rails.predict(Bodies.HOMEWORLD, Vec3d.new(r, 0, 0), Vec3d.new(0, 0, math.sqrt(HOME.Mu / r)), 0)
		t.expectEqual(#circle, 1)
		t.expectEqual(circle[1].endReason, "None")
		local falling = Rails.predict(Bodies.HOMEWORLD, Vec3d.new(r, 0, 0), Vec3d.new(0, 0, 200), 0)
		t.expectEqual(falling[1].endReason, "Impact")
		local ut0, r0, v0 = dentTransfer()
		local transfer = Rails.predict(Bodies.HOMEWORLD, r0, v0, ut0)
		t.expectTrue(#transfer >= 2, "at least two patches")
		t.expectEqual(transfer[1].endReason, "Enter")
		t.expectEqual(transfer[2].bodyId, Bodies.MOON)
		t.expectNear(transfer[2].startUT, transfer[1].endUT, 1e-9)
		t.expectTrue(Vec3d.length(transfer[2].r0) <= MOON.SoiRadius + 1, "patch 2 starts on Mun's SOI")
		if transfer[2].endReason == "Exit" then
			t.expectEqual(transfer[3].bodyId, Bodies.HOMEWORLD)
		end
	end)

	-- CHANGED (Night review): the map's impact point is on the heightmap ground (predict's terrain option)
	t.test("prediction: with terrain, the impact is on the heightmap ground (hills earlier, craters later)", function()
		local function findSpot(bodyId: number, wanted: (number) -> boolean): Vec3d?
			local radius = Bodies.get(bodyId).Radius
			for i = 0, 1999 do
				local golden = math.pi * (3 - math.sqrt(5))
				local y = 1 - (i + 0.5) * 2 / 2000
				local r = math.sqrt(1 - y * y)
				local d = Vec3d.new(r * math.cos(golden * i), y, r * math.sin(golden * i))
				local ground = SurfaceHeight.groundPoint(bodyId, d)
				if wanted(Vec3d.length(ground) - radius) then
					return d
				end
			end
			return nil
		end
		local cases: { { bodyId: number, spot: Vec3d?, earlier: boolean } } = {
			{
				bodyId = Bodies.HOMEWORLD,
				spot = findSpot(Bodies.HOMEWORLD, function(h: number): boolean
					return h > 300
				end),
				earlier = true,
			},
			{
				bodyId = Bodies.MOON,
				spot = findSpot(Bodies.MOON, function(h: number): boolean
					return h < -100
				end),
				earlier = false,
			},
		}
		for _, case in cases do
			local d = case.spot
			t.expectTrue(d ~= nil, "found a spot")
			if d == nil then
				continue
			end
			local body = Bodies.get(case.bodyId)
			-- dropped from 3 km with a little sideways speed
			local ref = if math.abs(d.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
			local side = Vec3d.normalize(Vec3d.cross(ref, d))
			local pos = Vec3d.scale(d, body.Radius + 3000)
			local vel = Vec3d.scale(side, 20)
			local sea = Rails.predict(case.bodyId, pos, vel, 0)
			local ground = Rails.predict(case.bodyId, pos, vel, 0, { terrain = true })
			t.expectEqual(sea[1].endReason, "Impact")
			t.expectEqual(ground[1].endReason, "Impact")
			if case.earlier then
				t.expectTrue(ground[1].endUT < sea[1].endUT, "hits the hill before sea level")
			else
				t.expectTrue(ground[1].endUT > sea[1].endUT, "falls into the crater below sea level")
			end
			local at = Kepler.propagate(body.Mu, pos, vel, ground[1].endUT)
			-- within the 0.01 s bisection at ~250 m/s
			local height = SurfaceHeight.height(case.bodyId, at)
			t.expectTrue(height <= 0 and height > -3, `on the ground at the impact: {height}`)
		end
		-- far above the highest ground: no change
		local r = HOME.Radius + 10000
		local circle = Rails.predict(Bodies.HOMEWORLD, Vec3d.new(r, 0, 0), Vec3d.new(0, 0, math.sqrt(HOME.Mu / r)), 0, {
			terrain = true,
		})
		t.expectEqual(circle[1].endReason, "None")
	end)
end
