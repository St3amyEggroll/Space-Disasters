--!strict
-- Tests for Shared/Config/SettingsSchema (Phase 11): defaults, sanitizing, keybind rules, JSON round trip.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)

type Values = SettingsSchema.Values

return function(t: TestKit.Context)
	local function expectSameValues(actual: Values, expected: Values, message: string)
		for _, field in SettingsSchema.FIELDS do
			if field ~= "keybinds" then
				t.expectEqual(
					SettingsSchema.getField(actual, field),
					SettingsSchema.getField(expected, field),
					`{message}: {field}`
				)
			end
		end
		for _, action in SettingsSchema.ACTIONS do
			t.expectEqual(actual.keybinds[action.id], expected.keybinds[action.id], `{message}: key of {action.id}`)
		end
	end

	local function expectDefaults(values: Values, message: string)
		expectSameValues(values, SettingsSchema.defaults(), message)
	end

	t.test("defaults are complete, in range and fresh", function()
		local values = SettingsSchema.defaults()
		t.expectEqual(values.mouseSensitivity, 1)
		t.expectEqual(values.cameraSmoothing, 0.5)
		t.expectEqual(values.uiScale, 1)
		t.expectEqual(values.musicVolume, 0.5)
		t.expectEqual(values.effectsVolume, 0.8)
		t.expectEqual(values.invertY, false)
		t.expectEqual(values.cameraShake, true) -- CHANGED (Physics feel)
		t.expectEqual(values.hudVisible, true)
		t.expectEqual(values.units, "Metric")
		t.expectEqual(values.hints, true)
		for field, range in SettingsSchema.RANGES do
			local value = SettingsSchema.getField(values, field)
			t.expectTrue(value >= range.min and value <= range.max, field .. " default in range")
			t.expectEqual(value, range.default, field .. " default")
		end
		for _, action in SettingsSchema.ACTIONS do
			t.expectEqual(values.keybinds[action.id], action.default, action.id)
		end
		values.keybinds.Stage = "K"
		values.uiScale = 1.3
		local again = SettingsSchema.defaults()
		t.expectEqual(again.keybinds.Stage, "Space", "defaults() returns a fresh keybinds table")
		t.expectEqual(again.uiScale, 1)
	end)

	t.test("default keys are allowed and unique per context", function()
		local seen: { [string]: { [string]: string } } = { Flight = {}, EVA = {}, Build = {} } -- CHANGED (Phase 6)
		local ids: { [string]: boolean } = {}
		for _, action in SettingsSchema.ACTIONS do
			t.expectTrue(SettingsSchema.isAllowedKey(action.default), action.id .. " default allowed")
			t.expectTrue(seen[action.context][action.default] == nil, action.id .. " default unique in context")
			t.expectTrue(not ids[action.id], action.id .. " id unique")
			seen[action.context][action.default] = action.id
			ids[action.id] = true
			t.expectTrue(SettingsSchema.findAction(action.id) == action)
		end
		t.expectEqual(#SettingsSchema.actionsFor("Flight"), 17)
		t.expectEqual(#SettingsSchema.actionsFor("Build"), 9)
		t.expectEqual(#SettingsSchema.actionsFor("EVA"), 8) -- CHANGED (Phase 6)
		t.expectTrue(SettingsSchema.findAction("Teleport") == nil)
	end)

	-- CHANGED (Phase 6): the EVA keys (spacewalk jetpack, brake, light)
	t.test("EVA defaults: WASD / Space / Ctrl jetpack, R brake, L light, E left for the seat prompts", function()
		local expected: { [string]: string } = {
			EvaForward = "W",
			EvaBack = "S",
			EvaLeft = "A",
			EvaRight = "D",
			EvaUp = "Space",
			EvaDown = "LeftControl",
			EvaBrake = "R",
			EvaLight = "L",
		}
		local binds = SettingsSchema.defaultKeybinds()
		for id, key in expected do
			local action = SettingsSchema.findAction(id)
			t.expectTrue(action ~= nil and action.context == "EVA", id .. " is an EVA action")
			t.expectEqual(binds[id], key, id)
		end
		for _, action in SettingsSchema.actionsFor("EVA") do
			t.expectTrue(action.default ~= "E", "E boards (seat prompts)")
			t.expectTrue(action.default ~= "M" and action.default ~= "F2", "map and HUD keys keep working on EVA")
		end
		t.expectEqual(SettingsSchema.CONTEXTS[2], "EVA", "EVA is shown between Flight and Builder")
		-- an EVA key may repeat a flight key (separate contexts), and a clash inside EVA falls back to defaults
		local raw = SettingsSchema.defaultKeybinds()
		raw.EvaBrake = "W"
		local clean = SettingsSchema.sanitizeKeybinds(raw)
		t.expectEqual(clean.EvaBrake, "R", "the later EVA action gives way")
		t.expectEqual(clean.PitchDown, "W", "the flight context keeps its key")
	end)

	t.test("flight defaults are the Phase 2a keys", function()
		local expected: { [string]: string } = {
			PitchDown = "W",
			PitchUp = "S",
			YawLeft = "A",
			YawRight = "D",
			RollLeft = "E",
			RollRight = "Q",
			ThrottleUp = "LeftShift",
			ThrottleDown = "LeftControl",
			ThrottleFull = "Z",
			ThrottleCut = "X",
			ToggleSAS = "T",
			ToggleGear = "G",
			Stage = "Space",
			ToggleCamera = "V",
			LeaveSeat = "F",
			MapView = "M",
			ToggleHUD = "F2",
			RotateY = "R",
			RotateX = "T",
			ToolBuild = "B",
			ToolPaint = "P",
			ToolDelete = "X",
			SymmetryOff = "One",
			SymmetryRadial2 = "Two",
			SymmetryRadial4 = "Four",
			SymmetryMirror = "M",
		}
		local binds = SettingsSchema.defaultKeybinds()
		for id, key in expected do
			t.expectEqual(binds[id], key, id)
		end
		t.expectEqual(SettingsSchema.ACTIONS[1].id, "PitchDown", "display order starts with flight")
	end)

	t.test("reserved keys are never bindable", function()
		for _, name in SettingsSchema.RESERVED_KEYS do
			t.expectTrue(not SettingsSchema.isAllowedKey(name), name)
		end
		t.expectTrue(SettingsSchema.isAllowedKey("W"))
		t.expectTrue(SettingsSchema.isAllowedKey("KeypadNine"))
		t.expectTrue(not SettingsSchema.isAllowedKey("Nope"))
		t.expectTrue(not SettingsSchema.isAllowedKey("w"), "names are case sensitive")
	end)

	t.test("numbers are clamped and must be finite", function()
		local values = SettingsSchema.sanitize({
			mouseSensitivity = 100,
			cameraSmoothing = -2,
			uiScale = 0.1,
			musicVolume = 1.5,
			effectsVolume = 0.25,
		})
		t.expectEqual(values.mouseSensitivity, 3)
		t.expectEqual(values.cameraSmoothing, 0)
		t.expectEqual(values.uiScale, 0.7)
		t.expectEqual(values.musicVolume, 1)
		t.expectEqual(values.effectsVolume, 0.25)
		local bad = SettingsSchema.sanitize({ mouseSensitivity = 0 / 0, uiScale = math.huge, musicVolume = -math.huge })
		t.expectEqual(bad.mouseSensitivity, 1, "NaN gives the default")
		t.expectEqual(bad.uiScale, 1, "inf gives the default")
		t.expectEqual(bad.musicVolume, 0.5, "-inf gives the default")
	end)

	t.test("wrong types give the defaults", function()
		expectDefaults(
			SettingsSchema.sanitize({
				mouseSensitivity = "fast",
				invertY = "yes",
				cameraSmoothing = true,
				cameraShake = "off", -- CHANGED (Physics feel)
				uiScale = {},
				hudVisible = 0,
				units = "Parsecs",
				hints = "no",
				musicVolume = "loud",
				effectsVolume = false,
				keybinds = "WASD",
			}),
			"wrong types"
		)
		expectDefaults(SettingsSchema.sanitize(nil), "nil")
		expectDefaults(SettingsSchema.sanitize("garbage"), "string")
		expectDefaults(SettingsSchema.sanitize(42), "number")
		local imperial =
			SettingsSchema.sanitize({ units = "Imperial", invertY = true, hints = false, cameraShake = false })
		t.expectEqual(imperial.units, "Imperial")
		t.expectEqual(imperial.invertY, true)
		t.expectEqual(imperial.hints, false)
		t.expectEqual(imperial.cameraShake, false) -- CHANGED (Physics feel)
	end)

	t.test("unknown fields and actions are dropped", function()
		local values = SettingsSchema.sanitize({
			fov = 120,
			admin = true,
			keybinds = { Teleport = "K", Stage = "K", [1] = "J" },
		})
		local known: { [string]: boolean } = {}
		for _, field in SettingsSchema.FIELDS do
			known[field] = true
		end
		for key in pairs(values) do
			t.expectTrue(known[key] == true, "unexpected field " .. tostring(key))
		end
		local count = 0
		for actionId in pairs(values.keybinds) do
			t.expectTrue(SettingsSchema.findAction(actionId) ~= nil, "unexpected action " .. tostring(actionId))
			count += 1
		end
		t.expectEqual(count, #SettingsSchema.ACTIONS, "one key per action")
		t.expectEqual(values.keybinds.Stage, "K")
	end)

	t.test("disallowed keys give the default", function()
		local values = SettingsSchema.sanitize({
			keybinds = { Stage = "Escape", MapView = "F3", ToggleSAS = 42, RotateY = "Tab", ToolPaint = "Slash" },
		})
		expectDefaults(values, "disallowed keys")
	end)

	t.test("a duplicate in one context gives the later action its default", function()
		local values = SettingsSchema.sanitize({ keybinds = { PitchDown = "K", Stage = "K" } })
		t.expectEqual(values.keybinds.PitchDown, "K", "the earlier action keeps the key")
		t.expectEqual(values.keybinds.Stage, "Space", "the later action gets its default")
		-- a swap is not a duplicate
		local swapped = SettingsSchema.sanitize({ keybinds = { Stage = "M", MapView = "Space" } })
		t.expectEqual(swapped.keybinds.Stage, "M")
		t.expectEqual(swapped.keybinds.MapView, "Space")
	end)

	t.test("a duplicate that survives the default resets that context only", function()
		local values = SettingsSchema.sanitize({
			keybinds = { PitchDown = "Space", Stage = "Space", ToggleSAS = "K", RotateY = "K" },
		})
		for _, action in SettingsSchema.actionsFor("Flight") do
			t.expectEqual(values.keybinds[action.id], action.default, "flight reset: " .. action.id)
		end
		t.expectEqual(values.keybinds.RotateY, "K", "the build context keeps its keys")
	end)

	t.test("one key may serve a flight and a build action", function()
		local values = SettingsSchema.sanitize({ keybinds = { Stage = "R", RotateY = "R" } })
		t.expectEqual(values.keybinds.Stage, "R")
		t.expectEqual(values.keybinds.RotateY, "R")
		t.expectEqual(values.keybinds.MapView, "M")
		t.expectEqual(values.keybinds.SymmetryMirror, "M")
	end)

	t.test("sanitizeField validates single fields", function()
		local ok, clean = SettingsSchema.sanitizeField("uiScale", 5)
		t.expectTrue(ok)
		t.expectEqual(clean, 1.4)
		ok = SettingsSchema.sanitizeField("uiScale", "big")
		t.expectTrue(not ok)
		ok = SettingsSchema.sanitizeField("mouseSensitivity", 0 / 0)
		t.expectTrue(not ok, "NaN rejected")
		ok, clean = SettingsSchema.sanitizeField("units", "Imperial")
		t.expectTrue(ok)
		t.expectEqual(clean, "Imperial")
		ok = SettingsSchema.sanitizeField("units", "Furlongs")
		t.expectTrue(not ok)
		ok, clean = SettingsSchema.sanitizeField("invertY", true)
		t.expectTrue(ok)
		t.expectEqual(clean, true)
		ok = SettingsSchema.sanitizeField("hudVisible", "true")
		t.expectTrue(not ok)
		-- CHANGED (Physics feel): the camera shake toggle
		ok, clean = SettingsSchema.sanitizeField("cameraShake", false)
		t.expectTrue(ok)
		t.expectEqual(clean, false)
		ok = SettingsSchema.sanitizeField("cameraShake", 1)
		t.expectTrue(not ok)
		ok = SettingsSchema.sanitizeField("nope", 1)
		t.expectTrue(not ok, "unknown field")
		ok, clean = SettingsSchema.sanitizeField("keybinds", { Stage = "Escape" })
		t.expectTrue(ok)
		t.expectEqual(clean.Stage, "Space")
		ok = SettingsSchema.sanitizeField("keybinds", "Space")
		t.expectTrue(not ok)
	end)

	t.test("getField / setField cover every field", function()
		local values = SettingsSchema.defaults()
		for _, field in SettingsSchema.FIELDS do
			t.expectTrue(SettingsSchema.getField(values, field) ~= nil, field)
		end
		t.expectTrue(SettingsSchema.setField(values, "units", "Imperial"))
		t.expectEqual(values.units, "Imperial")
		t.expectTrue(SettingsSchema.setField(values, "mouseSensitivity", 2))
		t.expectEqual(SettingsSchema.getField(values, "mouseSensitivity"), 2)
		t.expectTrue(SettingsSchema.setField(values, "cameraShake", false)) -- CHANGED (Physics feel)
		t.expectEqual(SettingsSchema.getField(values, "cameraShake"), false)
		t.expectTrue(not SettingsSchema.setField(values, "nope", 1))
		t.expectTrue(SettingsSchema.getField(values, "nope") == nil)
	end)

	t.test("encode / decode round trip", function()
		local values = SettingsSchema.defaults()
		values.mouseSensitivity = 0.1 + 0.2 -- not representable exactly in decimal
		values.invertY = true
		values.cameraSmoothing = 0.9
		values.cameraShake = false -- CHANGED (Physics feel)
		values.uiScale = 1.25
		values.hudVisible = false
		values.units = "Imperial"
		values.hints = false
		values.musicVolume = 0
		values.effectsVolume = 1
		values.keybinds.Stage = "M"
		values.keybinds.MapView = "Space"
		values.keybinds.RotateY = "Q"
		local decoded = SettingsSchema.decode(SettingsSchema.encode(values))
		expectSameValues(decoded, values, "round trip")
		expectDefaults(SettingsSchema.decode(SettingsSchema.encode(SettingsSchema.defaults())), "default round trip")
	end)

	t.test("encode writes only changed keybinds and always fits", function()
		local values = SettingsSchema.defaults()
		values.keybinds.Stage = "K"
		local json = SettingsSchema.encode(values)
		t.expectTrue(string.find(json, '"Stage":"K"', 1, true) ~= nil, "changed key written")
		t.expectTrue(string.find(json, "PitchDown", 1, true) == nil, "default key not written")
		-- worst case: every action on a non-default key (rotate each context's keys by one allowed key)
		local worst = SettingsSchema.defaults()
		for _, context: SettingsSchema.Context in SettingsSchema.CONTEXTS do
			for index, action in SettingsSchema.actionsFor(context) do
				worst.keybinds[action.id] = SettingsSchema.ALLOWED_KEYS[#SettingsSchema.ALLOWED_KEYS - index + 1]
			end
		end
		local worstJson = SettingsSchema.encode(worst)
		t.expectTrue(#worstJson <= SettingsSchema.MAX_JSON_BYTES, `worst case is {#worstJson} bytes`)
		expectSameValues(SettingsSchema.decode(worstJson), SettingsSchema.sanitize(worst), "worst case round trip")
	end)

	t.test("encode never errors on bad values", function()
		local values = SettingsSchema.defaults()
		values.mouseSensitivity = 0 / 0
		values.uiScale = math.huge
		local decoded = SettingsSchema.decode(SettingsSchema.encode(values))
		t.expectEqual(decoded.mouseSensitivity, 1)
		t.expectEqual(decoded.uiScale, 1)
	end)

	t.test("garbage JSON gives the defaults without errors", function()
		local deep = string.rep("[", 200) .. string.rep("]", 200)
		for _, text in { "", "{", "null", "true", "12", '"text"', "[1,2,3]", '{"keybinds":"x"}', "\0\1\2", deep } do
			expectDefaults(SettingsSchema.decode(text), "decode " .. string.sub(text, 1, 12))
		end
		local partial = SettingsSchema.decode('{"uiScale":1.2,"units":"Imperial","keybinds":{"Stage":"Nope"}}')
		t.expectEqual(partial.uiScale, 1.2)
		t.expectEqual(partial.units, "Imperial")
		t.expectEqual(partial.keybinds.Stage, "Space")
		t.expectEqual(partial.mouseSensitivity, 1)
	end)

	t.test("oversize JSON gives the defaults", function()
		local padding = string.rep("x", SettingsSchema.MAX_JSON_BYTES)
		local oversize = '{"uiScale":1.2,"pad":"' .. padding .. '"}'
		t.expectTrue(#oversize > SettingsSchema.MAX_JSON_BYTES)
		expectDefaults(SettingsSchema.decode(oversize), "oversize")
		local fits = '{"uiScale":1.2,"pad":"' .. string.rep("x", 100) .. '"}'
		t.expectEqual(SettingsSchema.decode(fits).uiScale, 1.2, "a payload under the limit is read")
	end)

	-- CHANGED (Phase 11 review): a key freed by a rebind (Space after Stage moved) is still captured while piloting
	t.test("pilotKeys keeps the old flight keys after a rebind", function()
		local function count(list: { string }, key: string): number
			local n = 0
			for _, item in list do
				if item == key then
					n += 1
				end
			end
			return n
		end
		local defaults = SettingsSchema.pilotKeys(SettingsSchema.defaultKeybinds())
		for _, action in SettingsSchema.actionsFor("Flight") do
			t.expectEqual(count(defaults, action.default), 1, `default key of {action.id} once`)
		end
		for _, key in SettingsSchema.PILOT_SINK_KEYS do
			t.expectEqual(count(defaults, key), 1, `sink key {key} once`)
		end
		t.expectEqual(count(defaults, "R"), 0, "a Build-only key is not captured")

		local binds = SettingsSchema.defaultKeybinds()
		binds.Stage = "Return"
		binds.ThrottleUp = "RightShift"
		local rebound = SettingsSchema.pilotKeys(SettingsSchema.sanitizeKeybinds(binds))
		t.expectEqual(count(rebound, "Return"), 1, "the new Stage key")
		t.expectEqual(count(rebound, "RightShift"), 1, "the new ThrottleUp key")
		t.expectEqual(count(rebound, "Space"), 1, "Space stays captured (no jump out of the seat)")
		t.expectEqual(count(rebound, "LeftShift"), 1, "LeftShift stays captured (no shift lock)")
		t.expectEqual(rebound[1], "W", "Flight action keys come first, in ACTIONS order")
	end)
end
