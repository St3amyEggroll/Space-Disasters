--!strict
--[[
	EvaController (Phase 6, spec 7.9 "EVAController")
	The local astronaut on EVA (a spacewalk): on foot (not seated, alive) in any pocket but the base.

	Getting out: leaving a seat in flight (F, or the jump key) makes the server unseat the player and keep him in the
	pocket. EXIT_DELAY_S later (any PocketTransfer that came with the unseat, e.g. a passenger stepping off beside
	the pad, has arrived by then and taken him to the base) the EVA starts and puts him OUTSIDE THE HATCH: above the
	command pod's top (where its hatch is), else in front of / behind / beside the seat, the first spot no part of the
	craft overlaps (pocket-filtered query).

	Two modes:
	  FLOAT  in space, in the air, or next to anything that moves. The astronaut is a point mass with an ABSOLUTE state
	         (Shared/Sim/Eva: true gravity of the SOI body, a little air drag, ground contact on the SurfaceHeight
	         tiles), advanced every frame to the UT the pocket frame is drawn at (PocketController.renderUT), and the
	         character is placed at Frames.pointToWorkspace(frame, pos): Humanoid.PlatformStand, workspace.Gravity 0
	         (this client only, spike S3), the HumanoidRootPart's CFrame set every frame (never anchored, so physics
	         replication keeps working) and its velocity set to the velocity relative to the pocket (that is what the
	         server reads back). So he floats beside a coasting craft in orbit while its pilot turns it, a burning craft
	         leaves him behind, and pocket changes (bubbles, rebases) never move him. Deviation from the spec: the
	         HumanoidRootPart is set directly each frame (exact, no lag) instead of an AlignPosition, and the state is
	         absolute instead of an offset with gravity cancelled.
	         Jetpack: EvaForward / EvaBack / EvaLeft / EvaRight / EvaUp / EvaDown (W A S D Space Ctrl) push at
	         EVA_THRUST_ACCEL along the CAMERA's axes; EvaBrake (R) cancels the velocity relative to the nearest craft
	         (or the pocket); fuel EVA_PROPELLANT_S of full thrust, refilled while seated aboard any craft. He turns to
	         face where he flies. Collisions: a sphere cast (pocket-filtered: the real craft models of this pocket)
	         from where he was drawn last frame to where he is now; on a hit he stops at the surface and loses the
	         velocity into it, relative to the craft.
	  WALK   in a pocket that stands still on the ground (a landed craft, a surface solo pocket) and near the ground:
	         the normal Roblox character (walk, jump) with workspace.Gravity = Eva.walkGravity(body) (1/6 on the Mun,
	         spec 7.5), standing on an invisible client-only plate kept under him on the ground tile (so he never falls
	         through, whatever the terrain layer shows). Holding EvaUp fires the jetpack: a hop, 1.5 x his weight
	         upward (VectorForce) while fuel lasts. Too high above the ground (a long jetpack climb), or when the pocket
	         starts to move (the craft lifts off), he floats again.
	Leaving EVA (sitting down, dying, going home, the base pocket) gives everything back: PlatformStand off, normal
	gravity, the plate removed.

	Also: the helmet light (EvaLight, L), ToggleHUD (F2) on EVA, the EVA HUD (UI/EvaHUD: fuel, nearest craft distance
	and relative speed, ground height, board hint from the seat ProximityPrompts, "Return to plot" with a
	confirmation -> EndFlight), the jetpack flame / light for everyone (Render/EvaVisuals, EvaInput to the server).
	Boarding: the real SitPrompts of every craft in the pocket (uncrewed ones too: BubbleService gives uncrewed crafts
	near an astronaut a real model), checked by the server; a triggered SitPrompt also sends EvaBoard, so boarding
	does not depend on how the engine checks a prompt on a model that only the clients turn.

	Input is ignored while UIState blocks it (menus, dialogs) and while the map view is open. For touch buttons later:
	  EvaController.performAction(id) -> boolean   "EvaLight", "ToggleHUD", "ReturnToPlot"
	  EvaController.setHeld(id, held) -> boolean    EvaForward, EvaBack, EvaLeft, EvaRight, EvaUp, EvaDown, EvaBrake
	  EvaController.isActive() -> boolean
	  EvaController.returnToPlot()                  asks first, then EndFlight (like the HUD button)
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Eva = require(ReplicatedStorage.Shared.Sim.Eva)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local StateBuffer = require(ReplicatedStorage.Shared.Net.StateBuffer)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local DebugOverlay = require(script.Parent.DebugOverlay)
local EvaHUD = require(script.Parent.Parent.UI.EvaHUD)
local EvaVisuals = require(script.Parent.Parent.Render.EvaVisuals)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds)
local Kit = require(script.Parent.Parent.UI.Kit)
local MapViewController = require(script.Parent.MapViewController)
local PocketController = require(script.Parent.PocketController)
local RemoteCraftRenderer = require(script.Parent.RemoteCraftRenderer)
local Settings = require(script.Parent.Parent.Settings.Settings)
local UIState = require(script.Parent.Parent.UI.UIState)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local RENDER_STEP_NAME = "EvaController"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 11 -- after UniverseRenderer (Camera + 10): fresh frame
local THRUST_ACCEL = GameConfig.EVA_THRUST_ACCEL
local PROPELLANT_S = GameConfig.EVA_PROPELLANT_S
local INTERP_DELAY = GameConfig.INTERP_DELAY
local CHARACTER_GRAVITY = GameConfig.CHARACTER_GRAVITY
local EXIT_DELAY_S = 0.2 -- s after leaving a seat before the EVA starts (a transfer that came with it arrives first)
local EXIT_LIFT = 3 -- studs above a pod's top
local EXIT_CLEARANCE = 2.5 -- studs beyond a block's side when getting out sideways
local EXIT_PROBE_RADIUS = 1.5 -- studs: an exit spot must be this clear of the craft's parts
local COLLISION_RADIUS = 1.6 -- studs, the astronaut's body for collisions with crafts
local COLLISION_SKIN = 0.05 -- studs kept between him and a hull
local MAX_CAST = 60 -- studs; a bigger jump in one frame is a frame change, not a motion (no cast)
local TURN_RATE = 6 -- rad/s the astronaut turns toward where he flies
local WALK_TO_FLOAT_MAX_SPEED = 20 -- m/s: a hop's speed is capped when he starts floating
local PLATE_SIZE = Vector3.new(24, 1, 24) -- studs, the invisible ground plate under a walking astronaut
local UNSTEADY_S = 0.5 -- s the pocket must move before a walking astronaut starts floating
local UNDERGROUND_RESCUE = 1.5 -- studs: a walking astronaut whose feet sink this far below the ground is lifted out
local NEAREST_REFRESH_S = 0.25 -- s between searches for the nearest craft
local NEAREST_MAX_DISTANCE = 5000 -- m
local THRUST_SEND_S = 0.1 -- s between EvaInput "Thrust" messages (the last change is always sent)
local HELD_ACTIONS = { "EvaForward", "EvaBack", "EvaLeft", "EvaRight", "EvaUp", "EvaDown", "EvaBrake" }
local SIT_PROMPT = "SitPrompt" -- CrewService's seat prompts
local RETURN_TEXT = {
	title = "Return to your plot?",
	body = "You fly straight back to your plot at Space Disasters Inc. Your craft stays where it is.",
	confirm = "Return",
}
--============================================================================

type Mode = "Off" | "Float" | "Walk"

type Nearest = {
	id: number,
	name: string,
}

local EvaController = {}

local player = Players.LocalPlayer
local mode: Mode = "Off"
local state: Eva.State? = nil
local fuel = PROPELLANT_S
local lightOn = false
local thrusting = false
local yaw = 0 -- radians about pocket Y, the direction the astronaut faces
local lastWS: Vector3? = nil -- where he was drawn last frame (workspace)
local lastFrameKey = "" -- pocket identity of lastWS (a different frame: no collision cast)
local exitSeat: BasePart? = nil -- the seat he left, until the EVA starts
local exitAt = 0 -- os.clock() when the EVA may start after leaving a seat
local lastSeat: BasePart? = nil
local unsteadyTime = 0 -- s the walking astronaut's pocket has not stood still
local virtualHeld: { [string]: boolean } = {}
local nearest: Nearest? = nil
local nearestTimer = math.huge
local sentThrust = false
local lastThrustSend = 0
local shownPrompt: ProximityPrompt? = nil
local remotes: { [string]: RemoteEvent } = {}
local hud: EvaHUD.EvaHUD
local plate: Part
local hopAttachment: Attachment? = nil
local hopForce: VectorForce? = nil
local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Include
local overlapParams = OverlapParams.new()
overlapParams.FilterType = Enum.RaycastFilterType.Include
local castFolder: Instance? = nil -- the Crafts folder castParams currently includes

--============================================================================
-- Character
--============================================================================

local function localCharacter(): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if character and humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return character, humanoid, root
	end
	return nil, nil, nil
end

local function pocketFolder(): Instance?
	local pockets = Workspace:FindFirstChild("Pockets")
	return if pockets then pockets:FindFirstChild(`Pocket_{PocketController.pocketId()}`) else nil
end

-- Identity of the frame the astronaut was drawn in (a change means: no collision cast across it).
local function frameKey(folder: Instance): string
	return `{PocketController.pocketId()}:{tostring(folder:GetAttribute("FrameEpoch"))}:{tostring(
		folder:GetAttribute("PrimaryId")
	)}`
end

--============================================================================
-- Input
--============================================================================

local function inputAllowed(): boolean
	return not UIState.isInputBlocked() and not MapViewController.isOpen()
end

local function held(action: string): boolean
	if not inputAllowed() then
		return false
	end
	return virtualHeld[action] == true or Keybinds.isDown(action)
end

local function axis(positive: string, negative: string): number
	return (if held(positive) then 1 else 0) - (if held(negative) then 1 else 0)
end

local function sendLight()
	remotes.EvaInput:FireServer("Light", lightOn)
end

-- Tells the server when the jetpack starts or stops firing (at most every THRUST_SEND_S; the last change wins).
local function syncThrust()
	if thrusting == sentThrust then
		return
	end
	local now = os.clock()
	if now - lastThrustSend < THRUST_SEND_S then
		return
	end
	lastThrustSend = now
	sentThrust = thrusting
	remotes.EvaInput:FireServer("Thrust", thrusting)
end

--============================================================================
-- Other crafts (the nearest one: HUD and brake)
--============================================================================

-- A craft's state at the pocket's render UT (rails exact, the stream sampled and led like PocketController does).
local function craftStateAt(craftId: number, ut: number, now: number): Protocol.State?
	local rails = RemoteCraftRenderer.railsOf(craftId)
	if rails then
		return Rails.stateAt(rails, ut)
	end
	local sampleUT = math.min(ut, now - INTERP_DELAY)
	local sampled = RemoteCraftRenderer.sampleState(craftId, sampleUT)
	if sampled and ut > sampleUT then
		return StateBuffer.lead(sampled, ut, INTERP_DELAY)
	end
	return sampled
end

-- Position and velocity of a craft relative to the astronaut's body (nil when unknown).
local function craftRelative(craftId: number, s: Eva.State, now: number): (Vec3d?, Vec3d?)
	local craft = craftStateAt(craftId, s.ut, now)
	if craft == nil then
		return nil, nil
	end
	if craft.bodyId == s.bodyId then
		return craft.pos, craft.vel
	end
	local offset = Universe.bodyOffset(craft.bodyId, s.bodyId, s.ut)
	local velOffset = Universe.bodyVelocityOffset(craft.bodyId, s.bodyId, s.ut)
	return Vec3d.add(craft.pos, offset), Vec3d.add(craft.vel, velOffset)
end

local function findNearest(s: Eva.State, now: number)
	local best: Nearest? = nil
	local bestDistance = NEAREST_MAX_DISTANCE
	for _, id in RemoteCraftRenderer.craftIds() do
		if RemoteCraftRenderer.isDebris(id) then
			continue
		end
		local pos = craftRelative(id, s, now)
		if pos then
			local d = Vec3d.distance(pos, s.pos)
			if d < bestDistance then
				local design = RemoteCraftRenderer.design(id)
				best = { id = id, name = if design then design.name else "Craft" }
				bestDistance = d
			end
		end
	end
	nearest = best
end

--============================================================================
-- Getting out of the hatch
--============================================================================

local function craftModelOf(instance: Instance): Model?
	local node: Instance? = instance
	while node do
		if node:IsA("Model") and node:GetAttribute("CraftId") ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- A spot outside the craft next to the seat he left: above a pod's top (its hatch), else around the seat's block.
local function exitPosition(seat: BasePart): Vector3?
	local craft = craftModelOf(seat)
	local block = seat.Parent
	if craft == nil or block == nil or seat.Parent == nil then
		return nil
	end
	local bounds = block:FindFirstChild("Bounds")
	local box: BasePart = if bounds and bounds:IsA("BasePart") then bounds else seat
	local cf, size = box.CFrame, box.Size
	local candidates: { Vector3 } = {}
	if block:FindFirstChild("Hatch") then
		table.insert(candidates, cf.Position + cf.UpVector * (size.Y / 2 + EXIT_LIFT))
	end
	local look = seat.CFrame.LookVector
	local right = seat.CFrame.RightVector
	local half = math.max(size.X, size.Z) / 2 + EXIT_CLEARANCE
	table.insert(candidates, cf.Position + look * half)
	table.insert(candidates, cf.Position - look * half)
	table.insert(candidates, cf.Position + right * half)
	table.insert(candidates, cf.Position - right * half)
	table.insert(candidates, cf.Position + cf.UpVector * (size.Y / 2 + EXIT_LIFT))
	overlapParams.FilterDescendantsInstances = { craft }
	for _, candidate in candidates do
		if #Workspace:GetPartBoundsInRadius(candidate, EXIT_PROBE_RADIUS, overlapParams) == 0 then
			return candidate
		end
	end
	return candidates[1]
end

--============================================================================
-- Modes
--============================================================================

-- How well the pocket's up matches the ground's up under a body-relative point (cosine).
local function groundAlignment(frame: Frames.Frame, bodyId: number, pos: Vec3d): number
	local _, up = SurfaceHeight.height(bodyId, pos)
	local pocketUp = frame.refRot.UpVector
	return pocketUp.X * up.x + pocketUp.Y * up.y + pocketUp.Z * up.z
end

local function ensureHopForce(root: BasePart): VectorForce
	local force = hopForce
	if force and force.Parent ~= nil and hopAttachment and hopAttachment.Parent == root then
		return force
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "EvaHop"
	attachment.Parent = root
	local created = Instance.new("VectorForce")
	created.Name = "EvaHop"
	created.Attachment0 = attachment
	created.RelativeTo = Enum.ActuatorRelativeTo.World
	created.ApplyAtCenterOfMass = true
	created.Force = Vector3.zero
	created.Enabled = false
	created.Parent = root
	hopAttachment = attachment
	hopForce = created
	return created
end

local function stopHop()
	local force = hopForce
	if force then
		force.Enabled = false
		force.Force = Vector3.zero
	end
end

local function enterFloat(humanoid: Humanoid)
	mode = "Float"
	humanoid.PlatformStand = true
	Workspace.Gravity = 0
	stopHop()
	plate.Parent = nil
	lastWS = nil
end

local function enterWalk(humanoid: Humanoid, root: BasePart, frame: Frames.Frame, frameVel: Vec3d)
	local s = state :: Eva.State
	mode = "Walk"
	unsteadyTime = 0
	humanoid.PlatformStand = false
	Workspace.Gravity = Eva.walkGravity(frame.refBodyId)
	root.AssemblyLinearVelocity = Frames.vectorToWorkspace(frame, Vec3d.sub(s.vel, frameVel))
	plate.Parent = Workspace
	lastWS = nil
end

local function startEva(humanoid: Humanoid, root: BasePart)
	local frame = PocketController.frame()
	local frameVel = PocketController.frameVelocity()
	local ut = PocketController.renderUT()
	local seat = exitSeat
	exitSeat = nil
	local leftCraftVel: Vec3d? = nil
	if seat and seat.Parent ~= nil then
		local position = exitPosition(seat)
		if position then
			root.CFrame = CFrame.new(position) * Frames.rotationOnly(root.CFrame)
		end
		-- he leaves with the velocity of the craft he left
		local craft = craftModelOf(seat)
		local craftId = if craft then craft:GetAttribute("CraftId") else nil
		if type(craftId) == "number" then
			local probe = Eva.new(frame.refBodyId, Frames.pointFromWorkspace(frame, root.Position), frameVel, ut)
			local _, vel = craftRelative(craftId, probe, UniverseTime.now())
			leftCraftVel = vel
		end
	end
	local pos = Frames.pointFromWorkspace(frame, root.Position)
	local vel = leftCraftVel
	if vel == nil then
		-- no craft to take the velocity from: the character's own (it may have been falling with Roblox gravity)
		local rel = Frames.vectorFromWorkspace(frame, root.AssemblyLinearVelocity)
		local speed = Vec3d.length(rel)
		if speed > WALK_TO_FLOAT_MAX_SPEED then
			rel = Vec3d.scale(rel, WALK_TO_FLOAT_MAX_SPEED / speed)
		end
		vel = Vec3d.add(frameVel, rel)
	end
	local s = Eva.new(frame.refBodyId, pos, vel :: Vec3d, ut)
	state = s
	local look = root.CFrame.LookVector
	yaw = math.atan2(-look.X, -look.Z)
	nearest = nil
	nearestTimer = math.huge
	enterFloat(humanoid)
	-- next to a landed craft (a pocket that stands still on the ground) he steps out and drops to the ground walking
	local stationary = Eva.stationaryPocket(Vec3d.length(frameVel), groundAlignment(frame, s.bodyId, s.pos))
	if stationary and Eva.shouldWalk(true, true, Eva.groundHeight(s.bodyId, s.pos), 0) then
		enterWalk(humanoid, root, frame, frameVel)
	end
	if lightOn then
		sendLight()
	end
end

local function stopEva()
	if mode == "Off" then
		return
	end
	mode = "Off"
	state = nil
	lastWS = nil
	table.clear(virtualHeld) -- touch holds end with the EVA
	stopHop()
	plate.Parent = nil
	Workspace.Gravity = CHARACTER_GRAVITY
	local _, humanoid = localCharacter()
	if humanoid then
		humanoid.PlatformStand = false
	end
	thrusting = false
end

--============================================================================
-- Per frame
--============================================================================

-- Camera axes in universe axes (doubles).
local function cameraAxes(frame: Frames.Frame): (Vec3d, Vec3d, Vec3d)
	local camera = Workspace.CurrentCamera
	local cf = if camera then camera.CFrame else CFrame.identity
	return Frames.vectorFromWorkspace(frame, cf.LookVector),
		Frames.vectorFromWorkspace(frame, cf.RightVector),
		Frames.vectorFromWorkspace(frame, cf.UpVector)
end

local function stepFloat(dt: number, root: BasePart, humanoid: Humanoid, folder: Instance, now: number)
	local s = state :: Eva.State
	local frame = PocketController.frame()
	local frameVel = PocketController.frameVelocity()
	local ut = PocketController.renderUT()
	if s.bodyId ~= frame.refBodyId then
		Eva.setBody(s, frame.refBodyId)
	end

	-- the nearest craft's velocity: what "brake" stops against, and what a hull moves with
	local targetVel: Vec3d = frameVel
	local target = nearest
	if target then
		local _, vel = craftRelative(target.id, s, now)
		if vel then
			targetVel = vel
		end
	end

	-- jetpack
	local f, r, u = axis("EvaForward", "EvaBack"), axis("EvaRight", "EvaLeft"), axis("EvaUp", "EvaDown")
	local forward, right, up = cameraAxes(frame)
	local direction = Eva.thrustDirection(forward, right, up, f, r, u)
	local accel = Vec3d.scale(direction, THRUST_ACCEL)
	if held("EvaBrake") then
		accel = Eva.brakeAccel(Vec3d.sub(s.vel, targetVel), THRUST_ACCEL, dt)
	end
	local fraction: number
	fuel, fraction = Eva.burn(fuel, Vec3d.length(accel), dt)
	accel = Vec3d.scale(accel, fraction)
	thrusting = Vec3d.length(accel) > 0.05

	Eva.advance(s, ut, if thrusting then accel else nil)

	-- collisions with the crafts of this pocket (relative motion since last frame, in the workspace)
	local key = frameKey(folder)
	local crafts = folder:FindFirstChild("Crafts")
	if crafts ~= castFolder then
		castFolder = crafts
		castParams.FilterDescendantsInstances = if crafts then { crafts } else {}
	end
	local position = Frames.pointToWorkspace(frame, s.pos)
	local previous = lastWS
	if previous and lastFrameKey == key and crafts then
		local delta = position - previous
		local distance = delta.Magnitude
		if distance > 1e-4 and distance < MAX_CAST then
			local hit = Workspace:Spherecast(previous, COLLISION_RADIUS, delta, castParams)
			if hit then
				position = previous + delta.Unit * math.max(hit.Distance - COLLISION_SKIN, 0)
				s.pos = Frames.pointFromWorkspace(frame, position)
				s.vel = Eva.collide(s.vel, targetVel, Frames.vectorFromWorkspace(frame, hit.Normal))
			end
		end
	end
	lastWS = position
	lastFrameKey = key

	-- face where he flies (horizontal part of the push, in pocket axes)
	if f ~= 0 or r ~= 0 then
		local push = Frames.vectorToWorkspace(frame, direction)
		local flat = Vector3.new(push.X, 0, push.Z)
		if flat.Magnitude > 1e-3 then
			local wanted = math.atan2(-flat.X, -flat.Z)
			local diff = (wanted - yaw + math.pi) % (2 * math.pi) - math.pi
			yaw += math.clamp(diff, -TURN_RATE * dt, TURN_RATE * dt)
		end
	end
	root.CFrame = CFrame.new(position) * CFrame.Angles(0, yaw, 0)
	root.AssemblyLinearVelocity = Frames.vectorToWorkspace(frame, Vec3d.sub(s.vel, frameVel))
	root.AssemblyAngularVelocity = Vector3.zero

	-- touch down in a pocket that stands still on the ground: walk
	local feet = Eva.groundHeight(s.bodyId, s.pos)
	local stationary = Eva.stationaryPocket(Vec3d.length(frameVel), groundAlignment(frame, s.bodyId, s.pos))
	if Eva.shouldWalk(false, stationary, feet, Vec3d.length(s.vel)) then
		enterWalk(humanoid, root, frame, frameVel)
	end
end

local function stepWalk(dt: number, root: BasePart, humanoid: Humanoid)
	local s = state :: Eva.State
	local frame = PocketController.frame()
	local frameVel = PocketController.frameVelocity()
	s.bodyId = frame.refBodyId
	s.pos = Frames.pointFromWorkspace(frame, root.Position)
	s.vel = Vec3d.add(frameVel, Frames.vectorFromWorkspace(frame, root.AssemblyLinearVelocity))
	s.ut = PocketController.renderUT()
	local gravity = Eva.walkGravity(frame.refBodyId)
	if Workspace.Gravity ~= gravity then
		Workspace.Gravity = gravity
	end

	-- the plate on the ground tile under him
	local h, up = SurfaceHeight.height(s.bodyId, s.pos)
	local ground = Frames.pointToWorkspace(frame, Vec3d.addScaled(s.pos, up, -h))
	local upWS = Frames.vectorToWorkspace(frame, up)
	local across = upWS:Cross(Vector3.zAxis)
	if across.Magnitude < 1e-3 then
		across = upWS:Cross(Vector3.xAxis)
	end
	plate.CFrame = CFrame.fromMatrix(ground - upWS * (PLATE_SIZE.Y / 2), across.Unit, upWS)
	-- never under the ground (the plate would be above him): back onto it, without the fall
	if h < Eva.ROOT_HEIGHT - UNDERGROUND_RESCUE then
		root.CFrame = root.CFrame + upWS * (Eva.ROOT_HEIGHT - h)
		local v = root.AssemblyLinearVelocity
		local down = v:Dot(upWS)
		if down < 0 then
			root.AssemblyLinearVelocity = v - upWS * down
		end
	end

	-- jetpack hop
	local force = ensureHopForce(root)
	thrusting = false
	if held("EvaUp") and fuel > 0 then
		local fraction: number
		fuel, fraction = Eva.burn(fuel, THRUST_ACCEL, dt)
		if fraction > 0 then
			force.Force = upWS * Eva.hopForce(root.AssemblyMass, Workspace.Gravity) * fraction
			force.Enabled = true
			thrusting = true
		end
	end
	if not thrusting then
		stopHop()
	end

	-- the pocket moves (for UNSTEADY_S: a resting craft's state jitters) or he flew high: float
	local feet = h - Eva.ROOT_HEIGHT
	local stationary = Eva.stationaryPocket(Vec3d.length(frameVel), groundAlignment(frame, s.bodyId, s.pos))
	unsteadyTime = if stationary then 0 else unsteadyTime + dt
	if not Eva.shouldWalk(true, unsteadyTime < UNSTEADY_S, feet, Vec3d.length(s.vel)) then
		local rel = Vec3d.sub(s.vel, frameVel)
		local speed = Vec3d.length(rel)
		if speed > WALK_TO_FLOAT_MAX_SPEED then
			s.vel = Vec3d.add(frameVel, Vec3d.scale(rel, WALK_TO_FLOAT_MAX_SPEED / speed))
		end
		local look = root.CFrame.LookVector
		yaw = math.atan2(-look.X, -look.Z)
		enterFloat(humanoid)
	end
end

local function boardText(): string?
	local prompt = shownPrompt
	if prompt == nil or prompt.Parent == nil or not prompt.Enabled then
		return nil
	end
	return `Press {Keybinds.keyLabel(prompt.KeyboardKeyCode)} to {prompt.ActionText}: {prompt.ObjectText}`
end

local function hudData(): EvaHUD.Data?
	local s = state
	if s == nil or mode == "Off" then
		return nil
	end
	local data: EvaHUD.Data = {
		mode = if mode == "Walk" then "Walk" else "Float",
		fuel = fuel / PROPELLANT_S,
		thrusting = thrusting,
		light = lightOn,
		bodyName = Bodies.get(s.bodyId).DisplayName,
		groundHeight = nil,
		targetName = nil,
		targetDistance = nil,
		targetSpeed = nil,
		boardText = boardText(),
	}
	local feet = Eva.groundHeight(s.bodyId, s.pos)
	if feet < NEAREST_MAX_DISTANCE then
		data.groundHeight = feet
	end
	local target = nearest
	if target then
		local pos, vel = craftRelative(target.id, s, UniverseTime.now())
		if pos and vel then
			data.targetName = target.name
			data.targetDistance = Vec3d.distance(pos, s.pos)
			data.targetSpeed = Vec3d.distance(vel, s.vel)
		end
	end
	return data
end

local function step(dt: number)
	local now = os.clock()
	local _, humanoid, root = localCharacter()
	local seated = humanoid ~= nil and humanoid.SeatPart ~= nil
	if seated then
		fuel = Eva.refill(fuel, dt) -- aboard a craft the jetpack fills up
	end
	local folder = pocketFolder()
	local want = humanoid ~= nil
		and root ~= nil
		and not seated
		and PocketController.pocketId() ~= 0
		and folder ~= nil
		and now >= exitAt
	if not want then
		stopEva()
		if now >= exitAt then
			exitSeat = nil -- the seat he left no longer matters (he went home, or sat down again)
		end
		EvaVisuals.update(false, false)
		hud.update(nil)
		syncThrust()
		return
	end
	local h, r = humanoid :: Humanoid, root :: BasePart
	if mode == "Off" then
		startEva(h, r)
	end
	local s = state :: Eva.State
	if not (Vec3d.isFinite(s.pos) and Vec3d.isFinite(s.vel)) then
		-- never keep a broken state: start again from where the character is
		mode = "Off"
		startEva(h, r)
	end
	local utNow = UniverseTime.now()
	nearestTimer += dt
	if nearestTimer >= NEAREST_REFRESH_S then
		nearestTimer = 0
		findNearest(state :: Eva.State, utNow)
	end
	if mode == "Float" then
		stepFloat(dt, r, h, folder :: Instance, utNow)
	else
		stepWalk(dt, r, h)
	end
	syncThrust()
	EvaVisuals.update(thrusting, lightOn)
	hud.update(hudData())
end

--============================================================================
-- Actions
--============================================================================

-- Asks the server to seat the astronaut in the seat a SitPrompt belongs to (a craft in his pocket).
local function boardSeatOf(prompt: ProximityPrompt)
	local seat = prompt.Parent
	local block = if seat then seat.Parent else nil
	local craft = if seat then craftModelOf(seat) else nil
	local blockId = if block then block:GetAttribute("BlockId") else nil
	local craftId = if craft then craft:GetAttribute("CraftId") else nil
	if type(blockId) == "number" and type(craftId) == "number" then
		remotes.EvaBoard:FireServer(craftId, blockId)
	end
end

local function returnToPlot()
	if mode == "Off" or Kit.isConfirmOpen() then
		return
	end
	Kit.confirm({
		title = RETURN_TEXT.title,
		body = RETURN_TEXT.body,
		confirmText = RETURN_TEXT.confirm,
		danger = true,
	}, function(confirmed: boolean)
		if confirmed and EvaController.isActive() then
			remotes.EndFlight:FireServer()
		end
	end)
end

local function performAction(action: string): boolean
	if action == "EvaLight" then
		lightOn = not lightOn
		if mode ~= "Off" then
			sendLight()
		end
	elseif action == "ToggleHUD" then
		Settings.set("hudVisible", not Settings.current().hudVisible)
	elseif action == "ReturnToPlot" then
		returnToPlot()
	else
		return false
	end
	return true
end

--============================================================================
-- Lifecycle
--============================================================================

local function watchCharacter(character: Model)
	lastSeat = nil
	exitSeat = nil
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil or not humanoid:IsA("Humanoid") then
		return
	end
	local h = humanoid :: Humanoid
	lastSeat = h.SeatPart
	h:GetPropertyChangedSignal("SeatPart"):Connect(function()
		local seat = h.SeatPart
		if seat then
			lastSeat = seat
			exitSeat = nil
		elseif lastSeat then
			-- just got out: start the EVA (outside the hatch) a moment later
			exitSeat = lastSeat
			exitAt = os.clock() + EXIT_DELAY_S
			lastSeat = nil
		end
	end)
end

function EvaController.Init()
	remotes.EvaInput = Remotes.event("EvaInput")
	remotes.EndFlight = Remotes.event("EndFlight")
	remotes.EvaBoard = Remotes.event("EvaBoard")
	hud = EvaHUD.create({ onReturn = returnToPlot })
	plate = Instance.new("Part")
	plate.Name = "EvaGroundPlate"
	plate.Size = PLATE_SIZE
	plate.Anchored = true
	plate.CanCollide = true
	plate.CanQuery = false
	plate.CanTouch = false
	plate.Transparency = 1
	plate.CastShadow = false
	DebugOverlay.addLine("eva", 21.5, function()
		local s = state
		if s == nil or mode == "Off" then
			return "EVA: off"
		end
		return string.format(
			"EVA: %s  fuel %.0f s  feet %.1f m  v %.1f m/s  %s",
			mode,
			fuel,
			Eva.groundHeight(s.bodyId, s.pos),
			Vec3d.length(Vec3d.sub(s.vel, PocketController.frameVelocity())),
			if nearest then `nearest {(nearest :: Nearest).name}` else "no craft near"
		)
	end)
end

function EvaController.Start()
	player.CharacterAdded:Connect(function(character: Model)
		stopEva()
		watchCharacter(character)
	end)
	if player.Character then
		task.spawn(watchCharacter, player.Character)
	end
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if prompt.Name == SIT_PROMPT then
			shownPrompt = prompt
		end
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		if prompt == shownPrompt then
			shownPrompt = nil
		end
	end)
	-- boarding from EVA: the SitPrompt's own server trigger, plus EvaBoard (see Remotes: whichever comes second
	-- finds the seat taken)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
		if prompt.Name == SIT_PROMPT and mode ~= "Off" then
			boardSeatOf(prompt)
		end
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or mode == "Off" or UIState.isInputBlocked() then
			return
		end
		local key = input.KeyCode
		if key == Keybinds.UNBOUND then
			return
		end
		if key == Keybinds.key("EvaLight") then
			performAction("EvaLight")
		elseif key == Keybinds.key("ToggleHUD") then
			performAction("ToggleHUD")
		end
	end)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
end

-- Is the local player on EVA right now?
function EvaController.isActive(): boolean
	return mode ~= "Off"
end

-- Runs a discrete EVA action like its key: "EvaLight", "ToggleHUD", "ReturnToPlot". False for anything else.
function EvaController.performAction(action: string): boolean
	return performAction(action)
end

-- Holds or releases a held EVA action (jetpack directions, brake) like its key, for touch buttons.
function EvaController.setHeld(action: string, isHeld: boolean): boolean
	if not table.find(HELD_ACTIONS, action) then
		return false
	end
	if isHeld then
		virtualHeld[action] = true
	else
		virtualHeld[action] = nil
	end
	return true
end

-- Asks first, then sends the astronaut home (like the HUD's "Return to plot").
function EvaController.returnToPlot()
	returnToPlot()
end

return EvaController
