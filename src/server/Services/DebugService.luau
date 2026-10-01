--!strict
--[[
	DebugService (spec 7.14)
	Chat commands for Studio and whitelisted user ids (GameConfig.DEBUG_USER_IDS):
	  /orbit <altKm> [body]   put your craft in a circular orbit (body: kablamo/homeworld or dent/moon)
	  /fuel                   refill your craft
	  /base                   go back to your plot
	  /time <hour>            set the time of day at the base (0..24, 12 = noon; everyone sees it)
	"Your craft" = the craft you pilot, else the craft whose pocket you are in.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local CraftService = require(script.Parent.CraftService)
local PlotService = require(script.Parent.PlotService)
local RailsService = require(script.Parent.RailsService) -- CHANGED (Phase 5)

--============================================================================
-- Tunables
--============================================================================
local PREFIX = "/"
--============================================================================

local DebugService = {}

local notify: RemoteEvent
local override: RemoteEvent

local function allowed(player: Player): boolean
	return RunService:IsStudio() or table.find(GameConfig.DEBUG_USER_IDS, player.UserId) ~= nil
end

local function craftOf(player: Player): CraftService.CraftRecord?
	local pocketId = player:GetAttribute("PocketId")
	local fallback: CraftService.CraftRecord? = nil
	for _, record in CraftService.all() do
		if record.sim then
			if record.pilot == player then
				return record
			end
			if record.pocketId ~= nil and record.pocketId == pocketId then
				fallback = record
			end
		end
	end
	return fallback
end

-- Pushes a new state to whoever simulates the craft.
local function setState(record: CraftService.CraftRecord, state: FlightModel.CraftState)
	-- CHANGED (Phase 5): leave rails first; the craft goes back on rails after RAILS_IDLE_TIME without input
	RailsService.takeOffRails(record)
	local sim = record.sim :: FlightModel.Craft
	sim.state = state
	sim.sasTarget = nil
	if record.pilot then
		override:FireClient(record.pilot, record.id, Protocol.encodeState(record.id, state), false)
	end
end

local function orbit(player: Player, args: { string })
	local record = craftOf(player)
	local altKm = tonumber(args[2])
	if record == nil or altKm == nil then
		notify:FireClient(player, "Usage: /orbit <altKm> [body] while in a flying craft", "Error")
		return
	end
	local sim = record.sim :: FlightModel.Craft
	local bodyId = sim.state.bodyId
	if args[3] then
		local body = Bodies.findByName(args[3])
		if body == nil or body.VisualOnly then
			notify:FireClient(player, `Unknown body {args[3]}`, "Error")
			return
		end
		bodyId = body.Id
	end
	local body = Bodies.get(bodyId)
	local radius = body.Radius + altKm * 1000
	local radial = if bodyId == sim.state.bodyId then Vec3d.normalize(sim.state.pos) else Vec3d.new(1, 0, 0)
	local east = Vec3d.cross(radial, Vec3d.new(0, 1, 0))
	if Vec3d.length(east) < 1e-6 then
		east = Vec3d.new(0, 0, 1)
	end
	east = Vec3d.normalize(east)
	local state = FlightModel.copyState(sim.state)
	state.bodyId = bodyId
	state.pos = Vec3d.scale(radial, radius)
	state.vel = Vec3d.scale(east, Universe.circularSpeed(bodyId, radius))
	state.angVel = Vector3.zero
	setState(record, state)
	notify:FireClient(player, `Orbit set: {altKm} km around {body.DisplayName}`)
end

local function refuel(player: Player)
	local record = craftOf(player)
	if record == nil then
		notify:FireClient(player, "You are not in a flying craft", "Error")
		return
	end
	local sim = record.sim :: FlightModel.Craft
	local full = FlightModel.fullFuel(sim.physics.design)
	for id, amount in full do
		sim.fuel[id] = amount
	end
	sim.mass = sim.physics.dryMass + FlightModel.totalFuel(sim)
	if record.pilot then
		override:FireClient(record.pilot, record.id, nil, true)
	end
	notify:FireClient(player, "Refuelled")
end

local function toBase(player: Player)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	if character == nil or humanoid == nil then
		return
	end
	local seat = humanoid.SeatPart
	if seat then
		local weld = seat:FindFirstChild("SeatWeld")
		if weld then
			weld:Destroy()
		end
		humanoid.Sit = false
		task.wait()
	end
	character:PivotTo(PlotService.spawnCFrame(player)) -- CHANGED (Phase 2a feedback): home = your plot
	player:SetAttribute("PocketId", 0)
end

-- CHANGED (Phase 2a playtest 4): jump to a time of day to check day / night / sunsets.
local function setTime(player: Player, args: { string })
	local hour = tonumber(args[2])
	if hour == nil or hour < 0 or hour > 24 then
		notify:FireClient(player, "Usage: /time <hour 0-24>  (12 = noon, 0 = midnight)", "Error")
		return
	end
	local offset = Universe.sunOffsetForBaseHour(hour, UniverseTime.now())
	Universe.setSunPhaseOffset(offset)
	ReplicatedStorage:WaitForChild("Globals"):SetAttribute(Universe.SUN_OFFSET_ATTRIBUTE, offset)
	notify:FireClient(
		player,
		string.format("Time at the base set to %02d:%02d", math.floor(hour), math.floor(hour % 1 * 60))
	)
end

local function onChatted(player: Player, message: string)
	if string.sub(message, 1, #PREFIX) ~= PREFIX or not allowed(player) then
		return
	end
	local args = string.split(string.lower(message), " ")
	local command = string.sub(args[1], #PREFIX + 1)
	if command == "orbit" then
		orbit(player, args)
	elseif command == "fuel" then
		refuel(player)
	elseif command == "base" then
		toBase(player)
	elseif command == "time" then
		setTime(player, args)
	end
end

function DebugService.Init()
	notify = Remotes.event("Notify")
	override = Remotes.event("FlightOverride")
end

function DebugService.Start()
	local function onPlayer(player: Player)
		player.Chatted:Connect(function(message: string)
			onChatted(player, message)
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		onPlayer(player)
	end
end

return DebugService
