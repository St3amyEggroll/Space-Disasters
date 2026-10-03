--!strict
-- CHANGED (Map planets): new file. Tests for Render/MapBodiesMath, the pure maths behind the map's planets: the night
-- shading curve, on-screen sizes and limbs, the ball <-> icon switch with hysteresis at the map's real scales, moon
-- icons, the atmosphere rim's gradient and images, and Sol's glow.
-- CHANGED (Map planets fix): the night shell's tests are replaced by the limb disc's (its circle is the true
-- silhouette), the night image's (every pixel shades by the true angle to Sol, in perspective and turned on screen;
-- the real Sol at the launch site), round balls at the map's camera distance, and uniform ground patches.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local MapBodiesMath = require(game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render.MapBodiesMath)

--============================================================================
-- Tunables
--============================================================================
local EPSILON = 1e-9
local PHASE_SIZE = 64 -- px per night image in the tests -- CHANGED (Map planets fix): was the shell images
local VIEWPORT_HEIGHT = 900 -- px
local MAP_FOV = GameConfig.MAP_FIELD_OF_VIEW -- MapViewController's FIELD_OF_VIEW (CHANGED (Map planets fix): was 70)
local MAP_DEFAULT_YAW = math.rad(35) -- MapViewController's DEFAULT_YAW / DEFAULT_PITCH
local MAP_DEFAULT_PITCH = math.rad(50)
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
-- CHANGED (Map planets fix): cameras and balls (studs): on the view axis, Steamy's screenshot (Earth under the craft,
-- two zoom notches in, the new camera), and two far off-axis bodies
local CASES: { { camera: Vector3, centre: Vector3, radius: number } } = {
	{ camera = Vector3.new(0, 0, 240), centre = Vector3.zero, radius = 60 },
	{ camera = Vector3.new(88.6, 183.8, 126.5), centre = Vector3.new(-86.4, 0, 0), radius = 86.4 },
	{ camera = Vector3.new(10, -50, 300), centre = Vector3.new(120, 40, -30), radius = 25 },
	{ camera = Vector3.new(0, 30, 0), centre = Vector3.new(300, 100, -200), radius = 150 },
}
--============================================================================

local function tanHalf(): number
	return math.tan(math.rad(MAP_FOV) / 2)
end

-- Bilinear alpha (0..1) of an RGBA8 image at pixel coordinates (fx, fy) (pixel centres at whole numbers).
local function sampleAlpha(buf: buffer, size: number, fx: number, fy: number): number
	local x0 = math.clamp(math.floor(fx), 0, size - 2)
	local y0 = math.clamp(math.floor(fy), 0, size - 2)
	local u, v = math.clamp(fx - x0, 0, 1), math.clamp(fy - y0, 0, 1)
	local function a(x: number, y: number): number
		return buffer.readu8(buf, (y * size + x) * 4 + 3) / 255
	end
	local top = a(x0, y0) * (1 - u) + a(x0 + 1, y0) * u
	local bottom = a(x0, y0 + 1) * (1 - u) + a(x0 + 1, y0 + 1) * u
	return top * (1 - v) + bottom * v
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

	-- CHANGED (Map planets fix): the limb disc, the night image, round balls and the patch sizes (the night shell's
	-- tests are gone with it)
	t.test(
		"limb disc: its circle is the ball's true silhouette, wholly in front of the ball, facing the camera",
		function()
			for _, case in CASES do
				local camera, centre, radius = case.camera, case.centre, case.radius
				local frame, limb = MapBodiesMath.discFrame(camera, centre, radius, Vector3.yAxis)
				local axis = (camera - centre).Unit
				t.expectNear(
					(frame.Position - centre).Magnitude,
					radius,
					1e-5 * radius,
					"through the point nearest the camera"
				)
				t.expectNear(frame.LookVector:Dot(axis), 1, 1e-5, "the Front face looks at the camera")
				for k = 0, 11 do
					local a = k * math.pi / 6
					local rim = frame:PointToWorldSpace(Vector3.new(math.cos(a) * limb, math.sin(a) * limb, 0))
					-- the ray from the camera through the disc's circle just touches the sphere
					local ray = (rim - camera).Unit
					local along = (centre - camera):Dot(ray)
					local miss = ((centre - camera) - ray * along).Magnitude
					t.expectNear(miss, radius, 1e-5 * radius, "the circle lies on the silhouette")
					t.expectTrue((rim - centre).Magnitude > radius, "the disc stays outside the ball")
				end
			end
		end
	)

	t.test("night image: every pixel shades by the true angle to Sol (true perspective, turned on screen)", function()
		for _, case in CASES do
			local camera, centre, radius = case.camera, case.centre, case.radius
			local frame, limb = MapBodiesMath.discFrame(camera, centre, radius, Vector3.yAxis)
			local axis = (camera - centre).Unit
			for _, sun in SUN_DIRECTIONS do
				local sunView = MapBodiesMath.discSun(frame, sun)
				local rotation = math.rad(MapBodiesMath.screenRotation(sunView))
				local buf = buffer.create(PHASE_SIZE * PHASE_SIZE * 4)
				local q = radius / (camera - centre).Magnitude
				MapBodiesMath.paintPhase(PHASE_SIZE, sunView.Z, q, buf)
				for k = 1, 60 do
					-- a point of the ball the camera sees
					local n = Vector3.new(math.sin(k * 1.7), math.cos(k * 2.3), math.sin(k * 0.9 + 1)).Unit
					local p = centre + n * radius
					if (camera - p).Unit:Dot(n) < 0.3 then
						continue -- hidden or too close to the limb (the image's steepest part)
					end
					-- where it lands on the disc (straight from the camera), in the disc's view axes (limb radii)
					local ray = p - camera
					local s = (frame.Position - camera):Dot(axis) / ray:Dot(axis)
					local onDisc = frame:PointToObjectSpace(camera + ray * s)
					local vx, vy = -onDisc.X / limb, onDisc.Y / limb
					-- screen (y down) -> the image turned by `rotation` clockwise -> its pixels
					local gx, gy = vx, -vy
					local ix = gx * math.cos(rotation) + gy * math.sin(rotation)
					local iy = -gx * math.sin(rotation) + gy * math.cos(rotation)
					local canvas = MapBodiesMath.PHASE_CANVAS
					local fx = (ix / canvas + 1) / 2 * PHASE_SIZE - 0.5
					local fy = (iy / canvas + 1) / 2 * PHASE_SIZE - 0.5
					local alpha = sampleAlpha(buf, PHASE_SIZE, fx, fy)
					local expected = MapBodiesMath.nightAlpha(n:Dot(sun))
					t.expectNear(alpha, expected, 0.06, "night image alpha = night alpha of the true angle to Sol")
				end
			end
		end
	end)

	t.test("night image: corners clear, the table form paints the same pixels, row ranges too", function()
		local buf = buffer.create(PHASE_SIZE * PHASE_SIZE * 4)
		MapBodiesMath.paintPhase(PHASE_SIZE, 0.3, 0.4, buf)
		t.expectEqual(buffer.readu8(buf, 3), 0, "the corner is clear")
		t.expectEqual(buffer.readu8(buf, 0), 0, "the night image is black")
		local tbl = MapBodiesMath.phaseTable(PHASE_SIZE, 0.4)
		local split = buffer.create(PHASE_SIZE * PHASE_SIZE * 4)
		MapBodiesMath.paintPhaseFrom(tbl, 0.3, split, 0, 9)
		MapBodiesMath.paintPhaseFrom(tbl, 0.3, split, 10, PHASE_SIZE - 1)
		t.expectEqual(buffer.tostring(split), buffer.tostring(buf), "same pixels")
		-- Sol straight behind the camera: the middle is full day; behind the ball: the middle is night
		local middle = ((PHASE_SIZE / 2) * PHASE_SIZE + PHASE_SIZE / 2) * 4 + 3
		MapBodiesMath.paintPhase(PHASE_SIZE, 1, 0.3, buf)
		t.expectTrue(buffer.readu8(buf, middle) < 10, "front-lit: clear in the middle")
		MapBodiesMath.paintPhase(PHASE_SIZE, -1, 0.3, buf)
		t.expectTrue(buffer.readu8(buf, middle) > 240, "back-lit: dark in the middle")
	end)

	t.test("the map's real Sol: the pad side faces Sol as in flight, the night image darkens the far side", function()
		local up = Frames.surfaceUp(0, 0) -- the launch site
		for _, ut in { 0, 150, 600, 900 } do
			local solRel = Universe.bodyOffset(Bodies.SUN, Bodies.HOMEWORLD, ut)
			local sun = MapBodiesMath.sunDirection(Vec3d.zero(), solRel) :: Vector3
			local flight = Universe.sunDirection(ut)
			local cosPad = sun:Dot(Vector3.new(up.x, up.y, up.z))
			t.expectNear(cosPad, flight.x * up.x + flight.y * up.y + flight.z * up.z, 1e-6, "the flight sun's height")
			-- seen from the map camera straight above the pad: the pad (the middle of the disc) is as lit as its sun
			local radius = 60
			local camera = Vector3.new(up.x, up.y, up.z) * (radius + GameConfig.MAP_CAMERA_DISTANCE)
			local frame = MapBodiesMath.discFrame(camera, Vector3.zero, radius, Vector3.yAxis)
			local sunView = MapBodiesMath.discSun(frame, sun)
			t.expectNear(sunView.Z, cosPad, 1e-6, "Sol's angle seen from the camera")
			local buf = buffer.create(PHASE_SIZE * PHASE_SIZE * 4)
			MapBodiesMath.paintPhase(PHASE_SIZE, sunView.Z, radius / (radius + GameConfig.MAP_CAMERA_DISTANCE), buf)
			local alpha = sampleAlpha(buf, PHASE_SIZE, PHASE_SIZE / 2 - 0.5, PHASE_SIZE / 2 - 0.5)
			t.expectNear(alpha, MapBodiesMath.nightAlpha(cosPad), 0.02, "the pad's shading")
		end
		local sun0 = MapBodiesMath.sunDirection(Vec3d.zero(), Universe.bodyOffset(Bodies.SUN, Bodies.HOMEWORLD, 0))
		t.expectTrue((sun0 :: Vector3):Dot(Vector3.new(up.x, up.y, up.z)) > 0.5, "at UT 0 the pad is in daylight")
	end)

	t.test("round balls: Earth under the craft is within 5% of round at the map's camera distance", function()
		t.expectNear(MapBodiesMath.silhouetteAspect(0, 0.4), 1, 1e-12, "on the view axis: a circle")
		local function aspect(distance: number, scale: number): number
			-- the map's default view of the craft on the pad (focus at the origin), Earth's centre under it
			local orbit = CFrame.Angles(0, MAP_DEFAULT_YAW, 0) * CFrame.Angles(-MAP_DEFAULT_PITCH, 0, 0)
			local camera = orbit:PointToWorldSpace(Vector3.new(0, 0, distance))
			local radius = Bodies.get(Bodies.HOMEWORLD).Radius * scale
			local centre = Vector3.new(-radius, 0, 0) -- the pad is at lat 0, lon 0 (+X)
			local toCentre = centre - camera
			local offAxis = math.acos(math.clamp(toCentre.Unit:Dot((-camera).Unit), -1, 1))
			return MapBodiesMath.silhouetteAspect(offAxis, math.asin(radius / toCentre.Magnitude))
		end
		local scale = GameConfig.MAP_SCALE * GameConfig.MAP_ZOOM_STEP ^ 2 -- two notches in (Steamy's screenshot)
		t.expectTrue(aspect(160, scale) > 1.09, "the old camera: about 10% wider than tall")
		t.expectTrue(aspect(GameConfig.MAP_CAMERA_DISTANCE, scale) < 1.05, "now within 5%")
		t.expectTrue(aspect(GameConfig.MAP_CAMERA_DISTANCE, GameConfig.MAP_SCALE) < 1.03, "at the opening zoom: 3%")
		-- the framing of the focus is unchanged: same studs per pixel at the origin
		local before = 160 * math.tan(math.rad(70) / 2)
		local now = GameConfig.MAP_CAMERA_DISTANCE * math.tan(math.rad(GameConfig.MAP_FIELD_OF_VIEW) / 2)
		t.expectNear(now / before, 1, 0.01, "the focus looks as big as before")
	end)

	t.test("ground patches: placed and sized uniformly, every vertex on the ball", function()
		-- ScaledSpace's shared patch: the +Y face quarter, recentred on its bounds (MeshSize = those bounds)
		local n = 8
		local points: { Vector3 } = {}
		local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
		for i = 0, n do
			for j = 0, n do
				local p = Vector3.new(-1 + i / n, 1, -1 + j / n).Unit
				table.insert(points, p)
				lo, hi = lo:Min(p), hi:Max(p)
			end
		end
		local centre, size = (lo + hi) / 2, hi - lo
		local radius = 37.5
		local partSize = size * radius -- MapBodies.resize
		local scale = partSize / size -- what Roblox stretches the mesh by, per axis
		t.expectNear(scale.X, radius, 1e-9, "uniform")
		t.expectNear(scale.Y, radius, 1e-9, "uniform")
		t.expectNear(scale.Z, radius, 1e-9, "uniform")
		for _, m in Biome.cubeRotations() do
			local rotation = CFrame.new(0, 0, 0, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9])
			local placed = rotation * CFrame.new(centre * radius) -- MapBodies.placePatches (body at the origin)
			for _, p in points do
				local world = placed:PointToWorldSpace((p - centre) * scale)
				t.expectNear(world.Magnitude, radius, 1e-4, "on the sphere (single-precision Vector3)")
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
