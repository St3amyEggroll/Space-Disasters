--!strict
--[[
	Vec3d
	Double-precision 3D vectors stored as plain Luau numbers (64-bit).

	Invariant I1: true (universe) positions must never be stored in Vector3, CFrame or `vector`, which are 32-bit.
	Only convert to Vector3 with toVector3() AFTER subtracting a nearby reference so the value is small.

	Two API styles:
	  * Allocating:   Vec3d.add(a, b) -> new Vec3d          (convenient, for non-hot code)
	  * Out-param:    Vec3d.addInto(out, a, b) -> out       (hot loops; out may alias a or b)
	Rotations take a CFrame (only its rotation is used). The math happens in doubles; only the rotation
	matrix itself is 32-bit, which is fine because orientations do not need more precision than that.
]]

--============================================================================
-- Tunables
--============================================================================
local EPSILON = 1e-12 -- lengths below this normalize to zero
--============================================================================

export type Vec3d = { x: number, y: number, z: number }

local Vec3d = {}

--============================================================================
-- Construction
--============================================================================
function Vec3d.new(x: number, y: number, z: number): Vec3d
	return { x = x, y = y, z = z }
end

function Vec3d.zero(): Vec3d
	return { x = 0, y = 0, z = 0 }
end

function Vec3d.clone(v: Vec3d): Vec3d
	return { x = v.x, y = v.y, z = v.z }
end

function Vec3d.set(out: Vec3d, x: number, y: number, z: number): Vec3d
	out.x, out.y, out.z = x, y, z
	return out
end

function Vec3d.copyInto(out: Vec3d, v: Vec3d): Vec3d
	out.x, out.y, out.z = v.x, v.y, v.z
	return out
end

function Vec3d.fromVector3(v: Vector3): Vec3d
	return { x = v.X, y = v.Y, z = v.Z }
end

-- Converts to a 32-bit Vector3. ONLY for small vectors (offsets from a nearby reference, velocities, directions).
function Vec3d.toVector3(v: Vec3d): Vector3
	return Vector3.new(v.x, v.y, v.z)
end

function Vec3d.unpack(v: Vec3d): (number, number, number)
	return v.x, v.y, v.z
end

--============================================================================
-- Arithmetic (allocating)
--============================================================================
function Vec3d.add(a: Vec3d, b: Vec3d): Vec3d
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end

function Vec3d.sub(a: Vec3d, b: Vec3d): Vec3d
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end

function Vec3d.scale(v: Vec3d, s: number): Vec3d
	return { x = v.x * s, y = v.y * s, z = v.z * s }
end

-- a + b * s
function Vec3d.addScaled(a: Vec3d, b: Vec3d, s: number): Vec3d
	return { x = a.x + b.x * s, y = a.y + b.y * s, z = a.z + b.z * s }
end

function Vec3d.negate(v: Vec3d): Vec3d
	return { x = -v.x, y = -v.y, z = -v.z }
end

function Vec3d.cross(a: Vec3d, b: Vec3d): Vec3d
	return {
		x = a.y * b.z - a.z * b.y,
		y = a.z * b.x - a.x * b.z,
		z = a.x * b.y - a.y * b.x,
	}
end

-- Unit vector in the same direction, or zero for a (near) zero vector.
function Vec3d.normalize(v: Vec3d): Vec3d
	local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if len < EPSILON then
		return { x = 0, y = 0, z = 0 }
	end
	local inv = 1 / len
	return { x = v.x * inv, y = v.y * inv, z = v.z * inv }
end

function Vec3d.lerp(a: Vec3d, b: Vec3d, t: number): Vec3d
	return {
		x = a.x + (b.x - a.x) * t,
		y = a.y + (b.y - a.y) * t,
		z = a.z + (b.z - a.z) * t,
	}
end

--============================================================================
-- Arithmetic (out-param; out may alias inputs)
--============================================================================
function Vec3d.addInto(out: Vec3d, a: Vec3d, b: Vec3d): Vec3d
	out.x, out.y, out.z = a.x + b.x, a.y + b.y, a.z + b.z
	return out
end

function Vec3d.subInto(out: Vec3d, a: Vec3d, b: Vec3d): Vec3d
	out.x, out.y, out.z = a.x - b.x, a.y - b.y, a.z - b.z
	return out
end

function Vec3d.scaleInto(out: Vec3d, v: Vec3d, s: number): Vec3d
	out.x, out.y, out.z = v.x * s, v.y * s, v.z * s
	return out
end

-- out = a + b * s
function Vec3d.addScaledInto(out: Vec3d, a: Vec3d, b: Vec3d, s: number): Vec3d
	out.x, out.y, out.z = a.x + b.x * s, a.y + b.y * s, a.z + b.z * s
	return out
end

function Vec3d.crossInto(out: Vec3d, a: Vec3d, b: Vec3d): Vec3d
	local x = a.y * b.z - a.z * b.y
	local y = a.z * b.x - a.x * b.z
	local z = a.x * b.y - a.y * b.x
	out.x, out.y, out.z = x, y, z
	return out
end

function Vec3d.normalizeInto(out: Vec3d, v: Vec3d): Vec3d
	local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	if len < EPSILON then
		out.x, out.y, out.z = 0, 0, 0
		return out
	end
	local inv = 1 / len
	out.x, out.y, out.z = v.x * inv, v.y * inv, v.z * inv
	return out
end

--============================================================================
-- Scalars
--============================================================================
function Vec3d.dot(a: Vec3d, b: Vec3d): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end

function Vec3d.lengthSq(v: Vec3d): number
	return v.x * v.x + v.y * v.y + v.z * v.z
end

function Vec3d.length(v: Vec3d): number
	return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
end

function Vec3d.distance(a: Vec3d, b: Vec3d): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

function Vec3d.distanceSq(a: Vec3d, b: Vec3d): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- Angle between two vectors in radians (0..pi). Returns 0 if either is zero.
function Vec3d.angle(a: Vec3d, b: Vec3d): number
	local la = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
	local lb = math.sqrt(b.x * b.x + b.y * b.y + b.z * b.z)
	if la < EPSILON or lb < EPSILON then
		return 0
	end
	local c = (a.x * b.x + a.y * b.y + a.z * b.z) / (la * lb)
	return math.acos(math.clamp(c, -1, 1))
end

function Vec3d.equalsApprox(a: Vec3d, b: Vec3d, tolerance: number): boolean
	return math.abs(a.x - b.x) <= tolerance and math.abs(a.y - b.y) <= tolerance and math.abs(a.z - b.z) <= tolerance
end

function Vec3d.isFinite(v: Vec3d): boolean
	-- NaN ~= NaN, and inf - inf is NaN, so this rejects both
	local s = v.x + v.y + v.z
	return s == s and s - s == 0
end

--============================================================================
-- Rotation by a CFrame's rotation part (math in doubles)
--============================================================================

-- out = rot * v  (rotate v from rot's local axes into the parent axes)
function Vec3d.rotateInto(out: Vec3d, rot: CFrame, v: Vec3d): Vec3d
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rot:GetComponents()
	local x, y, z = v.x, v.y, v.z
	out.x = r00 * x + r01 * y + r02 * z
	out.y = r10 * x + r11 * y + r12 * z
	out.z = r20 * x + r21 * y + r22 * z
	return out
end

-- out = rot^-1 * v  (rotate v from the parent axes into rot's local axes; rot must be orthonormal)
function Vec3d.invRotateInto(out: Vec3d, rot: CFrame, v: Vec3d): Vec3d
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = rot:GetComponents()
	local x, y, z = v.x, v.y, v.z
	out.x = r00 * x + r10 * y + r20 * z
	out.y = r01 * x + r11 * y + r21 * z
	out.z = r02 * x + r12 * y + r22 * z
	return out
end

function Vec3d.rotate(rot: CFrame, v: Vec3d): Vec3d
	return Vec3d.rotateInto({ x = 0, y = 0, z = 0 }, rot, v)
end

function Vec3d.invRotate(rot: CFrame, v: Vec3d): Vec3d
	return Vec3d.invRotateInto({ x = 0, y = 0, z = 0 }, rot, v)
end

function Vec3d.toString(v: Vec3d, decimals: number?): string
	local fmt = "%." .. tostring(decimals or 3) .. "f"
	return "(" .. string.format(fmt, v.x) .. ", " .. string.format(fmt, v.y) .. ", " .. string.format(fmt, v.z) .. ")"
end

return table.freeze(Vec3d)
