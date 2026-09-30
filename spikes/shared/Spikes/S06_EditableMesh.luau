--!strict
--[[
	S6: Can we build planet surface patches at runtime with EditableMesh -> AssetService:CreateMeshPartAsync?
	  - Do the APIs work here at all? Errors ARE results (permission / publishing / verification messages).
	  - Build time (CreateEditableMesh, vertex + face fill, CreateMeshPartAsync) and memory, for one patch and for
	    a full 24-patch cube-sphere.
	  - Is the triangle winding right (visible from outside, culled from inside)?
	  - Is a MeshPart made this way culled by distance like the S1 Ball parts? Is it LOD-decimated?
	  - Can an EditableImage texture the patches (MeshPart.TextureContent = Content.fromObject(image))?
	  - Does the MeshPart keep rendering after its EditableMesh is destroyed (can we free the mesh data)?
	  - Is MeshPart.Size clamped to 2048 per axis?

	A patch is a quarter of one face of a cube-sphere (each face split 2x2), subdivided N x N. Vertices are the
	normalized cube points (unit sphere) with smooth normals (normal = vertex direction) and UVs 0..1 across the
	patch. Triangles are wound counter-clockwise seen from outside. Vertices are stored relative to the patch's
	bounding-box centre, so the MeshPart goes at (bounding-box centre x radius) with Size (bounding-box size x
	radius) whether or not the engine recentres meshes.

	Availability: in a PUBLISHED experience EditableMesh/EditableImage may require Game Settings > Security >
	"Allow Mesh / Image APIs" and possibly ID-verified accounts. The spike reports what actually happens here
	(game.PlaceId / game.CreatorId are 0 in an unpublished place). If the unpublished run works, Steamy should also
	run it once in a published copy. Universe rendering is client-only, so the whole spike runs on the client.
	Atmosphere.Density is 0 and FogEnd 1e6 during the test (the game uses zero density in space); restored after.
]]

local AssetService = game:GetService("AssetService")
local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local SUBDIVISIONS = 32 -- quads per patch edge: (N+1)^2 vertices and 2*N^2 triangles per patch
local SPLIT = 2 -- patches per cube-face edge (2 -> 4 patches per face, 24 per sphere)
local MAX_PART_SIZE = 2048 -- engine limit per axis
local VIEWPOINT = Vector3.new(0, 1500, 0) -- camera position for the distance and sphere views
local SINGLE_PATCH_POSITION = Vector3.new(0, 400, -3000)
local SINGLE_PATCH_WIDTH = 2000 -- studs across the single test patch
-- Winding views, measured from the centre of the patch's sphere along the patch's outward direction, in sphere
-- radii: > 1.25 sees every triangle from outside, anything between -1 and 1 is inside the sphere.
local OUTSIDE_VIEW_RADII = 3
local INSIDE_VIEW_RADII = -0.5
local CULL_DISTANCES = { 2000, 5000, 10000, 20000 }
local SPHERE_RADIUS = 2500
local SPHERE_CENTER = Vector3.new(0, 1500, -6000) -- 6000 studs in front of VIEWPOINT
local ORBIT_DURATION = 12 -- s for one camera orbit around the sphere
local ORBIT_MAX_ELEVATION_DEG = 60
local OVERSIZE_TEST = 4000
local TEXTURE_SIZE = 256
local CHECKER_CELLS = 8
local TEXTURE_BORDER_PX = 6
local COLLISION_FIDELITY = Enum.CollisionFidelity.Box -- CanCollide is off anyway; keeps the build cheap
local RENDER_FIDELITY = Enum.RenderFidelity.Automatic
local PATCH_COLOR = Color3.fromRGB(255, 140, 40)
local FACE_COLORS = {
	Color3.fromRGB(230, 70, 70), -- +X
	Color3.fromRGB(120, 40, 40), -- -X
	Color3.fromRGB(70, 200, 90), -- +Y
	Color3.fromRGB(30, 100, 50), -- -Y
	Color3.fromRGB(80, 130, 255), -- +Z
	Color3.fromRGB(40, 60, 140), -- -Z
}
local SETTLE_TIME = 1 -- s after moving the camera or a part before asking
local MEMORY_SETTLE_TIME = 2 -- s before reading memory stats (they update lazily)
local STATS_SETTLE_FRAMES = 10 -- frames after adding/removing something before sampling Stats
local STATS_SAMPLE_FRAMES = 20 -- frames averaged per Stats sample
local TEST_FOG_END = 1e6
--============================================================================

type Face = { name: string, normal: Vector3, axisA: Vector3, axisB: Vector3, color: Color3 }
type PatchSpec = { name: string, face: Face, u0: number, u1: number, v0: number, v1: number }
type Geometry = { directions: { Vector3 }, uvs: { Vector2 }, center: Vector3, size: Vector3 }
type Built = {
	mesh: EditableMesh,
	part: MeshPart,
	triangles: number,
	createMs: number,
	fillMs: number,
	partMs: number,
}
type Tracker = { instances: { Instance }, meshes: { EditableMesh }, images: { EditableImage } }
type MemorySample = { total: number, meshParts: number, texture: number }
type SavedLighting = { atmosphere: Atmosphere?, density: number, fogEnd: number }
type State = {
	ctx: SpikeKit.ClientContext,
	camera: Camera,
	tracker: Tracker,
	flipWinding: boolean,
	baseline: MemorySample?,
}

--============================================================================
-- Cube-sphere geometry
--============================================================================

-- axisB = normal x axisA, so (axisA, axisB, normal) is right-handed: stepping +u then +v runs counter-clockwise
-- when seen from outside the sphere.
local function makeFace(name: string, normal: Vector3, axisA: Vector3, color: Color3): Face
	return { name = name, normal = normal, axisA = axisA, axisB = normal:Cross(axisA), color = color }
end

local FACES: { Face } = {
	makeFace("+X", Vector3.xAxis, Vector3.yAxis, FACE_COLORS[1]),
	makeFace("-X", -Vector3.xAxis, Vector3.yAxis, FACE_COLORS[2]),
	makeFace("+Y", Vector3.yAxis, Vector3.zAxis, FACE_COLORS[3]),
	makeFace("-Y", -Vector3.yAxis, Vector3.zAxis, FACE_COLORS[4]),
	makeFace("+Z", Vector3.zAxis, Vector3.xAxis, FACE_COLORS[5]),
	makeFace("-Z", -Vector3.zAxis, Vector3.xAxis, FACE_COLORS[6]),
}

local function facePatches(face: Face): { PatchSpec }
	local patches: { PatchSpec } = {}
	local step = 2 / SPLIT
	for j = 0, SPLIT - 1 do
		for i = 0, SPLIT - 1 do
			table.insert(patches, {
				name = `{face.name}[{i},{j}]`,
				face = face,
				u0 = -1 + i * step,
				u1 = -1 + (i + 1) * step,
				v0 = -1 + j * step,
				v1 = -1 + (j + 1) * step,
			})
		end
	end
	return patches
end

-- Unit-sphere points of the patch, row by row (u fastest), plus their bounding box.
local function computeGeometry(patch: PatchSpec, n: number): Geometry
	local face = patch.face
	local count = (n + 1) * (n + 1)
	local directions: { Vector3 } = table.create(count)
	local uvs: { Vector2 } = table.create(count)
	local low = Vector3.one * math.huge
	local high = -low
	for j = 0, n do
		local tv = j / n
		local v = patch.v0 + (patch.v1 - patch.v0) * tv
		for i = 0, n do
			local tu = i / n
			local u = patch.u0 + (patch.u1 - patch.u0) * tu
			local direction = (face.normal + face.axisA * u + face.axisB * v).Unit
			table.insert(directions, direction)
			table.insert(uvs, Vector2.new(tu, tv))
			low = low:Min(direction)
			high = high:Max(direction)
		end
	end
	return { directions = directions, uvs = uvs, center = (low + high) / 2, size = high - low }
end

-- Fills an EditableMesh with the patch grid. Returns the triangle count.
local function fillMesh(mesh: EditableMesh, geometry: Geometry, n: number, flipWinding: boolean): number
	local count = #geometry.directions
	local vertexIds: { number } = table.create(count)
	local normalIds: { number } = table.create(count)
	local uvIds: { number } = table.create(count)
	for index, direction in geometry.directions do
		vertexIds[index] = mesh:AddVertex(direction - geometry.center)
		normalIds[index] = mesh:AddNormal(direction)
		uvIds[index] = mesh:AddUV(geometry.uvs[index])
	end

	local triangles = 0
	local function addTriangle(a: number, b: number, c: number)
		if flipWinding then
			b, c = c, b
		end
		local faceId = mesh:AddTriangle(vertexIds[a], vertexIds[b], vertexIds[c])
		mesh:SetFaceNormals(faceId, { normalIds[a], normalIds[b], normalIds[c] })
		mesh:SetFaceUVs(faceId, { uvIds[a], uvIds[b], uvIds[c] })
		triangles += 1
	end

	local row = n + 1
	for j = 0, n - 1 do
		for i = 0, n - 1 do
			local i00 = j * row + i + 1
			local i10 = i00 + 1
			local i01 = i00 + row
			local i11 = i01 + 1
			addTriangle(i00, i10, i11)
			addTriangle(i00, i11, i01)
		end
	end
	return triangles
end

--============================================================================
-- Engine helpers
--============================================================================

local function vectorText(v: Vector3): string
	return string.format("(%.3f, %.3f, %.3f)", v.X, v.Y, v.Z)
end

-- Runs fn; on error re-raises with the name of the call that failed.
local function attempt<T>(label: string, fn: () -> T): T
	local ok, result = pcall(fn)
	if not ok then
		error(`{label} failed: {result}`, 0)
	end
	return result
end

local function buildPatchPart(tracker: Tracker, geometry: Geometry, flipWinding: boolean): Built
	local t0 = os.clock()
	local mesh = attempt("AssetService:CreateEditableMesh", function(): EditableMesh
		return AssetService:CreateEditableMesh()
	end)
	local t1 = os.clock()
	table.insert(tracker.meshes, mesh)
	local triangles = attempt("EditableMesh fill", function(): number
		return fillMesh(mesh, geometry, SUBDIVISIONS, flipWinding)
	end)
	local t2 = os.clock()
	local part = attempt("AssetService:CreateMeshPartAsync", function(): MeshPart
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = COLLISION_FIDELITY,
			RenderFidelity = RENDER_FIDELITY,
		})
	end)
	local t3 = os.clock()
	table.insert(tracker.instances, part)
	part.Name = "S6_Patch"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.SmoothPlastic
	return {
		mesh = mesh,
		part = part,
		triangles = triangles,
		createMs = (t1 - t0) * 1000,
		fillMs = (t2 - t1) * 1000,
		partMs = (t3 - t2) * 1000,
	}
end

local function describeMeshContent(part: MeshPart, mesh: EditableMesh): string
	local ok, result = pcall(function(): string
		local content = part.MeshContent
		return string.format(
			"MeshPart.MeshContent SourceType=%s, Object is the EditableMesh=%s, Uri=%s",
			tostring(content.SourceType),
			tostring(content.Object == mesh),
			tostring(content.Uri)
		)
	end)
	return if ok then result else "MeshContent read ERROR: " .. tostring(result)
end

local function describeMeshBounds(mesh: EditableMesh): string
	local ok, result = pcall(function(): string
		return `EditableMesh:GetSize() {vectorText(mesh:GetSize())}, GetCenter() {vectorText(mesh:GetCenter())}`
	end)
	return if ok then result else "EditableMesh GetSize/GetCenter ERROR: " .. tostring(result)
end

local function sampleMemory(): (MemorySample?, string?)
	local ok, result = pcall(function(): MemorySample
		return {
			total = Stats:GetTotalMemoryUsageMb(),
			meshParts = Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.GraphicsMeshParts),
			texture = Stats:GetMemoryUsageMbForTag(Enum.DeveloperMemoryTag.GraphicsTexture),
		}
	end)
	if ok then
		return result, nil
	end
	return nil, tostring(result)
end

-- Waits for the stats to catch up, reports them (with deltas if `before` is given) and returns the sample.
local function memoryReport(ctx: SpikeKit.ClientContext, label: string, before: MemorySample?): MemorySample?
	task.wait(MEMORY_SETTLE_TIME)
	local sample, err = sampleMemory()
	if sample == nil then
		ctx.report(`Memory {label}: ERROR {err}`)
		return nil
	end
	if before then
		ctx.report(
			string.format(
				"Memory %s: total %.1f MB (%+.1f), GraphicsMeshParts %.2f MB (%+.2f), GraphicsTexture %.2f MB (%+.2f)",
				label,
				sample.total,
				sample.total - before.total,
				sample.meshParts,
				sample.meshParts - before.meshParts,
				sample.texture,
				sample.texture - before.texture
			)
		)
	else
		ctx.report(
			string.format(
				"Memory %s: total %.1f MB, GraphicsMeshParts %.2f MB, GraphicsTexture %.2f MB",
				label,
				sample.total,
				sample.meshParts,
				sample.texture
			)
		)
	end
	return sample
end

local function waitFrames(count: number)
	for _ = 1, count do
		RunService.RenderStepped:Wait()
	end
end

local function sampleScene(frames: number): (number, number)
	local triangles, drawcalls = 0, 0
	for _ = 1, frames do
		RunService.RenderStepped:Wait()
		triangles += Stats.SceneTriangleCount
		drawcalls += Stats.SceneDrawcallCount
	end
	return triangles / frames, drawcalls / frames
end

-- Renderer load with `target` in the world vs removed: if removing it lowers the counts, it was being drawn.
local function renderedCheck(target: Instance): string
	local parent = target.Parent
	local ok, result = pcall(function(): string
		waitFrames(STATS_SETTLE_FRAMES)
		local shownTriangles, shownDrawcalls = sampleScene(STATS_SAMPLE_FRAMES)
		target.Parent = nil
		waitFrames(STATS_SETTLE_FRAMES)
		local hiddenTriangles, hiddenDrawcalls = sampleScene(STATS_SAMPLE_FRAMES)
		target.Parent = parent
		local triangleDelta = shownTriangles - hiddenTriangles
		local drawcallDelta = shownDrawcalls - hiddenDrawcalls
		return string.format(
			"Stats: scene triangles %.0f with / %.0f without (delta %.0f), drawcalls %.1f / %.1f (delta %.1f) => %s",
			shownTriangles,
			hiddenTriangles,
			triangleDelta,
			shownDrawcalls,
			hiddenDrawcalls,
			drawcallDelta,
			if triangleDelta > 0.5 or drawcallDelta > 0.5 then "RENDERED" else "NOT RENDERED"
		)
	end)
	target.Parent = parent
	if ok then
		return result
	end
	return "Stats check ERROR: " .. tostring(result)
end

local function applyTestLighting(): SavedLighting
	local found = Lighting:FindFirstChildOfClass("Atmosphere")
	local atmosphere = if found and found:IsA("Atmosphere") then found else nil
	local saved: SavedLighting = {
		atmosphere = atmosphere,
		density = if atmosphere then atmosphere.Density else 0,
		fogEnd = Lighting.FogEnd,
	}
	if atmosphere then
		atmosphere.Density = 0
	end
	Lighting.FogEnd = TEST_FOG_END
	return saved
end

local function restoreLighting(saved: SavedLighting)
	local atmosphere = saved.atmosphere
	if atmosphere then
		atmosphere.Density = saved.density
	end
	Lighting.FogEnd = saved.fogEnd
end

local function aimCamera(camera: Camera, from: Vector3, at: Vector3)
	local cframe = CFrame.lookAt(from, at)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = cframe
	camera.Focus = cframe
end

local function restoreCamera(camera: Camera, player: Player)
	camera.CameraType = Enum.CameraType.Custom
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid and humanoid:IsA("Humanoid") then
		camera.CameraSubject = humanoid
	end
end

-- `distance` studs in front of VIEWPOINT (toward -Z), with the patch's outside (local +Y) facing the camera.
local function facingCamera(distance: number): CFrame
	return CFrame.fromMatrix(VIEWPOINT - Vector3.zAxis * distance, Vector3.xAxis, Vector3.zAxis)
end

local function singlePatchScale(geometry: Geometry): number
	local size = geometry.size
	return math.min(SINGLE_PATCH_WIDTH / math.max(size.X, size.Z), MAX_PART_SIZE / math.max(size.X, size.Y, size.Z))
end

-- Camera position for a winding view of the placed single patch (see OUTSIDE_VIEW_RADII).
local function singlePatchView(geometry: Geometry, radii: number): Vector3
	local scale = singlePatchScale(geometry)
	local sphereCenter = SINGLE_PATCH_POSITION - geometry.center * scale
	return sphereCenter + geometry.center.Unit * scale * radii
end

local function placeSinglePatch(part: MeshPart, geometry: Geometry)
	part.Size = geometry.size * singlePatchScale(geometry)
	part.CFrame = CFrame.new(SINGLE_PATCH_POSITION)
	part.Color = PATCH_COLOR
	part.Parent = Workspace
end

local function orbit(camera: Camera)
	local distance = (VIEWPOINT - SPHERE_CENTER).Magnitude
	local start = os.clock()
	while true do
		local alpha = math.min((os.clock() - start) / ORBIT_DURATION, 1)
		local theta = alpha * 2 * math.pi
		local elevation = math.rad(ORBIT_MAX_ELEVATION_DEG) * math.sin(theta)
		local offset = Vector3.new(
			math.sin(theta) * math.cos(elevation),
			math.sin(elevation),
			math.cos(theta) * math.cos(elevation)
		)
		aimCamera(camera, SPHERE_CENTER + offset * distance, SPHERE_CENTER)
		if alpha >= 1 then
			return
		end
		RunService.RenderStepped:Wait()
	end
end

-- RGBA8 checkerboard: coloured squares (red = U, green = V) and dark squares, white border on every edge.
local function makeCheckerPixels(): buffer
	local pixels = buffer.create(TEXTURE_SIZE * TEXTURE_SIZE * 4)
	local cellSize = TEXTURE_SIZE / CHECKER_CELLS
	local last = TEXTURE_SIZE - 1
	for y = 0, last do
		for x = 0, last do
			local r, g, b = 30, 30, 30
			if
				x < TEXTURE_BORDER_PX
				or y < TEXTURE_BORDER_PX
				or x > last - TEXTURE_BORDER_PX
				or y > last - TEXTURE_BORDER_PX
			then
				r, g, b = 255, 255, 255
			elseif (math.floor(x / cellSize) + math.floor(y / cellSize)) % 2 == 0 then
				r, g, b = math.floor(255 * x / last), math.floor(255 * y / last), 220
			end
			local offset = (y * TEXTURE_SIZE + x) * 4
			buffer.writeu8(pixels, offset, r)
			buffer.writeu8(pixels, offset + 1, g)
			buffer.writeu8(pixels, offset + 2, b)
			buffer.writeu8(pixels, offset + 3, 255)
		end
	end
	return pixels
end

--============================================================================
-- Steps
--============================================================================

local function probeApis(ctx: SpikeKit.ClientContext): (boolean, boolean)
	local meshOk, mesh = pcall(function(): EditableMesh
		return AssetService:CreateEditableMesh()
	end)
	if meshOk then
		ctx.report("Probe: AssetService:CreateEditableMesh() OK")
		mesh:Destroy()
	else
		ctx.report("Probe: AssetService:CreateEditableMesh() FAILED: " .. tostring(mesh))
	end
	local imageOk, image = pcall(function(): EditableImage
		return AssetService:CreateEditableImage({ Size = Vector2.new(16, 16) })
	end)
	if imageOk then
		ctx.report("Probe: AssetService:CreateEditableImage({Size = 16x16}) OK")
		image:Destroy()
	else
		ctx.report("Probe: AssetService:CreateEditableImage({Size = 16x16}) FAILED: " .. tostring(image))
	end
	return meshOk, imageOk
end

local function stepSinglePatch(state: State): (Built?, Geometry)
	local ctx = state.ctx
	ctx.status("S6: building one patch")
	local spec = facePatches(FACES[3])[1] -- +Y face, first quarter
	local g0 = os.clock()
	local geometry = computeGeometry(spec, SUBDIVISIONS)
	local geometryMs = (os.clock() - g0) * 1000
	local ok, result = pcall(function(): Built
		return buildPatchPart(state.tracker, geometry, state.flipWinding)
	end)
	if not ok then
		ctx.report("Single patch FAILED: " .. tostring(result))
		return nil, geometry
	end
	local built = result
	ctx.report(
		string.format(
			"Single patch %s: %d vertices, %d triangles | geometry %.2f ms, CreateEditableMesh %.2f ms, fill %.2f ms, CreateMeshPartAsync %.2f ms (wall clock, includes any yield)",
			spec.name,
			#geometry.directions,
			built.triangles,
			geometryMs,
			built.createMs,
			built.fillMs,
			built.partMs
		)
	)
	ctx.report(
		string.format(
			"Fresh MeshPart: Size %s, MeshSize %s | patch bounds on the unit sphere %s centred at %s",
			vectorText(built.part.Size),
			vectorText(built.part.MeshSize),
			vectorText(geometry.size),
			vectorText(geometry.center)
		)
	)
	ctx.report(describeMeshBounds(built.mesh))
	ctx.report(describeMeshContent(built.part, built.mesh))
	placeSinglePatch(built.part, geometry)
	ctx.report("Single patch placed: Size reads back as " .. vectorText(built.part.Size))
	memoryReport(ctx, "after the single patch (vs baseline)", state.baseline)
	return built, geometry
end

-- Looks at the patch from outside and from inside. Rebuilds it with flipped winding if only the inside shows.
local function stepWinding(state: State, single: Built, geometry: Geometry): Built
	local ctx, camera = state.ctx, state.camera
	local outsideView = singlePatchView(geometry, OUTSIDE_VIEW_RADII)
	aimCamera(camera, outsideView, SINGLE_PATCH_POSITION)
	ctx.status("S6: winding check, view from above (outside)")
	task.wait(SETTLE_TIME)
	local above = ctx.ask(
		"VIEW FROM ABOVE (outside): an orange curved patch (a piece of a big sphere's surface, 2000 studs wide, bulging toward you) should be in the centre. What do you see?",
		{ "Smooth curved patch", "Faceted/odd shape", "Nothing there" }
	)
	aimCamera(camera, singlePatchView(geometry, INSIDE_VIEW_RADII), SINGLE_PATCH_POSITION)
	ctx.status("S6: winding check, view from below (inside)")
	task.wait(SETTLE_TIME)
	local below = ctx.ask(
		"VIEW FROM BELOW (inside): the camera now looks up into the same patch from inside its sphere. Is the orange patch visible?",
		{ "Visible from below", "Nothing there" }
	)

	local fromOutside = above ~= "Nothing there"
	local fromInside = below ~= "Nothing there"
	if fromOutside and not fromInside then
		ctx.report("Winding verdict: counter-clockwise seen from outside is the FRONT face, single-sided. Correct.")
		return single
	elseif fromOutside then
		ctx.report("Winding verdict: visible from BOTH sides (drawn double-sided). Keeping counter-clockwise.")
		return single
	elseif not fromInside then
		ctx.report("Winding verdict: visible from NEITHER side. Continuing; later visual answers may be moot.")
		return single
	end

	ctx.report("Winding verdict: only visible from INSIDE, so clockwise is the front face. Rebuilding flipped.")
	state.flipWinding = true
	single.part:Destroy()
	pcall(function()
		single.mesh:Destroy()
	end)
	local rebuilt = buildPatchPart(state.tracker, geometry, true)
	placeSinglePatch(rebuilt.part, geometry)
	aimCamera(camera, outsideView, SINGLE_PATCH_POSITION)
	task.wait(SETTLE_TIME)
	ctx.ask(
		"REBUILT with flipped winding. VIEW FROM ABOVE (outside): is the orange curved patch visible now?",
		{ "Visible now", "Still nothing" }
	)
	return rebuilt
end

local function stepDistance(state: State, single: Built)
	local ctx, camera = state.ctx, state.camera
	local part = single.part
	aimCamera(camera, VIEWPOINT, VIEWPOINT - Vector3.zAxis)
	for _, distance in CULL_DISTANCES do
		part.CFrame = facingCamera(distance)
		ctx.status(`S6: patch at {distance} studs`)
		task.wait(SETTLE_TIME)
		local screen, onScreen = camera:WorldToViewportPoint(part.Position)
		local answer = ctx.ask(
			`DISTANCE: the orange patch ({SINGLE_PATCH_WIDTH} studs wide, outside facing you) is now {distance} studs away in the centre of the screen. Is it visible?`,
			{ "Visible", "Missing", "Flickering/partial" }
		)
		ctx.status(`S6: measuring the patch at {distance} studs (it blinks once)`)
		ctx.report(
			string.format(
				"MeshPart patch at %d studs | answer: %s | onScreen=%s at (%.0f, %.0f), depth %.0f | %s (full mesh = %d triangles; fewer = LOD)",
				distance,
				answer,
				tostring(onScreen),
				screen.X,
				screen.Y,
				screen.Z,
				renderedCheck(part),
				single.triangles
			)
		)
	end
end

local function stepOversize(state: State, single: Built)
	local part = single.part
	local original = part.Size
	local ok, err = pcall(function()
		part.Size = Vector3.new(OVERSIZE_TEST, original.Y, original.Z)
	end)
	local outcome = if ok then "no error" else "ERROR " .. tostring(err)
	state.ctx.report(
		string.format(
			"MeshPart Size.X set to %d: %s; Size reads back as %s (limit per axis %d)",
			OVERSIZE_TEST,
			outcome,
			vectorText(part.Size),
			MAX_PART_SIZE
		)
	)
	part.Size = original
end

-- Can the EditableMesh be freed once the MeshPart exists?
local function stepDestroyMesh(state: State, single: Built)
	local ctx, camera = state.ctx, state.camera
	local part = single.part
	part.CFrame = facingCamera(CULL_DISTANCES[1])
	aimCamera(camera, VIEWPOINT, VIEWPOINT - Vector3.zAxis)
	ctx.status("S6: destroying the patch's EditableMesh")
	local before = memoryReport(ctx, "before destroying the single patch's EditableMesh", nil)
	local ok, err = pcall(function()
		single.mesh:Destroy()
	end)
	local outcome = if ok then "no error" else "ERROR " .. tostring(err)
	ctx.report("EditableMesh:Destroy() while its MeshPart is alive: " .. outcome)
	task.wait(SETTLE_TIME)
	ctx.report("After destroy: " .. describeMeshContent(part, single.mesh))
	ctx.ask(
		"The patch's EditableMesh was just destroyed; the MeshPart was kept. Is the orange patch still visible in the centre, unchanged?",
		{ "Still visible", "Disappeared", "Changed/broken" }
	)
	ctx.report("After destroy: " .. renderedCheck(part))
	memoryReport(ctx, "after destroying the single patch's EditableMesh", before)
	part:Destroy()
end

local function stepSphere(state: State): { MeshPart }
	local ctx, camera = state.ctx, state.camera
	ctx.status("S6: building a 24-patch cube-sphere")
	local before = memoryReport(ctx, "before the sphere", nil)
	local folder = Instance.new("Folder")
	folder.Name = "S6_Sphere"
	folder.Parent = Workspace
	table.insert(state.tracker.instances, folder)

	local parts: { MeshPart } = {}
	local geometryMs, createMs, fillMs, partMs = 0, 0, 0, 0
	local triangles = 0
	local largestWanted, largestReadBack = 0, 0
	local oversize: { string } = {}
	local start = os.clock()
	local ok, err = pcall(function()
		for _, face in FACES do
			for _, patch in facePatches(face) do
				local g0 = os.clock()
				local geometry = computeGeometry(patch, SUBDIVISIONS)
				geometryMs += (os.clock() - g0) * 1000
				local built = buildPatchPart(state.tracker, geometry, state.flipWinding)
				createMs += built.createMs
				fillMs += built.fillMs
				partMs += built.partMs
				triangles += built.triangles

				local size = geometry.size * SPHERE_RADIUS
				local wanted = math.max(size.X, size.Y, size.Z)
				if wanted > MAX_PART_SIZE then
					table.insert(oversize, `{patch.name} {vectorText(size)}`)
				end
				local part = built.part
				part.Size = size
				part.CFrame = CFrame.new(SPHERE_CENTER + geometry.center * SPHERE_RADIUS)
				part.Color = face.color
				part.Parent = folder
				largestWanted = math.max(largestWanted, wanted)
				largestReadBack = math.max(largestReadBack, part.Size.X, part.Size.Y, part.Size.Z)
				table.insert(parts, part)
			end
			task.wait() -- keep the client responsive between faces
		end
	end)
	local wallMs = (os.clock() - start) * 1000
	if not ok then
		ctx.report(`Sphere build FAILED after {#parts} patches: {err}`)
	end
	local divisor = math.max(#parts, 1)
	ctx.report(
		string.format(
			"Sphere: %d patches, %d triangles in %.0f ms wall (incl. one frame yield per face) | sums: geometry %.1f ms, CreateEditableMesh %.1f ms, fill %.1f ms, CreateMeshPartAsync %.1f ms | per patch: %.2f / %.2f / %.2f / %.2f ms",
			#parts,
			triangles,
			wallMs,
			geometryMs,
			createMs,
			fillMs,
			partMs,
			geometryMs / divisor,
			createMs / divisor,
			fillMs / divisor,
			partMs / divisor
		)
	)
	ctx.report(
		string.format(
			"Sphere radius %d: largest wanted patch axis %.1f studs, largest read back %.1f; patches over %d: %s",
			SPHERE_RADIUS,
			largestWanted,
			largestReadBack,
			MAX_PART_SIZE,
			if #oversize > 0 then table.concat(oversize, ", ") else "none"
		)
	)
	memoryReport(ctx, "after the sphere", before)
	if #parts == 0 then
		return parts
	end

	aimCamera(camera, VIEWPOINT, SPHERE_CENTER)
	task.wait(SETTLE_TIME)
	while true do
		ctx.status("S6: watch the sphere while the camera orbits around it")
		orbit(camera)
		ctx.status("")
		local answer = ctx.ask(
			"The camera orbited a sphere of 24 patches (6 colours, one per cube face). Did you see a complete sphere with no gaps or missing patches?",
			{ "Complete", "Gaps/missing patches", "Nothing visible", "Replay orbit" }
		)
		if answer ~= "Replay orbit" then
			break
		end
	end
	aimCamera(camera, VIEWPOINT, SPHERE_CENTER)
	ctx.status("S6: measuring the sphere (it blinks once)")
	ctx.report(
		string.format(
			"Whole sphere from %.0f studs: %s (full sphere = %d triangles; fewer = LOD)",
			(SPHERE_CENTER - VIEWPOINT).Magnitude,
			renderedCheck(folder),
			triangles
		)
	)
	return parts
end

local function stepTexture(state: State, parts: { MeshPart })
	local ctx, camera = state.ctx, state.camera
	ctx.status("S6: texturing the sphere with an EditableImage")
	local before = memoryReport(ctx, "before the EditableImage", nil)
	local t0 = os.clock()
	local ok, result = pcall(function(): EditableImage
		return AssetService:CreateEditableImage({ Size = Vector2.new(TEXTURE_SIZE, TEXTURE_SIZE) })
	end)
	local createMs = (os.clock() - t0) * 1000
	if not ok then
		ctx.report("AssetService:CreateEditableImage FAILED: " .. tostring(result))
		return
	end
	local image = result
	table.insert(state.tracker.images, image)

	local t1 = os.clock()
	local pixels = makeCheckerPixels()
	local t2 = os.clock()
	local writeOk, writeErr = pcall(function()
		image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)
	end)
	local t3 = os.clock()
	local writeOutcome = if writeOk then "OK" else "ERROR " .. tostring(writeErr)
	ctx.report(
		string.format(
			"EditableImage %dx%d: create %.2f ms, Lua pixel fill %.2f ms, WritePixelsBuffer %.2f ms (%s)",
			TEXTURE_SIZE,
			TEXTURE_SIZE,
			createMs,
			(t2 - t1) * 1000,
			(t3 - t2) * 1000,
			writeOutcome
		)
	)

	local applied = 0
	local firstError: string? = nil
	local t4 = os.clock()
	for _, part in parts do
		local assignOk, assignErr = pcall(function()
			part.TextureContent = Content.fromObject(image)
		end)
		if assignOk then
			applied += 1
		elseif firstError == nil then
			firstError = tostring(assignErr)
		end
	end
	ctx.report(
		string.format(
			"MeshPart.TextureContent = Content.fromObject(image) (one image shared): %d/%d patches OK in %.2f ms%s",
			applied,
			#parts,
			(os.clock() - t4) * 1000,
			if firstError then ", first error: " .. firstError else ""
		)
	)

	aimCamera(camera, VIEWPOINT, SPHERE_CENTER)
	task.wait(SETTLE_TIME)
	ctx.ask(
		"The sphere patches should now show a TEXTURE: coloured and dark checker squares with a white border around each patch. What do you see?",
		{ "Texture visible", "Still plain colours", "Patches black/missing" }
	)
	memoryReport(ctx, "after texturing", before)
end

local function runSpike(state: State)
	local ctx = state.ctx
	ctx.report(
		string.format(
			"PlaceId=%d CreatorId=%d GameId=%d IsStudio=%s | N=%d, %d patches per face | CollisionFidelity %s, RenderFidelity %s",
			game.PlaceId,
			game.CreatorId,
			game.GameId,
			tostring(RunService:IsStudio()),
			SUBDIVISIONS,
			SPLIT * SPLIT,
			tostring(COLLISION_FIDELITY),
			tostring(RENDER_FIDELITY)
		)
	)
	state.baseline = memoryReport(ctx, "baseline", nil)

	local meshOk, imageOk = probeApis(ctx)
	if not meshOk then
		ctx.report("EditableMesh unavailable: every mesh step skipped")
		return
	end

	local single, geometry = stepSinglePatch(state)
	if single == nil then
		ctx.report("Single patch failed: sphere and texture steps skipped")
		return
	end
	single = stepWinding(state, single, geometry)
	stepDistance(state, single)
	stepOversize(state, single)
	stepDestroyMesh(state, single)

	local parts = stepSphere(state)
	if #parts == 0 then
		return
	end
	if imageOk then
		stepTexture(state, parts)
	else
		ctx.report("EditableImage unavailable: texture step skipped")
	end
end

local function cleanup(tracker: Tracker)
	for _, instance in tracker.instances do
		instance:Destroy()
	end
	for _, mesh in tracker.meshes do
		pcall(function()
			mesh:Destroy()
		end)
	end
	for _, image in tracker.images do
		pcall(function()
			image:Destroy()
		end)
	end
	table.clear(tracker.instances)
	table.clear(tracker.meshes)
	table.clear(tracker.images)
end

local spike: SpikeKit.SpikeDef = {
	Id = "S6",
	Title = "EditableMesh sphere patches",
	Players = 1,
	Instructions = "Builds an orange curved patch from an EditableMesh: say if you see it from above and from below, then at 2k-20k studs, then after its mesh data is freed. Then a 24-patch coloured sphere (the camera orbits it; look for gaps) gets a checker texture. About 12 questions; the client may stutter while building.",
	Server = nil,
	Client = function(ctx: SpikeKit.ClientContext)
		local player = ctx.player
		if not player.Character then
			player.CharacterAdded:Wait()
		end
		local state: State = {
			ctx = ctx,
			camera = Workspace.CurrentCamera,
			tracker = { instances = {}, meshes = {}, images = {} },
			flipWinding = false,
			baseline = nil,
		}
		local savedLighting = applyTestLighting()

		local ok, err = xpcall(function()
			runSpike(state)
		end, debug.traceback)

		cleanup(state.tracker)
		restoreLighting(savedLighting)
		restoreCamera(state.camera, player)
		memoryReport(ctx, "after cleanup (vs baseline)", state.baseline)
		if not ok then
			error(err, 0)
		end
	end,
}

return spike
