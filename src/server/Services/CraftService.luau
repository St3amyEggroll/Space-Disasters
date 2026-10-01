--!strict
--[[
	CraftService
	Registry of crafts and their authoritative records. Phase 1: Roll Out (build the player's plot design as a
	real, anchored craft on a free SHARED launch pad in the base pocket's launch area, replacing their previous
	rolled-out craft; CHANGED Phase 1 rework),
	boarding permission per player (Private / Friends / Public), and despawning a leaving player's crafts after a
	grace period.

	CHANGED (Phase 2a): records also carry the flight simulation. Every flying craft has a server copy
	(`sim`, a FlightModel.Craft). Crewed crafts are simulated by their pilot's client (`pilot`); the server copy
	then follows the pilot's reported state and is used for staging/splits. Uncrewed crafts and debris are
	simulated on the server (`serverSim`). Crafts in flight are announced with CraftSpawned / CraftRemoved.

	Craft models (crewed crafts only): Workspace.Pockets.Pocket_<id>.Crafts.Craft_<id>, attributes CraftId,
	OwnerUserId, Boarding, State.

	CHANGED (Phase 3): rolled-out crafts on their pads are announced too (CraftSpawned with info.prelaunch), so
	players in other pockets get a cosmetic copy of them. A client asks for the join snapshot (RequestSnapshot)
	once its handlers are connected, and gets one CraftSpawned per craft.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local CraftGraph = require(ReplicatedStorage.Shared.Craft.CraftGraph)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local Frames = require(ReplicatedStorage.Shared.Math.Frames) -- CHANGED (Phase 3): prelaunch announce
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime) -- CHANGED (Phase 3): prelaunch announce
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d) -- CHANGED (Phase 3): prelaunch announce
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
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
local MAX_DEBRIS = GameConfig.MAX_DEBRIS
local SNAPSHOT_COOLDOWN_S = GameConfig.SNAPSHOT_COOLDOWN_S -- CHANGED (Phase 3)
--============================================================================

export type CraftState = "Prelaunch" | "Flying" | "Landed" | "OnRails" | "Destroyed"

export type CraftRecord = {
	id: number,
	ownerUserId: number,
	design: Design, -- design-local = craft-local grid
	model: Model?, -- real model (crewed crafts in a pocket); nil for debris / uncrewed crafts
	state: CraftState,
	origin: CFrame, -- where the design grid origin sits in its pocket (Prelaunch)
	-- flight (Phase 2a)
	sim: FlightModel.Craft?, -- server copy of the simulation
	pilot: Player?, -- client that simulates this craft (nil = server simulates when serverSim)
	serverSim: boolean,
	pocketId: number?, -- flight pocket holding the real model
	isDebris: boolean,
	createdAt: number, -- os.clock()
	restingSince: number?, -- os.clock() when a server-simulated craft came to rest
}

local CraftService = {}

CraftService.BOARDING_ATTRIBUTE = BOARDING_ATTRIBUTE

local crafts: { [number]: CraftRecord } = {}
local padCraftByUser: { [number]: number } = {}
local craftOnPad: { [number]: number } = {} -- pad index -> craft id
local padOfCraft: { [number]: number } = {} -- craft id -> pad index
local nextCraftId = 1
local lastRollout: { [Player]: number } = {}
local rolledOutListeners: { (player: Player, record: CraftRecord) -> () } = {}
local announcedIds: { [number]: boolean } = {} -- CHANGED (Phase 3): crafts clients know about (CraftRemoved owed)
local lastSnapshot: { [Player]: number } = {} -- CHANGED (Phase 3)

local function removeCraft(id: number)
	local record = crafts[id]
	if record == nil then
		return
	end
	crafts[id] = nil
	if padCraftByUser[record.ownerUserId] == id then
		padCraftByUser[record.ownerUserId] = nil
	end
	local pad = padOfCraft[id]
	if pad then
		padOfCraft[id] = nil
		craftOnPad[pad] = nil
	end
	record.state = "Destroyed"
	if record.model then
		record.model:Destroy()
	end
	-- CHANGED (Phase 3): announced prelaunch crafts (no sim) are removed on clients too
	if record.sim or announcedIds[id] then
		announcedIds[id] = nil
		Remotes.event("CraftRemoved"):FireAllClients(id)
	end
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
		-- CHANGED (Phase 2a feedback): Roll Out seats you in the pod, so a pilot seat is required
		BuildService.notify(player, "You need a Command Pod (or Crew Cabin) to fly! Add one to your rocket.", "Error")
		return
	end
	if #graph.looseIds > 0 then
		BuildService.notify(player, `{#graph.looseIds} block(s) are not attached to the command part`, "Error")
		return
	end

	-- Reuse the player's pad (replacing their previous craft), else take the first free pad.
	local padIndex: number? = nil
	local previous = padCraftByUser[player.UserId]
	if previous then
		padIndex = padOfCraft[previous]
		removeCraft(previous)
	end
	if padIndex == nil then
		for index = 1, BaseLayout.PAD_COUNT do
			if craftOnPad[index] == nil then
				padIndex = index
				break
			end
		end
	end
	if padIndex == nil then
		BuildService.notify(player, "All launch pads are busy, try again soon", "Error")
		return
	end

	local pad = BaseLayout.pad(padIndex)
	local grid = CraftDesign.GRID
	local minV, maxV = CraftDesign.bounds(design)
	local center = (minV + maxV) / 2 * grid
	local origin = pad.top * CFrame.new(-center.X, -minV.Y * grid, -center.Z)
	local halfExtent = math.max(maxV.X - minV.X, maxV.Z - minV.Z) * grid / 2
	clearPad(pad.top, halfExtent, (maxV.Y - minV.Y) * grid)

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
		sim = nil,
		pilot = nil,
		serverSim = false,
		pocketId = nil,
		isDebris = false,
		createdAt = os.clock(),
		restingSince = nil,
	}
	padCraftByUser[player.UserId] = id
	craftOnPad[padIndex] = id
	padOfCraft[id] = padIndex
	model:SetAttribute("PadIndex", padIndex)
	BuildService.notify(player, `Rolled out "{design.name}" to launch pad {padIndex}`)
	CraftService.announce(crafts[id]) -- CHANGED (Phase 3): players in other pockets see it on the pad
	-- CHANGED (Phase 2a feedback): CrewService puts the owner straight into the pilot seat
	for _, listener in rolledOutListeners do
		task.spawn(listener, player, crafts[id])
	end
end

local function onSetBoarding(player: Player, mode: unknown)
	if type(mode) ~= "string" or not BOARDING_MODES[mode] then
		return
	end
	player:SetAttribute(BOARDING_ATTRIBUTE, mode)
	for _, record in crafts do
		local model = record.model
		if record.ownerUserId == player.UserId and model then
			model:SetAttribute(BOARDING_ATTRIBUTE, mode)
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

	-- CHANGED (Phase 3): join snapshot, requested by the client once its CraftSpawned handler is connected
	Remotes.event("RequestSnapshot").OnServerEvent:Connect(function(player: Player)
		local now = os.clock()
		if lastSnapshot[player] and now - lastSnapshot[player] < SNAPSHOT_COOLDOWN_S then
			return
		end
		lastSnapshot[player] = now
		CraftService.snapshot(player)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastRollout[player] = nil
		lastSnapshot[player] = nil -- CHANGED (Phase 3)
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

function CraftService.all(): { [number]: CraftRecord }
	return crafts
end

-- CHANGED (Phase 2a feedback): called (in its own thread) after a player rolls a craft out onto a pad.
function CraftService.onRolledOut(listener: (player: Player, record: CraftRecord) -> ())
	table.insert(rolledOutListeners, listener)
end

-- CHANGED (Phase 2a feedback): the pad a craft stands on, or nil once it has lifted off.
function CraftService.padOf(id: number): number?
	return padOfCraft[id]
end

-- Frees the craft's launch pad (it has lifted off).
function CraftService.freePad(id: number)
	local record = crafts[id]
	local pad = padOfCraft[id]
	if pad then
		padOfCraft[id] = nil
		craftOnPad[pad] = nil
	end
	if record and padCraftByUser[record.ownerUserId] == id then
		padCraftByUser[record.ownerUserId] = nil
	end
end

local function activeList(sim: FlightModel.Craft): { number }
	local list = {}
	for id in sim.active do
		table.insert(list, id)
	end
	table.sort(list)
	return list
end

-- CHANGED (Phase 3): the true state of a Prelaunch craft where its real model stands in the base pocket.
local function prelaunchState(record: CraftRecord): FlightModel.CraftState?
	local root = CraftDesign.rootBlock(record.design)
	if root == nil then
		return nil
	end
	local rootWorld = record.origin * CFrame.new(CraftDesign.blockCenter(root) * CraftDesign.GRID)
	local baseFrame = PocketService.baseFrame()
	local pos, rot = Frames.cframeFromWorkspace(baseFrame, rootWorld)
	return {
		bodyId = baseFrame.refBodyId,
		pos = pos,
		vel = Vec3d.zero(),
		rot = rot,
		angVel = Vector3.zero,
		throttle = 0,
		flags = 0,
		ut = UniverseTime.now(),
	}
end

local function ownerNameOf(record: CraftRecord): string
	local owner = Players:GetPlayerByUserId(record.ownerUserId)
	if owner then
		return owner.DisplayName
	end
	local model = record.model
	local stored = if model then model:GetAttribute("OwnerName") else nil
	return if type(stored) == "string" then stored else ""
end

--[[
	Announces a craft to one player (join snapshot) or everyone: crafts in flight, and (CHANGED Phase 3) rolled-out
	crafts standing on their pads (info.prelaunch; clients in the base pocket see the real model instead).
]]
function CraftService.announce(record: CraftRecord, toPlayer: Player?)
	local sim = record.sim
	local designBuffer: buffer
	local stateBuffer: buffer
	local active: { number }
	local prelaunch = false
	if sim then
		designBuffer = CraftDesign.toBuffer(sim.physics.design)
		stateBuffer = Protocol.encodeState(record.id, sim.state)
		active = activeList(sim)
	elseif record.state == "Prelaunch" and record.model then
		local state = prelaunchState(record)
		if state == nil then
			return
		end
		designBuffer = CraftDesign.toBuffer(record.design)
		stateBuffer = Protocol.encodeState(record.id, state)
		active = {}
		prelaunch = true
	else
		return
	end
	announcedIds[record.id] = true
	local remote = Remotes.event("CraftSpawned")
	local info = {
		ownerUserId = record.ownerUserId,
		pocketId = record.pocketId or 0,
		active = active,
		-- CHANGED (Phase 3): marker labels and render rules
		name = record.design.name,
		ownerName = ownerNameOf(record),
		isDebris = record.isDebris,
		prelaunch = prelaunch,
	}
	if toPlayer then
		remote:FireClient(toPlayer, record.id, designBuffer, stateBuffer, info)
	else
		remote:FireAllClients(record.id, designBuffer, stateBuffer, info)
	end
end

-- CHANGED (Phase 3): the join snapshot: every craft the player's client should know about (spec 7.7 Snapshot).
function CraftService.snapshot(player: Player)
	for _, record in crafts do
		CraftService.announce(record, player)
	end
end

-- Creates a server-simulated debris craft from a piece split off a parent (FlightModel.Debris).
function CraftService.spawnDebris(parent: CraftRecord, debris: FlightModel.Debris): CraftRecord
	local id = nextCraftId
	nextCraftId += 1
	local parentSim = parent.sim :: FlightModel.Craft
	local sim = FlightModel.newCraft(debris.design, debris.state, debris.fuel, parentSim.stages, math.huge)
	for engineId in debris.active do
		sim.active[engineId] = true
	end
	local record: CraftRecord = {
		id = id,
		ownerUserId = parent.ownerUserId,
		design = debris.design,
		model = nil,
		state = "Flying",
		origin = CFrame.identity,
		sim = sim,
		pilot = nil,
		serverSim = true,
		pocketId = nil,
		isDebris = true,
		createdAt = os.clock(),
		restingSince = nil,
	}
	crafts[id] = record
	CraftService.announce(record)

	-- keep at most MAX_DEBRIS pieces: remove the oldest
	local debrisIds = {}
	for otherId, other in crafts do
		if other.isDebris then
			table.insert(debrisIds, otherId)
		end
	end
	if #debrisIds > MAX_DEBRIS then
		table.sort(debrisIds, function(a, b)
			return crafts[a].createdAt < crafts[b].createdAt
		end)
		for index = 1, #debrisIds - MAX_DEBRIS do
			removeCraft(debrisIds[index])
		end
	end
	return record
end

function CraftService.remove(id: number)
	removeCraft(id)
end

return CraftService
