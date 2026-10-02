--!strict
--[[
	Remotes
	Every remote in the game, by name and kind. The server creates them under ReplicatedStorage.Remotes in
	Remotes.createAll() (called from the first service's Init); both sides fetch them with Remotes.event(name) /
	Remotes.unreliable(name). Clients wait for them to replicate.

	Argument conventions are documented next to each name. The server validates every argument (never trust the
	client); RemoteEvent handlers should type their arguments as `unknown`.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--============================================================================
-- Tunables
--============================================================================
local FOLDER_NAME = "Remotes"
local CLIENT_WAIT_TIMEOUT = 30 -- s
--============================================================================

type Kind = "Reliable" | "Unreliable"

local DEFINITIONS: { [string]: Kind } = {
	-- Build (client -> server)
	PlaceBlock = "Reliable", -- (partId: string, gx, gy, gz: number, rot: number, seq: number?, color: number?)
	RemoveBlock = "Reliable", -- (gx, gy, gz: number, seq: number?) removes the block occupying that cell
	PaintBlock = "Reliable", -- (gx, gy, gz: number, color: number (Paint index, 0 = default), seq: number?)
	ClearPlot = "Reliable", -- ()
	SaveDesign = "Reliable", -- (slot: number, name: string)
	LoadDesign = "Reliable", -- (slot: number)
	RollOut = "Reliable", -- ()
	SetBoardingPermission = "Reliable", -- (mode: "Private" | "Friends" | "Public")
	-- Build (server -> client)
	SaveSlots = "Reliable", -- (names: { [number]: string }) slot index -> design name for filled slots
	Notify = "Reliable", -- (text: string, kind: "Info" | "Error")
	-- CHANGED (Phase 2a): flight
	RequestStage = "Reliable", -- (craftId) pilot pressed Space: launch from the pad, or fire the next stage
	LeaveSeat = "Reliable", -- () pilot/passenger pressed F
	ReportPartsDestroyed = "Reliable", -- (craftId, blockIds: {number}, ut) pilot's sim saw impacts
	FlightStart = "Reliable", -- server -> pilot (craftId, stateBuffer, stagesFired, designBuffer, resume?) start simulating
	--   CHANGED (Phase 3): resume (a pilot taking over a craft already in flight) = { stageIndex: number,
	--   stages: { CraftGraph.Stage }, active: { number }, fuel: { { blockId, kg } } }; designBuffer is then the
	--   craft's CURRENT design (stages fired, parts lost)
	FlightEnd = "Reliable", -- CHANGED (Phase 3): server -> former pilot (craftId) the server simulates the craft now
	FlightOverride = "Reliable", -- server -> pilot (craftId, stateBuffer?, refuel: boolean) debug / reset
	CraftSpawned = "Reliable", -- (craftId, designBuffer, stateBuffer, info: {ownerUserId, pocketId, active: {number}, rails: buffer?})
	--   CHANGED (Phase 3): info also has name, ownerName, isDebris, prelaunch (a rolled-out craft on its pad in the base
	--   pocket, announced so players in other pockets see it; pocketId is then 0 = base)
	--   CHANGED (Phase 5): info.rails = Protocol.encodeRails when the craft is on rails (join snapshot included)
	RequestSnapshot = "Reliable", -- CHANGED (Phase 3): client -> server () once its handlers are connected; the server
	--   answers with one CraftSpawned per known craft (join snapshot, spec 7.7)
	CraftRemoved = "Reliable", -- (craftId)
	CraftStaged = "Reliable", -- (craftId, stageIndex, ut, ignited: {number}, decoupled: {number}, debris: {{craftId, blockIds}})
	PartsDestroyed = "Reliable", -- (craftId, blockIds: {number}, ut, pieces: {{craftId, blockIds}})
	PocketTransfer = "Reliable", -- (transferId, sourcePocket, destPocket, M: CFrame, frameEpoch)
	PocketTransferAck = "Reliable", -- (transferId)
	PilotState = "Unreliable", -- client -> server, Protocol.encodePilotState (20 Hz)
	CraftStates = "Unreliable", -- server -> client, Protocol.encodeStates batches
	-- CHANGED (Phase 5): rails (spec 7.8)
	CraftRails = "Reliable", -- server -> client (railsBuffer) Protocol.encodeRails: the craft is on rails (new epoch)
	CraftOffRails = "Reliable", -- server -> client (craftId, ut) the craft left rails; its state stream resumes
	RequestRails = "Reliable", -- pilot -> server (railsBuffer) proposes rails for the piloted craft
	BuildAck = "Reliable", -- (seq, kind: "place" | "remove" | "paint", partId, gx, gy, gz, rot, color: number)
	--   color: the block's colour (0 = default); for "paint" it is the colour BEFORE the change (for undo)
	--   sent only for ACCEPTED operations that carried a seq > 0; the client builds its undo stack from these
	-- CHANGED (Phase 11): player settings (SettingsSchema JSON, stored by SettingsService through SaveService)
	RequestSettings = "Reliable", -- client -> server () asks for the saved settings; answered with SettingsData
	SettingsData = "Reliable", -- server -> client (json: string?) the saved settings re-sanitized, nil = none saved
	SaveSettings = "Reliable", -- client -> server (json: string) SettingsSchema.encode output, <= MAX_JSON_BYTES
	-- CHANGED (Phase 11): End Flight from the flight HUD (no pause menu)
	EndFlight = "Reliable", -- client -> server () no arguments; the craft is the one whose seat the player sits in.
	--   Its pilot (or its owner aboard) ends the flight for everyone: the craft is removed and everyone aboard goes
	--   back to their plot. Anyone else only leaves: they go back to their plot and the craft flies on.
	-- CHANGED (Boarding): boarding a craft in another pocket from the base (Shared/Craft/Boarding)
	BoardCraft = "Reliable", -- client -> server (craftId: number, seatBlockId: number) a player on foot in the base
	--   pocket triggered a seat prompt on the cosmetic copy of a craft flying in another pocket; seatBlockId is the
	--   id of the block holding the seat (one seat per block). The server checks everything, seats the player in the
	--   real model and sends them an identity PocketTransfer base -> flight pocket (it placed the character itself).
}

local Remotes = {}

local function folder(): Instance
	local existing = ReplicatedStorage:FindFirstChild(FOLDER_NAME)
	if existing then
		return existing
	end
	if RunService:IsServer() then
		local created = Instance.new("Folder")
		created.Name = FOLDER_NAME
		created.Parent = ReplicatedStorage
		return created
	end
	local waited = ReplicatedStorage:WaitForChild(FOLDER_NAME, CLIENT_WAIT_TIMEOUT)
	assert(waited, "ReplicatedStorage.Remotes never appeared")
	return waited
end

-- Server: creates every remote. Idempotent.
function Remotes.createAll()
	assert(RunService:IsServer(), "Remotes.createAll is server-only")
	local parent = folder()
	for name, kind in DEFINITIONS do
		if parent:FindFirstChild(name) == nil then
			local remote = Instance.new(if kind == "Reliable" then "RemoteEvent" else "UnreliableRemoteEvent")
			remote.Name = name
			remote.Parent = parent
		end
	end
end

local function fetch(name: string): Instance
	assert(DEFINITIONS[name] ~= nil, `Unknown remote {name}`)
	local parent = folder()
	local remote = if RunService:IsServer()
		then parent:FindFirstChild(name)
		else parent:WaitForChild(name, CLIENT_WAIT_TIMEOUT)
	assert(remote, `Remote {name} does not exist (server: call Remotes.createAll first)`)
	return remote
end

function Remotes.event(name: string): RemoteEvent
	assert(DEFINITIONS[name] == "Reliable", `{name} is not a reliable remote`)
	return fetch(name) :: RemoteEvent
end

function Remotes.unreliable(name: string): UnreliableRemoteEvent
	assert(DEFINITIONS[name] == "Unreliable", `{name} is not an unreliable remote`)
	return fetch(name) :: UnreliableRemoteEvent
end

return table.freeze(Remotes)
