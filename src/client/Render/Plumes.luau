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
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Parts = require(ReplicatedStorage.Shared.Config.Parts) -- CHANGED (Phase 10): solid booster detection
local EffectsMath = require(script.Parent.EffectsMath) -- CHANGED (Phase 10)

--============================================================================
-- Tunables
--============================================================================
local THROTTLE_EPSILON = 0.02 -- only rewrite properties when the throttle moved more than this
local PRESSURE_EPSILON = 0.02 -- CHANGED (Phase 10): ... or the air pressure ratio moved more than this
local SCALE_EPSILON = 0.01 -- relative Model:GetScale() change that forces a rewrite
local MIN_THROTTLE = 0.001 -- at or below this an engine counts as off
local REFERENCE_DIAMETER = 4 -- studs; engine_s nozzle, all "per diameter" factors below are relative to this
local BOOSTER_ASPECT = 1.8 -- fallback: Bounds height / diameter above which a block is treated as a solid booster
-- Particles
local PARTICLE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local PARTICLE_RATE_MAX = 90 -- particles/s at full throttle
local PARTICLE_RATE_MIN = 25 -- particles/s at minimum throttle
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
local PARTICLE_COLOR_SOLID = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 252, 230)),
	ColorSequenceKeypoint.new(0.18, Color3.fromRGB(255, 226, 120)),
	ColorSequenceKeypoint.new(0.45, Color3.fromRGB(255, 150, 50)),
	ColorSequenceKeypoint.new(0.75, Color3.fromRGB(150, 110, 90)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(110, 104, 100)),
})
local PARTICLE_LIFETIME_SOLID = NumberRange.new(0.3, 0.55)
-- Beam flame
local BEAM_SEGMENTS = 10
local CORE_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 240)),
	ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 226, 120)),
	ColorSequenceKeypoint.new(0.7, Color3.fromRGB(255, 150, 40)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 90, 20)),
})
local GLOW_COLOR = ColorSequence.new(Color3.fromRGB(255, 170, 60), Color3.fromRGB(255, 80, 20))
-- CHANGED (Phase 10): the vacuum glow is paler and bluer at its far end
local GLOW_COLOR_VACUUM = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 190, 110)),
	ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 160, 120)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 170, 255)),
})
local VACUUM_COLOR_THRESHOLD = 0.6 -- EffectsMath.vacuumFactor above which the vacuum glow colours are used
-- Base transparency keypoints (time, transparency); EffectsMath.plumeShape's fade is added on top
local CORE_TRANSPARENCY_KEYS = { { 0, 0.05 }, { 0.6, 0.3 }, { 1, 1 } }
local GLOW_TRANSPARENCY_KEYS = { { 0, 0.55 }, { 0.5, 0.75 }, { 1, 1 } }
local PARTICLE_TRANSPARENCY_KEYS = { { 0, 0.15 }, { 0.5, 0.35 }, { 1, 1 } }
-- Light
local LIGHT_COLOR = Color3.fromRGB(255, 150, 60)
local LIGHT_RANGE = 4 -- x diameter
local LIGHT_RANGE_MAX = 60 -- studs (Roblox caps PointLight.Range at 60)
-- CHANGED (Phase 10): ignition flash
local FLASH_TIME = 0.35 -- s
local FLASH_LIGHT = 6 -- extra PointLight brightness at the start of the flash
local FLASH_CORE = 1.5 -- extra core brightness multiplier at the start of the flash
local FLASH_PARTICLES = 14 -- flame particles emitted at ignition
-- Instance names
local EXHAUST_NAME = "Exhaust"
local TIP_NAME = "PlumeTip"
local CORE_TIP_NAME = "PlumeCoreTip" -- CHANGED (Phase 10)
local EMITTER_NAME = "PlumeParticles"
local CORE_NAME = "PlumeCore"
local GLOW_NAME = "PlumeGlow"
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

type Plume = {
	exhaust: Attachment,
	tip: Attachment,
	coreTip: Attachment, -- CHANGED (Phase 10): the core's own tip (shorter than the glow in vacuum)
	emitter: ParticleEmitter,
	core: Beam,
	glow: Beam,
	light: PointLight,
	diameter: number, -- unscaled nozzle diameter, studs
	solid: boolean, -- CHANGED (Phase 10): solid booster (was a length multiplier from the block's shape)
	throttle: number, -- last applied throttle (0 = off)
	pressure: number, -- CHANGED (Phase 10): last applied pressure ratio
	scale: number, -- Model:GetScale() the properties were last written for
	flash: number, -- CHANGED (Phase 10): seconds of ignition flash left
	baseLight: number, -- PointLight brightness without the flash
	baseCore: number, -- core Beam brightness without the flash
	vacuumColors: boolean, -- the glow currently uses GLOW_COLOR_VACUUM
}

type ModelState = {
	plumes: { [number]: Plume },
	-- blocks that exist but have no Exhaust attachment (not engines), cached so they are not searched again
	nonEngines: { [number]: true },
	fresh: boolean, -- CHANGED (Phase 10): true until the first update finished (no ignition flash then)
}

local Plumes = {}

local states: { [Model]: ModelState } = setmetatable({}, { __mode = "k" }) :: any

local function destroyPlume(plume: Plume)
	plume.emitter:Destroy()
	plume.core:Destroy()
	plume.glow:Destroy()
	plume.light:Destroy()
	plume.tip:Destroy()
	plume.coreTip:Destroy()
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

local function createPlume(exhaust: Attachment, modelScale: number): Plume
	local bounds = exhaust.Parent :: BasePart
	local size = bounds.Size / math.max(modelScale, 1e-3)
	local diameter = math.max(math.min(size.X, size.Z), 0.5)
	local solid = isSolid(exhaust, size, diameter)

	local tip = Instance.new("Attachment")
	tip.Name = TIP_NAME
	tip.CFrame = exhaust.CFrame
	tip.Parent = bounds
	local coreTip = Instance.new("Attachment")
	coreTip.Name = CORE_TIP_NAME
	coreTip.CFrame = exhaust.CFrame
	coreTip.Parent = bounds

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

	local function beam(name: string, tipAttachment: Attachment, color: ColorSequence): Beam
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
		b.Color = color
		b.Parent = exhaust
		return b
	end
	local core = beam(CORE_NAME, coreTip, CORE_COLOR)
	local glow = beam(GLOW_NAME, tip, GLOW_COLOR)

	local light = Instance.new("PointLight")
	light.Name = LIGHT_NAME
	light.Enabled = false
	light.Color = LIGHT_COLOR
	light.Shadows = false
	light.Brightness = 0
	light.Parent = exhaust

	return {
		exhaust = exhaust,
		tip = tip,
		coreTip = coreTip,
		emitter = emitter,
		core = core,
		glow = glow,
		light = light,
		diameter = diameter,
		solid = solid,
		throttle = 0,
		pressure = -1,
		scale = modelScale,
		flash = 0,
		baseLight = 0,
		baseCore = 0,
		vacuumColors = false,
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
	plume.flash = 0
	plume.emitter.Enabled = false -- live particles finish their short lifetime
	plume.core.Enabled = false
	plume.glow.Enabled = false
	plume.light.Enabled = false
	if events then
		table.insert(events, event(plume, "Cutoff", modelScale))
	end
end

-- CHANGED (Phase 10): the shape now depends on the air pressure (EffectsMath.plumeShape).
local function apply(plume: Plume, throttle: number, pressure: number, modelScale: number): boolean
	local wasOn = plume.throttle > 0
	local rescaled = math.abs(modelScale - plume.scale) > SCALE_EPSILON * plume.scale
	if
		wasOn
		and not rescaled
		and math.abs(throttle - plume.throttle) <= THROTTLE_EPSILON
		and math.abs(pressure - plume.pressure) <= PRESSURE_EPSILON
	then
		return false
	end
	plume.throttle = throttle
	plume.pressure = pressure
	plume.scale = modelScale

	local shape = EffectsMath.plumeShape(throttle, pressure, plume.solid)
	local d = plume.diameter * modelScale -- scaled nozzle diameter, studs
	local k = (plume.diameter / REFERENCE_DIAMETER) * modelScale -- length factor

	-- Particles
	local emitter = plume.emitter
	emitter.Rate = PARTICLE_RATE_MIN + (PARTICLE_RATE_MAX - PARTICLE_RATE_MIN) * throttle
	local speed = shape.particleSpeed * k
	emitter.Speed = NumberRange.new(speed * 0.85, speed)
	emitter.SpreadAngle = Vector2.new(shape.spreadDeg, shape.spreadDeg)
	local sizeK = d * shape.particleSize
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, sizeK * PARTICLE_SIZE_START),
		NumberSequenceKeypoint.new(0.4, sizeK * PARTICLE_SIZE_MID),
		NumberSequenceKeypoint.new(1, sizeK * PARTICLE_SIZE_END),
	})
	emitter.Transparency = fadedSequence(PARTICLE_TRANSPARENCY_KEYS, shape.fade)
	if not wasOn then
		emitter.Enabled = true
	end

	-- Beam flame: the tips ride along the exhaust direction (the attachment's local +Y)
	local length = shape.length * k
	plume.tip.CFrame = plume.exhaust.CFrame * CFrame.new(0, length, 0)
	plume.coreTip.CFrame = plume.exhaust.CFrame * CFrame.new(0, length * shape.coreLength, 0)
	-- A bright narrow core inside a wider, softer glow (an opening cone in vacuum).
	plume.core.Width0 = d * shape.coreWidth0
	plume.core.Width1 = d * shape.coreWidth1
	plume.glow.Width0 = d * shape.glowWidth0
	plume.glow.Width1 = d * shape.glowWidth1
	plume.core.Transparency = fadedSequence(CORE_TRANSPARENCY_KEYS, shape.fade)
	plume.glow.Transparency = fadedSequence(GLOW_TRANSPARENCY_KEYS, shape.fade)
	plume.glow.Brightness = shape.glowBrightness
	plume.baseCore = shape.coreBrightness
	local vacuumColors = EffectsMath.vacuumFactor(pressure) > VACUUM_COLOR_THRESHOLD
	if vacuumColors ~= plume.vacuumColors then
		plume.vacuumColors = vacuumColors
		plume.glow.Color = if vacuumColors then GLOW_COLOR_VACUUM else GLOW_COLOR
	end
	if not wasOn then
		plume.core.Enabled = true
		plume.glow.Enabled = true
	end

	-- Light
	plume.baseLight = shape.light
	plume.light.Range = math.min(d * LIGHT_RANGE, LIGHT_RANGE_MAX)
	if not wasOn then
		plume.light.Enabled = true
	end
	return not wasOn
end

-- CHANGED (Phase 10): light and core brightness, including the decaying ignition flash.
local function applyBrightness(plume: Plume, dt: number)
	local f = 0
	if plume.flash > 0 then
		plume.flash = math.max(plume.flash - dt, 0)
		f = plume.flash / FLASH_TIME
		f *= f
	end
	plume.light.Brightness = plume.baseLight + FLASH_LIGHT * f
	plume.core.Brightness = plume.baseCore * (1 + FLASH_CORE * f)
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
				plume = createPlume(exhaust, modelScale)
				plumes[blockId] = plume
			elseif model:FindFirstChild("Block_" .. blockId) then
				state.nonEngines[blockId] = true
			end
		end
		if plume then
			local ignited = apply(plume, math.clamp(throttle, 0, 1), p, modelScale)
			if ignited and not state.fresh then
				plume.flash = FLASH_TIME
				plume.emitter:Emit(FLASH_PARTICLES)
				if events then
					table.insert(events, event(plume, "Ignite", modelScale))
				end
			end
			applyBrightness(plume, dt)
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

return table.freeze(Plumes)
