--!strict
-- Tests for Shared/Util/UnitFormat (Phase 11): KSP-style distances, speeds, odometer parts, durations, masses.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local UnitFormat = require(ReplicatedStorage.Shared.Util.UnitFormat)

return function(t: TestKit.Context)
	t.test("metric distances", function()
		local cases: { { number | string } } = {
			{ 0, "0.0 m" },
			{ 5.26, "5.3 m" },
			{ 12, "12 m" },
			{ 950, "950 m" },
			{ 999.4, "999 m" },
			{ 999.6, "1.00 km" },
			{ 1250, "1.25 km" },
			{ 12400, "12.4 km" },
			{ 245000, "245 km" },
			{ 1250000, "1.25 Mm" },
			{ 2e12, "2,000 Gm" },
			{ -12400, "-12.4 km" },
			{ -0.01, "0.0 m" },
		}
		for _, case in cases do
			t.expectEqual(UnitFormat.distance(case[1] :: number, "Metric"), case[2], tostring(case[1]))
		end
	end)

	t.test("imperial distances", function()
		t.expectEqual(UnitFormat.distance(950, "Imperial"), "3,117 ft")
		t.expectEqual(UnitFormat.distance(1500, "Imperial"), "4,921 ft")
		t.expectEqual(UnitFormat.distance(1609.344, "Imperial"), "1.00 mi")
		t.expectEqual(UnitFormat.distance(12392, "Imperial"), "7.70 mi")
		t.expectEqual(UnitFormat.distance(2e7, "Imperial"), "12,427 mi")
		t.expectEqual(UnitFormat.distance(1, "Imperial"), "3.3 ft")
	end)

	t.test("speeds keep one decimal", function()
		t.expectEqual(UnitFormat.speed(123.4, "Metric"), "123.4 m/s")
		t.expectEqual(UnitFormat.speed(123.4, "Imperial"), "404.9 ft/s")
		t.expectEqual(UnitFormat.speed(2345.67, "Metric"), "2,345.7 m/s")
		t.expectEqual(UnitFormat.speed(0, "Metric"), "0.0 m/s")
		t.expectEqual(UnitFormat.speed(-3.21, "Metric"), "-3.2 m/s")
		t.expectEqual(UnitFormat.speed(-0.01, "Metric"), "0.0 m/s", "no negative zero")
	end)

	t.test("odometer parts", function()
		local whole, unit, fraction = UnitFormat.altitudeParts(65.75, "Metric")
		t.expectEqual(whole, 65)
		t.expectEqual(unit, "m")
		t.expectNear(fraction, 0.75, 1e-9)
		whole, unit = UnitFormat.altitudeParts(999999.5, "Metric")
		t.expectEqual(whole, 999999)
		t.expectEqual(unit, "m")
		whole, unit, fraction = UnitFormat.altitudeParts(1000000, "Metric")
		t.expectEqual(whole, 1000)
		t.expectEqual(unit, "km")
		t.expectNear(fraction, 0, 1e-9)
		whole, unit, fraction = UnitFormat.altitudeParts(12345678, "Metric")
		t.expectEqual(whole, 12345)
		t.expectEqual(unit, "km")
		t.expectNear(fraction, 0.678, 1e-6)
		whole, unit = UnitFormat.altitudeParts(2e15, "Metric")
		t.expectEqual(whole, 2000000)
		t.expectEqual(unit, "Gm", "the last unit takes everything above")
		whole, unit, fraction = UnitFormat.altitudeParts(65, "Imperial")
		t.expectEqual(whole, 213)
		t.expectEqual(unit, "ft")
		t.expectNear(fraction, 65 / 0.3048 - 213, 1e-9)
		whole, unit = UnitFormat.altitudeParts(400000, "Imperial")
		t.expectEqual(whole, 248)
		t.expectEqual(unit, "mi")
		whole, unit, fraction = UnitFormat.altitudeParts(-12.5, "Metric")
		t.expectEqual(whole, -12)
		t.expectEqual(unit, "m")
		t.expectNear(fraction, 0.5, 1e-9)
		whole = UnitFormat.altitudeParts(-0.4, "Metric")
		t.expectEqual(whole, 0)
		t.expectEqual(1 / whole, math.huge, "no negative zero")
		whole, unit, fraction = UnitFormat.altitudeParts(0 / 0, "Metric")
		t.expectEqual(whole, 0)
		t.expectEqual(unit, "m")
		t.expectEqual(fraction, 0)
	end)

	t.test("durations", function()
		t.expectEqual(UnitFormat.duration(0), "0s")
		t.expectEqual(UnitFormat.duration(12), "12s")
		t.expectEqual(UnitFormat.duration(12.9), "12s")
		t.expectEqual(UnitFormat.duration(245), "4m 05s")
		t.expectEqual(UnitFormat.duration(3725), "1h 02m 05s")
		t.expectEqual(UnitFormat.duration(90061), "1d 01h 01m")
		t.expectEqual(UnitFormat.duration(-65), "-1m 05s")
		t.expectEqual(UnitFormat.duration(1e300), "99999d 23h 59m", "clamped")
	end)

	t.test("masses", function()
		t.expectEqual(UnitFormat.mass(850, "Metric"), "0.85 t")
		t.expectEqual(UnitFormat.mass(4150, "Metric"), "4.15 t")
		t.expectEqual(UnitFormat.mass(12400, "Metric"), "12.4 t")
		t.expectEqual(UnitFormat.mass(1250000, "Metric"), "1,250 t")
		t.expectEqual(UnitFormat.mass(4150, "Imperial"), "9,149 lb")
	end)

	t.test("percent and thousands", function()
		t.expectEqual(UnitFormat.percent(0.456), "46%")
		t.expectEqual(UnitFormat.percent(1), "100%")
		t.expectEqual(UnitFormat.percent(0), "0%")
		t.expectEqual(UnitFormat.thousands(1234567), "1,234,567")
		t.expectEqual(UnitFormat.thousands(-1234.6), "-1,235")
		t.expectEqual(UnitFormat.thousands(999), "999")
	end)

	t.test("non-finite input", function()
		for _, value in { 0 / 0, math.huge, -math.huge } do
			t.expectEqual(UnitFormat.distance(value, "Metric"), UnitFormat.NOT_AVAILABLE)
			t.expectEqual(UnitFormat.speed(value, "Imperial"), UnitFormat.NOT_AVAILABLE)
			t.expectEqual(UnitFormat.mass(value, "Metric"), UnitFormat.NOT_AVAILABLE)
			t.expectEqual(UnitFormat.percent(value), UnitFormat.NOT_AVAILABLE)
			t.expectEqual(UnitFormat.duration(value), UnitFormat.NOT_AVAILABLE)
		end
	end)
end
