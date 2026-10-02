--!strict
--[[
	Boarding
	CHANGED (Boarding): the rules for boarding a craft whose real model lives in ANOTHER pocket. Once a pilot sits
	down the craft moves into its own flight pocket (D31), so players on foot in the base pocket only see its
	cosmetic copy (RemoteCraftRenderer) and could never board it, not even while it still stands on its pad. The
	client now puts seat prompts on the copy (Render/BoardPrompts) and asks the server with the remote
	BoardCraft(craftId, seatBlockId); the server (FlightService) checks the request with these same rules, then
	seats the player in the real model and moves them into the flight pocket.

	Pure module (no services, no Instances): shared by client and server and covered by Boarding.spec.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local BASE_POCKET_ID = 0 -- same as PocketService.BASE_POCKET_ID
local MAX_SPEED = GameConfig.BOARD_MAX_SPEED -- m/s relative to the ground
local RANGE = GameConfig.BOARD_RANGE -- m beyond the craft's bounding radius
local MAX_ID = 2 ^ 31 -- craft and block ids above this are malformed requests
local BOARDABLE_STATES = table.freeze({ Flying = true, Landed = true, OnRails = true })
--============================================================================

local Boarding = {}

Boarding.MAX_SPEED = MAX_SPEED
Boarding.RANGE = RANGE

-- A craft or block id from the network: a positive integer, or nil for anything else (NaN, inf, strings, ...).
function Boarding.validId(value: unknown): number?
	if type(value) ~= "number" then
		return nil
	end
	local n = value :: number
	if n ~= n or n < 1 or n > MAX_ID or n % 1 ~= 0 then
		return nil
	end
	return n
end

-- Craft states that can be boarded from another pocket (Prelaunch crafts stand in the base pocket itself and are
-- boarded through their real SitPrompts; destroyed crafts are gone).
function Boarding.boardableState(state: string): boolean
	return BOARDABLE_STATES[state] == true
end

-- Is a craft moving slowly enough (m/s relative to the ground) to be boarded?
function Boarding.slowEnough(speed: number): boolean
	return speed == speed and speed >= 0 and speed < MAX_SPEED
end

-- Is a player `distance` m from a craft's reference point close enough to board a craft of `craftRadius` m?
function Boarding.inRange(distance: number, craftRadius: number): boolean
	local radius = if craftRadius == craftRadius then math.max(craftRadius, 0) else 0
	return distance == distance and distance >= 0 and distance <= radius + RANGE
end

-- Client: does the cosmetic copy of a craft get boarding prompts? Only for a player in the base pocket, on crafts
-- flying (not debris) in another pocket, while they are slow.
function Boarding.offersPrompts(
	localPocketId: number,
	craftPocketId: number,
	prelaunch: boolean,
	isDebris: boolean,
	speed: number
): boolean
	return localPocketId == BASE_POCKET_ID
		and craftPocketId ~= BASE_POCKET_ID
		and not prelaunch
		and not isDebris
		and Boarding.slowEnough(speed)
end

-- Client: is it worth offering prompts on a craft with this boarding mode (the real model's Boarding attribute)?
-- Private crafts of other players never are; Friends is left to the server (it knows who is a friend).
function Boarding.modeMayAllow(mode: unknown, ownerUserId: number, userId: number): boolean
	return mode ~= "Private" or ownerUserId == userId
end

-- Rate limit: has at least `cooldown` s passed since `last` (nil = never)?
function Boarding.cooldownOver(last: number?, now: number, cooldown: number): boolean
	return last == nil or now - last >= cooldown
end

return table.freeze(Boarding)
