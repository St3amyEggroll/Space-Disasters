--!strict
--[[
	RailsController (Phase 5, spec 7.8)
	The client mirror of the server's rails for OTHER crafts (and for the pilot's own craft as seen by passengers):
	  * CraftRails / CraftSpawned (info.rails) set the rail RemoteCraftRenderer samples a craft from; CraftOffRails
	    and CraftRemoved clear it (the resumed CraftStates stream takes over).
	  * SOI changes are mirrored for display: every SOI_CHECK_INTERVAL of UT each rail is advanced with the same
	    shared Rails.advance the server runs (crossing bisected to 0.01 s), so a craft is drawn in the right frame
	    before the server's new CraftRails arrives. The server's message then replaces the local result.
	  * A rail is dropped locally at its exitUT (the orbit reaches the atmosphere / rails floor); the server's
	    CraftOffRails follows and states resume.
	The pilot's own simulation handles its own rail (FlightController).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local DebugOverlay = require(script.Parent.DebugOverlay)
local RemoteCraftRenderer = require(script.Parent.RemoteCraftRenderer)

--============================================================================
-- Tunables
--============================================================================
local SOI_CHECK_INTERVAL = GameConfig.SOI_CHECK_INTERVAL
local EXIT_GRACE_S = 0.5 -- s past exitUT a rail is kept while the server's CraftOffRails is on its way
--============================================================================

local RailsController = {}

local lastCheck: { [number]: number } = {} -- craft id -> UT of the last local SOI check
local tracked: { [number]: boolean } = {}

local function setRails(craftId: number, rails: Rails.Rails?)
	local now = UniverseTime.now()
	RemoteCraftRenderer.setRails(craftId, rails, now)
	if rails then
		tracked[craftId] = true
		-- the server has checked everything up to about now
		lastCheck[craftId] = math.max(rails.epochUT, now)
	else
		tracked[craftId] = nil
		lastCheck[craftId] = nil
	end
end

local function onCraftRails(packet: unknown)
	local craftId, data = Protocol.decodeRails(packet)
	if craftId == nil or data == nil then
		return
	end
	setRails(craftId, Rails.fromData(data))
end

local function onOffRails(craftId: unknown, _ut: unknown)
	if type(craftId) == "number" and tracked[craftId] then
		setRails(craftId, nil)
	end
end

local function onSpawned(craftId: unknown, _design: unknown, _state: unknown, info: unknown)
	if type(craftId) ~= "number" then
		return
	end
	local railsBuffer = if type(info) == "table" then (info :: { [string]: any }).rails else nil
	local id, data = Protocol.decodeRails(railsBuffer)
	if id == craftId and data then
		setRails(craftId, Rails.fromData(data))
	elseif tracked[craftId] then
		setRails(craftId, nil)
	end
end

local function onRemoved(craftId: unknown)
	if type(craftId) == "number" then
		tracked[craftId] = nil
		lastCheck[craftId] = nil
	end
end

local function update()
	local now = UniverseTime.now()
	for craftId in tracked do
		local rails = RemoteCraftRenderer.railsOf(craftId)
		if rails == nil then
			tracked[craftId] = nil
			lastCheck[craftId] = nil
			continue
		end
		local current = rails :: Rails.Rails
		if now >= current.exitUT + EXIT_GRACE_S then
			setRails(craftId, nil)
			continue
		end
		local from = lastCheck[craftId] or current.epochUT
		if now - from >= SOI_CHECK_INTERVAL then
			lastCheck[craftId] = now
			local changed = Rails.advance(current, from, now)
			if changed then
				RemoteCraftRenderer.setRails(craftId, changed, now)
			end
		end
	end
end

function RailsController.Init()
	DebugOverlay.addLine("rails", 23, function()
		local count = 0
		for _ in tracked do
			count += 1
		end
		return string.format("Rails: %d other craft(s) on rails", count)
	end)
end

function RailsController.Start()
	Remotes.event("CraftRails").OnClientEvent:Connect(onCraftRails)
	Remotes.event("CraftOffRails").OnClientEvent:Connect(onOffRails)
	Remotes.event("CraftSpawned").OnClientEvent:Connect(onSpawned)
	Remotes.event("CraftRemoved").OnClientEvent:Connect(onRemoved)
	RunService.Heartbeat:Connect(update)
end

-- Is this craft drawn from a rail on this client?
function RailsController.isOnRails(craftId: number): boolean
	return RemoteCraftRenderer.railsOf(craftId) ~= nil
end

return RailsController
