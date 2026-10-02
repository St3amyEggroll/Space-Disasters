--!strict
-- CHANGED (Physics feel): tests for the speed-cue render helpers: the cloud deck (Render/Clouds) sits in its band
-- on bodies with air only and is deterministic; trees and rocks (Render/SurfaceProps) grow right up to the launch
-- site but never on its plate (pads, plots and roads all lie on it).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local Render = game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render
local Clouds = require(Render.Clouds)
local SurfaceProps = require(Render.SurfaceProps)

--============================================================================
-- Tunables
--============================================================================
local SAMPLE_CELLS = 6 -- cells per side sampled around a tile centre
local CHUNK_RANGE = 3 -- chunks per side sampled around the site
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD
local MOON = Bodies.MOON

return function(t: TestKit.Context)
	local hooks = Clouds._test
	local site = Frames.surfaceUp(0, 0)

	t.test("clouds: band scales with the atmosphere top, none without air", function()
		local top = (Bodies.get(HOMEWORLD).Atmosphere :: Bodies.Atmosphere).Top
		local low, high = hooks.band(HOMEWORLD)
		t.expectTrue(low ~= nil and high ~= nil, "Earth has a cloud deck")
		t.expectNear(low :: number, top * 1.5 / 7, 1e-6)
		t.expectNear(high :: number, top * 2.5 / 7, 1e-6)
		local moonLow = hooks.band(MOON)
		t.expectTrue(moonLow == nil, "no clouds without an atmosphere")
	end)

	t.test("clouds: clusters are deterministic, in the band and sized as tuned", function()
		local low, high = hooks.band(HOMEWORLD)
		local radius = Bodies.get(HOMEWORLD).Radius
		local info = hooks.tileInfo(HOMEWORLD, SurfaceHeight.tileOf(HOMEWORLD, site))
		local found = 0
		for ci = -SAMPLE_CELLS, SAMPLE_CELLS - 1 do
			for cj = -SAMPLE_CELLS, SAMPLE_CELLS - 1 do
				local cluster = hooks.generateCluster(HOMEWORLD, info, ci, cj)
				local again = hooks.generateCluster(HOMEWORLD, info, ci, cj)
				t.expectTrue((cluster == nil) == (again == nil), "same cell, same answer")
				if cluster == nil or again == nil then
					continue
				end
				found += 1
				t.expectEqual(cluster.id, again.id)
				t.expectEqual(#cluster.puffs, #again.puffs)
				t.expectNear(Vec3d.distance(cluster.centre, again.centre), 0, 1e-9)
				local altitude = Vec3d.length(cluster.centre) - radius
				t.expectTrue(altitude >= (low :: number) - 1e-6 and altitude <= (high :: number) + 1e-6, "in band")
				for _, puff in cluster.puffs do
					t.expectTrue(puff.size > 0 and puff.size <= hooks.CLUSTER_WIDTH_MAX, "puff size")
					t.expectTrue(
						puff.transparency >= hooks.TRANSPARENCY_MIN and puff.transparency <= hooks.TRANSPARENCY_MAX,
						"puff transparency"
					)
					t.expectTrue(Vec3d.length(puff.offset) <= hooks.CLUSTER_WIDTH_MAX, "puff near its cluster")
				end
			end
		end
		t.expectTrue(found > 0, "some cells hold clouds")
	end)

	t.test("clouds: fade out toward the draw radius", function()
		t.expectNear(hooks.fadeAt(0), 0, 1e-9)
		t.expectNear(hooks.fadeAt(hooks.DRAW_RADIUS), 1, 1e-9)
		t.expectTrue(hooks.fadeAt(hooks.DRAW_RADIUS * 0.9) > hooks.fadeAt(hooks.DRAW_RADIUS * 0.8), "monotonic")
	end)

	t.test("props: the clearing is a square just outside the site plate", function()
		local inside = SurfaceProps._test.inSiteClearing
		local half = SurfaceProps._test.SITE_CLEAR_HALF_EXTENT
		t.expectTrue(half > BaseLayout.SITE_HALF_EXTENT, "clearing covers the plate")
		t.expectTrue(half < BaseLayout.SITE_HALF_EXTENT + 60, "but only just")
		local radius = Bodies.get(HOMEWORLD).Radius
		local rot = Frames.surfaceRotation(site)
		local east, north = Vec3d.fromVector3(rot.XVector), Vec3d.fromVector3(rot.ZVector)
		local function at(e: number, n: number): Vec3d.Vec3d
			return Vec3d.add(Vec3d.scale(site, radius), Vec3d.add(Vec3d.scale(east, e), Vec3d.scale(north, n)))
		end
		local e = BaseLayout.SITE_HALF_EXTENT
		for _, p in { at(0, 0), at(e, e), at(-e, e), at(e, -e), at(-e, -e), at(0, BaseLayout.LAUNCH_AREA_Z) } do
			t.expectTrue(inside(p.x, p.y, p.z), "plate point cleared")
		end
		for _, p in { at(half + 30, 0), at(0, -(half + 30)), at(half + 30, half + 30) } do
			t.expectTrue(not inside(p.x, p.y, p.z), "outside the square")
		end
		local far = Vec3d.scale(site, -radius)
		t.expectTrue(not inside(far.x, far.y, far.z), "the far side of Earth is not cleared")
	end)

	t.test("props: grow near the site, never on its plate", function()
		local inside = SurfaceProps._test.inSiteClearing
		local info = SurfaceProps._test.tileInfo(HOMEWORLD, SurfaceHeight.tileOf(HOMEWORLD, site))
		local radius = Bodies.get(HOMEWORLD).Radius
		local sitePos = Vec3d.scale(site, radius)
		local nearest = math.huge
		for ci = -CHUNK_RANGE, CHUNK_RANGE - 1 do
			for cj = -CHUNK_RANGE, CHUNK_RANGE - 1 do
				for _, prop in SurfaceProps._test.generateChunk(HOMEWORLD, info, ci, cj) do
					local p = prop.pos
					t.expectTrue(not inside(p.x, p.y, p.z), "no prop in the clearing")
					nearest = math.min(nearest, Vec3d.distance(p, sitePos))
				end
			end
		end
		t.expectTrue(nearest < 800, `trees within 800 m of the site (nearest {nearest} m)`)
	end)
end
