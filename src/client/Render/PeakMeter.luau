--!strict
--[[
	PeakMeter (CHANGED (Far layer smooth): new)
	The worst and the average of a per-frame cost over the last second or so: an average (DebugOverlay's timings)
	hides the one slow frame that makes the rocket and the ground hitch, so the F3 lines show the peak too. Pure (no
	services, the caller passes os.clock()), checked by the Lune spec (src/server/Tests/FarLayer.spec.luau).

	Two windows of `window` seconds: the one filling now and the last full one; peak() is the larger maximum of the
	two, so a spike stays on the line for one to two windows. average() is the last full window's mean per sample.

		PeakMeter.new(window): Meter
		PeakMeter.add(meter, now, value)          one sample (e.g. ms this frame)
		PeakMeter.peak(meter, now): number        the largest sample of the last one to two windows (0: none)
		PeakMeter.average(meter, now): number     the mean of the last full window (the filling one until then)
		PeakMeter.count(meter, now): number       samples per second in the last full window (e.g. writes)
]]

local PeakMeter = {}

export type Meter = {
	window: number, -- s
	start: number, -- os.clock() when the filling window began (-1: never sampled)
	max: number, -- the filling window's largest sample
	sum: number,
	samples: number,
	lastMax: number, -- the last full window's
	lastMean: number,
	lastRate: number, -- its samples per second
	full: boolean, -- a full window has passed
}

function PeakMeter.new(window: number): Meter
	return {
		window = window,
		start = -1,
		max = 0,
		sum = 0,
		samples = 0,
		lastMax = 0,
		lastMean = 0,
		lastRate = 0,
		full = false,
	}
end

-- Closes the filling window once it is `window` old (a gap of more than two windows forgets the last one too).
local function roll(m: Meter, now: number)
	if m.start < 0 then
		m.start = now
		return
	end
	local age = now - m.start
	if age < m.window then
		return
	end
	if age >= 2 * m.window then
		m.lastMax, m.lastMean, m.lastRate = 0, 0, 0 -- nothing measured in the window before this one
	else
		m.lastMax = m.max
		m.lastMean = if m.samples > 0 then m.sum / m.samples else 0
		m.lastRate = m.samples / age
	end
	m.full = true
	m.start, m.max, m.sum, m.samples = now, 0, 0, 0
end

function PeakMeter.add(m: Meter, now: number, value: number)
	roll(m, now)
	m.max = math.max(m.max, value)
	m.sum += value
	m.samples += 1
end

function PeakMeter.peak(m: Meter, now: number): number
	roll(m, now)
	return math.max(m.max, m.lastMax)
end

function PeakMeter.average(m: Meter, now: number): number
	roll(m, now)
	if m.full then
		return m.lastMean
	end
	return if m.samples > 0 then m.sum / m.samples else 0
end

function PeakMeter.count(m: Meter, now: number): number
	roll(m, now)
	return m.lastRate
end

return table.freeze(PeakMeter)
