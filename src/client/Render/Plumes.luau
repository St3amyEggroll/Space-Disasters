--!strict
--[[
	Plumes
	Engine exhaust effects (spec 7.4): a fiery ParticleEmitter, a two-layer Beam flame (bright core + soft outer
	glow) and an orange PointLight per burning engine.

	update(model, burning, pressure, dt, events?)
	                        burning = { [blockId] = throttle 0..1 } for the engines producing thrust right now;
	                        every other engine of the model that has a plume is switched off.
	clear(model)            destroys every plume instance created for the model and forgets it.
	litCount()              plumes burning right now (F3).

	Engine blocks are children of the model named "Block_<id>"; each has Bounds.Exhaust (PartVisuals), an
	Attachment at the nozzle exit whose UpVector points down the exhaust. Everything is created lazily under that
	attachment (the flame tips are sibling attachments under Bounds, pushed along the exhaust direction) and then
	only toggled / re-tuned, never recreated per frame. Properties are only written when the throttle or the air
	pressure moved by more than their epsilons (or the model was rescaled with Model:ScaleTo), so a steady burn
	costs a table lookup.

	Sizes derive from the engine's nozzle diameter (min of the Bounds X/Z size in unscaled studs: engine_s 4,
	engine_l 8, srb_s 4) and are multiplied by Model:GetScale(), so client-side cosmetic copies that are shrunk
	with ScaleTo get proportional plumes. Works for any model: the local craft's real model or cosmetic copies.

	CHANGED (Phase 10): effects phase.
	  * The flame shape follows the air pressure (EffectsMath.plumeShape): narrow, bright and tight near sea level;
	    a wide, faint cone that keeps expanding in vacuum. The bright core has its own tip (shorter in vacuum).
	  * Solid boosters are recognised by their part (Engine.Throttleable = false) instead of their shape alone:
	    thicker, longer flames with smokier particles.
	  * Ignition flash: when an engine lights on a model we already draw, the light and the core flare up for
	    FLASH_TIME and a burst of flame particles is emitted. Not on a model's first update (a copy that appears
	    mid-burn does not flash).
	  * update() can report transitions (events): "Ignite" and "Cutoff" with the nozzle's world position and
	    exhaust direction, so Render/Effects adds the ignition sparks and the cut-off smoke puff.
	  * Called by Render/Effects only (FlightController and RemoteCraftRenderer report crafts to Effects).

	CHANGED (Effects v2): Steamy: "effects still look shitty ... should go with graphics quality".
	  * Up to four layers per engine: white-hot core, coloured glow, a wide faint halo (Medium+) and, for liquid
	    engines in thick air, blue-white shock diamonds along the core (Medium+, EffectsMath.machDiamondKeys) that
	    fade out as the air thins.
	  * Colours follow the engine type and the air (EffectsMath.plumeTint): orange at sea level, a pale blue-white
	    expanding plume in vacuum; boosters burn deep orange with dense, smoky particles.
	  * The flame eases to a new throttle (THROTTLE_RISE_S / THROTTLE_FALL_S) and flickers (Medium+, a few property
	    writes per lit engine per frame, EffectsMath.flicker: no Random, no allocation).
	  * configure(settings) is called by Render/Effects with the Render/Quality tier's budget: particle rate scale,
	    halo / diamonds / flicker switches and the PointLight budget (High only). A new configuration rewrites every
	    plume on its next update. beginFrame() resets the per-frame light budget.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Parts = require(ReplicatedStorage.Shared.Config.Parts) -- CHANGED (Phase 10): solid booster detection
local EffectsMath = require(script.Parent.EffectsMath) -- CHANGED (Phase 10)

--============================================================================
-- Tunables
--============================================================================
local THROTTLE_EPSILON = 0.02 -- only rewrite properties when the throttle moved more than this
-- CHANGED (Phase 10): ... or the plume's vacuum factor (EffectsMath.vacuumFactor, which is what shapes it) moved
-- more than this. Not the raw pressure ratio: the shape follows its square root, so equal pressure steps would
-- freeze the plume high up and then snap it.
local VACUUM_EPSILON = 0.02
local SCALE_EPSILON = 0.01 -- relative Model:GetScale() change that forces a rewrite
local MIN_THROTTLE = 0.001 -- at or below this an engine counts as off
local REFERENCE_DIAMETER = 4 -- studs; engine_s nozzle, all "per diameter" factors below are relative to this
local BOOSTER_ASPECT = 1.8 -- fallback: Bounds height / diameter above which a block is treated as a solid booster
-- CHANGED (Effects v2): the flame eases to a new throttle (s time constants); an ignition starts at this fraction
local THROTTLE_RISE_S = 0.08
local THROTTLE_FALL_S = 0.15
local IGNITION_START = 0.3
-- Particles
local PARTICLE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local PARTICLE_RATE_MAX = 90 -- particles/s at full throttle (x the tier's rate scale)
local PARTICLE_RATE_MIN = 25 -- particles/s at minimum throttle
local PARTICLE_RATE_SOLID_MULT = 1.5 -- CHANGED (Effects v2): boosters throw out a denser, smokier flame
local PARTICLE_LIFETIME = NumberRange.new(0.22, 0.4)
local PARTICLE_SIZE_START = 0.45 -- x diameter
local PARTICLE_SIZE_MID = 0.8
local PARTICLE_SIZE_END = 1.3
local PARTICLE_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 220)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 214, 90)),
	ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 128, 32)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 44, 20)),
})
-- CHANGED (Phase 10): solid boosters burn yellower and end in grey-brown smoke
-- CHANGED (Effects v2): thick bright orange, then dense grey smoke
local PARTICLE_COLOR_SOLID = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 220)),
	ColorSequenceKeypoint.new(0.15, Color3.fromRGB(255, 200, 90)),
	ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 130, 35)),
	ColorSequenceKeypoint.new(0.65, Color3.fromRGB(140, 105, 90)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 116, 112)),
})
local PARTICLE_LIFETIME_SOLID = NumberRange.new(0.35, 0.65) -- CHANGED (Effects v2): was 0.3..0.55
-- Beam flame
local BEAM_SEGMENTS = 10
-- CHANGED (Effects v2): the core is white at the nozzle and takes EffectsMath.plumeTint's core-tip colour
local CORE_WHITE = Color3.fromRGB(255, 255, 248)
local CORE_WHITE_SOLID = Color3.fromRGB(255, 248, 220)
local CORE_WHITE_AT = 0.35 -- keypoint where the core is still mostly white
-- CHANGED (Effects v2): the glow / halo colours come from EffectsMath.plumeTint (was GLOW_COLOR / GLOW_COLOR_VACUUM
-- switched at a vacuum threshold); they are rebuilt when the vacuum factor moved more than this
local COLOR_VACUUM_EPSILON = 0.05
-- Base transparency keypoints (time, transparency); EffectsMath.plumeShape's fade is added on top
local CORE_TRANSPARENCY_KEYS = { { 0, 0.05 }, { 0.6, 0.3 }, { 1, 1 } }
local GLOW_TRANSPARENCY_KEYS = { { 0, 0.55 }, { 0.5, 0.75 }, { 1, 1 } }
local PARTICLE_TRANSPARENCY_KEYS = { { 0, 0.15 }, { 0.5, 0.35 }, { 1, 1 } }
-- CHANGED (Effects v2): liquid particles are fainter (the beams carry the shape); boosters' are dense
local PARTICLE_TRANSPARENCY_KEYS_LIQUID = { { 0, 0.3 }, { 0.5, 0.5 }, { 1, 1 } }
local PARTICLE_TRANSPARENCY_KEYS_SOLID = { { 0, 0.05 }, { 0.4, 0.2 }, { 1, 1 } }
-- CHANGED (Effects v2): halo, a third, widest and faintest layer (Medium+)
local HALO_WIDTH_MULT = 1.6 -- x the glow widths
local HALO_LENGTH = 0.85 -- x the glow length
local HALO_BRIGHTNESS = 0.6
local HALO_TRANSPARENCY_KEYS = { { 0, 0.75 }, { 0.4, 0.82 }, { 1, 1 } }
-- CHANGED (Effects v2): shock diamonds (liquid engines in thick air, Medium+)
local DIAMOND_COLOR = ColorSequence.new(Color3.fromRGB(205, 228, 255), Color3.fromRGB(255, 255, 255))
local DIAMOND_LENGTH = 0.8 -- x the core length
local DIAMOND_SPACING = 1.4 -- x nozzle diameter between diamonds
local DIAMOND_WIDTH0 = 0.42 -- x nozzle diameter
local DIAMOND_WIDTH1 = 0.26
local DIAMOND_BRIGHTNESS = 3
local DIAMOND_VACUUM_START = 0.12 -- vacuum factor where the diamonds start to fade
local DIAMOND_VACUUM_END = 0.5 -- ... and are gone
local DIAMOND_MIN_STRENGTH = 0.05
-- CHANGED (Effects v2): flicker (Medium+)
local FLICKER_WIDTH = 0.07 -- relative glow width wobble
local FLICKER_BRIGHTNESS = 0.12 -- relative core / light brightness wobble
-- Light
local LIGHT_COLOR = Color3.fromRGB(255, 165, 80) -- CHANGED (Effects v2): was 255,150,60
local LIGHT_COLOR_SOLID = Color3.fromRGB(255, 145, 55) -- CHANGED (Effects v2)
local LIGHT_RANGE = 4 -- x diameter
local LIGHT_RANGE_MAX = 60 -- studs (Roblox caps PointLight.Range at 60)
-- CHANGED (Phase 10): ignition flash
local FLASH_TIME = 0.35 -- s
local FLASH_LIGHT = 6 -- extra PointLight brightness at the start of the flash
local FLASH_CORE = 1.5 -- extra core brightness multiplier at the start of the flash
local FLASH_PARTICLES = 14 -- flame particles emitted at ignition (x the tier's rate scale)
-- Instance names
local EXHAUST_NAME = "Exhaust"
local TIP_NAME = "PlumeTip"
local CORE_TIP_NAME = "PlumeCoreTip" -- CHANGED (Phase 10)
local HALO_TIP_NAME = "PlumeHaloTip" -- CHANGED (Effects v2)
local DIAMOND_TIP_NAME = "PlumeDiamondTip" -- CHANGED (Effects v2)
local EMITTER_NAME = "PlumeParticles"
local CORE_NAME = "PlumeCore"
local GLOW_NAME = "PlumeGlow"
local HALO_NAME = "PlumeHalo" -- CHANGED (Effects v2)
local DIAMOND_NAME = "PlumeDiamonds" -- CHANGED (Effects v2)
local LIGHT_NAME = "PlumeLight"
--============================================================================

-- CHANGED (Phase 10): transitions reported to Render/Effects
export type PlumeEvent = {
	kind: "Ignite" | "Cutoff",
	position: Vector3, -- nozzle exit, workspace
	direction: Vector3, -- unit, down the exhaust, workspace
	diameter: number, -- studs (scaled)
	solid: boolean,
}

-- CHANGED (Effects v2): what the Render/Quality tier allows (Render/Effects calls configure on every tier change)
export type Settings = {
	rateScale: number, -- particle rate multiplier (Quality.scale())
	lights: number, -- PointLights across all plumes per frame
	halo: boolean,
	machDiamonds: boolean,
	flicker: boolean,
}

type Plume = {
	exhaust: Attachment,
	tip: Attachment,
	coreTip: Attachment, -- CHANGED (Phase 10): the core's own tip (shorter than the glow in vacuum)
	haloTip: Attachment, -- CHANGED (Effects v2)
	diamondTip: Attachment, -- CHANGED (Effects v2)
	emitter: ParticleEmitter,
	core: Beam,
	glow: Beam,
	halo: Beam, -- CHANGED (Effects v2)
	diamonds: Beam, -- CHANGED (Effects v2)
	light: PointLight,
	diameter: number, -- unscaled nozzle diameter, studs
	solid: boolean, -- CHANGED (Phase 10): solid booster (was a length multiplier from the block's shape)
	throttle: number, -- last applied throttle (0 = off)
	shown: number, -- CHANGED (Effects v2): eased throttle the flame shows
	vacuum: number, -- CHANGED (Phase 10): last applied EffectsMath.vacuumFactor
	colorVacuum: number, -- CHANGED (Effects v2): vacuum factor the colours were built for (-1 = never)
	scale: number, -- Model:GetScale() the properties were last written for
	version: number, -- CHANGED (Effects v2): configuration version the properties were written for
	flash: number, -- CHANGED (Phase 10): seconds of ignition flash left
	baseLight: number, -- PointLight brightness without the flash
	baseCore: number, -- core Beam brightness without the flash
	baseGlowWidth: number, -- CHANGED (Effects v2): glow Width0 without the flicker
	lightOn: boolean, -- CHANGED (Effects v2): holds one of the frame's light budget
	seed: number, -- CHANGED (Effects v2): flicker phase
}

type ModelState = {
	plumes: { [number]: Plume },
	-- blocks that exist but have no Exhaust attachment (not engines), cached so they are not searched again
	nonEngines: { [number]: true },
	fresh: boolean, -- CHANGED (Phase 10): true until the first update finished (no ignition flash then)
}

local Plumes = {}

local states: { [Model]: ModelState } = setmetatable({}, { __mode = "k" }) :: any
-- CHANGED (Effects v2): the tier's settings (High until Render/Effects configures them) and the frame's lights
local settings: Settings = { rateScale = 1, lights = 0, halo = true, machDiamonds = true, flicker = true }
local settingsVersion = 0
local lightsUsed = 0

local function destroyPlume(plume: Plume)
	plume.emitter:Destroy()
	plume.core:Destroy()
	plume.glow:Destroy()
	plume.halo:Destroy()
	plume.diamonds:Destroy()
	plume.light:Destroy()
	plume.tip:Destroy()
	plume.coreTip:Destroy()
	plume.haloTip:Destroy()
	plume.diamondTip:Destroy()
end

-- CHANGED (Phase 10): a NumberSequence from base keypoints with `extra` transparency added (clamped to 1).
local function fadedSequence(keys: { { number } }, extra: number): NumberSequence
	local points = table.create(#keys)
	for index, key in keys do
		points[index] = NumberSequenceKeypoint.new(key[1], math.min(key[2] + extra * (1 - key[2]), 1))
	end
	return NumberSequence.new(points)
end

local function findExhaust(model: Model, blockId: number): Attachment?
	local block = model:FindFirstChild("Block_" .. blockId)
	if not block then
		return nil
	end
	local bounds = block:FindFirstChild("Bounds")
	if not bounds or not bounds:IsA("BasePart") then
		return nil
	end
	local exhaust = bounds:FindFirstChild(EXHAUST_NAME)
	if exhaust and exhaust:IsA("Attachment") then
		return exhaust
	end
	return nil
end

-- CHANGED (Phase 10): solid boosters by part (Engine.Throttleable = false), with the old shape test as fallback.
local function isSolid(exhaust: Attachment, size: Vector3, diameter: number): boolean
	local bounds = exhaust.Parent
	local block = if bounds then bounds.Parent else nil
	local partId = if block then block:GetAttribute("PartId") else nil
	local def = if type(partId) == "string" then Parts.find(partId) else nil
	if def and def.Engine then
		return not def.Engine.Throttleable
	end
	return size.Y > diameter * BOOSTER_ASPECT
end

local function createPlume(exhaust: Attachment, modelScale: number, blockId: number): Plume
	local bounds = exhaust.Parent :: BasePart
	local size = bounds.Size / math.max(modelScale, 1e-3)
	local diameter = math.max(math.min(size.X, size.Z), 0.5)
	local solid = isSolid(exhaust, size, diameter)

	local function tipAttachment(name: string): Attachment
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.CFrame = exhaust.CFrame
		attachment.Parent = bounds
		return attachment
	end
	local tip = tipAttachment(TIP_NAME)
	local coreTip = tipAttachment(CORE_TIP_NAME)
	local haloTip = tipAttachment(HALO_TIP_NAME)
	local diamondTip = tipAttachment(DIAMOND_TIP_NAME)

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = EMITTER_NAME
	emitter.Enabled = false
	emitter.Texture = PARTICLE_TEXTURE
	emitter.EmissionDirection = Enum.NormalId.Top -- the attachment's UpVector = down the nozzle
	emitter.LockedToPart = true
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Color = if solid then PARTICLE_COLOR_SOLID else PARTICLE_COLOR
	emitter.Transparency = fadedSequence(PARTICLE_TRANSPARENCY_KEYS, 0)
	emitter.Lifetime = if solid then PARTICLE_LIFETIME_SOLID else PARTICLE_LIFETIME
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Drag = 1.5
	emitter.ZOffset = 0.5
	emitter.Rate = 0
	emitter.Parent = exhaust

	local function beam(name: string, tipAttachment: Attachment): Beam
		local b = Instance.new("Beam")
		b.Name = name
		b.Enabled = false
		b.Attachment0 = exhaust
		b.Attachment1 = tipAttachment
		b.FaceCamera = true
		b.LightEmission = 1
		b.LightInfluence = 0
		b.Segments = BEAM_SEGMENTS
		b.CurveSize0 = 0
		b.CurveSize1 = 0
		b.Parent = exhaust
		return b
	end
	local core = beam(CORE_NAME, coreTip)
	local glow = beam(GLOW_NAME, tip)
	local halo = beam(HALO_NAME, haloTip) -- CHANGED (Effects v2)
	halo.Brightness = HALO_BRIGHTNESS
	halo.Transparency = fadedSequence(HALO_TRANSPARENCY_KEYS, 0)
	local diamonds = beam(DIAMOND_NAME, diamondTip) -- CHANGED (Effects v2)
	diamonds.Color = DIAMOND_COLOR
	diamonds.Brightness = DIAMOND_BRIGHTNESS
	diamonds.ZOffset = 0.2 -- drawn over the core

	local light = Instance.new("PointLight")
	light.Name = LIGHT_NAME
	light.Enabled = false
	light.Color = if solid then LIGHT_COLOR_SOLID else LIGHT_COLOR
	light.Shadows = false
	light.Brightness = 0
	light.Parent = exhaust

	return {
		exhaust = exhaust,
		tip = tip,
		coreTip = coreTip,
		haloTip = haloTip,
		diamondTip = diamondTip,
		emitter = emitter,
		core = core,
		glow = glow,
		halo = halo,
		diamonds = diamonds,
		light = light,
		diameter = diameter,
		solid = solid,
		throttle = 0,
		shown = 0,
		vacuum = -1,
		colorVacuum = -1,
		scale = modelScale,
		version = -1,
		flash = 0,
		baseLight = 0,
		baseCore = 0,
		baseGlowWidth = 0,
		lightOn = false,
		seed = (blockId * 1.618) % 6.283,
	}
end

-- CHANGED (Phase 10): a transition event at the nozzle, in workspace.
local function event(plume: Plume, kind: "Ignite" | "Cutoff", modelScale: number): PlumeEvent
	local world = plume.exhaust.WorldCFrame
	return {
		kind = kind,
		position = world.Position,
		direction = world.UpVector,
		diameter = plume.diameter * modelScale,
		solid = plume.solid,
	}
end

local function switchOff(plume: Plume, modelScale: number, events: { PlumeEvent }?)
	if plume.throttle <= 0 then
		return
	end
	plume.throttle = 0
	plume.shown = 0 -- CHANGED (Effects v2)
	plume.flash = 0
	plume.emitter.Enabled = false -- live particles finish their short lifetime
	plume.core.Enabled = false
	plume.glow.Enabled = false
	plume.halo.Enabled = false -- CHANGED (Effects v2)
	plume.diamonds.Enabled = false -- CHANGED (Effects v2)
	plume.light.Enabled = false
	plume.lightOn = false -- CHANGED (Effects v2)
	if events then
		table.insert(events, event(plume, "Cutoff", modelScale))
	end
end

-- CHANGED (Effects v2): core / glow / halo colours for a vacuum factor (only rebuilt when it moved).
local function applyColors(plume: Plume, vacuum: number)
	if plume.colorVacuum >= 0 and math.abs(vacuum - plume.colorVacuum) <= COLOR_VACUUM_EPSILON then
		return
	end
	plume.colorVacuum = vacuum
	local coreTip, glowStart, glowEnd = EffectsMath.plumeTint(vacuum, plume.solid)
	local white = if plume.solid then CORE_WHITE_SOLID else CORE_WHITE
	plume.core.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, white),
		ColorSequenceKeypoint.new(CORE_WHITE_AT, white:Lerp(coreTip, 0.35)),
		ColorSequenceKeypoint.new(1, coreTip),
	})
	local glowColor = ColorSequence.new(glowStart, glowEnd)
	plume.glow.Color = glowColor
	plume.halo.Color = glowColor
end

-- CHANGED (Phase 10): the shape now depends on the air pressure (EffectsMath.plumeShape). Returns whether any
-- property was written, and whether the plume just lit.
-- CHANGED (Effects v2): + colours, halo, shock diamonds, tier settings (a new configuration forces a rewrite).
local function apply(plume: Plume, throttle: number, pressure: number, modelScale: number): (boolean, boolean)
	local wasOn = plume.throttle > 0
	local rescaled = math.abs(modelScale - plume.scale) > SCALE_EPSILON * plume.scale
	local vacuum = EffectsMath.vacuumFactor(pressure)
	if
		wasOn
		and not rescaled
		and plume.version == settingsVersion
		and math.abs(throttle - plume.throttle) <= THROTTLE_EPSILON
		and math.abs(vacuum - plume.vacuum) <= VACUUM_EPSILON
	then
		return false, false
	end
	plume.throttle = throttle
	plume.vacuum = vacuum
	plume.scale = modelScale
	plume.version = settingsVersion

	local shape = EffectsMath.plumeShape(throttle, pressure, plume.solid)
	local d = plume.diameter * modelScale -- scaled nozzle diameter, studs
	local k = (plume.diameter / REFERENCE_DIAMETER) * modelScale -- length factor

	-- Particles
	local emitter = plume.emitter
	local rate = PARTICLE_RATE_MIN + (PARTICLE_RATE_MAX - PARTICLE_RATE_MIN) * throttle
	emitter.Rate = rate * settings.rateScale * (if plume.solid then PARTICLE_RATE_SOLID_MULT else 1)
	local speed = shape.particleSpeed * k
	emitter.Speed = NumberRange.new(speed * 0.85, speed)
	emitter.SpreadAngle = Vector2.new(shape.spreadDeg, shape.spreadDeg)
	local sizeK = d * shape.particleSize
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, sizeK * PARTICLE_SIZE_START),
		NumberSequenceKeypoint.new(0.4, sizeK * PARTICLE_SIZE_MID),
		NumberSequenceKeypoint.new(1, sizeK * PARTICLE_SIZE_END),
	})
	emitter.Transparency = fadedSequence(
		if plume.solid then PARTICLE_TRANSPARENCY_KEYS_SOLID else PARTICLE_TRANSPARENCY_KEYS_LIQUID,
		shape.fade
	)
	if not wasOn then
		emitter.Enabled = true
	end

	-- Beam flame: the tips ride along the exhaust direction (the attachment's local +Y)
	local length = shape.length * k
	local coreLength = length * shape.coreLength
	plume.tip.CFrame = plume.exhaust.CFrame * CFrame.new(0, length, 0)
	plume.coreTip.CFrame = plume.exhaust.CFrame * CFrame.new(0, coreLength, 0)
	-- A bright narrow core inside a wider, softer glow (an opening cone in vacuum).
	plume.core.Width0 = d * shape.coreWidth0
	plume.core.Width1 = d * shape.coreWidth1
	plume.baseGlowWidth = d * shape.glowWidth0
	plume.glow.Width0 = plume.baseGlowWidth
	plume.glow.Width1 = d * shape.glowWidth1
	plume.core.Transparency = fadedSequence(CORE_TRANSPARENCY_KEYS, shape.fade)
	plume.glow.Transparency = fadedSequence(GLOW_TRANSPARENCY_KEYS, shape.fade)
	plume.glow.Brightness = shape.glowBrightness
	plume.baseCore = shape.coreBrightness
	applyColors(plume, vacuum)
	if not wasOn then
		plume.core.Enabled = true
		plume.glow.Enabled = true
	end

	-- CHANGED (Effects v2): halo (Medium+): wider and fainter than the glow, a little shorter
	if settings.halo then
		plume.haloTip.CFrame = plume.exhaust.CFrame * CFrame.new(0, length * HALO_LENGTH, 0)
		plume.halo.Width0 = d * shape.glowWidth0 * HALO_WIDTH_MULT
		plume.halo.Width1 = d * shape.glowWidth1 * HALO_WIDTH_MULT
		plume.halo.Transparency = fadedSequence(HALO_TRANSPARENCY_KEYS, shape.fade)
	end
	plume.halo.Enabled = settings.halo

	-- CHANGED (Effects v2): shock diamonds along the core, liquid engines in thick air only (Medium+)
	local diamondStrength = 0
	if settings.machDiamonds and not plume.solid then
		local thick = 1 - EffectsMath.smoothstep(DIAMOND_VACUUM_START, DIAMOND_VACUUM_END, vacuum)
		diamondStrength = thick * (0.5 + 0.5 * math.sqrt(throttle))
	end
	if diamondStrength > DIAMOND_MIN_STRENGTH then
		local diamondLength = coreLength * DIAMOND_LENGTH
		plume.diamondTip.CFrame = plume.exhaust.CFrame * CFrame.new(0, diamondLength, 0)
		plume.diamonds.Width0 = d * DIAMOND_WIDTH0
		plume.diamonds.Width1 = d * DIAMOND_WIDTH1
		local count = math.floor(diamondLength / math.max(d * DIAMOND_SPACING, 1e-3))
		local keys = EffectsMath.machDiamondKeys(count, diamondStrength)
		local points = table.create(#keys)
		for index, key in keys do
			points[index] = NumberSequenceKeypoint.new(key[1], key[2])
		end
		plume.diamonds.Transparency = NumberSequence.new(points)
		plume.diamonds.Enabled = true
	else
		plume.diamonds.Enabled = false
	end

	-- Light
	plume.baseLight = shape.light
	plume.light.Range = math.min(d * LIGHT_RANGE, LIGHT_RANGE_MAX)
	return true, not wasOn
end

-- CHANGED (Phase 10): light and core brightness, including the decaying ignition flash.
-- CHANGED (Effects v2): + the flicker (Medium+) on the core brightness, glow width and light.
local function applyBrightness(plume: Plume, dt: number, now: number)
	local f = 0
	if plume.flash > 0 then
		plume.flash = math.max(plume.flash - dt, 0)
		f = plume.flash / FLASH_TIME
		f *= f
	end
	local wobble = 1
	if settings.flicker then
		wobble = EffectsMath.flicker(now, plume.seed, FLICKER_BRIGHTNESS)
		plume.glow.Width0 = plume.baseGlowWidth * EffectsMath.flicker(now, plume.seed + 2.1, FLICKER_WIDTH)
	end
	if plume.lightOn then
		plume.light.Brightness = (plume.baseLight + FLASH_LIGHT * f) * wobble
	end
	plume.core.Brightness = plume.baseCore * (1 + FLASH_CORE * f) * wobble
end

--============================================================================
-- API
--============================================================================

--[[
	burning: blockId -> throttle 0..1 for engines currently producing thrust; every other plume is switched off.
	CHANGED (Phase 10): pressure = air pressure ratio at the craft (0 vacuum .. 1 sea level), dt = frame time (for
	the ignition flash), events = optional list that receives "Ignite" / "Cutoff" transitions.
]]
function Plumes.update(
	model: Model,
	burning: { [number]: number },
	pressure: number,
	dt: number,
	events: { PlumeEvent }?
)
	local state = states[model]
	if not state then
		state = { plumes = {}, nonEngines = {}, fresh = true }
		states[model] = state
	end
	local modelScale = model:GetScale()
	local p = math.clamp(pressure, 0, 1)
	local now = os.clock()

	-- Switch off (or drop, when the block is gone) plumes that are not burning this frame.
	local plumes = state.plumes
	for blockId, plume in plumes do
		if plume.exhaust.Parent == nil or plume.emitter.Parent == nil then
			destroyPlume(plume)
			plumes[blockId] = nil
		elseif burning[blockId] == nil or burning[blockId] <= MIN_THROTTLE then
			switchOff(plume, modelScale, events)
		end
	end

	for blockId, throttle in burning do
		if throttle <= MIN_THROTTLE then
			continue
		end
		local plume = plumes[blockId]
		if plume == nil and not state.nonEngines[blockId] then
			local exhaust = findExhaust(model, blockId)
			if exhaust then
				plume = createPlume(exhaust, modelScale, blockId)
				plumes[blockId] = plume
			elseif model:FindFirstChild("Block_" .. blockId) then
				state.nonEngines[blockId] = true
			end
		end
		if plume then
			-- CHANGED (Effects v2): the flame eases to the throttle (a fresh model shows it at once)
			local target = math.clamp(throttle, 0, 1)
			if plume.throttle <= 0 then
				plume.shown = if state.fresh then target else target * IGNITION_START
			else
				local tau = if target > plume.shown then THROTTLE_RISE_S else THROTTLE_FALL_S
				plume.shown += (target - plume.shown) * (1 - math.exp(-math.max(dt, 0) / tau))
			end
			local changed, ignited = apply(plume, math.max(plume.shown, MIN_THROTTLE * 2), p, modelScale)
			if ignited and not state.fresh then
				plume.flash = FLASH_TIME
				plume.emitter:Emit(math.max(math.round(FLASH_PARTICLES * settings.rateScale), 1))
				if events then
					table.insert(events, event(plume, "Ignite", modelScale))
				end
			end
			-- CHANGED (Effects v2): one of the frame's PointLights, while the budget lasts (High only)
			local wantLight = lightsUsed < settings.lights
			if wantLight then
				lightsUsed += 1
			end
			if wantLight ~= plume.lightOn then
				plume.lightOn = wantLight
				plume.light.Enabled = wantLight
				changed = true
			end
			-- a steady burn without a flash (and without flicker) writes nothing
			if changed or plume.flash > 0 or settings.flicker then
				applyBrightness(plume, dt, now)
			end
		end
	end
	state.fresh = false
end

-- Destroys every plume instance created for the model (e.g. when the craft is despawned or rebuilt).
function Plumes.clear(model: Model)
	local state = states[model]
	if not state then
		return
	end
	states[model] = nil
	for _, plume in state.plumes do
		destroyPlume(plume)
	end
end

-- CHANGED (Phase 10): number of plumes burning right now (F3).
function Plumes.litCount(): number
	local count = 0
	for model, state in states do
		if model.Parent ~= nil then
			for _, plume in state.plumes do
				if plume.throttle > 0 then
					count += 1
				end
			end
		end
	end
	return count
end

-- CHANGED (Effects v2): the Render/Quality tier's settings; every plume is rewritten on its next update.
function Plumes.configure(newSettings: Settings)
	settings = table.clone(newSettings)
	settingsVersion += 1
end

-- CHANGED (Effects v2): call once per frame before the updates (resets the PointLight budget).
function Plumes.beginFrame()
	lightsUsed = 0
end

return table.freeze(Plumes)
