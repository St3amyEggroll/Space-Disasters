--!strict
-- Tests for Biome: determinism, colour ranges, the launch-site guarantees, global coverage and the texture-space
-- mapping shared by the scaled-space patches and the ground tiles.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)

--============================================================================
-- Tunables
--============================================================================
local SPHERE_SAMPLES = 3000 -- Fibonacci-sphere directions for coverage tests
local SITE_FLAT_RADIUS_M = 3000 -- the base must sit on grass at least this far around the pad
local COAST_MIN_M = 3500 -- an ocean must be reached going east between these distances
local COAST_MAX_M = 14000
local EPSILON = 1e-9
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD
local MOON = Bodies.MOON

local function fibonacci(i: number, count: number): (number, number, number)
	local golden = math.pi * (3 - math.sqrt(5))
	local y = 1 - (i + 0.5) * 2 / count
	local r = math.sqrt(1 - y * y)
	return r * math.cos(golden * i), y, r * math.sin(golden * i)
end

local function kindCounts(bodyId: number): { [string]: number }
	local counts: { [string]: number } = {}
	for i = 0, SPHERE_SAMPLES - 1 do
		local x, y, z = fibonacci(i, SPHERE_SAMPLES)
		local _, _, _, kind = Biome.sample(bodyId, x, y, z)
		counts[kind] = (counts[kind] or 0) + 1
	end
	return counts
end

-- Is unit direction d inside patch `m` (row-major rotation)? Returns its (s, t) there.
local function patchParam(m: { number }, dx: number, dy: number, dz: number): (boolean, number, number)
	-- local = M^T d
	local lx = m[1] * dx + m[4] * dy + m[7] * dz
	local ly = m[2] * dx + m[5] * dy + m[8] * dz
	local lz = m[3] * dx + m[6] * dy + m[9] * dz
	if ly <= 0 then
		return false, 0, 0
	end
	local cx, cz = lx / ly, lz / ly
	if cx < -1 - 1e-9 or cx > 1e-9 or cz < -1 - 1e-9 or cz > 1e-9 then
		return false, 0, 0
	end
	return true, Biome.cubeToParam(cx), Biome.cubeToParam(cz)
end

return function(t: TestKit.Context)
	t.test("biome samples are deterministic and colours stay in 0..1", function()
		for _, bodyId in { HOMEWORLD, MOON } do
			for i = 0, 499 do
				local x, y, z = fibonacci(i, 500)
				local r, g, b, kind = Biome.sample(bodyId, x, y, z)
				local r2, g2, b2, kind2 = Biome.sample(bodyId, x, y, z)
				t.expectEqual(r, r2)
				t.expectEqual(g, g2)
				t.expectEqual(b, b2)
				t.expectEqual(kind, kind2)
				for _, c in { r, g, b } do
					t.expectTrue(c >= 0 and c <= 1, "colour out of range")
				end
				local alpha = Biome.clouds(bodyId, x, y, z)
				t.expectTrue(alpha >= 0 and alpha <= 1, "cloud alpha out of range")
			end
		end
		t.expectEqual(Biome.clouds(MOON, 0, 1, 0), 0)
		t.expectTrue(Biome.hasClouds(HOMEWORLD))
		t.expectTrue(not Biome.hasClouds(MOON))
	end)

	t.test("the launch site is flat grassland with a coast to the east", function()
		local radius = Bodies.get(HOMEWORLD).Radius
		local _, _, _, kind = Biome.sample(HOMEWORLD, 1, 0, 0)
		t.expectEqual(kind, "Grass")
		-- rings around the pad
		for _, metres in { 300, 1000, 2000, SITE_FLAT_RADIUS_M } do
			local a = metres / radius
			for k = 0, 15 do
				local phi = k * math.pi / 8
				local x, y, z = math.cos(a), math.sin(a) * math.cos(phi), math.sin(a) * math.sin(phi)
				local _, _, _, ringKind = Biome.sample(HOMEWORLD, x, y, z)
				t.expectEqual(ringKind, "Grass", `{metres} m from the pad at azimuth {k}`)
			end
		end
		-- east (+Z) of lat 0 / lon 0
		local foundOcean = false
		for metres = COAST_MIN_M, COAST_MAX_M, 250 do
			local a = metres / radius
			local _, _, _, eastKind = Biome.sample(HOMEWORLD, math.cos(a), 0, math.sin(a))
			if eastKind == "Ocean" then
				foundOcean = true
				break
			end
		end
		t.expectTrue(foundOcean, "no coast east of the launch site")
	end)

	t.test("Earth has oceans, land and polar ice", function()
		local counts = kindCounts(HOMEWORLD)
		local ocean = (counts.Ocean or 0) / SPHERE_SAMPLES
		t.expectTrue(ocean > 0.5 and ocean < 0.7, `ocean fraction {ocean}`)
		for _, kind in { "Grass", "Forest", "Desert", "Rock", "Snow", "Beach" } do
			t.expectTrue((counts[kind] or 0) > 0, "no " .. kind)
		end
		local _, _, _, north = Biome.sample(HOMEWORLD, 0, 1, 0)
		local _, _, _, south = Biome.sample(HOMEWORLD, 0, -1, 0)
		t.expectEqual(north, "Snow")
		t.expectEqual(south, "Snow")
		local _, _, _, nearPole = Biome.sample(HOMEWORLD, 0.2, 0.979, 0)
		t.expectEqual(nearPole, "Snow")
	end)

	t.test("Mun has maria, highlands and craters", function()
		local counts = kindCounts(MOON)
		for _, kind in { "Mare", "Highland", "Crater" } do
			t.expectTrue((counts[kind] or 0) > SPHERE_SAMPLES * 0.05, "too little " .. kind)
		end
		t.expectEqual(counts.Ocean, nil)
	end)

	t.test("average colours are plausible", function()
		local r, g, b = Biome.averageColor(HOMEWORLD)
		t.expectTrue(b > r, "Earth should look blue-ish from afar")
		local mr, mg, mb = Biome.averageColor(MOON)
		t.expectTrue(math.abs(mr - mg) < 0.1 and math.abs(mg - mb) < 0.1, "Mun should be grey")
		t.expectTrue(g >= 0 and g <= 1)
	end)

	t.test("props: densities and kinds", function()
		t.expectEqual(Biome.propDensity("Ocean"), 0)
		t.expectEqual(Biome.propKind("Ocean", 0.5), nil)
		t.expectTrue(Biome.propDensity("Forest") > Biome.propDensity("Grass"))
		t.expectEqual(Biome.propKind("Desert", 0), "Cactus")
		for _, kind in { "Grass", "Forest", "Desert", "Rock", "Snow", "Beach", "Mare", "Highland", "Crater", "Ray" } do
			for roll = 0, 0.999, 0.111 do
				t.expectTrue(Biome.propKind(kind :: Biome.Kind, roll) ~= nil, kind)
			end
		end
		local h = Biome.hash01(12, -7, 99, 5)
		t.expectEqual(h, Biome.hash01(12, -7, 99, 5))
		t.expectTrue(h >= 0 and h < 1)
		t.expectTrue(h ~= Biome.hash01(12, -7, 98, 5))
	end)

	t.test("texture space: UV mapping round-trips", function()
		for _, s in { 0, 0.25, 0.5, 1 } do
			for _, tt in { 0, 0.3, 1 } do
				local u, v = Biome.paramToUV(s, tt)
				t.expectTrue(u > 0 and u < 1 and v > 0 and v < 1, "UV outside the inset")
				local s2, t2 = Biome.uvToParam(u, v)
				t.expectNear(s2, s, EPSILON)
				t.expectNear(t2, tt, EPSILON)
			end
		end
		for _, c in { -1, -0.7, -0.2, 0 } do
			t.expectNear(Biome.paramToCube(Biome.cubeToParam(c)), c, EPSILON)
		end
	end)

	t.test("cube rotations: 24 distinct proper rotations covering the sphere", function()
		local rotations = Biome.cubeRotations()
		t.expectEqual(#rotations, 24)
		local seen: { [string]: boolean } = {}
		for _, m in rotations do
			local det = m[1] * (m[5] * m[9] - m[6] * m[8])
				- m[2] * (m[4] * m[9] - m[6] * m[7])
				+ m[3] * (m[4] * m[8] - m[5] * m[7])
			t.expectEqual(det, 1)
			local key = table.concat(m, ",")
			t.expectTrue(not seen[key], "duplicate rotation")
			seen[key] = true
		end
		-- every direction is covered by at least one patch
		for i = 0, 199 do
			local x, y, z = fibonacci(i, 200)
			local covered = false
			for _, m in rotations do
				if patchParam(m, x, y, z) then
					covered = true
					break
				end
			end
			t.expectTrue(covered, "direction not covered by any patch")
		end
	end)

	t.test("texture space: adjacent patch edges sample the same directions", function()
		local rotations = Biome.cubeRotations()
		local edgeParams = { { 0, -1 }, { 1, -1 }, { -1, 0 }, { -1, 1 } } -- (s fixed or -1 = free, t fixed or free)
		for index, m in rotations do
			for _, edge in edgeParams do
				for _, along in { 0.17, 0.5, 0.83 } do
					local s = if edge[1] >= 0 then edge[1] else along
					local tt = if edge[2] >= 0 then edge[2] else along
					local dx, dy, dz = Biome.patchDirection(m, s, tt)
					t.expectNear(dx * dx + dy * dy + dz * dz, 1, 1e-12)
					local matches = 0
					for other, mo in rotations do
						if other ~= index then
							local inside, so, to = patchParam(mo, dx, dy, dz)
							if inside then
								matches += 1
								-- the neighbour sees this point on its own edge and maps it back to the same direction
								local onEdge = math.min(so, 1 - so, to, 1 - to)
								t.expectNear(onEdge, 0, 1e-9, "shared point is not on the neighbour's edge")
								local ox, oy, oz = Biome.patchDirection(mo, so, to)
								t.expectNear(ox, dx, 1e-12)
								t.expectNear(oy, dy, 1e-12)
								t.expectNear(oz, dz, 1e-12)
								local r1, g1, b1 = Biome.sample(HOMEWORLD, dx, dy, dz)
								local r2, g2, b2 = Biome.sample(HOMEWORLD, ox, oy, oz)
								t.expectNear(r1, r2, 1e-9)
								t.expectNear(g1, g2, 1e-9)
								t.expectNear(b1, b2, 1e-9)
							end
						end
					end
					t.expectEqual(matches, 1, `patch {index} edge ({s}, {tt}) shared by {matches} other patches`)
				end
			end
		end
	end)

	t.test("painters: patch and rect jobs fill the buffer with the mapped directions", function()
		local size = 32
		local buf = buffer.create(size * size * 4)
		local painter = Biome.newPainter(size, 8, buf)
		local rotations = Biome.cubeRotations()
		Biome.beginPatch(painter, HOMEWORLD, "Ground", rotations[5], 1)
		for _, st in { { 0, 0 }, { 1, 0.5 }, { 0.3, 1 } } do
			local px, py, pz = Biome.painterDirection(painter, st[1], st[2])
			local ex, ey, ez = Biome.patchDirection(rotations[5], st[1], st[2])
			t.expectNear(px, ex, 1e-12)
			t.expectNear(py, ey, 1e-12)
			t.expectNear(pz, ez, 1e-12)
		end
		local steps = 0
		while not Biome.paintStep(painter) do
			steps += 1
			t.expectTrue(steps < 1000, "painter never finishes")
		end
		t.expectEqual(painter.pixelRow, size)
		-- every pixel is opaque
		for i = 0, size * size - 1 do
			t.expectEqual(buffer.readu8(buf, i * 4 + 3), 255)
		end

		-- the base tile (face +X centre, flat on the pad): grass, no ocean
		local radius = Bodies.get(HOMEWORLD).Radius
		Biome.beginRect(painter, HOMEWORLD, "Ground", radius, 0, 0, 0, 0, 1, 0, 1, 0, 2048, 2048, 2)
		local cx, cy, cz = Biome.painterDirection(painter, 0.5, 0.5)
		t.expectNear(cx, 1, 1e-12)
		t.expectNear(cy, 0, 1e-12)
		t.expectNear(cz, 0, 1e-12)
		local ax = Biome.painterDirection(painter, 1, 0.5)
		t.expectTrue(ax < 1)
		while not Biome.paintStep(painter) do
		end
		t.expectEqual(painter.oceanPixels, 0)
		t.expectTrue(painter.sumG > painter.sumB, "the pad tile should be green")

		-- clouds have transparent and opaque-ish pixels somewhere on the planet
		local minA, maxA = 255, 0
		for _, m in rotations do
			Biome.beginPatch(painter, HOMEWORLD, "Clouds", m, 1)
			while not Biome.paintStep(painter) do
			end
			for i = 0, size * size - 1 do
				local a = buffer.readu8(buf, i * 4 + 3)
				minA, maxA = math.min(minA, a), math.max(maxA, a)
			end
		end
		t.expectEqual(minA, 0)
		t.expectTrue(maxA > 150, "no thick clouds anywhere")
	end)
end
