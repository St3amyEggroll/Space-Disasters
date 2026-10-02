--!strict
-- Tests for Shared/Sim/FlightModel: orbital energy conservation, a real launch, contacts, crashes, staging.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Fixtures = require(script.Parent.CraftFixtures)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

local HOME = Bodies.get(Bodies.HOMEWORLD)

local function stateAt(pos: Vec3d.Vec3d, vel: Vec3d.Vec3d, rot: CFrame): FlightModel.CraftState
	return {
		bodyId = Bodies.HOMEWORLD,
		pos = pos,
		vel = vel,
		rot = rot,
		angVel = Vector3.zero,
		throttle = 0,
		flags = 0,
		ut = 0,
	}
end

-- The craft standing upright at the launch site (lat 0, lon 0), `height` m above the ground (its bottom).
local function onPad(design: CraftDesign.Design, height: number): FlightModel.CraftState
	local up = Frames.surfaceUp(0, 0)
	local rot = Frames.surfaceRotation(up)
	local root = CraftDesign.rootBlock(design) :: CraftDesign.Block
	local rootCenterY = CraftDesign.blockCenter(root).Y * CraftDesign.GRID
	local pos = Vec3d.scale(up, HOME.Radius + height + rootCenterY)
	return stateAt(pos, Vec3d.zero(), rot)
end

local function energy(craft: FlightModel.Craft): number
	local s = craft.state
	return 0.5 * Vec3d.lengthSq(s.vel) - HOME.Mu / Vec3d.length(s.pos)
end

return function(t: TestKit.Context)
	t.test("vacuum coast: energy drift < 1e-4 over a quarter orbit at 120 Hz", function()
		local design = Fixtures.stack("Coaster", { "pod_mk1" })
		local r = HOME.Radius + 20000
		local v = math.sqrt(HOME.Mu / r)
		local craft = FlightModel.newCraft(design, stateAt(Vec3d.new(r, 0, 0), Vec3d.new(0, 0, v), CFrame.identity))
		local e0 = energy(craft)
		local period = 2 * math.pi * math.sqrt(r ^ 3 / HOME.Mu)
		local steps = math.floor(period / 4 / FlightModel.STEP)
		for _ = 1, steps do
			FlightModel.step(craft)
		end
		local drift = math.abs((energy(craft) - e0) / e0)
		t.expectTrue(drift < 1e-4, "relative energy drift " .. drift)
		t.expectNear(Vec3d.length(craft.state.pos), r, 5)
	end)

	t.test("sanity rocket lifts off on stage 1 and burns fuel at the right rate", function()
		local design = Fixtures.sanity()
		local craft = FlightModel.newCraft(design, onPad(design, 0.01))
		FlightModel.setControls(craft, 0, 0, 0, 1, false)
		local result = FlightModel.stage(craft)
		t.expectTrue(result ~= nil and #result.ignited == 1, "stage 1 ignites the engine")
		local fuel0 = FlightModel.totalFuel(craft)
		for _ = 1, 5 * 60 do
			FlightModel.step(craft)
		end
		local altitude = Vec3d.length(craft.state.pos) - HOME.Radius
		t.expectTrue(altitude > 30, "climbed " .. altitude .. " m in 5 s")
		local burned = fuel0 - FlightModel.totalFuel(craft)
		t.expectNear(burned, 5 * 135000 / (330 * 9.80665), 1) -- CHANGED (Physics feel): 135 kN engine (x1.5), same Isp
		t.expectEqual(#craft.destroyed, 0)
	end)

	t.test("a craft dropped gently settles on the ground", function()
		local design = Fixtures.stack("Lander", { "tank_s_short", "pod_mk1" })
		local craft = FlightModel.newCraft(design, onPad(design, 2))
		for _ = 1, 4 * 60 do
			FlightModel.step(craft)
		end
		local up = Frames.surfaceUp(0, 0)
		local bottom = Vec3d.dot(craft.state.pos, up) - HOME.Radius - 1.5 * CraftDesign.GRID
		t.expectTrue(math.abs(bottom) < 0.5, "resting height " .. bottom)
		t.expectTrue(Vec3d.length(craft.state.vel) < 0.5, "speed " .. Vec3d.length(craft.state.vel))
		t.expectEqual(#craft.destroyed, 0)
	end)

	t.test("a 30 m/s impact destroys parts", function()
		local design = Fixtures.stack("Crasher", { "tank_s_short", "pod_mk1" })
		local state = onPad(design, 3)
		local up = Frames.surfaceUp(0, 0)
		state.vel = Vec3d.scale(up, -30)
		local craft = FlightModel.newCraft(design, state)
		for _ = 1, 30 do
			FlightModel.step(craft)
		end
		t.expectTrue(#craft.destroyed > 0, "impact destroyed blocks")
	end)

	t.test("staging drops the lower stage as debris with a separation push", function()
		local design = Fixtures.sanity() -- 1 engine, 2 tank, 3 decoupler, 4 pod, 5 chute
		local craft = FlightModel.newCraft(design, onPad(design, 100))
		FlightModel.stage(craft) -- ignite
		local result = FlightModel.stage(craft) :: FlightModel.StageResult
		t.expectEqual(#result.decoupled, 1)
		t.expectEqual(#result.debris, 1)
		table.sort(result.debris[1].blockIds)
		t.expectEqual(table.concat(result.debris[1].blockIds, ","), "1,2,3")
		t.expectEqual(#craft.physics.design.blocks, 2)
		t.expectTrue(Vec3d.length(result.debris[1].deltaV) > 0, "debris gets a push")
		local debris = result.debris[1]
		t.expectEqual(#debris.design.blocks, 3)
		t.expectTrue(debris.state.pos.x < craft.state.pos.x, "debris reference sits below the pod")
		t.expectTrue(debris.fuel[2] ~= nil, "the tank's fuel goes with the debris")
		t.expectTrue(debris.active[1] == true, "the engine stays lit on the debris")
		-- the reference point (root) did not move in craft space
		t.expectEqual(craft.physics.originId, 4)
	end)
end
