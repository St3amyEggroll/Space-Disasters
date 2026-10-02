--!strict
-- CHANGED (Physics feel): tests for the speed-cue render helpers: trees and rocks (Render/SurfaceProps) grow right
-- up to the launch site but never on its plate (pads, plots and roads all lie on it). (The cloud deck was removed.)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local Render = game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render
local SurfaceProps = require(Render.SurfaceProps)

--============================================================================
-- Tunables
--============================================================================
local CHUNK_RANGE = 3 -- chunks per side sampled around the site
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD

return function(t: TestKit.Context)
	local site = Frames.surfaceUp(0, 0)

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
