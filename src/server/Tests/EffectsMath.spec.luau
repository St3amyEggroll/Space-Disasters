--!strict
-- Tests for Render/EffectsMath (Phase 10): plume shaping by air pressure, smoke-trail fading, dust, re-entry heat
-- calibration on the 60 km Earth (CHANGED (Physics feel): was half-size Earth), the vapour cone, drift-aimed particle
-- emission and the small geometry helpers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Atmosphere = require(ReplicatedStorage.Shared.Sim.Atmosphere)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local EffectsMath = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render.EffectsMath)

--============================================================================
-- Tunables
--============================================================================
local EPSILON = 1e-9
-- CHANGED (Physics feel): a pod re-entering from low orbit on the 60 km Earth, measured with the flight model:
-- ~710 m/s at 7 km, ~700 at 6 km, ~670 at 5 km (was 450 m/s on half-size Earth)
local ORBIT_SPEED = 700 -- m/s
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
		t.expectNear(EffectsMath.trailStrength(pressure(6500)), 0, EPSILON) -- CHANGED (Physics feel): 1.1 km scale height
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
			t.expectTrue(
				life >= 1.2 - EPSILON and life <= EffectsMath.TRAIL_LIFETIME_MAX + EPSILON,
				"lifetime within its clamp"
			)
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
		-- CHANGED (Physics feel): altitudes and speeds for the 60 km Earth and the new ascent speeds
		t.expectTrue(EffectsMath.heatFactor(density(6000), ORBIT_SPEED) > 0.4, "re-entry at 6 km should glow")
		t.expectTrue(EffectsMath.heatFactor(density(5000), ORBIT_SPEED) > 0.7, "re-entry at 5 km should glow hard")
		t.expectTrue(EffectsMath.heatFactor(density(7800), ORBIT_SPEED) < 0.25, "barely any glow at the air's top")
		-- the sanity rocket's gravity turn to orbit (measured): 220 m/s at 1 km, 340 at 2 km, 450 at 3 km, 490 at 4 km
		t.expectNear(EffectsMath.heatFactor(density(1000), 220), 0, EPSILON)
		t.expectNear(EffectsMath.heatFactor(density(2000), 340), 0, EPSILON)
		t.expectNear(EffectsMath.heatFactor(density(3000), 450), 0, EPSILON)
		t.expectNear(EffectsMath.heatFactor(density(4000), 490), 0, EPSILON)
		-- the most aggressive two-stage gravity turn measured: 620 m/s at 5 km
		t.expectTrue(EffectsMath.heatFactor(density(5000), 620) < 0.15, "only a faint glow on a fast ascent")
		-- vacuum and slow flight never glow
		t.expectNear(EffectsMath.heatFactor(0, 2000), 0, EPSILON)
		t.expectNear(EffectsMath.heatFactor(density(0), 300), 0, EPSILON)
		-- monotonic in speed and density
		t.expectTrue(EffectsMath.heatFactor(density(6000), 690) > EffectsMath.heatFactor(density(6000), 640))
		t.expectTrue(EffectsMath.heatFactor(density(6000), 700) > EffectsMath.heatFactor(density(7000), 700))
		t.expectTrue(EffectsMath.heatFactor(10, 5000) <= 1 + EPSILON, "capped at 1")
	end)

	-- CHANGED (Physics feel): the cone now shows in all but the thinnest air (rockets pass Mach 1 high up), so the
	-- checks use pressure ratios instead of altitudes and follow the atmosphere whatever its size.
	t.test("vapour cone: around Mach 1, in all but the thinnest air", function()
		t.expectTrue(EffectsMath.vaporFactor(340, 1) > 0.9, "peak at Mach 1 near sea level")
		t.expectNear(EffectsMath.vaporFactor(250, 1), 0, EPSILON)
		t.expectNear(EffectsMath.vaporFactor(280, 1), 0, EPSILON) -- Mach 0.82
		t.expectNear(EffectsMath.vaporFactor(420, 1), 0, EPSILON)
		t.expectTrue(EffectsMath.vaporFactor(330, 1) > 0, "starts just below Mach 1")
		t.expectTrue(EffectsMath.vaporFactor(300, 1) > 0, "builds up from about Mach 0.85")
		t.expectTrue(EffectsMath.vaporFactor(340, 0.05) > 0.9, "full in moderately thin air")
		t.expectTrue(EffectsMath.vaporFactor(340, 0.02) > 0.2, "still visible where real ascents go transonic")
		t.expectNear(EffectsMath.vaporFactor(340, 0.004), 0, EPSILON)
		t.expectNear(EffectsMath.vaporFactor(340, 0), 0, EPSILON)
		local top = Atmosphere.top(HOMEWORLD)
		t.expectNear(EffectsMath.vaporFactor(340, pressure(top - 2)), 0, EPSILON) -- the fade band thins it out
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

	-- CHANGED (Effects v2): qualityScale is gone (Render/Quality gives the one tier); budgets per tier instead
	t.test("explosion scale stays in range", function()
		t.expectNear(EffectsMath.explosionScale(Vector3.new(4, 4, 4)), 1, 1e-6) -- Vector3 is 32-bit
		t.expectTrue(EffectsMath.explosionScale(Vector3.new(8, 8, 8)) > 1.5, "bigger blocks, bigger blasts")
		t.expectTrue(EffectsMath.explosionScale(Vector3.new(400, 400, 400)) <= 3, "capped")
		t.expectNear(EffectsMath.fade(0, 1), 0, EPSILON)
		t.expectNear(EffectsMath.fade(2, 1), 1, EPSILON)
	end)

	-- CHANGED (Effects v2): the per-tier budgets, the plasma look and the new helpers
	t.test("budgets: every cap grows Low -> Medium -> High, no lights on phones' tiers", function()
		local low = EffectsMath.budget("Low") :: any
		local medium = EffectsMath.budget("Medium") :: any
		local high = EffectsMath.budget("High") :: any
		for key, value in high do
			local lowValue, mediumValue = low[key], medium[key]
			t.expectTrue(lowValue ~= nil and mediumValue ~= nil, `{key} is set on every tier`)
			if type(value) == "number" then
				t.expectTrue(lowValue <= mediumValue and mediumValue <= value, `{key} grows with the tier`)
				t.expectTrue(lowValue >= 0, `{key} is never negative`)
			else
				t.expectTrue(not lowValue or mediumValue, `{key}: on at Low means on at Medium`)
				t.expectTrue(not mediumValue or value, `{key}: on at Medium means on at High`)
			end
		end
		-- phones never go above Medium: no PointLights there
		for _, tier in { "Low", "Medium" } do
			local budget = EffectsMath.budget(tier)
			t.expectEqual(budget.plumeLights + budget.heatLights + budget.flashLights, 0, `{tier} has no lights`)
			t.expectEqual(budget.heatTint, 0, `{tier} has no part heat tint`)
		end
		t.expectTrue(high.plumeLights > 0 and high.heatLights > 0, "High lights the flames and the plasma")
		t.expectTrue(low.aero >= 1 and low.tongues >= 1, "Low still shows re-entry plasma")
		t.expectTrue(low.trails >= 1 and low.dust >= 1 and low.bursts >= 1, "Low keeps every effect kind")
		t.expectTrue(EffectsMath.budget("Nonsense") == EffectsMath.budget("Low"), "unknown tiers get Low")
		t.expectTrue(table.isfrozen(EffectsMath.budget("High")), "budgets are frozen")
	end)

	t.test("budgets: worst-case emitter counts stay small on Low and grow with the tier", function()
		local low = EffectsMath.worstCaseEmitters(EffectsMath.budget("Low"))
		local medium = EffectsMath.worstCaseEmitters(EffectsMath.budget("Medium"))
		local high = EffectsMath.worstCaseEmitters(EffectsMath.budget("High"))
		t.expectTrue(low < medium and medium < high, "more emitters on higher tiers")
		t.expectTrue(low <= 30, `Low stays at 30 emitters or fewer (got {low})`)
		t.expectTrue(medium <= 60, `Medium stays at 60 emitters or fewer (got {medium})`)
		t.expectTrue(high <= 100, `High stays at 100 emitters or fewer (got {high})`)
		for _, tier in { "Low", "Medium", "High" } do
			local budget = EffectsMath.budget(tier)
			t.expectTrue(budget.tongues <= 8, "tongue beams per heated craft are bounded")
			t.expectTrue(budget.tongueLength > 0 and budget.tongueLength <= 1, "flame length factor within (0, 1]")
		end
		local trailCap = EffectsMath.budget("Low").trailLifetimeMax
		t.expectTrue(EffectsMath.trailLifetime(1, trailCap) <= trailCap + EPSILON, "Low caps the smoke column")
		t.expectTrue(EffectsMath.trailLifetime(1, trailCap) < EffectsMath.trailLifetime(1), "shorter than the default")
	end)

	-- CHANGED (Night review): plume budget per tier (a 100-engine craft was 400 beams, 100 emitters, 100 lights)
	t.test("budgets: plumes are capped per tier, over-budget engines get core + glow only", function()
		local low = EffectsMath.budget("Low")
		local medium = EffectsMath.budget("Medium")
		local high = EffectsMath.budget("High")
		t.expectTrue(low.plumes >= 1 and low.plumes < medium.plumes and medium.plumes < high.plumes, "plumes grow")
		t.expectTrue(low.plumeEvents >= 1 and low.plumeEvents <= high.plumeEvents, "ignition bursts per frame")
		t.expectTrue(high.plumeLights <= high.plumes, "lights only go to full plumes")
		for _, budget in { low, medium, high } do
			local beams, emitters, lights = EffectsMath.plumeLoad(budget, 100)
			t.expectEqual(emitters, budget.plumes, "only the full plumes have emitters")
			t.expectTrue(lights <= budget.plumeLights, "lights within the light budget")
			t.expectTrue(beams <= 200 + 2 * budget.plumes, `core + glow per engine, extras per full plume ({beams})`)
			local oneBeams, oneEmitters = EffectsMath.plumeLoad(budget, 1)
			t.expectEqual(oneEmitters, 1, "a single engine is always drawn in full")
			t.expectTrue(oneBeams >= 2, "core and glow")
		end
		local lowBeams = EffectsMath.plumeLoad(low, 100)
		t.expectEqual(lowBeams, 200, "Low: no halo or diamonds, core + glow on every engine")
		local beams0, emitters0, lights0 = EffectsMath.plumeLoad(high, 0)
		t.expectEqual(beams0 + emitters0 + lights0, 0, "no engines, no load")
	end)

	t.test("plasma: grows with heat from a faint glow to a full shock layer", function()
		local none = EffectsMath.plasma(0)
		t.expectNear(none.shellOpacity, 0, EPSILON)
		t.expectNear(none.streakRate, 0, EPSILON)
		t.expectNear(none.emberRate, 0, EPSILON)
		local previous = none
		for step = 1, 20 do
			local shape = EffectsMath.plasma(step / 20)
			t.expectTrue(shape.shellOpacity >= previous.shellOpacity - EPSILON, "shell brightens")
			t.expectTrue(shape.glowOpacity >= previous.glowOpacity - EPSILON, "edge glow brightens")
			t.expectTrue(shape.tongueLength >= previous.tongueLength - EPSILON, "flames lengthen")
			t.expectTrue(shape.tongueWidth >= previous.tongueWidth - EPSILON, "flames thicken")
			t.expectTrue(shape.streakRate >= previous.streakRate - EPSILON, "more streaks")
			t.expectTrue(shape.emberRate >= previous.emberRate - EPSILON, "more embers")
			t.expectTrue(shape.shellOpacity <= 1 and shape.glowOpacity <= 1, "opacities within 0..1")
			previous = shape
		end
		local full = EffectsMath.plasma(1)
		t.expectNear(full.streakRate, 1, EPSILON)
		t.expectNear(full.emberRate, 1, EPSILON)
		t.expectTrue(full.tongueLength > 3 * none.tongueLength, "full heat streams far behind")
		local faint = EffectsMath.plasma(0.15)
		t.expectNear(faint.emberRate, 0, EPSILON) -- embers only once it is properly hot
		t.expectTrue(faint.shellOpacity > 0, "a faint glow already shows")
		t.expectNear(EffectsMath.plasma(5).shellOpacity, full.shellOpacity, EPSILON) -- clamped
	end)

	t.test("heat colour: orange when it first glows, white-hot front with pink / blue edges at the hottest", function()
		local function brightness(c: Color3): number
			return c.R + c.G + c.B
		end
		local hotFront = EffectsMath.heatColor(1, 0)
		t.expectTrue(hotFront.R > 0.95 and hotFront.G > 0.9 and hotFront.B > 0.85, "white-hot front")
		local warmFront = EffectsMath.heatColor(0.2, 0)
		t.expectTrue(warmFront.R > warmFront.G and warmFront.G > warmFront.B, "orange front when it first glows")
		t.expectTrue(warmFront.B < 0.35, "no blue in a faint glow")
		local hotEdge = EffectsMath.heatColor(1, 1)
		t.expectTrue(hotEdge.B > hotEdge.G, "blue-violet tint at the hottest edges")
		local pinkEdge = EffectsMath.heatColor(0.8, 1)
		t.expectTrue(pinkEdge.R > 0.9 and pinkEdge.B > pinkEdge.G, "pinkish edges when very hot")
		local coolEdge = EffectsMath.heatColor(0.1, 1)
		t.expectTrue(coolEdge.R > coolEdge.B * 2, "red edges when barely glowing")
		local previous = 0
		for step = 0, 10 do
			local front = brightness(EffectsMath.heatColor(step / 10, 0))
			t.expectTrue(front >= previous - 1e-6, "the front brightens with heat")
			previous = front
		end
		for step = 0, 10 do
			local heat = step / 10
			t.expectTrue(
				brightness(EffectsMath.heatColor(heat, 0)) >= brightness(EffectsMath.heatColor(heat, 0.5)) - 1e-6,
				"the front is the brightest part"
			)
			for _, at in { -1, 0, 0.3, 0.45, 0.7, 1, 2 } do
				local c = EffectsMath.heatColor(heat, at)
				for _, channel in { c.R, c.G, c.B } do
					t.expectTrue(channel >= 0 and channel <= 1, "channels within 0..1")
				end
			end
		end
	end)

	t.test("heat soak: parts heat up quickly and cool slowly, never overshooting", function()
		local glow = 0
		for _ = 1, 60 do
			glow = EffectsMath.heatSoak(glow, 1, 1 / 30) -- 2 s
		end
		t.expectTrue(glow > 0.75 and glow <= 1, "hot within a couple of seconds")
		local cooling = glow
		for _ = 1, 60 do
			cooling = EffectsMath.heatSoak(cooling, 0, 1 / 30)
		end
		t.expectTrue(cooling > 0.3 and cooling < glow, "still glowing 2 s after the heat ended")
		local risen = EffectsMath.heatSoak(0, 1, 0.5)
		local fallen = 1 - EffectsMath.heatSoak(1, 0, 0.5)
		t.expectTrue(risen > fallen, "heats faster than it cools")
		t.expectNear(EffectsMath.heatSoak(0.4, 0.4, 1), 0.4, EPSILON)
		t.expectTrue(EffectsMath.heatSoak(0.5, 0.6, 100) <= 0.6 + EPSILON, "no overshoot")
		t.expectNear(EffectsMath.heatSoak(0.5, 3, 0), 0.5, EPSILON) -- dt 0 holds
	end)

	t.test("flicker: bounded, moving and seed dependent", function()
		local lowest, highest = math.huge, -math.huge
		for step = 0, 600 do
			local value = EffectsMath.flicker(step / 60, 1.7, 0.2)
			lowest = math.min(lowest, value)
			highest = math.max(highest, value)
		end
		t.expectTrue(lowest >= 0.8 - EPSILON and highest <= 1.2 + EPSILON, "within 1 +- amplitude")
		t.expectTrue(highest - lowest > 0.1, "it actually flickers")
		t.expectTrue(
			math.abs(EffectsMath.flicker(0.3, 1, 0.2) - EffectsMath.flicker(0.3, 5, 0.2)) > 1e-3,
			"different seeds flicker differently"
		)
		t.expectNear(EffectsMath.flicker(0.3, 1, 0), 1, EPSILON)
	end)

	t.test("mach diamonds: at most 20 keypoints, increasing times, transparent ends, fading diamonds", function()
		for count = 0, 9 do
			local keys = EffectsMath.machDiamondKeys(count, 1)
			t.expectTrue(#keys <= 20, "NumberSequence keypoint limit")
			t.expectNear(keys[1][1], 0, EPSILON)
			t.expectNear(keys[#keys][1], 1, EPSILON)
			t.expectNear(keys[1][2], 1, EPSILON)
			t.expectNear(keys[#keys][2], 1, EPSILON)
			for index = 2, #keys do
				t.expectTrue(keys[index][1] > keys[index - 1][1], "times strictly increase")
				t.expectTrue(keys[index][2] >= 0 and keys[index][2] <= 1, "transparency within 0..1")
			end
		end
		local keys = EffectsMath.machDiamondKeys(4, 1)
		t.expectEqual(#keys, 2 + 3 * 4)
		t.expectTrue(keys[3][2] < keys[6][2], "the first diamond is the brightest")
		t.expectTrue(keys[3][2] < keys[2][2], "diamonds are brighter than the gaps")
		local faint = EffectsMath.machDiamondKeys(4, 0)
		for _, key in faint do
			t.expectNear(key[2], 1, EPSILON) -- strength 0: invisible
		end
	end)

	t.test("plume colours: orange at sea level, pale blue in vacuum, boosters redder", function()
		local _, seaStart, seaEnd = EffectsMath.plumeTint(0, false)
		local vacuumCore, _, vacuumEnd = EffectsMath.plumeTint(1, false)
		t.expectTrue(seaEnd.R > seaEnd.G and seaEnd.G > seaEnd.B, "sea-level flame is orange")
		t.expectTrue(seaStart.R > seaStart.B, "sea-level glow is warm")
		t.expectTrue(vacuumEnd.B > vacuumEnd.R, "vacuum plume fades to pale blue")
		t.expectTrue(vacuumCore.B > 0.9, "vacuum core is blue-white")
		local _, _, solidEnd = EffectsMath.plumeTint(0, true)
		t.expectTrue(solidEnd.G < seaEnd.G, "booster flame is deeper orange")
		local _, _, solidVacuumEnd = EffectsMath.plumeTint(1, true)
		t.expectTrue(solidVacuumEnd.R > vacuumEnd.R, "boosters stay warmer in vacuum")
	end)

	t.test("air coupling: smoke stops in thick air, keeps the craft's momentum in vacuum", function()
		t.expectNear(EffectsMath.airCoupling(0), 0, EPSILON)
		t.expectNear(EffectsMath.airCoupling(1), 1, EPSILON)
		t.expectNear(EffectsMath.airCoupling(pressure(500)), 1, EPSILON)
		t.expectNear(EffectsMath.airCoupling(pressure(20000)), 0, EPSILON)
		local mid = EffectsMath.airCoupling(pressure(5000))
		t.expectTrue(mid > 0 and mid < 1, "partly carried in thin air")
	end)

	t.test("blast scale: grows with the wrecked span and the blocks lost, capped", function()
		local one = EffectsMath.blastScale(4 * math.sqrt(3), 1)
		t.expectNear(one, 1, 1e-9)
		t.expectTrue(EffectsMath.blastScale(40, 1) > one, "bigger wrecks, bigger blasts")
		t.expectTrue(EffectsMath.blastScale(20, 12) > EffectsMath.blastScale(20, 2), "more blocks, bigger blast")
		t.expectTrue(EffectsMath.blastScale(1e6, 1000) <= 4.5 + EPSILON, "capped")
		t.expectTrue(EffectsMath.blastScale(0, 0) >= 0.6 - EPSILON, "never vanishes")
	end)
end
