--!strict
--[[
	Effects (Phase 10)
	Every client-side rocket effect except the landing-leg animation: engine plumes (Render/Plumes), smoke trails,
	launch/landing dust, stage-separation puffs, explosions, re-entry heating and the transonic vapour cone.
	Purely cosmetic and local (invariants I5/I6): nothing here is replicated, nothing touches Roblox physics (I3).

	Who drives it
	  * FlightController reports the craft this client simulates (source "Local") every frame, from its own sim, and
	    calls blockEvent() for its predicted staging and crash reports.
	  * RemoteCraftRenderer reports every cosmetic copy it draws (source "Stream", interpolated states) and the real
	    model of this pocket's primary craft when someone else flies it (passengers), and calls blockEvent() on
	    CraftStaged / PartsDestroyed.
	  So every player sees the same effects for every craft, driven only by data every client already has
	  (CraftState.flags FLAG_BURNING, throttle, active engines, velocity, position). No new remotes.
	  * UniverseRenderer calls step() once per frame after the pocket frame is updated and the copies are posed.

	Reports
	  reportCraft(id, report) stores the craft's model, design, state and burning engines for this frame; step()
	  turns them into instances. A craft that is not reported for STALE_FRAMES frames (not drawn: other pocket,
	  marker LOD, map view, hidden) has its continuous effects released, so hidden crafts never show effects. A
	  "Stream" report never overrides a recent "Local" one (the pilot's own simulation wins).

	Moving frames (the important bit)
	  In a flight pocket the craft is nearly still in the workspace and the world streams past it. Anything at rest
	  in the air (smoke, dust, explosion debris) must therefore move at the AIR velocity in pocket axes:
	    drift = vectorToWorkspace(frame, v_body(craft) - v_body(frame ref) - v_frame)
	  where v_frame is the pocket reference's velocity (PocketController.frameVelocity: the primary craft's velocity
	  in a flight pocket, zero in the base). ParticleEmitters cannot add a velocity to their particles, so each one is
	  aimed along drift + its own push and opens its cone just enough for the random part (EffectsMath.driftEmission).
	  The pocket's acceleration (smoothed from v_frame) is applied as -a to every drifting emitter, so trails do not
	  get dragged along while the rocket accelerates. Emitters that drift never use Drag (it would pull particles
	  toward the pocket's rest frame).

	Instances live in workspace.ClientUniverse.Effects (carrier parts: anchored, invisible, no collision/queries,
	no shadows) and, for plumes, under the engines' Exhaust attachments. Everything is pooled and capped
	(Tunables); particle rates scale with the graphics quality level (EffectsMath.qualityScale).

	No sounds yet: they need uploaded audio asset ids (follow-up).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Atmosphere = require(ReplicatedStorage.Shared.Sim.Atmosphere)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local EffectsMath = require(script.Parent.EffectsMath)
local Plumes = require(script.Parent.Plumes)
local RenderContext = require(script.Parent.RenderContext)

--============================================================================
-- Tunables
--============================================================================
local FOLDER_NAME = "Effects"
local STALE_FRAMES = 2 -- a craft not reported for this many frames has its continuous effects released
local FORGET_AFTER_S = 10 -- records of crafts not reported for this long are dropped
local PARK_CFRAME = CFrame.new(0, -10000, 0) -- where idle carrier parts wait (far below every pocket)
local QUALITY_POLL_S = 1
local DEDUPE_S = 3 -- the same block's separation / explosion is not shown twice within this time
-- Pocket motion
local ACCEL_SMOOTH_S = 0.25 -- s time constant of the pocket acceleration estimate
local ACCEL_MAX = 60 -- m/s^2 clamp
local ACCEL_RESET_DV = 50 -- m/s velocity jump in one frame that counts as a discontinuity (resets the estimate)
local ACCEL_WRITE_EPSILON = 0.3 -- m/s^2 change before emitter accelerations are rewritten
local SMOKE_BUOYANCY = 2.5 -- m/s^2 upward drift of smoke and fire (only in air)
-- Smoke trail
local MAX_TRAILS = 6
local TRAIL_RATE_MAX = 55 -- puffs/s at full strength and quality
local TRAIL_RANDOM_SPEED = 3 -- m/s random spread of trail puffs
local TRAIL_WIDTH_MULT = 1.4 -- x nozzle diameter
local TRAIL_OFFSET_DIAMETERS = 2.2 -- the trail starts this many nozzle diameters behind the nozzle (flame tip)
local TRAIL_GROWTH = 3.2 -- puffs grow to this x their start size
local TRAIL_LIQUID_WEIGHT = 0.45 -- liquid engines leave a thinner trail than solid boosters
local TRAIL_TRANSPARENCY_SOLID = 0.25
local TRAIL_TRANSPARENCY_LIQUID = 0.6
local TRAIL_MIN_STRENGTH = 0.02
local TRAIL_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local TRAIL_COLOR = ColorSequence.new(Color3.fromRGB(245, 242, 236), Color3.fromRGB(196, 196, 202))
-- Launch / landing dust
local MAX_DUST = 4
local DUST_EMITTERS = 6 -- point emitters in a ring (each aimed outward)
local DUST_RATE_MAX = 90 -- puffs/s for the whole ring at full strength and quality
local DUST_REFERENCE_THRUST = 200000 -- N; thrust fraction 1 (about one Solid Booster)
local DUST_OUT_SPEED = 38 -- m/s outward at full strength
local DUST_RISE_SPEED = 5 -- m/s upward
local DUST_RANDOM_SPEED = 9
local DUST_SIZE = 7 -- studs start size at full strength for a 4-stud nozzle
local DUST_GROWTH = 2.6
local DUST_LIFETIME = NumberRange.new(1.6, 3.2)
local DUST_DRAG = 1.2 -- only while the pocket hardly moves (see header)
local DUST_DRAG_FADE_SPEED = 20 -- m/s of drift at which the drag is gone
local DUST_DOWN_MIN = 0.3 -- exhaust must point at least this much toward the ground (cos)
local DUST_CHECK_MARGIN = 120 -- m; the ground is only looked up below max dust height + craft size + this
local DUST_COLOR_INTERVAL = 0.5 -- s between ground colour samples
local DUST_SMOKE_COLOR = Color3.fromRGB(200, 196, 188) -- mixed into the ground colour
local DUST_GROUND_MIX = 0.55
local DUST_WATER_COLOR = Color3.fromRGB(240, 246, 255) -- spray over the ocean
local DUST_MIN_STRENGTH = 0.02
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
-- Re-entry heating and the vapour cone
local MAX_AERO = 4
local AERO_MIN = 0.02
local HEAT_QUANTUM = 0.05 -- heat steps at which beam transparency sequences are rebuilt
local HEAT_CAP_RATE = 45 -- glow puffs/s at the leading side at full heat
local HEAT_STREAK_RATE = 70 -- streaks/s at full heat
local HEAT_STREAK_LIFETIME = 0.22 -- s
local HEAT_STREAK_SQUASH = 1.8 -- ParticleEmitter.Squash: streaks stretched along their motion
local HEAT_LIGHT = 4
local HEAT_FLICKER = 0.07 -- relative random width wobble per frame
local HEAT_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 244, 220)),
	ColorSequenceKeypoint.new(0.15, Color3.fromRGB(255, 176, 90)),
	ColorSequenceKeypoint.new(0.6, Color3.fromRGB(255, 110, 140)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 80, 170)),
})
local HEAT_LIGHT_COLOR = Color3.fromRGB(255, 140, 90)
local VAPOR_COLOR = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(235, 240, 248))
local VAPOR_OPACITY = 0.6 -- peak opacity of the vapour cone
local FIRE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
-- One-shot bursts (ignition, cut-off, separation, explosions)
local BURST_POOL = 16
local BURST_SMOKE_COLOR = ColorSequence.new(Color3.fromRGB(235, 232, 226), Color3.fromRGB(150, 148, 146))
local BURST_DARK_SMOKE_COLOR = ColorSequence.new(Color3.fromRGB(90, 80, 72), Color3.fromRGB(40, 38, 38))
local BURST_FIRE_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 210)),
	ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 180, 60)),
	ColorSequenceKeypoint.new(0.7, Color3.fromRGB(230, 80, 20)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 30, 15)),
})
local BURST_SPARK_COLOR = ColorSequence.new(Color3.fromRGB(255, 240, 180), Color3.fromRGB(255, 120, 40))
local BURST_LIGHT_COLOR = Color3.fromRGB(255, 190, 120)
-- Stage separation
local SEPARATION_SMOKE = 10
local SEPARATION_SPARKS = 10
local SEPARATION_LIGHT = 5
-- Explosions
local EXPLOSIONS_PER_EVENT = 6 -- largest destroyed blocks that get a full explosion per event
local EXPLOSIONS_PER_SECOND = 10 -- refill rate of the explosion budget
local EXPLOSION_BUDGET = 12 -- most explosions in one burst of events
local MAX_FIREBALLS = 10
local FIREBALL_TIME = 0.5 -- s for a 4-stud block (grows with sqrt of the scale)
local FIREBALL_SIZE0 = 2.5 -- studs x explosion scale
local FIREBALL_SIZE1 = 9
local MAX_BITS = 40
local BITS_PER_EXPLOSION = 5
local BIT_SPEED_MIN = 15
local BIT_SPEED_MAX = 40
local BIT_LIFETIME_MIN = 0.8
local BIT_LIFETIME_MAX = 1.6
local BIT_SIZE = 0.7 -- studs x sqrt(scale)
local BIT_COLOR = Color3.fromRGB(255, 150, 60)
local EXPLOSION_LIGHT = 10
local EXPLOSION_LIGHT_TIME = 0.6
local CLASSIC_EXPLOSION = true -- also play Roblox's classic Explosion (no pressure, no joint breaking)
local CLASSIC_MAX_DRIFT = 30 -- m/s; not when the air streams past fast (the classic effect cannot move)
local CLASSIC_MIN_QUALITY = 0.5 -- quality scale below which it is skipped
local CLASSIC_CLEANUP_S = 3
--============================================================================

type Vec3d = Vec3d.Vec3d
type RenderContext = RenderContext.RenderContext

-- What both CraftState (FlightModel) and Protocol.State provide.
export type EffectState = {
	bodyId: number,
	pos: Vec3d,
	vel: Vec3d,
	rot: CFrame,
	flags: number,
}

export type Source = "Local" | "Stream"

export type CraftReport = {
	source: Source,
	model: Model, -- the model plumes go on (real model or cosmetic copy)
	design: CraftDesign.Design, -- the craft's current design (block ids match the model)
	state: EffectState, -- the state the model is drawn at
	burning: { [number]: number }, -- engine block id -> throttle for engines producing thrust
	craftCFrame: CFrame?, -- workspace pose of the craft reference frame; nil = from the state via the pocket frame
}

type EngineInfo = {
	exhaust: Vector3, -- craft-local nozzle exit
	direction: Vector3, -- craft-local unit, down the exhaust
	diameter: number, -- studs
	thrust: number, -- N (vacuum)
	solid: boolean,
}

type BlockInfo = { pos: Vector3, size: Vector3 } -- craft-local centre, studs

type DesignInfo = {
	count: number, -- #design.blocks when computed (copies remove blocks in place)
	center: Vector3, -- craft-local bounding-box centre
	half: Vector3, -- bounding-box half size
	engines: { [number]: EngineInfo },
	blocks: { [number]: BlockInfo },
}

type TrailSlot = {
	part: Part,
	attachment: Attachment,
	emitter: ParticleEmitter,
	size: number,
	transparency: number,
	lifetime: number,
}

type DustSlot = {
	part: Part,
	attachments: { Attachment },
	emitters: { ParticleEmitter },
	size: number,
	color: Color3,
}

type AeroSlot = {
	part: Part,
	lead: Attachment,
	tail: Attachment,
	vaporStart: Attachment,
	vaporEnd: Attachment,
	cap: ParticleEmitter,
	streaks: ParticleEmitter,
	inner: Beam,
	outer: Beam,
	vapor: Beam,
	light: PointLight,
	heatLevel: number, -- quantised heat the beam sequences were built for (-1 = never)
	heatRadius: number, -- radius the glow / streak sizes were built for
	heatLength: number, -- plasma length the streak speed was built for
	vaporLevel: number,
}

type CraftRecord = {
	id: number,
	source: Source, -- source of the report processed last
	report: CraftReport?, -- report processed last
	processedFrame: number, -- frame it was processed in
	localReport: CraftReport?, -- latest report from the pilot's own simulation
	localFrame: number,
	streamReport: CraftReport?, -- latest report from the stream (copies, passengers)
	streamFrame: number,
	reportTime: number, -- os.clock() of the latest report of either source
	model: Model?,
	craftCFrame: CFrame,
	drift: Vector3,
	centerWs: Vector3,
	trail: TrailSlot?,
	dust: DustSlot?,
	aero: AeroSlot?,
	dustColor: Color3,
	dustColorTimer: number,
}

type Burst = {
	part: Part,
	smokeAttachment: Attachment,
	fireAttachment: Attachment,
	sparkAttachment: Attachment,
	smoke: ParticleEmitter,
	fire: ParticleEmitter,
	sparks: ParticleEmitter,
	light: PointLight,
	lightPeak: number,
	lightDuration: number,
	age: number,
	buoyancy: Vector3,
}

type BurstSpec = {
	smoke: number, -- particles (before quality scaling)
	smokeVelocity: Vector3, -- push on top of the drift
	smokeRandom: number,
	smokeSize0: number,
	smokeSize1: number,
	smokeLife: NumberRange,
	smokeColor: ColorSequence,
	smokeTransparency: number, -- start transparency
	fire: number,
	fireRandom: number,
	fireSize0: number,
	fireSize1: number,
	fireLife: NumberRange,
	sparks: number,
	sparkVelocity: Vector3,
	sparkRandom: number,
	sparkSize: number,
	sparkLife: NumberRange,
	light: number,
	lightRange: number,
	lightDuration: number,
}

type Fireball = {
	part: Part,
	active: boolean,
	age: number,
	duration: number,
	size0: number,
	size1: number,
	velocity: Vector3,
}

type Bit = {
	part: Part,
	trail: Trail,
	active: boolean,
	age: number,
	life: number,
	velocity: Vector3,
	spin: Vector3, -- rad/s about part axes
	size: number,
}

local Effects = {}

local folder: Folder? = nil
local frameCounter = 0
local records: { [number]: CraftRecord } = {}
local designCache: { [CraftDesign.Design]: DesignInfo } = setmetatable({}, { __mode = "k" }) :: any
local freeTrails: { TrailSlot } = {}
local freeDust: { DustSlot } = {}
local freeAero: { AeroSlot } = {}
local trailCount, dustCount, aeroCount = 0, 0, 0 -- created so far (caps)
local bursts: { Burst } = {}
local nextBurst = 1
local fireballs: { Fireball } = {}
local bits: { Bit } = {}
local dedupe: { [string]: number } = {}
local dedupeTimer = 0
local explosionBudget = EXPLOSION_BUDGET
local eventScratch: { Plumes.PlumeEvent } = {}
local bitParts: { BasePart } = {}
local bitCFrames: { CFrame } = {}
local rng = Random.new()

-- Pocket motion
local lastPocketId = -1
local lastEpoch = -1
local lastFrameVel: Vector3? = nil
local frameAccel = Vector3.zero -- pocket axes, m/s^2
local writtenAccel = Vector3.new(1e9, 0, 0)
local baseDrift = Vector3.zero -- air velocity in pocket axes for crafts on the frame's reference body
local gravityWs = Vector3.zero
local smokeUp = Vector3.yAxis -- unit "up" (against gravity) in pocket axes

-- Quality
local userGameSettings = UserSettings():GetService("UserGameSettings")
local quality = 1
local qualityTimer = math.huge

-- Stats (F3)
local stats = { crafts = 0, trails = 0, dust = 0, aero = 0, bursts = 0 }

--============================================================================
-- Helpers
--============================================================================

-- The effects folder (it may be unparented while the map view hides it; it is never replaced then).
local function getFolder(): Folder
	local current = folder
	if current then
		return current
	end
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	local universe = workspace:FindFirstChild("ClientUniverse")
	created.Parent = universe or workspace
	folder = created
	return created
end

local function carrierPart(name: string): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = Vector3.one * 0.2
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.CFrame = PARK_CFRAME
	part.Parent = getFolder()
	return part
end

local function newEmitter(parent: Instance, name: string, texture: string): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = name
	emitter.Texture = texture
	emitter.Enabled = true
	emitter.Rate = 0
	emitter.LockedToPart = false
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-40, 40)
	emitter.Drag = 0
	emitter.Parent = parent
	return emitter
end

local function newAttachment(parent: Instance, name: string): Attachment
	local attachment = Instance.new("Attachment")
	attachment.Name = name
	attachment.Parent = parent
	return attachment
end

local function sizeSequence(size0: number, size1: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, math.max(size0, 0.05)),
		NumberSequenceKeypoint.new(1, math.max(size1, 0.05)),
	})
end

local function fadeSequence(start: number): NumberSequence
	local s = math.clamp(start, 0, 1)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, math.min(s + 0.15, 1)),
		NumberSequenceKeypoint.new(0.12, s),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- Points an emitter (on its own attachment) so its particles move with `velocity` plus up to `randomSpeed`.
local function aim(
	attachment: Attachment,
	emitter: ParticleEmitter,
	position: Vector3,
	velocity: Vector3,
	randomSpeed: number
)
	local direction, speedMin, speedMax, spread = EffectsMath.driftEmission(velocity, randomSpeed)
	attachment.WorldCFrame = EffectsMath.frameWithUp(position, direction)
	emitter.Speed = NumberRange.new(speedMin, speedMax)
	emitter.SpreadAngle = Vector2.new(spread, spread)
end

local function scaledCount(count: number): number
	if count <= 0 then
		return 0
	end
	return math.max(math.round(count * quality), 1)
end

-- True the first time a key is seen within DEDUPE_S.
local function firstTime(key: string): boolean
	local now = os.clock()
	local seen = dedupe[key]
	if seen and now - seen < DEDUPE_S then
		return false
	end
	dedupe[key] = now
	return true
end

--============================================================================
-- Design data (craft-local geometry, cached per design table)
--============================================================================

local function referenceCenter(design: CraftDesign.Design): Vector3
	local reference = CraftDesign.rootBlock(design)
	if reference == nil then
		for _, block in design.blocks do
			if reference == nil or block.id < (reference :: CraftDesign.Block).id then
				reference = block
			end
		end
	end
	return if reference then CraftDesign.blockCenter(reference) * CraftDesign.GRID else Vector3.zero
end

local function designInfo(design: CraftDesign.Design): DesignInfo
	local cached = designCache[design]
	if cached and cached.count == #design.blocks then
		return cached
	end
	local grid = CraftDesign.GRID
	local origin = referenceCenter(design)
	local engines: { [number]: EngineInfo } = {}
	local blocks: { [number]: BlockInfo } = {}
	for _, block in design.blocks do
		local def = Parts.get(block.type)
		blocks[block.id] = {
			pos = CraftDesign.blockCenter(block) * grid - origin,
			size = CraftDesign.blockSize(block) * grid,
		}
		local engine = def.Engine
		if engine then
			local blockCFrame = CFrame.new(-origin) * CraftDesign.blockCFrame(block)
			local size = def.Size * grid
			engines[block.id] = {
				exhaust = blockCFrame:PointToWorldSpace(Vector3.new(0, -size.Y / 2, 0)),
				direction = -blockCFrame.UpVector,
				diameter = math.max(math.min(size.X, size.Z), 0.5),
				thrust = engine.ThrustVac,
				solid = not engine.Throttleable,
			}
		end
	end
	local center, half = Vector3.zero, Vector3.one * grid / 2
	if #design.blocks > 0 then
		local minV, maxV = CraftDesign.bounds(design)
		local lo, hi = minV * grid - origin, maxV * grid - origin
		center, half = (lo + hi) / 2, (hi - lo) / 2
	end
	local info: DesignInfo =
		{ count = #design.blocks, center = center, half = half, engines = engines, blocks = blocks }
	designCache[design] = info
	return info
end

--============================================================================
-- Pools: continuous per-craft slots
--============================================================================

local function takeTrail(): TrailSlot?
	local slot = table.remove(freeTrails)
	if slot then
		return slot
	end
	if trailCount >= MAX_TRAILS then
		return nil
	end
	trailCount += 1
	local part = carrierPart("Trail")
	local attachment = newAttachment(part, "Emit")
	local emitter = newEmitter(attachment, "Smoke", TRAIL_TEXTURE)
	emitter.Color = TRAIL_COLOR
	emitter.LightEmission = 0.05
	emitter.LightInfluence = 1
	emitter.ZOffset = -1
	emitter.RotSpeed = NumberRange.new(-15, 15)
	return { part = part, attachment = attachment, emitter = emitter, size = -1, transparency = -1, lifetime = -1 }
end

local function releaseTrail(slot: TrailSlot)
	slot.emitter.Rate = 0 -- live puffs fade out where they are
	table.insert(freeTrails, slot)
end

local function takeDust(): DustSlot?
	local slot = table.remove(freeDust)
	if slot then
		return slot
	end
	if dustCount >= MAX_DUST then
		return nil
	end
	dustCount += 1
	local part = carrierPart("Dust")
	local attachments: { Attachment } = {}
	local emitters: { ParticleEmitter } = {}
	for index = 1, DUST_EMITTERS do
		local attachment = newAttachment(part, "Ring" .. index)
		local emitter = newEmitter(attachment, "Dust", DUST_TEXTURE)
		emitter.LightEmission = 0
		emitter.LightInfluence = 1
		emitter.Lifetime = DUST_LIFETIME
		emitter.Transparency = fadeSequence(0.35)
		emitter.RotSpeed = NumberRange.new(-25, 25)
		table.insert(attachments, attachment)
		table.insert(emitters, emitter)
	end
	return { part = part, attachments = attachments, emitters = emitters, size = -1, color = Color3.new() }
end

local function releaseDust(slot: DustSlot)
	for _, emitter in slot.emitters do
		emitter.Rate = 0
	end
	table.insert(freeDust, slot)
end

local function newBeam(parent: Instance, name: string, a0: Attachment, a1: Attachment, color: ColorSequence): Beam
	local beam = Instance.new("Beam")
	beam.Name = name
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.FaceCamera = true
	beam.Segments = 10
	beam.Color = color
	beam.Enabled = false
	beam.Parent = parent
	return beam
end

local function takeAero(): AeroSlot?
	local slot = table.remove(freeAero)
	if slot then
		return slot
	end
	if aeroCount >= MAX_AERO then
		return nil
	end
	aeroCount += 1
	local part = carrierPart("Aero")
	local lead = newAttachment(part, "Lead")
	local tail = newAttachment(part, "Tail")
	local vaporStart = newAttachment(part, "VaporStart")
	local vaporEnd = newAttachment(part, "VaporEnd")

	local cap = newEmitter(lead, "Glow", FIRE_TEXTURE)
	cap.LockedToPart = true
	cap.Color = HEAT_COLOR
	cap.LightEmission = 1
	cap.LightInfluence = 0
	cap.Lifetime = NumberRange.new(0.12, 0.2)
	cap.Speed = NumberRange.new(0, 3)
	cap.SpreadAngle = Vector2.new(40, 40)
	cap.Transparency = fadeSequence(0.2)
	cap.RotSpeed = NumberRange.new(-200, 200)

	-- emitted from the carrier part's volume (a slab across the leading side), streaming backward (+Y)
	local streaks = newEmitter(part, "Streaks", FIRE_TEXTURE)
	streaks.LockedToPart = true
	streaks.Color = HEAT_COLOR
	streaks.LightEmission = 1
	streaks.LightInfluence = 0
	streaks.Lifetime = NumberRange.new(HEAT_STREAK_LIFETIME * 0.7, HEAT_STREAK_LIFETIME)
	streaks.SpreadAngle = Vector2.new(6, 6)
	streaks.Orientation = Enum.ParticleOrientation.VelocityParallel
	streaks.Squash = NumberSequence.new(HEAT_STREAK_SQUASH)
	streaks.Transparency = fadeSequence(0.25)
	streaks.Rotation = NumberRange.new(0, 0)
	streaks.RotSpeed = NumberRange.new(0, 0)

	local inner = newBeam(part, "Plasma", lead, tail, HEAT_COLOR)
	inner.LightEmission = 1
	inner.LightInfluence = 0
	inner.Brightness = 2
	local outer = newBeam(part, "PlasmaGlow", lead, tail, HEAT_COLOR)
	outer.LightEmission = 1
	outer.LightInfluence = 0
	outer.Brightness = 1
	local vapor = newBeam(part, "Vapor", vaporStart, vaporEnd, VAPOR_COLOR)
	vapor.LightEmission = 0.2
	vapor.LightInfluence = 1

	local light = Instance.new("PointLight")
	light.Name = "HeatLight"
	light.Color = HEAT_LIGHT_COLOR
	light.Shadows = false
	light.Enabled = false
	light.Parent = part

	return {
		part = part,
		lead = lead,
		tail = tail,
		vaporStart = vaporStart,
		vaporEnd = vaporEnd,
		cap = cap,
		streaks = streaks,
		inner = inner,
		outer = outer,
		vapor = vapor,
		light = light,
		heatLevel = -1,
		heatRadius = -1,
		heatLength = -1,
		vaporLevel = -1,
	}
end

local function releaseAero(slot: AeroSlot)
	slot.cap.Rate = 0
	slot.streaks.Rate = 0
	slot.inner.Enabled = false
	slot.outer.Enabled = false
	slot.vapor.Enabled = false
	slot.light.Enabled = false
	slot.heatLevel = -1
	slot.heatRadius = -1
	slot.heatLength = -1
	slot.vaporLevel = -1
	slot.part.CFrame = PARK_CFRAME
	table.insert(freeAero, slot)
end

local function releaseSlots(record: CraftRecord)
	if record.trail then
		releaseTrail(record.trail :: TrailSlot)
		record.trail = nil
	end
	if record.dust then
		releaseDust(record.dust :: DustSlot)
		record.dust = nil
	end
	if record.aero then
		releaseAero(record.aero :: AeroSlot)
		record.aero = nil
	end
end

--============================================================================
-- Pools: one-shot bursts, fireballs and debris bits
--============================================================================

local function takeBurst(): Burst
	if #bursts < BURST_POOL then
		local part = carrierPart("Burst")
		local smokeAttachment = newAttachment(part, "Smoke")
		local fireAttachment = newAttachment(part, "Fire")
		local sparkAttachment = newAttachment(part, "Sparks")
		local smoke = newEmitter(smokeAttachment, "Smoke", SMOKE_TEXTURE)
		smoke.Enabled = false
		smoke.LightInfluence = 1
		smoke.LightEmission = 0.05
		local fire = newEmitter(fireAttachment, "Fire", FIRE_TEXTURE)
		fire.Enabled = false
		fire.Color = BURST_FIRE_COLOR
		fire.LightEmission = 1
		fire.LightInfluence = 0
		fire.Transparency = fadeSequence(0.1)
		fire.RotSpeed = NumberRange.new(-120, 120)
		local sparks = newEmitter(sparkAttachment, "Sparks", SPARK_TEXTURE)
		sparks.Enabled = false
		sparks.Color = BURST_SPARK_COLOR
		sparks.LightEmission = 1
		sparks.LightInfluence = 0
		sparks.Transparency = fadeSequence(0)
		sparks.Orientation = Enum.ParticleOrientation.VelocityParallel
		sparks.Squash = NumberSequence.new(1.2)
		local light = Instance.new("PointLight")
		light.Name = "Flash"
		light.Color = BURST_LIGHT_COLOR
		light.Shadows = false
		light.Enabled = false
		light.Parent = part
		local burst: Burst = {
			part = part,
			smokeAttachment = smokeAttachment,
			fireAttachment = fireAttachment,
			sparkAttachment = sparkAttachment,
			smoke = smoke,
			fire = fire,
			sparks = sparks,
			light = light,
			lightPeak = 0,
			lightDuration = 0,
			age = math.huge,
			buoyancy = Vector3.zero,
		}
		table.insert(bursts, burst)
		return burst
	end
	-- round robin: the oldest burst is reused (its particles are long gone by then in all but extreme cases)
	local burst = bursts[nextBurst]
	nextBurst = nextBurst % BURST_POOL + 1
	return burst
end

local function spawnBurst(position: Vector3, drift: Vector3, inAir: boolean, spec: BurstSpec)
	local burst = takeBurst()
	burst.part.CFrame = CFrame.new(position)
	burst.age = 0
	burst.buoyancy = if inAir then smokeUp * SMOKE_BUOYANCY else Vector3.zero
	local accel = -frameAccel
	local smokeCount = scaledCount(spec.smoke)
	if smokeCount > 0 then
		local smoke = burst.smoke
		aim(burst.smokeAttachment, smoke, position, drift + spec.smokeVelocity, spec.smokeRandom)
		smoke.Size = sizeSequence(spec.smokeSize0, spec.smokeSize1)
		smoke.Lifetime = spec.smokeLife
		smoke.Color = spec.smokeColor
		smoke.Transparency = fadeSequence(spec.smokeTransparency)
		smoke.Acceleration = accel + burst.buoyancy
		smoke:Emit(smokeCount)
	end
	local fireCount = scaledCount(spec.fire)
	if fireCount > 0 then
		local fire = burst.fire
		aim(burst.fireAttachment, fire, position, drift, spec.fireRandom)
		fire.Size = sizeSequence(spec.fireSize0, spec.fireSize1)
		fire.Lifetime = spec.fireLife
		fire.Acceleration = accel + burst.buoyancy
		fire:Emit(fireCount)
	end
	local sparkCount = scaledCount(spec.sparks)
	if sparkCount > 0 then
		local sparks = burst.sparks
		aim(burst.sparkAttachment, sparks, position, drift + spec.sparkVelocity, spec.sparkRandom)
		sparks.Size = sizeSequence(spec.sparkSize, spec.sparkSize * 0.3)
		sparks.Lifetime = spec.sparkLife
		sparks.Acceleration = accel + gravityWs
		sparks:Emit(sparkCount)
	end
	burst.lightPeak = spec.light
	burst.lightDuration = spec.lightDuration
	if spec.light > 0 then
		burst.light.Range = math.min(spec.lightRange, 60)
		burst.light.Brightness = spec.light
		burst.light.Enabled = true
	end
end

local function newFireball(): Fireball
	local part = Instance.new("Part")
	part.Name = "Fireball"
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Transparency = 1
	part.CFrame = PARK_CFRAME
	part.Parent = getFolder()
	return { part = part, active = false, age = 0, duration = 1, size0 = 1, size1 = 1, velocity = Vector3.zero }
end

local function spawnFireball(position: Vector3, scale: number, drift: Vector3)
	local chosen: Fireball? = nil
	for _, fireball in fireballs do
		if not fireball.active then
			chosen = fireball
			break
		end
	end
	if chosen == nil then
		if #fireballs >= MAX_FIREBALLS then
			return
		end
		chosen = newFireball()
		table.insert(fireballs, chosen :: Fireball)
	end
	local fireball = chosen :: Fireball
	fireball.active = true
	fireball.age = 0
	fireball.duration = FIREBALL_TIME * math.sqrt(scale)
	fireball.size0 = FIREBALL_SIZE0 * scale
	fireball.size1 = FIREBALL_SIZE1 * scale
	fireball.velocity = drift
	fireball.part.Size = Vector3.one * fireball.size0
	fireball.part.Transparency = 0
	fireball.part.Color = Color3.fromRGB(255, 240, 180)
	fireball.part.CFrame = CFrame.new(position)
end

local function newBit(): Bit
	local part = Instance.new("Part")
	part.Name = "Debris"
	part.Material = Enum.Material.Neon
	part.Color = BIT_COLOR
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Transparency = 1
	part.Size = Vector3.one * BIT_SIZE
	part.CFrame = PARK_CFRAME
	local a0 = newAttachment(part, "TrailA")
	a0.Position = Vector3.new(0, 0.25, 0)
	local a1 = newAttachment(part, "TrailB")
	a1.Position = Vector3.new(0, -0.25, 0)
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.2
	trail.FaceCamera = true
	trail.LightEmission = 1
	trail.LightInfluence = 0
	trail.Color = BURST_SPARK_COLOR
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.Enabled = false
	trail.Parent = part
	part.Parent = getFolder()
	return {
		part = part,
		trail = trail,
		active = false,
		age = 0,
		life = 1,
		velocity = Vector3.zero,
		spin = Vector3.zero,
		size = BIT_SIZE,
	}
end

local function randomUnit(): Vector3
	local v = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
	return if v.Magnitude > 1e-3 then v.Unit else Vector3.yAxis
end

local function spawnBits(position: Vector3, scale: number, drift: Vector3, count: number)
	local root = math.sqrt(scale)
	for _ = 1, count do
		local chosen: Bit? = nil
		for _, bit in bits do
			if not bit.active then
				chosen = bit
				break
			end
		end
		if chosen == nil then
			if #bits >= MAX_BITS then
				return
			end
			chosen = newBit()
			table.insert(bits, chosen :: Bit)
		end
		local bit = chosen :: Bit
		bit.active = true
		bit.age = 0
		bit.life = rng:NextNumber(BIT_LIFETIME_MIN, BIT_LIFETIME_MAX)
		bit.velocity = drift + randomUnit() * rng:NextNumber(BIT_SPEED_MIN, BIT_SPEED_MAX) * root
		bit.spin = randomUnit() * rng:NextNumber(4, 12)
		bit.size = BIT_SIZE * root * rng:NextNumber(0.6, 1.4)
		bit.trail.Enabled = false
		bit.part.Size = Vector3.one * bit.size
		bit.part.Transparency = 0
		bit.part.CFrame = CFrame.new(position) * CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), 0)
		bit.trail:Clear()
		bit.trail.Enabled = true
	end
end

local function clearOneShots()
	for _, burst in bursts do
		burst.smoke:Clear()
		burst.fire:Clear()
		burst.sparks:Clear()
		burst.light.Enabled = false
		burst.age = math.huge
	end
	for _, fireball in fireballs do
		fireball.active = false
		fireball.part.Transparency = 1
		fireball.part.CFrame = PARK_CFRAME
	end
	for _, bit in bits do
		bit.active = false
		bit.trail.Enabled = false
		bit.part.Transparency = 1
		bit.part.CFrame = PARK_CFRAME
	end
	for _, record in records do
		if record.trail then
			(record.trail :: TrailSlot).emitter:Clear()
		end
		if record.dust then
			for _, emitter in (record.dust :: DustSlot).emitters do
				emitter:Clear()
			end
		end
	end
	for _, slot in freeTrails do
		slot.emitter:Clear()
	end
	for _, slot in freeDust do
		for _, emitter in slot.emitters do
			emitter:Clear()
		end
	end
end

--============================================================================
-- Events (plume transitions, staging, destruction)
--============================================================================

local function plumeEvent(event: Plumes.PlumeEvent, drift: Vector3, pressure: number)
	local d = event.diameter
	local inAir = pressure > 0.001
	if event.kind == "Ignite" then
		spawnBurst(event.position + event.direction * d * 0.5, drift, inAir, {
			smoke = if pressure > 0.05 then 4 else 0,
			smokeVelocity = event.direction * 10,
			smokeRandom = 4,
			smokeSize0 = d * 0.8,
			smokeSize1 = d * 2.5,
			smokeLife = NumberRange.new(1, 1.6),
			smokeColor = BURST_SMOKE_COLOR,
			smokeTransparency = 0.45,
			fire = 0,
			fireRandom = 0,
			fireSize0 = 0,
			fireSize1 = 0,
			fireLife = NumberRange.new(0.2),
			sparks = 6,
			sparkVelocity = event.direction * 30,
			sparkRandom = 12,
			sparkSize = 0.35 * math.sqrt(d / 4),
			sparkLife = NumberRange.new(0.2, 0.45),
			light = 0,
			lightRange = 0,
			lightDuration = 0,
		})
	else
		local strength = 0.35 + 0.65 * math.sqrt(math.clamp(pressure, 0, 1))
		spawnBurst(event.position + event.direction * d * 0.6, drift, inAir, {
			smoke = 6 * strength,
			smokeVelocity = event.direction * 6,
			smokeRandom = 3,
			smokeSize0 = d,
			smokeSize1 = d * 3.2,
			smokeLife = NumberRange.new(1.2, 2.2),
			smokeColor = if event.solid then BURST_DARK_SMOKE_COLOR else BURST_SMOKE_COLOR,
			smokeTransparency = 1 - 0.55 * strength,
			fire = 0,
			fireRandom = 0,
			fireSize0 = 0,
			fireSize1 = 0,
			fireLife = NumberRange.new(0.2),
			sparks = 0,
			sparkVelocity = Vector3.zero,
			sparkRandom = 0,
			sparkSize = 0,
			sparkLife = NumberRange.new(0.2),
			light = 0,
			lightRange = 0,
			lightDuration = 0,
		})
	end
end

local function separation(position: Vector3, size: Vector3, outward: Vector3, drift: Vector3, inAir: boolean)
	local s = math.max(size.Magnitude / 3, 1)
	spawnBurst(position, drift, inAir, {
		smoke = SEPARATION_SMOKE,
		smokeVelocity = outward * 4,
		smokeRandom = 10,
		smokeSize0 = s * 1.2,
		smokeSize1 = s * 4,
		smokeLife = NumberRange.new(0.8, 1.6),
		smokeColor = BURST_SMOKE_COLOR,
		smokeTransparency = 0.2,
		fire = 0,
		fireRandom = 0,
		fireSize0 = 0,
		fireSize1 = 0,
		fireLife = NumberRange.new(0.2),
		sparks = SEPARATION_SPARKS,
		sparkVelocity = outward * 20,
		sparkRandom = 25,
		sparkSize = 0.4,
		sparkLife = NumberRange.new(0.25, 0.5),
		light = SEPARATION_LIGHT,
		lightRange = 6 * s,
		lightDuration = 0.25,
	})
end

local function explosion(position: Vector3, size: Vector3, drift: Vector3, inAir: boolean)
	if explosionBudget < 1 then
		return
	end
	explosionBudget -= 1
	local k = EffectsMath.explosionScale(size)
	local root = math.sqrt(k)
	spawnBurst(position, drift, inAir, {
		smoke = 10 * root,
		smokeVelocity = Vector3.zero,
		smokeRandom = 12 * root,
		smokeSize0 = 3 * k,
		smokeSize1 = 10 * k,
		smokeLife = NumberRange.new(1.5, 3),
		smokeColor = BURST_DARK_SMOKE_COLOR,
		smokeTransparency = 0.15,
		fire = 12 * root,
		fireRandom = 18 * root,
		fireSize0 = 2.5 * k,
		fireSize1 = 6 * k,
		fireLife = NumberRange.new(0.35, 0.8),
		sparks = 12,
		sparkVelocity = Vector3.zero,
		sparkRandom = 45 * root,
		sparkSize = 0.5 * root,
		sparkLife = NumberRange.new(0.3, 0.8),
		light = EXPLOSION_LIGHT,
		lightRange = 18 * k,
		lightDuration = EXPLOSION_LIGHT_TIME,
	})
	spawnFireball(position, k, drift)
	spawnBits(position, k, drift, scaledCount(BITS_PER_EXPLOSION))
	if CLASSIC_EXPLOSION and quality >= CLASSIC_MIN_QUALITY and drift.Magnitude < CLASSIC_MAX_DRIFT then
		local classic = Instance.new("Explosion")
		classic.Position = position
		classic.BlastRadius = 4 * k
		classic.BlastPressure = 0
		classic.DestroyJointRadiusPercent = 0
		classic.ExplosionType = Enum.ExplosionType.NoCraters
		classic.Visible = true
		classic.Parent = getFolder()
		task.delay(CLASSIC_CLEANUP_S, function()
			classic:Destroy()
		end)
	end
end

--============================================================================
-- Per-craft continuous effects
--============================================================================

local function updateTrail(
	record: CraftRecord,
	point: Vector3,
	width: number,
	strength: number,
	solidShare: number,
	airSpeed: number
)
	local slot = record.trail
	if slot == nil then
		slot = takeTrail()
		record.trail = slot
	end
	if slot == nil then
		return
	end
	local trail = slot :: TrailSlot
	local emitter = trail.emitter
	local rate = TRAIL_RATE_MAX * strength * quality
	trail.part.CFrame = CFrame.new(point)
	aim(trail.attachment, emitter, point, record.drift, TRAIL_RANDOM_SPEED)
	emitter.Rate = rate
	emitter.Acceleration = -frameAccel + smokeUp * SMOKE_BUOYANCY * 0.3
	local size = EffectsMath.trailSize(airSpeed, rate, width)
	if math.abs(size - trail.size) > 0.1 * trail.size then
		trail.size = size
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, size * 0.6),
			NumberSequenceKeypoint.new(0.15, size),
			NumberSequenceKeypoint.new(1, size * TRAIL_GROWTH),
		})
	end
	local transparency = TRAIL_TRANSPARENCY_LIQUID + (TRAIL_TRANSPARENCY_SOLID - TRAIL_TRANSPARENCY_LIQUID) * solidShare
	transparency = 1 - (1 - transparency) * math.sqrt(strength)
	if math.abs(transparency - trail.transparency) > 0.04 then
		trail.transparency = transparency
		emitter.Transparency = fadeSequence(transparency)
	end
	local lifetime = EffectsMath.trailLifetime(airSpeed)
	if math.abs(lifetime - trail.lifetime) > 0.1 * trail.lifetime then
		trail.lifetime = lifetime
		emitter.Lifetime = NumberRange.new(lifetime * 0.8, lifetime)
	end
end

local function dustColorFor(bodyId: number, up: Vec3d): Color3
	local r, g, b, kind = Biome.sample(bodyId, up.x, up.y, up.z)
	if kind == "Ocean" then
		return DUST_WATER_COLOR
	end
	return Color3.new(r, g, b):Lerp(DUST_SMOKE_COLOR, 1 - DUST_GROUND_MIX)
end

local function updateDust(
	record: CraftRecord,
	ground: Vector3,
	upWs: Vector3,
	strength: number,
	diameter: number,
	color: Color3
)
	local slot = record.dust
	if slot == nil then
		slot = takeDust()
		record.dust = slot
	end
	if slot == nil then
		return
	end
	local dust = slot :: DustSlot
	local frame = EffectsMath.frameWithUp(ground, upWs)
	dust.part.CFrame = frame
	local spread = math.sqrt(math.max(diameter, 1) / 4)
	local size = DUST_SIZE * (0.6 + 0.4 * strength) * spread
	local resize = math.abs(size - dust.size) > 0.1 * dust.size
	if resize then
		dust.size = size
	end
	local recolor = color ~= dust.color
	dust.color = color
	local driftSpeed = record.drift.Magnitude
	local drag = DUST_DRAG * (1 - math.clamp(driftSpeed / DUST_DRAG_FADE_SPEED, 0, 1))
	local rate = DUST_RATE_MAX / DUST_EMITTERS * strength * quality
	local outSpeed = DUST_OUT_SPEED * (0.5 + 0.5 * strength)
	for index, emitter in dust.emitters do
		local angle = (index - 1) * (2 * math.pi / DUST_EMITTERS)
		local outward = frame:VectorToWorldSpace(Vector3.new(math.cos(angle), 0, math.sin(angle)))
		local origin = ground + outward * (diameter * 0.5) + upWs * 0.6
		aim(
			dust.attachments[index],
			emitter,
			origin,
			outward * outSpeed + upWs * DUST_RISE_SPEED + record.drift,
			DUST_RANDOM_SPEED
		)
		emitter.Rate = rate
		emitter.Drag = drag
		emitter.Acceleration = -frameAccel
		if resize then
			emitter.Size = sizeSequence(size, size * DUST_GROWTH)
		end
		if recolor then
			emitter.Color = ColorSequence.new(color, color:Lerp(DUST_SMOKE_COLOR, 0.4))
		end
	end
end

local function heatSequence(base: number, level: number): NumberSequence
	-- level 0..1: the whole beam fades in with the heat
	local alpha = 1 - level
	local function t(x: number): number
		return math.clamp(x + (1 - x) * alpha, 0, 1)
	end
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, t(base + 0.1)),
		NumberSequenceKeypoint.new(0.15, t(base)),
		NumberSequenceKeypoint.new(0.6, t(base + 0.35)),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local function updateAero(
	record: CraftRecord,
	velocityWs: Vector3,
	craftCFrame: CFrame,
	info: DesignInfo,
	heat: number,
	vapor: number
)
	local slot = record.aero
	if slot == nil then
		slot = takeAero()
		record.aero = slot
	end
	if slot == nil then
		return
	end
	local aero = slot :: AeroSlot
	local forward = velocityWs.Unit
	local reach, radius = EffectsMath.leadingExtent(info.half, craftCFrame:VectorToObjectSpace(forward))
	local center = craftCFrame:PointToWorldSpace(info.center)
	local leadPoint = center + forward * reach
	-- the carrier's +Y points backward (down the air flow); it is a slab across the leading side
	aero.part.CFrame = EffectsMath.frameWithUp(leadPoint, -forward)
	local slab = Vector3.new(radius * 2, 0.4, radius * 2)
	if (aero.part.Size - slab).Magnitude > 0.1 * radius then
		aero.part.Size = slab
	end
	local length = 2 * reach + radius * (1.5 + 2.5 * heat)

	if heat > AERO_MIN then
		local wobble = 1 + rng:NextNumber(-HEAT_FLICKER, HEAT_FLICKER)
		aero.lead.Position = Vector3.new(0, -radius * 0.25, 0)
		aero.tail.Position = Vector3.new(0, length, 0)
		aero.inner.Width0 = radius * 2.3 * wobble
		aero.inner.Width1 = radius * 1.1
		aero.outer.Width0 = radius * 3.2 * wobble
		aero.outer.Width1 = radius * 2.2
		local level = math.ceil(heat / HEAT_QUANTUM) * HEAT_QUANTUM
		local resized = math.abs(radius - aero.heatRadius) > 0.05 * aero.heatRadius
		if level ~= aero.heatLevel then
			aero.inner.Transparency = heatSequence(0.2, level)
			aero.outer.Transparency = heatSequence(0.55, level)
		end
		-- sequences and ranges are only rebuilt when the heat step or the size moved (not every frame)
		if level ~= aero.heatLevel or resized then
			aero.heatRadius = radius
			aero.cap.Size = sizeSequence(radius * 2.4 * (0.7 + 0.3 * level), radius * 1.6)
			aero.streaks.Size = sizeSequence(math.max(radius * 0.35, 0.4), radius * 0.15)
		end
		aero.heatLevel = level
		if math.abs(length - aero.heatLength) > 0.05 * aero.heatLength then
			aero.heatLength = length
			aero.streaks.Speed = NumberRange.new(length / HEAT_STREAK_LIFETIME * 0.8, length / HEAT_STREAK_LIFETIME)
		end
		aero.inner.Enabled = true
		aero.outer.Enabled = true
		aero.cap.Rate = HEAT_CAP_RATE * heat * quality
		aero.streaks.Rate = HEAT_STREAK_RATE * heat * quality
		aero.light.Brightness = HEAT_LIGHT * heat
		aero.light.Range = math.min(radius * 6, 60)
		aero.light.Enabled = true
	else
		aero.inner.Enabled = false
		aero.outer.Enabled = false
		aero.cap.Rate = 0
		aero.streaks.Rate = 0
		aero.light.Enabled = false
		aero.heatLevel = -1
	end

	if vapor > AERO_MIN then
		local wobble = 1 + rng:NextNumber(-HEAT_FLICKER, HEAT_FLICKER) * 2
		aero.vaporStart.Position = Vector3.new(0, reach * 0.8, 0)
		aero.vaporEnd.Position = Vector3.new(0, reach * 0.8 + radius * 2.5, 0)
		aero.vapor.Width0 = radius * 2.3
		aero.vapor.Width1 = radius * 4.5 * wobble
		local level = math.ceil(vapor / HEAT_QUANTUM) * HEAT_QUANTUM
		if level ~= aero.vaporLevel then
			aero.vaporLevel = level
			local start = 1 - VAPOR_OPACITY * level
			aero.vapor.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, math.min(start + 0.25, 1)),
				NumberSequenceKeypoint.new(0.3, start),
				NumberSequenceKeypoint.new(1, 1),
			})
		end
		aero.vapor.Enabled = true
	else
		aero.vapor.Enabled = false
		aero.vaporLevel = -1
	end
end

local function processCraft(record: CraftRecord, report: CraftReport, ctx: RenderContext, frameVelocity: Vec3d)
	local s = report.state
	local frame = ctx.frame
	local model = report.model
	local previous = record.model
	if previous and previous ~= model then
		Plumes.clear(previous)
	end
	record.model = model
	local info = designInfo(report.design)

	-- Pose and air drift (doubles until the subtraction, invariant I1)
	local bodyOffset: Vec3d? = nil
	local drift = baseDrift
	if s.bodyId ~= frame.refBodyId then
		bodyOffset = Universe.bodyOffset(s.bodyId, frame.refBodyId, ctx.ut)
		local bodyVel = Universe.bodyVelocityOffset(s.bodyId, frame.refBodyId, ctx.ut)
		drift = Frames.vectorToWorkspace(frame, Vec3d.sub(bodyVel, frameVelocity))
	end
	local craftCFrame = report.craftCFrame or Frames.cframeToWorkspace(frame, s.pos, s.rot, bodyOffset)
	record.craftCFrame = craftCFrame
	record.drift = drift
	record.centerWs = craftCFrame:PointToWorldSpace(info.center)

	local body = Bodies.get(s.bodyId)
	local altitude = Vec3d.length(s.pos) - body.Radius
	local pressure = Atmosphere.pressureRatio(s.bodyId, altitude)
	local density = Atmosphere.density(s.bodyId, altitude)
	local airSpeed = Vec3d.length(s.vel)

	-- Plumes, and their ignition / cut-off transitions
	table.clear(eventScratch)
	if model.Parent ~= nil then
		Plumes.update(model, report.burning, pressure, ctx.dt, eventScratch)
	end
	for _, event in eventScratch do
		plumeEvent(event, drift, pressure)
	end

	-- Burning engines in workspace
	local nearGround = altitude < EffectsMath.DUST_MAX_HEIGHT + 2 * info.half.Magnitude + DUST_CHECK_MARGIN
	local height, up: Vec3d?, upWs = 0, nil, Vector3.yAxis
	if nearGround then
		local h, normal = SurfaceHeight.height(s.bodyId, s.pos)
		height, up = h, normal
		upWs = Frames.vectorToWorkspace(frame, normal).Unit
	end
	local thrust, solidThrust, sumDiameter, maxDiameter = 0, 0, 0, 0
	local meanPos, meanDir = Vector3.zero, Vector3.zero
	local dustThrust, dustPos, dustWeight, lowest = 0, Vector3.zero, 0, math.huge
	local origin = craftCFrame.Position
	for blockId, throttle in report.burning do
		local engine = info.engines[blockId]
		if engine == nil or throttle <= 0 then
			continue
		end
		local weight = engine.thrust * throttle
		local position = craftCFrame:PointToWorldSpace(engine.exhaust)
		local direction = craftCFrame:VectorToWorldSpace(engine.direction)
		thrust += weight
		if engine.solid then
			solidThrust += weight
		end
		sumDiameter += engine.diameter
		maxDiameter = math.max(maxDiameter, engine.diameter)
		meanPos += position * weight
		meanDir += direction * weight
		if up then
			local down = -direction:Dot(upWs)
			if down > DUST_DOWN_MIN then
				local nozzleHeight = height + (position - origin):Dot(upWs)
				lowest = math.min(lowest, nozzleHeight)
				dustThrust += weight * down
				dustPos += position * weight
				dustWeight += weight
			end
		end
	end

	-- Smoke trail
	local trailStrength = 0
	local solidShare = 0
	if thrust > 0 then
		meanPos /= thrust
		meanDir = if meanDir.Magnitude > 1e-6 then meanDir.Unit else -craftCFrame.UpVector
		solidShare = solidThrust / thrust
		trailStrength = EffectsMath.trailStrength(pressure)
			* (TRAIL_LIQUID_WEIGHT + (1 - TRAIL_LIQUID_WEIGHT) * solidShare)
	end
	if trailStrength > TRAIL_MIN_STRENGTH then
		local width = math.max(maxDiameter, sumDiameter * 0.6) * TRAIL_WIDTH_MULT
		local point = meanPos + meanDir * maxDiameter * TRAIL_OFFSET_DIAMETERS
		updateTrail(record, point, width, trailStrength, solidShare, airSpeed)
	elseif record.trail then
		releaseTrail(record.trail :: TrailSlot)
		record.trail = nil
	end

	-- Launch / landing dust
	local dustStrength = 0
	if up and dustWeight > 0 then
		dustStrength = EffectsMath.dustStrength(lowest, dustThrust / DUST_REFERENCE_THRUST)
	end
	if dustStrength > DUST_MIN_STRENGTH and up then
		record.dustColorTimer -= ctx.dt
		if record.dustColorTimer <= 0 then
			record.dustColorTimer = DUST_COLOR_INTERVAL
			record.dustColor = dustColorFor(s.bodyId, up :: Vec3d)
		end
		local nozzles = dustPos / dustWeight
		-- straight down from the nozzles onto the ground plane (SurfaceHeight's tile plane = the visible ground)
		local ground = nozzles - upWs * (height + (nozzles - origin):Dot(upWs))
		updateDust(record, ground, upWs, dustStrength, math.max(sumDiameter, maxDiameter), record.dustColor)
	elseif record.dust then
		releaseDust(record.dust :: DustSlot)
		record.dust = nil
	end

	-- Re-entry heating and the transonic vapour cone
	local heat = EffectsMath.heatFactor(density, airSpeed)
	local vapor = EffectsMath.vaporFactor(airSpeed, pressure)
	if (heat > AERO_MIN or vapor > AERO_MIN) and airSpeed > 1 then
		updateAero(record, Frames.vectorToWorkspace(frame, s.vel), craftCFrame, info, heat, vapor)
	elseif record.aero then
		releaseAero(record.aero :: AeroSlot)
		record.aero = nil
	end
end

-- A craft that was not reported recently: everything continuous goes out. Its plumes are destroyed (not just switched
-- off), so when it is drawn again (map view closed, copy LOD back) they come back without an ignition flash.
local function sweep(record: CraftRecord, now: number): boolean
	releaseSlots(record)
	record.report = nil
	record.localReport = nil
	record.streamReport = nil
	local model = record.model
	if model then
		Plumes.clear(model)
		record.model = nil
	end
	return now - record.reportTime > FORGET_AFTER_S
end

--============================================================================
-- One-shot updates
--============================================================================

local function updateOneShots(dt: number)
	stats.bursts = 0
	for _, burst in bursts do
		if burst.age < math.huge then
			burst.age += dt
			if burst.light.Enabled then
				local f = 1 - math.clamp(burst.age / math.max(burst.lightDuration, 1e-3), 0, 1)
				if f <= 0 then
					burst.light.Enabled = false
				else
					burst.light.Brightness = burst.lightPeak * f * f
				end
			end
			if burst.age < 4 then
				stats.bursts += 1
			end
		end
	end

	for _, fireball in fireballs do
		if fireball.active then
			fireball.age += dt
			local f = fireball.age / fireball.duration
			local part = fireball.part
			if f >= 1 then
				fireball.active = false
				part.Transparency = 1
				part.CFrame = PARK_CFRAME
			else
				local grow = EffectsMath.fade(fireball.age, fireball.duration)
				part.Size = Vector3.one * (fireball.size0 + (fireball.size1 - fireball.size0) * grow)
				part.Transparency = f ^ 1.5
				part.Color = if f < 0.4
					then Color3.fromRGB(255, 240, 180):Lerp(Color3.fromRGB(255, 120, 30), f / 0.4)
					else Color3.fromRGB(255, 120, 30):Lerp(Color3.fromRGB(120, 30, 10), (f - 0.4) / 0.6)
				part.CFrame = part.CFrame + (fireball.velocity - frameAccel * fireball.age) * dt
			end
		end
	end

	table.clear(bitParts)
	table.clear(bitCFrames)
	local bitAccel = gravityWs - frameAccel
	for _, bit in bits do
		if bit.active then
			bit.age += dt
			local part = bit.part
			if bit.age >= bit.life then
				bit.active = false
				bit.trail.Enabled = false
				part.Transparency = 1
				part.CFrame = PARK_CFRAME
			else
				bit.velocity += bitAccel * dt
				local f = bit.age / bit.life
				part.Transparency = f * f
				local spin = bit.spin * dt
				table.insert(bitParts, part)
				table.insert(bitCFrames, (part.CFrame + bit.velocity * dt) * CFrame.Angles(spin.X, spin.Y, spin.Z))
			end
		end
	end
	if #bitParts > 0 then
		workspace:BulkMoveTo(bitParts, bitCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Every live burst gets -a_frame (plus its own buoyancy / gravity) whenever the estimate moved (trails and dust
-- are rewritten every frame by their own updates).
local function writeAccelerations()
	if (frameAccel - writtenAccel).Magnitude < ACCEL_WRITE_EPSILON then
		return
	end
	writtenAccel = frameAccel
	local accel = -frameAccel
	for _, burst in bursts do
		if burst.age < 4 then
			burst.smoke.Acceleration = accel + burst.buoyancy
			burst.fire.Acceleration = accel + burst.buoyancy
			burst.sparks.Acceleration = accel + gravityWs
		end
	end
end

--============================================================================
-- API
--============================================================================

-- Creates the Effects folder under the client universe root.
function Effects.init(parent: Instance)
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = parent
	folder = created
end

-- The folder (UniverseRenderer hides it in map view).
function Effects.folder(): Folder
	return getFolder()
end

-- Reports a craft drawn this frame. Call every frame while it is drawn.
function Effects.reportCraft(craftId: number, report: CraftReport)
	local record = records[craftId]
	if record == nil then
		record = {
			id = craftId,
			source = report.source,
			report = nil,
			processedFrame = -math.huge,
			localReport = nil,
			localFrame = -math.huge,
			streamReport = nil,
			streamFrame = -math.huge,
			reportTime = 0,
			model = nil,
			craftCFrame = CFrame.identity,
			drift = Vector3.zero,
			centerWs = Vector3.zero,
			trail = nil,
			dust = nil,
			aero = nil,
			dustColor = DUST_SMOKE_COLOR,
			dustColorTimer = 0,
		}
		records[craftId] = record
	end
	local r = record :: CraftRecord
	-- both are kept: step() prefers a recent local report (the pilot's own simulation), and a hand-over to the
	-- stream (the pilot left the seat) continues without a gap
	if report.source == "Local" then
		r.localReport = report
		r.localFrame = frameCounter
	else
		r.streamReport = report
		r.streamFrame = frameCounter
	end
	r.reportTime = os.clock()
end

--[[
	Blocks of a drawn craft separated ("Separate": decouplers that fired) or were destroyed ("Explode"). Call BEFORE
	the blocks are removed from `design` (their positions come from it). Ignored for crafts not drawn recently
	(hidden), for a source that is not the one drawing the craft (the pilot predicts its own events; the server's
	echo is ignored) and for blocks already shown within DEDUPE_S.
]]
function Effects.blockEvent(
	craftId: number,
	kind: "Separate" | "Explode",
	design: CraftDesign.Design,
	blockIds: { number },
	source: Source
)
	local record = records[craftId]
	if record == nil or record.processedFrame < frameCounter - STALE_FRAMES or record.source ~= source then
		return
	end
	local info = designInfo(design)
	local candidates: { BlockInfo } = {}
	for _, id in blockIds do
		local block = info.blocks[id]
		if block and firstTime(`{craftId}:{kind}:{id}`) then
			table.insert(candidates, block)
		end
	end
	if #candidates == 0 then
		return
	end
	local inAir = smokeUp ~= Vector3.zero
	local report = record.report
	if report then
		local state = report.state
		local altitude = Vec3d.length(state.pos) - Bodies.get(state.bodyId).Radius
		inAir = Atmosphere.pressureRatio(state.bodyId, altitude) > 0.001
	end
	local craftCFrame = record.craftCFrame
	if kind == "Separate" then
		for _, block in candidates do
			local position = craftCFrame:PointToWorldSpace(block.pos)
			local away = position - record.centerWs
			local outward = if away.Magnitude > 1e-3 then away.Unit else -craftCFrame.UpVector
			separation(position, block.size, outward, record.drift, inAir)
		end
	else
		table.sort(candidates, function(a, b)
			return a.size.Magnitude > b.size.Magnitude
		end)
		for index, block in candidates do
			if index > EXPLOSIONS_PER_EVENT then
				break
			end
			explosion(craftCFrame:PointToWorldSpace(block.pos), block.size, record.drift, inAir)
		end
	end
end

--[[
	Once per frame (UniverseRenderer, after the pocket frame and the copies): turns this frame's reports into
	effects and ages the one-shots. frameVelocity = the pocket reference's velocity relative to frame.refBodyId
	(universe axes, PocketController.frameVelocity).
]]
function Effects.step(ctx: RenderContext, frameVelocity: Vec3d)
	frameCounter += 1
	local dt = math.max(ctx.dt, 1e-4)
	local now = os.clock()
	local frame = ctx.frame

	qualityTimer += dt
	if qualityTimer >= QUALITY_POLL_S then
		qualityTimer = 0
		quality = EffectsMath.qualityScale(userGameSettings.SavedQualityLevel.Value)
	end
	explosionBudget = math.min(explosionBudget + EXPLOSIONS_PER_SECOND * dt, EXPLOSION_BUDGET)

	-- Pocket motion: a pocket switch or rebase invalidates every particle position
	local velWs = Frames.vectorToWorkspace(frame, frameVelocity)
	local previousVel = lastFrameVel
	if ctx.pocketId ~= lastPocketId or frame.frameEpoch ~= lastEpoch then
		if lastPocketId ~= -1 then
			clearOneShots()
		end
		lastPocketId = ctx.pocketId
		lastEpoch = frame.frameEpoch
		frameAccel = Vector3.zero
	elseif previousVel then
		local dv = velWs - previousVel
		if dv.Magnitude > ACCEL_RESET_DV then
			frameAccel = Vector3.zero
		else
			local alpha = 1 - math.exp(-dt / ACCEL_SMOOTH_S)
			frameAccel = frameAccel:Lerp(dv / dt, alpha)
			if frameAccel.Magnitude > ACCEL_MAX then
				frameAccel = frameAccel.Unit * ACCEL_MAX
			end
		end
	end
	lastFrameVel = velWs
	baseDrift = -velWs
	local refR = Vec3d.length(frame.refPos)
	if refR > 1 then
		local body = Bodies.get(frame.refBodyId)
		local downWs = Frames.vectorToWorkspace(frame, Vec3d.scale(frame.refPos, -1 / refR))
		gravityWs = downWs * (body.Mu / (refR * refR))
		local altitude = refR - body.Radius
		smokeUp = if Atmosphere.isInside(frame.refBodyId, altitude) then -downWs else Vector3.zero
	else
		gravityWs, smokeUp = Vector3.zero, Vector3.zero
	end

	-- Continuous per-craft effects
	stats.crafts, stats.trails, stats.dust, stats.aero = 0, 0, 0, 0
	local recent = frameCounter - STALE_FRAMES
	for id, record in records do
		local report: CraftReport? = nil
		if record.localReport and record.localFrame >= recent then
			report = record.localReport
		elseif record.streamReport and record.streamFrame >= recent then
			report = record.streamReport
		end
		if report then
			record.report = report
			record.source = report.source
			record.processedFrame = frameCounter
			processCraft(record, report, ctx, frameVelocity)
			stats.crafts += 1
			stats.trails += if record.trail then 1 else 0
			stats.dust += if record.dust then 1 else 0
			stats.aero += if record.aero then 1 else 0
		else
			if sweep(record, now) then
				records[id] = nil
			end
		end
	end

	updateOneShots(dt)
	writeAccelerations()

	dedupeTimer += dt
	if dedupeTimer >= 1 then
		dedupeTimer = 0
		for key, seen in dedupe do
			if now - seen > DEDUPE_S then
				dedupe[key] = nil
			end
		end
	end
end

-- F3 line.
function Effects.summary(): string
	local active = 0
	for _, fireball in fireballs do
		if fireball.active then
			active += 1
		end
	end
	local flying = 0
	for _, bit in bits do
		if bit.active then
			flying += 1
		end
	end
	return string.format(
		"Effects: %d crafts  %d flames  %d trails  %d dust  %d heat  bursts %d/%d  fireballs %d  debris %d  quality x%.2f",
		stats.crafts,
		Plumes.litCount(),
		stats.trails,
		stats.dust,
		stats.aero,
		stats.bursts,
		BURST_POOL,
		active,
		flying,
		quality
	)
end

return table.freeze(Effects)
