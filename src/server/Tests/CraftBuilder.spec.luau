--!strict
-- Tests for Shared/Craft/CraftBuilder: models match the design and readDesign() round-trips.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Fixtures = require(script.Parent.CraftFixtures)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)

return function(t: TestKit.Context)
	t.test("build + readDesign round trip", function()
		local design = Fixtures.sanity()
		design.blocks[2].rot = 1
		design.blocks[2].stageOverride = 3
		local origin = CFrame.new(100, 1, -250)
		local model = CraftBuilder.build(design, "Real", origin, "Test")
		t.expectEqual(#model:GetChildren(), #design.blocks)
		t.expectTrue(model.PrimaryPart ~= nil, "root block is the primary part")
		local back = CraftBuilder.readDesign(model, "Test")
		t.expectEqual(#back.blocks, #design.blocks)
		for index, block in design.blocks do
			local other = back.blocks[index]
			t.expectEqual(other.id, block.id)
			t.expectEqual(other.type, block.type)
			t.expectEqual(other.gx, block.gx)
			t.expectEqual(other.rot, block.rot)
			t.expectEqual(other.stageOverride, block.stageOverride)
		end
		model:Destroy()
	end)

	t.test("block Bounds sits exactly on the grid box", function()
		local design = Fixtures.sanity()
		local origin = CFrame.new(10, 0, 20)
		for _, block in design.blocks do
			local model = CraftBuilder.buildBlock(block, "Real", origin)
			local bounds = model.PrimaryPart :: BasePart
			local expected = origin * CFrame.new(CraftDesign.blockCenter(block) * CraftDesign.GRID)
			t.expectNear((bounds.CFrame.Position - expected.Position).Magnitude, 0, 1e-4)
			t.expectEqual(bounds.Size, Parts.get(block.type).Size * CraftDesign.GRID)
			model:Destroy()
		end
	end)

	t.test("every part builds in every orientation and mode", function()
		for _, def in Parts.List do
			for _, mode in { "Real", "Cosmetic", "Ghost" } do
				local model = CraftBuilder.buildBlock(
					{ id = 1, type = def.Id, gx = 0, gy = 0, gz = 0, rot = 7 },
					mode :: CraftBuilder.Mode,
					CFrame.identity
				)
				t.expectTrue(model.PrimaryPart ~= nil, def.Id .. " " .. mode)
				model:Destroy()
			end
		end
	end)
end
