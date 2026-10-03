--!strict
--[[
	Atmosphere
	Density and pressure ratio by body and altitude (spec 6.1):
	  rho(h) = rho0 * e^(-h / H) * clamp((top - h) / FADE_BAND, 0, 1)
	Pressure ratio for Isp = rho / rho0. Bodies without an atmosphere return 0. Pure module.
	CHANGED (Solar system): the pressure ratio is rho / Earth's sea-level rho (REFERENCE_RHO), not the body's own
	rho0: Mars' thin air is ~2% of Earth's, so engines there run near their vacuum Isp (Earth is unchanged).
]]

local Bodies = require(script.Parent.Parent.Config.Bodies)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local FADE_BAND = GameConfig.ATMOSPHERE_FADE_BAND
local REFERENCE_RHO = 1.225 -- CHANGED (Solar system): kg/m^3, Earth's sea level = pressure ratio 1
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

-- rho / Earth's sea-level rho (0 in vacuum, 1 at Earth's sea level). CHANGED (Solar system): was rho / rho0.
function Atmosphere.pressureRatio(bodyId: number, altitude: number): number
	local atmosphere = Bodies.get(bodyId).Atmosphere
	if atmosphere == nil then
		return 0
	end
	return math.min(Atmosphere.density(bodyId, altitude) / REFERENCE_RHO, 1)
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
