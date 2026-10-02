--!strict
-- CHANGED (Planet detail): tests for the detailed planet seen from orbit: Earth's small-scale features
-- (Sim/BiomeDetail through Biome and Relief: lakes lie flat, nothing changes around the launch site), the relief
-- shade baked into the textures, the padded / chunked painters, and the per-tier texture, detail-slot, atmosphere
-- and cloud settings of Render/PlanetDetail.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local BiomeDetail = require(ReplicatedStorage.Shared.Sim.BiomeDetail)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Relief = require(ReplicatedStorage.Shared.Sim.Relief)
local Render = game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render
local PlanetDetail = require(Render.PlanetDetail)

--============================================================================
-- Tunables
--============================================================================
local SPHERE_SAMPLES = 12000 -- Fibonacci directions for the feature census
local LAKE_PROBES = 40 -- lake points checked for flat water
local LAKE_FLAT_STEP_M = 15 -- neighbour distance for the flat-water check
local LAKE_FLAT_TOLERANCE_M = 0.5 -- the level follows the smooth continent elevation: median slope ~0.5%, max ~2.5%
local QUIET_RADIUS_M = 5000 -- no new feature this close to the pad
local MB = 1024 * 1024
-- CHANGED (Memory budget): EditableImage memory per tier (Render/EditableBudget holds it with the terrain meshes)
local TIER_BUDGET_BYTES = { Low = 4 * MB, Medium = 6 * MB, High = 14 * MB }
local IMAGE_CAP = 112 -- images ScaledSpace may hold at once
--============================================================================

local HOMEWORLD = Bodies.HOMEWORLD
local MOON = Bodies.MOON
local EARTH_R = Bodies.get(HOMEWORLD).Radius
local TIERS: { PlanetDetail.Tier } = { "Low", "Medium", "High" }

local function fibonacci(i: number, count: number): (number, number, number)
	local golden = math.pi * (3 - math.sqrt(5))
	local y = 1 - (i + 0.5) * 2 / count
	local r = math.sqrt(1 - y * y)
	return r * math.cos(golden * i), y, r * math.sin(golden * i)
end

-- Unit direction `metres` along the surface from (x, y, z) toward +Y (or +X near the poles), turned by `phi`.
local function around(x: number, y: number, z: number, metres: number, phi: number): (number, number, number)
	local rx, ry, rz = 0, 1, 0
	if math.abs(y) > 0.9 then
		rx, ry, rz = 1, 0, 0
	end
	local ax, ay, az = ry * z - rz * y, rz * x - rx * z, rx * y - ry * x
	local al = math.sqrt(ax * ax + ay * ay + az * az)
	ax, ay, az = ax / al, ay / al, az / al
	local bx, by, bz = y * az - z * ay, z * ax - x * az, x * ay - y * ax
	local a = metres / EARTH_R
	local tx = ax * math.cos(phi) + bx * math.sin(phi)
	local ty = ay * math.cos(phi) + by * math.sin(phi)
	local tz = az * math.cos(phi) + bz * math.sin(phi)
	return x * math.cos(a) + tx * math.sin(a), y * math.cos(a) + ty * math.sin(a), z * math.cos(a) + tz * math.sin(a)
end

local function paintAll(painter: Biome.Painter): number
	local steps = 0
	while not Biome.paintStep(painter) do
		steps += 1
		assert(steps < 1e6, "painter never finishes")
	end
	return steps + 1
end

return function(t: TestKit.Context)
	t.test("Earth gets lakes and rivers, and none of the new features near the launch site", function()
		local land, lakes, lakeCores = 0, 0, 0
		for i = 0, SPHERE_SAMPLES - 1 do
			local x, y, z = fibonacci(i, SPHERE_SAMPLES)
			local _, _, _, kind = Biome.sample(HOMEWORLD, x, y, z)
			if kind ~= "Ocean" then
				land += 1
			end
			if kind == "Lake" then
				lakes += 1
				local _, _, lake = Biome.reliefFields(HOMEWORLD, x, y, z)
				if lake >= 0 then
					lakeCores += 1
				end
			end
		end
		local share = lakes / land
		t.expectTrue(share > 0.002 and share < 0.06, `lakes and rivers cover {share} of the land`)
		t.expectTrue(lakeCores > 0 and lakeCores < lakes, `lakes {lakeCores}, lakes and rivers {lakes}`)
		-- the site keeps its look and shape: no feature within QUIET_RADIUS_M of the pad
		t.expectEqual(BiomeDetail.featureWeight(1, 0, 0), 0)
		for _, metres in { 500, 2000, 3500, QUIET_RADIUS_M } do
			for k = 0, 23 do
				local x, y, z = around(1, 0, 0, metres, k * math.pi / 12)
				t.expectEqual(BiomeDetail.featureWeight(x, y, z), 0)
				local _, _, lake = Biome.reliefFields(HOMEWORLD, x, y, z)
				t.expectEqual(lake, -1)
				local _, _, _, kind = Biome.sample(HOMEWORLD, x, y, z)
				t.expectTrue(kind ~= "Lake", `{kind} {metres} m from the pad`)
			end
		end
		-- far away the features are fully on
		local fx, fy, fz = around(1, 0, 0, 20000, 0.3)
		t.expectEqual(BiomeDetail.featureWeight(fx, fy, fz), 1)
	end)

	t.test("lakes are (near-)flat water in the physics ground, above the sea", function()
		local probed = 0
		local i = 0
		while probed < LAKE_PROBES and i < SPHERE_SAMPLES * 4 do
			local x, y, z = fibonacci(i, SPHERE_SAMPLES * 4)
			i += 1
			local ee, _, lake = Biome.reliefFields(HOMEWORLD, x, y, z)
			if ee > 0 and lake >= 0.03 then
				probed += 1
				local h = Relief.height(HOMEWORLD, x, y, z)
				t.expectTrue(h >= 2, `lake level {h} m`)
				local _, _, _, kind = Biome.sample(HOMEWORLD, x, y, z)
				t.expectEqual(kind, "Lake")
				for k = 0, 3 do
					local nx, ny, nz = around(x, y, z, LAKE_FLAT_STEP_M, k * math.pi / 2)
					local _, _, nLake = Biome.reliefFields(HOMEWORLD, nx, ny, nz)
					if nLake >= 0 then
						local nh = Relief.height(HOMEWORLD, nx, ny, nz)
						t.expectNear(nh, h, LAKE_FLAT_TOLERANCE_M, "lake surface is not flat")
					end
				end
			end
		end
		t.expectTrue(probed >= 10, `only {probed} lake points found`)
	end)

	t.test("relief shade: neutral on flat ground, hollows darker, crests lighter", function()
		local eps = math.pi / 4 / 64
		local function flat(_x: number, _y: number, _z: number): number
			return 0
		end
		t.expectNear(BiomeDetail.reliefShade(flat, 0.6, 0.48, 0.64, eps, EARTH_R), 1, 1e-9)
		-- a bump / a pit 3 km across around the direction (0.6, 0.48, 0.64)
		local function bump(x: number, y: number, z: number): number
			local d = math.acos(math.clamp(x * 0.6 + y * 0.48 + z * 0.64, -1, 1)) * EARTH_R
			return 300 * math.exp(-(d / 1500) ^ 2)
		end
		local function pit(x: number, y: number, z: number): number
			return -bump(x, y, z)
		end
		local crest = BiomeDetail.reliefShade(bump, 0.6, 0.48, 0.64, eps, EARTH_R)
		local hollow = BiomeDetail.reliefShade(pit, 0.6, 0.48, 0.64, eps, EARTH_R)
		t.expectTrue(crest > 1.05, `crest {crest}`)
		t.expectTrue(hollow < 0.95, `hollow {hollow}`)
		-- the real Mun has visible relief
		local lo, hi = math.huge, -math.huge
		local moonHeight = Relief.heightFn(MOON)
		for i = 0, 499 do
			local x, y, z = fibonacci(i, 500)
			local s = BiomeDetail.reliefShade(moonHeight, x, y, z, math.pi / 4 / 64, Bodies.get(MOON).Radius)
			lo, hi = math.min(lo, s), math.max(hi, s)
		end
		t.expectTrue(lo < 0.9 and hi > 1.1, `Mun shade range {lo} .. {hi}`)
	end)

	t.test("painters: padded grid at any size, small steps, relief shade baked in", function()
		local rotations = Biome.cubeRotations()
		-- 256 px with 128 cells needs two padding nodes per side (the old grid required cells <= 64)
		local big = Biome.newPainter(256, 128, buffer.create(256 * 256 * 4))
		t.expectEqual(big.pad, 2)
		t.expectEqual(big.nodes, 128 + 1 + 4)
		-- the outermost pixel centres lie inside the grid
		local first = Biome.uvToParam(0.5 / 256, 0.5)
		t.expectTrue(first >= -big.pad / big.cells, "grid misses the padding pixels")
		-- chunked: a 64 px image with a 16-cell grid takes more steps than rows
		local size = 64
		local plainBuf = buffer.create(size * size * 4)
		local plain = Biome.newPainter(size, 16, plainBuf)
		Biome.beginPatch(plain, MOON, "Ground", rotations[3], 1)
		local plainSteps = paintAll(plain)
		t.expectTrue(plainSteps >= plain.nodes + size, `{plainSteps} steps`)
		local shadedBuf = buffer.create(size * size * 4)
		local shaded = Biome.newPainter(size, 16, shadedBuf)
		Biome.beginPatch(shaded, MOON, "Ground", rotations[3], 1, Relief.heightFn(MOON))
		local shadedSteps = paintAll(shaded)
		t.expectTrue(shadedSteps > plainSteps, "relief nodes are painted in smaller steps")
		local changed = 0
		for i = 0, size * size - 1 do
			local a = buffer.readu8(plainBuf, i * 4)
			local b = buffer.readu8(shadedBuf, i * 4)
			if math.abs(a - b) > 6 then
				changed += 1
			end
			t.expectEqual(buffer.readu8(shadedBuf, i * 4 + 3), 255)
		end
		t.expectTrue(changed > size * size * 0.05, `relief shade changed {changed} pixels`)
		-- over the open sea (flat at sea level) the shade changes nothing: find an all-ocean Earth patch
		local oceanBuf = buffer.create(32 * 32 * 4)
		local ocean = Biome.newPainter(32, 8, oceanBuf)
		local oceanPlainBuf = buffer.create(32 * 32 * 4)
		local oceanPlain = Biome.newPainter(32, 8, oceanPlainBuf)
		for _, m in rotations do
			Biome.beginPatch(oceanPlain, HOMEWORLD, "Ground", m, 1)
			paintAll(oceanPlain)
			if oceanPlain.oceanPixels == 32 * 32 then
				Biome.beginPatch(ocean, HOMEWORLD, "Ground", m, 1, Relief.heightFn(HOMEWORLD))
				paintAll(ocean)
				t.expectEqual(buffer.tostring(oceanBuf), buffer.tostring(oceanPlainBuf))
				break
			end
		end
	end)

	-- CHANGED (Memory budget): smaller budgets, slots per body, base textures per tier, clouds on High only
	t.test("tiers: texture memory within budget, phones never paint 1024 px slots", function()
		local last = 0
		for _, tier: PlanetDetail.Tier in TIERS do
			local bytes = PlanetDetail.textureBytes(tier)
			t.expectTrue(bytes <= TIER_BUDGET_BYTES[tier], `{tier}: {bytes / MB} MB`)
			t.expectTrue(bytes >= last, "higher tiers never use less")
			last = bytes
			local spec = PlanetDetail.tierSpec(tier)
			local images = 0
			for _, body in Bodies.List do
				if body.Kind ~= "Star" and not body.VisualOnly then
					images += 24
					local base = PlanetDetail.baseTexture(tier, body.Id)
					t.expectTrue(base.size >= 128, "base textures keep at least 128 px (the Mun's craters)")
					local slot = PlanetDetail.slotTexture(tier, body.Id)
					if slot then
						t.expectTrue(slot.size >= base.size, "slots are sharper")
						t.expectTrue(slot.size <= 1024, "EditableImage size limit")
						t.expectTrue(slot.cells <= slot.size / 2, "grid at most half the pixels")
						t.expectTrue(PlanetDetail.slotCount(tier, body.Id) > 0, "a slot texture comes with slots")
						images += PlanetDetail.slotCount(tier, body.Id)
					end
				end
			end
			images += if PlanetDetail.cloudTexture(tier) then 24 else 0
			t.expectTrue(images <= IMAGE_CAP, `{tier}: {images} images`)
			t.expectTrue(spec.paintBudgetS > 0 and spec.paintBudgetS <= 0.005, "paint budget per frame")
		end
		-- Medium is the phone / console tier (Quality caps them there)
		for _, body in Bodies.List do
			local slot = PlanetDetail.slotTexture("Medium", body.Id)
			if slot then
				t.expectTrue(slot.size <= 512, "Medium slots stay at 512 px or less")
			end
		end
		t.expectEqual(PlanetDetail.cloudTexture("Low"), nil)
		t.expectEqual(PlanetDetail.cloudTexture("Medium"), nil)
		t.expectEqual(PlanetDetail.slotTexture("Low", HOMEWORLD), nil)
		t.expectEqual(PlanetDetail.slotCount("Low", HOMEWORLD), 0)
	end)

	t.test("detail slots go to the patch under the camera first, then its nearest neighbours", function()
		local rotations = Biome.cubeRotations()
		for i = 0, 49 do
			local x, y, z = fibonacci(i, 50)
			local chosen = PlanetDetail.desiredPatches(rotations, x, y, z, 8)
			t.expectEqual(#chosen, 8)
			t.expectNear(PlanetDetail.closeness(rotations[chosen[1]], x, y, z), 1, 1e-9)
			local seen: { [number]: boolean } = {}
			local previous = math.huge
			for _, patch in chosen do
				t.expectTrue(not seen[patch], "duplicate patch")
				seen[patch] = true
				local c = PlanetDetail.closeness(rotations[patch], x, y, z)
				t.expectTrue(c <= previous + 1e-12, "not nearest first")
				previous = c
			end
			-- deterministic
			local again = PlanetDetail.desiredPatches(rotations, x, y, z, 8)
			t.expectEqual(table.concat(again, ","), table.concat(chosen, ","))
		end
		t.expectTrue(PlanetDetail.slotsWanted(10000, EARTH_R))
		t.expectTrue(not PlanetDetail.slotsWanted(450000, EARTH_R))
	end)

	t.test("atmosphere: inside the shell budget, about the old tint, the halo fades outward", function()
		for _, tier: PlanetDetail.Tier in TIERS do
			local layers = PlanetDetail.atmosphereLayers(tier)
			t.expectTrue(#layers >= 1 and #layers <= PlanetDetail.ATMOSPHERE_MAX_LAYERS, `{tier} layers`)
			local through = 1
			local lastScale = 1
			for _, layer in layers do
				t.expectTrue(layer.scale > lastScale, "innermost first")
				t.expectTrue(layer.scale <= PlanetDetail.MAX_SHELL_SCALE, "shell larger than the proxy budget")
				lastScale = layer.scale
				through *= layer.transparency
			end
			local tint = 1 - through
			t.expectTrue(tint >= 0.18 and tint <= 0.3, `{tier}: disc tint {tint}`)
		end
		t.expectTrue(PlanetDetail.CLOUD_SHELL_SCALE < PlanetDetail.MAX_SHELL_SCALE)
	end)

	t.test("clouds: sparse and wispy, invisible at the surface handover", function()
		local handover = 6500
		t.expectEqual(PlanetDetail.cloudFade(handover, handover), 0)
		t.expectEqual(PlanetDetail.cloudFade(3 * handover, handover), 1)
		t.expectTrue(PlanetDetail.cloudFade(1.3 * handover, handover) > 0)
		local covered, maxAlpha = 0, 0
		local count = 3000
		for i = 0, count - 1 do
			local x, y, z = fibonacci(i, count)
			local a = Biome.clouds(HOMEWORLD, x, y, z)
			maxAlpha = math.max(maxAlpha, a)
			if a > 0.2 then
				covered += 1
			end
		end
		local share = covered / count
		t.expectTrue(share > 0.02 and share < 0.2, `cloud cover {share}`)
		t.expectTrue(maxAlpha <= 0.65, `densest cloud alpha {maxAlpha}`)
	end)
end
