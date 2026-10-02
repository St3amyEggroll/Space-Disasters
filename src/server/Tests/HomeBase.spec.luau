--!strict
-- CHANGED (Physics feel): tests for Shared/Sites/HomeBase: the part budget, and the taller launch towers stay
-- clear of every pad footprint (rockets up to the full build footprint are centred on their pad at roll-out).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HomeBase = require(ReplicatedStorage.Shared.Sites.HomeBase)

--============================================================================
-- Tunables
--============================================================================
local MIN_TOWER_HEIGHT = 80 -- studs, top of the tallest tower part
local MIN_BEACONS = 3 -- per tower
--============================================================================

-- Axis-aligned bounds of an unrotated (or ball) part.
local function partBounds(p: BasePart): (Vector3, Vector3)
	local half = p.Size / 2
	local centre = p.CFrame.Position -- Lune's DOM has no derived Position property
	return centre - half, centre + half
end

return function(t: TestKit.Context)
	local model = HomeBase.build()

	t.test("home base stays within its part budget", function()
		local count = model:GetAttribute("PartCount")
		t.expectTrue(type(count) == "number", "PartCount attribute")
		t.expectTrue((count :: number) <= GameConfig.HOME_BASE_MAX_PARTS, `{count} parts`)
	end)

	t.test("launch towers are tall, lit and clear of every pad footprint", function()
		local towers = 0
		for _, d in model:GetDescendants() do
			if not (d:IsA("Model") and d.Name == "LaunchTower") then
				continue
			end
			towers += 1
			local top = -math.huge
			local beacons = 0
			for _, p in d:GetDescendants() do
				if not p:IsA("BasePart") then
					continue
				end
				local lo, hi = partBounds(p)
				top = math.max(top, hi.Y)
				if p.Name == "TowerBeacon" then
					beacons += 1
				end
				for _, pad in BaseLayout.Pads do
					local c = pad.top.Position
					local half = pad.size / 2
					local overlaps = lo.X < c.X + half and hi.X > c.X - half and lo.Z < c.Z + half and hi.Z > c.Z - half
					t.expectTrue(not overlaps, `{p.Name} overlaps pad {pad.index}`)
				end
			end
			t.expectTrue(top >= MIN_TOWER_HEIGHT, `tower top {top}`)
			t.expectTrue(beacons >= MIN_BEACONS, `{beacons} beacons`)
		end
		t.expectEqual(towers, BaseLayout.PAD_COUNT, "one tower per pad")
	end)
end
