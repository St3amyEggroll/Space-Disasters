--!strict
--[[
	EvaVisuals (Phase 6)
	The jetpack flame and the helmet light of astronauts on EVA, on this client. The jetpack model itself is built by
	the server (EvaService) and welded to the character, so everyone sees it; its attributes Thrust / Light say
	what it does. This module turns the flame emitters and the light on and off locally:
	  * the local astronaut from EvaController's own state at once (no round trip),
	  * other astronauts from the attributes, only while they are in the local player's pocket (PocketController
	    hides characters in other pockets, and must never find an emitter switched on there).
	Detail follows Render/Quality: the flame's particle rate scales with Quality.scale(), and the light casts
	shadows only on the High tier. Others are refreshed every REFRESH_S, the local astronaut every frame; nothing is
	created here (cheap on phones).

	API:
	  EvaVisuals.update(localThrust: boolean, localLight: boolean)   once per frame (EvaController)
]]

local Players = game:GetService("Players")

local Quality = require(script.Parent.Quality)

--============================================================================
-- Tunables
--============================================================================
local REFRESH_S = 0.1 -- s between refreshes of other astronauts' jetpacks
local JETPACK_NAME = "EvaJetpack" -- EvaService's model name
local FLAME_NAME = "Flame"
local LIGHT_NAME = "HelmetLight"
local FLAME_RATE = 60 -- particles per second per nozzle at full detail
--============================================================================

local EvaVisuals = {}

local lastRefresh = -math.huge

local function apply(jetpack: Instance, thrust: boolean, light: boolean)
	local rate = FLAME_RATE * Quality.scale()
	local shadows = Quality.tier() == "High"
	for _, descendant in jetpack:GetDescendants() do
		if descendant:IsA("ParticleEmitter") and descendant.Name == FLAME_NAME then
			if descendant.Enabled ~= thrust then
				descendant.Enabled = thrust
			end
			if descendant.Rate ~= rate then
				descendant.Rate = rate
			end
		elseif descendant:IsA("Light") and descendant.Name == LIGHT_NAME then
			if descendant.Enabled ~= light then
				descendant.Enabled = light
			end
			if descendant.Shadows ~= shadows then
				descendant.Shadows = shadows
			end
		end
	end
end

function EvaVisuals.update(localThrust: boolean, localLight: boolean)
	local localPlayer = Players.LocalPlayer
	local character = localPlayer.Character
	local own = if character then character:FindFirstChild(JETPACK_NAME) else nil
	if own then
		apply(own, localThrust, localLight)
	end
	local now = os.clock()
	if now - lastRefresh < REFRESH_S then
		return
	end
	lastRefresh = now
	local myPocket = localPlayer:GetAttribute("PocketId")
	for _, other in Players:GetPlayers() do
		local otherCharacter = other.Character
		local jetpack = if other ~= localPlayer and otherCharacter
			then otherCharacter:FindFirstChild(JETPACK_NAME)
			else nil
		if jetpack and other:GetAttribute("PocketId") == myPocket then
			apply(jetpack, jetpack:GetAttribute("Thrust") == true, jetpack:GetAttribute("Light") == true)
		end
	end
end

return table.freeze(EvaVisuals)
