--!strict
--[[
	SimInterp (CHANGED (Rocket shudder): new)
	Render-time interpolation of a fixed-step simulation (the pilot's FlightModel at FlightModel.STEP, 60 Hz).

	Steamy: "my rocket keeps moving back aswell like shuddering". FlightController steps its craft at a fixed 60 Hz
	with an accumulator, but the pocket frame (and with it the terrain, scaled space, sky, effects drift and the camera
	up) followed the LAST step's state. Rendering at 144 Hz repeated that state on 58% of frames; at 60 Hz the
	accumulator hovers at the step boundary, so frame-time noise gives 0-step and 2-step frames (the ground moved 0,
	10, 0, 10 m per frame at 300 m/s while the engine-simulated smoke moved 5 m every frame): the rocket jerked back
	and forth against the world. Now the render state is the state between the previous and the current step at the
	accumulator's fraction (alpha = accumulator / STEP): it advances by exactly the frame's dt every frame, at a
	constant latency of one step (16.7 ms), and it never overshoots (no extrapolation into the ground).

	API (pure; Lune-tested by SimInterp.spec):
	  SimInterp.newState() -> State                          a zeroed state to snapshot / blend into
	  SimInterp.copyInto(out, s) -> out                      copies every field (Vec3d by value)
	  SimInterp.alpha(accumulator, step) -> number           accumulator / step, clamped to [0, 1]
	  SimInterp.blendInto(out, prev, cur, alpha, maxGap) -> (out, blended)
	      out = prev + (cur - prev) * alpha (positions and velocities in doubles, rotation slerped, UT too); flags
	      and bodyId from cur. It copies cur instead (blended = false) when the two states do not belong to one
	      continuous step: different bodies (SOI change), or cur.ut - prev.ut outside (0, maxGap] (a UT resync, a
	      replaced state).
]]

local Vec3d = require(script.Parent.Parent.Math.Vec3d)

--============================================================================
-- Tunables
--============================================================================
local MIN_GAP = 1e-9 -- s; states closer in UT than this are treated as the same instant (no blend)
--============================================================================

export type State = {
	bodyId: number,
	pos: Vec3d.Vec3d,
	vel: Vec3d.Vec3d,
	rot: CFrame,
	angVel: Vector3,
	throttle: number,
	flags: number,
	ut: number,
}

local SimInterp = {}

function SimInterp.newState(): State
	return {
		bodyId = 0,
		pos = Vec3d.zero(),
		vel = Vec3d.zero(),
		rot = CFrame.identity,
		angVel = Vector3.zero,
		throttle = 0,
		flags = 0,
		ut = 0,
	}
end

-- Copies every field of `s` into `out` (positions and velocities by value: `s` may be mutated in place later).
function SimInterp.copyInto(out: State, s: State): State
	out.bodyId = s.bodyId
	Vec3d.copyInto(out.pos, s.pos)
	Vec3d.copyInto(out.vel, s.vel)
	out.rot = s.rot
	out.angVel = s.angVel
	out.throttle = s.throttle
	out.flags = s.flags
	out.ut = s.ut
	return out
end

-- The render fraction between the previous and the current step.
function SimInterp.alpha(accumulator: number, step: number): number
	if step <= 0 then
		return 1
	end
	return math.clamp(accumulator / step, 0, 1)
end

-- See the header. Returns `out` and whether it was blended (false = a copy of `cur`).
function SimInterp.blendInto(out: State, prev: State, cur: State, alpha: number, maxGap: number): (State, boolean)
	local gap = cur.ut - prev.ut
	if prev.bodyId ~= cur.bodyId or gap < MIN_GAP or gap > maxGap or alpha >= 1 then
		return SimInterp.copyInto(out, cur), false
	end
	local t = math.max(alpha, 0)
	local p, q = prev.pos, cur.pos
	Vec3d.set(out.pos, p.x + (q.x - p.x) * t, p.y + (q.y - p.y) * t, p.z + (q.z - p.z) * t)
	local u, v = prev.vel, cur.vel
	Vec3d.set(out.vel, u.x + (v.x - u.x) * t, u.y + (v.y - u.y) * t, u.z + (v.z - u.z) * t)
	out.rot = prev.rot:Lerp(cur.rot, t)
	out.angVel = prev.angVel:Lerp(cur.angVel, t)
	out.throttle = prev.throttle + (cur.throttle - prev.throttle) * t
	out.flags = cur.flags
	out.bodyId = cur.bodyId
	out.ut = prev.ut + gap * t
	return out, true
end

return table.freeze(SimInterp)
