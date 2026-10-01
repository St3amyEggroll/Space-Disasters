--!strict
-- Tests for Render/MenuSceneMath (Phase 11): the main menu camera solve puts the sun exactly at its screen target and
-- Earth's limb at its screen height for any sun direction and cone angle, the camera axes are orthonormal and
-- right-handed like Roblox's, the Mun search improves its placement, and the screen helpers behave.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local MenuSceneMath = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render.MenuSceneMath)

--============================================================================
-- Tunables
--============================================================================
local EPSILON = 1e-9
local ANGLE_EPSILON = 1e-7 -- rad
local EARTH_RADIUS = 30000
local DISTANCE = 44000
local MUN_RADIUS = 7500
local MUN_ORBIT = 220000
local TAN_HALF_Y = math.tan(math.rad(35))
local TAN_HALF_X = TAN_HALF_Y * 16 / 9
local LIMB_NY = -0.3
local SUN_NX, SUN_NY = 0.72, 0.5
local MUN_NX, MUN_NY = -0.1, 0.45
local ALPHAS = { 0, 0.7, 1.9, 3.1, 4.4, 5.8 }
--============================================================================

type Vec3d = Vec3d.Vec3d

local function sunDirection(angle: number, elevation: number): Vec3d
	local c = math.cos(elevation)
	return Vec3d.new(c * math.cos(angle), math.sin(elevation), c * math.sin(angle))
end

local function params(sun: Vec3d, munAngle: number): MenuSceneMath.ViewParams
	local limbAngle = select(2, MenuSceneMath.screenAngles(0, LIMB_NY, TAN_HALF_X, TAN_HALF_Y))
	local sunAz, sunEl = MenuSceneMath.screenAngles(SUN_NX, SUN_NY, TAN_HALF_X, TAN_HALF_Y)
	local munAz, munEl = MenuSceneMath.screenAngles(MUN_NX, MUN_NY, TAN_HALF_X, TAN_HALF_Y)
	return {
		earthRadius = EARTH_RADIUS,
		distance = DISTANCE,
		sunDir = sun,
		munPos = Vec3d.new(MUN_ORBIT * math.cos(munAngle), 0, MUN_ORBIT * math.sin(munAngle)),
		munRadius = MUN_RADIUS,
		pitch = MenuSceneMath.pitchFor(EARTH_RADIUS, DISTANCE, limbAngle),
		sunAzimuth = sunAz,
		sunElevation = sunEl,
		munAzimuth = munAz,
		munElevation = munEl,
	}
end

return function(t: TestKit.Context)
	t.test("screenAngles: centre, edges and the vertical angle off-centre", function()
		local az, el = MenuSceneMath.screenAngles(0, 0, TAN_HALF_X, TAN_HALF_Y)
		t.expectNear(az, 0, EPSILON)
		t.expectNear(el, 0, EPSILON)
		az, el = MenuSceneMath.screenAngles(1, 0, TAN_HALF_X, TAN_HALF_Y)
		t.expectNear(az, math.atan(TAN_HALF_X), EPSILON)
		t.expectNear(el, 0, EPSILON)
		az, el = MenuSceneMath.screenAngles(0, -1, TAN_HALF_X, TAN_HALF_Y)
		t.expectNear(az, 0, EPSILON)
		t.expectNear(el, -math.rad(35), EPSILON)
		local _, cornerEl = MenuSceneMath.screenAngles(1, 1, TAN_HALF_X, TAN_HALF_Y)
		t.expectTrue(cornerEl < math.rad(35), "off-centre points are lower than the edge-centre angle")
	end)

	t.test("horizonDip and pitchFor", function()
		t.expectNear(MenuSceneMath.horizonDip(1, 2), math.rad(60), EPSILON)
		t.expectNear(MenuSceneMath.horizonDip(1, 0.5), 0, EPSILON, "inside the body clamps to the surface")
		t.expectNear(MenuSceneMath.pitchFor(1, 2, -math.rad(10)), math.rad(50), EPSILON)
	end)

	t.test("solveView: the sun lands exactly on its screen target", function()
		for _, sunAngle in { 0, 1.1, 2.5, 4, 5.5 } do
			local p = params(sunDirection(sunAngle, math.rad(15)), 0.3)
			for _, alpha in ALPHAS do
				local view = MenuSceneMath.solveView(p, alpha)
				t.expectTrue(view ~= nil, "view exists")
				assert(view)
				local az, el = MenuSceneMath.cameraAngles(view, p.sunDir)
				t.expectNear(az, p.sunAzimuth, ANGLE_EPSILON, `sun azimuth (sun {sunAngle}, alpha {alpha})`)
				t.expectNear(el, p.sunElevation, ANGLE_EPSILON, `sun elevation (sun {sunAngle}, alpha {alpha})`)
			end
		end
	end)

	t.test("solveView: Earth's limb sits at its screen height in the centre column", function()
		local p = params(sunDirection(0.8, math.rad(15)), 1)
		local limbAngle = select(2, MenuSceneMath.screenAngles(0, LIMB_NY, TAN_HALF_X, TAN_HALF_Y))
		local dip = MenuSceneMath.horizonDip(EARTH_RADIUS, DISTANCE)
		for _, alpha in ALPHAS do
			local view = MenuSceneMath.solveView(p, alpha)
			assert(view)
			-- the heading h = cos(pitch) forward + sin(pitch) cameraUp; the horizon is dip below it
			local h =
				Vec3d.add(Vec3d.scale(view.forward, math.cos(p.pitch)), Vec3d.scale(view.cameraUp, math.sin(p.pitch)))
			local horizon = Vec3d.add(Vec3d.scale(h, math.cos(dip)), Vec3d.scale(view.up, -math.sin(dip)))
			local az, el = MenuSceneMath.cameraAngles(view, horizon)
			t.expectNear(az, 0, ANGLE_EPSILON, "limb in the centre column")
			t.expectNear(el, limbAngle, ANGLE_EPSILON, "limb height")
			-- that horizon ray just grazes Earth
			local closest = Vec3d.length(Vec3d.addScaled(view.pos, horizon, -Vec3d.dot(view.pos, horizon)))
			t.expectRelNear(closest, EARTH_RADIUS, 1e-9, "the limb ray is tangent to Earth")
		end
	end)

	t.test("solveView: orthonormal, right-handed like Roblox (right = forward x up)", function()
		local p = params(sunDirection(3.3, math.rad(15)), 2)
		for _, alpha in ALPHAS do
			local view = MenuSceneMath.solveView(p, alpha)
			assert(view)
			t.expectNear(Vec3d.length(view.right), 1, EPSILON)
			t.expectNear(Vec3d.length(view.cameraUp), 1, EPSILON)
			t.expectNear(Vec3d.length(view.forward), 1, EPSILON)
			t.expectNear(Vec3d.dot(view.right, view.cameraUp), 0, EPSILON)
			t.expectNear(Vec3d.dot(view.right, view.forward), 0, EPSILON)
			t.expectNear(Vec3d.dot(view.cameraUp, view.forward), 0, EPSILON)
			t.expectTrue(
				Vec3d.equalsApprox(view.right, Vec3d.cross(view.forward, view.cameraUp), EPSILON),
				"right = forward x up"
			)
			t.expectRelNear(Vec3d.length(view.pos), DISTANCE, EPSILON, "viewpoint distance")
			t.expectNear(Vec3d.dot(view.right, view.up), 0, EPSILON, "no roll: right stays horizontal")
		end
	end)

	t.test("cameraDirection inverts cameraAngles", function()
		local p = params(sunDirection(2, math.rad(15)), 0)
		local view = MenuSceneMath.solveView(p, 1.2)
		assert(view)
		local dir = MenuSceneMath.cameraDirection(view, 0.4, -0.2)
		local az, el = MenuSceneMath.cameraAngles(view, dir)
		t.expectNear(az, 0.4, ANGLE_EPSILON)
		t.expectNear(el, -0.2, ANGLE_EPSILON)
	end)

	t.test("bestAlpha beats the other samples; refineAlpha never makes it worse", function()
		for _, munAngle in { 0, 1.5, 3, 4.5 } do
			local p = params(sunDirection(1.3, math.rad(15)), munAngle)
			local best = MenuSceneMath.bestAlpha(p, 90)
			local bestView = MenuSceneMath.solveView(p, best)
			assert(bestView)
			local bestScore = MenuSceneMath.munScore(p, bestView)
			for _, alpha in ALPHAS do
				local view = MenuSceneMath.solveView(p, alpha)
				assert(view)
				t.expectTrue(MenuSceneMath.munScore(p, view) >= bestScore - 0.08, `alpha {alpha} vs best`)
			end
			local alpha = best + 0.4
			for _ = 1, 50 do
				local view = MenuSceneMath.solveView(p, alpha)
				assert(view)
				local before = MenuSceneMath.munScore(p, view)
				alpha = MenuSceneMath.refineAlpha(p, alpha, math.rad(1))
				local nextView = MenuSceneMath.solveView(p, alpha)
				assert(nextView)
				t.expectTrue(MenuSceneMath.munScore(p, nextView) <= before + 0.02, "refine does not climb")
			end
		end
	end)

	t.test("discOcclusion: inside, outside and the soft edge", function()
		local centre = Vec3d.new(0, 0, 1)
		local radius = math.rad(10)
		local soft = math.rad(1)
		t.expectNear(MenuSceneMath.discOcclusion(centre, centre, radius, soft), 1, EPSILON)
		local far = Vec3d.new(math.sin(math.rad(30)), 0, math.cos(math.rad(30)))
		t.expectNear(MenuSceneMath.discOcclusion(far, centre, radius, soft), 0, EPSILON)
		local edge = Vec3d.new(math.sin(radius), 0, math.cos(radius))
		t.expectNear(MenuSceneMath.discOcclusion(edge, centre, radius, soft), 0.5, 1e-6)
	end)

	t.test("halfExtents, edgeFade, flarePoint and smoothstep", function()
		local w, h = MenuSceneMath.halfExtents(10, 2, 0.5)
		t.expectNear(w, 20, EPSILON)
		t.expectNear(h, 5, EPSILON)
		t.expectNear(MenuSceneMath.edgeFade(50, 50, 100, 100, 10), 1, EPSILON)
		t.expectNear(MenuSceneMath.edgeFade(5, 50, 100, 100, 10), 0.5, EPSILON)
		t.expectNear(MenuSceneMath.edgeFade(-5, 50, 100, 100, 10), 0, EPSILON)
		t.expectNear(MenuSceneMath.edgeFade(50, 50, 0, 100, 10), 0, EPSILON)
		local x, y = MenuSceneMath.flarePoint(100, 20, 50, 50, 2)
		t.expectNear(x, 0, EPSILON)
		t.expectNear(y, 80, EPSILON)
		t.expectNear(MenuSceneMath.smoothstep(0, 1, 0.5), 0.5, EPSILON)
		t.expectNear(MenuSceneMath.smoothstep(0, 1, -1), 0, EPSILON)
		t.expectNear(MenuSceneMath.smoothstep(1, 1, 2), 1, EPSILON)
	end)
end
