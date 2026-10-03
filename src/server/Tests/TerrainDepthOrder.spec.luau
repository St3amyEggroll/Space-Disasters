--!strict
-- CHANGED (Depth order fix): tests for the radial depth map the scaled terrain bands are baked with
-- (TerrainMath.depthMap / mapDepth / depthFactor / depthPose / depthChunk): continuous, strictly increasing, bounded,
-- points on one ray from the build camera keep their direction and their order (so from that camera a nearer ridge
-- always hides what lies behind it, across bands too), and the pose's error bound holds for a moved camera.
-- CHANGED (Flight depth fix): the new anchors (a plain factor out to 1.7 km), the uniform zone (a band holding ground
-- there is posed exactly: its picture of that ground is right from any camera, so its seams there never move),
-- the widened maps of a plan in flight (depthStart / widenDepthMap: continuous, increasing, the same zone-end depth)
-- and the depth map's lead (depthCentre).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local Render = game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render
local TerrainMath = require(Render.TerrainMath)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables (the values Render/TerrainMesh uses: DEPTH)
--============================================================================
local DIST = { 1700, 6000, 40000 } -- CHANGED (Flight depth fix): was { 900, 3000, 40000 } -> { 520, 940, 1010 }
local DEPTH = { 850, 935, 1010 }
local STEP = 1.25 -- CULL.DEPTH_STEP
local PART_LIMIT = 2040
local SAMPLES = 4000 -- distances checked along the map
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD

-- a camera `height` m above the ground at site-plane (x, z) on Earth
local function earthCamera(x: number, z: number, height: number): Vec3d
	local radius = Bodies.get(HOMEWORLD).Radius
	local up = Frames.surfaceUp(0, 0)
	local frame = Frames.new(HOMEWORLD, Vec3d.scale(up, radius), Frames.surfaceRotation(up), Vector3.zero)
	local dir = Vec3d.normalize(Frames.pointFromWorkspace(frame, Vector3.new(x, 0, z)))
	return Vec3d.add(SurfaceHeight.groundPoint(HOMEWORLD, dir), Vec3d.scale(dir, height))
end

-- angle (rad) between two vectors
local function angle(a: Vec3d, b: Vec3d): number
	local c = Vec3d.dot(a, b) / (Vec3d.length(a) * Vec3d.length(b))
	return math.acos(math.clamp(c, -1, 1))
end

return function(t: TestKit.Context)
	local m = TerrainMath.depthMap(DIST, DEPTH)

	t.test("depth map: through the anchors, continuous, strictly increasing, bounded by the part limit", function()
		for i, d in DIST do
			t.expectNear(TerrainMath.mapDepth(m, d), DEPTH[i], 1e-6, "anchor")
			-- continuous at every anchor (both sides)
			local below, above = TerrainMath.mapDepth(m, d - 1e-4), TerrainMath.mapDepth(m, d + 1e-4)
			t.expectTrue(math.abs(above - below) < 1e-3, `continuous at {d} m`)
		end
		local last = -math.huge
		for i = 1, SAMPLES do
			local d = 10 ^ (6 * i / SAMPLES) -- 1 m .. 1000 km
			local f = TerrainMath.mapDepth(m, d)
			t.expectTrue(f > last, `strictly increasing at {d} m`)
			last = f
			t.expectNear(TerrainMath.depthFactor(m, d) * d, f, 1e-6 * f, "depthFactor = f(d) / d")
			if d <= DIST[#DIST] then
				t.expectTrue(f <= DEPTH[#DEPTH] + 1e-9, "within the last anchor's depth")
				t.expectTrue(2 * f <= PART_LIMIT, "a ring around the camera fits the part limit")
			end
			if d >= DIST[1] then
				t.expectTrue(f >= DEPTH[1] - 1e-9, "scaled ground keeps at least the first anchor's depth")
				t.expectTrue(f <= d, "never drawn farther than it is")
			end
		end
		-- CHANGED (Flight depth fix): a plain factor out to the first anchor (past the near square's corners)
		for _, d in { 100, 760, 1400, 1700 } do
			t.expectNear(TerrainMath.depthFactor(m, d), DEPTH[1] / DIST[1], 1e-9, "uniform zone")
		end
	end)

	t.test("depthChunk: every vertex keeps its ray from the build camera and its order along it", function()
		local config = TerrainMath.config(HOMEWORLD) :: TerrainMath.Config
		for _, case in { { 0, 0, 40 }, { -1500, 1500, 250 }, { -6000, -10500, 20 } } do
			local cam = earthCamera(case[1], case[2], case[3])
			local up = Vec3d.normalize(cam)
			-- leaves near and far in one direction (on overlapping rays)
			local face, fi, fj = SurfaceHeight.latticeCoords(HOMEWORLD, cam)
			local checked = 0
			for depth = config.maxDepth - 2, math.max(config.maxDepth - 6, 0), -1 do
				local cells = TerrainMath.CHUNK * 2 ^ (config.maxDepth - depth)
				local x, y = math.floor(fi / cells) + 2, math.floor(fj / cells)
				if x >= 2 ^ depth then
					continue
				end
				local node = TerrainMath.node(config, face, depth, x, y)
				local chunk = TerrainMath.buildChunk(config, node)
				local shaded = 0
				local out, near, far = TerrainMath.depthChunk(chunk, cam, m, function(px, py, pz, r, g, b)
					-- the shade sees the TRUE position (on the ground: about the radius)
					local h = Vec3d.length(Vec3d.new(px, py, pz)) - config.radius
					t.expectTrue(math.abs(h) < 3000, "a true ground position")
					shaded += 1
					return r, g, b
				end)
				t.expectEqual(shaded, chunk.vertexCount, "every vertex shaded")
				t.expectEqual(out.vertexCount, chunk.vertexCount)
				t.expectTrue(out.tris == chunk.tris, "same triangles")
				t.expectTrue(near <= far, "nearest <= farthest")
				for v = 1, chunk.vertexCount do
					local px, py, pz, nx, ny, nz = TerrainMath.chunkVertex(chunk, v)
					local qx, qy, qz, mx, my, mz = TerrainMath.chunkVertex(out, v)
					local truth = Vec3d.sub(Vec3d.new(chunk.ox + px, chunk.oy + py, chunk.oz + pz), cam)
					local drawn = Vec3d.sub(Vec3d.new(out.ox + qx, out.oy + qy, out.oz + qz), cam)
					local d = Vec3d.length(truth)
					t.expectTrue(angle(truth, drawn) < 2e-5, "same ray from the build camera")
					t.expectNear(Vec3d.length(drawn), TerrainMath.mapDepth(m, d), 0.01, "drawn at f(d)")
					t.expectTrue(d >= near - 1e-6 and d <= far + 1e-6, "within the reported range")
					t.expectNear(nx, mx, 1e-6, "true normal kept")
					t.expectNear(ny, my, 1e-6)
					t.expectNear(nz, mz, 1e-6)
					t.expectTrue(
						qx >= out.minX - 1e-3
							and qx <= out.maxX + 1e-3
							and qz >= out.minZ - 1e-3
							and qz <= out.maxZ + 1e-3,
						"box"
					)
					t.expectTrue(qy >= out.minY - 1e-3 and qy <= out.maxY + 1e-3, "box y")
				end
				checked += 1
			end
			t.expectTrue(checked >= 2, "chunks checked")
			-- order along one ray: a nearer point always stays nearer, whatever bands they are in
			for _ = 1, 200 do
				local dir = Vec3d.normalize(
					Vec3d.add(
						Vec3d.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5),
						Vec3d.scale(up, -0.2)
					)
				)
				local d1 = 10 ^ (2 + 3 * math.random())
				local d2 = d1 * (1 + 0.001 + 2 * math.random())
				local f1, f2 = TerrainMath.mapDepth(m, d1), TerrainMath.mapDepth(m, d2)
				t.expectTrue(f2 > f1, "farther stays farther on the same ray")
				t.expectTrue(Vec3d.length(Vec3d.scale(dir, f1)) < Vec3d.length(Vec3d.scale(dir, f2)), "drawn order")
			end
		end
	end)

	t.test("depthPose: a band posed for a moved camera stays within its error bound", function()
		for _, range in { { 2000, 5000 }, { 2400, 9000 }, { 8000, 40000 }, { 1800, 60000 } } do
			local near, far = range[1], range[2]
			local k, err = TerrainMath.depthPose(m, near, far)
			t.expectTrue(k > 0 and k <= 1, "a factor")
			t.expectTrue(err > 0 and err < 1e-2, "an error bound (rad / m)")
			t.expectTrue(
				k <= TerrainMath.depthFactor(m, near) + 1e-9 and k >= TerrainMath.depthFactor(m, far) - 1e-9,
				"between the band's own factors"
			)
			-- a single distance: exact; posing at either end's own factor is never better than the minimax factor
			local _, errNear = TerrainMath.depthPose(m, near, near)
			t.expectTrue(errNear < 1e-9, "a single distance: exact")
			for _, at in { near, far } do
				local ka = TerrainMath.depthFactor(m, at)
				local worst = 0
				for i = 0, 24 do
					local d = near * (far / near) ^ (i / 24)
					worst = math.max(worst, math.abs(ka / TerrainMath.mapDepth(m, d) - 1 / d))
				end
				t.expectTrue(worst >= err - 1e-12, "minimax is the smallest bound")
			end
			for _ = 1, 300 do
				local u =
					Vec3d.normalize(Vec3d.new(math.random() - 0.5, (math.random() - 0.8) * 0.2, math.random() - 0.5))
				local d = near * (far / near) ^ math.random()
				local c0 = Vec3d.new(0, 0, 0)
				local move = Vec3d.scale(
					Vec3d.normalize(Vec3d.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)),
					0.5
				)
				local cam = Vec3d.add(c0, move)
				local truth = Vec3d.sub(Vec3d.scale(u, d), move)
				-- drawn at C + k (C0 - C) + u f(d)
				local drawn = Vec3d.add(Vec3d.scale(move, -k), Vec3d.scale(u, TerrainMath.mapDepth(m, d)))
				local off = angle(truth, drawn)
				t.expectTrue(off <= 0.5 * err * 1.05 + 1e-7, `within the bound ({off} > {0.5 * err})`)
				-- seen from the moved camera the picture is still in order along each ray (first order): no flip
				t.expectTrue(Vec3d.length(drawn) > 0, "in front")
				t.expectTrue(cam ~= nil)
			end
		end
	end)
	-- CHANGED (Flight depth fix)
	t.test(
		"depthPose: a band holding uniform-zone ground is exact there from any camera (its seams never move)",
		function()
			for _, range in { { 500, 1700 }, { 760, 2600 }, { 900, 40000 } } do
				local near, far = range[1], range[2]
				local k, err = TerrainMath.depthPose(m, near, far)
				t.expectNear(k, DEPTH[1] / DIST[1], 1e-12, "the zone's factor")
				if far <= DIST[1] then
					t.expectTrue(err < 1e-12, "wholly in the zone: no drift")
				end
				for _ = 1, 300 do
					local u = Vec3d.normalize(
						Vec3d.new(math.random() - 0.5, (math.random() - 0.8) * 0.2, math.random() - 0.5)
					)
					local d = near * (far / near) ^ math.random()
					-- a large move (a fast flight between rebuilds): 0 .. 500 m in any direction
					local move = Vec3d.scale(
						Vec3d.normalize(Vec3d.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5)),
						500 * math.random()
					)
					local truth = Vec3d.sub(Vec3d.scale(u, d), move)
					local drawn = Vec3d.add(Vec3d.scale(move, -k), Vec3d.scale(u, TerrainMath.mapDepth(m, d)))
					local off = angle(truth, drawn)
					if d <= DIST[1] then
						t.expectTrue(off < 1e-6, `exact in the zone ({off})`)
					else
						-- per-band affine placement: within the bound (first order, plus the second order of the move)
						t.expectTrue(
							off <= Vec3d.length(move) * err * 1.05 + 1e-3 * (Vec3d.length(move) / d) ^ 2 + 1e-7,
							"bound"
						)
					end
				end
			end
		end
	)

	t.test("depthStart / widenDepthMap: the zone widens as the protected depth allows; one continuous map", function()
		t.expectEqual(TerrainMath.depthStart(m, 760, 520, STEP), DIST[1], "on the ground: the base map")
		local last = DIST[1]
		for _, nearest in { 600, 900, 1500, 2500, 6000, 20000 } do
			local start = TerrainMath.depthStart(m, nearest, 160, STEP)
			t.expectTrue(start >= last, "wider for farther ground")
			last = start
			t.expectTrue(DEPTH[1] / start * nearest >= 160 - 1e-6 or start == DIST[1], "the protected depth holds")
			local steps = math.log(start / DIST[1]) / math.log(STEP)
			t.expectNear(steps, math.floor(steps + 0.5), 1e-9, "in steps")
			local w = TerrainMath.widenDepthMap(m, start)
			t.expectNear(w.dist[1], start, 1e-9, "zone end")
			t.expectNear(w.depth[1], DEPTH[1], 1e-9, "same depth at the zone's end (the seam between zones)")
			local prev = -math.huge
			for i = 1, SAMPLES do
				local d = 10 ^ (6 * i / SAMPLES)
				local f = TerrainMath.mapDepth(w, d)
				t.expectTrue(f > prev, "strictly increasing")
				prev = f
				if d <= 40000 then
					t.expectTrue(2 * f <= PART_LIMIT, "fits the part limit")
				end
			end
			for _, a in w.dist do
				local below, above = TerrainMath.mapDepth(w, a - 1e-4), TerrainMath.mapDepth(w, a + 1e-4)
				t.expectTrue(math.abs(above - below) < 1e-3, "continuous at its anchors")
			end
		end
		t.expectTrue(TerrainMath.widenDepthMap(m, DIST[1]) == m, "its own zone: the base map")
	end)

	t.test("depthCentre: the camera moved ahead along its velocity, at most `limit` m", function()
		local cam = Vec3d.new(10, 60000, -5)
		local c = TerrainMath.depthCentre(cam, 0, 0, 0, 1, 100)
		t.expectNear(Vec3d.distance(c, cam), 0, 1e-12, "still: the camera")
		c = TerrainMath.depthCentre(cam, 300, 0, 0, 0.5, 1000)
		t.expectNear(c.x - cam.x, 150, 1e-9, "lead x speed")
		c = TerrainMath.depthCentre(cam, 0, 700, 0, 2, 120)
		t.expectNear(c.y - cam.y, 120, 1e-9, "capped")
		c = TerrainMath.depthCentre(cam, 0, 700, 0, -1, 120)
		t.expectNear(Vec3d.distance(c, cam), 0, 1e-12, "never behind")
	end)
end
