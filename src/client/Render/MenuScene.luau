--!strict
--[[
	MenuScene (Phase 11)
	The live 3D space scene behind the main menu (Steamy: "characters floating in space as the play screen, and
	stuff happening in the background"). Client-only parts in workspace.MainMenuScene, built around MENU_ORIGIN, far
	below everything else (the base pocket is at the origin, flight pocket slots at y = 4000..12000, the map at
	+-2000 from a slot), with the camera at MENU_ORIGIN looking down workspace -Z.

	What is in it:
	  * The player's own avatar (no spacesuit): a clone of the local character (Archivable set locally for the
	    clone, then restored) with scripts, Animator, sounds and tools stripped, the name hidden, only the
	    HumanoidRootPart anchored and nothing colliding, queried or touched. It floats in front of the camera,
	    slowly rolling and swaying, with a relaxed pose animated through Motor6D.Transform (arms drifting out,
	    knees bent, slow breathing). The clone waits for the appearance (HasAppearanceLoaded, up to
	    APPEARANCE_TIMEOUT_S) and is redone when CharacterAppearanceLoaded or a new character arrives. Without any
	    character after the timeout a blocky stand-in made of parts floats there instead.
	  * Up to MAX_OTHERS other players of the server floating further back (clones of their characters, the same
	    way; players without a loaded, visible character are skipped quietly; refreshed every OTHER_REFRESH_S).
	  * Space junk built from the game's own parts (CraftBuilder "Cosmetic": a scorched fuel tank with its engine,
	    a big decoupler, a nose cone, a tank with its cone) and a satellite made of parts (body, two solar panels,
	    a dish, a blinking light), tumbling slowly across the view and respawning off-screen after they leave it.
	  * Shooting stars: short-lived neon streaks with a Trail, far behind the scene.
	  * Sun glare: a Bloom and a SunRays effect in Lighting while the scene runs, and the lens flare overlay
	    (Render/MenuSceneFlare) in the menu's ScreenGui, faded out when the sun is off-screen or behind Earth, the
	    Mun or the avatar. A soft blue fill light keeps the avatar's shadow side readable.
	  * The real universe around it: UniverseRenderer.setViewOverride(frame) with a frame that maps MENU_ORIGIN to a
	    viewpoint VIEW_ALTITUDE above Earth (above the air: the SkyCube is black and ScaledSpace in scaled mode).
	    Each frame MenuSceneMath.solveView turns the view so Earth's limb is at LIMB_NY on screen, Sol at
	    (SUN_NX, SUN_NY) and the Mun (at its real position for the menu's UT) drifts around (MUN_NX, MUN_NY); the
	    targets sway slowly so the whole view drifts. CHANGED (Phase 11 review): the view runs on its own menu time
	    (UniverseRenderer.setViewOverride's ut), started MenuSceneMath.timeOffset ahead of the real UT so the sun /
	    Mun angle is MUN_SEPARATION_MIN..MAX (the Mun can be framed and shows a lit crescent) and slowed to
	    MENU_TIME_RATE; if it ever drifts out of MUN_KEEP_MIN..MAX the offset is picked again (at most every
	    MUN_REPICK_MIN_S). Lighting on the avatar comes from the real sun via SkyLighting (the workspace axes are the camera's, and the sun is kept above the screen centre so Roblox
	    lights the scene as day).

	start() takes the camera (Scriptable, MENU_FOV) and binds one render step before UniverseRenderer's; stop()
	unbinds it, gives the camera back (CameraType Custom, CameraSubject = the local Humanoid, the old field of
	view), removes the Lighting effects and the view override and parks the scene folder (kept for a cheap
	reopen; other players' clones are destroyed). Nothing of this module runs while it is stopped.

	API:
	  MenuScene.MENU_ORIGIN: Vector3
	  MenuScene.start(flareParent: GuiObject)   flareParent: a full-screen frame in the menu ScreenGui
	  MenuScene.stop()
	  MenuScene.isRunning() -> boolean
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime) -- CHANGED (Phase 11 review): menu time
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local MenuSceneFlare = require(script.Parent.MenuSceneFlare)
local MenuSceneMath = require(script.Parent.MenuSceneMath)
local UniverseRenderer = require(script.Parent.Parent.Controllers.UniverseRenderer)

--============================================================================
-- Tunables
--============================================================================
local MENU_ORIGIN = Vector3.new(0, -6000, 0) -- far from the base (origin), pocket slots (y >= 4000) and maps
local FOLDER_NAME = "MainMenuScene"
local RENDER_STEP_NAME = "MainMenuScene"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 5 -- after ChaseCamera (+1), before UniverseRenderer (+10)
local MENU_FOV = 60 -- degrees (vertical)
local CAMERA_SWAY_DEG = Vector2.new(0.35, 0.45) -- slow "handheld" pitch / yaw sway amplitude
local CAMERA_SWAY_PERIODS = Vector2.new(13, 17) -- s

-- The view of the universe (MenuSceneMath.solveView)
local VIEW_ALTITUDE = 10000 -- m above Earth's sea level (air ends at 7 km: black sky, scaled mode)
local LIMB_NY = -0.28 -- Earth's horizon this far below the screen centre (normalised, -1 = bottom edge)
local SUN_NX, SUN_NY = 0.78, 0.72 -- where Sol sits on screen (normalised; top right: glare, and Earth's day side)
local SUN_DRIFT = Vector2.new(0.05, 0.06) -- slow sway of that point
local SUN_DRIFT_PERIOD = 110 -- s
local MUN_NX, MUN_NY = 0.0, 0.45 -- the Mun's target on screen (it drifts around this)
local MUN_DRIFT = Vector2.new(0.42, 0.08)
local MUN_DRIFT_PERIOD = 170 -- s
local MUN_TRACK_RATE = math.rad(5) -- rad/s: how fast the viewpoint may slide around the sun cone to follow
local ALPHA_SAMPLES = 120 -- global search when the scene starts
local OCCLUSION_SOFT = math.rad(0.8) -- soft edge of Earth / Mun hiding the sun (flare)
-- CHANGED (Phase 11 review): the menu's own time (header), so the Mun is always where the view can frame it
local MENU_TIME_RATE = 0.25 -- menu UT seconds per real second (the sun / Mun angle changes ~0.06 deg/s)
local MUN_SEPARATION_MIN = math.rad(50) -- sun / Mun angle (Earth-centred) picked when the scene starts ...
local MUN_SEPARATION_MAX = math.rad(70)
local MUN_KEEP_MIN = math.rad(30) -- ... and kept while it stays in here (beyond it: picked again)
local MUN_KEEP_MAX = math.rad(90)
local MUN_SEARCH_SPAN_S = 3000 -- UT seconds searched ahead (about two synodic periods of the Mun)
local MUN_SEARCH_STEP_S = 5
local MUN_REPICK_MIN_S = 30 -- real seconds between two searches (none succeeding must not search every frame)

-- The player's avatar
local AVATAR_DISTANCE = 11 -- studs in front of the camera
local AVATAR_NX, AVATAR_NY = 0.26, -0.04 -- screen position (normalised), right of the menu panel
local AVATAR_BOB = 0.35 -- studs, slow up / down float
local AVATAR_BOB_PERIOD = 7 -- s
local AVATAR_ROLL_RATE = 0.1 -- rad/s, continuous roll about the view axis (face stays toward the camera)
local AVATAR_SWING_DEG = Vector2.new(22, 34) -- pitch / yaw swing amplitude
local AVATAR_SWING_PERIODS = Vector2.new(19, 27) -- s
local AVATAR_OCCLUSION_RADIUS = 2.6 -- studs, the avatar's disc for hiding the flare
local APPEARANCE_TIMEOUT_S = 8 -- wait this long for the appearance (or a character) before showing what exists
local FACE_CAMERA = CFrame.Angles(0, math.pi, 0) -- characters face -Z; the camera looks down -Z

-- Other players
local MAX_OTHERS = 3
local OTHER_REFRESH_S = 3
type OtherSlot = { nx: number, ny: number, depth: number, roll: number, phase: number }
local OTHER_SLOTS: { OtherSlot } = {
	{ nx = -0.12, ny = 0.3, depth = 28, roll = -0.07, phase = 1.3 },
	{ nx = 0.68, ny = 0.28, depth = 36, roll = 0.08, phase = 2.9 },
	{ nx = 0.1, ny = -0.45, depth = 42, roll = -0.06, phase = 4.4 },
}

-- Floating pose (Motor6D.Transform), degrees in the joint parent's axes (X right, Y up, Z back):
-- base + sway * sin(breath + offset). Shoulders: +Z lifts the right arm out; hips / elbows: +X swings forward.
type PoseSpec = { base: Vector3, sway: Vector3, offset: number }
local POSE: { [string]: PoseSpec } = {
	RightShoulder = { base = Vector3.new(12, 0, 58), sway = Vector3.new(4, 0, 6), offset = 0 },
	LeftShoulder = { base = Vector3.new(8, 0, -52), sway = Vector3.new(4, 0, -6), offset = 0.6 },
	RightElbow = { base = Vector3.new(28, 0, 0), sway = Vector3.new(6, 0, 0), offset = 0.3 },
	LeftElbow = { base = Vector3.new(20, 0, 0), sway = Vector3.new(6, 0, 0), offset = 0.9 },
	RightHip = { base = Vector3.new(14, 0, 9), sway = Vector3.new(5, 0, 2), offset = 1.4 },
	LeftHip = { base = Vector3.new(-6, 0, -11), sway = Vector3.new(4, 0, -2), offset = 2.0 },
	RightKnee = { base = Vector3.new(-30, 0, 0), sway = Vector3.new(6, 0, 0), offset = 1.7 },
	LeftKnee = { base = Vector3.new(-18, 0, 0), sway = Vector3.new(5, 0, 0), offset = 2.3 },
	Waist = { base = Vector3.new(4, 0, 0), sway = Vector3.new(3, 0, 2), offset = 0 },
	Neck = { base = Vector3.new(-8, 0, 0), sway = Vector3.new(4, 12, 3), offset = 0.4 },
}
-- Motor6D names (R15 and R6) -> pose roles
local JOINT_ROLES: { [string]: string } = {
	RightShoulder = "RightShoulder",
	["Right Shoulder"] = "RightShoulder",
	LeftShoulder = "LeftShoulder",
	["Left Shoulder"] = "LeftShoulder",
	RightElbow = "RightElbow",
	LeftElbow = "LeftElbow",
	RightHip = "RightHip",
	["Right Hip"] = "RightHip",
	LeftHip = "LeftHip",
	["Left Hip"] = "LeftHip",
	RightKnee = "RightKnee",
	LeftKnee = "LeftKnee",
	Waist = "Waist",
	Neck = "Neck",
}
local BREATH_PERIOD = 4.5 -- s

-- Blocky stand-in (no character): the classic colours
local STAND_IN_HEAD = Color3.fromRGB(245, 205, 48)
local STAND_IN_TORSO = Color3.fromRGB(13, 105, 172)
local STAND_IN_LEGS = Color3.fromRGB(40, 127, 71)
local STAND_IN_FACE = "rbxasset://textures/face.png"

-- Space junk (CraftBuilder designs, grid blocks) and the satellite
type JunkBlock = { part: string, gx: number, gy: number, gz: number, rot: number, color: number? }
local JUNK_DESIGNS: { { name: string, blocks: { JunkBlock } } } = {
	{
		name = "BrokenStage",
		blocks = {
			{ part = "engine_s", gx = 0, gy = 0, gz = 0, rot = 0 },
			{ part = "tank_s_long", gx = 0, gy = 1, gz = 0, rot = 0, color = 3 }, -- scorched dark grey
		},
	},
	{ name = "Decoupler", blocks = { { part = "decoupler_l", gx = 0, gy = 0, gz = 0, rot = 0 } } },
	{ name = "NoseCone", blocks = { { part = "nose_s", gx = 0, gy = 0, gz = 0, rot = 0 } } },
	{
		name = "TankWithCone",
		blocks = {
			{ part = "tank_l_short", gx = 0, gy = 0, gz = 0, rot = 0 },
			{ part = "nose_l", gx = 0, gy = 1, gz = 0, rot = 0 },
		},
	},
}
local DEAD_ENGINE_COLOR = Color3.fromRGB(40, 36, 34) -- the engines' neon glow, switched off
local JUNK_DEPTH_MIN, JUNK_DEPTH_MAX = 24, 75 -- studs from the camera (behind the avatar)
local JUNK_SPEED_MIN, JUNK_SPEED_MAX = 1.2, 3.2 -- studs/s across the view
local JUNK_VERTICAL_DRIFT = 0.25 -- vertical speed as a fraction of the horizontal one (random sign)
local JUNK_DEPTH_DRIFT = 0.08 -- same for depth
local JUNK_SPIN_MIN, JUNK_SPIN_MAX = 0.08, 0.4 -- rad/s tumble
local JUNK_Y_RANGE = 0.8 -- vertical spawn range (fraction of the half height)
local JUNK_START_SPREAD = 0.85 -- at start, junk is spread over this fraction of the view width
local JUNK_EDGE_MARGIN = 4 -- studs beyond the view edge before a piece counts as gone
local JUNK_RESPAWN_MIN, JUNK_RESPAWN_MAX = 2, 9 -- s off-screen before a piece comes back
local SATELLITE_BODY = Vector3.new(2.4, 2.4, 3)
local SATELLITE_FOIL = Color3.fromRGB(214, 172, 58)
local SATELLITE_PANEL = Vector3.new(6, 0.15, 2.2) -- each solar wing
local SATELLITE_PANEL_COLOR = Color3.fromRGB(28, 46, 104)
local SATELLITE_METAL = Color3.fromRGB(170, 174, 180)
local SATELLITE_DISH_DIAMETER = 2.6
local SATELLITE_LIGHT_COLOR = Color3.fromRGB(255, 60, 50)
local BLINK_PERIOD = 1.4 -- s
local BLINK_ON = 0.18 -- s lit per period

-- Shooting stars
local STAR_POOL = 3
local STAR_DEPTH_MIN, STAR_DEPTH_MAX = 160, 260 -- studs (inside the smallest SkyCube, half-size 400)
local STAR_SPEED_MIN, STAR_SPEED_MAX = 160, 260 -- studs/s
local STAR_LIFE_MIN, STAR_LIFE_MAX = 0.35, 0.7 -- s
local STAR_INTERVAL_MIN, STAR_INTERVAL_MAX = 1.2, 4.5 -- s between two
local STAR_SLOPE_MIN, STAR_SLOPE_MAX = math.rad(12), math.rad(40) -- downward angle of the streak
local STAR_AREA = Vector2.new(0.9, 0.85) -- spawn area (fractions of the half extents), upper half of the view
local STAR_WIDTH = 1.2 -- studs (trail width)
local STAR_HEAD_SIZE = 0.6
local STAR_TRAIL_LIFETIME = 0.25 -- s
local STAR_COLOR = Color3.fromRGB(220, 235, 255)

-- Glare and light
local BLOOM_INTENSITY = 0.7
local BLOOM_SIZE = 30
local BLOOM_THRESHOLD = 1.5
local SUNRAYS_INTENSITY = 0.04
local SUNRAYS_SPREAD = 0.55
local BLOOM_NAME = "MainMenuBloom"
local SUNRAYS_NAME = "MainMenuSunRays"
local FLARE_EDGE_MARGIN = 0.1 -- fraction of the screen height over which the flare fades at the edges
local FLARE_DISTANCE = 1000 -- studs along the sun direction for the viewport projection
local FILL_LIGHT_OFFSET = Vector3.new(-4, 3, -3) -- camera-local
local FILL_LIGHT_COLOR = Color3.fromRGB(150, 175, 255)
local FILL_LIGHT_BRIGHTNESS = 0.7
local FILL_LIGHT_RANGE = 24
--============================================================================

type Joint = { motor: Motor6D, pose: PoseSpec, c0: CFrame, c0Inverse: CFrame }
type Figure = {
	model: Model,
	root: BasePart,
	joints: { Joint },
	source: Model?, -- the character it was cloned from (nil = the blocky stand-in)
	pending: boolean, -- cloned before the appearance had loaded
}
type Rig = { parts: { BasePart }, offsets: { CFrame }, radius: number }
type Mover = {
	rig: Rig,
	position: Vector3, -- camera-local
	velocity: Vector3,
	axis: Vector3,
	spin: number,
	angle: number,
	orientation: CFrame,
	wait: number, -- s until it respawns (> 0 while off-screen)
}
type Streak = {
	part: Part,
	trail: Trail,
	position: Vector3, -- camera-local
	velocity: Vector3,
	life: number,
	maxLife: number,
	active: boolean,
	arm: boolean, -- enable the trail next frame (after the teleport)
}
type Other = { player: Player, figure: Figure, slot: number }

local MenuScene = {}

MenuScene.MENU_ORIGIN = MENU_ORIGIN

local player = Players.LocalPlayer
local rng = Random.new()

local running = false
local built = false
local folder: Folder? = nil
local flare: MenuSceneFlare.Flare? = nil
local flareHost: GuiObject? = nil
local viewFrame = Frames.new(Bodies.HOMEWORLD, Vec3d.zero(), CFrame.identity, MENU_ORIGIN, 0)
local viewParams: MenuSceneMath.ViewParams = {
	earthRadius = Bodies.get(Bodies.HOMEWORLD).Radius,
	distance = Bodies.get(Bodies.HOMEWORLD).Radius + VIEW_ALTITUDE,
	sunDir = Vec3d.new(1, 0, 0),
	munPos = Vec3d.new(1, 0, 0),
	munRadius = Bodies.get(Bodies.MOON).Radius,
	pitch = 0,
	sunAzimuth = 0,
	sunElevation = 0,
	munAzimuth = 0,
	munElevation = 0,
}
local alpha: number? = nil -- position on the sun cone (nil = search again)
local menuUT = 0 -- CHANGED (Phase 11 review): the UT the menu view shows (header)
local nextPickAt = 0 -- CHANGED (Phase 11 review): clock before which the menu time is not searched again
local clock = 0 -- s since start()
local startedAt = 0 -- clock at the last start (appearance timeout)

local localFigure: Figure? = nil
local failedSource: Model? = nil -- a character whose clone failed (not retried)
local appearanceDirty = false
local others: { Other } = {}
local otherTimer = math.huge
local movers: { Mover } = {}
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local satelliteLight: BasePart? = nil
local satelliteGlow: PointLight? = nil
local streaks: { Streak } = {}
local nextStreak = 0
local fillLight: Part? = nil
local connections: { RBXScriptConnection } = {}

-- Camera state to restore
local savedFov = 70

--============================================================================
-- Figures (avatars)
--============================================================================

local function collectJoints(model: Model): { Joint }
	local joints: { Joint } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") then
			descendant.Transform = CFrame.identity
			local role = JOINT_ROLES[descendant.Name]
			local pose = if role then POSE[role] else nil
			if pose then
				local c0 = Frames.rotationOnly(descendant.C0)
				table.insert(joints, { motor = descendant, pose = pose, c0 = c0, c0Inverse = c0:Inverse() })
			end
		end
	end
	return joints
end

-- Turns a character-like model into a passive floating figure (header).
local function prepareFigure(model: Model, source: Model?, pending: boolean): Figure?
	local root = model:FindFirstChild("HumanoidRootPart")
	if root == nil or not root:IsA("BasePart") then
		return nil
	end
	for _, descendant in model:GetDescendants() do
		if
			descendant:IsA("LuaSourceContainer")
			or descendant:IsA("Animator")
			or descendant:IsA("Sound")
			or descendant:IsA("ForceField")
			or descendant:IsA("Tool")
			or descendant:IsA("BodyMover")
			or descendant:IsA("ProximityPrompt")
			or descendant:IsA("BillboardGui")
		then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = descendant == root
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
			descendant.LocalTransparencyModifier = 0
		end
	end
	root.Transparency = 1
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		humanoid.BreakJointsOnDeath = false
		humanoid.RequiresNeck = false
		humanoid.EvaluateStateMachine = false
	end
	model.PrimaryPart = root
	return { model = model, root = root, joints = collectJoints(model), source = source, pending = pending }
end

-- True when PocketController hid this character (another pocket): its decals are blanked, so it is skipped.
local function isHidden(character: Model): boolean
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.LocalTransparencyModifier >= 1 then
			return true
		end
	end
	return false
end

-- CHANGED (Phase 11 review): a dead character has lost its joints (BreakJointsOnDeath), so a clone would fall apart.
local function isDead(character: Model): boolean
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and (humanoid.Health <= 0 or humanoid:GetState() == Enum.HumanoidStateType.Dead)
end

local function cloneCharacter(character: Model, pending: boolean): Figure?
	local wasArchivable = character.Archivable
	character.Archivable = true
	local ok, copy = pcall(function(): Instance?
		return character:Clone()
	end)
	character.Archivable = wasArchivable
	if not ok or copy == nil or not copy:IsA("Model") then
		return nil
	end
	local figure = prepareFigure(copy, character, pending)
	if figure == nil then
		copy:Destroy()
	end
	return figure
end

local function standInPart(model: Model, name: string, size: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

local function standInMotor(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame)
	local joint = Instance.new("Motor6D")
	joint.Name = name
	joint.Part0 = part0
	joint.Part1 = part1
	joint.C0 = c0
	joint.C1 = c1
	joint.Parent = part0
	part1.CFrame = part0.CFrame * c0 * c1:Inverse()
end

-- A blocky figure of parts (classic colours) with elbows and knees, for when there is no character.
local function standIn(): Figure?
	local model = Instance.new("Model")
	model.Name = "StandIn"
	local root = standInPart(model, "HumanoidRootPart", Vector3.new(2, 2, 1), STAND_IN_TORSO)
	root.CFrame = CFrame.identity
	local torso = standInPart(model, "Torso", Vector3.new(2, 2, 1), STAND_IN_TORSO)
	standInMotor("Root", root, torso, CFrame.identity, CFrame.identity)
	local head = standInPart(model, "Head", Vector3.new(1.2, 1.2, 1.2), STAND_IN_HEAD)
	standInMotor("Neck", torso, head, CFrame.new(0, 1, 0), CFrame.new(0, -0.6, 0))
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = STAND_IN_FACE
	face.Face = Enum.NormalId.Front
	face.Parent = head
	for _, side in { -1, 1 } do
		local prefix = if side < 0 then "Left" else "Right"
		local upperArm = standInPart(model, prefix .. "UpperArm", Vector3.new(1, 1, 1), STAND_IN_HEAD)
		standInMotor(prefix .. "Shoulder", torso, upperArm, CFrame.new(side * 1.5, 0.9, 0), CFrame.new(0, 0.4, 0))
		local lowerArm = standInPart(model, prefix .. "LowerArm", Vector3.new(1, 1.1, 1), STAND_IN_HEAD)
		standInMotor(prefix .. "Elbow", upperArm, lowerArm, CFrame.new(0, -0.5, 0), CFrame.new(0, 0.55, 0))
		local upperLeg = standInPart(model, prefix .. "UpperLeg", Vector3.new(1, 1, 1), STAND_IN_LEGS)
		standInMotor(prefix .. "Hip", torso, upperLeg, CFrame.new(side * 0.5, -1, 0), CFrame.new(0, 0.5, 0))
		local lowerLeg = standInPart(model, prefix .. "LowerLeg", Vector3.new(1, 1, 1), STAND_IN_LEGS)
		standInMotor(prefix .. "Knee", upperLeg, lowerLeg, CFrame.new(0, -0.5, 0), CFrame.new(0, 0.5, 0))
	end
	return prepareFigure(model, nil, false)
end

local function poseFigure(figure: Figure, cf: CFrame, phase: number)
	figure.root.CFrame = cf
	local breath = 2 * math.pi * clock / BREATH_PERIOD + phase
	for _, joint in figure.joints do
		local pose = joint.pose
		local s = math.sin(breath + pose.offset)
		local base, sway = pose.base, pose.sway
		local rotation =
			CFrame.Angles(math.rad(base.X + sway.X * s), math.rad(base.Y + sway.Y * s), math.rad(base.Z + sway.Z * s))
		-- the rotation about the joint pivot in the parent's axes, expressed through C0 (R6 C0s are turned)
		joint.motor.Transform = joint.c0Inverse * rotation * joint.c0
	end
end

-- Floating pose of a figure at a screen point and depth (camera-local), rolling and swinging slowly.
local function floatCFrame(
	base: CFrame,
	nx: number,
	ny: number,
	depth: number,
	tanX: number,
	tanY: number,
	roll: number,
	phase: number
): CFrame
	local bob = AVATAR_BOB * math.sin(2 * math.pi * clock / AVATAR_BOB_PERIOD + phase)
	local pitch = math.rad(AVATAR_SWING_DEG.X) * math.sin(2 * math.pi * clock / AVATAR_SWING_PERIODS.X + phase)
	local yaw = math.rad(AVATAR_SWING_DEG.Y) * math.sin(2 * math.pi * clock / AVATAR_SWING_PERIODS.Y + phase * 1.7)
	return base
		* CFrame.new(nx * tanX * depth, ny * tanY * depth + bob, -depth)
		* CFrame.Angles(0, 0, roll * clock + phase)
		* CFrame.Angles(pitch, yaw, 0)
		* FACE_CAMERA
end

local function setLocalFigure(figure: Figure?)
	local old = localFigure
	if old then
		old.model:Destroy()
	end
	localFigure = figure
	if figure then
		figure.model.Name = "MenuAvatar"
		figure.model.Parent = folder
	end
end

-- Keeps the avatar in line with the local character (header: appearance wait, re-clone, stand-in).
local function updateLocalSource()
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	local waited = clock - startedAt >= APPEARANCE_TIMEOUT_S
	local current = localFigure
	-- CHANGED (Phase 11 review): a dead character is not ready (keep the figure; re-cloned after the respawn)
	if character and root and isDead(character) then
		if current == nil and waited then
			setLocalFigure(standIn())
		end
	elseif character and root then
		local loaded = player:HasAppearanceLoaded()
		local stale = current == nil or current.source ~= character or (current.pending and (loaded or appearanceDirty))
		if stale and (loaded or waited or appearanceDirty) and failedSource ~= character then
			appearanceDirty = false
			local figure = cloneCharacter(character, not loaded)
			if figure then
				setLocalFigure(figure)
			else
				failedSource = character
				if current == nil then
					setLocalFigure(standIn())
				end
			end
		end
	elseif current == nil and waited then
		setLocalFigure(standIn())
	end
end

local function destroyOthers()
	for _, other in others do
		other.figure.model:Destroy()
	end
	table.clear(others)
end

-- Up to MAX_OTHERS other players with a loaded, visible character (refreshed every OTHER_REFRESH_S).
local function refreshOthers()
	local kept: { Other } = {}
	local used: { [number]: boolean } = {}
	for _, other in others do
		local character = other.player.Character
		if other.player.Parent ~= nil and character ~= nil and character == other.figure.source then
			table.insert(kept, other)
			used[other.slot] = true
		else
			other.figure.model:Destroy()
		end
	end
	others = kept
	if #others >= MAX_OTHERS then
		return
	end
	for _, candidate in Players:GetPlayers() do
		if #others >= MAX_OTHERS then
			break
		end
		local already = false
		for _, other in others do
			if other.player == candidate then
				already = true
				break
			end
		end
		local character = candidate.Character
		if
			already
			or candidate == player
			or character == nil
			or character:FindFirstChild("HumanoidRootPart") == nil
			or character:FindFirstChildOfClass("Humanoid") == nil -- CHANGED (Phase 11 review)
			or isDead(character) -- CHANGED (Phase 11 review): its limbs would fall away
			or not candidate:HasAppearanceLoaded()
			or isHidden(character)
		then
			continue
		end
		local figure = cloneCharacter(character, false)
		if figure == nil then
			continue
		end
		local slot = 1
		while used[slot] do
			slot += 1
		end
		used[slot] = true
		figure.model.Name = `MenuFigure_{candidate.UserId}`
		figure.model.Parent = folder
		table.insert(others, { player = candidate, figure = figure, slot = slot })
	end
end

--============================================================================
-- Junk, satellite and shooting stars
--============================================================================

-- Collects a built model's parts as offsets around its centre (camera-free rigid "rig").
local function makeRig(model: Model): Rig
	local parts: { BasePart } = {}
	local low = Vector3.new(math.huge, math.huge, math.huge)
	local high = -low
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			table.insert(parts, descendant)
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			local half = descendant.Size / 2
			low = low:Min(descendant.Position - half)
			high = high:Max(descendant.Position + half)
		end
	end
	local centre = if #parts > 0 then (low + high) / 2 else Vector3.zero
	local offsets: { CFrame } = {}
	for index, part in parts do
		offsets[index] = CFrame.new(-centre) * part.CFrame
	end
	local radius = if #parts > 0 then (high - low).Magnitude / 2 else 1
	return { parts = parts, offsets = offsets, radius = radius }
end

local function buildJunk(parent: Folder, spec: { name: string, blocks: { JunkBlock } }): Rig
	local design = CraftDesign.new(spec.name)
	for index, block in spec.blocks do
		table.insert(design.blocks, {
			id = index,
			type = block.part,
			gx = block.gx,
			gy = block.gy,
			gz = block.gz,
			rot = block.rot,
			stageOverride = nil,
			color = block.color,
		})
	end
	local model = CraftBuilder.build(design, "Cosmetic", CFrame.identity, "Junk_" .. spec.name)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant.Material == Enum.Material.Neon then
			descendant.Material = Enum.Material.SmoothPlastic -- a dead engine does not glow
			descendant.Color = DEAD_ENGINE_COLOR
		end
	end
	model.Parent = parent
	return makeRig(model)
end

local function satellitePart(
	model: Model,
	name: string,
	size: Vector3,
	cf: CFrame,
	color: Color3,
	material: Enum.Material
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cf
	part.Color = color
	part.Material = material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = model
	return part
end

-- A small satellite: foil body, two solar wings on struts, a dish with its feed, a blinking light.
local function buildSatellite(parent: Folder): Rig
	local model = Instance.new("Model")
	model.Name = "Satellite"
	local body = SATELLITE_BODY
	satellitePart(model, "Body", body, CFrame.identity, SATELLITE_FOIL, Enum.Material.Foil)
	for _, side in { -1, 1 } do
		local strutLength = 1
		local strutX = side * (body.X / 2 + strutLength / 2)
		satellitePart(
			model,
			"Strut",
			Vector3.new(strutLength, 0.2, 0.2),
			CFrame.new(strutX, 0, 0),
			SATELLITE_METAL,
			Enum.Material.Metal
		)
		local panelX = side * (body.X / 2 + strutLength + SATELLITE_PANEL.X / 2)
		satellitePart(
			model,
			"SolarPanel",
			SATELLITE_PANEL,
			CFrame.new(panelX, 0, 0),
			SATELLITE_PANEL_COLOR,
			Enum.Material.Glass
		)
	end
	local dish = satellitePart(
		model,
		"Dish",
		Vector3.new(0.3, SATELLITE_DISH_DIAMETER, SATELLITE_DISH_DIAMETER),
		CFrame.new(0, 0, -body.Z / 2 - 0.4) * CFrame.Angles(0, math.pi / 2, 0),
		SATELLITE_METAL,
		Enum.Material.SmoothPlastic
	)
	dish.Shape = Enum.PartType.Cylinder
	satellitePart(
		model,
		"Feed",
		Vector3.new(0.15, 0.15, 1.2),
		CFrame.new(0, 0, -body.Z / 2 - 1),
		SATELLITE_METAL,
		Enum.Material.Metal
	)
	local light = satellitePart(
		model,
		"Light",
		Vector3.new(0.35, 0.35, 0.35),
		CFrame.new(0, body.Y / 2 + 0.25, body.Z / 2 - 0.3),
		SATELLITE_LIGHT_COLOR,
		Enum.Material.Neon
	)
	light.Shape = Enum.PartType.Ball
	local glow = Instance.new("PointLight")
	glow.Color = SATELLITE_LIGHT_COLOR
	glow.Brightness = 2
	glow.Range = 6
	glow.Parent = light
	satelliteLight = light
	satelliteGlow = glow
	model.Parent = parent
	return makeRig(model)
end

local function randomUnit(): Vector3
	local v = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
	return if v.Magnitude > 1e-3 then v.Unit else Vector3.yAxis
end

local function signOf(): number
	return if rng:NextNumber() < 0.5 then -1 else 1
end

-- (Re)spawns a mover: inside the view (scene start) or just beyond one side edge, heading across.
local function spawnMover(mover: Mover, tanX: number, tanY: number, inside: boolean)
	local depth = rng:NextNumber(JUNK_DEPTH_MIN, JUNK_DEPTH_MAX)
	local halfW, halfH = MenuSceneMath.halfExtents(depth, tanX, tanY)
	local direction = signOf()
	local edge = halfW + mover.rig.radius + JUNK_EDGE_MARGIN
	local x = if inside then rng:NextNumber(-1, 1) * halfW * JUNK_START_SPREAD else -direction * edge
	local speed = rng:NextNumber(JUNK_SPEED_MIN, JUNK_SPEED_MAX)
	mover.position = Vector3.new(x, rng:NextNumber(-1, 1) * JUNK_Y_RANGE * halfH, -depth)
	mover.velocity = Vector3.new(
		direction * speed,
		rng:NextNumber(-1, 1) * JUNK_VERTICAL_DRIFT * speed,
		rng:NextNumber(-1, 1) * JUNK_DEPTH_DRIFT * speed
	)
	mover.axis = randomUnit()
	mover.spin = rng:NextNumber(JUNK_SPIN_MIN, JUNK_SPIN_MAX) * signOf()
	mover.angle = rng:NextNumber(0, 2 * math.pi)
	mover.orientation = CFrame.fromAxisAngle(randomUnit(), rng:NextNumber(0, 2 * math.pi))
	mover.wait = 0
end

local function newMover(rig: Rig): Mover
	return {
		rig = rig,
		position = Vector3.zero,
		velocity = Vector3.zero,
		axis = Vector3.yAxis,
		spin = 0,
		angle = 0,
		orientation = CFrame.identity,
		wait = 0,
	}
end

local function updateMovers(base: CFrame, dt: number, tanX: number, tanY: number)
	table.clear(moveParts)
	table.clear(moveCFrames)
	for _, mover in movers do
		if mover.wait > 0 then
			mover.wait -= dt
			if mover.wait <= 0 then
				spawnMover(mover, tanX, tanY, false)
			else
				continue -- parked beyond the edge it left
			end
		end
		mover.position += mover.velocity * dt
		mover.angle += mover.spin * dt
		local depth = math.max(-mover.position.Z, 1)
		local edge = depth * tanX + mover.rig.radius + JUNK_EDGE_MARGIN
		local x = mover.position.X
		if (mover.velocity.X > 0 and x > edge) or (mover.velocity.X < 0 and x < -edge) then
			mover.wait = rng:NextNumber(JUNK_RESPAWN_MIN, JUNK_RESPAWN_MAX)
		end
		local pose = base
			* CFrame.new(mover.position)
			* CFrame.fromAxisAngle(mover.axis, mover.angle)
			* mover.orientation
		for index, part in mover.rig.parts do
			table.insert(moveParts, part)
			table.insert(moveCFrames, pose * mover.rig.offsets[index])
		end
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	local light, glow = satelliteLight, satelliteGlow
	if light and glow then
		local lit = clock % BLINK_PERIOD < BLINK_ON
		light.Transparency = if lit then 0 else 0.7
		glow.Enabled = lit
	end
end

local function newStreak(parent: Folder): Streak
	local part = Instance.new("Part")
	part.Name = "ShootingStar"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * STAR_HEAD_SIZE
	part.Material = Enum.Material.Neon
	part.Color = STAR_COLOR
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, STAR_WIDTH / 2, 0)
	top.Parent = part
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -STAR_WIDTH / 2, 0)
	bottom.Parent = part
	local trail = Instance.new("Trail")
	trail.Attachment0 = top
	trail.Attachment1 = bottom
	trail.FaceCamera = true
	trail.Lifetime = STAR_TRAIL_LIFETIME
	trail.MinLength = 0
	trail.LightEmission = 1
	trail.Brightness = 3
	trail.Color = ColorSequence.new(STAR_COLOR)
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(1, 0),
	})
	trail.Enabled = false
	trail.Parent = part
	part.Parent = parent
	return {
		part = part,
		trail = trail,
		position = Vector3.zero,
		velocity = Vector3.zero,
		life = 0,
		maxLife = 1,
		active = false,
		arm = false,
	}
end

local function launchStreak(streak: Streak, base: CFrame, tanX: number, tanY: number)
	local depth = rng:NextNumber(STAR_DEPTH_MIN, STAR_DEPTH_MAX)
	local halfW, halfH = MenuSceneMath.halfExtents(depth, tanX, tanY)
	streak.position =
		Vector3.new(rng:NextNumber(-STAR_AREA.X, STAR_AREA.X) * halfW, rng:NextNumber(0.1, STAR_AREA.Y) * halfH, -depth)
	local slope = rng:NextNumber(STAR_SLOPE_MIN, STAR_SLOPE_MAX)
	local direction = Vector3.new(signOf() * math.cos(slope), -math.sin(slope), 0)
	streak.velocity = direction * rng:NextNumber(STAR_SPEED_MIN, STAR_SPEED_MAX)
	streak.maxLife = rng:NextNumber(STAR_LIFE_MIN, STAR_LIFE_MAX)
	streak.life = streak.maxLife
	streak.active = true
	streak.trail.Enabled = false
	streak.part.CFrame = base * CFrame.new(streak.position)
	streak.trail:Clear()
	streak.arm = true
end

local function updateStreaks(base: CFrame, dt: number, tanX: number, tanY: number)
	if clock >= nextStreak then
		nextStreak = clock + rng:NextNumber(STAR_INTERVAL_MIN, STAR_INTERVAL_MAX)
		for _, streak in streaks do
			if not streak.active then
				launchStreak(streak, base, tanX, tanY)
				break
			end
		end
	end
	for _, streak in streaks do
		if not streak.active then
			continue
		end
		if streak.arm then
			streak.arm = false
			streak.trail.Enabled = true
		end
		streak.position += streak.velocity * dt
		streak.life -= dt
		if streak.life <= 0 then
			streak.active = false
			streak.trail.Enabled = false -- the trail fades out on its own
			streak.part.Transparency = 1
			continue
		end
		streak.part.Transparency = 1 - streak.life / streak.maxLife
		streak.part.CFrame = base * CFrame.new(streak.position)
	end
end

local function build()
	if built then
		return
	end
	built = true
	local existing = Workspace:FindFirstChild(FOLDER_NAME)
	if existing then
		existing:Destroy()
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	folder = created
	for _, spec in JUNK_DESIGNS do
		table.insert(movers, newMover(buildJunk(created, spec)))
	end
	table.insert(movers, newMover(buildSatellite(created)))
	for _ = 1, STAR_POOL do
		table.insert(streaks, newStreak(created))
	end
	local fill = Instance.new("Part")
	fill.Name = "FillLight"
	fill.Anchored = true
	fill.CanCollide = false
	fill.CanQuery = false
	fill.CanTouch = false
	fill.CastShadow = false
	fill.Transparency = 1
	fill.Size = Vector3.one
	local light = Instance.new("PointLight")
	light.Color = FILL_LIGHT_COLOR
	light.Brightness = FILL_LIGHT_BRIGHTNESS
	light.Range = FILL_LIGHT_RANGE
	light.Shadows = false
	light.Parent = fill
	fill.Parent = created
	fillLight = fill
end

--============================================================================
-- Lighting effects
--============================================================================

local function removeLightingEffects()
	for _, name in { BLOOM_NAME, SUNRAYS_NAME } do
		local effect = Lighting:FindFirstChild(name)
		if effect then
			effect:Destroy()
		end
	end
end

local function addLightingEffects()
	removeLightingEffects()
	local bloom = Instance.new("BloomEffect")
	bloom.Name = BLOOM_NAME
	bloom.Intensity = BLOOM_INTENSITY
	bloom.Size = BLOOM_SIZE
	bloom.Threshold = BLOOM_THRESHOLD
	bloom.Parent = Lighting
	local rays = Instance.new("SunRaysEffect")
	rays.Name = SUNRAYS_NAME
	rays.Intensity = SUNRAYS_INTENSITY
	rays.Spread = SUNRAYS_SPREAD
	rays.Parent = Lighting
end

--============================================================================
-- Per frame
--============================================================================

local function toVector3(v: Vec3d.Vec3d): Vector3
	return Vector3.new(v.x, v.y, v.z)
end

-- CHANGED (Phase 11 review): the Earth-centred sun / Mun angle at a UT.
local function separationAt(ut: number): number
	return Vec3d.angle(Universe.sunDirection(ut), Universe.bodyOffset(Bodies.MOON, Bodies.HOMEWORLD, ut))
end

local function separationIn(ut: number, minAngle: number, maxAngle: number): boolean
	local angle = separationAt(ut)
	return angle >= minAngle and angle <= maxAngle
end

-- CHANGED (Phase 11 review): how far ahead of `ut` the menu time starts (MenuSceneMath.timeOffset).
local function menuTimeOffset(ut: number): number
	return MenuSceneMath.timeOffset(function(offset: number): number
		return separationAt(ut + offset)
	end, MUN_SEARCH_SPAN_S, MUN_SEARCH_STEP_S, MUN_SEPARATION_MIN, MUN_SEPARATION_MAX)
end

-- Turns the universe around the camera (header) and returns the solved view, if any.
local function updateView(dt: number, tanX: number, tanY: number): MenuSceneMath.View?
	-- CHANGED (Phase 11 review): the menu's own time (header), picked again if the Mun drifts out of reach
	menuUT += dt * MENU_TIME_RATE
	local p = viewParams
	if clock >= nextPickAt and not separationIn(menuUT, MUN_KEEP_MIN, MUN_KEEP_MAX) then
		nextPickAt = clock + MUN_REPICK_MIN_S
		menuUT += menuTimeOffset(menuUT)
		alpha = nil
	end
	local ut = menuUT
	p.sunDir = Universe.sunDirection(ut)
	p.munPos = Universe.bodyOffset(Bodies.MOON, Bodies.HOMEWORLD, ut)
	UniverseRenderer.setViewOverride(viewFrame, ut)
	local _, limbAngle = MenuSceneMath.screenAngles(0, LIMB_NY, tanX, tanY)
	p.pitch = MenuSceneMath.pitchFor(p.earthRadius, p.distance, limbAngle)
	local sunPhase = 2 * math.pi * clock / SUN_DRIFT_PERIOD
	p.sunAzimuth, p.sunElevation = MenuSceneMath.screenAngles(
		SUN_NX + SUN_DRIFT.X * math.sin(sunPhase),
		SUN_NY + SUN_DRIFT.Y * math.cos(sunPhase),
		tanX,
		tanY
	)
	local munPhase = 2 * math.pi * clock / MUN_DRIFT_PERIOD
	p.munAzimuth, p.munElevation = MenuSceneMath.screenAngles(
		MUN_NX + MUN_DRIFT.X * math.sin(munPhase),
		MUN_NY + MUN_DRIFT.Y * math.sin(2 * munPhase),
		tanX,
		tanY
	)
	local previous = alpha
	local current: number
	if previous == nil then
		current = MenuSceneMath.bestAlpha(p, ALPHA_SAMPLES)
	else
		current = MenuSceneMath.refineAlpha(p, previous, MUN_TRACK_RATE * dt)
	end
	alpha = current
	local view = MenuSceneMath.solveView(p, current)
	if view then
		local rotation =
			CFrame.fromMatrix(Vector3.zero, toVector3(view.right), toVector3(view.cameraUp), -toVector3(view.forward))
		Frames.setReference(viewFrame, Bodies.HOMEWORLD, view.pos, rotation)
	end
	return view
end

-- Lens flare: the sun's viewport point and how visible it is (header).
local function updateFlare(camera: Camera, view: MenuSceneMath.View?, tanY: number)
	local current = flare
	if current == nil then
		return
	end
	if view == nil then
		current.hide()
		return
	end
	local p = viewParams
	local viewport = camera.ViewportSize
	local sunWs = Frames.vectorToWorkspace(viewFrame, p.sunDir)
	local camPos = camera.CFrame.Position
	local point = camera:WorldToViewportPoint(camPos + sunWs * FLARE_DISTANCE)
	if point.Z <= 0 then
		current.hide()
		return
	end
	local strength = MenuSceneMath.edgeFade(point.X, point.Y, viewport.X, viewport.Y, FLARE_EDGE_MARGIN * viewport.Y)
	-- Earth (straight down from the viewpoint) and the Mun
	local earthAngle = math.asin(math.clamp(p.earthRadius / p.distance, 0, 1))
	local hidden = MenuSceneMath.discOcclusion(p.sunDir, Vec3d.scale(view.up, -1), earthAngle, OCCLUSION_SOFT)
	local toMun = Vec3d.sub(p.munPos, view.pos)
	local munDistance = Vec3d.length(toMun)
	if munDistance > p.munRadius then
		local munAngle = math.asin(p.munRadius / munDistance)
		hidden = math.max(hidden, MenuSceneMath.discOcclusion(p.sunDir, toMun, munAngle, OCCLUSION_SOFT))
	end
	-- the avatar, as a disc on screen
	local figure = localFigure
	if figure then
		local rootPoint = camera:WorldToViewportPoint(figure.root.Position)
		if rootPoint.Z > 0 then
			local radiusPx = AVATAR_OCCLUSION_RADIUS / rootPoint.Z * (viewport.Y / 2) / tanY
			local distance = Vector2.new(point.X - rootPoint.X, point.Y - rootPoint.Y).Magnitude
			hidden = math.max(hidden, 1 - MenuSceneMath.smoothstep(radiusPx * 0.6, radiusPx * 1.2, distance))
		end
	end
	current.update(point.X, point.Y, strength * (1 - hidden), viewport.X, viewport.Y)
end

local function step(dt: number)
	local camera = Workspace.CurrentCamera
	if camera == nil or not running then
		return
	end
	clock += dt
	local viewport = camera.ViewportSize
	local tanY = math.tan(math.rad(MENU_FOV / 2))
	local tanX = tanY * (if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9)

	-- camera: fixed at the menu origin (the universe turns around it), with a slow sway
	local base = CFrame.new(MENU_ORIGIN)
	local sway = CFrame.Angles(
		math.rad(CAMERA_SWAY_DEG.X) * math.sin(2 * math.pi * clock / CAMERA_SWAY_PERIODS.X),
		math.rad(CAMERA_SWAY_DEG.Y) * math.sin(2 * math.pi * clock / CAMERA_SWAY_PERIODS.Y),
		0
	)
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end
	camera.FieldOfView = MENU_FOV
	camera.CFrame = base * sway
	-- CHANGED (Phase 11 review): lighting and detail are prioritised around Focus (else it stays at the character)
	camera.Focus = base * CFrame.new(0, 0, -AVATAR_DISTANCE)

	local view = updateView(dt, tanX, tanY)

	-- figures
	updateLocalSource()
	local figure = localFigure
	if figure then
		poseFigure(figure, floatCFrame(base, AVATAR_NX, AVATAR_NY, AVATAR_DISTANCE, tanX, tanY, AVATAR_ROLL_RATE, 0), 0)
	end
	otherTimer += dt
	if otherTimer >= OTHER_REFRESH_S then
		otherTimer = 0
		refreshOthers()
	end
	for _, other in others do
		local slot = OTHER_SLOTS[other.slot]
		if slot then
			poseFigure(
				other.figure,
				floatCFrame(base, slot.nx, slot.ny, slot.depth, tanX, tanY, slot.roll, slot.phase),
				slot.phase
			)
		end
	end

	updateMovers(base, dt, tanX, tanY)
	updateStreaks(base, dt, tanX, tanY)
	updateFlare(camera, view, tanY)
end

--============================================================================
-- API
--============================================================================

function MenuScene.start(flareParent: GuiObject)
	if running then
		return
	end
	build()
	running = true
	clock = 0
	startedAt = 0
	alpha = nil
	otherTimer = math.huge
	nextStreak = rng:NextNumber(STAR_INTERVAL_MIN, STAR_INTERVAL_MAX)
	appearanceDirty = false
	failedSource = nil -- a clone that failed last time is tried again

	if flare == nil or flareHost ~= flareParent then
		local old = flare
		if old then
			old.destroy()
		end
		flare = MenuSceneFlare.new(flareParent)
		flareHost = flareParent
	end

	local camera = Workspace.CurrentCamera
	if camera then
		savedFov = camera.FieldOfView
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.new(MENU_ORIGIN)
		camera.Focus = CFrame.new(MENU_ORIGIN) * CFrame.new(0, 0, -AVATAR_DISTANCE) -- CHANGED (Phase 11 review)
	end
	local viewport = if camera then camera.ViewportSize else Vector2.new(16, 9)
	local tanY = math.tan(math.rad(MENU_FOV / 2))
	local tanX = tanY * (if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9)
	for _, mover in movers do
		spawnMover(mover, tanX, tanY, true)
	end
	for _, streak in streaks do
		streak.active = false
		streak.trail.Enabled = false
		streak.part.Transparency = 1
	end
	local fill = fillLight
	if fill then
		fill.CFrame = CFrame.new(MENU_ORIGIN + FILL_LIGHT_OFFSET)
	end
	local f = folder
	if f then
		f.Parent = Workspace
	end

	table.insert(
		connections,
		player.CharacterAppearanceLoaded:Connect(function()
			appearanceDirty = true
			failedSource = nil
		end)
	)
	table.insert(
		connections,
		player.CharacterAdded:Connect(function()
			failedSource = nil
		end)
	)

	addLightingEffects()
	-- CHANGED (Phase 11 review): the menu's own time (header)
	local now = UniverseTime.now()
	menuUT = now + menuTimeOffset(now)
	nextPickAt = MUN_REPICK_MIN_S
	UniverseRenderer.setViewOverride(viewFrame, menuUT)
	RunService:BindToRenderStep(RENDER_STEP_NAME, RENDER_PRIORITY, step)
end

function MenuScene.stop()
	if not running then
		return
	end
	running = false
	RunService:UnbindFromRenderStep(RENDER_STEP_NAME)
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
	UniverseRenderer.setViewOverride(nil)
	removeLightingEffects()
	local current = flare
	if current then
		current.hide()
	end
	destroyOthers()
	local f = folder
	if f then
		f.Parent = nil -- parked for a cheap reopen
	end

	local camera = Workspace.CurrentCamera
	if camera then
		camera.FieldOfView = savedFov
		camera.CameraType = Enum.CameraType.Custom
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		if humanoid then
			camera.CameraSubject = humanoid
		end
	end
end

function MenuScene.isRunning(): boolean
	return running
end

return MenuScene
