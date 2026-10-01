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
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)

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
--============================================================================

export type CopyInfo = { root: BasePart, distance: number, radius: number }
export type Sampler = (craftId: number, ut: number) -> Protocol.State?

type Puppet = {
	model: Model,
	root: BasePart,
	hips: { Motor6D },
	knees: { Motor6D },
	standIn: boolean, -- the blocky fallback (the real appearance is retried every RETRY_BUILD_S)
}

local Puppets = {}

local folder: Folder? = nil
local puppets: { [Player]: Puppet } = {}
local building: { [Player]: boolean } = {}
local failedAt: { [Player]: number } = {}
local shownCount = 0

--============================================================================
-- Building
--============================================================================

local function collectMotors(model: Model, names: { string }): { Motor6D }
	local result = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Motor6D") and table.find(names, descendant.Name) then
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
	return {
		model = model,
		root = root,
		hips = collectMotors(model, HIP_NAMES),
		knees = collectMotors(model, KNEE_NAMES),
		standIn = false,
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
		destroyPuppet(player) -- replaces a stand-in
		puppets[player] = puppet
	end)
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
end

--[[
	Called once per render frame by RemoteCraftRenderer after the copies are posed.
	myPocketId: the local pocket; copies: craft id -> the copy drawn this frame (true-scale, posed root).
]]
function Puppets.update(myPocketId: number, renderUT: number, copies: { [number]: CopyInfo }, sample: Sampler)
	local parent = folder
	if parent == nil then
		return
	end
	local localPlayer = Players.LocalPlayer
	shownCount = 0
	for _, other in Players:GetPlayers() do
		if other == localPlayer then
			continue
		end
		local character = other.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		local otherPocket = other:GetAttribute("PocketId")
		if
			humanoid == nil
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
		local copy = if craftId then copies[craftId] else nil
		if copy == nil or rel == nil or copy.distance > PUPPET_DISTANCE then
			hide(other)
			continue
		end
		local puppet = puppets[other]
		if puppet == nil or puppet.standIn then
			requestPuppet(other)
		end
		if puppet == nil then
			continue
		end
		puppet.root.CFrame = copy.root.CFrame * rel
		setSeated(puppet, seated)
		if puppet.model.Parent ~= parent then
			puppet.model.Parent = parent
		end
		shownCount += 1
	end
end

-- Puppets drawn in the last update (debug overlay).
function Puppets.shownCount(): number
	return shownCount
end

return Puppets
