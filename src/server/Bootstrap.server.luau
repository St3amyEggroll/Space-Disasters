--!strict
--[[
	Server bootstrap: boots every service in Services in a fixed order (Init all, then Start all).
	Add new services to BOOT_ORDER; the Loader warns about any module missing from it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Shared.Util.Loader)

--============================================================================
-- Tunables
--============================================================================
local BOOT_ORDER = {
	"TimeService", -- first: everything else reads UT
	"PocketService", -- CHANGED (Phase 1): base pocket + site must exist before plots and builds
	"PlotService",
	"SaveService",
	"BuildService", -- creates the remotes (Remotes.createAll) in Init
	"CraftService",
	"CrewService",
	"FlightService", -- CHANGED (Phase 2a): launch, staging, pilot states, crashes
	"ServerSimService",
	"FlightRelayService",
	"DebugService",
}
--============================================================================

Loader.run("Server", script.Parent.Services, BOOT_ORDER)
