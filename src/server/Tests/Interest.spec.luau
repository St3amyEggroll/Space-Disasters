--!strict
-- Tests for Shared/Net/Interest (Phase 3): interest tiers, budget allocation and send scheduling.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Interest = require(ReplicatedStorage.Shared.Net.Interest)

type Demand = Interest.Demand

local TICK = 1 / GameConfig.CRAFT_STATE_RATE

-- How many sends `rate` produces over `seconds` of relay ticks.
local function sendsOver(rate: number, seconds: number, credit: number): number
	local sends = 0
	local c = credit
	for _ = 1, math.floor(seconds / TICK + 0.5) do
		local send
		c, send = Interest.advance(c, rate, TICK)
		if send then
			sends += 1
		end
	end
	return sends
end

local function totalBytes(rates: { number }): number
	local total = 0
	for _, rate in rates do
		total += rate
	end
	return Interest.bytesPerSecond(total)
end

return function(t: TestKit.Context)
	t.test("tiers: pocket, within 50 km, same SOI, everything else", function()
		t.expectEqual(Interest.classify(true, false, 1e9), "Pocket")
		t.expectEqual(Interest.classify(false, true, 10), "Near")
		t.expectEqual(Interest.classify(false, false, GameConfig.INTEREST_NEAR), "Near") -- near even across an SOI
		t.expectEqual(Interest.classify(false, true, GameConfig.INTEREST_NEAR + 1), "Soi")
		t.expectEqual(Interest.classify(false, false, GameConfig.INTEREST_NEAR + 1), "Far")
		t.expectEqual(Interest.rateOf("Pocket"), 20)
		t.expectEqual(Interest.rateOf("Near"), 20)
		t.expectEqual(Interest.rateOf("Soi"), 2)
		t.expectEqual(Interest.rateOf("Far"), 0.5)
	end)

	t.test("12 players flying near each other fit the 20 KB/s budget", function()
		local demands: { Demand } = {}
		for i = 1, 11 do -- everyone else's craft, all within 50 km
			table.insert(demands, { tier = "Near", distance = i * 1000, debris = false })
		end
		local rates = Interest.allocate(demands, GameConfig.CRAFT_STATES_BUDGET)
		for _, rate in rates do
			t.expectEqual(rate, 20) -- no degradation needed
		end
		t.expectTrue(totalBytes(rates) <= GameConfig.NET_BUDGET_BYTES_PER_S, `{totalBytes(rates)} B/s`)
	end)

	t.test("over budget: pocket crafts keep 20 Hz, nearest crafts first, debris last", function()
		local demands: { Demand } = {
			{ tier = "Pocket", distance = 0, debris = false },
		}
		for i = 1, 9 do
			table.insert(demands, { tier = "Near", distance = i * 1000, debris = false })
		end
		for i = 1, 40 do -- MAX_DEBRIS pieces falling nearby
			table.insert(demands, { tier = "Near", distance = i * 10, debris = true })
		end
		table.insert(demands, { tier = "Far", distance = 1e6, debris = false })
		local budget = GameConfig.CRAFT_STATES_BUDGET
		local rates = Interest.allocate(demands, budget)
		t.expectNear(totalBytes(rates), budget, 1, "uses the budget exactly")
		t.expectEqual(rates[1], 20) -- own pocket
		for i = 2, 10 do
			t.expectEqual(rates[i], 20, "crafts before debris")
		end
		for i = 11, 50 do
			t.expectTrue(rates[i] >= Interest.RATE_FAR - 1e-9, "debris floor")
			t.expectTrue(rates[i] < 20, "debris degraded")
		end
		-- the spare rate goes to the nearest debris first
		t.expectTrue(rates[11] > rates[50])
		t.expectEqual(rates[51], Interest.RATE_FAR)
	end)

	t.test("over budget: a far demand never goes below the floor or above its wish", function()
		local demands: { Demand } = {}
		for i = 1, 60 do
			table.insert(demands, { tier = if i % 2 == 0 then "Soi" else "Near", distance = i, debris = false })
		end
		local rates = Interest.allocate(demands, 2000)
		for index, rate in rates do
			t.expectTrue(rate >= Interest.RATE_FAR - 1e-9, "floor")
			t.expectTrue(rate <= Interest.rateOf(demands[index].tier) + 1e-9, "never above the wish")
		end
	end)

	t.test("send credit produces the requested average rate", function()
		t.expectEqual(sendsOver(20, 10, 1), 200)
		t.expectEqual(sendsOver(2, 10, 0), 20)
		t.expectEqual(sendsOver(0.5, 10, 0), 5)
		t.expectNear(sendsOver(13.3, 30, 0), 399, 1) -- fractional rates are not rounded up to the tick rate
		t.expectEqual(sendsOver(0, 10, 1), 0)
	end)

	t.test("near crafts send on the first tick, slow ones are spread out", function()
		local _, send = Interest.advance(Interest.initialCredit(5, "Near"), 20, TICK)
		t.expectTrue(send)
		local first: { [number]: number } = {}
		for id = 1, 20 do
			local credit = Interest.initialCredit(id, "Far")
			t.expectTrue(credit >= 0.5 and credit < 1)
			first[id] = credit
		end
		local distinct = 0
		local seen: { [number]: boolean } = {}
		for _, credit in first do
			local key = math.floor(credit * 100)
			if not seen[key] then
				seen[key] = true
				distinct += 1
			end
		end
		t.expectTrue(distinct >= 10, "initial credits are spread")
	end)

	t.test("a hitch owes at most one extra send", function()
		local credit, send = Interest.advance(1, 20, 1) -- one second in a single tick
		t.expectTrue(send)
		local _, again = Interest.advance(credit, 20, 0)
		t.expectTrue(again)
		local _, third = Interest.advance(0, 20, 0)
		t.expectTrue(not third)
	end)
end
