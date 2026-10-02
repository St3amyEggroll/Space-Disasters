--!strict
--[[
	BubbleService (Phase 6, spec 7.5 "Bubble merge/split", 7.9 EVA)
	Server-authoritative bubbles. BUBBLE_CHECK_RATE (4) times a second it builds a snapshot of every flight pocket,
	every craft in flight and every astronaut on EVA (true positions, doubles, I1), asks Shared/Sim/Bubbles what should
	change (all the rules and their hysteresis live there and are unit-tested) and applies the answers, re-checking
	each against the live state. Then it keeps every solo pocket's reference near its astronaut (EVA rebase).

	Frames on the server (frameOf): a Craft pocket is HORIZON_ALIGNED on its primary craft's state NOW (the rail, or
	the last valid state carried forward with its velocity), exactly how its clients pose it; a Solo pocket is its
	PocketFrames reference; the base pocket is PocketService.baseFrame(). An astronaut's true position is his
	replicated HumanoidRootPart through his pocket's frame; his velocity the pocket reference's velocity plus the
	replicated assembly velocity (the EVA client keeps that equal to his velocity relative to the pocket).

	Transfers (spec 7.5 transfer protocol, through FlightService.sendTransfer, which also pins the player's PocketId
	for a moment because the replicated position lags): M = Frames.relativeTransform(old frame, new frame). Unseated
	characters on Roblox physics (walking) move themselves by M; floating astronauts keep their absolute state
	(Shared/Sim/Eva), so for them only the frame changes; seated crew ride with their seats, which every client poses
	from the craft states. Models that change pocket are moved by M on the server too (PivotTo, PoseEpoch), so the
	server's seated characters land in the right slot.

	Actions:
	  Repoint      a pocket gets a new primary in place (same slot): new attributes and FrameEpoch, PocketTransfer
	               (in place) to everyone in it. Models stay where they are on the server (clients pose them).
	  Merge        every craft model and player of one pocket moves into another, which is then released.
	  Join         one astronaut moves into another pocket.
	  NewSolo      one astronaut gets his own Solo pocket (INERTIAL, or SURFACE_ALIGNED when low and slow).
	  ToBase       one astronaut moves into the base pocket (near the launch site).
	  SplitCraft   a crewed secondary craft gets its own Craft pocket, with its seated crew.
	  DropCraft    an uncrewed secondary craft loses its real model (cosmetic copies only again).
	  AddCraft     an uncrewed boardable craft near an astronaut / occupied pocket gets a real model there, so it can
	               be boarded through its real seats ("boarding uncrewed crafts").
	Solo upkeep (EVA rebase, spec 7.9): when the astronaut is more than EVA_REBASE_DIST from his pocket's reference,
	his pocket should change mode (PocketFrames.desiredMode: SURFACE_ALIGNED low and slow, INERTIAL otherwise) or he
	crossed into another SOI, the reference moves to him (a Repoint with a new reference). Deviation from the spec:
	the server decides rebases (no EVARebase remote), from the same replicated position it uses for everything else.

	Also:
	  * CraftService.onRemoving: a removed craft's pocket gets a new primary at once (or is released when empty), in
	    the same server frame, so clients never draw it from a stale reference.
	  * seatInReach (CrewService's SitPrompt check): the player's distance to where the CLIENTS draw a seat of a
	    flying model (the server's copy of the model never turns, D31).
	  * frameOf / craftStateAt / isEva are exported for EvaService and others.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Bubbles = require(ReplicatedStorage.Shared.Sim.Bubbles)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Eva = require(ReplicatedStorage.Shared.Sim.Eva)
local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PocketFrames = require(ReplicatedStorage.Shared.Sim.PocketFrames)
local Rails = require(ReplicatedStorage.Shared.Sim.Rails)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local CraftService = require(script.Parent.CraftService)
local CrewService = require(script.Parent.CrewService)
local FlightService = require(script.Parent.FlightService)
local PocketService = require(script.Parent.PocketService)

type CraftRecord = CraftService.CraftRecord
type FlightPocket = PocketService.FlightPocket
type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local CHECK_INTERVAL = 1 / GameConfig.BUBBLE_CHECK_RATE -- s
local BASE_BUBBLE = GameConfig.BASE_BUBBLE -- m around the launch site
local BASE_JOIN_HEIGHT = GameConfig.BASE_JOIN_HEIGHT -- m of the feet above the ground
local BASE_CRAFT_MARGIN = 200 -- m beyond BASE_BUBBLE where pockets do not merge and crafts are not pulled in
local MAX_EXTRAPOLATE = 2 -- s a craft's last state is carried forward with its velocity
local SEAT_REACH = 22 -- studs: a SitPrompt's 8-stud range plus room for latency and interpolation
local SLOT_CAPTURE_RADIUS = PocketService.SLOT_CAPTURE_RADIUS
local INERTIAL: PocketFrames.Mode = "INERTIAL" -- a new solo pocket's starting mode (desiredMode may pick the ground)
--============================================================================

export type Astronaut = {
	player: Player,
	pocket: FlightPocket,
	frame: Frames.Frame,
	bodyId: number,
	pos: Vec3d, -- relative to bodyId (= the pocket frame's reference body)
	vel: Vec3d,
	feet: number, -- m of the feet above the ground
	settled: boolean,
}

local BubbleService = {}

local accumulator = 0

--============================================================================
-- States and frames
--============================================================================

-- A craft's state at `ut`: its rail, or its last (valid) state carried forward with its velocity.
function BubbleService.craftStateAt(record: CraftRecord, ut: number): FlightModel.CraftState?
	local rails = record.rails
	if record.state == "OnRails" and rails then
		return Rails.stateAt(rails, ut)
	end
	local sim = record.sim
	if sim == nil then
		return nil
	end
	local s = sim.state
	local dt = math.clamp(ut - s.ut, -MAX_EXTRAPOLATE, MAX_EXTRAPOLATE)
	return {
		bodyId = s.bodyId,
		pos = Vec3d.addScaled(s.pos, s.vel, dt),
		vel = Vec3d.clone(s.vel),
		rot = s.rot,
		angVel = s.angVel,
		throttle = s.throttle,
		flags = s.flags,
		ut = s.ut + dt,
	}
end

-- The frame clients use for a craft-primary pocket whose craft is at `state`.
local function horizonFrame(pocket: FlightPocket, state: FlightModel.CraftState, ut: number): Frames.Frame
	return Frames.new(
		state.bodyId,
		state.pos,
		Universe.pocketRotation(state.bodyId, state.pos, ut),
		pocket.slotOrigin,
		PocketService.frameEpoch(pocket.id)
	)
end

-- A pocket's frame from its folder attributes (a lost primary; the last reference it had).
local function attributeFrame(pocket: FlightPocket): Frames.Frame?
	local folder = pocket.folder
	local x, y, z = folder:GetAttribute("RefX"), folder:GetAttribute("RefY"), folder:GetAttribute("RefZ")
	local rot, body = folder:GetAttribute("RefRot"), folder:GetAttribute("RefBodyId")
	if
		type(x) ~= "number"
		or type(y) ~= "number"
		or type(z) ~= "number"
		or typeof(rot) ~= "CFrame"
		or type(body) ~= "number"
	then
		return nil
	end
	return Frames.new(body, Vec3d.new(x, y, z), rot, pocket.slotOrigin, PocketService.frameEpoch(pocket.id))
end

--[[
	A flight pocket's frame at `ut` and its reference's velocity (relative to the frame's body), as its clients have
	it. nil when it cannot be known.
]]
function BubbleService.pocketFrame(pocket: FlightPocket, ut: number): (Frames.Frame?, Vec3d)
	if pocket.kind == "Solo" then
		local ref = pocket.ref
		if ref == nil then
			return nil, Vec3d.zero()
		end
		local pos, vel = PocketFrames.referenceAt(ref, ut)
		local frame = Frames.new(
			ref.bodyId,
			pos,
			PocketFrames.rotationAt(ref, pos, ut),
			pocket.slotOrigin,
			PocketService.frameEpoch(pocket.id)
		)
		return frame, vel
	end
	local craftId = pocket.craftId
	local record = if craftId then CraftService.get(craftId) else nil
	local state = if record and record.pocketId == pocket.id then BubbleService.craftStateAt(record, ut) else nil
	if state then
		return horizonFrame(pocket, state, ut), Vec3d.clone(state.vel)
	end
	return attributeFrame(pocket), Vec3d.zero()
end

-- Any pocket's frame (0 = the base) at `ut`, and its reference velocity.
function BubbleService.frameOf(pocketId: number, ut: number): (Frames.Frame?, Vec3d)
	if pocketId == PocketService.BASE_POCKET_ID then
		return PocketService.baseFrame(), Vec3d.zero()
	end
	local pocket = PocketService.flightPocket(pocketId)
	if pocket == nil then
		return nil, Vec3d.zero()
	end
	return BubbleService.pocketFrame(pocket, ut)
end

-- The rigid transform taking workspace coordinates of `from` to `to` (same true point), body offsets in doubles.
local function transformBetween(from: Frames.Frame, to: Frames.Frame, ut: number): CFrame
	local offset = if from.refBodyId ~= to.refBodyId then Universe.bodyOffset(from.refBodyId, to.refBodyId, ut) else nil
	return Frames.relativeTransform(from, to, offset)
end

-- Absolute (universe-frame) position of a body-relative point.
local function absolute(bodyId: number, pos: Vec3d, ut: number): Vec3d
	return Vec3d.add(pos, Universe.bodyPosition(bodyId, ut))
end

--============================================================================
-- Players
--============================================================================

local function aliveHumanoid(player: Player): (Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = if character then character:FindFirstChildOfClass("Humanoid") else nil
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return humanoid, root
	end
	return nil, nil
end

-- Is the player on EVA: alive, on foot, in a pocket other than the base?
function BubbleService.isEva(player: Player): boolean
	local humanoid = aliveHumanoid(player)
	local pocketId = player:GetAttribute("PocketId")
	return humanoid ~= nil
		and humanoid.SeatPart == nil
		and type(pocketId) == "number"
		and pocketId ~= PocketService.BASE_POCKET_ID
end

-- Where an astronaut on EVA is (nil when he is not on EVA or his pocket is unknown).
local function astronautOf(player: Player, ut: number): Astronaut?
	local humanoid, root = aliveHumanoid(player)
	local pocketId = player:GetAttribute("PocketId")
	if humanoid == nil or root == nil or humanoid.SeatPart ~= nil or type(pocketId) ~= "number" then
		return nil
	end
	local pocket = PocketService.flightPocket(pocketId)
	if pocket == nil then
		return nil
	end
	local frame, frameVel = BubbleService.pocketFrame(pocket, ut)
	if frame == nil then
		return nil
	end
	local f = frame :: Frames.Frame
	local position = (root :: BasePart).Position
	local pos = Frames.pointFromWorkspace(f, position)
	local vel = Vec3d.add(frameVel, Frames.vectorFromWorkspace(f, (root :: BasePart).AssemblyLinearVelocity))
	local settled = not PocketService.isPinned(player)
		and (position - pocket.slotOrigin).Magnitude < SLOT_CAPTURE_RADIUS
	return {
		player = player,
		pocket = pocket,
		frame = f,
		bodyId = f.refBodyId,
		pos = pos,
		vel = vel,
		feet = (Eva.groundHeight(f.refBodyId, pos)),
		settled = settled and Vec3d.isFinite(pos) and Vec3d.isFinite(vel),
	}
end

-- Is a body-relative point within `radius` of the launch site (and on its body)?
local function nearLaunchSite(bodyId: number, pos: Vec3d, radius: number): boolean
	local base = PocketService.baseFrame()
	return bodyId == base.refBodyId and Vec3d.distance(pos, base.refPos) < radius
end

--============================================================================
-- Moves
--============================================================================

local function transfer(player: Player, fromId: number, toId: number, m: CFrame)
	FlightService.sendTransfer(player, fromId, toId, m, PocketService.frameEpoch(toId))
end

local function craftsFolder(pocket: FlightPocket): Instance
	return pocket.folder:FindFirstChild("Crafts") or pocket.folder
end

-- Moves a craft's real model into another pocket (server pose moved by m, so seated characters change slot too).
local function moveModel(record: CraftRecord, to: FlightPocket, m: CFrame)
	local model = record.model
	if model == nil then
		return
	end
	model:SetAttribute("FlightPocket", nil) -- clients stop posing it before the move reaches them (D31)
	model:PivotTo(m * model:GetPivot())
	FlightService.bumpPoseEpoch(model)
	model.Parent = craftsFolder(to)
	model:SetAttribute("FlightPocket", to.id)
	record.origin = m * record.origin
	record.pocketId = to.id
	CraftService.announce(record)
end

-- Crafts whose real model is in a pocket.
local function craftsIn(pocketId: number): { CraftRecord }
	local list = {}
	for _, record in CraftService.all() do
		if record.pocketId == pocketId and record.model ~= nil then
			table.insert(list, record)
		end
	end
	table.sort(list, function(a: CraftRecord, b: CraftRecord): boolean
		return a.id < b.id
	end)
	return list
end

-- Releases a Solo pocket nobody is in any more (its crafts go back to cosmetic copies through the release listener).
local function releaseIfEmpty(pocket: FlightPocket)
	if PocketService.flightPocket(pocket.id) == pocket and #PocketService.playersIn(pocket.id) == 0 then
		PocketService.releaseFlightPocket(pocket.id)
	end
end

--[[
	A new primary for a pocket, in place: oldFrame is the frame its clients have now. Exactly one of craftId / userId
	(with the astronaut's new reference). Everyone in the pocket gets the in-place PocketTransfer.
]]
local function repoint(
	pocket: FlightPocket,
	oldFrame: Frames.Frame,
	craftId: number?,
	userId: number?,
	ref: PocketFrames.Reference?,
	ut: number
)
	if craftId then
		local record = CraftService.get(craftId)
		local state = if record then BubbleService.craftStateAt(record, ut) else nil
		if state == nil then
			return
		end
		local s = state :: FlightModel.CraftState
		PocketService.setCraftPrimary(pocket.id, craftId, s.bodyId, s.pos, Universe.pocketRotation(s.bodyId, s.pos, ut))
	elseif userId and ref then
		PocketService.setSoloPrimary(pocket.id, userId, ref)
	else
		return
	end
	local newFrame = BubbleService.pocketFrame(pocket, ut)
	if newFrame == nil then
		return
	end
	local m = transformBetween(oldFrame, newFrame :: Frames.Frame, ut)
	for _, player in PocketService.playersIn(pocket.id) do
		transfer(player, pocket.id, pocket.id, m)
	end
end

-- A solo reference for an astronaut where he is (mode by height and speed, in the SOI body he is in).
local function soloReferenceFor(astronaut: Astronaut, mode: PocketFrames.Mode, ut: number): PocketFrames.Reference
	local bodyId, pos = Universe.soiTransition(astronaut.bodyId, astronaut.pos, ut)
	local vel = astronaut.vel
	if bodyId ~= astronaut.bodyId then
		vel = Vec3d.add(vel, Universe.bodyVelocityOffset(astronaut.bodyId, bodyId, ut))
	end
	return PocketFrames.solo(mode, bodyId, pos, vel, ut)
end

--============================================================================
-- Actions
--============================================================================

type Context = {
	ut: number,
	astronauts: { [number]: Astronaut }, -- user id -> astronaut
	changed: { [number]: boolean }, -- pockets changed this check (no solo upkeep for them)
}

local function applyRepoint(ctx: Context, action: Bubbles.Action)
	local pocket = if action.pocketId then PocketService.flightPocket(action.pocketId) else nil
	if pocket == nil then
		return
	end
	local p = pocket :: FlightPocket
	local oldFrame = BubbleService.pocketFrame(p, ctx.ut)
	if oldFrame == nil then
		return
	end
	if action.craftId then
		local record = CraftService.get(action.craftId)
		if record == nil or record.pocketId ~= p.id then
			return
		end
		repoint(p, oldFrame :: Frames.Frame, action.craftId, nil, nil, ctx.ut)
	elseif action.userId then
		local astronaut = ctx.astronauts[action.userId]
		if astronaut == nil or astronaut.pocket ~= p then
			return
		end
		local mode: PocketFrames.Mode = PocketFrames.desiredMode(INERTIAL, astronaut.feet, Vec3d.length(astronaut.vel))
		repoint(p, oldFrame :: Frames.Frame, nil, action.userId, soloReferenceFor(astronaut, mode, ctx.ut), ctx.ut)
	end
	ctx.changed[p.id] = true
end

local function applyMerge(ctx: Context, action: Bubbles.Action)
	local from = if action.fromId then PocketService.flightPocket(action.fromId) else nil
	local into = if action.intoId then PocketService.flightPocket(action.intoId) else nil
	if from == nil or into == nil or from == into then
		return
	end
	local f, i = from :: FlightPocket, into :: FlightPocket
	local fromFrame = BubbleService.pocketFrame(f, ctx.ut)
	local intoFrame = BubbleService.pocketFrame(i, ctx.ut)
	if fromFrame == nil or intoFrame == nil then
		return
	end
	local m = transformBetween(fromFrame :: Frames.Frame, intoFrame :: Frames.Frame, ctx.ut)
	for _, record in craftsIn(f.id) do
		moveModel(record, i, m)
	end
	for _, player in PocketService.playersIn(f.id) do
		transfer(player, f.id, i.id, m)
	end
	PocketService.releaseFlightPocket(f.id) -- nothing left in it: its release listener finds no craft
	ctx.changed[f.id] = true
	ctx.changed[i.id] = true
end

local function applyJoin(ctx: Context, action: Bubbles.Action)
	local astronaut = if action.userId then ctx.astronauts[action.userId] else nil
	local target = if action.pocketId then PocketService.flightPocket(action.pocketId) else nil
	if astronaut == nil or target == nil or astronaut.pocket == target then
		return
	end
	local a, q = astronaut :: Astronaut, target :: FlightPocket
	local targetFrame = BubbleService.pocketFrame(q, ctx.ut)
	if targetFrame == nil then
		return
	end
	transfer(a.player, a.pocket.id, q.id, transformBetween(a.frame, targetFrame :: Frames.Frame, ctx.ut))
	if a.pocket.kind == "Solo" then
		releaseIfEmpty(a.pocket)
	end
end

local function applyNewSolo(ctx: Context, action: Bubbles.Action)
	local astronaut = if action.userId then ctx.astronauts[action.userId] else nil
	if astronaut == nil then
		return
	end
	local a = astronaut :: Astronaut
	local mode: PocketFrames.Mode = PocketFrames.desiredMode(INERTIAL, a.feet, Vec3d.length(a.vel))
	local ref = soloReferenceFor(a, mode, ctx.ut)
	local pocket = PocketService.createSoloPocket(a.player.UserId, ref)
	if pocket == nil then
		return -- every slot is taken: he stays where he is for now
	end
	local p = pocket :: FlightPocket
	local frame = BubbleService.pocketFrame(p, ctx.ut)
	if frame == nil then
		PocketService.releaseFlightPocket(p.id)
		return
	end
	transfer(a.player, a.pocket.id, p.id, transformBetween(a.frame, frame :: Frames.Frame, ctx.ut))
	ctx.changed[p.id] = true
end

local function applyToBase(ctx: Context, action: Bubbles.Action)
	local astronaut = if action.userId then ctx.astronauts[action.userId] else nil
	if astronaut == nil then
		return
	end
	local a = astronaut :: Astronaut
	local base = PocketService.baseFrame()
	transfer(a.player, a.pocket.id, PocketService.BASE_POCKET_ID, transformBetween(a.frame, base, ctx.ut))
	if a.pocket.kind == "Solo" then
		releaseIfEmpty(a.pocket)
	end
end

local function applySplitCraft(ctx: Context, action: Bubbles.Action)
	local record = if action.craftId then CraftService.get(action.craftId) else nil
	if record == nil or record.model == nil or record.pocketId == nil then
		return
	end
	local r = record :: CraftRecord
	local from = PocketService.flightPocket(r.pocketId :: number)
	local state = BubbleService.craftStateAt(r, ctx.ut)
	if from == nil or state == nil then
		return
	end
	local fromFrame = BubbleService.pocketFrame(from :: FlightPocket, ctx.ut)
	if fromFrame == nil then
		return
	end
	local s = state :: FlightModel.CraftState
	local pocket =
		PocketService.createFlightPocket(r.id, s.bodyId, s.pos, Universe.pocketRotation(s.bodyId, s.pos, ctx.ut))
	if pocket == nil then
		return
	end
	local p = pocket :: FlightPocket
	local m = transformBetween(fromFrame :: Frames.Frame, horizonFrame(p, s, ctx.ut), ctx.ut)
	local crew = FlightService.seatedIn(r.model :: Model)
	moveModel(r, p, m)
	for _, player in crew do
		transfer(player, (from :: FlightPocket).id, p.id, m)
	end
	ctx.changed[p.id] = true
end

local function applyDropCraft(_ctx: Context, action: Bubbles.Action)
	local record = if action.craftId then CraftService.get(action.craftId) else nil
	if record == nil or record.model == nil then
		return
	end
	local r = record :: CraftRecord
	if #FlightService.seatedIn(r.model :: Model) > 0 then
		return -- somebody sat down meanwhile
	end
	(r.model :: Model):Destroy()
	r.model = nil
	r.pocketId = nil
	CraftService.announce(r)
end

local function applyAddCraft(ctx: Context, action: Bubbles.Action)
	local record = if action.craftId then CraftService.get(action.craftId) else nil
	local pocket = if action.pocketId then PocketService.flightPocket(action.pocketId) else nil
	if record == nil or pocket == nil or record.model ~= nil or record.pocketId ~= nil then
		return
	end
	local r, p = record :: CraftRecord, pocket :: FlightPocket
	if not CraftService.isBoardable(r) then
		return
	end
	local state = BubbleService.craftStateAt(r, ctx.ut)
	local frame = BubbleService.pocketFrame(p, ctx.ut)
	local sim = r.sim
	if state == nil or frame == nil or sim == nil then
		return
	end
	local s, f = state :: FlightModel.CraftState, frame :: Frames.Frame
	local design = sim.physics.design
	local root = CraftDesign.rootBlock(design)
	if root == nil then
		return
	end
	local offset = if s.bodyId ~= f.refBodyId then Universe.bodyOffset(s.bodyId, f.refBodyId, ctx.ut) else nil
	local craftCFrame = Frames.cframeToWorkspace(f, s.pos, s.rot, offset)
	local origin = craftCFrame * CFrame.new(-(CraftDesign.blockCenter(root) * CraftDesign.GRID))
	CraftService.buildFlightModel(r, origin, p.id, craftsFolder(p))
	CraftService.announce(r)
end

local APPLY: { [string]: (Context, Bubbles.Action) -> () } = {
	Repoint = applyRepoint,
	Merge = applyMerge,
	Join = applyJoin,
	NewSolo = applyNewSolo,
	ToBase = applyToBase,
	SplitCraft = applySplitCraft,
	DropCraft = applyDropCraft,
	AddCraft = applyAddCraft,
}

--============================================================================
-- Solo upkeep (EVA rebase)
--============================================================================

local function soloUpkeep(ctx: Context)
	for id, pocket in PocketService.flightPockets() do
		if ctx.changed[id] or pocket.kind ~= "Solo" then
			continue
		end
		local userId = pocket.userId
		local ref = pocket.ref
		local astronaut = if userId then ctx.astronauts[userId] else nil
		if ref == nil or astronaut == nil or astronaut.pocket ~= pocket or not astronaut.settled then
			continue
		end
		local a = astronaut :: Astronaut
		local r = ref :: PocketFrames.Reference
		local mode: PocketFrames.Mode = PocketFrames.desiredMode(r.mode, a.feet, Vec3d.length(a.vel))
		local soi = Universe.soiTransition(a.bodyId, a.pos, ctx.ut)
		if mode ~= r.mode or soi ~= r.bodyId or PocketFrames.needsRebase(r, ctx.ut, a.pos) then
			repoint(pocket, a.frame, nil, a.player.UserId, soloReferenceFor(a, mode, ctx.ut), ctx.ut)
			ctx.changed[id] = true
		end
	end
end

--============================================================================
-- The check
--============================================================================

local function check()
	local ut = UniverseTime.now()
	local ctx: Context = { ut = ut, astronauts = {}, changed = {} }

	-- pockets busy with a launch / return / end are left alone this check
	local skip: { [number]: boolean } = {}
	for id, pocket in PocketService.flightPockets() do
		for _, record in CraftService.all() do
			if record.pocketId == id and FlightService.isBusy(record.id) then
				skip[id] = true
			end
		end
		local craftId = pocket.craftId
		if craftId and FlightService.isBusy(craftId) then
			skip[id] = true
		end
	end

	-- astronauts
	local astronauts: { Bubbles.Astronaut } = {}
	for _, player in Players:GetPlayers() do
		local astronaut = astronautOf(player, ut)
		if astronaut and not skip[astronaut.pocket.id] then
			local a = astronaut :: Astronaut
			ctx.astronauts[player.UserId] = a
			table.insert(astronauts, {
				userId = player.UserId,
				pocketId = a.pocket.id,
				bodyId = a.bodyId,
				pos = absolute(a.bodyId, a.pos, ut),
				settled = a.settled,
				nearBase = nearLaunchSite(a.bodyId, a.pos, BASE_BUBBLE) and a.feet < BASE_JOIN_HEIGHT,
			})
		end
	end

	-- crafts in flight
	local crafts: { Bubbles.Craft } = {}
	local anchorOf: { [number]: { bodyId: number, abs: Vec3d, nearBase: boolean } } = {}
	for id, record in CraftService.all() do
		if record.state == "Destroyed" or record.state == "Prelaunch" or FlightService.isBusy(id) then
			continue
		end
		local pocketId = record.pocketId
		if pocketId and skip[pocketId] then
			continue
		end
		local state = BubbleService.craftStateAt(record, ut)
		if state == nil then
			continue
		end
		local s = state :: FlightModel.CraftState
		local model = record.model
		local nearBase = nearLaunchSite(s.bodyId, s.pos, BASE_BUBBLE + BASE_CRAFT_MARGIN)
		local abs = absolute(s.bodyId, s.pos, ut)
		anchorOf[id] = { bodyId = s.bodyId, abs = abs, nearBase = nearBase }
		table.insert(crafts, {
			id = id,
			pocketId = if model then pocketId else nil,
			bodyId = s.bodyId,
			pos = abs,
			crew = if model then #FlightService.seatedIn(model) else 0,
			boardable = CraftService.isBoardable(record),
			nearBase = nearBase,
		})
	end

	-- pockets
	local pockets: { Bubbles.Pocket } = {}
	for id, pocket in PocketService.flightPockets() do
		if skip[id] then
			continue
		end
		local bodyId = Bodies.HOMEWORLD
		local anchor: Vec3d? = nil
		local nearBase = false
		if pocket.kind == "Craft" then
			local craftId = pocket.craftId
			local record = if craftId then CraftService.get(craftId) else nil
			local info = if craftId and record and record.pocketId == id then anchorOf[craftId] else nil
			if info then
				bodyId, anchor, nearBase = info.bodyId, info.abs, info.nearBase
			end
		else
			local userId = pocket.userId
			local astronaut = if userId then ctx.astronauts[userId] else nil
			-- his own position once settled (right after a transfer the server still sees the old one)
			if astronaut and astronaut.pocket == pocket and astronaut.settled then
				bodyId = astronaut.bodyId
				anchor = absolute(astronaut.bodyId, astronaut.pos, ut)
				nearBase = nearLaunchSite(astronaut.bodyId, astronaut.pos, BASE_BUBBLE + BASE_CRAFT_MARGIN)
			elseif pocket.ref then
				local ref = pocket.ref :: PocketFrames.Reference
				local pos = PocketFrames.referenceAt(ref, ut)
				bodyId = ref.bodyId
				anchor = absolute(ref.bodyId, pos, ut)
			end
		end
		table.insert(pockets, {
			id = id,
			kind = pocket.kind,
			primaryCraftId = pocket.craftId,
			primaryUserId = pocket.userId,
			bodyId = bodyId,
			anchor = anchor,
			order = pocket.order,
			players = #PocketService.playersIn(id),
			nearBase = nearBase,
		})
	end

	for _, action in Bubbles.decide({ pockets = pockets, crafts = crafts, astronauts = astronauts }) do
		local apply = APPLY[action.kind]
		if apply then
			local ok, err = pcall(function()
				apply(ctx, action)
			end)
			if not ok then
				warn(`[BubbleService] {action.kind} failed: {err}`)
			end
		end
	end
	soloUpkeep(ctx)
end

--============================================================================
-- A craft leaves the world: its pocket gets a new primary now
--============================================================================

local function onCraftRemoving(record: CraftRecord)
	local pocketId = record.pocketId
	local pocket = if pocketId then PocketService.flightPocket(pocketId) else nil
	if pocket == nil then
		return
	end
	local p = pocket :: FlightPocket
	if p.kind ~= "Craft" or p.craftId ~= record.id then
		return -- a secondary craft: the pocket keeps its primary
	end
	local ut = UniverseTime.now()
	local state = BubbleService.craftStateAt(record, ut)
	local oldFrame = if state then horizonFrame(p, state, ut) else attributeFrame(p)
	if oldFrame == nil then
		return
	end
	-- another craft in the pocket: the one with the most crew
	local best: CraftRecord? = nil
	local bestCrew = -1
	for _, other in craftsIn(p.id) do
		if other ~= record then
			local crew = #FlightService.seatedIn(other.model :: Model)
			if crew > bestCrew then
				best, bestCrew = other, crew
			end
		end
	end
	if best then
		repoint(p, oldFrame :: Frames.Frame, best.id, nil, nil, ut)
		return
	end
	-- else an astronaut on EVA in it
	for _, player in PocketService.playersIn(p.id) do
		local astronaut = astronautOf(player, ut)
		if astronaut and astronaut.pocket == p then
			local a = astronaut :: Astronaut
			local mode: PocketFrames.Mode = PocketFrames.desiredMode(INERTIAL, a.feet, Vec3d.length(a.vel))
			repoint(p, oldFrame :: Frames.Frame, nil, player.UserId, soloReferenceFor(a, mode, ut), ut)
			return
		end
	end
	-- else nobody (or only the crew that goes down with it): release it
	if #PocketService.playersIn(p.id) == 0 then
		PocketService.releaseFlightPocket(p.id)
	end
end

--============================================================================
-- Seat reach (CrewService's SitPrompt check)
--============================================================================

local function craftModelOf(instance: Instance): Model?
	local node: Instance? = instance
	while node do
		if node:IsA("Model") and node:GetAttribute("CraftId") ~= nil then
			return node
		end
		node = node.Parent
	end
	return nil
end

--[[
	Can the player reach this seat? For a model in a flight pocket the seat is where the CLIENTS draw it: the craft's
	pose from its state through the pocket frame, times the seat's offset in the server's copy of the model. Players
	already seated in the same craft may always switch seats.
]]
function BubbleService.seatInReach(player: Player, seat: Seat): boolean
	local humanoid, root = aliveHumanoid(player)
	if humanoid == nil or root == nil then
		return false
	end
	local model = craftModelOf(seat)
	if model == nil then
		return true -- not a craft (nothing to check)
	end
	local current = humanoid.SeatPart
	if current and current:IsDescendantOf(model) then
		return true
	end
	local pocketId = model:GetAttribute("FlightPocket")
	local seatPosition = seat.Position
	if type(pocketId) == "number" then
		local craftId = model:GetAttribute("CraftId")
		local record = if type(craftId) == "number" then CraftService.get(craftId) else nil
		local ut = UniverseTime.now()
		local frame = BubbleService.frameOf(pocketId, ut)
		local state = if record then BubbleService.craftStateAt(record, ut) else nil
		local rootBlock = if record then CraftDesign.rootBlock(record.design) else nil
		if record == nil or frame == nil or state == nil or rootBlock == nil then
			return false
		end
		local f, s = frame :: Frames.Frame, state :: FlightModel.CraftState
		local offset = if s.bodyId ~= f.refBodyId then Universe.bodyOffset(s.bodyId, f.refBodyId, ut) else nil
		local clientCraft = Frames.cframeToWorkspace(f, s.pos, s.rot, offset)
		local serverCraft = record.origin * CFrame.new(CraftDesign.blockCenter(rootBlock) * CraftDesign.GRID)
		seatPosition = (clientCraft * serverCraft:Inverse()):PointToWorldSpace(seat.Position)
	end
	return ((root :: BasePart).Position - seatPosition).Magnitude <= SEAT_REACH
end

--============================================================================
-- Lifecycle
--============================================================================

function BubbleService.Init()
	CraftService.onRemoving(onCraftRemoving)
	CrewService.setSeatReach(BubbleService.seatInReach)
end

function BubbleService.Start()
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < CHECK_INTERVAL then
			return
		end
		accumulator = 0
		local ok, err = pcall(function()
			check()
		end)
		if not ok then
			warn(`[BubbleService] check failed: {err}`)
		end
	end)
end

return BubbleService
