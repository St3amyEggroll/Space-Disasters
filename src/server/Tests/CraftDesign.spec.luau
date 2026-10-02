--!strict
-- Tests for Shared/Craft/CraftDesign: orientations, geometry, validation, JSON and buffer round trips.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Fixtures = require(script.Parent.CraftFixtures)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)

local LIMITS = { maxBlocks = 250 }

return function(t: TestKit.Context)
	t.test("24 distinct orientations, index 0 is identity", function()
		local seen: { [string]: boolean } = {}
		for rot = 0, 23 do
			local cf = CraftDesign.rotationCFrame(rot)
			local key = tostring(cf.RightVector) .. tostring(cf.UpVector)
			t.expectTrue(not seen[key], "orientation " .. rot .. " duplicated")
			seen[key] = true
			t.expectEqual(CraftDesign.rotationIndex(cf), rot)
		end
		t.expectEqual(CraftDesign.rotationCFrame(0), CFrame.identity)
	end)

	t.test("four yaws return to the start; pitch changes the up axis", function()
		local yaw = CFrame.Angles(0, math.pi / 2, 0)
		for rot = 0, 23 do
			local r = rot
			for _ = 1, 4 do
				r = CraftDesign.rotateOrientation(r, yaw)
			end
			t.expectEqual(r, rot)
		end
		local pitched = CraftDesign.rotateOrientation(0, CFrame.Angles(math.pi / 2, 0, 0))
		local up = CraftDesign.rotationCFrame(pitched).UpVector
		t.expectNear(math.abs(up.Y), 0, 1e-6)
	end)

	t.test("oriented size swaps axes", function()
		t.expectEqual(CraftDesign.orientedSize("fin", 0), Vector3.new(1, 2, 1))
		local lying = CraftDesign.rotateOrientation(0, CFrame.Angles(0, 0, math.pi / 2))
		t.expectEqual(CraftDesign.orientedSize("srb_s", lying), Vector3.new(3, 1, 1))
		t.expectEqual(CraftDesign.orientedSize("beam_4", 0), Vector3.new(1, 1, 3))
	end)

	t.test("touches needs a shared face with area; overlaps needs volume", function()
		local design = CraftDesign.new()
		local a = { id = 1, type = "block_1", gx = 0, gy = 0, gz = 0, rot = 0 }
		local faceNeighbor = { id = 2, type = "block_1", gx = 1, gy = 0, gz = 0, rot = 0 }
		local edgeOnly = { id = 3, type = "block_1", gx = 1, gy = 1, gz = 0, rot = 0 }
		local apart = { id = 4, type = "block_1", gx = 3, gy = 0, gz = 0, rot = 0 }
		local inside = { id = 5, type = "plate_4", gx = 0, gy = 0, gz = 0, rot = 0 }
		t.expectTrue(CraftDesign.touches(a, faceNeighbor))
		t.expectTrue(not CraftDesign.touches(a, edgeOnly))
		t.expectTrue(not CraftDesign.touches(a, apart))
		t.expectTrue(not CraftDesign.overlaps(a, faceNeighbor))
		t.expectTrue(CraftDesign.overlaps(a, inside))
		design.blocks = { a, faceNeighbor }
		t.expectTrue((CraftDesign.validate(design, LIMITS)))
		design.blocks = { a, inside }
		local ok, reason = CraftDesign.validate(design, LIMITS)
		t.expectTrue(not ok and reason ~= nil, "overlap rejected")
	end)

	t.test("validation rejects bad data", function()
		local cases = {
			{ id = 1, type = "nope", gx = 0, gy = 0, gz = 0, rot = 0 },
			{ id = 1, type = "block_1", gx = 0.5, gy = 0, gz = 0, rot = 0 },
			{ id = 1, type = "block_1", gx = 0, gy = 0, gz = 0, rot = 24 },
			{ id = 0, type = "block_1", gx = 0, gy = 0, gz = 0, rot = 0 },
		}
		for _, block in cases do
			local design = CraftDesign.new()
			design.blocks = { block :: any }
			t.expectTrue(not (CraftDesign.validate(design, LIMITS)))
		end
		local design = CraftDesign.new()
		design.blocks = { { id = 1, type = "block_1", gx = 0, gy = 0, gz = 0, rot = 0 } }
		local bounded = { maxBlocks = 250, boundsMin = Vector3.new(1, 0, 0), boundsMax = Vector3.new(40, 120, 40) }
		t.expectTrue(not (CraftDesign.validate(design, bounded)), "outside bounds")
		local tiny = { maxBlocks = 0 }
		t.expectTrue(not (CraftDesign.validate(design, tiny)), "too many blocks")
	end)

	t.test("JSON round trip", function()
		local design = Fixtures.sanity()
		design.blocks[1].stageOverride = 2
		design.blocks[1].color = 5
		design.blocks[2].rot = 13
		local decoded, err = CraftDesign.fromJson(CraftDesign.toJson(design))
		t.expectTrue(decoded ~= nil, tostring(err))
		if decoded then
			t.expectEqual(decoded.name, "Sanity")
			t.expectEqual(#decoded.blocks, #design.blocks)
			for index, block in design.blocks do
				local other = decoded.blocks[index]
				t.expectEqual(other.id, block.id)
				t.expectEqual(other.type, block.type)
				t.expectEqual(other.gx, block.gx)
				t.expectEqual(other.gy, block.gy)
				t.expectEqual(other.gz, block.gz)
				t.expectEqual(other.rot, block.rot)
				t.expectEqual(other.stageOverride, block.stageOverride)
				t.expectEqual(other.color, block.color)
			end
		end
		t.expectTrue(CraftDesign.fromJson("{") == nil)
		t.expectTrue(CraftDesign.fromJson('{"v":99,"blocks":[]}') == nil)
	end)

	t.test("buffer round trip (12 bytes per block)", function()
		local design = Fixtures.sanity()
		design.blocks[3].stageOverride = 7
		design.blocks[3].color = 12
		design.blocks[4].gx = -300
		local b = CraftDesign.toBuffer(design)
		t.expectEqual(buffer.len(b), 2 + #design.name + 2 + #design.blocks * 12)
		local decoded = CraftDesign.fromBuffer(b)
		t.expectTrue(decoded ~= nil)
		if decoded then
			for index, block in design.blocks do
				local other = decoded.blocks[index]
				t.expectEqual(other.type, block.type)
				t.expectEqual(other.gx, block.gx)
				t.expectEqual(other.stageOverride, block.stageOverride)
				t.expectEqual(other.color, block.color)
			end
		end
		t.expectTrue(CraftDesign.fromBuffer(buffer.create(3)) == nil)
	end)

	t.test("mirror orientations are proper rotations and mirror twice to the start", function()
		for rot = 0, 23 do
			for _, axis in { "X", "Z" } do
				local m = CraftDesign.mirrorOrientation(rot, axis :: "X" | "Z")
				t.expectEqual(CraftDesign.mirrorOrientation(m, axis :: "X" | "Z"), rot)
			end
		end
		-- a part pointing +X mirrors across X to point -X
		local pointX = CraftDesign.rotateOrientation(0, CFrame.Angles(0, 0, -math.pi / 2))
		local up = CraftDesign.rotationCFrame(CraftDesign.mirrorOrientation(pointX, "X")).UpVector
		t.expectNear(up.X, -1, 1e-6)
	end)

	t.test("bounds and root block", function()
		local design = Fixtures.sanity()
		local minV, maxV = CraftDesign.bounds(design)
		t.expectEqual(minV, Vector3.new(0, 0, 0))
		t.expectEqual(maxV.Y, 1 + 2 + 1 + 1 + 1)
		-- block CFrames are in studs
		t.expectEqual(CraftDesign.blockCFrame(design.blocks[1]).Position, Vector3.new(0.5, 0.5, 0.5) * CraftDesign.GRID)
		local root = CraftDesign.rootBlock(design)
		t.expectTrue(root ~= nil and root.type == "pod_mk1")
	end)
	-- CHANGED (Night review): the chase camera's craft size about its orbit centre (the centre of mass)
	t.test("reachFrom: the farthest block corner from a point", function()
		local design = Fixtures.sanity()
		local minV, maxV = CraftDesign.bounds(design)
		local grid = CraftDesign.GRID
		local middle = (minV + maxV) / 2 * grid
		local halfDiagonal = (maxV - minV).Magnitude * grid / 2
		t.expectTrue(CraftDesign.reachFrom(design, middle) <= halfDiagonal + 1e-6, "inside the bounding sphere")
		-- from the bottom of the stack the top corners are much farther than half the diagonal
		local low = Vector3.new(middle.X, minV.Y * grid, middle.Z)
		t.expectTrue(CraftDesign.reachFrom(design, low) > halfDiagonal * 1.5, "an off-centre point reaches farther")
		-- one block: exactly the distance to its far corner
		local one = CraftDesign.new("One")
		table.insert(one.blocks, { id = 1, type = "pod_mk1", gx = 0, gy = 0, gz = 0, rot = 0 })
		local size = CraftDesign.blockSize(one.blocks[1]) * grid
		t.expectNear(CraftDesign.reachFrom(one, Vector3.zero), size.Magnitude, 1e-6, "from a corner")
		t.expectNear(CraftDesign.reachFrom(one, size / 2), size.Magnitude / 2, 1e-6, "from the centre")
		t.expectEqual(CraftDesign.reachFrom(CraftDesign.new("Empty"), Vector3.zero), 0, "empty")
	end)
	-- CHANGED (Phase 2a remodel): removed parts (Crew Cabin, Ladder) are dropped from old saves
	t.test("old saves with removed parts still load", function()
		local text = '{"v":1,"name":"Old","blocks":[{"id":1,"t":"pod_mk1","x":0,"y":0,"z":0,"r":0},'
			.. '{"id":2,"t":"cabin_l","x":0,"y":1,"z":0,"r":0},{"id":3,"t":"ladder","x":1,"y":0,"z":0,"r":0}]}'
		local design = CraftDesign.fromJson(text)
		t.expectTrue(design ~= nil, "loads")
		if design then
			t.expectEqual(#design.blocks, 1)
			t.expectEqual(design.blocks[1].type, "pod_mk1")
		end
	end)
end
