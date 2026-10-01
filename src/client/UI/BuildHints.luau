--!strict
--[[
	BuildHints (Phase 11)
	A slim strip of key hints for the builder ("[Click] place  [R] rotate  [T] tilt ..."), different for each tool.
	Key badges come from Settings/Keybinds and the strip is rebuilt on every rebinding; it is shown only while the
	"hints" setting is on (live). Pure view: no input of its own (the strip sinks clicks so they do not build behind it).

	API:
	  BuildHints.create(parent) -> Hints
	  Hints.frame: Frame              the strip (BuildUI sets its Position)
	  Hints.setTool(tool)             rebuilds the strip for that tool
	  Hints.setHasRoom(hasRoom)       false hides the strip (BuildUI: the side panels leave no room for it)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SettingsSchema = require(ReplicatedStorage.Shared.Config.SettingsSchema)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local Settings = require(script.Parent.Parent.Settings.Settings)
local BuildInfo = require(script.Parent.BuildInfo)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)

--============================================================================
-- Tunables
--============================================================================
local HINTS_FIELD = "hints" -- the Settings field that shows / hides the strip
local HEIGHT = 30 -- design px
local PADDING = 6
local KEY_GAP = 3
local GROUP_GAP = 12
local CLICK_TEXT = "Click"
local UNDO_KEY_TEXT = "Ctrl+Z" -- fixed, not rebindable
-- One entry per hint: action ids (or literal key text, when not an action id) and what they do.
local HINTS: { [string]: { Hint } } = {
	Build = {
		{ keys = { CLICK_TEXT }, text = "place" },
		{ keys = { "RotateY" }, text = "rotate" },
		{ keys = { "RotateX" }, text = "tilt" },
		{ keys = { "SymmetryMirror" }, text = "mirror" },
		{ keys = { "SymmetryOff", "SymmetryRadial2", "SymmetryRadial4" }, text = "symmetry" },
		{ keys = { UNDO_KEY_TEXT }, text = "undo" },
	},
	Paint = {
		{ keys = { CLICK_TEXT }, text = "paint" },
		{ keys = { "ToolBuild" }, text = "build" },
		{ keys = { "ToolDelete" }, text = "delete" },
		{ keys = { UNDO_KEY_TEXT }, text = "undo" },
	},
	Delete = {
		{ keys = { CLICK_TEXT }, text = "remove" },
		{ keys = { "ToolDelete" }, text = "back to build" },
		{ keys = { UNDO_KEY_TEXT }, text = "undo" },
	},
}
--============================================================================

type Hint = { keys: { string }, text: string }

export type Hints = {
	frame: Frame,
	setTool: (tool: BuildInfo.Tool) -> (),
	setHasRoom: (hasRoom: boolean) -> (),
}

local BuildHints = {}

local EMPTY: { Hint } = {}

-- The badge text for a hint key: an action's current key, or the literal text.
local function keyText(key: string): string
	if SettingsSchema.findAction(key) then
		return Keybinds.label(key)
	end
	return key
end

function BuildHints.create(parent: Instance): Hints
	local strip = Kit.panel({
		parent = parent,
		name = "Hints",
		size = UDim2.fromOffset(0, HEIGHT),
		anchor = Vector2.new(0.5, 1),
		padding = PADDING,
	})
	strip.AutomaticSize = Enum.AutomaticSize.X

	local tool: BuildInfo.Tool = "Build"
	local content: Frame? = nil
	local hasRoom = true

	local function rebuild()
		if content then
			content:Destroy()
		end
		local frame = Kit.frame(strip, { name = "Content", size = UDim2.fromScale(0, 1) })
		frame.AutomaticSize = Enum.AutomaticSize.X
		Kit.list(frame, { horizontal = true, gap = KEY_GAP })
		for index, hint in HINTS[tool] or EMPTY do
			if index > 1 then
				Kit.frame(frame, { name = "Gap", size = UDim2.fromOffset(GROUP_GAP - KEY_GAP * 2, 1) })
			end
			for _, key in hint.keys do
				Kit.keycap(frame, keyText(key))
			end
			local label = Kit.label(frame, hint.text, {
				size = UDim2.fromScale(0, 1),
				dim = true,
				textSize = Theme.TextSizes.Small,
			})
			label.AutomaticSize = Enum.AutomaticSize.X
		end
		content = frame
	end

	local function refreshVisible()
		strip.Visible = Settings.current().hints and hasRoom
	end

	Keybinds.onChanged(rebuild)
	Settings.onChanged(function(field: string)
		if field == HINTS_FIELD then
			refreshVisible()
		end
	end)
	rebuild()
	refreshVisible()

	return {
		frame = strip,
		setTool = function(newTool: BuildInfo.Tool)
			if newTool ~= tool then
				tool = newTool
				rebuild()
			end
		end,
		setHasRoom = function(room: boolean)
			if room ~= hasRoom then
				hasRoom = room
				refreshVisible()
			end
		end,
	}
end

return table.freeze(BuildHints)
