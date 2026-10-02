--!strict
-- Tests for Shared/Net/StateBuffer (Phase 3): interpolation, extrapolation for up to 0.25 s, then freeze.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local StateBuffer = require(ReplicatedStorage.Shared.Net.StateBuffer)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type State = StateBuffer.State

-- A craft moving at 100 m/s along +x, 1e6 m from its body's centre (doubles, I1).
local function at(ut: number, bodyId: number?): State
	return {
		bodyId = bodyId or 1,
		pos = Vec3d.new(1e6 + 100 * ut, 0, 0),
		vel = Vec3d.new(100, 0, 0),
		rot = CFrame.identity,
		angVel = Vector3.zero,
		throttle = 0.5,
		flags = 0,
		ut = ut,
	}
end

local function stream(from: number, to: number, rate: number): { State }
	local states = {}
	local ut = from
	while ut <= to + 1e-9 do
		StateBuffer.push(states, at(ut))
		ut += 1 / rate
	end
	return states
end

return function(t: TestKit.Context)
	t.test("interpolates between the two states around the sample time", function()
		local states = stream(10, 11, 20)
		local s, mode = StateBuffer.sample(states, 10.525)
		t.expectEqual(mode, "Interpolated")
		t.expectNear((s :: State).pos.x, 1e6 + 1052.5, 1e-6)
		t.expectNear((s :: State).ut, 10.525, 1e-9)
	end)

	t.test("before the oldest state it holds the oldest", function()
		local states = stream(10, 11, 20)
		local s, mode = StateBuffer.sample(states, 5)
		t.expectEqual(mode, "Held")
		t.expectEqual((s :: State).ut, 10)
	end)

	t.test("starved: extrapolates with velocity for up to 0.25 s, then freezes", function()
		local states = stream(10, 11, 20)
		local s, mode = StateBuffer.sample(states, 11.2)
		t.expectEqual(mode, "Extrapolated")
		t.expectNear((s :: State).pos.x, 1e6 + 1120, 1e-6)
		local frozen, frozenMode = StateBuffer.sample(states, 13)
		t.expectEqual(frozenMode, "Frozen")
		t.expectNear((frozen :: State).pos.x, 1e6 + 100 * (11 + GameConfig.EXTRAPOLATE_MAX), 1e-6)
		local later = StateBuffer.sample(states, 20)
		t.expectNear((later :: State).pos.x, (frozen :: State).pos.x, 1e-9) -- stays frozen
	end)

	t.test("extrapolation turns with the angular velocity", function()
		local s = at(0)
		s.angVel = Vector3.new(0, math.pi, 0) -- half a turn per second
		local moved = StateBuffer.extrapolate(s, 0.25)
		local expected = CFrame.fromAxisAngle(Vector3.yAxis, math.pi / 4)
		t.expectNear((moved.rot.LookVector - expected.LookVector).Magnitude, 0, 1e-5)
	end)

	t.test("slow streams extrapolate about one packet interval before freezing", function()
		t.expectNear(StateBuffer.extrapolationLimit(stream(0, 1, 20)), GameConfig.EXTRAPOLATE_MAX, 1e-9)
		t.expectNear(StateBuffer.extrapolationLimit(stream(0, 4, 2)), 0.5 * 1.25, 1e-9)
		t.expectNear(StateBuffer.extrapolationLimit(stream(0, 10, 0.5)), GameConfig.EXTRAPOLATE_MAX_SLOW, 1e-9)
		local slow = stream(0, 4, 2)
		local _, mode = StateBuffer.sample(slow, 4.4)
		t.expectEqual(mode, "Extrapolated")
	end)

	t.test("late, duplicate and reordered packets are dropped", function()
		local states = stream(10, 10.5, 20)
		local count = #states
		t.expectTrue(not StateBuffer.push(states, at(10.2)))
		t.expectTrue(not StateBuffer.push(states, at(10.5)))
		t.expectEqual(#states, count)
		t.expectTrue(StateBuffer.push(states, at(10.6)))
	end)

	t.test("the buffer keeps only the newest states", function()
		local states = stream(0, 10, 20)
		t.expectEqual(#states, StateBuffer.DEFAULT_CAPACITY)
		t.expectNear(states[#states].ut, 10, 1e-6)
	end)

	t.test("never blends across an SOI change", function()
		local states = {}
		StateBuffer.push(states, at(0, 1))
		StateBuffer.push(states, at(1, 2))
		local s = StateBuffer.sample(states, 0.5)
		t.expectEqual((s :: State).bodyId, 2)
		t.expectEqual((s :: State).ut, 1)
	end)

	-- CHANGED (Deploy fix)
	t.test("lead carries a delayed sample to the present, capped at maxLead", function()
		local states = stream(10, 11, 20)
		local delay = GameConfig.INTERP_DELAY
		local sampled = StateBuffer.sample(states, 10.9 - delay) :: State
		local led = StateBuffer.lead(sampled, 10.9, delay)
		t.expectNear(led.pos.x, 1e6 + 100 * 10.9, 1e-6)
		t.expectNear(led.ut, 10.9, 1e-9)
		-- a stale (frozen) state is led by maxLead at most
		local stale = StateBuffer.lead(at(5), 10.9, delay)
		t.expectNear(stale.ut, 5 + delay, 1e-9)
		-- a state already at (or after) the present is unchanged
		t.expectEqual(StateBuffer.lead(at(11), 10.9, delay).ut, 11)
	end)

	t.test("an empty buffer has no state", function()
		local s, mode = StateBuffer.sample({}, 1)
		t.expectTrue(s == nil and mode == nil)
	end)
end
