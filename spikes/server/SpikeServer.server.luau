--!strict
--[[
	SpikeServer
	Starts spikes on request from any client and prints every result line to the server Output.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpikeKit = require(ReplicatedStorage:WaitForChild("SpikeShared"):WaitForChild("SpikeKit"))

--============================================================================
-- Tunables
--============================================================================
local MAX_REPORT_LENGTH = 2000
--============================================================================

local control = SpikeKit.serverRemote(SpikeKit.CONTROL_NAME)
local reportRemote = SpikeKit.serverRemote(SpikeKit.REPORT_NAME)

local CLIENT_DONE_LINE = "client part done" -- sent by SpikeClient when a client part finishes

-- A spike stays "running" until its server part AND every client that started it are done, so a double click
-- cannot start a second copy.
type RunState = { serverDone: boolean, pendingClients: { [Player]: boolean } }
local running: { [string]: RunState } = {}

local function finishIfDone(id: string)
	local state = running[id]
	if state and state.serverDone and next(state.pendingClients) == nil then
		running[id] = nil
	end
end

reportRemote.OnServerEvent:Connect(function(player: Player, id: unknown, line: unknown)
	if type(id) ~= "string" or type(line) ~= "string" then
		return
	end
	print(`[SPIKE {id}][{player.Name}] {string.sub(line, 1, MAX_REPORT_LENGTH)}`)
	local state = running[id]
	if state and line == CLIENT_DONE_LINE then
		state.pendingClients[player] = nil
		finishIfDone(id)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	for id, state in running do
		state.pendingClients[player] = nil
		finishIfDone(id)
	end
end)

control.OnServerEvent:Connect(function(player: Player, action: unknown, id: unknown)
	if action ~= "start" or type(id) ~= "string" then
		return
	end
	local def = SpikeKit.find(id)
	if def == nil then
		warn(`[SpikeServer] unknown spike {id}`)
		return
	end
	if running[id] then
		warn(`[SpikeServer] {id} is already running`)
		return
	end
	local pendingClients: { [Player]: boolean } = {}
	if def.Client then
		for _, other in Players:GetPlayers() do
			pendingClients[other] = true
		end
	end
	running[id] = { serverDone = def.Server == nil, pendingClients = pendingClients }
	print(`[SPIKE {id}] ===== START: {def.Title} (started by {player.Name}) =====`)
	control:FireAllClients("start", id)
	local server = def.Server
	if server then
		task.spawn(function()
			local ok, err = xpcall(function()
				server(SpikeKit.serverContext(id))
			end, debug.traceback)
			if not ok then
				warn(`[SPIKE {id}] server error: {err}`)
			end
			print(`[SPIKE {id}] ===== SERVER PART DONE =====`)
			local state = running[id]
			if state then
				state.serverDone = true
				finishIfDone(id)
			end
		end)
	else
		finishIfDone(id)
	end
end)

print("[SpikeServer] ready. Pick a spike from the menu on the client.")
