--!strict
--[[
	RailsService (Phase 5, spec 7.8)
	Owns crafts on rails (record.state == "OnRails", record.rails = Shared/Sim/Rails rail).

	Going on rails
	  * Server-simulated crafts (uncrewed, pilot gone, debris): when Rails.eligible holds for RAILS_IDLE_TIME
	    (nobody steers them, so "no input" is automatic), the server puts them on rails.
	  * Piloted crafts: the pilot's client proposes a rail (RequestRails) after 0.5 s without input. It is checked
	    against the server copy's state (record.sim.state, the last VALID pilot state) and accepted, or refused
	    with CraftOffRails to that pilot (who waits RAILS_RETRY_S before trying again).
	  Accepting broadcasts CraftRails to everyone. While on rails nobody integrates or streams the craft: the pilot
	  sends no PilotState, FlightRelayService skips it, and every client samples the rail analytically.

	While on rails (every Heartbeat, cheap; SOI checks every SOI_CHECK_INTERVAL of UT)
	  * SOI changes: Rails.advance bisects the crossing to 0.01 s, re-expresses the rail in the new body's frame
	    and the new rail is broadcast. The server copy's state (sim.state) is kept in step with the rail.
	  * Rails end at rail.exitUT (the orbit reaches the atmosphere / rails floor): CraftOffRails, and the server
	    simulation (or the pilot) carries on.
	Going off rails: takeOffRails (pilot input arrives as a newer PilotState, staging, debug commands, the floor).

	Debris cleanup (every DEBRIS_CHECK_INTERVAL): suborbital debris (periapsis inside the atmosphere / surface)
	farther than DEBRIS_DESPAWN_DIST from every occupied pocket is deleted. Orbital debris persists (MAX_DEBRIS,
	oldest first, is enforced by CraftService.spawnDebris).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local CraftService = require(script.Parent.CraftService)
local PocketService = require(script.Parent.PocketService)

type CraftRecord = CraftService.CraftRecord

--============================================================================
-- Tunables
--============================================================================
local IDLE_TIME = GameConfig.RAILS_IDLE_TIME
local SOI_CHECK_INTERVAL = GameConfig.SOI_CHECK_INTERVAL
local POS_TOLERANCE = GameConfig.RAILS_POS_TOLERANCE
local VEL_TOLERANCE = GameConfig.RAILS_VEL_TOLERANCE
local EPOCH_TOLERANCE = 2 -- s between a proposed rail's epoch and the server's UT
local MAX_COM_OFFSET = 200 -- m; a proposed centre of mass farther than this from the root is refused
local DEBRIS_CHECK_INTERVAL = GameConfig.DEBRIS_CHECK_INTERVAL
local DEBRIS_DESPAWN_DIST = GameConfig.DEBRIS_DESPAWN_DIST
--============================================================================

local RailsService = {}

local remotes: { [string]: RemoteEvent } = {}
local lastCheck: { [number]: number } = {} -- craft id -> UT of the last SOI check
local eligibleSince: { [number]: number } = {} -- server-simulated craft id -> UT it became eligible
local debrisTimer = 0

--============================================================================
-- Helpers
--============================================================================

-- Copies the rail's state at `ut` into the server copy (keeps fuel, stages, controls).
local function syncSim(record: CraftRecord, rails: Rails.Rails, ut: number)
	local sim = record.sim
	if sim then
		sim.state = Rails.stateAt(rails, ut)
	end
end

local function broadcastRails(record: CraftRecord, rails: Rails.Rails)
	remotes.CraftRails:FireAllClients(Protocol.encodeRails(record.id, rails))
end

-- Puts a flying craft on rails and tells everyone.
function RailsService.putOnRails(record: CraftRecord, rails: Rails.Rails)
	if record.sim == nil or record.state == "Destroyed" then
		return
	end
	record.rails = rails
	record.state = "OnRails"
	lastCheck[record.id] = math.max(rails.epochUT, UniverseTime.now())
	eligibleSince[record.id] = nil
	syncSim(record, rails, UniverseTime.now())
	broadcastRails(record, rails)
end

--[[
	Takes a craft off rails at `ut` (default: now): the server copy continues from the rail's state there, and
	everyone is told (CraftOffRails); the pilot's PilotState stream / the server simulation resumes.
]]
function RailsService.takeOffRails(record: CraftRecord, ut: number?)
	if record.state ~= "OnRails" then
		return
	end
	local rails = record.rails
	local at = ut or UniverseTime.now()
	if rails then
		syncSim(record, rails, at)
		local sim = record.sim
		if sim then
			sim.sasTarget = nil
		end
	end
	record.rails = nil
	record.state = "Flying"
	lastCheck[record.id] = nil
	eligibleSince[record.id] = nil
	remotes.CraftOffRails:FireAllClients(record.id, at)
end

function RailsService.isOnRails(record: CraftRecord): boolean
	return record.state == "OnRails" and record.rails ~= nil
end

--============================================================================
-- Pilot proposals
--============================================================================

local function refuse(player: Player, craftId: number)
	remotes.CraftOffRails:FireClient(player, craftId, UniverseTime.now())
end

local function onRequestRails(player: Player, packet: unknown)
	local craftId, data = Protocol.decodeRails(packet)
	if craftId == nil or data == nil then
		return
	end
	local record = CraftService.get(craftId)
	local sim = if record then record.sim else nil
	if record == nil or sim == nil or record.pilot ~= player then
		return
	end
	if record.state ~= "Flying" then
		if record.state ~= "OnRails" then
			refuse(player, craftId)
		end
		return
	end
	local proposal = Rails.fromData(data)
	local valid = sim.state
	local now = UniverseTime.now()
	local ok = proposal ~= nil
		and data.bodyId == valid.bodyId
		and math.abs(data.epochUT - now) <= EPOCH_TOLERANCE
		and data.epochUT >= valid.ut - 0.5 -- not older than what the server already accepted
		and data.com.Magnitude <= MAX_COM_OFFSET
		and bit32.band(valid.flags, bit32.bor(FlightModel.FLAG_BURNING, FlightModel.FLAG_CONTACT)) == 0
	if ok then
		local rails = proposal :: Rails.Rails
		local expected = Rails.stateAt(rails, valid.ut)
		local altitude = Vec3d.length(rails.r0) - Bodies.get(rails.bodyId).Radius
		ok = Vec3d.distance(expected.pos, valid.pos) <= POS_TOLERANCE
			and Vec3d.distance(expected.vel, valid.vel) <= VEL_TOLERANCE
			and altitude >= Rails.minAltitude(rails.bodyId)
			and rails.exitUT > now
	end
	if ok then
		RailsService.putOnRails(record, proposal :: Rails.Rails)
	else
		refuse(player, craftId)
	end
end

--============================================================================
-- Per-frame upkeep
--============================================================================

local function updateOnRails(record: CraftRecord, rails: Rails.Rails, now: number)
	if now >= rails.exitUT then
		RailsService.takeOffRails(record, rails.exitUT)
		return
	end
	local from = lastCheck[record.id] or rails.epochUT
	if now - from < SOI_CHECK_INTERVAL then
		return
	end
	lastCheck[record.id] = now
	local changed = Rails.advance(rails, from, now)
	if changed then
		record.rails = changed
		broadcastRails(record, changed)
		syncSim(record, changed, now)
		if now >= changed.exitUT then
			RailsService.takeOffRails(record, now)
		end
	else
		syncSim(record, rails, now)
	end
end

local function updateServerSim(record: CraftRecord, now: number)
	local sim = record.sim :: FlightModel.Craft
	if not Rails.eligible(sim) then
		eligibleSince[record.id] = nil
		return
	end
	local since = eligibleSince[record.id]
	if since == nil then
		eligibleSince[record.id] = now
	elseif now - since >= IDLE_TIME then
		local state = FlightModel.copyState(sim.state)
		state.ut = math.min(state.ut, now)
		RailsService.putOnRails(record, Rails.fromState(state, sim.physics.com, sim.controls.sas))
	end
end

-- True positions of occupied pockets' references: { bodyId, pos }.
local function occupiedReferences(): { { bodyId: number, pos: Vec3d.Vec3d } }
	local list = {}
	if #PocketService.playersIn(PocketService.BASE_POCKET_ID) > 0 then
		local frame = PocketService.baseFrame()
		table.insert(list, { bodyId = frame.refBodyId, pos = frame.refPos })
	end
	for _, record in CraftService.all() do
		local pocketId = record.pocketId
		local sim = record.sim
		if pocketId and sim and #PocketService.playersIn(pocketId) > 0 then
			table.insert(list, { bodyId = sim.state.bodyId, pos = sim.state.pos })
		end
	end
	return list
end

local function cleanDebris(now: number)
	local references = occupiedReferences()
	local doomed = {}
	for id, record in CraftService.all() do
		local sim = record.sim
		if record.isDebris and sim then
			local rails = record.rails
			local s = if record.state == "OnRails" and rails then Rails.stateAt(rails, now) else sim.state
			if Rails.isSuborbital(s.bodyId, s.pos, s.vel) then
				local near = false
				for _, ref in references do
					local offset = Universe.bodyOffset(s.bodyId, ref.bodyId, now)
					local distance = Vec3d.distance(Vec3d.add(s.pos, offset), ref.pos)
					if distance <= DEBRIS_DESPAWN_DIST then
						near = true
						break
					end
				end
				if not near then
					table.insert(doomed, id)
				end
			end
		end
	end
	for _, id in doomed do
		CraftService.remove(id)
	end
end

local function heartbeat(dt: number)
	local now = UniverseTime.now()
	for id, record in CraftService.all() do
		local rails = record.rails
		if record.state == "OnRails" and rails then
			updateOnRails(record, rails, now)
		elseif record.state == "Flying" and record.serverSim and record.sim then
			updateServerSim(record, now)
		else
			eligibleSince[id] = nil
		end
	end
	-- forget crafts that no longer exist
	for id in lastCheck do
		if CraftService.get(id) == nil then
			lastCheck[id] = nil
		end
	end
	for id in eligibleSince do
		if CraftService.get(id) == nil then
			eligibleSince[id] = nil
		end
	end
	debrisTimer += dt
	if debrisTimer >= DEBRIS_CHECK_INTERVAL then
		debrisTimer = 0
		cleanDebris(now)
	end
end

--============================================================================
-- Lifecycle
--============================================================================

function RailsService.Init()
	for _, name in { "CraftRails", "CraftOffRails", "RequestRails" } do
		remotes[name] = Remotes.event(name)
	end
end

function RailsService.Start()
	remotes.RequestRails.OnServerEvent:Connect(onRequestRails)
	RunService.Heartbeat:Connect(heartbeat)
end

return RailsService
