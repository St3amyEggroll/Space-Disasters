--!strict
--[[
	Updates (Phase 11)
	The "Updates" list shown on the main menu's Credits / Updates panel, newest first, and the version line in the
	menu's bottom-left corner. Short, simple-English notes for players; no dates. Add a new entry at the TOP of
	ENTRIES whenever a phase ships (the version line always shows the first entry).

	Text rules: ASCII plus the degree sign only (Roblox fonts may lack other glyphs). The offline spec
	(src/server/Tests/Updates.spec.luau) checks this.

	API:
	  Updates.ENTRIES: { Entry }       newest first (frozen)
	  Updates.latest() -> Entry        the newest entry
	  Updates.heading(entry) -> string "Phase 11: New look"
	  Updates.versionLine() -> string  "Phase 11: New look" for the newest entry

	Pure module (no services), so it can be required by the offline test runner.
]]

--============================================================================
-- Tunables
--============================================================================
local HEADING_SEPARATOR = ": "
--============================================================================

export type Entry = {
	version: string, -- "Phase 11"
	title: string, -- "New look"
	notes: { string }, -- one short sentence per bullet
}

local entries: { Entry } = {
	{
		version = "Phase 11",
		title = "New look",
		notes = {
			"A new main menu with your avatar floating in space.",
			"A settings screen: mouse, camera, keys, UI size, units and sound.",
			"A new flight HUD in the style of Kerbal Space Program.",
			"A restyled builder with a new staging list.",
		},
	},
	{
		version = "Update",
		title = "New names",
		notes = {
			"The game and the launch site are now called Space Disasters Inc.",
			"Our planet is now Earth.",
			"Its moon is now the Mun.",
			"The sun is now Sol.",
		},
	},
	{
		version = "Phase 10",
		title = "Effects",
		notes = {
			"Engine flames that change with the air around them.",
			"Smoke trails and launch dust.",
			"Explosions when things crash.",
			"Re-entry heat when you come back from space fast.",
		},
	},
	{
		version = "Phase 5",
		title = "Orbits and map",
		notes = {
			"Real orbits around Earth and the Mun.",
			"The map view: press M while flying.",
			"A navball to see where you point.",
			"Crafts in orbit keep flying while nobody touches them.",
		},
	},
	{
		version = "Phase 3",
		title = "Multiplayer crafts",
		notes = {
			"See the rockets of other players fly.",
			"See who is sitting in them.",
		},
	},
	{
		version = "Phase 2a",
		title = "Flight",
		notes = {
			"Fly your rockets and fire stages with Space.",
			"Crash them in style.",
			"Landing legs.",
			"New models for all the parts.",
		},
	},
	{
		version = "Phase 1",
		title = "Builder",
		notes = {
			"Build rockets on your own plot.",
			"Save your rockets in save slots.",
		},
	},
}

for index, entry in entries do
	table.freeze(entry.notes)
	entries[index] = table.freeze(entry)
end

local Updates = {}

Updates.ENTRIES = table.freeze(entries)

function Updates.latest(): Entry
	return entries[1]
end

function Updates.heading(entry: Entry): string
	return entry.version .. HEADING_SEPARATOR .. entry.title
end

function Updates.versionLine(): string
	return Updates.heading(entries[1])
end

return table.freeze(Updates)
