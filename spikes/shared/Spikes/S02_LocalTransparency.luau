--!strict
--[[
	S2: What does LocalTransparencyModifier = 1 do on a NON-character part?
	  - Does it hide the part, its Decal, its Texture, its SurfaceGui and a BillboardGui adorned to it?
	  - Does the hidden part still cast a shadow?
	  - Does the hidden part still block client raycasts with default RaycastParams? (If yes, the game must use
	    Include filters for its own queries.)
	Then it checks the manual fallback (Decal/Texture Transparency, Gui Enabled, CastShadow) and that the modifier
	is per part inside a plain two-part Model (no Humanoid, no MeshParts).

	Not covered: setting LocalTransparencyModifier on a part inside ANOTHER player's character. That needs a
	2-player test (and the default camera scripts rewrite it every frame on the local character anyway).

	The camera is scripted and sits on the shadow side of the block, so the shadow falls toward the viewer.
	Lighting.ClockTime, GeographicLatitude (raised if needed so the sun is low enough for a long shadow) and
	GlobalShadows are restored afterwards.
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local BLOCK_SIZE = Vector3.new(8, 12, 8)
local BLOCK_POSITION = Vector3.new(0, 6, -30) -- standing on the baseplate in front of the spawn
local BLOCK_COLOR = Color3.fromRGB(225, 200, 160)
local DECAL_IMAGE = "rbxasset://textures/SpawnLocation.png" -- ships with the client, works offline
local TEXTURE_IMAGE = "rbxasset://textures/SpawnLocation.png"
local TEXTURE_TINT = Color3.fromRGB(60, 160, 255)
local TEXTURE_STUDS_PER_TILE = 3
local CLOCK_TIME = 14
local MAX_SUN_ELEVATION_DEG = 55 -- raise GeographicLatitude (5 deg steps) until the sun is this low: longer shadow
local CAMERA_BACK = 24 -- studs from the block toward the shadow side
local CAMERA_UP = 18
local CAMERA_RIGHT = 14 -- sideways, so the textured right face is visible
local SETTLE_TIME = 0.75 -- s after a change before asking
local READBACK_DELAY = 1 -- s before reading LocalTransparencyModifier back a second time
local MODEL_PART_SIZE = 4
local MODEL_OFFSETS = { -9, -15 } -- studs to the left of the block (block local X) for the two Model parts
--============================================================================

type Scene = {
	block: Part,
	decal: Decal,
	texture: Texture,
	surfaceGui: SurfaceGui,
	billboard: BillboardGui,
}
type SavedLighting = { clockTime: number, latitude: number, globalShadows: boolean }

local function sunElevationDeg(): number
	return math.deg(math.asin(math.clamp(Lighting:GetSunDirection().Y, -1, 1)))
end

-- Horizontal direction from the block toward where its shadow falls (the camera goes on that side).
local function shadowSide(): Vector3
	local sun = Lighting:GetSunDirection()
	local flat = Vector3.new(-sun.X, 0, -sun.Z)
	if flat.Magnitude < 0.05 then
		return Vector3.zAxis -- sun (almost) overhead: any side works, face the spawn
	end
	return flat.Unit
end

local function textLabel(text: string, color: Color3): TextLabel
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = color
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = text
	return label
end

-- The block's Back face (+Z local) faces the camera, its Right face (+X local) is angled toward the camera.
local function buildScene(towardCamera: Vector3): Scene
	local block = Instance.new("Part")
	block.Name = "S2_Block"
	block.Anchored = true
	block.Size = BLOCK_SIZE
	block.CFrame = CFrame.lookAt(BLOCK_POSITION, BLOCK_POSITION - towardCamera)
	block.Color = BLOCK_COLOR
	block.Material = Enum.Material.SmoothPlastic
	block.CastShadow = true
	block.Parent = Workspace

	local decal = Instance.new("Decal")
	decal.Face = Enum.NormalId.Back
	decal.Texture = DECAL_IMAGE
	decal.Parent = block

	local texture = Instance.new("Texture")
	texture.Face = Enum.NormalId.Right
	texture.Texture = TEXTURE_IMAGE
	texture.Color3 = TEXTURE_TINT
	texture.StudsPerTileU = TEXTURE_STUDS_PER_TILE
	texture.StudsPerTileV = TEXTURE_STUDS_PER_TILE
	texture.Parent = block

	local surfaceGui = Instance.new("SurfaceGui")
	surfaceGui.Face = Enum.NormalId.Top
	surfaceGui.Adornee = block
	surfaceGui.LightInfluence = 0
	surfaceGui.Parent = block
	textLabel("SURFACEGUI", Color3.fromRGB(255, 220, 0)).Parent = surfaceGui

	local billboard = Instance.new("BillboardGui")
	billboard.Adornee = block
	billboard.Size = UDim2.fromOffset(220, 60)
	billboard.StudsOffset = Vector3.new(0, BLOCK_SIZE.Y / 2 + 3, 0)
	billboard.LightInfluence = 0
	billboard.Parent = block
	textLabel("BILLBOARD", Color3.fromRGB(80, 255, 120)).Parent = billboard

	return {
		block = block,
		decal = decal,
		texture = texture,
		surfaceGui = surfaceGui,
		billboard = billboard,
	}
end

local function aimCamera(camera: Camera, towardCamera: Vector3, block: Part)
	local from = BLOCK_POSITION
		+ towardCamera * CAMERA_BACK
		+ block.CFrame.RightVector * CAMERA_RIGHT
		+ Vector3.yAxis * CAMERA_UP
	-- Aim between the block and its shadow, a bit below the block's centre.
	local at = BLOCK_POSITION + towardCamera * 3 - Vector3.yAxis * 3
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

-- Default RaycastParams, from the camera toward the block's centre.
local function raycastFromCamera(camera: Camera, block: Part): string
	local origin = camera.CFrame.Position
	local offset = block.Position - origin
	local result = Workspace:Raycast(origin, offset.Unit * (offset.Magnitude + 20))
	if result == nil then
		return "ray hit NOTHING"
	end
	return string.format(
		"ray hit %s at %.1f studs (is the block: %s)",
		result.Instance:GetFullName(),
		result.Distance,
		tostring(result.Instance == block)
	)
end

local function askHidden(ctx: SpikeKit.ClientContext, what: string): string
	return ctx.ask(
		`LocalTransparencyModifier = 1 is now set on the block. Look at {what}. Is it hidden?`,
		{ "Hidden", "Still visible", "Unsure" }
	)
end

local function stepBaseline(ctx: SpikeKit.ClientContext, camera: Camera, scene: Scene)
	ctx.status("S2 step 1/5: baseline")
	task.wait(SETTLE_TIME)
	ctx.report("Baseline raycast (default params): " .. raycastFromCamera(camera, scene.block))
	ctx.ask(
		"BASELINE: can you see the block, its DECAL (spawn logo, face toward you), its TEXTURE (blue tiles, right face), the SURFACEGUI text (top), the BILLBOARD text above it and the block's shadow on the floor?",
		{ "All visible", "Something missing" }
	)
end

local function stepModifier(ctx: SpikeKit.ClientContext, camera: Camera, scene: Scene)
	ctx.status("S2 step 2/5: LocalTransparencyModifier = 1 on the block")
	local block = scene.block
	local ok, err = pcall(function()
		block.LocalTransparencyModifier = 1
	end)
	local outcome = if ok then "no error" else "ERROR " .. tostring(err)
	ctx.report(`Setting LocalTransparencyModifier = 1 on a non-character part: {outcome}`)
	-- Decal and Texture have their own LocalTransparencyModifier: does the part's value propagate to them?
	local readOk, readBack = pcall(function(): string
		return string.format(
			"block %.3f, decal %.3f, texture %.3f",
			block.LocalTransparencyModifier,
			scene.decal.LocalTransparencyModifier,
			scene.texture.LocalTransparencyModifier
		)
	end)
	ctx.report(`Read back immediately: {if readOk then readBack else "ERROR " .. tostring(readBack)}`)
	task.wait(READBACK_DELAY)
	ctx.report(
		string.format(
			"Read back after %.1f s: block %.3f (still 1 = nothing resets it on non-character parts)",
			READBACK_DELAY,
			block.LocalTransparencyModifier
		)
	)

	askHidden(ctx, "the BLOCK itself (the sand-coloured box)")
	askHidden(ctx, "the DECAL (spawn logo on the face toward you)")
	askHidden(ctx, "the TEXTURE (small blue tiles on the block's right-hand face)")
	askHidden(ctx, "the yellow SURFACEGUI text on the block's top")
	askHidden(ctx, "the green BILLBOARD label floating above the block")
	ctx.ask(
		"LocalTransparencyModifier = 1 is set on the block. Look at the floor between the block and you. Is the block's SHADOW still there?",
		{ "Shadow still there", "Shadow gone", "Unsure" }
	)

	ctx.status("S2 step 3/5: raycast against the hidden block")
	ctx.report("Raycast with the block hidden (default params): " .. raycastFromCamera(camera, block))
	ctx.report(
		string.format(
			"Block CanQuery=%s CanCollide=%s LocalTransparencyModifier=%.3f",
			tostring(block.CanQuery),
			tostring(block.CanCollide),
			block.LocalTransparencyModifier
		)
	)
end

local function stepManualFallback(ctx: SpikeKit.ClientContext, scene: Scene)
	ctx.status("S2 step 4/5: manual fallback")
	scene.decal.Transparency = 1
	scene.texture.Transparency = 1
	scene.surfaceGui.Enabled = false
	scene.billboard.Enabled = false
	scene.block.CastShadow = false
	task.wait(SETTLE_TIME)
	local answer = ctx.ask(
		"FALLBACK: Decal/Texture Transparency = 1, both Guis Enabled = false, CastShadow = false (block keeps only LocalTransparencyModifier = 1). Is EVERYTHING gone now, including the shadow?",
		{ "All gone", "Something still visible" }
	)
	if answer ~= "All gone" then
		ctx.ask(
			"Which one is still visible? (If several, pick the first in the list.)",
			{ "Block", "Decal", "Texture", "SurfaceGui", "Billboard", "Shadow" }
		)
	end
end

-- Built up front (unparented) so cleanup always finds it; step 5 parents it.
local function buildModel(block: Part): (Model, { Part })
	local model = Instance.new("Model")
	model.Name = "S2_Model"
	local colors = { Color3.fromRGB(230, 50, 50), Color3.fromRGB(50, 200, 70) }
	local parts: { Part } = {}
	for index, offset in MODEL_OFFSETS do
		local part = Instance.new("Part")
		part.Name = if index == 1 then "Red" else "Green"
		part.Anchored = true
		part.Size = Vector3.one * MODEL_PART_SIZE
		part.Color = colors[index]
		part.Material = Enum.Material.SmoothPlastic
		part.CFrame = block.CFrame * CFrame.new(offset, (MODEL_PART_SIZE - BLOCK_SIZE.Y) / 2, 0)
		part.Parent = model
		table.insert(parts, part)
	end
	return model, parts
end

local function stepModel(ctx: SpikeKit.ClientContext, model: Model, parts: { Part })
	ctx.status("S2 step 5/5: plain two-part Model")
	model.Parent = Workspace
	task.wait(SETTLE_TIME)

	ctx.ask(
		"MODEL: a RED cube and a GREEN cube (one Model, plain Parts) now stand to the left of the block. Do you see both?",
		{ "Both visible", "Not both visible" }
	)

	parts[1].LocalTransparencyModifier = 1
	task.wait(SETTLE_TIME)
	ctx.ask(
		"LocalTransparencyModifier = 1 was set on the RED cube only. What do you see?",
		{ "Red hidden, green visible", "Both hidden", "Both visible", "Other" }
	)

	parts[2].LocalTransparencyModifier = 1
	task.wait(SETTLE_TIME)
	ctx.ask(
		"LocalTransparencyModifier = 1 is now set on BOTH cubes. Are both cubes hidden? (Ignore their shadows.)",
		{ "Both hidden", "Something still visible" }
	)
	ctx.report(
		string.format(
			"Model parts read back: red %.3f, green %.3f",
			parts[1].LocalTransparencyModifier,
			parts[2].LocalTransparencyModifier
		)
	)
end

local spike: SpikeKit.SpikeDef = {
	Id = "S2",
	Title = "LocalTransparencyModifier on world parts",
	Players = 1,
	Instructions = "The camera looks at a sand-coloured block (decal, blue texture, SURFACEGUI, BILLBOARD) in front of spawn. It gets hidden step by step; answer what you still see, including the block's shadow on the floor. About 12 questions, 5 steps.",
	Server = nil,
	Client = function(ctx: SpikeKit.ClientContext)
		local player = ctx.player
		if not player.Character then
			player.CharacterAdded:Wait()
		end
		local camera = Workspace.CurrentCamera
		local saved: SavedLighting = {
			clockTime = Lighting.ClockTime,
			latitude = Lighting.GeographicLatitude,
			globalShadows = Lighting.GlobalShadows,
		}
		Lighting.ClockTime = CLOCK_TIME
		Lighting.GlobalShadows = true
		for _ = 1, 10 do -- bounded: never more than 50 deg of extra latitude
			if sunElevationDeg() <= MAX_SUN_ELEVATION_DEG or Lighting.GeographicLatitude >= 85 then
				break
			end
			Lighting.GeographicLatitude = math.min(Lighting.GeographicLatitude + 5, 85)
		end

		local sun = Lighting:GetSunDirection()
		ctx.report(
			string.format(
				"Sun direction at ClockTime %.1f, latitude %.1f: (%.3f, %.3f, %.3f), elevation %.1f deg",
				Lighting.ClockTime,
				Lighting.GeographicLatitude,
				sun.X,
				sun.Y,
				sun.Z,
				sunElevationDeg()
			)
		)
		local towardCamera = shadowSide()
		local scene = buildScene(towardCamera)
		local model, modelParts = buildModel(scene.block)

		local ok, err = xpcall(function()
			aimCamera(camera, towardCamera, scene.block)
			stepBaseline(ctx, camera, scene)
			stepModifier(ctx, camera, scene)
			stepManualFallback(ctx, scene)
			stepModel(ctx, model, modelParts)
		end, debug.traceback)

		scene.block:Destroy()
		model:Destroy()
		Lighting.ClockTime = saved.clockTime
		Lighting.GeographicLatitude = saved.latitude
		Lighting.GlobalShadows = saved.globalShadows
		restoreCamera(camera, player)
		if not ok then
			error(err, 0)
		end
	end,
}

return spike
