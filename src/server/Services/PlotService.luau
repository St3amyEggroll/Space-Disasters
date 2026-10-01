--!strict
--[[
	PlotService
	Assigns a hangar plot (and its launch pad) to each player on join and frees it on leave.
	Plot index is exposed as the player attribute "PlotIndex"; the plot sign shows the owner's name.
	Other services subscribe to onAssigned / onFreed.
	CHANGED (Phase 2a feedback): players spawn (and respawn) standing on their own plot.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local PocketService = require(script.Parent.PocketService)

--============================================================================
-- Tunables
--============================================================================
local PLOT_ATTRIBUTE = "PlotIndex"
local SPAWN_ROOT_TIMEOUT_S = 10 -- s to wait for a new character's HumanoidRootPart
--============================================================================

type Listener = (player: Player, plotIndex: number) -> ()

local PlotService = {}

PlotService.PLOT_ATTRIBUTE = PLOT_ATTRIBUTE

local ownerByPlot: { [number]: Player } = {}
local plotByPlayer: { [Player]: number } = {}
local assignedListeners: { Listener } = {}
local freedListeners: { Listener } = {}

local function plotModel(index: number): Model?
	local plots = PocketService.baseSite():FindFirstChild("Plots")
	local model = if plots then plots:FindFirstChild(`Plot_{index}`) else nil
	if model and model:IsA("Model") then
		return model
	end
	return nil
end

local function setSign(index: number, text: string)
	local model = plotModel(index)
	local sign = if model then model:FindFirstChild("Sign") else nil
	local gui = if sign then sign:FindFirstChild("SignGui") else nil
	local label = if gui then gui:FindFirstChild("Owner") else nil
	if label and label:IsA("TextLabel") then
		label.Text = text
	end
end

local function fire(listeners: { Listener }, player: Player, index: number)
	for _, listener in listeners do
		task.spawn(listener, player, index)
	end
end

local function assign(player: Player)
	if plotByPlayer[player] then
		return
	end
	for index = 1, BaseLayout.PLOT_COUNT do
		if not ownerByPlot[index] then
			ownerByPlot[index] = player
			plotByPlayer[player] = index
			player:SetAttribute(PLOT_ATTRIBUTE, index)
			local model = plotModel(index)
			if model then
				model:SetAttribute("OwnerUserId", player.UserId)
			end
			setSign(index, player.DisplayName)
			fire(assignedListeners, player, index)
			return
		end
	end
	warn(`[PlotService] no free plot for {player.Name}`)
end

local function free(player: Player)
	local index = plotByPlayer[player]
	if index == nil then
		return
	end
	plotByPlayer[player] = nil
	ownerByPlot[index] = nil
	local model = plotModel(index)
	if model then
		model:SetAttribute("OwnerUserId", nil)
	end
	setSign(index, "")
	fire(freedListeners, player, index)
end

-- Where the player should stand when sent home: their plot's spawn spot, else the base spawn.
local function spawnCFrame(player: Player): CFrame
	local index = plotByPlayer[player]
	if index then
		return BaseLayout.plotSpawn(BaseLayout.plot(index))
	end
	return CFrame.new(BaseLayout.SPAWN_POSITION + Vector3.new(0, 3, 0))
end

local function moveToPlot(player: Player, character: Model)
	local root = character:WaitForChild("HumanoidRootPart", SPAWN_ROOT_TIMEOUT_S)
	if root == nil or character.Parent == nil or player.Character ~= character then
		return
	end
	character:PivotTo(spawnCFrame(player))
	player:SetAttribute("PocketId", 0)
end

local function onPlayerAdded(player: Player)
	assign(player)
	player.CharacterAdded:Connect(function(character: Model)
		moveToPlot(player, character)
	end)
	local character = player.Character
	if character then
		task.spawn(moveToPlot, player, character)
	end
end

function PlotService.Init() end

function PlotService.Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(free)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

-- CHANGED (Phase 2a feedback): the spot a player spawns at (their plot).
function PlotService.spawnCFrame(player: Player): CFrame
	return spawnCFrame(player)
end

-- The player's plot index, or nil.
function PlotService.plotOf(player: Player): number?
	return plotByPlayer[player]
end

function PlotService.ownerOf(index: number): Player?
	return ownerByPlot[index]
end

function PlotService.plotModel(index: number): Model?
	return plotModel(index)
end

-- Listeners run in their own thread. Subscribe during Init so no assignment is missed.
function PlotService.onAssigned(listener: Listener)
	table.insert(assignedListeners, listener)
end

function PlotService.onFreed(listener: Listener)
	table.insert(freedListeners, listener)
end

return PlotService
