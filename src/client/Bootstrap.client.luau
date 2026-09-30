--!strict
--[[
	Client bootstrap: waits for the server's Globals (UT anchors), then boots every controller in Controllers in
	a fixed order (Init all, then Start all). Add new controllers to BOOT_ORDER.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Initial replication must finish before shared modules are indexed directly.
if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Loader = require(ReplicatedStorage.Shared.Util.Loader)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)

--============================================================================
-- Tunables
--============================================================================
local BOOT_ORDER = {
	"DebugOverlay",
	"BuildController", -- CHANGED (Phase 1): hangar builder
}
--============================================================================

UniverseTime.waitForGlobals()
Loader.run("Client", script.Parent:WaitForChild("Controllers"), BOOT_ORDER)
