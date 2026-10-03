--!strict
-- CHANGED (Far layer): tests for the far ground's backdrop maths (Render/FarLayerMath): the six face cameras draw an
-- exact cubemap (each camera's picture of a direction lands on its panel exactly where that direction meets the
-- panel, as the SurfaceGui shows it), neighbouring faces agree along their edges and corners, the faces marked
-- visible include every face the view can show, the cube stays inside the draw distance and in front of the
-- SkyCube with one part per face, the backdrop's one scale keeps every direction and depth order and fits the part
-- limit, and the /farground switch.
-- CHANGED (Far layer fix): + the backdrop's reach (ScaledSpace keeps other bodies beyond it), the diagnostics (face
-- list, re-parent timing, the verdict's order, error clipping) and where /farground test's reference objects land.

local TestKit = require(script.Parent.TestKit)
local Render = game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render
local FarLayerMath = require(Render.FarLayerMath)

--============================================================================
-- Tunables (the values Render/FarLayer uses)
--============================================================================
local OVERLAP = 0.003 -- PANEL_OVERLAP
local HALF_SIZE: FarLayerMath.HalfSizeParams =
	{ fraction = 0.8, min = 300, max = 1020, skyFraction = 0.9, skyMin = 400 }
local PART_LIMIT = 2040
local MARGIN = math.rad(12) -- VISIBLE_MARGIN
local SAMPLES = 3000 -- random directions
local DENSE = 41 -- rays across the view in the visibility check
local SEED = 7
-- CHANGED (Far layer fix): /farground test's reference objects (FarLayer's TEST) and the copies' re-parents
local TEST_DISTANCE, TEST_LIFT, TEST_SIZE = 700, 90, 90
local KICK_DELAYS = { 0.3, 2 }
--============================================================================

-- deterministic generator (LCG; Lune has no Random)
local state = SEED
local function uniform(a: number, b: number): number
	state = (state * 1103515245 + 12345) % 2147483648
	return a + (b - a) * state / 2147483648
end
local function pick(n: number): number
	return math.min(math.floor(uniform(1, n + 1)), n)
end

local function randomDir(): Vector3
	while true do
		local v = Vector3.new(uniform(-1, 1), uniform(-1, 1), uniform(-1, 1))
		local m = v.Magnitude
		if m > 0.05 and m <= 1 then
			return v / m
		end
	end
end

-- where a camera with a symmetric frustum (vertical FOV `fov`, square frame) draws direction `d`: x right, y up
local function screen(camera: CFrame, fov: number, d: Vector3): (number, number, boolean)
	local lp = camera:VectorToObjectSpace(d)
	local t = math.tan(math.rad(fov) / 2)
	return (lp.X / -lp.Z) / t, (lp.Y / -lp.Z) / t, lp.Z < 0
end

-- the face a direction leaves the cube through, by brute force (largest component along a face normal)
local function hitFace(d: Vector3): number
	return FarLayerMath.faceOf(d)
end

return function(t: TestKit.Context)
	t.test("cube faces: right-handed frames, the panel's Front face looks at the eye", function()
		for i, face in FarLayerMath.FACES do
			t.expectNear(face.normal:Dot(face.up), 0, 1e-12, `face {i}: up is in the face`)
			local camera = FarLayerMath.faceCamera(face)
			t.expectTrue((camera.LookVector - face.normal).Magnitude < 1e-9, `face {i}: camera looks out`)
			t.expectTrue((camera.UpVector - face.up).Magnitude < 1e-9, `face {i}: camera up`)
			local panel = FarLayerMath.panelCFrame(face, 1000)
			t.expectTrue((panel.Position - face.normal * 1000).Magnitude < 1e-6, `face {i}: panel on the face`)
			t.expectTrue(panel.LookVector:Dot(-panel.Position) > 0, `face {i}: Front face towards the eye`)
			t.expectTrue((panel.UpVector - face.up).Magnitude < 1e-9, `face {i}: GUI upright`)
		end
		-- every direction leaves through exactly one face's +-45 degree pyramid (ties on edges aside)
		local opposite = 0
		for i, a in FarLayerMath.FACES do
			for j, b in FarLayerMath.FACES do
				if i ~= j and a.normal:Dot(b.normal) < -0.5 then
					opposite += 1
				end
			end
		end
		t.expectEqual(opposite, 6, "three pairs of opposite faces")
	end)

	t.test(
		"cubemap: each face camera draws a direction where it meets that face's panel (SurfaceGui coordinates)",
		function()
			local fov = FarLayerMath.fieldOfView(OVERLAP)
			local worst = 0
			for _ = 1, SAMPLES do
				local d = randomDir()
				local index = hitFace(d)
				local face = FarLayerMath.FACES[index]
				local x, y = FarLayerMath.project(face, d)
				t.expectTrue(math.abs(x) <= 1 + 1e-9 and math.abs(y) <= 1 + 1e-9, "inside the face")
				-- the face camera's picture
				local sx, sy, front = screen(FarLayerMath.faceCamera(face), fov, d)
				t.expectTrue(front, "in front of the face camera")
				-- the panel: where the ray from the eye meets it, in the GUI's terms
				for _, h in { 300, 1020 } do
					local hit = d * (h / d:Dot(face.normal))
					local onPanel = FarLayerMath.panelCFrame(face, h):PointToObjectSpace(hit)
					t.expectNear(onPanel.Z, 0, 1e-6 * h, "the hit lies in the panel's plane")
					local gx, gy = FarLayerMath.guiPoint(face, h, OVERLAP, hit)
					worst = math.max(worst, math.abs(gx - sx), math.abs(gy - sy))
					t.expectTrue((FarLayerMath.panelPoint(face, h, x, y) - hit).Magnitude < 1e-6 * h, "panelPoint")
				end
				t.expectNear(sx, x / (1 + OVERLAP), 1e-9, "camera x = cube x / (1 + overlap)")
				t.expectNear(sy, y / (1 + OVERLAP), 1e-9, "camera y = cube y / (1 + overlap)")
			end
			t.expectTrue(worst < 1e-6, `camera picture vs panel position: worst {worst}`)
		end
	)

	t.test("seams: neighbouring faces meet at the same cube point along every edge and corner", function()
		local h = 1020
		for i, a in FarLayerMath.FACES do
			for j, b in FarLayerMath.FACES do
				if i < j and math.abs(a.normal:Dot(b.normal)) < 0.5 then
					-- the shared edge: directions n_a + n_b + s w (w along the edge), s in [-1, 1]
					local w = a.normal:Cross(b.normal)
					for k = 0, 20 do
						local s = -1 + k / 10
						local d = a.normal + b.normal + w * s
						local xa, ya = FarLayerMath.project(a, d)
						local xb, yb = FarLayerMath.project(b, d)
						t.expectNear(math.max(math.abs(xa), math.abs(ya)), 1, 1e-9, "on face a's border")
						t.expectNear(math.max(math.abs(xb), math.abs(yb)), 1, 1e-9, "on face b's border")
						local pa = FarLayerMath.panelPoint(a, h, xa, ya)
						local pb = FarLayerMath.panelPoint(b, h, xb, yb)
						t.expectTrue((pa - pb).Magnitude < 1e-6, `faces {i}/{j}: the same edge point`)
						t.expectTrue((pa - d * h).Magnitude < 1e-6, "on the cube")
					end
				end
			end
		end
		-- the eight corners: every face that touches one maps it to its own corner, the same point
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local d = Vector3.new(sx, sy, sz)
					for _, face in FarLayerMath.FACES do
						if d:Dot(face.normal) > 0 then
							local x, y = FarLayerMath.project(face, d)
							t.expectNear(math.abs(x), 1, 1e-9, "corner x")
							t.expectNear(math.abs(y), 1, 1e-9, "corner y")
							t.expectTrue((FarLayerMath.panelPoint(face, h, x, y) - d * h).Magnitude < 1e-6, "corner")
						end
					end
				end
			end
		end
	end)

	t.test("visible faces: every face the view shows is drawn; the face behind a level camera is not", function()
		local out: { boolean } = {}
		for _, aspect in { 16 / 9, 2.2, 4 / 3 } do
			for _, fov in { 70, 40, 100 } do
				for _ = 1, 150 do
					local look = randomDir()
					local up = randomDir()
					if math.abs(look:Dot(up)) > 0.95 then
						continue
					end
					FarLayerMath.visibleFaces(look, up, fov, aspect, MARGIN, out)
					local right = look:Cross(up).Unit
					local trueUp = right:Cross(look).Unit
					local ty = math.tan(math.rad(fov) / 2)
					for i = 0, DENSE - 1 do
						for j = 0, DENSE - 1 do
							local d = look
								+ right * ((2 * i / (DENSE - 1) - 1) * ty * aspect)
								+ trueUp * ((2 * j / (DENSE - 1) - 1) * ty)
							local face = hitFace(d.Unit)
							t.expectTrue(out[face], `face {face} shows in the view but is not drawn`)
						end
					end
				end
			end
		end
		-- a level camera looking along +X with a 70-degree view: -X (behind) is not drawn
		FarLayerMath.visibleFaces(Vector3.xAxis, Vector3.yAxis, 70, 16 / 9, MARGIN, out)
		t.expectTrue(out[1], "+X drawn")
		t.expectTrue(not out[2], "-X (behind) skipped")
	end)

	t.test("cube size: inside the draw distance, in front of the SkyCube, one part per face", function()
		t.expectTrue(2 * HALF_SIZE.max * (1 + OVERLAP) <= 2048, "a face fits one part")
		for dd = 100, 20000, 50 do
			local h = FarLayerMath.halfSize(dd, HALF_SIZE)
			local sky = math.clamp(dd * HALF_SIZE.skyFraction, HALF_SIZE.skyMin, 2900)
			t.expectTrue(h >= HALF_SIZE.min and h <= HALF_SIZE.max, `{dd}: within the bounds`)
			t.expectTrue(h < sky, `{dd}: in front of the SkyCube ({h} vs {sky})`)
			if dd * HALF_SIZE.fraction >= HALF_SIZE.min then
				t.expectTrue(h <= HALF_SIZE.fraction * dd + 1e-9, `{dd}: face centres inside the draw distance`)
			end
		end
		t.expectEqual(FarLayerMath.halfSize(0 / 0, HALF_SIZE), HALF_SIZE.max, "unknown draw distance")
	end)

	t.test(
		"backdrop scale: one factor about the eye keeps directions and depth order, copies fit the part limit",
		function()
			-- bands like a plan's: the near square (2 km) and rings out to a high camera's horizon (300 km)
			local bands = {
				{ offset = Vector3.new(30, -12, 40), size = Vector3.new(2100, 300, 2100) },
				{ offset = Vector3.new(-400, -60, 900), size = Vector3.new(9000, 900, 9000) },
				{ offset = Vector3.new(2000, -400, -1500), size = Vector3.new(40000, 3000, 40000) },
				{ offset = Vector3.new(0, -9000, 0), size = Vector3.new(300000, 20000, 300000) },
			}
			for _, count in { 1, 2, 3, 4 } do
				local extent = 0
				for i = 1, count do
					local s = bands[i].size
					extent = math.max(extent, s.X, s.Y, s.Z)
				end
				local k = FarLayerMath.backdropScale(extent, PART_LIMIT)
				t.expectTrue(k > 0 and k <= 1, "a factor in (0, 1]")
				for i = 1, count do
					local s = bands[i].size * k
					t.expectTrue(math.max(s.X, s.Y, s.Z) <= PART_LIMIT * (1 + 1e-6), `{count} bands: band {i} fits`) -- (float32)
				end
				-- points of the bands (relative to the eye): same direction, all distances x k, so every pair keeps its
				-- order, and the scene stays within the copies' reach of the eye
				local reach = 0
				for i = 1, count do
					local b = bands[i]
					reach = math.max(reach, (b.offset.Magnitude + b.size.Magnitude / 2) * k)
				end
				t.expectTrue(reach <= 2 * PART_LIMIT, `{count} bands: the scene stays within {reach} studs`)
				for _ = 1, 400 do
					local b1 = bands[pick(count)]
					local b2 = bands[pick(count)]
					local q1 = b1.offset
						+ Vector3.new(uniform(-0.5, 0.5), uniform(-0.5, 0.5), uniform(-0.5, 0.5)) * b1.size
					local q2 = b2.offset
						+ Vector3.new(uniform(-0.5, 0.5), uniform(-0.5, 0.5), uniform(-0.5, 0.5)) * b2.size
					local p1, p2 = FarLayerMath.pose(q1, k), FarLayerMath.pose(q2, k)
					t.expectTrue((p1.Unit - q1.Unit).Magnitude < 1e-5, "same direction from the eye")
					t.expectTrue((q1.Magnitude < q2.Magnitude) == (p1.Magnitude < p2.Magnitude), "depth order kept")
				end
			end
		end
	)

	t.test("/farground: the tier's default until picked, toggles back and forth, reports each change once", function()
		local state = FarLayerMath.newModeState()
		t.expectEqual(FarLayerMath.modeOf(state, "layer"), "layer", "High / Medium default")
		t.expectEqual(FarLayerMath.modeOf(state, "mesh"), "mesh", "Low default")
		t.expectTrue(FarLayerMath.consumeChanged(state, true), "starts on: the bands are built for the layer")
		t.expectTrue(not FarLayerMath.consumeChanged(state, true), "reported once")
		t.expectEqual(FarLayerMath.toggle(state, "layer"), "mesh", "/farground: mesh")
		t.expectEqual(FarLayerMath.modeOf(state, "layer"), "mesh", "kept over the tier's default")
		t.expectEqual(FarLayerMath.modeOf(state, "mesh"), "mesh", "and over another tier's")
		t.expectTrue(FarLayerMath.consumeChanged(state, false), "the change is reported")
		t.expectTrue(not FarLayerMath.consumeChanged(state, false), "once")
		t.expectEqual(FarLayerMath.toggle(state, "layer"), "layer", "/farground again: layer")
		t.expectTrue(FarLayerMath.consumeChanged(state, true), "reported")
		local low = FarLayerMath.newModeState()
		t.expectTrue(not FarLayerMath.consumeChanged(low, false), "starting in mesh mode changes nothing")
		t.expectEqual(FarLayerMath.toggle(low, "mesh"), "layer", "Low: /farground turns the layer on")
		t.expectTrue(FarLayerMath.consumeChanged(low, true), "reported")
	end)

	-- CHANGED (Far layer fix)
	t.test("reach: every panel point lies within it, the cube's corners at it", function()
		for _, h in { 300, 640, 1020 } do
			local reach = FarLayerMath.reach(h, OVERLAP)
			local farthest = 0
			for _, face in FarLayerMath.FACES do
				for _, x in { -1, -0.5, 0, 0.5, 1 } do
					for _, y in { -1, -0.5, 0, 0.5, 1 } do
						local p = FarLayerMath.panelPoint(face, h, x * (1 + OVERLAP), y * (1 + OVERLAP))
						farthest = math.max(farthest, p.Magnitude)
						t.expectTrue(p.Magnitude <= reach + 1e-6, `h {h}: panel point within the reach`)
					end
				end
			end
			-- the panel's corner: the face's normal at h plus the overlapped half-sides
			t.expectTrue(farthest <= reach + 1e-6 and farthest >= h * math.sqrt(3) - 1e-6, `h {h}: corner`)
			t.expectTrue(reach <= 1.01 * 1020 * math.sqrt(3), "at most ~1.77 km (inside a 3000-stud draw distance)")
		end
	end)

	t.test("diagnostics: face list, re-parent timing, error clipping", function()
		t.expectEqual(FarLayerMath.faceList({ true, false, false, true, true, false }), "+X-Y+Z", "names in order")
		t.expectEqual(FarLayerMath.faceList({ false, false, false, false, false, false }), "none", "none")
		t.expectTrue(not FarLayerMath.kickDue(0.1, 0, KICK_DELAYS), "too early")
		t.expectTrue(FarLayerMath.kickDue(0.3, 0, KICK_DELAYS), "first re-parent")
		t.expectTrue(not FarLayerMath.kickDue(1, 1, KICK_DELAYS), "second: not yet")
		t.expectTrue(FarLayerMath.kickDue(2.5, 1, KICK_DELAYS), "second")
		t.expectTrue(not FarLayerMath.kickDue(100, 2, KICK_DELAYS), "never a third")
		t.expectEqual(FarLayerMath.clip("short", 20), "short", "kept")
		local long = FarLayerMath.clip("CreateMeshPartAsync:\n" .. string.rep("x", 200), 40)
		t.expectEqual(#long, 40, "clipped to the width")
		t.expectTrue(string.find(long, "\n") == nil, "one line")
	end)

	t.test("verdict: the first thing wrong, in pipeline order", function()
		local function stats(over: { [string]: any }): FarLayerMath.Stats
			local s: FarLayerMath.Stats =
				{ shown = true, bands = 5, faces = 3, copies = 15, valid = 15, pending = 0, failed = 0 }
			for key, value in over do
				(s :: any)[key] = value
			end
			return s
		end
		t.expectEqual(FarLayerMath.verdict(stats({})), "copies ok", "all right")
		t.expectEqual(FarLayerMath.verdict(stats({ shown = false, bands = 0 })), "hidden", "hidden first")
		t.expectEqual(FarLayerMath.verdict(stats({ bands = 0, copies = 0 })), "no bands from TerrainMesh", "bands")
		t.expectEqual(FarLayerMath.verdict(stats({ faces = 0, copies = 0 })), "no face drawn", "faces")
		t.expectEqual(FarLayerMath.verdict(stats({ copies = 0, valid = 0, pending = 4 })), "copies loading", "loading")
		t.expectEqual(FarLayerMath.verdict(stats({ copies = 0, valid = 0 })), "no copies made", "none made")
		t.expectEqual(FarLayerMath.verdict(stats({ valid = 12 })), "3 copies without a mesh", "meshless copies")
		t.expectEqual(FarLayerMath.verdict(stats({ failed = 2 })), "2 copies failed", "failures")
		t.expectEqual(FarLayerMath.verdict(stats({ pending = 1 })), "copies loading", "still loading")
	end)

	t.test("/farground test: each reference object lies whole inside one face camera's view", function()
		local half = math.sqrt(3) * TEST_SIZE / 2 -- the objects' bounding sphere
		local refs = {
			{ at = Vector3.new(0, TEST_LIFT, TEST_DISTANCE), face = 5, name = "red cube +Z" },
			{ at = Vector3.new(TEST_DISTANCE, TEST_LIFT, 0), face = 1, name = "green ball +X" },
			{ at = Vector3.new(0, TEST_LIFT, -TEST_DISTANCE), face = 6, name = "plain mesh -Z" },
		}
		local fov = FarLayerMath.fieldOfView(OVERLAP)
		for _, ref in refs do
			t.expectEqual(FarLayerMath.faceOf(ref.at), ref.face, ref.name .. ": its face")
			local face = FarLayerMath.FACES[ref.face]
			local cam = FarLayerMath.faceCamera(face)
			for _, d in { Vector3.xAxis, Vector3.yAxis, Vector3.zAxis } do
				for _, sign in { -1, 1 } do
					local x, y, ahead = screen(cam, fov, ref.at + d * sign * half)
					t.expectTrue(ahead and math.abs(x) < 1 and math.abs(y) < 1, ref.name .. ": inside the view")
				end
			end
			t.expectTrue(ref.at.Y - half > 0, ref.name .. ": above the eye's horizon")
		end
	end)
end
