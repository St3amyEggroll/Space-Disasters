--!strict
-- Sanity tests for the config modules, including the Section 6.2 sanity example.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)

return function(t: TestKit.Context)
	-- CHANGED (Phase 2a feedback): bodies halved (DECISIONS D27)
	t.test("body constants match the spec", function()
		local home = Bodies.get(Bodies.HOMEWORLD)
		local moon = Bodies.get(Bodies.MOON)
		t.expectRelNear(home.Mu, 8.829e9, 1e-9)
		t.expectRelNear(moon.Mu, 9.1125e7, 1e-9)
		t.expectNear(moon.SoiRadius, 35300, 200)
		local orbit = moon.Orbit
		t.expectTrue(orbit ~= nil, "moon has an orbit")
		if orbit then
			t.expectNear(orbit.Period, 6900, 20)
		end
		t.expectTrue(Bodies.get(Bodies.SUN).VisualOnly)
		t.expectEqual(#Bodies.physicalBodies(), 2)
	end)

	t.test("low orbit numbers from the spec rationale", function()
		local home = Bodies.get(Bodies.HOMEWORLD)
		local r = home.Radius + 10000
		local v = math.sqrt(home.Mu / r)
		t.expectNear(v, 470, 5)
		local period = 2 * math.pi * math.sqrt(r ^ 3 / home.Mu)
		t.expectNear(period / 60, 8.9, 0.5)
	end)

	t.test("every part fits the grid and has stats", function()
		t.expectEqual(#Parts.List, 23)
		for _, def in Parts.List do
			t.expectTrue(def.DryMass > 0, def.Id .. " dry mass")
			t.expectTrue(def.CrashTolerance > 0, def.Id .. " crash tolerance")
			t.expectTrue(def.Size.X >= 1 and def.Size.Y >= 1 and def.Size.Z >= 1, def.Id .. " size")
		end
		t.expectTrue(Parts.find("nope") == nil)
		t.expectError(function()
			Parts.get("nope")
		end)
	end)

	t.test("Section 6.2 sanity example: ~4.15 t, TWR ~1.9, ~2,100 m/s", function()
		local ids = { "pod_mk1", "chute_s", "decoupler_s", "tank_s_long", "engine_s" }
		local wet = 0
		local fuel = 0
		for _, id in ids do
			local def = Parts.get(id)
			wet += Parts.wetMass(def)
			fuel += def.FuelMass
		end
		t.expectNear(wet, 4150, 1e-9)

		local engine = Parts.get("engine_s").Engine
		t.expectTrue(engine ~= nil)
		if engine then
			local g0 = GameConfig.G0
			local thrustAsl = Parts.thrustAt(engine, 1, g0)
			local twr = thrustAsl / (wet * Bodies.get(Bodies.HOMEWORLD).SurfaceGravity)
			t.expectNear(twr, 1.9, 0.1)
			-- the decoupler stays with the lower stage, so the whole stack burns the tank
			local dv = engine.IspVac * g0 * math.log(wet / (wet - fuel))
			t.expectNear(dv, 2100, 105)
			t.expectRelNear(Parts.thrustAt(engine, 0, g0), engine.ThrustVac, 1e-12)
		end
	end)

	t.test("config is frozen", function()
		t.expectTrue(table.isfrozen(GameConfig))
		t.expectTrue(table.isfrozen(GameConfig.WARP_RATES))
	end)
end
