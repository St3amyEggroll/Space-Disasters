--!strict
-- CHANGED (See-through fix): tests for the see-through fix: every LOD seam inside a cube face stitched with short
-- skirts (TerrainMath.seamCode), and the scaled bands' bulge culling (bulgeOccluder / occluded / cullChunk): what it
-- leaves out is hidden by the drawn ground for every camera within the reach, and it does leave out the slopes behind
-- the horizon bulge that face the camera.

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
-- Tunables (the values Render/TerrainMesh uses)
--============================================================================
local NEAR_HALF = 760
local NEAR_MAX_LEAF = 400
local BAND_COUNT = 4 -- High / Medium
local PART_LIMIT = 2040
local FAR_LIMIT = 17000
local BUDGET = 0.85 * 20000
local HIGH = { splitK = 1.4, mergeK = 1.4 * 1.15, maxLeaves = 320 }
local REACH = 25 -- m: TerrainMesh's CULL_REACH_MIN
local CAMERAS_PER_CHECK = 2 -- moved cameras each hidden triangle is ray-cast from
local CHECKED_TRIANGLES = 16 -- hidden triangles ray-cast per scene
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD
local MOON = Bodies.MOON

-- a ground point (site-plane metres x / z from the launch site) on Earth, `height` m above the ground
local function earthCamera(x: number, z: number, height: number): Vec3d
	local radius = Bodies.get(HOMEWORLD).Radius
	local up = Frames.surfaceUp(0, 0)
	local frame = Frames.new(HOMEWORLD, Vec3d.scale(up, radius), Frames.surfaceRotation(up), Vector3.zero)
	local dir = Vec3d.normalize(Frames.pointFromWorkspace(frame, Vector3.new(x, 0, z)))
	local ground = SurfaceHeight.groundPoint(HOMEWORLD, dir)
	return Vec3d.add(ground, Vec3d.scale(dir, height))
end

type Scene = {
	config: TerrainMath.Config,
	cam: Vec3d,
	leaves: { TerrainMath.Node },
	band: { [number]: number },
	code: { [number]: number },
	drawn: { [number]: TerrainMath.Chunk }, -- leaf key -> its stitched chunk (as drawn)
}

-- the plan TerrainMesh would make for a camera: selection, ring bands, seam codes and the drawn (stitched) chunks
local function scene(bodyId: number, cam: Vec3d): Scene
	local config = TerrainMath.config(bodyId) :: TerrainMath.Config
	local near = TerrainMath.newNear(config, cam, NEAR_HALF, NEAR_MAX_LEAF)
	local rings: TerrainMath.RingContext = {
		cam = cam,
		budget = BUDGET,
		farLimit = FAR_LIMIT,
		partLimit = PART_LIMIT,
		previous = nil,
	}
	local height = Vec3d.length(cam) - config.radius
	local params: TerrainMath.Params = {
		splitK = HIGH.splitK,
		mergeK = HIGH.mergeK,
		maxLeaves = HIGH.maxLeaves,
		bandCount = BAND_COUNT,
		horizonLead = math.max(30, 0.15 * height),
		near = near,
		rings = rings,
	}
	local selection = TerrainMath.select(config, cam, params, nil)
	local band = TerrainMath.assignBands(config, selection.leaves, BAND_COUNT, near, rings)
	local under: { [number]: { [number]: boolean } } = {}
	for _, node in selection.leaves do
		local face, depth, x, y = node.face, node.depth, node.x, node.y
		while depth > 0 do
			depth -= 1
			x //= 2
			y //= 2
			local key = TerrainMath.nodeKey(config.bodyId, face, depth, x, y)
			local set = under[key] or {}
			set[band[node.key]] = true
			under[key] = set
		end
	end
	local code: { [number]: number } = {}
	local drawn: { [number]: TerrainMath.Chunk } = {}
	for _, node in selection.leaves do
		code[node.key] = TerrainMath.seamCode(config, node, band, under)
		drawn[node.key] = TerrainMath.stitchChunk(config, node, TerrainMath.buildChunk(config, node), code[node.key])
	end
	return {
		config = config,
		cam = cam,
		leaves = selection.leaves,
		band = band,
		code = code,
		drawn = drawn,
	}
end

local function vertexOf(c: TerrainMath.Chunk, v: number): Vec3d
	local x, y, z = TerrainMath.chunkVertex(c, v)
	return Vec3d.new(c.ox + x, c.oy + y, c.oz + z)
end

-- Möller-Trumbore: distance along the unit ray (o, d) to triangle (a, b, c), or nil
local function rayHit(o: Vec3d, d: Vec3d, a: Vec3d, b: Vec3d, c: Vec3d): number?
	local e1, e2 = Vec3d.sub(b, a), Vec3d.sub(c, a)
	local p = Vec3d.cross(d, e2)
	local det = Vec3d.dot(e1, p)
	if math.abs(det) < 1e-12 then
		return nil
	end
	local inv = 1 / det
	local s = Vec3d.sub(o, a)
	local u = Vec3d.dot(s, p) * inv
	if u < -1e-9 or u > 1 + 1e-9 then
		return nil
	end
	local q = Vec3d.cross(s, e1)
	local v = Vec3d.dot(d, q) * inv
	if v < -1e-9 or u + v > 1 + 1e-9 then
		return nil
	end
	local t = Vec3d.dot(e2, q) * inv
	return if t > 0 then t else nil
end

type Tri = { a: Vec3d, b: Vec3d, c: Vec3d, centre: Vec3d, size: number }

local function triangles(s: Scene, keep: (number) -> boolean): { Tri }
	local list: { Tri } = {}
	for _, node in s.leaves do
		if keep(s.band[node.key]) then
			local c = s.drawn[node.key]
			for i = 1, #c.tris, 3 do
				local a, b, cc = vertexOf(c, c.tris[i]), vertexOf(c, c.tris[i + 1]), vertexOf(c, c.tris[i + 2])
				local centre = Vec3d.scale(Vec3d.add(Vec3d.add(a, b), cc), 1 / 3)
				local size = math.max(Vec3d.distance(a, centre), Vec3d.distance(b, centre), Vec3d.distance(cc, centre))
				table.insert(list, { a = a, b = b, c = cc, centre = centre, size = size })
			end
		end
	end
	return list
end

--[[
	Is `target` hidden from camera `from` by the drawn ground (`ground`: every drawn triangle)? A ray cast toward it
	must hit some triangle clearly before it (triangles far off the ray are skipped by their bounding sphere).
]]
local function hiddenFrom(from: Vec3d, target: Vec3d, ground: { Tri }): boolean
	local delta = Vec3d.sub(target, from)
	local length = Vec3d.length(delta)
	local dir = Vec3d.scale(delta, 1 / length)
	for _, tri in ground do
		local rel = Vec3d.sub(tri.centre, from)
		local along = Vec3d.dot(rel, dir)
		if along > 0 and along < length + tri.size then
			local off = Vec3d.length(Vec3d.sub(rel, Vec3d.scale(dir, along)))
			if off <= tri.size + 1e-6 then
				local t = rayHit(from, dir, tri.a, tri.b, tri.c)
				if t and t < length - 0.5 then
					return true
				end
			end
		end
	end
	return false
end

-- cameras within `reach` of `cam` (up, down, sideways and toward `target`)
local function movedCameras(cam: Vec3d, target: Vec3d, reach: number): { Vec3d }
	local up = Vec3d.normalize(cam)
	local toward = Vec3d.normalize(Vec3d.sub(target, cam))
	local side = Vec3d.normalize(Vec3d.cross(up, toward))
	local list = { cam, Vec3d.add(cam, Vec3d.scale(up, 0.95 * reach)) }
	table.insert(list, Vec3d.add(cam, Vec3d.scale(Vec3d.normalize(Vec3d.add(toward, side)), 0.95 * reach)))
	table.insert(list, Vec3d.add(cam, Vec3d.scale(Vec3d.normalize(Vec3d.sub(up, side)), 0.95 * reach)))
	return list
end

return function(t: TestKit.Context)
	t.test("seams: every LOD seam inside a cube face is stitched and keeps only a short skirt", function()
		local cases: { { bodyId: number, cam: Vec3d } } = {
			{ bodyId = HOMEWORLD, cam = earthCamera(0, 0, 250) },
			{ bodyId = HOMEWORLD, cam = earthCamera(-6000, -10500, 40) },
			{ bodyId = MOON, cam = Vec3d.scale(Vec3d.normalize(Vec3d.new(0.6, -0.5, 0.6)), 20000 + 300) },
		}
		for _, case in cases do
			local s = scene(case.bodyId, case.cam)
			local config = s.config
			local stitched = 0
			for _, node in s.leaves do
				local code = s.code[node.key]
				local count = 2 ^ node.depth
				-- a union's new leaves: the same stitches with the plain skirts back
				local plain = TerrainMath.plainSkirts(code)
				for edge = 1, 4 do
					local e, p = math.floor(code / 16 ^ (edge - 1)) % 16, math.floor(plain / 16 ^ (edge - 1)) % 16
					t.expectEqual(p, e % 8, "plainSkirts keeps the stitch, drops the short skirt")
				end
				for edge = 1, 4 do
					local e = math.floor(code / 16 ^ (edge - 1)) % 16
					local x, y = node.x, node.y
					if edge == 1 then
						x -= 1
					elseif edge == 2 then
						x += 1
					elseif edge == 3 then
						y -= 1
					else
						y += 1
					end
					local inFace = x >= 0 and y >= 0 and x < count and y < count
					t.expectEqual(e >= 8, inFace, "short skirt exactly on in-face edges")
					if inFace then
						-- the coarser leaf over the neighbour node, if any: the stitch spans the level difference
						local depth, ax, ay, levels, found = node.depth, x, y, 0, false
						while depth > 0 and not found do
							depth -= 1
							ax //= 2
							ay //= 2
							levels += 1
							found = s.band[TerrainMath.nodeKey(config.bodyId, node.face, depth, ax, ay)] ~= nil
						end
						local same = s.band[TerrainMath.nodeKey(config.bodyId, node.face, node.depth, x, y)] ~= nil
						if found and not same then
							t.expectEqual(e % 8, math.min(levels, 7), "stitched onto the coarser neighbour")
							stitched += 1
						else
							t.expectEqual(e % 8, 0, "nothing to stitch")
						end
					end
				end
			end
			t.expectTrue(stitched > 0, "the selection has LOD seams")
		end
	end)

	t.test("bulge occluder: what it hides stays below the ground for every camera within the reach", function()
		for _, bodyId in { HOMEWORLD, MOON } do
			local config = TerrainMath.config(bodyId) :: TerrainMath.Config
			local up = if bodyId == HOMEWORLD then Frames.surfaceUp(0, 0) else Vec3d.new(0.6, -0.5, 0.6)
			up = Vec3d.normalize(up)
			local side = Vec3d.normalize(Vec3d.cross(up, Vec3d.new(0, 0, 1)))
			for _, height in { 20, 250, 2000 } do
				local cam = Vec3d.add(SurfaceHeight.groundPoint(bodyId, up), Vec3d.scale(up, height))
				local o = TerrainMath.bulgeOccluder(config, cam, REACH) :: TerrainMath.Occluder
				t.expectTrue(o ~= nil, "an occluder above the ground")
				local lowest = config.radius + config.minHeight
				local hidden, visible = 0, 0
				for step = 1, 80 do
					-- out to three times the horizon angle of the lowest ground
					local angle = step / 80 * 3 * math.sqrt(2 * (height - config.minHeight + REACH) / config.radius)
					local dir =
						Vec3d.normalize(Vec3d.add(Vec3d.scale(up, math.cos(angle)), Vec3d.scale(side, math.sin(angle))))
					local p = SurfaceHeight.groundPoint(bodyId, dir)
					if TerrainMath.occluded(o, p.x, p.y, p.z) then
						hidden += 1
						for _, c in movedCameras(cam, p, REACH) do
							-- the segment from that camera dips below the lowest ground
							local d = Vec3d.sub(p, c)
							local tStar = math.clamp(-Vec3d.dot(c, d) / Vec3d.dot(d, d), 0, 1)
							local closest = Vec3d.length(Vec3d.add(c, Vec3d.scale(d, tStar)))
							t.expectTrue(closest < lowest, `hidden from a moved camera ({closest - lowest} m)`)
						end
					else
						visible += 1
					end
				end
				t.expectTrue(
					hidden > 0 and visible > 0,
					`{bodyId} at {height} m: both hidden ({hidden}) and visible ({visible}) ground`
				)
				-- ground right below the camera is never hidden
				local below = SurfaceHeight.groundPoint(bodyId, up)
				t.expectTrue(not TerrainMath.occluded(o, below.x, below.y, below.z), "the ground below")
			end
		end
	end)

	t.test("cullChunk: a far leaf behind the bulge loses its hidden triangles, the rest stays consistent", function()
		local s = scene(HOMEWORLD, earthCamera(0, 300, 250))
		local o = TerrainMath.bulgeOccluder(s.config, s.cam, REACH) :: TerrainMath.Occluder
		local culledAll, keptNear = 0, 0
		for _, node in s.leaves do
			local chunk = s.drawn[node.key]
			local out, culled = TerrainMath.cullChunk(chunk, o)
			culledAll += culled
			if culled == 0 then
				t.expectTrue(out == chunk, "nothing hidden: the chunk itself")
				if s.band[node.key] == TerrainMath.NEAR_BAND then
					keptNear += 1
				end
			else
				t.expectEqual(out.triangleCount + culled, chunk.triangleCount, "every triangle kept or culled")
				t.expectEqual(#out.tris, 3 * out.triangleCount)
				local used: { [number]: boolean } = {}
				for _, v in out.tris do
					t.expectTrue(v >= 1 and v <= out.vertexCount, "index within the kept vertices")
					used[v] = true
				end
				for v = 1, out.vertexCount do
					t.expectTrue(used[v] == true, "only used vertices are kept")
					local x, y, z = TerrainMath.chunkVertex(out, v)
					t.expectTrue(x >= out.minX and x <= out.maxX and y >= out.minY and y <= out.maxY, "box")
					t.expectTrue(z >= out.minZ and z <= out.maxZ, "box z")
				end
			end
		end
		t.expectTrue(culledAll > 500, `ground behind the horizon is left out ({culledAll} triangles)`)
		t.expectTrue(keptNear > 0, "the near band is whole")
	end)

	t.test("bulge culling: what a scaled band leaves out is hidden by the drawn ground from moved cameras", function()
		-- 250 m over the site (Steamy's view), on the plain near the western mountains, and 1.5 km up
		for _, cam in { earthCamera(0, 280, 250), earthCamera(-14000, 1000, 30), earthCamera(0, 300, 1500) } do
			local s = scene(HOMEWORLD, cam)
			local o = TerrainMath.bulgeOccluder(s.config, s.cam, REACH) :: TerrainMath.Occluder
			local ground = triangles(s, function(): boolean
				return true
			end)
			local scaled = triangles(s, function(band: number): boolean
				return band ~= TerrainMath.NEAR_BAND
			end)
			local hidden: { Tri } = {}
			for _, tri in scaled do
				if TerrainMath.triangleHidden(o, tri.a, tri.b, tri.c) then
					table.insert(hidden, tri)
				end
			end
			t.expectTrue(#hidden > 20, `slopes behind the bulge face the camera ({#hidden})`)
			-- a spread sample is hidden by the drawn ground from the camera and from cameras moved within the reach
			local stepSize = math.max(1, #hidden // CHECKED_TRIANGLES)
			for index = 1, #hidden, stepSize do
				local tri = hidden[index]
				for n, c in movedCameras(cam, tri.centre, REACH) do
					if n > CAMERAS_PER_CHECK + 1 then
						break
					end
					for _, p in { tri.a, tri.b, tri.c, tri.centre } do
						t.expectTrue(hiddenFrom(c, p, ground), "a left-out triangle is hidden by the drawn ground")
					end
				end
			end
		end
	end)
end
