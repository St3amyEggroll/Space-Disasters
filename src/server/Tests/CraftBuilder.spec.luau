--!strict
-- Tests for Shared/Craft/CraftBuilder: models match the design and readDesign() round-trips.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Fixtures = require(script.Parent.CraftFixtures)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local PartVisuals = require(ReplicatedStorage.Shared.Craft.PartVisuals)

local BOUNDS_TOLERANCE = 0.01 -- studs a primitive may poke out of its part's box (float slack)

-- Axis-aligned half extents of an oriented box.
local function extentOf(cf: CFrame, size: Vector3): Vector3
	local half = size / 2
	local right, up, back = cf.RightVector, cf.UpVector, cf.LookVector
	return Vector3.new(
		math.abs(right.X) * half.X + math.abs(up.X) * half.Y + math.abs(back.X) * half.Z,
		math.abs(right.Y) * half.X + math.abs(up.Y) * half.Y + math.abs(back.Y) * half.Z,
		math.abs(right.Z) * half.X + math.abs(up.Z) * half.Y + math.abs(back.Z) * half.Z
	)
end

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

	-- CHANGED (Phase 2a remodel): tilted facets, struts and the landing leg's stowed pose must stay inside the
	-- part's cell so neighbouring blocks never overlap.
	t.test("every primitive stays inside its part's box (gear deployed and stowed)", function()
		for _, def in Parts.List do
			for _, mode in { "Real", "Cosmetic" } do
				local model = PartVisuals.build(def, mode :: PartVisuals.Mode)
				local bounds = model.PrimaryPart :: BasePart
				local limit = bounds.Size / 2 + Vector3.one * BOUNDS_TOLERANCE
				for _, descendant in model:GetDescendants() do
					if descendant:IsA("BasePart") then
						t.expectTrue(descendant.Anchored, `{def.Id} {mode} {descendant.Name} is anchored`)
						local poses = { descendant.CFrame }
						local stowed = descendant:GetAttribute(PartVisuals.GEAR_STOWED_ATTRIBUTE)
						if typeof(stowed) == "CFrame" then
							table.insert(poses, stowed)
						end
						for _, cf in poses do
							local e, p = extentOf(cf, descendant.Size), cf.Position
							t.expectTrue(
								math.abs(p.X) + e.X <= limit.X
									and math.abs(p.Y) + e.Y <= limit.Y
									and math.abs(p.Z) + e.Z <= limit.Z,
								`{def.Id} {mode} {descendant.Name} leaves the part box`
							)
						end
					end
				end
				model:Destroy()
			end
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
