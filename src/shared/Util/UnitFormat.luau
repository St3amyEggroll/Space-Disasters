--!strict
--[[
	UnitFormat (Phase 11)
	Number formatting for the HUD, map and builder, in metric or imperial units, KSP style: thousands separators,
	whole base units ("950 m", "3,117 ft") and about three significant figures once a bigger unit takes over
	("12.4 km", "1.25 Mm", "7.70 mi"). Pure Luau (tested offline); the client's UI/Format wraps it with the
	player's units setting, so UI code normally calls that instead.

	API (units: "Metric" | "Imperial"; anything else counts as metric):
	  UnitFormat.distance(m, units)       "5.3 m", "950 m", "12.4 km", "1.25 Mm" | "3,117 ft", "7.70 mi"
	  UnitFormat.speed(mps, units)        "123.4 m/s", "2,345.7 m/s" | "404.9 ft/s" (always one decimal)
	  UnitFormat.altitudeParts(m, units) -> (whole: number, unit: string, fraction: number)
	                                      for an odometer: whole = the value in `unit` truncated toward zero
	                                      (signed); metric m up to ODOMETER_MAX then km (then Mm, Gm), imperial ft
	                                      up to ODOMETER_MAX then mi; fraction 0..1 = how far the last digit
	                                      wheel has rolled toward the next one
	  UnitFormat.duration(s)              "12s", "4m 05s", "1h 02m 05s", "3d 04h 05m" (seconds truncated)
	  UnitFormat.mass(kg, units)          "0.85 t", "4.15 t", "12.4 t", "1,250 t" | "9,149 lb"
	  UnitFormat.percent(fraction)        "46%"
	  UnitFormat.thousands(n)             "1,234,567" (rounded to a whole number)
	Negative values keep their sign ("-12.4 km") unless they round to zero; non-finite input gives NOT_AVAILABLE.
]]

--============================================================================
-- Tunables
--============================================================================
local THOUSANDS_SEPARATOR = ","
local NOT_AVAILABLE = "--" -- shown for NaN / infinite input
local METRES_PER_FOOT = 0.3048
local METRES_PER_MILE = 1609.344
local KG_PER_POUND = 0.45359237
local FEET_BELOW_MILES = 5280 -- imperial distances under one mile are shown in whole feet
local BASE_DECIMAL_BELOW = 9.95 -- base-unit distances below this get one decimal ("5.3 m")
local ODOMETER_MAX = 999999 -- the altimeter switches to the next unit above this
local MAX_DURATION_DAYS = 99999 -- longer durations are clamped
local METRIC_DISTANCE_UNITS: { Step } = {
	{ size = 1e3, suffix = "km" },
	{ size = 1e6, suffix = "Mm" },
	{ size = 1e9, suffix = "Gm" },
}
local METRIC_ODOMETER_UNITS: { Step } = {
	{ size = 1, suffix = "m" },
	{ size = 1e3, suffix = "km" },
	{ size = 1e6, suffix = "Mm" },
	{ size = 1e9, suffix = "Gm" },
}
local IMPERIAL_ODOMETER_UNITS: { Step } = {
	{ size = METRES_PER_FOOT, suffix = "ft" },
	{ size = METRES_PER_MILE, suffix = "mi" },
}
--============================================================================

export type Units = "Metric" | "Imperial"

type Step = { size: number, suffix: string } -- size: metres per unit

local UnitFormat = {}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

-- "1234567" -> "1,234,567"
local function groupDigits(digits: string): string
	local result = digits
	while true do
		local replaced, count = string.gsub(result, "^(%d+)(%d%d%d)", "%1" .. THOUSANDS_SEPARATOR .. "%2")
		result = replaced
		if count == 0 then
			return result
		end
	end
end

-- A non-negative value with a fixed number of decimals and thousands separators.
local function fixed(value: number, decimals: number): string
	local text = string.format("%." .. decimals .. "f", value)
	local whole, rest = string.match(text, "^(%d+)(.*)$")
	if whole == nil or rest == nil then
		return text
	end
	return groupDigits(whole) .. rest
end

-- About three significant figures for a non-negative value below 999.5; separators above.
local function significant(value: number): string
	if value >= 99.95 then
		return fixed(value, 0)
	elseif value >= 9.995 then
		return fixed(value, 1)
	end
	return fixed(value, 2)
end

-- A whole base unit ("950", "3,117"), or one decimal for small values ("5.3").
local function baseUnit(value: number): string
	return if value < BASE_DECIMAL_BELOW then fixed(value, 1) else fixed(value, 0)
end

-- Formats |value| with `formatAbs`, then puts the sign back unless the text shows zero.
local function signed(value: number, formatAbs: (number) -> string): string
	if not isFinite(value) then
		return NOT_AVAILABLE
	end
	local text = formatAbs(math.abs(value))
	if value < 0 and string.find(text, "[1-9]") then
		return "-" .. text
	end
	return text
end

function UnitFormat.thousands(n: number): string
	return signed(n, function(abs: number): string
		return fixed(abs, 0)
	end)
end

function UnitFormat.distance(m: number, units: Units): string
	return signed(m, function(abs: number): string
		if units == "Imperial" then
			local feet = abs / METRES_PER_FOOT
			if feet < FEET_BELOW_MILES - 0.5 then
				return baseUnit(feet) .. " ft"
			end
			local miles = abs / METRES_PER_MILE
			return significant(miles) .. " mi"
		end
		if abs < 999.5 then
			return baseUnit(abs) .. " m"
		end
		for index, step in METRIC_DISTANCE_UNITS do
			local scaled = abs / step.size
			if scaled < 999.5 or index == #METRIC_DISTANCE_UNITS then
				return significant(scaled) .. " " .. step.suffix
			end
		end
		return NOT_AVAILABLE
	end)
end

function UnitFormat.speed(mps: number, units: Units): string
	return signed(mps, function(abs: number): string
		if units == "Imperial" then
			return fixed(abs / METRES_PER_FOOT, 1) .. " ft/s"
		end
		return fixed(abs, 1) .. " m/s"
	end)
end

function UnitFormat.altitudeParts(m: number, units: Units): (number, string, number)
	local chain: { Step } = if units == "Imperial" then IMPERIAL_ODOMETER_UNITS else METRIC_ODOMETER_UNITS
	if not isFinite(m) then
		return 0, chain[1].suffix, 0
	end
	local abs = math.abs(m)
	for index, step in chain do
		local scaled = abs / step.size
		local whole = math.floor(scaled)
		if whole <= ODOMETER_MAX or index == #chain then
			local fraction = scaled - whole
			if whole == 0 or m >= 0 then
				return whole, step.suffix, fraction
			end
			return -whole, step.suffix, fraction
		end
	end
	return 0, chain[1].suffix, 0
end

function UnitFormat.duration(s: number): string
	return signed(s, function(abs: number): string
		local total = math.floor(math.min(abs, MAX_DURATION_DAYS * 86400 + 86399))
		local days = total // 86400
		local hours = (total % 86400) // 3600
		local minutes = (total % 3600) // 60
		local seconds = total % 60
		if days > 0 then
			return string.format("%dd %02dh %02dm", days, hours, minutes)
		elseif hours > 0 then
			return string.format("%dh %02dm %02ds", hours, minutes, seconds)
		elseif minutes > 0 then
			return string.format("%dm %02ds", minutes, seconds)
		end
		return string.format("%ds", seconds)
	end)
end

function UnitFormat.mass(kg: number, units: Units): string
	return signed(kg, function(abs: number): string
		if units == "Imperial" then
			return fixed(abs / KG_PER_POUND, 0) .. " lb"
		end
		return significant(abs / 1000) .. " t"
	end)
end

function UnitFormat.percent(fraction: number): string
	return signed(fraction, function(abs: number): string
		return fixed(abs * 100, 0) .. "%"
	end)
end

UnitFormat.NOT_AVAILABLE = NOT_AVAILABLE

return table.freeze(UnitFormat)
