--!strict
--[[
	S4: Can the skybox be rotated at runtime, and can the sun/moon discs be hidden?
	  - Sky.SkyboxOrientation (Vector3, degrees): does writing it at runtime rotate the skybox, and do the stars
	    turn with it? What does one write cost on the Lua side, and how are out-of-range values read back?
	  - Sky.CelestialBodiesShown = false: does it hide the sun disc?
	The game needs both: the star field must turn with the craft's reference frame, and the Roblox sun disc must
	not show where our own sun is not.

	Atmosphere.Density is 0 during the test (the game uses zero density in space) so the stars are not washed out.
	If Lighting has no Sky, one is created (it uses the default Roblox sky textures and stars) and destroyed
	afterwards; otherwise the existing Sky's properties are restored. ClockTime and the camera are restored too.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local CAMERA_POSITION = Vector3.new(0, 40, 0)
local CAMERA_PITCH_DEG = 15 -- look slightly above the horizon, toward -Z
local NIGHT_CLOCK_TIME = 0
local DAY_CLOCK_TIME = 14
local SPIN_DURATION = 8 -- s for a full turn about Y
local TILT_DURATION = 4 -- s for the X tilt
local TILT_DEG = 90
local BENCH_COUNT = 1000
local SETTLE_TIME = 1 -- s after a lighting/camera change before animating or asking
local READBACK_TESTS = {
	Vector3.new(0, 400, 0),
	Vector3.new(0, -30, 0),
	Vector3.new(120, 0, 0),
	Vector3.new(0, 0, 45),
	Vector3.new(-200, 720, -90),
}
--============================================================================

type SkySetup = { sky: Sky, created: boolean, orientation: Vector3, celestialShown: boolean }
type SavedLighting = { clockTime: number, atmosphere: Atmosphere?, density: number }

local function vectorText(v: Vector3): string
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end

local function findOrCreateSky(ctx: SpikeKit.ClientContext): SkySetup
	local found = Lighting:FindFirstChildOfClass("Sky")
	if found and found:IsA("Sky") then
		ctx.report(`Using the existing Sky "{found.Name}" (StarCount {found.StarCount})`)
		local readOk, orientation = pcall(function(): Vector3
			return found.SkyboxOrientation
		end)
		return {
			sky = found,
			created = false,
			orientation = if readOk then orientation else Vector3.zero,
			celestialShown = found.CelestialBodiesShown,
		}
	end
	local sky = Instance.new("Sky")
	sky.Name = "S4_Sky"
	sky.Parent = Lighting
	ctx.report(`Lighting had no Sky: created one with default textures (StarCount {sky.StarCount})`)
	return { sky = sky, created = true, orientation = Vector3.zero, celestialShown = true }
end

local function applyTestLighting(): SavedLighting
	local found = Lighting:FindFirstChildOfClass("Atmosphere")
	local atmosphere = if found and found:IsA("Atmosphere") then found else nil
	local saved: SavedLighting = {
		clockTime = Lighting.ClockTime,
		atmosphere = atmosphere,
		density = if atmosphere then atmosphere.Density else 0,
	}
	if atmosphere then
		atmosphere.Density = 0
	end
	return saved
end

local function restoreLighting(saved: SavedLighting)
	Lighting.ClockTime = saved.clockTime
	local atmosphere = saved.atmosphere
	if atmosphere then
		atmosphere.Density = saved.density
	end
end

local function aimCamera(camera: Camera, from: Vector3, at: Vector3)
	local cframe = CFrame.lookAt(from, at)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = cframe
	camera.Focus = cframe
end

local function aimAtHorizon(camera: Camera)
	local pitch = math.rad(CAMERA_PITCH_DEG)
	aimCamera(camera, CAMERA_POSITION, CAMERA_POSITION + Vector3.new(0, math.sin(pitch), -math.cos(pitch)))
end

local function restoreCamera(camera: Camera, player: Player)
	camera.CameraType = Enum.CameraType.Custom
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid and humanoid:IsA("Humanoid") then
		camera.CameraSubject = humanoid
	end
end

-- Calls step(alpha) once per rendered frame with alpha going 0 -> 1 over duration. Returns the frame count.
local function animate(duration: number, step: (alpha: number) -> ()): number
	local start = os.clock()
	local frames = 0
	while true do
		local alpha = math.min((os.clock() - start) / duration, 1)
		step(alpha)
		frames += 1
		if alpha >= 1 then
			return frames
		end
		RunService.RenderStepped:Wait()
	end
end

-- Plays the animation, then asks; "Replay" plays it again.
local function watchAndAsk(
	ctx: SpikeKit.ClientContext,
	question: string,
	options: { string },
	play: () -> number,
	label: string
): string
	local withReplay = table.clone(options)
	table.insert(withReplay, "Replay")
	while true do
		ctx.status(`S4: watch the sky now ({label})`)
		local start = os.clock()
		local frames = play()
		local elapsed = os.clock() - start
		ctx.report(string.format("%s: %d frames in %.2f s (%.0f fps)", label, frames, elapsed, frames / elapsed))
		ctx.status("")
		local answer = ctx.ask(question, withReplay)
		if answer ~= "Replay" then
			return answer
		end
	end
end

-- Can the property be read and written at all? Returns false if not (the rotation tests are then skipped).
local function probeProperty(ctx: SpikeKit.ClientContext, sky: Sky): boolean
	local readOk, initial = pcall(function(): Vector3
		return sky.SkyboxOrientation
	end)
	local readText = if readOk then "OK, initial " .. vectorText(initial) else "ERROR " .. tostring(initial)
	ctx.report("Read SkyboxOrientation: " .. readText)
	local writeOk, writeErr = pcall(function()
		sky.SkyboxOrientation = Vector3.new(0, 10, 0)
	end)
	local writeText = if writeOk then "OK" else "ERROR " .. tostring(writeErr)
	ctx.report("Write SkyboxOrientation = (0, 10, 0): " .. writeText)
	if not (readOk and writeOk) then
		return false
	end
	ctx.report("Reads back as " .. vectorText(sky.SkyboxOrientation))
	sky.SkyboxOrientation = Vector3.zero
	return true
end

local function testRotation(ctx: SpikeKit.ClientContext, camera: Camera, sky: Sky)
	-- Night: stars visible
	Lighting.ClockTime = NIGHT_CLOCK_TIME
	aimAtHorizon(camera)
	sky.SkyboxOrientation = Vector3.zero
	task.wait(SETTLE_TIME)
	watchAndAsk(
		ctx,
		"NIGHT: the skybox was turned a full 360 deg about the vertical axis over 8 s. Did the skybox/stars visibly rotate around the vertical axis (sliding sideways)?",
		{ "Yes, smoothly", "Yes, but choppy", "No" },
		function(): number
			return animate(SPIN_DURATION, function(alpha: number)
				sky.SkyboxOrientation = Vector3.new(0, 360 * alpha, 0)
			end)
		end,
		"night spin about Y"
	)
	ctx.ask(
		"NIGHT: during that turn, did the STARS (small white dots) move together with the skybox?",
		{ "Stars moved with it", "Stars stayed fixed", "Could not see stars" }
	)

	watchAndAsk(
		ctx,
		"NIGHT: the skybox was now tilted 0 -> 90 deg about the X axis over 4 s. Did the sky tilt (rolling up or down, not sideways)?",
		{ "Yes, smoothly", "Yes, but choppy", "No" },
		function(): number
			return animate(TILT_DURATION, function(alpha: number)
				sky.SkyboxOrientation = Vector3.new(TILT_DEG * alpha, 0, 0)
			end)
		end,
		"night tilt about X"
	)
	sky.SkyboxOrientation = Vector3.zero

	-- Day: the skybox texture itself (clouds/horizon) is visible
	Lighting.ClockTime = DAY_CLOCK_TIME
	aimAtHorizon(camera)
	task.wait(SETTLE_TIME)
	watchAndAsk(
		ctx,
		"DAY: the skybox was turned a full 360 deg about the vertical axis over 8 s again. Did the daytime sky texture (clouds / horizon) visibly rotate?",
		{ "Yes, smoothly", "Yes, but choppy", "No" },
		function(): number
			return animate(SPIN_DURATION, function(alpha: number)
				sky.SkyboxOrientation = Vector3.new(0, 360 * alpha, 0)
			end)
		end,
		"day spin about Y"
	)
	sky.SkyboxOrientation = Vector3.zero
end

local function measureProperty(ctx: SpikeKit.ClientContext, sky: Sky)
	for _, value in READBACK_TESTS do
		local ok, err = pcall(function()
			sky.SkyboxOrientation = value
		end)
		if ok then
			ctx.report(`SkyboxOrientation set to {vectorText(value)} reads back as {vectorText(sky.SkyboxOrientation)}`)
		else
			ctx.report(`SkyboxOrientation set to {vectorText(value)}: ERROR {err}`)
		end
	end

	local start = os.clock()
	for index = 1, BENCH_COUNT do
		sky.SkyboxOrientation = Vector3.new(index % 90, index % 360, 0)
	end
	local writeUs = (os.clock() - start) * 1e6 / BENCH_COUNT

	start = os.clock()
	local sum = 0
	for _ = 1, BENCH_COUNT do
		sum += sky.SkyboxOrientation.Y
	end
	local readUs = (os.clock() - start) * 1e6 / BENCH_COUNT
	ctx.report(
		string.format(
			"SkyboxOrientation cost over %d calls: %.3f us per write, %.3f us per read (checksum %.0f)",
			BENCH_COUNT,
			writeUs,
			readUs,
			sum
		)
	)
	sky.SkyboxOrientation = Vector3.zero
end

local function testCelestialBodies(ctx: SpikeKit.ClientContext, camera: Camera, sky: Sky)
	Lighting.ClockTime = DAY_CLOCK_TIME
	local sun = Lighting:GetSunDirection()
	ctx.report(
		string.format(
			"Sun direction at ClockTime %.1f: %s, elevation %.1f deg",
			Lighting.ClockTime,
			vectorText(sun),
			math.deg(math.asin(math.clamp(sun.Y, -1, 1)))
		)
	)
	aimCamera(camera, CAMERA_POSITION, CAMERA_POSITION + sun)
	local options = { "Disc visible", "Only glow/glare", "No sun at all", "Unsure" }

	sky.CelestialBodiesShown = true
	task.wait(SETTLE_TIME)
	ctx.ask(
		"CelestialBodiesShown = TRUE. The camera points straight at the sun. Is the SUN DISC visible in the centre of the screen?",
		options
	)

	sky.CelestialBodiesShown = false
	task.wait(SETTLE_TIME)
	ctx.ask(
		"CelestialBodiesShown = FALSE. Same view. Is the SUN DISC still visible in the centre of the screen?",
		options
	)
	ctx.report("CelestialBodiesShown reads back as " .. tostring(sky.CelestialBodiesShown))
end

local spike: SpikeKit.SpikeDef = {
	Id = "S4",
	Title = "Skybox rotation + hiding the sun disc",
	Players = 1,
	Instructions = "The camera looks at the sky. At night the skybox spins once (8 s) and tilts (4 s), then spins once in daylight: watch the stars and clouds. Then the camera looks at the sun with the sun disc on, then off. 6 questions; pick Replay to watch an animation again.",
	Server = nil,
	Client = function(ctx: SpikeKit.ClientContext)
		local player = ctx.player
		if not player.Character then
			player.CharacterAdded:Wait()
		end
		local camera = Workspace.CurrentCamera
		local savedLighting = applyTestLighting()
		local setup = findOrCreateSky(ctx)
		local sky = setup.sky

		local ok, err = xpcall(function()
			if probeProperty(ctx, sky) then
				testRotation(ctx, camera, sky)
				measureProperty(ctx, sky)
			else
				ctx.report("SkyboxOrientation is not usable here: rotation tests skipped")
			end
			testCelestialBodies(ctx, camera, sky)
		end, debug.traceback)

		if setup.created then
			sky:Destroy()
		else
			pcall(function()
				sky.SkyboxOrientation = setup.orientation
			end)
			sky.CelestialBodiesShown = setup.celestialShown
		end
		restoreLighting(savedLighting)
		restoreCamera(camera, player)
		if not ok then
			error(err, 0)
		end
	end,
}

return spike
