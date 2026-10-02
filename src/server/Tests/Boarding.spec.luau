--!strict
-- CHANGED (Boarding): tests for Shared/Craft/Boarding, the rules for boarding a craft in another pocket from the base
-- (request validation, speed and range limits, which copies get prompts, the rate limit).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Boarding = require(ReplicatedStorage.Shared.Craft.Boarding)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local BASE = 0
local FLIGHT_POCKET = 7
local RADIUS = 6 -- m, a small rocket
--============================================================================

return function(t: TestKit.Context)
	t.test("ids from the network must be positive integers", function()
		t.expectEqual(Boarding.validId(1), 1)
		t.expectEqual(Boarding.validId(42), 42)
		t.expectEqual(Boarding.validId(0), nil, "zero")
		t.expectEqual(Boarding.validId(-3), nil, "negative")
		t.expectEqual(Boarding.validId(1.5), nil, "fraction")
		t.expectEqual(Boarding.validId(0 / 0), nil, "NaN")
		t.expectEqual(Boarding.validId(math.huge), nil, "infinity")
		t.expectEqual(Boarding.validId(2 ^ 40), nil, "absurdly large")
		t.expectEqual(Boarding.validId("3"), nil, "string")
		t.expectEqual(Boarding.validId(nil), nil, "nil")
		t.expectEqual(Boarding.validId({ 1 }), nil, "table")
	end)

	t.test("only crafts in flight can be boarded across pockets", function()
		t.expectTrue(Boarding.boardableState("Flying"))
		t.expectTrue(Boarding.boardableState("Landed"))
		t.expectTrue(Boarding.boardableState("OnRails"))
		t.expectTrue(not Boarding.boardableState("Prelaunch"), "pad crafts use their real SitPrompts")
		t.expectTrue(not Boarding.boardableState("Destroyed"))
		t.expectTrue(not Boarding.boardableState("Launching"))
	end)

	t.test("the speed limit is strict and rejects nonsense", function()
		t.expectTrue(Boarding.slowEnough(0))
		t.expectTrue(Boarding.slowEnough(GameConfig.BOARD_MAX_SPEED - 0.01))
		t.expectTrue(not Boarding.slowEnough(GameConfig.BOARD_MAX_SPEED), "at the limit")
		t.expectTrue(not Boarding.slowEnough(GameConfig.BOARD_MAX_SPEED + 1))
		t.expectTrue(not Boarding.slowEnough(0 / 0), "NaN")
		t.expectTrue(not Boarding.slowEnough(-1), "negative")
	end)

	t.test("range is the craft radius plus BOARD_RANGE", function()
		local limit = RADIUS + GameConfig.BOARD_RANGE
		t.expectTrue(Boarding.inRange(0, RADIUS))
		t.expectTrue(Boarding.inRange(limit, RADIUS), "exactly at the limit")
		t.expectTrue(not Boarding.inRange(limit + 0.01, RADIUS))
		t.expectTrue(Boarding.inRange(GameConfig.BOARD_RANGE, -5), "a negative radius counts as zero")
		t.expectTrue(Boarding.inRange(GameConfig.BOARD_RANGE, 0 / 0), "a NaN radius counts as zero")
		t.expectTrue(not Boarding.inRange(0 / 0, RADIUS), "NaN distance")
		t.expectTrue(not Boarding.inRange(math.huge, RADIUS))
	end)

	t.test("prompts only for slow crafts in another pocket, seen from the base", function()
		t.expectTrue(Boarding.offersPrompts(BASE, FLIGHT_POCKET, false, false, 0))
		t.expectTrue(not Boarding.offersPrompts(FLIGHT_POCKET, 3, false, false, 0), "player not in the base")
		-- CHANGED (Night review): a flying craft announced in pocket 0 has no real model (its pocket was released,
		-- e.g. landed near the base after its crew went home): it can be boarded, the server builds the model
		t.expectTrue(Boarding.offersPrompts(BASE, BASE, false, false, 0), "uncrewed craft without a real model")
		t.expectTrue(Boarding.withoutRealModel(BASE), "pocket 0: no real model")
		t.expectTrue(not Boarding.withoutRealModel(FLIGHT_POCKET), "a flight pocket holds its real model")
		t.expectTrue(not Boarding.offersPrompts(BASE, BASE, true, false, 0), "pad craft in the base pocket")
		t.expectTrue(not Boarding.offersPrompts(BASE, FLIGHT_POCKET, true, false, 0), "pad craft (real model shown)")
		t.expectTrue(not Boarding.offersPrompts(BASE, FLIGHT_POCKET, false, true, 0), "debris")
		t.expectTrue(
			not Boarding.offersPrompts(BASE, FLIGHT_POCKET, false, false, GameConfig.BOARD_MAX_SPEED + 1),
			"too fast"
		)
	end)

	t.test("private crafts of other players get no prompts", function()
		t.expectTrue(Boarding.modeMayAllow("Public", 1, 2))
		t.expectTrue(Boarding.modeMayAllow("Friends", 1, 2), "the server checks friendship")
		t.expectTrue(Boarding.modeMayAllow(nil, 1, 2), "unknown mode: leave it to the server")
		t.expectTrue(not Boarding.modeMayAllow("Private", 1, 2))
		t.expectTrue(Boarding.modeMayAllow("Private", 1, 1), "the owner may always board")
	end)

	t.test("the rate limit lets one request through per cooldown", function()
		t.expectTrue(Boarding.cooldownOver(nil, 10, 1), "first request")
		t.expectTrue(not Boarding.cooldownOver(10, 10.5, 1))
		t.expectTrue(Boarding.cooldownOver(10, 11, 1))
	end)
end
