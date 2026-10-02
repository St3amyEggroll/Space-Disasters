--!strict
-- Tests for UI/BuildInfo (Phase 11): the builder UI's pure text and layout rules (part info lines, staging chips and
-- TWR text, KSP staging order, warning lines, save names and slot labels, toolbar fit scale).

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TestKit = require(script.Parent.TestKit)
local BuildInfo = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.UI.BuildInfo)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)

--============================================================================
-- Tunables
--============================================================================
local G0 = 9.80665
local MIN_FIT = 0.7
--============================================================================

local function row(overrides: { [string]: any }): BuildInfo.StageRow
	local base: { [string]: any } = {
		stage = 1,
		dvVac = 0,
		dvAsl = 0,
		twrAsl = 0,
		burnTime = 0,
		engines = 0,
		decouplers = 0,
		chutes = 0,
	}
	for key, value in overrides do
		base[key] = value
	end
	return (base :: any) :: BuildInfo.StageRow
end

local function contains(lines: { string }, text: string): boolean
	for _, line in lines do
		if string.find(line, text, 1, true) then
			return true
		end
	end
	return false
end

return function(t: TestKit.Context)
	t.test("category names and symmetry labels", function()
		t.expectEqual(BuildInfo.categoryName("FuelTank"), "Fuel")
		t.expectEqual(BuildInfo.categoryName("Engine"), "Engines")
		t.expectEqual(BuildInfo.categoryName("Unknown"), "Unknown")
		t.expectEqual(BuildInfo.symmetryLabel("MirrorXZ"), "Mirror XZ")
		t.expectEqual(BuildInfo.symmetryLabel("Off"), "Off")
		t.expectEqual(BuildInfo.boardingHint("Private"), "Only you")
	end)

	t.test("every part category has a tab name", function()
		for _, category in Parts.Categories do
			t.expectTrue(BuildInfo.categoryName(category) ~= "", category)
		end
	end)

	t.test("nextIn wraps both ways and starts unknown values at the first entry", function()
		local order = BuildInfo.SYMMETRY_ORDER
		t.expectEqual(BuildInfo.nextIn(order, "Off", 1), "MirrorX")
		t.expectEqual(BuildInfo.nextIn(order, "Radial4", 1), "Off")
		t.expectEqual(BuildInfo.nextIn(order, "Off", -1), "Radial4")
		t.expectEqual(BuildInfo.nextIn(BuildInfo.BOARDING_ORDER, "Private", 1), "Public")
		t.expectEqual(BuildInfo.nextIn(BuildInfo.BOARDING_ORDER, "Nope", 1), "Public")
	end)

	t.test("part lines: engine thrust and Isp, tank fuel, size last", function()
		local engine = BuildInfo.partLines(Parts.get("engine_s"), "Metric", G0)
		t.expectEqual(engine[1], "Mass 0.70 t")
		t.expectTrue(contains(engine, "Thrust 135 kN (vac)"), "thrust") -- CHANGED (Physics feel): engines x1.5
		t.expectTrue(contains(engine, "Isp 290 s ASL / 330 s vac"), "isp")
		t.expectEqual(engine[#engine], "1 x 1 x 1 blocks")

		local tank = BuildInfo.partLines(Parts.get("tank_l_long"), "Metric", G0)
		t.expectEqual(tank[1], "Mass 9.60 t")
		t.expectTrue(contains(tank, "Fuel 8.00 t"), "fuel")

		local srb = BuildInfo.partLines(Parts.get("srb_s"), "Metric", G0)
		t.expectTrue(contains(srb, "can't throttle"), "solid")
		t.expectTrue(not contains(srb, "Fuel "), "solid fuel is on the solid line, not a tank line")

		local pod = BuildInfo.partLines(Parts.get("pod_mk1"), "Imperial", G0)
		t.expectTrue(contains(pod, " lb"), "imperial mass")
		t.expectTrue(contains(pod, "1 seat (pilot)"), "seats")
	end)

	t.test("every part has info lines without non-ASCII text", function()
		for _, def in Parts.List do
			local lines = BuildInfo.partLines(def, "Metric", G0)
			t.expectTrue(#lines >= 2, def.Id)
			for _, line in lines do
				t.expectTrue(string.find(line, "[\128-\255]") == nil, def.Id .. ": " .. line)
			end
		end
	end)

	t.test("stage chips list only what the stage does, with plurals", function()
		local chips = BuildInfo.stageChips(row({ engines = 2, decouplers = 1 }))
		t.expectEqual(#chips, 2)
		t.expectEqual(chips[1].text, "2 engines")
		t.expectEqual(chips[1].kind, "Engine")
		t.expectEqual(chips[2].text, "1 decoupler")
		local chute = BuildInfo.stageChips(row({ chutes = 3 }))
		t.expectEqual(#chute, 1)
		t.expectEqual(chute[1].text, "3 chutes")
		t.expectEqual(#BuildInfo.stageChips(row({})), 0)
	end)

	t.test("TWR text and the low first-stage TWR flag", function()
		t.expectEqual(BuildInfo.twrText(1.456), "1.46")
		t.expectEqual(BuildInfo.twrText(0), "--")
		t.expectEqual(BuildInfo.twrText(0 / 0), "--")
		t.expectEqual(BuildInfo.twrText(math.huge), "--")
		t.expectTrue(BuildInfo.isTwrLow(row({ twrAsl = 0.8 }), true), "first stage below 1")
		t.expectTrue(not BuildInfo.isTwrLow(row({ twrAsl = 0.8 }), false), "upper stages are not flagged")
		t.expectTrue(not BuildInfo.isTwrLow(row({ twrAsl = 1.2 }), true), "first stage above 1")
		t.expectTrue(BuildInfo.isTwrLow(row({ twrAsl = 0 }), true), "no thrust on the first stage")
		t.expectTrue(BuildInfo.hasBurn(row({ twrAsl = 0.3 })), "burns")
		t.expectTrue(not BuildInfo.hasBurn(row({ chutes = 1 })), "chute stage has no burn")
	end)

	t.test("staging order puts stage 1 at the bottom", function()
		t.expectTrue(BuildInfo.stageLayoutOrder(1) > BuildInfo.stageLayoutOrder(2), "1 below 2")
		t.expectTrue(BuildInfo.stageLayoutOrder(2) > BuildInfo.stageLayoutOrder(5), "2 below 5")
	end)

	t.test("warning lines cap the list", function()
		local lines = BuildInfo.warningLines({ "a", "b", "c", "d", "e" }, 3)
		t.expectEqual(#lines, 4)
		t.expectEqual(lines[3], "c")
		t.expectEqual(lines[4], "+2 more")
		t.expectEqual(#BuildInfo.warningLines({ "a" }, 3), 1)
		t.expectEqual(#BuildInfo.warningLines({}, 3), 0)
	end)

	t.test("names, slots and part counts", function()
		t.expectEqual(BuildInfo.trimName("   Orbiter  ", 40), "Orbiter")
		t.expectEqual(BuildInfo.trimName("    ", 40), "")
		t.expectEqual(BuildInfo.trimName("abcdef", 3), "abc")
		t.expectEqual(BuildInfo.slotLabel(3, "Orbiter"), "3   Orbiter")
		t.expectEqual(BuildInfo.slotLabel(10, nil), "10   Empty")
		t.expectEqual(BuildInfo.partCountText(12, 250), "12 / 250")
	end)

	t.test("fit scale shrinks only, never below the minimum", function()
		t.expectEqual(BuildInfo.fitScale(1400, 1200, MIN_FIT), 1)
		t.expectEqual(BuildInfo.fitScale(900, 1200, MIN_FIT), 0.75)
		t.expectEqual(BuildInfo.fitScale(100, 1200, MIN_FIT), MIN_FIT)
		t.expectEqual(BuildInfo.fitScale(900, 0, MIN_FIT), 1)
		t.expectEqual(BuildInfo.fitScale(0 / 0, 1200, MIN_FIT), 1)
	end)
end
