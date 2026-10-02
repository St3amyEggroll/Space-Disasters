--!strict
-- CHANGED (Terrain polish): tests for the terrain polish: the ring bands around the near square (TerrainMath
-- planRings / assignBands), the shared band factor with a protected depth (bandScales), the band seams (stitchCode /
-- stitchChunk), the ground sunk under the base's plate, the richer vertex colours, and the launch site's
-- mountain-free plain with gentler mountains (Biome / Relief).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Relief = require(ReplicatedStorage.Shared.Sim.Relief)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local Render = game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render
local TerrainMath = require(Render.TerrainMath)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables (the values Render/TerrainMesh uses)
--============================================================================
local NEAR_HALF = 760
local NEAR_MAX_LEAF = 400
local BAND_COUNT = 6
local PART_LIMIT = 2040
local FAR_LIMIT = 17000
local BUDGET = 0.85 * 3000 -- Automatic on a PC
local HIGH = { splitK = 1.4, mergeK = 1.4 * 1.15, maxLeaves = 320 }
local LOW = { splitK = 0.8, mergeK = 0.8 * 1.15, maxLeaves = 180 }
local SITE_GROUND_DEPTH = 300 -- studs: ring bands seen from the pads are drawn at least this far
local CALM_RADIUS = 10000 -- m: no mountains this near the site
local CALM_MAX_HEIGHT = 200 -- m: highest ground there
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD
local MOON = Bodies.MOON
local EARTH_R = Bodies.get(HOMEWORLD).Radius

local function cameraAt(bodyId: number, dir: Vec3d, height: number): Vec3d
	local d = Vec3d.normalize(dir)
	return Vec3d.add(SurfaceHeight.groundPoint(bodyId, d), Vec3d.scale(d, height))
end

local function ringContext(cam: Vec3d, previous: { number }?): TerrainMath.RingContext
	return { cam = cam, budget = BUDGET, farLimit = FAR_LIMIT, partLimit = PART_LIMIT, previous = previous }
end

local function selectRings(
	config: TerrainMath.Config,
	cam: Vec3d,
	tier: any
): (TerrainMath.Selection, TerrainMath.Near, TerrainMath.RingContext)
	local near = TerrainMath.newNear(config, cam, NEAR_HALF, NEAR_MAX_LEAF)
	local rings = ringContext(cam)
	local height = Vec3d.length(cam) - config.radius
	local params: TerrainMath.Params = {
		splitK = tier.splitK,
		mergeK = tier.mergeK,
		maxLeaves = tier.maxLeaves,
		bandCount = BAND_COUNT,
		horizonLead = math.max(30, 0.15 * height),
		near = near,
		rings = rings,
	}
	return TerrainMath.select(config, cam, params, nil), near, rings
end

return function(t: TestKit.Context)
	t.test("ring bands: rings by distance from the near square, within the band count and the mesh size", function()
		local places: { { bodyId: number, dir: Vec3d } } = {
			{ bodyId = HOMEWORLD, dir = Vec3d.new(1, 0, 0.004) }, -- the launch site
			{ bodyId = HOMEWORLD, dir = Vec3d.new(0.7, 0.5, 0.5) }, -- near a cube-face corner
			{ bodyId = MOON, dir = Vec3d.new(0.6, -0.5, 0.6) },
		}
		for _, place in places do
			local config = TerrainMath.config(place.bodyId) :: TerrainMath.Config
			for _, height in { 2, 600, 3000 } do
				for _, tier in { HIGH, LOW } do
					local cam = cameraAt(place.bodyId, place.dir, height)
					local selection, near, rings = selectRings(config, cam, tier)
					local assigned, bounds, fits =
						TerrainMath.assignBands(config, selection.leaves, BAND_COUNT, near, rings)
					t.expectTrue(fits, "a ring layout fits")
					t.expectTrue(bounds ~= nil, "ring bounds")
					local perBand: { [number]: number } = {}
					local ringOf: { { c: number, band: number } } = {}
					for _, leaf in selection.leaves do
						local band = assigned[leaf.key]
						perBand[band] = (perBand[band] or 0) + 1
						t.expectTrue(band >= 0 and band < BAND_COUNT, `band {band}`)
						if band ~= TerrainMath.NEAR_BAND then
							local u, v = TerrainMath.nearOffset(near, Vec3d.new(leaf.cx, leaf.cy, leaf.cz))
							table.insert(ringOf, { c = math.max(math.abs(u), math.abs(v)), band = band })
						end
					end
					for band, count in perBand do
						t.expectTrue(count <= TerrainMath.MAX_BAND_LEAVES, `band {band}: {count} leaves`)
					end
					-- rings are ordered by distance from the near square's centre
					table.sort(ringOf, function(a, b)
						return a.c < b.c
					end)
					for index = 2, #ringOf do
						t.expectTrue(ringOf[index].band >= ringOf[index - 1].band, "ring ids grow outward")
					end
					-- the previous bounds are kept when they are still as good
					local outside: { TerrainMath.Node } = {}
					for _, leaf in selection.leaves do
						if assigned[leaf.key] ~= TerrainMath.NEAR_BAND then
							table.insert(outside, leaf)
						end
					end
					local kept = TerrainMath.planRings(config, outside, BAND_COUNT - 1, near, ringContext(cam, bounds))
					t.expectTrue(kept == bounds, "the same bounds are kept")
				end
			end
		end
	end)

	t.test("ring bands seen from the pads are drawn behind the launch site", function()
		local config = TerrainMath.config(HOMEWORLD) :: TerrainMath.Config
		-- on the pads (280 m north of the site centre), 25 m up
		local cam = Vec3d.new(EARTH_R + 25, 280, 0)
		local near = TerrainMath.newNear(config, Vec3d.new(EARTH_R, 0, 0), NEAR_HALF, NEAR_MAX_LEAF)
		local params: TerrainMath.Params = {
			splitK = HIGH.splitK,
			mergeK = HIGH.mergeK,
			maxLeaves = HIGH.maxLeaves,
			bandCount = BAND_COUNT,
			horizonLead = 30,
			near = near,
			rings = ringContext(cam),
		}
		local selection = TerrainMath.select(config, cam, params, nil)
		local assigned = TerrainMath.assignBands(config, selection.leaves, BAND_COUNT, near, params.rings)
		local outside: { TerrainMath.Node } = {}
		for _, leaf in selection.leaves do
			if assigned[leaf.key] ~= TerrainMath.NEAR_BAND then
				table.insert(outside, leaf)
			end
		end
		local _, depth = TerrainMath.planRings(config, outside, BAND_COUNT - 1, near, ringContext(cam))
		t.expectTrue(depth >= SITE_GROUND_DEPTH, `nearest drawn ring ground {depth} studs`)
	end)

	t.test("bandScales: true scale stays, the rest share one factor beyond the protected depth", function()
		local maxScales = { 1, 0.7, 0.4, 0.2, 0.08, 0.03 }
		local nearest = { 20, 800, 1500, 3000, 20000, 30000 }
		local scales = TerrainMath.bandScales(maxScales, nearest, 500)
		t.expectEqual(scales[1], 1)
		for index = 2, #scales do
			t.expectTrue(scales[index] <= maxScales[index] + 1e-12, "never above a band's largest factor")
			t.expectTrue(scales[index] >= 0.03 - 1e-12, "never below the shared factor")
			-- the protected depth where the band's largest factor allows it
			t.expectTrue(
				scales[index] * nearest[index] >= math.min(500, maxScales[index] * nearest[index]) - 1e-9,
				`band {index} drawn from {scales[index] * nearest[index]} studs`
			)
			t.expectTrue(scales[index] <= scales[index - 1] + 1e-12, "factors never grow outward")
		end
		-- far bands share the smallest factor (their true order is kept)
		t.expectNear(scales[6], 0.03, 1e-12)
		t.expectNear(scales[5], 0.03, 1e-12)
		-- with no protection every scaled band takes the shared factor
		for index, k in TerrainMath.bandScales(maxScales, nearest, 0) do
			t.expectNear(k, if index == 1 then 1 else 0.03, 1e-12)
		end
	end)

	t.test("seams: a stitched edge lies on the coarser neighbour's edge; inner skirts are short", function()
		local function drawn(bodyId: number, face: number, i: number, j: number): Vec3d
			local x, y, z = SurfaceHeight.nodeDirection(bodyId, face, i, j)
			local r = Bodies.get(bodyId).Radius + SurfaceHeight.nodeHeight(bodyId, face, i, j) - TerrainMath.RENDER_DROP
			return Vec3d.new(x * r, y * r, z * r)
		end
		for _, bodyId in { HOMEWORLD, MOON } do
			local config = TerrainMath.config(bodyId) :: TerrainMath.Config
			for _, levels in { 1, 2, 4 } do
				local depth = config.maxDepth - 1
				local scale = 2 ^ levels
				local x, y = 9, 6
				-- the fine node's +i edge (edge 2) is the coarse node's -i edge
				local fine = TerrainMath.node(config, 5, depth, scale * x + scale - 1, scale * y)
				local coarse = TerrainMath.node(config, 5, depth - levels, x + 1, y)
				local chunk = TerrainMath.buildChunk(config, fine)
				t.expectTrue(TerrainMath.stitchChunk(config, fine, chunk, 0) == chunk, "code 0: the chunk itself")
				local code = TerrainMath.stitchCode({ 0, levels, 0, 0 }, { true, false, false, false })
				local stitched = TerrainMath.stitchChunk(config, fine, chunk, code)
				local edgeI = fine.i0 + TerrainMath.CHUNK * fine.stride
				t.expectEqual(edgeI, coarse.i0)
				for k = 0, TerrainMath.CHUNK do
					local j = fine.j0 + k * fine.stride
					local v = TerrainMath.CHUNK * (TerrainMath.CHUNK + 1) + k + 1
					local px, py, pz = TerrainMath.chunkVertex(stitched, v)
					local p = Vec3d.new(stitched.ox + px, stitched.oy + py, stitched.oz + pz)
					local span = coarse.stride
					local t0 = coarse.j0 + math.floor((j - coarse.j0) / span) * span
					local a, b = drawn(bodyId, 5, edgeI, t0), drawn(bodyId, 5, edgeI, t0 + span)
					local q = Vec3d.add(a, Vec3d.scale(Vec3d.sub(b, a), (j - t0) / span))
					t.expectTrue(Vec3d.distance(p, q) < 0.02, `on the coarse edge: {Vec3d.distance(p, q)} m off`)
				end
				-- edge 1 (inner): its skirt hangs only a little below the edge
				local surface = (TerrainMath.CHUNK + 1) * (TerrainMath.CHUNK + 1)
				for k = 0, TerrainMath.CHUNK do
					local ex, ey, ez = TerrainMath.chunkVertex(stitched, k + 1)
					local sx, sy, sz = TerrainMath.chunkVertex(stitched, surface + k + 1)
					local drop = math.sqrt((ex - sx) ^ 2 + (ey - sy) ^ 2 + (ez - sz) ^ 2)
					t.expectTrue(drop < 0.5, `short inner skirt {drop} m`)
				end
				-- its box is the stitched vertices' box
				t.expectTrue(stitched.minY <= stitched.maxY and stitched.vertexCount == chunk.vertexCount, "box")
			end
		end
	end)

	t.test("vertex colours: varied land, plate grey on the site, all within 0..1", function()
		local config = TerrainMath.config(HOMEWORLD) :: TerrainMath.Config
		local brightness: { number } = {}
		for _, dir in { Vec3d.new(1, -0.2, 0.3), Vec3d.new(0.8, 0.1, -0.5), Vec3d.new(1, 0.25, -0.1) } do
			local _, fi, fj = SurfaceHeight.latticeCoords(HOMEWORLD, Vec3d.normalize(dir))
			local span = TerrainMath.CHUNK
			local node = TerrainMath.node(config, 1, config.maxDepth, math.floor(fi / span), math.floor(fj / span))
			local chunk = TerrainMath.buildChunk(config, node)
			for v = 1, (span + 1) * (span + 1) do
				local _, _, _, _, _, _, r, g, b = TerrainMath.chunkVertex(chunk, v)
				t.expectTrue(r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1, "colour range")
				table.insert(brightness, r + g + b)
			end
		end
		local lo, hi = math.huge, -math.huge
		for _, value in brightness do
			lo, hi = math.min(lo, value), math.max(hi, value)
		end
		t.expectTrue(hi - lo > 0.06, `brightness varies: {lo} .. {hi}`)
	end)

	t.test("the launch site sits in a mountain-free plain; mountains stay smooth and bounded", function()
		local _, earthMax = Relief.bounds(HOMEWORLD)
		local highest = 0
		for _, metres in { 2000, 4000, 6000, 8000, CALM_RADIUS } do
			local a = metres / EARTH_R
			for k = 0, 23 do
				local phi = k * math.pi / 12
				local x, y, z = math.cos(a), math.sin(a) * math.cos(phi), math.sin(a) * math.sin(phi)
				local h = Relief.height(HOMEWORLD, x, y, z)
				highest = math.max(highest, h)
				local _, _, _, kind = Biome.sample(HOMEWORLD, x, y, z)
				t.expectTrue(kind ~= "Rock" and kind ~= "Snow", `{kind} {metres} m from the pad`)
			end
		end
		t.expectTrue(highest < CALM_MAX_HEIGHT, `ground near the site reaches {highest} m`)
		-- elsewhere the mountains are still there, under the cap
		local peak = 0
		for i = 0, 3999 do
			local golden = math.pi * (3 - math.sqrt(5))
			local y = 1 - (i + 0.5) * 2 / 4000
			local r = math.sqrt(1 - y * y)
			peak = math.max(peak, Relief.height(HOMEWORLD, r * math.cos(golden * i), y, r * math.sin(golden * i)))
		end
		t.expectTrue(peak > 800 and peak <= earthMax, `mountains reach {peak} m`)
	end)
end
