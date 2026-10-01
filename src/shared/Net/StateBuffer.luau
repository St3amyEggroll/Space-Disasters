--!strict
--[[
	StateBuffer (Phase 3, spec 7.7 "Interpolation")
	Pure buffering and sampling of streamed craft states, used by RemoteCraftRenderer (cosmetic copies, markers,
	puppets) and through it by PocketController (passengers' pocket frame). Pure so Lune can test it.

	sample(states, ut, maxExtrapolate):
	  * ut inside the buffer        -> interpolated between the two states around it ("Interpolated")
	  * ut before the oldest state  -> the oldest state ("Held")
	  * ut after the newest state   -> extrapolated with velocity / angular velocity for up to maxExtrapolate
	                                   seconds ("Extrapolated"), then frozen at that pose ("Frozen")
	Across an SOI change (two states with different bodies) it never blends: it takes the newer state.

	extrapolationLimit(states): EXTRAPOLATE_MAX (0.25 s) for a normal 20 Hz stream. Slow streams (the 2 Hz / 0.5 Hz
	interest tiers, or a craft degraded by the bandwidth budget) are always "starved" between packets, so their
	limit grows with the observed packet interval, up to EXTRAPOLATE_MAX_SLOW.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)
local Protocol = require(script.Parent.Protocol)

--============================================================================
-- Tunables
--============================================================================
local EXTRAPOLATE_MAX = GameConfig.EXTRAPOLATE_MAX -- s
local EXTRAPOLATE_MAX_SLOW = GameConfig.EXTRAPOLATE_MAX_SLOW -- s
local SLOW_INTERVAL_FACTOR = 1.25 -- slow streams extrapolate this many packet intervals before freezing
local DEFAULT_CAPACITY = 40 -- states kept per craft (2 s at 20 Hz)
--============================================================================

export type State = Protocol.State
export type Mode = "Interpolated" | "Held" | "Extrapolated" | "Frozen"

local StateBuffer = {}

StateBuffer.DEFAULT_CAPACITY = DEFAULT_CAPACITY

-- Appends a state; returns false (and keeps the buffer) when it is not newer than the newest one
-- (unreliable packets may arrive late or twice).
function StateBuffer.push(states: { State }, state: State, capacity: number?): boolean
	local last = states[#states]
	if last and state.ut <= last.ut then
		return false
	end
	table.insert(states, state)
	local limit = capacity or DEFAULT_CAPACITY
	while #states > limit do
		table.remove(states, 1)
	end
	return true
end

function StateBuffer.lerp(a: State, b: State, t: number): State
	return {
		bodyId = a.bodyId,
		pos = Vec3d.lerp(a.pos, b.pos, t),
		vel = Vec3d.lerp(a.vel, b.vel, t),
		rot = a.rot:Lerp(b.rot, t),
		angVel = a.angVel:Lerp(b.angVel, t),
		throttle = a.throttle + (b.throttle - a.throttle) * t,
		flags = if t < 0.5 then a.flags else b.flags,
		ut = a.ut + (b.ut - a.ut) * t,
	}
end

-- Moves a state forward by dt seconds with its velocity and angular velocity (universe axes).
function StateBuffer.extrapolate(s: State, dt: number): State
	local angle = s.angVel.Magnitude * dt
	local rot = if angle > 1e-9 then CFrame.fromAxisAngle(s.angVel.Unit, angle) * s.rot else s.rot
	return {
		bodyId = s.bodyId,
		pos = Vec3d.addScaled(s.pos, s.vel, dt),
		vel = s.vel,
		rot = rot,
		angVel = s.angVel,
		throttle = s.throttle,
		flags = s.flags,
		ut = s.ut + dt,
	}
end

-- How far past the newest state this buffer may be extrapolated before it freezes.
function StateBuffer.extrapolationLimit(states: { State }): number
	local count = #states
	if count < 2 then
		return EXTRAPOLATE_MAX
	end
	local interval = states[count].ut - states[count - 1].ut
	return math.clamp(interval * SLOW_INTERVAL_FACTOR, EXTRAPOLATE_MAX, EXTRAPOLATE_MAX_SLOW)
end

--[[
	The state at `ut` (see the header). maxExtrapolate defaults to extrapolationLimit(states).
	Returns nil for an empty buffer.
]]
function StateBuffer.sample(states: { State }, ut: number, maxExtrapolate: number?): (State?, Mode?)
	local count = #states
	if count == 0 then
		return nil, nil
	end
	if ut <= states[1].ut then
		return states[1], "Held"
	end
	local newest = states[count]
	if ut <= newest.ut then
		for index = count - 1, 1, -1 do
			local a, b = states[index], states[index + 1]
			if ut >= a.ut then
				if a.bodyId ~= b.bodyId then
					return b, "Interpolated"
				end
				local span = b.ut - a.ut
				return StateBuffer.lerp(a, b, if span > 0 then (ut - a.ut) / span else 1), "Interpolated"
			end
		end
		return states[1], "Held"
	end
	local limit = maxExtrapolate or StateBuffer.extrapolationLimit(states)
	local ahead = ut - newest.ut
	if ahead > limit then
		return StateBuffer.extrapolate(newest, limit), "Frozen"
	end
	return StateBuffer.extrapolate(newest, ahead), "Extrapolated"
end

return table.freeze(StateBuffer)
