--!strict
--[[
	S1: Does the renderer cull a huge part by distance? A 2048-stud sphere (the maximum part size) is checked at
	2k, 5k, 10k and 20k studs from a viewpoint high above the baseplate, at graphics quality levels 1, 5 and 10.

	A Ball Part stands in for a MeshPart here; S6 repeats the distance check with an EditableMesh MeshPart.
	Atmosphere.Density is 0 and Lighting.FogEnd is 1e6 during the test (the game uses zero density in space), so a
	missing sphere means culling, not fog. The four spheres sit in a fan (one per compass direction) so only one is
	in view at a time.

	Automatic part: reports what the engine says the quality level is (UserGameSettings.SavedQualityLevel and
	settings().Rendering.QualityLevel, or the error), and for every sphere: WorldToViewportPoint (was it in frame),
	its angular size, and Stats.SceneTriangleCount / SceneDrawcallCount with the sphere in the world vs removed (a
	drop means the renderer really was drawing it).
	Visual part: Steamy sets a quality level, says which one, and answers one question per sphere. Repeat per level.
	Note: Studio's own Quality Level list runs Level01-Level21 while the in-game slider runs 1-10; the engine
	read-back in each pass records what was actually set.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local VIEWPOINT = Vector3.new(0, 1200, 0) -- high enough that the nearest sphere clears the baseplate
local SPHERE_SIZE = 2048 -- studs, the maximum part size
local SPHERES = {
	{ label = "RED", distance = 2000, yawDeg = 0, color = Color3.fromRGB(255, 40, 40) },
	{ label = "YELLOW", distance = 5000, yawDeg = 90, color = Color3.fromRGB(255, 220, 0) },
	{ label = "GREEN", distance = 10000, yawDeg = 180, color = Color3.fromRGB(40, 255, 70) },
	{ label = "BLUE", distance = 20000, yawDeg = 270, color = Color3.fromRGB(40, 90, 255) },
}
local QUALITY_OPTIONS = { "1", "5", "10", "Done" }
local SETTLE_TIME = 1.0 -- s after moving the camera before asking
local STATS_SETTLE_FRAMES = 10 -- frames after adding/removing a sphere before sampling Stats
local STATS_SAMPLE_FRAMES = 20 -- frames averaged per Stats sample
local TEST_FOG_END = 1e6
--============================================================================

type SphereSpec = { label: string, distance: number, yawDeg: number, color: Color3 }
type Sphere = { spec: SphereSpec, part: Part }
type SavedLighting = { atmosphere: Atmosphere?, density: number, fogEnd: number }

-- Yaw 0 looks down -Z (in front of the spawn), 90 down +X, and so on.
local function directionFor(yawDeg: number): Vector3
	local yaw = math.rad(yawDeg)
	return Vector3.new(math.sin(yaw), 0, -math.cos(yaw))
end

local function buildSpheres(): { Sphere }
	local spheres: { Sphere } = {}
	for _, spec in SPHERES do
		local part = Instance.new("Part")
		part.Name = `S1_{spec.label}_{spec.distance}`
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.one * SPHERE_SIZE
		part.Anchored = true
		part.CanCollide = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = spec.color
		part.Position = VIEWPOINT + directionFor(spec.yawDeg) * spec.distance
		part.Parent = Workspace
		table.insert(spheres, { spec = spec, part = part })
	end
	return spheres
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

-- What the engine reports as the current graphics quality (or the error it throws).
local function readQualitySettings(): string
	local okSaved, saved = pcall(function(): Enum.SavedQualitySetting
		return UserSettings():GetService("UserGameSettings").SavedQualityLevel
	end)
	local okRendering, rendering = pcall(function(): any
		return (settings().Rendering :: any).QualityLevel
	end)
	return string.format(
		"UserGameSettings.SavedQualityLevel = %s | settings().Rendering.QualityLevel = %s",
		if okSaved then tostring(saved) else "ERROR " .. tostring(saved),
		if okRendering then tostring(rendering) else "ERROR " .. tostring(rendering)
	)
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

-- Renderer load with the part in the world vs removed: if removing it lowers the counts, it was being drawn.
local function renderedCheck(part: BasePart): string
	local parent = part.Parent
	local ok, result = pcall(function(): string
		waitFrames(STATS_SETTLE_FRAMES)
		local shownTriangles, shownDrawcalls = sampleScene(STATS_SAMPLE_FRAMES)
		part.Parent = nil
		waitFrames(STATS_SETTLE_FRAMES)
		local hiddenTriangles, hiddenDrawcalls = sampleScene(STATS_SAMPLE_FRAMES)
		part.Parent = parent
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
	part.Parent = parent
	if ok then
		return result
	end
	return "Stats check ERROR: " .. tostring(result)
end

local function checkSphere(ctx: SpikeKit.ClientContext, camera: Camera, sphere: Sphere, level: string)
	local spec = sphere.spec
	local center = sphere.part.Position
	aimCamera(camera, VIEWPOINT, center)
	ctx.status(`S1 quality {level}: looking at the {spec.label} sphere, {spec.distance} studs away`)
	task.wait(SETTLE_TIME)

	local screen, onScreen = camera:WorldToViewportPoint(center)
	local viewport = camera.ViewportSize
	local halfAngle = math.asin(math.min(1, (SPHERE_SIZE / 2) / spec.distance))
	local pixels = viewport.Y * math.tan(halfAngle) / math.tan(math.rad(camera.FieldOfView / 2))

	local colorName = string.lower(spec.label)
	local answer = ctx.ask(
		`[Quality {level}] Is the {spec.label} sphere ({spec.distance} studs away) fully visible? It should be a round {colorName} disc in the centre of the screen.`,
		{ "Visible", "Missing", "Flickering/partial" }
	)
	ctx.status(`S1 quality {level}: measuring the {spec.label} sphere (it blinks once)`)
	local rendered = renderedCheck(sphere.part)
	ctx.report(
		string.format(
			"Quality %s | %s sphere at %d studs | answer: %s | onScreen=%s at (%.0f, %.0f) of %.0fx%.0f, depth %.0f | angular diameter %.2f deg (~%.0f px) | %s",
			level,
			spec.label,
			spec.distance,
			answer,
			tostring(onScreen),
			screen.X,
			screen.Y,
			viewport.X,
			viewport.Y,
			screen.Z,
			math.deg(2 * halfAngle),
			pixels,
			rendered
		)
	)
end

local function runTest(ctx: SpikeKit.ClientContext, camera: Camera, spheres: { Sphere })
	ctx.report("Quality settings at start: " .. readQualitySettings())
	ctx.report(
		string.format(
			"Sphere Size reads back as (%.0f, %.0f, %.0f); viewpoint (%.0f, %.0f, %.0f); camera FieldOfView %.1f, viewport %.0fx%.0f",
			spheres[1].part.Size.X,
			spheres[1].part.Size.Y,
			spheres[1].part.Size.Z,
			VIEWPOINT.X,
			VIEWPOINT.Y,
			VIEWPOINT.Z,
			camera.FieldOfView,
			camera.ViewportSize.X,
			camera.ViewportSize.Y
		)
	)

	local instructions = "S1: set graphics quality (1, 5 or 10), then pick it below. Pick Done after the last level."
	local passes = 0
	while true do
		ctx.status(instructions)
		local level = ctx.ask(
			"Which graphics quality level are you testing now? (Studio: File > Studio Settings > Rendering > Quality Level, or the in-game Esc menu Graphics slider in manual mode)",
			QUALITY_OPTIONS
		)
		if level == "Done" then
			break
		end
		passes += 1
		ctx.report(`--- Pass {passes}: quality level {level} (as picked) | engine says {readQualitySettings()}`)
		for _, sphere in spheres do
			checkSphere(ctx, camera, sphere, level)
		end
	end
	ctx.report(`Finished after {passes} pass(es)`)
end

local spike: SpikeKit.SpikeDef = {
	Id = "S1",
	Title = "Render distance of a 2048-stud sphere",
	Players = 1,
	Instructions = "The camera jumps high above the map and looks at 4 huge coloured spheres (2k/5k/10k/20k studs) one by one. Before each pass set the graphics quality level (1, then 5, then 10) and say which; answer whether each sphere is visible. Each sphere blinks once while it is measured. Pick Done to finish.",
	Server = nil,
	Client = function(ctx: SpikeKit.ClientContext)
		local player = ctx.player
		if not player.Character then
			player.CharacterAdded:Wait()
		end
		local camera = Workspace.CurrentCamera
		local saved = applyTestLighting()
		local spheres = buildSpheres()

		local ok, err = xpcall(function()
			runTest(ctx, camera, spheres)
		end, debug.traceback)

		for _, sphere in spheres do
			sphere.part:Destroy()
		end
		restoreLighting(saved)
		restoreCamera(camera, player)
		if not ok then
			error(err, 0)
		end
	end,
}

return spike
