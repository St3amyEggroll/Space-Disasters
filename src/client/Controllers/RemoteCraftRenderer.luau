--!strict
--[[
	RemoteCraftRenderer (spec 7.7)
	Knows every craft in flight (CraftSpawned / CraftRemoved / CraftStaged / PartsDestroyed), buffers their
	streamed states (CraftStates) and interpolates them at UT - INTERP_DELAY (extrapolating up to
	EXTRAPOLATE_MAX when starved). Crafts that are not in the local player's pocket are drawn as client-side
	cosmetic copies (invariant I6): CraftBuilder "Cosmetic" models with one anchored root and welded, massless
	children, moved by setting the root CFrame once per frame through the current pocket frame.

	Also used by PocketController: passengers take their flight-pocket frame from sampleState() of the primary.
	Phase 2a draws copies at true scale out to COPY_MAX_DISTANCE; scaled-space copies arrive in Phase 4.

	CHANGED (Phase 3):
	  * Sampling lives in Shared/Net/StateBuffer: interpolation, extrapolation with velocity for up to
	    EXTRAPOLATE_MAX (0.25 s) on a 20 Hz stream, then freeze. Slow interest tiers (2 Hz / 0.5 Hz) extrapolate up
	    to about one packet interval (EXTRAPOLATE_MAX_SLOW at most) before freezing.
	  * LOD markers (Render/CraftMarkers): a craft beyond COPY_MAX_DISTANCE, or smaller on screen than
	    CRAFT_MARKER_ANGLE_DEG, shows a name/owner/distance marker instead of its copy (with hysteresis; never for
	    debris; hidden when a planet blocks the line of sight). Distances and directions are computed from true
	    positions in doubles after subtracting the camera's true position (I1).
	  * Puppets (Render/Puppets): crews of crafts in other pockets, posed inside the copies.
	  * Rolled-out crafts on their pads are announced too (info.prelaunch): players in the base see the real model,
	    everyone else a copy.
	  * The join snapshot is requested once the handlers are connected (RequestSnapshot).
	  * F3 shows the CraftStates bytes/s this client receives, and copy / marker / puppet counts.
	  * seedState(): the former pilot's last local state, so its pocket frame continues smoothly when the server
	    takes the craft over.

	CHANGED (Boarding): copies of slow crafts flying in another pocket get client-side seat prompts while the local
	player is on foot in the base (Render/BoardPrompts, rules in Shared/Craft/Boarding), so crafts can be boarded
	after their pilot sat down.

	CHANGED (Phase 10): effects. Every copy drawn this frame is reported to Render/Effects (source "Stream": plumes,
	smoke trail, dust, re-entry heat from the interpolated state), and so is the real model of this pocket's primary
	craft when this client does not fly it (passengers: their own rocket now has flames and smoke too). CraftStaged
	and PartsDestroyed call Effects.blockEvent before the blocks are removed (separation puffs, explosions).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local LineOfSight = require(ReplicatedStorage.Shared.Sim.LineOfSight)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails) -- CHANGED (Phase 5)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local StateBuffer = require(ReplicatedStorage.Shared.Net.StateBuffer)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local CraftMarkers = require(script.Parent.Parent.Render.CraftMarkers)
local DebugOverlay = require(script.Parent.DebugOverlay)
local Effects = require(script.Parent.Parent.Render.Effects) -- CHANGED (Phase 10)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel) -- CHANGED (Phase 10): flag bits
local Plumes = require(script.Parent.Parent.Render.Plumes)
local Boarding = require(ReplicatedStorage.Shared.Craft.Boarding) -- CHANGED (Boarding)
local BoardPrompts = require(script.Parent.Parent.Render.BoardPrompts) -- CHANGED (Boarding)
local Gear = require(script.Parent.Parent.Render.Gear)
local Puppets = require(script.Parent.Parent.Render.Puppets)
local RenderContext = require(script.Parent.Parent.Render.RenderContext)

type State = Protocol.State
type Design = CraftDesign.Design

--============================================================================
-- Tunables
--============================================================================
local INTERP_DELAY = GameConfig.INTERP_DELAY
local BUFFER_SIZE = StateBuffer.DEFAULT_CAPACITY
local COPY_MAX_DISTANCE = GameConfig.COPY_MAX_DISTANCE -- CHANGED (Phase 3): moved to GameConfig
local MARKER_ANGLE = math.rad(GameConfig.CRAFT_MARKER_ANGLE_DEG) -- CHANGED (Phase 3): smaller -> marker
local LOD_HYSTERESIS = 0.1 -- CHANGED (Phase 3): +-10% around both switch points
local MIN_RADIUS = 2 -- m; a craft's apparent size never counts as smaller than this
local STREAM_NAME = "CraftStates" -- CHANGED (Phase 3): DebugOverlay byte counter
--============================================================================

type Lod = "None" | "Copy" | "Marker"

type Entry = {
	id: number,
	design: Design,
	ownerUserId: number,
	pocketId: number,
	active: { [number]: boolean },
	states: { State },
	model: Model?,
	root: BasePart?,
	gear: { Gear.GearPart }, -- CHANGED (Phase 2a remodel): landing-leg parts (anchored, posed by Gear)
	gearFraction: number,
	-- CHANGED (Phase 3)
	name: string,
	ownerName: string,
	isDebris: boolean,
	prelaunch: boolean, -- rolled out, standing on its pad in the base pocket
	radius: number, -- m, farthest block corner from the reference point
	lod: Lod,
	boarding: BoardPrompts.Candidate, -- CHANGED (Boarding): reused every frame the copy may be boarded
}

local RemoteCraftRenderer = {}

local entries: { [number]: Entry } = {}
local folder: Folder
local copies: { [number]: Puppets.CopyInfo } = {} -- CHANGED (Phase 3): copies drawn this frame (for puppets)
local boardCandidates: { [number]: BoardPrompts.Candidate } = {} -- CHANGED (Boarding): copies that may be boarded
local frameStats = { copies = 0, markers = 0, frozen = 0 }
-- CHANGED (Phase 5): crafts on rails, sampled analytically instead of from the state buffer (RailsController
-- fills this from CraftRails / CraftOffRails / CraftSpawned and mirrors SOI changes).
local railsById: { [number]: Rails.Rails } = {}

--============================================================================
-- Interpolation (CHANGED Phase 3: Shared/Net/StateBuffer)
--============================================================================

local function pushState(entry: Entry, state: State)
	StateBuffer.push(entry.states, state, BUFFER_SIZE)
end

-- Interpolated (or briefly extrapolated, then frozen) state of a craft at a UT, or nil if unknown.
function RemoteCraftRenderer.sampleState(craftId: number, ut: number): State?
	local onRails = railsById[craftId] -- CHANGED (Phase 5)
	if onRails then
		return Rails.stateAt(onRails, ut)
	end
	local entry = entries[craftId]
	if entry == nil then
		return nil
	end
	local state = StateBuffer.sample(entry.states, ut)
	return state
end

-- The latest streamed state (no interpolation), or nil.
function RemoteCraftRenderer.latestState(craftId: number): State?
	local entry = entries[craftId]
	return if entry then entry.states[#entry.states] else nil
end

--[[
	CHANGED (Phase 5): sets (or clears, with nil) the rail a craft is sampled from. Clearing seeds the state
	buffer with the rail's states at `ut - INTERP_DELAY` and `ut`, so interpolation carries on smoothly from the
	rail until the resumed CraftStates stream arrives.
]]
function RemoteCraftRenderer.setRails(craftId: number, rails: Rails.Rails?, ut: number)
	local previous = railsById[craftId]
	if rails then
		railsById[craftId] = rails
	else
		railsById[craftId] = nil
	end
	local entry = entries[craftId]
	if rails == nil and previous and entry then
		pushState(entry, Rails.stateAt(previous, ut - INTERP_DELAY))
		pushState(entry, Rails.stateAt(previous, ut))
	end
end

function RemoteCraftRenderer.railsOf(craftId: number): Rails.Rails?
	return railsById[craftId]
end

-- CHANGED (Phase 5): ids of every known craft (map view).
function RemoteCraftRenderer.craftIds(): { number }
	local ids = {}
	for id in entries do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

-- CHANGED (Phase 5): is this craft debris (CraftSpawned info.isDebris)? Used by the map view.
function RemoteCraftRenderer.isDebris(craftId: number): boolean
	local entry = entries[craftId]
	return entry ~= nil and entry.isDebris
end

function RemoteCraftRenderer.design(craftId: number): Design?
	local entry = entries[craftId]
	return if entry then entry.design else nil
end

function RemoteCraftRenderer.activeEngines(craftId: number): { [number]: boolean }?
	local entry = entries[craftId]
	return if entry then entry.active else nil
end

function RemoteCraftRenderer.interpolationDelay(): number
	return INTERP_DELAY
end

-- CHANGED (Phase 3): restarts a craft's buffer from a known state. Used when this client stops simulating its craft
-- (the server took it over): the stream does not carry a pilot's own craft, so the buffer would be stale.
function RemoteCraftRenderer.seedState(craftId: number, state: State)
	local entry = entries[craftId]
	if entry == nil then
		return
	end
	entry.states = {
		{
			bodyId = state.bodyId,
			pos = Vec3d.clone(state.pos),
			vel = Vec3d.clone(state.vel),
			rot = state.rot,
			angVel = state.angVel,
			throttle = state.throttle,
			flags = state.flags,
			ut = state.ut,
		},
	}
end

--============================================================================
-- Cosmetic models
--============================================================================

local function destroyModel(entry: Entry)
	local model = entry.model
	if model then
		Plumes.clear(model)
		model:Destroy()
	end
	entry.model = nil
	entry.root = nil
	entry.gear = {}
end

local function referenceCenter(design: Design): Vector3
	local root = CraftDesign.rootBlock(design)
	local reference = root
	if reference == nil then
		for _, block in design.blocks do
			if reference == nil or block.id < (reference :: CraftDesign.Block).id then
				reference = block
			end
		end
	end
	return if reference then CraftDesign.blockCenter(reference) * CraftDesign.GRID else Vector3.zero
end

-- CHANGED (Phase 3): the farthest block corner from the craft reference point (m), for the marker LOD.
local function craftRadius(design: Design): number
	if #design.blocks == 0 then
		return MIN_RADIUS
	end
	local center = referenceCenter(design)
	local minV, maxV = CraftDesign.bounds(design)
	local lo, hi = minV * CraftDesign.GRID - center, maxV * CraftDesign.GRID - center
	local x = math.max(math.abs(lo.X), math.abs(hi.X))
	local y = math.max(math.abs(lo.Y), math.abs(hi.Y))
	local z = math.max(math.abs(lo.Z), math.abs(hi.Z))
	return math.max(math.sqrt(x * x + y * y + z * z), MIN_RADIUS)
end

-- Builds the cosmetic copy with its craft-local origin (reference block centre) at the model root.
local function buildModel(entry: Entry): Model
	local origin = CFrame.new(-referenceCenter(entry.design))
	local model = CraftBuilder.build(entry.design, "Cosmetic", origin, `Remote_{entry.id}`)
	local root = Instance.new("Part")
	root.Name = "CosmeticRoot"
	root.Size = Vector3.one * 0.2
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.CFrame = CFrame.identity
	root.Parent = model
	entry.gear = Gear.collect(model, CFrame.identity) -- the root (craft reference frame) is at the identity here
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= root and not Gear.isMoving(descendant) then
			descendant.Anchored = false
			descendant.Massless = true
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = root
			weld.Part1 = descendant
			weld.Parent = descendant
		end
	end
	model.PrimaryPart = root
	model.Parent = folder
	entry.model = model
	entry.root = root
	return model
end

local function hideModel(entry: Entry)
	local model = entry.model
	if model and model.Parent ~= nil then
		model.Parent = nil
	end
end

local function removeBlocks(entry: Entry, ids: { number })
	local lookup: { [number]: boolean } = {}
	for _, id in ids do
		lookup[id] = true
		entry.active[id] = nil
		local model = entry.model
		if model then
			local block = CraftBuilder.findBlockModel(model, id)
			if block then
				block:Destroy()
			end
		end
	end
	local kept = {}
	for _, block in entry.design.blocks do
		if not lookup[block.id] then
			table.insert(kept, block)
		end
	end
	entry.design.blocks = kept
	entry.radius = craftRadius(entry.design) -- CHANGED (Phase 3)
end

--============================================================================
-- Rendering (called by UniverseRenderer every frame, after the pocket frame is updated)
--============================================================================

-- CHANGED (Phase 3): copy or marker, with hysteresis around COPY_MAX_DISTANCE and the marker angle.
local function chooseLod(entry: Entry, distance: number): Lod
	local angular = entry.radius / math.max(distance, 1e-3)
	local copy: boolean
	if entry.lod == "Copy" then
		copy = distance <= COPY_MAX_DISTANCE * (1 + LOD_HYSTERESIS) and angular >= MARKER_ANGLE * (1 - LOD_HYSTERESIS)
	else
		copy = distance < COPY_MAX_DISTANCE * (1 - LOD_HYSTERESIS) and angular > MARKER_ANGLE * (1 + LOD_HYSTERESIS)
	end
	return if copy then "Copy" else "Marker"
end

-- CHANGED (Phase 10): engines burning in a streamed state (FLAG_BURNING + the craft's ignited engines). Moved out of
-- poseCopy and made one pass over the blocks. Solid boosters (not throttleable) always burn at 1.
local function burningOf(entry: Entry, s: State): { [number]: number }
	local burning: { [number]: number } = {}
	if bit32.band(s.flags, FlightModel.FLAG_BURNING) == 0 then
		return burning
	end
	for _, block in entry.design.blocks do
		if entry.active[block.id] then
			local engine = Parts.get(block.type).Engine
			if engine then
				-- CHANGED (Phase 2a feedback): no minimum flame, a throttled-down liquid engine is out
				burning[block.id] = if engine.Throttleable then s.throttle else 1
			end
		end
	end
	return burning
end

local function poseCopy(entry: Entry, s: State, target: CFrame, dt: number)
	local model = entry.model or buildModel(entry)
	if model.Parent ~= folder then
		model.Parent = folder
	end
	local root = entry.root :: BasePart
	root.CFrame = target
	if #entry.gear > 0 then
		entry.gearFraction = Gear.approach(entry.gearFraction, Gear.target(s.flags), dt)
		Gear.pose(entry.gear, target, entry.gearFraction)
	end

	-- CHANGED (Phase 10): plumes and the other effects are drawn by Render/Effects from this report
	Effects.reportCraft(entry.id, {
		source = "Stream",
		model = model,
		design = entry.design,
		state = s,
		burning = burningOf(entry, s),
		craftCFrame = target,
	})
end

--[[
	CHANGED (Phase 10): the real model of this pocket's primary craft, for passengers (and anyone in the pocket who
	does not fly it). PocketController poses it from sampleState at the render UT; the effects use the same state.
	The pilot's own "Local" report wins inside Effects.
]]
local function reportPocketCraft(entry: Entry, ctx: RenderContext.RenderContext)
	local pockets = Workspace:FindFirstChild("Pockets")
	local pocket = if pockets then pockets:FindFirstChild(`Pocket_{ctx.pocketId}`) else nil
	if pocket == nil or pocket:GetAttribute("PrimaryId") ~= entry.id then
		return
	end
	local crafts = pocket:FindFirstChild("Crafts")
	local model = if crafts then crafts:FindFirstChild(`Craft_{entry.id}`) else nil
	if model == nil or not model:IsA("Model") or model:GetAttribute("FlightPocket") ~= ctx.pocketId then
		return
	end
	local s = RemoteCraftRenderer.sampleState(entry.id, ctx.ut)
	if s == nil then
		return
	end
	Effects.reportCraft(entry.id, {
		source = "Stream",
		model = model,
		design = entry.design,
		state = s,
		burning = burningOf(entry, s),
		craftCFrame = nil,
	})
end

local function markerTitle(entry: Entry): string
	if entry.ownerName ~= "" then
		return `{entry.name} ({entry.ownerName})`
	end
	return entry.name
end

function RemoteCraftRenderer.render(ctx: RenderContext.RenderContext)
	local renderUT = ctx.ut - INTERP_DELAY
	local cameraPos = ctx.camera.Position
	local cameraAbs = ctx.cameraAbs
	local refBodyId = ctx.frame.refBodyId
	table.clear(copies)
	table.clear(boardCandidates) -- CHANGED (Boarding)
	frameStats.copies, frameStats.markers, frameStats.frozen = 0, 0, 0
	for id, entry in entries do
		-- CHANGED (Phase 3): a craft on its pad belongs to the base pocket (its real model is shown there)
		local inMyPocket = if entry.prelaunch
			then ctx.pocketId == 0
			else entry.pocketId ~= 0 and entry.pocketId == ctx.pocketId
		local state: State? = nil
		if inMyPocket and not entry.prelaunch and #entry.design.blocks > 0 then
			reportPocketCraft(entry, ctx) -- CHANGED (Phase 10)
		end
		if not inMyPocket and #entry.design.blocks > 0 then
			local onRails = railsById[id] -- CHANGED (Phase 5): crafts on rails are not streamed; sample the rail
			if onRails then
				-- CHANGED (Deploy fix): a rail is exact at any time, so sample it now (not INTERP_DELAY ago)
				state = Rails.stateAt(onRails, ctx.ut)
			else
				local sampled, mode = StateBuffer.sample(entry.states, renderUT)
				-- CHANGED (Deploy fix): lead the delayed sample to now, so crafts are drawn where they are
				-- relative to our own craft instead of velocity * INTERP_DELAY behind (StateBuffer.lead)
				state = if sampled then StateBuffer.lead(sampled, ctx.ut, INTERP_DELAY) else nil
				if mode == "Frozen" then
					frameStats.frozen += 1
				end
			end
		end
		if state == nil then
			hideModel(entry)
			CraftMarkers.hide(id)
			entry.lod = "None"
			continue
		end
		local s = state :: State
		local bodyOffset = if s.bodyId ~= refBodyId then Universe.bodyOffset(s.bodyId, refBodyId, ctx.ut) else nil

		-- CHANGED (Phase 3): true camera -> craft offset in doubles (I1), relative to the pocket's reference body
		local px, py, pz = s.pos.x, s.pos.y, s.pos.z
		if bodyOffset then
			px, py, pz = px + bodyOffset.x, py + bodyOffset.y, pz + bodyOffset.z
		end
		local dx, dy, dz = px - cameraAbs.x, py - cameraAbs.y, pz - cameraAbs.z
		local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
		local lod: Lod = chooseLod(entry, distance)
		entry.lod = lod

		if lod == "Copy" then
			CraftMarkers.hide(id)
			local target = Frames.cframeToWorkspace(ctx.frame, s.pos, s.rot, bodyOffset)
			poseCopy(entry, s, target, ctx.dt)
			copies[id] = { root = entry.root :: BasePart, distance = distance, radius = entry.radius }
			frameStats.copies += 1
			-- CHANGED (Boarding): a slow craft in another pocket, seen from the base, may be boarded from its copy
			if
				Boarding.offersPrompts(
					ctx.pocketId,
					entry.pocketId,
					entry.prelaunch,
					entry.isDebris,
					Vec3d.length(s.vel)
				)
			then
				local candidate = entry.boarding
				candidate.model = entry.model
				candidate.root = entry.root
				candidate.radius = entry.radius
				boardCandidates[id] = candidate
			end
		else
			hideModel(entry)
			local blocked = entry.isDebris
				or distance < 1e-3
				or LineOfSight.blocked(refBodyId, cameraAbs, Vec3d.new(px, py, pz), ctx.ut)
			if blocked then
				CraftMarkers.hide(id)
			else
				local inv = 1 / distance
				local direction = Frames.vectorToWorkspace(ctx.frame, Vec3d.new(dx * inv, dy * inv, dz * inv))
				CraftMarkers.show(id, cameraPos, direction, distance, markerTitle(entry), entry.ownerUserId)
				frameStats.markers += 1
			end
		end
	end
	-- CHANGED (Phase 3): crews of crafts in other pockets, inside the copies just posed
	Puppets.update(ctx.pocketId, renderUT, copies, RemoteCraftRenderer.sampleState)
	BoardPrompts.update(boardCandidates) -- CHANGED (Boarding): after the copies are posed (and hidden ones dropped)
end

--============================================================================
-- Network
--============================================================================

-- CHANGED (Phase 10): the numbers of a network list (anything else is dropped).
local function numberList(value: unknown): { number }
	local list: { number } = {}
	if type(value) == "table" then
		for _, item in value :: { any } do
			if type(item) == "number" then
				table.insert(list, item)
			end
		end
	end
	return list
end

local function onSpawned(craftId: unknown, designBuffer: unknown, stateBuffer: unknown, info: unknown)
	if type(craftId) ~= "number" or typeof(designBuffer) ~= "buffer" or type(info) ~= "table" then
		return
	end
	local design = CraftDesign.fromBuffer(designBuffer :: buffer)
	if design == nil then
		return
	end
	local data = info :: { [string]: any }
	local existing = entries[craftId]
	if existing then
		destroyModel(existing)
		CraftMarkers.remove(craftId) -- CHANGED (Phase 3): rebuilt with the new label
	end
	local prelaunch = data.prelaunch == true
	local ownerUserId = if type(data.ownerUserId) == "number" then data.ownerUserId else 0
	local pocketId = if type(data.pocketId) == "number" then data.pocketId else 0
	local radius = craftRadius(design)
	local entry: Entry = {
		id = craftId,
		design = design,
		ownerUserId = ownerUserId,
		pocketId = pocketId,
		active = {},
		-- CHANGED (Phase 3): a pad craft's state is not part of a flight stream; start a new buffer either way
		states = if existing and not existing.prelaunch and not prelaunch then existing.states else {},
		model = nil,
		root = nil,
		gear = {},
		gearFraction = 1,
		name = if type(data.name) == "string" then data.name else design.name,
		ownerName = if type(data.ownerName) == "string" then data.ownerName else "",
		isDebris = data.isDebris == true,
		prelaunch = prelaunch,
		radius = radius,
		lod = "None" :: Lod,
		-- CHANGED (Boarding)
		boarding = {
			craftId = craftId,
			pocketId = pocketId,
			ownerUserId = ownerUserId,
			radius = radius,
			model = nil,
			root = nil,
		},
	}
	if type(data.active) == "table" then
		for _, id in data.active do
			if type(id) == "number" then
				entry.active[id] = true
			end
		end
	end
	local _, state = Protocol.decodeState(stateBuffer)
	if state then
		pushState(entry, state)
	end
	entries[craftId] = entry
end

local function onRemoved(craftId: unknown)
	if type(craftId) ~= "number" then
		return
	end
	local entry = entries[craftId]
	if entry then
		destroyModel(entry)
		entries[craftId] = nil
	end
	CraftMarkers.remove(craftId) -- CHANGED (Phase 3)
	railsById[craftId] = nil -- CHANGED (Phase 5)
	BoardPrompts.clear(craftId) -- CHANGED (Boarding)
end

local function onStaged(
	craftId: unknown,
	_stage: unknown,
	_ut: unknown,
	ignited: unknown,
	decoupled: unknown, -- CHANGED (Phase 10): used for the separation puffs
	debris: unknown
)
	if type(craftId) ~= "number" then
		return
	end
	local entry = entries[craftId]
	if entry == nil then
		return
	end
	if type(ignited) == "table" then
		for _, id in ignited :: { any } do
			if type(id) == "number" then
				entry.active[id] = true
			end
		end
	end
	-- CHANGED (Phase 10): separation puffs at the decouplers that fired (before their blocks are removed)
	local decouplers = numberList(decoupled)
	if #decouplers > 0 then
		Effects.blockEvent(craftId, "Separate", entry.design, decouplers, "Stream")
	end
	if type(debris) == "table" then
		for _, piece in debris :: { any } do
			if type(piece) == "table" and type(piece.blockIds) == "table" then
				removeBlocks(entry, piece.blockIds)
			end
		end
	end
end

local function onDestroyed(craftId: unknown, ids: unknown, _ut: unknown, pieces: unknown)
	if type(craftId) ~= "number" or type(ids) ~= "table" then
		return
	end
	local entry = entries[craftId]
	if entry == nil then
		return
	end
	-- CHANGED (Phase 10): explosions at the destroyed blocks (before they are removed)
	Effects.blockEvent(craftId, "Explode", entry.design, numberList(ids), "Stream")
	removeBlocks(entry, ids :: { number })
	if type(pieces) == "table" then
		for _, piece in pieces :: { any } do
			if type(piece) == "table" and type(piece.blockIds) == "table" then
				removeBlocks(entry, piece.blockIds)
			end
		end
	end
end

function RemoteCraftRenderer.Init()
	folder = Instance.new("Folder")
	folder.Name = "RemoteCrafts"
	folder.Parent = Workspace
	-- CHANGED (Phase 3): markers and puppets live in this client-only folder too
	CraftMarkers.init(folder)
	Puppets.init(folder)
	DebugOverlay.addLine("remoteCrafts", 23, function()
		local known = 0
		for _ in entries do
			known += 1
		end
		return string.format(
			"Remote crafts: %d known  %d copies  %d markers  %d puppets  %d frozen  (CraftStates %.2f KB/s)",
			known,
			frameStats.copies,
			frameStats.markers,
			Puppets.shownCount(),
			frameStats.frozen,
			DebugOverlay.streamBytesPerSecond(STREAM_NAME) / 1000
		)
	end)
end

function RemoteCraftRenderer.Start()
	Remotes.event("CraftSpawned").OnClientEvent:Connect(onSpawned)
	Remotes.event("CraftRemoved").OnClientEvent:Connect(onRemoved)
	Remotes.event("CraftStaged").OnClientEvent:Connect(onStaged)
	Remotes.event("PartsDestroyed").OnClientEvent:Connect(onDestroyed)
	Remotes.unreliable("CraftStates").OnClientEvent:Connect(function(packet: unknown)
		if typeof(packet) == "buffer" then
			DebugOverlay.countBytes(STREAM_NAME, buffer.len(packet :: buffer)) -- CHANGED (Phase 3)
		end
		for _, item in Protocol.decodeStates(packet) do
			local entry = entries[item.craftId]
			if entry then
				pushState(entry, item.state)
			end
		end
	end)
	-- CHANGED (Phase 3): the join snapshot, now that every handler above is connected
	Remotes.event("RequestSnapshot"):FireServer()
end

return RemoteCraftRenderer
