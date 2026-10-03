--!strict
--[[
	DebugService (spec 7.14)
	Chat commands for Studio and whitelisted user ids (GameConfig.DEBUG_USER_IDS):
	  /orbit <altKm> [body]   put your craft in a circular orbit (body: earth/homeworld or mun/moon)
	  /fuel                   refill your craft
	  /base                   go back to your plot
	  /time <hour>            set the time of day at the base (0..24, 12 = noon; everyone sees it)
	  /hover <m> [body]       CHANGED (Phase 8): put your craft upright and still, <m> metres above the terrain under
	                          it (or above a hilly spot of another body) to test landings on slopes
	  /bands                  CHANGED (Far slabs fix): toggle your terrain debug view (each terrain band in a flat
	                          colour, plates white, the launch-site copy cyan; DebugView remote, client only)
	"Your craft" = the craft you pilot, else the craft whose pocket you are in.
	CHANGED (Solar system): bodies are earth/homeworld, mun/moon, mars and sol/sun (orbit only: /hover over Sol
	burns the craft up). The two placements are exported for the admin panel (AdminService), so it uses exactly
	these implementations: DebugService.placeInOrbit(record, bodyId, altKm, radial?) and
	DebugService.placeHovering(record, bodyId, metres, up?, onGround?) (onGround: the craft's lowest point, not its
	bounding radius, sits `metres` above the ground: a gentle landing).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames) -- CHANGED (Phase 8)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight) -- CHANGED (Phase 8)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local CraftService = require(script.Parent.CraftService)
local FlightService = require(script.Parent.FlightService) -- CHANGED (Phase 6): /base from a spacewalk
local PlotService = require(script.Parent.PlotService)
local RailsService = require(script.Parent.RailsService) -- CHANGED (Phase 5)

--============================================================================
-- Tunables
--============================================================================
local PREFIX = "/"
local HOVER_OTHER_BODY_DIR = Vec3d.normalize(Vec3d.new(-1, 0.25, 0.15)) -- CHANGED (Phase 8): /hover spot on another body
local HOVER_MAX_M = 20000
local GROUND_CLEARANCE = 1 -- CHANGED (Solar system): m between the lowest hull point and the ground (onGround)
--============================================================================

local DebugService = {}

local notify: RemoteEvent
local override: RemoteEvent
local debugView: RemoteEvent -- CHANGED (Far slabs fix)

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

-- CHANGED (Solar system): the /orbit placement, exported (header). `radial` = where on the orbit (body axes).
local function placeInOrbit(record: CraftService.CraftRecord, bodyId: number, altKm: number, radial: Vec3d.Vec3d?)
	local sim = record.sim :: FlightModel.Craft
	local body = Bodies.get(bodyId)
	local radius = body.Radius + altKm * 1000
	local dir = radial or if bodyId == sim.state.bodyId then Vec3d.normalize(sim.state.pos) else Vec3d.new(1, 0, 0)
	local east = Vec3d.cross(dir, Vec3d.new(0, 1, 0))
	if Vec3d.length(east) < 1e-6 then
		east = Vec3d.new(0, 0, 1)
	end
	east = Vec3d.normalize(east)
	local state = FlightModel.copyState(sim.state)
	state.bodyId = bodyId
	state.pos = Vec3d.scale(dir, radius)
	state.vel = Vec3d.scale(east, Universe.circularSpeed(bodyId, radius))
	state.angVel = Vector3.zero
	setState(record, state)
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
	placeInOrbit(record, bodyId, altKm, nil)
	notify:FireClient(player, `Orbit set: {altKm} km around {Bodies.get(bodyId).DisplayName}`)
end

-- CHANGED (Solar system): the /hover placement, exported (header). `up` = the ground spot (body axes).
local function placeHovering(
	record: CraftService.CraftRecord,
	bodyId: number,
	metres: number,
	up: Vec3d.Vec3d?,
	onGround: boolean?
)
	local sim = record.sim :: FlightModel.Craft
	local dir = up or if bodyId == sim.state.bodyId then Vec3d.normalize(sim.state.pos) else HOVER_OTHER_BODY_DIR
	local ground = SurfaceHeight.groundPoint(bodyId, dir)
	local lift = metres + sim.physics.boundingRadius
	if onGround then
		-- upright: craft +Y is up, so the lowest hull point is the smallest hull Y
		local lowest = 0
		for _, point in sim.physics.hull do
			lowest = math.min(lowest, point.pos.Y)
		end
		lift = metres + GROUND_CLEARANCE - lowest
	end
	local state = FlightModel.copyState(sim.state)
	state.bodyId = bodyId
	state.pos = Vec3d.add(ground, Vec3d.scale(dir, lift))
	state.vel = Vec3d.zero()
	state.rot = Frames.surfaceRotation(dir)
	state.angVel = Vector3.zero
	setState(record, state)
end

-- CHANGED (Phase 8): /hover <m> [body]: upright and at rest, <m> metres (plus the craft's radius) above the terrain.
local function hover(player: Player, args: { string })
	local record = craftOf(player)
	local metres = tonumber(args[2])
	if record == nil or metres == nil or metres < 0 or metres > HOVER_MAX_M then
		notify:FireClient(player, "Usage: /hover <metres 0-20000> [body] while in a flying craft", "Error")
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
	placeHovering(record, bodyId, metres, nil, false)
	notify:FireClient(player, `Hovering {metres} m above {Bodies.get(bodyId).DisplayName}'s ground`)
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
	-- CHANGED (Phase 6): from a flight pocket (a spacewalk too) like End Flight / Return to plot: a PocketTransfer
	-- home (an astronaut's client places his character every frame and would undo a bare teleport)
	-- CHANGED (Night review): seated in a flight pocket too (was: unseat, teleport and a bare PocketId = 0 without a
	-- transfer or pin, so trackPlayers could flip the PocketId back for a moment and the client started an EVA at
	-- the plot)
	local pocketId = player:GetAttribute("PocketId")
	if type(pocketId) == "number" and pocketId ~= 0 then
		FlightService.sendHome(player, pocketId)
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
	elseif command == "hover" then
		hover(player, args) -- CHANGED (Phase 8)
	elseif command == "bands" then
		debugView:FireClient(player, "bands") -- CHANGED (Far slabs fix): the client toggles its terrain band view
	end
end

-- CHANGED (Solar system): the /orbit and /hover placements for the admin panel (header)
function DebugService.placeInOrbit(
	record: CraftService.CraftRecord,
	bodyId: number,
	altKm: number,
	radial: Vec3d.Vec3d?
)
	placeInOrbit(record, bodyId, altKm, radial)
end

function DebugService.placeHovering(
	record: CraftService.CraftRecord,
	bodyId: number,
	metres: number,
	up: Vec3d.Vec3d?,
	onGround: boolean?
)
	placeHovering(record, bodyId, metres, up, onGround)
end

function DebugService.Init()
	notify = Remotes.event("Notify")
	override = Remotes.event("FlightOverride")
	debugView = Remotes.event("DebugView") -- CHANGED (Far slabs fix)
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
