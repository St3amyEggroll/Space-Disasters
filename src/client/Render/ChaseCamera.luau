--!strict
--[[
	ChaseCamera
	The piloting camera (spec 7.11): a Scriptable camera orbiting the craft's centre of mass.

	start(getTarget)  take over Workspace.CurrentCamera; getTarget() returns the craft's CoM CFrame in workspace
	                  every frame (nil = keep following the last known position). Calling start again while active
	                  just swaps the target function.
	stop()            give the camera back: CameraType Custom, CameraSubject = the local Humanoid.
	isActive()

	Controls: hold RIGHT mouse and drag to orbit (the cursor is locked in place while dragging), mouse wheel zooms
	between GameConfig.CHASE_ZOOM_MIN and CHASE_ZOOM_MAX (smooth, exponential); on a gamepad the right stick
	orbits and DPad up/down zooms.

	The orbit is around the world Y axis through the target ("up" = pocket up): during flight the craft sits upright
	in its pocket, so the camera never rolls with the craft. Rotation is applied instantly (no lag in the feel);
	only the orbit centre follows the target smoothly, and snaps when the target jumps far (teleport / rebase).
	No occlusion handling: the camera simply orbits, the craft's own parts never push it in.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local RENDER_STEP_NAME = "ChaseCamera"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local MOUSE_SENSITIVITY = math.rad(0.35) -- rad per pixel of mouse drag
local GAMEPAD_SPEED = math.rad(160) -- rad/s at full right-stick deflection
local GAMEPAD_DEADZONE = 0.15
local GAMEPAD_ZOOM_RATE = 1.2 -- ln(zoom) per second while a DPad zoom button is held
local PITCH_LIMIT = math.rad(85)
local DEFAULT_PITCH = math.rad(15) -- camera slightly above the craft
local ZOOM_STEP = 1.15 -- zoom factor per mouse-wheel notch
local ZOOM_SMOOTHING = 12 -- 1/s, exponential approach of the displayed zoom to the target zoom
local FOLLOW_SMOOTHING = 15 -- 1/s, exponential approach of the orbit centre to the target
local SNAP_DISTANCE = 500 -- studs; a target jump larger than this is snapped to instead of smoothed
--============================================================================

local ChaseCamera = {}

local active = false
local getTargetFn: (() -> CFrame?)? = nil
local connections: { RBXScriptConnection } = {}

local yaw = 0 -- rad about world +Y
local pitch = DEFAULT_PITCH -- rad, positive = camera above the target
local zoom = GameConfig.CHASE_ZOOM_DEFAULT -- displayed distance, studs
local targetZoom = GameConfig.CHASE_ZOOM_DEFAULT
local focus: Vector3? = nil -- smoothed orbit centre
local lastTarget: Vector3? = nil

local dragging = false
local pendingDelta = Vector2.zero -- accumulated mouse drag since the last frame, pixels
local stick = Vector2.zero -- right stick, deadzoned
local zoomIn = false -- DPad up held
local zoomOut = false -- DPad down held

local function clampZoom(value: number): number
	return math.clamp(value, GameConfig.CHASE_ZOOM_MIN, GameConfig.CHASE_ZOOM_MAX)
end

local function setDragging(on: boolean)
	if dragging == on then
		return
	end
	dragging = on
	UserInputService.MouseBehavior = if on then Enum.MouseBehavior.LockCurrentPosition else Enum.MouseBehavior.Default
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		if not gameProcessed then
			setDragging(true)
		end
	elseif input.KeyCode == Enum.KeyCode.DPadUp then
		zoomIn = true
	elseif input.KeyCode == Enum.KeyCode.DPadDown then
		zoomOut = true
	end
end

local function onInputEnded(input: InputObject, _gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		setDragging(false)
	elseif input.KeyCode == Enum.KeyCode.DPadUp then
		zoomIn = false
	elseif input.KeyCode == Enum.KeyCode.DPadDown then
		zoomOut = false
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		stick = Vector2.zero
	end
end

local function onInputChanged(input: InputObject, gameProcessed: boolean)
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.MouseMovement then
		if dragging then
			local delta = input.Delta
			pendingDelta += Vector2.new(delta.X, delta.Y)
		end
	elseif inputType == Enum.UserInputType.MouseWheel then
		if not gameProcessed then
			local notches = input.Position.Z
			targetZoom = clampZoom(targetZoom * ZOOM_STEP ^ -notches)
		end
	elseif input.KeyCode == Enum.KeyCode.Thumbstick2 then
		local position = Vector2.new(input.Position.X, input.Position.Y)
		if position.Magnitude < GAMEPAD_DEADZONE then
			stick = Vector2.zero
		else
			-- Rescale so motion starts from zero at the edge of the deadzone.
			local magnitude = (position.Magnitude - GAMEPAD_DEADZONE) / (1 - GAMEPAD_DEADZONE)
			stick = position.Unit * math.min(magnitude, 1)
		end
	end
end

local function localHumanoid(): Humanoid?
	local character = Players.LocalPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	-- Target
	local getTarget = getTargetFn
	local targetCFrame = if getTarget then getTarget() else nil
	if targetCFrame then
		lastTarget = targetCFrame.Position
	end
	local target = lastTarget
	if not target then
		return -- nothing to look at yet; leave the camera where it is
	end

	-- Orbit angles: applied immediately
	yaw -= pendingDelta.X * MOUSE_SENSITIVITY
	pitch += pendingDelta.Y * MOUSE_SENSITIVITY
	pendingDelta = Vector2.zero
	if stick ~= Vector2.zero then
		yaw -= stick.X * GAMEPAD_SPEED * dt
		pitch -= stick.Y * GAMEPAD_SPEED * dt
	end
	yaw %= 2 * math.pi
	pitch = math.clamp(pitch, -PITCH_LIMIT, PITCH_LIMIT)

	-- Zoom: exponential approach in log space so every step feels the same at any distance
	if zoomIn ~= zoomOut then
		local direction = if zoomIn then -1 else 1
		targetZoom = clampZoom(targetZoom * math.exp(direction * GAMEPAD_ZOOM_RATE * dt))
	end
	local zoomAlpha = 1 - math.exp(-ZOOM_SMOOTHING * dt)
	zoom = math.exp(math.log(zoom) + (math.log(targetZoom) - math.log(zoom)) * zoomAlpha)

	-- Orbit centre: smooth follow, snap on big jumps
	local previous = focus
	local current: Vector3 = target
	if previous and (target - previous).Magnitude <= SNAP_DISTANCE then
		current = previous:Lerp(target, 1 - math.exp(-FOLLOW_SMOOTHING * dt))
	end
	focus = current

	local rotation = CFrame.Angles(0, yaw, 0) * CFrame.Angles(-pitch, 0, 0)
	camera.CFrame = CFrame.new(current) * rotation * CFrame.new(0, 0, zoom)
	camera.Focus = CFrame.new(current)
end

--============================================================================
-- API
--============================================================================

-- Takes over Workspace.CurrentCamera (Scriptable). getTarget returns the craft's CoM CFrame in workspace each
-- frame; nil keeps the last known position.
function ChaseCamera.start(getTarget: () -> CFrame?)
	getTargetFn = getTarget
	if active then
		return
	end
	active = true

	-- Begin from the current view direction so taking over does not jump the view around.
	local camera = Workspace.CurrentCamera
	if camera then
		local look = camera.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude > 1e-3 then
			-- The camera sits at -look from the target; yaw measures the camera's offset direction (+Z at yaw 0).
			yaw = math.atan2(-look.X, -look.Z)
		end
	end
	pitch = DEFAULT_PITCH
	zoom = GameConfig.CHASE_ZOOM_DEFAULT
	targetZoom = GameConfig.CHASE_ZOOM_DEFAULT
	focus = nil
	lastTarget = nil
	pendingDelta = Vector2.zero
	stick = Vector2.zero
	zoomIn, zoomOut = false, false

	if camera then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	table.insert(connections, UserInputService.InputBegan:Connect(onInputBegan))
	table.insert(connections, UserInputService.InputEnded:Connect(onInputEnded))
	table.insert(connections, UserInputService.InputChanged:Connect(onInputChanged))
	table.insert(
		connections,
		UserInputService.WindowFocusReleased:Connect(function()
			setDragging(false)
			stick = Vector2.zero
			zoomIn, zoomOut = false, false
		end)
	)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
end

-- Restores the default character camera (CameraType Custom, CameraSubject = local Humanoid).
function ChaseCamera.stop()
	if not active then
		return
	end
	active = false
	getTargetFn = nil
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	setDragging(false)

	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		local humanoid = localHumanoid()
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

function ChaseCamera.isActive(): boolean
	return active
end

return table.freeze(ChaseCamera)
