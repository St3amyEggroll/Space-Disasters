--!strict
-- Tests for Render/EffectsMath (Phase 10): plume shaping by air pressure, smoke-trail fading, dust, re-entry heat
-- calibration on half-size Kablamo, the vapour cone, drift-aimed particle emission and the small geometry helpers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Atmosphere = require(ReplicatedStorage.Shared.Sim.Atmosphere)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local EffectsMath = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render.EffectsMath)

--============================================================================
-- Tunables
--============================================================================
local EPSILON = 1e-9
local ORBIT_SPEED = 450 -- m/s, a re-entry from a 15 km orbit on half-size Kablamo
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD

local function density(altitude: number): number
	return Atmosphere.density(HOMEWORLD, altitude)
end

local function pressure(altitude: number): number
	return Atmosphere.pressureRatio(HOMEWORLD, altitude)
end

return function(t: TestKit.Context)
	t.test("plume: tight at sea level, wide faint expanding cone in vacuum", function()
		local sea = EffectsMath.plumeShape(1, 1, false)
		local vacuum = EffectsMath.plumeShape(1, 0, false)
		t.expectTrue(sea.glowWidth1 < sea.glowWidth0, "sea-level glow should narrow toward the tip")
		t.expectTrue(vacuum.glowWidth1 > vacuum.glowWidth0, "vacuum glow should widen toward the tip")
		t.expectTrue(vacuum.length > sea.length, "vacuum plume should be longer")
		t.expectTrue(vacuum.fade > sea.fade, "vacuum plume should be fainter")
		t.expectTrue(vacuum.coreBrightness < sea.coreBrightness, "vacuum core should be dimmer")
		t.expectTrue(vacuum.spreadDeg > sea.spreadDeg, "vacuum particles should spread wider")
		t.expectTrue(vacuum.coreLength < sea.coreLength, "vacuum core should be shorter than the glow")
		t.expectNear(sea.fade, 0, EPSILON)
	end)

	t.test("plume: solid boosters are thicker and longer than liquid engines", function()
		for _, p in { 0, 0.3, 1 } do
			local liquid = EffectsMath.plumeShape(1, p, false)
			local solid = EffectsMath.plumeShape(1, p, true)
			t.expectTrue(solid.glowWidth0 > liquid.glowWidth0, "booster glow should be wider")
			t.expectTrue(solid.length > liquid.length, "booster flame should be longer")
			t.expectTrue(solid.particleSize > liquid.particleSize, "booster particles should be bigger")
		end
	end)

	t.test("plume: shape changes monotonically with pressure and throttle", function()
		local previous = EffectsMath.plumeShape(1, 1, false)
		for step = 9, 0, -1 do
			local shape = EffectsMath.plumeShape(1, step / 10, false)
			t.expectTrue(shape.glowWidth1 >= previous.glowWidth1 - EPSILON, "glow opens as the air thins")
			t.expectTrue(shape.length >= previous.length - EPSILON, "flame lengthens as the air thins")
			previous = shape
		end
		local low = EffectsMath.plumeShape(0.05, 1, false)
		local high = EffectsMath.plumeShape(1, 1, false)
		t.expectTrue(low.length < high.length, "throttle shortens the flame")
		t.expectTrue(low.light > 0 and low.light < high.light, "low throttle still glows, less")
	end)

	t.test("trail: full low down, gone high up, fading smoothly", function()
		t.expectNear(EffectsMath.trailStrength(1), 1, EPSILON)
		t.expectNear(EffectsMath.trailStrength(pressure(500)), 1, EPSILON)
		t.expectNear(EffectsMath.trailStrength(pressure(6000)), 0, EPSILON)
		t.expectNear(EffectsMath.trailStrength(0), 0, EPSILON)
		local previous = 1
		for altitude = 0, 7000, 250 do
			local strength = EffectsMath.trailStrength(pressure(altitude))
			t.expectTrue(strength <= previous + EPSILON, `trail should fade with altitude ({altitude} m)`)
			previous = strength
		end
		local mid = EffectsMath.trailStrength(pressure(3000))
		t.expectTrue(mid > 0.05 and mid < 0.95, "trail should be partial at 3 km")
	end)

	t.test("trail: puffs overlap at any speed and the trail length is bounded", function()
		for _, speed in { 0, 50, 200, 470 } do
			local rate = 55
			local size = EffectsMath.trailSize(speed, rate, 4)
			t.expectTrue(size >= 4 - EPSILON, "never thinner than the nozzle width")
			if speed / rate * 1.6 < 45 then
				t.expectTrue(size >= speed / rate, "puffs must cover the gap between them")
			end
			local life = EffectsMath.trailLifetime(speed)
			t.expectTrue(life >= 1.2 - EPSILON and life <= 5 + EPSILON, "lifetime within its clamp")
			t.expectTrue(speed * life <= 900 + EPSILON or life <= 1.2 + EPSILON, "trail length bounded")
		end
	end)

	t.test("dust: only near the ground, stronger closer and with more thrust", function()
		t.expectNear(EffectsMath.dustStrength(EffectsMath.DUST_MAX_HEIGHT, 1), 0, EPSILON)
		t.expectNear(EffectsMath.dustStrength(100, 1), 0, EPSILON)
		t.expectNear(EffectsMath.dustStrength(5, 0), 0, EPSILON)
		local near = EffectsMath.dustStrength(2, 1)
		local far = EffectsMath.dustStrength(30, 1)
		t.expectTrue(near > far and far > 0, "closer is stronger")
		t.expectTrue(EffectsMath.dustStrength(2, 1.5) > EffectsMath.dustStrength(2, 0.5), "more thrust is stronger")
		t.expectTrue(EffectsMath.dustStrength(0, 10) <= 1 + EPSILON, "capped at 1")
	end)

	t.test("heat: visible on a re-entry from orbit, not on a normal ascent", function()
		-- re-entry at orbital speed through the middle of the air
		t.expectTrue(EffectsMath.heatFactor(density(5000), ORBIT_SPEED) > 0.4, "re-entry at 5 km should glow")
		t.expectTrue(EffectsMath.heatFactor(density(4000), ORBIT_SPEED) > 0.7, "re-entry at 4 km should glow hard")
		t.expectTrue(EffectsMath.heatFactor(density(6800), ORBIT_SPEED) < 0.25, "barely any glow at the air's top")
		-- a typical ascent: 150 m/s at 1 km, 250 m/s at 2 km, 330 m/s at 3 km, 400 m/s at 4.5 km
		t.expectNear(EffectsMath.heatFactor(density(1000), 150), 0, EPSILON)
		t.expectNear(EffectsMath.heatFactor(density(2000), 250), 0, EPSILON)
		t.expectNear(EffectsMath.heatFactor(density(3000), 330), 0, EPSILON)
		t.expectTrue(EffectsMath.heatFactor(density(4500), 400) < 0.15, "only a faint glow on a fast ascent")
		-- vacuum and slow flight never glow
		t.expectNear(EffectsMath.heatFactor(0, 2000), 0, EPSILON)
		t.expectNear(EffectsMath.heatFactor(density(0), 300), 0, EPSILON)
		-- monotonic in speed and density
		t.expectTrue(EffectsMath.heatFactor(density(4000), 470) >= EffectsMath.heatFactor(density(4000), 430))
		t.expectTrue(EffectsMath.heatFactor(density(3500), 450) >= EffectsMath.heatFactor(density(5000), 450))
		t.expectTrue(EffectsMath.heatFactor(10, 5000) <= 1 + EPSILON, "capped at 1")
	end)

	t.test("vapour cone: around Mach 1, low in the air only", function()
		t.expectTrue(EffectsMath.vaporFactor(340, 1) > 0.9, "peak at Mach 1 near sea level")
		t.expectNear(EffectsMath.vaporFactor(250, 1), 0, EPSILON)
		t.expectNear(EffectsMath.vaporFactor(420, 1), 0, EPSILON)
		t.expectNear(EffectsMath.vaporFactor(340, pressure(4000)), 0, EPSILON)
		t.expectTrue(EffectsMath.vaporFactor(330, 1) > 0, "starts just below Mach 1")
	end)

	t.test("drift emission: cone and speeds cover drift plus the random part", function()
		local direction, speedMin, speedMax, spread = EffectsMath.driftEmission(Vector3.zero, 10)
		t.expectNear(spread, 180, EPSILON)
		t.expectTrue(speedMax <= 10 + EPSILON and speedMin >= 0, "random speeds only")
		t.expectNear(direction.Magnitude, 1, 1e-6)

		direction, speedMin, speedMax, spread = EffectsMath.driftEmission(Vector3.new(0, 0, -100), 10)
		t.expectNear(direction.Z, -1, 1e-6)
		t.expectNear(speedMin, 90, 1e-6)
		t.expectNear(speedMax, 110, 1e-6)
		t.expectNear(spread, math.deg(math.asin(0.1)), 1e-6)

		direction, speedMin, speedMax, spread = EffectsMath.driftEmission(Vector3.new(5, 0, 0), 10)
		t.expectNear(direction.X, 1, 1e-6)
		t.expectNear(spread, 180, EPSILON)
		t.expectTrue(speedMax >= 15 - 1e-6, "slow drift: all directions, up to drift + random")
		t.expectTrue(speedMin >= 0, "never negative")
	end)

	t.test("frameWithUp: UpVector is the requested direction, orthonormal", function()
		for _, up in { Vector3.new(0, 0, 1), Vector3.new(1, 2, 3).Unit, Vector3.new(0, -1, 0), Vector3.new(1, 0, 0) } do
			local cf = EffectsMath.frameWithUp(Vector3.new(10, 20, 30), up)
			t.expectNear((cf.UpVector - up).Magnitude, 0, 1e-5)
			t.expectNear(cf.RightVector:Dot(cf.UpVector), 0, 1e-5)
			t.expectNear(cf.LookVector:Dot(cf.UpVector), 0, 1e-5)
			t.expectNear(cf.RightVector.Magnitude, 1, 1e-5)
			t.expectNear((cf.Position - Vector3.new(10, 20, 30)).Magnitude, 0, 1e-5)
		end
	end)

	t.test("leadingExtent: tall rocket along and across its axis", function()
		local half = Vector3.new(2, 10, 2)
		local reach, radius = EffectsMath.leadingExtent(half, Vector3.new(0, 1, 0))
		t.expectNear(reach, 10, 1e-9)
		t.expectNear(radius, math.sqrt(8), 1e-9)
		reach, radius = EffectsMath.leadingExtent(half, Vector3.new(1, 0, 0))
		t.expectNear(reach, 2, 1e-9)
		t.expectTrue(radius > 10, "sideways the cross-section is the rocket's length")
	end)

	t.test("quality scale and explosion scale stay in range", function()
		local previous = 0
		for level = 1, 10 do
			local scale = EffectsMath.qualityScale(level)
			t.expectTrue(scale >= previous, "monotonic in the quality level")
			t.expectTrue(scale > 0 and scale <= 1, "within (0, 1]")
			previous = scale
		end
		t.expectNear(EffectsMath.qualityScale(10), 1, EPSILON)
		local automatic = EffectsMath.qualityScale(0)
		t.expectTrue(automatic > 0 and automatic <= 1, "automatic quality within range")
		t.expectNear(EffectsMath.explosionScale(Vector3.new(4, 4, 4)), 1, 1e-6) -- Vector3 is 32-bit
		t.expectTrue(EffectsMath.explosionScale(Vector3.new(8, 8, 8)) > 1.5, "bigger blocks, bigger blasts")
		t.expectTrue(EffectsMath.explosionScale(Vector3.new(400, 400, 400)) <= 3, "capped")
		t.expectNear(EffectsMath.fade(0, 1), 0, EPSILON)
		t.expectNear(EffectsMath.fade(2, 1), 1, EPSILON)
	end)
end
