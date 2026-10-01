--!strict
--[[
	RemoteCraftRenderer (spec 7.7)
	Knows every craft in flight (CraftSpawned / CraftRemoved / CraftStaged / PartsDestroyed), buffers their
	streamed states (CraftStates) and interpolates them at UT - INTERP_DELAY (extrapolating up to
	EXTRAPOLATE_MAX when starved). Crafts that are not in the local player's pocket are drawn as client-side
	cosmetic copies (invariant I6): CraftBuilder "Cosmetic" models with one anchored root and welded, massless
	children, moved by setting the root CFrame once per frame through the current pocket frame.

	Also used by PocketController: passengers take their CRAFT_ALIGNED frame from sampleState() of the primary.
	Phase 2a draws copies at true scale out to COPY_MAX_DISTANCE; scaled-space copies arrive in Phase 4.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local Plumes = require(script.Parent.Parent.Render.Plumes)
local Gear = require(script.Parent.Parent.Render.Gear)
local RenderContext = require(script.Parent.Parent.Render.RenderContext)

type State = Protocol.State
type Design = CraftDesign.Design

--============================================================================
-- Tunables
--============================================================================
local INTERP_DELAY = GameConfig.INTERP_DELAY
local EXTRAPOLATE_MAX = GameConfig.EXTRAPOLATE_MAX
local BUFFER_SIZE = 40
local COPY_MAX_DISTANCE = 30000 -- studs from the camera; farther copies are hidden (Phase 4 adds scaled copies)
--============================================================================

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
}

local RemoteCraftRenderer = {}

local entries: { [number]: Entry } = {}
local folder: Folder

--============================================================================
-- Interpolation
--============================================================================

local function pushState(entry: Entry, state: State)
	local states = entry.states
	local last = states[#states]
	if last and state.ut <= last.ut then
		return -- older than what we already have (unreliable packets may reorder)
	end
	table.insert(states, state)
	if #states > BUFFER_SIZE then
		table.remove(states, 1)
	end
end

local function lerpState(a: State, b: State, t: number): State
	return {
		bodyId = a.bodyId,
		pos = Vec3d.lerp(a.pos, b.pos, t),
		vel = Vec3d.lerp(a.vel, b.vel, t),
		rot = a.rot:Lerp(b.rot, t),
		angVel = a.angVel:Lerp(b.angVel, t),
		throttle = a.throttle + (b.throttle - a.throttle) * t,
		flags = if t < 0.5 then a.flags else b.flags,
		ut = a.ut + (b.ut - a.ut) * t,
	}
end

local function extrapolate(s: State, dt: number): State
	local angle = s.angVel.Magnitude * dt
	local rot = if angle > 1e-9 then CFrame.fromAxisAngle(s.angVel.Unit, angle) * s.rot else s.rot
	return {
		bodyId = s.bodyId,
		pos = Vec3d.addScaled(s.pos, s.vel, dt),
		vel = s.vel,
		rot = rot,
		angVel = s.angVel,
		throttle = s.throttle,
		flags = s.flags,
		ut = s.ut + dt,
	}
end

-- Interpolated (or briefly extrapolated) state of a craft at a UT, or nil if unknown.
function RemoteCraftRenderer.sampleState(craftId: number, ut: number): State?
	local entry = entries[craftId]
	if entry == nil or #entry.states == 0 then
		return nil
	end
	local states = entry.states
	if ut <= states[1].ut then
		return states[1]
	end
	for index = #states - 1, 1, -1 do
		local a, b = states[index], states[index + 1]
		if ut >= a.ut and ut <= b.ut then
			if a.bodyId ~= b.bodyId then
				return b
			end
			local span = b.ut - a.ut
			return lerpState(a, b, if span > 0 then (ut - a.ut) / span else 1)
		end
	end
	local newest = states[#states]
	return extrapolate(newest, math.clamp(ut - newest.ut, 0, EXTRAPOLATE_MAX))
end

-- The latest streamed state (no interpolation), or nil.
function RemoteCraftRenderer.latestState(craftId: number): State?
	local entry = entries[craftId]
	return if entry then entry.states[#entry.states] else nil
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
end

--============================================================================
-- Rendering (called by UniverseRenderer every frame, after the pocket frame is updated)
--============================================================================

function RemoteCraftRenderer.render(ctx: RenderContext.RenderContext)
	local renderUT = ctx.ut - INTERP_DELAY
	local cameraPos = ctx.camera.Position
	for id, entry in entries do
		local inMyPocket = entry.pocketId ~= 0 and entry.pocketId == ctx.pocketId
		local state = if inMyPocket then nil else RemoteCraftRenderer.sampleState(id, renderUT)
		if state == nil or #entry.design.blocks == 0 then
			if entry.model then
				(entry.model :: Model).Parent = nil
			end
			continue
		end
		local s = state :: State
		local bodyOffset = if s.bodyId ~= ctx.frame.refBodyId
			then Universe.bodyOffset(s.bodyId, ctx.frame.refBodyId, ctx.ut)
			else nil
		local target = Frames.cframeToWorkspace(ctx.frame, s.pos, s.rot, bodyOffset)
		if (target.Position - cameraPos).Magnitude > COPY_MAX_DISTANCE then
			if entry.model then
				(entry.model :: Model).Parent = nil
			end
			continue
		end
		local model = entry.model or buildModel(entry)
		model.Parent = folder
		local root = entry.root :: BasePart
		root.CFrame = target
		if #entry.gear > 0 then
			entry.gearFraction = Gear.approach(entry.gearFraction, Gear.target(s.flags), ctx.dt)
			Gear.pose(entry.gear, target, entry.gearFraction)
		end

		local burning: { [number]: number } = {}
		if bit32.band(s.flags, 2) ~= 0 then
			for engineId in entry.active do
				local block = nil
				for _, b in entry.design.blocks do
					if b.id == engineId then
						block = b
						break
					end
				end
				if block then
					local engine = Parts.get(block.type).Engine
					-- CHANGED (Phase 2a feedback): no minimum flame, a throttled-down liquid engine is out
					burning[engineId] = if engine and not engine.Throttleable then 1 else s.throttle
				end
			end
		end
		Plumes.update(model, burning)
	end
end

--============================================================================
-- Network
--============================================================================

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
	end
	local entry: Entry = {
		id = craftId,
		design = design,
		ownerUserId = if type(data.ownerUserId) == "number" then data.ownerUserId else 0,
		pocketId = if type(data.pocketId) == "number" then data.pocketId else 0,
		active = {},
		states = if existing then existing.states else {},
		model = nil,
		root = nil,
		gear = {},
		gearFraction = 1,
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
end

local function onStaged(
	craftId: unknown,
	_stage: unknown,
	_ut: unknown,
	ignited: unknown,
	_decoupled: unknown,
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
end

function RemoteCraftRenderer.Start()
	Remotes.event("CraftSpawned").OnClientEvent:Connect(onSpawned)
	Remotes.event("CraftRemoved").OnClientEvent:Connect(onRemoved)
	Remotes.event("CraftStaged").OnClientEvent:Connect(onStaged)
	Remotes.event("PartsDestroyed").OnClientEvent:Connect(onDestroyed)
	Remotes.unreliable("CraftStates").OnClientEvent:Connect(function(packet: unknown)
		for _, item in Protocol.decodeStates(packet) do
			local entry = entries[item.craftId]
			if entry then
				pushState(entry, item.state)
			end
		end
	end)
end

return RemoteCraftRenderer
