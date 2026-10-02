--!strict
-- CHANGED (Phase 6): tests for Shared/Sim/Bubbles, the server's bubble merge / split decisions (spec 7.5): astronauts
-- splitting off into solo pockets and joining others, craft pockets merging, uncrewed crafts becoming real secondary
-- crafts, primaries being replaced, hysteresis and one action per thing per check.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Bubbles = require(ReplicatedStorage.Shared.Sim.Bubbles)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

--============================================================================
-- Tunables
--============================================================================
local EARTH = 1
local MUN = 2
local MERGE = GameConfig.BUBBLE_MERGE_DIST
local SPLIT = GameConfig.BUBBLE_SPLIT_DIST
local ORIGIN = Vec3d.new(75000, 0, 0) -- somewhere in Earth orbit (absolute positions)
--============================================================================

type Snapshot = Bubbles.Snapshot

-- A point `dx` m along +Y from ORIGIN.
local function at(dx: number): Vec3d.Vec3d
	return Vec3d.add(ORIGIN, Vec3d.new(0, dx, 0))
end

local function craftPocket(id: number, craftId: number, anchor: number, players: number, order: number?): Bubbles.Pocket
	return {
		id = id,
		kind = "Craft",
		primaryCraftId = craftId,
		primaryUserId = nil,
		bodyId = EARTH,
		anchor = at(anchor),
		order = order or id,
		players = players,
	}
end

local function soloPocket(id: number, userId: number, anchor: number, players: number?): Bubbles.Pocket
	return {
		id = id,
		kind = "Solo",
		primaryCraftId = nil,
		primaryUserId = userId,
		bodyId = EARTH,
		anchor = at(anchor),
		order = id,
		players = players or 1,
	}
end

local function craft(id: number, pocketId: number?, x: number, crew: number?, boardable: boolean?): Bubbles.Craft
	return {
		id = id,
		pocketId = pocketId,
		bodyId = EARTH,
		pos = at(x),
		crew = crew or 0,
		boardable = if boardable == nil then true else boardable,
	}
end

local function astronaut(userId: number, pocketId: number, x: number, settled: boolean?): Bubbles.Astronaut
	return {
		userId = userId,
		pocketId = pocketId,
		bodyId = EARTH,
		pos = at(x),
		settled = if settled == nil then true else settled,
		nearBase = false,
	}
end

local function describe(actions: { Bubbles.Action }): string
	local parts = {}
	for _, action in actions do
		table.insert(
			parts,
			string.format(
				"%s(p=%s from=%s into=%s craft=%s user=%s)",
				action.kind,
				tostring(action.pocketId),
				tostring(action.fromId),
				tostring(action.intoId),
				tostring(action.craftId),
				tostring(action.userId)
			)
		)
	end
	return if #parts == 0 then "none" else table.concat(parts, ", ")
end

return function(t: TestKit.Context)
	local function expectActions(snapshot: Snapshot, expected: { Bubbles.Action }, message: string)
		local actions = Bubbles.decide(snapshot)
		local ok = #actions == #expected
		if ok then
			for i, want in expected do
				local got = actions[i]
				for key, value in want :: any do
					if (got :: any)[key] ~= value then
						ok = false
					end
				end
			end
		end
		t.expectTrue(ok, `{message}: got {describe(actions)}, wanted {describe(expected)}`)
	end

	t.test("an astronaut floating beside his craft stays in its pocket", function()
		expectActions({
			pockets = { craftPocket(1, 10, 0, 2) },
			crafts = { craft(10, 1, 0, 1) },
			astronauts = { astronaut(100, 1, 120) },
		}, {}, "120 m out")
		expectActions({
			pockets = { craftPocket(1, 10, 0, 2) },
			crafts = { craft(10, 1, 0, 1) },
			astronauts = { astronaut(100, 1, SPLIT - 1) },
		}, {}, "just inside the split distance (hysteresis)")
	end)

	t.test("beyond BUBBLE_SPLIT_DIST he gets his own solo pocket", function()
		expectActions({
			pockets = { craftPocket(1, 10, 0, 2) },
			crafts = { craft(10, 1, 0, 1) },
			astronauts = { astronaut(100, 1, SPLIT + 1) },
		}, { { kind = "NewSolo", userId = 100 } }, "401 m out")
	end)

	t.test("leaving one craft near another: he joins that craft's pocket instead", function()
		expectActions({
			pockets = { craftPocket(1, 10, 0, 1), craftPocket(2, 20, 600, 1) },
			crafts = { craft(10, 1, 0, 1), craft(20, 2, 600, 1) },
			astronauts = { astronaut(100, 1, 420) },
		}, { { kind = "Join", userId = 100, pocketId = 2 } }, "180 m from the other craft")
	end)

	t.test("between two crafts he changes pocket only when the other is much closer (no flip-flop)", function()
		local pockets = { craftPocket(1, 10, 0, 1), craftPocket(2, 20, 300, 1) }
		local crafts = { craft(10, 1, 0, 1), craft(20, 2, 300, 1) }
		expectActions(
			{ pockets = pockets, crafts = crafts, astronauts = { astronaut(100, 1, 260) } },
			{ { kind = "Join", userId = 100, pocketId = 2 } },
			"40 m from the other craft, 260 m from his own"
		)
		expectActions(
			{ pockets = pockets, crafts = crafts, astronauts = { astronaut(100, 1, 170) } },
			{},
			"170 / 130 m: not enough closer"
		)
		expectActions(
			{ pockets = pockets, crafts = crafts, astronauts = { astronaut(100, 2, 260) } },
			{},
			"after the change he stays"
		)
	end)

	t.test("a lone astronaut reaching a craft merges his pocket into the craft's", function()
		expectActions({
			pockets = { craftPocket(1, 10, 0, 1), soloPocket(5, 100, 200) },
			crafts = { craft(10, 1, 0, 1) },
			astronauts = { astronaut(100, 5, 200) },
		}, { { kind = "Merge", fromId = 5, intoId = 1 } }, "200 m from the craft")
		expectActions({
			pockets = { craftPocket(1, 10, 0, 1), soloPocket(5, 100, 300) },
			crafts = { craft(10, 1, 0, 1) },
			astronauts = { astronaut(100, 5, 300) },
		}, {}, "300 m: not yet (merge distance)")
	end)

	t.test("two lone astronauts: the newer pocket merges into the older, once", function()
		expectActions({
			pockets = { soloPocket(3, 100, 0), soloPocket(4, 200, 100) },
			crafts = {},
			astronauts = { astronaut(100, 3, 0), astronaut(200, 4, 100) },
		}, { { kind = "Merge", fromId = 4, intoId = 3 } }, "100 m apart")
	end)

	t.test("craft pockets within BUBBLE_MERGE_DIST merge: fewer players into more, ties keep the older", function()
		expectActions({
			pockets = { craftPocket(1, 10, 0, 1), craftPocket(2, 20, 200, 3) },
			crafts = { craft(10, 1, 0, 1), craft(20, 2, 200, 3) },
			astronauts = {},
		}, { { kind = "Merge", fromId = 1, intoId = 2 } }, "more players stay")
		expectActions({
			pockets = { craftPocket(1, 10, 0, 2, 9), craftPocket(2, 20, 200, 2, 4) },
			crafts = { craft(10, 1, 0, 2), craft(20, 2, 200, 2) },
			astronauts = {},
		}, { { kind = "Merge", fromId = 1, intoId = 2 } }, "tie: the older (order 4) stays")
		expectActions({
			pockets = { craftPocket(1, 10, 0, 1), craftPocket(2, 20, MERGE + 10, 1) },
			crafts = { craft(10, 1, 0, 1), craft(20, 2, MERGE + 10, 1) },
			astronauts = {},
		}, {}, "just beyond the merge distance")
		local munPocket = craftPocket(2, 20, 100, 1)
		munPocket.bodyId = MUN
		local munCraft = craft(20, 2, 100, 1)
		munCraft.bodyId = MUN
		expectActions({
			pockets = { craftPocket(1, 10, 0, 1), munPocket },
			crafts = { craft(10, 1, 0, 1), munCraft },
			astronauts = {},
		}, {}, "another SOI never merges")
	end)

	t.test("three pockets in a row: the nearest pair merges first, each pocket once per check", function()
		expectActions({
			pockets = { craftPocket(1, 10, 0, 1), craftPocket(2, 20, 100, 1), craftPocket(3, 30, 150, 1) },
			crafts = { craft(10, 1, 0, 1), craft(20, 2, 100, 1), craft(30, 3, 150, 1) },
			astronauts = {},
		}, { { kind = "Merge", fromId = 3, intoId = 2 } }, "50 m pair first; pocket 1 waits")
	end)

	t.test("an uncrewed boardable craft near an astronaut becomes a real secondary craft", function()
		expectActions({
			pockets = { soloPocket(5, 100, 0) },
			crafts = { craft(30, nil, 120, 0, true) },
			astronauts = { astronaut(100, 5, 0) },
		}, { { kind = "AddCraft", craftId = 30, pocketId = 5 } }, "120 m away")
		expectActions({
			pockets = { soloPocket(5, 100, 0) },
			crafts = { craft(30, nil, 120, 0, false) },
			astronauts = { astronaut(100, 5, 0) },
		}, {}, "debris never")
		expectActions({
			pockets = { soloPocket(5, 100, 0) },
			crafts = { craft(30, nil, MERGE + 5, 0, true) },
			astronauts = { astronaut(100, 5, 0) },
		}, {}, "too far")
		expectActions({
			pockets = { craftPocket(1, 10, 0, 0) },
			crafts = { craft(10, 1, 0, 0), craft(30, nil, 50, 0, true) },
			astronauts = {},
		}, {}, "only occupied pockets take crafts in")
	end)

	t.test(
		"secondary crafts: uncrewed ones drop out far from everyone, crewed ones split into their own pocket",
		function()
			expectActions({
				pockets = { craftPocket(1, 10, 0, 1) },
				crafts = { craft(10, 1, 0, 1), craft(30, 1, SPLIT + 50, 0) },
				astronauts = {},
			}, { { kind = "DropCraft", craftId = 30 } }, "uncrewed, far")
			expectActions({
				pockets = { craftPocket(1, 10, 0, 2) },
				crafts = { craft(10, 1, 0, 1), craft(30, 1, SPLIT + 50, 0) },
				astronauts = { astronaut(100, 1, SPLIT - 20) },
			}, {}, "an astronaut beside it keeps it real")
			expectActions({
				pockets = { craftPocket(1, 10, 0, 2) },
				crafts = { craft(10, 1, 0, 1), craft(30, 1, SPLIT + 50, 1) },
				astronauts = {},
			}, { { kind = "SplitCraft", craftId = 30 } }, "crewed, far")
			expectActions({
				pockets = { craftPocket(1, 10, 0, 2) },
				crafts = { craft(10, 1, 0, 1), craft(30, 1, SPLIT - 50, 1) },
				astronauts = {},
			}, {}, "crewed, near")
		end
	)

	t.test("primaries: a lost primary is replaced, a crewed craft beats an empty one", function()
		expectActions({
			pockets = { craftPocket(1, 10, 0, 2) },
			crafts = { craft(20, 1, 50, 1), craft(30, 1, 80, 2) },
			astronauts = {},
		}, { { kind = "Repoint", pocketId = 1, craftId = 30 } }, "most crew")
		local lost = craftPocket(1, 10, 0, 1)
		lost.anchor = nil
		expectActions({
			pockets = { lost },
			crafts = {},
			astronauts = { astronaut(100, 1, 30) },
		}, { { kind = "Repoint", pocketId = 1, userId = 100 } }, "no craft left: the astronaut")
		expectActions({
			pockets = { craftPocket(1, 10, 0, 2) },
			crafts = { craft(10, 1, 0, 0), craft(30, 1, 40, 1) },
			astronauts = {},
		}, { { kind = "Repoint", pocketId = 1, craftId = 30 } }, "the crewed craft becomes primary")
		expectActions({
			pockets = { soloPocket(5, 100, 0) },
			crafts = { craft(30, 5, 0, 1) },
			astronauts = {},
		}, { { kind = "Repoint", pocketId = 5, craftId = 30 } }, "the astronaut boarded the craft")
	end)

	t.test("near the launch site an astronaut joins the base pocket; fresh transfers wait", function()
		local near = astronaut(100, 1, 50)
		near.nearBase = true
		expectActions({
			pockets = { craftPocket(1, 10, 0, 1) },
			crafts = { craft(10, 1, 0, 0) },
			astronauts = { near },
		}, { { kind = "ToBase", userId = 100 } }, "near base")
		expectActions({
			pockets = { craftPocket(1, 10, 0, 1) },
			crafts = { craft(10, 1, 0, 1) },
			astronauts = { astronaut(100, 1, SPLIT + 100, false) },
		}, {}, "not settled yet")
	end)

	t.test("a just-transferred astronaut counts as present but his position is not trusted yet", function()
		expectActions({
			pockets = { soloPocket(5, 100, 0) },
			crafts = { craft(30, 5, 0, 0) },
			astronauts = { astronaut(100, 5, 0, false) },
		}, {}, "his solo pocket is not re-pointed while he settles")
		-- CHANGED (Night review): was "an unsettled astronaut keeps no craft" (DropCraft). His position is unknown
		-- while he settles and he may be right beside the craft (just joined, or pinned by a repoint / rebase), so
		-- an uncrewed secondary craft of his pocket is kept until he settles
		expectActions({
			pockets = { craftPocket(1, 10, 0, 2) },
			crafts = { craft(10, 1, 0, 1), craft(30, 1, SPLIT + 50, 0) },
			astronauts = { astronaut(100, 1, 0, false) },
		}, {}, "an unsettled astronaut keeps the pocket's crafts until he settles")
		expectActions({
			pockets = { craftPocket(1, 10, 0, 2), craftPocket(2, 20, 5 * SPLIT, 1) },
			crafts = { craft(10, 1, 0, 1), craft(30, 1, SPLIT + 50, 0), craft(20, 2, 5 * SPLIT, 1) },
			astronauts = { astronaut(100, 2, 5 * SPLIT, false) },
		}, { { kind = "DropCraft", craftId = 30 } }, "one unsettled in ANOTHER pocket keeps nothing here")
		expectActions({
			pockets = { soloPocket(5, 100, 0) },
			crafts = { craft(30, nil, 100, 0, true) },
			astronauts = { astronaut(100, 5, 100, false) },
		}, { { kind = "AddCraft", craftId = 30, pocketId = 5 } }, "the pocket anchor still pulls a craft in")
	end)

	t.test("near the launch site nothing merges and no craft is pulled in", function()
		local a = craftPocket(1, 10, 0, 1)
		local b = craftPocket(2, 20, 50, 1)
		a.nearBase = true
		b.nearBase = true
		expectActions({
			pockets = { a, b },
			crafts = { craft(10, 1, 0, 1), craft(20, 2, 50, 1) },
			astronauts = {},
		}, {}, "two rockets on neighbouring pads")
		local parked = craft(30, nil, 40, 0, true)
		parked.nearBase = true
		expectActions({
			pockets = { soloPocket(5, 100, 0) },
			crafts = { parked },
			astronauts = { astronaut(100, 5, 0) },
		}, {}, "a craft parked at the base stays a copy")
	end)

	t.test("one action per pocket: a merging pocket's astronauts wait for the next check", function()
		expectActions({
			pockets = { craftPocket(1, 10, 0, 2), craftPocket(2, 20, 100, 1) },
			crafts = { craft(10, 1, 0, 1), craft(20, 2, 100, 1) },
			astronauts = { astronaut(100, 1, SPLIT + 100) },
		}, { { kind = "Merge", fromId = 2, intoId = 1 } }, "merge only")
	end)

	t.test("decisions do not depend on the order of the input lists", function()
		local pockets = { craftPocket(1, 10, 0, 1), craftPocket(2, 20, 600, 1), soloPocket(7, 300, 1000) }
		local crafts = { craft(10, 1, 0, 1), craft(20, 2, 600, 1), craft(40, nil, 1100, 0, true) }
		local astronauts = { astronaut(100, 1, 450), astronaut(300, 7, 1000) }
		local a = Bubbles.decide({ pockets = pockets, crafts = crafts, astronauts = astronauts })
		local function reversed<T>(list: { T }): { T }
			local out = {}
			for i = #list, 1, -1 do
				table.insert(out, list[i])
			end
			return out
		end
		local b = Bubbles.decide({
			pockets = reversed(pockets),
			crafts = reversed(crafts),
			astronauts = reversed(astronauts),
		})
		t.expectEqual(describe(a), describe(b))
		t.expectTrue(#a >= 2, `join + add: {describe(a)}`)
	end)
end
