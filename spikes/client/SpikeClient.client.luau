--!strict
--[[
	SpikeClient
	Shows the spike menu and runs a spike's client part when the server starts it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpikeKit = require(ReplicatedStorage:WaitForChild("SpikeShared"):WaitForChild("SpikeKit"))

--============================================================================
-- Tunables
--============================================================================
local MENU_WIDTH = 460
local ROW_HEIGHT = 34
local BG = Color3.fromRGB(20, 22, 30)
local ACCENT = Color3.fromRGB(255, 140, 40)
local TEXT = Color3.fromRGB(235, 235, 240)
local FONT = Enum.Font.GothamMedium
--============================================================================

local player = Players.LocalPlayer
local control = SpikeKit.clientRemote(SpikeKit.CONTROL_NAME)
local defs = SpikeKit.all()

local gui = Instance.new("ScreenGui")
gui.Name = "SpikeMenu"
gui.ResetOnSpawn = false
gui.DisplayOrder = 50
gui.Parent = player:WaitForChild("PlayerGui")

local toggle = Instance.new("TextButton")
toggle.AnchorPoint = Vector2.new(1, 0)
toggle.Position = UDim2.new(1, -12, 0, 12)
toggle.Size = UDim2.new(0, 140, 0, 32)
toggle.BackgroundColor3 = ACCENT
toggle.Font = FONT
toggle.TextSize = 16
toggle.Text = "Spike menu"
toggle.Parent = gui

local menu = Instance.new("Frame")
menu.AnchorPoint = Vector2.new(1, 0)
menu.Position = UDim2.new(1, -12, 0, 52)
menu.Size = UDim2.new(0, MENU_WIDTH, 0, 0)
menu.AutomaticSize = Enum.AutomaticSize.Y
menu.BackgroundColor3 = BG
menu.BackgroundTransparency = 0.1
menu.Parent = gui

local padding = Instance.new("UIPadding")
padding.PaddingTop = UDim.new(0, 8)
padding.PaddingBottom = UDim.new(0, 8)
padding.PaddingLeft = UDim.new(0, 8)
padding.PaddingRight = UDim.new(0, 8)
padding.Parent = menu

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = menu

local info = Instance.new("TextLabel")
info.LayoutOrder = 1000
info.BackgroundTransparency = 1
info.Size = UDim2.new(1, 0, 0, 0)
info.AutomaticSize = Enum.AutomaticSize.Y
info.TextWrapped = true
info.Font = FONT
info.TextSize = 14
info.TextColor3 = TEXT
info.TextXAlignment = Enum.TextXAlignment.Left
info.Text = "Hover a spike to see its instructions. Results print in the SERVER Output with [SPIKE ...]."
info.Parent = menu

for index, def in defs do
	local button = Instance.new("TextButton")
	button.LayoutOrder = index
	button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	button.BackgroundColor3 = Color3.fromRGB(40, 44, 58)
	button.TextColor3 = TEXT
	button.Font = FONT
	button.TextSize = 15
	button.TextXAlignment = Enum.TextXAlignment.Left
	local playersNote = if def.Players > 1 then `  [needs {def.Players} players]` else ""
	button.Text = `  {def.Id}  {def.Title}{playersNote}`
	button.Parent = menu
	button.MouseEnter:Connect(function()
		info.Text = `{def.Id}: {def.Instructions}`
	end)
	button.Activated:Connect(function()
		if def.Players > #Players:GetPlayers() then
			info.Text =
				`{def.Id} needs {def.Players} players. Use Test > Clients and Servers with {def.Players} players.`
			return
		end
		info.Text = `{def.Id}: {def.Instructions}`
		control:FireServer("start", def.Id)
	end)
end

toggle.Activated:Connect(function()
	menu.Visible = not menu.Visible
end)

control.OnClientEvent:Connect(function(action: unknown, id: unknown)
	if action ~= "start" or type(id) ~= "string" then
		return
	end
	local def = SpikeKit.find(id)
	if def == nil then
		return
	end
	menu.Visible = false
	local client = def.Client
	if client then
		task.spawn(function()
			local ctx = SpikeKit.clientContext(id, player)
			local ok, err = xpcall(function()
				client(ctx)
			end, debug.traceback)
			if not ok then
				ctx.report("CLIENT ERROR: " .. tostring(err))
				warn(err)
			end
			ctx.report("client part done")
			ctx.status("")
			menu.Visible = true
		end)
	end
end)
