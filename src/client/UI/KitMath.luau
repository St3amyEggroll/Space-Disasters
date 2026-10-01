--!strict
--[[
	KitMath (Phase 11)
	The pure maths behind UI/Kit: slider values (snapping to a step without float noise, value <-> track fraction),
	the screen scale of a Kit screen, and how long a toast stays up. No instances, no services, so the offline Lune
	spec tests it (src/server/Tests/KitMath.spec.luau).

	API:
	  KitMath.clamp01(x) -> number                       0..1; NaN -> 0
	  KitMath.snap(value, min, max, step) -> number      clamped into min..max and rounded to the nearest
	                                                     min + k * step (step <= 0: no rounding); NaN -> min; the
	                                                     result carries no float noise (0.1 + 0.2 snaps to 0.3)
	  KitMath.fraction(value, min, max) -> number        where value sits on min..max, 0..1 (0 when max <= min)
	  KitMath.fromFraction(f, min, max, step) -> number  the snapped value at track fraction f
	  KitMath.screenScale(width, height, userScale, designWidth, designHeight, minFit, maxFit) -> number
	                                                     a design canvas fitted to the screen (the smaller of the two
	                                                     ratios, clamped to minFit..maxFit) times the player's UI size;
	                                                     a zero-sized screen (not laid out yet) counts as fit 1
	  KitMath.toastSeconds(text, base, perChar, max) -> number  base + perChar per character, at most max
]]

--============================================================================
-- Tunables
--============================================================================
local SNAP_DECIMALS = 1e9 -- snapped values are rounded to 1 / SNAP_DECIMALS, which removes binary float noise
local DEFAULT_USER_SCALE = 1 -- used when the UI size setting is not a usable number
--============================================================================

local KitMath = {}

local function isFinite(x: number): boolean
	return x == x and x ~= math.huge and x ~= -math.huge
end

function KitMath.clamp01(x: number): number
	if x ~= x then
		return 0
	end
	return math.clamp(x, 0, 1)
end

function KitMath.snap(value: number, min: number, max: number, step: number): number
	if value ~= value then
		return min
	end
	local clamped = math.clamp(value, min, math.max(min, max))
	if step <= 0 or not isFinite(step) then
		return clamped
	end
	local steps = math.floor((clamped - min) / step + 0.5)
	local snapped = min + steps * step
	snapped = math.floor(snapped * SNAP_DECIMALS + 0.5) / SNAP_DECIMALS -- dividing gives the double nearest the decimal
	return math.clamp(snapped, min, math.max(min, max))
end

function KitMath.fraction(value: number, min: number, max: number): number
	if max <= min then
		return 0
	end
	return KitMath.clamp01((value - min) / (max - min))
end

function KitMath.fromFraction(f: number, min: number, max: number, step: number): number
	return KitMath.snap(min + KitMath.clamp01(f) * (max - min), min, max, step)
end

function KitMath.screenScale(
	width: number,
	height: number,
	userScale: number,
	designWidth: number,
	designHeight: number,
	minFit: number,
	maxFit: number
): number
	local fit = 1
	if width >= 1 and height >= 1 and designWidth > 0 and designHeight > 0 then
		fit = math.clamp(math.min(width / designWidth, height / designHeight), minFit, maxFit)
	end
	local user = if isFinite(userScale) and userScale > 0 then userScale else DEFAULT_USER_SCALE
	return fit * user
end

function KitMath.toastSeconds(text: string, base: number, perChar: number, max: number): number
	return math.min(base + #text * perChar, max)
end

return table.freeze(KitMath)
