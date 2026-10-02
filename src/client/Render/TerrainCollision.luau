--!strict
--[[
	TerrainCollision (CHANGED (Phase 8): surface terrain)
	Something for the local character to stand on: the heightmap lattice triangles (SurfaceHeight, the same ground the
	flight model collides with and the terrain renderer draws) within the tier's radius of the local player's
	HumanoidRootPart, each filled with two invisible, anchored WedgeParts (solid below the triangle). Rebuilt only
	when the character's lattice cell changes; moved with one BulkMoveTo when the pocket frame moves (flight pockets
	stream the world past the craft). Nothing is built while the character is seated or more than ACTIVE_HEIGHT above
	the ground. Crafts never touch these parts: craft contact is SurfaceHeight-based (FlightModel).

	CHANGED (Night review): incremental. Every cell crossing used to release and re-create all the wedges (80 / 124
	/ 208 WedgeParts per 23 m on Low / Medium / High); now the wedges are kept per lattice cell
	(TerrainMath.collisionCells / cellTriangles) and only the cells entering or leaving the radius change (offline:
	about 48 / 58 WedgeParts per crossing at 50 / 70 m). Their CFrames stay relative to one anchor, which is only
	reset (a full rebuild) after the character has moved ANCHOR_RESET from it, or on a body / face / radius change.

	API (driven by Surface):
		TerrainCollision.init(parent)
		TerrainCollision.update(ctx)
		TerrainCollision.partCount(): number
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Quality = require(script.Parent.Quality)
local RenderContext = require(script.Parent.RenderContext)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local TerrainMath = require(script.Parent.TerrainMath)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local RADIUS_BY_TIER: { [string]: number } = { Low = 35, Medium = 50, High = 70 } -- m around the character
local ACTIVE_HEIGHT = 300 -- m above the ground; higher than this, no collision parts
local THICKNESS = 4 -- studs, wedge thickness below the triangle
local POOL_PREWARM = 40
local BULK_MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged
local ANCHOR_RESET = 1000 -- m: CHANGED (Night review) the wedges are rebuilt about a new anchor this far from it
--============================================================================

type Wedge = { part: WedgePart, cf: CFrame } -- cf relative to the anchor (body axes)

local TerrainCollision = {}

local folder: Folder? = nil
local pool: { WedgePart } = {}
local wedges: { Wedge } = {} -- every wedge in use (rebuilt from cellWedges when the cells change)
local cellWedges: { [number]: { Wedge } } = {} -- CHANGED (Night review): by TerrainMath.cellKey
local anchor: Vec3d = Vec3d.zero() -- body-relative point the wedge CFrames are relative to
local anchored = false -- CHANGED (Night review): `anchor` is set (cells exist relative to it)
local cellBody: number? = nil
local cellFace = 0
local cellI = -1
local cellJ = -1
local cellRadius = 0
local wantedCells: { number } = {} -- CHANGED (Night review): scratch for TerrainMath.collisionCells
local wantedSet: { [number]: boolean } = {}
local parts: { BasePart } = {}
local cframes: { CFrame } = {}
local placedDirty = true
local lastRef: Vec3d = Vec3d.zero()
local lastRot: CFrame = CFrame.identity
local lastSlot: Vector3 = Vector3.zero
local lastOffset: Vec3d = Vec3d.zero()
local shown = false
local scratch: Vec3d = Vec3d.zero()

local function newWedge(): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = "TerrainCollider"
	w.Anchored = true
	w.CanCollide = true
	w.CanQuery = true
	w.CanTouch = false
	w.CastShadow = false
	w.Massless = true
	w.Locked = true
	w.Transparency = 1
	return w
end

local function acquire(): WedgePart
	return table.remove(pool) or newWedge()
end

local function releaseAll()
	for _, w in wedges do
		w.part.Parent = nil
		table.insert(pool, w.part)
	end
	table.clear(wedges)
	table.clear(cellWedges) -- CHANGED (Night review)
	anchored = false
	table.clear(parts)
	table.clear(cframes)
	cellBody = nil
	placedDirty = true
end

local function hide()
	if shown then
		shown = false
		releaseAll()
	end
end

-- The local character's root position, or nil (no character, or seated: a seat carries it, nothing to stand on).
local function localRootPosition(): Vector3?
	local player = Players.LocalPlayer
	local character = player and player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		local humanoid = (character :: Model):FindFirstChildOfClass("Humanoid")
		if humanoid and humanoid.SeatPart ~= nil then
			return nil
		end
		return hrp.Position
	end
	return nil
end

-- CHANGED (Night review): the wedges of one lattice cell's two triangles (CFrames relative to the anchor).
local function buildCell(config: TerrainMath.Config, key: number, parent: Folder): { Wedge }
	local result: { Wedge } = {}
	local face, i, j = TerrainMath.cellOf(key)
	local first, second = TerrainMath.cellTriangles(config, face, i, j)
	local ax, ay, az = anchor.x, anchor.y, anchor.z
	for _, t in { first, second } do
		local a = Vector3.new(t[1] - ax, t[2] - ay, t[3] - az)
		local b = Vector3.new(t[4] - ax, t[5] - ay, t[6] - az)
		local c = Vector3.new(t[7] - ax, t[8] - ay, t[9] - az)
		local mid = Vector3.new((t[1] + t[4] + t[7]) / 3, (t[2] + t[5] + t[8]) / 3, (t[3] + t[6] + t[9]) / 3)
		local cf0, size0, cf1, size1 = TerrainMath.wedgePair(a, b, c, mid.Unit, THICKNESS)
		if cf0 and size0 and cf1 and size1 then
			local w0 = acquire()
			w0.Size = size0
			w0.Parent = parent
			table.insert(result, { part = w0, cf = cf0 })
			local w1 = acquire()
			w1.Size = size1
			w1.Parent = parent
			table.insert(result, { part = w1, cf = cf1 })
		end
	end
	return result
end

--[[
	Brings the wedges up to date for the cells around body-relative `pos`.
	CHANGED (Night review): only cells entering / leaving the radius change (was: everything rebuilt); a full rebuild
	about a new anchor when `full` or once the anchor is ANCHOR_RESET away.
]]
local function rebuild(config: TerrainMath.Config, pos: Vec3d, radius: number, parent: Folder, full: boolean)
	if full or not anchored or Vec3d.distance(pos, anchor) > ANCHOR_RESET then
		releaseAll()
		local ground = SurfaceHeight.groundPoint(config.bodyId, pos)
		Vec3d.copyInto(anchor, ground)
		anchored = true
	end
	TerrainMath.collisionCells(config, pos, radius, wantedCells)
	table.clear(wantedSet)
	for _, key in wantedCells do
		wantedSet[key] = true
	end
	local changed = false
	for key, list in cellWedges do
		if not wantedSet[key] then
			for _, w in list do
				w.part.Parent = nil
				table.insert(pool, w.part)
			end
			cellWedges[key] = nil
			changed = true
		end
	end
	for _, key in wantedCells do
		if cellWedges[key] == nil then
			cellWedges[key] = buildCell(config, key, parent)
			changed = true
		end
	end
	if not changed then
		return
	end
	table.clear(wedges)
	table.clear(parts)
	table.clear(cframes)
	for _, list in cellWedges do
		for _, w in list do
			table.insert(wedges, w)
			table.insert(parts, w.part)
			table.insert(cframes, CFrame.identity)
		end
	end
	placedDirty = true
end

function TerrainCollision.init(parent: Folder)
	local f = Instance.new("Folder")
	f.Name = "TerrainCollision"
	f.Parent = parent
	folder = f
	for _ = 1, POOL_PREWARM do
		table.insert(pool, newWedge())
	end
end

function TerrainCollision.update(ctx: RenderContext.RenderContext)
	local parent = folder
	local rootPos = localRootPosition()
	local config = TerrainMath.config(ctx.dominantBodyId)
	if parent == nil or rootPos == nil or config == nil then
		hide()
		return
	end
	local frame = ctx.frame
	local bodyId = config.bodyId
	-- the character relative to the dominant body (doubles)
	local pos = Frames.pointFromWorkspace(frame, rootPos, scratch)
	local offset: Vec3d? = nil
	if bodyId ~= frame.refBodyId then
		offset = Universe.bodyOffset(bodyId, frame.refBodyId, ctx.ut)
		local o = offset :: Vec3d
		Vec3d.set(pos, pos.x - o.x, pos.y - o.y, pos.z - o.z)
	end
	local height = SurfaceHeight.height(bodyId, pos)
	if height > ACTIVE_HEIGHT then
		hide()
		return
	end
	shown = true
	local radius = RADIUS_BY_TIER[Quality.tier()] or RADIUS_BY_TIER.High
	local face, fi, fj = SurfaceHeight.latticeCoords(bodyId, pos)
	local i, j = math.floor(fi), math.floor(fj)
	if cellBody ~= bodyId or face ~= cellFace or i ~= cellI or j ~= cellJ or radius ~= cellRadius then
		-- CHANGED (Night review): incremental within a face at the same radius
		local full = cellBody ~= bodyId or face ~= cellFace or radius ~= cellRadius
		rebuild(config, pos, radius, parent, full)
		cellBody, cellFace, cellI, cellJ, cellRadius = bodyId, face, i, j, radius
	end
	if #wedges == 0 then
		return
	end
	local ox, oy, oz = 0, 0, 0
	if offset then
		ox, oy, oz = offset.x, offset.y, offset.z
	end
	local ref = frame.refPos
	if
		placedDirty
		or ref.x ~= lastRef.x
		or ref.y ~= lastRef.y
		or ref.z ~= lastRef.z
		or frame.refRot ~= lastRot
		or frame.slotOrigin ~= lastSlot
		or ox ~= lastOffset.x
		or oy ~= lastOffset.y
		or oz ~= lastOffset.z
	then
		local anchorCFrame = Frames.cframeToWorkspace(frame, anchor, CFrame.identity, offset)
		for index, w in wedges do
			cframes[index] = anchorCFrame * w.cf
		end
		Workspace:BulkMoveTo(parts, cframes, BULK_MOVE_MODE)
		Vec3d.copyInto(lastRef, ref)
		lastRot = frame.refRot
		lastSlot = frame.slotOrigin
		Vec3d.set(lastOffset, ox, oy, oz)
		placedDirty = false
	end
end

-- Collision parts in use (debug).
function TerrainCollision.partCount(): number
	return #wedges
end

return table.freeze(TerrainCollision)
