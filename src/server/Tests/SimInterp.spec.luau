--!strict
-- CHANGED (Rocket shudder): tests for Shared/Sim/SimInterp, the render-time interpolation of the pilot's fixed-step
-- simulation, including a frame-timing run of FlightController's accumulator loop at 60 / 144 / 240 Hz and with
-- uneven frame times: the drawn state must advance by exactly each frame's dt (no repeats, no double steps).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local SimInterp = require(ReplicatedStorage.Shared.Sim.SimInterp)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

--============================================================================
-- Tunables
--============================================================================
local STEP = 1 / GameConfig.SIM_RATE
local MAX_STEPS = GameConfig.SIM_MAX_STEPS_PER_FRAME
local MAX_GAP = STEP * 1.5 -- as FlightController's INTERP_MAX_GAP
local SPEED = 300 -- m/s along +x (lower atmosphere)
local RADIUS = 6e5 -- m from the body's centre (doubles, I1)
local FRAMES = 600
--============================================================================

type State = SimInterp.State

local function stateAt(ut: number, bodyId: number?): State
	return {
		bodyId = bodyId or 1,
		pos = Vec3d.new(RADIUS + SPEED * ut, 0, 0),
		vel = Vec3d.new(SPEED, 0, 0),
		rot = CFrame.Angles(0, 0, 0.1 * ut),
		angVel = Vector3.new(0, 0, 0.1),
		throttle = 1,
		flags = 0,
		ut = ut,
	}
end

-- One fixed step of a craft moving at SPEED, mutating the state in place (as FlightModel.step does).
local function stepInPlace(s: State)
	s.ut += STEP
	s.pos = Vec3d.new(RADIUS + SPEED * s.ut, 0, 0)
	s.rot = CFrame.Angles(0, 0, 0.1 * s.ut)
end

-- Deterministic frame times: base period, +-jitter (fraction of it) of timing noise, an extra period every hitchEvery.
local function frameTimes(hz: number, jitter: number, hitchEvery: number): { number }
	local seed = 12345
	local times = {}
	for k = 1, FRAMES do
		seed = (seed * 1103515245 + 12345) % 2147483648
		local dt = (1 + (seed / 2147483648 * 2 - 1) * jitter) / hz
		if hitchEvery > 0 and k % hitchEvery == 0 then
			dt += 1 / hz
		end
		times[k] = dt
	end
	return times
end

-- FlightController's frame: render (PocketController reads the provider), then PreSimulation (accumulator loop).
-- Returns the drawn UT of each frame, interpolated or (old) the latest step's.
local function run(dts: { number }, interpolate: boolean): ({ number }, { number })
	local cur = stateAt(0)
	local prev = SimInterp.newState()
	local prevOf: State? = nil
	local out = SimInterp.newState()
	local accumulator = 0
	local drawnUT, drawnX = {}, {}
	for k, dt in dts do
		local drawn: State
		if interpolate and prevOf == cur then
			drawn = SimInterp.blendInto(out, prev, cur, SimInterp.alpha(accumulator, STEP), MAX_GAP)
		else
			drawn = SimInterp.copyInto(out, cur)
		end
		drawnUT[k] = drawn.ut
		drawnX[k] = drawn.pos.x - RADIUS
		accumulator += dt
		local steps = 0
		while accumulator >= STEP and steps < MAX_STEPS do
			SimInterp.copyInto(prev, cur)
			prevOf = cur
			stepInPlace(cur)
			accumulator -= STEP
			steps += 1
		end
		if steps >= MAX_STEPS then
			accumulator = 0
		end
	end
	return drawnUT, drawnX
end

return function(t: TestKit.Context)
	t.test("alpha is the accumulator's fraction of a step, clamped", function()
		t.expectNear(SimInterp.alpha(0, STEP), 0, 1e-12)
		t.expectNear(SimInterp.alpha(STEP / 4, STEP), 0.25, 1e-12)
		t.expectNear(SimInterp.alpha(STEP * 3, STEP), 1, 1e-12)
		t.expectNear(SimInterp.alpha(-1, STEP), 0, 1e-12)
		t.expectNear(SimInterp.alpha(1, 0), 1, 1e-12)
	end)

	t.test("blends position, velocity, rotation, throttle and UT between two steps", function()
		local a, b = stateAt(10), stateAt(10 + STEP)
		a.throttle, b.throttle = 0, 1
		b.vel = Vec3d.new(SPEED + 6, 0, 0)
		b.flags = 2
		local out, blended = SimInterp.blendInto(SimInterp.newState(), a, b, 0.25, MAX_GAP)
		t.expectTrue(blended, "blended")
		t.expectNear(out.ut, 10 + STEP * 0.25, 1e-12)
		t.expectNear(out.pos.x, RADIUS + SPEED * (10 + STEP * 0.25), 1e-6, "doubles")
		t.expectNear(out.vel.x, SPEED + 1.5, 1e-9)
		t.expectNear(out.throttle, 0.25, 1e-12)
		t.expectEqual(out.flags, 2, "flags from the newer state")
		local _, _, angle = out.rot:ToEulerAnglesXYZ()
		t.expectNear(angle, 0.1 * (10 + STEP * 0.25), 1e-5, "rotation slerped")
	end)

	t.test("copies the newer state across an SOI change, a UT jump or at alpha 1", function()
		local a = stateAt(10)
		local other = stateAt(10 + STEP, 2)
		local out, blended = SimInterp.blendInto(SimInterp.newState(), a, other, 0.5, MAX_GAP)
		t.expectTrue(not blended, "different bodies")
		t.expectEqual(out.bodyId, 2)
		t.expectNear(out.ut, other.ut, 1e-12)
		local resynced = stateAt(10.4) -- a UT resync (UT_RESYNC_THRESHOLD) between the two
		local _, b2 = SimInterp.blendInto(SimInterp.newState(), a, resynced, 0.5, MAX_GAP)
		t.expectTrue(not b2, "gap beyond maxGap")
		local _, b3 = SimInterp.blendInto(SimInterp.newState(), a, a, 0.5, MAX_GAP)
		t.expectTrue(not b3, "same instant")
		local out4, b4 = SimInterp.blendInto(SimInterp.newState(), a, stateAt(10 + STEP), 1, MAX_GAP)
		t.expectTrue(not b4, "alpha 1 is the newer state")
		t.expectNear(out4.ut, 10 + STEP, 1e-12)
	end)

	t.test("copyInto copies by value (the source is mutated in place later)", function()
		local s = stateAt(3)
		local copy = SimInterp.copyInto(SimInterp.newState(), s)
		s.pos.x += 100
		t.expectNear(copy.pos.x, RADIUS + SPEED * 3, 1e-6)
	end)

	-- The frame-timing evidence: interpolated, every drawn frame advances by the previous frame's dt (constant
	-- latency of one step); the old (latest step) drawing repeats frames and doubles steps.
	local cases = {
		{ name = "60 Hz +-3% noise", hz = 60, jitter = 0.03, hitch = 0 },
		{ name = "60 Hz +-10% noise, hitch every 50", hz = 60, jitter = 0.10, hitch = 50 },
		{ name = "144 Hz", hz = 144, jitter = 0.03, hitch = 0 },
		{ name = "240 Hz", hz = 240, jitter = 0.03, hitch = 0 },
		{ name = "75 Hz uneven +-25%", hz = 75, jitter = 0.25, hitch = 0 },
	}
	for _, case in cases do
		t.test(`frame timing, {case.name}: the drawn state advances by each frame's dt`, function()
			local dts = frameTimes(case.hz, case.jitter, case.hitch)
			local uts, xs = run(dts, true)
			local worst = 0
			-- once the first steps are taken (frame 10 on) the drawn UT lags the accumulated time by one step
			for k = 10, #uts do
				local advance = uts[k] - uts[k - 1]
				worst = math.max(worst, math.abs(advance - dts[k - 1]))
				t.expectNear(xs[k], SPEED * uts[k], 1e-6, "position at the drawn UT")
			end
			t.expectTrue(worst < 1e-9, `drawn UT advances by dt (worst {worst})`)
			-- the old drawing, for contrast: frames that repeat the previous one, or jump two steps
			local oldUts = run(dts, false)
			local uneven = 0
			for k = 2, #oldUts do
				local advance = oldUts[k] - oldUts[k - 1]
				if advance < STEP * 0.5 or advance > STEP * 1.5 then
					uneven += 1
				end
			end
			t.expectTrue(uneven > 0, "the latest-step drawing was uneven")
		end)
	end
end
