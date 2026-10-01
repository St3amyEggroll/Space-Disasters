--!strict
--[[
	Format (Phase 11)
	Shared/Util/UnitFormat with the player's units setting (Settings.current().units). UI code formats every shown
	quantity through here, so switching units in the settings changes every readout; redraw static text in
	onUnitsChanged.

	API:
	  Format.units() -> UnitFormat.Units
	  Format.distance(m) -> string                       "950 m", "12.4 km" | "3,117 ft", "7.70 mi"
	  Format.speed(mps) -> string                        "123.4 m/s" | "404.9 ft/s"
	  Format.altitudeParts(m) -> (whole, unit, fraction) odometer parts (see UnitFormat.altitudeParts)
	  Format.duration(s) -> string                       "1h 02m 05s"
	  Format.mass(kg) -> string                          "4.15 t" | "9,149 lb"
	  Format.percent(fraction) -> string                 "46%"
	  Format.thousands(n) -> string                      "1,234,567"
	  Format.onUnitsChanged(fn(units)) -> RBXScriptConnection
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UnitFormat = require(ReplicatedStorage.Shared.Util.UnitFormat)
local Settings = require(script.Parent.Parent.Settings.Settings)

--============================================================================
-- Tunables
--============================================================================
local UNITS_FIELD = "units" -- the Settings field that picks the unit system
--============================================================================

local Format = {}

function Format.units(): UnitFormat.Units
	return Settings.current().units
end

function Format.distance(m: number): string
	return UnitFormat.distance(m, Format.units())
end

function Format.speed(mps: number): string
	return UnitFormat.speed(mps, Format.units())
end

function Format.altitudeParts(m: number): (number, string, number)
	return UnitFormat.altitudeParts(m, Format.units())
end

function Format.duration(s: number): string
	return UnitFormat.duration(s)
end

function Format.mass(kg: number): string
	return UnitFormat.mass(kg, Format.units())
end

function Format.percent(fraction: number): string
	return UnitFormat.percent(fraction)
end

function Format.thousands(n: number): string
	return UnitFormat.thousands(n)
end

function Format.onUnitsChanged(fn: (units: UnitFormat.Units) -> ()): RBXScriptConnection
	return Settings.onChanged(function(field: string)
		if field == UNITS_FIELD then
			fn(Format.units())
		end
	end)
end

return table.freeze(Format)
