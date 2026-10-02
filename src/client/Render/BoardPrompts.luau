--!strict
--[[
	BoardPrompts
	CHANGED (Boarding): seat prompts on the cosmetic copies of crafts flying in ANOTHER pocket, so a player on foot
	in the base pocket can board a craft whose pilot already sat down (its real model lives in its flight pocket;
	before this nobody could ever board it, not even on the pad). Rules in Shared/Craft/Boarding.

	RemoteCraftRenderer hands over, every frame, the copies that may be boarded (Boarding.offersPrompts: local player
	in the base, craft flying in another pocket, not debris, slower than BOARD_MAX_SPEED). Every REFRESH_S this
	module then:
	  * offers prompts only while the local player is alive, on foot and within the craft's radius + BOARD_RANGE of
	    the copy, and the craft is not Private to someone else (the real model's Boarding attribute);
	  * puts one client-side ProximityPrompt on each seat of the copy (PartVisuals.seatPrompt: the same look, text
	    and key as a real seat's SitPrompt, "Pilot" on a pilot seat), created once per copy model, never per frame;
	  * enables a prompt only while the matching Seat of the real model (replicated, hidden in its pocket) is free;
	  * removes every prompt of a craft that is no longer offered (copy hidden, LOD marker, craft removed, player
	    seated or in another pocket, out of range) or whose copy was rebuilt.
	Triggering a prompt fires BoardCraft(craftId, seatBlockId); the server checks everything again and answers by
	seating the player (PocketTransfer into the flight pocket) or with a Notify error.

	Everything here is client-only and lives in the copies (RemoteCrafts folder, never inside a pocket, so
	PocketController's hiding never touches it). A destroyed copy takes its prompts (and their connections) with it.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Boarding = require(ReplicatedStorage.Shared.Craft.Boarding)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local PartVisuals = require(ReplicatedStorage.Shared.Craft.PartVisuals)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)

--============================================================================
-- Tunables
--============================================================================
local REFRESH_S = 0.1 -- s between prompt refreshes (creation, occupancy, range); hiding a copy hides its prompts at once
local REQUEST_COOLDOWN_S = 1 -- s between two BoardCraft requests (the server rate-limits too)
local PROMPT_NAME = "BoardPrompt"
local SEAT_INDEX_ATTRIBUTE = "SeatIndex"
local PILOT_ATTRIBUTE = "IsPilot"
local BOARDING_ATTRIBUTE = "Boarding" -- the real craft model's mode, as CraftService.BOARDING_ATTRIBUTE (server-only)
--============================================================================

-- A copy that may be boarded this frame (filled by RemoteCraftRenderer; one reused table per known craft).
export type Candidate = {
	craftId: number,
	pocketId: number, -- the flight pocket holding the real model
	ownerUserId: number,
	radius: number, -- m, the craft's bounding radius around its reference point
	model: Model?, -- the cosmetic copy
	root: BasePart?, -- the copy's root (the craft reference point)
}

type SeatPrompt = {
	prompt: ProximityPrompt,
	blockId: number,
	realSeat: Seat?, -- the matching Seat of the real model, resolved lazily
}

type CraftPrompts = {
	model: Model, -- the copy the prompts were built on
	seats: { SeatPrompt },
}

local BoardPrompts = {}

local player = Players.LocalPlayer
local active: { [number]: CraftPrompts } = {}
local lastRefresh = -math.huge
local lastRequest: number? = nil
local boardRemote: RemoteEvent? = nil

local function request(craftId: number, blockId: number)
	local now = os.clock()
	if not Boarding.cooldownOver(lastRequest, now, REQUEST_COOLDOWN_S) then
		return
	end
	lastRequest = now
	local remote = boardRemote
	if remote == nil then
		remote = Remotes.event("BoardCraft")
		boardRemote = remote
	end
	(remote :: RemoteEvent):FireServer(craftId, blockId)
end

local function clearCraft(craftId: number)
	local entry = active[craftId]
	if entry == nil then
		return
	end
	active[craftId] = nil
	for _, seat in entry.seats do
		seat.prompt:Destroy() -- also disconnects its Triggered connection
	end
end

-- One prompt per seat of the copy (every seat part has exactly one seat, so the block id names it).
local function buildPrompts(craftId: number, model: Model): CraftPrompts
	local seats: { SeatPrompt } = {}
	for _, block in model:GetChildren() do
		local blockId = block:GetAttribute("BlockId")
		local partId = block:GetAttribute("PartId")
		local def = if type(partId) == "string" then Parts.find(partId) else nil
		if block:IsA("Model") and type(blockId) == "number" and def and def.Seats > 0 then
			for _, descendant in block:GetDescendants() do
				if descendant:IsA("BasePart") and type(descendant:GetAttribute(SEAT_INDEX_ATTRIBUTE)) == "number" then
					local isPilot = descendant:GetAttribute(PILOT_ATTRIBUTE) == true
					local prompt = PartVisuals.seatPrompt(descendant, PROMPT_NAME, isPilot, def.DisplayName)
					prompt.Enabled = false -- until the real seat is known to be free
					local id = blockId :: number
					prompt.Triggered:Connect(function()
						request(craftId, id)
					end)
					table.insert(seats, { prompt = prompt, blockId = id, realSeat = nil })
					break
				end
			end
		end
	end
	return { model = model, seats = seats }
end

-- The real craft model in its flight pocket (replicated, hidden there), while the server says it belongs to it.
local function realModel(candidate: Candidate): Model?
	local pockets = Workspace:FindFirstChild("Pockets")
	local pocket = if pockets then pockets:FindFirstChild(`Pocket_{candidate.pocketId}`) else nil
	local crafts = if pocket then pocket:FindFirstChild("Crafts") else nil
	local found = if crafts then crafts:FindFirstChild(`Craft_{candidate.craftId}`) else nil
	if found and found:IsA("Model") and found:GetAttribute("FlightPocket") == candidate.pocketId then
		return found
	end
	return nil
end

local function seatOfBlock(model: Model, blockId: number): Seat?
	local block = CraftBuilder.findBlockModel(model, blockId)
	if block == nil then
		return nil
	end
	for _, descendant in block:GetDescendants() do
		if descendant:IsA("Seat") then
			return descendant
		end
	end
	return nil
end

-- The local character's root while it is alive and on foot, or nil.
local function onFootRoot(): BasePart?
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if humanoid and humanoid.Health > 0 and humanoid.SeatPart == nil and root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function refreshCraft(candidate: Candidate, real: Model)
	local model = candidate.model :: Model
	local previous = active[candidate.craftId]
	if previous and previous.model ~= model then
		clearCraft(candidate.craftId) -- the copy was rebuilt (its old prompts went with the old model)
	end
	local current = active[candidate.craftId]
	if current == nil then
		current = buildPrompts(candidate.craftId, model)
		active[candidate.craftId] = current
	end
	local kept: { SeatPrompt }? = nil
	for index, seat in current.seats do
		if seat.prompt.Parent == nil then
			-- the seat's block was destroyed (staging, crash): drop it from the list
			if kept == nil then
				kept = table.move(current.seats, 1, index - 1, 1, {})
			end
			continue
		end
		if kept then
			table.insert(kept, seat)
		end
		local realSeat = seat.realSeat
		if realSeat == nil or realSeat.Parent == nil or not realSeat:IsDescendantOf(real) then
			realSeat = seatOfBlock(real, seat.blockId)
			seat.realSeat = realSeat
		end
		local free = realSeat ~= nil and realSeat.Occupant == nil
		if seat.prompt.Enabled ~= free then
			seat.prompt.Enabled = free
		end
	end
	if kept then
		current.seats = kept
	end
end

--[[
	Called by RemoteCraftRenderer once per frame, after the copies are posed, with the copies that may be boarded
	this frame (craft id -> candidate). Cheap between refreshes.
]]
function BoardPrompts.update(candidates: { [number]: Candidate })
	local now = os.clock()
	if now - lastRefresh < REFRESH_S then
		return
	end
	lastRefresh = now
	local root = onFootRoot()
	-- drop prompts of crafts no longer offered
	for craftId in active do
		if root == nil or candidates[craftId] == nil then
			clearCraft(craftId)
		end
	end
	if root == nil then
		return
	end
	local here = (root :: BasePart).Position
	for craftId, candidate in candidates do
		local model, copyRoot = candidate.model, candidate.root
		local real = if model and copyRoot then realModel(candidate) else nil
		local offered = model ~= nil
			and copyRoot ~= nil
			and model.Parent ~= nil
			and real ~= nil
			and Boarding.modeMayAllow(
				(real :: Model):GetAttribute(BOARDING_ATTRIBUTE),
				candidate.ownerUserId,
				player.UserId
			)
			and Boarding.inRange(((copyRoot :: BasePart).Position - here).Magnitude, candidate.radius)
		if offered then
			refreshCraft(candidate, real :: Model)
		else
			clearCraft(craftId)
		end
	end
end

-- Drops a craft's prompts at once (the craft was removed).
function BoardPrompts.clear(craftId: number)
	clearCraft(craftId)
end

return BoardPrompts
