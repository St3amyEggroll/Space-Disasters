--!strict
--[[
	Universe
	Body states as a function of Universal Time, sphere-of-influence lookup and the sun direction.

	Universe frame: origin at Homeworld's centre, +Y = Homeworld's north pole axis, inertial. Planets do not
	rotate in v1. The Moon moves on a circular orbit in the XZ plane (phase measured from +X toward +Z).
	The Sun is visual only: its direction circles the +Y axis once per DAY_LENGTH_S.

	CHANGED (Solar system): Sol is the root body (Config/Bodies, D51). Earth and Mars orbit it, the Mun orbits Earth.
	  * Heliocentric frame: Sol's centre, Sol's fixed axes (every planet orbit lies in its XZ plane).
	  * Body axes: every body has axes M_B(ut) (columns = the body's X, Y, Z in heliocentric axes). A body with a
	    Spin turns so that, seen from its centre, the sun sits at declination TiltDeg and hour angle
	    PhaseAtUT0 + 2 pi ut / DayLengthS: Y = cos(tilt) Y_sol + sin(tilt) s, with s the horizontal direction to the
	    sun, then a turn about Y by the hour angle. For Earth this is exactly the old visual sun (sunDirection is
	    unchanged), so day and night on Earth and the Mun are unchanged. Bodies without a Spin use their parent's
	    axes (the Mun: Earth's), so the whole Earth-Mun system is computed exactly as before.
	  * Physics in a body's SOI treats its axes as inertial (as it always did on Earth: no Coriolis). Positions,
	    velocities and attitudes are re-expressed when they change body: p_to = M_to^T (M_from p + P_from - P_to),
	    v_to = M_to^T (M_from v + V_from - V_to) (no frame-rotation term: a relative speed is kept exactly), and an
	    attitude is turned by M_to^T M_from (axesRotation).
	  * bodyOffset(from, to) is the centre of `from` relative to `to`, in `to`'s axes. Adding it to a position given
	    relative to `from` is exact only when both bodies share axes (sameAxes: the Earth-Mun system); toBody /
	    transferState / axesRotation do the full conversion for every pair.
	  * The universe frame (bodyPosition, toUniverse: "absolute" positions, e.g. Bubbles) is still Earth's centre
	    and axes (Bodies.UNIVERSE_FRAME), so every Earth-Mun number is unchanged.
	  * The sun direction comes from Sol's real position: sunDirectionFrom(bodyId, pos, ut) from any viewer.
	    sunDirection(ut) is the direction from Earth's centre (the old function, same values).

	All results are doubles (Vec3d). Pure module.
]]

local Bodies = require(script.Parent.Parent.Config.Bodies)
local Frames = require(script.Parent.Parent.Math.Frames)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
-- CHANGED (Solar system): SUN_PHASE_AT_UT0 and SUN_ELEVATION moved to Earth's Spin in Config/Bodies
-- CHANGED (Phase 2a feedback, D31): flight-pocket "up"
local POCKET_UP_LOW_MIN = 2000 -- m; up = local vertical below max(this, atmosphere top)
local POCKET_UP_BLEND_HEIGHT = 3000 -- m above that over which up turns toward the sun
local AXES_CACHE = true -- CHANGED (Solar system): remember each body's axes for the last UT asked
--============================================================================

-- CHANGED (Solar system): a body's axes in heliocentric axes, doubles: X = (xx, xy, xz), Y = (yx, ...), Z = (zx, ...)
export type Axes = {
	xx: number,
	xy: number,
	xz: number,
	yx: number,
	yy: number,
	yz: number,
	zx: number,
	zy: number,
	zz: number,
}

local Universe = {}

local ROOT = Bodies.ROOT
local FRAME_BODY = Bodies.UNIVERSE_FRAME
local HOMEWORLD = Bodies.HOMEWORLD

-- CHANGED (Solar system): static per-body data: the axes body (whose Spin sets the axes) of every body
local axesOwner: { [number]: number } = {}
for _, body in Bodies.List do
	axesOwner[body.Id] = Bodies.axesBody(body.Id)
end

-- CHANGED (Phase 2a playtest 4): debug "/time" shifts the sun's phase (server and every client apply the same
-- offset, replicated as the Globals attribute SUN_OFFSET_ATTRIBUTE). Orbits and UT are untouched.
-- CHANGED (Solar system): it turns Earth's axes (Earth's hour angle); other bodies keep theirs.
local sunPhaseOffset = 0
Universe.SUN_OFFSET_ATTRIBUTE = "SunPhaseOffset"

local axesCache: { [number]: Axes } = {}
local axesCacheUT: { [number]: number } = {}

function Universe.setSunPhaseOffset(radians: number)
	if radians == radians and math.abs(radians) < math.huge then
		sunPhaseOffset = radians
		table.clear(axesCacheUT)
	end
end

--============================================================================
-- Heliocentric states (CHANGED (Solar system))
--============================================================================

-- Position of a body's centre relative to its group's axes body, in that body's axes (the Mun relative to Earth).
local function groupPosition(bodyId: number, ut: number, out: Vec3d): Vec3d
	local body = Bodies.get(bodyId)
	local orbit = body.Orbit
	if orbit == nil or axesOwner[bodyId] == bodyId then
		return Vec3d.set(out, 0, 0, 0)
	end
	groupPosition(orbit.ParentId, ut, out)
	local angle = orbit.PhaseAtUT0 + orbit.AngularRate * ut
	out.x += orbit.Radius * math.cos(angle)
	out.z += orbit.Radius * math.sin(angle)
	return out
end

local function groupVelocity(bodyId: number, ut: number, out: Vec3d): Vec3d
	local body = Bodies.get(bodyId)
	local orbit = body.Orbit
	if orbit == nil or axesOwner[bodyId] == bodyId then
		return Vec3d.set(out, 0, 0, 0)
	end
	groupVelocity(orbit.ParentId, ut, out)
	local angle = orbit.PhaseAtUT0 + orbit.AngularRate * ut
	local speed = orbit.Radius * orbit.AngularRate
	out.x -= speed * math.sin(angle)
	out.z += speed * math.cos(angle)
	return out
end

-- Heliocentric position (and velocity) of a body's centre: Sol's centre and axes.
function Universe.heliocentric(bodyId: number, ut: number, outPos: Vec3d?, outVel: Vec3d?): (Vec3d, Vec3d)
	local pos = outPos or Vec3d.zero()
	local vel = outVel or Vec3d.zero()
	local body = Bodies.get(bodyId)
	local orbit = body.Orbit
	if orbit == nil then
		return Vec3d.set(pos, 0, 0, 0), Vec3d.set(vel, 0, 0, 0)
	end
	local parentPos, parentVel = Universe.heliocentric(orbit.ParentId, ut)
	local angle = orbit.PhaseAtUT0 + orbit.AngularRate * ut
	local c, s = math.cos(angle), math.sin(angle)
	local speed = orbit.Radius * orbit.AngularRate
	-- the orbit lies in the parent's XZ plane (parent axes)
	local m = Universe.axes(orbit.ParentId, ut)
	local px, pz = orbit.Radius * c, orbit.Radius * s
	local vx, vz = -speed * s, speed * c
	Vec3d.set(
		pos,
		parentPos.x + m.xx * px + m.zx * pz,
		parentPos.y + m.xy * px + m.zy * pz,
		parentPos.z + m.xz * px + m.zz * pz
	)
	Vec3d.set(
		vel,
		parentVel.x + m.xx * vx + m.zx * vz,
		parentVel.y + m.xy * vx + m.zy * vz,
		parentVel.z + m.xz * vx + m.zz * vz
	)
	return pos, vel
end

-- The sun's hour angle over a spinning body at UT (Earth: Universe.sunAngle).
local function hourAngle(body: Bodies.Body, ut: number): number
	local spin = body.Spin :: Bodies.Spin
	local offset = if body.Id == HOMEWORLD then sunPhaseOffset else 0
	return spin.PhaseAtUT0 + offset + 2 * math.pi * ut / spin.DayLengthS
end

local function computeAxes(bodyId: number, ut: number, out: Axes): Axes
	local owner = axesOwner[bodyId]
	local body = Bodies.get(owner)
	local spin = body.Spin
	if spin == nil then
		out.xx, out.xy, out.xz = 1, 0, 0
		out.yx, out.yy, out.yz = 0, 1, 0
		out.zx, out.zy, out.zz = 0, 0, 1
		return out
	end
	-- s: horizontal unit direction from the body toward Sol (orbits lie in Sol's XZ plane)
	local p = Universe.heliocentric(owner, ut)
	local sx, sz = -p.x, -p.z
	local len = math.sqrt(sx * sx + sz * sz)
	if len < 1e-9 then
		sx, sz, len = 1, 0, 1
	end
	sx, sz = sx / len, sz / len
	local tilt = math.rad(spin.TiltDeg)
	local ct, st = math.cos(tilt), math.sin(tilt)
	-- base axes: Y tilted toward the sun, X toward the sun's foot on the equator, Z = X x Y
	local yx, yy, yz = st * sx, ct, st * sz
	local bx, by, bz = ct * sx, -st, ct * sz
	local zx, zy, zz = by * yz - bz * yy, bz * yx - bx * yz, bx * yy - by * yx
	local phi = hourAngle(body, ut)
	local c, s = math.cos(phi), math.sin(phi)
	out.xx, out.xy, out.xz = c * bx - s * zx, c * by - s * zy, c * bz - s * zz
	out.yx, out.yy, out.yz = yx, yy, yz
	out.zx, out.zy, out.zz = s * bx + c * zx, s * by + c * zy, s * bz + c * zz
	return out
end

-- CHANGED (Solar system): a body's axes in heliocentric axes at UT (shared with its axes group).
function Universe.axes(bodyId: number, ut: number): Axes
	local owner = axesOwner[bodyId]
	if owner == nil then
		error(`Unknown body id {bodyId}`, 2)
	end
	if AXES_CACHE and axesCacheUT[owner] == ut then
		return axesCache[owner]
	end
	-- a fresh table each time: a caller may still hold the axes of another UT
	local out: Axes = { xx = 1, xy = 0, xz = 0, yx = 0, yy = 1, yz = 0, zx = 0, zy = 0, zz = 1 }
	computeAxes(owner, ut, out)
	axesCache[owner] = out
	axesCacheUT[owner] = ut
	return out
end

-- CHANGED (Solar system): do two bodies share axes (offsets between them are pure translations)?
function Universe.sameAxes(a: number, b: number): boolean
	return axesOwner[a] == axesOwner[b]
end

-- body axes -> heliocentric axes
local function toHelio(m: Axes, x: number, y: number, z: number): (number, number, number)
	return m.xx * x + m.yx * y + m.zx * z, m.xy * x + m.yy * y + m.zy * z, m.xz * x + m.yz * y + m.zz * z
end

-- heliocentric axes -> body axes
local function fromHelio(m: Axes, x: number, y: number, z: number): (number, number, number)
	return m.xx * x + m.xy * y + m.xz * z, m.yx * x + m.yy * y + m.yz * z, m.zx * x + m.zy * y + m.zz * z
end

--============================================================================
-- Offsets between bodies
--============================================================================

-- CHANGED (Solar system): centre of `from` relative to `to`, in `to`'s axes (header). Was abs(from) - abs(to).
-- Add it to a position relative to `from` to make it relative to `to` only when sameAxes(from, to) (else: toBody).
function Universe.bodyOffset(fromBodyId: number, toBodyId: number, ut: number, out: Vec3d?): Vec3d
	local result = out or Vec3d.zero()
	if fromBodyId == toBodyId then
		return Vec3d.set(result, 0, 0, 0)
	end
	if axesOwner[fromBodyId] == axesOwner[toBodyId] then
		-- inside one axes group (the Earth-Mun system): the old pure circular-orbit arithmetic
		local a = groupPosition(fromBodyId, ut, Vec3d.zero())
		local b = groupPosition(toBodyId, ut, Vec3d.zero())
		return Vec3d.set(result, a.x - b.x, a.y - b.y, a.z - b.z)
	end
	local pa = Universe.heliocentric(fromBodyId, ut)
	local pb = Universe.heliocentric(toBodyId, ut)
	local x, y, z = fromHelio(Universe.axes(toBodyId, ut), pa.x - pb.x, pa.y - pb.y, pa.z - pb.z)
	return Vec3d.set(result, x, y, z)
end

-- CHANGED (Solar system): velocity of `from`'s centre relative to `to`'s, in `to`'s axes (no frame-rotation term).
function Universe.bodyVelocityOffset(fromBodyId: number, toBodyId: number, ut: number): Vec3d
	if fromBodyId == toBodyId then
		return Vec3d.zero()
	end
	if axesOwner[fromBodyId] == axesOwner[toBodyId] then
		local a = groupVelocity(fromBodyId, ut, Vec3d.zero())
		local b = groupVelocity(toBodyId, ut, Vec3d.zero())
		return Vec3d.sub(a, b)
	end
	local _, va = Universe.heliocentric(fromBodyId, ut)
	local _, vb = Universe.heliocentric(toBodyId, ut)
	local x, y, z = fromHelio(Universe.axes(toBodyId, ut), va.x - vb.x, va.y - vb.y, va.z - vb.z)
	return Vec3d.new(x, y, z)
end

-- Universe-frame (Earth's centre and axes) position of a body's centre at UT.
-- CHANGED (Solar system): Sol and Mars are re-expressed in Earth's (turning) axes.
function Universe.bodyPosition(bodyId: number, ut: number, out: Vec3d?): Vec3d
	return Universe.bodyOffset(bodyId, FRAME_BODY, ut, out)
end

-- Universe-frame velocity of a body's centre at UT.
function Universe.bodyVelocity(bodyId: number, ut: number, out: Vec3d?): Vec3d
	local v = Universe.bodyVelocityOffset(bodyId, FRAME_BODY, ut)
	if out then
		return Vec3d.copyInto(out, v)
	end
	return v
end

--[[
	CHANGED (Solar system): a position given relative to `fromId` (its axes) re-expressed relative to `toId` (its
	axes) at UT. Exact for every pair (a pure translation inside one axes group).
]]
function Universe.toBody(fromId: number, toId: number, ut: number, pos: Vec3d, out: Vec3d?): Vec3d
	local result = out or Vec3d.zero()
	if fromId == toId then
		return Vec3d.copyInto(result, pos)
	end
	if axesOwner[fromId] == axesOwner[toId] then
		local o = Universe.bodyOffset(fromId, toId, ut)
		return Vec3d.set(result, pos.x + o.x, pos.y + o.y, pos.z + o.z)
	end
	local pa = Universe.heliocentric(fromId, ut)
	local pb = Universe.heliocentric(toId, ut)
	local hx, hy, hz = toHelio(Universe.axes(fromId, ut), pos.x, pos.y, pos.z)
	local x, y, z = fromHelio(Universe.axes(toId, ut), hx + pa.x - pb.x, hy + pa.y - pb.y, hz + pa.z - pb.z)
	return Vec3d.set(result, x, y, z)
end

-- CHANGED (Solar system): a direction (no translation) given in `fromId`'s axes, in `toId`'s axes.
function Universe.vectorToBody(fromId: number, toId: number, ut: number, v: Vec3d, out: Vec3d?): Vec3d
	local result = out or Vec3d.zero()
	if axesOwner[fromId] == axesOwner[toId] then
		return Vec3d.copyInto(result, v)
	end
	local hx, hy, hz = toHelio(Universe.axes(fromId, ut), v.x, v.y, v.z)
	local x, y, z = fromHelio(Universe.axes(toId, ut), hx, hy, hz)
	return Vec3d.set(result, x, y, z)
end

-- CHANGED (Solar system): a velocity relative to `fromId` re-expressed relative to `toId` (header).
function Universe.velocityToBody(fromId: number, toId: number, ut: number, vel: Vec3d): Vec3d
	local rotated = Universe.vectorToBody(fromId, toId, ut, vel)
	return Vec3d.add(rotated, Universe.bodyVelocityOffset(fromId, toId, ut))
end

--[[
	CHANGED (Solar system): rotation-only CFrame that turns vectors in `fromId`'s axes into `toId`'s axes
	(M_to^T M_from). An attitude (craft axes -> body axes) changes body as axesRotation * rot; an angular velocity
	as axesRotation:VectorToWorldSpace(w). Identity inside one axes group.
]]
function Universe.axesRotation(fromId: number, toId: number, ut: number): CFrame
	if axesOwner[fromId] == axesOwner[toId] then
		return CFrame.identity
	end
	local a = Universe.axes(fromId, ut)
	local b = Universe.axes(toId, ut)
	local x1, y1, z1 = fromHelio(b, a.xx, a.xy, a.xz)
	local x2, y2, z2 = fromHelio(b, a.yx, a.yy, a.yz)
	local x3, y3, z3 = fromHelio(b, a.zx, a.zy, a.zz)
	return CFrame.fromMatrix(Vector3.zero, Vector3.new(x1, y1, z1), Vector3.new(x2, y2, z2), Vector3.new(x3, y3, z3))
end

--[[
	CHANGED (Solar system): a state (position and velocity relative to `fromId`) re-expressed relative to `toId`,
	plus the rotation for its attitude (nil when the axes are the same). Used on every SOI change.
]]
function Universe.transferState(
	fromId: number,
	toId: number,
	ut: number,
	pos: Vec3d,
	vel: Vec3d
): (Vec3d, Vec3d, CFrame?)
	local newPos = Universe.toBody(fromId, toId, ut, pos)
	local newVel = Universe.velocityToBody(fromId, toId, ut, vel)
	local rotation = if axesOwner[fromId] == axesOwner[toId] then nil else Universe.axesRotation(fromId, toId, ut)
	return newPos, newVel, rotation
end

--[[
	CHANGED (Solar system): frame helpers for things on another body than a pocket frame's reference (crafts drawn
	in a pocket, transfers between pockets). Inside one axes group they are the old offset arithmetic.
	  frameTransform(from, to, ut)               workspace of frame `from` -> workspace of frame `to` (same point)
	  cframeInFrame(frame, bodyId, pos, rot, ut) a pose relative to bodyId (its axes) -> workspace CFrame
	  pointInFrame(frame, bodyId, pos, ut)       a position relative to bodyId -> workspace Vector3
]]
function Universe.frameTransform(from: Frames.Frame, to: Frames.Frame, ut: number): CFrame
	local a, b = from.refBodyId, to.refBodyId
	if a == b then
		return Frames.relativeTransform(from, to)
	elseif axesOwner[a] == axesOwner[b] then
		return Frames.relativeTransform(from, to, Universe.bodyOffset(a, b, ut))
	end
	return Frames.relativeTransformAxes(
		from,
		to,
		Universe.toBody(a, b, ut, from.refPos),
		Universe.axesRotation(a, b, ut)
	)
end

function Universe.cframeInFrame(frame: Frames.Frame, bodyId: number, pos: Vec3d, rot: CFrame, ut: number): CFrame
	local ref = frame.refBodyId
	if bodyId == ref then
		return Frames.cframeToWorkspace(frame, pos, rot)
	elseif axesOwner[bodyId] == axesOwner[ref] then
		return Frames.cframeToWorkspace(frame, pos, rot, Universe.bodyOffset(bodyId, ref, ut))
	end
	local p = Universe.toBody(bodyId, ref, ut, pos)
	return Frames.cframeToWorkspace(frame, p, Universe.axesRotation(bodyId, ref, ut) * rot)
end

function Universe.pointInFrame(frame: Frames.Frame, bodyId: number, pos: Vec3d, ut: number): Vector3
	local ref = frame.refBodyId
	if bodyId == ref then
		return Frames.pointToWorkspace(frame, pos)
	elseif axesOwner[bodyId] == axesOwner[ref] then
		return Frames.pointToWorkspace(frame, pos, Universe.bodyOffset(bodyId, ref, ut))
	end
	return Frames.pointToWorkspace(frame, Universe.toBody(bodyId, ref, ut, pos))
end

-- CHANGED (Solar system): a body-relative position in the universe frame (Earth's centre and axes).
function Universe.toUniverse(bodyId: number, pos: Vec3d, ut: number, out: Vec3d?): Vec3d
	return Universe.toBody(bodyId, FRAME_BODY, ut, pos, out)
end

--[[
	Which body's sphere of influence contains a position given relative to `bodyId`? Checks children first
	(entering), then whether the position has left `bodyId`'s SOI (exiting to its parent).
	Returns (newBodyId, positionRelativeToNewBody). Returns the same body when nothing changes.
	CHANGED (Solar system): the new position is in the new body's axes (toBody); velocities and attitudes must be
	converted with transferState / axesRotation, not with offsets.
]]
function Universe.soiTransition(bodyId: number, pos: Vec3d, ut: number): (number, Vec3d)
	for _, child in Bodies.children(bodyId) do
		local childPos = Universe.bodyOffset(child.Id, bodyId, ut)
		if Vec3d.distanceSq(pos, childPos) < child.SoiRadius * child.SoiRadius then
			return child.Id, Universe.toBody(bodyId, child.Id, ut, pos)
		end
	end
	local body = Bodies.get(bodyId)
	if body.ParentId and Vec3d.lengthSq(pos) > body.SoiRadius * body.SoiRadius then
		local parentId = body.ParentId :: number
		return parentId, Universe.toBody(bodyId, parentId, ut, pos)
	end
	return bodyId, pos
end

-- The sun's angle around +Y (from +X toward +Z) at UT. 0 = noon at the base (lat 0 / lon 0).
-- CHANGED (Solar system): Earth's hour angle (its Spin), the same numbers as before.
function Universe.sunAngle(ut: number): number
	return hourAngle(Bodies.get(HOMEWORLD), ut)
end

-- Local time of day at the base (hours, 0..24, 12 = noon) at UT.
function Universe.baseHour(ut: number): number
	return (Universe.sunAngle(ut) / (2 * math.pi) * 24 + 12) % 24
end

-- Phase offset that makes the base's local time `hour` at UT.
function Universe.sunOffsetForBaseHour(hour: number, ut: number): number
	local wanted = (hour - 12) / 24 * 2 * math.pi
	return wanted - (Universe.sunAngle(ut) - sunPhaseOffset)
end

-- Unit vector from Earth's centre toward the sun at UT (Earth's axes = universe axes).
-- CHANGED (Solar system): Sol's real direction from Earth; by construction of Earth's axes the old formula.
function Universe.sunDirection(ut: number): Vec3d
	local spin = Bodies.get(HOMEWORLD).Spin :: Bodies.Spin
	local angle = Universe.sunAngle(ut)
	local tilt = math.rad(spin.TiltDeg)
	local c = math.cos(tilt)
	return Vec3d.new(c * math.cos(angle), math.sin(tilt), c * math.sin(angle))
end

--[[
	CHANGED (Solar system): unit vector from a viewer at `pos` (relative to `bodyId`, its axes) toward Sol's centre,
	in `bodyId`'s axes. The lighting of every view comes from this.
]]
function Universe.sunDirectionFrom(bodyId: number, pos: Vec3d, ut: number): Vec3d
	local sun = if bodyId == ROOT then Vec3d.zero() else Universe.bodyOffset(ROOT, bodyId, ut)
	local d = Vec3d.sub(sun, pos)
	local length = Vec3d.length(d)
	if length < 1e-9 then
		return Vec3d.new(0, 1, 0)
	end
	return Vec3d.scale(d, 1 / length)
end

--[[
	CHANGED (Phase 2a feedback, D31): "up" of a flight pocket whose reference point is at `pos` (relative to
	`bodyId`). Low down it is the local vertical, so Roblox's sky, horizon and day/night match the real planet.
	Above the air it turns toward the sun: in space "day" means the sun is visible, but Roblox lights a scene only
	while the sun is above the workspace horizon (an orbit sees the sun far below its local horizon).
	Planet shadow is drawn by SkyLighting, not by this.
	CHANGED (Solar system): toward Sol's real position from `pos`; around Sol itself up is simply toward it.
]]
function Universe.pocketUp(bodyId: number, pos: Vec3d, ut: number): Vec3d
	local body = Bodies.get(bodyId)
	local sun = Universe.sunDirectionFrom(bodyId, pos, ut)
	local r = Vec3d.length(pos)
	if r < 1 or body.Kind == "Star" then
		return sun
	end
	local radial = Vec3d.scale(pos, 1 / r)
	local atmosphere = body.Atmosphere
	local low = math.max(POCKET_UP_LOW_MIN, if atmosphere then atmosphere.Top else 0)
	local t = math.clamp((r - body.Radius - low) / POCKET_UP_BLEND_HEIGHT, 0, 1)
	if t <= 0 then
		return radial
	end
	t = t * t * (3 - 2 * t) -- smoothstep
	local up = Vec3d.new(
		radial.x + (sun.x - radial.x) * t,
		radial.y + (sun.y - radial.y) * t,
		radial.z + (sun.z - radial.z) * t
	)
	local length = Vec3d.length(up)
	if length < 1e-3 then
		return radial
	end
	return Vec3d.scale(up, 1 / length)
end

-- Rotation (pocket axes in universe axes: X east, Y up, Z north) of a flight pocket at `pos` (D31).
function Universe.pocketRotation(bodyId: number, pos: Vec3d, ut: number): CFrame
	return Frames.surfaceRotation(Universe.pocketUp(bodyId, pos, ut))
end

-- Altitude above sea level of a position relative to a body.
function Universe.altitude(bodyId: number, pos: Vec3d): number
	return Vec3d.length(pos) - Bodies.get(bodyId).Radius
end

-- Circular orbit speed at a radius from a body's centre.
function Universe.circularSpeed(bodyId: number, radius: number): number
	return math.sqrt(Bodies.get(bodyId).Mu / radius)
end

return table.freeze(Universe)
