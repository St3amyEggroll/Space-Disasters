--!strict
--[[
	Bubbles (Phase 6, spec 7.5 "Bubble merge/split")
	The server's bubble decisions as a pure function: given where every pocket, craft and astronaut on EVA is, what
	should change? BubbleService builds the snapshot 4 times a second (BUBBLE_CHECK_RATE), applies the actions in
	order (re-checking each against the live state) and the next check sees the result. No services, no Instances:
	the Lune suite tests every rule (src/server/Tests/Bubbles.spec.luau).

	Positions are ABSOLUTE (universe frame: Homeworld's centre, Universe.bodyPosition added in doubles), so crafts and
	astronauts around different bodies compare directly; merges still need the same SOI body.

	Terms
	  pocket anchor   where its primary is: the primary craft (Craft pockets) or the primary astronaut (Solo pockets)
	  stay anchors    of pocket X for astronaut a: every craft whose real model is in X, plus X's primary astronaut
	                  (Solo pockets) when that is not a himself. An astronaut stays in his pocket while one of its stay
	                  anchors is within BUBBLE_SPLIT_DIST.

	Rules, in this order; every pocket, craft and astronaut takes part in at most one action per check:
	  1. Primaries (Repoint): a Craft pocket whose primary craft is gone gets the craft with the most crew (else any
	     craft, else an astronaut in it); a Craft pocket whose primary has no crew while another craft in it has some
	     gets that one (spec: "the crewed craft with the most occupants comes first"); a Solo pocket whose primary
	     astronaut is no longer on EVA in it gets a crewed craft, else another astronaut, else a craft.
	  2. Craft pockets whose anchors are within BUBBLE_MERGE_DIST in the same SOI merge (Merge): the one with fewer
	     players moves into the other; a tie keeps the older pocket. Nearest pairs first.
	  3. Astronauts (only "settled" ones: their replicated position is in their pocket, not just transferred):
	     * within BASE_BUBBLE of the launch site and low (the caller decides nearBase): ToBase;
	     * the primary of a Solo pocket: when another pocket's stay anchor is within BUBBLE_MERGE_DIST, his whole
	       pocket merges into it (Merge; two lone astronauts: the newer pocket merges into the older);
	     * anyone else: beyond BUBBLE_SPLIT_DIST of every stay anchor he leaves, into the nearest other pocket with a
	       stay anchor within BUBBLE_MERGE_DIST (Join), else his own new Solo pocket (NewSolo); closer than that he
	       still changes to another pocket whose nearest stay anchor is within BUBBLE_MERGE_DIST and less than
	       BUBBLE_SWITCH_RATIO times as far (Join; symmetric, so he never flips back and forth).
	  4. Secondary crafts (crafts in a pocket that are not its primary): a crewed one farther than BUBBLE_SPLIT_DIST
	     from the pocket anchor gets its own pocket (SplitCraft); an uncrewed one farther than that from the anchor
	     AND from every astronaut in the pocket goes back to a cosmetic copy (DropCraft). CHANGED (Night review): not
	     while an astronaut of that pocket is unsettled (his position is unknown: he may be right beside it).
	  5. Uncrewed boardable crafts without a pocket (Phase 3: they only exist as simulation and copies) within
	     BUBBLE_MERGE_DIST of an occupied pocket's anchor or of an astronaut in it become a real secondary craft there
	     (AddCraft), so they can be boarded through their real seats. Debris (not boardable) never does.
	Merge / split use BUBBLE_MERGE_DIST (250 m) and BUBBLE_SPLIT_DIST (400 m): the gap is the hysteresis.
	Near the launch site (nearBase pockets and crafts, decided by the caller) nothing merges and no craft is pulled in:
	rockets standing on neighbouring pads keep their own pockets (returning to the pad moves a whole pocket back).

	API:
	  Bubbles.decide(snapshot) -> { Action }
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local MERGE_DIST = GameConfig.BUBBLE_MERGE_DIST -- m
local SPLIT_DIST = GameConfig.BUBBLE_SPLIT_DIST -- m
local SWITCH_RATIO = GameConfig.BUBBLE_SWITCH_RATIO
--============================================================================

export type PocketKind = "Craft" | "Solo"

export type Pocket = {
	id: number,
	kind: PocketKind,
	primaryCraftId: number?, -- Craft pockets
	primaryUserId: number?, -- Solo pockets
	bodyId: number, -- SOI body of its anchor
	anchor: Vec3d?, -- absolute position of the primary (nil when the primary is gone / unknown)
	order: number, -- creation order (smaller = older)
	players: number, -- every player in the pocket (crew, astronauts)
	nearBase: boolean?, -- its anchor is near the launch site: it never merges (the base pocket rules there)
}

export type Craft = {
	id: number,
	pocketId: number?, -- the pocket holding its real model; nil = no real model (cosmetic copies only)
	bodyId: number,
	pos: Vec3d, -- absolute
	crew: number, -- players seated in it
	boardable: boolean, -- has a seat and is not debris
	nearBase: boolean?, -- near the launch site: never pulled into a pocket as a secondary craft
}

export type Astronaut = {
	userId: number,
	pocketId: number,
	bodyId: number,
	pos: Vec3d, -- absolute
	settled: boolean, -- false right after a transfer: his replicated position may still be in the old pocket
	nearBase: boolean, -- within BASE_BUBBLE of the launch site and below BASE_JOIN_HEIGHT
}

export type Snapshot = {
	pockets: { Pocket },
	crafts: { Craft },
	astronauts: { Astronaut },
}

export type ActionKind = "Repoint" | "Merge" | "ToBase" | "Join" | "NewSolo" | "SplitCraft" | "DropCraft" | "AddCraft"

export type Action = {
	kind: ActionKind,
	pocketId: number?, -- Repoint: the pocket; Join / AddCraft: the destination
	fromId: number?, -- Merge: the pocket that moves
	intoId: number?, -- Merge: the pocket it moves into
	craftId: number?, -- Repoint (new primary craft), SplitCraft, DropCraft, AddCraft
	userId: number?, -- Repoint (new primary astronaut), ToBase, Join, NewSolo
}

local Bubbles = {}

type Index = {
	pockets: { [number]: Pocket },
	craftsIn: { [number]: { Craft } }, -- pocket id -> crafts with a real model there
	astronautsIn: { [number]: { Astronaut } }, -- pocket id -> SETTLED astronauts on EVA there (positions are trusted)
	astronautById: { [number]: Astronaut }, -- every astronaut (settled or not: presence only)
	craftById: { [number]: Craft },
	-- CHANGED (Night review): pockets with an astronaut whose position is not trusted yet (just transferred)
	unsettledIn: { [number]: boolean },
}

local function buildIndex(snapshot: Snapshot): Index
	local index: Index =
		{ pockets = {}, craftsIn = {}, astronautsIn = {}, astronautById = {}, craftById = {}, unsettledIn = {} }
	for _, pocket in snapshot.pockets do
		index.pockets[pocket.id] = pocket
		index.craftsIn[pocket.id] = {}
		index.astronautsIn[pocket.id] = {}
	end
	for _, craft in snapshot.crafts do
		index.craftById[craft.id] = craft
		local pocketId = craft.pocketId
		if pocketId and index.craftsIn[pocketId] then
			table.insert(index.craftsIn[pocketId], craft)
		end
	end
	for _, astronaut in snapshot.astronauts do
		index.astronautById[astronaut.userId] = astronaut
		-- an astronaut just transferred still has his old pocket's position: he counts as present, but his position
		-- is used for nothing until he settles
		if astronaut.settled and index.astronautsIn[astronaut.pocketId] then
			table.insert(index.astronautsIn[astronaut.pocketId], astronaut)
		elseif not astronaut.settled then
			index.unsettledIn[astronaut.pocketId] = true -- CHANGED (Night review)
		end
	end
	return index
end

local function byId(a: Craft, b: Craft): boolean
	return a.id < b.id
end

-- The craft of a list with the most crew (lowest id on ties); `crewedOnly` skips crafts without crew.
local function mostCrew(crafts: { Craft }, crewedOnly: boolean): Craft?
	local best: Craft? = nil
	local sorted = table.clone(crafts)
	table.sort(sorted, byId)
	for _, craft in sorted do
		if (not crewedOnly or craft.crew > 0) and (best == nil or craft.crew > (best :: Craft).crew) then
			best = craft
		end
	end
	return best
end

-- Lowest user id first, so decisions do not depend on table order.
local function firstAstronaut(list: { Astronaut }, except: number?): Astronaut?
	local best: Astronaut? = nil
	for _, astronaut in list do
		if astronaut.userId ~= except and (best == nil or astronaut.userId < (best :: Astronaut).userId) then
			best = astronaut
		end
	end
	return best
end

-- Distance from `pos` to the nearest stay anchor of a pocket for astronaut `userId` (math.huge without any).
local function stayDistance(index: Index, pocket: Pocket, bodyId: number, pos: Vec3d, userId: number?): number
	local best = math.huge
	for _, craft in index.craftsIn[pocket.id] do
		if craft.bodyId == bodyId then
			best = math.min(best, Vec3d.distance(craft.pos, pos))
		end
	end
	if pocket.kind == "Solo" and pocket.primaryUserId ~= userId then
		local primary = if pocket.primaryUserId then index.astronautById[pocket.primaryUserId] else nil
		if primary and primary.settled and primary.pocketId == pocket.id and primary.bodyId == bodyId then
			best = math.min(best, Vec3d.distance(primary.pos, pos))
		end
	end
	return best
end

-- The other pocket (not `current`, not touched) with the nearest stay anchor within MERGE_DIST, and that distance.
local function nearestOther(
	index: Index,
	touched: { [number]: boolean },
	current: number,
	bodyId: number,
	pos: Vec3d,
	userId: number
): (Pocket?, number)
	local best: Pocket? = nil
	local bestDistance = math.huge
	for id, pocket in index.pockets do
		if id ~= current and not touched[id] then
			local d = stayDistance(index, pocket, bodyId, pos, userId)
			if d < MERGE_DIST and (d < bestDistance or (d == bestDistance and best and id < (best :: Pocket).id)) then
				best = pocket
				bestDistance = d
			end
		end
	end
	return best, bestDistance
end

local function add(actions: { Action }, action: Action)
	table.insert(actions, action)
end

--============================================================================
-- 1. Primaries
--============================================================================

local function decidePrimaries(index: Index, touched: { [number]: boolean }, actions: { Action })
	local ids: { number } = {}
	for id in index.pockets do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local pocket = index.pockets[id]
		local crafts = index.craftsIn[id]
		local astronauts = index.astronautsIn[id]
		local action: Action? = nil
		if pocket.kind == "Craft" then
			local primaryId = pocket.primaryCraftId
			local primary = if primaryId then index.craftById[primaryId] else nil
			local present = primary ~= nil and (primary :: Craft).pocketId == id
			if not present then
				local craft = mostCrew(crafts, false)
				local astronaut = firstAstronaut(astronauts, nil)
				if craft then
					action = { kind = "Repoint", pocketId = id, craftId = craft.id }
				elseif astronaut then
					action = { kind = "Repoint", pocketId = id, userId = astronaut.userId }
				end
			elseif (primary :: Craft).crew == 0 then
				local crewed = mostCrew(crafts, true)
				if crewed then
					action = { kind = "Repoint", pocketId = id, craftId = crewed.id }
				end
			end
		else
			local userId = pocket.primaryUserId
			local primary = if userId then index.astronautById[userId] else nil
			if primary == nil or (primary :: Astronaut).pocketId ~= id then
				local crewed = mostCrew(crafts, true)
				local astronaut = firstAstronaut(astronauts, userId)
				local craft = mostCrew(crafts, false)
				if crewed then
					action = { kind = "Repoint", pocketId = id, craftId = crewed.id }
				elseif astronaut then
					action = { kind = "Repoint", pocketId = id, userId = astronaut.userId }
				elseif craft then
					action = { kind = "Repoint", pocketId = id, craftId = craft.id }
				end
			end
		end
		if action then
			add(actions, action)
			touched[id] = true
		end
	end
end

--============================================================================
-- 2. Craft pocket merges
--============================================================================

type Pair = { a: Pocket, b: Pocket, distance: number }

local function decideMerges(index: Index, touched: { [number]: boolean }, actions: { Action })
	local list: { Pocket } = {}
	for id, pocket in index.pockets do
		if pocket.kind == "Craft" and pocket.anchor ~= nil and not touched[id] and not pocket.nearBase then
			table.insert(list, pocket)
		end
	end
	table.sort(list, function(a: Pocket, b: Pocket): boolean
		return a.id < b.id
	end)
	local candidates: { Pair } = {}
	for i = 1, #list do
		for j = i + 1, #list do
			local a, b = list[i], list[j]
			if a.bodyId == b.bodyId then
				local d = Vec3d.distance(a.anchor :: Vec3d, b.anchor :: Vec3d)
				if d < MERGE_DIST then
					table.insert(candidates, { a = a, b = b, distance = d })
				end
			end
		end
	end
	table.sort(candidates, function(x: Pair, y: Pair): boolean
		if x.distance ~= y.distance then
			return x.distance < y.distance
		end
		return x.a.id < y.a.id
	end)
	for _, pair in candidates do
		local a, b = pair.a, pair.b
		if touched[a.id] or touched[b.id] then
			continue
		end
		-- the pocket with more players stays; on a tie the older one
		local into, from = a, b
		if b.players > a.players or (b.players == a.players and b.order < a.order) then
			into, from = b, a
		end
		add(actions, { kind = "Merge", fromId = from.id, intoId = into.id })
		touched[a.id] = true
		touched[b.id] = true
	end
end

--============================================================================
-- 3. Astronauts
--============================================================================

local function decideAstronauts(snapshot: Snapshot, index: Index, touched: { [number]: boolean }, actions: { Action })
	local list = table.clone(snapshot.astronauts)
	table.sort(list, function(a: Astronaut, b: Astronaut): boolean
		return a.userId < b.userId
	end)
	for _, astronaut in list do
		local pocket = index.pockets[astronaut.pocketId]
		if pocket == nil or touched[pocket.id] or not astronaut.settled then
			continue
		end
		if astronaut.nearBase then
			add(actions, { kind = "ToBase", userId = astronaut.userId })
			continue
		end
		local userId = astronaut.userId
		local stay = stayDistance(index, pocket, astronaut.bodyId, astronaut.pos, userId)
		local other, otherDistance = nearestOther(index, touched, pocket.id, astronaut.bodyId, astronaut.pos, userId)
		if pocket.kind == "Solo" and pocket.primaryUserId == userId then
			-- the primary of his own pocket: rebases keep it with him; it merges into a pocket he reaches
			if other then
				local target = other :: Pocket
				local lonePair = target.kind == "Solo"
				-- two lone astronauts: only the newer pocket merges (the other one's turn would merge the other way)
				if not lonePair or pocket.order > target.order then
					add(actions, { kind = "Merge", fromId = pocket.id, intoId = target.id })
					touched[pocket.id] = true
					touched[target.id] = true
				end
			end
			continue
		end
		if stay > SPLIT_DIST then
			if other then
				add(actions, { kind = "Join", userId = userId, pocketId = (other :: Pocket).id })
			else
				add(actions, { kind = "NewSolo", userId = userId })
			end
		elseif other and otherDistance < SWITCH_RATIO * stay then
			add(actions, { kind = "Join", userId = userId, pocketId = (other :: Pocket).id })
		end
	end
end

--============================================================================
-- 4. Secondary crafts, 5. uncrewed crafts joining a pocket
--============================================================================

local function decideCrafts(snapshot: Snapshot, index: Index, touched: { [number]: boolean }, actions: { Action })
	local crafts = table.clone(snapshot.crafts)
	table.sort(crafts, byId)
	for _, craft in crafts do
		local pocketId = craft.pocketId
		if pocketId == nil then
			continue
		end
		local pocket = index.pockets[pocketId]
		if pocket == nil or touched[pocketId] or pocket.primaryCraftId == craft.id then
			continue
		end
		local anchor = pocket.anchor
		local toAnchor = if anchor and pocket.bodyId == craft.bodyId
			then Vec3d.distance(craft.pos, anchor)
			else math.huge
		if craft.crew > 0 then
			if toAnchor > SPLIT_DIST then
				add(actions, { kind = "SplitCraft", craftId = craft.id })
			end
		else
			local nearest = toAnchor
			for _, astronaut in index.astronautsIn[pocketId] do
				if astronaut.bodyId == craft.bodyId then
					nearest = math.min(nearest, Vec3d.distance(astronaut.pos, craft.pos))
				end
			end
			-- CHANGED (Night review): never while an astronaut in the pocket is unsettled: his position is unknown, and
			-- he may be right next to the craft (just joined, or pinned by a repoint / rebase transfer)
			if nearest > SPLIT_DIST and not index.unsettledIn[pocketId] then
				add(actions, { kind = "DropCraft", craftId = craft.id })
			end
		end
	end
	for _, craft in crafts do
		if craft.pocketId ~= nil or craft.crew > 0 or not craft.boardable or craft.nearBase then
			continue
		end
		local best: Pocket? = nil
		local bestDistance = MERGE_DIST
		for id, pocket in index.pockets do
			if pocket.players <= 0 or touched[id] then
				continue
			end
			local d = math.huge
			local anchor = pocket.anchor
			if anchor and pocket.bodyId == craft.bodyId then
				d = Vec3d.distance(anchor, craft.pos)
			end
			for _, astronaut in index.astronautsIn[id] do
				if astronaut.bodyId == craft.bodyId then
					d = math.min(d, Vec3d.distance(astronaut.pos, craft.pos))
				end
			end
			if d < bestDistance or (d == bestDistance and best and id < (best :: Pocket).id) then
				best = pocket
				bestDistance = d
			end
		end
		if best then
			add(actions, { kind = "AddCraft", craftId = craft.id, pocketId = (best :: Pocket).id })
		end
	end
end

--[[
	The bubble actions for one check, in the order they should be applied. Pure and deterministic (ties are broken
	by ids), so every rule is unit-tested.
]]
function Bubbles.decide(snapshot: Snapshot): { Action }
	local index = buildIndex(snapshot)
	local touched: { [number]: boolean } = {}
	local actions: { Action } = {}
	decidePrimaries(index, touched, actions)
	decideMerges(index, touched, actions)
	decideAstronauts(snapshot, index, touched, actions)
	decideCrafts(snapshot, index, touched, actions)
	return actions
end

return table.freeze(Bubbles)
