--!strict
-- Tests for UI/HudMath (Phase 11): odometer wheels that carry like a real odometer, the log-scaled vertical-speed
-- needle, the throttle arc, the automatic Surface / Orbit speed mode and the heading / pitch texts.

local TestKit = require(script.Parent.TestKit)
local HudMath = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.UI.HudMath)

--============================================================================
-- Tunables
--============================================================================
local EPSILON = 1e-6
local WHEELS = 6
local VSI_MAX = 2000
--============================================================================

return function(t: TestKit.Context)
	t.test("wheels show the digits most significant first", function()
		local p = HudMath.wheelPositions(65, 0, WHEELS)
		t.expectEqual(#p, WHEELS)
		for index, digit in { 0, 0, 0, 0, 6, 5 } do
			t.expectNear(p[index], digit, EPSILON, `wheel {index}`)
		end
	end)

	t.test("the last wheel rolls with the fraction, the others stay put", function()
		local p = HudMath.wheelPositions(65, 0.25, WHEELS)
		t.expectNear(p[6], 5.25, EPSILON)
		t.expectNear(p[5], 6, EPSILON, "the tens wheel does not move while the units are not at 9")
	end)

	t.test("a higher wheel rolls only while the lower ones pass 9 -> 0", function()
		local p = HudMath.wheelPositions(69, 0.5, WHEELS)
		t.expectNear(p[6], 9.5, EPSILON)
		t.expectNear(p[5], 6.5, EPSILON)
		t.expectNear(p[4], 0, EPSILON)
		local q = HudMath.wheelPositions(999, 0.75, WHEELS)
		t.expectNear(q[6], 9.75, EPSILON)
		t.expectNear(q[5], 9.75, EPSILON)
		t.expectNear(q[4], 9.75, EPSILON)
		t.expectNear(q[3], 0.75, EPSILON, "the thousands wheel follows the carry")
		t.expectNear(q[2], 0, EPSILON)
		local r = HudMath.wheelPositions(1999, 0.1, WHEELS)
		t.expectNear(r[3], 1.1, EPSILON)
	end)

	t.test("negative values show their magnitude; too many digits show nines; NaN shows zero", function()
		local p = HudMath.wheelPositions(-42, 0, WHEELS)
		t.expectNear(p[5], 4, EPSILON)
		t.expectNear(p[6], 2, EPSILON)
		local big = HudMath.wheelPositions(12345678, 0.5, WHEELS)
		for index = 1, WHEELS do
			t.expectNear(big[index], 9, EPSILON, `wheel {index}`)
		end
		local nan = HudMath.wheelPositions(0 / 0, 0 / 0, WHEELS)
		for index = 1, WHEELS do
			t.expectEqual(nan[index], 0, `wheel {index}`)
		end
	end)

	t.test("every wheel stays inside the 0-9-0 strip", function()
		for _, value in { 0, 9.999, 99999.9999, 999999.99, 123456.5 } do
			local whole = math.floor(value)
			for _, position in HudMath.wheelPositions(whole, value - whole, WHEELS) do
				t.expectTrue(position >= 0 and position < 10, `{value}: {position}`)
			end
		end
	end)

	t.test("the vertical-speed needle is signed and log scaled", function()
		t.expectEqual(HudMath.verticalSpeedFraction(0, VSI_MAX), 0)
		t.expectNear(HudMath.verticalSpeedFraction(VSI_MAX, VSI_MAX), 1, EPSILON)
		t.expectNear(HudMath.verticalSpeedFraction(-VSI_MAX, VSI_MAX), -1, EPSILON)
		t.expectEqual(HudMath.verticalSpeedFraction(1e9, VSI_MAX), 1, "clamped")
		t.expectEqual(HudMath.verticalSpeedFraction(-math.huge, VSI_MAX), -1)
		t.expectEqual(HudMath.verticalSpeedFraction(0 / 0, VSI_MAX), 0)
		local small = HudMath.verticalSpeedFraction(10, VSI_MAX)
		t.expectTrue(small > 0.25 and small < 0.4, "10 m/s already moves the needle a third of the way")
		t.expectNear(HudMath.verticalSpeedFraction(-10, VSI_MAX), -small, EPSILON)
	end)

	t.test("throttle segments light up to the throttle", function()
		t.expectEqual(HudMath.litSegments(0, 20), 0)
		t.expectEqual(HudMath.litSegments(0.001, 20), 1, "any throttle lights the first segment")
		t.expectEqual(HudMath.litSegments(0.5, 20), 10)
		t.expectEqual(HudMath.litSegments(0.51, 20), 11)
		t.expectEqual(HudMath.litSegments(1, 20), 20)
		t.expectEqual(HudMath.litSegments(3, 20), 20)
		t.expectEqual(HudMath.litSegments(0 / 0, 20), 0)
	end)

	t.test("arc segments are spread evenly between the ends", function()
		t.expectNear(HudMath.arcAngle(1, 20, 100, 200), 102.5, EPSILON)
		t.expectNear(HudMath.arcAngle(20, 20, 100, 200), 197.5, EPSILON)
		local x, y = HudMath.arcPoint(180, 10)
		t.expectNear(x, -10, EPSILON)
		t.expectNear(y, 0, EPSILON)
		local x2, y2 = HudMath.arcPoint(90, 10)
		t.expectNear(x2, 0, EPSILON)
		t.expectNear(y2, 10, EPSILON, "90 degrees points down the screen")
	end)

	t.test("the speed mode switches to Orbit above the atmosphere", function()
		t.expectEqual(HudMath.isOrbitMode(1000, 70000, 600000), false)
		t.expectEqual(HudMath.isOrbitMode(80000, 70000, 600000), true)
		t.expectEqual(HudMath.isOrbitMode(5000, nil, 200000), false, "airless: 5% of the radius")
		t.expectEqual(HudMath.isOrbitMode(20000, nil, 200000), true)
	end)

	t.test("heading and pitch texts", function()
		t.expectEqual(HudMath.headingText(17.2), "017°")
		t.expectEqual(HudMath.headingText(359.7), "000°")
		t.expectEqual(HudMath.headingText(-90), "270°")
		t.expectEqual(HudMath.headingText(0 / 0), "000°")
		t.expectEqual(HudMath.pitchText(12.4), "+12°")
		t.expectEqual(HudMath.pitchText(-3.2), "-3°")
		t.expectEqual(HudMath.pitchText(0.2), "0°")
	end)
end
