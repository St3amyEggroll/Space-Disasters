--!strict
--[[
	PocketService
	Owns Workspace.Pockets. The permanent base pocket (slot 0) is a SURFACE_ALIGNED pocket at the launch site on
	Homeworld's equator (lat 0, lon 0), holding the HomeBase site, the plot builds and the rolled-out crafts.
	CHANGED (Phase 2a): crewed crafts in flight get their own CRAFT_ALIGNED pocket on the slot lattice
	(ix, iz in [-3, 3], iy in [1, 3], spacing POCKET_SPACING). The server tracks which pocket each player's
	character is in (player attribute "PocketId") and releases empty flight pockets.

	Pocket folder layout (spec 6.4):
	  Workspace.Pockets.Pocket_<id>            Folder with attributes PocketId, SlotOrigin, FrameMode, PrimaryKind,
	                                           PrimaryId, RefBodyId, FrameEpoch, RefX/RefY/RefZ, RefRot
	                                           (CHANGED (Phase 6): solo pockets also RefVX/RefVY/RefVZ, RefUT)
	    Crafts                                 real craft models
	    Site                                   (base only) the HomeBase site model
	    Builds                                 (base only) Plot_<i> folders with hangar block models

	CHANGED (Phase 6): EVA and bubbles (BubbleService decides, this service keeps the books).
	  * A flight pocket has a KIND: "Craft" (primary = a craft, FrameMode HORIZON_ALIGNED, PrimaryKind "Craft",
	    PrimaryId = craft id) or "Solo" (primary = an astronaut on EVA, PrimaryKind "Astronaut", PrimaryId = user id,
	    FrameMode INERTIAL or SURFACE_ALIGNED with the reference from Shared/Sim/PocketFrames). A pocket can hold
	    several crafts (the primary and secondaries; each craft record's pocketId says where its model is) and any
	    number of players.
	  * setCraftPrimary / setSoloPrimary / setSoloReference change a pocket's primary or reference in place and bump
	    FrameEpoch; BubbleService moves the crafts and players with the matching PocketTransfer.
	  * pin(player, id): right after a PocketTransfer the server still sees the character where it was (replication
	    lags), so trackPlayers leaves that player's PocketId alone for PIN_S (and counts the pocket as occupied).
	  * An empty pocket of either kind is released after EMPTY_RELEASE_S (onReleased listeners run first).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HomeBase = require(ReplicatedStorage.Shared.Sites.HomeBase)
local PocketFrames = require(ReplicatedStorage.Shared.Sim.PocketFrames) -- CHANGED (Phase 6)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

--============================================================================
-- Tunables
--============================================================================
local BASE_POCKET_ID = 0
local BASE_LATITUDE = 0 -- rad
local BASE_LONGITUDE = 0 -- rad
local SPACING = GameConfig.POCKET_SPACING
local SLOT_CAPTURE_RADIUS = 1800 -- studs: a character this close to a slot origin is in that pocket
local TRACK_INTERVAL_S = 0.5
local EMPTY_RELEASE_S = 3 -- an empty flight pocket is released after this long
local PIN_S = 3 -- CHANGED (Phase 6): s after a transfer during which trackPlayers keeps the player's PocketId
--============================================================================

-- CHANGED (Phase 6): pockets have a kind (see the header)
export type PocketKind = "Craft" | "Solo"

export type FlightPocket = {
	id: number,
	folder: Folder,
	slotOrigin: Vector3,
	kind: PocketKind, -- CHANGED (Phase 6)
	craftId: number?, -- the primary craft (Craft pockets); CHANGED (Phase 6): nil for Solo pockets
	userId: number?, -- CHANGED (Phase 6): the primary astronaut (Solo pockets)
	ref: PocketFrames.Reference?, -- CHANGED (Phase 6): the reference (Solo pockets)
	order: number, -- CHANGED (Phase 6): creation order (smaller = older)
	emptySince: number?,
}

local PocketService = {}

PocketService.BASE_POCKET_ID = BASE_POCKET_ID

local pocketsFolder: Folder? = nil
local basePocket: Folder? = nil
local baseFrame: Frames.Frame? = nil
local flightPockets: { [number]: FlightPocket } = {}
local releaseListeners: { (pocket: FlightPocket) -> () } = {}
local nextOrder = 1 -- CHANGED (Phase 6)
local pins: { [Player]: { id: number, untilTime: number } } = {} -- CHANGED (Phase 6)

-- Slot lattice (excluding slot 0 at the origin): pocket id -> slot origin
local slotOrigins: { [number]: Vector3 } = {}
do
	local id = 0
	for iy = GameConfig.POCKET_SLOT_Y_MIN, GameConfig.POCKET_SLOT_Y_MAX do
		for ix = -GameConfig.POCKET_SLOT_X_RANGE, GameConfig.POCKET_SLOT_X_RANGE do
			for iz = -GameConfig.POCKET_SLOT_Z_RANGE, GameConfig.POCKET_SLOT_Z_RANGE do
				id += 1
				slotOrigins[id] = Vector3.new(ix * SPACING, iy * SPACING, iz * SPACING)
			end
		end
	end
end

local function createPocketFolder(id: number, slotOrigin: Vector3): Folder
	local pocket = Instance.new("Folder")
	pocket.Name = `Pocket_{id}`
	pocket:SetAttribute("PocketId", id)
	pocket:SetAttribute("SlotOrigin", slotOrigin)
	pocket:SetAttribute("FrameEpoch", 0)
	local crafts = Instance.new("Folder")
	crafts.Name = "Crafts"
	crafts.Parent = pocket
	return pocket
end

function PocketService.Init()
	local folder = Instance.new("Folder")
	folder.Name = "Pockets"
	folder.Parent = Workspace
	pocketsFolder = folder

	-- Base pocket: SURFACE_ALIGNED at a fixed surface point; pocket y = 0 is ground level.
	local home = Bodies.get(Bodies.HOMEWORLD)
	local up = Frames.surfaceUp(BASE_LATITUDE, BASE_LONGITUDE)
	local refPos = Vec3d.scale(up, home.Radius)
	local pocket = createPocketFolder(BASE_POCKET_ID, Vector3.zero)
	pocket:SetAttribute("FrameMode", "SURFACE_ALIGNED")
	pocket:SetAttribute("PrimaryKind", "Site")
	pocket:SetAttribute("PrimaryId", 0)
	pocket:SetAttribute("RefBodyId", home.Id)
	pocket:SetAttribute("RefX", refPos.x)
	pocket:SetAttribute("RefY", refPos.y)
	pocket:SetAttribute("RefZ", refPos.z)
	pocket:SetAttribute("RefRot", Frames.surfaceRotation(up))

	local site = HomeBase.build()
	site.Name = "Site"
	site.Parent = pocket

	local builds = Instance.new("Folder")
	builds.Name = "Builds"
	builds.Parent = pocket

	pocket.Parent = folder
	basePocket = pocket
	baseFrame = Frames.new(home.Id, refPos, Frames.surfaceRotation(up), Vector3.zero, 0)
end

-- The pocket (0 = base) whose slot contains a workspace position, or nil if it is in none.
function PocketService.pocketAt(position: Vector3): number?
	if position.Magnitude < SLOT_CAPTURE_RADIUS * 1.5 then
		return 0
	end
	for id, origin in slotOrigins do
		if (position - origin).Magnitude < SLOT_CAPTURE_RADIUS and flightPockets[id] then
			return id
		end
	end
	return nil
end

local function trackPlayers()
	local now = os.clock()
	local occupied: { [number]: boolean } = {}
	for _, player in Players:GetPlayers() do
		-- CHANGED (Phase 6): a player just transferred keeps the pocket the server gave them
		local pin = pins[player]
		if pin and now < pin.untilTime then
			occupied[pin.id] = true
			continue
		end
		pins[player] = nil
		local character = player.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if root and root:IsA("BasePart") then
			local id = PocketService.pocketAt(root.Position)
			if id then
				occupied[id] = true
				if player:GetAttribute("PocketId") ~= id then
					player:SetAttribute("PocketId", id)
				end
			end
		end
	end
	for id, pocket in flightPockets do
		if occupied[id] then
			pocket.emptySince = nil
		elseif pocket.emptySince == nil then
			pocket.emptySince = now
		elseif now - (pocket.emptySince :: number) > EMPTY_RELEASE_S then
			PocketService.releaseFlightPocket(id)
		end
	end
end

function PocketService.Start()
	task.spawn(function()
		while true do
			task.wait(TRACK_INTERVAL_S)
			trackPlayers()
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		pins[player] = nil -- CHANGED (Phase 6)
	end)
end

-- CHANGED (Phase 6): keeps `player` in pocket `id` (their PocketId) for PIN_S, whatever the replicated character
-- position says (it lags a PocketTransfer). FlightService.sendTransfer calls this for every transfer.
function PocketService.pin(player: Player, id: number)
	pins[player] = { id = id, untilTime = os.clock() + PIN_S }
end

-- CHANGED (Phase 6): is the player's PocketId still pinned by a recent transfer?
function PocketService.isPinned(player: Player): boolean
	local pin = pins[player]
	return pin ~= nil and os.clock() < pin.untilTime
end

-- CHANGED (Phase 6): the slot capture radius (studs) around a flight pocket's slot origin.
PocketService.SLOT_CAPTURE_RADIUS = SLOT_CAPTURE_RADIUS

-- The base pocket's frame (SURFACE_ALIGNED at the launch site).
function PocketService.baseFrame(): Frames.Frame
	assert(baseFrame, "PocketService.Init has not run")
	return baseFrame
end

--[[
	Creates a flight pocket for a crewed craft. CHANGED (Phase 2a feedback, D31): HORIZON_ALIGNED instead of
	CRAFT_ALIGNED: the reference point follows the craft, but the pocket axes are the local horizon frame
	(Y = away from the body centre), so Roblox's sky, sun and day/night are right and the craft turns inside it.
	`refRot` is that horizon rotation at creation (the pocket attributes RefX/RefY/RefZ/RefRot hold it until
	clients receive the craft's state stream).
	Returns nil when every slot is taken.
]]
function PocketService.createFlightPocket(craftId: number, bodyId: number, refPos: any, refRot: CFrame): FlightPocket?
	for id, origin in slotOrigins do
		if flightPockets[id] == nil then
			local folder = createPocketFolder(id, origin)
			folder:SetAttribute("FrameMode", "HORIZON_ALIGNED")
			folder:SetAttribute("PrimaryKind", "Craft")
			folder:SetAttribute("PrimaryId", craftId)
			folder:SetAttribute("RefBodyId", bodyId)
			folder:SetAttribute("RefX", refPos.x)
			folder:SetAttribute("RefY", refPos.y)
			folder:SetAttribute("RefZ", refPos.z)
			folder:SetAttribute("RefRot", Frames.rotationOnly(refRot))
			folder.Parent = PocketService.pockets()
			-- CHANGED (Phase 6): kind and creation order
			local pocket: FlightPocket = {
				id = id,
				folder = folder,
				slotOrigin = origin,
				kind = "Craft",
				craftId = craftId,
				userId = nil,
				ref = nil,
				order = nextOrder,
				emptySince = nil,
			}
			nextOrder += 1
			flightPockets[id] = pocket
			return pocket
		end
	end
	return nil
end

-- CHANGED (Phase 6): writes a solo reference into a pocket folder's attributes (clearing the craft-only velocity
-- fields is not needed: SURFACE_ALIGNED readers ignore them).
local function writeSoloAttributes(folder: Folder, userId: number, ref: PocketFrames.Reference)
	folder:SetAttribute("PrimaryKind", "Astronaut")
	folder:SetAttribute("PrimaryId", userId)
	for name, value in PocketFrames.toAttributes(ref) do
		folder:SetAttribute(name, value)
	end
end

local function bumpEpoch(pocket: FlightPocket): number
	local epoch = pocket.folder:GetAttribute("FrameEpoch")
	local nextEpoch = (if type(epoch) == "number" then epoch else 0) + 1
	pocket.folder:SetAttribute("FrameEpoch", nextEpoch)
	return nextEpoch
end

--[[
	CHANGED (Phase 6): creates a SOLO pocket for an astronaut on EVA (spec 7.5: "A solo EVA astronaut gets its own
	pocket"), its frame from `ref` (Shared/Sim/PocketFrames). Returns nil when every slot is taken.
]]
function PocketService.createSoloPocket(userId: number, ref: PocketFrames.Reference): FlightPocket?
	for id, origin in slotOrigins do
		if flightPockets[id] == nil then
			local folder = createPocketFolder(id, origin)
			writeSoloAttributes(folder, userId, ref)
			folder.Parent = PocketService.pockets()
			local pocket: FlightPocket = {
				id = id,
				folder = folder,
				slotOrigin = origin,
				kind = "Solo",
				craftId = nil,
				userId = userId,
				ref = ref,
				order = nextOrder,
				emptySince = nil,
			}
			nextOrder += 1
			flightPockets[id] = pocket
			return pocket
		end
	end
	return nil
end

--[[
	CHANGED (Phase 6): makes a craft the pocket's primary (HORIZON_ALIGNED; the RefX.. attributes hold its state now
	until clients get its stream). Returns the new frame epoch.
]]
function PocketService.setCraftPrimary(id: number, craftId: number, bodyId: number, refPos: any, refRot: CFrame): number
	local pocket = flightPockets[id]
	assert(pocket, "unknown flight pocket")
	pocket.kind = "Craft"
	pocket.craftId = craftId
	pocket.userId = nil
	pocket.ref = nil
	local folder = pocket.folder
	folder:SetAttribute("FrameMode", "HORIZON_ALIGNED")
	folder:SetAttribute("PrimaryKind", "Craft")
	folder:SetAttribute("PrimaryId", craftId)
	folder:SetAttribute("RefBodyId", bodyId)
	folder:SetAttribute("RefX", refPos.x)
	folder:SetAttribute("RefY", refPos.y)
	folder:SetAttribute("RefZ", refPos.z)
	folder:SetAttribute("RefRot", Frames.rotationOnly(refRot))
	return bumpEpoch(pocket)
end

-- CHANGED (Phase 6): makes an astronaut the pocket's primary with a solo reference. Returns the new frame epoch.
function PocketService.setSoloPrimary(id: number, userId: number, ref: PocketFrames.Reference): number
	local pocket = flightPockets[id]
	assert(pocket, "unknown flight pocket")
	pocket.kind = "Solo"
	pocket.craftId = nil
	pocket.userId = userId
	pocket.ref = ref
	writeSoloAttributes(pocket.folder, userId, ref)
	return bumpEpoch(pocket)
end

-- CHANGED (Phase 6): the frame epoch of a pocket (0 for the base).
function PocketService.frameEpoch(id: number): number
	local pocket = flightPockets[id]
	local epoch = if pocket then pocket.folder:GetAttribute("FrameEpoch") else 0
	return if type(epoch) == "number" then epoch else 0
end

--[[
	CHANGED (Phase 6): a Solo pocket's reference (bodyId, position, velocity) at ut, or nil for other pockets.
	FlightRelayService (interest distances) and RailsService (debris near occupied pockets) use it.
]]
function PocketService.soloReference(id: number, ut: number): (number?, Vec3d.Vec3d?, Vec3d.Vec3d?)
	local pocket = flightPockets[id]
	local ref = if pocket and pocket.kind == "Solo" then pocket.ref else nil
	if ref == nil then
		return nil, nil, nil
	end
	local pos, vel = PocketFrames.referenceAt(ref, ut)
	return ref.bodyId, pos, vel
end

-- CHANGED (Phase 6): every flight pocket by id (do not modify).
function PocketService.flightPockets(): { [number]: FlightPocket }
	return flightPockets
end

function PocketService.flightPocket(id: number): FlightPocket?
	return flightPockets[id]
end

function PocketService.releaseFlightPocket(id: number)
	local pocket = flightPockets[id]
	if pocket == nil then
		return
	end
	flightPockets[id] = nil
	for _, listener in releaseListeners do
		task.spawn(listener, pocket)
	end
	pocket.folder:Destroy()
end

-- Called (in its own thread) when a flight pocket is released, before its folder is destroyed.
function PocketService.onReleased(listener: (pocket: FlightPocket) -> ())
	table.insert(releaseListeners, listener)
end

-- Players whose characters are currently in a pocket.
function PocketService.playersIn(id: number): { Player }
	local result = {}
	for _, player in Players:GetPlayers() do
		if player:GetAttribute("PocketId") == id then
			table.insert(result, player)
		end
	end
	return result
end

function PocketService.basePocket(): Folder
	assert(basePocket, "PocketService.Init has not run")
	return basePocket
end

function PocketService.baseCrafts(): Folder
	return PocketService.basePocket():FindFirstChild("Crafts") :: Folder
end

function PocketService.baseBuilds(): Folder
	return PocketService.basePocket():FindFirstChild("Builds") :: Folder
end

function PocketService.baseSite(): Model
	return PocketService.basePocket():FindFirstChild("Site") :: Model
end

function PocketService.pockets(): Folder
	assert(pocketsFolder, "PocketService.Init has not run")
	return pocketsFolder
end

return PocketService
