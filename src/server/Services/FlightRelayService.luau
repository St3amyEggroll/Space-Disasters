--!strict
--[[
	FlightRelayService (Phase 2a)
	Broadcasts every flying craft's latest state to all clients at CRAFT_STATE_RATE over the unreliable
	CraftStates remote, batched by Protocol (<= MAX_STATES_PER_PACKET per packet). Passengers use it for their
	pocket frame; everyone else for cosmetic copies. Phase 3 adds per-client interest management.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local CraftService = require(script.Parent.CraftService)

--============================================================================
-- Tunables
--============================================================================
local INTERVAL_S = 1 / GameConfig.CRAFT_STATE_RATE
--============================================================================

local FlightRelayService = {}

local remote: UnreliableRemoteEvent
local elapsed = 0

local function broadcast()
	local entries: { Protocol.Entry } = {}
	for id, record in CraftService.all() do
		local sim = record.sim
		if sim and record.state == "Flying" then
			table.insert(entries, { craftId = id, state = sim.state })
		end
	end
	if #entries == 0 then
		return
	end
	for _, packet in Protocol.encodeStates(entries) do
		remote:FireAllClients(packet)
	end
end

function FlightRelayService.Init()
	remote = Remotes.unreliable("CraftStates")
end

function FlightRelayService.Start()
	RunService.Heartbeat:Connect(function(dt: number)
		elapsed += dt
		if elapsed >= INTERVAL_S then
			elapsed = 0
			broadcast()
		end
	end)
end

return FlightRelayService
