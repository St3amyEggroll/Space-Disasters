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
	PlaceBlock = "Reliable", -- (partId: string, gx: number, gy: number, gz: number, rot: number)
	RemoveBlock = "Reliable", -- (gx: number, gy: number, gz: number) removes the block occupying that cell
	ClearPlot = "Reliable", -- ()
	SaveDesign = "Reliable", -- (slot: number, name: string)
	LoadDesign = "Reliable", -- (slot: number)
	RollOut = "Reliable", -- ()
	SetBoardingPermission = "Reliable", -- (mode: "Private" | "Friends" | "Public")
	-- Build (server -> client)
	SaveSlots = "Reliable", -- (names: { [number]: string }) slot index -> design name for filled slots
	Notify = "Reliable", -- (text: string, kind: "Info" | "Error")
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
