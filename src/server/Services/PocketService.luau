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
	    Crafts                                 real craft models
	    Site                                   (base only) the HomeBase site model
	    Builds                                 (base only) Plot_<i> folders with hangar block models
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local HomeBase = require(ReplicatedStorage.Shared.Sites.HomeBase)
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
--============================================================================

export type FlightPocket = {
	id: number,
	folder: Folder,
	slotOrigin: Vector3,
	craftId: number,
	emptySince: number?,
}

local PocketService = {}

PocketService.BASE_POCKET_ID = BASE_POCKET_ID

local pocketsFolder: Folder? = nil
local basePocket: Folder? = nil
local baseFrame: Frames.Frame? = nil
local flightPockets: { [number]: FlightPocket } = {}
local releaseListeners: { (pocket: FlightPocket) -> () } = {}

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
end

-- The base pocket's frame (SURFACE_ALIGNED at the launch site).
function PocketService.baseFrame(): Frames.Frame
	assert(baseFrame, "PocketService.Init has not run")
	return baseFrame
end

--[[
	Creates a CRAFT_ALIGNED pocket for a crewed craft. The reference is the craft's root state at creation (the
	pocket attributes RefX/RefY/RefZ/RefRot hold it until clients receive the craft's state stream).
	Returns nil when every slot is taken.
]]
function PocketService.createFlightPocket(craftId: number, bodyId: number, refPos: any, refRot: CFrame): FlightPocket?
	for id, origin in slotOrigins do
		if flightPockets[id] == nil then
			local folder = createPocketFolder(id, origin)
			folder:SetAttribute("FrameMode", "CRAFT_ALIGNED")
			folder:SetAttribute("PrimaryKind", "Craft")
			folder:SetAttribute("PrimaryId", craftId)
			folder:SetAttribute("RefBodyId", bodyId)
			folder:SetAttribute("RefX", refPos.x)
			folder:SetAttribute("RefY", refPos.y)
			folder:SetAttribute("RefZ", refPos.z)
			folder:SetAttribute("RefRot", Frames.rotationOnly(refRot))
			folder.Parent = PocketService.pockets()
			local pocket: FlightPocket =
				{ id = id, folder = folder, slotOrigin = origin, craftId = craftId, emptySince = nil }
			flightPockets[id] = pocket
			return pocket
		end
	end
	return nil
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
