--!strict
-- Tests for UI/KitMath (Phase 11): slider snapping without float noise, value <-> track fraction, the Kit screen
-- scale (design canvas fit times the player's UI size) and toast durations.

local TestKit = require(script.Parent.TestKit)
local KitMath = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.UI.KitMath)

--============================================================================
-- Tunables
--============================================================================
local EPSILON = 1e-12
local DESIGN_WIDTH = 1366
local DESIGN_HEIGHT = 710
local MIN_FIT = 0.6
local MAX_FIT = 1.6
--============================================================================

return function(t: TestKit.Context)
	t.test("clamp01 clamps and maps NaN to 0", function()
		t.expectEqual(KitMath.clamp01(-1), 0)
		t.expectEqual(KitMath.clamp01(0.25), 0.25)
		t.expectEqual(KitMath.clamp01(4), 1)
		t.expectEqual(KitMath.clamp01(0 / 0), 0)
	end)

	t.test("snap rounds to the step and clamps", function()
		t.expectEqual(KitMath.snap(0.33, 0, 1, 0.05), 0.35)
		t.expectEqual(KitMath.snap(0.32, 0, 1, 0.05), 0.3)
		t.expectEqual(KitMath.snap(-3, 0, 1, 0.05), 0)
		t.expectEqual(KitMath.snap(9, 0, 1, 0.05), 1)
		t.expectEqual(KitMath.snap(0 / 0, 0.2, 3, 0.05), 0.2)
		t.expectEqual(KitMath.snap(0.123, 0, 1, 0), 0.123, "step 0 does not round")
	end)

	t.test("snap leaves no float noise", function()
		t.expectEqual(KitMath.snap(0.1 + 0.2, 0, 1, 0.1), 0.3)
		t.expectEqual(KitMath.snap(0.7 + 0.05 * 7, 0.7, 1.4, 0.05), 1.05)
		for k = 0, 56 do
			local value = KitMath.snap(0.2 + k * 0.05, 0.2, 3, 0.05)
			t.expectEqual(value, tonumber(string.format("%.2f", value)), `step {k}`)
		end
	end)

	t.test("snap counts steps from min", function()
		t.expectEqual(KitMath.snap(0.74, 0.7, 1.4, 0.05), 0.75)
		t.expectEqual(KitMath.snap(1.4, 0.7, 1.4, 0.05), 1.4)
	end)

	t.test("fraction and fromFraction round-trip", function()
		t.expectNear(KitMath.fraction(1.6, 0.2, 3), 0.5, EPSILON)
		t.expectEqual(KitMath.fraction(5, 0, 1), 1)
		t.expectEqual(KitMath.fraction(5, 1, 1), 0, "empty range")
		t.expectEqual(KitMath.fromFraction(0.5, 0.2, 3, 0.05), 1.6)
		t.expectEqual(KitMath.fromFraction(-1, 0.2, 3, 0.05), 0.2)
		t.expectEqual(KitMath.fromFraction(2, 0.2, 3, 0.05), 3)
		for k = 0, 20 do
			local value = KitMath.snap(k * 0.05, 0, 1, 0.05)
			t.expectEqual(KitMath.fromFraction(KitMath.fraction(value, 0, 1), 0, 1, 0.05), value, `value {value}`)
		end
	end)

	t.test("screenScale fits the design canvas and applies the UI size", function()
		local function scale(width: number, height: number, user: number): number
			return KitMath.screenScale(width, height, user, DESIGN_WIDTH, DESIGN_HEIGHT, MIN_FIT, MAX_FIT)
		end
		t.expectNear(scale(1366, 710, 1), 1, EPSILON)
		t.expectNear(scale(1920, 1080, 1), 1920 / 1366, EPSILON, "1080p: width limits")
		t.expectNear(scale(2732, 710, 1), 1, EPSILON, "ultra wide: height limits")
		t.expectNear(scale(400, 300, 1), MIN_FIT, EPSILON, "tiny screens clamp")
		t.expectNear(scale(8000, 6000, 1), MAX_FIT, EPSILON, "huge screens clamp")
		t.expectNear(scale(1366, 710, 1.4), 1.4, EPSILON)
		t.expectNear(scale(1366, 710, 0.7), 0.7, EPSILON)
		t.expectNear(scale(0, 0, 1.2), 1.2, EPSILON, "not laid out yet: fit 1")
		t.expectNear(scale(1366, 710, 0 / 0), 1, EPSILON, "bad UI size falls back to 1")
		t.expectNear(scale(1366, 710, -2), 1, EPSILON)
	end)

	t.test("toastSeconds grows with the text and is capped", function()
		t.expectNear(KitMath.toastSeconds("", 2, 0.05, 6), 2, EPSILON)
		t.expectNear(KitMath.toastSeconds("abcdefghij", 2, 0.05, 6), 2.5, EPSILON)
		t.expectNear(KitMath.toastSeconds(string.rep("x", 1000), 2, 0.05, 6), 6, EPSILON)
	end)
end
