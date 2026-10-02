--!strict
--[[
	MainMenuController (Phase 11)
	The main menu: what the player sees on joining, and again when the builder asks for it (UIState.requestMenu).
	The screen is UI/MainMenu (logo, Play / Settings / Credits / Updates, version, creator), the background is the
	live space scene Render/MenuScene (the avatar floating above Earth, junk, a satellite, shooting stars, glare).

	Flow:
	  Init    UIState.setMenuOpen(true), so every other UI starts hidden and gameplay ignores input (BuildController
	          boots earlier, but its Start runs after every Init).
	  Start   builds the screen (black cover) and opens: takes the camera (MenuScene), hides the Backpack / Health /
	          PlayerList core GUIs (their previous state is restored on close), fades in from black. CHANGED (Phase 11
	          review): the character's controls follow UIState (UI/CharacterControls, started in Init), so they are
	          off while the menu (or any dialog) is open. If building or opening the menu fails, the menu is
	          abandoned (scene stopped, core GUIs back, UIState menu closed) so the game stays playable without it;
	          a failing scene still shows the menu over a plain background.
	  Play    instant: the menu content and the scene fade to black (CLOSE_FADE_S), the camera goes back to the
	          character (CameraType Custom, CameraSubject = the Humanoid), controls and core GUIs come back,
	          UIState.setMenuOpen(false), the scene is parked, and the black fades away (REVEAL_FADE_S). The player is
	          already at their plot (the server spawns them there). CHANGED (Terrain polish): the black first waits
	          (TERRAIN_WAIT_S at most) until the ground around the base is drawn as meshes (Surface.isReady), so the
	          game never opens on the blocky placeholder plates.
	          CHANGED (Review 3): the menu stays open in UIState (controls off, the other UIs hidden) until the black
	          starts to fade (the player walked blind while it waited), and the cover says "Preparing launch
	          site..." once the wait takes longer than PREPARING_DELAY_S.
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

local CharacterControls = require(script.Parent.Parent.UI.CharacterControls) -- CHANGED (Phase 11 review)
local FlightController = require(script.Parent.FlightController)
local MainMenu = require(script.Parent.Parent.UI.MainMenu)
local MainMenuCredits = require(script.Parent.Parent.UI.MainMenuCredits)
local MapViewController = require(script.Parent.MapViewController)
local MenuScene = require(script.Parent.Parent.Render.MenuScene)
local Kit = require(script.Parent.Parent.UI.Kit)
local PocketController = require(script.Parent.PocketController)
local SettingsPanel = require(script.Parent.Parent.UI.SettingsPanel)
local Surface = require(script.Parent.Parent.Render.Surface) -- CHANGED (Terrain polish)
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
-- CHANGED (Review 3): the status line while Play waits for the base's ground (TERRAIN_WAIT_S at most)
local PREPARING_TEXT = "Preparing launch site..."
local PREPARING_DELAY_S = 0.3 -- shown only when the wait is longer than this
-- CHANGED (Terrain polish): the black stays until the ground around the base is drawn as meshes (no blocky plates
-- first), at most this long
local TERRAIN_WAIT_S = 6
local CONTENT_FADE_S = Theme.Tween.Fade
local PLAY_KEYS = { Enum.KeyCode.Return, Enum.KeyCode.KeypadEnter }
local HIDDEN_CORE_GUIS = { Enum.CoreGuiType.Backpack, Enum.CoreGuiType.Health, Enum.CoreGuiType.PlayerList }
local BUSY_TOAST = "The menu is not available during a flight."
local BASE_POCKET_ID = 0
--============================================================================

type State = "Closed" | "Opening" | "Open" | "Closing"

local MainMenuController = {}

local player = Players.LocalPlayer
local state: State = "Closed"
local view: MainMenu.View? = nil
local savedCoreGuis: { [Enum.CoreGuiType]: boolean } = {}

-- State test through a typed parameter (comparing the refined local directly confuses the old solver).
local function is(wanted: State): boolean
	return state == wanted
end

--============================================================================
-- Core GUIs
-- CHANGED (Phase 11 review): the character controls moved to UI/CharacterControls (they follow UIState now, so
-- dialogs outside the menu block them too, and a respawn while Play fades cannot leave them off)
--============================================================================

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
	-- CHANGED (Phase 11 review): a failing scene still shows the menu (over a plain background)
	local ok, err = pcall(function()
		MenuScene.start(v.flareLayer)
	end)
	if not ok then
		warn(`[MainMenuController] the menu scene failed to start: {err}`)
	end
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
	UIState.setMenuOpen(true) -- CHANGED (Phase 11 review): also switches the character controls off
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

-- CHANGED (Phase 11 review): the menu failed to build or open: drop it so the game stays playable without it.
local function abandonMenu(err: unknown)
	warn(`[MainMenuController] the main menu failed; playing without it: {err}`)
	pcall(MenuScene.stop)
	restoreCoreGuis()
	state = "Closed"
	local v = view
	if v then
		pcall(v.setEnabled, false)
	end
	UIState.setMenuOpen(false)
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
		-- camera back to the character, scene parked
		-- CHANGED (Phase 11 review): protected, so a failing stop cannot keep the game blocked
		local ok, err = pcall(function()
			MenuScene.stop()
		end)
		if not ok then
			warn(`[MainMenuController] the menu scene failed to stop: {err}`)
		end
		restoreCoreGuis()
		-- CHANGED (Terrain polish): stay black until the base's ground meshes are on screen (TERRAIN_WAIT_S at most)
		task.spawn(function()
			local started = os.clock()
			local hinted = false
			repeat
				task.wait()
				-- CHANGED (Review 3): say why it stays black
				if not hinted and os.clock() - started >= PREPARING_DELAY_S then
					hinted = true
					v.setStatus(PREPARING_TEXT)
				end
				-- CHANGED (Review 3): protected: a failing check must not leave the player behind a black screen
				local checked, ready = pcall(Surface.isReady)
			until not is("Closing") or os.clock() - started >= TERRAIN_WAIT_S or not checked or ready
			v.setStatus(nil)
			if not is("Closing") then
				return
			end
			-- CHANGED (Review 3): moved here from before the wait (the controls were on behind the black)
			UIState.setMenuOpen(false) -- CHANGED (Phase 11 review): also switches the character controls back on
			v.fadeCover(0, REVEAL_FADE_S, function()
				if is("Closing") then
					state = "Closed"
					v.setEnabled(false)
				end
			end)
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
	CharacterControls.start() -- CHANGED (Phase 11 review): character controls off while menus / dialogs are open
	-- every other UI starts hidden and gameplay ignores input until Play
	UIState.setMenuOpen(true)
	UIState.onMenuRequested(function()
		if is("Closed") then
			MainMenuController.open()
		end
	end)
end

function MainMenuController.Start()
	-- CHANGED (Phase 11 review): building / opening the menu is protected (see the header)
	local built, err = pcall(function()
		view = MainMenu.build({
			play = MainMenuController.play,
			settings = MainMenuController.openSettings,
			credits = MainMenuController.openCredits,
		})
	end)
	if not built then
		abandonMenu(err)
		return
	end
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or not is("Open") or UIState.isModalOpen() then
			return
		end
		if table.find(PLAY_KEYS, input.KeyCode) then
			MainMenuController.play()
		end
	end)
	-- Init already set the menu state open (before the screen existed); show it now
	-- CHANGED (Phase 11 review): the respawn handling moved to UI/CharacterControls; opening is protected
	local opened, openErr = pcall(function()
		openMenu(true)
	end)
	if not opened then
		abandonMenu(openErr)
	end
end

return MainMenuController
