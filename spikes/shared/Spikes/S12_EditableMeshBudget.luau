--!strict
--[[
	S12 (follow-up to S6): how many EditableMeshes / EditableImages fit in the memory budget, and can many MeshParts
	share ONE EditableMesh?

	S6 found: creating an EditableMesh failed with "reaching memory budget limits" after about 7 patches, and a
	MeshPart disappears when its EditableMesh is destroyed (so each proxy would keep its mesh alive). All 24 patches
	of a cube-sphere are congruent (rotations of the same quarter-face patch), so if many MeshParts can share one
	EditableMesh, a whole solar system needs only ONE mesh.

	Fully automatic, then one visual question.
]]

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local PATCH_N = 32 -- same patch as S6: 33x33 vertices, 2048 triangles
local BUDGET_TESTS = { { n = 8, cap = 400 }, { n = 32, cap = 200 }, { n = 64, cap = 100 } }
local IMAGE_TESTS = { { size = 256, cap = 200 }, { size = 1024, cap = 60 } }
local SHARED_COPIES = 24
local VIEWPOINT = Vector3.new(0, 2500, 0)
local GRID_SPACING = 260
local COPY_SIZE = 200
--============================================================================

-- Quarter of the +Y cube face (x, z in [-1, 0]) projected onto the unit sphere, vertices relative to the bounds
-- centre, counter-clockwise seen from outside (S6 verified this is the front face).
local function buildPatch(n: number): EditableMesh?
	local mesh: EditableMesh? = nil
	local ok = pcall(function()
		mesh = AssetService:CreateEditableMesh()
	end)
	if not ok or mesh == nil then
		return nil
	end
	local em = mesh :: EditableMesh

	local points: { Vector3 } = {}
	local minP = Vector3.new(math.huge, math.huge, math.huge)
	local maxP = -minP
	for i = 0, n do
		for j = 0, n do
			local p = Vector3.new(-1 + i / n, 1, -1 + j / n).Unit
			points[i * (n + 1) + j + 1] = p
			minP = minP:Min(p)
			maxP = maxP:Max(p)
		end
	end
	local centre = (minP + maxP) / 2

	local vertexIds: { number } = {}
	local normalIds: { number } = {}
	for index, p in points do
		vertexIds[index] = em:AddVertex(p - centre)
		normalIds[index] = em:AddNormal(p)
	end
	local function id(i: number, j: number): number
		return i * (n + 1) + j + 1
	end
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local a, b, c, d = id(i, j), id(i, j + 1), id(i + 1, j), id(i + 1, j + 1)
			local f1 = em:AddTriangle(vertexIds[a], vertexIds[b], vertexIds[c])
			em:SetFaceNormals(f1, { normalIds[a], normalIds[b], normalIds[c] })
			local f2 = em:AddTriangle(vertexIds[b], vertexIds[d], vertexIds[c])
			em:SetFaceNormals(f2, { normalIds[b], normalIds[d], normalIds[c] })
		end
	end
	return em
end

local function waitFrames(count: number)
	for _ = 1, count do
		RunService.RenderStepped:Wait()
	end
end

local function budgetTest(ctx: SpikeKit.ClientContext)
	for _, test in BUDGET_TESTS do
		local meshes: { EditableMesh } = {}
		local t0 = os.clock()
		for _ = 1, test.cap do
			local mesh = buildPatch(test.n)
			if mesh == nil then
				break
			end
			table.insert(meshes, mesh)
		end
		local count = #meshes
		local vertices = (test.n + 1) * (test.n + 1)
		ctx.report(
			string.format(
				"EditableMesh budget: N=%d (%d vertices, %d triangles each): created %d%s in %.0f ms (%d vertices total)",
				test.n,
				vertices,
				2 * test.n * test.n,
				count,
				if count >= test.cap then " (hit the test cap, no failure)" else " before the budget refused",
				(os.clock() - t0) * 1000,
				count * vertices
			)
		)
		for _, mesh in meshes do
			mesh:Destroy()
		end
		task.wait(0.5)
	end
	-- Is the budget released after Destroy?
	local again = buildPatch(PATCH_N)
	ctx.report(`After destroying everything, a new N={PATCH_N} EditableMesh can be created: {again ~= nil}`)
	if again then
		again:Destroy()
	end

	for _, test in IMAGE_TESTS do
		local images: { EditableImage } = {}
		for _ = 1, test.cap do
			local image: EditableImage? = nil
			local ok = pcall(function()
				image = AssetService:CreateEditableImage({ Size = Vector2.new(test.size, test.size) })
			end)
			if not ok or image == nil then
				break
			end
			table.insert(images, image :: EditableImage)
		end
		ctx.report(
			string.format(
				"EditableImage budget: %dx%d: created %d%s",
				test.size,
				test.size,
				#images,
				if #images >= test.cap then " (hit the test cap, no failure)" else " before the budget refused"
			)
		)
		for _, image in images do
			image:Destroy()
		end
		task.wait(0.5)
	end
end

local function sharedTest(ctx: SpikeKit.ClientContext): { () -> () }
	local created: { () -> () } = {}
	local mesh = buildPatch(PATCH_N)
	if mesh == nil then
		ctx.report("Shared-mesh test: could not create the EditableMesh (budget?)")
		return created
	end
	local sharedMesh = mesh :: EditableMesh
	table.insert(created, function()
		sharedMesh:Destroy()
	end)
	local content = Content.fromObject(mesh)
	local trianglesBefore = Stats.SceneTriangleCount

	-- (a) many CreateMeshPartAsync calls from the same EditableMesh
	local made = 0
	local firstError: string? = nil
	local parts: { MeshPart } = {}
	for index = 1, SHARED_COPIES do
		local ok, result = pcall(function()
			return AssetService:CreateMeshPartAsync(content)
		end)
		if ok and typeof(result) == "Instance" and result:IsA("MeshPart") then
			made += 1
			table.insert(parts, result)
		elseif firstError == nil then
			firstError = tostring(result)
		end
		if index % 6 == 0 then
			task.wait()
		end
	end
	ctx.report(
		`CreateMeshPartAsync x{SHARED_COPIES} from ONE EditableMesh: {made} succeeded{if firstError
			then "; first error: " .. firstError
			else ""}`
	)

	-- (b) Clone() of a MeshPart that uses the EditableMesh
	local cloneOk, cloneResult = pcall(function()
		return if parts[1] then parts[1]:Clone() else nil
	end)
	local clone = if cloneOk and typeof(cloneResult) == "Instance" then cloneResult :: MeshPart else nil
	ctx.report(`MeshPart:Clone() of a shared-mesh part: {if clone then "OK" else "failed: " .. tostring(cloneResult)}`)
	if clone then
		table.insert(parts, clone)
	end

	-- Lay them out in a grid facing the camera (each patch rotated a little so the shared mesh is obvious).
	local columns = 5
	for index, part in parts do
		local col = (index - 1) % columns
		local row = math.floor((index - 1) / columns)
		part.Size = Vector3.new(COPY_SIZE, COPY_SIZE * 0.6, COPY_SIZE)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Color = Color3.fromHSV((index - 1) / #parts, 0.7, 1)
		local position = VIEWPOINT
			+ Vector3.new((col - (columns - 1) / 2) * GRID_SPACING, (row - 2.5) * GRID_SPACING, -1600)
		-- rotate so the outside (+Y) of the patch faces the camera (+Z)
		part.CFrame = CFrame.new(position) * CFrame.Angles(math.rad(90), 0, math.rad(index * 15))
		part.Parent = Workspace
		table.insert(created, function()
			part:Destroy()
		end)
	end
	waitFrames(20)
	local trianglesAfter = Stats.SceneTriangleCount
	ctx.report(
		string.format(
			"Scene triangles with %d shared-mesh parts: %d more than before (full = %d)",
			#parts,
			trianglesAfter - trianglesBefore,
			#parts * 2 * PATCH_N * PATCH_N
		)
	)
	return created
end

local spike: SpikeKit.SpikeDef = {
	Id = "S12",
	Title = "EditableMesh budget + sharing one mesh",
	Players = 1,
	Instructions = "Automatic for ~30 s (Studio may print 'memory budget' warnings; copy them too), then one question about a grid of coloured patches.",
	Server = nil,
	Client = function(ctx: SpikeKit.ClientContext)
		local camera = Workspace.CurrentCamera
		local created: { () -> () } = {}
		local ok, err = xpcall(function()
			ctx.status("S12: measuring budgets...")
			budgetTest(ctx)
			ctx.status("S12: shared-mesh test...")
			created = sharedTest(ctx)
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = CFrame.lookAt(VIEWPOINT, VIEWPOINT + Vector3.new(0, 0, -1))
			ctx.status("")
			ctx.ask(
				"You should see a grid of up to 25 coloured curved patches (all using ONE shared mesh). What do you see?",
				{ "All patches visible", "Some missing", "None visible" }
			)
		end, debug.traceback)
		for index = #created, 1, -1 do
			created[index]()
		end
		local character = ctx.player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid then
			camera.CameraSubject = humanoid
		end
		camera.CameraType = Enum.CameraType.Custom
		if not ok then
			error(err, 0)
		end
	end,
}

return spike
