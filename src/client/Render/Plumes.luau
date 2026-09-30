--!strict
--[[
	Plumes
	Engine exhaust effects (spec 7.4): a fiery ParticleEmitter, a two-layer Beam flame (bright core + soft outer
	glow) and an orange PointLight per burning engine.

	update(model, burning)  burning = { [blockId] = throttle 0..1 } for the engines producing thrust right now;
	                        every other engine of the model that has a plume is switched off.
	clear(model)            destroys every plume instance created for the model and forgets it.

	Engine blocks are children of the model named "Block_<id>"; each has Bounds.Exhaust (PartVisuals), an
	Attachment at the nozzle exit whose UpVector points down the exhaust. Everything is created lazily under that
	attachment (the flame tip is a sibling attachment under Bounds, pushed along the exhaust direction) and then only
	toggled / re-tuned, never recreated per frame. Properties are only written when the throttle moved by more
	than THROTTLE_EPSILON (or the model was rescaled with Model:ScaleTo), so a steady burn costs a table lookup.

	Sizes derive from the engine's nozzle diameter (min of the Bounds X/Z size in unscaled studs: engine_s 4,
	engine_l 8, srb_s 4) and are multiplied by Model:GetScale(), so client-side cosmetic copies that are shrunk
	with ScaleTo get proportional plumes. Works for any model: the local craft's real model or cosmetic copies.
]]

--============================================================================
-- Tunables
--============================================================================
local THROTTLE_EPSILON = 0.02 -- only rewrite properties when the throttle moved more than this
local SCALE_EPSILON = 0.01 -- relative Model:GetScale() change that forces a rewrite
local MIN_THROTTLE = 0.001 -- at or below this an engine counts as off
local REFERENCE_DIAMETER = 4 -- studs; engine_s nozzle, all "per diameter" factors below are relative to this
local BOOSTER_ASPECT = 1.8 -- Bounds height / diameter above which a block is treated as a solid booster
local BOOSTER_LENGTH_MULT = 1.35 -- boosters get a longer, fatter flame
-- Particles
local PARTICLE_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local PARTICLE_RATE_MAX = 90 -- particles/s at full throttle
local PARTICLE_RATE_MIN = 25 -- particles/s at minimum throttle
local PARTICLE_SPEED_MIN = 30 -- studs/s at minimum throttle (engine_s, scale 1)
local PARTICLE_SPEED_MAX = 58 -- studs/s at full throttle
local PARTICLE_LIFETIME = NumberRange.new(0.22, 0.4)
local PARTICLE_SPREAD_DEG = 7
local PARTICLE_SIZE_START = 0.45 -- x diameter
local PARTICLE_SIZE_MID = 0.8
local PARTICLE_SIZE_END = 1.3
local PARTICLE_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 250, 220)),
	ColorSequenceKeypoint.new(0.2, Color3.fromRGB(255, 214, 90)),
	ColorSequenceKeypoint.new(0.55, Color3.fromRGB(255, 128, 32)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 44, 20)),
})
local PARTICLE_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.15),
	NumberSequenceKeypoint.new(0.5, 0.35),
	NumberSequenceKeypoint.new(1, 1),
})
-- Beam flame
local FLAME_LENGTH_MIN = 3 -- studs at minimum throttle (engine_s, scale 1)
local FLAME_LENGTH_MAX = 9 -- studs at full throttle
local CORE_WIDTH0 = 0.55 -- x diameter, at the nozzle
local CORE_WIDTH1 = 0.08 -- x diameter, at the tip
local GLOW_WIDTH0 = 0.85
local GLOW_WIDTH1 = 0.3
local BEAM_SEGMENTS = 10
local CORE_COLOR = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 255, 240)),
	ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 226, 120)),
	ColorSequenceKeypoint.new(0.7, Color3.fromRGB(255, 150, 40)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 90, 20)),
})
local CORE_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.05),
	NumberSequenceKeypoint.new(0.6, 0.3),
	NumberSequenceKeypoint.new(1, 1),
})
local GLOW_COLOR = ColorSequence.new(Color3.fromRGB(255, 170, 60), Color3.fromRGB(255, 80, 20))
local GLOW_TRANSPARENCY = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.55),
	NumberSequenceKeypoint.new(0.5, 0.75),
	NumberSequenceKeypoint.new(1, 1),
})
-- Light
local LIGHT_COLOR = Color3.fromRGB(255, 150, 60)
local LIGHT_BRIGHTNESS_MAX = 3
local LIGHT_RANGE = 4 -- x diameter
local LIGHT_RANGE_MAX = 60 -- studs (Roblox caps PointLight.Range at 60)
-- Instance names
local EXHAUST_NAME = "Exhaust"
local TIP_NAME = "PlumeTip"
local EMITTER_NAME = "PlumeParticles"
local CORE_NAME = "PlumeCore"
local GLOW_NAME = "PlumeGlow"
local LIGHT_NAME = "PlumeLight"
--============================================================================

type Plume = {
	exhaust: Attachment,
	tip: Attachment,
	emitter: ParticleEmitter,
	core: Beam,
	glow: Beam,
	light: PointLight,
	diameter: number, -- unscaled nozzle diameter, studs
	lengthMult: number,
	throttle: number, -- last applied throttle (0 = off)
	scale: number, -- Model:GetScale() the properties were last written for
}

type ModelState = {
	plumes: { [number]: Plume },
	-- blocks that exist but have no Exhaust attachment (not engines), cached so they are not searched again
	nonEngines: { [number]: true },
}

local Plumes = {}

local states: { [Model]: ModelState } = setmetatable({}, { __mode = "k" }) :: any

local function destroyPlume(plume: Plume)
	plume.emitter:Destroy()
	plume.core:Destroy()
	plume.glow:Destroy()
	plume.light:Destroy()
	plume.tip:Destroy()
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

local function createPlume(exhaust: Attachment, modelScale: number): Plume
	local bounds = exhaust.Parent :: BasePart
	local size = bounds.Size / math.max(modelScale, 1e-3)
	local diameter = math.max(math.min(size.X, size.Z), 0.5)
	local lengthMult = if size.Y > diameter * BOOSTER_ASPECT then BOOSTER_LENGTH_MULT else 1

	local tip = Instance.new("Attachment")
	tip.Name = TIP_NAME
	tip.CFrame = exhaust.CFrame
	tip.Parent = bounds

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = EMITTER_NAME
	emitter.Enabled = false
	emitter.Texture = PARTICLE_TEXTURE
	emitter.EmissionDirection = Enum.NormalId.Top -- the attachment's UpVector = down the nozzle
	emitter.LockedToPart = true
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Color = PARTICLE_COLOR
	emitter.Transparency = PARTICLE_TRANSPARENCY
	emitter.Lifetime = PARTICLE_LIFETIME
	emitter.SpreadAngle = Vector2.new(PARTICLE_SPREAD_DEG, PARTICLE_SPREAD_DEG)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	emitter.Drag = 1.5
	emitter.ZOffset = 0.5
	emitter.Rate = 0
	emitter.Parent = exhaust

	local function beam(name: string, color: ColorSequence, transparency: NumberSequence, brightness: number): Beam
		local b = Instance.new("Beam")
		b.Name = name
		b.Enabled = false
		b.Attachment0 = exhaust
		b.Attachment1 = tip
		b.FaceCamera = true
		b.LightEmission = 1
		b.LightInfluence = 0
		b.Brightness = brightness
		b.Segments = BEAM_SEGMENTS
		b.CurveSize0 = 0
		b.CurveSize1 = 0
		b.Color = color
		b.Transparency = transparency
		b.Parent = exhaust
		return b
	end
	local core = beam(CORE_NAME, CORE_COLOR, CORE_TRANSPARENCY, 3)
	local glow = beam(GLOW_NAME, GLOW_COLOR, GLOW_TRANSPARENCY, 1.5)

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
		emitter = emitter,
		core = core,
		glow = glow,
		light = light,
		diameter = diameter,
		lengthMult = lengthMult,
		throttle = 0,
		scale = modelScale,
	}
end

local function switchOff(plume: Plume)
	if plume.throttle <= 0 then
		return
	end
	plume.throttle = 0
	plume.emitter.Enabled = false -- live particles finish their short lifetime
	plume.core.Enabled = false
	plume.glow.Enabled = false
	plume.light.Enabled = false
end

local function apply(plume: Plume, throttle: number, modelScale: number)
	if throttle <= MIN_THROTTLE then
		switchOff(plume)
		return
	end
	local wasOn = plume.throttle > 0
	local rescaled = math.abs(modelScale - plume.scale) > SCALE_EPSILON * plume.scale
	if wasOn and not rescaled and math.abs(throttle - plume.throttle) <= THROTTLE_EPSILON then
		return
	end
	plume.throttle = throttle
	plume.scale = modelScale

	local d = plume.diameter * modelScale -- scaled nozzle diameter, studs
	local k = (plume.diameter / REFERENCE_DIAMETER) * modelScale * plume.lengthMult -- length factor
	local burn = math.sqrt(throttle) -- low throttles still read as a flame

	-- Particles
	local emitter = plume.emitter
	emitter.Rate = PARTICLE_RATE_MIN + (PARTICLE_RATE_MAX - PARTICLE_RATE_MIN) * throttle
	local speed = (PARTICLE_SPEED_MIN + (PARTICLE_SPEED_MAX - PARTICLE_SPEED_MIN) * throttle) * k
	emitter.Speed = NumberRange.new(speed * 0.85, speed)
	local sizeK = d * (0.6 + 0.4 * burn) * (if plume.lengthMult > 1 then 1.15 else 1)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, sizeK * PARTICLE_SIZE_START),
		NumberSequenceKeypoint.new(0.4, sizeK * PARTICLE_SIZE_MID),
		NumberSequenceKeypoint.new(1, sizeK * PARTICLE_SIZE_END),
	})
	if not wasOn then
		emitter.Enabled = true
	end

	-- Beam flame: the tip rides along the exhaust direction (the attachment's local +Y)
	local length = (FLAME_LENGTH_MIN + (FLAME_LENGTH_MAX - FLAME_LENGTH_MIN) * throttle) * k
	plume.tip.CFrame = plume.exhaust.CFrame * CFrame.new(0, length, 0)
	-- Both beams share the tip: a bright narrow core inside a wider, softer glow.
	plume.core.Width0 = d * CORE_WIDTH0 * (0.7 + 0.3 * burn)
	plume.core.Width1 = d * CORE_WIDTH1
	plume.glow.Width0 = d * GLOW_WIDTH0 * (0.7 + 0.3 * burn)
	plume.glow.Width1 = d * GLOW_WIDTH1 * burn
	if not wasOn then
		plume.core.Enabled = true
		plume.glow.Enabled = true
	end

	-- Light
	plume.light.Brightness = LIGHT_BRIGHTNESS_MAX * burn
	plume.light.Range = math.min(d * LIGHT_RANGE, LIGHT_RANGE_MAX)
	if not wasOn then
		plume.light.Enabled = true
	end
end

--============================================================================
-- API
--============================================================================

-- burning: blockId -> throttle 0..1 for engines currently producing thrust; every other plume is switched off.
function Plumes.update(model: Model, burning: { [number]: number })
	local state = states[model]
	if not state then
		state = { plumes = {}, nonEngines = {} }
		states[model] = state
	end
	local modelScale = model:GetScale()

	-- Switch off (or drop, when the block is gone) plumes that are not burning this frame.
	local plumes = state.plumes
	for blockId, plume in plumes do
		if plume.exhaust.Parent == nil or plume.emitter.Parent == nil then
			destroyPlume(plume)
			plumes[blockId] = nil
		elseif burning[blockId] == nil then
			switchOff(plume)
		end
	end

	for blockId, throttle in burning do
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
			apply(plume, math.clamp(throttle, 0, 1), modelScale)
		end
	end
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

return table.freeze(Plumes)
