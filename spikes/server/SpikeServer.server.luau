--!strict
--[[
	SpikeServer
	Starts spikes on request from any client and prints every result line to the server Output.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SpikeKit = require(ReplicatedStorage:WaitForChild("SpikeShared"):WaitForChild("SpikeKit"))

--============================================================================
-- Tunables
--============================================================================
local MAX_REPORT_LENGTH = 2000
--============================================================================

local control = SpikeKit.serverRemote(SpikeKit.CONTROL_NAME)
local reportRemote = SpikeKit.serverRemote(SpikeKit.REPORT_NAME)

local running: { [string]: boolean } = {}

reportRemote.OnServerEvent:Connect(function(player: Player, id: unknown, line: unknown)
	if type(id) ~= "string" or type(line) ~= "string" then
		return
	end
	print(`[SPIKE {id}][{player.Name}] {string.sub(line, 1, MAX_REPORT_LENGTH)}`)
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
	running[id] = true
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
			running[id] = nil
		end)
	else
		running[id] = nil
	end
end)

print("[SpikeServer] ready. Pick a spike from the menu on the client.")
