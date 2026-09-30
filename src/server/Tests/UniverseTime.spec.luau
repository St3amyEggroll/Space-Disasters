--!strict
-- Tests for the pure parts of Shared/Sim/UniverseTime (anchor encoding and formatting).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)

return function(t: TestKit.Context)
	t.test("anchors round trip at full double precision", function()
		local original = { utAnchor = 123456789.123456789, serverTimeAnchor = 1727712345.987654321, warpRate = 25 }
		local decoded = UniverseTime.decode(UniverseTime.encode(original))
		t.expectTrue(decoded ~= nil, "decodes")
		if decoded then
			t.expectEqual(decoded.utAnchor, original.utAnchor)
			t.expectEqual(decoded.serverTimeAnchor, original.serverTimeAnchor)
			t.expectEqual(decoded.warpRate, original.warpRate)
		end
	end)

	t.test("malformed anchors are rejected", function()
		t.expectTrue(UniverseTime.decode("") == nil)
		t.expectTrue(UniverseTime.decode("1|2") == nil)
		t.expectTrue(UniverseTime.decode("a|b|c") == nil)
	end)

	t.test("format", function()
		t.expectEqual(UniverseTime.format(0), "T+ 00:00:00.0")
		t.expectEqual(UniverseTime.format(3723.5), "T+ 01:02:03.5")
		t.expectEqual(UniverseTime.format(90061), "T+ 1d 01:01:01.0")
		t.expectEqual(UniverseTime.format(-5), "T- 00:00:05.0")
	end)
end
