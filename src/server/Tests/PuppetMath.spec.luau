--!strict
-- Tests for Render/PuppetMath (Ground puppets): which pocket a workspace position is in, a character in the base
-- pocket placed at its true position in a flight pocket (same as the rigid rebase transform, across bodies too),
-- and Motor6D animation retargeting between rigs whose joint C0s turn differently (R6 -> R15 / stand-in).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local PuppetMath = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render.PuppetMath)

--============================================================================
-- Tunables
--============================================================================
local WS_TOLERANCE = 5e-3 -- studs; workspace floats near slot origins of ~10 km
local ROT_TOLERANCE = 1e-5
local CAPTURE = 1800
local HOME_RADIUS = 300000
--============================================================================

local function expectCFrameNear(t: TestKit.Context, a: CFrame, b: CFrame, tolerance: number, message: string)
	t.expectNear((a.Position - b.Position).Magnitude, 0, tolerance, message .. " (position)")
	t.expectNear((a.RightVector - b.RightVector).Magnitude, 0, ROT_TOLERANCE, message .. " (right)")
	t.expectNear((a.UpVector - b.UpVector).Magnitude, 0, ROT_TOLERANCE, message .. " (up)")
	t.expectNear((a.LookVector - b.LookVector).Magnitude, 0, ROT_TOLERANCE, message .. " (look)")
end

-- How a Motor6D with this C0 turns its child in the parent's axes for a Transform (rotation only).
local function parentTurn(c0: CFrame, transform: CFrame): CFrame
	local r = Frames.rotationOnly(c0)
	return r * Frames.rotationOnly(transform) * r:Inverse()
end

local function baseFrame(): Frames.Frame
	local up = Frames.surfaceUp(0, 0)
	return Frames.new(1, Vec3d.scale(up, HOME_RADIUS), Frames.surfaceRotation(up), Vector3.zero)
end

return function(t: TestKit.Context)
	t.test("slotPocket: base near the origin, flight slots by capture radius, none in between", function()
		local origins = { Vector3.new(20000, 0, 0), Vector3.new(0, 0, -20000) }
		local ids = { 7, 9 }
		t.expectEqual(PuppetMath.slotPocket(Vector3.new(100, 5, -300), CAPTURE, origins, ids), 0)
		t.expectEqual(PuppetMath.slotPocket(Vector3.new(CAPTURE * 1.4, 0, 0), CAPTURE, origins, ids), 0)
		t.expectEqual(PuppetMath.slotPocket(Vector3.new(20500, 30, 10), CAPTURE, origins, ids), 7)
		t.expectEqual(PuppetMath.slotPocket(Vector3.new(0, 100, -19000), CAPTURE, origins, ids), 9)
		t.expectEqual(PuppetMath.slotPocket(Vector3.new(10000, 0, 0), CAPTURE, origins, ids), nil)
	end)

	t.test("a base-pocket character lands where the rigid rebase transform puts it", function()
		local base = baseFrame()
		-- a flight pocket 400 m up and 600 m east of the site, horizon axes tilted a little
		local refPos = Vec3d.new(HOME_RADIUS + 400, 3, 600)
		local flight = Frames.new(1, refPos, base.refRot * CFrame.Angles(0.01, 0.2, -0.015), Vector3.new(16000, 0, 0))
		local character = CFrame.new(120, 3, -45) * CFrame.Angles(0, 1.1, 0)
		local truePos = PuppetMath.trueInto(base, nil, character.Position, Vec3d.zero())
		local placed = PuppetMath.cframeIn(flight, truePos, PuppetMath.rotationBetween(base, flight), character)
		local expected = Frames.relativeTransform(base, flight) * character
		expectCFrameNear(t, placed, expected, WS_TOLERANCE, "same as relativeTransform")
		-- and the true position is the universe point of the character
		local direct = Frames.pointFromWorkspace(base, character.Position)
		t.expectNear(Vec3d.distance(truePos, direct), 0, 1e-9)
		-- the distance to the flight pocket's reference is the real one
		t.expectNear(Vec3d.distance(truePos, refPos), (placed.Position - flight.slotOrigin).Magnitude, WS_TOLERANCE)
	end)

	t.test("a character on another body is moved by the body offset (in doubles)", function()
		-- source pocket on the moon (body 2), our frame on the homeworld; the moon centre is 450 km away along +X
		local onMoon = Frames.new(2, Vec3d.new(-80000, 0, 0), CFrame.identity, Vector3.new(0, 0, 24000))
		local ours = Frames.new(1, Vec3d.new(370000 - 50, 10, 0), CFrame.Angles(0, 0.3, 0), Vector3.new(16000, 0, 0))
		local bodyOffset = Vec3d.new(450000, 0, 0) -- abs(moon) - abs(homeworld)
		local character = CFrame.new(0, 2, 24010)
		local truePos = PuppetMath.trueInto(onMoon, bodyOffset, character.Position, Vec3d.zero())
		t.expectNear(truePos.x, 370000, 1e-6)
		t.expectNear(truePos.y, 2, 1e-6)
		t.expectNear(truePos.z, 10, 1e-6)
		local placed = PuppetMath.cframeIn(ours, truePos, PuppetMath.rotationBetween(onMoon, ours), character)
		local expected = Frames.relativeTransform(onMoon, ours, bodyOffset) * character
		expectCFrameNear(t, placed, expected, WS_TOLERANCE, "cross-body placement")
	end)

	t.test("jointRole maps R6 and stand-in names onto the R15 ones", function()
		t.expectEqual(PuppetMath.jointRole("Left Hip"), "LeftHip")
		t.expectEqual(PuppetMath.jointRole("Right Shoulder"), "RightShoulder")
		t.expectEqual(PuppetMath.jointRole("RootJoint"), "Root")
		t.expectEqual(PuppetMath.jointRole("Root"), "Root")
		t.expectEqual(PuppetMath.jointRole("LeftKnee"), "LeftKnee")
		t.expectEqual(PuppetMath.jointRole("Neck"), "Neck")
	end)

	t.test("retarget: same C0 rotation copies the Transform unchanged", function()
		local q, qInverse, direct = PuppetMath.retargetFor(CFrame.new(-0.5, -1, 0), CFrame.new(-1, -0.2, 0))
		t.expectTrue(direct, "joints that turn the same way need no retargeting")
		local transform = CFrame.new(0, 0.1, 0) * CFrame.Angles(0.6, 0.1, -0.2)
		local copied = PuppetMath.retarget(transform, q, qInverse, direct)
		expectCFrameNear(t, copied, transform, 1e-9, "copied")
	end)

	t.test("retarget: an R6 hip swing turns an R15-style hip the same way in the parent's axes", function()
		-- R6 "Left Hip": C0 turned -90 degrees about Y; R15 "LeftHip": no turn
		local r6C0 = CFrame.new(-1, -1, 0) * CFrame.Angles(0, -math.pi / 2, 0)
		local r15C0 = CFrame.new(-0.5, -0.2, 0)
		local q, qInverse, direct = PuppetMath.retargetFor(r15C0, r6C0)
		t.expectTrue(not direct, "different C0 rotations need retargeting")
		for _, transform in
			{
				CFrame.Angles(0, 0, 0.7), -- R6 walk swing (about the joint's Z)
				CFrame.Angles(0.3, -0.4, 0.2),
				CFrame.new(0, 0.2, 0.1) * CFrame.Angles(-0.5, 0, 0.9),
			}
		do
			local retargeted = PuppetMath.retarget(transform, q, qInverse, direct)
			local want = parentTurn(r6C0, transform)
			local got = parentTurn(r15C0, retargeted)
			expectCFrameNear(t, got, want, 1e-6, "parent-space turn")
		end
		-- a pure swing about the R6 joint's Z becomes a swing about the R15 joint's X (a forward leg swing)
		local swing = PuppetMath.retarget(CFrame.Angles(0, 0, 0.7), q, qInverse, direct)
		t.expectNear(swing.RightVector.X, 1, 1e-6, "the swing axis is X on the R15 joint")
	end)
end
