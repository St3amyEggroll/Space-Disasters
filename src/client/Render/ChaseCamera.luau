--!strict
--[[
	ChaseCamera
	The piloting camera (spec 7.11): a Scriptable camera orbiting the craft's centre of mass.

	start(getTarget)  take over Workspace.CurrentCamera; getTarget() returns a Target every frame (nil = keep
	                  following the last known position). Calling start again while active just swaps the function.
	stop()            give the camera back: CameraType Custom, CameraSubject = the local Humanoid.
	isActive()

	Controls: hold RIGHT mouse and drag to orbit (the cursor is locked in place while dragging), mouse wheel zooms
	between GameConfig.CHASE_ZOOM_MIN and CHASE_ZOOM_MAX (smooth, exponential); on a gamepad the right stick
	orbits and DPad up/down zooms.

	CHANGED (Phase 2a feedback): it behaves like the normal Roblox camera, but "up" is whatever the Target says
	(gravity up in the atmosphere, the solar-system plane's normal in space) and the orbit lives in a STABLE space
	(universe axes), NOT the pocket's: a CRAFT_ALIGNED pocket turns with the craft, so orbiting about pocket Y made
	the camera follow every turn of the rocket. Now the rocket turns on screen and the horizon stays level.
	The horizontal view direction is carried along (re-projected onto the plane under `up`) whenever up changes,
	so blending between gravity-up and the solar plane never jumps. Rotation is applied instantly; only the orbit
	centre follows the target smoothly, and snaps when the target jumps far (teleport / rebase). No occlusion
	handling: the camera simply orbits.

	CHANGED (Phase 11): player settings. Drag speed is MOUSE_SENSITIVITY times Settings mouseSensitivity, invertY flips
	the pitch of the drag and of the right stick, and cameraSmoothing scales FOLLOW_SMOOTHING and ZOOM_SMOOTHING
	(0.5 = exactly those rates, 0 = SMOOTHING_SNAPPY_FACTOR times them, 1 = SMOOTHING_SMOOTH_FACTOR times them,
	log-linear in between). While UIState.isInputBlocked() (main menu or a dialog) drag, wheel, stick and DPad zoom
	are ignored and a drag in progress ends (the cursor is freed).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Settings = require(script.Parent.Parent.Settings.Settings) -- CHANGED (Phase 11)
local UIState = require(script.Parent.Parent.UI.UIState) -- CHANGED (Phase 11)

--============================================================================
-- Tunables
--============================================================================
local RENDER_STEP_NAME = "ChaseCamera"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local MOUSE_SENSITIVITY = math.rad(0.35) -- rad per pixel of mouse drag (times Settings mouseSensitivity)
local GAMEPAD_SPEED = math.rad(160) -- rad/s at full right-stick deflection
local GAMEPAD_DEADZONE = 0.15
local GAMEPAD_ZOOM_RATE = 1.2 -- ln(zoom) per second while a DPad zoom button is held
local PITCH_LIMIT = math.rad(85)
local DEFAULT_PITCH = math.rad(15) -- camera slightly above the craft
local ZOOM_STEP = 1.15 -- zoom factor per mouse-wheel notch
local ZOOM_SMOOTHING = 12 -- 1/s, exponential approach of the displayed zoom to the target zoom (at smoothing 0.5)
local FOLLOW_SMOOTHING = 15 -- 1/s, exponential approach of the orbit centre to the target (at smoothing 0.5)
-- CHANGED (Phase 11): rate multipliers at Settings cameraSmoothing 0 and 1 (follow 40/s and 4/s)
local SMOOTHING_SNAPPY_FACTOR = 40 / 15
local SMOOTHING_SMOOTH_FACTOR = 4 / 15
local SNAP_DISTANCE = 500 -- studs; a target jump larger than this is snapped to instead of smoothed
--============================================================================

export type Target = {
	position: Vector3, -- orbit centre, workspace
	up: Vector3, -- unit "up" in the stable space (universe axes)
	toWorkspace: CFrame, -- rotation from the stable space to workspace axes (the pocket frame's refRotInv)
}

local ChaseCamera = {}

local active = false
local getTargetFn: (() -> Target?)? = nil
local connections: { RBXScriptConnection } = {}

local back = Vector3.zAxis -- unit, stable space: horizontal direction from the target toward the camera
local pitch = DEFAULT_PITCH -- rad, positive = camera above the target
local lastUp = Vector3.yAxis -- stable space
local lastToWorkspace = CFrame.identity
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

-- CHANGED (Phase 11): multiplier for both smoothing rates from Settings cameraSmoothing (exactly 1 at 0.5).
local function smoothingFactor(smoothing: number): number
	local s = math.clamp(smoothing, 0, 1)
	if s <= 0.5 then
		return SMOOTHING_SNAPPY_FACTOR ^ ((0.5 - s) * 2)
	end
	return SMOOTHING_SMOOTH_FACTOR ^ ((s - 0.5) * 2)
end

local function onInputBegan(input: InputObject, gameProcessed: boolean)
	if input.UserInputType == Enum.UserInputType.MouseButton2 then
		if not gameProcessed and not UIState.isInputBlocked() then -- CHANGED (Phase 11)
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
		if dragging and not UIState.isInputBlocked() then -- CHANGED (Phase 11)
			local delta = input.Delta
			pendingDelta += Vector2.new(delta.X, delta.Y)
		end
	elseif inputType == Enum.UserInputType.MouseWheel then
		if not gameProcessed and not UIState.isInputBlocked() then -- CHANGED (Phase 11)
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

-- Rotates v about the unit axis u by angle a (Rodrigues).
local function rotateAbout(v: Vector3, u: Vector3, a: number): Vector3
	local c, sn = math.cos(a), math.sin(a)
	return v * c + u:Cross(v) * sn + u * (u:Dot(v) * (1 - c))
end

-- `v` made perpendicular to `up` and unit length; any perpendicular when v is (nearly) parallel to up.
local function horizontal(v: Vector3, up: Vector3): Vector3
	local h = v - up * v:Dot(up)
	if h.Magnitude < 1e-4 then
		h = up:Cross(if math.abs(up.X) < 0.9 then Vector3.xAxis else Vector3.zAxis)
	end
	return h.Unit
end

local function step(dt: number)
	-- CHANGED (Phase 11): a menu or dialog frees the mouse and stops camera input
	local blocked = UIState.isInputBlocked()
	if blocked and dragging then
		setDragging(false)
		pendingDelta = Vector2.zero
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	-- Target
	local getTarget = getTargetFn
	local t = if getTarget then getTarget() else nil
	if t then
		lastTarget = t.position
		lastUp = t.up
		lastToWorkspace = t.toWorkspace
	end
	local target = lastTarget
	if not target then
		return -- nothing to look at yet; leave the camera where it is
	end
	local up = lastUp

	-- CHANGED (Phase 11): player settings
	local values = Settings.current()
	local sensitivity = MOUSE_SENSITIVITY * values.mouseSensitivity
	local pitchSign = if values.invertY then -1 else 1
	local rateFactor = smoothingFactor(values.cameraSmoothing)

	-- Orbit angles: applied immediately. Mouse right = orbit to the right around the target, like Roblox.
	local yawDelta = -pendingDelta.X * sensitivity
	pitch += pendingDelta.Y * sensitivity * pitchSign
	pendingDelta = Vector2.zero
	if stick ~= Vector2.zero and not blocked then
		yawDelta -= stick.X * GAMEPAD_SPEED * dt
		pitch -= stick.Y * GAMEPAD_SPEED * dt * pitchSign
	end
	pitch = math.clamp(pitch, -PITCH_LIMIT, PITCH_LIMIT)
	back = horizontal(back, up)
	if yawDelta ~= 0 then
		back = horizontal(rotateAbout(back, up, yawDelta), up)
	end

	-- Zoom: exponential approach in log space so every step feels the same at any distance
	if zoomIn ~= zoomOut and not blocked then
		local direction = if zoomIn then -1 else 1
		targetZoom = clampZoom(targetZoom * math.exp(direction * GAMEPAD_ZOOM_RATE * dt))
	end
	local zoomAlpha = 1 - math.exp(-ZOOM_SMOOTHING * rateFactor * dt) -- CHANGED (Phase 11): rateFactor
	zoom = math.exp(math.log(zoom) + (math.log(targetZoom) - math.log(zoom)) * zoomAlpha)

	-- Orbit centre: smooth follow, snap on big jumps
	local previous = focus
	local current: Vector3 = target
	if previous and (target - previous).Magnitude <= SNAP_DISTANCE then
		current = previous:Lerp(target, 1 - math.exp(-FOLLOW_SMOOTHING * rateFactor * dt)) -- CHANGED (Phase 11)
	end
	focus = current

	local offset = lastToWorkspace:VectorToWorldSpace(back * math.cos(pitch) + up * math.sin(pitch))
	local upWorkspace = lastToWorkspace:VectorToWorldSpace(up)
	camera.CFrame = CFrame.lookAt(current + offset * zoom, current, upWorkspace)
	camera.Focus = CFrame.new(current)
end

--============================================================================
-- API
--============================================================================

-- Takes over Workspace.CurrentCamera (Scriptable). getTarget returns the orbit centre and the up direction each
-- frame; nil keeps the last known ones.
function ChaseCamera.start(getTarget: () -> Target?)
	getTargetFn = getTarget
	if active then
		return
	end
	active = true

	-- Begin from the current view direction so taking over does not jump the view around.
	local camera = Workspace.CurrentCamera
	local first = getTarget()
	if first then
		lastUp = first.up
		lastToWorkspace = first.toWorkspace
	end
	if camera then
		-- the camera sits at -look from the target, expressed in the stable space
		back = horizontal(lastToWorkspace:VectorToObjectSpace(-camera.CFrame.LookVector), lastUp)
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
