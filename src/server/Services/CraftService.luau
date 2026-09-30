--!strict
--[[
	CraftService
	Registry of crafts and their authoritative records. Phase 1: Roll Out (build the player's hangar design as a
	real, anchored craft on their launch pad in the base pocket, replacing their previous rolled-out craft),
	boarding permission per player (Private / Friends / Public), and despawning a leaving player's crafts after a
	grace period. Flight state, staging and destruction arrive in Phase 2.

	Craft models: Workspace.Pockets.Pocket_0.Crafts.Craft_<id>, attributes CraftId, OwnerUserId, Boarding, State.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local CraftGraph = require(ReplicatedStorage.Shared.Craft.CraftGraph)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local BuildService = require(script.Parent.BuildService)
local PlotService = require(script.Parent.PlotService)
local PocketService = require(script.Parent.PocketService)

type Design = CraftDesign.Design

--============================================================================
-- Tunables
--============================================================================
local ROLLOUT_COOLDOWN_S = 2
local DESPAWN_GRACE_S = GameConfig.PAD_DESPAWN_GRACE_S
local BOARDING_MODES = { Private = true, Friends = true, Public = true }
local BOARDING_ATTRIBUTE = "Boarding"
local PAD_CLEAR_MARGIN = 4 -- studs; characters standing where the craft appears are moved off the pad
--============================================================================

export type CraftState = "Prelaunch" | "Flying" | "Landed" | "OnRails" | "Destroyed"

export type CraftRecord = {
	id: number,
	ownerUserId: number,
	design: Design, -- design-local = craft-local grid
	model: Model,
	state: CraftState,
	origin: CFrame, -- where the design grid origin sits in its pocket (Prelaunch)
}

local CraftService = {}

CraftService.BOARDING_ATTRIBUTE = BOARDING_ATTRIBUTE

local crafts: { [number]: CraftRecord } = {}
local padCraftByUser: { [number]: number } = {}
local nextCraftId = 1
local lastRollout: { [Player]: number } = {}

local function removeCraft(id: number)
	local record = crafts[id]
	if record == nil then
		return
	end
	crafts[id] = nil
	if padCraftByUser[record.ownerUserId] == id then
		padCraftByUser[record.ownerUserId] = nil
	end
	record.state = "Destroyed"
	record.model:Destroy()
end

-- Moves characters that stand inside the area a new craft will occupy to the pad edge.
local function clearPad(padTop: CFrame, halfExtent: number, height: number)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if character and humanoid and root and root:IsA("BasePart") and humanoid.SeatPart == nil then
			local offset = padTop:PointToObjectSpace(root.Position)
			if
				math.abs(offset.X) < halfExtent + PAD_CLEAR_MARGIN
				and math.abs(offset.Z) < halfExtent + PAD_CLEAR_MARGIN
				and offset.Y > -2
				and offset.Y < height + 4
			then
				local side = if offset.X >= 0 then 1 else -1
				character:PivotTo(padTop * CFrame.new(side * (halfExtent + PAD_CLEAR_MARGIN + 2), 4, offset.Z))
			end
		end
	end
end

local function onRollOut(player: Player)
	local now = os.clock()
	if lastRollout[player] and now - lastRollout[player] < ROLLOUT_COOLDOWN_S then
		return
	end
	lastRollout[player] = now

	local plotIndex = PlotService.plotOf(player)
	local design = BuildService.designOf(player)
	if plotIndex == nil or design == nil then
		return
	end
	if #design.blocks == 0 then
		BuildService.notify(player, "Build something first!", "Error")
		return
	end
	local graph = CraftGraph.build(design)
	if graph.rootId == nil then
		BuildService.notify(player, "Needs a command part (Command Pod or Crew Cabin)", "Error")
		return
	end
	if #graph.looseIds > 0 then
		BuildService.notify(player, `{#graph.looseIds} block(s) are not attached to the command part`, "Error")
		return
	end

	-- Replace the player's previous rolled-out craft.
	local previous = padCraftByUser[player.UserId]
	if previous then
		removeCraft(previous)
	end

	local plot = BaseLayout.plot(plotIndex)
	local minV, maxV = CraftDesign.bounds(design)
	local center = (minV + maxV) / 2
	local origin = plot.padTop * CFrame.new(-center.X, -minV.Y, -center.Z)
	local halfExtent = math.max(maxV.X - minV.X, maxV.Z - minV.Z) / 2
	clearPad(plot.padTop, halfExtent, maxV.Y - minV.Y)

	local id = nextCraftId
	nextCraftId += 1
	local model = CraftBuilder.build(design, "Real", origin, `Craft_{id}`)
	model:SetAttribute("CraftId", id)
	model:SetAttribute("OwnerUserId", player.UserId)
	model:SetAttribute("OwnerName", player.DisplayName)
	model:SetAttribute("DesignName", design.name)
	model:SetAttribute(BOARDING_ATTRIBUTE, player:GetAttribute(BOARDING_ATTRIBUTE) or GameConfig.DEFAULT_BOARDING)
	model:SetAttribute("State", "Prelaunch")
	model.Parent = PocketService.baseCrafts()

	crafts[id] = {
		id = id,
		ownerUserId = player.UserId,
		design = design,
		model = model,
		state = "Prelaunch",
		origin = origin,
	}
	padCraftByUser[player.UserId] = id
	BuildService.notify(player, `Rolled out "{design.name}" to pad {plotIndex}`)
end

local function onSetBoarding(player: Player, mode: unknown)
	if type(mode) ~= "string" or not BOARDING_MODES[mode] then
		return
	end
	player:SetAttribute(BOARDING_ATTRIBUTE, mode)
	for _, record in crafts do
		if record.ownerUserId == player.UserId then
			record.model:SetAttribute(BOARDING_ATTRIBUTE, mode)
		end
	end
end

function CraftService.Init() end

function CraftService.Start()
	Remotes.event("RollOut").OnServerEvent:Connect(onRollOut)
	Remotes.event("SetBoardingPermission").OnServerEvent:Connect(onSetBoarding)

	local function onPlayerAdded(player: Player)
		if player:GetAttribute(BOARDING_ATTRIBUTE) == nil then
			player:SetAttribute(BOARDING_ATTRIBUTE, GameConfig.DEFAULT_BOARDING)
		end
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		lastRollout[player] = nil
		local userId = player.UserId
		task.delay(DESPAWN_GRACE_S, function()
			if Players:GetPlayerByUserId(userId) then
				return -- rejoined within the grace period
			end
			for id, record in crafts do
				if record.ownerUserId == userId then
					removeCraft(id)
				end
			end
		end)
	end)
end

function CraftService.get(id: number): CraftRecord?
	return crafts[id]
end

function CraftService.remove(id: number)
	removeCraft(id)
end

return CraftService
