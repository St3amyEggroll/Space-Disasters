--!strict
--[[
	MainMenuController (Phase 11)
	The main menu: what the player sees on joining, and again when the builder asks for it (UIState.requestMenu).
	The screen is UI/MainMenu (logo, Play / Settings / Credits / Updates, version, creator), the background is the
	live space scene Render/MenuScene (the avatar floating above Earth, junk, a satellite, shooting stars, glare).

	Flow:
	  Init    UIState.setMenuOpen(true), so every other UI starts hidden and gameplay ignores input (BuildController
	          boots earlier, but its Start runs after every Init).
	  Start   builds the screen (black cover) and opens: takes the camera (MenuScene), disables the character's
	          controls (PlayerModule), hides the Backpack / Health / PlayerList core GUIs (their previous state is
	          restored on close), fades in from black.
	  Play    instant: the menu content and the scene fade to black (CLOSE_FADE_S), the camera goes back to the
	          character (CameraType Custom, CameraSubject = the Humanoid), controls and core GUIs come back,
	          UIState.setMenuOpen(false), the scene is parked, and the black fades away (REVEAL_FADE_S). The player is
	          already at their plot (the server spawns them there).
	  Reopen  UIState.onMenuRequested (the builder's Menu button): ignored (with a toast) while the local character
	          sits in a seat, a flight is active (piloting, a flight pocket) or the map view is open.
	Keys: Enter = Play while the menu shows and no dialog is open. Settings opens UI/SettingsPanel; Credits /
	Updates opens UI/MainMenuCredits. Every action is a named function (touch buttons can call them later).

	API:
	  MainMenuController.open()            show the menu (no-op while open / during a flight)
	  MainMenuController.play()            close it and play
	  MainMenuController.openSettings()
	  MainMenuController.openCredits()
	  MainMenuController.isOpen() -> boolean   true from open() until play() has finished fading
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local FlightController = require(script.Parent.FlightController)
local MainMenu = require(script.Parent.Parent.UI.MainMenu)
local MainMenuCredits = require(script.Parent.Parent.UI.MainMenuCredits)
local MapViewController = require(script.Parent.MapViewController)
local MenuScene = require(script.Parent.Parent.Render.MenuScene)
local Kit = require(script.Parent.Parent.UI.Kit)
local PocketController = require(script.Parent.PocketController)
local SettingsPanel = require(script.Parent.Parent.UI.SettingsPanel)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIState = require(script.Parent.Parent.UI.UIState)

--============================================================================
-- Tunables
--============================================================================
local FIRST_FADE_IN_S = 1.4 -- from black when the game starts
local REOPEN_FADE_OUT_S = 0.3 -- to black before the scene appears on a reopen
local REOPEN_FADE_IN_S = 0.6
local CLOSE_FADE_S = 0.3 -- Play: to black ...
local REVEAL_FADE_S = 0.35 -- ... then from black at the plot (about 0.6 s in all)
local CONTENT_FADE_S = Theme.Tween.Fade
local PLAY_KEYS = { Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter }
local HIDDEN_CORE_GUIS = { Enum.CoreGuiType.Backpack, Enum.CoreGuiType.Health, Enum.CoreGuiType.PlayerList }
local BUSY_TOAST = "The menu is not available during a flight."
local BASE_POCKET_ID = 0
local CONTROLS_RETRY_S = 0.5 -- retry disabling the character controls until the PlayerModule exists
--============================================================================

type State = "Closed" | "Opening" | "Open" | "Closing"

local MainMenuController = {}

local player = Players.LocalPlayer
local state: State = "Closed"
local view: MainMenu.View? = nil
local savedCoreGuis: { [Enum.CoreGuiType]: boolean } = {}
local controlsDisabled = false

-- State test through a typed parameter (comparing the refined local directly confuses the old solver).
local function is(wanted: State): boolean
	return state == wanted
end

--============================================================================
-- Character controls and core GUIs
--============================================================================

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

local function setControlsEnabled(enabled: boolean)
	if enabled == not controlsDisabled then
		return
	end
	local control = controls()
	local ok = control ~= nil
		and pcall(function()
			if enabled then
				control:Enable()
			else
				control:Disable()
			end
		end)
	if ok then
		controlsDisabled = not enabled
	elseif not enabled then
		-- the PlayerModule may not have loaded yet: try again while the menu is still showing
		task.delay(CONTROLS_RETRY_S, function()
			if is("Opening") or is("Open") then
				setControlsEnabled(false)
			end
		end)
	end
end

local function hideCoreGuis()
	for _, guiType in HIDDEN_CORE_GUIS do
		if savedCoreGuis[guiType] == nil then
			local ok, enabled = pcall(function(): boolean
				return StarterGui:GetCoreGuiEnabled(guiType)
			end)
			savedCoreGuis[guiType] = if ok then enabled else true
		end
		pcall(function()
			StarterGui:SetCoreGuiEnabled(guiType, false)
		end)
	end
end

local function restoreCoreGuis()
	for guiType, enabled in savedCoreGuis do
		pcall(function()
			StarterGui:SetCoreGuiEnabled(guiType, enabled)
		end)
	end
	table.clear(savedCoreGuis)
end

--============================================================================
-- Opening and closing
--============================================================================

-- Seated, piloting, in a flight pocket or mapping: the menu stays shut.
local function isBusy(): boolean
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if humanoid and humanoid.SeatPart ~= nil then
		return true
	end
	if FlightController.simulatedCraft() ~= nil then
		return true
	end
	return PocketController.pocketId() ~= BASE_POCKET_ID or MapViewController.isOpen()
end

local function closeDialogs()
	if SettingsPanel.isOpen() then
		SettingsPanel.close()
	end
	if MainMenuCredits.isOpen() then
		MainMenuCredits.close()
	end
end

-- Shows the scene and the menu behind the (already black) cover, then fades the cover away.
local function reveal(v: MainMenu.View, fadeIn: number)
	MenuScene.start(v.flareLayer)
	v.setButtonsEnabled(true)
	v.fadeContent(true, CONTENT_FADE_S)
	v.fadeCover(0, fadeIn, function()
		if is("Opening") then
			state = "Open"
		end
	end)
end

local function openMenu(first: boolean)
	local v = view
	if v == nil or not is("Closed") then
		return
	end
	state = "Opening"
	UIState.setMenuOpen(true)
	setControlsEnabled(false)
	hideCoreGuis()
	v.setEnabled(true)
	v.setButtonsEnabled(false)
	if first then
		v.fadeCover(1, 0)
		reveal(v, FIRST_FADE_IN_S)
	else
		v.fadeCover(1, REOPEN_FADE_OUT_S, function()
			if is("Opening") then
				reveal(v, REOPEN_FADE_IN_S)
			end
		end)
	end
end

function MainMenuController.open()
	if isBusy() then
		Kit.toast(BUSY_TOAST, "Warning")
		return
	end
	openMenu(false)
end

function MainMenuController.play()
	local v = view
	if v == nil or (not is("Open") and not is("Opening")) then
		return
	end
	state = "Closing"
	closeDialogs()
	v.setButtonsEnabled(false)
	v.fadeContent(false, CLOSE_FADE_S)
	v.fadeCover(1, CLOSE_FADE_S, function()
		if not is("Closing") then
			return
		end
		MenuScene.stop() -- camera back to the character, scene parked
		setControlsEnabled(true)
		restoreCoreGuis()
		UIState.setMenuOpen(false)
		v.fadeCover(0, REVEAL_FADE_S, function()
			if is("Closing") then
				state = "Closed"
				v.setEnabled(false)
			end
		end)
	end)
end

function MainMenuController.openSettings()
	if is("Open") or is("Opening") then
		SettingsPanel.open()
	end
end

function MainMenuController.openCredits()
	if is("Open") or is("Opening") then
		MainMenuCredits.open()
	end
end

function MainMenuController.isOpen(): boolean
	return not is("Closed")
end

--============================================================================
-- Lifecycle
--============================================================================

function MainMenuController.Init()
	-- every other UI starts hidden and gameplay ignores input until Play
	UIState.setMenuOpen(true)
	UIState.onMenuRequested(function()
		if is("Closed") then
			MainMenuController.open()
		end
	end)
end

function MainMenuController.Start()
	local v = MainMenu.build({
		play = MainMenuController.play,
		settings = MainMenuController.openSettings,
		credits = MainMenuController.openCredits,
	})
	view = v
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or not is("Open") or UIState.isModalOpen() then
			return
		end
		if table.find(PLAY_KEYS, input.KeyCode) then
			MainMenuController.play()
		end
	end)
	-- respawns while the menu shows: keep the new character's controls off
	player.CharacterAdded:Connect(function()
		if not is("Closed") then
			controlsDisabled = false
			task.defer(setControlsEnabled, false)
		end
	end)
	-- Init already set the menu state open (before the screen existed); show it now
	openMenu(true)
end

return MainMenuController
