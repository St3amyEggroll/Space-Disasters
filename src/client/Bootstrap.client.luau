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
	"SettingsController", -- CHANGED (Phase 11): loads / saves settings, sound groups (before anything reads them)
	"BuildController", -- CHANGED (Phase 1): hangar builder
	"RemoteCraftRenderer", -- CHANGED (Phase 2a): flight rendering and control
	"RailsController", -- CHANGED (Phase 5): other crafts' rails and their SOI changes
	"PocketController",
	"FlightController",
	"UniverseRenderer",
	"MapViewController", -- CHANGED (Phase 5): map view (M)
	"EvaController", -- CHANGED (Phase 6): spacewalks (jetpack, walking on the Mun, the EVA HUD)
	"MainMenuController", -- CHANGED (Phase 11): main menu and its space scene (last: opens over everything)
}
--============================================================================

UniverseTime.waitForGlobals()
Loader.run("Client", script.Parent:WaitForChild("Controllers"), BOOT_ORDER)
