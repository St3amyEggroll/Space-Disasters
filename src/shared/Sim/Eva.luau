--!strict
--[[
	Eva (Phase 6, spec 7.9)
	Pure maths for an astronaut on EVA (EVAController on the client): the floating astronaut's motion, the jetpack,
	ground contact, and the rules that pick floating or walking. No services and no Instances, so the offline Lune
	suite tests it (src/server/Tests/Eva.spec.luau).

	The astronaut is a point mass with an ABSOLUTE state, like a craft: (bodyId, pos, vel, ut), position relative to
	the body's centre, universe axes, doubles (invariant I1). Every frame the client advances it to the UT its pocket
	frame is drawn at and places the character at Frames.pointToWorkspace(frame, pos). Deviation from the spec
	(which integrated an offset relative to the pocket reference with no gravity): with an absolute state the
	astronaut feels the true gravity of the body (patched conics: the SOI body only), so
	  * in orbit the astronaut and the craft fall together and he floats beside it (relative motion is a straight
	    line, tidal effects of a few cm per minute come for free),
	  * when the pilot burns the engines the craft really leaves the astronaut behind,
	  * next to a landed craft he falls back to the ground at the body's real gravity,
	  * pocket changes (transfers, rebases, merges) never move him: only the frame he is drawn in changes.
	Thin air slows him down (EVA_DRAG_K: about 55 m/s terminal speed at sea level, like a skydiver), so jumping out
	of a rocket low in the air never ends in a 400 m/s fall.

	Ground: SurfaceHeight (the flat tile planes the craft physics and the surface tiles use). The astronaut's point
	is his HumanoidRootPart, ROOT_HEIGHT above his feet; below that he is pushed back up, loses the velocity into the
	ground and slides with GROUND_FRICTION.
	CHANGED (Night review): sliding friction is Coulomb friction, GROUND_FRICTION_COEF times the load pressing him
	into the ground (gravity plus jetpack along the ground's normal), so the jetpack can move a floating astronaut
	lying on Earth's ground (the old fixed 6 m/s^2 beat its 3 m/s^2 and he could never get away).

	Jetpack: EVA_THRUST_ACCEL (3 m/s^2) along the input direction for EVA_PROPELLANT_S (60 s) of full thrust; brake
	(R) cancels the velocity relative to the nearest craft without overshooting. It refills aboard a craft in
	EVA_REFILL_S. On a surface the jetpack hops: vertical thrust EVA_SURFACE_HOP_G (1.5) x the character gravity.

	Walking or floating (client): the astronaut walks (Roblox Humanoid physics, workspace.Gravity =
	walkGravity(body), spec 7.5 "Character gravity") only in a pocket that stands still on the ground (a landed craft
	or a surface pocket) and only near the ground; everywhere else he floats on this module's integration.
	CHANGED (Night review): "stands still on the ground" compares the pocket's up with the RADIAL up under the
	astronaut (Eva.radialUp), not the terrain triangle's normal: since Phase 8 the ground is ~23 m triangles, and on
	slopes steeper than STATIONARY_UP's 20 degrees (16% of the Mun, 9% of Earth's land) he could never walk.

	CHANGED (Night review): time jumps. A frame hitch longer than the old MAX_ADVANCE (0.5 s) only resynced the
	clock, so an astronaut in orbit was left hundreds of metres behind his craft (0.6 s at 15 km: 412 m). Forward
	jumps up to MAX_CATCH_UP are now integrated in MAX_STEP steps; longer ones follow the conic (Kepler) when
	nothing but gravity acts (no thrust, no air), else they still only resync.

	CHANGED (Night review): plausibleMove, the server's check of an astronaut's replicated motion (his position and
	velocity are client-authoritative and feed the bubble decisions): a sample is only trusted when it follows the
	last trusted one within what gravity, the jetpack and Roblox walking physics allow (plus slack).

	API:
	  Eva.new(bodyId, pos, vel, ut) -> State
	  Eva.copy(state) -> State
	  Eva.gravity(bodyId, pos) -> Vec3d                      m/s^2, universe axes
	  Eva.dragAccel(bodyId, pos, vel) -> Vec3d               m/s^2 (air at rest relative to the body)
	  Eva.groundHeight(bodyId, pos) -> (number, Vec3d)        height of the FEET above the ground, ground up normal
	  Eva.step(state, dt, thrust?) -> boolean                 one step (thrust in m/s^2, universe axes); true = on
	                                                          the ground after the step
	  Eva.advance(state, ut, thrust?) -> boolean              to `ut` in steps of at most MAX_STEP (a small step back
	                                                          in time is a straight line; a long jump ahead coasts on
	                                                          its conic or resyncs)
	  Eva.setBody(state, bodyId)                              re-expresses the state relative to another body
	  Eva.thrustDirection(forward, right, up, f, r, u) -> Vec3d   input axes (each -1..1) -> unit-or-shorter vector
	  Eva.brakeAccel(relVel, accel, dt) -> Vec3d              acceleration that cancels relVel without overshoot
	  Eva.burn(fuel, accel, dt) -> (number, number)           (fuel left, fraction of the asked acceleration given)
	  Eva.refill(fuel, dt) -> number
	  Eva.walkGravity(bodyId) -> number                       workspace.Gravity for walking on that body
	  Eva.hopForce(mass, gravity) -> number                   jetpack force while walking (N in Roblox units)
	  Eva.collide(vel, surfaceVel, normal) -> Vec3d           removes the velocity INTO a surface (relative to it)
	  Eva.stationaryPocket(frameSpeed, upAlignment) -> boolean   a pocket that stands still on the ground
	  Eva.radialUp(pos) -> Vec3d                              CHANGED (Night review): unit up away from the body's
	                                                          centre (what a pocket's up is compared with)
	  Eva.plausibleMove(previous?, current) -> boolean        CHANGED (Night review): may the server trust a
	                                                          replicated Sample after the last trusted one?
	  Eva.shouldWalk(walking, stationary, feetHeight, groundSpeed) -> boolean   with hysteresis
]]

local Atmosphere = require(script.Parent.Atmosphere)
local Bodies = require(script.Parent.Parent.Config.Bodies)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Kepler = require(script.Parent.Kepler) -- CHANGED (Night review): long time jumps coast on the conic
local SurfaceHeight = require(script.Parent.SurfaceHeight)
local Universe = require(script.Parent.Universe)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local THRUST_ACCEL = GameConfig.EVA_THRUST_ACCEL -- m/s^2
local PROPELLANT_S = GameConfig.EVA_PROPELLANT_S -- s of full thrust
local REFILL_S = GameConfig.EVA_REFILL_S -- s for an empty jetpack to refill aboard
local HOP_G = GameConfig.EVA_SURFACE_HOP_G
local CHARACTER_GRAVITY = GameConfig.CHARACTER_GRAVITY -- workspace.Gravity at 1 g
local G0 = GameConfig.G0
local MAX_STEP = 1 / 60 -- s; longer frames are split
-- CHANGED (Night review): was MAX_ADVANCE = 0.5 s (any longer jump only resynced the clock: a hitch left an orbiting
-- astronaut behind). Jumps ahead up to this are integrated step by step (1800 steps at most, once per hitch).
local MAX_CATCH_UP = 30 -- s
local MAX_BACKWARD = 0.5 -- s; a frame that moves back in time this much at most is followed as a straight line
local DRAG_K = 0.00265 -- 1/m: a = -DRAG_K * rho * |v| * v (terminal ~55 m/s in sea-level air)
local ROOT_HEIGHT = 3 -- m: a standing R15 HumanoidRootPart is this high above the feet
-- CHANGED (Night review): was GROUND_FRICTION = 6 m/s^2 flat, more than the jetpack's 3 m/s^2. Coulomb friction
-- now: this times the load (m/s^2 pressing into the ground). Earth: 2.45 m/s^2, so the jetpack still pushes him.
local GROUND_FRICTION_COEF = 0.25
local STATIONARY_SPEED = 0.5 -- m/s: a pocket slower than this stands still on the ground
-- cos of the largest angle between the pocket's up and the radial up under the astronaut (20 degrees)
-- CHANGED (Night review): compared with the radial up (radialUp), not the terrain triangle's normal (header)
local STATIONARY_UP = 0.94
local WALK_ENTER_HEIGHT = 0.6 -- m of the feet above the ground at which a floating astronaut starts walking
local WALK_ENTER_SPEED = 20 -- m/s: faster than this he keeps floating (sliding) until slower
local WALK_EXIT_HEIGHT = 60 -- m of the feet above the ground at which a walking (hopping) astronaut floats
-- CHANGED (Night review): plausibleMove (the server's check of replicated EVA motion)
local MOVE_POS_SLACK = 30 -- m of position error always allowed between two samples (replication jitter, collisions)
local MOVE_VEL_SLACK = 60 -- m/s of velocity change always allowed (a jump, a hull collision, walk <-> float)
local MOVE_MAX_GAP = 3 -- s: a sample this long after the last trusted one starts a new history (transfers, lag)
local MAX_SPEED = 5000 -- m/s relative to the body: faster is never an astronaut (escape speeds are ~1 km/s)
--============================================================================

export type State = {
	bodyId: number,
	pos: Vec3d, -- relative to the body's centre, universe axes (the HumanoidRootPart)
	vel: Vec3d,
	ut: number,
}

-- CHANGED (Night review): a replicated astronaut sample the server checks (plausibleMove); the fields of a State.
export type Sample = State

local Eva = {}

Eva.ROOT_HEIGHT = ROOT_HEIGHT
Eva.MAX_STEP = MAX_STEP
Eva.MAX_CATCH_UP = MAX_CATCH_UP -- CHANGED (Night review)
Eva.GROUND_FRICTION_COEF = GROUND_FRICTION_COEF -- CHANGED (Night review)

function Eva.new(bodyId: number, pos: Vec3d, vel: Vec3d, ut: number): State
	return { bodyId = bodyId, pos = Vec3d.clone(pos), vel = Vec3d.clone(vel), ut = ut }
end

function Eva.copy(state: State): State
	return Eva.new(state.bodyId, state.pos, state.vel, state.ut)
end

-- Gravity of the SOI body at a position relative to its centre (m/s^2).
function Eva.gravity(bodyId: number, pos: Vec3d): Vec3d
	local r2 = Vec3d.lengthSq(pos)
	if r2 < 1 then
		return Vec3d.zero()
	end
	local r = math.sqrt(r2)
	return Vec3d.scale(pos, -Bodies.get(bodyId).Mu / (r2 * r))
end

-- Air drag on the astronaut (the air is at rest relative to the body: planets do not rotate).
function Eva.dragAccel(bodyId: number, pos: Vec3d, vel: Vec3d): Vec3d
	local rho = Atmosphere.density(bodyId, Universe.altitude(bodyId, pos))
	if rho <= 0 then
		return Vec3d.zero()
	end
	local speed = Vec3d.length(vel)
	return Vec3d.scale(vel, -DRAG_K * rho * speed)
end

-- Height of the astronaut's FEET above the ground under him (negative = below), and the ground's up normal.
function Eva.groundHeight(bodyId: number, pos: Vec3d): (number, Vec3d)
	local h, up = SurfaceHeight.height(bodyId, pos)
	return h - ROOT_HEIGHT, up
end

-- Removes the velocity component that moves INTO a surface whose outward normal is `normal`, relative to the
-- surface's own velocity (a craft drifting along, or the ground at rest).
function Eva.collide(vel: Vec3d, surfaceVel: Vec3d, normal: Vec3d): Vec3d
	local rel = Vec3d.sub(vel, surfaceVel)
	local into = Vec3d.dot(rel, normal)
	if into >= 0 then
		return Vec3d.clone(vel)
	end
	return Vec3d.addScaled(vel, normal, -into)
end

-- Pushes a state out of the ground and applies ground friction for dt. Returns true when touching the ground.
-- CHANGED (Night review): `thrust` (the jetpack, m/s^2) adds to the friction load (header)
local function groundContact(state: State, dt: number, thrust: Vec3d?): boolean
	local feet, up = Eva.groundHeight(state.bodyId, state.pos)
	if feet > 0 then
		return false
	end
	Vec3d.addScaledInto(state.pos, state.pos, up, -feet)
	local vel = Eva.collide(state.vel, Vec3d.zero(), up)
	-- friction on what is left (all of it is tangential once the inward part is gone; an outward part is kept)
	local normalPart = Vec3d.dot(vel, up)
	local tangent = Vec3d.addScaled(vel, up, -normalPart)
	local speed = Vec3d.length(tangent)
	if speed > 0 and dt > 0 then
		-- CHANGED (Night review): Coulomb friction, proportional to what presses him into the ground
		local press = Eva.gravity(state.bodyId, state.pos)
		if thrust then
			press = Vec3d.add(press, thrust)
		end
		local load = math.max(-Vec3d.dot(press, up), 0)
		local slowed = math.max(speed - GROUND_FRICTION_COEF * load * dt, 0)
		tangent = Vec3d.scale(tangent, slowed / speed)
	end
	state.vel = Vec3d.addScaled(tangent, up, normalPart)
	return true
end

-- Patched conics: moves the state into another body's frame when it crossed an SOI boundary.
local function checkSoi(state: State)
	local newBody, newPos = Universe.soiTransition(state.bodyId, state.pos, state.ut)
	if newBody ~= state.bodyId then
		state.vel = Vec3d.add(state.vel, Universe.bodyVelocityOffset(state.bodyId, newBody, state.ut))
		state.pos = newPos
		state.bodyId = newBody
	end
end

-- Gravity + drag + thrust at a state's position and velocity.
local function acceleration(bodyId: number, pos: Vec3d, vel: Vec3d, thrust: Vec3d?): Vec3d
	local accel = Eva.gravity(bodyId, pos)
	Vec3d.addInto(accel, accel, Eva.dragAccel(bodyId, pos, vel))
	if thrust then
		Vec3d.addInto(accel, accel, thrust)
	end
	return accel
end

--[[
	One step of dt seconds: velocity Verlet (kick, drift, kick), the integrator FlightModel uses for crafts, so an
	astronaut beside a coasting craft stays beside it (a first-order integrator drifts metres per orbit, because its
	velocity runs half a step ahead of its position). `thrust` is the jetpack's acceleration (m/s^2, universe axes).
	Returns true when the astronaut touches the ground after the step.
]]
function Eva.step(state: State, dt: number, thrust: Vec3d?): boolean
	local half = dt / 2
	Vec3d.addScaledInto(state.vel, state.vel, acceleration(state.bodyId, state.pos, state.vel, thrust), half)
	Vec3d.addScaledInto(state.pos, state.pos, state.vel, dt)
	Vec3d.addScaledInto(state.vel, state.vel, acceleration(state.bodyId, state.pos, state.vel, thrust), half)
	state.ut += dt
	local touching = groundContact(state, dt, thrust) -- CHANGED (Night review): thrust for the friction load
	checkSoi(state)
	return touching
end

--[[
	Advances to `ut` in steps of at most MAX_STEP. A small step back in time (the pocket frame switched to a stream
	sampled INTERP_DELAY in the past) is followed as a straight line; a bigger step back only resyncs the clock.
	CHANGED (Night review): a jump ahead of up to MAX_CATCH_UP (a frame hitch) is integrated like any frame; a longer
	one follows the conic when only gravity acts (no thrust, no air) and only resyncs otherwise. Returns true when on
	the ground at the end.
]]
function Eva.advance(state: State, ut: number, thrust: Vec3d?): boolean
	local dt = ut - state.ut
	if dt ~= dt then
		return false
	end
	if dt < 0 then
		if dt >= -MAX_BACKWARD then
			Vec3d.addScaledInto(state.pos, state.pos, state.vel, dt)
		end
		state.ut = ut
		return groundContact(state, 0)
	end
	if dt == 0 then
		state.ut = ut
		return groundContact(state, 0)
	end
	if dt > MAX_CATCH_UP then
		-- CHANGED (Night review): a very long jump coasts on the conic when nothing but gravity acts
		local airless = Atmosphere.density(state.bodyId, Universe.altitude(state.bodyId, state.pos)) <= 0
		if thrust == nil and airless then
			local pos, vel = Kepler.propagate(Bodies.get(state.bodyId).Mu, state.pos, state.vel, dt)
			if Vec3d.isFinite(pos) and Vec3d.isFinite(vel) then
				state.pos, state.vel = pos, vel
			end
		end
		state.ut = ut
		local touching = groundContact(state, 0)
		checkSoi(state)
		return touching
	end
	local touching = false
	local steps = math.max(1, math.ceil(dt / MAX_STEP - 1e-9))
	local h = dt / steps
	for _ = 1, steps do
		touching = Eva.step(state, h, thrust)
	end
	state.ut = ut -- no rounding drift
	return touching
end

-- Re-expresses the state relative to another body (same instant, same true position and velocity).
function Eva.setBody(state: State, bodyId: number)
	if bodyId == state.bodyId then
		return
	end
	state.pos = Vec3d.add(state.pos, Universe.bodyOffset(state.bodyId, bodyId, state.ut))
	state.vel = Vec3d.add(state.vel, Universe.bodyVelocityOffset(state.bodyId, bodyId, state.ut))
	state.bodyId = bodyId
end

--[[
	Jetpack direction from the input axes (each -1..1: forward / right / up) and the camera's axes (universe, unit).
	The result is at most 1 long (diagonals are not faster) and zero without input.
]]
function Eva.thrustDirection(forward: Vec3d, right: Vec3d, up: Vec3d, f: number, r: number, u: number): Vec3d
	local x = forward.x * f + right.x * r + up.x * u
	local y = forward.y * f + right.y * r + up.y * u
	local z = forward.z * f + right.z * r + up.z * u
	local length = math.sqrt(x * x + y * y + z * z)
	if length < 1e-9 then
		return Vec3d.zero()
	end
	local s = if length > 1 then 1 / length else 1
	return Vec3d.new(x * s, y * s, z * s)
end

-- Acceleration that cancels a relative velocity: at most `accel`, and never more than stops it within dt.
function Eva.brakeAccel(relVel: Vec3d, accel: number, dt: number): Vec3d
	local speed = Vec3d.length(relVel)
	if speed < 1e-6 or dt <= 0 then
		return Vec3d.zero()
	end
	local a = math.min(accel, speed / dt)
	return Vec3d.scale(relVel, -a / speed)
end

--[[
	Uses jetpack fuel (seconds of full thrust) for an acceleration of `accel` m/s^2 over dt. Returns the fuel left
	and the fraction of the asked acceleration actually delivered (less than 1 when the tank runs dry this step).
]]
function Eva.burn(fuel: number, accel: number, dt: number): (number, number)
	if accel <= 0 or dt <= 0 then
		return math.max(fuel, 0), 1
	end
	local needed = accel / THRUST_ACCEL * dt
	if needed <= 0 then
		return fuel, 1
	end
	if fuel <= 0 then
		return 0, 0
	end
	if fuel >= needed then
		return fuel - needed, 1
	end
	return 0, fuel / needed
end

-- Refuelling aboard a craft: a full tank in REFILL_S.
function Eva.refill(fuel: number, dt: number): number
	return math.min(PROPELLANT_S, math.max(fuel, 0) + PROPELLANT_S / REFILL_S * math.max(dt, 0))
end

-- workspace.Gravity for walking on a body (Roblox's character feel scaled by the body's surface gravity).
function Eva.walkGravity(bodyId: number): number
	return CHARACTER_GRAVITY * Bodies.get(bodyId).SurfaceGravity / G0
end

-- The jetpack's upward force while walking: HOP_G times the character's weight under `gravity`.
function Eva.hopForce(mass: number, gravity: number): number
	return HOP_G * mass * gravity
end

--[[
	Does a pocket stand still on the ground? Its reference moves slower than STATIONARY_SPEED (a landed craft, a
	surface pocket) and its "up" matches the radial up under the astronaut (radialUp) within STATIONARY_UP (cosine).
	CHANGED (Night review): the radial up, not the terrain triangle's normal (header).
]]
function Eva.stationaryPocket(frameSpeed: number, upAlignment: number): boolean
	return frameSpeed == frameSpeed and frameSpeed < STATIONARY_SPEED and upAlignment >= STATIONARY_UP
end

-- CHANGED (Night review): unit "up" away from the body's centre at a body-relative position: what a pocket's up is
-- compared with for stationaryPocket (the terrain triangle's normal tilts with every slope).
function Eva.radialUp(pos: Vec3d): Vec3d
	if Vec3d.lengthSq(pos) < 1 then
		return Vec3d.new(0, 1, 0)
	end
	return Vec3d.normalize(pos)
end

-- CHANGED (Night review): the largest acceleration (m/s^2) an astronaut's motion may show on a body: Roblox
-- walking gravity with the jetpack hop, the floating jetpack and the body's own gravity.
local function maxAcceleration(bodyId: number): number
	return Eva.walkGravity(bodyId) * (1 + HOP_G) + THRUST_ACCEL + Bodies.get(bodyId).SurfaceGravity
end

--[[
	CHANGED (Night review): may the server trust a replicated astronaut sample (body-relative position / velocity at
	ut) after `previous`, the last trusted one? Never when it is not finite or faster than MAX_SPEED. Always when
	there is no usable history (nil, another body, not later, or MOVE_MAX_GAP or more ago). Otherwise only when it
	follows from `previous` within what an astronaut can do (a = the largest acceleration on that body):
	|pos - (prev.pos + prev.vel dt)| <= MOVE_POS_SLACK + a dt^2 / 2 and |vel - prev.vel| <= MOVE_VEL_SLACK + a dt.
]]
function Eva.plausibleMove(previous: Sample?, current: Sample): boolean
	if not (Vec3d.isFinite(current.pos) and Vec3d.isFinite(current.vel)) or current.ut ~= current.ut then
		return false
	end
	if Vec3d.length(current.vel) > MAX_SPEED then
		return false
	end
	if previous == nil or previous.bodyId ~= current.bodyId then
		return true
	end
	local dt = current.ut - previous.ut
	if not (dt > 0 and dt < MOVE_MAX_GAP) then
		return true
	end
	local accel = maxAcceleration(current.bodyId)
	local expected = Vec3d.addScaled(previous.pos, previous.vel, dt)
	local posError = Vec3d.distance(expected, current.pos)
	local velError = Vec3d.distance(previous.vel, current.vel)
	return posError <= MOVE_POS_SLACK + 0.5 * accel * dt * dt and velError <= MOVE_VEL_SLACK + accel * dt
end

--[[
	Walking (Roblox Humanoid physics) or floating (this module)? `feetHeight` = feet above the ground (m),
	`groundSpeed` = speed relative to the ground (m/s). A floating astronaut starts walking when he touches the ground
	slowly in a stationary pocket; a walking one floats again when the pocket moves or he flew WALK_EXIT_HEIGHT up.
]]
function Eva.shouldWalk(walking: boolean, stationary: boolean, feetHeight: number, groundSpeed: number): boolean
	if not stationary or feetHeight ~= feetHeight then
		return false
	end
	if walking then
		return feetHeight < WALK_EXIT_HEIGHT
	end
	return feetHeight <= WALK_ENTER_HEIGHT and groundSpeed < WALK_ENTER_SPEED
end

return table.freeze(Eva)
