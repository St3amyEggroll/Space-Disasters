--!strict
-- Tests for Universe, Atmosphere and SurfaceHeight.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Atmosphere = require(ReplicatedStorage.Shared.Sim.Atmosphere)
local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

return function(t: TestKit.Context)
	t.test("moon orbit: radius, period and velocity", function()
		local moon = Bodies.get(Bodies.MOON)
		local orbit = moon.Orbit :: any
		local p0 = Universe.bodyPosition(Bodies.MOON, 0)
		t.expectNear(Vec3d.length(p0), 220000, 1e-6)
		t.expectNear(p0.x, 220000, 1e-6) -- phase 0 at UT 0
		local p1 = Universe.bodyPosition(Bodies.MOON, orbit.Period)
		t.expectNear(Vec3d.distance(p0, p1), 0, 1e-3)
		local v = Universe.bodyVelocity(Bodies.MOON, 123)
		t.expectNear(Vec3d.length(v), math.sqrt(Bodies.get(Bodies.HOMEWORLD).Mu / 220000), 1e-6)
		-- velocity is the derivative of position
		local a = Universe.bodyPosition(Bodies.MOON, 123 - 0.5)
		local b = Universe.bodyPosition(Bodies.MOON, 123 + 0.5)
		t.expectNear((b.x - a.x) - v.x, 0, 1e-2)
	end)

	t.test("SOI transitions in and out of the Moon", function()
		local ut = 0
		local moonPos = Universe.bodyPosition(Bodies.MOON, ut)
		local near = Vec3d.add(moonPos, Vec3d.new(0, 1000, 20000)) -- inside the ~35 km SOI
		local body, rel = Universe.soiTransition(Bodies.HOMEWORLD, near, ut)
		t.expectEqual(body, Bodies.MOON)
		t.expectNear(rel.z, 20000, 1e-6)
		local outside = Vec3d.new(0, 0, 90000)
		local back, relBack = Universe.soiTransition(Bodies.MOON, outside, ut)
		t.expectEqual(back, Bodies.HOMEWORLD)
		t.expectNear(relBack.x, moonPos.x, 1e-6)
		local stay = Universe.soiTransition(Bodies.HOMEWORLD, Vec3d.new(70000, 0, 0), ut)
		t.expectEqual(stay, Bodies.HOMEWORLD)
	end)

	t.test("sun direction is a unit vector that circles once per day", function()
		local d0 = Universe.sunDirection(0)
		t.expectNear(Vec3d.length(d0), 1, 1e-12)
		local dDay = Universe.sunDirection(1200)
		t.expectNear(Vec3d.distance(d0, dDay), 0, 1e-9)
	end)

	t.test("atmosphere density profile", function()
		t.expectNear(Atmosphere.density(Bodies.HOMEWORLD, 0), 1.225, 1e-9)
		t.expectNear(Atmosphere.density(Bodies.HOMEWORLD, 1000), 1.225 / math.exp(1), 1e-9)
		t.expectEqual(Atmosphere.density(Bodies.HOMEWORLD, 7000), 0)
		t.expectTrue(Atmosphere.density(Bodies.HOMEWORLD, 6500) < Atmosphere.density(Bodies.HOMEWORLD, 5500) * 0.6)
		t.expectEqual(Atmosphere.density(Bodies.MOON, 0), 0)
		t.expectNear(Atmosphere.pressureRatio(Bodies.HOMEWORLD, 0), 1, 1e-12)
	end)

	t.test("surface tiles: odd count, launch site on a face-centre tile", function()
		local n = SurfaceHeight.tilesPerFace(Bodies.HOMEWORLD)
		t.expectTrue(n % 2 == 1)
		local base = SurfaceHeight.tileOf(Bodies.HOMEWORLD, Vec3d.new(1, 0, 0))
		t.expectEqual(base.face, 1)
		t.expectEqual(base.i, (n - 1) / 2)
		local center = SurfaceHeight.tileCenter(Bodies.HOMEWORLD, base)
		t.expectNear(center.x, 1, 1e-12)
		-- heights on the base tile are exact plane distances
		local h = SurfaceHeight.height(Bodies.HOMEWORLD, Vec3d.new(30010, 600, -250))
		t.expectNear(h, 10, 1e-9)
		local w, d = SurfaceHeight.tileExtent(Bodies.HOMEWORLD, base)
		t.expectNear(w, 2048, 200)
		t.expectNear(d, 2048, 200)
		-- tile rotation: Y is the tile up
		local rot = SurfaceHeight.tileRotation(Bodies.HOMEWORLD, base)
		t.expectNear((rot.UpVector - Vector3.new(1, 0, 0)).Magnitude, 0, 1e-6)
	end)

	t.test("every point on the sphere lies just below its tile's tangent plane", function()
		for _, dir in { Vec3d.new(0.3, 0.9, -0.2), Vec3d.new(-0.7, -0.1, 0.7), Vec3d.new(0.577, 0.577, 0.577) } do
			local p = Vec3d.scale(Vec3d.normalize(dir), 30000)
			local h = SurfaceHeight.height(Bodies.HOMEWORLD, p)
			t.expectTrue(h <= 1e-6 and h > -40, "height " .. h)
		end
	end)
	-- CHANGED (Phase 2a feedback): rockets stand on their pad with real physics
	t.test("launch pads and plots are raised platforms in the ground height", function()
		local up = Frames.surfaceUp(0, 0)
		local home = Bodies.get(Bodies.HOMEWORLD)
		local baseFrame =
			Frames.new(Bodies.HOMEWORLD, Vec3d.scale(up, home.Radius), Frames.surfaceRotation(up), Vector3.zero)
		local pad = BaseLayout.pad(3).top.Position
		local onPad = Frames.pointFromWorkspace(baseFrame, pad + Vector3.new(10, 0, -20))
		t.expectNear(SurfaceHeight.height(Bodies.HOMEWORLD, onPad), 0, 1e-6)
		local beside = Frames.pointFromWorkspace(baseFrame, Vector3.new(pad.X, 0, pad.Z + BaseLayout.PAD_SIZE))
		t.expectNear(SurfaceHeight.height(Bodies.HOMEWORLD, beside), 0, 1e-6)
		local plot = BaseLayout.plot(1).center
		local onPlot = Frames.pointFromWorkspace(baseFrame, plot + Vector3.new(0, 2, 0))
		t.expectNear(SurfaceHeight.height(Bodies.HOMEWORLD, onPlot), 2, 1e-6)
	end)
end
