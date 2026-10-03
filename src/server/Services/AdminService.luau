--!strict
--[[
	AdminService (new file, Solar system; D51)
	The server side of the admin panel (UI/AdminPanel, F7 or the ADMIN button): "spawn my ship in orbit around any
	body, or landed on one". Rules (who is an admin, ranges, spots) are Shared/Sim/AdminSpawn.

	Admins: on join every player gets the attribute IsAdmin (AdminSpawn.isAdmin: everyone in Studio; live: the place's
	creator, or for a group game the group's owner (GroupService), plus GameConfig.ADMIN_USER_IDS). The client only shows the panel to admins; the
	server checks again on every request (its own cached flag, never the attribute the client sees).

	Remote AdminSpawn (client -> server, { bodyId, mode, altitudeKm, spot }): refused unless the sender is an admin,
	not already spawning, past the cooldown (AdminSpawn.COOLDOWN_S) and the request validates. Then, in a thread:
	  1. the player's current flight ends (FlightService.leaveFlight: a pilot / owner ends it, a passenger or an
	     astronaut goes home) and the server waits until he is back in the base, on foot
	  2. his ship rolls out exactly like Roll Out (CraftService.rollOut): the design on his plot, or the starter rocket
	     (Shared/Craft/StarterCraft) when the plot holds nothing that can fly. CrewService seats him as pilot and
	     FlightService starts the flight (flight pocket, FlightStart), as for every launch
	  3. the craft is moved with the /orbit or /hover implementation (DebugService.placeInOrbit / placeHovering):
	     Orbit = a circular prograde orbit over the day side (AdminSpawn.orbitState); Landed = upright, its lowest
	     point 1 m over the flattest ground at the chosen spot (AdminSpawn.landingDirection); "Launch pad" (Earth)
	     stops after step 2. Its launch pad is freed (it is not on it any more).
	Every client sees the craft like any other (it is a normal flight: CraftSpawned, bubbles, pockets). Messages go
	back with Notify.
]]

local GroupService = game:GetService("GroupService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AdminSpawn = require(ReplicatedStorage.Shared.Sim.AdminSpawn)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local StarterCraft = require(ReplicatedStorage.Shared.Craft.StarterCraft)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local BuildService = require(script.Parent.BuildService)
local CraftService = require(script.Parent.CraftService)
local DebugService = require(script.Parent.DebugService)
local FlightService = require(script.Parent.FlightService)

--============================================================================
-- Tunables
--============================================================================
local ADMIN_ATTRIBUTE = "IsAdmin"
local POLL_S = 0.1
local LEAVE_TIMEOUT_S = 6 -- s to get back to the base after ending the current flight
local START_TIMEOUT_S = 8 -- s for the rolled-out ship's flight to start (seat, pocket, FlightStart)
local SETTLE_S = 0.4 -- s after the flight started before the ship is moved (FlightStart reaches the client first)
local FALLBACK_UP = Vec3d.new(1, 0, 0)
--============================================================================

local AdminService = {}

local admins: { [Player]: boolean } = {}
local busy: { [Player]: boolean } = {}
local lastSpawn: { [Player]: number } = {}
local notify: RemoteEvent

local ownerId: number? = nil -- the place's owner (looked up once)
local ownerKnown = false

-- The place's owner: its creator, or a group game's group owner (nil if the lookup fails).
local function placeOwner(): number?
	if ownerKnown then
		return ownerId
	end
	if game.CreatorType ~= Enum.CreatorType.Group then
		ownerId, ownerKnown = game.CreatorId, true
		return ownerId
	end
	local ok, info = pcall(function(): any
		return GroupService:GetGroupInfoAsync(game.CreatorId)
	end)
	local owner = if ok and type(info) == "table" then info.Owner else nil
	local id = if type(owner) == "table" then owner.Id else nil
	if type(id) == "number" then
		ownerId, ownerKnown = id, true
	end
	return ownerId
end

local function isAdminNow(player: Player): boolean
	local studio = RunService:IsStudio()
	return AdminSpawn.isAdmin(player.UserId, { studio = studio, ownerId = if studio then nil else placeOwner() })
end

-- Polls `done` every POLL_S until it holds (true) or `timeout` s passed (false).
local function waitFor(timeout: number, done: () -> boolean): boolean
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if done() then
			return true
		end
		task.wait(POLL_S)
	end
	return done()
end

local function inBaseOnFoot(player: Player): boolean
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local pocketId = player:GetAttribute("PocketId")
	return humanoid ~= nil and humanoid.SeatPart == nil and (pocketId == nil or pocketId == 0)
end

local function describe(request: AdminSpawn.Request): string
	local body = Bodies.get(request.bodyId)
	if request.mode == "Orbit" then
		return `in a {request.altitudeKm} km orbit around {body.DisplayName}`
	end
	return `landed on {body.DisplayName} ({request.spot})`
end

-- The spawn itself (header steps 1-3); runs in its own thread.
local function spawnShip(player: Player, request: AdminSpawn.Request)
	-- 1. leave the current flight
	if not inBaseOnFoot(player) then
		FlightService.leaveFlight(player)
		if not waitFor(LEAVE_TIMEOUT_S, function()
			return inBaseOnFoot(player)
		end) then
			notify:FireClient(player, "Could not leave your current flight, try again", "Error")
			return
		end
	end
	if player.Parent == nil then
		return
	end
	-- 2. roll out the plot's ship (or the starter rocket); CrewService seats the owner and the flight starts
	local design = BuildService.designOf(player)
	local starter = design == nil or not CraftService.canFly(design)
	local record = CraftService.rollOut(player, if starter then StarterCraft.design() else nil)
	if record == nil then
		return -- rollOut told the player why
	end
	if starter then
		notify:FireClient(player, "Your plot has no flyable rocket: here is the Starter Rocket", "Info")
	end
	if request.mode == "Landed" and request.spot == AdminSpawn.SPOT_PAD then
		notify:FireClient(player, `Spawned {describe(request)}. Press Space to launch!`, "Info")
		return
	end
	local started = waitFor(START_TIMEOUT_S, function()
		return record.sim ~= nil and record.pilot == player and CraftService.get(record.id) == record
	end)
	if not started then
		notify:FireClient(player, "The flight did not start in time, try again", "Error")
		return
	end
	task.wait(SETTLE_S)
	if CraftService.get(record.id) ~= record or record.pilot ~= player or record.sim == nil then
		return
	end
	-- 3. move it (the /orbit and /hover implementations)
	local ut = UniverseTime.now()
	if request.mode == "Orbit" then
		local pos = AdminSpawn.orbitState(request.bodyId, request.altitudeKm, ut)
		DebugService.placeInOrbit(record, request.bodyId, request.altitudeKm, Vec3d.normalize(pos))
	else
		local up = AdminSpawn.landingDirection(request.bodyId, request.spot, ut, os.time() + player.UserId)
		DebugService.placeHovering(record, request.bodyId, 0, up or FALLBACK_UP, true)
	end
	CraftService.freePad(record.id)
	notify:FireClient(player, `Spawned {describe(request)}`, "Info")
end

local function onSpawnRequest(player: Player, raw: unknown)
	if not admins[player] then
		notify:FireClient(player, "The admin panel is for admins only", "Error")
		return
	end
	if busy[player] then
		return
	end
	local now = os.clock()
	if not AdminSpawn.cooldownOk(lastSpawn[player], now) then
		notify:FireClient(player, "Wait a moment before spawning again", "Error")
		return
	end
	local request, problem = AdminSpawn.validate(raw)
	if request == nil then
		notify:FireClient(player, problem or "Bad request", "Error")
		return
	end
	lastSpawn[player] = now
	busy[player] = true
	task.spawn(function()
		local ok, err = pcall(function()
			spawnShip(player, request :: AdminSpawn.Request)
		end)
		busy[player] = nil
		if not ok then
			warn(`[AdminService] spawn failed for {player.Name}: {err}`)
			notify:FireClient(player, "Spawning failed", "Error")
		end
	end)
end

function AdminService.Init()
	notify = Remotes.event("Notify")
end

function AdminService.Start()
	Remotes.event("AdminSpawn").OnServerEvent:Connect(onSpawnRequest)
	local function onPlayer(player: Player)
		local admin = isAdminNow(player)
		admins[player] = admin
		player:SetAttribute(ADMIN_ATTRIBUTE, admin)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		admins[player] = nil
		busy[player] = nil
		lastSpawn[player] = nil
	end)
end

-- Is this player an admin (the server's own flag)?
function AdminService.isAdmin(player: Player): boolean
	return admins[player] == true
end

return AdminService
