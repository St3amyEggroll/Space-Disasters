--!strict
--[[
	Puppets (Phase 3, spec 7.7 "Puppets")
	Lets players see the crews of crafts in OTHER pockets. Their real characters are hidden locally (PocketController,
	invariant I6), so for each such character that sits in (or stands inside) a craft that has a cosmetic copy near
	the camera (within PUPPET_DISTANCE), a lightweight appearance clone is posed inside that copy at the character's
	pose relative to the craft.

	Pose relative to the craft (computed from data that is the same on every client):
	  * Seated: Humanoid.SeatPart replicates. The pose is the seat (and the SeatWeld's C0/C1) relative to the craft
	    reference frame of the real model, read from the root block's Bounds. The server never moves a flying craft's
	    real model (D31), and a client that once posed it moved every part rigidly, so seat and Bounds always agree.
	  * Standing in a flight pocket: the character's HumanoidRootPart relative to where the clients IN that pocket
	    pose the primary craft: slot origin + (pocket horizon rotation)^-1 * craft rotation, from the interpolated
	    stream. Rejected if the character is farther than the craft's radius + PUPPET_ABOARD_RADIUS from it.

	The clone is built once per player from their HumanoidDescription (the character's applied description, else the
	user id's), via Players:CreateHumanoidModelFromDescription (pcall; R15). If that fails, a simple blocky stand-in
	in the character's body colours is used. Scripts, animators and sounds are stripped; the HumanoidRootPart is the
	anchored root and every other part is massless, unanchored and joined by its rig joints; nothing collides, is
	queried or touched; the Humanoid's state machine is off and its name/health display hidden. Seated puppets get a
	fixed sitting pose (hip and knee Motor6D.Transform); no animation in v1.

	CHANGED (Ground puppets): players ON FOOT in another pocket (walking around the base while you fly, or out of a
	landed craft in another flight pocket) were never drawn ("while flying I can't see others on the ground").
	Every other player who is not seated and not aboard a craft is now a "ground puppet" at their true position:
	their HumanoidRootPart (their pocket's workspace) -> universe through THEIR pocket's frame -> this pocket through
	ours (Render/PuppetMath, doubles first, I1). Their pocket is found from the root's position by slot, exactly as
	PocketController decides to hide them. The source frame is the pocket folder's attributes (base / surface
	pockets: RefX/RefY/RefZ/RefRot/RefBodyId, the frame the launch-site copy in Surface is placed with) or, for a
	flight pocket, its primary craft's streamed state led to now with the local horizon axes, as the copy of that
	craft is drawn. Only within GROUND_PUPPET_DISTANCE of the camera, not behind a planet (LineOfSight), at most
	GROUND_PUPPET_MAX nearest. They are animated: each frame the hidden real character's Motor6D.Transform values
	(other players' animations still play on this client) are copied onto the puppet's matching joints, retargeted
	when the rigs differ (R6 character -> R15 puppet, or the stand-in); joints without a match stay neutral.
	Aboard / seated puppets keep their fixed pose; a puppet that switches between the two resets its joints.

	CHANGED (Night review): ground puppets follow Render/Quality: at most GROUND_MAX_BY_TIER of them (Low 4 /
	Medium 8 / High GameConfig.GROUND_PUPPET_MAX), and on Low every puppet is the blocky stand-in (no
	CreateHumanoidModelFromDescription: no accessory / layered-clothing meshes to load and draw); full-appearance
	puppets are dropped when the tier falls to Low and come back through the usual stand-in retry above it.

	CHANGED (Phase 6): EVA puppets. Astronauts on EVA in another pocket are ground puppets at their true position,
	including in an astronaut's own solo pocket: an INERTIAL pocket's frame is its free-falling reference
	(Shared/Sim/PocketFrames) at our UT; SURFACE_ALIGNED solo pockets read their attributes like the base.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies) -- CHANGED (Ground puppets)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LineOfSight = require(ReplicatedStorage.Shared.Sim.LineOfSight) -- CHANGED (Ground puppets)
local PocketFrames = require(ReplicatedStorage.Shared.Sim.PocketFrames) -- CHANGED (Phase 6): solo EVA pockets
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local StateBuffer = require(ReplicatedStorage.Shared.Net.StateBuffer) -- CHANGED (Ground puppets)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d) -- CHANGED (Ground puppets)
local PuppetMath = require(script.Parent.PuppetMath) -- CHANGED (Ground puppets)
local Quality = require(script.Parent.Quality) -- CHANGED (Night review)
local RenderContext = require(script.Parent.RenderContext) -- CHANGED (Ground puppets)

--============================================================================
-- Tunables
--============================================================================
local PUPPET_DISTANCE = GameConfig.PUPPET_DISTANCE -- m from the camera to the craft copy
local ABOARD_RADIUS = GameConfig.PUPPET_ABOARD_RADIUS -- m beyond the craft radius
local SEATED_HIP = CFrame.Angles(math.rad(90), 0, 0) -- thighs forward
local SEATED_KNEE = CFrame.Angles(math.rad(-90), 0, 0) -- shins down
local RETRY_BUILD_S = 30 -- s between attempts to replace a stand-in with the real appearance
local HIP_NAMES = { "LeftHip", "RightHip" }
local KNEE_NAMES = { "LeftKnee", "RightKnee" }
local STAND_IN_SKIN = Color3.fromRGB(234, 184, 146)
local STAND_IN_SHIRT = Color3.fromRGB(70, 110, 190)
local STAND_IN_PANTS = Color3.fromRGB(45, 50, 65)
local STAND_IN_FACE = "rbxasset://textures/face.png"
-- CHANGED (Ground puppets)
local GROUND_DISTANCE = GameConfig.GROUND_PUPPET_DISTANCE -- m from the camera (true distance)
local GROUND_MAX = GameConfig.GROUND_PUPPET_MAX -- nearest on-foot puppets drawn at once
-- CHANGED (Night review): ... per Quality tier (High = GROUND_MAX)
local GROUND_MAX_BY_TIER: { [string]: number } = { Low = 4, Medium = 8, High = GROUND_MAX }
local STAND_IN_TIER = "Low" -- CHANGED (Night review): every puppet is the blocky stand-in on this tier
local INTERP_DELAY = GameConfig.INTERP_DELAY -- s; a flight pocket's sampled craft state is led by this to now
local SLOT_CAPTURE_RADIUS = 1800 -- same as PocketService / PocketController
local REPAIR_S = 2 -- s between re-pairings while some puppet joints have no match (the character may still load)
local VIEW_PRUNE_FRAMES = 600 -- updates a pocket's cached frame may go unused before it is dropped
--============================================================================

export type CopyInfo = { root: BasePart, distance: number, radius: number }
export type Sampler = (craftId: number, ut: number) -> Protocol.State?

-- CHANGED (Ground puppets): what posed a puppet last; its joints are reset when this changes
type Mode = "None" | "Aboard" | "Ground"

type Puppet = {
	model: Model,
	root: BasePart,
	hips: { Motor6D },
	knees: { Motor6D },
	standIn: boolean, -- the blocky fallback (the real appearance is retried every RETRY_BUILD_S)
	-- CHANGED (Ground puppets): animation copied from the real character
	joints: { Motor6D }, -- every rig joint of the puppet
	roles: { string }, -- PuppetMath.jointRole of each joint
	mode: Mode,
	pairedWith: Model?, -- the character the pairs below were built for (nil = pair again)
	pairedAt: number, -- os.clock() of the last pairing
	pairPuppet: { Motor6D }, -- puppet joint i is driven by real joint i ...
	pairReal: { Motor6D },
	pairQ: { CFrame }, -- ... retargeted with these (PuppetMath.retargetFor)
	pairQInverse: { CFrame },
	pairDirect: { boolean },
}

-- CHANGED (Ground puppets): another pocket's frame, refreshed at most once per update
type PocketView = {
	frame: Frames.Frame,
	stamp: number, -- frameStamp of the last refresh
	ok: boolean, -- the frame is known this update
	rotation: CFrame, -- that pocket's workspace axes -> ours
	bodyOffset: Vec3d.Vec3d?, -- abs(its reference body) - abs(ours), nil for the same body
}

-- CHANGED (Ground puppets): an on-foot player within range this update (pooled, reused every update)
type Candidate = {
	player: Player,
	character: Model,
	root: BasePart,
	view: PocketView,
	truePos: Vec3d.Vec3d, -- relative to our frame's reference body (doubles)
	distanceSq: number,
}

local Puppets = {}

local folder: Folder? = nil
local puppets: { [Player]: Puppet } = {}
local building: { [Player]: boolean } = {}
local failedAt: { [Player]: number } = {}
local shownCount = 0
-- CHANGED (Ground puppets)
local frameStamp = 0
local views: { [number]: PocketView } = {}
local slotOrigins: { Vector3 } = {}
local slotIds: { number } = {}
local slotStamp = -1
local candidates: { Candidate } = {}
local candidateCount = 0
local sorted: { Candidate } = {}
local scratchRef = Vec3d.zero()

--============================================================================
-- Building
--============================================================================

local function collectMotors(model: Model, names: { string }?): { Motor6D }
	local result = {}
	for _, descendant in model:GetDescendants() do
		-- CHANGED (Ground puppets): no names = every joint
		if descendant:IsA("Motor6D") and (names == nil or table.find(names, descendant.Name)) then
			table.insert(result, descendant)
		end
	end
	return result
end

-- Turns a character-like model into a puppet: anchored root, everything else massless and passive.
local function preparePuppet(model: Model): Puppet?
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
		then
			descendant:Destroy()
		elseif descendant:IsA("BasePart") then
			descendant.Anchored = descendant == root
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
			descendant.Massless = true
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
	-- CHANGED (Ground puppets): every joint and its role, for the animation copy
	local joints = collectMotors(model)
	local roles: { string } = {}
	for index, joint in joints do
		roles[index] = PuppetMath.jointRole(joint.Name)
	end
	return {
		model = model,
		root = root,
		hips = collectMotors(model, HIP_NAMES),
		knees = collectMotors(model, KNEE_NAMES),
		standIn = false,
		joints = joints,
		roles = roles,
		mode = "None" :: Mode,
		pairedWith = nil,
		pairedAt = 0,
		pairPuppet = {},
		pairReal = {},
		pairQ = {},
		pairQInverse = {},
		pairDirect = {},
	}
end

local function descriptionOf(player: Player): HumanoidDescription?
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid then
		local ok, result = pcall(function()
			return humanoid:GetAppliedDescription()
		end)
		if ok and typeof(result) == "Instance" and result:IsA("HumanoidDescription") then
			return result
		end
	end
	if player.UserId > 0 then
		local ok, result = pcall(function()
			return Players:GetHumanoidDescriptionFromUserId(player.UserId)
		end)
		if ok and typeof(result) == "Instance" and result:IsA("HumanoidDescription") then
			return result
		end
	end
	return nil
end

local function fromDescription(player: Player): Model?
	local description = descriptionOf(player)
	if description == nil then
		return nil
	end
	local ok, result = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	if ok and typeof(result) == "Instance" and result:IsA("Model") then
		return result
	end
	return nil
end

local function part(model: Model, name: string, size: Vector3, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function motor(name: string, part0: BasePart, part1: BasePart, c0: CFrame, c1: CFrame)
	local joint = Instance.new("Motor6D")
	joint.Name = name
	joint.Part0 = part0
	joint.Part1 = part1
	joint.C0 = c0
	joint.C1 = c1
	joint.Parent = part0
	part1.CFrame = part0.CFrame * c0 * c1:Inverse()
end

-- A simple blocky stand-in (R6 proportions, knees so it can sit) in the character's body colours.
local function standIn(player: Player): Model
	local skin, shirt, pants = STAND_IN_SKIN, STAND_IN_SHIRT, STAND_IN_PANTS
	local character = player.Character
	local colors = if character then character:FindFirstChildOfClass("BodyColors") else nil
	if colors then
		skin = colors.HeadColor3
		shirt = colors.TorsoColor3
		pants = colors.LeftLegColor3
	end
	local model = Instance.new("Model")
	model.Name = "StandIn"
	local root = part(model, "HumanoidRootPart", Vector3.new(2, 2, 1), shirt)
	root.CFrame = CFrame.identity
	local torso = part(model, "Torso", Vector3.new(2, 2, 1), shirt)
	motor("RootJoint", root, torso, CFrame.identity, CFrame.identity)
	local head = part(model, "Head", Vector3.new(1.2, 1.2, 1.2), skin)
	motor("Neck", torso, head, CFrame.new(0, 1, 0), CFrame.new(0, -0.6, 0))
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Texture = STAND_IN_FACE
	face.Face = Enum.NormalId.Front
	face.Parent = head
	for _, side in { -1, 1 } do
		local prefix = if side < 0 then "Left" else "Right"
		local arm = part(model, prefix .. "Arm", Vector3.new(1, 2, 1), skin)
		motor(prefix .. "Shoulder", torso, arm, CFrame.new(side * 1.5, 0, 0), CFrame.identity)
		local thigh = part(model, prefix .. "UpperLeg", Vector3.new(1, 1, 1), pants)
		motor(prefix .. "Hip", torso, thigh, CFrame.new(side * 0.5, -1, 0), CFrame.new(0, 0.5, 0))
		local shin = part(model, prefix .. "LowerLeg", Vector3.new(1, 1, 1), pants)
		motor(prefix .. "Knee", thigh, shin, CFrame.new(0, -0.5, 0), CFrame.new(0, 0.5, 0))
	end
	return model
end

local function destroyPuppet(player: Player)
	local puppet = puppets[player]
	if puppet then
		puppet.model:Destroy()
		puppets[player] = nil
	end
end

-- Builds the player's puppet in the background (CreateHumanoidModelFromDescription yields).
local function requestPuppet(player: Player)
	local existing = puppets[player]
	-- CHANGED (Night review): on Low only the blocky stand-in is built (at once, no appearance fetch)
	if Quality.tier() == STAND_IN_TIER then
		if existing == nil and not building[player] then
			local puppet = preparePuppet(standIn(player))
			if puppet then
				puppet.standIn = true
				puppet.model.Name = `Puppet_{player.UserId}`
				puppets[player] = puppet
			end
		end
		return
	end
	if building[player] or (existing and not existing.standIn) then
		return
	end
	local failed = failedAt[player]
	if existing and failed and os.clock() - failed < RETRY_BUILD_S then
		return -- showing the stand-in; try the real appearance again later (it may not have loaded yet)
	end
	building[player] = true
	task.spawn(function()
		local model = fromDescription(player)
		local puppet = if model then preparePuppet(model) else nil
		if puppet == nil then
			if model then
				model:Destroy()
			end
			failedAt[player] = os.clock()
			if puppets[player] == nil then
				puppet = preparePuppet(standIn(player))
				if puppet then
					puppet.standIn = true
				end
			end
		end
		building[player] = nil
		if puppet == nil then
			return
		end
		puppet.model.Name = `Puppet_{player.UserId}`
		if player.Parent == nil then
			puppet.model:Destroy()
			return
		end
		-- CHANGED (Night review): the tier fell to Low while this was built: keep (or make) the stand-in instead
		if not puppet.standIn and Quality.tier() == STAND_IN_TIER then
			puppet.model:Destroy()
			return
		end
		destroyPuppet(player) -- replaces a stand-in
		puppets[player] = puppet
	end)
end

-- CHANGED (Ground puppets): moved out of update (shared by aboard and ground puppets). The player's puppet, asking
-- for it (or for the real appearance in place of the stand-in) when needed; nil while the first one is built.
local function ensurePuppet(player: Player): Puppet?
	local puppet = puppets[player]
	if puppet == nil or puppet.standIn then
		requestPuppet(player)
	end
	return puppet
end

--============================================================================
-- Pose relative to the craft
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

-- The craft reference frame (root block centre, craft axes) of a real model where it stands on this client.
local function craftFrameOf(model: Model): CFrame?
	local rootId = model:GetAttribute("RootBlockId")
	local block = if type(rootId) == "number" then model:FindFirstChild(`Block_{rootId}`) else nil
	local bounds = if block then block:FindFirstChild("Bounds") else nil
	local rot = if block then block:GetAttribute("Rot") else nil
	if bounds == nil or not bounds:IsA("BasePart") or type(rot) ~= "number" then
		return nil
	end
	-- Bounds = (craft frame) * rotation(root.rot)
	return bounds.CFrame * CraftDesign.rotationCFrame(rot):Inverse()
end

-- Where a seated character's root sits: from the seat weld when there is one (robust to late replication).
local function seatedRootCFrame(seat: BasePart, root: BasePart): CFrame
	local weld = seat:FindFirstChild("SeatWeld")
	if weld and weld:IsA("Weld") then
		if weld.Part0 == seat and weld.Part1 == root then
			return seat.CFrame * weld.C0 * weld.C1:Inverse()
		elseif weld.Part1 == seat and weld.Part0 == root then
			return seat.CFrame * weld.C1 * weld.C0:Inverse()
		end
	end
	return root.CFrame
end

local function pocketFolder(id: number): Instance?
	local pockets = Workspace:FindFirstChild("Pockets")
	return if pockets then pockets:FindFirstChild(`Pocket_{id}`) else nil
end

--[[
	The craft a character in another pocket is aboard and its root's pose relative to that craft's reference
	frame, or nil. `renderUT` is the UT copies are drawn at.
]]
local function aboardPose(
	other: Player,
	root: BasePart,
	humanoid: Humanoid,
	sample: Sampler,
	renderUT: number,
	copies: { [number]: CopyInfo }
): (number?, CFrame?, boolean)
	local seat = humanoid.SeatPart
	if seat then
		local model = craftModelOf(seat)
		local craftId = if model then model:GetAttribute("CraftId") else nil
		local craftFrame = if model then craftFrameOf(model) else nil
		if type(craftId) ~= "number" or craftFrame == nil then
			return nil, nil, false
		end
		return craftId, craftFrame:Inverse() * seatedRootCFrame(seat, root), true
	end
	-- standing: aboard the primary craft of a flight pocket
	local pocketId = other:GetAttribute("PocketId")
	local folder = if type(pocketId) == "number" then pocketFolder(pocketId) else nil
	if folder == nil or folder:GetAttribute("FrameMode") ~= "HORIZON_ALIGNED" then
		return nil, nil, false
	end
	local primary = folder:GetAttribute("PrimaryId")
	local slot = folder:GetAttribute("SlotOrigin")
	if type(primary) ~= "number" or typeof(slot) ~= "Vector3" then
		return nil, nil, false
	end
	local copy = copies[primary]
	local state = sample(primary, renderUT)
	if copy == nil or state == nil then
		return nil, nil, false
	end
	-- the primary's reference point is the pocket reference, so it sits at the slot origin (D31)
	local horizon = Universe.pocketRotation(state.bodyId, state.pos, renderUT)
	local craftInPocket = CFrame.new(slot) * (horizon:Inverse() * Frames.rotationOnly(state.rot))
	local rel = craftInPocket:Inverse() * root.CFrame
	if rel.Position.Magnitude > copy.radius + ABOARD_RADIUS then
		return nil, nil, false
	end
	return primary, rel, false
end

--============================================================================
-- CHANGED (Ground puppets): other pockets' frames
--============================================================================

-- Slot origins of the flight pockets, read at most once per update (for PuppetMath.slotPocket).
local function refreshSlots()
	if slotStamp == frameStamp then
		return
	end
	slotStamp = frameStamp
	table.clear(slotOrigins)
	table.clear(slotIds)
	local pockets = Workspace:FindFirstChild("Pockets")
	if pockets == nil then
		return
	end
	for _, pocket in pockets:GetChildren() do
		local id = pocket:GetAttribute("PocketId")
		local origin = pocket:GetAttribute("SlotOrigin")
		if type(id) == "number" and id ~= 0 and typeof(origin) == "Vector3" then
			table.insert(slotOrigins, origin)
			table.insert(slotIds, id)
		end
	end
end

--[[
	Sets `frame`'s reference to where the pocket's own clients have it now: a flight pocket follows its primary
	craft (the sampled stream led to `ut`, horizon axes, as PocketController and the copy of that craft); the base and
	other fixed pockets read their attributes. False if unknown.
]]
local function setPocketReference(
	frame: Frames.Frame,
	pocket: Instance,
	ut: number,
	renderUT: number,
	sample: Sampler
): boolean
	if pocket:GetAttribute("FrameMode") == "HORIZON_ALIGNED" then
		local primary = pocket:GetAttribute("PrimaryId")
		local sampled = if type(primary) == "number" then sample(primary, renderUT) else nil
		if sampled == nil then
			return false
		end
		local s = StateBuffer.lead(sampled, ut, INTERP_DELAY)
		Frames.setReference(frame, s.bodyId, s.pos, Universe.pocketRotation(s.bodyId, s.pos, ut))
		return true
	end
	-- CHANGED (Phase 6): an astronaut's solo pocket in space: its free-falling reference at our UT (PocketFrames)
	if pocket:GetAttribute("FrameMode") == "INERTIAL" then
		local ref = PocketFrames.fromAttributes(function(name: string): unknown
			return pocket:GetAttribute(name)
		end)
		if ref == nil then
			return false
		end
		local r = ref :: PocketFrames.Reference
		local pos = PocketFrames.referenceAt(r, ut)
		Frames.setReference(frame, r.bodyId, pos, PocketFrames.rotationAt(r, pos, ut))
		return true
	end
	local x, y, z = pocket:GetAttribute("RefX"), pocket:GetAttribute("RefY"), pocket:GetAttribute("RefZ")
	local rot = pocket:GetAttribute("RefRot")
	local body = pocket:GetAttribute("RefBodyId")
	if
		type(x) ~= "number"
		or type(y) ~= "number"
		or type(z) ~= "number"
		or typeof(rot) ~= "CFrame"
		or type(body) ~= "number"
	then
		return false
	end
	Frames.setReference(frame, body, Vec3d.set(scratchRef, x, y, z), rot)
	return true
end

-- Another pocket's frame seen from ours this update, or nil when it is unknown.
local function pocketView(id: number, ctx: RenderContext.RenderContext, renderUT: number, sample: Sampler): PocketView?
	local view = views[id]
	if view and view.stamp == frameStamp then
		return if view.ok then view else nil
	end
	if view == nil then
		local created: PocketView = {
			frame = Frames.new(Bodies.HOMEWORLD, Vec3d.zero(), CFrame.identity, Vector3.zero),
			stamp = 0,
			ok = false,
			rotation = CFrame.identity,
			bodyOffset = nil,
		}
		views[id] = created
		view = created
	end
	local v = view :: PocketView
	v.stamp = frameStamp
	v.ok = false
	local pocket = pocketFolder(id)
	local slot = if pocket then pocket:GetAttribute("SlotOrigin") else nil
	if pocket == nil or typeof(slot) ~= "Vector3" then
		return nil
	end
	v.frame.slotOrigin = slot
	if not setPocketReference(v.frame, pocket, ctx.ut, renderUT, sample) then
		return nil
	end
	local mine = ctx.frame
	v.rotation = PuppetMath.rotationBetween(v.frame, mine)
	v.bodyOffset = if v.frame.refBodyId ~= mine.refBodyId
		then Universe.bodyOffset(v.frame.refBodyId, mine.refBodyId, ctx.ut)
		else nil
	v.ok = true
	return v
end

--============================================================================
-- Per frame
--============================================================================

local function setSeated(puppet: Puppet, seated: boolean)
	local hip = if seated then SEATED_HIP else CFrame.identity
	local knee = if seated then SEATED_KNEE else CFrame.identity
	for _, joint in puppet.hips do
		joint.Transform = hip
	end
	for _, joint in puppet.knees do
		joint.Transform = knee
	end
end

local function hide(player: Player)
	local puppet = puppets[player]
	if puppet and puppet.model.Parent ~= nil then
		puppet.model.Parent = nil
	end
end

-- CHANGED (Ground puppets)
local function show(puppet: Puppet, parent: Instance)
	if puppet.model.Parent ~= parent then
		puppet.model.Parent = parent
	end
	shownCount += 1
end

-- CHANGED (Ground puppets): a change between aboard (fixed pose) and ground (copied animation) starts from neutral.
local function setMode(puppet: Puppet, mode: Mode)
	if puppet.mode == mode then
		return
	end
	puppet.mode = mode
	puppet.pairedWith = nil
	for _, joint in puppet.joints do
		joint.Transform = CFrame.identity
	end
end

-- CHANGED (Ground puppets): pairs each puppet joint with the real character's joint of the same role.
local function pairJoints(puppet: Puppet, character: Model)
	table.clear(puppet.pairPuppet)
	table.clear(puppet.pairReal)
	table.clear(puppet.pairQ)
	table.clear(puppet.pairQInverse)
	table.clear(puppet.pairDirect)
	local real: { [string]: Motor6D } = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") then
			local role = PuppetMath.jointRole(descendant.Name)
			if not real[role] then
				real[role] = descendant
			end
		end
	end
	for index, joint in puppet.joints do
		joint.Transform = CFrame.identity -- neutral unless a match drives it
		local match = real[puppet.roles[index]]
		if match then
			local q, qInverse, direct = PuppetMath.retargetFor(joint.C0, match.C0)
			table.insert(puppet.pairPuppet, joint)
			table.insert(puppet.pairReal, match)
			table.insert(puppet.pairQ, q)
			table.insert(puppet.pairQInverse, qInverse)
			table.insert(puppet.pairDirect, direct)
		end
	end
	puppet.pairedWith = character
	puppet.pairedAt = os.clock()
end

-- CHANGED (Ground puppets): copies the hidden real character's current joint transforms onto the puppet.
local function animate(puppet: Puppet, character: Model)
	if
		puppet.pairedWith ~= character
		or (#puppet.pairPuppet < #puppet.joints and os.clock() - puppet.pairedAt > REPAIR_S)
	then
		pairJoints(puppet, character)
	end
	local pairReal, pairQ, pairQInverse, pairDirect =
		puppet.pairReal, puppet.pairQ, puppet.pairQInverse, puppet.pairDirect
	for index, joint in puppet.pairPuppet do
		local real = pairReal[index]
		if real.Parent == nil then
			puppet.pairedWith = nil -- a joint went away (respawn, rig rebuilt): pair again next frame
			break
		end
		joint.Transform = PuppetMath.retarget(real.Transform, pairQ[index], pairQInverse[index], pairDirect[index])
	end
end

-- CHANGED (Ground puppets): records an on-foot player in another pocket if within GROUND_DISTANCE of the camera.
local function addGroundCandidate(
	other: Player,
	character: Model,
	root: BasePart,
	ctx: RenderContext.RenderContext,
	renderUT: number,
	sample: Sampler
): boolean
	refreshSlots()
	local position = root.Position
	local pocketId = PuppetMath.slotPocket(position, SLOT_CAPTURE_RADIUS, slotOrigins, slotIds)
	if pocketId == nil or pocketId == ctx.pocketId then
		return false -- between slots, or in our pocket (where the real character is shown)
	end
	local view = pocketView(pocketId, ctx, renderUT, sample)
	if view == nil then
		return false
	end
	local candidate = candidates[candidateCount + 1]
	if candidate == nil then
		candidate = {
			player = other,
			character = character,
			root = root,
			view = view,
			truePos = Vec3d.zero(),
			distanceSq = 0,
		}
		candidates[candidateCount + 1] = candidate
	end
	local c = candidate :: Candidate
	PuppetMath.trueInto(view.frame, view.bodyOffset, position, c.truePos)
	local distanceSq = Vec3d.distanceSq(c.truePos, ctx.cameraAbs)
	if distanceSq > GROUND_DISTANCE * GROUND_DISTANCE then
		return false
	end
	c.player, c.character, c.root, c.view, c.distanceSq = other, character, root, view, distanceSq
	candidateCount += 1
	return true
end

local function closerFirst(a: Candidate, b: Candidate): boolean
	return a.distanceSq < b.distanceSq
end

-- CHANGED (Ground puppets): the GROUND_MAX nearest visible candidates, posed at their true position and animated.
local function drawGround(ctx: RenderContext.RenderContext, parent: Instance)
	table.clear(sorted)
	for index = 1, candidateCount do
		sorted[index] = candidates[index]
	end
	if candidateCount > 1 then
		table.sort(sorted, closerFirst)
	end
	local drawn = 0
	local groundMax = GROUND_MAX_BY_TIER[Quality.tier()] or GROUND_MAX -- CHANGED (Night review)
	for _, candidate in sorted do
		local other = candidate.player
		if
			drawn >= groundMax -- CHANGED (Night review): per tier
			or LineOfSight.blocked(ctx.frame.refBodyId, ctx.cameraAbs, candidate.truePos, ctx.ut)
		then
			hide(other)
			continue
		end
		local puppet = ensurePuppet(other)
		if puppet == nil then
			continue
		end
		setMode(puppet, "Ground")
		puppet.root.CFrame =
			PuppetMath.cframeIn(ctx.frame, candidate.truePos, candidate.view.rotation, candidate.root.CFrame)
		animate(puppet, candidate.character)
		show(puppet, parent)
		drawn += 1
	end
	table.clear(sorted)
	if frameStamp % VIEW_PRUNE_FRAMES == 0 then
		for id, view in views do
			if frameStamp - view.stamp > VIEW_PRUNE_FRAMES then
				views[id] = nil
			end
		end
	end
end

function Puppets.init(parent: Instance)
	local created = Instance.new("Folder")
	created.Name = "Puppets"
	created.Parent = parent
	folder = created
	Players.PlayerRemoving:Connect(function(player: Player)
		destroyPuppet(player)
		building[player] = nil
		failedAt[player] = nil
	end)
	-- CHANGED (Night review): dropping to Low swaps full-appearance puppets for stand-ins (rebuilt on next use)
	Quality.onChanged(function(tier: Quality.Tier)
		if tier ~= STAND_IN_TIER then
			return
		end
		for player, puppet in puppets do
			if not puppet.standIn then
				puppet.model:Destroy()
				puppets[player] = nil
			end
		end
	end)
end

--[[
	Called once per render frame by RemoteCraftRenderer after the copies are posed.
	ctx: this frame's render context (CHANGED (Ground puppets): was the pocket id; the frame and camera are needed for
	players on foot in other pockets); renderUT: the UT copies are sampled at; copies: craft id -> the copy drawn
	this frame (true-scale, posed root).
]]
function Puppets.update(
	ctx: RenderContext.RenderContext,
	renderUT: number,
	copies: { [number]: CopyInfo },
	sample: Sampler
)
	local parent = folder
	if parent == nil then
		return
	end
	local myPocketId = ctx.pocketId
	local localPlayer = Players.LocalPlayer
	shownCount = 0
	frameStamp += 1 -- CHANGED (Ground puppets)
	candidateCount = 0
	for _, other in Players:GetPlayers() do
		if other == localPlayer then
			continue
		end
		local character = other.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local otherPocket = other:GetAttribute("PocketId")
		if
			character == nil
			or humanoid == nil
			or humanoid.Health <= 0
			or root == nil
			or not root:IsA("BasePart")
			or type(otherPocket) ~= "number"
			or otherPocket == myPocketId
		then
			hide(other)
			continue
		end
		local craftId, rel, seated = aboardPose(other, root, humanoid, sample, renderUT, copies)
		if craftId == nil then
			-- CHANGED (Ground puppets): on foot (not seated, not aboard): drawn at the true position, if near
			if humanoid.SeatPart ~= nil or not addGroundCandidate(other, character, root, ctx, renderUT, sample) then
				hide(other)
			end
			continue
		end
		local copy = copies[craftId]
		if copy == nil or rel == nil or copy.distance > PUPPET_DISTANCE then
			hide(other)
			continue
		end
		local puppet = ensurePuppet(other)
		if puppet == nil then
			continue
		end
		setMode(puppet, "Aboard") -- CHANGED (Ground puppets)
		puppet.root.CFrame = copy.root.CFrame * rel
		setSeated(puppet, seated)
		show(puppet, parent)
	end
	drawGround(ctx, parent) -- CHANGED (Ground puppets)
end

-- Puppets drawn in the last update (debug overlay).
function Puppets.shownCount(): number
	return shownCount
end

return Puppets
