--!strict
-- Tests for Shared/Craft/MassProps: mass properties and per-stage delta-v / TWR (Section 6.2 sanity example).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Fixtures = require(script.Parent.CraftFixtures)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local CraftGraph = require(ReplicatedStorage.Shared.Craft.CraftGraph)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MassProps = require(ReplicatedStorage.Shared.Craft.MassProps)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)

local G_HOME = Bodies.get(Bodies.HOMEWORLD).SurfaceGravity

return function(t: TestKit.Context)
	t.test("sanity rocket mass, CoM and areas", function()
		local design = Fixtures.sanity()
		local props = MassProps.compute(design)
		t.expectNear(props.mass, 4150, 1e-9)
		t.expectNear(props.fuelMass, 2000, 1e-9)
		-- a 1-block-wide stack: every block centre is half a block (2 studs) from the grid origin
		local half = CraftDesign.GRID / 2
		t.expectNear(props.com.X, half, 1e-9)
		t.expectNear(props.com.Z, half, 1e-9)
		t.expectTrue(props.com.Y > 0 and props.com.Y < 6 * CraftDesign.GRID)
		-- CHANGED (Physics feel): aero areas are at the parts' visual size, (4 studs x 0.3 m)^2 = 1.44 m^2 per block face
		local cell = (CraftDesign.GRID * GameConfig.AERO_METERS_PER_STUD) ^ 2
		t.expectNear(cell, 1.44, 1e-9)
		t.expectNear(props.area.Y, 1 * cell, 1e-5) -- 1x1 block footprint
		t.expectNear(props.area.X, 6 * cell, 1e-5) -- 1 wide x 6 blocks tall
		t.expectEqual(props.leadDragFactor["+Y"], 1)
		t.expectTrue(props.inertia.X > 0 and props.inertia.Y > 0 and props.inertia.Z > 0)
		t.expectNear(props.inertia.X, props.inertia.Z, 1e-6) -- symmetric in X and Z
	end)

	t.test("empty fuel state lowers the mass", function()
		local design = Fixtures.sanity()
		local props = MassProps.compute(design, { [2] = 0 })
		t.expectNear(props.mass, 2150, 1e-9)
	end)

	t.test("nose cone leads the drag factor", function()
		local design = Fixtures.stack("Nose", { "engine_s", "tank_s_long", "pod_mk1", "nose_s" })
		local props = MassProps.compute(design)
		t.expectEqual(props.leadDragFactor["+Y"], 0.5)
		t.expectEqual(props.leadDragFactor["-Y"], 1)
	end)

	-- CHANGED (Physics feel): fin lift area uses the same visual-size factor as the drag areas, so a finned
	-- rocket keeps its lift-to-drag balance
	t.test("fin area is scaled like the drag areas", function()
		local design = Fixtures.stack("Finned", { "engine_s", "tank_s_long", "pod_mk1" })
		Fixtures.add(design, "fin", 1, 0, 0)
		local props = MassProps.compute(design)
		local fin = Parts.get("fin").Fin :: Parts.FinStats
		local scale = GameConfig.AERO_METERS_PER_STUD ^ 2
		t.expectNear(props.finArea, fin.Area * scale, 1e-9)
		-- fin area per m^2 of side drag area is the same as at block scale (1 stud = 1 m)
		local sideStuds = props.area.Z / scale
		t.expectNear(props.finArea / props.area.Z, fin.Area / sideStuds, 1e-6)
	end)

	-- CHANGED (Physics feel): engines x1.5 with the same Isp: TWR ~2.9 (was ~1.9), same delta-v, 2/3 the burn time
	t.test("Section 6.2 sanity example: TWR ~2.9 and ~2,100 m/s (within 5%)", function()
		local graph = CraftGraph.build((Fixtures.sanity()))
		local stats = MassProps.stageStats(graph, GameConfig.G0, G_HOME)
		t.expectEqual(#stats, 3)
		t.expectRelNear(stats[1].massStart, 4150, 1e-9)
		t.expectRelNear(stats[1].twrAsl, 2.9, 0.05)
		t.expectRelNear(stats[1].dvVac, 2100, 0.05)
		local engine = Parts.get("engine_s").Engine :: Parts.EngineStats
		local exact = engine.IspVac * GameConfig.G0 * math.log(4150 / 2150)
		t.expectRelNear(stats[1].dvVac, exact, 1e-9)
		t.expectTrue(stats[1].dvAsl < stats[1].dvVac)
		t.expectNear(stats[1].burnTime, 2000 / Parts.massFlow(engine, GameConfig.G0), 1e-6)
		-- after separation only the pod + chute remain and nothing burns
		t.expectRelNear(stats[2].massStart, 900, 1e-9)
		t.expectEqual(stats[2].dvVac, 0)
	end)

	t.test("solid booster burns only its own fuel; staged booster drops", function()
		local design = Fixtures.stack("Radial", { "engine_s", "tank_s_long", "pod_mk1" })
		Fixtures.add(design, "decoupler_r", 1, 1, 0)
		Fixtures.add(design, "srb_s", 2, 0, 0)
		local graph = CraftGraph.build(design)
		local stats = MassProps.stageStats(graph, GameConfig.G0, G_HOME)
		t.expectEqual(#stats, 2)
		local srb = Parts.get("srb_s")
		local wet = 700 + 2450 + 800 + 60 + 3600
		t.expectRelNear(stats[1].massStart, wet, 1e-9)
		local srbEngine = srb.Engine :: Parts.EngineStats
		local expected = srbEngine.IspVac * GameConfig.G0 * math.log(wet / (wet - 3000))
		t.expectRelNear(stats[1].dvVac, expected, 1e-9)
		-- stage 2 drops the burnt-out booster (600 kg dry) and the decoupler (60 kg), then the core burns its tank
		t.expectRelNear(stats[2].massStart, wet - 3000 - 600 - 60, 1e-9)
		t.expectTrue(stats[2].dvVac > 0)
	end)
end
