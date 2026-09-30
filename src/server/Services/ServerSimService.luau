--!strict
--[[
	ServerSimService (Phase 2a)
	Simulates every flying craft nobody's client simulates: debris and crafts whose pilot left, died or whose
	pocket emptied (spec 7.4, 7.8). Uses the same FlightModel as the pilots' clients, kept in step with Universal
	Time. Impacts destroy blocks through FlightService.applyDestruction. Debris that has come to rest is removed
	after a while, and so is very old debris (MAX_DEBRIS is enforced when debris is created).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local CraftService = require(script.Parent.CraftService)
local FlightService = require(script.Parent.FlightService)

--============================================================================
-- Tunables
--============================================================================
local STEP_DT = 1 / GameConfig.DEBRIS_SIM_RATE
local MAX_CATCH_UP_S = 0.25 -- never simulate more than this per tick after a hitch
local REST_SPEED = 0.5 -- m/s
local DEBRIS_REST_LIFETIME_S = 120 -- debris at rest this long is removed
local DEBRIS_MAX_AGE_S = 900
--============================================================================

local ServerSimService = {}

local accumulator = 0

local function tick()
	local now = UniverseTime.now()
	local clock = os.clock()
	for id, record in CraftService.all() do
		local sim = record.sim
		if record.serverSim and sim and record.state == "Flying" then
			-- catch the simulation up to the current UT in fixed chunks
			local behind = math.clamp(now - sim.state.ut, 0, MAX_CATCH_UP_S)
			if now - sim.state.ut > MAX_CATCH_UP_S then
				sim.state.ut = now - MAX_CATCH_UP_S
			end
			while behind >= STEP_DT * 0.5 do
				local dt = math.min(STEP_DT, behind)
				FlightModel.step(sim, dt)
				behind -= dt
				if #sim.destroyed > 0 then
					local destroyed = sim.destroyed
					sim.destroyed = {}
					FlightService.applyDestruction(record, destroyed)
					if CraftService.get(id) ~= record then
						break
					end
				end
			end
			if CraftService.get(id) == record and record.isDebris then
				local resting = bit32.band(sim.state.flags, FlightModel.FLAG_CONTACT) ~= 0
					and Vec3d.length(sim.state.vel) < REST_SPEED
				if resting then
					record.restingSince = record.restingSince or clock
				else
					record.restingSince = nil
				end
				if
					(record.restingSince and clock - (record.restingSince :: number) > DEBRIS_REST_LIFETIME_S)
					or clock - record.createdAt > DEBRIS_MAX_AGE_S
				then
					CraftService.remove(id)
				end
			end
		end
	end
end

function ServerSimService.Init() end

function ServerSimService.Start()
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator >= STEP_DT then
			accumulator = 0
			tick()
		end
	end)
end

return ServerSimService
