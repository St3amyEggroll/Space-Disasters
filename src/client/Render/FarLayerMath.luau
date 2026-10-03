--!strict
--[[
	FarLayerMath (CHANGED (Far layer): new)
	The pure maths behind Render/FarLayer, the far-ground backdrop: no instances, no services, so the offline Lune
	spec (src/server/Tests/FarLayer.spec.luau) can check every mapping.

	The backdrop is a cube of six panels around the camera (workspace axes). Each panel shows a ViewportFrame whose
	camera sits at the cube's centre (the eye), looks along the face's outward normal with a 90-degree field of view
	and a square frame, so the six pictures form an exact cubemap: a direction d that leaves the cube through face n
	lands on that face's panel at the same point where the face camera draws it, (d . R / d . n, d . U / d . n) in
	[-1, 1]^2 (R = n x U), and neighbouring faces agree along their shared edge (the same cube point).

	  FACES                                 the six faces: normal, up (U) and right (R) vectors, workspace axes
	  fieldOfView(overlap)                  the face camera's FOV for panels `overlap` larger than their face
	  faceCamera(face)                      the face camera's CFrame at the origin (the eye), square frame
	  panelCFrame(face, halfSize)           the panel part's CFrame about the eye (its Front face looks at the eye)
	  project(face, dir)                    where the face camera draws a direction: x right, y up, in [-1, 1]
	  panelPoint(face, halfSize, x, y)      the point of the panel (about the eye) that shows (x, y)
	  guiPoint(face, halfSize, overlap, point)
	                                        the SurfaceGui position (x right, y up, [-1, 1]) of a panel point
	  faceOf(dir)                           the face a direction leaves the cube through
	  visibleFaces(look, up, fovY, aspect, margin, out)
	                                        which faces can show inside the camera's view (sampled, with a margin)
	  halfSize(drawDistance, params)        the cube's half-size: inside the draw distance and the SkyCube, one
	                                        part per face (the 2048-stud part limit)
	  backdropScale(maxExtent, partLimit)   the ONE factor every band is drawn at in the backdrop (about the eye)
	  pose(offset, scale)                   a band's place in the backdrop: offset (band centre - camera) x scale
	  newModeState() / modeOf(state, tierMode) / toggle(state, tierMode) / consumeChanged(state, active)
	                                        the /farground switch: the tier's default until the player picks
	CHANGED (Far layer fix): Studio drew no far ground in layer mode; the diagnostics' pure parts:
	  reach(halfSize, overlap)              the farthest panel point from the eye (a cube corner): other bodies'
	                                        proxies beyond it are hidden by the picture's ground, seen in its sky
	  FACE_NAMES                            "+X" ... "-Z" (the F3 line, the panel labels)
	  faceList(visible)                     the visible faces' names, e.g. "+X-Z-Y"
	  kickDue(age, kicks, delays)           a copy parented `age` s ago and re-parented `kicks` times is due another
	                                        re-parent (ViewportFrames may skip a mesh added before it loaded)
	  verdict(stats)                        the first thing wrong, in a few words (F3 line, [FarLayer] report)
	  clip(text, chars)                     one line of at most `chars` characters
CHANGED (Far layer smooth): Steamy: "game is super jittery, the ground and the rocket" with the layer on. The copies
were re-posed every frame the camera moved (every face re-rendered every band each frame). Now the backdrop scene is
STATIC (each band at its true place about a fixed anchor, x the one scale) and only each face's camera moves, and
only when the change would show (a fraction of a screen pixel). The pure parts:
  scenePoint(origin, cam, anchor, push, scale)
                                        a band's place in the static scene (doubles; a stale band pushed back
                                        about the camera, as TerrainMesh draws it)
  sceneCamera(face, toWorkspace, at)    a face camera in the scene's (body) axes: it sees what the workspace face
                                        camera would see of the band in workspace axes
  pixelAngle(pixels, fovY, viewportY)   radians a `pixels`-pixel shift at the screen centre is
  nearestGround(eye, size, inWorld, floor)
                                        how near the backdrop's visible ground can be (the near band's edge, or the
                                        height above it): a move of d shifts the picture by at most d / that
  turnAngle(a, b)                       the angle between two rotations (their axes; a threshold, not exact)
  viewDue(moved, turned, nearest, tolerance)
                                        the picture changed by more than `tolerance` radians
  daylight(sunUp, dark, lit)            0 at night .. 1 by day (smooth)
  viewportLight(params)                 the ViewportFrames' Ambient and LightColor matching the 3D near band's
                                        look at the seam (header of Render/FarLayer, DECISIONS D53)
  shade(albedo, ambient, light, sunUp)  a flat colour lit like flat ground in the ViewportFrames
  faceHeld(visibleNow, lastSeen, now, hold)
                                        a face stays drawn `hold` s after it left the view (no SurfaceGui churn)
]]

local FarLayerMath = {}

export type Face = {
	normal: Vector3,
	up: Vector3,
	right: Vector3, -- normal x up: the face camera's RightVector, the panel GUI's +x
}

export type HalfSizeParams = {
	fraction: number, -- x the draw distance (the panel's face centre must stay drawn)
	min: number, -- studs
	max: number, -- studs: one part per face (2 x max <= the part limit)
	skyFraction: number, -- SkyCube's fraction of the draw distance (the backdrop stays in front of it)
	skyMin: number, -- SkyCube's smallest half-size
}

local function newFace(normal: Vector3, up: Vector3): Face
	return table.freeze({ normal = normal, up = up, right = normal:Cross(up) })
end

-- +X, -X, +Y, -Y, +Z, -Z (SkyCube's up choice: Y on the side faces, X on the top and bottom)
FarLayerMath.FACES = table.freeze({
	newFace(Vector3.xAxis, Vector3.yAxis),
	newFace(-Vector3.xAxis, Vector3.yAxis),
	newFace(Vector3.yAxis, Vector3.xAxis),
	newFace(-Vector3.yAxis, Vector3.xAxis),
	newFace(Vector3.zAxis, Vector3.yAxis),
	newFace(-Vector3.zAxis, Vector3.yAxis),
}) :: { Face }

-- The face camera's vertical field of view (degrees; the frame is square, so the same across) for panels `overlap`
-- larger than their face (no hairline seam): 90 for none; the panel's picture then still matches the cube exactly
-- (its edge shows the direction 1 + overlap off the axis, where the panel's edge is).
function FarLayerMath.fieldOfView(overlap: number): number
	return 2 * math.deg(math.atan(1 + overlap))
end

function FarLayerMath.faceCamera(face: Face): CFrame
	return CFrame.fromMatrix(Vector3.zero, face.right, face.up, -face.normal)
end

-- The panel's Front face (-Z) looks back at the eye; its UpVector is the face's up, so the SurfaceGui on it reads
-- upright from the eye with +x along the face's right.
function FarLayerMath.panelCFrame(face: Face, halfSize: number): CFrame
	return CFrame.fromMatrix(face.normal * halfSize, -face.right, face.up, face.normal)
end

function FarLayerMath.project(face: Face, dir: Vector3): (number, number)
	local along = dir:Dot(face.normal)
	return dir:Dot(face.right) / along, dir:Dot(face.up) / along
end

function FarLayerMath.panelPoint(face: Face, halfSize: number, x: number, y: number): Vector3
	return (face.normal + face.right * x + face.up * y) * halfSize
end

-- A panel point (about the eye) in the GUI's terms (the panel is `overlap` larger than its face): the Front face is
-- seen from the eye, so +x is the part's -X.
function FarLayerMath.guiPoint(face: Face, halfSize: number, overlap: number, point: Vector3): (number, number)
	local lp = FarLayerMath.panelCFrame(face, halfSize):PointToObjectSpace(point)
	local half = halfSize * (1 + overlap)
	return -lp.X / half, lp.Y / half
end

function FarLayerMath.faceOf(dir: Vector3): number
	local best, index = -math.huge, 1
	for i, face in FarLayerMath.FACES do
		local along = dir:Dot(face.normal)
		if along > best then
			best, index = along, i
		end
	end
	return index
end

--[[
	Which faces can show inside a camera's view: rays over the view's frame (a GRID x GRID lattice, edges included)
	mark the faces they leave through, and every face within `margin` (radians, about the ray) of a ray too, so a
	face that only pokes in between two rays is still drawn. `out[i]` is set true / false for the six faces.
]]
local GRID = 7
function FarLayerMath.visibleFaces(
	look: Vector3,
	up: Vector3,
	fovY: number,
	aspect: number,
	margin: number,
	out: { boolean }
)
	for i = 1, 6 do
		out[i] = false
	end
	local right = look:Cross(up).Unit
	local trueUp = right:Cross(look).Unit
	local ty = math.tan(math.rad(fovY) / 2)
	local tx = ty * aspect
	-- a face is hit when its normal component is the largest; within the margin when it is at most this far behind
	local slack = math.sin(margin)
	for i = 0, GRID - 1 do
		for j = 0, GRID - 1 do
			local sx = (2 * i / (GRID - 1) - 1) * tx
			local sy = (2 * j / (GRID - 1) - 1) * ty
			local d = (look + right * sx + trueUp * sy).Unit
			local best = math.max(math.abs(d.X), math.abs(d.Y), math.abs(d.Z))
			for f, face in FarLayerMath.FACES do
				if not out[f] and d:Dot(face.normal) >= best - slack then
					out[f] = true
				end
			end
		end
	end
end

function FarLayerMath.halfSize(drawDistance: number, params: HalfSizeParams): number
	local dd = if drawDistance == drawDistance and drawDistance > 0 then drawDistance else 1e9
	local sky = math.max(params.skyFraction * dd, params.skyMin)
	return math.clamp(math.min(params.fraction * dd, 0.95 * sky), params.min, params.max)
end

function FarLayerMath.backdropScale(maxExtent: number, partLimit: number): number
	if maxExtent <= partLimit then
		return 1
	end
	return partLimit / maxExtent
end

function FarLayerMath.pose(offset: Vector3, scale: number): Vector3
	return offset * scale
end

-- The mode switch (/farground): the tier's default until the player picks one for the session; TerrainMesh is told
-- once after every change of the effective mode (its bands are rebuilt for it).
export type ModeState = {
	override: string?, -- "layer" | "mesh" picked with /farground (nil: the tier's default)
	reported: boolean?, -- the active state consumeChanged last reported (nil: never asked)
}

function FarLayerMath.newModeState(): ModeState
	return { override = nil, reported = nil }
end

function FarLayerMath.modeOf(state: ModeState, tierMode: string): string
	return state.override or tierMode
end

function FarLayerMath.toggle(state: ModeState, tierMode: string): string
	local mode = if FarLayerMath.modeOf(state, tierMode) == "layer" then "mesh" else "layer"
	state.override = mode
	return mode
end

-- True once after the effective mode changed (the first ask only when the layer starts on: the bands are built in
-- "mesh" mode's way otherwise anyway).
function FarLayerMath.consumeChanged(state: ModeState, active: boolean): boolean
	local last = state.reported
	if last == active then
		return false
	end
	state.reported = active
	return last ~= nil or active
end

--============================================================================
-- CHANGED (Far layer fix): diagnostics and the backdrop's reach
--============================================================================

-- The farthest point of the panels from the eye: a corner of the cube (the panels are `overlap` larger).
function FarLayerMath.reach(halfSize: number, overlap: number): number
	return halfSize * (1 + overlap) * math.sqrt(3)
end

FarLayerMath.FACE_NAMES = table.freeze({ "+X", "-X", "+Y", "-Y", "+Z", "-Z" }) :: { string }

function FarLayerMath.faceList(visible: { boolean }): string
	local names = {}
	for i, name in FarLayerMath.FACE_NAMES do
		if visible[i] then
			table.insert(names, name)
		end
	end
	return if #names > 0 then table.concat(names) else "none"
end

function FarLayerMath.kickDue(age: number, kicks: number, delays: { number }): boolean
	local next = delays[kicks + 1]
	return next ~= nil and age >= next
end

-- What the backdrop holds right now (FarLayer counts it for the F3 line and the [FarLayer] report).
export type Stats = {
	shown: boolean, -- the cube is in the world
	bands: number, -- bands TerrainMesh gave since clear()
	faces: number, -- faces drawn
	copies: number, -- band copies made (in the drawn faces)
	valid: number, -- ... of them with a mesh the engine reports (MeshContent set, MeshSize > 0)
	pending: number, -- CreateMeshPartAsync calls still running
	failed: number, -- copies that could not be made at all
}

-- The first thing wrong, in the order the pipeline runs; "copies ok" when every count is right, so a picture
-- without ground then means the ViewportFrames do not draw the copies (Studio's screenshot tells).
function FarLayerMath.verdict(s: Stats): string
	if not s.shown then
		return "hidden"
	elseif s.bands == 0 then
		return "no bands from TerrainMesh"
	elseif s.faces == 0 then
		return "no face drawn"
	elseif s.copies == 0 then
		return if s.pending > 0 then "copies loading" else "no copies made"
	elseif s.valid < s.copies then
		return string.format("%d copies without a mesh", s.copies - s.valid)
	elseif s.failed > 0 then
		return string.format("%d copies failed", s.failed)
	elseif s.pending > 0 then
		return "copies loading"
	end
	return "copies ok"
end

function FarLayerMath.clip(text: string, chars: number): string
	local line = string.gsub(text, "%s+", " ")
	if #line <= chars then
		return line
	end
	return string.sub(line, 1, math.max(chars - 3, 0)) .. "..."
end

--============================================================================
-- CHANGED (Far layer smooth): the static backdrop scene, its change thresholds and its light
--============================================================================

type Vec3dLike = { x: number, y: number, z: number }

-- A band's place in the scene: (its centre - the anchor) x scale, in doubles before the Vector3 (true positions
-- never go into a Vector3 unreduced, invariant I1). `push` > 1: a stale band drawn that much farther from the
-- camera (the same image, deeper: TerrainMesh's PUSH_BACK), so it moves with the camera while stale.
function FarLayerMath.scenePoint(
	origin: Vec3dLike,
	cam: Vec3dLike,
	anchor: Vec3dLike,
	push: number,
	scale: number
): Vector3
	local x = cam.x + (origin.x - cam.x) * push - anchor.x
	local y = cam.y + (origin.y - cam.y) * push - anchor.y
	local z = cam.z + (origin.z - cam.z) * push - anchor.z
	return Vector3.new(x * scale, y * scale, z * scale)
end

-- The face camera in the scene: at `at` (the eye's scene point), turned by the inverse of the body-to-workspace
-- rotation, so a scene direction d appears where the workspace face camera shows toWorkspace * d (the panels and
-- their cubemap stay in workspace axes; every turn and move of the pocket frame goes into these six CFrames).
function FarLayerMath.sceneCamera(face: Face, toWorkspace: CFrame, at: Vector3): CFrame
	return CFrame.new(at) * toWorkspace:Inverse() * FarLayerMath.faceCamera(face)
end

-- Radians that `pixels` pixels are at the centre of a view `fovY` degrees high and `viewportY` pixels tall.
function FarLayerMath.pixelAngle(pixels: number, fovY: number, viewportY: number): number
	local perRadian = (math.max(viewportY, 1) / 2) / math.tan(math.rad(math.clamp(fovY, 1, 179)) / 2)
	return pixels / perRadian
end

--[[
	How near the ground the backdrop shows can be to the eye. `eye` is the eye minus the near band's box centre in
	the band's own axes (y up), `size` its box. With the near band in the 3D world (true scale) it covers its own
	square, so the backdrop's visible ground starts at its edge: the horizontal distance to the edge (0 outside),
	combined with the height above its box. Without it (scaled at altitude) everything below is backdrop: the
	height above the box. Never below `floor`.
]]
function FarLayerMath.nearestGround(eye: Vector3, size: Vector3, inWorld: boolean, floor: number): number
	local above = math.max(eye.Y - size.Y / 2, 0)
	local distance = above
	if inWorld then
		local edge = math.max(math.min(size.X / 2 - math.abs(eye.X), size.Z / 2 - math.abs(eye.Z)), 0)
		distance = math.sqrt(edge * edge + above * above)
	end
	return math.max(distance, floor)
end

-- The angle between two rotations, from their axes (at most the true angle, at least ~0.7 of it: a threshold).
function FarLayerMath.turnAngle(a: CFrame, b: CFrame): number
	local function between(u: Vector3, v: Vector3): number
		return math.acos(math.clamp(u:Dot(v), -1, 1))
	end
	return math.max(
		between(a.LookVector, b.LookVector),
		between(a.UpVector, b.UpVector),
		between(a.RightVector, b.RightVector)
	)
end

-- A move of `moved` (true studs) shifts ground at least `nearest` away by at most moved / nearest radians, a turn
-- shifts everything by `turned`: due once the sum exceeds `tolerance`.
function FarLayerMath.viewDue(moved: number, turned: number, nearest: number, tolerance: number): boolean
	return moved / math.max(nearest, 1e-6) + turned > tolerance
end

function FarLayerMath.daylight(sunUp: number, dark: number, lit: number): number
	local x = math.clamp((sunUp - dark) / math.max(lit - dark, 1e-6), 0, 1)
	return x * x * (3 - 2 * x)
end

export type LightParams = {
	outdoor: Color3, -- Lighting.OutdoorAmbient
	brightness: number, -- Lighting.Brightness
	sunUp: number, -- the sun direction's up component (pocket axes)
	perBrightness: number, -- LightColor = Brightness x this (grey) before the gain
	floor: number, -- the ambient never below this grey
	gain: { number }, -- r, g, b: the 3D near band / the backdrop at the seam by day (measured, DECISIONS D53)
	dark: number, -- daylight(): sunUp where the gain is gone (night: the 3D world's sky light is dark too) ...
	lit: number, -- ... and where it is whole
}

--[[
	The ViewportFrames' light (DECISIONS D53, "Colour match"). A ViewportFrame lights a surface as
	albedo x (Ambient + LightColor x max(0, n . -LightDirection)); Roblox's 3D world adds the sky's diffuse and
	specular light, tone mapping and more, which a ViewportFrame cannot do. So the base light (OutdoorAmbient, never
	below `floor`, and a grey sun of Brightness x perBrightness) is multiplied per channel by the gain measured at
	the seam (`gain`, faded out toward night by daylight(sunUp)). LightColor cannot exceed 1: what it loses is
	moved into the ambient, exact for flat ground (n = up): (L x g - min(1, L x g)) x sunUp. Every channel is
	clamped to [0, 1].
]]
function FarLayerMath.viewportLight(p: LightParams): (Color3, Color3)
	local day = FarLayerMath.daylight(p.sunUp, p.dark, p.lit)
	local level = math.clamp(p.brightness * p.perBrightness, 0, 1)
	local up = math.max(p.sunUp, 0)
	local base = { p.outdoor.R, p.outdoor.G, p.outdoor.B }
	local ambient, light = table.create(3, 0), table.create(3, 0)
	for c = 1, 3 do
		local g = 1 + ((p.gain[c] or 1) - 1) * day
		local wanted = level * g
		light[c] = math.min(wanted, 1)
		ambient[c] = math.clamp(math.max(base[c], p.floor) * g + (wanted - light[c]) * up, 0, 1)
	end
	return Color3.new(ambient[1], ambient[2], ambient[3]), Color3.new(light[1], light[2], light[3])
end

-- A flat colour lit like flat ground in the ViewportFrames: the clear background's colour, so the picture's
-- anti-aliased edges (the horizon, the faces' borders) fade toward the ground's colour and not a stray one.
function FarLayerMath.shade(albedo: Color3, ambient: Color3, light: Color3, sunUp: number): Color3
	local up = math.max(sunUp, 0)
	return Color3.new(
		math.clamp(albedo.R * (ambient.R + light.R * up), 0, 1),
		math.clamp(albedo.G * (ambient.G + light.G * up), 0, 1),
		math.clamp(albedo.B * (ambient.B + light.B * up), 0, 1)
	)
end

-- A face stays drawn (its SurfaceGui enabled, its picture kept) while visible and for `hold` s after: turning back
-- and forth does not enable / disable SurfaceGuis (canvas memory) every few frames.
function FarLayerMath.faceHeld(visibleNow: boolean, lastSeen: number, now: number, hold: number): boolean
	return visibleNow or now - lastSeen < hold
end

return table.freeze(FarLayerMath)
