--!strict
-- CHANGED (Phase 6): tests for Shared/Sim/Eva, the astronaut on EVA: floating beside a craft in orbit, the jetpack,
-- ground contact on the Mun, air drag, braking, fuel, and the walk / float rules.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Eva = require(ReplicatedStorage.Shared.Sim.Eva)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Kepler = require(ReplicatedStorage.Shared.Sim.Kepler)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

--============================================================================
-- Tunables
--============================================================================
local FRAME = 1 / 60 -- s, one render frame
local ORBIT_ALT = 15000 -- m above Earth's sea level
--============================================================================

-- A circular equatorial orbit state around Earth (prograde, in the XZ plane).
local function orbitState(): (Vec3d.Vec3d, Vec3d.Vec3d)
	local body = Bodies.get(Bodies.HOMEWORLD)
	local r = body.Radius + ORBIT_ALT
	return Vec3d.new(r, 0, 0), Vec3d.new(0, 0, Universe.circularSpeed(Bodies.HOMEWORLD, r))
end

-- Advances an astronaut frame by frame (like the client) for `seconds`, with an optional constant thrust.
local function fly(state: Eva.State, seconds: number, thrust: Vec3d.Vec3d?)
	local frames = math.floor(seconds / FRAME + 0.5)
	for _ = 1, frames do
		Eva.advance(state, state.ut + FRAME, thrust)
	end
end

return function(t: TestKit.Context)
	t.test("floating beside a craft in orbit: the astronaut stays where he was", function()
		local pos, vel = orbitState()
		local mu = Bodies.get(Bodies.HOMEWORLD).Mu
		-- 3 m beside the craft (along the orbit normal), same velocity
		local start = Vec3d.add(pos, Vec3d.new(0, 3, 0))
		local astronaut = Eva.new(Bodies.HOMEWORLD, start, vel, 100)
		fly(astronaut, 120)
		-- exactly his own orbit (frame-by-frame integration vs the analytic conic)
		local exact = Kepler.propagate(mu, start, vel, 120)
		t.expectNear(Vec3d.distance(astronaut.pos, exact), 0, 0.05, "on his analytic orbit to 5 cm")
		-- and still beside the craft: out-of-plane offsets only swing slowly back and forth (tides), never grow
		local craftPos = Kepler.propagate(mu, pos, vel, 120)
		local offset = Vec3d.sub(astronaut.pos, craftPos)
		t.expectTrue(Vec3d.length(offset) <= 3.05, `within 3 m of the craft ({Vec3d.length(offset)} m)`)
		t.expectNear(astronaut.ut, 220, 1e-6, "clock follows the frames")
	end)

	t.test("a push in orbit is a straight line relative to the craft", function()
		local pos, vel = orbitState()
		local mu = Bodies.get(Bodies.HOMEWORLD).Mu
		local push = Vec3d.new(0, 0.5, 0) -- 0.5 m/s along the orbit normal
		local astronaut = Eva.new(Bodies.HOMEWORLD, pos, Vec3d.add(vel, push), 0)
		fly(astronaut, 20)
		local craftPos = Kepler.propagate(mu, pos, vel, 20)
		local offset = Vec3d.sub(astronaut.pos, craftPos)
		t.expectNear(offset.y, 10, 0.3, "about 10 m after 20 s")
		t.expectTrue(math.abs(offset.x) < 0.5 and math.abs(offset.z) < 0.5, "and nowhere else")
	end)

	t.test("the jetpack accelerates at EVA_THRUST_ACCEL", function()
		local pos, vel = orbitState()
		local mu = Bodies.get(Bodies.HOMEWORLD).Mu
		local astronaut = Eva.new(Bodies.HOMEWORLD, pos, vel, 0)
		local thrust = Vec3d.new(0, GameConfig.EVA_THRUST_ACCEL, 0)
		fly(astronaut, 4, thrust)
		local _, craftVel = Kepler.propagate(mu, pos, vel, 4)
		local rel = Vec3d.sub(astronaut.vel, craftVel)
		t.expectNear(rel.y, 4 * GameConfig.EVA_THRUST_ACCEL, 0.05, "12 m/s after 4 s")
	end)

	t.test("next to a landed craft on the Mun he falls to the ground and stands", function()
		local body = Bodies.get(Bodies.MOON)
		local up = Vec3d.normalize(Vec3d.new(0.3, 0.2, 0.9))
		local _, tileUp = SurfaceHeight.height(Bodies.MOON, Vec3d.scale(up, body.Radius))
		-- 5 m of feet above the tile plane, at rest
		local ground = Vec3d.scale(tileUp, body.Radius / Vec3d.dot(tileUp, tileUp))
		local start = Vec3d.addScaled(ground, tileUp, 5 + Eva.ROOT_HEIGHT)
		local feet0 = Eva.groundHeight(Bodies.MOON, start)
		t.expectNear(feet0, 5, 0.05, "starts 5 m up")
		local astronaut = Eva.new(Bodies.MOON, start, Vec3d.zero(), 0)
		local landedAt: number? = nil
		for frame = 1, 600 do
			local touching = Eva.advance(astronaut, astronaut.ut + FRAME)
			if touching and landedAt == nil then
				landedAt = frame * FRAME
			end
		end
		t.expectTrue(landedAt ~= nil, "lands")
		t.expectNear(landedAt :: number, math.sqrt(2 * 5 / body.SurfaceGravity), 0.1, "falls at the Mun's gravity")
		local feet = Eva.groundHeight(Bodies.MOON, astronaut.pos)
		t.expectNear(feet, 0, 0.01, "stands on the ground")
		t.expectTrue(Vec3d.length(astronaut.vel) < 0.05, "and stays put")
	end)

	t.test("sliding on the ground slows down and stops", function()
		local body = Bodies.get(Bodies.MOON)
		local up = Vec3d.new(1, 0, 0)
		local start = Vec3d.scale(up, body.Radius + Eva.ROOT_HEIGHT)
		local astronaut = Eva.new(Bodies.MOON, start, Vec3d.new(0, 0, 5), 0)
		fly(astronaut, 3)
		t.expectTrue(Vec3d.length(astronaut.vel) < 0.05, "stopped by friction")
		t.expectNear(Eva.groundHeight(Bodies.MOON, astronaut.pos), 0, 0.01)
	end)

	t.test("air slows a fall to skydiving speed", function()
		local body = Bodies.get(Bodies.HOMEWORLD)
		-- at sea level, 55 m/s down: the drag about balances the weight (a skydiver's terminal speed)
		local low = Vec3d.new(body.Radius + 10, 0, 0)
		local drag = Eva.dragAccel(Bodies.HOMEWORLD, low, Vec3d.new(-55, 0, 0))
		t.expectNear(drag.x, body.SurfaceGravity, 0.6, "terminal speed about 55 m/s")
		-- a fast fall into thick air slows down
		local astronaut = Eva.new(Bodies.HOMEWORLD, Vec3d.new(body.Radius + 600, 0, 0), Vec3d.new(-150, 0, 0), 0)
		fly(astronaut, 2)
		local speed = Vec3d.length(astronaut.vel)
		t.expectTrue(speed < 110, `slowed by the air ({speed} m/s)`)
		-- no drag in vacuum
		local high = Eva.new(Bodies.HOMEWORLD, Vec3d.new(body.Radius + 20000, 0, 0), Vec3d.new(0, 0, 100), 0)
		t.expectEqual(Vec3d.length(Eva.dragAccel(high.bodyId, high.pos, high.vel)), 0, "vacuum")
	end)

	t.test("thrust direction: camera axes, never faster on diagonals", function()
		local f, r, u = Vec3d.new(0, 0, -1), Vec3d.new(1, 0, 0), Vec3d.new(0, 1, 0)
		local forward = Eva.thrustDirection(f, r, u, 1, 0, 0)
		t.expectNear(forward.z, -1, 1e-9)
		local diagonal = Eva.thrustDirection(f, r, u, 1, 1, 1)
		t.expectNear(Vec3d.length(diagonal), 1, 1e-9, "unit length")
		local none = Eva.thrustDirection(f, r, u, 0, 0, 0)
		t.expectEqual(Vec3d.length(none), 0)
		local cancel = Eva.thrustDirection(f, r, u, 1, 0, 0)
		local back = Eva.thrustDirection(f, r, u, -1, 0, 0)
		t.expectNear(Vec3d.dot(cancel, back), -1, 1e-9, "back is the opposite of forward")
	end)

	t.test("brake: cancels the relative velocity without overshooting", function()
		local rel = Vec3d.new(2, 0, 0)
		local a = Eva.brakeAccel(rel, GameConfig.EVA_THRUST_ACCEL, FRAME)
		t.expectNear(a.x, -GameConfig.EVA_THRUST_ACCEL, 1e-9, "full thrust against the drift")
		local tiny = Vec3d.new(0.01, 0, 0)
		local stop = Eva.brakeAccel(tiny, GameConfig.EVA_THRUST_ACCEL, FRAME)
		t.expectNear(tiny.x + stop.x * FRAME, 0, 1e-9, "a small drift stops exactly")
		t.expectEqual(Vec3d.length(Eva.brakeAccel(Vec3d.zero(), 3, FRAME)), 0, "nothing to brake")
		-- braking frame by frame brings 2 m/s to rest in about 2/3 s
		local v = Vec3d.new(0, -2, 0)
		local time = 0
		while Vec3d.length(v) > 1e-9 and time < 2 do
			v = Vec3d.addScaled(v, Eva.brakeAccel(v, GameConfig.EVA_THRUST_ACCEL, FRAME), FRAME)
			time += FRAME
		end
		t.expectNear(time, 2 / GameConfig.EVA_THRUST_ACCEL, FRAME * 1.5)
	end)

	t.test("fuel: EVA_PROPELLANT_S seconds of full thrust, refills aboard", function()
		local full = GameConfig.EVA_PROPELLANT_S
		local fuel, fraction = Eva.burn(full, GameConfig.EVA_THRUST_ACCEL, 1)
		t.expectNear(fuel, full - 1, 1e-9, "one second of full thrust")
		t.expectEqual(fraction, 1)
		local half, halfFraction = Eva.burn(full, GameConfig.EVA_THRUST_ACCEL / 2, 1)
		t.expectNear(half, full - 0.5, 1e-9, "half thrust uses half")
		t.expectEqual(halfFraction, 1)
		local last, lastFraction = Eva.burn(0.25, GameConfig.EVA_THRUST_ACCEL, 1)
		t.expectEqual(last, 0, "runs dry")
		t.expectNear(lastFraction, 0.25, 1e-9, "only a quarter of the push")
		local empty, emptyFraction = Eva.burn(0, GameConfig.EVA_THRUST_ACCEL, 1)
		t.expectEqual(empty, 0)
		t.expectEqual(emptyFraction, 0, "no push from an empty tank")
		local same = Eva.burn(10, 0, 1)
		t.expectEqual(same, 10, "coasting uses nothing")
		t.expectNear(Eva.refill(0, GameConfig.EVA_REFILL_S / 2), full / 2, 1e-9, "half full halfway")
		t.expectEqual(Eva.refill(full - 1, 100), full, "never above full")
	end)

	t.test("walking gravity and the jetpack hop", function()
		t.expectNear(Eva.walkGravity(Bodies.HOMEWORLD), GameConfig.CHARACTER_GRAVITY, 0.5, "Earth: the Roblox feel")
		local mun = Eva.walkGravity(Bodies.MOON)
		t.expectNear(mun, GameConfig.CHARACTER_GRAVITY * 1.62 / GameConfig.G0, 1e-6, "Mun: about a sixth")
		local mass = 12
		local force = Eva.hopForce(mass, mun)
		t.expectTrue(force > mass * mun, "the hop beats the weight")
		t.expectNear(force / (mass * mun), GameConfig.EVA_SURFACE_HOP_G, 1e-9)
	end)

	t.test("collide removes only the velocity into the surface", function()
		local up = Vec3d.new(0, 1, 0)
		local v = Eva.collide(Vec3d.new(3, -2, 1), Vec3d.zero(), up)
		t.expectNear(v.y, 0, 1e-12, "into the floor: gone")
		t.expectNear(v.x, 3, 1e-12, "along the floor: kept")
		local away = Eva.collide(Vec3d.new(0, 2, 0), Vec3d.zero(), up)
		t.expectNear(away.y, 2, 1e-12, "moving away: kept")
		-- relative to a drifting craft: 710 m/s orbit, closing at 1 m/s
		local craftVel = Vec3d.new(0, 0, 710)
		local closing = Eva.collide(Vec3d.new(0, -1, 710), craftVel, up)
		t.expectNear(closing.y, 0, 1e-9, "stops relative to the hull")
		t.expectNear(closing.z, 710, 1e-9)
	end)

	t.test("walk or float: stationary pockets near the ground, with hysteresis", function()
		t.expectTrue(Eva.stationaryPocket(0, 1), "a landed craft")
		t.expectTrue(not Eva.stationaryPocket(3, 1), "a moving craft")
		t.expectTrue(not Eva.stationaryPocket(0, 0.9), "a tilted pocket")
		t.expectTrue(not Eva.stationaryPocket(0 / 0, 1), "NaN")
		t.expectTrue(Eva.shouldWalk(false, true, 0.2, 2), "touch down slowly: walk")
		t.expectTrue(not Eva.shouldWalk(false, true, 5, 2), "still above the ground: float")
		t.expectTrue(not Eva.shouldWalk(false, true, 0.2, 40), "sliding fast: float")
		t.expectTrue(Eva.shouldWalk(true, true, 30, 10), "a hop keeps walking")
		t.expectTrue(not Eva.shouldWalk(true, true, 80, 10), "a long jetpack climb floats")
		t.expectTrue(not Eva.shouldWalk(true, false, 0, 0), "the craft lifts off: float")
	end)

	t.test("time jumps: a small step back is a straight line, a big jump only resyncs", function()
		local pos, vel = orbitState()
		local astronaut = Eva.new(Bodies.HOMEWORLD, pos, vel, 50)
		Eva.advance(astronaut, 49.9)
		t.expectNear(astronaut.pos.z, pos.z - vel.z * 0.1, 1e-6, "back along the velocity")
		t.expectNear(astronaut.ut, 49.9, 1e-12)
		local before = Vec3d.clone(astronaut.pos)
		Eva.advance(astronaut, 60)
		t.expectEqual(astronaut.ut, 60, "resynced")
		t.expectNear(Vec3d.distance(before, astronaut.pos), 0, 1e-9, "without moving")
		t.expectTrue(not Eva.advance(astronaut, 0 / 0), "NaN time is ignored")
	end)

	t.test("setBody keeps the true position and velocity", function()
		local astronaut = Eva.new(Bodies.HOMEWORLD, Vec3d.new(452000, 100, 3000), Vec3d.new(1, 2, 3), 1234)
		local absolute = Vec3d.add(astronaut.pos, Universe.bodyPosition(Bodies.HOMEWORLD, 1234))
		Eva.setBody(astronaut, Bodies.MOON)
		t.expectEqual(astronaut.bodyId, Bodies.MOON)
		local again = Vec3d.add(astronaut.pos, Universe.bodyPosition(Bodies.MOON, 1234))
		t.expectNear(Vec3d.distance(absolute, again), 0, 1e-6)
		Eva.setBody(astronaut, Bodies.HOMEWORLD)
		t.expectNear(astronaut.vel.x, 1, 1e-9, "velocity round trip")
		t.expectNear(astronaut.vel.z, 3, 1e-9)
	end)
end
