--!strict
-- Tests for Shared/Sim/LineOfSight (Phase 3): planets hide craft markers behind them.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local LineOfSight = require(ReplicatedStorage.Shared.Sim.LineOfSight)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

return function(t: TestKit.Context)
	local home = Bodies.get(Bodies.HOMEWORLD)
	local R = home.Radius

	t.test("a craft on the far side of the planet is hidden", function()
		local camera = Vec3d.new(R + 1000, 0, 0)
		local craft = Vec3d.new(-(R + 1000), 0, 0)
		t.expectTrue(LineOfSight.blocked(Bodies.HOMEWORLD, camera, craft, 0))
	end)

	t.test("a craft beside us, or above the horizon, is visible", function()
		local camera = Vec3d.new(R + 1000, 0, 0)
		t.expectTrue(not LineOfSight.blocked(Bodies.HOMEWORLD, camera, Vec3d.new(R + 1000, 5000, 0), 0))
		t.expectTrue(not LineOfSight.blocked(Bodies.HOMEWORLD, camera, Vec3d.new(R + 100000, 0, 0), 0))
	end)

	t.test("a craft sitting on the ground below us is visible", function()
		local camera = Vec3d.new(R + 5000, 0, 0)
		local craft = Vec3d.new(R, 0, 0)
		t.expectTrue(not LineOfSight.blocked(Bodies.HOMEWORLD, camera, craft, 0))
	end)

	t.test("the moon blocks a line through it (other body than the reference)", function()
		local ut = 0
		local moon = Universe.bodyOffset(Bodies.MOON, Bodies.HOMEWORLD, ut)
		local dir = Vec3d.normalize(moon)
		local before = Vec3d.sub(moon, Vec3d.scale(dir, 30000))
		local after = Vec3d.add(moon, Vec3d.scale(dir, 30000))
		t.expectTrue(LineOfSight.blocked(Bodies.HOMEWORLD, before, after, ut))
	end)

	t.test("two crafts on the ground a few km apart still see each other's markers", function()
		local a = Vec3d.new(R + 2, 0, 0)
		local angle = 4000 / R -- 4 km along the surface
		local b = Vec3d.new(R * math.cos(angle), 0, R * math.sin(angle))
		t.expectTrue(not LineOfSight.blocked(Bodies.HOMEWORLD, a, b, 0))
	end)

	t.test("segment vs sphere", function()
		local center = Vec3d.new(0, 0, 0)
		t.expectTrue(LineOfSight.segmentHitsSphere(Vec3d.new(-1e4, 0, 0), Vec3d.new(1e4, 0, 0), center, 1000))
		t.expectTrue(not LineOfSight.segmentHitsSphere(Vec3d.new(-1e4, 2000, 0), Vec3d.new(1e4, 2000, 0), center, 1000))
		-- a segment that stops before the sphere
		t.expectTrue(not LineOfSight.segmentHitsSphere(Vec3d.new(-1e4, 0, 0), Vec3d.new(-5000, 0, 0), center, 1000))
	end)
end
