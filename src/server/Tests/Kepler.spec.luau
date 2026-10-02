--!strict
-- Tests for Shared/Sim/Kepler: propagation round trips, conservation, elements, crossing searches, map points.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Kepler = require(ReplicatedStorage.Shared.Sim.Kepler)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

local HOME = Bodies.get(Bodies.HOMEWORLD)
local MOON = Bodies.get(Bodies.MOON)
local MU = HOME.Mu

local function energy(r: Vec3d, v: Vec3d): number
	return 0.5 * Vec3d.lengthSq(v) - MU / Vec3d.length(r)
end

local function angleDiff(a: number, b: number): number
	local d = (a - b) % (2 * math.pi)
	return math.min(d, 2 * math.pi - d)
end

-- Deterministic pseudo-random numbers (no math.random seeding differences between Studio and Lune).
local function lcg(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

return function(t: TestKit.Context)
	t.test("Stumpff functions are continuous across the series boundary", function()
		for _, z in { 0.1, -0.1 } do
			local c1, s1 = Kepler.stumpff(z * (1 - 1e-12))
			local c2, s2 = Kepler.stumpff(z * (1 + 1e-12))
			t.expectNear(c1, c2, 1e-12)
			t.expectNear(s1, s2, 1e-12)
		end
		local c0, s0 = Kepler.stumpff(0)
		t.expectNear(c0, 0.5, 1e-15)
		t.expectNear(s0, 1 / 6, 1e-15)
	end)

	t.test("circular prograde equatorial orbit: elements", function()
		local r = HOME.Radius + 10000
		local v = Universe.circularSpeed(Bodies.HOMEWORLD, r)
		-- eastward at lat 0 / lon 0 is +Z (D9)
		local el = Kepler.elements(MU, Vec3d.new(r, 0, 0), Vec3d.new(0, 0, v))
		t.expectEqual(el.kind, "Elliptic")
		t.expectNear(el.e, 0, 1e-9)
		t.expectNear(el.i, 0, 1e-9, "eastward orbits are prograde (i = 0)")
		t.expectRelNear(el.a, r, 1e-12)
		t.expectRelNear(el.periapsis, r, 1e-9)
		t.expectRelNear(el.apoapsis, r, 1e-9)
		t.expectRelNear(el.period, 2 * math.pi * math.sqrt(r ^ 3 / MU), 1e-12)
		t.expectTrue(el.circular and el.equatorial, "flags")
		-- the Moon's orbit is the reference plane too
		local moonEl =
			Kepler.elements(MU, Universe.bodyPosition(Bodies.MOON, 100), Universe.bodyVelocity(Bodies.MOON, 100))
		t.expectNear(moonEl.i, 0, 1e-9)
	end)

	t.test("elements -> state -> elements round trips (elliptic and hyperbolic)", function()
		local random = lcg(7)
		for _ = 1, 60 do
			local hyperbolic = random() < 0.3
			local e = if hyperbolic then 1.05 + random() * 2 else 0.01 + random() * 0.9
			local p = (HOME.Radius + 2000 + random() * 200000) * (1 + e)
			local input = {
				p = p,
				e = e,
				i = 0.05 + random() * 3.0,
				raan = random() * 6.2,
				argPe = random() * 6.2,
				trueAnomaly = if hyperbolic then (random() - 0.5) * 2 * math.acos(-1 / e) * 0.9 else random() * 6.2,
			}
			local r, v = Kepler.stateFromElements(MU, input)
			local el = Kepler.elements(MU, r, v)
			t.expectRelNear(el.p, p, 1e-9, "p")
			t.expectNear(el.e, e, 1e-9, "e")
			t.expectNear(el.i, input.i, 1e-9, "i")
			t.expectNear(angleDiff(el.raan, input.raan), 0, 1e-8, "raan")
			t.expectNear(angleDiff(el.argPe, input.argPe), 0, 1e-7, "argPe")
			t.expectNear(angleDiff(el.trueAnomaly, input.trueAnomaly), 0, 1e-7, "true anomaly")
			t.expectEqual(el.kind, if hyperbolic then "Hyperbolic" else "Elliptic")
		end
	end)

	t.test("state -> elements -> state round trips for degenerate orbits", function()
		local r0 = HOME.Radius + 15000
		local vc = math.sqrt(MU / r0)
		local cases: { { r: Vec3d, v: Vec3d } } = {
			{ r = Vec3d.new(r0, 0, 0), v = Vec3d.new(0, 0, vc) }, -- circular prograde equatorial
			{ r = Vec3d.new(r0, 0, 0), v = Vec3d.new(0, 0, -vc) }, -- circular retrograde equatorial
			{ r = Vec3d.new(0, 0, r0), v = Vec3d.new(0, vc, 0) }, -- circular polar
			{ r = Vec3d.new(r0, 0, 0), v = Vec3d.new(0, 0, vc * 1.2) }, -- elliptic equatorial
			{ r = Vec3d.new(-r0, 0, 3), v = Vec3d.new(10, 0, -vc * 1.1) }, -- elliptic retrograde equatorial
			{ r = Vec3d.new(r0, 0, 0), v = Vec3d.new(0, vc * 0.3, vc) }, -- circular-ish inclined
		}
		for index, case in cases do
			local el = Kepler.elements(MU, case.r, case.v)
			local r, v = Kepler.stateFromElements(MU, {
				p = el.p,
				e = el.e,
				i = el.i,
				raan = el.raan,
				argPe = el.argPe,
				trueAnomaly = el.trueAnomaly,
			})
			t.expectNear(Vec3d.distance(r, case.r), 0, 1e-4, `position, case {index}`)
			t.expectNear(Vec3d.distance(v, case.v), 0, 1e-7, `velocity, case {index}`)
		end
	end)

	t.test("propagate forward then back: relative error < 1e-6 (elliptic, hyperbolic, parabolic, radial)", function()
		local r0 = Vec3d.new(HOME.Radius + 12000, 340, -2500)
		local vEsc = math.sqrt(2 * MU / Vec3d.length(r0))
		local cases: { { v: Vec3d, dt: number } } = {
			{ v = Vec3d.new(30, 20, 520), dt = 3000 },
			{ v = Vec3d.new(100, 50, 900), dt = 20000 },
			{ v = Vec3d.new(0, 0, vEsc), dt = 5000 },
			{ v = Vec3d.new(200, 0, 50), dt = 100 }, -- nearly radial
			{ v = Vec3d.scale(Vec3d.normalize(r0), 600), dt = 80 }, -- exactly radial (bound)
			{ v = Vec3d.scale(Vec3d.normalize(r0), 900), dt = 4000 }, -- exactly radial (escape)
		}
		for index, case in cases do
			local r1, v1 = Kepler.propagate(MU, r0, case.v, case.dt)
			local r2, v2 = Kepler.propagate(MU, r1, v1, -case.dt)
			t.expectTrue(
				Vec3d.distance(r2, r0) / Vec3d.length(r0) < 1e-6,
				`position round trip, case {index}: {Vec3d.distance(r2, r0)}`
			)
			t.expectTrue(
				Vec3d.distance(v2, case.v) / Vec3d.length(case.v) < 1e-6,
				`velocity round trip, case {index}: {Vec3d.distance(v2, case.v)}`
			)
		end
	end)

	t.test("energy and angular momentum are conserved", function()
		local r0 = Vec3d.new(HOME.Radius + 9000, 1200, 0)
		local v0 = Vec3d.new(-40, 90, 610)
		local e0 = energy(r0, v0)
		local h0 = Vec3d.cross(r0, v0)
		for _, dt in { 1, 37.5, 600, 4321, 98765 } do
			local r, v = Kepler.propagate(MU, r0, v0, dt)
			t.expectRelNear(energy(r, v), e0, 1e-10, "energy")
			t.expectNear(Vec3d.distance(Vec3d.cross(r, v), h0) / Vec3d.length(h0), 0, 1e-10, "angular momentum")
		end
	end)

	t.test("10 orbits stay within 1 m of a fresh propagation", function()
		local r0 = Vec3d.new(HOME.Radius + 10000, 0, 0)
		local v0 = Vec3d.new(0, 35, 520)
		local el = Kepler.elements(MU, r0, v0)
		local total = 10 * el.period + 123.4
		-- chained: 997 short hops, the way a long session on rails would re-epoch
		local r, v = Vec3d.clone(r0), Vec3d.clone(v0)
		local hops = 997
		for _ = 1, hops do
			r, v = Kepler.propagate(MU, r, v, total / hops)
		end
		local fresh = Kepler.propagate(MU, r0, v0, total)
		t.expectTrue(Vec3d.distance(r, fresh) < 1, "chained vs fresh " .. Vec3d.distance(r, fresh) .. " m")
		-- exactly ten periods later the craft is back where it started
		local back = Kepler.propagate(MU, r0, v0, 10 * el.period)
		t.expectTrue(Vec3d.distance(back, r0) < 1, "after 10 periods " .. Vec3d.distance(back, r0) .. " m")
	end)

	t.test("apsis times: r.v = 0 at both apsides and the radii match", function()
		local r0 = Vec3d.new(HOME.Radius + 20000, 0, 0)
		local v0 = Vec3d.new(120, 0, 560)
		local el = Kepler.elements(MU, r0, v0)
		local rAp, vAp = Kepler.propagate(MU, r0, v0, el.timeToApoapsis :: number)
		t.expectNear(Vec3d.length(rAp), el.apoapsis, 0.05)
		t.expectNear(Vec3d.dot(rAp, vAp) / Vec3d.length(rAp), 0, 1e-3)
		local rPe, vPe = Kepler.propagate(MU, r0, v0, el.timeToPeriapsis :: number)
		t.expectNear(Vec3d.length(rPe), el.periapsis, 0.05)
		t.expectNear(Vec3d.dot(rPe, vPe) / Vec3d.length(rPe), 0, 1e-3)
		-- hyperbolic: approaching periapsis has a time to Pe, no apoapsis
		local hyp = Kepler.elements(MU, Vec3d.new(200000, 0, 0), Vec3d.new(-900, 0, 300))
		t.expectEqual(hyp.kind, "Hyperbolic")
		t.expectEqual(hyp.apoapsis, math.huge)
		t.expectTrue(hyp.timeToApoapsis == nil, "no apoapsis")
		t.expectTrue(hyp.timeToPeriapsis ~= nil and (hyp.timeToPeriapsis :: number) > 0, "approaching periapsis")
		local leaving = Kepler.elements(MU, Vec3d.new(200000, 0, 0), Vec3d.new(900, 0, 300))
		t.expectTrue(leaving.timeToPeriapsis == nil, "periapsis already passed")
	end)

	t.test("radial orbit: periapsis 0, apoapsis 2a, symmetric fall", function()
		local r0 = Vec3d.new(HOME.Radius + 1000, 0, 0)
		local el = Kepler.elements(MU, r0, Vec3d.new(300, 0, 0))
		t.expectTrue(el.radial, "radial")
		t.expectEqual(el.periapsis, 0)
		t.expectRelNear(el.apoapsis, 2 * el.a, 1e-12)
		local up = Kepler.propagate(MU, r0, Vec3d.new(300, 0, 0), el.timeToApoapsis :: number)
		t.expectRelNear(Vec3d.length(up), el.apoapsis, 1e-6)
	end)

	t.test("hyperbolic escape: SOI-radius crossing found to 0.01 s", function()
		local r0 = Vec3d.new(HOME.Radius + 10000, 0, 0)
		local vEsc = math.sqrt(2 * MU / Vec3d.length(r0))
		local v0 = Vec3d.new(0, 0, vEsc * 1.3)
		local limit = 500000
		local dt = Kepler.findRadiusCrossing(MU, r0, v0, limit, 0, 1e6, HOME.Radius)
		t.expectTrue(dt ~= nil, "escapes")
		local tc = dt :: number
		local rIn = Kepler.propagate(MU, r0, v0, tc - 0.011)
		local rOut = Kepler.propagate(MU, r0, v0, tc)
		t.expectTrue(Vec3d.length(rIn) < limit, "just before the crossing it is inside")
		t.expectTrue(Vec3d.length(rOut) >= limit, "the returned time is outside")
		-- an orbit that stays low never crosses
		t.expectTrue(
			Kepler.findRadiusCrossing(MU, r0, Vec3d.new(0, 0, vEsc * 0.7), limit, 0, 1e5, HOME.Radius) == nil,
			"bound low orbit does not reach 500 km"
		)
	end)

	t.test("radius crossing time matches a brute-force scan", function()
		local r0 = Vec3d.new(HOME.Radius + 30000, 0, 0)
		-- CHANGED (Physics feel): periapsis is inside the 60 km planet, so it falls through the atmosphere top
		local v0 = Vec3d.new(-200, 0, 300)
		local top = HOME.Radius + (HOME.Atmosphere :: Bodies.Atmosphere).Top
		local dt = Kepler.findRadiusCrossing(MU, r0, v0, top, 0, 1e4, HOME.Radius) :: number
		t.expectTrue(dt ~= nil, "crosses the atmosphere top")
		local brute = 0
		for step = 0, 200000 do
			local tt = step * 0.005
			if Vec3d.length((Kepler.propagate(MU, r0, v0, tt))) < top then
				brute = tt
				break
			end
		end
		t.expectNear(dt, brute, 0.011)
	end)

	t.test("moving SOI entry: a transfer orbit meets Mun's SOI at the right time", function()
		local moonOrbit = MOON.Orbit :: Bodies.CircularOrbit
		local r1 = HOME.Radius + 10000
		local r2 = moonOrbit.Radius
		local aT = (r1 + r2) / 2
		local vT = math.sqrt(MU * (2 / r1 - 1 / aT))
		local transferTime = math.pi * math.sqrt(aT ^ 3 / MU)
		-- leave from +X at UT 0 heading +Z; arrive at -X; the Moon must be there at UT transferTime
		local ut0 = (math.pi - moonOrbit.PhaseAtUT0 - moonOrbit.AngularRate * transferTime) / moonOrbit.AngularRate
		local r0 = Vec3d.new(r1, 0, 0)
		local v0 = Vec3d.new(0, 0, vT)
		local function moonAt(dt: number): Vec3d
			return Universe.bodyPosition(Bodies.MOON, ut0 + dt)
		end
		local speed = moonOrbit.Radius * moonOrbit.AngularRate
		local dt = Kepler.findSphereEntry(MU, r0, v0, moonAt, speed, MOON.SoiRadius, 0, transferTime * 1.2, HOME.Radius)
		t.expectTrue(dt ~= nil, "encounter found")
		local tc = dt :: number
		t.expectTrue(tc < transferTime, "enters before reaching apoapsis")
		local inside = Vec3d.distance((Kepler.propagate(MU, r0, v0, tc)), moonAt(tc))
		local before = Vec3d.distance((Kepler.propagate(MU, r0, v0, tc - 0.011)), moonAt(tc - 0.011))
		t.expectTrue(inside <= MOON.SoiRadius, "inside at the returned time")
		t.expectTrue(before > MOON.SoiRadius, "outside 0.011 s earlier")
	end)

	t.test("conic points lie on the orbit", function()
		local r0 = Vec3d.new(HOME.Radius + 20000, 500, 0)
		-- CHANGED (Physics feel): x1.4 for the 60 km Earth, so this stays an eccentric ellipse whose period
		-- (~1,900 s) is longer than the partial arc below
		local v0 = Vec3d.new(112, 56, 790)
		local el = Kepler.elements(MU, r0, v0)
		local points = Kepler.conicPoints(MU, r0, v0, 0, el.period, 64)
		t.expectEqual(#points, 65)
		t.expectNear(Vec3d.distance(points[1], points[65]), 0, 1e-3, "closed")
		t.expectNear(Vec3d.distance(points[1], r0), 0, 1e-3, "starts at the craft")
		local h = Vec3d.normalize(Vec3d.cross(r0, v0))
		for _, p in points do
			local rr = Vec3d.length(p)
			t.expectTrue(rr >= el.periapsis - 1e-3 and rr <= el.apoapsis + 1e-3, "between the apsides")
			t.expectNear(Vec3d.dot(p, h), 0, 1e-3, "in the orbit plane")
		end
		-- a partial arc ends at the propagated position
		local arc = Kepler.conicPoints(MU, r0, v0, 100, 900, 16)
		t.expectNear(Vec3d.distance(arc[17], (Kepler.propagate(MU, r0, v0, 900))), 0, 1e-2)
		t.expectNear(Vec3d.distance(arc[1], (Kepler.propagate(MU, r0, v0, 100))), 0, 1e-2)
		-- hyperbola
		local hv = Vec3d.new(0, 0, math.sqrt(2 * MU / Vec3d.length(r0)) * 1.4)
		local hyp = Kepler.conicPoints(MU, r0, hv, 0, 2000, 32)
		t.expectNear(Vec3d.distance(hyp[33], (Kepler.propagate(MU, r0, hv, 2000))), 0, 1e-2)
	end)
end
