--!strict
--[[
	S11 (follow-up to S1): at which distance does each graphics quality level stop drawing a part, and does the
	distance depend on the part's size?

	S1 found that at quality 1 and 5 a 2048-stud sphere was not drawn even 2000 studs away, while quality 10 drew it
	at 20000. The universe renderer puts scaled-space bodies 400-1800 studs from the camera, so we need the actual
	cut-off per quality level and part size.

	Fully automatic per quality level: for each size and distance, the sphere is added and removed and
	Stats.SceneTriangleCount is compared (the same method S1 validated). About 1 minute per quality level.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local userSettings = UserSettings()
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local VIEWPOINT = Vector3.new(0, 3000, 0) -- well above the baseplate so nothing else is in view
local SIZES = { 4, 64, 512, 2048 }
local DISTANCES = {
	100,
	150,
	200,
	300,
	400,
	500,
	650,
	800,
	1000,
	1250,
	1500,
	2000,
	2500,
	3000,
	4000,
	5000,
	6500,
	8000,
	10000,
	15000,
	20000,
}
local SETTLE_FRAMES = 8
local SAMPLE_FRAMES = 8
--============================================================================

local function waitFrames(count: number)
	for _ = 1, count do
		RunService.RenderStepped:Wait()
	end
end

local function sampleTriangles(): number
	local total = 0
	for _ = 1, SAMPLE_FRAMES do
		RunService.RenderStepped:Wait()
		total += Stats.SceneTriangleCount
	end
	return total / SAMPLE_FRAMES
end

local function qualityName(): string
	local ok, value = pcall(function()
		return tostring(userSettings:GetService("UserGameSettings").SavedQualityLevel)
	end)
	return if ok then value else "unknown"
end

local function measure(part: Part, distance: number): boolean
	part.CFrame = CFrame.new(VIEWPOINT + Vector3.new(0, 0, -distance))
	part.Parent = Workspace
	waitFrames(SETTLE_FRAMES)
	local shown = sampleTriangles()
	part.Parent = nil
	waitFrames(SETTLE_FRAMES)
	local hidden = sampleTriangles()
	return shown - hidden > 1
end

local function runPass(ctx: SpikeKit.ClientContext, label: string)
	ctx.report(`--- Quality {label} (engine: {qualityName()})`)
	for _, size in SIZES do
		local part = Instance.new("Part")
		part.Name = "S11_Sphere"
		part.Shape = Enum.PartType.Ball
		part.Size = Vector3.new(size, size, size)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = Color3.fromRGB(255, 80, 40)

		local pattern = table.create(#DISTANCES)
		local lastDrawn: number? = nil
		local firstCulled: number? = nil
		for index, distance in DISTANCES do
			if distance <= size / 2 + 20 then
				pattern[index] = "-" -- camera would be inside or touching the sphere
				continue
			end
			ctx.status(`S11 quality {label}: size {size} at {distance} studs`)
			local drawn = measure(part, distance)
			pattern[index] = if drawn then "D" else "x"
			if drawn then
				lastDrawn = distance
			elseif firstCulled == nil then
				firstCulled = distance
			end
		end
		part:Destroy()
		ctx.report(
			string.format(
				"Quality %s | size %4d | last drawn at %s studs (centre), first culled at %s | pattern %s",
				label,
				size,
				if lastDrawn then tostring(lastDrawn) else "none",
				if firstCulled then tostring(firstCulled) else "none",
				table.concat(pattern)
			)
		)
	end
end

local spike: SpikeKit.SpikeDef = {
	Id = "S11",
	Title = "Cull distance per quality level and part size",
	Players = 1,
	Instructions = "Pick the quality level you set (Esc menu > Graphics manual, or Studio settings), then wait ~1 minute while it measures automatically. Repeat for 1, 3, 5, 7, 10.",
	Server = nil,
	Client = function(ctx: SpikeKit.ClientContext)
		local camera = Workspace.CurrentCamera
		local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
		local oldDensity = if atmosphere then atmosphere.Density else 0
		local oldFogEnd = Lighting.FogEnd
		local oldType = camera.CameraType
		local ok, err = xpcall(function()
			if atmosphere then
				atmosphere.Density = 0
			end
			Lighting.FogEnd = 1e6
			camera.CameraType = Enum.CameraType.Scriptable
			camera.CFrame = CFrame.lookAt(VIEWPOINT, VIEWPOINT + Vector3.new(0, 0, -1))
			ctx.report(
				`Distances (centre to camera): {table.concat(DISTANCES, ", ")}. Pattern: D = drawn, x = culled, - = skipped.`
			)
			while true do
				local level = ctx.ask(
					"Set the graphics quality level first (Esc > Settings > Graphics, manual), then pick it here. Pick Done to finish.",
					{ "1", "3", "5", "7", "10", "Done" }
				)
				if level == "Done" then
					break
				end
				camera.CameraType = Enum.CameraType.Scriptable
				camera.CFrame = CFrame.lookAt(VIEWPOINT, VIEWPOINT + Vector3.new(0, 0, -1))
				runPass(ctx, level)
				ctx.status("")
			end
		end, debug.traceback)
		if atmosphere then
			atmosphere.Density = oldDensity
		end
		Lighting.FogEnd = oldFogEnd
		camera.CameraType = oldType
		local player = ctx.player
		local character = player.Character
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
