--!strict
-- CHANGED (Phase 6): tests for Shared/Sim/PocketFrames, the reference of an astronaut's solo pocket (INERTIAL in space,
-- SURFACE_ALIGNED on the ground): propagation, attributes, mode hysteresis, rebases and SOI changes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Eva = require(ReplicatedStorage.Shared.Sim.Eva) -- CHANGED (Night review): the level-ground rule
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Kepler = require(ReplicatedStorage.Shared.Sim.Kepler)
local PocketFrames = require(ReplicatedStorage.Shared.Sim.PocketFrames)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

--============================================================================
-- Tunables
--============================================================================
local WS_TOLERANCE = 2e-3 -- studs: workspace floats near a slot origin
local SLOT = Vector3.new(4000, 8000, -4000)
--============================================================================

local function orbit(): (Vec3d.Vec3d, Vec3d.Vec3d)
	local r = Bodies.get(Bodies.HOMEWORLD).Radius + 15000
	return Vec3d.new(r * 0.6, 0, r * 0.8), Vec3d.new(-0.8 * 710, 0, 0.6 * 710)
end

-- Reads attributes back through the same getter shape the game uses (folder:GetAttribute).
local function getter(attributes: { [string]: any }): (string) -> unknown
	return function(name: string): unknown
		return attributes[name]
	end
end

return function(t: TestKit.Context)
	t.test("INERTIAL: the reference falls along its own orbit", function()
		local pos, vel = orbit()
		local ref = PocketFrames.solo("INERTIAL", Bodies.HOMEWORLD, pos, vel, 1000)
		local p0 = PocketFrames.referenceAt(ref, 1000)
		t.expectNear(Vec3d.distance(p0, pos), 0, 1e-9, "at the epoch: the astronaut")
		local p, v = PocketFrames.referenceAt(ref, 1300)
		local kp, kv = Kepler.propagate(Bodies.get(Bodies.HOMEWORLD).Mu, pos, vel, 300)
		t.expectNear(Vec3d.distance(p, kp), 0, 1e-6, "Kepler position")
		t.expectNear(Vec3d.distance(v, kv), 0, 1e-9, "Kepler velocity")
		-- axes: the flight pockets' horizon / sun axes (D31)
		local rot = PocketFrames.rotationAt(ref, p, 1300)
		local expected = Universe.pocketRotation(Bodies.HOMEWORLD, p, 1300)
		t.expectNear((rot.UpVector - expected.UpVector).Magnitude, 0, 1e-6)
	end)

	-- CHANGED (Night review): up is the radial up at the ground point (was the terrain triangle's normal)
	t.test("SURFACE_ALIGNED: the reference is the ground under the astronaut, up = the radial up", function()
		local body = Bodies.get(Bodies.MOON)
		local dir = Vec3d.normalize(Vec3d.new(0.2, 0.5, -0.7))
		local feet = Vec3d.scale(dir, body.Radius + 40)
		local ref = PocketFrames.solo("SURFACE_ALIGNED", Bodies.MOON, feet, Vec3d.new(5, 5, 5), 50)
		local h = SurfaceHeight.height(Bodies.MOON, ref.pos)
		t.expectNear(h, 0, 1e-6, "on the ground")
		local radial = Vec3d.normalize(ref.pos)
		t.expectNear((ref.rot.UpVector - Vec3d.toVector3(radial)).Magnitude, 0, 1e-5, "pocket up = radial up")
		local pos, vel = PocketFrames.referenceAt(ref, 5000)
		t.expectNear(Vec3d.distance(pos, ref.pos), 0, 1e-12, "fixed on the ground")
		t.expectEqual(Vec3d.length(vel), 0)
		-- the ground point is pocket y = 0, like the base pocket
		local frame = Frames.new(ref.bodyId, pos, ref.rot, SLOT)
		local ws = Frames.pointToWorkspace(frame, feet)
		t.expectNear(ws.Y - SLOT.Y, Vec3d.dot(Vec3d.sub(feet, ref.pos), radial), WS_TOLERANCE, "height is pocket Y")
	end)

	-- CHANGED (Night review): a solo pocket made on a steep slope is level (walking gravity straight down) and the
	-- slope around it still counts as standing ground for walking
	t.test("SURFACE_ALIGNED on a steep slope: the pocket stays level", function()
		local body = Bodies.get(Bodies.MOON)
		local found: Vec3d.Vec3d? = nil
		for i = 1, 4000 do
			local a, b = i * 0.6180339887 * 2 * math.pi, math.acos(1 - 2 * ((i - 0.5) / 4000))
			local dir = Vec3d.new(math.sin(b) * math.cos(a), math.cos(b), math.sin(b) * math.sin(a))
			local _, normal = SurfaceHeight.height(Bodies.MOON, Vec3d.scale(dir, body.Radius))
			if Vec3d.dot(normal, dir) < 0.9 then
				found = dir
				break
			end
		end
		t.expectTrue(found ~= nil, "the Mun has slopes steeper than 25 degrees")
		local dir = found :: Vec3d.Vec3d
		local feet = Vec3d.scale(dir, body.Radius + 1)
		local ref = PocketFrames.solo("SURFACE_ALIGNED", Bodies.MOON, feet, Vec3d.zero(), 0)
		local _, normal = SurfaceHeight.height(Bodies.MOON, ref.pos)
		local up = ref.rot.UpVector
		local radial = Eva.radialUp(ref.pos)
		local alignment = up.X * radial.x + up.Y * radial.y + up.Z * radial.z
		t.expectNear(alignment, 1, 1e-6, "pocket up is radial")
		t.expectTrue(up.X * normal.x + up.Y * normal.y + up.Z * normal.z < 0.9, "not the slope's normal")
		-- 100 m away along the slope it is still level ground for the walk / float rules
		local side = Vec3d.normalize(Vec3d.cross(radial, Vec3d.new(0, 1, 0)))
		local away = Eva.radialUp(Vec3d.addScaled(ref.pos, side, 100))
		local there = up.X * away.x + up.Y * away.y + up.Z * away.z
		t.expectTrue(Eva.stationaryPocket(0, there), "stationary 100 m away")
	end)

	t.test("attributes round trip and reject garbage", function()
		local pos, vel = orbit()
		local function roundTrip(mode: PocketFrames.Mode)
			local ref = PocketFrames.solo(mode, Bodies.HOMEWORLD, pos, vel, 77.5)
			local back = PocketFrames.fromAttributes(getter(PocketFrames.toAttributes(ref)))
			t.expectTrue(back ~= nil, mode .. " reads back")
			local r = back :: PocketFrames.Reference
			t.expectEqual(r.mode, mode)
			t.expectEqual(r.bodyId, Bodies.HOMEWORLD)
			t.expectNear(Vec3d.distance(r.pos, ref.pos), 0, 1e-9)
			t.expectNear(Vec3d.distance(r.vel, ref.vel), 0, 1e-9)
			t.expectNear(r.ut, 77.5, 1e-12)
		end
		roundTrip("INERTIAL")
		roundTrip("SURFACE_ALIGNED")
		local good = PocketFrames.toAttributes(PocketFrames.solo("INERTIAL", Bodies.HOMEWORLD, pos, vel, 1))
		local function without(name: string, value: any): { [string]: any }
			local copy = table.clone(good)
			copy[name] = value
			return copy
		end
		t.expectTrue(PocketFrames.fromAttributes(getter(without("FrameMode", "HORIZON_ALIGNED"))) == nil, "mode")
		t.expectTrue(PocketFrames.fromAttributes(getter(without("RefBodyId", 99))) == nil, "unknown body")
		t.expectTrue(PocketFrames.fromAttributes(getter(without("RefX", 0 / 0))) == nil, "NaN")
		t.expectTrue(PocketFrames.fromAttributes(getter(without("RefY", math.huge))) == nil, "infinity")
		t.expectTrue(PocketFrames.fromAttributes(getter(without("RefVZ", nil))) == nil, "missing velocity")
		t.expectTrue(PocketFrames.fromAttributes(getter(without("RefUT", "soon"))) == nil, "bad epoch")
		t.expectTrue(PocketFrames.fromAttributes(getter(without("RefRot", 3))) == nil, "bad rotation")
		t.expectTrue(PocketFrames.fromAttributes(getter({})) == nil, "nothing at all")
	end)

	t.test("mode hysteresis: surface when low and slow, inertial when high or fast", function()
		local enter = GameConfig.EVA_SURFACE_ENTER_HEIGHT
		local exit = GameConfig.EVA_SURFACE_EXIT_HEIGHT
		t.expectEqual(PocketFrames.desiredMode("INERTIAL", enter - 1, 2), "SURFACE_ALIGNED")
		t.expectEqual(PocketFrames.desiredMode("INERTIAL", enter + 1, 2), "INERTIAL", "a bit higher: stays")
		t.expectEqual(PocketFrames.desiredMode("INERTIAL", 1, 500), "INERTIAL", "skimming fast: stays")
		t.expectEqual(PocketFrames.desiredMode("SURFACE_ALIGNED", (enter + exit) / 2, 2), "SURFACE_ALIGNED", "band")
		t.expectEqual(PocketFrames.desiredMode("SURFACE_ALIGNED", exit + 1, 2), "INERTIAL", "climbed out")
		t.expectEqual(PocketFrames.desiredMode("SURFACE_ALIGNED", 1, 100), "INERTIAL", "too fast")
		t.expectEqual(PocketFrames.desiredMode("SURFACE_ALIGNED", 0 / 0, 1), "SURFACE_ALIGNED", "NaN keeps it")
	end)

	t.test("rebase after EVA_REBASE_DIST of drift, and the transfer keeps the astronaut in place", function()
		local pos, vel = orbit()
		local ref = PocketFrames.solo("INERTIAL", Bodies.HOMEWORLD, pos, vel, 0)
		local refAt = PocketFrames.referenceAt(ref, 60)
		local near = Vec3d.add(refAt, Vec3d.new(0, GameConfig.EVA_REBASE_DIST - 1, 0))
		local far = Vec3d.add(refAt, Vec3d.new(0, GameConfig.EVA_REBASE_DIST + 1, 0))
		t.expectTrue(not PocketFrames.needsRebase(ref, 60, near), "within the limit")
		t.expectTrue(PocketFrames.needsRebase(ref, 60, far), "beyond it")
		-- old frame -> new frame (reference = the astronaut): the rigid transform maps his old workspace point onto
		-- the new slot origin
		local _, refVel = PocketFrames.referenceAt(ref, 60)
		local oldFrame = Frames.new(ref.bodyId, refAt, PocketFrames.rotationAt(ref, refAt, 60), SLOT)
		local newRef = PocketFrames.solo("INERTIAL", Bodies.HOMEWORLD, far, refVel, 60)
		local newFrame = Frames.new(newRef.bodyId, newRef.pos, PocketFrames.rotationAt(newRef, newRef.pos, 60), SLOT)
		local m = Frames.relativeTransform(oldFrame, newFrame)
		local before = Frames.pointToWorkspace(oldFrame, far)
		t.expectNear((m:PointToWorldSpace(before) - SLOT).Magnitude, 0, WS_TOLERANCE)
	end)

	t.test("transfers between a craft's horizon frame and solo frames keep the true position", function()
		local pos, vel = orbit()
		local ut = 321
		-- a craft pocket (HORIZON_ALIGNED on the craft, D31) and an astronaut 380 m from the craft
		local craftFrame = Frames.new(
			Bodies.HOMEWORLD,
			pos,
			Universe.pocketRotation(Bodies.HOMEWORLD, pos, ut),
			Vector3.new(4000, 4000, 0)
		)
		local astronaut = Vec3d.add(pos, Vec3d.new(120, -300, 200))
		local before = Frames.pointToWorkspace(craftFrame, astronaut)
		-- he splits off into a solo pocket in another slot
		local ref = PocketFrames.solo("INERTIAL", Bodies.HOMEWORLD, astronaut, vel, ut)
		local refPos = PocketFrames.referenceAt(ref, ut)
		local solo = Frames.new(ref.bodyId, refPos, PocketFrames.rotationAt(ref, refPos, ut), SLOT)
		local m = Frames.relativeTransform(craftFrame, solo)
		local after = m:PointToWorldSpace(before)
		t.expectNear((after - Frames.pointToWorkspace(solo, astronaut)).Magnitude, 0, WS_TOLERANCE, "same point")
		t.expectNear((after - SLOT).Magnitude, 0, WS_TOLERANCE, "at his new pocket's origin")
		-- the same astronaut seen from a SURFACE_ALIGNED pocket on the Mun (body offset in doubles)
		local munCentre = Universe.bodyPosition(Bodies.MOON, ut)
		local onMun = Vec3d.new(15000, 30, 40)
		local surface = PocketFrames.solo("SURFACE_ALIGNED", Bodies.MOON, onMun, Vec3d.zero(), ut)
		local surfaceFrame = Frames.new(surface.bodyId, surface.pos, surface.rot, SLOT)
		local munAstronaut = Vec3d.sub(Vec3d.add(onMun, munCentre), Universe.bodyPosition(Bodies.HOMEWORLD, ut))
		local wsEarth = Frames.pointToWorkspace(craftFrame, munAstronaut)
		local cross =
			Frames.relativeTransform(craftFrame, surfaceFrame, Universe.bodyOffset(Bodies.HOMEWORLD, Bodies.MOON, ut))
		local wsMun = Frames.pointToWorkspace(surfaceFrame, onMun)
		-- far from the slot the float workspace is coarse; compare in doubles-derived metres with a looser bound
		t.expectNear((cross:PointToWorldSpace(wsEarth) - wsMun).Magnitude, 0, 0.5, "across bodies")
	end)

	t.test("the reference's SOI: Earth orbit stays, near the Mun it is the Mun", function()
		local pos, vel = orbit()
		local ref = PocketFrames.solo("INERTIAL", Bodies.HOMEWORLD, pos, vel, 0)
		t.expectEqual(PocketFrames.soiAt(ref, 10), Bodies.HOMEWORLD)
		local moonPos = Universe.bodyPosition(Bodies.MOON, 500)
		local nearMun = Vec3d.add(moonPos, Vec3d.new(20000, 0, 0))
		local moonVel = Universe.bodyVelocity(Bodies.MOON, 500)
		local munRef = PocketFrames.solo("INERTIAL", Bodies.HOMEWORLD, nearMun, moonVel, 500)
		t.expectEqual(PocketFrames.soiAt(munRef, 500), Bodies.MOON)
	end)
end
