--!strict
--[[
	CharacterControls (Phase 11 review)
	The character's own controls (the PlayerModule's ControlModule: walking, jumping, the touch thumbstick) follow
	UIState: off while UIState.isInputBlocked() (the main menu or any modal dialog: settings, credits, the slot picker,
	Kit.confirm) and back on when nothing blocks input any more. UIState alone only reaches this game's own input
	code; without this the default character actions (W/A/S/D walk, Space jump) still ran behind a dialog, e.g. a
	seated passenger pressing Space in the settings' key capture jumped out of the seat mid-flight.

	The ControlModule may not exist yet when input first gets blocked (the main menu opens in its Init): a failed
	switch is retried every RETRY_S until it works or is no longer wanted. A respawn while blocked switches the new
	character's controls off again. (Moved here from MainMenuController, which only did this for the menu.)

	API:
	  CharacterControls.start()        follow UIState from now on (idempotent; MainMenuController.Init calls it)
	  CharacterControls.isDisabled() -> boolean   this module has the controls switched off
]]

local Players = game:GetService("Players")

local UIState = require(script.Parent.UIState)

--============================================================================
-- Tunables
--============================================================================
local RETRY_S = 0.5 -- retry a failed switch (the PlayerModule not loaded yet) this often
--============================================================================

local CharacterControls = {}

local player = Players.LocalPlayer
local started = false
local disabled = false -- the ControlModule is switched off by this module
local retryPending = false
local stale = false -- a respawn while switched off: switch again even if `disabled` already matches

-- The PlayerModule's ControlModule (nil until the player scripts exist; never yields).
local function controls(): any
	local playerScripts = player:FindFirstChildOfClass("PlayerScripts")
	local module = if playerScripts then playerScripts:FindFirstChild("PlayerModule") else nil
	if module == nil or not module:IsA("ModuleScript") then
		return nil
	end
	local ok, playerModule = pcall(require, module)
	if not ok or type(playerModule) ~= "table" then
		return nil
	end
	local getControls = (playerModule :: any).GetControls
	if type(getControls) ~= "function" then
		return nil
	end
	local gotten, result = pcall(getControls, playerModule)
	return if gotten then result else nil
end

-- Brings the ControlModule in line with UIState (retrying while the PlayerModule is missing).
local function apply()
	local wantDisabled = UIState.isInputBlocked()
	if wantDisabled == disabled and not stale then
		return
	end
	local control = controls()
	local ok = control ~= nil
		and pcall(function()
			if wantDisabled then
				control:Disable()
			else
				control:Enable()
			end
		end)
	if ok then
		disabled = wantDisabled
		stale = false
	elseif not retryPending then
		retryPending = true
		task.delay(RETRY_S, function()
			retryPending = false
			apply()
		end)
	end
end

function CharacterControls.start()
	if started then
		return
	end
	started = true
	UIState.onInputBlockedChanged(function()
		apply()
	end)
	-- a respawn while switched off: switch the new character's controls again (off, or on if nothing blocks now)
	player.CharacterAdded:Connect(function()
		if disabled then
			stale = true
			task.defer(apply)
		end
	end)
	apply()
end

function CharacterControls.isDisabled(): boolean
	return disabled
end

return table.freeze(CharacterControls)
