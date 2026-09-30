--!strict
--[[
	CrewService
	Seats and hatches (spec 7.2 boarding, 7.9 hatches). Phase 1 scope: players sit through a seat's "SitPrompt"
	and move through a cabin hatch with "EnterPrompt" / "ExitPrompt", subject to the owner's boarding permission
	(Private = owner only, Friends = owner and friends, Public = everyone). Seats are Disabled by default so nobody
	can touch-sit past the permission check; a seat is enabled only while occupied.

	Pilots, deaths and respawn arrive with flight in Phase 2.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local CraftService = require(script.Parent.CraftService)
local PlotService = require(script.Parent.PlotService)

--============================================================================
-- Tunables
--============================================================================
local FRIEND_CACHE_S = 120
local HATCH_COOLDOWN_S = 0.5
--============================================================================

local CrewService = {}

local notifyRemote: RemoteEvent
local watchedSeats: { [Seat]: boolean } = {}
local friendCache: { [string]: { value: boolean, time: number } } = {}
local lastHatch: { [Player]: number } = {}

-- Owner user id and boarding mode for whatever contains `instance` (a craft or a hangar build).
local function ownership(instance: Instance): (number?, string)
	local node: Instance? = instance
	while node do
		local owner = node:GetAttribute("OwnerUserId")
		if type(owner) == "number" and node:GetAttribute("CraftId") ~= nil then
			local mode = node:GetAttribute(CraftService.BOARDING_ATTRIBUTE)
			return owner, if type(mode) == "string" then mode else GameConfig.DEFAULT_BOARDING
		end
		local plotIndex = node:GetAttribute("PlotIndex")
		if type(plotIndex) == "number" and node:IsA("Folder") then
			local ownerPlayer = PlotService.ownerOf(plotIndex)
			if ownerPlayer then
				local mode = ownerPlayer:GetAttribute(CraftService.BOARDING_ATTRIBUTE)
				return ownerPlayer.UserId, if type(mode) == "string" then mode else GameConfig.DEFAULT_BOARDING
			end
			return nil, "Private"
		end
		node = node.Parent
	end
	return nil, "Public"
end

local function isFriend(player: Player, userId: number): boolean
	local cacheKey = `{player.UserId}:{userId}`
	local cached = friendCache[cacheKey]
	if cached and os.clock() - cached.time < FRIEND_CACHE_S then
		return cached.value
	end
	local ok, result = pcall(function()
		return player:IsFriendsWithAsync(userId)
	end)
	local value = ok and result == true
	friendCache[cacheKey] = { value = value, time = os.clock() }
	return value
end

local function canBoard(player: Player, instance: Instance): boolean
	local ownerUserId, mode = ownership(instance)
	if ownerUserId == nil then
		return mode == "Public"
	end
	if ownerUserId == player.UserId or mode == "Public" then
		return true
	end
	if mode == "Friends" then
		return isFriend(player, ownerUserId)
	end
	return false
end

local function aliveHumanoid(player: Player): (Model?, Humanoid?)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if character and humanoid and humanoid.Health > 0 then
		return character, humanoid
	end
	return nil, nil
end

-- Gets a humanoid out of its seat safely: the SeatWeld must go BEFORE the character is moved, or moving the
-- character drags the (anchored) seat along with it (review finding; same order as spike S9's unseat).
local function unseat(humanoid: Humanoid)
	local seatPart = humanoid.SeatPart
	if seatPart == nil then
		return
	end
	local weld = seatPart:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	humanoid.Sit = false
	task.wait()
end

local function watchSeat(seat: Seat)
	if watchedSeats[seat] then
		return
	end
	watchedSeats[seat] = true
	local prompt = seat:FindFirstChild("SitPrompt")
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupied = seat.Occupant ~= nil
		seat.Disabled = not occupied
		if prompt and prompt:IsA("ProximityPrompt") then
			prompt.Enabled = not occupied
		end
	end)
	seat.Destroying:Connect(function()
		watchedSeats[seat] = nil
	end)
end

local function onSitPrompt(prompt: ProximityPrompt, player: Player)
	local seat = prompt.Parent
	if not (seat and seat:IsA("Seat")) or seat.Occupant ~= nil then
		return
	end
	local _, humanoid = aliveHumanoid(player)
	if humanoid == nil then
		return
	end
	if not canBoard(player, seat) then
		notifyRemote:FireClient(player, "The owner hasn't allowed you to board this craft", "Error")
		return
	end
	watchSeat(seat)
	unseat(humanoid)
	if seat.Occupant ~= nil then
		return
	end
	seat.Disabled = false
	seat:Sit(humanoid)
	task.delay(0.5, function()
		if seat.Parent and seat.Occupant == nil then
			seat.Disabled = true
		end
	end)
end

local function onHatchPrompt(prompt: ProximityPrompt, player: Player, entering: boolean)
	local attachment = prompt.Parent
	local hatch = if attachment then attachment.Parent else nil
	if not (attachment and attachment:IsA("Attachment") and hatch and hatch:IsA("BasePart")) then
		return
	end
	local now = os.clock()
	if lastHatch[player] and now - lastHatch[player] < HATCH_COOLDOWN_S then
		return
	end
	lastHatch[player] = now
	local character, humanoid = aliveHumanoid(player)
	if character == nil or humanoid == nil then
		return
	end
	if entering and not canBoard(player, hatch) then
		notifyRemote:FireClient(player, "The owner hasn't allowed you to board this craft", "Error")
		return
	end
	local target = hatch:FindFirstChild(if entering then "HatchInside" else "HatchOutside")
	if not (target and target:IsA("Attachment")) then
		return
	end
	unseat(humanoid)
	character:PivotTo(target.WorldCFrame)
end

function CrewService.Init()
	notifyRemote = Remotes.event("Notify")
end

function CrewService.Start()
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if prompt.Name == "SitPrompt" then
			onSitPrompt(prompt, player)
		elseif prompt.Name == "EnterPrompt" then
			onHatchPrompt(prompt, player, true)
		elseif prompt.Name == "ExitPrompt" then
			onHatchPrompt(prompt, player, false)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		lastHatch[player] = nil
	end)
end

return CrewService
