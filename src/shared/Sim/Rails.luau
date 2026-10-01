--!strict
--[[
	Rails (Phase 5, spec 7.8)
	On-rails crafts: a coasting craft's motion is the analytic two-body orbit, so nobody integrates it and nothing
	is streamed. Shared by the server (RailsService), the pilot's client (FlightController) and every client's
	remote rendering (RemoteCraftRenderer / RailsController).

	A rail stores STATE VECTORS AT AN EPOCH, not elements (no element singularities):
	  bodyId, epochUT, r0 / v0   the craft's reference point (root block, as in CraftState) relative to the body,
	                             universe axes, doubles (I1)
	  rot, angVel                attitude at the epoch and a constant angular velocity (universe axes); 0 when the
	                             attitude is held (SAS) or frozen
	  com                        the centre of mass in craft axes; the CoM follows the Kepler orbit and the
	                             reference point turns around it, exactly like FlightModel integrates it
	  throttle, flags            carried through for the HUD and cosmetics (gear, SAS)
	The state at any UT is Kepler.propagate of the CoM by UT - epochUT, so there is no integration drift.

	Going on rails (eligible): out of the atmosphere and above RAILS_MIN_ALTITUDE (+ hysteresis), no engine
	burning or able to burn, no ground contact, no pilot input (the caller tracks the 0.5 s of idle time), and
	with SAS on the craft must have settled. Rails end by themselves at `exitUT`, when the orbit drops below the
	rails floor (atmosphere top or RAILS_MIN_ALTITUDE).

	SOI transitions: advance(rails, fromUT, toUT) checks every SOI_CHECK_INTERVAL of UT whether the craft has left
	its body's SOI or entered a child's (Universe.soiTransition), bisects the crossing to SOI_BISECTION_TOLERANCE
	and re-expresses the state in the new body's frame at that UT (a new epoch).

	predict(...) chains conic patches through SOI changes for the map view.
]]

local Atmosphere = require(script.Parent.Atmosphere)
local Bodies = require(script.Parent.Parent.Config.Bodies)
local FlightModel = require(script.Parent.FlightModel)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Kepler = require(script.Parent.Kepler)
local Universe = require(script.Parent.Universe)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local MIN_ALTITUDE = GameConfig.RAILS_MIN_ALTITUDE
local ALTITUDE_HYSTERESIS = GameConfig.RAILS_ALTITUDE_HYSTERESIS
local SAS_MAX_RATE = GameConfig.RAILS_SAS_MAX_RATE
local SOI_CHECK_INTERVAL = GameConfig.SOI_CHECK_INTERVAL
local BISECTION_TOLERANCE = GameConfig.SOI_BISECTION_TOLERANCE
local MAX_CHECKS_PER_ADVANCE = 4096 -- longer windows use longer check steps
local MAX_TRANSITIONS_PER_ADVANCE = 4
local TRANSITION_GUARD_S = 1 -- s after an SOI change before the boundary just crossed is searched again
local PREDICT_ORBITS = 2 -- elliptic patches are searched this many periods ahead for events
local PREDICT_HORIZON = 40000 -- s; open orbits (and long periods) are searched this far ahead
local CLEAR_FLAGS = bit32.bor(FlightModel.FLAG_BURNING, FlightModel.FLAG_CONTACT)
--============================================================================

export type Rails = {
	bodyId: number,
	epochUT: number,
	r0: Vec3d,
	v0: Vec3d,
	rot: CFrame,
	angVel: Vector3,
	com: Vector3,
	throttle: number,
	flags: number,
	-- derived (not sent on the wire)
	mu: number,
	comPos0: Vec3d,
	comVel0: Vec3d,
	exitUT: number, -- UT at which the orbit drops below the rails floor (math.huge if never)
}

export type PatchEnd = "None" | "Impact" | "Exit" | "Enter"

export type Patch = {
	bodyId: number,
	startUT: number,
	endUT: number, -- math.huge when the patch never ends
	r0: Vec3d, -- state at startUT relative to bodyId
	v0: Vec3d,
	endReason: PatchEnd,
	nextBodyId: number?,
	elements: Kepler.Elements, -- at startUT
}

export type PredictOptions = {
	maxPatches: number?,
	orbits: number?,
	horizon: number?,
}

local Rails = {}

Rails.TRANSITION_GUARD_S = TRANSITION_GUARD_S

--============================================================================
-- Construction and sampling
--============================================================================

-- Rails floor of a body: below this altitude (sea level) nothing stays on rails.
function Rails.minAltitude(bodyId: number): number
	return math.max(Atmosphere.top(bodyId), MIN_ALTITUDE)
end

-- First UT at which the CoM orbit drops below the rails floor, or math.huge.
local function lowExitTime(bodyId: number, mu: number, epochUT: number, r: Vec3d, v: Vec3d): number
	local body = Bodies.get(bodyId)
	local threshold = body.Radius + Rails.minAltitude(bodyId)
	if Vec3d.length(r) < threshold then
		return epochUT
	end
	local el = Kepler.elements(mu, r, v)
	if el.periapsis >= threshold then
		return math.huge
	end
	local toPe = el.timeToPeriapsis
	if toPe == nil then
		return math.huge -- leaving periapsis behind on an open orbit
	end
	local window = if el.kind == "Elliptic" and toPe < 1e-6 then el.period else toPe
	local dt = Kepler.findRadiusCrossing(mu, r, v, threshold, 0, window + 1, threshold)
	return if dt then epochUT + dt else math.huge
end

function Rails.new(
	bodyId: number,
	epochUT: number,
	r0: Vec3d,
	v0: Vec3d,
	rot: CFrame,
	angVel: Vector3,
	com: Vector3,
	throttle: number,
	flags: number
): Rails
	local body = Bodies.get(bodyId)
	local rotation = rot - rot.Position
	local comWorld = rotation:VectorToWorldSpace(com)
	local offsetVel = angVel:Cross(comWorld)
	local comPos0 = Vec3d.new(r0.x + comWorld.X, r0.y + comWorld.Y, r0.z + comWorld.Z)
	local comVel0 = Vec3d.new(v0.x + offsetVel.X, v0.y + offsetVel.Y, v0.z + offsetVel.Z)
	return {
		bodyId = bodyId,
		epochUT = epochUT,
		r0 = Vec3d.clone(r0),
		v0 = Vec3d.clone(v0),
		rot = rotation,
		angVel = angVel,
		com = com,
		throttle = throttle,
		flags = bit32.band(flags, bit32.bnot(CLEAR_FLAGS)),
		mu = body.Mu,
		comPos0 = comPos0,
		comVel0 = comVel0,
		exitUT = lowExitTime(bodyId, body.Mu, epochUT, comPos0, comVel0),
	}
end

--[[
	Rails from a craft state. `com` is the craft's centre of mass in craft axes (FlightModel physics.com).
	`holdAttitude` (SAS on) freezes the attitude: the angular velocity becomes 0, and the reference point gets the
	CoM's velocity so the orbit itself is unchanged.
]]
function Rails.fromState(state: FlightModel.CraftState, com: Vector3, holdAttitude: boolean): Rails
	local v0 = state.vel
	local angVel = state.angVel
	if holdAttitude then
		local comWorld = state.rot:VectorToWorldSpace(com)
		local offsetVel = state.angVel:Cross(comWorld)
		v0 = Vec3d.new(v0.x + offsetVel.X, v0.y + offsetVel.Y, v0.z + offsetVel.Z)
		angVel = Vector3.zero
	end
	return Rails.new(state.bodyId, state.ut, state.pos, v0, state.rot, angVel, com, state.throttle, state.flags)
end

-- Rebuilds a rail from its wire form (Protocol.RailsData).
function Rails.fromData(data: {
	bodyId: number,
	epochUT: number,
	r0: Vec3d,
	v0: Vec3d,
	rot: CFrame,
	angVel: Vector3,
	com: Vector3,
	throttle: number,
	flags: number,
}): Rails?
	if Bodies.find(data.bodyId) == nil or Bodies.get(data.bodyId).VisualOnly then
		return nil
	end
	return Rails.new(
		data.bodyId,
		data.epochUT,
		data.r0,
		data.v0,
		data.rot,
		data.angVel,
		data.com,
		data.throttle,
		data.flags
	)
end

-- Attitude on the rail at a UT.
function Rails.rotationAt(rails: Rails, ut: number): CFrame
	local w = rails.angVel
	local rate = w.Magnitude
	if rate < 1e-9 then
		return rails.rot
	end
	local angle = (rate * (ut - rails.epochUT)) % (2 * math.pi)
	return CFrame.fromAxisAngle(w / rate, angle) * rails.rot
end

-- The craft's state on the rail at a UT (a new CraftState; also usable as a Protocol.State).
function Rails.stateAt(rails: Rails, ut: number): FlightModel.CraftState
	local comPos, comVel = Kepler.propagate(rails.mu, rails.comPos0, rails.comVel0, ut - rails.epochUT)
	local rot = Rails.rotationAt(rails, ut)
	local comWorld = rot:VectorToWorldSpace(rails.com)
	local offsetVel = rails.angVel:Cross(comWorld)
	return {
		bodyId = rails.bodyId,
		pos = Vec3d.new(comPos.x - comWorld.X, comPos.y - comWorld.Y, comPos.z - comWorld.Z),
		vel = Vec3d.new(comVel.x - offsetVel.X, comVel.y - offsetVel.Y, comVel.z - offsetVel.Z),
		rot = rot,
		angVel = rails.angVel,
		throttle = rails.throttle,
		flags = rails.flags,
		ut = ut,
	}
end

-- Same rail, new epoch (keeps everything; used after an SOI change or to keep epochs recent).
function Rails.rebase(rails: Rails, ut: number): Rails
	local s = Rails.stateAt(rails, ut)
	return Rails.new(s.bodyId, ut, s.pos, s.vel, s.rot, rails.angVel, rails.com, rails.throttle, rails.flags)
end

--============================================================================
-- Eligibility
--============================================================================

-- Would any ignited engine produce thrust with the craft's current controls?
function Rails.wouldThrust(craft: FlightModel.Craft): boolean
	for _, engine in craft.physics.engines do
		if FlightModel.engineBurning(craft, engine) then
			return true
		end
	end
	return false
end

-- May this craft go on rails now (apart from the idle time, which the caller tracks)?
function Rails.eligible(craft: FlightModel.Craft): boolean
	local state = craft.state
	if bit32.band(state.flags, CLEAR_FLAGS) ~= 0 then
		return false
	end
	local controls = craft.controls
	if controls.pitch ~= 0 or controls.yaw ~= 0 or controls.roll ~= 0 then
		return false
	end
	if Rails.wouldThrust(craft) then
		return false
	end
	local body = Bodies.get(state.bodyId)
	local altitude = Vec3d.length(state.pos) - body.Radius
	if altitude < Rails.minAltitude(state.bodyId) + ALTITUDE_HYSTERESIS then
		return false
	end
	if controls.sas and state.angVel.Magnitude > SAS_MAX_RATE then
		return false
	end
	return true
end

-- Will this trajectory come back down into the atmosphere (or to the surface on airless bodies)?
function Rails.isSuborbital(bodyId: number, pos: Vec3d, vel: Vec3d): boolean
	local body = Bodies.get(bodyId)
	local el = Kepler.elements(body.Mu, pos, vel)
	if el.kind ~= "Elliptic" and el.timeToPeriapsis == nil then
		return false -- leaving for good
	end
	return el.periapsis < body.Radius + Atmosphere.top(bodyId)
end

--============================================================================
-- SOI transitions
--============================================================================

local function bodyAt(rails: Rails, ut: number): number
	local s = Rails.stateAt(rails, ut)
	return (Universe.soiTransition(rails.bodyId, s.pos, ut))
end

-- The rail re-expressed in the frame of the body whose SOI it is in at `ut` (call after a detected change).
function Rails.transition(rails: Rails, ut: number): Rails
	local s = Rails.stateAt(rails, ut)
	local newBody, newPos = Universe.soiTransition(rails.bodyId, s.pos, ut)
	if newBody == rails.bodyId then
		return Rails.rebase(rails, ut)
	end
	local newVel = Vec3d.add(s.vel, Universe.bodyVelocityOffset(rails.bodyId, newBody, ut))
	return Rails.new(newBody, ut, newPos, newVel, s.rot, rails.angVel, rails.com, rails.throttle, rails.flags)
end

--[[
	Checks (fromUT, toUT] every SOI_CHECK_INTERVAL for SOI changes (it assumes none was pending at fromUT).
	Each change is bisected to SOI_BISECTION_TOLERANCE and the rail re-expressed in the new body at that UT.
	Returns the new rail, or nil when the craft stayed in its SOI.
]]
function Rails.advance(rails: Rails, fromUT: number, toUT: number): Rails?
	if not (toUT > fromUT) then
		return nil
	end
	local current = rails
	local changed = false
	local from = fromUT
	for _ = 1, MAX_TRANSITIONS_PER_ADVANCE do
		local span = toUT - from
		if span <= 0 then
			break
		end
		local checks = math.clamp(math.ceil(span / SOI_CHECK_INTERVAL), 1, MAX_CHECKS_PER_ADVANCE)
		local step = span / checks
		local crossing: number? = nil
		local previous = from
		for k = 1, checks do
			local t = if k == checks then toUT else from + step * k
			if bodyAt(current, t) ~= current.bodyId then
				local lo, hi = previous, t
				while hi - lo > BISECTION_TOLERANCE do
					local mid = 0.5 * (lo + hi)
					if bodyAt(current, mid) ~= current.bodyId then
						hi = mid
					else
						lo = mid
					end
				end
				crossing = hi
				break
			end
			previous = t
		end
		if crossing == nil then
			break
		end
		current = Rails.transition(current, crossing :: number)
		changed = true
		from = crossing :: number
	end
	return if changed then current else nil
end

--============================================================================
-- Prediction (map view)
--============================================================================

--[[
	Conic patches from a state: each ends at an impact, an SOI exit, an SOI entry, or never. Elliptic patches are
	searched PREDICT_ORBITS periods ahead (capped by the horizon), open ones up to the horizon.
]]
function Rails.predict(bodyId: number, pos: Vec3d, vel: Vec3d, ut: number, options: PredictOptions?): { Patch }
	local opts: PredictOptions = options or {}
	local maxPatches = opts.maxPatches or GameConfig.MAP_PREDICT_PATCHES
	local orbits = opts.orbits or PREDICT_ORBITS
	local horizon = opts.horizon or PREDICT_HORIZON

	local patches: { Patch } = {}
	local currentBody, currentUT = bodyId, ut
	local r, v = Vec3d.clone(pos), Vec3d.clone(vel)
	local justLeft: number? = nil
	for index = 1, maxPatches do
		local body = Bodies.get(currentBody)
		local mu = body.Mu
		local el = Kepler.elements(mu, r, v)
		local window = if el.kind == "Elliptic" then math.min(el.period * orbits, horizon) else horizon
		local guard = if index > 1 then TRANSITION_GUARD_S else 0
		local endT = math.huge
		local reason: PatchEnd = "None"
		local nextBody: number? = nil

		if Vec3d.length(r) <= body.Radius then
			endT, reason = 0, "Impact"
		elseif el.periapsis < body.Radius then
			local limit = if el.kind == "Elliptic" then math.min(window, el.period) else window
			local t = Kepler.findRadiusCrossing(mu, r, v, body.Radius, 0, limit, body.Radius * 0.5)
			if t then
				endT, reason = t, "Impact"
			end
		end

		if body.SoiRadius < math.huge and (el.kind ~= "Elliptic" or el.apoapsis > body.SoiRadius) then
			local t = Kepler.findRadiusCrossing(mu, r, v, body.SoiRadius, guard, math.min(window, endT), body.Radius)
			if t and t < endT then
				endT, reason, nextBody = t, "Exit", body.ParentId
			end
		end

		for _, child in Bodies.children(currentBody) do
			local orbit = child.Orbit
			if orbit then
				local reach = orbit.Radius - child.SoiRadius
				local beyond = orbit.Radius + child.SoiRadius
				if el.periapsis <= beyond and el.apoapsis >= reach then
					local childId = child.Id
					local startUT = currentUT
					-- the SOI just left is searched again after the guard (a later re-encounter still counts)
					local from = if childId == justLeft then guard else 0
					local t = Kepler.findSphereEntry(mu, r, v, function(dt: number): Vec3d
						return Universe.bodyOffset(childId, currentBody, startUT + dt)
					end, orbit.Radius * orbit.AngularRate, child.SoiRadius, from, math.min(window, endT), body.Radius)
					if t and t < endT then
						endT, reason, nextBody = t, "Enter", childId
					end
				end
			end
		end

		table.insert(patches, {
			bodyId = currentBody,
			startUT = currentUT,
			endUT = if reason == "None" then math.huge else currentUT + endT,
			r0 = r,
			v0 = v,
			endReason = reason,
			nextBodyId = nextBody,
			elements = el,
		})
		if nextBody == nil then
			break
		end
		local target = nextBody :: number
		local rs, vs = Kepler.propagate(mu, r, v, endT)
		local tAbs = currentUT + endT
		local newPos = Vec3d.add(rs, Universe.bodyOffset(currentBody, target, tAbs))
		local newVel = Vec3d.add(vs, Universe.bodyVelocityOffset(currentBody, target, tAbs))
		justLeft = if reason == "Exit" then currentBody else nil
		currentBody, currentUT, r, v = target, tAbs, newPos, newVel
	end
	return patches
end

return table.freeze(Rails)
