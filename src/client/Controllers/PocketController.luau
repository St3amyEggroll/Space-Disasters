--!strict
--[[
	PocketController (spec 7.5)
	Which pocket the local player is in, that pocket's frame each render frame, pocket transfers, and hiding
	everything that belongs to other pockets (invariant I6).

	Frame sources:
	  SURFACE_ALIGNED / INERTIAL   the pocket folder's RefX/RefY/RefZ/RefRot/RefBodyId attributes
	  HORIZON_ALIGNED              CHANGED (Phase 2a feedback, D31; was CRAFT_ALIGNED): reference point = the primary
	                               craft's position, axes = the local horizon (Y away from the body centre; above
	                               the air Y turns toward the sun, Universe.pocketUp), from
	                               the craft's state: a registered provider (the pilot's own simulation,
	                               FlightController) or the interpolated stream (passengers, RemoteCraftRenderer),
	                               falling back to the pocket's attributes at creation. Because the pocket no longer
	                               turns with the craft, this client poses the craft's real model every frame
	                               (anchored parts moved locally; seated characters ride along with their seats).
	                               The server never moves the model in flight; when it does (pocket transfers) it
	                               bumps the model's PoseEpoch attribute and the pose cache is rebuilt, and models
	                               are only posed while their FlightPocket attribute names the current pocket.

	Hiding (spike S2): LocalTransparencyModifier on parts, CastShadow off, decals/textures transparent, GUIs and
	ProximityPrompts disabled, name tags hidden. Client raycasts always use Include filters (hidden parts still
	block rays).

	CHANGED (Phase 6): EVA and bubbles.
	  * INERTIAL pockets (an astronaut's solo pocket in space): the reference is a free-falling point propagated on
	    its conic from the folder's RefX../RefVX../RefUT attributes, with the horizon / sun axes (Shared/Sim/
	    PocketFrames); renderUT is now. SURFACE_ALIGNED solo pockets read their attributes like the base.
	  * EVERY craft model in the pocket is posed, not only the primary: a pocket can hold secondary crafts (merged
	    bubbles, uncrewed crafts near an astronaut). Each is drawn at the pocket's render UT: this client's own
	    simulation moved back / forward to it, a rail sampled at it, or the stream sampled at it (led to it when the
	    frame runs at the present, StateBuffer.lead). craftCFrame(id) gives any posed craft's frame (the pilot of a
	    secondary craft's chase camera and effects use it), and RemoteCraftRenderer learns which crafts are real in
	    this pocket every frame (no cosmetic copy for them).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PocketFrames = require(ReplicatedStorage.Shared.Sim.PocketFrames) -- CHANGED (Phase 6)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails) -- CHANGED (Phase 6): secondary crafts on rails
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local StateBuffer = require(ReplicatedStorage.Shared.Net.StateBuffer) -- CHANGED (Phase 6)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local DebugOverlay = require(script.Parent.DebugOverlay)
local RemoteCraftRenderer = require(script.Parent.RemoteCraftRenderer)
local Gear = require(script.Parent.Parent.Render.Gear)

--============================================================================
-- Tunables
--============================================================================
local INTERP_DELAY = GameConfig.INTERP_DELAY
local CHARACTER_CHECK_S = 0.5
local SLOT_CAPTURE_RADIUS = 1800 -- same as PocketService
local POSE_MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged
--============================================================================

-- What the pilot's simulation reports for its own craft (a subset of FlightModel.CraftState).
-- CHANGED (Phase 10): vel (optional) so effects know how fast the pocket moves through the air
export type PrimaryState = {
	bodyId: number,
	pos: Vec3d.Vec3d,
	vel: Vec3d.Vec3d?,
	rot: CFrame,
	ut: number,
	flags: number?,
}
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
local primaryCraftCFrame: CFrame? = nil -- workspace CFrame of the posed primary craft's reference frame
local primaryCraftId: number? = nil -- CHANGED (Phase 6): the primary craft posed this frame
-- CHANGED (Phase 10): velocity of the pocket's reference point relative to frame.refBodyId (universe axes); the
-- primary craft's velocity in a flight pocket, zero otherwise (planets do not rotate)
local frameVelocity = Vec3d.zero()

-- Pose cache for the real model of the current pocket's primary craft (D31).
type PoseCache = {
	model: Model,
	epoch: unknown, -- PoseEpoch the offsets were read at
	parts: { BasePart },
	offsets: { CFrame }, -- each part relative to the craft reference frame
	seats: { BasePart }, -- seats are moved one by one (CFrame writes carry a welded, seated character along)
	seatOffsets: { CFrame },
	gear: { Gear.GearPart }, -- CHANGED (Phase 2a remodel): landing-leg parts, posed by Gear
	gearFraction: number, -- 1 = deployed
	gearTime: number, -- os.clock() of the last gear update
	cframes: { CFrame }, -- scratch for BulkMoveTo
	dirty: boolean, -- a part was removed: drop missing parts before the next move
	connection: RBXScriptConnection,
}
-- CHANGED (Phase 6): one cache per posed model (primary and secondary crafts), and what was posed this frame
local poseCaches: { [Model]: PoseCache } = {}
local posedThisFrame: { [Model]: boolean } = {}
local posedCFrames: { [number]: CFrame } = {} -- craft id -> workspace CFrame of its craft reference frame

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

-- CHANGED (Phase 2a playtest): whatever ARRIVES in the shown pocket is un-hidden. A craft model re-parented from
-- a hidden pocket into ours after we switched (S8: re-parents can lag the transfer event) kept its hidden state
-- and flew invisible, with only its seat prompts showing.
local shownRoots: { [Instance]: RBXScriptConnection } = {}

local function refreshPocketVisibility()
	for _, pocket in pocketFolders() do
		local id = pocket:GetAttribute("PocketId")
		if id == pocketId then
			showTree(pocket)
			if not shownRoots[pocket] then
				shownRoots[pocket] = pocket.DescendantAdded:Connect(showInstance)
			end
		else
			local connection = shownRoots[pocket]
			if connection then
				connection:Disconnect()
				shownRoots[pocket] = nil
			end
			hideTree(pocket)
		end
	end
	for root, connection in shownRoots do
		if root.Parent == nil then
			connection:Disconnect()
			shownRoots[root] = nil
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

--============================================================================
-- Posing the primary craft (HORIZON_ALIGNED pockets)
--============================================================================

-- CHANGED (Phase 6): drops the caches of models not posed this frame (every cache when `all`).
local function dropPoseCaches(all: boolean)
	for model, cache in poseCaches do
		if all or not posedThisFrame[model] then
			cache.connection:Disconnect()
			poseCaches[model] = nil
		end
	end
end

-- The craft reference frame (root block centre, design axes) of a real model where it stands now.
local function craftFrameOf(model: Model): CFrame?
	local design = CraftBuilder.readDesign(model)
	local root = CraftDesign.rootBlock(design)
	local block = if root then CraftBuilder.findBlockModel(model, root.id) else nil
	local bounds = if block then block:FindFirstChild("Bounds") else nil
	if root == nil or bounds == nil or not bounds:IsA("BasePart") then
		return nil
	end
	-- Bounds = origin * blockCFrame(root) = (craft frame) * rotation(root.rot)
	return bounds.CFrame * CraftDesign.rotationCFrame(root.rot):Inverse()
end

local function buildPoseCache(model: Model): PoseCache?
	local craftFrame = craftFrameOf(model)
	if craftFrame == nil then
		return nil
	end
	local inverse = craftFrame:Inverse()
	local parts: { BasePart } = {}
	local offsets: { CFrame } = {}
	local seats: { BasePart } = {}
	local seatOffsets: { CFrame } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("Seat") then
			table.insert(seats, descendant)
			table.insert(seatOffsets, inverse * descendant.CFrame)
		elseif descendant:IsA("BasePart") and not Gear.isMoving(descendant) then
			table.insert(parts, descendant)
			table.insert(offsets, inverse * descendant.CFrame)
		end
	end
	local cache: PoseCache
	cache = {
		model = model,
		epoch = model:GetAttribute("PoseEpoch"),
		parts = parts,
		offsets = offsets,
		seats = seats,
		seatOffsets = seatOffsets,
		gear = Gear.collect(model, craftFrame),
		gearFraction = 1,
		gearTime = os.clock(),
		cframes = table.create(#parts),
		dirty = false,
		connection = model.DescendantRemoving:Connect(function(descendant: Instance)
			if descendant:IsA("BasePart") then
				cache.dirty = true
			end
		end),
	}
	return cache
end

-- CHANGED (Phase 6): poses one real model (was: only the primary's) at `target`, the workspace CFrame of its craft
-- reference frame. Only call it while the model's FlightPocket attribute names this pocket (the server clears it,
-- in order, before it moves the model out again: a stale local pose would otherwise stick, since replication only
-- sends changes).
local function poseModel(model: Model, target: CFrame, flags: number?)
	posedThisFrame[model] = true
	local cache: PoseCache? = poseCaches[model]
	if cache == nil or cache.epoch ~= model:GetAttribute("PoseEpoch") then
		if cache then
			cache.connection:Disconnect()
			poseCaches[model] = nil
		end
		cache = buildPoseCache(model)
		if cache then
			poseCaches[model] = cache
		end
	end
	if cache == nil then
		return
	end
	if cache.dirty then
		cache.dirty = false
		local parts, offsets = {}, {}
		for index, part in cache.parts do
			if part.Parent ~= nil and part:IsDescendantOf(model) then
				table.insert(parts, part)
				table.insert(offsets, cache.offsets[index])
			end
		end
		cache.parts, cache.offsets = parts, offsets
		table.clear(cache.cframes)
	end
	local cframes = cache.cframes
	for index, offset in cache.offsets do
		cframes[index] = target * offset
	end
	if #cache.parts > 0 then
		Workspace:BulkMoveTo(cache.parts, cframes, POSE_MOVE_MODE)
	end
	for index, seat in cache.seats do
		if seat.Parent ~= nil then
			seat.CFrame = target * cache.seatOffsets[index]
		end
	end
	if #cache.gear > 0 then
		local now = os.clock()
		cache.gearFraction = Gear.approach(cache.gearFraction, Gear.target(flags), now - cache.gearTime)
		cache.gearTime = now
		Gear.pose(cache.gear, target, cache.gearFraction)
	end
end

--[[
	CHANGED (Phase 6): the state of a NON-primary craft at the pocket's render UT: this client's own simulation moved
	there with its velocity (a secondary craft's pilot sees his craft where everyone in the pocket sees it), a rail
	sampled there, or the stream sampled there (led forward to it when the frame runs at the present).
]]
local function secondaryState(craftId: number, now: number): PrimaryState?
	local provider = primaryProvider
	local own = if provider then provider(craftId) else nil
	if own then
		local vel = own.vel
		local dt = renderUT - own.ut
		if vel == nil or dt == 0 then
			return own
		end
		return {
			bodyId = own.bodyId,
			pos = Vec3d.addScaled(own.pos, vel, dt),
			vel = vel,
			rot = own.rot,
			ut = renderUT,
			flags = own.flags,
		}
	end
	local rails = RemoteCraftRenderer.railsOf(craftId)
	if rails then
		return Rails.stateAt(rails, renderUT)
	end
	local sampleUT = math.min(renderUT, now - INTERP_DELAY)
	local sampled = RemoteCraftRenderer.sampleState(craftId, sampleUT)
	if sampled and renderUT > sampleUT then
		return StateBuffer.lead(sampled, renderUT, INTERP_DELAY)
	end
	return sampled
end

-- CHANGED (Phase 6): poses every real craft model of the pocket (the primary from `primaryState`).
local function poseCrafts(folder: Instance, primaryId: number?, primaryState: PrimaryState?, now: number)
	table.clear(posedThisFrame)
	local crafts = folder:FindFirstChild("Crafts")
	if crafts then
		for _, child in crafts:GetChildren() do
			if not child:IsA("Model") or child:GetAttribute("FlightPocket") ~= pocketId then
				continue
			end
			local id = child:GetAttribute("CraftId")
			if type(id) ~= "number" then
				continue
			end
			local state = if id == primaryId then primaryState else secondaryState(id, now)
			if state == nil then
				continue
			end
			local s = state :: PrimaryState
			local known: CFrame? = posedCFrames[id] -- the primary's pose is already computed
			local target: CFrame
			if known then
				target = known
			else
				local offset = if s.bodyId ~= frame.refBodyId
					then Universe.bodyOffset(s.bodyId, frame.refBodyId, renderUT)
					else nil
				target = Frames.cframeToWorkspace(frame, s.pos, s.rot, offset)
				posedCFrames[id] = target
			end
			poseModel(child, target, s.flags)
		end
	end
	dropPoseCaches(false)
	RemoteCraftRenderer.setLocalPocketCrafts(posedCFrames)
end

-- Recomputes the current pocket frame; call once per render frame before drawing.
function PocketController.update()
	local now = UniverseTime.now()
	renderUT = now
	table.clear(posedCFrames) -- CHANGED (Phase 6)
	local folder = pocketFolder(pocketId)
	if folder == nil then
		table.clear(posedThisFrame)
		dropPoseCaches(true)
		RemoteCraftRenderer.setLocalPocketCrafts(posedCFrames)
		return
	end
	local slot = folder:GetAttribute("SlotOrigin")
	if typeof(slot) == "Vector3" then
		frame.slotOrigin = slot
	end
	local mode = folder:GetAttribute("FrameMode")
	frameMode = if type(mode) == "string" then mode else "SURFACE_ALIGNED"
	primaryCraftCFrame = nil
	primaryCraftId = nil -- CHANGED (Phase 6)
	Vec3d.set(frameVelocity, 0, 0, 0) -- CHANGED (Phase 10)
	local primaryId: number? = nil
	local primaryState: PrimaryState? = nil
	if frameMode == "HORIZON_ALIGNED" then
		local primary = folder:GetAttribute("PrimaryId")
		if type(primary) == "number" then
			local provider = primaryProvider
			local own = if provider then provider(primary) else nil
			local state: PrimaryState? = own
			if state then
				renderUT = state.ut
			else
				local streamed = RemoteCraftRenderer.sampleState(primary, now - INTERP_DELAY)
				if streamed then
					state = streamed
					renderUT = now - INTERP_DELAY
				end
			end
			if state then
				local vel = state.vel -- CHANGED (Phase 10)
				if vel then
					Vec3d.copyInto(frameVelocity, vel)
				end
				Frames.setReference(
					frame,
					state.bodyId,
					state.pos,
					Universe.pocketRotation(state.bodyId, state.pos, renderUT)
				)
				-- the primary's reference point is the pocket reference (it sits at the slot origin)
				local target = Frames.cframeToWorkspace(frame, state.pos, state.rot)
				primaryCraftCFrame = target
				posedCFrames[primary] = target
				primaryId, primaryState = primary, state
				primaryCraftId = primary -- CHANGED (Phase 6)
			end
		end
		if primaryState == nil then
			frameFromAttributes(folder)
		end
	elseif frameMode == "INERTIAL" then
		-- CHANGED (Phase 6): an astronaut's solo pocket in space: a free-falling reference (PocketFrames)
		local ref = PocketFrames.fromAttributes(function(name: string): unknown
			return folder:GetAttribute(name)
		end)
		if ref then
			local r = ref :: PocketFrames.Reference
			local pos, vel = PocketFrames.referenceAt(r, now)
			Frames.setReference(frame, r.bodyId, pos, PocketFrames.rotationAt(r, pos, now))
			Vec3d.copyInto(frameVelocity, vel)
		else
			frameFromAttributes(folder)
		end
	else
		frameFromAttributes(folder)
	end
	poseCrafts(folder, primaryId, primaryState, now) -- CHANGED (Phase 6): every craft of the pocket
end

-- CHANGED (Phase 2a feedback, D31): workspace CFrame of the current pocket's primary craft reference frame
-- (root block centre, craft axes) as posed this frame; nil outside flight pockets or before the state arrives.
function PocketController.primaryCraftCFrame(): CFrame?
	return primaryCraftCFrame
end

-- CHANGED (Phase 6): workspace CFrame of any craft posed in the current pocket this frame (primary or secondary;
-- craft reference frame: root block centre, craft axes), or nil.
function PocketController.craftCFrame(craftId: number): CFrame?
	return posedCFrames[craftId]
end

-- CHANGED (Phase 6): the id of the craft the current pocket's frame follows (nil outside craft pockets).
function PocketController.primaryCraftId(): number?
	return primaryCraftId
end

function PocketController.frame(): Frames.Frame
	return frame
end

-- CHANGED (Phase 10): velocity of the current pocket's reference point relative to frame.refBodyId (universe axes,
-- m/s): the primary craft's velocity in a flight pocket, zero in surface pockets. Effects use it to move smoke and
-- dust with the air.
function PocketController.frameVelocity(): Vec3d.Vec3d
	return frameVelocity
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
