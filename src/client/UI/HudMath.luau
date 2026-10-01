--!strict
--[[
	HudMath (Phase 11)
	The pure maths behind the KSP-style flight HUD instruments (UI/FlightHUD), kept free of instances so the offline
	Lune spec can check it (src/server/Tests/HudMath.spec.luau):
	  * the odometer altimeter: where each digit wheel stands. The last wheel rolls continuously with the fraction;
	    a higher wheel only rolls while every wheel below it passes 9 -> 0, exactly like a mechanical odometer
	  * the vertical-speed needle: a signed, log-scaled deflection (small climbs are visible, huge ones still fit)
	  * the throttle arc around the navball bezel: how many segments are lit and where each segment sits
	  * the speed display mode (Surface / Orbit) chosen automatically by altitude, like KSP's navball
	  * the heading / pitch texts under the navball

	API:
	  HudMath.wheelPositions(whole, fraction, count) -> { number }
	      odometer wheel positions, most significant first; each is 0..10 (the digit shown at the window's top
	      edge plus how far it has rolled toward the next one; 10 = the trailing 0 of the 0-9-0 strip). `whole` may
	      be negative (its absolute value is shown); values beyond count digits show all nines
	  HudMath.verticalSpeedFraction(verticalSpeed, maxSpeed) -> number
	      -1..1, sign(v) * log10(1 + |v|) / log10(1 + maxSpeed), clamped; NaN -> 0
	  HudMath.litSegments(throttle, count) -> number
	      segments lit for a throttle fraction: 0 only at zero throttle, all only at full throttle
	  HudMath.arcAngle(index, count, startDeg, endDeg) -> number
	      screen angle (degrees, clockwise from +X, y down) of segment `index` (1..count), evenly spread with the
	      first and last segment half a step inside the ends
	  HudMath.arcPoint(angleDeg, radius) -> (x, y)
	      offset from the arc's centre in screen space (y down)
	  HudMath.isOrbitMode(altitude, atmosphereTop?, bodyRadius) -> boolean
	      true above the top of the atmosphere, or above AIRLESS_ORBIT_FRACTION of the radius on airless bodies
	  HudMath.headingText(degrees) -> string    "017°" (whole degrees, 000..359)
	  HudMath.pitchText(degrees) -> string      "+12°" / "-3°" / "0°"
]]

--============================================================================
-- Tunables
--============================================================================
local AIRLESS_ORBIT_FRACTION = 0.05 -- airless bodies: Orbit speed mode above this fraction of the body radius
local DEGREE = "°"
local LIT_EPSILON = 1e-6 -- throttle fractions this close to a segment boundary count as reaching it
--============================================================================

local HudMath = {}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function HudMath.wheelPositions(whole: number, fraction: number, count: number): { number }
	local positions = table.create(count, 0)
	if count <= 0 then
		return positions
	end
	local maxValue = 10 ^ count - 1
	local value: number
	if not isFinite(whole) then
		value = 0
	else
		local magnitude = math.floor(math.abs(whole))
		if magnitude > maxValue then
			value = maxValue -- more digits than wheels: all nines, not rolling
		else
			local f = if isFinite(fraction) then math.clamp(fraction, 0, 1 - 1e-9) else 0
			value = magnitude + f
		end
	end
	for k = 0, count - 1 do
		local unit = 10 ^ k
		local digit = math.floor(value / unit) % 10
		local roll: number
		if k == 0 then
			roll = value - math.floor(value)
		else
			-- a higher wheel turns only while everything below it rolls from all nines to zero
			roll = math.max(0, (value % unit) - (unit - 1))
		end
		positions[count - k] = digit + roll
	end
	return positions
end

function HudMath.verticalSpeedFraction(verticalSpeed: number, maxSpeed: number): number
	if verticalSpeed ~= verticalSpeed or maxSpeed <= 0 then
		return 0
	end
	local magnitude = math.log10(1 + math.min(math.abs(verticalSpeed), 1e300)) / math.log10(1 + maxSpeed)
	local f = math.min(magnitude, 1)
	return if verticalSpeed < 0 then -f else f
end

function HudMath.litSegments(throttle: number, count: number): number
	if throttle ~= throttle or throttle <= 0 then
		return 0
	end
	local t = math.min(throttle, 1)
	return math.clamp(math.ceil(t * count - LIT_EPSILON), 1, count)
end

function HudMath.arcAngle(index: number, count: number, startDeg: number, endDeg: number): number
	local step = (endDeg - startDeg) / count
	return startDeg + step * (index - 0.5)
end

function HudMath.arcPoint(angleDeg: number, radius: number): (number, number)
	local a = math.rad(angleDeg)
	return math.cos(a) * radius, math.sin(a) * radius
end

function HudMath.isOrbitMode(altitude: number, atmosphereTop: number?, bodyRadius: number): boolean
	local threshold = if atmosphereTop then atmosphereTop else bodyRadius * AIRLESS_ORBIT_FRACTION
	return altitude > threshold
end

function HudMath.headingText(degrees: number): string
	local d = if isFinite(degrees) then math.floor(degrees + 0.5) % 360 else 0
	return string.format("%03d", d) .. DEGREE
end

function HudMath.pitchText(degrees: number): string
	local d = if isFinite(degrees) then math.floor(degrees + 0.5) else 0
	if d > 0 then
		return "+" .. d .. DEGREE
	end
	return tostring(d) .. DEGREE
end

return table.freeze(HudMath)
