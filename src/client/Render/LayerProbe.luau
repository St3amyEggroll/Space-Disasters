--!strict
--[[
	LayerProbe (CHANGED (Far layer probe): Studio diagnosis)
	Steamy, with /farground test on: no backdrop panel, tint or label showed anywhere, although FarLayer reported
	every panel, band copy and mesh as made. This probe finds out which kind of object Roblox does not draw here,
	in one screenshot: `/farground probe` (DebugService -> DebugView "farground probe") toggles six labelled test
	objects that follow the camera, spread across the view from left to right:

	  V1  a 20-stud panel 80 studs ahead, 256 px canvas            (as the earlier probe's E, which drew)
	  V2  the same with a 1024 px canvas                           (the backdrop's canvas)
	  V3 / V4 / V5  the same as V1 at 300 / 600 / 1000 studs        (the backdrop's distance is 1020)
	Each holds a ViewportFrame (white, with a blue cube) in a blue frame. Earlier rounds (CHANGED (Far layer probe
	2)) showed plain SurfaceGui panels drawing at every size and distance, but the backdrop's ViewportFrames do not.

	Each panel says its letter. Nothing exists while the probe is off.

	API:
		LayerProbe.toggle(): boolean    on / off (true: now on)
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

--============================================================================
-- Tunables
--============================================================================
local FOLDER_NAME = "LayerProbe"
local RENDER_STEP_NAME = "LayerProbe"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 5 -- after the camera moved
local MAX_GUI_DISTANCE = 1e6 -- studs (SurfaceGui.MaxDistance)
local CANVAS = 256 -- px across each probe panel's SurfaceGui
--============================================================================

type Probe = { part: BasePart, distance: number, angle: number, height: number }

local LayerProbe = {}

local folder: Folder? = nil
local probes: { Probe } = {}

local function newPart(name: string, size: number, transparency: number, height: number?): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = transparency
	part.Size = Vector3.new(size, height or size, 1)
	return part
end

local function newGui(
	part: BasePart,
	color: Color3,
	text: string,
	frameTransparency: number,
	canvas: Vector2?
): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.MaxDistance = MAX_GUI_DISTANCE
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = canvas or Vector2.new(CANVAS, CANVAS)
	gui.Adornee = part
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = frameTransparency
	frame.BorderSizePixel = 0
	frame.Parent = gui
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(0.5, 0.25)
	label.Position = UDim2.fromScale(0.25, 0.375)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.ZIndex = 2
	label.Parent = gui
	gui.Parent = part
	return gui
end

local function add(f: Folder, part: BasePart, distance: number, angle: number, height: number)
	part.Parent = f
	table.insert(probes, { part = part, distance = distance, angle = math.rad(angle), height = math.rad(height) })
end

-- a SurfaceGui panel holding a ViewportFrame (white background, a blue cube), `distance` studs ahead
-- CHANGED (Far layer probe 4): GUIs parented to the PlayerGui (adorned to their part) instead of the part
local playerGuis: { Instance } = {}

local function fillView(view: ViewportFrame)
	view.BackgroundColor3 = Color3.new(1, 1, 1)
	view.BackgroundTransparency = 0
	view.Ambient = Color3.new(0.8, 0.8, 0.8)
	view.LightColor = Color3.new(1, 1, 1)
	local cube = Instance.new("Part")
	cube.Size = Vector3.new(2, 2, 2)
	cube.Color = Color3.fromRGB(30, 90, 255)
	cube.CFrame = CFrame.Angles(0.5, 0.6, 0)
	cube.Parent = view
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 1.5, 6), Vector3.zero)
	camera.Parent = view
	view.CurrentCamera = camera
end

local function viewPanel(
	f: Folder,
	name: string,
	size: number,
	canvas: number,
	distance: number,
	yaw: number,
	inPlayerGui: boolean?
)
	local part = newPart(name, size, 1)
	local gui = newGui(part, Color3.fromRGB(30, 90, 255), name, 0, Vector2.new(canvas, canvas))
	if inPlayerGui then
		local player = Players.LocalPlayer
		local playerGui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
		if playerGui then
			gui.ResetOnSpawn = false
			gui.Parent = playerGui -- Adornee stays the part
			table.insert(playerGuis, gui)
		end
	end
	local view = Instance.new("ViewportFrame")
	view.Size = UDim2.fromScale(0.8, 0.8)
	view.Position = UDim2.fromScale(0.1, 0.1)
	fillView(view)
	view.Parent = gui
	add(f, part, distance, yaw, 0)
end

-- CHANGED (Far layer probe 4): the control: a ViewportFrame in a ScreenGui (2D, top centre of the screen), like the
-- navball, which draws
local function screenView(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "LayerProbeScreen"
	screen.ResetOnSpawn = false
	local view = Instance.new("ViewportFrame")
	view.Size = UDim2.fromOffset(120, 120)
	view.Position = UDim2.new(0.5, -60, 0, 120)
	fillView(view)
	view.Parent = screen
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromOffset(120, 24)
	label.Position = UDim2.new(0.5, -60, 0, 96)
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Text = "S"
	label.Parent = screen
	return screen
end

local function build(): Folder
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	-- CHANGED (Far layer probe 3): the backdrop's panels draw (their labels show) but their ViewportFrames do not,
	-- while probe E (a ViewportFrame 80 studs ahead, 256 px) did. Each V panel looks the same size on screen,
	-- left to right: V1 as E; V2 as E with a 1024 px canvas; V3 / V4 / V5 at 300 / 600 / 1000 studs
	-- CHANGED (Far layer probe 4): no V panel drew its ViewportFrame (only the frame around it). W1 / W2: the same
	-- with the SurfaceGui in the PlayerGui (Adornee = the part) at 80 / 1000 studs; S: a ScreenGui control
	viewPanel(f, "V1", 20, 256, 80, -24)
	viewPanel(f, "W1", 20, 256, 80, -8, true)
	viewPanel(f, "W2", 250, 256, 1000, 8, true)
	viewPanel(f, "V5", 250, 256, 1000, 24)
	local player = Players.LocalPlayer
	local playerGui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	if playerGui then
		local screen = screenView()
		screen.Parent = playerGui
		table.insert(playerGuis, screen)
	end
	return f
end

local function follow()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local view = camera.CFrame
	local eye = view.Position
	local parts: { BasePart } = table.create(#probes)
	local cframes: { CFrame } = table.create(#probes)
	for _, probe in probes do
		local direction = (view * CFrame.Angles(probe.height, -probe.angle, 0)).LookVector
		local at = eye + direction * probe.distance
		table.insert(parts, probe.part)
		table.insert(cframes, CFrame.lookAt(at, eye)) -- the Front face (and its SurfaceGui) faces the eye
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

function LayerProbe.toggle(): boolean
	local f = folder
	if f then
		RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
		f:Destroy()
		for _, gui in playerGuis do
			gui:Destroy()
		end
		table.clear(playerGuis)
		folder = nil
		table.clear(probes)
		return false
	end
	local built = build()
	folder = built
	follow()
	built.Parent = Workspace
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, follow)
	return true
end

return table.freeze(LayerProbe)
