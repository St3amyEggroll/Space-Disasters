--!strict
-- CHANGED (Night review): tests for the terrain review fixes in Render/TerrainMath: the near band (true-scale ground
-- around the camera's nadir) and its forced fine leaves, the band frames and exact boxes, the plan order that keeps
-- the mesh budget (planStep), the launch-site square kept in the near band (nearTarget), the object scale ladder
-- (scaleStep) and the per-cell collision updates.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
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
local PART_LIMIT = 2040
local BAND_COUNT = 6
local HIGH = { splitK = 1.4, mergeK = 1.4 * 1.15, maxLeaves = 320 }
local LOW = { splitK = 0.8, mergeK = 0.8 * 1.15, maxLeaves = 180 }
local KEEP_HALF = 600
local KEEP_RANGE = 400
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD
local MOON = Bodies.MOON

local function cameraAt(bodyId: number, dir: Vec3d, height: number): Vec3d
	local d = Vec3d.normalize(dir)
	return Vec3d.add(SurfaceHeight.groundPoint(bodyId, d), Vec3d.scale(d, height))
end

local function selectNear(config: TerrainMath.Config, cam: Vec3d, tier: any): (TerrainMath.Selection, TerrainMath.Near)
	local near = TerrainMath.newNear(config, cam, NEAR_HALF, NEAR_MAX_LEAF)
	local height = Vec3d.length(cam) - config.radius
	local params: TerrainMath.Params = {
		splitK = tier.splitK,
		mergeK = tier.mergeK,
		maxLeaves = tier.maxLeaves,
		bandCount = BAND_COUNT,
		horizonLead = math.max(30, 0.15 * height),
		near = near,
	}
	return TerrainMath.select(config, cam, params, nil), near
end

-- Every vertex of the chunks in body coordinates (brute force reference for frameBounds).
local function vertexBox(
	chunks: { TerrainMath.Chunk },
	nodes: { TerrainMath.Node },
	drops: { number },
	axes: TerrainMath.Axes
)
	local lo = { math.huge, math.huge, math.huge }
	local hi = { -math.huge, -math.huge, -math.huge }
	for index, c in chunks do
		local node = nodes[index]
		for v = 1, c.vertexCount do
			local px, py, pz = TerrainMath.chunkVertex(c, v)
			local p = Vec3d.new(
				c.ox + px - node.dx * drops[index],
				c.oy + py - node.dy * drops[index],
				c.oz + pz - node.dz * drops[index]
			)
			local f = { Vec3d.dot(p, axes.x), Vec3d.dot(p, axes.y), Vec3d.dot(p, axes.z) }
			for k = 1, 3 do
				lo[k] = math.min(lo[k], f[k])
				hi[k] = math.max(hi[k], f[k])
			end
		end
	end
	return lo, hi
end

return function(t: TestKit.Context)
	t.test("near band: fine leaves over the square, one true-scale part, the rest one band per level", function()
		local places: { { bodyId: number, dir: Vec3d } } = {
			{ bodyId = HOMEWORLD, dir = Vec3d.new(1, 0, 0.02) }, -- the launch site
			{ bodyId = HOMEWORLD, dir = Vec3d.new(0.7, 0.5, 0.5) }, -- near a cube-face corner (skewed lattice)
			{ bodyId = MOON, dir = Vec3d.new(0.6, -0.5, 0.6) },
		}
		for _, place in places do
			local bodyId, dir = place.bodyId, place.dir
			local config = TerrainMath.config(bodyId) :: TerrainMath.Config
			for _, height in { 2, 600, 3000 } do
				for _, tier in { HIGH, LOW } do
					local cam = cameraAt(bodyId, dir, height)
					local selection, near = selectNear(config, cam, tier)
					local assigned = TerrainMath.assignBands(config, selection.leaves, BAND_COUNT, near)
					local chunks, nodes = {}, {}
					local perBand: { [number]: number } = {}
					local bandsUsed = 0
					local ring: { TerrainMath.Node } = {}
					for _, leaf in selection.leaves do
						local u, v = TerrainMath.nearOffset(near, Vec3d.new(leaf.cx, leaf.cy, leaf.cz))
						if math.abs(u) > NEAR_HALF or math.abs(v) > NEAR_HALF then
							table.insert(ring, leaf)
						end
					end
					-- levels counted from the finest leaf of the whole selection (stable band ids)
					local merge = TerrainMath.mergeLevel(config, selection.leaves, BAND_COUNT - 1)
					t.expectTrue(#ring > 0, "ground beyond the near band")
					for _, leaf in selection.leaves do
						local band = assigned[leaf.key]
						if perBand[band] == nil then
							bandsUsed += 1
						end
						perBand[band] = (perBand[band] or 0) + 1
						local u, v = TerrainMath.nearOffset(near, Vec3d.new(leaf.cx, leaf.cy, leaf.cz))
						local inside = math.abs(u) <= NEAR_HALF and math.abs(v) <= NEAR_HALF
						if inside then
							-- select() splits everything over the square down to the near leaf size
							t.expectTrue(leaf.size <= NEAR_MAX_LEAF * 1.01, `leaf of {leaf.size} m in the square`)
							t.expectEqual(band, TerrainMath.NEAR_BAND)
							table.insert(chunks, TerrainMath.buildChunk(config, leaf))
							table.insert(nodes, leaf)
						else
							t.expectEqual(
								band,
								TerrainMath.NEAR_BAND + 1 + math.min(TerrainMath.levelOf(config, leaf), merge)
							)
						end
					end
					t.expectTrue(bandsUsed <= BAND_COUNT, `{bandsUsed} bands`)
					for band, count in perBand do
						t.expectTrue(count <= TerrainMath.MAX_BAND_LEAVES + 5, `band {band}: {count} leaves`)
					end
					t.expectTrue(#chunks > 0, "the near band holds the ground under the camera")
					-- the near band fits one part at true scale (in its best frame)
					local axes = TerrainMath.bestAxes(chunks, near.axes)
					local _, _, _, size = TerrainMath.frameBounds(chunks, nodes, nil, axes)
					t.expectTrue(math.max(size.X, size.Y, size.Z) < PART_LIMIT, `near band box {size}`)
				end
			end
		end
	end)

	t.test(
		"band frames: frameBounds is the exact vertex box (sunk leaves included); bestAxes is never worse",
		function()
			local config = TerrainMath.config(HOMEWORLD) :: TerrainMath.Config
			local cam = cameraAt(HOMEWORLD, Vec3d.new(0.7, 0.5, 0.5), 150)
			local selection = TerrainMath.select(config, cam, { splitK = 1.05, mergeK = 1.2, maxLeaves = 240 }, nil)
			local chunks, nodes, drops = {}, {}, {}
			for index, leaf in selection.leaves do
				if index > 30 then
					break
				end
				table.insert(chunks, TerrainMath.buildChunk(config, leaf))
				table.insert(nodes, leaf)
				table.insert(drops, if index % 3 == 0 then 4 else 0)
			end
			local base = TerrainMath.tangentAxes(config, cam)
			-- right-handed and orthonormal
			t.expectNear(Vec3d.dot(base.x, base.y), 0, 1e-9)
			t.expectNear(Vec3d.dot(Vec3d.cross(base.x, base.y), base.z), 1, 1e-9)
			local fx, fy, fz, size = TerrainMath.frameBounds(chunks, nodes, drops, base)
			local lo, hi = vertexBox(chunks, nodes, drops, base)
			t.expectNear(fx, (lo[1] + hi[1]) / 2, 1e-3)
			t.expectNear(fy, (lo[2] + hi[2]) / 2, 1e-3)
			t.expectNear(fz, (lo[3] + hi[3]) / 2, 1e-3)
			t.expectNear(size.X, hi[1] - lo[1], 1e-2)
			t.expectNear(size.Y, hi[2] - lo[2], 1e-2)
			t.expectNear(size.Z, hi[3] - lo[3], 1e-2)
			-- the sink lowers the box (along the radial up, roughly the frame's y)
			local _, _, _, unsunk = TerrainMath.frameBounds(chunks, nodes, nil, base)
			t.expectTrue(size.Y >= unsunk.Y, "sunk leaves widen the box downward")
			local best = TerrainMath.bestAxes(chunks, base)
			local universe = { x = Vec3d.new(1, 0, 0), y = Vec3d.new(0, 1, 0), z = Vec3d.new(0, 0, 1) }
			local function extent(axes: TerrainMath.Axes): number
				local _, _, _, s = TerrainMath.frameBounds(chunks, nodes, nil, axes)
				return math.max(s.X, s.Y, s.Z)
			end
			t.expectTrue(extent(best) <= extent(base) + 1, "best <= lattice frame")
			t.expectTrue(extent(best) <= extent(universe) + 1, "best <= universe axes")
		end
	)

	t.test("planStep: nothing is built while more than bandCount bands are alive; hole-free order otherwise", function()
		-- bands 2..7 alive (6 = bandCount); band 0 and 1 are new, 6 and 7 go away and wait for them (a camera jump)
		local pending = { [0] = true, [1] = true, [2] = true, [6] = true, [7] = true }
		local covered = { [0] = false, [1] = false, [2] = false, [6] = true, [7] = true }
		local deps = { [0] = {}, [1] = {}, [2] = { [0] = true }, [6] = { [2] = true }, [7] = { [2] = true } }
		local alive = { [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true }
		local empty = { [0] = false, [1] = false, [2] = false, [6] = true, [7] = true }
		-- the first new band fits the budget (6 alive + 1 building)
		local kind, id = TerrainMath.planStep(pending, covered, deps, alive, empty, 6, 6)
		t.expectEqual(kind, "build")
		t.expectEqual(id, 0)
		-- it is up (7 alive): the second one would need an 8th mesh, so a band going away is dropped first
		alive[0], covered[0], pending[0] = true, true, nil
		kind, id = TerrainMath.planStep(pending, covered, deps, alive, empty, 7, 6)
		t.expectEqual(kind, "retire")
		t.expectEqual(id, 7) -- the band going away with the highest id
		-- (the old order built it anyway: 2 new ids in a row = 8 meshes, refused by the budget)
		-- ready bands: going away first, then replaced, then new
		local p2 = { [1] = true, [3] = true, [9] = true }
		local c2 = { [1] = false, [3] = false, [9] = true }
		local d2 = { [1] = {}, [3] = {}, [9] = {} }
		local a2 = { [3] = true, [9] = true }
		local e2 = { [1] = false, [3] = false, [9] = true }
		kind, id = TerrainMath.planStep(p2, c2, d2, a2, e2, 2, 6)
		t.expectEqual(id, 9)
		p2[9] = nil
		kind, id = TerrainMath.planStep(p2, c2, d2, a2, e2, 2, 6)
		t.expectEqual(id, 3)
		-- bands waiting on each other: a union, on an existing band
		local p3 = { [0] = true, [1] = true }
		local c3 = { [0] = false, [1] = false }
		local d3 = { [0] = { [1] = true }, [1] = { [0] = true } }
		kind, id = TerrainMath.planStep(p3, c3, d3, { [1] = true }, { [0] = false, [1] = false }, 1, 6)
		t.expectEqual(kind, "union")
		t.expectEqual(id, 1)
		-- nothing pending: nothing to do
		kind, id = TerrainMath.planStep({}, {}, {}, {}, {}, 0, 6)
		t.expectEqual(kind, nil)
	end)

	t.test("nearTarget: the launch site stays inside the near square while the camera is near it", function()
		local config = TerrainMath.config(HOMEWORLD) :: TerrainMath.Config
		local R = config.radius
		local site = Vec3d.new(R, 0, 0)
		for _, offset in { 0, 150, 350, 520, 1200 } do
			local cam = Vec3d.new(R + 300, offset * 0.6, offset)
			local target = TerrainMath.nearTarget(config, cam, site, KEEP_HALF, NEAR_HALF, KEEP_RANGE)
			t.expectNear(Vec3d.length(target), R, 1e-6)
			local near = TerrainMath.newNear(config, target, NEAR_HALF, NEAR_MAX_LEAF)
			local su, sv = TerrainMath.nearOffset(near, site)
			local cu, cv = TerrainMath.nearOffset(near, Vec3d.scale(Vec3d.normalize(cam), R))
			if offset <= NEAR_HALF - KEEP_HALF + KEEP_RANGE then
				t.expectTrue(
					math.max(math.abs(su), math.abs(sv)) + KEEP_HALF <= NEAR_HALF + 1,
					`site inside at {offset}`
				)
				t.expectTrue(
					math.max(math.abs(cu), math.abs(cv)) <= KEEP_RANGE + 1,
					`camera stays well inside at {offset}`
				)
			else
				t.expectTrue(math.max(math.abs(cu), math.abs(cv)) < 1, `centred on the camera at {offset}`)
			end
		end
		-- no keep square: the ground under the camera
		local cam = Vec3d.new(R + 50, 3000, -2000)
		local target = TerrainMath.nearTarget(config, cam, nil, 0, NEAR_HALF, KEEP_RANGE)
		t.expectNear(Vec3d.distance(target, Vec3d.scale(Vec3d.normalize(cam), R)), 0, 1e-6)
	end)

	t.test("scaleStep: at or below the terrain's factor, in steps, back to 1 at once", function()
		local ratio = 0.94
		local applied = 1
		local rescales = 0
		local wanted = 1
		while wanted > 0.05 do
			wanted *= 0.995
			local nextScale = TerrainMath.scaleStep(wanted, applied, ratio)
			t.expectTrue(nextScale <= wanted + 1e-12, "never behind the terrain")
			t.expectTrue(nextScale >= wanted * ratio - 1e-12, "at most one step in front")
			if nextScale ~= applied then
				rescales += 1
			end
			applied = nextScale
		end
		t.expectTrue(rescales <= 52, `rescales {rescales}`)
		-- small wobble does not flicker between steps
		local held = applied
		for _ = 1, 20 do
			applied = TerrainMath.scaleStep(held / ratio, applied, ratio)
		end
		t.expectEqual(applied, held)
		t.expectEqual(TerrainMath.scaleStep(1, 0.3, ratio), 1)
	end)

	t.test("collision cells: keys round-trip; a cell crossing changes only the edge cells", function()
		t.expectEqual(select("#", TerrainMath.cellOf(TerrainMath.cellKey(5, 12345, 678))), 3)
		local face, i, j = TerrainMath.cellOf(TerrainMath.cellKey(5, 12345, 678))
		t.expectEqual(face, 5)
		t.expectEqual(i, 12345)
		t.expectEqual(j, 678)
		local config = TerrainMath.config(HOMEWORLD) :: TerrainMath.Config
		local R = config.radius
		local radius = 70
		local a = TerrainMath.collisionCells(config, Vec3d.new(R, 300, 500), radius, {})
		local b = TerrainMath.collisionCells(config, Vec3d.new(R, 300 + config.cellArc, 500), radius, {})
		local inA: { [number]: boolean } = {}
		for _, key in a do
			inA[key] = true
		end
		local changed = 0
		local inB: { [number]: boolean } = {}
		for _, key in b do
			inB[key] = true
			if not inA[key] then
				changed += 1
			end
		end
		for _, key in a do
			if not inB[key] then
				changed += 1
			end
		end
		t.expectTrue(#a >= 40, `{#a} cells`)
		t.expectTrue(changed > 0 and changed <= #a / 2, `{changed} of {#a} cells change`)
		-- collisionTriangles is the same ground, two triangles per cell
		local triangles = TerrainMath.collisionTriangles(config, Vec3d.new(R, 300, 500), radius, {})
		t.expectEqual(#triangles, 2 * #a)
	end)
end
