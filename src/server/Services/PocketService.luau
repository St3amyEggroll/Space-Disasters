--!strict
--[[
	PocketService
	Owns Workspace.Pockets. Phase 1 creates the permanent base pocket (slot 0): a SURFACE_ALIGNED pocket at the
	launch site on Homeworld's equator (lat 0, lon 0), holding the HomeBase site, the hangar builds and the
	rolled-out crafts. Flight pockets, transfers and rebases arrive in Phase 2.

	Pocket folder layout (spec 6.4):
	  Workspace.Pockets.Pocket_<id>            Folder with attributes PocketId, SlotOrigin, FrameMode, PrimaryKind,
	                                           PrimaryId, RefBodyId, FrameEpoch, RefX/RefY/RefZ, RefRot
	    Crafts                                 real craft models
	    Site                                   (base only) the HomeBase site model
	    Builds                                 (base only) Plot_<i> folders with hangar block models
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local HomeBase = require(ReplicatedStorage.Shared.Sites.HomeBase)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

--============================================================================
-- Tunables
--============================================================================
local BASE_POCKET_ID = 0
local BASE_LATITUDE = 0 -- rad
local BASE_LONGITUDE = 0 -- rad
--============================================================================

local PocketService = {}

PocketService.BASE_POCKET_ID = BASE_POCKET_ID

local pocketsFolder: Folder? = nil
local basePocket: Folder? = nil

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
end

function PocketService.Start() end

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
