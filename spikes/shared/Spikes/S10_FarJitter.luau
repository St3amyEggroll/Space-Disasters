--!strict
--[[
	S10: Are characters and anchored geometry jitter-free 12,000 studs from the origin? Our farthest pocket slot is
	(+/-12000, 12000, +/-12000).

	Positions are float32: one ULP (the spacing between representable values) is 2^(floor(log2(x)) - 23), about
	0.00098 studs at 12000 and 0.002 at 24000, against 0.00003 at 300. Thin details (0.2-stud trims, a 0.05-stud
	plate, a 0.02-stud gap) are where that error would show as shimmering, cracks or z-fighting.

	The client builds identical local test sites (anchored, not replicated): a 60x1x60 floor, a small roofed room
	with a doorway and a window hole, 0.2-stud trims, a 0.05-stud plate lying on the floor, a standing 0.05-stud plate
	with a 0.02-stud gap to a block in front of a red neon panel, and a checkerboard of abutting tiles. Sites:
	NEAR (0, 300, 0), FAR (12000, 12000, 12000) and optionally FAR2 (24000, 24000, 24000) to learn the margin.

	Automatic, per site: teleport the character onto the floor, let it settle, then (hands off) sample the
	HumanoidRootPart every rendered frame for 3 s (std-dev, max deviation, max frame-to-frame step) and the camera
	for 2 s (position std-dev and look-direction wobble).
	Visual at FAR (and FAR2): walk, jump, zoom close to the trims, plates and gap; answer three questions.

	Expected: standing jitter stays within a few ULP at 12000 (well under 0.01 studs) and nothing visible; if 12000
	is clean but 24000 is not, the margin is about 2x.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local NEAR_ORIGIN = Vector3.new(0, 300, 0) -- high enough to clear the baseplate
local FAR_ORIGIN = Vector3.new(12000, 12000, 12000)
local FAR2_ORIGIN = Vector3.new(24000, 24000, 24000)
local STAND_OFFSET = Vector3.new(0, 0, 14) -- where the character stands on the floor (facing the room, -Z)
local SETTLE_MIN = 1 -- s after a teleport before checking the speed
local SETTLE_MAX = 4 -- s at most spent waiting for the character to stop
local SETTLE_SPEED = 0.05 -- studs/s that counts as standing still
local HRP_SAMPLE_TIME = 3
local CAMERA_SAMPLE_TIME = 2
local MOVED_THRESHOLD = 0.5 -- studs: a larger deviation means someone touched the controls
local SEVERITY = { "None", "Slight", "Obvious" }
--============================================================================

type Site = { key: string, label: string, origin: Vector3, folder: Folder }
type Spread = { count: number, std: number, maxDev: number, maxStep: number }
type SiteResult = { hrp: Spread, camera: Spread, lookWobbleDeg: number }

local FLOOR_TOP = 0.5 -- the floor is 1 stud thick and centred on the site origin
local ROOM_Z = -12 -- room centre (local z); interior 16 x 10 x 16, walls 1 thick

local CONCRETE = Color3.fromRGB(120, 120, 125)
local WALL = Color3.fromRGB(200, 190, 170)
local TRIM = Color3.fromRGB(255, 140, 40)
local WHITE = Color3.fromRGB(245, 245, 245)
local DARK = Color3.fromRGB(35, 35, 40)

-- One float32 ULP at x: 2^(floor(log2(x)) - 23).
local function ulp(x: number): number
	local _, exponent = math.frexp(math.abs(x))
	return math.ldexp(1, exponent - 24)
end

--============================================================================
-- Test geometry
--============================================================================

local function makePart(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function buildSite(key: string, label: string, origin: Vector3): Site
	local folder = Instance.new("Folder")
	folder.Name = "S10_" .. key
	local base = CFrame.new(origin)
	local function at(x: number, y: number, z: number): CFrame
		return base * CFrame.new(x, y, z)
	end
	local function block(
		name: string,
		size: Vector3,
		x: number,
		y: number,
		z: number,
		color: Color3,
		material: Enum.Material
	)
		makePart(folder, name, size, at(x, y, z), color, material)
	end
	local frontZ = ROOM_Z + 8.5
	local wallY = FLOOR_TOP + 5

	block("Floor", Vector3.new(60, 1, 60), 0, 0, 0, CONCRETE, Enum.Material.Concrete)

	-- Room walls (brick texture shows swimming/shimmering well)
	block("BackWall", Vector3.new(18, 10, 1), 0, wallY, ROOM_Z - 8.5, WALL, Enum.Material.Brick)
	block("RightWall", Vector3.new(1, 10, 16), 8.5, wallY, ROOM_Z, WALL, Enum.Material.Brick)
	-- Left wall with a 4 (z) x 3 (y) window hole, sill 4 studs above the floor
	block("LeftWallLow", Vector3.new(1, 4, 16), -8.5, FLOOR_TOP + 2, ROOM_Z, WALL, Enum.Material.Brick)
	block("LeftWallHigh", Vector3.new(1, 3, 16), -8.5, FLOOR_TOP + 8.5, ROOM_Z, WALL, Enum.Material.Brick)
	block("LeftWallBack", Vector3.new(1, 3, 6), -8.5, FLOOR_TOP + 5.5, ROOM_Z - 5, WALL, Enum.Material.Brick)
	block("LeftWallFront", Vector3.new(1, 3, 6), -8.5, FLOOR_TOP + 5.5, ROOM_Z + 5, WALL, Enum.Material.Brick)
	-- Front wall with a 4 x 7 doorway
	block("FrontWallLeft", Vector3.new(7, 10, 1), -5.5, wallY, frontZ, WALL, Enum.Material.Brick)
	block("FrontWallRight", Vector3.new(7, 10, 1), 5.5, wallY, frontZ, WALL, Enum.Material.Brick)
	block("Lintel", Vector3.new(4, 3, 1), 0, FLOOR_TOP + 8.5, frontZ, WALL, Enum.Material.Brick)
	block("Roof", Vector3.new(18, 0.5, 18), 0, FLOOR_TOP + 10.25, ROOM_Z, DARK, Enum.Material.SmoothPlastic)

	-- 0.2-stud trims
	block("BaseboardRight", Vector3.new(0.2, 0.4, 16), 7.9, FLOOR_TOP + 0.2, ROOM_Z, TRIM, Enum.Material.SmoothPlastic)
	block(
		"BaseboardBack",
		Vector3.new(16, 0.4, 0.2),
		0,
		FLOOR_TOP + 0.2,
		ROOM_Z - 7.9,
		TRIM,
		Enum.Material.SmoothPlastic
	)
	block(
		"DoorTrimLeft",
		Vector3.new(0.2, 7, 0.2),
		-2.1,
		FLOOR_TOP + 3.5,
		frontZ + 0.6,
		TRIM,
		Enum.Material.SmoothPlastic
	)
	block(
		"DoorTrimRight",
		Vector3.new(0.2, 7, 0.2),
		2.1,
		FLOOR_TOP + 3.5,
		frontZ + 0.6,
		TRIM,
		Enum.Material.SmoothPlastic
	)
	block(
		"DoorTrimTop",
		Vector3.new(4.4, 0.2, 0.2),
		0,
		FLOOR_TOP + 7.1,
		frontZ + 0.6,
		TRIM,
		Enum.Material.SmoothPlastic
	)
	block(
		"WindowTrimBack",
		Vector3.new(0.2, 3, 0.2),
		-9.1,
		FLOOR_TOP + 5.5,
		ROOM_Z - 2.1,
		TRIM,
		Enum.Material.SmoothPlastic
	)
	block(
		"WindowTrimFront",
		Vector3.new(0.2, 3, 0.2),
		-9.1,
		FLOOR_TOP + 5.5,
		ROOM_Z + 2.1,
		TRIM,
		Enum.Material.SmoothPlastic
	)
	block("WindowSill", Vector3.new(0.2, 0.2, 4.4), -9.1, FLOOR_TOP + 3.9, ROOM_Z, TRIM, Enum.Material.SmoothPlastic)
	block("WindowHead", Vector3.new(0.2, 0.2, 4.4), -9.1, FLOOR_TOP + 7.1, ROOM_Z, TRIM, Enum.Material.SmoothPlastic)
	for index = 0, 4 do
		-- parallel 0.2-wide strips 0.2 apart on the floor (aliasing / shimmer bait)
		block(
			"FloorStrip" .. index,
			Vector3.new(0.2, 0.05, 10),
			-12 + index * 0.4,
			FLOOR_TOP + 0.025,
			20,
			WHITE,
			Enum.Material.SmoothPlastic
		)
	end

	-- 0.05-stud plate lying on the floor (depth precision / z-fighting against the floor)
	block("FlatPlate", Vector3.new(6, 0.05, 6), -18, FLOOR_TOP + 0.025, 8, WHITE, Enum.Material.SmoothPlastic)
	-- Standing 0.05-stud plate, then a 0.02-stud gap, then a block; red neon behind shows through the gap
	block("ThinPlate", Vector3.new(6, 4, 0.05), 15, FLOOR_TOP + 2, 6, WHITE, Enum.Material.SmoothPlastic)
	block("GapBlock", Vector3.new(6, 4, 1), 18.02 + 3, FLOOR_TOP + 2, 6, DARK, Enum.Material.SmoothPlastic)
	block("GapLight", Vector3.new(14, 6, 0.2), 18, FLOOR_TOP + 3, 4, Color3.fromRGB(255, 30, 30), Enum.Material.Neon)
	-- Checkerboard of abutting tiles (seams should stay closed)
	for ix = 0, 3 do
		for iz = 0, 3 do
			local color = if (ix + iz) % 2 == 0 then WHITE else DARK
			block(
				string.format("Tile%d_%d", ix, iz),
				Vector3.new(1.5, 0.2, 1.5),
				-20 + ix * 1.5,
				FLOOR_TOP + 0.1,
				20 + iz * 1.5,
				color,
				Enum.Material.SmoothPlastic
			)
		end
	end

	-- Sign above the doorway, facing the stand point (+Z)
	local sign = makePart(
		folder,
		"Sign",
		Vector3.new(12, 2.5, 0.2),
		at(0, FLOOR_TOP + 12, frontZ) * CFrame.Angles(0, math.pi, 0),
		DARK,
		Enum.Material.SmoothPlastic
	)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.Parent = sign
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.Font = Enum.Font.GothamMedium
	text.TextColor3 = WHITE
	text.Text = label
	text.Parent = gui

	folder.Parent = Workspace
	return { key = key, label = label, origin = origin, folder = folder }
end

--============================================================================
-- Measurement
--============================================================================

local function sampleCFrames(duration: number, read: () -> CFrame): { CFrame }
	local frames: { CFrame } = {}
	local startClock = os.clock()
	while os.clock() - startClock < duration do
		RunService.RenderStepped:Wait()
		table.insert(frames, read())
	end
	return frames
end

-- Spread of positions, computed in doubles relative to the site origin.
local function spreadOf(frames: { CFrame }, origin: Vector3): Spread
	local count = #frames
	if count == 0 then
		return { count = 0, std = 0, maxDev = 0, maxStep = 0 }
	end
	local mx, my, mz = 0, 0, 0
	for _, frame in frames do
		local position = frame.Position
		mx += position.X - origin.X
		my += position.Y - origin.Y
		mz += position.Z - origin.Z
	end
	mx /= count
	my /= count
	mz /= count
	local sumSquares, maxDev, maxStep = 0, 0, 0
	for index, frame in frames do
		local position = frame.Position
		local dx = position.X - origin.X - mx
		local dy = position.Y - origin.Y - my
		local dz = position.Z - origin.Z - mz
		local squared = dx * dx + dy * dy + dz * dz
		sumSquares += squared
		maxDev = math.max(maxDev, math.sqrt(squared))
		if index > 1 then
			local previous = frames[index - 1].Position
			local sx, sy, sz = position.X - previous.X, position.Y - previous.Y, position.Z - previous.Z
			maxStep = math.max(maxStep, math.sqrt(sx * sx + sy * sy + sz * sz))
		end
	end
	return { count = count, std = math.sqrt(sumSquares / count), maxDev = maxDev, maxStep = maxStep }
end

-- Largest angle (degrees) between any sampled look direction and the mean look direction.
local function lookWobble(frames: { CFrame }): number
	if #frames == 0 then
		return 0
	end
	local sum = Vector3.zero
	for _, frame in frames do
		sum += frame.LookVector
	end
	if sum.Magnitude < 1e-6 then
		return 180
	end
	local mean = sum.Unit
	local worst = 0
	for _, frame in frames do
		local dot = math.clamp(frame.LookVector:Dot(mean), -1, 1)
		worst = math.max(worst, math.deg(math.acos(dot)))
	end
	return worst
end

local function teleport(character: Model, root: BasePart, position: Vector3)
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	character:PivotTo(CFrame.new(position)) -- identity rotation faces -Z, toward the room
end

local function settle(root: BasePart)
	local startClock = os.clock()
	task.wait(SETTLE_MIN)
	while os.clock() - startClock < SETTLE_MAX do
		if root.AssemblyLinearVelocity.Magnitude < SETTLE_SPEED then
			break
		end
		task.wait()
	end
	task.wait(0.25)
end

--============================================================================
-- Client
--============================================================================

local function runClient(ctx: SpikeKit.ClientContext)
	local character = ctx.player.Character or ctx.player.CharacterAdded:Wait()
	local humanoidInstance = character:WaitForChild("Humanoid", 10)
	local rootInstance = character:WaitForChild("HumanoidRootPart", 10)
	if
		humanoidInstance == nil
		or not humanoidInstance:IsA("Humanoid")
		or rootInstance == nil
		or not rootInstance:IsA("BasePart")
	then
		ctx.report("ERROR: own character has no Humanoid / HumanoidRootPart")
		return
	end
	local humanoid: Humanoid = humanoidInstance
	local root: BasePart = rootInstance
	local camera = Workspace.CurrentCamera
	local startCFrame = root.CFrame
	local standHeight = FLOOR_TOP + humanoid.HipHeight + root.Size.Y / 2 + 0.2

	local sites: { Site } = {}
	local results: { [string]: SiteResult } = {}
	local answers: { [string]: { string } } = {}

	local function measureSite(site: Site): SiteResult
		ctx.status(
			string.format(
				"S10 %s: HANDS OFF keyboard and mouse for about %d s (automatic measurement)",
				site.label,
				HRP_SAMPLE_TIME + CAMERA_SAMPLE_TIME + SETTLE_MAX
			)
		)
		teleport(character, root, site.origin + STAND_OFFSET + Vector3.new(0, standHeight, 0))
		settle(root)
		local hrpFrames = sampleCFrames(HRP_SAMPLE_TIME, function(): CFrame
			return root.CFrame
		end)
		local cameraFrames = sampleCFrames(CAMERA_SAMPLE_TIME, function(): CFrame
			return camera.CFrame
		end)
		local hrp = spreadOf(hrpFrames, site.origin)
		local cameraSpread = spreadOf(cameraFrames, site.origin)
		local wobble = lookWobble(cameraFrames)
		local unit = ulp(math.max(math.abs(site.origin.X), math.abs(site.origin.Y), math.abs(site.origin.Z)))
		ctx.report(
			string.format(
				"%s: standing HRP over %.0f s (%d frames): std-dev %.6f studs (%.1f ULP), max deviation %.6f, max frame-to-frame step %.6f%s",
				site.label,
				HRP_SAMPLE_TIME,
				hrp.count,
				hrp.std,
				hrp.std / unit,
				hrp.maxDev,
				hrp.maxStep,
				if hrp.maxDev > MOVED_THRESHOLD then " (the character MOVED: were the controls touched?)" else ""
			)
		)
		ctx.report(
			string.format(
				"%s: still camera over %.0f s (%d frames): position std-dev %.6f studs, max deviation %.6f, max frame-to-frame step %.6f, look-direction wobble %.4f deg",
				site.label,
				CAMERA_SAMPLE_TIME,
				cameraSpread.count,
				cameraSpread.std,
				cameraSpread.maxDev,
				cameraSpread.maxStep,
				wobble
			)
		)
		local result: SiteResult = { hrp = hrp, camera = cameraSpread, lookWobbleDeg = wobble }
		results[site.key] = result
		return result
	end

	local function askVisual(site: Site)
		ctx.status(
			string.format(
				"S10 %s: walk around, jump, go into the room, zoom close to the orange trims, the flat white plate, the floor strips/tiles and the gap in front of the red light. Then answer below.",
				site.label
			)
		)
		local tag = string.format("[%s]", site.label)
		answers[site.key] = {
			ctx.ask(tag .. " Any visible jitter of your character?", SEVERITY),
			ctx.ask(tag .. " Any shimmering/cracks in the room or trims?", SEVERITY),
			ctx.ask(tag .. " Camera shaking?", SEVERITY),
		}
		ctx.status("")
	end

	local function visualSummary(key: string): string
		local given = answers[key]
		if given == nil then
			return "not tested"
		end
		return string.format("character %s, geometry %s, camera %s", given[1], given[2], given[3])
	end

	local ok, err = pcall(function()
		for _, x in { 300, 12000, 24000 } do
			local unit = ulp(x)
			ctx.report(
				string.format(
					"float32 ULP at %d studs: %.7f studs (0.05-stud plate = %.0f ULP, 0.02-stud gap = %.0f ULP)",
					x,
					unit,
					0.05 / unit,
					0.02 / unit
				)
			)
		end

		table.insert(sites, buildSite("NEAR", "NEAR (0, 300, 0)", NEAR_ORIGIN))
		table.insert(sites, buildSite("FAR", "FAR (12000, 12000, 12000)", FAR_ORIGIN))
		local near, far = sites[1], sites[2]

		measureSite(near)
		ctx.status("")
		ctx.ask(
			"[NEAR baseline, y = 300] Look at the room, trims, plates, tiles and the gap here for reference. Ready to go to 12000?",
			{ "Continue" }
		)

		measureSite(far)
		askVisual(far)

		local compare = ctx.ask("Also compare at (24000, 24000, 24000) to learn the margin?", { "Yes", "Skip" })
		if compare == "Yes" then
			local far2 = buildSite("FAR2", "FAR2 (24000, 24000, 24000)", FAR2_ORIGIN)
			table.insert(sites, far2)
			measureSite(far2)
			askVisual(far2)
		end

		local function hrpStd(key: string): string
			local result = results[key]
			return if result then string.format("%.6f", result.hrp.std) else "n/a"
		end
		local farAnswers = answers["FAR"]
		local clean = farAnswers ~= nil
			and farAnswers[1] == "None"
			and farAnswers[2] == "None"
			and farAnswers[3] == "None"
		ctx.report(
			string.format(
				"RESULT: 12000 studs %s. Standing HRP std-dev near %s / 12000 %s / 24000 %s studs. Visual at 12000: %s. Visual at 24000: %s.",
				if clean then "looks JITTER-FREE" else "shows ARTIFACTS (see answers)",
				hrpStd("NEAR"),
				hrpStd("FAR"),
				hrpStd("FAR2"),
				visualSummary("FAR"),
				visualSummary("FAR2")
			)
		)
	end)

	ctx.status("")
	if character.Parent ~= nil then
		teleport(character, root, startCFrame.Position + Vector3.new(0, 1, 0))
	end
	for _, site in sites do
		site.folder:Destroy()
	end
	if not ok then
		error(err, 0)
	end
end

local spike: SpikeKit.SpikeDef = {
	Id = "S10",
	Title = "Jitter 12,000 studs from the origin",
	Players = 1,
	Instructions = "Play Solo is fine. You get teleported to test rooms at y=300, then (12000, 12000, 12000), optionally (24000, ...). Keep HANDS OFF while the status says so (automatic measurement); then walk, jump and zoom close to the thin orange trims, white plates, floor strips/tiles and the gap in front of the red light, and answer the questions.",
	Server = nil,
	Client = runClient,
}

return spike
