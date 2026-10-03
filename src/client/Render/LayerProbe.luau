--!strict
--[[
	LayerProbe (CHANGED (Far layer probe): Studio diagnosis)
	Steamy, with /farground test on: no backdrop panel, tint or label showed anywhere, although FarLayer reported
	every panel, band copy and mesh as made. This probe finds out which kind of object Roblox does not draw here,
	in one screenshot: `/farground probe` (DebugService -> DebugView "farground probe") toggles six labelled test
	objects that follow the camera, spread across the view from left to right:

	  A  a red Neon cube, 40 studs ahead                         a plain part (always expected)
	  B  a 20-stud SurfaceGui panel 60 studs ahead (red)           a SurfaceGui on an invisible part, near
	  C  a 400-stud SurfaceGui panel 1000 studs ahead (green)      the same, at the backdrop's distance
	  D  the same as C on a part with Transparency 0.98 (orange)   in case an invisible part skips its SurfaceGui
	  E  a 20-stud SurfaceGui panel 80 studs ahead holding a       a ViewportFrame in a SurfaceGui
	     ViewportFrame with a blue cube (blue frame around it)
	  F  a 2040-stud SurfaceGui panel 1020 studs ahead, faint      the backdrop's exact panel size and distance
	     yellow over the whole view, with a label at its centre

	Each panel says its letter. Nothing exists while the probe is off.

	API:
		LayerProbe.toggle(): boolean    on / off (true: now on)
]]

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

local function newPart(name: string, size: number, transparency: number): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = transparency
	part.Size = Vector3.new(size, size, 1)
	return part
end

local function newGui(part: BasePart, color: Color3, text: string, frameTransparency: number): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.MaxDistance = MAX_GUI_DISTANCE
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(CANVAS, CANVAS)
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

local function build(): Folder
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME

	-- A: a plain part
	local a = newPart("A", 4, 0)
	a.Material = Enum.Material.Neon
	a.Color = Color3.fromRGB(255, 40, 40)
	add(f, a, 40, -25, 0)

	-- B: a small SurfaceGui panel, near
	local b = newPart("B", 20, 1)
	newGui(b, Color3.fromRGB(220, 30, 30), "B", 0)
	add(f, b, 60, -15, 0)

	-- C: a SurfaceGui panel at the backdrop's distance
	local c = newPart("C", 400, 1)
	newGui(c, Color3.fromRGB(30, 200, 60), "C", 0)
	add(f, c, 1000, -3, 8)

	-- D: as C on a nearly (not fully) transparent part
	local d = newPart("D", 400, 0.98)
	newGui(d, Color3.fromRGB(255, 140, 0), "D", 0)
	add(f, d, 1000, 12, 8)

	-- E: a ViewportFrame in a SurfaceGui
	local e = newPart("E", 20, 1)
	local gui = newGui(e, Color3.fromRGB(30, 90, 255), "E", 0)
	local view = Instance.new("ViewportFrame")
	view.Size = UDim2.fromScale(0.8, 0.8)
	view.Position = UDim2.fromScale(0.1, 0.1)
	view.BackgroundColor3 = Color3.new(1, 1, 1)
	view.BackgroundTransparency = 0
	view.Ambient = Color3.new(0.8, 0.8, 0.8)
	view.LightColor = Color3.new(1, 1, 1)
	view.Parent = gui
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
	add(f, e, 80, 22, 0)

	-- F: the backdrop's panel size and distance
	local panel = newPart("F", 2040, 1)
	newGui(panel, Color3.fromRGB(255, 230, 0), "F", 0.8)
	add(f, panel, 1020, 0, 0)

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
