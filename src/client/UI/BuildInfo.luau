--!strict
--[[
	BuildInfo (Phase 11)
	The builder UI's shared types and its pure text / layout rules, kept free of instances and services so the offline
	Lune spec can test them (src/server/Tests/BuildInfo.spec.luau). The Build* view modules (BuildUI, BuildCatalog,
	BuildToolbar, BuildStaging, BuildSlots, BuildHints) all read their names and numbers from here.

	Types:
	  Tool        "Build" | "Paint" | "Delete"
	  Symmetry    "Off" | "MirrorX" | "MirrorZ" | "MirrorXZ" | "Radial2" | "Radial4"
	  StageRow    one stage in firing order (stage 1 fires first): delta-v (m/s), TWR on the home world, burn time (s)
	              and what the stage does (engines ignited, decouplers fired, parachutes armed)
	  Stats       the craft: mass (kg), part count, stage rows, total delta-v, warnings
	  Chip        { text, kind } one "what this stage does" tag on a staging card

	API:
	  BuildInfo.TOOLS: { Tool }                          toolbar order
	  BuildInfo.SYMMETRY_ORDER: { Symmetry }             symmetry button cycle order
	  BuildInfo.BOARDING_ORDER: { string }               boarding button cycle order ("Public", "Friends", "Private")
	  BuildInfo.categoryName(category) -> string         tab label ("FuelTank" -> "Fuel")
	  BuildInfo.symmetryLabel(mode) -> string            "Mirror X", "Radial 4", "Off"
	  BuildInfo.boardingHint(mode) -> string             "Anyone can board", "Friends only", "Only you"
	  BuildInfo.nextIn(order, current, step) -> string   the entry step places after current (wraps; unknown -> 1st)
	  BuildInfo.partLines(def, units, g0) -> { string }  short stats for the part info card, most important first
	  BuildInfo.sizeText(def) -> string                  "2 x 1 x 2 blocks"
	  BuildInfo.stageChips(row) -> { Chip }              "2 engines", "1 decoupler", "3 chutes" (only non-zero)
	  BuildInfo.hasBurn(row) -> boolean                  the stage produces thrust (shows delta-v and TWR)
	  BuildInfo.twrText(twr) -> string                   "1.45"; "--" for no thrust or a non-finite value
	  BuildInfo.isTwrLow(row, isFirst) -> boolean        the first stage cannot lift off (TWR < 1)
	  BuildInfo.stageLayoutOrder(stage) -> number        UIListLayout order that puts stage 1 at the BOTTOM (KSP)
	  BuildInfo.warningLines(warnings, max) -> { string } at most max lines, then "+N more"
	  BuildInfo.partCountText(parts, max) -> string      "12 / 250"
	  BuildInfo.trimName(text, maxLength) -> string      surrounding spaces removed, cut to maxLength
	  BuildInfo.slotLabel(slot, name?) -> string         "3   Orbiter Mk2" / "3   Empty"
	  BuildInfo.fitScale(available, natural, minScale) -> number   shrink factor (<= 1) so natural fits available
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local UnitFormat = require(ReplicatedStorage.Shared.Util.UnitFormat)

--============================================================================
-- Tunables
--============================================================================
local CATEGORY_NAMES: { [string]: string } = {
	Command = "Command",
	FuelTank = "Fuel",
	Engine = "Engines",
	Coupling = "Coupling",
	Aero = "Aero",
	Utility = "Utility",
	Structural = "Structural",
}
local SYMMETRY_LABELS: { [string]: string } = {
	Off = "Off",
	MirrorX = "Mirror X",
	MirrorZ = "Mirror Z",
	MirrorXZ = "Mirror XZ",
	Radial2 = "Radial 2",
	Radial4 = "Radial 4",
}
local BOARDING_HINTS: { [string]: string } = {
	Public = "Anyone can board",
	Friends = "Friends only",
	Private = "Only you",
}
local NOT_AVAILABLE = "--" -- TWR / values that do not apply
local EMPTY_SLOT = "Empty"
local SLOT_SEPARATOR = "   "
local NEWTONS_PER_KN = 1000
local LOW_DRAG = 1 -- DragFactor below this is called out as a low-drag part
--============================================================================

export type Tool = "Build" | "Paint" | "Delete"
export type Symmetry = "Off" | "MirrorX" | "MirrorZ" | "MirrorXZ" | "Radial2" | "Radial4"

export type StageRow = {
	stage: number, -- 1 = fires first
	dvVac: number, -- m/s
	dvAsl: number, -- m/s
	twrAsl: number, -- at ignition, home world surface gravity
	burnTime: number, -- s at full throttle
	engines: number, -- engines this stage ignites
	decouplers: number, -- decouplers this stage fires
	chutes: number, -- parachutes this stage arms
}

export type Stats = {
	mass: number, -- kg
	parts: number,
	stages: { StageRow }, -- firing order
	totalVac: number,
	totalAsl: number,
	warnings: { string },
}

export type ChipKind = "Engine" | "Decoupler" | "Chute"
export type Chip = { text: string, kind: ChipKind }

local BuildInfo = {}

local TOOLS: { Tool } = { "Build", "Paint", "Delete" }
local SYMMETRY_ORDER: { Symmetry } = { "Off", "MirrorX", "MirrorZ", "MirrorXZ", "Radial2", "Radial4" }
BuildInfo.TOOLS = table.freeze(TOOLS)
BuildInfo.SYMMETRY_ORDER = table.freeze(SYMMETRY_ORDER)
BuildInfo.BOARDING_ORDER = table.freeze({ "Public", "Friends", "Private" })

local function isFinite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function plural(count: number, singular: string, pluralText: string): string
	return `{count} {if count == 1 then singular else pluralText}`
end

function BuildInfo.categoryName(category: string): string
	return CATEGORY_NAMES[category] or category
end

function BuildInfo.symmetryLabel(mode: string): string
	return SYMMETRY_LABELS[mode] or mode
end

function BuildInfo.boardingHint(mode: string): string
	return BOARDING_HINTS[mode] or ""
end

function BuildInfo.nextIn<T>(order: { T }, current: T, step: number): T
	local index = table.find(order, current)
	if index == nil then
		return order[1]
	end
	return order[(index - 1 + step) % #order + 1]
end

function BuildInfo.sizeText(def: Parts.PartDef): string
	return `{def.Size.X} x {def.Size.Y} x {def.Size.Z} blocks`
end

function BuildInfo.partLines(def: Parts.PartDef, units: UnitFormat.Units, g0: number): { string }
	local lines: { string } = {}
	table.insert(lines, `Mass {UnitFormat.mass(Parts.wetMass(def), units)}`)
	local engine = def.Engine
	if engine then
		local thrust = UnitFormat.thousands(Parts.thrustAt(engine, 0, g0) / NEWTONS_PER_KN)
		table.insert(lines, `Thrust {thrust} kN (vac)`)
		table.insert(lines, `Isp {engine.IspAsl} s ASL / {engine.IspVac} s vac`)
		if not engine.Throttleable then
			table.insert(lines, `Solid fuel {UnitFormat.mass(def.FuelMass, units)}, can't throttle`)
		end
	elseif def.FuelMass > 0 then
		table.insert(lines, `Fuel {UnitFormat.mass(def.FuelMass, units)}`)
	end
	if def.Seats > 0 then
		local seats = plural(def.Seats, "seat", "seats")
		table.insert(lines, if def.PilotSeat then seats .. " (pilot)" else seats)
	end
	if def.Torque > 0 then
		table.insert(lines, `Reaction wheel {UnitFormat.thousands(def.Torque / NEWTONS_PER_KN)} kN*m`)
	end
	local decoupler = def.Decoupler
	if decoupler then
		table.insert(lines, if decoupler.Radial then "Radial decoupler (side mount)" else "Stack decoupler")
	end
	local chute = def.Chute
	if chute then
		table.insert(lines, `Opens below {UnitFormat.speed(chute.MaxDeploySpeed, units)}`)
	end
	if def.Leg then
		table.insert(lines, "Landing leg")
	end
	if def.Fin then
		table.insert(lines, "Fin: keeps the nose forward")
	end
	if def.DragFactor < LOW_DRAG then
		table.insert(lines, "Low drag when leading")
	end
	table.insert(lines, BuildInfo.sizeText(def))
	return lines
end

function BuildInfo.stageChips(row: StageRow): { Chip }
	local chips: { Chip } = {}
	if row.engines > 0 then
		table.insert(chips, { text = plural(row.engines, "engine", "engines"), kind = "Engine" })
	end
	if row.decouplers > 0 then
		table.insert(chips, { text = plural(row.decouplers, "decoupler", "decouplers"), kind = "Decoupler" })
	end
	if row.chutes > 0 then
		table.insert(chips, { text = plural(row.chutes, "chute", "chutes"), kind = "Chute" })
	end
	return chips
end

function BuildInfo.hasBurn(row: StageRow): boolean
	return isFinite(row.twrAsl) and row.twrAsl > 0
end

function BuildInfo.twrText(twr: number): string
	if not isFinite(twr) or twr <= 0 then
		return NOT_AVAILABLE
	end
	return string.format("%.2f", twr)
end

function BuildInfo.isTwrLow(row: StageRow, isFirst: boolean): boolean
	return isFirst and not (isFinite(row.twrAsl) and row.twrAsl >= 1)
end

function BuildInfo.stageLayoutOrder(stage: number): number
	return -stage
end

function BuildInfo.warningLines(warnings: { string }, max: number): { string }
	local lines: { string } = {}
	for index = 1, math.min(#warnings, max) do
		table.insert(lines, warnings[index])
	end
	if #warnings > max then
		table.insert(lines, `+{#warnings - max} more`)
	end
	return lines
end

function BuildInfo.partCountText(parts: number, max: number): string
	return `{parts} / {max}`
end

function BuildInfo.trimName(text: string, maxLength: number): string
	local trimmed = string.match(text, "^%s*(.-)%s*$") or ""
	return string.sub(trimmed, 1, maxLength)
end

function BuildInfo.slotLabel(slot: number, name: string?): string
	return `{slot}{SLOT_SEPARATOR}{name or EMPTY_SLOT}`
end

function BuildInfo.fitScale(available: number, natural: number, minScale: number): number
	if natural <= 0 or available ~= available then
		return 1
	end
	return math.clamp(available / natural, minScale, 1)
end

return table.freeze(BuildInfo)
