--!strict
-- CHANGED (Map planets): new file. Tests for Render/MapBodiesMath, the pure maths behind the map's planets: the night
-- shading curve, the night shell turned toward Sol (and its six shared images shading every patch exactly as the
-- real direction to Sol says), on-screen sizes and limbs, the ball <-> icon switch with hysteresis at the map's real
-- scales, moon icons, the atmosphere rim's gradient and images, and Sol's glow.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local MapBodiesMath = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render.MapBodiesMath)

--============================================================================
-- Tunables
--============================================================================
local EPSILON = 1e-9
local BYTE = 1 / 255 + 1e-9 -- one 8-bit step
local SHELL_SIZE = 16 -- px per shell image in the tests
local VIEWPORT_HEIGHT = 900 -- px
local MAP_FOV = 70 -- MapViewController's FIELD_OF_VIEW
local SUN_DIRECTIONS: { Vector3 } = {
	Vector3.new(1, 0, 0),
	Vector3.new(-1, 0, 0),
	Vector3.new(0, 1, 0),
	Vector3.new(0, -1, 0),
	Vector3.new(0, 0, 1),
	Vector3.new(0, 0, -1),
	Vector3.new(0.3, 0.25, -0.92).Unit,
	Vector3.new(-0.7, 0.1, 0.7).Unit,
	Vector3.new(0.95, -0.05, 0.31).Unit,
}
--============================================================================

local function tanHalf(): number
	return math.tan(math.rad(MAP_FOV) / 2)
end

local function paint(m: { number }): buffer
	local buf = buffer.create(SHELL_SIZE * SHELL_SIZE * 4)
	MapBodiesMath.paintShell(m, SHELL_SIZE, buf)
	return buf
end

return function(t: TestKit.Context)
	t.test("night shading: dark night half, soft terminator, bright and round day half", function()
		local previous = -math.huge
		for k = 0, 200 do
			local c = -1 + k / 100
			local b = MapBodiesMath.brightness(c)
			t.expectTrue(b >= previous - EPSILON, `brightness never drops toward Sol (c {c})`)
			t.expectTrue(b >= 0 and b <= 1, "brightness in 0..1")
			t.expectNear(MapBodiesMath.nightAlpha(c), 1 - b, EPSILON)
			previous = b
		end
		t.expectTrue(MapBodiesMath.brightness(-1) < 0.05, "the night side is dark")
		t.expectTrue(MapBodiesMath.brightness(-0.2) < 0.05, "past the terminator it is night")
		t.expectNear(MapBodiesMath.brightness(1), 1, EPSILON, "under Sol: full brightness")
		local atTerminator = MapBodiesMath.brightness(0)
		t.expectTrue(atTerminator > 0.03 and atTerminator < 0.3, "the terminator is soft (between night and day)")
		t.expectTrue(MapBodiesMath.brightness(0.5) < 0.85, "the day side falls off toward the terminator (round)")
		t.expectTrue(MapBodiesMath.brightness(0.5) > 0.5, "the day side is clearly lit")
	end)

	t.test("sunDirection: unit, toward Sol, exact for far bodies; nil when they coincide", function()
		local body = Vec3d.new(1e7 + 0.5, 3, -2.5e6)
		local sol = Vec3d.new(1e7 + 0.5 + 300, 3 + 400, -2.5e6)
		local d = MapBodiesMath.sunDirection(body, sol)
		t.expectTrue(d ~= nil, "a direction")
		local v = d :: Vector3
		t.expectNear(v.X, 0.6, 1e-6)
		t.expectNear(v.Y, 0.8, 1e-6)
		t.expectNear(v.Z, 0, 1e-6)
		t.expectTrue(MapBodiesMath.sunDirection(body, body) == nil, "no direction from a point to itself")
		-- the real solar system: from Earth (focus Earth) Sol is where Universe says the sun is
		for _, ut in { 0, 300, 2000, 12345 } do
			local solRel = Universe.bodyOffset(Bodies.SUN, Bodies.HOMEWORLD, ut)
			local dir = MapBodiesMath.sunDirection(Vec3d.zero(), solRel) :: Vector3
			local expected = Universe.sunDirection(ut)
			t.expectNear(dir.X, expected.x, 1e-6)
			t.expectNear(dir.Y, expected.y, 1e-6)
			t.expectNear(dir.Z, expected.z, 1e-6)
		end
	end)

	t.test("nightShellRotation: a proper rotation whose +Y points at Sol", function()
		for _, sun in SUN_DIRECTIONS do
			local r = MapBodiesMath.nightShellRotation(sun)
			local x, y, z = r.XVector, r.YVector, r.ZVector
			t.expectNear((y - sun).Magnitude, 0, 1e-6, "+Y toward Sol")
			t.expectNear(x.Magnitude, 1, 1e-6)
			t.expectNear(z.Magnitude, 1, 1e-6)
			t.expectNear(x:Dot(y), 0, 1e-6)
			t.expectNear(y:Dot(z), 0, 1e-6)
			t.expectNear((x:Cross(y) - z).Magnitude, 0, 1e-6, "right-handed (determinant +1)")
			t.expectNear(r.Position.Magnitude, 0, EPSILON, "rotation only")
		end
	end)

	t.test("night shell: six shared images give every one of the 24 patches exactly its own pixels", function()
		local matrices = Biome.cubeRotations()
		t.expectEqual(#matrices, 24)
		local counts: { [number]: number } = {}
		local byKey: { [number]: buffer } = {}
		for _, m in matrices do
			local key = MapBodiesMath.shellKey(m)
			t.expectTrue(key >= 1 and key <= 6, "key 1..6")
			counts[key] = (counts[key] or 0) + 1
			local own = paint(m)
			local shared = byKey[key]
			if shared == nil then
				byKey[key] = own
			else
				t.expectEqual(buffer.tostring(own), buffer.tostring(shared), `patch shares image {key} pixel for pixel`)
			end
		end
		for key = 1, 6 do
			t.expectEqual(counts[key], 4, `four patches use image {key}`)
		end
	end)

	t.test("night shell: turned toward Sol, every shell pixel shades by the true angle to Sol", function()
		local matrices = Biome.cubeRotations()
		for _, sun in SUN_DIRECTIONS do
			local rotation = MapBodiesMath.nightShellRotation(sun)
			for index = 1, #matrices, 5 do
				local m = matrices[index]
				local buf = paint(m)
				for py = 0, SHELL_SIZE - 1, 3 do
					for px = 0, SHELL_SIZE - 1, 3 do
						-- where this pixel sits on the shell (shell axes), then in the map's axes
						local s, tt = Biome.uvToParam((px + 0.5) / SHELL_SIZE, (py + 0.5) / SHELL_SIZE)
						local lx, ly, lz = Biome.patchDirection(m, s, tt)
						local world = rotation:VectorToWorldSpace(Vector3.new(lx, ly, lz))
						local expected = MapBodiesMath.nightAlpha(world:Dot(sun))
						local alpha = buffer.readu8(buf, (py * SHELL_SIZE + px) * 4 + 3) / 255
						t.expectNear(alpha, expected, BYTE, "shell alpha = night alpha of the true angle to Sol")
						t.expectEqual(buffer.readu8(buf, (py * SHELL_SIZE + px) * 4), 0, "the shell is black")
					end
				end
			end
		end
	end)

	t.test("screen size: pixel radius, limb radii (true perspective)", function()
		local h = tanHalf()
		-- a sphere seen at 45 degrees half-angle fills tan(45)/tan(35) of the half-height
		local r, d = 1, math.sqrt(2)
		t.expectNear(MapBodiesMath.pixelRadius(d, r, h, VIEWPORT_HEIGHT), 1 / h * VIEWPORT_HEIGHT / 2, 1e-6)
		t.expectEqual(MapBodiesMath.pixelRadius(0.5, 1, h, VIEWPORT_HEIGHT), math.huge, "camera inside: huge")
		local previous = math.huge
		for k = 1, 50 do
			local px = MapBodiesMath.pixelRadius(2 + k * 10, 1, h, VIEWPORT_HEIGHT)
			t.expectTrue(px < previous, "smaller farther away")
			previous = px
		end
		-- the tangent cone from the camera crosses the centre plane at limbRadius and the front plane at
		-- frontLimbRadius
		for _, dist in { 1.2, 2, 5, 40 } do
			local theta = math.asin(1 / dist)
			t.expectNear(MapBodiesMath.limbRadius(dist, 1), dist * math.tan(theta), 1e-9)
			t.expectNear(MapBodiesMath.frontLimbRadius(dist, 1), (dist - 1) * math.tan(theta), 1e-9)
			t.expectTrue(MapBodiesMath.limbRadius(dist, 1) > 1, "the limb seen in perspective is wider than R")
		end
	end)

	t.test("ball <-> icon: hysteresis, no flicker between the thresholds", function()
		local below, above = MapBodiesMath.ICON_BELOW_PX, MapBodiesMath.BALL_ABOVE_PX
		t.expectTrue(below < above, "a gap between the thresholds")
		t.expectEqual(MapBodiesMath.nextIconMode(false, below + 0.1), false, "a ball stays a ball above the low one")
		t.expectEqual(MapBodiesMath.nextIconMode(false, below - 0.1), true, "a ball shrinking below it: icon")
		t.expectEqual(MapBodiesMath.nextIconMode(true, above - 0.1), true, "an icon stays an icon below the high one")
		t.expectEqual(MapBodiesMath.nextIconMode(true, above + 0.1), false, "an icon growing above it: ball")
		-- wobbling between the thresholds never switches
		local icon = true
		for k = 0, 40 do
			local px = (below + above) / 2 + 0.9 * (above - below) / 2 * math.sin(k)
			local nextIcon = MapBodiesMath.nextIconMode(icon, px)
			t.expectEqual(nextIcon, icon, "no flicker")
			icon = nextIcon
		end
	end)

	t.test("at the map's real scales: planets are icons zoomed out, balls when framed", function()
		local h = tanHalf()
		local camera = GameConfig.MAP_CAMERA_DISTANCE
		local function px(body: Bodies.Body, scale: number, offsetStuds: number): number
			-- seen from the side: the camera is MAP_CAMERA_DISTANCE from the focus, square to the body's offset
			local distance = math.sqrt(camera * camera + offsetStuds * offsetStuds)
			return MapBodiesMath.pixelRadius(distance, body.Radius * scale, h, VIEWPORT_HEIGHT)
		end
		local earth, mars, mun = Bodies.get(Bodies.HOMEWORLD), Bodies.get(Bodies.MARS), Bodies.get(Bodies.MOON)
		local zoomedOut = GameConfig.MAP_SCALE_MIN
		t.expectTrue(
			MapBodiesMath.nextIconMode(
				false,
				px(mars, zoomedOut, (mars.Orbit :: Bodies.CircularOrbit).Radius * zoomedOut)
			),
			"Mars is an icon when the whole solar system is on screen"
		)
		t.expectTrue(
			MapBodiesMath.nextIconMode(
				false,
				px(earth, zoomedOut, (earth.Orbit :: Bodies.CircularOrbit).Radius * zoomedOut)
			),
			"Earth is an icon too"
		)
		-- the Earth button frames Earth's SOI: Earth and the Mun are real balls there
		local framed = GameConfig.MAP_EXTENT * 0.45 / earth.SoiRadius
		local earthPx = MapBodiesMath.pixelRadius(camera, earth.Radius * framed, h, VIEWPORT_HEIGHT)
		local munPx = MapBodiesMath.pixelRadius(
			camera + (mun.Orbit :: Bodies.CircularOrbit).Radius * framed,
			mun.Radius * framed,
			h,
			VIEWPORT_HEIGHT
		)
		t.expectEqual(MapBodiesMath.nextIconMode(false, earthPx), false, "Earth is a ball when framed")
		t.expectEqual(MapBodiesMath.nextIconMode(false, munPx), false, "the Mun is a ball when Earth is framed")
		-- and the map opens at MAP_SCALE: Earth is big
		t.expectTrue(MapBodiesMath.pixelRadius(camera, earth.Radius * GameConfig.MAP_SCALE, h, VIEWPORT_HEIGHT) > 50)
	end)

	t.test("moon icons hide only right next to their parent's icon", function()
		t.expectTrue(MapBodiesMath.moonIconHidden(true, 5), "on top of the parent's icon: hidden")
		t.expectEqual(MapBodiesMath.moonIconHidden(true, 200), false, "far from it: shown")
		t.expectEqual(MapBodiesMath.moonIconHidden(false, 5), false, "the parent is a ball: shown")
	end)

	t.test("rim gradient: bright toward Sol on screen, even when Sol is in front or behind", function()
		local rotation, tNight, tDay = MapBodiesMath.rimGradient(Vector3.new(1, 0, 0))
		t.expectNear(rotation, 0, 1e-9, "Sol to the right: the gradient's end (offset 1) on the right")
		t.expectTrue(tDay < tNight, "the sunlit limb is brighter")
		t.expectTrue(tDay >= 0 and tNight <= 1, "transparencies in 0..1")
		rotation = MapBodiesMath.rimGradient(Vector3.new(0, 1, 0))
		t.expectNear(rotation, -90, 1e-9, "Sol up on screen: turned 90 degrees counter-clockwise (UIGradient)")
		rotation = MapBodiesMath.rimGradient(Vector3.new(0, -1, 0))
		t.expectNear(rotation, 90, 1e-9, "Sol down: clockwise")
		local _, n2, d2 = MapBodiesMath.rimGradient(Vector3.new(0, 0, 1))
		t.expectNear(n2, d2, 1e-9, "Sol behind the camera: an even ring")
		local _, n3, d3 = MapBodiesMath.rimGradient(Vector3.new(0, 0, -1))
		t.expectNear(n3, d3, 1e-9, "Sol behind the planet: an even ring")
		local e0, e1 = MapBodiesMath.rimKeypoints(MapBodiesMath.RIM_CANVAS)
		t.expectTrue(e0 > 0 and e0 < 0.5 and e1 > 0.5 and e1 < 1, "limb keypoints inside the image")
		t.expectNear(e0 + e1, 1, 1e-12, "symmetric")
	end)

	t.test("rim image: a thin ring on the limb, nothing in the middle or the corners", function()
		t.expectNear(MapBodiesMath.rimAlpha(1, 0.03, 0.07), 1, 1e-12, "full at the limb")
		t.expectTrue(MapBodiesMath.rimAlpha(1 - 0.1, 0.03, 0.07) < 0.01, "thin inside the limb")
		t.expectTrue(MapBodiesMath.rimAlpha(1.05, 0.03, 0.07) > 0.3, "a soft tail outside")
		t.expectTrue(MapBodiesMath.rimAlpha(1.25, 0.03, 0.07) < 0.06, "fading out")
		local size = 64
		local buf = buffer.create(size * size * 4)
		MapBodiesMath.paintRim(size, Color3.fromRGB(120, 170, 255), 0.03, 0.07, 0.9, buf)
		local function alphaAt(px: number, py: number): number
			return buffer.readu8(buf, (py * size + px) * 4 + 3)
		end
		t.expectEqual(alphaAt(0, 0), 0, "corner")
		t.expectEqual(alphaAt(size / 2, size / 2), 0, "centre")
		-- the limb is at 1 / RIM_CANVAS of the half-size from the centre
		local limbPx = math.floor(size / 2 + size / 2 / MapBodiesMath.RIM_CANVAS)
		t.expectTrue(alphaAt(limbPx, size / 2) > 150, "bright on the limb")
		-- the row-range painter gives the same pixels
		local split = buffer.create(size * size * 4)
		MapBodiesMath.paintRim(size, Color3.fromRGB(120, 170, 255), 0.03, 0.07, 0.9, split, 0, 9)
		MapBodiesMath.paintRim(size, Color3.fromRGB(120, 170, 255), 0.03, 0.07, 0.9, split, 10, size - 1)
		t.expectEqual(buffer.tostring(split), buffer.tostring(buf), "painting in row ranges is identical")
	end)

	t.test("Sol's glow: bright core, smooth falloff, zero at its edge", function()
		local previous = math.huge
		for k = 0, 100 do
			local a = MapBodiesMath.glowAlpha(k / 100)
			t.expectTrue(a <= previous + EPSILON, "never brighter farther out")
			t.expectTrue(a >= 0 and a <= 1, "alpha in 0..1")
			previous = a
		end
		t.expectTrue(MapBodiesMath.glowAlpha(0) > 0.9, "bright in the middle")
		t.expectEqual(MapBodiesMath.glowAlpha(1), 0, "nothing at the edge (no square)")
		local size = 32
		local buf = buffer.create(size * size * 4)
		MapBodiesMath.paintGlow(size, Color3.fromRGB(255, 220, 160), buf)
		t.expectEqual(buffer.readu8(buf, 3), 0, "the corner is clear")
		t.expectTrue(buffer.readu8(buf, ((size / 2) * size + size / 2) * 4 + 3) > 200, "the middle is bright")
	end)
end
