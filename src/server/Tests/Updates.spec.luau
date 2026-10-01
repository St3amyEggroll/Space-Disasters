--!strict
-- Tests for Config/Updates (Phase 11): the main menu's update notes are present, frozen, newest first (Phase 11 on
-- top) and use only characters Roblox's fonts can draw (ASCII plus the degree sign).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Updates = require(ReplicatedStorage.Shared.Config.Updates)

--============================================================================
-- Tunables
--============================================================================
local DEGREE = utf8.char(176)
local MAX_NOTE_LENGTH = 90 -- keep notes short and simple
--============================================================================

local function allowedText(text: string): boolean
	local cleaned = string.gsub(text, DEGREE, "")
	return string.find(cleaned, "[^\32-\126]") == nil
end

return function(t: TestKit.Context)
	t.test("entries exist and are frozen", function()
		t.expectTrue(#Updates.ENTRIES >= 1)
		t.expectTrue(table.isfrozen(Updates.ENTRIES))
		for _, entry in Updates.ENTRIES do
			t.expectTrue(table.isfrozen(entry), entry.version)
			t.expectTrue(table.isfrozen(entry.notes), entry.version .. " notes")
			t.expectTrue(#entry.notes >= 1, entry.version .. " has notes")
		end
	end)

	t.test("newest first: Phase 11 is the latest and the version line", function()
		t.expectEqual(Updates.latest(), Updates.ENTRIES[1])
		t.expectEqual(Updates.latest().version, "Phase 11")
		t.expectEqual(Updates.versionLine(), "Phase 11: New look")
		t.expectEqual(Updates.ENTRIES[#Updates.ENTRIES].version, "Phase 1")
	end)

	t.test("text is short ASCII (plus the degree sign)", function()
		t.expectTrue(allowedText("HDG 017" .. DEGREE), "the degree sign is allowed")
		t.expectTrue(not allowedText("caf" .. utf8.char(233)), "other characters are not")
		for _, entry in Updates.ENTRIES do
			t.expectTrue(allowedText(entry.version) and allowedText(entry.title), entry.version)
			for _, note in entry.notes do
				t.expectTrue(allowedText(note), note)
				t.expectTrue(#note <= MAX_NOTE_LENGTH, note)
			end
		end
	end)
end
