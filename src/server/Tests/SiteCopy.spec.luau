--!strict
-- CHANGED (Review 3): tests for the launch-site copy rules after the review of the terrain polish: the copy is
-- never nearer than the protected depth (TerrainMath.objectScale), the base pocket draws the real base near the
-- site (TerrainMath.siteCopyScale), the near band keeps every leaf under the real plate while the camera is in that
-- zone (nearTarget with Surface's keep square and range), and the night haze (TerrainMath.daylight / hazeColour).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local Render = game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render
local TerrainMath = require(Render.TerrainMath)

--============================================================================
-- Tunables (the values Render/TerrainMesh and Render/Surface use)
--============================================================================
local NEAR_HALF = 760
local NEAR_MAX_LEAF = 400
local BAND_COUNT = 6
local PART_LIMIT = 2040
local FAR_LIMIT = 17000
local BUDGET = 0.85 * 1400 -- a phone on Automatic
local HIGH = { splitK = 1.4, mergeK = 1.4 * 1.15, maxLeaves = 320 }
local LOW = { splitK = 0.8, mergeK = 0.8 * 1.15, maxLeaves = 180 }
local SITE_KEEP_HALF = 630
local SITE_KEEP_RANGE = 600
local SITE_NEAR_HALF = 700
local SITE_PLATE_HALF = BaseLayout.SITE_HALF_EXTENT + 10
local HAZE_DAY = { 0.63, 0.73, 0.87 }
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD
local EARTH_R = Bodies.get(HOMEWORLD).Radius

return function(t: TestKit.Context)
	t.test("objectScale: in front of its ground, never nearer than the protected depth", function()
		-- the climb: ground under the site at 0.3, depthScale 0.06, 160 studs protected, site 1.2 km away
		local k = TerrainMath.objectScale(0.3, 0.06, 160, 1200)
		t.expectNear(k * 1200, 160, 1e-9)
		-- the depth scale wins when it is already farther
		t.expectNear(TerrainMath.objectScale(0.3, 0.2, 160, 1200), 0.2, 1e-12)
		-- never behind its own ground
		t.expectNear(TerrainMath.objectScale(0.3, 0.06, 520, 400), 0.3, 1e-12)
		-- a camera inside the site's reach: no division blow-up
		t.expectNear(TerrainMath.objectScale(0.5, 0.1, 160, -50), 0.5, 1e-12)
		for _, nearest in { 50, 300, 900, 3000, 12000 } do
			for _, protect in { 160, 300, 520 } do
				local s = TerrainMath.objectScale(0.25, 0.03, protect, nearest)
				t.expectTrue(s <= 0.25 + 1e-12, "at most the ground's factor")
				t.expectTrue(s * nearest >= math.min(protect, 0.25 * nearest) - 1e-9, "protected depth kept")
			end
		end
	end)

	t.test("siteCopyScale: the real base near the site in the base pocket, the copy elsewhere", function()
		-- ground under the plate at true scale: the base pocket draws nothing extra, a flight pocket a true copy
		local scale, hole = TerrainMath.siteCopyScale(1, true, true, 0.1, 520, 100)
		t.expectEqual(scale, nil)
		t.expectTrue(not hole, "no hole over true-scale ground")
		scale, hole = TerrainMath.siteCopyScale(1, false, false, 0.1, 520, 100)
		t.expectEqual(scale, 1)
		t.expectTrue(not hole, "no hole in a flight pocket")
		-- scaled ground under the plate, base pocket, near the site (a jump home): no copy, hide that ground
		scale, hole = TerrainMath.siteCopyScale(0.14, true, true, 0.14, 520, 1)
		t.expectEqual(scale, nil)
		t.expectTrue(hole, "the scaled ground under the plate is hidden")
		-- far from the site: the copy, at the protected depth
		scale, hole = TerrainMath.siteCopyScale(0.3, true, false, 0.05, 520, 2000)
		t.expectNear(scale :: number, 0.26, 1e-12)
		t.expectTrue(not hole, "no hole far away")
		-- a flight pocket near the site never hides ground (no real base there)
		scale, hole = TerrainMath.siteCopyScale(0.3, false, true, 0.05, 160, 2000)
		t.expectNear(scale :: number, 0.08, 1e-12)
		t.expectTrue(not hole, "flight pocket")
	end)

	t.test("keepNear: every leaf under the real plate is in the near band out to the near zone", function()
		local config = TerrainMath.config(HOMEWORLD) :: TerrainMath.Config
		local site = Vec3d.new(EARTH_R, 0, 0)
		local siteNear = TerrainMath.newNear(config, site, SITE_KEEP_HALF, 0)
		local axes = siteNear.axes
		local offsets = { { 0, 0 }, { 700, 0 }, { 0, -700 }, { -500, 500 }, { 700, 700 }, { 600, -300 } }
		for _, offset in offsets do
			for _, height in { 2, 200 } do
				for _, tier in { HIGH, LOW } do
					local dir =
						Vec3d.add(site, Vec3d.add(Vec3d.scale(axes.x, offset[1]), Vec3d.scale(axes.z, offset[2])))
					local d = Vec3d.normalize(dir)
					local cam = Vec3d.add(SurfaceHeight.groundPoint(HOMEWORLD, d), Vec3d.scale(d, height))
					local target, keeping =
						TerrainMath.nearTarget(config, cam, site, SITE_KEEP_HALF, NEAR_HALF, SITE_KEEP_RANGE)
					t.expectTrue(keeping, `the keep square places the near square at {offset[1]}, {offset[2]}`)
					local near = TerrainMath.newNear(config, target, NEAR_HALF, NEAR_MAX_LEAF)
					local rings: TerrainMath.RingContext =
						{ cam = cam, budget = BUDGET, farLimit = FAR_LIMIT, partLimit = PART_LIMIT, previous = nil }
					local params: TerrainMath.Params = {
						splitK = tier.splitK,
						mergeK = tier.mergeK,
						maxLeaves = tier.maxLeaves,
						bandCount = BAND_COUNT,
						horizonLead = math.max(30, 0.15 * height),
						near = near,
						rings = rings,
					}
					local selection = TerrainMath.select(config, cam, params, nil)
					local assigned = TerrainMath.assignBands(config, selection.leaves, BAND_COUNT, near, rings)
					local under = 0
					for _, leaf in selection.leaves do
						local u, v = TerrainMath.nearOffset(siteNear, Vec3d.new(leaf.cx, leaf.cy, leaf.cz))
						local half = leaf.size / 2
						if math.abs(u) - half < SITE_PLATE_HALF and math.abs(v) - half < SITE_PLATE_HALF then
							under += 1
							t.expectEqual(assigned[leaf.key], TerrainMath.NEAR_BAND)
						end
					end
					t.expectTrue(under > 0, "leaves under the plate")
					-- the camera stays well inside the near band
					local cu, cv = TerrainMath.nearOffset(near, Vec3d.scale(d, config.radius))
					t.expectTrue(math.max(math.abs(cu), math.abs(cv)) <= NEAR_HALF - 150, "camera inside")
				end
			end
		end
		-- beyond the near zone (and the keep range) the near square follows the camera again
		local far = Vec3d.new(EARTH_R + 5, 0, SITE_NEAR_HALF + 200)
		local _, keeping = TerrainMath.nearTarget(config, far, site, SITE_KEEP_HALF, NEAR_HALF, SITE_KEEP_RANGE)
		t.expectTrue(not keeping, "camera far from the site")
	end)

	t.test("haze: the day colour by day, dark at night, steps in between", function()
		t.expectEqual(TerrainMath.daylight(1), 1)
		t.expectEqual(TerrainMath.daylight(-1), 0)
		local previous = -1
		for step = -20, 20 do
			local level = TerrainMath.daylight(step / 20)
			t.expectTrue(level >= previous, "never darker as the sun rises")
			t.expectTrue(level >= 0 and level <= 1, "0..1")
			previous = level
		end
		local atmosphere = Bodies.get(HOMEWORLD).AtmosphereColor :: Color3
		local r, g, b = TerrainMath.hazeColour(HAZE_DAY, atmosphere, 1)
		t.expectNear(r, HAZE_DAY[1], 1e-12)
		t.expectNear(g, HAZE_DAY[2], 1e-12)
		t.expectNear(b, HAZE_DAY[3], 1e-12)
		local nr, ng, nb = TerrainMath.hazeColour(HAZE_DAY, atmosphere, 0)
		-- at night the haze is darker than any grass (it fades the far ground toward the night sky)
		t.expectTrue(math.max(nr, ng, nb) < 0.15, `night haze {nr} {ng} {nb}`)
		t.expectTrue(nb >= nr, "a bluish night")
		local mr = TerrainMath.hazeColour(HAZE_DAY, atmosphere, 0.5)
		t.expectTrue(mr > nr and mr < r, "twilight in between")
	end)
end
