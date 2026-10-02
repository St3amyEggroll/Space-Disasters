--!strict
--[[
	FlightModel (spec 7.4)
	Craft flight simulation shared by the pilot's client (its own craft) and the server (unpiloted crafts and
	debris). Never uses Roblox physics (invariant I3). Positions and velocities are doubles (Vec3d, invariant I1).

	Craft-local frame: origin at the reference block's centre (the root command part, or the lowest-id block for
	debris), axes = the design grid axes, studs = meters. The reference point is what CraftState.pos tracks, so
	the craft's parts never shift inside its pocket as fuel drains; internally the integrator works on the CoM.

	CraftState (universe axes, relative to the SOI body):
	  pos     reference point position (Vec3d)      vel     reference point velocity (Vec3d)
	  rot     craft axes -> universe axes (CFrame, rotation only)
	  angVel  rad/s, universe axes                    throttle 0..1   flags (bit field)   ut

	Per step: gravity (SOI body only, patched conics), thrust (constant fuel flow, Isp by pressure, gimbal
	torque), drag (projected area, nose factor, applied at the centre of pressure), fin lift (flat plate),
	(CHANGED (Physics feel): drag and lift areas at the parts' visual size, GameConfig.AERO_METERS_PER_STUD), ground
	contacts (penalty springs on hull points against SurfaceHeight, Coulomb friction), control torque and
	SAS. Translation: velocity Verlet with a velocity predictor for the velocity-dependent forces. Rotation:
	semi-implicit Euler on the diagonal inertia, re-orthonormalised every step.

	Crash: a hull point that hits the ground faster than its block's CrashTolerance destroys that block. The
	owner of the simulation reads craft.destroyed after each step and applies/reports it (removeBlocks).

	CHANGED (Phase 8): the ground is SurfaceHeight's heightmap (hills, mountains, craters): each hull point is pushed
	along the normal of the ground triangle under it, so crafts settle on slopes; the contact and near-surface
	substep checks measure from that ground, not from sea level (groundClearance).
]]

local Bodies = require(script.Parent.Parent.Config.Bodies)
local CraftDesign = require(script.Parent.Parent.Craft.CraftDesign)
local CraftGraph = require(script.Parent.Parent.Craft.CraftGraph)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local MassProps = require(script.Parent.Parent.Craft.MassProps)
local Parts = require(script.Parent.Parent.Config.Parts)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)
local Atmosphere = require(script.Parent.Atmosphere)
local SurfaceHeight = require(script.Parent.SurfaceHeight)
local Universe = require(script.Parent.Universe)

type Vec3d = Vec3d.Vec3d
type Design = CraftDesign.Design
type Graph = CraftGraph.Graph

--============================================================================
-- Tunables
--============================================================================
local G0 = GameConfig.G0
local GRID = CraftDesign.GRID
local STEP = 1 / GameConfig.SIM_RATE
local SUBSTEPS_FLIGHT = GameConfig.SIM_SUBSTEPS_FLIGHT
local SUBSTEPS_NEAR = GameConfig.SIM_SUBSTEPS_NEAR_SURFACE
local NEAR_SURFACE_DIST = GameConfig.SIM_NEAR_SURFACE_DIST
local ROTATION_ASSIST = GameConfig.ROTATION_ASSIST
local CD_BASE = GameConfig.CD_BASE
-- CHANGED (Physics feel): fin lift areas at the parts' visual size, the same factor MassProps applies to drag areas
-- (so finned rockets keep their lift-to-drag balance). Phase 2b chutes must scale their CdA by this too.
local AERO_AREA_SCALE = GameConfig.AERO_METERS_PER_STUD * GameConfig.AERO_METERS_PER_STUD
local MAX_ANGULAR_SPEED = GameConfig.MAX_ANGULAR_SPEED
local SAS_KP = GameConfig.SAS_KP
local SAS_KD = GameConfig.SAS_KD
local MASS_REFRESH_S = 1 / GameConfig.MASS_PROPS_FUEL_RATE
local MAX_HULL_POINTS = GameConfig.MAX_HULL_POINTS
local CONTACT_FREQUENCY = 7 -- Hz, natural frequency of the ground contact for the whole craft
local CONTACT_DAMPING_RATIO = 0.8
local CONTACT_POINTS_EXPECTED = 4 -- contact stiffness is split as if this many hull points share the load
local CONTACT_SPRING_CAP = GameConfig.CONTACT_SPRING -- N/m per hull point (upper bound)
local CONTACT_DAMPER_CAP = GameConfig.CONTACT_DAMPER -- N*s/m per hull point (upper bound)
local FRICTION = GameConfig.CONTACT_FRICTION
local FRICTION_VISCOUS = 4 -- 1/s; friction ramps in with tangential speed to stay stable near zero
local SUPPORT_DIRECTIONS = 72 -- directions sampled to pick convex-hull points
local MIN_DRAG_SPEED = 0.05 -- m/s
--============================================================================

export type CraftState = {
	bodyId: number,
	pos: Vec3d,
	vel: Vec3d,
	rot: CFrame,
	angVel: Vector3,
	throttle: number,
	flags: number,
	ut: number,
}

-- CraftState.flags bits
local FLAG_SAS = 1
local FLAG_BURNING = 2 -- at least one engine producing thrust (for plumes)
local FLAG_CONTACT = 4 -- touching the ground this step
local FLAG_CHUTES = 8 -- parachutes deployed (Phase 2b)
local FLAG_GEAR_UP = 16 -- CHANGED (Phase 2a remodel): landing legs retracted (clear = deployed, the default)

export type Engine = {
	blockId: number,
	solid: boolean,
	pos: Vector3, -- craft-local
	axis: Vector3, -- craft-local unit vector the thrust pushes along
	stats: Parts.EngineStats,
	flow: number, -- kg/s at full throttle
}

export type Fin = { blockId: number, pos: Vector3, normal: Vector3, area: number, liftCoef: number }

export type HullPoint = { pos: Vector3, blockId: number, tolerance: number }

export type Physics = {
	design: Design,
	graph: Graph,
	originId: number, -- reference block
	originCenter: Vector3, -- reference block centre in design studs
	blockPos: { [number]: Vector3 }, -- craft-local block centres
	dryMass: number,
	com: Vector3, -- craft-local
	inertia: Vector3,
	area: Vector3,
	leadDrag: { [string]: number },
	cop: Vector3,
	engines: { Engine },
	fins: { Fin },
	hull: { HullPoint },
	boundingRadius: number, -- max hull distance from the origin
	commandTorque: number,
	groups: { { number } }, -- fuel groups (tank block ids) indexed like `groupOf`
	groupOf: { [number]: number }, -- block id -> fuel group index
}

export type Controls = { pitch: number, yaw: number, roll: number, throttle: number, sas: boolean }

export type Craft = {
	physics: Physics,
	state: CraftState,
	fuel: { [number]: number }, -- block id -> kg of fuel left (tanks and solid boosters)
	active: { [number]: boolean }, -- ignited engine block ids
	stages: { CraftGraph.Stage }, -- the staging sequence fixed at launch
	stageIndex: number, -- next stage to fire (1-based)
	controls: Controls,
	sasTarget: CFrame?,
	mass: number,
	massRefreshTimer: number,
	destroyed: { number }, -- block ids destroyed by impacts since the owner last cleared the list
	lastContactSpeed: number, -- m/s, largest impact speed seen this step (for effects)
}

export type Debris = {
	blockIds: { number },
	deltaV: Vec3d, -- separation velocity that was added (universe axes)
	design: Design, -- the piece's own design (block ids preserved)
	state: CraftState, -- the piece's state at the split, including deltaV
	fuel: { [number]: number }, -- fuel left in the piece's tanks / boosters
	active: { [number]: boolean }, -- engines still ignited in the piece
}

export type StageResult = {
	stage: number,
	ignited: { number },
	decoupled: { number },
	deployed: { number },
	debris: { Debris },
}

local FlightModel = {}

FlightModel.FLAG_SAS = FLAG_SAS
FlightModel.FLAG_BURNING = FLAG_BURNING
FlightModel.FLAG_CONTACT = FLAG_CONTACT
FlightModel.FLAG_CHUTES = FLAG_CHUTES
FlightModel.FLAG_GEAR_UP = FLAG_GEAR_UP
FlightModel.STEP = STEP

--============================================================================
-- Physics build (from a design)
--============================================================================

local function fibonacciDirections(count: number): { Vector3 }
	local dirs = table.create(count)
	local golden = math.pi * (3 - math.sqrt(5))
	for i = 0, count - 1 do
		local y = 1 - (i + 0.5) / count * 2
		local r = math.sqrt(1 - y * y)
		local theta = golden * i
		dirs[i + 1] = Vector3.new(r * math.cos(theta), y, r * math.sin(theta))
	end
	return dirs
end

local SUPPORT_DIRS = fibonacciDirections(SUPPORT_DIRECTIONS)

-- Reference block: the root command part, else the lowest block id.
local function originBlock(design: Design): CraftDesign.Block
	local root = CraftDesign.rootBlock(design)
	if root then
		return root
	end
	local lowest = design.blocks[1]
	for _, block in design.blocks do
		if block.id < lowest.id then
			lowest = block
		end
	end
	return lowest
end

local function fuelGroups(design: Design, graph: Graph): ({ { number } }, { [number]: number })
	local groups: { { number } } = {}
	local groupOf: { [number]: number } = {}
	if graph.rootId then
		for _, segment in graph.segments do
			groups[segment.index] = {}
			for _, id in segment.blockIds do
				groupOf[id] = segment.index
			end
		end
		-- blocks not reachable from the root form one extra group (should not happen after splits)
		local loose = #graph.segments + 1
		for _, id in graph.looseIds do
			groupOf[id] = loose
			groups[loose] = groups[loose] or {}
		end
	else
		groups[1] = {}
		for _, block in design.blocks do
			groupOf[block.id] = 1
		end
	end
	for _, block in design.blocks do
		local def = Parts.get(block.type)
		if def.FuelMass > 0 and def.Engine == nil then
			table.insert(groups[groupOf[block.id]], block.id)
		end
	end
	return groups, groupOf
end

function FlightModel.buildPhysics(design: Design, fuel: { [number]: number }): Physics
	assert(#design.blocks > 0, "cannot build physics for an empty design")
	local graph = CraftGraph.build(design)
	local origin = originBlock(design)
	local originCenter = CraftDesign.blockCenter(origin) * GRID

	local blockPos: { [number]: Vector3 } = {}
	local engines: { Engine } = {}
	local fins: { Fin } = {}
	local commandTorque = 0
	local dryMass = 0
	local corners: { [string]: { pos: Vector3, blockId: number } } = {}

	for _, block in design.blocks do
		local def = Parts.get(block.type)
		local center = CraftDesign.blockCenter(block) * GRID - originCenter
		blockPos[block.id] = center
		dryMass += def.DryMass
		commandTorque += def.Torque
		local rot = CraftDesign.rotationCFrame(block.rot)
		if def.Engine then
			local stats = def.Engine :: Parts.EngineStats
			table.insert(engines, {
				blockId = block.id,
				solid = CraftGraph.isSolid(def),
				pos = center,
				axis = rot.UpVector,
				stats = stats,
				flow = Parts.massFlow(stats, G0),
			})
		end
		if def.Fin then
			local finStats = def.Fin :: Parts.FinStats
			table.insert(fins, {
				blockId = block.id,
				pos = center,
				normal = rot.RightVector, -- the fin blade is thin along its local X
				area = finStats.Area * AERO_AREA_SCALE, -- CHANGED (Physics feel): visual-size lift area
				liftCoef = finStats.LiftCoef,
			})
		end
		local minV = CraftDesign.blockMin(block) * GRID - originCenter
		local maxV = CraftDesign.blockMax(block) * GRID - originCenter
		for _, x in { minV.X, maxV.X } do
			for _, y in { minV.Y, maxV.Y } do
				for _, z in { minV.Z, maxV.Z } do
					local key = `{x},{y},{z}`
					if corners[key] == nil then
						corners[key] = { pos = Vector3.new(x, y, z), blockId = block.id }
					end
				end
			end
		end
	end

	-- Convex-hull points: the support point of the corner cloud in many directions.
	local hull: { HullPoint } = {}
	local used: { [string]: boolean } = {}
	local cornerList = {}
	for key, corner in corners do
		table.insert(cornerList, { key = key, pos = corner.pos, blockId = corner.blockId })
	end
	table.sort(cornerList, function(a, b)
		return a.key < b.key
	end)
	local boundingRadius = 0
	for _, dir in SUPPORT_DIRS do
		local best = nil
		local bestDot = -math.huge
		for _, corner in cornerList do
			local d = corner.pos:Dot(dir)
			if d > bestDot then
				bestDot = d
				best = corner
			end
		end
		if best and not used[best.key] and #hull < MAX_HULL_POINTS then
			used[best.key] = true
			table.insert(hull, {
				pos = best.pos,
				blockId = best.blockId,
				tolerance = Parts.get((CraftDesign.findBlock(design, best.blockId) :: CraftDesign.Block).type).CrashTolerance,
			})
			boundingRadius = math.max(boundingRadius, best.pos.Magnitude)
		end
	end

	local groups, groupOf = fuelGroups(design, graph)

	local physics: Physics = {
		design = design,
		graph = graph,
		originId = origin.id,
		originCenter = originCenter,
		blockPos = blockPos,
		dryMass = dryMass,
		com = Vector3.zero,
		inertia = Vector3.one,
		area = Vector3.one,
		leadDrag = {},
		cop = Vector3.zero,
		engines = engines,
		fins = fins,
		hull = hull,
		boundingRadius = boundingRadius,
		commandTorque = commandTorque,
		groups = groups,
		groupOf = groupOf,
	}
	FlightModel.refreshMassProps(physics, fuel)
	return physics
end

-- Recomputes CoM, inertia, areas and CoP for the current fuel (called at MASS_PROPS_FUEL_RATE while burning).
function FlightModel.refreshMassProps(physics: Physics, fuel: { [number]: number })
	local props = MassProps.compute(physics.design, fuel)
	physics.com = props.com - physics.originCenter
	physics.inertia =
		Vector3.new(math.max(props.inertia.X, 1), math.max(props.inertia.Y, 1), math.max(props.inertia.Z, 1))
	physics.area = props.area
	physics.leadDrag = props.leadDragFactor
	physics.cop = props.cop - physics.originCenter
end

--============================================================================
-- Craft construction
--============================================================================

-- Full fuel for every tank and solid booster in a design.
function FlightModel.fullFuel(design: Design): { [number]: number }
	local fuel: { [number]: number } = {}
	for _, block in design.blocks do
		local def = Parts.get(block.type)
		if def.FuelMass > 0 then
			fuel[block.id] = def.FuelMass
		end
	end
	return fuel
end

local function totalFuel(craft: Craft): number
	local total = 0
	for id, amount in craft.fuel do
		if craft.physics.blockPos[id] then
			total += amount
		end
	end
	return total
end

function FlightModel.totalFuel(craft: Craft): number
	return totalFuel(craft)
end

--[[
	Creates a simulated craft. `stages` defaults to the design's auto staging (use the parent's stage list,
	already partly consumed, for crafts created by splits).
]]
function FlightModel.newCraft(
	design: Design,
	state: CraftState,
	fuel: { [number]: number }?,
	stages: { CraftGraph.Stage }?,
	stageIndex: number?
): Craft
	local fuelMap = fuel or FlightModel.fullFuel(design)
	local physics = FlightModel.buildPhysics(design, fuelMap)
	local craft: Craft = {
		physics = physics,
		state = state,
		fuel = fuelMap,
		active = {},
		stages = stages or physics.graph.stages,
		stageIndex = stageIndex or 1,
		controls = { pitch = 0, yaw = 0, roll = 0, throttle = state.throttle, sas = false },
		sasTarget = nil,
		mass = 0,
		massRefreshTimer = 0,
		destroyed = {},
		lastContactSpeed = 0,
	}
	craft.mass = physics.dryMass + totalFuel(craft)
	return craft
end

function FlightModel.setControls(craft: Craft, pitch: number, yaw: number, roll: number, throttle: number, sas: boolean)
	local c = craft.controls
	c.pitch = math.clamp(pitch, -1, 1)
	c.yaw = math.clamp(yaw, -1, 1)
	c.roll = math.clamp(roll, -1, 1)
	c.throttle = math.clamp(throttle, 0, 1)
	if sas and not c.sas then
		craft.sasTarget = nil
	end
	c.sas = sas
	craft.state.throttle = c.throttle
end

--============================================================================
-- Force model
--============================================================================

type Accum = {
	force: Vec3d, -- universe axes, N
	torque: Vector3, -- craft axes, N*m (about the CoM)
}

local function groupFuel(craft: Craft, group: number): number
	local total = 0
	local tanks: { number } = craft.physics.groups[group] or {}
	for _, id in tanks do
		total += craft.fuel[id] or 0
	end
	return total
end

-- Is this engine able to burn right now?
local function engineHasFuel(craft: Craft, engine: Engine): boolean
	if engine.solid then
		return (craft.fuel[engine.blockId] or 0) > 0
	end
	local group = craft.physics.groupOf[engine.blockId]
	return group ~= nil and groupFuel(craft, group) > 0
end

local function engineThrottle(craft: Craft, engine: Engine): number
	if engine.solid or not engine.stats.Throttleable then
		return 1
	end
	return craft.controls.throttle
end

-- CHANGED (Phase 2a feedback): exact per-engine "producing thrust now" test, shared with the plume renderer
-- (plumes used a whole-craft flag plus a fuel guess and could stay lit on an engine with no thrust).
function FlightModel.engineBurning(craft: Craft, engine: Engine): boolean
	return craft.active[engine.blockId] == true and engineHasFuel(craft, engine) and engineThrottle(craft, engine) > 0
end

-- Throttle an engine runs at (solid boosters and non-throttleable engines: always 1).
function FlightModel.engineThrottle(craft: Craft, engine: Engine): number
	return engineThrottle(craft, engine)
end

-- Takes `amount` kg from an engine's fuel source, spread across its group's tanks by what each holds.
local function drainFuel(craft: Craft, engine: Engine, amount: number)
	if engine.solid then
		craft.fuel[engine.blockId] = math.max(0, (craft.fuel[engine.blockId] or 0) - amount)
		return
	end
	local group = craft.physics.groupOf[engine.blockId]
	local available = groupFuel(craft, group)
	if available <= 0 then
		return
	end
	local fraction = math.min(1, amount / available)
	for _, id in craft.physics.groups[group] do
		local have = craft.fuel[id] or 0
		craft.fuel[id] = have - have * fraction
	end
end

--[[
	CHANGED (Phase 8): how far a hull of radius `reach` around `pos` (altitude above sea level given) is above the
	ground, conservatively: its height above the heightmap ground under `pos`, less `reach` twice over (the ground may
	rise toward the hull's far side). Skips the ground lookup when even the highest ground is far below.
]]
local function groundClearance(bodyId: number, pos: Vec3d, altitude: number, reach: number): number
	local _, highest = SurfaceHeight.bounds(bodyId)
	local rough = altitude - math.max(highest, 0) - 2 * reach
	if rough > NEAR_SURFACE_DIST + 5 then
		return rough
	end
	local height = SurfaceHeight.height(bodyId, pos)
	return height - 2 * reach
end

--[[
	Computes forces for a candidate state. `comPos`/`comVel` are the CoM's (doubles); returns the net force
	(universe) and torque (craft axes). `applyContacts` records impacts only on the committed evaluation.
]]
local function computeForces(
	craft: Craft,
	comPos: Vec3d,
	comVel: Vec3d,
	rot: CFrame,
	omegaCraft: Vector3,
	recordImpacts: boolean
): Accum
	local physics = craft.physics
	local state = craft.state
	local body = Bodies.get(state.bodyId)
	local force = Vec3d.zero()
	local torque = Vector3.zero

	-- Gravity (patched conics: the SOI body only)
	local r2 = Vec3d.lengthSq(comPos)
	local r = math.sqrt(r2)
	local gScale = -body.Mu * craft.mass / (r2 * r)
	Vec3d.addScaledInto(force, force, comPos, gScale)

	local altitude = r - body.Radius
	local rho = Atmosphere.density(state.bodyId, altitude)
	local pressure = Atmosphere.pressureRatio(state.bodyId, altitude)

	-- Thrust and gimbal authority
	local gimbalTorque = 0
	local burning = false
	for _, engine in physics.engines do
		if craft.active[engine.blockId] and engineHasFuel(craft, engine) then
			local throttle = engineThrottle(craft, engine)
			if throttle > 0 then
				local thrust = Parts.thrustAt(engine.stats, pressure, G0) * throttle
				local lever = engine.pos - physics.com
				local fCraft = engine.axis * thrust
				torque += lever:Cross(fCraft)
				local fWorld = rot:VectorToWorldSpace(fCraft)
				force.x += fWorld.X
				force.y += fWorld.Y
				force.z += fWorld.Z
				gimbalTorque += thrust * math.sin(math.rad(engine.stats.GimbalDeg)) * lever.Magnitude
				burning = true
			end
		end
	end
	state.flags = if burning
		then bit32.bor(state.flags, FLAG_BURNING)
		else bit32.band(state.flags, bit32.bnot(FLAG_BURNING))

	-- Aerodynamics
	local speed = Vec3d.length(comVel)
	if rho > 0 and speed > MIN_DRAG_SPEED then
		local vWorld = Vector3.new(comVel.x / speed, comVel.y / speed, comVel.z / speed)
		local vCraft = rot:VectorToObjectSpace(vWorld)
		local q = 0.5 * rho * speed * speed
		local area = math.abs(vCraft.X) * physics.area.X
			+ math.abs(vCraft.Y) * physics.area.Y
			+ math.abs(vCraft.Z) * physics.area.Z
		local ax, ay, az = math.abs(vCraft.X), math.abs(vCraft.Y), math.abs(vCraft.Z)
		local leadKey: string
		if ax >= ay and ax >= az then
			leadKey = if vCraft.X > 0 then "+X" else "-X"
		elseif ay >= az then
			leadKey = if vCraft.Y > 0 then "+Y" else "-Y"
		else
			leadKey = if vCraft.Z > 0 then "+Z" else "-Z"
		end
		local cdA = CD_BASE * area * (physics.leadDrag[leadKey] or 1)
		local dragCraft = -vCraft * (q * cdA)
		torque += (physics.cop - physics.com):Cross(dragCraft)
		local dragWorld = rot:VectorToWorldSpace(dragCraft)
		force.x += dragWorld.X
		force.y += dragWorld.Y
		force.z += dragWorld.Z
		for _, fin in physics.fins do
			local sinAoA = vCraft:Dot(fin.normal)
			local liftCraft = fin.normal * (-q * fin.area * fin.liftCoef * sinAoA)
			torque += (fin.pos - physics.com):Cross(liftCraft)
			local liftWorld = rot:VectorToWorldSpace(liftCraft)
			force.x += liftWorld.X
			force.y += liftWorld.Y
			force.z += liftWorld.Z
		end
	end

	-- Ground contacts (only when the hull could reach the ground)
	-- CHANGED (Phase 8): measured from the heightmap ground under the CoM (hills and mountains), with room for the
	-- ground rising under the far side of the hull (slopes up to 45 degrees)
	local contact = false
	local reach = physics.boundingRadius + Vec3d.length(Vec3d.new(physics.com.X, physics.com.Y, physics.com.Z))
	if groundClearance(state.bodyId, comPos, altitude, reach) < NEAR_SURFACE_DIST + 5 then
		local omegaWorld = rot:VectorToWorldSpace(omegaCraft)
		local kPoint =
			math.min(CONTACT_SPRING_CAP, craft.mass * (2 * math.pi * CONTACT_FREQUENCY) ^ 2 / CONTACT_POINTS_EXPECTED)
		local cPoint = math.min(
			CONTACT_DAMPER_CAP,
			2 * CONTACT_DAMPING_RATIO * craft.mass * (2 * math.pi * CONTACT_FREQUENCY) / CONTACT_POINTS_EXPECTED
		)
		local point = Vec3d.zero()
		for _, hullPoint in physics.hull do
			local leverCraft = hullPoint.pos - physics.com
			local leverWorld = rot:VectorToWorldSpace(leverCraft)
			Vec3d.set(point, comPos.x + leverWorld.X, comPos.y + leverWorld.Y, comPos.z + leverWorld.Z)
			local height, up = SurfaceHeight.height(state.bodyId, point)
			if height < 0 then
				contact = true
				local n = Vector3.new(up.x, up.y, up.z)
				local vPoint = Vector3.new(comVel.x, comVel.y, comVel.z) + omegaWorld:Cross(leverWorld)
				local vn = vPoint:Dot(n)
				if recordImpacts and -vn > hullPoint.tolerance then
					if not table.find(craft.destroyed, hullPoint.blockId) then
						table.insert(craft.destroyed, hullPoint.blockId)
					end
				end
				if recordImpacts then
					craft.lastContactSpeed = math.max(craft.lastContactSpeed, -vn)
				end
				local normalForce = math.max(0, kPoint * -height - cPoint * vn)
				local vt = vPoint - n * vn
				local vtMag = vt.Magnitude
				local fWorld = n * normalForce
				if vtMag > 1e-4 then
					local frictionMag = math.min(
						FRICTION * normalForce,
						craft.mass / CONTACT_POINTS_EXPECTED * FRICTION_VISCOUS * vtMag
					)
					fWorld -= vt * (frictionMag / vtMag)
				end
				force.x += fWorld.X
				force.y += fWorld.Y
				force.z += fWorld.Z
				torque += leverCraft:Cross(rot:VectorToObjectSpace(fWorld))
			end
		end
	end
	state.flags = if contact
		then bit32.bor(state.flags, FLAG_CONTACT)
		else bit32.band(state.flags, bit32.bnot(FLAG_CONTACT))

	-- Pilot control torque and SAS (craft axes: pitch about X, roll about Y, yaw about Z)
	local budget = (physics.commandTorque + gimbalTorque) * ROTATION_ASSIST
	if budget > 0 then
		local c = craft.controls
		local commanded = Vector3.new(-c.pitch, -c.roll, -c.yaw) * budget
		local hasInput = c.pitch ~= 0 or c.yaw ~= 0 or c.roll ~= 0
		if c.sas and not hasInput then
			local target = craft.sasTarget
			if target == nil then
				target = rot
				craft.sasTarget = rot
			end
			-- rotation that takes the current attitude to the target, in craft axes
			local delta = rot:ToObjectSpace(target :: CFrame)
			local axis, angle = delta:ToAxisAngle()
			if angle > math.pi then
				angle -= 2 * math.pi
			end
			local inertia = physics.inertia
			local accel = axis * (angle * SAS_KP) - omegaCraft * SAS_KD
			local wanted = Vector3.new(accel.X * inertia.X, accel.Y * inertia.Y, accel.Z * inertia.Z)
			commanded = Vector3.new(
				math.clamp(wanted.X, -budget, budget),
				math.clamp(wanted.Y, -budget, budget),
				math.clamp(wanted.Z, -budget, budget)
			)
		elseif hasInput then
			craft.sasTarget = nil
		end
		torque += commanded
	end

	return { force = force, torque = torque }
end

--============================================================================
-- Integration
--============================================================================

local function orthonormalize(cf: CFrame): CFrame
	local x = cf.XVector.Unit
	local y = (cf.YVector - x * x:Dot(cf.YVector)).Unit
	local z = x:Cross(y)
	return CFrame.fromMatrix(Vector3.zero, x, y, z)
end

local function nearSurface(craft: Craft): boolean
	local state = craft.state
	local altitude = Vec3d.length(state.pos) - Bodies.get(state.bodyId).Radius
	-- CHANGED (Phase 8): from the heightmap ground, not sea level
	return groundClearance(state.bodyId, state.pos, altitude, craft.physics.boundingRadius) < NEAR_SURFACE_DIST
end

local function substep(craft: Craft, dt: number)
	local physics = craft.physics
	local state = craft.state
	local rot = state.rot

	-- CoM state from the reference point state
	local comWorld = rot:VectorToWorldSpace(physics.com)
	local omegaWorld = state.angVel
	local comPos = Vec3d.new(state.pos.x + comWorld.X, state.pos.y + comWorld.Y, state.pos.z + comWorld.Z)
	local comVelOffset = omegaWorld:Cross(comWorld)
	local comVel = Vec3d.new(state.vel.x + comVelOffset.X, state.vel.y + comVelOffset.Y, state.vel.z + comVelOffset.Z)
	local omegaCraft = rot:VectorToObjectSpace(omegaWorld)

	-- Velocity Verlet with a velocity predictor for velocity-dependent forces
	local a0 = computeForces(craft, comPos, comVel, rot, omegaCraft, false)
	local invMass = 1 / craft.mass
	local ax0, ay0, az0 = a0.force.x * invMass, a0.force.y * invMass, a0.force.z * invMass
	local newPos = Vec3d.new(
		comPos.x + comVel.x * dt + 0.5 * ax0 * dt * dt,
		comPos.y + comVel.y * dt + 0.5 * ay0 * dt * dt,
		comPos.z + comVel.z * dt + 0.5 * az0 * dt * dt
	)
	local predictedVel = Vec3d.new(comVel.x + ax0 * dt, comVel.y + ay0 * dt, comVel.z + az0 * dt)
	local a1 = computeForces(craft, newPos, predictedVel, rot, omegaCraft, true)
	local ax1, ay1, az1 = a1.force.x * invMass, a1.force.y * invMass, a1.force.z * invMass
	local newVel = Vec3d.new(
		comVel.x + 0.5 * (ax0 + ax1) * dt,
		comVel.y + 0.5 * (ay0 + ay1) * dt,
		comVel.z + 0.5 * (az0 + az1) * dt
	)

	-- Rotation: semi-implicit Euler on the diagonal inertia (no gyroscopic term in v1)
	local torque = (a0.torque + a1.torque) * 0.5
	local inertia = physics.inertia
	omegaCraft += Vector3.new(torque.X / inertia.X, torque.Y / inertia.Y, torque.Z / inertia.Z) * dt
	if omegaCraft.Magnitude > MAX_ANGULAR_SPEED then
		omegaCraft = omegaCraft.Unit * MAX_ANGULAR_SPEED
	end
	omegaWorld = rot:VectorToWorldSpace(omegaCraft)
	local angle = omegaWorld.Magnitude * dt
	if angle > 1e-12 then
		rot = CFrame.fromAxisAngle(omegaWorld.Unit, angle) * rot
	end
	rot = orthonormalize(rot)

	-- Back to the reference point
	local newComWorld = rot:VectorToWorldSpace(physics.com)
	local newOffsetVel = omegaWorld:Cross(newComWorld)
	state.pos = Vec3d.new(newPos.x - newComWorld.X, newPos.y - newComWorld.Y, newPos.z - newComWorld.Z)
	state.vel = Vec3d.new(newVel.x - newOffsetVel.X, newVel.y - newOffsetVel.Y, newVel.z - newOffsetVel.Z)
	state.rot = rot
	state.angVel = omegaWorld

	-- Fuel
	local burnedAny = false
	for _, engine in physics.engines do
		if craft.active[engine.blockId] and engineHasFuel(craft, engine) then
			local throttle = engineThrottle(craft, engine)
			if throttle > 0 then
				drainFuel(craft, engine, engine.flow * throttle * dt)
				burnedAny = true
			end
		end
	end
	if burnedAny then
		craft.mass = physics.dryMass + totalFuel(craft)
	end
end

-- Patched-conics SOI switch at the current state.
local function checkSoi(craft: Craft)
	local state = craft.state
	local newBody, newPos = Universe.soiTransition(state.bodyId, state.pos, state.ut)
	if newBody ~= state.bodyId then
		local velOffset = Universe.bodyVelocityOffset(state.bodyId, newBody, state.ut)
		state.vel = Vec3d.add(state.vel, velOffset)
		state.pos = newPos
		state.bodyId = newBody
	end
end

-- CHANGED (Phase 2a remodel): raises (true) or lowers the landing legs. Visual only for now: contact still uses each
-- leg block's full box. The state travels in CraftState.flags, so every client animates the same legs.
function FlightModel.setGearUp(craft: Craft, up: boolean)
	craft.state.flags = if up
		then bit32.bor(craft.state.flags, FLAG_GEAR_UP)
		else bit32.band(craft.state.flags, bit32.bnot(FLAG_GEAR_UP))
end

function FlightModel.isGearUp(flags: number): boolean
	return bit32.band(flags, FLAG_GEAR_UP) ~= 0
end

-- Advances the craft by one fixed step (FlightModel.STEP), with substeps near the surface.
function FlightModel.step(craft: Craft, dt: number?)
	local stepDt = dt or STEP
	craft.lastContactSpeed = 0
	local substeps = if nearSurface(craft) then SUBSTEPS_NEAR else SUBSTEPS_FLIGHT
	local h = stepDt / substeps
	for _ = 1, substeps do
		substep(craft, h)
	end
	craft.state.ut += stepDt
	craft.state.flags = if craft.controls.sas
		then bit32.bor(craft.state.flags, FLAG_SAS)
		else bit32.band(craft.state.flags, bit32.bnot(FLAG_SAS))
	checkSoi(craft)
	craft.massRefreshTimer += stepDt
	if craft.massRefreshTimer >= MASS_REFRESH_S then
		craft.massRefreshTimer = 0
		FlightModel.refreshMassProps(craft.physics, craft.fuel)
	end
end

--============================================================================
-- Staging, splits and destruction
--============================================================================

-- World position/velocity of a craft-local point (doubles) for a craft state.
function FlightModel.pointState(craft: Craft, localPos: Vector3): (Vec3d, Vec3d)
	local state = craft.state
	local offset = state.rot:VectorToWorldSpace(localPos)
	local pointVel = state.angVel:Cross(offset)
	return Vec3d.new(state.pos.x + offset.X, state.pos.y + offset.Y, state.pos.z + offset.Z),
		Vec3d.new(state.vel.x + pointVel.X, state.vel.y + pointVel.Y, state.vel.z + pointVel.Z)
end

local function massOf(craft: Craft, ids: { number }): number
	local m = 0
	for _, id in ids do
		local block = craft.physics.graph.blockById[id]
		if block then
			m += Parts.get(block.type).DryMass + (craft.fuel[id] or 0)
		end
	end
	return m
end

local function centroid(craft: Craft, ids: { number }): Vector3
	local sum = Vector3.zero
	local total = 0
	for _, id in ids do
		local block = craft.physics.graph.blockById[id]
		if block then
			local m = Parts.get(block.type).DryMass + (craft.fuel[id] or 0)
			sum += craft.physics.blockPos[id] * m
			total += m
		end
	end
	return if total > 0 then sum / total else Vector3.zero
end

local splitState: (Craft, { number }, Vec3d?) -> (Design, CraftState)

local function makeDebris(craft: Craft, blockIds: { number }, deltaV: Vec3d): Debris
	local design, state = splitState(craft, blockIds, deltaV)
	local fuel: { [number]: number } = {}
	local active: { [number]: boolean } = {}
	for _, id in blockIds do
		if craft.fuel[id] then
			fuel[id] = craft.fuel[id]
		end
		if craft.active[id] then
			active[id] = true
		end
	end
	return { blockIds = blockIds, deltaV = deltaV, design = design, state = state, fuel = fuel, active = active }
end

--[[
	Removes blocks (destroyed or separated) and rebuilds the craft's physics. Returns the pieces that came off
	(connected components of what is left, not containing the reference block) as Debris with their own designs
	and states, and whether the reference block itself was removed (then every remaining piece is returned and
	the caller should retire this craft).
]]
function FlightModel.removeBlocks(craft: Craft, ids: { number }, deltaVs: { Vec3d }?): ({ Debris }, boolean)
	local physics = craft.physics
	local removed: { [number]: boolean } = {}
	for _, id in ids do
		removed[id] = true
	end
	local components = CraftGraph.components(physics.design, physics.graph.neighbors, removed, physics.originId)
	local originLost = removed[physics.originId] == true
	local keep: { number }? = nil
	if not originLost and #components > 0 and table.find(components[1], physics.originId) then
		keep = table.remove(components, 1)
	end
	local pieces: { Debris } = {}
	for index, component in components do
		local dv = if deltaVs and deltaVs[index] then deltaVs[index] else Vec3d.zero()
		table.insert(pieces, makeDebris(craft, component, dv))
	end
	if keep then
		local keepSet: { [number]: boolean } = {}
		for _, id in keep do
			keepSet[id] = true
		end
		local newDesign = CraftDesign.new(physics.design.name)
		for _, block in physics.design.blocks do
			if keepSet[block.id] then
				table.insert(newDesign.blocks, block)
			end
		end
		-- keep the reference point where it was: the origin block is unchanged, so craft-local positions stay put
		craft.physics = FlightModel.buildPhysics(newDesign, craft.fuel)
		craft.mass = craft.physics.dryMass + totalFuel(craft)
	end
	for _, id in ids do
		craft.active[id] = nil
	end
	return pieces, originLost
end

-- Fires the next stage. Returns nil when there are no stages left.
function FlightModel.stage(craft: Craft): StageResult?
	local stage = craft.stages[craft.stageIndex]
	if stage == nil then
		return nil
	end
	local index = craft.stageIndex
	craft.stageIndex += 1
	local physics = craft.physics
	local result: StageResult = { stage = index, ignited = {}, decoupled = {}, deployed = {}, debris = {} }

	for _, id in stage.ignite do
		if physics.blockPos[id] then
			craft.active[id] = true
			table.insert(result.ignited, id)
		end
	end
	for _, id in stage.deploy do
		if physics.blockPos[id] then
			table.insert(result.deployed, id)
		end
	end

	-- Decouplers: each drops its segment and everything hanging from it
	local dropIds: { number } = {}
	local impulses: { { ids: { [number]: boolean }, impulse: number } } = {}
	for _, decouplerId in stage.decouple do
		local segmentIndex = physics.graph.segmentOf[decouplerId]
		if physics.blockPos[decouplerId] and segmentIndex then
			table.insert(result.decoupled, decouplerId)
			local subtree = CraftGraph.subtree(physics.graph, segmentIndex)
			local set: { [number]: boolean } = {}
			for _, segment in physics.graph.segments do
				if subtree[segment.index] then
					for _, id in segment.blockIds do
						if not table.find(dropIds, id) then
							table.insert(dropIds, id)
						end
						set[id] = true
					end
				end
			end
			local decoupler = Parts.get(physics.graph.blockById[decouplerId].type).Decoupler
			table.insert(impulses, { ids = set, impulse = if decoupler then decoupler.Impulse else 0 })
		end
	end

	if #dropIds > 0 then
		local dropSet: { [number]: boolean } = {}
		for _, id in dropIds do
			dropSet[id] = true
		end
		local keptIds: { number } = {}
		local keptSet: { [number]: boolean } = {}
		for id in physics.blockPos do
			if not dropSet[id] then
				table.insert(keptIds, id)
				keptSet[id] = true
			end
		end
		local keptCentroid = centroid(craft, keptIds)
		local keptMass = massOf(craft, keptIds)

		-- Each connected piece of the dropped set becomes its own debris, pushed away from the kept craft.
		local keptDeltaCraft = Vector3.zero
		for _, piece in CraftGraph.components(physics.design, physics.graph.neighbors, keptSet, nil) do
			local impulse = 0
			for _, entry in impulses do
				if entry.ids[piece[1]] then
					impulse = entry.impulse
				end
			end
			local away = centroid(craft, piece) - keptCentroid
			local dir = if away.Magnitude > 1e-6 then away.Unit else Vector3.new(0, -1, 0)
			local dvDebris = dir * (impulse / math.max(massOf(craft, piece), 1))
			keptDeltaCraft -= dir * (impulse / math.max(keptMass, 1))
			local dvWorld = craft.state.rot:VectorToWorldSpace(dvDebris)
			table.insert(result.debris, makeDebris(craft, piece, Vec3d.fromVector3(dvWorld)))
		end

		FlightModel.removeBlocks(craft, dropIds)
		local keptDeltaWorld = craft.state.rot:VectorToWorldSpace(keptDeltaCraft)
		craft.state.vel = Vec3d.add(craft.state.vel, Vec3d.fromVector3(keptDeltaWorld))
	end
	return result
end

--[[
	State for a piece split off `parent` (block ids from stage()/removeBlocks()), with its own reference point
	(the piece's root or lowest-id block), inheriting the parent's motion plus `deltaV`.
]]
splitState = function(parent: Craft, blockIds: { number }, deltaV: Vec3d?): (Design, CraftState)
	local physics = parent.physics
	local design = CraftDesign.new(physics.design.name .. " debris")
	local lookup: { [number]: boolean } = {}
	for _, id in blockIds do
		lookup[id] = true
	end
	for _, block in physics.design.blocks do
		if lookup[block.id] then
			table.insert(design.blocks, block)
		end
	end
	local origin = originBlock(design)
	local localPos = CraftDesign.blockCenter(origin) * GRID - physics.originCenter
	local pos, vel = FlightModel.pointState(parent, localPos)
	if deltaV then
		vel = Vec3d.add(vel, deltaV)
	end
	local s = parent.state
	return design,
		{
			bodyId = s.bodyId,
			pos = pos,
			vel = vel,
			rot = s.rot,
			angVel = s.angVel,
			throttle = 0,
			flags = 0,
			ut = s.ut,
		}
end

FlightModel.splitState = splitState

-- Fraction of the craft's full fuel capacity that is left.
function FlightModel.remainingFuelFraction(craft: Craft): number
	local full = 0
	for _, block in craft.physics.design.blocks do
		full += Parts.get(block.type).FuelMass
	end
	return if full > 0 then totalFuel(craft) / full else 0
end

-- A copy of a state (states are mutated in place by step()).
function FlightModel.copyState(state: CraftState): CraftState
	return {
		bodyId = state.bodyId,
		pos = Vec3d.clone(state.pos),
		vel = Vec3d.clone(state.vel),
		rot = state.rot,
		angVel = state.angVel,
		throttle = state.throttle,
		flags = state.flags,
		ut = state.ut,
	}
end

return table.freeze(FlightModel)
