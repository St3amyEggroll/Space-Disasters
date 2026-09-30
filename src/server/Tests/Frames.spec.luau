--!strict
-- Tests for Shared/Math/Frames: universe <-> pocket round trips, rebase transforms and surface frames.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)

-- Workspace floats near 12,000 studs have ~0.001 stud resolution, so round trips are checked to 2 mm.
local WS_TOLERANCE = 2e-3

return function(t: TestKit.Context)
	t.test("point round trip far from the body center", function()
		local refPos = Vec3d.new(450000.125, 1234.5, -61000.75)
		local frame = Frames.new(1, refPos, CFrame.Angles(0.4, 1.2, -0.7), Vector3.new(12000, 12000, -12000), 3)
		local p = Vec3d.new(450000.125 + 37.25, 1234.5 - 12.5, -61000.75 + 5.125)
		local ws = Frames.pointToWorkspace(frame, p)
		t.expectTrue((ws - frame.slotOrigin).Magnitude < 50, "point should land near the slot origin")
		local back = Frames.pointFromWorkspace(frame, ws)
		t.expectNear(back.x, p.x, WS_TOLERANCE)
		t.expectNear(back.y, p.y, WS_TOLERANCE)
		t.expectNear(back.z, p.z, WS_TOLERANCE)
	end)

	t.test("reference point maps exactly to the slot origin", function()
		local refPos = Vec3d.new(7.3e7, -1.1e6, 2.9e7)
		local frame = Frames.new(1, refPos, CFrame.Angles(1, 2, 3), Vector3.new(4000, 8000, 0))
		local ws = Frames.pointToWorkspace(frame, refPos)
		t.expectNear(ws.X, 4000, 1e-9)
		t.expectNear(ws.Y, 8000, 1e-9)
		t.expectNear(ws.Z, 0, 1e-9)
	end)

	t.test("body offset is applied in doubles", function()
		local frame = Frames.new(1, Vec3d.new(450000, 0, 0), CFrame.identity, Vector3.zero)
		-- a point 10 m above a body whose center is 435,000 m from the frame's body center
		local pos = Vec3d.new(15010, 0, 0)
		local bodyOffset = Vec3d.new(435000, 0, 0)
		local ws = Frames.pointToWorkspace(frame, pos, bodyOffset)
		t.expectNear(ws.X, 10, 1e-9)
	end)

	t.test("vector and rotation round trips", function()
		local frame = Frames.new(1, Vec3d.zero(), CFrame.Angles(-0.2, 0.9, 1.7), Vector3.zero)
		local v = Vec3d.new(710.5, -3.25, 44)
		local ws = Frames.vectorToWorkspace(frame, v)
		local back = Frames.vectorFromWorkspace(frame, ws)
		t.expectNear(back.x, v.x, 1e-3)
		t.expectNear(back.y, v.y, 1e-3)
		t.expectNear(back.z, v.z, 1e-3)

		local rot = CFrame.Angles(0.5, 0.25, -1)
		local wsRot = Frames.rotationToWorkspace(frame, rot)
		local rotBack = Frames.rotationFromWorkspace(frame, wsRot)
		local a = rot.LookVector
		local b = rotBack.LookVector
		t.expectNear((a - b).Magnitude, 0, 1e-5)
	end)

	t.test("CRAFT_ALIGNED: the primary craft sits upright at the slot origin", function()
		local craftRot = CFrame.Angles(0.8, -0.3, 2.2)
		local craftPos = Vec3d.new(-58000.5, 21000.25, 3000)
		local frame = Frames.new(1, craftPos, craftRot, Vector3.new(0, 4000, 0))
		local cf = Frames.cframeToWorkspace(frame, craftPos, craftRot)
		t.expectNear((cf.Position - Vector3.new(0, 4000, 0)).Magnitude, 0, 1e-6)
		t.expectNear((cf.UpVector - Vector3.yAxis).Magnitude, 0, 1e-5)
		t.expectNear((cf.RightVector - Vector3.xAxis).Magnitude, 0, 1e-5)
	end)

	t.test("relativeTransform keeps true positions (rebase)", function()
		local old = Frames.new(1, Vec3d.new(60010, 5, -3), CFrame.Angles(0.1, 0.2, 0.3), Vector3.new(4000, 4000, 4000))
		local new =
			Frames.new(1, Vec3d.new(60050, -20, 9), CFrame.Angles(-1.3, 0.4, 0.05), Vector3.new(-8000, 12000, 0))
		local m = Frames.relativeTransform(old, new)
		local truePoint = Vec3d.new(60030, 12, 1)
		local inOld = Frames.pointToWorkspace(old, truePoint)
		local mapped = m:PointToWorldSpace(inOld)
		local inNew = Frames.pointToWorkspace(new, truePoint)
		t.expectNear((mapped - inNew).Magnitude, 0, WS_TOLERANCE * 4)

		-- rotations map too: a universe rotation seen in old, mapped by M, equals it seen in new
		local rot = CFrame.Angles(0.7, -0.2, 0.9)
		local cfOld = Frames.cframeToWorkspace(old, truePoint, rot)
		local cfMapped = m * cfOld
		local cfNew = Frames.cframeToWorkspace(new, truePoint, rot)
		t.expectNear((cfMapped.LookVector - cfNew.LookVector).Magnitude, 0, 1e-5)
		t.expectNear((cfMapped.UpVector - cfNew.UpVector).Magnitude, 0, 1e-5)
	end)

	t.test("relativeTransform across bodies uses the body offset", function()
		local onHome = Frames.new(1, Vec3d.new(449000, 0, 0), CFrame.identity, Vector3.zero)
		local onMoon = Frames.new(2, Vec3d.new(-1000, 0, 0), CFrame.identity, Vector3.new(4000, 4000, 4000))
		-- Moon center is at +450,000 m from Homeworld: abs(from body) - abs(to body) = 0 - 450000
		local m = Frames.relativeTransform(onHome, onMoon, Vec3d.new(-450000, 0, 0))
		-- the Homeworld frame's reference is the same true point as the Moon frame's reference
		local mapped = m:PointToWorldSpace(Vector3.zero)
		t.expectNear((mapped - Vector3.new(4000, 4000, 4000)).Magnitude, 0, 1e-6)
	end)

	t.test("surface frame: Y up, Z north, X east, right-handed", function()
		local up = Frames.surfaceUp(0, 0)
		t.expectNear(up.x, 1, 1e-12)
		local rot = Frames.surfaceRotation(up)
		t.expectNear((rot.UpVector - Vector3.new(1, 0, 0)).Magnitude, 0, 1e-6)
		t.expectNear((rot.RightVector - Vector3.new(0, 0, 1)).Magnitude, 0, 1e-6) -- east is +Z at lon 0
		t.expectNear((-rot.LookVector - Vector3.new(0, 1, 0)).Magnitude, 0, 1e-6) -- Z column = north
		-- east is the direction of increasing longitude
		local east = Frames.surfaceUp(0, 1e-4)
		t.expectTrue(east.z > 0)
		-- right-handed: X x Y = Z
		local cross = rot.RightVector:Cross(rot.UpVector)
		t.expectNear((cross - -rot.LookVector).Magnitude, 0, 1e-5)
	end)

	t.test("surface frame at the poles is still orthonormal", function()
		for _, lat in { math.pi / 2, -math.pi / 2 } do
			local rot = Frames.surfaceRotation(Frames.surfaceUp(lat, 0.3))
			t.expectNear(rot.RightVector:Dot(rot.UpVector), 0, 1e-5)
			t.expectNear(rot.UpVector:Dot(rot.LookVector), 0, 1e-5)
			t.expectNear(rot.UpVector.Magnitude, 1, 1e-5)
		end
	end)

	t.test("latLon inverts surfaceUp", function()
		for _, sample in { { 0.3, -2.1 }, { -1.2, 0.5 }, { 0, 3.0 } } do
			local up = Frames.surfaceUp(sample[1], sample[2])
			local lat, lon = Frames.latLon(Vec3d.scale(up, 60000))
			t.expectNear(lat, sample[1], 1e-12)
			t.expectNear(lon, sample[2], 1e-12)
		end
	end)
end
