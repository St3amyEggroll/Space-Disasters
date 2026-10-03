--!strict
--[[
	Frames
	Transforms between true (universe) coordinates and pocket-local workspace coordinates.

	A pocket frame has:
	  refBodyId   the body the reference position is measured from
	  refPos      reference point relative to that body's center, universe axes, doubles
	  refRot      rotation-only CFrame; its columns are the pocket axes expressed in universe axes
	  slotOrigin  where the reference point sits in the workspace (a fixed pocket slot)
	  frameEpoch  incremented by the server on every rebase

	  toWorkspace(p)   = slotOrigin + refRot^-1 * (p - refPos)     (subtraction in doubles FIRST, invariant I1)
	  fromWorkspace(w) = refPos + refRot * (w - slotOrigin)

	Positions of things on a different body than the frame's reference are passed with a bodyOffset:
	  bodyOffset = abs(thing's body) - abs(frame's reference body), both at the same UT (from Universe).

	Surface frames: Y = radial up, Z = north tangent, X = east (right-handed, X = Y x Z).
	Lat/lon convention: up(lat, lon) = (cos lat cos lon, sin lat, cos lat sin lon); longitude increases toward east.
]]

local Vec3d = require(script.Parent.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local POLE_EPSILON = 1e-12 -- horizontal length below which a surface frame is treated as at a pole
--============================================================================

export type Frame = {
	refBodyId: number,
	refPos: Vec3d,
	refRot: CFrame,
	refRotInv: CFrame,
	slotOrigin: Vector3,
	frameEpoch: number,
	-- refRot matrix components cached as doubles for hot paths (row-major)
	r00: number,
	r01: number,
	r02: number,
	r10: number,
	r11: number,
	r12: number,
	r20: number,
	r21: number,
	r22: number,
}

local Frames = {}

-- Strips the translation from a CFrame, keeping only its rotation.
function Frames.rotationOnly(cf: CFrame): CFrame
	return cf - cf.Position
end

local function cacheRotation(frame: Frame, rot: CFrame)
	local r = Frames.rotationOnly(rot)
	frame.refRot = r
	frame.refRotInv = r:Inverse()
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = r:GetComponents()
	frame.r00, frame.r01, frame.r02 = r00, r01, r02
	frame.r10, frame.r11, frame.r12 = r10, r11, r12
	frame.r20, frame.r21, frame.r22 = r20, r21, r22
end

function Frames.new(refBodyId: number, refPos: Vec3d, refRot: CFrame, slotOrigin: Vector3, frameEpoch: number?): Frame
	local frame: Frame = {
		refBodyId = refBodyId,
		refPos = Vec3d.clone(refPos),
		refRot = CFrame.identity,
		refRotInv = CFrame.identity,
		slotOrigin = slotOrigin,
		frameEpoch = frameEpoch or 0,
		r00 = 1,
		r01 = 0,
		r02 = 0,
		r10 = 0,
		r11 = 1,
		r12 = 0,
		r20 = 0,
		r21 = 0,
		r22 = 1,
	}
	cacheRotation(frame, refRot)
	return frame
end

-- Replaces the reference in place (slot and epoch are unchanged; the caller bumps frameEpoch on a rebase).
function Frames.setReference(frame: Frame, refBodyId: number, refPos: Vec3d, refRot: CFrame)
	frame.refBodyId = refBodyId
	Vec3d.copyInto(frame.refPos, refPos)
	cacheRotation(frame, refRot)
end

function Frames.clone(frame: Frame): Frame
	return Frames.new(frame.refBodyId, frame.refPos, frame.refRot, frame.slotOrigin, frame.frameEpoch)
end

--============================================================================
-- Points
--============================================================================

-- Hot path: (x, y, z) relative to the frame's reference body center -> workspace position.
function Frames.pointToWorkspaceXYZ(frame: Frame, x: number, y: number, z: number): Vector3
	local ref = frame.refPos
	local dx, dy, dz = x - ref.x, y - ref.y, z - ref.z -- doubles: exact enough, and now small
	local o = frame.slotOrigin
	return Vector3.new(
		o.X + frame.r00 * dx + frame.r10 * dy + frame.r20 * dz,
		o.Y + frame.r01 * dx + frame.r11 * dy + frame.r21 * dz,
		o.Z + frame.r02 * dx + frame.r12 * dy + frame.r22 * dz
	)
end

-- pos is relative to its own body center; bodyOffset = abs(pos body) - abs(frame ref body), nil if same body.
function Frames.pointToWorkspace(frame: Frame, pos: Vec3d, bodyOffset: Vec3d?): Vector3
	if bodyOffset then
		return Frames.pointToWorkspaceXYZ(frame, pos.x + bodyOffset.x, pos.y + bodyOffset.y, pos.z + bodyOffset.z)
	end
	return Frames.pointToWorkspaceXYZ(frame, pos.x, pos.y, pos.z)
end

-- Workspace position -> position relative to the frame's reference body center (doubles).
function Frames.pointFromWorkspace(frame: Frame, p: Vector3, out: Vec3d?): Vec3d
	local o = frame.slotOrigin
	local lx, ly, lz = p.X - o.X, p.Y - o.Y, p.Z - o.Z
	local ref = frame.refPos
	local result = out or Vec3d.zero()
	result.x = ref.x + frame.r00 * lx + frame.r01 * ly + frame.r02 * lz
	result.y = ref.y + frame.r10 * lx + frame.r11 * ly + frame.r12 * lz
	result.z = ref.z + frame.r20 * lx + frame.r21 * ly + frame.r22 * lz
	return result
end

--============================================================================
-- Directions and velocities (no translation)
--============================================================================

-- Universe-axes vector -> pocket-axes Vector3.
function Frames.vectorToWorkspace(frame: Frame, v: Vec3d): Vector3
	local x, y, z = v.x, v.y, v.z
	return Vector3.new(
		frame.r00 * x + frame.r10 * y + frame.r20 * z,
		frame.r01 * x + frame.r11 * y + frame.r21 * z,
		frame.r02 * x + frame.r12 * y + frame.r22 * z
	)
end

-- Pocket-axes Vector3 -> universe-axes vector (doubles).
function Frames.vectorFromWorkspace(frame: Frame, v: Vector3, out: Vec3d?): Vec3d
	local x, y, z = v.X, v.Y, v.Z
	local result = out or Vec3d.zero()
	result.x = frame.r00 * x + frame.r01 * y + frame.r02 * z
	result.y = frame.r10 * x + frame.r11 * y + frame.r12 * z
	result.z = frame.r20 * x + frame.r21 * y + frame.r22 * z
	return result
end

--============================================================================
-- Rotations
--============================================================================

-- Universe rotation (craft axes -> universe axes) -> workspace rotation.
function Frames.rotationToWorkspace(frame: Frame, rot: CFrame): CFrame
	return frame.refRotInv * Frames.rotationOnly(rot)
end

-- Workspace rotation -> universe rotation.
function Frames.rotationFromWorkspace(frame: Frame, wsRot: CFrame): CFrame
	return frame.refRot * Frames.rotationOnly(wsRot)
end

-- Full pose: position relative to its body (+ optional body offset) and universe rotation -> workspace CFrame.
function Frames.cframeToWorkspace(frame: Frame, pos: Vec3d, rot: CFrame, bodyOffset: Vec3d?): CFrame
	local p = Frames.pointToWorkspace(frame, pos, bodyOffset)
	return CFrame.new(p) * Frames.rotationToWorkspace(frame, rot)
end

-- Workspace CFrame -> (position relative to the frame's reference body, universe rotation).
function Frames.cframeFromWorkspace(frame: Frame, cf: CFrame, outPos: Vec3d?): (Vec3d, CFrame)
	return Frames.pointFromWorkspace(frame, cf.Position, outPos), Frames.rotationFromWorkspace(frame, cf)
end

--============================================================================
-- Rebase / transfer
--============================================================================

--[[
	Rigid transform M that maps workspace coordinates in frame `from` to workspace coordinates in frame `to`
	for the same true point: M = T_to o T_from^-1. Apply it with M * cf (or M:PointToWorldSpace(p)).

	bodyOffset = abs(from.refBody) - abs(to.refBody) at the same UT; nil when both frames use the same body.
	The reference difference is computed in doubles before any conversion to float.
]]
function Frames.relativeTransform(from: Frame, to: Frame, bodyOffset: Vec3d?): CFrame
	local d = Vec3d.sub(from.refPos, to.refPos)
	if bodyOffset then
		Vec3d.addInto(d, d, bodyOffset)
	end
	-- d expressed in the destination pocket's axes
	local dx = to.r00 * d.x + to.r10 * d.y + to.r20 * d.z
	local dy = to.r01 * d.x + to.r11 * d.y + to.r21 * d.z
	local dz = to.r02 * d.x + to.r12 * d.y + to.r22 * d.z
	local q = to.refRotInv * from.refRot
	local t = to.slotOrigin + Vector3.new(dx, dy, dz) - q:VectorToWorldSpace(from.slotOrigin)
	return CFrame.new(t) * q
end

--[[
	CHANGED (Solar system): relativeTransform between frames whose reference bodies have DIFFERENT axes (Earth, Sol
	and Mars each turn their own way). `fromRefInTo` = from.refPos re-expressed relative to to.refBodyId (doubles,
	Universe.toBody); `axes` = rotation from from-body axes to to-body axes (Universe.axesRotation).
	Universe.frameTransform picks this or relativeTransform.
]]
function Frames.relativeTransformAxes(from: Frame, to: Frame, fromRefInTo: Vec3d, axes: CFrame): CFrame
	local d = Vec3d.sub(fromRefInTo, to.refPos)
	local dx = to.r00 * d.x + to.r10 * d.y + to.r20 * d.z
	local dy = to.r01 * d.x + to.r11 * d.y + to.r21 * d.z
	local dz = to.r02 * d.x + to.r12 * d.y + to.r22 * d.z
	local q = to.refRotInv * Frames.rotationOnly(axes) * from.refRot
	local t = to.slotOrigin + Vector3.new(dx, dy, dz) - q:VectorToWorldSpace(from.slotOrigin)
	return CFrame.new(t) * q
end

--============================================================================
-- Surface frames
--============================================================================

-- Unit radial "up" vector for a latitude/longitude (radians).
function Frames.surfaceUp(lat: number, lon: number): Vec3d
	local cl = math.cos(lat)
	return Vec3d.new(cl * math.cos(lon), math.sin(lat), cl * math.sin(lon))
end

-- Latitude/longitude (radians) of a body-relative position.
function Frames.latLon(pos: Vec3d): (number, number)
	local horizontal = math.sqrt(pos.x * pos.x + pos.z * pos.z)
	return math.atan2(pos.y, horizontal), math.atan2(pos.z, pos.x)
end

--[[
	Surface-aligned rotation for a radial up vector: columns X = east, Y = up, Z = north.
	At the poles north is undefined; there we use universe -X projected onto the tangent plane (arbitrary but stable).
]]
function Frames.surfaceRotation(up: Vec3d): CFrame
	local u = Vec3d.normalize(up)
	-- north = projection of universe +Y onto the tangent plane
	local nx, ny, nz = -u.x * u.y, 1 - u.y * u.y, -u.z * u.y
	local nLen = math.sqrt(nx * nx + ny * ny + nz * nz)
	if nLen < POLE_EPSILON then
		-- project universe -X instead
		local d = -u.x
		nx, ny, nz = -1 - u.x * d, -u.y * d, -u.z * d
		nLen = math.sqrt(nx * nx + ny * ny + nz * nz)
	end
	nx, ny, nz = nx / nLen, ny / nLen, nz / nLen
	-- east = up x north
	local ex = u.y * nz - u.z * ny
	local ey = u.z * nx - u.x * nz
	local ez = u.x * ny - u.y * nx
	return CFrame.fromMatrix(Vector3.zero, Vector3.new(ex, ey, ez), Vector3.new(u.x, u.y, u.z), Vector3.new(nx, ny, nz))
end

return table.freeze(Frames)
