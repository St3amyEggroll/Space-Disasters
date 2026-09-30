--!strict
-- Tests for Shared/Craft/CraftGraph: segments and auto staging on 5 fixture designs, plus splits.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Fixtures = require(script.Parent.CraftFixtures)
local CraftGraph = require(ReplicatedStorage.Shared.Craft.CraftGraph)

local function same(a: { number }, b: { number }): boolean
	if #a ~= #b then
		return false
	end
	for index, value in a do
		if b[index] ~= value then
			return false
		end
	end
	return true
end

return function(t: TestKit.Context)
	t.test("fixture 1: sanity rocket (engine, tank | decoupler | pod, chute)", function()
		local design = Fixtures.sanity() -- ids: 1 engine, 2 tank, 3 decoupler, 4 pod, 5 chute
		local graph = CraftGraph.build(design)
		t.expectEqual(graph.rootId, 4)
		t.expectEqual(graph.maxDepth, 1)
		t.expectEqual(#graph.segments, 2)
		t.expectTrue(same(graph.segments[1].blockIds, { 4, 5 }), "root segment = pod + chute")
		t.expectTrue(same(graph.segments[2].blockIds, { 1, 2, 3 }), "decoupler drops with the lower stage")
		t.expectEqual(graph.segments[2].tankFuel, 2000)
		t.expectEqual(#graph.stages, 3)
		t.expectTrue(same(graph.stages[1].ignite, { 1 }))
		t.expectTrue(same(graph.stages[2].decouple, { 3 }))
		t.expectTrue(same(graph.stages[3].deploy, { 5 }))
		t.expectEqual(#graph.warnings, 0)
	end)

	t.test("fixture 2: two liquid stages", function()
		local design = Fixtures.stack(
			"TwoStage",
			{ "engine_s", "tank_s_long", "decoupler_s", "engine_s", "tank_s_short", "pod_mk1", "chute_s" }
		)
		local graph = CraftGraph.build(design)
		t.expectEqual(graph.maxDepth, 1)
		t.expectEqual(#graph.stages, 3)
		t.expectTrue(same(graph.stages[1].ignite, { 1 }))
		t.expectTrue(same(graph.stages[2].decouple, { 3 }))
		t.expectTrue(same(graph.stages[2].ignite, { 4 }))
		t.expectTrue(same(graph.stages[3].deploy, { 7 }))
	end)

	t.test("fixture 3: no command part", function()
		local design = Fixtures.stack("NoPod", { "engine_s", "tank_s_long" })
		local graph = CraftGraph.build(design)
		t.expectTrue(graph.rootId == nil)
		t.expectEqual(#graph.stages, 0)
		t.expectEqual(#graph.looseIds, 2)
		t.expectTrue(string.find(graph.warnings[1], "No command part") ~= nil)
	end)

	t.test("fixture 4: engine that cannot reach fuel", function()
		local design = Fixtures.stack("Dry", { "engine_s", "pod_mk1" })
		local graph = CraftGraph.build(design)
		t.expectEqual(#graph.stages, 1)
		local found = false
		for _, warning in graph.warnings do
			if string.find(warning, "can't reach any fuel") then
				found = true
			end
		end
		t.expectTrue(found, "fuel warning")
	end)

	t.test("fixture 5: radial booster on a radial decoupler, plus a stage override", function()
		-- core: engine (1), long tank (2), pod (3); radial decoupler (4) on the tank's +X side; SRB (5) beyond it
		local design = Fixtures.stack("Radial", { "engine_s", "tank_s_long", "pod_mk1" })
		local decoupler = Fixtures.add(design, "decoupler_r", 3, 5, 0)
		local srb = Fixtures.add(design, "srb_s", 4, 0, -2)
		local graph = CraftGraph.build(design)
		t.expectEqual(graph.maxDepth, 1)
		t.expectEqual(graph.segments[graph.segmentOf[srb]].depth, 1)
		t.expectEqual(graph.segmentOf[decoupler], graph.segmentOf[srb])
		t.expectEqual(#graph.stages, 2)
		t.expectTrue(same(graph.stages[1].ignite, { srb }))
		t.expectTrue(same(graph.stages[2].decouple, { decoupler }))
		t.expectTrue(same(graph.stages[2].ignite, { 1 }))

		design.blocks[1].stageOverride = 1
		local overridden = CraftGraph.build(design)
		t.expectTrue(same(overridden.stages[1].ignite, { 1, srb }), "core lights with the booster")
		t.expectTrue(same(overridden.stages[2].ignite, {}))
		t.expectTrue(same(overridden.stages[2].decouple, { decoupler }))
	end)

	t.test("loose blocks and splits", function()
		local design = Fixtures.sanity()
		local loose = Fixtures.add(design, "block_1", 20, 0, 20)
		local graph = CraftGraph.build(design)
		t.expectTrue(same(graph.looseIds, { loose }))
		t.expectTrue(not graph.attached[loose])

		-- firing the decoupler splits the craft: root component first
		local components = CraftGraph.components(design, graph.neighbors, { [3] = true }, graph.rootId)
		t.expectTrue(same(components[1], { 4, 5 }))
		t.expectTrue(same(components[2], { 1, 2 }))
		t.expectTrue(same(components[3], { loose }))
	end)

	t.test("deterministic: same result regardless of block order", function()
		local design = Fixtures.sanity()
		local reversed = Fixtures.sanity()
		local blocks = reversed.blocks
		for i = 1, math.floor(#blocks / 2) do
			blocks[i], blocks[#blocks - i + 1] = blocks[#blocks - i + 1], blocks[i]
		end
		local a = CraftGraph.build(design)
		local b = CraftGraph.build(reversed)
		t.expectEqual(#a.stages, #b.stages)
		for index, stage in a.stages do
			t.expectTrue(same(stage.ignite, b.stages[index].ignite))
			t.expectTrue(same(stage.decouple, b.stages[index].decouple))
		end
	end)
end
