--!strict
--[[
	EvaService (Phase 6, spec 7.9)
	The server side of an astronaut on EVA, besides the bubbles (BubbleService):
	  * the little JETPACK on his back: a server-built model welded to the torso (so every client sees it, and
	    PocketController hides it with the character in other pockets). Its attributes Thrust / Light say whether
	    the jetpack fires and the helmet light shines; clients turn the flame and the light on from those
	    (Render/EvaVisuals). It is added while the player is on EVA and removed when he sits down, goes home or dies.
	  * EvaInput (client -> server): ("Thrust" | "Light", on). Validated (types, on EVA, a jetpack to set) and
	    rate-limited (a token bucket: INPUT_RATE per second, INPUT_BURST at once); everything else is dropped.
	  * RESCUE: an astronaut whose pocket no longer exists, or whose character is outside his pocket's slot, for
	    RESCUE_S is sent back to his plot (never stuck in a pocket, never falling forever).
	"On EVA" = alive, not seated, in a pocket other than the base (BubbleService.isEva).
	Leaving the game needs nothing here: the character goes, and the empty solo pocket is released (PocketService).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local BubbleService = require(script.Parent.BubbleService)
local FlightService = require(script.Parent.FlightService)
local PocketService = require(script.Parent.PocketService)

--============================================================================
-- Tunables
--============================================================================
local CHECK_INTERVAL = 0.25 -- s between jetpack / rescue checks
local RESCUE_S = 5 -- s an astronaut may be lost (no pocket, or outside its slot) before he is sent home
local INPUT_RATE = 10 -- EvaInput messages per second, sustained
local INPUT_BURST = 20 -- ... and at once
local JETPACK_NAME = "EvaJetpack"
local PACK_SIZE = Vector3.new(1.6, 1.9, 0.8) -- studs
local TANK_SIZE = Vector3.new(1.8, 0.62, 0.62) -- cylinder: length along X, turned upright
local NOZZLE_SIZE = Vector3.new(0.4, 0.35, 0.4)
local LAMP_SIZE = Vector3.new(0.35, 0.35, 0.35)
local PACK_COLOR = Color3.fromRGB(236, 236, 232)
local TANK_COLOR = Color3.fromRGB(150, 155, 160)
local NOZZLE_COLOR = Color3.fromRGB(45, 45, 50)
local ACCENT_COLOR = Color3.fromRGB(230, 110, 30)
local LAMP_COLOR = Color3.fromRGB(255, 244, 214)
local FLAME_TEXTURE = "rbxasset://textures/particles/fire_main.dds"
local FLAME_COLOR = Color3.fromRGB(150, 200, 255)
local LIGHT_RANGE = 40 -- studs
local LIGHT_ANGLE = 70 -- degrees
local LIGHT_BRIGHTNESS = 3
local RESCUE_TEXT = "You drifted off into nowhere, so we brought you back to your plot"
--============================================================================

local EvaService = {}

local lostSince: { [Player]: number } = {}
local tokens: { [Player]: { amount: number, time: number } } = {}
local accumulator = 0

--============================================================================
-- The jetpack model
--============================================================================

local function passive(part: BasePart)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

local function weld(a: BasePart, b: BasePart)
	local joint = Instance.new("WeldConstraint")
	joint.Part0 = a
	joint.Part1 = b
	joint.Parent = b
end

-- Builds the jetpack around the identity (pack centre at the origin, its back toward +Z, up +Y). Not parented.
local function buildJetpack(): Model
	local model = Instance.new("Model")
	model.Name = JETPACK_NAME
	model:SetAttribute("Thrust", false)
	model:SetAttribute("Light", false)

	local pack = Instance.new("Part")
	pack.Name = "Pack"
	pack.Size = PACK_SIZE
	pack.Color = PACK_COLOR
	pack.Material = Enum.Material.SmoothPlastic
	pack.CFrame = CFrame.identity
	passive(pack)
	pack.Parent = model
	model.PrimaryPart = pack

	local stripe = Instance.new("Part")
	stripe.Name = "Stripe"
	stripe.Size = Vector3.new(PACK_SIZE.X + 0.02, 0.25, PACK_SIZE.Z + 0.02)
	stripe.Color = ACCENT_COLOR
	stripe.Material = Enum.Material.SmoothPlastic
	stripe.CFrame = CFrame.new(0, PACK_SIZE.Y * 0.25, 0)
	passive(stripe)
	stripe.Parent = model

	for _, side in { -1, 1 } do
		local tank = Instance.new("Part")
		tank.Name = if side < 0 then "TankLeft" else "TankRight"
		tank.Shape = Enum.PartType.Cylinder
		tank.Size = TANK_SIZE
		tank.Color = TANK_COLOR
		tank.Material = Enum.Material.Metal
		tank.CFrame = CFrame.new(
			side * (PACK_SIZE.X / 2 - TANK_SIZE.Y / 2),
			0,
			PACK_SIZE.Z / 2 + TANK_SIZE.Z / 2 - 0.05
		) * CFrame.Angles(0, 0, math.pi / 2)
		passive(tank)
		tank.Parent = model

		local nozzle = Instance.new("Part")
		nozzle.Name = if side < 0 then "NozzleLeft" else "NozzleRight"
		nozzle.Size = NOZZLE_SIZE
		nozzle.Color = NOZZLE_COLOR
		nozzle.Material = Enum.Material.Metal
		nozzle.CFrame = CFrame.new(
			side * (PACK_SIZE.X / 2 - TANK_SIZE.Y / 2),
			-TANK_SIZE.X / 2 - NOZZLE_SIZE.Y / 2,
			PACK_SIZE.Z / 2 + TANK_SIZE.Z / 2 - 0.05
		)
		passive(nozzle)
		nozzle.Parent = model

		-- the flame: an emitter blowing down out of the nozzle (clients enable it from the Thrust attribute)
		local exhaust = Instance.new("Attachment")
		exhaust.Name = "Exhaust"
		exhaust.CFrame = CFrame.new(0, -NOZZLE_SIZE.Y / 2, 0)
		exhaust.Parent = nozzle
		local flame = Instance.new("ParticleEmitter")
		flame.Name = "Flame"
		flame.Enabled = false
		flame.Texture = FLAME_TEXTURE
		flame.Color = ColorSequence.new(FLAME_COLOR)
		flame.LightEmission = 1
		flame.EmissionDirection = Enum.NormalId.Bottom
		flame.Speed = NumberRange.new(8, 12)
		flame.Lifetime = NumberRange.new(0.12, 0.2)
		flame.Rate = 60
		flame.SpreadAngle = Vector2.new(8, 8)
		flame.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0.05) })
		flame.Transparency =
			NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
		flame.Parent = exhaust
	end

	-- the helmet light: on the right shoulder, shining forward (clients enable it from the Light attribute)
	local lamp = Instance.new("Part")
	lamp.Name = "Lamp"
	lamp.Shape = Enum.PartType.Ball
	lamp.Size = LAMP_SIZE
	lamp.Color = LAMP_COLOR
	lamp.Material = Enum.Material.Neon
	lamp.CFrame = CFrame.new(PACK_SIZE.X / 2 - 0.1, PACK_SIZE.Y / 2 + LAMP_SIZE.Y / 2, -PACK_SIZE.Z / 2)
	passive(lamp)
	lamp.Parent = model
	local light = Instance.new("SpotLight")
	light.Name = "HelmetLight"
	light.Enabled = false
	light.Face = Enum.NormalId.Front
	light.Range = LIGHT_RANGE
	light.Angle = LIGHT_ANGLE
	light.Brightness = LIGHT_BRIGHTNESS
	light.Color = LAMP_COLOR
	light.Shadows = false
	light.Parent = lamp
	return model
end

local function torsoOf(character: Model): BasePart?
	local torso = character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")
	return if torso and torso:IsA("BasePart") then torso else nil
end

local function jetpackOf(character: Model?): Model?
	local found = if character then character:FindFirstChild(JETPACK_NAME) else nil
	return if found and found:IsA("Model") then found else nil
end

local function addJetpack(character: Model)
	if jetpackOf(character) then
		return
	end
	local torso = torsoOf(character)
	if torso == nil then
		return
	end
	local model = buildJetpack()
	local pack = model.PrimaryPart :: BasePart
	-- every part was built around the identity: move them all onto the torso's back
	local place = torso.CFrame * CFrame.new(0, 0, torso.Size.Z / 2 + PACK_SIZE.Z / 2)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CFrame = place * descendant.CFrame
		end
	end
	-- welded only now, where they sit (a WeldConstraint keeps the offset its parts have when it activates)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and descendant ~= pack then
			weld(pack, descendant)
		end
	end
	weld(torso, pack)
	model.Parent = character
end

local function removeJetpack(character: Model?)
	local model = jetpackOf(character)
	if model then
		model:Destroy()
	end
end

--============================================================================
-- Input
--============================================================================

-- Token bucket: true when this message may pass.
local function allow(player: Player): boolean
	local now = os.clock()
	local bucket = tokens[player]
	if bucket == nil then
		bucket = { amount = INPUT_BURST, time = now }
		tokens[player] = bucket
	end
	local b = bucket :: { amount: number, time: number }
	b.amount = math.min(INPUT_BURST, b.amount + (now - b.time) * INPUT_RATE)
	b.time = now
	if b.amount < 1 then
		return false
	end
	b.amount -= 1
	return true
end

local function onEvaInput(player: Player, kind: unknown, on: unknown)
	if (kind ~= "Thrust" and kind ~= "Light") or type(on) ~= "boolean" then
		return
	end
	if not allow(player) or not BubbleService.isEva(player) then
		return
	end
	local model = jetpackOf(player.Character)
	if model then
		model:SetAttribute(kind :: string, on)
	end
end

--============================================================================
-- Upkeep
--============================================================================

-- Is an astronaut lost: his pocket is gone, or his character is outside its slot (and not just transferred)?
local function isLost(player: Player): boolean
	local pocketId = player:GetAttribute("PocketId")
	if type(pocketId) ~= "number" or PocketService.isPinned(player) then
		return false
	end
	local pocket = PocketService.flightPocket(pocketId)
	if pocket == nil then
		return true
	end
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if root == nil or not root:IsA("BasePart") then
		return false
	end
	local offset = root.Position - pocket.slotOrigin
	return offset.Magnitude > PocketService.SLOT_CAPTURE_RADIUS or offset.Y ~= offset.Y
end

local function upkeep()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if BubbleService.isEva(player) then
			if character then
				addJetpack(character)
			end
			if isLost(player) then
				local since = lostSince[player]
				if since == nil then
					lostSince[player] = now
				elseif now - since > RESCUE_S then
					lostSince[player] = nil
					local pocketId = player:GetAttribute("PocketId")
					FlightService.sendHome(player, if type(pocketId) == "number" then pocketId else nil)
					Remotes.event("Notify"):FireClient(player, RESCUE_TEXT, "Info")
				end
			else
				lostSince[player] = nil
			end
		else
			lostSince[player] = nil
			removeJetpack(character)
		end
	end
end

--============================================================================
-- Lifecycle
--============================================================================

function EvaService.Init() end

function EvaService.Start()
	Remotes.event("EvaInput").OnServerEvent:Connect(onEvaInput)
	Players.PlayerRemoving:Connect(function(player: Player)
		lostSince[player] = nil
		tokens[player] = nil
	end)
	RunService.Heartbeat:Connect(function(dt: number)
		accumulator += dt
		if accumulator < CHECK_INTERVAL then
			return
		end
		accumulator = 0
		local ok, err = pcall(function()
			upkeep()
		end)
		if not ok then
			warn(`[EvaService] upkeep failed: {err}`)
		end
	end)
end

return EvaService
