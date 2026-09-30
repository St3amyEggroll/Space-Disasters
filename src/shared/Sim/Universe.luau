--!strict
--[[
	Universe
	Body states as a function of Universal Time, sphere-of-influence lookup and the sun direction.

	Universe frame: origin at Homeworld's centre, +Y = Homeworld's north pole axis, inertial. Planets do not
	rotate in v1. The Moon moves on a circular orbit in the XZ plane (phase measured from +X toward +Z).
	The Sun is visual only: its direction circles the +Y axis once per DAY_LENGTH_S.

	All results are doubles (Vec3d). Pure module.
]]

local Bodies = require(script.Parent.Parent.Config.Bodies)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local SUN_PHASE_AT_UT0 = math.rad(30) -- sun direction angle from +X toward +Z at UT 0 (morning light at the base)
local SUN_ELEVATION = math.rad(15) -- the sun's path is tilted a little so noon light is not perfectly flat
--============================================================================

local Universe = {}

-- Absolute (universe-frame) position of a body's centre at UT.
function Universe.bodyPosition(bodyId: number, ut: number, out: Vec3d?): Vec3d
	local result = out or Vec3d.zero()
	local body = Bodies.get(bodyId)
	local orbit = body.Orbit
	if orbit == nil then
		return Vec3d.set(result, 0, 0, 0)
	end
	local parent = Universe.bodyPosition(orbit.ParentId, ut)
	local angle = orbit.PhaseAtUT0 + orbit.AngularRate * ut
	return Vec3d.set(
		result,
		parent.x + orbit.Radius * math.cos(angle),
		parent.y,
		parent.z + orbit.Radius * math.sin(angle)
	)
end

-- Absolute velocity of a body's centre at UT.
function Universe.bodyVelocity(bodyId: number, ut: number, out: Vec3d?): Vec3d
	local result = out or Vec3d.zero()
	local body = Bodies.get(bodyId)
	local orbit = body.Orbit
	if orbit == nil then
		return Vec3d.set(result, 0, 0, 0)
	end
	local parent = Universe.bodyVelocity(orbit.ParentId, ut)
	local angle = orbit.PhaseAtUT0 + orbit.AngularRate * ut
	local speed = orbit.Radius * orbit.AngularRate
	return Vec3d.set(result, parent.x - speed * math.sin(angle), parent.y, parent.z + speed * math.cos(angle))
end

-- abs(from) - abs(to): add this to a position relative to `from` to make it relative to `to`.
function Universe.bodyOffset(fromBodyId: number, toBodyId: number, ut: number): Vec3d
	if fromBodyId == toBodyId then
		return Vec3d.zero()
	end
	return Vec3d.sub(Universe.bodyPosition(fromBodyId, ut), Universe.bodyPosition(toBodyId, ut))
end

-- Velocity of `from` relative to `to`.
function Universe.bodyVelocityOffset(fromBodyId: number, toBodyId: number, ut: number): Vec3d
	if fromBodyId == toBodyId then
		return Vec3d.zero()
	end
	return Vec3d.sub(Universe.bodyVelocity(fromBodyId, ut), Universe.bodyVelocity(toBodyId, ut))
end

--[[
	Which body's sphere of influence contains a position given relative to `bodyId`? Checks children first
	(entering), then whether the position has left `bodyId`'s SOI (exiting to its parent).
	Returns (newBodyId, positionRelativeToNewBody). Returns the same body when nothing changes.
]]
function Universe.soiTransition(bodyId: number, pos: Vec3d, ut: number): (number, Vec3d)
	for _, child in Bodies.children(bodyId) do
		local childPos = Universe.bodyOffset(child.Id, bodyId, ut)
		if Vec3d.distanceSq(pos, childPos) < child.SoiRadius * child.SoiRadius then
			return child.Id, Vec3d.sub(pos, childPos)
		end
	end
	local body = Bodies.get(bodyId)
	if body.ParentId and Vec3d.lengthSq(pos) > body.SoiRadius * body.SoiRadius then
		local parentId = body.ParentId :: number
		return parentId, Vec3d.add(pos, Universe.bodyOffset(bodyId, parentId, ut))
	end
	return bodyId, pos
end

-- Unit vector from the universe origin toward the sun at UT (universe axes).
function Universe.sunDirection(ut: number): Vec3d
	local angle = SUN_PHASE_AT_UT0 + 2 * math.pi * ut / GameConfig.DAY_LENGTH_S
	local c = math.cos(SUN_ELEVATION)
	return Vec3d.new(c * math.cos(angle), math.sin(SUN_ELEVATION), c * math.sin(angle))
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
