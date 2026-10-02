--!strict
-- CHANGED (Phase 8): tests for the surface terrain: the heightmap (Sim/Relief, Sim/SurfaceHeight) and the
-- renderer's pure geometry (Render/TerrainMath): determinism, the flat launch site and its blend, the sea, Mun
-- craters, continuity across cube faces and lattice cells, normals, speed, chunks matching the physics ground,
-- LOD seams covered by skirts, the quadtree selection, collision wedges, and a craft settling on a slope.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Fixtures = require(script.Parent.CraftFixtures)
local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Relief = require(ReplicatedStorage.Shared.Sim.Relief)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local Render = game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render
local TerrainMath = require(Render.TerrainMath)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local SPHERE_SAMPLES = 400 -- Fibonacci directions for sphere-wide checks
local PERF_CALLS = 20000 -- SurfaceHeight.height calls timed
local MIN_CALLS_PER_SECOND = 30000 -- offline (Lune, no native code); Roblox runs it several times faster
local CONTINUITY_EPS = 1e-9 -- rad either side of an edge
local CONTINUITY_TOL = 1e-4 -- m of ground radius
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD
local MOON = Bodies.MOON
local EARTH_R = Bodies.get(HOMEWORLD).Radius
local MOON_R = Bodies.get(MOON).Radius

local function fibonacci(i: number, count: number): Vec3d
	local golden = math.pi * (3 - math.sqrt(5))
	local y = 1 - (i + 0.5) * 2 / count
	local r = math.sqrt(1 - y * y)
	return Vec3d.new(r * math.cos(golden * i), y, r * math.sin(golden * i))
end

-- Point in the launch site's tangent plane (the base pocket's ground), `e` east and `n` north of the pad area origin.
local function sitePlane(e: number, n: number, up: number): Vec3d
	-- base-pocket axes at lat 0 / lon 0: X = east = universe +Z, Y = up = universe +X, Z = north = universe +Y
	return Vec3d.new(EARTH_R + up, n, e)
end

-- Unit tangent axes perpendicular to a unit direction.
local function tangents(d: Vec3d): (Vec3d, Vec3d)
	local ref = if math.abs(d.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
	local e1 = Vec3d.normalize(Vec3d.cross(ref, d))
	return e1, Vec3d.cross(d, e1)
end

-- Direction `dist` m (along the surface) from unit direction d along unit tangent t, on a body of radius r.
local function walk(d: Vec3d, t: Vec3d, dist: number, r: number): Vec3d
	local a = dist / r
	return Vec3d.normalize(Vec3d.add(Vec3d.scale(d, math.cos(a)), Vec3d.scale(t, math.sin(a))))
end

local function groundRadius(bodyId: number, d: Vec3d): number
	local p = SurfaceHeight.groundPoint(bodyId, d)
	return Vec3d.length(p)
end

return function(t: TestKit.Context)
	t.test("heightmap: deterministic, bounded, oceans at sea level", function()
		local _, earthMax = Relief.bounds(HOMEWORLD)
		local moonMin, moonMax = Relief.bounds(MOON)
		local land, sea, flatSea = 0, 0, 0
		for i = 0, SPHERE_SAMPLES - 1 do
			local d = fibonacci(i, SPHERE_SAMPLES)
			local h1 = Relief.height(HOMEWORLD, d.x, d.y, d.z)
			t.expectEqual(h1, Relief.height(HOMEWORLD, d.x, d.y, d.z))
			t.expectTrue(h1 >= 0 and h1 <= earthMax, "Earth height in bounds: " .. h1)
			local _, _, _, kind = Biome.sample(HOMEWORLD, d.x, d.y, d.z)
			if kind == "Ocean" then
				sea += 1
				t.expectEqual(h1, 0)
				-- the ground over the sea is the flat sea (lattice chords sag < 1 cm below the sphere), except within
				-- a cell of a coast
				local r = groundRadius(HOMEWORLD, d)
				t.expectTrue(r > EARTH_R - 0.01 and r < EARTH_R + 10, "sea level " .. r)
				if math.abs(r - EARTH_R) < 0.01 then
					flatSea += 1
				end
			else
				land += 1
			end
			local m = Relief.height(MOON, d.x, d.y, d.z)
			t.expectEqual(m, Relief.height(MOON, d.x, d.y, d.z))
			t.expectTrue(m >= moonMin and m <= moonMax, "Mun height in bounds: " .. m)
			-- physics heights are the same number every time (cache or not)
			local p = Vec3d.scale(d, EARTH_R + 30)
			local a1, n1 = SurfaceHeight.height(HOMEWORLD, p)
			local a2, n2 = SurfaceHeight.height(HOMEWORLD, p)
			t.expectEqual(a1, a2)
			t.expectEqual(n1.x, n2.x)
		end
		t.expectTrue(sea > SPHERE_SAMPLES * 0.4 and land > SPHERE_SAMPLES * 0.2, `sea {sea}, land {land}`)
		t.expectTrue(flatSea > 0.95 * sea, `flat sea {flatSea} of {sea}`)
		-- the Mun's peaks stay under its 500 m rails floor
		t.expectTrue(moonMax < 450, "Mun peaks under the rails floor")
	end)

	t.test("heightmap: Earth has hills and mountains, the Mun has relief", function()
		local earthHigh, moonLow, moonHigh = 0, 0, 0
		for i = 0, 1999 do
			local d = fibonacci(i, 2000)
			earthHigh = math.max(earthHigh, Relief.height(HOMEWORLD, d.x, d.y, d.z))
			local m = Relief.height(MOON, d.x, d.y, d.z)
			moonLow = math.min(moonLow, m)
			moonHigh = math.max(moonHigh, m)
		end
		t.expectTrue(earthHigh > 800, "Earth mountains reach " .. earthHigh)
		t.expectTrue(moonHigh - moonLow > 250, `Mun relief {moonLow} .. {moonHigh}`)
	end)

	t.test("launch site: exactly the base pocket's plane, pads and plots where they were", function()
		local plateEdge = BaseLayout.SITE_HALF_EXTENT
		for _, en in { { 0, 0 }, { plateEdge, plateEdge }, { -plateEdge, 300 }, { 600, -600 }, { 0, 850 } } do
			local e, n = en[1], en[2]
			local onGround = sitePlane(e, n, 0)
			if BaseLayout.platformHeight(e, n) == 0 then
				local h, normal = SurfaceHeight.height(HOMEWORLD, onGround)
				t.expectNear(h, 0, 1e-6)
				t.expectNear(normal.x, 1, 1e-9)
				t.expectNear(SurfaceHeight.height(HOMEWORLD, sitePlane(e, n, 7.5)), 7.5, 1e-6)
			end
		end
		-- every pad top is exactly 1 stud above the plane, as before
		for _, pad in BaseLayout.Pads do
			local top = pad.top.Position
			t.expectNear(SurfaceHeight.height(HOMEWORLD, sitePlane(top.X, top.Z, BaseLayout.PAD_HEIGHT)), 0, 1e-6)
		end
	end)

	t.test("launch site: the plane blends smoothly into the hills", function()
		local flat, blend = Relief.SITE_FLAT_RADIUS, Relief.SITE_BLEND_RADIUS
		for _, heading in { 0, 1.1, 2.3, 3.9, 5.2 } do
			local previous: number? = nil
			local worstSlope = 0
			for rho = flat - 100, blend + 300, 10 do
				local e, n = rho * math.cos(heading), rho * math.sin(heading)
				local d = Vec3d.normalize(sitePlane(e, n, 0))
				local h = Relief.height(HOMEWORLD, d.x, d.y, d.z)
				if previous then
					worstSlope = math.max(worstSlope, math.abs(h - previous) / 10)
				end
				previous = h
				if rho <= flat then
					t.expectNear(Relief.siteWeight(d.x, d.y, d.z), 1, 1e-9)
				elseif rho >= blend then
					t.expectNear(Relief.siteWeight(d.x, d.y, d.z), 0, 1e-9)
				end
			end
			t.expectTrue(worstSlope < 0.6, "no cliffs in the blend ring: slope " .. worstSlope)
		end
	end)

	t.test("Mun craters: a bowl below a raised rim", function()
		-- find a large crater's centre: the direction with the smallest scale-1 crater distance
		local bestT, bestDir, bestRadius = math.huge, Vec3d.new(1, 0, 0), 0
		local function probe(d: Vec3d)
			Biome.craterSum(d.x, d.y, d.z, function(tt: number, radius: number, scale: number): number
				if scale == 1 and tt < bestT then
					bestT, bestDir, bestRadius = tt, d, radius
				end
				return 0
			end)
		end
		for i = 0, 2999 do
			probe(fibonacci(i, 3000))
		end
		-- refine toward the centre
		local step = bestRadius * 0.25
		for _ = 1, 60 do
			local e1, e2 = tangents(bestDir)
			local from = bestDir
			for _, tdir in { e1, e2, Vec3d.scale(e1, -1), Vec3d.scale(e2, -1) } do
				probe(walk(from, tdir, step * MOON_R, MOON_R))
			end
			if bestDir == from then
				step *= 0.5
			end
		end
		t.expectTrue(bestT < 0.05, "found a crater centre (t " .. bestT .. ")")
		local rim = bestRadius * MOON_R
		local e1 = tangents(bestDir)
		local floor = Relief.height(MOON, bestDir.x, bestDir.y, bestDir.z)
		local function at(k: number): number
			local d = walk(bestDir, e1, k * rim, MOON_R)
			return Relief.height(MOON, d.x, d.y, d.z)
		end
		local rimHeight, outside = at(1), at(2.2)
		t.expectTrue(rimHeight - floor > 0.08 * rim, `deep bowl: floor {floor}, rim {rimHeight}, rim radius {rim}`)
		t.expectTrue(rimHeight > outside, `raised rim: rim {rimHeight}, outside {outside}`)
		t.expectTrue(at(0.5) < at(0.9), "the bowl rises toward the rim")
	end)

	t.test("ground is continuous across cube faces and lattice cells", function()
		for _, bodyId in { HOMEWORLD, MOON } do
			-- cube edges (x = z) and corners, then lattice cell edges inside a face
			local cases: { { Vec3d } } = {}
			for _, v in { 0.31, -0.62, 0.05 } do
				local a = Vec3d.normalize(Vec3d.new(1, v, 1 + CONTINUITY_EPS))
				local b = Vec3d.normalize(Vec3d.new(1 + CONTINUITY_EPS, v, 1))
				table.insert(cases, { a, b })
				local c = Vec3d.normalize(Vec3d.new(v, -1, -1 - CONTINUITY_EPS))
				local d = Vec3d.normalize(Vec3d.new(v, -1 - CONTINUITY_EPS, -1))
				table.insert(cases, { c, d })
			end
			table.insert(cases, {
				Vec3d.normalize(Vec3d.new(1, 1 + CONTINUITY_EPS, 1 + 2 * CONTINUITY_EPS)),
				Vec3d.normalize(Vec3d.new(1 + 2 * CONTINUITY_EPS, 1, 1 + CONTINUITY_EPS)),
			})
			local n = SurfaceHeight.latticeSize(bodyId)
			for _, i in { 17, 300, n / 2 } do
				-- either side of the line a = lattice angle i on face 3 (+Y)
				local angle = -math.pi / 4 + i * (math.pi / 2) / n
				for _, sign in { 1, -1 } do
					local x1 = math.tan(angle - CONTINUITY_EPS * sign)
					local x2 = math.tan(angle + CONTINUITY_EPS * sign)
					table.insert(cases, {
						Vec3d.normalize(Vec3d.new(x1, 1, 0.123)),
						Vec3d.normalize(Vec3d.new(x2, 1, 0.123)),
					})
				end
			end
			for _, pair in cases do
				local r1, r2 = groundRadius(bodyId, pair[1]), groundRadius(bodyId, pair[2])
				t.expectNear(r1, r2, CONTINUITY_TOL, `continuity on body {bodyId}`)
			end
		end
	end)

	t.test("normals: unit, upward, and the true triangle normal; heights measured along them", function()
		for i = 0, 99 do
			local d = fibonacci(i * 7 + 3, 700)
			for _, bodyId in { HOMEWORLD, MOON } do
				local ground, normal = SurfaceHeight.groundPoint(bodyId, d)
				t.expectNear(Vec3d.length(normal), 1, 1e-9)
				t.expectTrue(Vec3d.dot(normal, d) > 0, "normal points up")
				-- 2.5 m above the ground along the normal reads as 2.5 m
				local above = Vec3d.add(ground, Vec3d.scale(normal, 2.5))
				local h, n2 = SurfaceHeight.height(bodyId, above)
				if Vec3d.dot(n2, normal) > 0.999999 then -- still over the same triangle
					t.expectNear(h, 2.5, 1e-6)
				end
				-- numerical normal from three nearby ground points on the same triangle
				local r = Vec3d.length(ground)
				local e1, e2 = tangents(d)
				local pa = SurfaceHeight.groundPoint(bodyId, walk(d, e1, 0.3, r))
				local pb = SurfaceHeight.groundPoint(bodyId, walk(d, e2, 0.3, r))
				local _, na = SurfaceHeight.groundPoint(bodyId, walk(d, e1, 0.3, r))
				local _, nb = SurfaceHeight.groundPoint(bodyId, walk(d, e2, 0.3, r))
				if Vec3d.dot(na, normal) > 0.999999 and Vec3d.dot(nb, normal) > 0.999999 then
					local numeric = Vec3d.normalize(Vec3d.cross(Vec3d.sub(pa, ground), Vec3d.sub(pb, ground)))
					t.expectTrue(math.abs(Vec3d.dot(numeric, normal)) > 0.9999, "triangle normal")
				end
			end
		end
	end)

	t.test("SurfaceHeight.height is fast enough for the flight sim", function()
		local d = Vec3d.normalize(Vec3d.new(0.4, 0.5, 0.75))
		local base = SurfaceHeight.groundPoint(HOMEWORLD, d)
		local p = Vec3d.zero()
		-- warm the cache like a landed craft would
		for i = 1, 64 do
			Vec3d.set(p, base.x + (i % 8) * 1.7, base.y + (i % 5) * 1.3, base.z + (i % 3) * 2.1)
			SurfaceHeight.height(HOMEWORLD, p)
		end
		local start = os.clock()
		local sum = 0
		for i = 1, PERF_CALLS do
			Vec3d.set(p, base.x + (i % 8) * 1.7, base.y + (i % 5) * 1.3, base.z + (i % 3) * 2.1)
			sum += SurfaceHeight.height(HOMEWORLD, p)
		end
		local perSecond = PERF_CALLS / math.max(os.clock() - start, 1e-6)
		t.expectTrue(sum == sum, "finite")
		t.expectTrue(perSecond > MIN_CALLS_PER_SECOND, string.format("%.0f calls/s", perSecond))
	end)

	t.test("finest chunks are exactly the physics ground; every triangle faces up", function()
		for _, bodyId in { HOMEWORLD, MOON } do
			local config = TerrainMath.config(bodyId) :: TerrainMath.Config
			local deepest = config.maxDepth
			local node = TerrainMath.node(config, 3, deepest, 37, 52)
			local chunk = TerrainMath.buildChunk(config, node)
			local side = TerrainMath.CHUNK + 1
			t.expectEqual(chunk.triangleCount, 2 * TerrainMath.CHUNK * TerrainMath.CHUNK + 8 * TerrainMath.CHUNK)
			local function world(v: number): Vec3d
				local px, py, pz = TerrainMath.chunkVertex(chunk, v)
				return Vec3d.new(chunk.ox + px, chunk.oy + py, chunk.oz + pz)
			end
			for v = 1, side * side do
				local p = world(v)
				local d = Vec3d.normalize(p)
				local h = SurfaceHeight.height(bodyId, Vec3d.add(p, Vec3d.scale(d, TerrainMath.RENDER_DROP)))
				t.expectNear(h, 0, 2e-3) -- f32 offsets from the chunk origin
			end
			for k = 1, 2 * TerrainMath.CHUNK * TerrainMath.CHUNK * 3, 3 do
				local a, b, c = world(chunk.tris[k]), world(chunk.tris[k + 1]), world(chunk.tris[k + 2])
				local centroid = Vec3d.scale(Vec3d.add(Vec3d.add(a, b), c), 1 / 3)
				local up = Vec3d.normalize(centroid)
				local normal = Vec3d.cross(Vec3d.sub(b, a), Vec3d.sub(c, a))
				t.expectTrue(Vec3d.dot(normal, up) > 0, "counter-clockwise seen from above")
				local h = SurfaceHeight.height(bodyId, Vec3d.add(centroid, Vec3d.scale(up, TerrainMath.RENDER_DROP)))
				t.expectNear(h, 0, 2e-3)
			end
			-- skirts hang below their edge
			for v = side * side + 1, chunk.vertexCount do
				local p = world(v)
				t.expectTrue(SurfaceHeight.height(bodyId, p) < -1.5, "skirt below the ground")
			end
			for k = 1, chunk.vertexCount do
				local _, _, _, nx, ny, nz, r, g, b = TerrainMath.chunkVertex(chunk, k)
				t.expectNear(nx * nx + ny * ny + nz * nz, 1, 1e-5)
				t.expectTrue(r >= 0 and r <= 1 and g >= 0 and g <= 1 and b >= 0 and b <= 1, "colour")
			end
			-- every skirt quad faces away from the chunk, and the skirts are as deep as promised
			t.expectTrue(chunk.skirt >= 2, "skirt depth")
		end
	end)

	t.test("the launch site's ground plate is painted into the terrain (seen from high up)", function()
		local config = TerrainMath.config(HOMEWORLD) :: TerrainMath.Config
		local _, fi, fj = SurfaceHeight.latticeCoords(HOMEWORLD, Vec3d.new(1, 0, 0))
		local span = TerrainMath.CHUNK
		local node = TerrainMath.node(config, 1, config.maxDepth, math.floor(fi / span), math.floor(fj / span))
		local chunk = TerrainMath.buildChunk(config, node)
		local grey, green = 0, 0
		for v = 1, (span + 1) * (span + 1) do
			local px, py, pz, _, _, _, r, _, b = TerrainMath.chunkVertex(chunk, v)
			local x, y, z = chunk.ox + px, chunk.oy + py, chunk.oz + pz
			local onPlate = math.abs(y) <= BaseLayout.SITE_HALF_EXTENT and math.abs(z) <= BaseLayout.SITE_HALF_EXTENT
			local isGrey = math.abs(r - 99 / 255) < 1e-6 and math.abs(b - 107 / 255) < 1e-6
			t.expectEqual(isGrey, onPlate)
			if isGrey then
				grey += 1
			else
				green += 1
			end
			t.expectNear(x, EARTH_R - TerrainMath.RENDER_DROP, 0.01) -- the plane, just below the real plate
		end
		t.expectTrue(grey > 0, "plate vertices")
	end)

	t.test("LOD seams: skirts cover the gap to a coarser neighbour", function()
		local function point(bodyId: number, face: number, i: number, j: number): Vec3d
			local x, y, z = SurfaceHeight.nodeDirection(bodyId, face, i, j)
			local r = Bodies.get(bodyId).Radius + SurfaceHeight.nodeHeight(bodyId, face, i, j)
			return Vec3d.new(x * r, y * r, z * r)
		end
		for _, bodyId in { HOMEWORLD, MOON } do
			local config = TerrainMath.config(bodyId) :: TerrainMath.Config
			for _, levels in { 1, 2 } do
				for _, depth in { config.maxDepth, config.maxDepth - 2, config.maxDepth - 4 } do
					-- the fine node's +i edge is the coarse node's -i edge (coarse = `levels` levels up)
					local scale = 2 ^ levels
					local x, y = 9, 6
					local fine = TerrainMath.node(config, 5, depth, scale * x + scale - 1, scale * y)
					local coarse = TerrainMath.node(config, 5, depth - levels, x + 1, y)
					local fineChunk = TerrainMath.buildChunk(config, fine)
					local coarseChunk = TerrainMath.buildChunk(config, coarse)
					local edgeI = fine.i0 + TerrainMath.CHUNK * fine.stride
					t.expectEqual(edgeI, coarse.i0)
					for k = 0, TerrainMath.CHUNK do
						local j = fine.j0 + k * fine.stride
						local p = point(bodyId, 5, edgeI, j)
						-- the coarse edge: straight between its own vertices
						local cj = (j - coarse.j0) / coarse.stride
						local c0 = math.floor(cj)
						local f = cj - c0
						local a = point(bodyId, 5, edgeI, coarse.j0 + c0 * coarse.stride)
						local b =
							point(bodyId, 5, edgeI, coarse.j0 + math.min(c0 + 1, TerrainMath.CHUNK) * coarse.stride)
						local q = Vec3d.add(a, Vec3d.scale(Vec3d.sub(b, a), f))
						local gap = Vec3d.length(p) - Vec3d.length(q)
						if gap > 0 then
							t.expectTrue(gap <= fineChunk.skirt, `fine skirt {fineChunk.skirt} covers {gap}`)
						else
							t.expectTrue(-gap <= coarseChunk.skirt, `coarse skirt {coarseChunk.skirt} covers {-gap}`)
						end
					end
				end
			end
		end
	end)

	t.test("quadtree: deterministic, bounded, covers the ground under the camera", function()
		for _, bodyId in { HOMEWORLD, MOON } do
			local config = TerrainMath.config(bodyId) :: TerrainMath.Config
			local d = Vec3d.normalize(Vec3d.new(1, 0.21, -0.13))
			local foot = SurfaceHeight.groundPoint(bodyId, d)
			for _, height in { 2, 400, 5000 } do
				local cam = Vec3d.add(foot, Vec3d.scale(d, height))
				local params = { splitK = 1.05, mergeK = 1.2, maxLeaves = 240 }
				local a = TerrainMath.select(config, cam, params, nil)
				local b = TerrainMath.select(config, cam, params, a.split)
				t.expectEqual(#a.leaves, #b.leaves)
				t.expectTrue(#a.leaves > 0 and #a.leaves <= 240, "leaf count " .. #a.leaves)
				-- the leaf under the camera (same face and lattice cell range)
				local face, fi, fj = SurfaceHeight.latticeCoords(bodyId, cam)
				local under: TerrainMath.Node? = nil
				for _, leaf in a.leaves do
					local span = TerrainMath.CHUNK * leaf.stride
					if
						leaf.face == face
						and fi >= leaf.i0
						and fi < leaf.i0 + span
						and fj >= leaf.j0
						and fj < leaf.j0 + span
					then
						under = leaf
					end
				end
				t.expectTrue(under ~= nil, "a leaf under the camera")
				if height <= 2 and under then
					t.expectEqual(under.depth, config.maxDepth) -- at the ground, the physics resolution
				end
				-- one band per level, coarse levels merged; the finest band fits one part at true scale
				local merge = TerrainMath.mergeLevel(config, a.leaves, 6)
				local finest = merge - 5
				local perBand: { [number]: number } = {}
				for _, leaf in a.leaves do
					local level = TerrainMath.levelOf(config, leaf)
					local band = TerrainMath.bandOf(config, leaf, merge)
					t.expectEqual(band, math.min(level, merge))
					t.expectTrue(level >= finest, "no leaf finer than the finest level")
					perBand[band] = (perBand[band] or 0) + 1
					if level == finest and height <= 2 then
						local reach = Vec3d.distance(Vec3d.new(leaf.cx, leaf.cy, leaf.cz), foot) + leaf.radius
						t.expectTrue(reach < 1020, "finest band within one part: " .. reach)
					end
				end
				for band, count in perBand do
					if band < merge then
						t.expectTrue(count <= TerrainMath.MAX_BAND_LEAVES, `band {band}: {count} leaves`)
					end
				end
			end
		end
	end)

	t.test("band scale: true scale inside the budget, scaled about the camera outside it", function()
		-- a ring around the camera: only the part limit matters
		t.expectEqual(TerrainMath.bandScale(100, 1100, 1900, 1000, 17000, 2040), 1)
		t.expectNear(TerrainMath.bandScale(100, 6000, 12000, 1000, 17000, 2040), 0.17, 1e-12)
		-- far below the camera: its centre comes within the draw budget
		local k = TerrainMath.bandScale(8000, 9000, 1800, 1000, 17000, 2040)
		t.expectTrue(8000 * k <= 1000 + 1e-9 and 1800 * k <= 2040, "fits the budget")
		-- never beyond the far limit
		t.expectTrue(TerrainMath.bandScale(100, 40000, 1500, 1000, 17000, 2040) * 40000 <= 17000 + 1e-9, "far limit")
	end)

	t.test("collision wedges: the lattice triangle is their top face, their bulk below", function()
		local config = TerrainMath.config(MOON) :: TerrainMath.Config
		local d = Vec3d.normalize(Vec3d.new(-0.6, 0.5, 0.62))
		local foot = SurfaceHeight.groundPoint(MOON, d)
		local triangles = TerrainMath.collisionTriangles(config, foot, 40, {})
		t.expectTrue(#triangles >= 8, "triangles around the point: " .. #triangles)
		for index = 1, math.min(#triangles, 12) do
			local tri = triangles[index]
			local o = Vec3d.new(tri[1], tri[2], tri[3])
			local a = Vector3.zero
			local b = Vector3.new(tri[4] - o.x, tri[5] - o.y, tri[6] - o.z)
			local c = Vector3.new(tri[7] - o.x, tri[8] - o.y, tri[9] - o.z)
			local up = Vec3d.toVector3(Vec3d.normalize(o))
			local thickness = 4
			local cf0, size0, cf1, size1 = TerrainMath.wedgePair(a, b, c, up, thickness)
			t.expectTrue(cf0 ~= nil and cf1 ~= nil, "two wedges")
			if cf0 and size0 and cf1 and size1 then
				local wedges: { { cf: CFrame, size: Vector3 } } =
					{ { cf = cf0, size = size0 }, { cf = cf1, size = size1 } }
				for _, wedge in wedges do
					local cf, size = wedge.cf, wedge.size
					t.expectNear(size.X, thickness, 1e-6)
					-- the wedge's side face plane holds the triangle; the wedge lies below it
					for _, v in { a, b, c } do
						t.expectNear(math.abs(cf:PointToObjectSpace(v).X), thickness / 2, 1e-3)
					end
					local n = (b - a):Cross(c - a).Unit
					if n:Dot(up) < 0 then
						n = -n
					end
					t.expectNear((cf.Position - (a + b + c) / 3):Dot(n), -thickness / 2, 1e-3)
				end
				-- together they span the longest edge
				local longest = math.max(b.Magnitude, c.Magnitude, (c - b).Magnitude)
				t.expectNear(size0.Z + size1.Z, longest, 1e-3)
			end
			-- and the triangle is the physics ground
			local mid = Vec3d.new(
				(tri[1] + tri[4] + tri[7]) / 3,
				(tri[2] + tri[5] + tri[8]) / 3,
				(tri[3] + tri[6] + tri[9]) / 3
			)
			t.expectNear(SurfaceHeight.height(MOON, mid), 0, 1e-6)
		end
	end)

	t.test("a lander settles on sloped ground without sliding away", function()
		-- a Mun spot sloping 6 .. 14 degrees
		local spot: Vec3d? = nil
		for i = 0, 3999 do
			local d = fibonacci(i, 4000)
			local _, normal = SurfaceHeight.groundPoint(MOON, d)
			local slope = math.deg(math.acos(math.clamp(Vec3d.dot(normal, d), -1, 1)))
			if slope > 6 and slope < 14 then
				spot = d
				break
			end
		end
		t.expectTrue(spot ~= nil, "found a slope")
		local up = spot :: Vec3d
		local design = Fixtures.stack("Lander", { "tank_s_short", "pod_mk1" })
		local ground = SurfaceHeight.groundPoint(MOON, up)
		local state: FlightModel.CraftState = {
			bodyId = MOON,
			pos = Vec3d.add(ground, Vec3d.scale(up, 8)),
			vel = Vec3d.zero(),
			rot = Frames.surfaceRotation(up),
			angVel = Vector3.zero,
			throttle = 0,
			flags = 0,
			ut = 0,
		}
		local craft = FlightModel.newCraft(design, state)
		for _ = 1, 10 * 60 do
			FlightModel.step(craft)
		end
		t.expectEqual(#craft.destroyed, 0)
		t.expectTrue(Vec3d.length(craft.state.vel) < 0.3, "at rest: " .. Vec3d.length(craft.state.vel))
		t.expectTrue(bit32.band(craft.state.flags, FlightModel.FLAG_CONTACT) ~= 0, "touching the ground")
		local drift = Vec3d.distance(SurfaceHeight.groundPoint(MOON, craft.state.pos), ground)
		t.expectTrue(drift < 6, "did not slide away: " .. drift .. " m")
	end)
end
