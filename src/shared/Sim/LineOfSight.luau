--!strict
--[[
	LineOfSight (Phase 3)
	Is the straight line between two true positions blocked by a physical body (planet or moon)? Used to hide craft
	markers behind planets (markers are drawn on top of everything, so they need their own occlusion test).
	All maths in doubles (invariant I1). Pure, so Lune can test it.
]]

local Bodies = require(script.Parent.Parent.Config.Bodies)
local Universe = require(script.Parent.Universe)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
-- m below the surface a line must pass to count as blocked: a line grazing the ground (a craft on the ground a few
-- km away, which the flat tile cap and hills make visible anyway) is not blocked
local SURFACE_MARGIN = 300
--============================================================================

local LineOfSight = {}

local physicalBodies = Bodies.physicalBodies() -- fixed list, read once

-- Does the segment from `a` to `b` pass through a sphere of `radius` at `center`? (all relative to one origin)
function LineOfSight.segmentHitsSphere(a: Vec3d, b: Vec3d, center: Vec3d, radius: number): boolean
	local dx, dy, dz = b.x - a.x, b.y - a.y, b.z - a.z
	local lengthSq = dx * dx + dy * dy + dz * dz
	local cx, cy, cz = center.x - a.x, center.y - a.y, center.z - a.z
	local t = if lengthSq > 0 then math.clamp((cx * dx + cy * dy + cz * dz) / lengthSq, 0, 1) else 0
	local px, py, pz = dx * t - cx, dy * t - cy, dz * t - cz
	local limit = math.max(radius - SURFACE_MARGIN, 0)
	return px * px + py * py + pz * pz < limit * limit
end

--[[
	Is the line from `from` to `to` (both relative to `refBodyId`'s centre at `ut`) blocked by any physical body?
]]
function LineOfSight.blocked(refBodyId: number, from: Vec3d, to: Vec3d, ut: number): boolean
	for _, body in physicalBodies do
		local center = if body.Id == refBodyId then Vec3d.zero() else Universe.bodyOffset(body.Id, refBodyId, ut)
		if LineOfSight.segmentHitsSphere(from, to, center, body.Radius) then
			return true
		end
	end
	return false
end

return table.freeze(LineOfSight)
