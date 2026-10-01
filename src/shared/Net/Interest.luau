--!strict
--[[
	Interest (Phase 3, spec 7.7)
	Pure interest-management rules for the CraftStates relay: how often each client hears about each craft.
	FlightRelayService runs them per client per relay tick; they are pure so Lune can test them offline.

	Tiers (per client, per craft):
	  Pocket  the craft is in the client's own pocket                          INTEREST_RATE_NEAR (20 Hz)
	  Near    within INTEREST_NEAR (50 km, true distance) of the pocket reference  INTEREST_RATE_NEAR (20 Hz)
	  Soi     same SOI body as the pocket reference, beyond 50 km                INTEREST_RATE_SOI (2 Hz)
	  Far     everything else (map view)                                         INTEREST_RATE_FAR (0.5 Hz)

	Budget (allocate): when the wanted rates would cost more than the per-client budget, Pocket crafts keep their
	full rate, every other craft drops to the Far rate, and the spare budget is handed back in order of importance
	(crafts before debris, then Near > Soi > Far, then nearest first). The nearest crafts stay smooth; the rest
	degrade.

	Scheduling (advance): each (client, craft) pair keeps a send credit that grows by rate * dt every relay tick;
	a state is sent when it reaches 1. Fractional rates average out exactly (13.3 Hz on a 20 Hz tick sends 2 of
	every 3 ticks) instead of rounding up to the tick rate.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local RATE_NEAR = GameConfig.INTEREST_RATE_NEAR -- Hz
local RATE_SOI = GameConfig.INTEREST_RATE_SOI -- Hz
local RATE_FAR = GameConfig.INTEREST_RATE_FAR -- Hz
local NEAR_DISTANCE = GameConfig.INTEREST_NEAR -- m
local STATE_BYTES = 77 -- one state block on the wire (Protocol.STATE_BYTES)
local PER_PACKET = GameConfig.MAX_STATES_PER_PACKET
local MAX_CREDIT = 2 -- a tick hitch can owe at most one extra send
local CREDIT_EPSILON = 1e-9 -- 10 x 0.1 must count as 1 despite rounding
local GOLDEN = 0.6180339887498949 -- spreads first sends of slow crafts over different ticks
--============================================================================

export type Tier = "Pocket" | "Near" | "Soi" | "Far"

export type Demand = {
	tier: Tier,
	distance: number, -- m, true distance from the client's pocket reference (importance within a tier)
	debris: boolean, -- debris is degraded before crafts
}

local Interest = {}

Interest.STATE_BYTES = STATE_BYTES
Interest.RATE_NEAR = RATE_NEAR
Interest.RATE_SOI = RATE_SOI
Interest.RATE_FAR = RATE_FAR

local TIER_RANK: { [Tier]: number } = { Pocket = 0, Near = 1, Soi = 2, Far = 3 }

-- The tier of a craft for one client.
function Interest.classify(samePocket: boolean, sameSoi: boolean, distance: number): Tier
	if samePocket then
		return "Pocket"
	end
	if distance <= NEAR_DISTANCE then
		return "Near"
	end
	if sameSoi then
		return "Soi"
	end
	return "Far"
end

-- Wanted send rate (Hz) for a tier.
function Interest.rateOf(tier: Tier): number
	if tier == "Pocket" or tier == "Near" then
		return RATE_NEAR
	elseif tier == "Soi" then
		return RATE_SOI
	end
	return RATE_FAR
end

-- Payload bytes per second for a total state rate (state blocks plus one count byte per packet).
function Interest.bytesPerSecond(totalRate: number): number
	return totalRate * (STATE_BYTES + 1 / PER_PACKET)
end

--[[
	Send rates (Hz), in the same order as `demands`, that fit `budget` payload bytes per second whenever possible.
	Pocket crafts are never degraded; nothing goes below the Far rate.
]]
function Interest.allocate(demands: { Demand }, budget: number): { number }
	local rates = table.create(#demands, 0)
	local total = 0
	for index, demand in demands do
		local rate = Interest.rateOf(demand.tier)
		rates[index] = rate
		total += rate
	end
	if Interest.bytesPerSecond(total) <= budget then
		return rates
	end

	-- Over budget: everything but Pocket drops to the floor, then the spare rate is handed back by importance.
	local spare = budget / (STATE_BYTES + 1 / PER_PACKET)
	local order: { number } = {}
	for index, demand in demands do
		if demand.tier == "Pocket" then
			spare -= rates[index]
		else
			rates[index] = math.min(RATE_FAR, rates[index])
			spare -= rates[index]
			table.insert(order, index)
		end
	end
	table.sort(order, function(a, b)
		local da, db = demands[a], demands[b]
		if da.debris ~= db.debris then
			return not da.debris
		end
		local ra, rb = TIER_RANK[da.tier], TIER_RANK[db.tier]
		if ra ~= rb then
			return ra < rb
		end
		if da.distance ~= db.distance then
			return da.distance < db.distance
		end
		return a < b
	end)
	for _, index in order do
		if spare <= 0 then
			break
		end
		local wanted = Interest.rateOf(demands[index].tier)
		local extra = math.min(wanted - rates[index], spare)
		if extra > 0 then
			rates[index] += extra
			spare -= extra
		end
	end
	return rates
end

-- The starting send credit of a (client, craft) pair: near crafts go out on the first tick, slow ones are spread.
function Interest.initialCredit(craftId: number, tier: Tier): number
	if tier == "Pocket" or tier == "Near" then
		return 1
	end
	local fraction = (craftId * GOLDEN) % 1
	return 0.5 + 0.5 * fraction
end

-- Advances a send credit by one relay tick of `dt` seconds. Returns the new credit and whether to send now.
function Interest.advance(credit: number, rate: number, dt: number): (number, boolean)
	if rate <= 0 then
		return credit, false -- not wanted at all
	end
	local value = math.min(credit + rate * math.max(dt, 0), MAX_CREDIT)
	if value >= 1 - CREDIT_EPSILON then
		return math.max(value - 1, 0), true
	end
	return value, false
end

return table.freeze(Interest)
