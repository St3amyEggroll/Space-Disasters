--!strict
--[[
	AdminController (new file, Solar system; D51)
	Opens the admin panel (UI/AdminPanel) for admins: F7 (fixed, like F3's debug overlay; F7 is free in every context)
	or the small ADMIN button in the Roblox top bar (touch friendly, beside Roblox's own buttons, so it never covers
	the builder or the flight HUD). Only players the server marked as admins (attribute IsAdmin, AdminService) see
	the button or can open the panel; the server re-checks every request anyway. Hidden while the main menu is up.

	The panel's Spawn sends the request with the AdminSpawn remote; the server answers with a Notify toast.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local AdminPanel = require(script.Parent.Parent.UI.AdminPanel)
local Kit = require(script.Parent.Parent.UI.Kit)
local Theme = require(script.Parent.Parent.UI.Theme)
local UIState = require(script.Parent.Parent.UI.UIState)

--============================================================================
-- Tunables
--============================================================================
local OPEN_KEY = Enum.KeyCode.F7
local ADMIN_ATTRIBUTE = "IsAdmin"
local BUTTON_TEXT = "ADMIN"
local BUTTON_WIDTH = 74 -- px (the top bar is not scaled by the UI size setting)
local BUTTON_GAP = 8 -- px from Roblox's own top-bar buttons
local BUTTON_MARGIN = 4 -- px above and below inside the top bar
local FALLBACK_TOPBAR = Rect.new(110, 0, 400, 44) -- px, when the engine reports no top-bar inset
--============================================================================

local AdminController = {}

local player = Players.LocalPlayer
local button: TextButton? = nil
local spawnRemote: RemoteEvent? = nil

local function isAdmin(): boolean
	return player:GetAttribute(ADMIN_ATTRIBUTE) == true
end

local function sendSpawn(request: AdminPanel.Request)
	local remote = spawnRemote or Remotes.event("AdminSpawn")
	spawnRemote = remote
	remote:FireServer({
		bodyId = request.bodyId,
		mode = request.mode,
		altitudeKm = request.altitudeKm,
		spot = request.spot,
	})
	Kit.toast("Spawning your ship...", "Info")
end

local function toggle()
	if AdminPanel.isOpen() then
		AdminPanel.close()
		return
	end
	-- not over the main menu, the settings or a dialog
	if not isAdmin() or UIState.isMenuOpen() or UIState.isModalOpen() then
		return
	end
	AdminPanel.open(sendSpawn)
end

local function placeButton()
	local b = button
	if b == nil then
		return
	end
	local inset = GuiService.TopbarInset
	if inset.Height <= 0 then
		inset = FALLBACK_TOPBAR
	end
	local height = math.max(inset.Height - 2 * BUTTON_MARGIN, 20)
	b.Size = UDim2.fromOffset(BUTTON_WIDTH, height)
	b.Position = UDim2.fromOffset(inset.Min.X + BUTTON_GAP, inset.Min.Y + (inset.Height - height) / 2)
end

local function refreshButton()
	local b = button
	if b then
		b.Visible = isAdmin() and not UIState.isMenuOpen()
	end
end

local function buildButton()
	local screen = Instance.new("ScreenGui")
	screen.Name = "AdminButton"
	screen.ResetOnSpawn = false
	screen.IgnoreGuiInset = true -- positions are screen pixels, like GuiService.TopbarInset
	screen.DisplayOrder = Theme.DisplayOrder.HUD
	screen.Parent = player:WaitForChild("PlayerGui")
	local created = Kit.button(screen, BUTTON_TEXT, toggle, {
		name = "Admin",
		style = "Accent",
		size = UDim2.fromOffset(BUTTON_WIDTH, 32),
		textSize = Theme.TextSizes.Small,
	})
	created.Visible = false
	button = created
	placeButton()
	refreshButton()
end

function AdminController.Init() end

function AdminController.Start()
	buildButton()
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(placeButton)
	player:GetAttributeChangedSignal(ADMIN_ATTRIBUTE):Connect(function()
		refreshButton()
		if not isAdmin() then
			AdminPanel.close()
		end
	end)
	UIState.onMenuChanged(function(open: boolean)
		refreshButton()
		if open then
			AdminPanel.close()
		end
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, _processed: boolean)
		-- F7 is not a Roblox key; the pilot's action binding does not take it, so it arrives unprocessed or not
		if input.KeyCode == OPEN_KEY then
			toggle()
		end
	end)
end

return AdminController
