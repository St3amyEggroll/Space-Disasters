--!strict
--[[
	PocketController (spec 7.5)
	Which pocket the local player is in, that pocket's frame each render frame, pocket transfers, and hiding
	everything that belongs to other pockets (invariant I6).

	Frame sources:
	  SURFACE_ALIGNED / INERTIAL   the pocket folder's RefX/RefY/RefZ/RefRot/RefBodyId attributes
	  CRAFT_ALIGNED                the primary craft's state: from a registered provider (the pilot's own
	                               simulation, FlightController) or the interpolated stream (passengers,
	                               RemoteCraftRenderer), falling back to the pocket's attributes at creation.

	Hiding (spike S2): LocalTransparencyModifier on parts, CastShadow off, decals/textures transparent, GUIs and
	ProximityPrompts disabled, name tags hidden. Client raycasts always use Include filters (hidden parts still
	block rays).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local DebugOverlay = require(script.Parent.DebugOverlay)
local RemoteCraftRenderer = require(script.Parent.RemoteCraftRenderer)

--============================================================================
-- Tunables
--============================================================================
local INTERP_DELAY = GameConfig.INTERP_DELAY
local CHARACTER_CHECK_S = 0.5
local SLOT_CAPTURE_RADIUS = 1800 -- same as PocketService
--============================================================================

-- What the pilot's simulation reports for its own craft (a subset of FlightModel.CraftState).
export type PrimaryState = { bodyId: number, pos: Vec3d.Vec3d, rot: CFrame, ut: number }
export type PrimaryProvider = (craftId: number) -> PrimaryState?

local PocketController = {}

local player = Players.LocalPlayer
local pocketId = 0
local frame: Frames.Frame =
	Frames.new(Bodies.HOMEWORLD, Vec3d.new(Bodies.get(Bodies.HOMEWORLD).Radius, 0, 0), CFrame.identity, Vector3.zero, 0)
local renderUT = 0
local frameMode = "SURFACE_ALIGNED"
local primaryProvider: PrimaryProvider? = nil
local pocketChanged = Instance.new("BindableEvent")

-- Hidden-state bookkeeping so we can restore what we changed
local hiddenRoots: { [Instance]: RBXScriptConnection } = {}
local savedCastShadow: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local savedTransparency: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local savedEnabled: { [Instance]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local hiddenCharacters: { [Model]: boolean } = {}

--============================================================================
-- Hiding
--============================================================================

local function hideInstance(instance: Instance)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = 1
		if savedCastShadow[instance] == nil then
			savedCastShadow[instance] = instance.CastShadow
		end
		instance.CastShadow = false
	elseif instance:IsA("Decal") then -- includes Texture
		if savedTransparency[instance] == nil then
			savedTransparency[instance] = instance.Transparency
		end
		instance.Transparency = 1
	elseif instance:IsA("LayerCollector") then -- SurfaceGui, BillboardGui
		if savedEnabled[instance] == nil then
			savedEnabled[instance] = instance.Enabled
		end
		instance.Enabled = false
	elseif instance:IsA("ProximityPrompt") then
		if savedEnabled[instance] == nil then
			savedEnabled[instance] = instance.Enabled
		end
		instance.Enabled = false
	elseif instance:IsA("Humanoid") then
		instance.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	elseif instance:IsA("ParticleEmitter") or instance:IsA("Beam") or instance:IsA("Light") then
		if savedEnabled[instance] == nil then
			savedEnabled[instance] = (instance :: any).Enabled
		end
		(instance :: any).Enabled = false
	end
end

local function showInstance(instance: Instance)
	if instance:IsA("BasePart") then
		instance.LocalTransparencyModifier = 0
		local shadow = savedCastShadow[instance]
		if shadow ~= nil then
			instance.CastShadow = shadow
			savedCastShadow[instance] = nil
		end
	elseif instance:IsA("Decal") then
		local transparency = savedTransparency[instance]
		if transparency ~= nil then
			instance.Transparency = transparency
			savedTransparency[instance] = nil
		end
	elseif instance:IsA("Humanoid") then
		instance.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	else
		local enabled = savedEnabled[instance]
		if enabled ~= nil then
			(instance :: any).Enabled = enabled
			savedEnabled[instance] = nil
		end
	end
end

local function hideTree(root: Instance)
	if hiddenRoots[root] then
		return
	end
	hideInstance(root)
	for _, descendant in root:GetDescendants() do
		hideInstance(descendant)
	end
	hiddenRoots[root] = root.DescendantAdded:Connect(hideInstance)
end

local function showTree(root: Instance)
	local connection: RBXScriptConnection? = hiddenRoots[root]
	if not connection then
		return
	end
	connection:Disconnect()
	hiddenRoots[root] = nil
	showInstance(root)
	for _, descendant in root:GetDescendants() do
		showInstance(descendant)
	end
end

local function pocketFolders(): { Instance }
	local pockets = Workspace:FindFirstChild("Pockets")
	return if pockets then pockets:GetChildren() else {}
end

local function refreshPocketVisibility()
	for _, pocket in pocketFolders() do
		local id = pocket:GetAttribute("PocketId")
		if id == pocketId then
			showTree(pocket)
		else
			hideTree(pocket)
		end
	end
end

-- Pocket of a workspace position by slot distance (0 = base), nil if in no known pocket.
local function pocketAt(position: Vector3): number?
	if position.Magnitude < SLOT_CAPTURE_RADIUS * 1.5 then
		return 0
	end
	for _, pocket in pocketFolders() do
		local origin = pocket:GetAttribute("SlotOrigin")
		if typeof(origin) == "Vector3" and (position - origin).Magnitude < SLOT_CAPTURE_RADIUS then
			local id = pocket:GetAttribute("PocketId")
			return if type(id) == "number" then id else nil
		end
	end
	return nil
end

local function refreshCharacters()
	for _, other in Players:GetPlayers() do
		local character = other.Character
		if other ~= player and character then
			local root = character:FindFirstChild("HumanoidRootPart")
			local otherPocket = if root and root:IsA("BasePart") then pocketAt(root.Position) else nil
			local shouldHide = otherPocket ~= nil and otherPocket ~= pocketId
			if shouldHide and not hiddenCharacters[character] then
				hiddenCharacters[character] = true
				hideTree(character)
			elseif not shouldHide and hiddenCharacters[character] then
				hiddenCharacters[character] = nil
				showTree(character)
			end
		end
	end
	for character in hiddenCharacters do
		if character.Parent == nil then
			hiddenCharacters[character] = nil
			local connection = hiddenRoots[character]
			if connection then
				connection:Disconnect()
				hiddenRoots[character] = nil
			end
		end
	end
end

--============================================================================
-- Pocket switching and transfers
--============================================================================

local function setPocket(id: number)
	if id == pocketId then
		return
	end
	pocketId = id
	refreshPocketVisibility()
	refreshCharacters()
	pocketChanged:Fire(id)
end

local function onTransfer(transferId: unknown, _source: unknown, dest: unknown, m: unknown, epoch: unknown)
	if type(transferId) ~= "number" or type(dest) ~= "number" or typeof(m) ~= "CFrame" then
		return
	end
	local transform = m :: CFrame
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if humanoid and humanoid.SeatPart == nil and root and root:IsA("BasePart") then
		-- not seated: move ourselves by the same rigid transform as the craft (seated crew ride with the seat)
		root.CFrame = transform * root.CFrame
		root.AssemblyLinearVelocity = transform:VectorToWorldSpace(root.AssemblyLinearVelocity)
	end
	local camera = Workspace.CurrentCamera
	camera.CFrame = transform * camera.CFrame
	if type(epoch) == "number" then
		frame.frameEpoch = epoch
	end
	setPocket(dest :: number)
	Remotes.event("PocketTransferAck"):FireServer(transferId)
end

--============================================================================
-- Frame (updated once per render frame by UniverseRenderer)
--============================================================================

local function pocketFolder(id: number): Instance?
	local pockets = Workspace:FindFirstChild("Pockets")
	return if pockets then pockets:FindFirstChild(`Pocket_{id}`) else nil
end

local function frameFromAttributes(folder: Instance): boolean
	local x, y, z = folder:GetAttribute("RefX"), folder:GetAttribute("RefY"), folder:GetAttribute("RefZ")
	local rot = folder:GetAttribute("RefRot")
	local body = folder:GetAttribute("RefBodyId")
	if
		type(x) == "number"
		and type(y) == "number"
		and type(z) == "number"
		and typeof(rot) == "CFrame"
		and type(body) == "number"
	then
		Frames.setReference(frame, body, Vec3d.new(x, y, z), rot)
		return true
	end
	return false
end

-- Recomputes the current pocket frame; call once per render frame before drawing.
function PocketController.update()
	local now = UniverseTime.now()
	renderUT = now
	local folder = pocketFolder(pocketId)
	if folder == nil then
		return
	end
	local slot = folder:GetAttribute("SlotOrigin")
	if typeof(slot) == "Vector3" then
		frame.slotOrigin = slot
	end
	local mode = folder:GetAttribute("FrameMode")
	frameMode = if type(mode) == "string" then mode else "SURFACE_ALIGNED"
	if frameMode == "CRAFT_ALIGNED" then
		local primary = folder:GetAttribute("PrimaryId")
		if type(primary) == "number" then
			local provider = primaryProvider
			local own = if provider then provider(primary) else nil
			if own then
				Frames.setReference(frame, own.bodyId, own.pos, own.rot)
				renderUT = own.ut
				return
			end
			local streamed = RemoteCraftRenderer.sampleState(primary, now - INTERP_DELAY)
			if streamed then
				Frames.setReference(frame, streamed.bodyId, streamed.pos, streamed.rot)
				renderUT = now - INTERP_DELAY
				return
			end
		end
	end
	frameFromAttributes(folder)
end

function PocketController.frame(): Frames.Frame
	return frame
end

-- UT the current frame corresponds to (pilot: its simulation time; passengers: the interpolation time).
function PocketController.renderUT(): number
	return renderUT
end

function PocketController.pocketId(): number
	return pocketId
end

function PocketController.frameMode(): string
	return frameMode
end

-- The pilot's simulation registers here so its own craft's pocket follows the local state exactly.
function PocketController.registerPrimaryProvider(provider: PrimaryProvider)
	primaryProvider = provider
end

function PocketController.onPocketChanged(callback: (id: number) -> ()): RBXScriptConnection
	return pocketChanged.Event:Connect(callback)
end

--============================================================================
-- Lifecycle
--============================================================================

function PocketController.Init()
	DebugOverlay.addLine("pocket", 20, function()
		return string.format(
			"Pocket %d  %s  epoch %d  body %s",
			pocketId,
			frameMode,
			frame.frameEpoch,
			Bodies.get(frame.refBodyId).DisplayName
		)
	end)
end

function PocketController.Start()
	Remotes.event("PocketTransfer").OnClientEvent:Connect(onTransfer)
	player:GetAttributeChangedSignal("PocketId"):Connect(function()
		local id = player:GetAttribute("PocketId")
		if type(id) == "number" then
			setPocket(id)
		end
	end)
	local initial = player:GetAttribute("PocketId")
	if type(initial) == "number" then
		setPocket(initial)
	end
	local pockets = Workspace:WaitForChild("Pockets")
	pockets.ChildAdded:Connect(function()
		task.defer(refreshPocketVisibility)
	end)
	refreshPocketVisibility()
	task.spawn(function()
		while true do
			task.wait(CHARACTER_CHECK_S)
			refreshCharacters()
		end
	end)
end

return PocketController
