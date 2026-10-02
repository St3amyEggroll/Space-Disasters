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
	(CHANGED (Effects v2): caps per Render/Quality tier, EffectsMath.budget; particle rates x Quality.scale()).

	No sounds yet: they need uploaded audio asset ids (follow-up).

	CHANGED (Effects v2): Steamy: "effects still look shitty. the plasma needs to look better ... this should all be
	working on mobile so please dont make it to intensive. and should go with graphics quality".
	  * One detail tier for everything: Render/Quality (Low / Medium / High; phones at most Medium). The caps per tier
	    are EffectsMath.budget(tier) (pool sizes, emitters per effect, lights) and every particle rate / burst count
	    is multiplied by Quality.scale(). Quality.onChanged re-applies the budget live: continuous slots are released
	    (and re-taken within the new caps on the next frame), pools above the new caps are destroyed, and Plumes is
	    reconfigured. PointLights only exist on High (never on phones).
	  * Re-entry plasma (EffectsMath.plasma / heatColor), along the craft's velocity relative to the air (s.vel, the
	    body-relative velocity, in pocket axes):
	      Low     a glowing shock-layer shell on the windward side (Neon ellipsoid) + glow puffs + 3 short flame
	              tongues (beams) streaming back along the airflow, flickering
	      Medium  + an outer, edge-tinted shell (pink / blue-violet at the hottest), 5 longer tongues, plasma streaks
	      High    + 8 tongues, embers peeling off into the airflow, a heat light, and the leading blocks glow
	              (Highlight fill) as they heat up and fade slowly after (EffectsMath.heatSoak)
	  * Loose smoke and debris keep the craft's momentum in vacuum and stop in thick air (EffectsMath.airCoupling).
	    Before, a separation puff in orbit flew off at the orbital speed and was never seen.
	  * Explosions: a main blast at the wreck's centre sized by the wrecked span and the blocks lost
	    (EffectsMath.blastScale): white-hot core fireball inside a slower orange-to-soot outer fireball, fire, dark
	    buoyant smoke, streaky sparks and glowing debris; then smaller blasts on the largest blocks.
	  * Separation: a pyro flash, a white puff and sparks. Smoke trail: warm where it leaves the flame, greyer for
	    boosters, column length per tier. Dust: emitters per ring per tier. Vapour cone: + a puffy collar (Medium+).
	  * F3 shows the tier.
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
local Quality = require(script.Parent.Quality) -- CHANGED (Effects v2): the one detail tier
local RenderContext = require(script.Parent.RenderContext)

--============================================================================
-- Tunables
--============================================================================
-- CHANGED (Effects v2): every count cap (trails, dust rings, heated crafts, burst / fireball / debris pools,
-- explosions per event, lights) is now per tier in EffectsMath's BUDGETS; QUALITY_POLL_S went with Render/Quality.
local FOLDER_NAME = "Effects"
local STALE_FRAMES = 2 -- a craft not reported for this many frames has its continuous effects released
local FORGET_AFTER_S = 10 -- records of crafts not reported for this long are dropped
local PARK_CFRAME = CFrame.new(0, -10000, 0) -- where idle carrier parts wait (far below every pocket)
local DEDUPE_S = 3 -- the same block's separation / explosion is not shown twice within this time
-- Pocket motion
local ACCEL_SMOOTH_S = 0.25 -- s time constant of the pocket acceleration estimate
local ACCEL_MAX = 60 -- m/s^2 clamp
local ACCEL_RESET_DV = 50 -- m/s velocity jump in one frame that counts as a discontinuity (resets the estimate)
local ACCEL_WRITE_EPSILON = 0.3 -- m/s^2 change before emitter accelerations are rewritten
local SMOKE_BUOYANCY = 2.5 -- m/s^2 upward drift of smoke and fire (only in air)
-- CHANGED (Effects v2): emitter speed / spread are only rewritten when they moved more than this (relative)
local AIM_EPSILON = 0.03
-- Smoke trail
local TRAIL_RATE_MAX = 55 -- puffs/s at full strength and quality
local TRAIL_RANDOM_SPEED = 3 -- m/s random spread of trail puffs
local TRAIL_WIDTH_MULT = 2.0 -- x nozzle diameter -- CHANGED (Physics feel): was 1.4; a fatter trail reads as speed
local TRAIL_OFFSET_DIAMETERS = 2.2 -- the trail starts this many nozzle diameters behind the nozzle (flame tip)
local TRAIL_GROWTH = 3.2 -- puffs grow to this x their start size
local TRAIL_LIQUID_WEIGHT = 0.75 -- liquid engines leave a thinner trail than solid boosters -- CHANGED (Physics feel): was 0.45; liquid trails were too faint to show speed
local TRAIL_TRANSPARENCY_SOLID = 0.2 -- CHANGED (Effects v2): was 0.25; boosters leave dense smoke
local TRAIL_TRANSPARENCY_LIQUID = 0.45 -- CHANGED (Physics feel): was 0.6; denser liquid-engine trail
local TRAIL_MIN_STRENGTH = 0.02
local TRAIL_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
-- CHANGED (Effects v2): warm where it leaves the flame, then white to grey; boosters' smoke is greyer
local TRAIL_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 222, 180)),
	ColorSequenceKeypoint.new(0.08, Color3.fromRGB(247, 244, 238)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(192, 192, 200)),
})
local TRAIL_COLOR_SOLID = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 205, 150)),
	ColorSequenceKeypoint.new(0.08, Color3.fromRGB(232, 228, 222)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(165, 162, 162)),
})
local TRAIL_SOLID_COLOR_SHARE = 0.5 -- solid share of the thrust above which the booster smoke colour is used
-- Launch / landing dust
local DUST_EMITTERS_MAX = 6 -- CHANGED (Effects v2): emitters built per ring; the tier uses Budget.dustEmitters
local DUST_RATE_MAX = 90 -- puffs/s for the whole ring at full strength and quality
-- CHANGED (Physics feel): x1.5 with every engine's thrust (was 200000), so launch dust looks the same per engine
local DUST_REFERENCE_THRUST = 300000 -- N; thrust fraction 1 (about one Solid Booster)
local DUST_OUT_SPEED = 38 -- m/s outward at full strength
local DUST_RISE_SPEED = 5 -- m/s upward
local DUST_RANDOM_SPEED = 9
local DUST_SIZE = 7 -- studs start size at full strength for a 4-stud nozzle
local DUST_GROWTH = 3 -- CHANGED (Effects v2): was 2.6; billows out more
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
local DUST_TRANSPARENCY = 0.3 -- CHANGED (Effects v2): was 0.35
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
-- Re-entry heating and the vapour cone
local AERO_MIN = 0.02
local HEAT_QUANTUM = 0.05 -- heat steps at which colour / transparency sequences are rebuilt
-- CHANGED (Effects v2): the plasma (sizes x the leading cross-section radius r; see EffectsMath.plasma)
local SHELL_SPAN = 2 -- inner shell width, x r
local SHELL_FORWARD = 0.2 -- inner shell centre, x its depth, upstream of the leading face
local GLOW_SHELL_SPAN = 2.6 -- outer shell width, x r
local GLOW_SHELL_DEPTH = 1.4 -- x the inner shell depth
local GLOW_SHELL_FORWARD = 0.45
local SHELL_FLICKER = 0.12 -- relative opacity flicker of the shells
local SHELL_RESIZE = 0.05 -- relative size change before the shells are resized
local CAP_RATE = 40 -- glow puffs/s on the shell at full heat
local CAP_LIFETIME = NumberRange.new(0.12, 0.22)
local CAP_SIZE0 = 1.1 -- x r
local CAP_SIZE1 = 0.5
local TONGUES_MAX = 8 -- beams built per heated craft (the tier enables Budget.tongues of them)
local TONGUE_ROOT_RADIUS = 0.85 -- x r, around the leading face
local TONGUE_ROOT_DOWNSTREAM = 0.15 -- x r, behind the leading face
local TONGUE_TIP_RADIUS = 0.55 -- x r, the flames close in behind the craft
local TONGUE_TIP_WIDTH = 0.1 -- x r
local TONGUE_LENGTH_JITTER = 0.25 -- each tongue's length flickers down by up to this fraction
local TONGUE_WIDTH_FLICKER = 0.15
local TONGUE_BRIGHTNESS = 1.6
local TONGUE_SEGMENTS = 6
local HEAT_STREAK_RATE = 70 -- streaks/s at full heat
local HEAT_STREAK_LIFETIME = 0.22 -- s
local HEAT_STREAK_SQUASH = 1.8 -- ParticleEmitter.Squash: streaks stretched along their motion
local EMBER_RATE = 35 -- embers/s at full heat
local EMBER_LIFETIME = NumberRange.new(0.35, 0.8)
local EMBER_SIZE = 0.35 -- studs x sqrt(r / 2)
local EMBER_SHED = 0.12 -- embers leave the craft this fraction of the air speed slower than it
local EMBER_PULL = 250 -- m/s^2 the air drags them back along the flow
local EMBER_RANDOM = 25 -- m/s
local EMBER_RIM = 0.9 -- x r, where embers peel off
local HEAT_LIGHT = 5
local HEAT_LIGHT_RANGE = 6 -- x r (capped at 60)
-- CHANGED (Effects v2): leading blocks' heat glow (High: Highlight fill on Block_<id> models)
local TINT_MAX = 0.65 -- fill opacity at full soak
local TINT_MIN = 0.03 -- soak below which the glow is released
local TINT_REFRESH_S = 0.3 -- s between choices of the leading blocks
local TINT_WEIGHTS = { 1, 0.8, 0.62, 0.48 } -- leading block first
local TINT_EPSILON = 0.02
local TINT_POOL_CRAFTS = 2 -- Highlights pooled = Budget.heatTint x this (Roblox draws at most 31 at once)
local VAPOR_COLOR = ColorSequence.new(Color3.fromRGB(255, 255, 255), Color3.fromRGB(235, 240, 248))
local VAPOR_OPACITY = 0.6 -- peak opacity of the vapour cone
local VAPOR_FLICKER = 0.14
-- CHANGED (Effects v2): vapour collar puffs (Medium+)
local COLLAR_RATE = 45
local COLLAR_SPEED = 20 -- m/s back along the craft
local COLLAR_LIFETIME = NumberRange.new(0.15, 0.3)
local COLLAR_OPACITY = 0.5
local FIRE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local SPARK_TEXTURE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
-- One-shot bursts (ignition, cut-off, separation, explosions)
local BURST_SMOKE_COLOR = ColorSequence.new(Color3.fromRGB(240, 238, 232), Color3.fromRGB(158, 156, 154))
local BURST_DARK_SMOKE_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 92, 70)), -- CHANGED (Effects v2): lit by the fire at first
	ColorSequenceKeypoint.new(0.25, Color3.fromRGB(70, 64, 60)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(42, 40, 40)),
})
local BURST_FIRE_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 210)),
	ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 180, 60)),
	ColorSequenceKeypoint.new(0.7, Color3.fromRGB(230, 80, 20)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(90, 30, 15)),
})
local BURST_SPARK_COLOR = ColorSequence.new(Color3.fromRGB(255, 240, 180), Color3.fromRGB(255, 120, 40))
local BURST_LIGHT_COLOR = Color3.fromRGB(255, 190, 120)
local BURST_ACTIVE_S = 4 -- a burst counts as live (accelerations rewritten, F3) this long
-- Stage separation
local SEPARATION_SMOKE = 14 -- CHANGED (Effects v2): was 10
local SEPARATION_SPARKS = 12 -- CHANGED (Effects v2): was 10
local SEPARATION_LIGHT = 5
local SEPARATION_FLASH_TIME = 0.15 -- CHANGED (Effects v2): pyro flash
-- Explosions
local EXPLOSIONS_PER_SECOND = 10 -- refill rate of the explosion budget
local EXPLOSION_BUDGET = 12 -- most explosions in one burst of events
local FIREBALL_TIME = 0.5 -- s for a 4-stud block (grows with sqrt of the scale)
local FIREBALL_SIZE0 = 2.5 -- studs x explosion scale
local FIREBALL_SIZE1 = 9
-- CHANGED (Effects v2): the outer fireball of a main blast: bigger, slower, fading to soot
local OUTER_FIREBALL_TIME = 1.6 -- x the core's duration
local OUTER_FIREBALL_SIZE = 1.5 -- x the core's sizes
local OUTER_FIREBALL_OPACITY = 0.6
local FLASH_OPACITY = 0.85
local BIT_SPEED_MIN = 15
local BIT_SPEED_MAX = 40
local BIT_LIFETIME_MIN = 0.8
local BIT_LIFETIME_MAX = 1.6
local BIT_SIZE = 0.7 -- studs x sqrt(scale)
local BIT_COLOR = Color3.fromRGB(255, 150, 60)
local BIT_AIR_COUPLING = 0.35 -- CHANGED (Effects v2): debris is heavy: it only partly follows the air at once
local EXPLOSION_LIGHT = 10
local EXPLOSION_LIGHT_TIME = 0.6
local MAIN_BLAST_MIN_BLOCKS = 2 -- CHANGED (Effects v2): events with at least this many blocks get a main blast
local CLASSIC_MAX_DRIFT = 30 -- m/s; not when the air streams past fast (the classic effect cannot move)
local CLASSIC_CLEANUP_S = 3
--============================================================================

type Vec3d = Vec3d.Vec3d
type RenderContext = RenderContext.RenderContext
type Budget = EffectsMath.Budget

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

type BlockInfo = { id: number, pos: Vector3, size: Vector3 } -- craft-local centre, studs

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
	solidColor: boolean, -- CHANGED (Effects v2): uses TRAIL_COLOR_SOLID
}

type DustSlot = {
	part: Part,
	attachments: { Attachment },
	emitters: { ParticleEmitter },
	size: number,
	color: Color3,
	active: number, -- CHANGED (Effects v2): emitters in use (Budget.dustEmitters when written)
}

-- CHANGED (Effects v2): one plasma flame tongue (a camera-facing beam from the leading rim back along the flow)
type Tongue = {
	root: Attachment,
	tip: Attachment,
	beam: Beam,
	angle: number,
	seed: number,
}

-- CHANGED (Effects v2): rebuilt for the new plasma (shells, tongues, embers, collar)
type AeroSlot = {
	part: Part, -- carrier: invisible slab across the leading side, +Y = downstream
	shell: Part, -- inner shock-layer ellipsoid
	glowShell: Part, -- outer, edge-tinted ellipsoid (Medium+)
	vaporStart: Attachment,
	vaporEnd: Attachment,
	ember: Attachment,
	collar: Attachment,
	cap: ParticleEmitter, -- glow puffs from the shell's volume
	streaks: ParticleEmitter, -- from the carrier's volume
	embers: ParticleEmitter,
	collarPuffs: ParticleEmitter,
	tongues: { Tongue },
	vapor: Beam,
	light: PointLight,
	heatLevel: number, -- quantised heat the colour / transparency sequences were built for (-1 = never)
	heatRadius: number, -- radius the sizes were built for
	heatLength: number, -- plasma length the streak speed was built for
	shellSize: Vector3, -- inner shell size last written
	tongueCount: number, -- tongues enabled
	vaporLevel: number,
	collarRadius: number,
}

-- CHANGED (Effects v2): a Highlight that makes one leading block glow
type TintSlot = {
	highlight: Highlight,
	blockId: number,
	weight: number,
	fill: number, -- FillTransparency written
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
	velocityWs: Vector3, -- CHANGED (Effects v2): the craft's own workspace velocity (drift + air-relative velocity)
	pressure: number, -- CHANGED (Effects v2): air pressure ratio at the craft
	centerWs: Vector3,
	trail: TrailSlot?,
	dust: DustSlot?,
	aero: AeroSlot?,
	dustColor: Color3,
	dustColorTimer: number,
	soak: number, -- CHANGED (Effects v2): 0..1 part heat glow (EffectsMath.heatSoak)
	tintForward: Vector3, -- CHANGED (Effects v2): craft-local flow direction the leading blocks were chosen for
	tintTimer: number,
	tintLevel: number, -- quantised soak the tint colour was written for
	tints: { TintSlot },
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

-- CHANGED (Effects v2): fireball palettes
type FireballKind = "Core" | "Outer" | "Flash"

type Fireball = {
	part: Part,
	active: boolean,
	kind: FireballKind,
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
local freeTints: { TintSlot } = {}
local trailCount, dustCount, aeroCount, tintCount = 0, 0, 0, 0 -- created so far (caps)
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
local rankScratch: { BlockInfo } = {}
local aimState: { [ParticleEmitter]: { number } } = setmetatable({}, { __mode = "k" }) :: any
local rng = Random.new()
local now = 0 -- os.clock() of the current step (flicker phase)

-- Pocket motion
local lastPocketId = -1
local lastEpoch = -1
local lastFrameVel: Vector3? = nil
local frameAccel = Vector3.zero -- pocket axes, m/s^2
local writtenAccel = Vector3.new(1e9, 0, 0)
local baseDrift = Vector3.zero -- air velocity in pocket axes for crafts on the frame's reference body
local gravityWs = Vector3.zero
local smokeUp = Vector3.yAxis -- unit "up" (against gravity) in pocket axes

-- Quality (CHANGED (Effects v2): one tier from Render/Quality, was EffectsMath.qualityScale polled here)
local tier: EffectsMath.Tier = "High"
local budget: Budget = EffectsMath.budget("High")
local quality = 1 -- Quality.scale(): particle rate / burst count multiplier
local tierApplied = false
local tierConnection: RBXScriptConnection? = nil
local heatLightsUsed = 0 -- this frame

-- Stats (F3)
local stats = { crafts = 0, trails = 0, dust = 0, aero = 0, bursts = 0, tints = 0 }

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

-- CHANGED (Effects v2): a glowing ellipsoid (Neon part + sphere SpecialMesh, which stretches to the part's Size).
local function ellipsoidPart(name: string): Part
	local part = carrierPart(name)
	part.Material = Enum.Material.Neon
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
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

local function moved(a: number, b: number): boolean
	return math.abs(a - b) > AIM_EPSILON * math.max(math.abs(b), 1)
end

-- Points an emitter (on its own attachment) so its particles move with `velocity` plus up to `randomSpeed`.
-- CHANGED (Effects v2): Speed / SpreadAngle are only rewritten when they moved (no NumberRange per emitter per frame).
local function aim(
	attachment: Attachment,
	emitter: ParticleEmitter,
	position: Vector3,
	velocity: Vector3,
	randomSpeed: number
)
	local direction, speedMin, speedMax, spread = EffectsMath.driftEmission(velocity, randomSpeed)
	attachment.WorldCFrame = EffectsMath.frameWithUp(position, direction)
	local last = aimState[emitter]
	if last == nil or moved(speedMin, last[1]) or moved(speedMax, last[2]) or math.abs(spread - last[3]) > 0.5 then
		aimState[emitter] = { speedMin, speedMax, spread }
		emitter.Speed = NumberRange.new(speedMin, speedMax)
		emitter.SpreadAngle = Vector2.new(spread, spread)
	end
end

local function scaledCount(count: number): number
	if count <= 0 then
		return 0
	end
	return math.max(math.round(count * quality), 1)
end

-- True the first time a key is seen within DEDUPE_S.
local function firstTime(key: string): boolean
	local seen = dedupe[key]
	local time = os.clock()
	if seen and time - seen < DEDUPE_S then
		return false
	end
	dedupe[key] = time
	return true
end

-- CHANGED (Effects v2): the velocity loose smoke / debris starts with: the craft's own in vacuum, the air's in
-- thick air.
local function looseVelocity(record: CraftRecord, coupling: number?): Vector3
	local k = coupling or EffectsMath.airCoupling(record.pressure)
	return record.velocityWs:Lerp(record.drift, k)
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
			id = block.id,
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
	if trailCount >= budget.trails then
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
	return {
		part = part,
		attachment = attachment,
		emitter = emitter,
		size = -1,
		transparency = -1,
		lifetime = -1,
		solidColor = false,
	}
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
	if dustCount >= budget.dust then
		return nil
	end
	dustCount += 1
	local part = carrierPart("Dust")
	local attachments: { Attachment } = {}
	local emitters: { ParticleEmitter } = {}
	for index = 1, DUST_EMITTERS_MAX do
		local attachment = newAttachment(part, "Ring" .. index)
		local emitter = newEmitter(attachment, "Dust", DUST_TEXTURE)
		emitter.LightEmission = 0
		emitter.LightInfluence = 1
		emitter.Lifetime = DUST_LIFETIME
		emitter.Transparency = fadeSequence(DUST_TRANSPARENCY)
		emitter.RotSpeed = NumberRange.new(-25, 25)
		table.insert(attachments, attachment)
		table.insert(emitters, emitter)
	end
	return {
		part = part,
		attachments = attachments,
		emitters = emitters,
		size = -1,
		color = Color3.new(),
		active = 0,
	}
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

-- CHANGED (Effects v2): tongues are built up to the tier's count (a higher tier later adds the missing ones).
local function ensureTongues(aero: AeroSlot, count: number)
	for index = #aero.tongues + 1, math.min(count, TONGUES_MAX) do
		local root = newAttachment(aero.part, "TongueRoot" .. index)
		local tip = newAttachment(aero.part, "TongueTip" .. index)
		local beam = newBeam(aero.part, "Tongue" .. index, root, tip, VAPOR_COLOR)
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Brightness = TONGUE_BRIGHTNESS
		beam.Segments = TONGUE_SEGMENTS
		table.insert(aero.tongues, {
			root = root,
			tip = tip,
			beam = beam,
			angle = 0,
			seed = index * 2.399, -- golden angle: unrelated flicker phases
		})
	end
end

local function takeAero(): AeroSlot?
	local slot = table.remove(freeAero)
	if slot then
		return slot
	end
	if aeroCount >= budget.aero then
		return nil
	end
	aeroCount += 1
	local part = carrierPart("Aero")
	local shell = ellipsoidPart("PlasmaShell")
	local glowShell = ellipsoidPart("PlasmaGlow")
	local vaporStart = newAttachment(part, "VaporStart")
	local vaporEnd = newAttachment(part, "VaporEnd")
	local ember = newAttachment(part, "Ember")
	local collar = newAttachment(part, "Collar")

	-- glow puffs from the inner shell's volume, drifting downstream with it
	local cap = newEmitter(shell, "Glow", FIRE_TEXTURE)
	cap.LockedToPart = true
	cap.LightEmission = 1
	cap.LightInfluence = 0
	cap.Lifetime = CAP_LIFETIME
	cap.Speed = NumberRange.new(0, 4)
	cap.SpreadAngle = Vector2.new(50, 50)
	cap.Transparency = fadeSequence(0.25)
	cap.RotSpeed = NumberRange.new(-200, 200)

	-- emitted from the carrier part's volume (a slab across the leading side), streaming backward (+Y)
	local streaks = newEmitter(part, "Streaks", FIRE_TEXTURE)
	streaks.LockedToPart = true
	streaks.LightEmission = 1
	streaks.LightInfluence = 0
	streaks.Lifetime = NumberRange.new(HEAT_STREAK_LIFETIME * 0.7, HEAT_STREAK_LIFETIME)
	streaks.SpreadAngle = Vector2.new(6, 6)
	streaks.Orientation = Enum.ParticleOrientation.VelocityParallel
	streaks.Squash = NumberSequence.new(HEAT_STREAK_SQUASH)
	streaks.Transparency = fadeSequence(0.25)
	streaks.Rotation = NumberRange.new(0, 0)
	streaks.RotSpeed = NumberRange.new(0, 0)

	-- embers: free particles that peel off the rim and are dragged away by the air
	local embers = newEmitter(ember, "Embers", SPARK_TEXTURE)
	embers.LightEmission = 1
	embers.LightInfluence = 0
	embers.Lifetime = EMBER_LIFETIME
	embers.Orientation = Enum.ParticleOrientation.VelocityParallel
	embers.Squash = NumberSequence.new(1.4)
	embers.Transparency = fadeSequence(0)
	embers.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 220)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 170, 70)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(220, 60, 30)),
	})

	-- vapour collar puffs: free particles that keep pace with the craft and slide back a little
	local collarPuffs = newEmitter(collar, "Collar", SMOKE_TEXTURE)
	collarPuffs.Color = VAPOR_COLOR
	collarPuffs.LightEmission = 0.15
	collarPuffs.LightInfluence = 1
	collarPuffs.Lifetime = COLLAR_LIFETIME
	collarPuffs.RotSpeed = NumberRange.new(-60, 60)

	local vapor = newBeam(part, "Vapor", vaporStart, vaporEnd, VAPOR_COLOR)
	vapor.LightEmission = 0.2
	vapor.LightInfluence = 1

	local light = Instance.new("PointLight")
	light.Name = "HeatLight"
	light.Shadows = false
	light.Enabled = false
	light.Parent = part

	local aero: AeroSlot = {
		part = part,
		shell = shell,
		glowShell = glowShell,
		vaporStart = vaporStart,
		vaporEnd = vaporEnd,
		ember = ember,
		collar = collar,
		cap = cap,
		streaks = streaks,
		embers = embers,
		collarPuffs = collarPuffs,
		tongues = {},
		vapor = vapor,
		light = light,
		heatLevel = -1,
		heatRadius = -1,
		heatLength = -1,
		shellSize = Vector3.zero,
		tongueCount = 0,
		vaporLevel = -1,
		collarRadius = -1,
	}
	ensureTongues(aero, budget.tongues)
	return aero
end

-- CHANGED (Effects v2): switches the plasma off (the shells park; the vapour cone is separate).
local function heatOff(aero: AeroSlot)
	if aero.heatLevel < 0 and aero.tongueCount == 0 then
		return
	end
	aero.cap.Rate = 0
	aero.streaks.Rate = 0
	aero.embers.Rate = 0
	for _, tongue in aero.tongues do
		tongue.beam.Enabled = false
	end
	aero.tongueCount = 0
	aero.shell.Transparency = 1
	aero.glowShell.Transparency = 1
	aero.shell.CFrame = PARK_CFRAME
	aero.glowShell.CFrame = PARK_CFRAME
	aero.light.Enabled = false
	aero.heatLevel = -1
	aero.heatRadius = -1
	aero.heatLength = -1
	aero.shellSize = Vector3.zero -- both shells are resized when the heat comes back (the tier may have changed)
end

local function vaporOff(aero: AeroSlot)
	aero.vapor.Enabled = false
	aero.collarPuffs.Rate = 0
	aero.vaporLevel = -1
end

local function releaseAero(slot: AeroSlot)
	heatOff(slot)
	vaporOff(slot)
	slot.part.CFrame = PARK_CFRAME
	table.insert(freeAero, slot)
end

local function destroyAero(slot: AeroSlot)
	slot.part:Destroy()
	slot.shell:Destroy()
	slot.glowShell:Destroy()
end

-- CHANGED (Effects v2): heat-glow Highlights (High)
local function takeTint(): TintSlot?
	local slot = table.remove(freeTints)
	if slot then
		return slot
	end
	if tintCount >= budget.heatTint * TINT_POOL_CRAFTS then
		return nil
	end
	tintCount += 1
	local highlight = Instance.new("Highlight")
	highlight.Name = "HeatGlow"
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.OutlineTransparency = 1
	highlight.FillTransparency = 1
	highlight.Enabled = false
	highlight.Parent = getFolder()
	return { highlight = highlight, blockId = -1, weight = 0, fill = 1 }
end

local function releaseTints(record: CraftRecord)
	for _, slot in record.tints do
		slot.highlight.Enabled = false
		slot.highlight.Adornee = nil
		slot.blockId = -1
		slot.fill = 1
		table.insert(freeTints, slot)
	end
	table.clear(record.tints)
	record.tintTimer = 0
	record.tintLevel = -1
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
	if #bursts < budget.bursts then
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
		sparks.Squash = NumberSequence.new(1.6) -- CHANGED (Effects v2): was 1.2; streakier sparks
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
	if nextBurst > #bursts then
		nextBurst = 1
	end
	local burst = bursts[nextBurst]
	nextBurst = nextBurst % #bursts + 1
	return burst
end

-- CHANGED (Effects v2): burst flashes share the tier's light budget (none below High).
local function flashLightsLit(): number
	local lit = 0
	for _, burst in bursts do
		if burst.light.Enabled then
			lit += 1
		end
	end
	return lit
end

-- `drift` is the velocity the burst's particles start from (CHANGED (Effects v2): looseVelocity, was the air's).
local function spawnBurst(position: Vector3, drift: Vector3, inAir: boolean, spec: BurstSpec)
	local wantLight = spec.light > 0 and flashLightsLit() < budget.flashLights
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
	burst.lightPeak = if wantLight then spec.light else 0
	burst.lightDuration = spec.lightDuration
	if wantLight then
		burst.light.Range = math.min(spec.lightRange, 60)
		burst.light.Brightness = spec.light
		burst.light.Enabled = true
	else
		burst.light.Enabled = false
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
	return {
		part = part,
		active = false,
		kind = "Core",
		age = 0,
		duration = 1,
		size0 = 1,
		size1 = 1,
		velocity = Vector3.zero,
	}
end

-- CHANGED (Effects v2): fireball colour and opacity over its life f (0..1), per palette.
local CORE_HOT = Color3.fromRGB(255, 240, 180)
local CORE_MID = Color3.fromRGB(255, 120, 30)
local CORE_END = Color3.fromRGB(120, 30, 10)
local OUTER_START = Color3.fromRGB(255, 150, 50)
local OUTER_MID = Color3.fromRGB(200, 60, 20)
local OUTER_END = Color3.fromRGB(55, 40, 36)
local FLASH_COLOR = Color3.fromRGB(255, 255, 240)

local function fireballLook(kind: FireballKind, f: number): (Color3, number)
	if kind == "Flash" then
		return FLASH_COLOR, 1 - FLASH_OPACITY * (1 - f) * (1 - f)
	elseif kind == "Outer" then
		local color = if f < 0.45
			then OUTER_START:Lerp(OUTER_MID, f / 0.45)
			else OUTER_MID:Lerp(OUTER_END, (f - 0.45) / 0.55)
		return color, 1 - OUTER_FIREBALL_OPACITY * (1 - f ^ 1.3)
	end
	local color = if f < 0.4 then CORE_HOT:Lerp(CORE_MID, f / 0.4) else CORE_MID:Lerp(CORE_END, (f - 0.4) / 0.6)
	return color, f ^ 1.5
end

local function spawnFireball(
	kind: FireballKind,
	position: Vector3,
	duration: number,
	size0: number,
	size1: number,
	velocity: Vector3
)
	local chosen: Fireball? = nil
	for _, fireball in fireballs do
		if not fireball.active then
			chosen = fireball
			break
		end
	end
	if chosen == nil then
		if #fireballs >= budget.fireballs then
			return
		end
		chosen = newFireball()
		table.insert(fireballs, chosen :: Fireball)
	end
	local fireball = chosen :: Fireball
	fireball.active = true
	fireball.kind = kind
	fireball.age = 0
	fireball.duration = duration
	fireball.size0 = size0
	fireball.size1 = size1
	fireball.velocity = velocity
	local color, transparency = fireballLook(kind, 0)
	fireball.part.Size = Vector3.one * size0
	fireball.part.Transparency = transparency
	fireball.part.Color = color
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
	trail.Lifetime = 0.25 -- CHANGED (Effects v2): was 0.2
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
			if #bits >= budget.debris then
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
		if record.aero then
			local aero = record.aero :: AeroSlot
			aero.embers:Clear()
			aero.collarPuffs:Clear()
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
	for _, slot in freeAero do
		slot.embers:Clear()
		slot.collarPuffs:Clear()
	end
end

--============================================================================
-- CHANGED (Effects v2): tier changes (Render/Quality)
--============================================================================

local function applyTier()
	tier = Quality.tier()
	budget = EffectsMath.budget(tier)
	quality = Quality.scale()
	tierApplied = true
	Plumes.configure({
		rateScale = quality,
		lights = budget.plumeLights,
		halo = budget.plumeHalo,
		machDiamonds = budget.machDiamonds,
		flicker = budget.plumeFlicker,
	})
	-- continuous slots: released now, taken again within the new caps on the next step
	for _, record in records do
		releaseSlots(record)
		releaseTints(record)
	end
	while #freeTrails > budget.trails do
		local slot = table.remove(freeTrails) :: TrailSlot
		slot.part:Destroy()
		trailCount -= 1
	end
	while #freeDust > budget.dust do
		local slot = table.remove(freeDust) :: DustSlot
		slot.part:Destroy()
		dustCount -= 1
	end
	while #freeAero > budget.aero do
		destroyAero(table.remove(freeAero) :: AeroSlot)
		aeroCount -= 1
	end
	for _, slot in freeAero do
		ensureTongues(slot, budget.tongues)
	end
	while #freeTints > budget.heatTint * TINT_POOL_CRAFTS do
		local slot = table.remove(freeTints) :: TintSlot
		slot.highlight:Destroy()
		tintCount -= 1
	end
	-- one-shot pools above the new caps go (a few live particles may vanish early)
	while #bursts > budget.bursts do
		local burst = table.remove(bursts) :: Burst
		burst.part:Destroy()
	end
	nextBurst = 1
	if budget.flashLights == 0 then
		for _, burst in bursts do
			burst.light.Enabled = false
		end
	end
	while #fireballs > budget.fireballs do
		local fireball = table.remove(fireballs) :: Fireball
		fireball.part:Destroy()
	end
	while #bits > budget.debris do
		local bit = table.remove(bits) :: Bit
		bit.part:Destroy()
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
			smoke = if pressure > 0.05 then 5 else 0,
			smokeVelocity = event.direction * 10,
			smokeRandom = 4,
			smokeSize0 = d * 0.8,
			smokeSize1 = d * 2.8,
			smokeLife = NumberRange.new(1, 1.6),
			smokeColor = BURST_SMOKE_COLOR,
			smokeTransparency = 0.4,
			fire = 0,
			fireRandom = 0,
			fireSize0 = 0,
			fireSize1 = 0,
			fireLife = NumberRange.new(0.2),
			sparks = 8,
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
		smokeVelocity = outward * 6,
		smokeRandom = 12,
		smokeSize0 = s * 1.1,
		smokeSize1 = s * 4.5,
		smokeLife = NumberRange.new(0.8, 1.8),
		smokeColor = BURST_SMOKE_COLOR,
		smokeTransparency = 0.15,
		fire = 0,
		fireRandom = 0,
		fireSize0 = 0,
		fireSize1 = 0,
		fireLife = NumberRange.new(0.2),
		sparks = SEPARATION_SPARKS,
		sparkVelocity = outward * 22,
		sparkRandom = 28,
		sparkSize = 0.4,
		sparkLife = NumberRange.new(0.25, 0.55),
		light = SEPARATION_LIGHT,
		lightRange = 6 * s,
		lightDuration = 0.25,
	})
	-- CHANGED (Effects v2): the pyro bolts' flash
	spawnFireball("Flash", position, SEPARATION_FLASH_TIME, s * 0.8, s * 2.2, drift)
end

-- CHANGED (Effects v2): `k` = explosion scale; `main` = the crash's main blast (outer fireball, more of everything).
local function explosion(
	position: Vector3,
	k: number,
	drift: Vector3,
	debrisDrift: Vector3,
	inAir: boolean,
	main: boolean
)
	if explosionBudget < 1 then
		return
	end
	explosionBudget -= 1
	local root = math.sqrt(k)
	local more = if main then 1.5 else 1
	spawnBurst(position, drift, inAir, {
		smoke = 12 * root * more,
		smokeVelocity = Vector3.zero,
		smokeRandom = 12 * root,
		smokeSize0 = 3 * k,
		smokeSize1 = 11 * k,
		smokeLife = NumberRange.new(1.8, 3.5),
		smokeColor = BURST_DARK_SMOKE_COLOR,
		smokeTransparency = 0.1,
		fire = 14 * root * more,
		fireRandom = 18 * root,
		fireSize0 = 2.5 * k,
		fireSize1 = 6 * k,
		fireLife = NumberRange.new(0.35, 0.8),
		sparks = 16 * more,
		sparkVelocity = Vector3.zero,
		sparkRandom = 50 * root,
		sparkSize = 0.5 * root,
		sparkLife = NumberRange.new(0.3, 0.9),
		light = EXPLOSION_LIGHT,
		lightRange = 18 * k,
		lightDuration = EXPLOSION_LIGHT_TIME,
	})
	local duration = FIREBALL_TIME * math.sqrt(k)
	spawnFireball("Core", position, duration, FIREBALL_SIZE0 * k, FIREBALL_SIZE1 * k, drift)
	if main then
		spawnFireball(
			"Outer",
			position,
			duration * OUTER_FIREBALL_TIME,
			FIREBALL_SIZE0 * k * OUTER_FIREBALL_SIZE,
			FIREBALL_SIZE1 * k * OUTER_FIREBALL_SIZE,
			drift
		)
	end
	local debris = budget.debrisPerExplosion * (if main then 2 else 1)
	spawnBits(position, k, debrisDrift, scaledCount(debris))
	if budget.classicExplosion and drift.Magnitude < CLASSIC_MAX_DRIFT then
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
	-- CHANGED (Effects v2): the tier caps how long the smoke column lingers
	local lifetime = EffectsMath.trailLifetime(airSpeed, budget.trailLifetimeMax)
	if math.abs(lifetime - trail.lifetime) > 0.1 * trail.lifetime then
		trail.lifetime = lifetime
		emitter.Lifetime = NumberRange.new(lifetime * 0.8, lifetime)
	end
	-- CHANGED (Effects v2): booster smoke is greyer
	local solidColor = solidShare > TRAIL_SOLID_COLOR_SHARE
	if solidColor ~= trail.solidColor then
		trail.solidColor = solidColor
		emitter.Color = if solidColor then TRAIL_COLOR_SOLID else TRAIL_COLOR
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
	local active = math.clamp(budget.dustEmitters, 1, DUST_EMITTERS_MAX)
	local rebuilt = active ~= dust.active -- CHANGED (Effects v2): emitters per ring follow the tier
	local resize = rebuilt or math.abs(size - dust.size) > 0.1 * dust.size
	if resize then
		dust.size = size
	end
	local recolor = rebuilt or color ~= dust.color
	dust.color = color
	dust.active = active
	local driftSpeed = record.drift.Magnitude
	local drag = DUST_DRAG * (1 - math.clamp(driftSpeed / DUST_DRAG_FADE_SPEED, 0, 1))
	local rate = DUST_RATE_MAX / active * strength * quality
	local outSpeed = DUST_OUT_SPEED * (0.5 + 0.5 * strength)
	for index, emitter in dust.emitters do
		if index > active then
			if rebuilt then
				emitter.Rate = 0
			end
			continue
		end
		local angle = (index - 1) * (2 * math.pi / active)
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

-- CHANGED (Effects v2): a flame / glow transparency profile along the flow that fades in with the heat level.
local function heatSequence(base: number, level: number): NumberSequence
	local alpha = 1 - math.clamp(level / 0.5, 0, 1) -- full opacity from heat 0.5 on
	local function t(x: number): number
		return math.clamp(x + (1 - x) * alpha, 0, 1)
	end
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, t(base + 0.15)),
		NumberSequenceKeypoint.new(0.1, t(base)),
		NumberSequenceKeypoint.new(0.55, t(base + 0.3)),
		NumberSequenceKeypoint.new(1, 1),
	})
end

-- CHANGED (Effects v2): the plasma colour along the flow at a heat level (EffectsMath.heatColor).
local function heatColors(level: number): ColorSequence
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, EffectsMath.heatColor(level, 0)),
		ColorSequenceKeypoint.new(0.3, EffectsMath.heatColor(level, 0.35)),
		ColorSequenceKeypoint.new(0.65, EffectsMath.heatColor(level, 0.7)),
		ColorSequenceKeypoint.new(1, EffectsMath.heatColor(level, 1)),
	})
end

local function setShell(part: Part, cframe: CFrame, size: Vector3, resize: boolean, transparency: number)
	if resize then
		part.Size = size
	end
	part.CFrame = cframe
	part.Transparency = transparency
end

--[[
	CHANGED (Effects v2): the re-entry plasma and the vapour cone. velocityWs = the craft's velocity relative to the
	air (s.vel, body-relative) in pocket axes: the flow comes from `forward` and streams back along -forward.
	The carrier sits on the leading face with +Y downstream; tongues, streaks and the vapour attachments are in its
	axes, so they follow it.
]]
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
	local airSpeed = velocityWs.Magnitude
	local forward = velocityWs / airSpeed
	local reach, radius = EffectsMath.leadingExtent(info.half, craftCFrame:VectorToObjectSpace(forward))
	local center = craftCFrame:PointToWorldSpace(info.center)
	local leadPoint = center + forward * reach
	local frame = EffectsMath.frameWithUp(leadPoint, -forward)
	aero.part.CFrame = frame
	local slab = Vector3.new(radius * 2, 0.4, radius * 2)
	if (aero.part.Size - slab).Magnitude > 0.1 * radius then
		aero.part.Size = slab
	end

	if heat > AERO_MIN then
		local shape = EffectsMath.plasma(heat)
		local level = math.ceil(heat / HEAT_QUANTUM) * HEAT_QUANTUM
		local recolor = level ~= aero.heatLevel
		local resized = math.abs(radius - aero.heatRadius) > 0.05 * math.max(aero.heatRadius, 0.1)
		aero.heatLevel = level
		if resized then
			aero.heatRadius = radius
		end

		-- the shock layer: a glowing ellipsoid hugging the windward face (half of it hides inside the hull)
		local depth = radius * shape.shellDepth
		local shellSize = Vector3.new(radius * SHELL_SPAN, depth * 2, radius * SHELL_SPAN)
		local resizeShell = (shellSize - aero.shellSize).Magnitude > SHELL_RESIZE * shellSize.Magnitude
		if resizeShell then
			aero.shellSize = shellSize
		end
		local flick = EffectsMath.flicker(now, record.id, SHELL_FLICKER)
		setShell(
			aero.shell,
			frame * CFrame.new(0, -depth * SHELL_FORWARD, 0),
			shellSize,
			resizeShell,
			1 - math.clamp(shape.shellOpacity * flick, 0, 1)
		)
		if budget.shellGlow then
			local glowDepth = depth * GLOW_SHELL_DEPTH
			setShell(
				aero.glowShell,
				frame * CFrame.new(0, -glowDepth * GLOW_SHELL_FORWARD, 0),
				Vector3.new(radius * GLOW_SHELL_SPAN, glowDepth * 2, radius * GLOW_SHELL_SPAN),
				resizeShell,
				1 - math.clamp(shape.glowOpacity * (2 - flick), 0, 1)
			)
		elseif aero.glowShell.Transparency < 1 then
			aero.glowShell.Transparency = 1
			aero.glowShell.CFrame = PARK_CFRAME
		end
		if recolor then
			aero.shell.Color = EffectsMath.heatColor(level, 0)
			aero.glowShell.Color = EffectsMath.heatColor(level, 1)
		end

		-- flame tongues streaming back along the flow from the leading rim
		local count = math.min(budget.tongues, TONGUES_MAX)
		ensureTongues(aero, count)
		local length = (2 * reach + radius * shape.tongueLength) * budget.tongueLength
		local colors: ColorSequence? = if recolor then heatColors(level) else nil
		local transparency: NumberSequence? = if recolor then heatSequence(0.15, level) else nil
		local rootWidth = radius * shape.tongueWidth
		for index, tongue in aero.tongues do
			local beam = tongue.beam
			if index > count then
				if beam.Enabled then
					beam.Enabled = false
				end
				continue
			end
			if resized or aero.tongueCount ~= count then
				tongue.angle = (index - 1) * (2 * math.pi / count) + 0.35
				local c, s = math.cos(tongue.angle), math.sin(tongue.angle)
				tongue.root.Position = Vector3.new(
					c * radius * TONGUE_ROOT_RADIUS,
					radius * TONGUE_ROOT_DOWNSTREAM,
					s * radius * TONGUE_ROOT_RADIUS
				)
				beam.Width1 = radius * TONGUE_TIP_WIDTH
			end
			local f = EffectsMath.flicker(now, tongue.seed + record.id, 1) -- 0..2
			local reachBack = length * (1 - TONGUE_LENGTH_JITTER * 0.5 * f)
			local c, s = math.cos(tongue.angle), math.sin(tongue.angle)
			tongue.tip.Position =
				Vector3.new(c * radius * TONGUE_TIP_RADIUS, math.max(reachBack, radius), s * radius * TONGUE_TIP_RADIUS)
			beam.Width0 = rootWidth * EffectsMath.flicker(now, tongue.seed * 1.7 + record.id, TONGUE_WIDTH_FLICKER)
			if colors then
				beam.Color = colors
			end
			if transparency then
				beam.Transparency = transparency
			end
			if not beam.Enabled then
				beam.Enabled = true
				if colors == nil then
					beam.Color = heatColors(level)
					beam.Transparency = heatSequence(0.15, level)
				end
			end
		end
		aero.tongueCount = count

		-- glow puffs on the shell, streaks (Medium+) and embers (High)
		if recolor or resized then
			local puffColors = colors or heatColors(level)
			aero.cap.Color = puffColors
			aero.streaks.Color = puffColors
			aero.cap.Size = sizeSequence(radius * CAP_SIZE0 * (0.7 + 0.3 * level), radius * CAP_SIZE1)
			aero.streaks.Size = sizeSequence(math.max(radius * 0.35, 0.4), radius * 0.15)
		end
		aero.cap.Rate = CAP_RATE * heat * quality
		if budget.streaks then
			if math.abs(length - aero.heatLength) > 0.05 * math.max(aero.heatLength, 0.1) then
				aero.heatLength = length
				aero.streaks.Speed = NumberRange.new(length / HEAT_STREAK_LIFETIME * 0.8, length / HEAT_STREAK_LIFETIME)
			end
			aero.streaks.Rate = HEAT_STREAK_RATE * shape.streakRate * quality
		else
			aero.streaks.Rate = 0
		end
		if budget.embers and shape.emberRate > 0 then
			local angle = rng:NextNumber(0, 2 * math.pi)
			local rim = frame:PointToWorldSpace(
				Vector3.new(math.cos(angle) * radius * EMBER_RIM, 0, math.sin(angle) * radius * EMBER_RIM)
			)
			-- they leave at the craft's velocity less a little, then the air drags them back along the flow
			aim(aero.ember, aero.embers, rim, record.drift + velocityWs * (1 - EMBER_SHED), EMBER_RANDOM)
			if resized then
				local size = EMBER_SIZE * math.sqrt(math.max(radius, 0.5) / 2)
				aero.embers.Size = sizeSequence(size, size * 0.3)
			end
			aero.embers.Acceleration = -forward * EMBER_PULL - frameAccel
			aero.embers.Rate = EMBER_RATE * shape.emberRate * quality
		else
			aero.embers.Rate = 0
		end

		-- the heat light (High, while the frame's budget lasts)
		if heatLightsUsed < budget.heatLights then
			heatLightsUsed += 1
			aero.light.Brightness = HEAT_LIGHT * shape.light * flick
			if recolor or resized then
				aero.light.Color = EffectsMath.heatColor(level, 0.25)
				aero.light.Range = math.min(radius * HEAT_LIGHT_RANGE, 60)
			end
			aero.light.Enabled = true
		elseif aero.light.Enabled then
			aero.light.Enabled = false
		end
	else
		heatOff(aero)
	end

	if vapor > AERO_MIN then
		local wobble = EffectsMath.flicker(now, record.id + 0.5, VAPOR_FLICKER)
		local vaporY = reach * 0.8
		aero.vaporStart.Position = Vector3.new(0, vaporY, 0)
		aero.vaporEnd.Position = Vector3.new(0, vaporY + radius * 2.5, 0)
		aero.vapor.Width0 = radius * 2.3
		aero.vapor.Width1 = radius * 4.5 * wobble
		local level = math.ceil(vapor / HEAT_QUANTUM) * HEAT_QUANTUM
		local relevel = level ~= aero.vaporLevel
		if relevel then
			aero.vaporLevel = level
			local start = 1 - VAPOR_OPACITY * level
			aero.vapor.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, math.min(start + 0.25, 1)),
				NumberSequenceKeypoint.new(0.3, start),
				NumberSequenceKeypoint.new(1, 1),
			})
		end
		aero.vapor.Enabled = true
		-- CHANGED (Effects v2): puffs on a ring around the body (Medium+), keeping pace with the craft
		if budget.vaporCollar then
			local angle = rng:NextNumber(0, 2 * math.pi)
			local ringRadius = radius * 1.05
			local spot =
				frame:PointToWorldSpace(Vector3.new(math.cos(angle) * ringRadius, vaporY, math.sin(angle) * ringRadius))
			aim(aero.collar, aero.collarPuffs, spot, record.velocityWs - forward * COLLAR_SPEED, 3)
			if relevel or math.abs(ringRadius - aero.collarRadius) > 0.05 * aero.collarRadius then
				aero.collarRadius = ringRadius
				aero.collarPuffs.Size = sizeSequence(radius * 0.8, radius * 1.5)
				aero.collarPuffs.Transparency = fadeSequence(1 - COLLAR_OPACITY * level)
			end
			aero.collarPuffs.Acceleration = -frameAccel
			aero.collarPuffs.Rate = COLLAR_RATE * vapor * quality
		else
			aero.collarPuffs.Rate = 0
		end
	else
		vaporOff(aero)
	end
end

--[[
	CHANGED (Effects v2): the leading blocks glow while they are hot and fade slowly after (High only). The blocks
	are chosen every TINT_REFRESH_S along the last flow direction (craft-local), so the glow stays on the parts that
	took the heat even after the plasma is gone.
]]
local function updateTints(record: CraftRecord, model: Model, info: DesignInfo, dt: number)
	local wanted = budget.heatTint
	if wanted <= 0 or record.soak < TINT_MIN then
		if #record.tints > 0 then
			releaseTints(record)
		end
		return
	end
	record.tintTimer -= dt
	if record.tintTimer <= 0 then
		record.tintTimer = TINT_REFRESH_S
		-- the most windward blocks along the flow (largest projection on the direction the air comes from)
		table.clear(rankScratch)
		local forward = record.tintForward
		for _, block in info.blocks do
			table.insert(rankScratch, block)
		end
		table.sort(rankScratch, function(a: BlockInfo, b: BlockInfo): boolean
			return (a.pos - info.center):Dot(forward) > (b.pos - info.center):Dot(forward)
		end)
		local count = math.min(wanted, #rankScratch, #TINT_WEIGHTS)
		for index = 1, count do
			local block = rankScratch[index]
			local slot: TintSlot? = record.tints[index]
			if slot == nil then
				slot = takeTint()
				if slot == nil then
					break
				end
				table.insert(record.tints, slot :: TintSlot)
			end
			local tint = slot :: TintSlot
			tint.weight = TINT_WEIGHTS[index]
			if tint.blockId ~= block.id or tint.highlight.Adornee == nil then
				tint.blockId = block.id
				local blockModel = model:FindFirstChild("Block_" .. block.id)
				tint.highlight.Adornee = blockModel
				tint.highlight.Enabled = blockModel ~= nil
				tint.fill = 1
				record.tintLevel = -1 -- recolour the new one
			end
		end
		for index = #record.tints, count + 1, -1 do
			local slot = table.remove(record.tints, index) :: TintSlot
			slot.highlight.Enabled = false
			slot.highlight.Adornee = nil
			slot.blockId = -1
			table.insert(freeTints, slot)
		end
		table.clear(rankScratch)
	end
	local level = math.ceil(record.soak / HEAT_QUANTUM) * HEAT_QUANTUM
	local recolor = level ~= record.tintLevel
	record.tintLevel = level
	local color = if recolor then EffectsMath.heatColor(level * 0.85, 0.3) else nil
	for _, tint in record.tints do
		local fill = 1 - TINT_MAX * record.soak * tint.weight
		if math.abs(fill - tint.fill) > TINT_EPSILON then
			tint.fill = fill
			tint.highlight.FillTransparency = fill
		end
		if color then
			tint.highlight.FillColor = color
		end
	end
end

local function processCraft(record: CraftRecord, report: CraftReport, ctx: RenderContext, frameVelocity: Vec3d)
	local s = report.state
	local frame = ctx.frame
	local model = report.model
	local previous = record.model
	if previous and previous ~= model then
		Plumes.clear(previous)
		releaseTints(record) -- CHANGED (Effects v2): the highlights adorn the old model's blocks
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
	-- CHANGED (Effects v2): the craft's velocity relative to the air, and its own workspace velocity
	local airVelocityWs = Frames.vectorToWorkspace(frame, s.vel)
	record.velocityWs = drift + airVelocityWs
	record.pressure = pressure

	-- Plumes, and their ignition / cut-off transitions
	table.clear(eventScratch)
	if model.Parent ~= nil then
		Plumes.update(model, report.burning, pressure, ctx.dt, eventScratch)
	end
	if #eventScratch > 0 then
		local loose = looseVelocity(record) -- CHANGED (Effects v2)
		for _, event in eventScratch do
			plumeEvent(event, loose, pressure)
		end
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
		updateAero(record, airVelocityWs, craftCFrame, info, heat, vapor)
	elseif record.aero then
		releaseAero(record.aero :: AeroSlot)
		record.aero = nil
	end

	-- CHANGED (Effects v2): the leading blocks' heat glow lags the heat (and outlives the plasma)
	record.soak = EffectsMath.heatSoak(record.soak, heat, ctx.dt)
	if heat > AERO_MIN and airSpeed > 1 then
		record.tintForward = craftCFrame:VectorToObjectSpace(airVelocityWs / airSpeed)
	end
	updateTints(record, model, info, ctx.dt)
end

-- A craft that was not reported recently: everything continuous goes out. Its plumes are destroyed (not just switched
-- off), so when it is drawn again (map view closed, copy LOD back) they come back without an ignition flash.
local function sweep(record: CraftRecord, time: number): boolean
	releaseSlots(record)
	releaseTints(record) -- CHANGED (Effects v2)
	record.soak = 0
	record.report = nil
	record.localReport = nil
	record.streamReport = nil
	local model = record.model
	if model then
		Plumes.clear(model)
		record.model = nil
	end
	return time - record.reportTime > FORGET_AFTER_S
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
			if burst.age < BURST_ACTIVE_S then
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
				local color, transparency = fireballLook(fireball.kind, f)
				part.Transparency = transparency
				part.Color = color
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
		if burst.age < BURST_ACTIVE_S then
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
-- CHANGED (Effects v2): and follows the Render/Quality tier from now on.
function Effects.init(parent: Instance)
	local created = Instance.new("Folder")
	created.Name = FOLDER_NAME
	created.Parent = parent
	folder = created
	applyTier()
	if tierConnection == nil then
		tierConnection = Quality.onChanged(function()
			applyTier()
		end)
	end
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
			velocityWs = Vector3.zero,
			pressure = 0,
			centerWs = Vector3.zero,
			trail = nil,
			dust = nil,
			aero = nil,
			dustColor = DUST_SMOKE_COLOR,
			dustColorTimer = 0,
			soak = 0,
			tintForward = Vector3.yAxis,
			tintTimer = 0,
			tintLevel = -1,
			tints = {},
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
	if not tierApplied then
		applyTier()
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
	-- CHANGED (Effects v2): smoke / fireballs start with the craft's momentum in thin air (EffectsMath.airCoupling)
	local loose = looseVelocity(record)
	if kind == "Separate" then
		for _, block in candidates do
			local position = craftCFrame:PointToWorldSpace(block.pos)
			local away = position - record.centerWs
			local outward = if away.Magnitude > 1e-3 then away.Unit else -craftCFrame.UpVector
			separation(position, block.size, outward, loose, inAir)
		end
	else
		table.sort(candidates, function(a, b)
			return a.size.Magnitude > b.size.Magnitude
		end)
		local debrisVelocity = looseVelocity(record, EffectsMath.airCoupling(record.pressure) * BIT_AIR_COUPLING)
		local perEvent = budget.explosionsPerEvent
		-- CHANGED (Effects v2): a main blast at the wreck's centre, sized by its span and the blocks lost
		if #candidates >= MAIN_BLAST_MIN_BLOCKS then
			local lo, hi = Vector3.one * math.huge, -Vector3.one * math.huge
			local sum = Vector3.zero
			for _, block in candidates do
				local halfSize = block.size / 2
				lo = lo:Min(block.pos - halfSize)
				hi = hi:Max(block.pos + halfSize)
				sum += block.pos
			end
			local centre = craftCFrame:PointToWorldSpace(sum / #candidates)
			local k = EffectsMath.blastScale((hi - lo).Magnitude, #candidates)
			explosion(centre, k, loose, debrisVelocity, inAir, true)
			perEvent -= 1
		end
		for index, block in candidates do
			if index > perEvent then
				break
			end
			local k = EffectsMath.explosionScale(block.size)
			explosion(craftCFrame:PointToWorldSpace(block.pos), k, loose, debrisVelocity, inAir, #candidates == 1)
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
	now = os.clock()
	local frame = ctx.frame

	-- CHANGED (Effects v2): the tier comes from Render/Quality (applied at init and on every change)
	if not tierApplied then
		applyTier()
	end
	Plumes.beginFrame()
	heatLightsUsed = 0
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
	stats.crafts, stats.trails, stats.dust, stats.aero, stats.tints = 0, 0, 0, 0, 0
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
			stats.tints += #record.tints
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
	-- CHANGED (Effects v2): + tier, heat glows and the pools' caps
	return string.format(
		"Effects [%s x%.2f]: %d crafts  %d flames  %d trails  %d dust  %d heat  %d glows  bursts %d/%d  fireballs %d/%d  debris %d/%d",
		tier,
		quality,
		stats.crafts,
		Plumes.litCount(),
		stats.trails,
		stats.dust,
		stats.aero,
		stats.tints,
		stats.bursts,
		budget.bursts,
		active,
		budget.fireballs,
		flying,
		budget.debris
	)
end

return table.freeze(Effects)
