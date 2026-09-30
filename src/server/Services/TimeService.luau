--!strict
--[[
	TimeService
	Owns Universal Time. Creates ReplicatedStorage.Globals and writes the UT anchors that UniverseTime reads on
	every machine. Phases 2-6 keep the warp rate fixed at 1; Phase 7 adds votes on top of SetWarpRate.

	Every rate change re-anchors: utAnchor = current UT, serverTimeAnchor = now.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)

--============================================================================
-- Tunables
--============================================================================
local START_UT = 0 -- UT when the server starts (the Moon is at phase 0 at UT 0)
--============================================================================

local TimeService = {}

local globals: Folder? = nil

local function isAllowedRate(rate: number): boolean
	for _, allowed in GameConfig.WARP_RATES do
		if allowed == rate then
			return true
		end
	end
	return false
end

local function writeAnchors(utAnchor: number, rate: number)
	local folder = globals
	assert(folder, "TimeService.Init has not run")
	folder:SetAttribute(
		UniverseTime.ANCHORS_ATTRIBUTE,
		UniverseTime.encode({
			utAnchor = utAnchor,
			serverTimeAnchor = Workspace:GetServerTimeNow(),
			warpRate = rate,
		})
	)
end

function TimeService.Init()
	local folder = Instance.new("Folder")
	folder.Name = UniverseTime.GLOBALS_NAME
	globals = folder
	writeAnchors(START_UT, 1)
	folder.Parent = ReplicatedStorage
	UniverseTime.bind(folder)
end

function TimeService.Start() end

-- Current UT (convenience; identical to UniverseTime.now()).
function TimeService.now(): number
	return UniverseTime.now()
end

-- Sets the warp rate (must be one of GameConfig.WARP_RATES) and re-anchors. Returns false if the rate is invalid.
function TimeService.SetWarpRate(rate: number): boolean
	if not isAllowedRate(rate) then
		return false
	end
	if rate == UniverseTime.warpRate() then
		return true
	end
	writeAnchors(UniverseTime.now(), rate)
	return true
end

return TimeService
