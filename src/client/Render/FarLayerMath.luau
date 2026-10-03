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

return table.freeze(FarLayerMath)
