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
local Frames = require(script.Parent.Parent.Math.Frames)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local SUN_PHASE_AT_UT0 = math.rad(30) -- sun direction angle from +X toward +Z at UT 0 (morning light at the base)
local SUN_ELEVATION = math.rad(15) -- the sun's path is tilted a little so noon light is not perfectly flat
-- CHANGED (Phase 2a feedback, D31): flight-pocket "up"
local POCKET_UP_LOW_MIN = 2000 -- m; up = local vertical below max(this, atmosphere top)
local POCKET_UP_BLEND_HEIGHT = 3000 -- m above that over which up turns toward the sun
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

-- CHANGED (Phase 2a playtest 4): debug "/time" shifts the sun's phase (server and every client apply the same
-- offset, replicated as the Globals attribute SUN_OFFSET_ATTRIBUTE). Orbits and UT are untouched.
local sunPhaseOffset = 0
Universe.SUN_OFFSET_ATTRIBUTE = "SunPhaseOffset"

function Universe.setSunPhaseOffset(radians: number)
	if radians == radians and math.abs(radians) < math.huge then
		sunPhaseOffset = radians
	end
end

-- The sun's angle around +Y (from +X toward +Z) at UT. 0 = noon at the base (lat 0 / lon 0).
function Universe.sunAngle(ut: number): number
	return SUN_PHASE_AT_UT0 + sunPhaseOffset + 2 * math.pi * ut / GameConfig.DAY_LENGTH_S
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

-- Unit vector from the universe origin toward the sun at UT (universe axes).
function Universe.sunDirection(ut: number): Vec3d
	local angle = Universe.sunAngle(ut)
	local c = math.cos(SUN_ELEVATION)
	return Vec3d.new(c * math.cos(angle), math.sin(SUN_ELEVATION), c * math.sin(angle))
end

--[[
	CHANGED (Phase 2a feedback, D31): "up" of a flight pocket whose reference point is at `pos` (relative to
	`bodyId`). Low down it is the local vertical, so Roblox's sky, horizon and day/night match the real planet.
	Above the air it turns toward the sun: in space "day" means the sun is visible, but Roblox lights a scene only
	while the sun is above the workspace horizon (an orbit sees the sun far below its local horizon).
	Planet shadow is drawn by SkyLighting, not by this.
]]
function Universe.pocketUp(bodyId: number, pos: Vec3d, ut: number): Vec3d
	local body = Bodies.get(bodyId)
	local r = Vec3d.length(pos)
	if r < 1 then
		return Universe.sunDirection(ut)
	end
	local radial = Vec3d.scale(pos, 1 / r)
	local atmosphere = body.Atmosphere
	local low = math.max(POCKET_UP_LOW_MIN, if atmosphere then atmosphere.Top else 0)
	local t = math.clamp((r - body.Radius - low) / POCKET_UP_BLEND_HEIGHT, 0, 1)
	if t <= 0 then
		return radial
	end
	t = t * t * (3 - 2 * t) -- smoothstep
	local sun = Universe.sunDirection(ut)
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
