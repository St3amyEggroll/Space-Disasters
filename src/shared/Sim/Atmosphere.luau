--!strict
--[[
	Atmosphere
	Density and pressure ratio by body and altitude (spec 6.1):
	  rho(h) = rho0 * e^(-h / H) * clamp((top - h) / FADE_BAND, 0, 1)
	Pressure ratio for Isp = rho / rho0. Bodies without an atmosphere return 0. Pure module.
]]

local Bodies = require(script.Parent.Parent.Config.Bodies)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local FADE_BAND = GameConfig.ATMOSPHERE_FADE_BAND
--============================================================================

local Atmosphere = {}

-- Air density (kg/m^3) at an altitude above sea level.
function Atmosphere.density(bodyId: number, altitude: number): number
	local atmosphere = Bodies.get(bodyId).Atmosphere
	if atmosphere == nil or altitude >= atmosphere.Top then
		return 0
	end
	local h = math.max(altitude, 0)
	local fade = math.clamp((atmosphere.Top - h) / FADE_BAND, 0, 1)
	return atmosphere.Rho0 * math.exp(-h / atmosphere.ScaleHeight) * fade
end

-- rho / rho0 (0 in vacuum, 1 at sea level).
function Atmosphere.pressureRatio(bodyId: number, altitude: number): number
	local atmosphere = Bodies.get(bodyId).Atmosphere
	if atmosphere == nil then
		return 0
	end
	return Atmosphere.density(bodyId, altitude) / atmosphere.Rho0
end

-- True while below the atmosphere top (used for warp/rails rules and visuals).
function Atmosphere.isInside(bodyId: number, altitude: number): boolean
	local atmosphere = Bodies.get(bodyId).Atmosphere
	return atmosphere ~= nil and altitude < atmosphere.Top
end

-- Top of the atmosphere (m), or 0 when the body has none.
function Atmosphere.top(bodyId: number): number
	local atmosphere = Bodies.get(bodyId).Atmosphere
	return if atmosphere then atmosphere.Top else 0
end

return table.freeze(Atmosphere)
