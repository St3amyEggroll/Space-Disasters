--!strict
--[[
	PuppetMath (Ground puppets)
	Pure maths for Render/Puppets' ground puppets: players on foot in ANOTHER pocket (the base, or a flight pocket
	whose craft has landed) drawn at their true position in the local pocket. No services and no Instances, so the
	offline Lune suite tests it (src/server/Tests/PuppetMath.spec.luau).

	Pocket of a workspace position (same rule as PocketService.pocketAt / PocketController): the base pocket (0)
	within captureRadius * 1.5 of the workspace origin, else the flight pocket whose slot origin is within
	captureRadius, else none.

	Position: a workspace point in the source pocket goes to universe coordinates with the source pocket's frame
	(relative to its reference body, doubles), the body offset moves it onto the local frame's reference body, and
	only then is it turned into a local workspace point (invariant I1). The rotation is
	  (local refRot)^-1 * (source refRot) * (rotation in the source pocket).

	Animation retargeting: a Motor6D animates Part1 = Part0 * C0 * Transform * C1^-1, so the joint turns its child
	by C0.R * Transform.R * C0.R^-1 in the parent's axes. To show the same turn on a rig whose joint has another C0
	rotation (R6 character -> R15 puppet, or -> the blocky stand-in), the puppet's Transform is
	  Q * Transform * Q^-1,  Q = (puppet C0.R)^-1 * (real C0.R)
	which is just Transform when both C0s turn the same way (R15 -> R15). Joint names of both rigs map to one role
	(R6 "Left Hip" and R15 "LeftHip" -> "LeftHip"; R6/stand-in "RootJoint" and R15 "Root" -> "Root").

	API:
	  PuppetMath.slotPocket(position, captureRadius, origins, ids) -> number?
	  PuppetMath.trueInto(from, bodyOffset, position, out) -> Vec3d   relative to the local frame's reference body
	  PuppetMath.rotationBetween(from, to) -> CFrame                   source pocket axes -> local pocket axes
	  PuppetMath.cframeIn(to, truePos, rotation, cf) -> CFrame         cf (source workspace) in the local workspace
	  PuppetMath.jointRole(name) -> string
	  PuppetMath.retargetFor(puppetC0, realC0) -> (q, qInverse, direct)
	  PuppetMath.retarget(transform, q, qInverse, direct) -> CFrame
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Frame = Frames.Frame
type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local BASE_CAPTURE_FACTOR = 1.5 -- the base pocket's capture radius is this times a flight slot's (PocketService)
local DIRECT_TRACE_EPSILON = 1e-6 -- rotation trace this close to 3 counts as no turn between two joint C0s
--============================================================================

-- R6 and stand-in Motor6D names -> the R15 name of the same joint (others map to themselves)
local JOINT_ROLES: { [string]: string } = {
	["Left Shoulder"] = "LeftShoulder",
	["Right Shoulder"] = "RightShoulder",
	["Left Hip"] = "LeftHip",
	["Right Hip"] = "RightHip",
	RootJoint = "Root",
}

local PuppetMath = {}

--============================================================================
-- Pockets and frames
--============================================================================

-- The pocket a workspace position is in: 0 near the origin, ids[i] near origins[i], or nil.
function PuppetMath.slotPocket(position: Vector3, captureRadius: number, origins: { Vector3 }, ids: { number }): number?
	if position.Magnitude < captureRadius * BASE_CAPTURE_FACTOR then
		return 0
	end
	for index, origin in origins do
		if (position - origin).Magnitude < captureRadius then
			return ids[index]
		end
	end
	return nil
end

--[[
	True position (doubles) of a workspace point of the `from` pocket, relative to the LOCAL frame's reference body.
	bodyOffset = abs(from.refBodyId) - abs(local reference body) at the render UT, nil when they are the same body.
]]
function PuppetMath.trueInto(from: Frame, bodyOffset: Vec3d?, position: Vector3, out: Vec3d): Vec3d
	Frames.pointFromWorkspace(from, position, out)
	if bodyOffset then
		Vec3d.addInto(out, out, bodyOffset)
	end
	return out
end

-- Rotation from the `from` pocket's workspace axes to the `to` pocket's workspace axes.
function PuppetMath.rotationBetween(from: Frame, to: Frame): CFrame
	return to.refRotInv * from.refRot
end

-- A CFrame of the source pocket in the `to` pocket: truePos from trueInto, rotation from rotationBetween.
function PuppetMath.cframeIn(to: Frame, truePos: Vec3d, rotation: CFrame, cf: CFrame): CFrame
	local position = Frames.pointToWorkspaceXYZ(to, truePos.x, truePos.y, truePos.z)
	return rotation * Frames.rotationOnly(cf) + position
end

--============================================================================
-- Animation retargeting
--============================================================================

function PuppetMath.jointRole(name: string): string
	return JOINT_ROLES[name] or name
end

-- Conjugation that carries a Transform from a joint with C0 `realC0` to one with C0 `puppetC0` (see header).
function PuppetMath.retargetFor(puppetC0: CFrame, realC0: CFrame): (CFrame, CFrame, boolean)
	local q = Frames.rotationOnly(puppetC0):Inverse() * Frames.rotationOnly(realC0)
	local _, _, _, r00, _, _, _, r11, _, _, _, r22 = q:GetComponents()
	local direct = r00 + r11 + r22 > 3 - DIRECT_TRACE_EPSILON
	return q, q:Inverse(), direct
end

function PuppetMath.retarget(transform: CFrame, q: CFrame, qInverse: CFrame, direct: boolean): CFrame
	if direct then
		return transform
	end
	return q * transform * qInverse
end

return table.freeze(PuppetMath)
