--!strict
--[[
	CraftDesign
	Craft design data: blocks on an integer grid, the 24 axis-aligned orientations, geometry helpers, validation,
	versioned JSON for persistence, and a compact buffer for the network.

	Grid convention: (gx, gy, gz) is the MINIMUM corner of the block's oriented bounding box, in integer BLOCK
	units (CHANGED Phase 1 rework: one block = GameConfig.GRID_SIZE studs), design-local. For a plot design,
	design-local = the plot's build grid (origin = plot buildOrigin). A block's design-local CFrame (in STUDS) is
	CFrame.new(center * GRID) * rotationCFrame(rot), where center = min + orientedSize / 2 (blocks).
	`color` is an optional paint index (Config/Paint); nil = the part's default colours.

	Orientation index rot (0..23) = upIndex * 4 + yawIndex:
	  the part's local +Y points along UP_DIRECTIONS[upIndex + 1], then the part is yawed yawIndex * 90 degrees
	  about its own up axis. rot 0 is the identity.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Paint = require(script.Parent.Parent.Config.Paint)
local Parts = require(script.Parent.Parent.Config.Parts)
local Json = require(script.Parent.Parent.Util.Json)

--============================================================================
-- Tunables
--============================================================================
local JSON_VERSION = 1
local BUFFER_VERSION = 1
local MAX_NAME_LENGTH = 40
local BLOCK_BYTES = 12 -- u16 id, u8 type, i16 gx, i16 gy, i16 gz, u8 rot, u8 stage, u8 color
local NO_COLOR = 0
local NO_STAGE = 255
local COORD_LIMIT = 32767 -- i16
--============================================================================

export type Block = {
	id: number,
	type: string, -- Parts Id
	gx: number,
	gy: number,
	gz: number,
	rot: number, -- 0..23
	stageOverride: number?,
	color: number?, -- paint index (Config/Paint), nil = default colours
}

export type Design = {
	version: number,
	name: string,
	blocks: { Block },
}

local CraftDesign = {}

CraftDesign.JSON_VERSION = JSON_VERSION
CraftDesign.GRID = GameConfig.GRID_SIZE
CraftDesign.MAX_NAME_LENGTH = MAX_NAME_LENGTH

--============================================================================
-- Orientations
--============================================================================

-- Rotations taking local +Y to each up direction (applied before the yaw).
local UP_BASES: { CFrame } = {
	CFrame.identity, -- +Y
	CFrame.Angles(0, 0, -math.pi / 2), -- +X
	CFrame.Angles(0, 0, math.pi / 2), -- -X
	CFrame.Angles(math.pi / 2, 0, 0), -- +Z
	CFrame.Angles(-math.pi / 2, 0, 0), -- -Z
	CFrame.Angles(math.pi, 0, 0), -- -Y
}

-- Rounds a rotation's matrix to exact 0/±1 entries.
local function snapRotation(cf: CFrame): CFrame
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	local function r(v: number): number
		return math.round(v)
	end
	return CFrame.new(0, 0, 0, r(r00), r(r01), r(r02), r(r10), r(r11), r(r12), r(r20), r(r21), r(r22))
end

local function rotationKey(cf: CFrame): string
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
	return string.format(
		"%d%d%d%d%d%d%d%d%d",
		math.round(r00),
		math.round(r01),
		math.round(r02),
		math.round(r10),
		math.round(r11),
		math.round(r12),
		math.round(r20),
		math.round(r21),
		math.round(r22)
	)
end

local ROTATIONS: { CFrame } = {}
local ROTATION_INDEX: { [string]: number } = {}
for upIndex = 0, 5 do
	for yawIndex = 0, 3 do
		local cf = snapRotation(UP_BASES[upIndex + 1] * CFrame.Angles(0, yawIndex * math.pi / 2, 0))
		local rot = upIndex * 4 + yawIndex
		ROTATIONS[rot + 1] = cf
		local key = rotationKey(cf)
		assert(ROTATION_INDEX[key] == nil, "duplicate orientation")
		ROTATION_INDEX[key] = rot
	end
end

CraftDesign.ORIENTATION_COUNT = 24

-- Rotation-only CFrame for an orientation index.
function CraftDesign.rotationCFrame(rot: number): CFrame
	local cf: CFrame? = ROTATIONS[rot + 1]
	if not cf then
		error(`Invalid orientation {rot}`, 2)
	end
	return cf :: CFrame
end

-- Orientation index of a rotation (snapped to the nearest axis-aligned rotation).
function CraftDesign.rotationIndex(cf: CFrame): number
	local rot = ROTATION_INDEX[rotationKey(cf - cf.Position)]
	if rot == nil then
		error("Rotation is not axis-aligned", 2)
	end
	return rot
end

-- The orientation after rotating an existing one by `by` about the design axes (e.g. yaw = CFrame.Angles(0, pi/2, 0)).
function CraftDesign.rotateOrientation(rot: number, by: CFrame): number
	return CraftDesign.rotationIndex(snapRotation(by * CraftDesign.rotationCFrame(rot)))
end

local function orientedSizeOf(size: Vector3, rot: number): Vector3
	local rotated = CraftDesign.rotationCFrame(rot):VectorToWorldSpace(size)
	return Vector3.new(
		math.round(math.abs(rotated.X)),
		math.round(math.abs(rotated.Y)),
		math.round(math.abs(rotated.Z))
	)
end

-- Size of a part type in design axes for an orientation.
function CraftDesign.orientedSize(partId: string, rot: number): Vector3
	return orientedSizeOf(Parts.get(partId).Size, rot)
end

--============================================================================
-- Blocks
--============================================================================

function CraftDesign.new(name: string?): Design
	return { version = JSON_VERSION, name = name or "Untitled", blocks = {} }
end

function CraftDesign.blockSize(block: Block): Vector3
	return orientedSizeOf(Parts.get(block.type).Size, block.rot)
end

function CraftDesign.blockMin(block: Block): Vector3
	return Vector3.new(block.gx, block.gy, block.gz)
end

function CraftDesign.blockMax(block: Block): Vector3
	return Vector3.new(block.gx, block.gy, block.gz) + CraftDesign.blockSize(block)
end

function CraftDesign.blockCenter(block: Block): Vector3
	return Vector3.new(block.gx, block.gy, block.gz) + CraftDesign.blockSize(block) / 2
end

-- Design-local CFrame (studs) of the block's part-local frame (centre + orientation).
function CraftDesign.blockCFrame(block: Block): CFrame
	return CFrame.new(CraftDesign.blockCenter(block) * GameConfig.GRID_SIZE) * CraftDesign.rotationCFrame(block.rot)
end

-- Orientation of the mirror image of a block across a design plane perpendicular to `axis` ("X" or "Z").
-- The reflection S R S of a rotation R is itself a proper rotation, so it is one of the 24 orientations.
function CraftDesign.mirrorOrientation(rot: number, axis: "X" | "Z"): number
	local _, _, _, r00, r01, r02, r10, r11, r12, r20, r21, r22 = CraftDesign.rotationCFrame(rot):GetComponents()
	local sx = if axis == "X" then -1 else 1
	local sz = if axis == "Z" then -1 else 1
	local signs = { sx, 1, sz }
	local m = { { r00, r01, r02 }, { r10, r11, r12 }, { r20, r21, r22 } }
	local out = {}
	for i = 1, 3 do
		for j = 1, 3 do
			out[(i - 1) * 3 + j] = math.round(signs[i] * signs[j] * m[i][j])
		end
	end
	local mirrored = CFrame.new(0, 0, 0, out[1], out[2], out[3], out[4], out[5], out[6], out[7], out[8], out[9])
	return CraftDesign.rotationIndex(mirrored)
end

-- True if the two blocks' boxes share volume.
function CraftDesign.overlaps(a: Block, b: Block): boolean
	local aMin, aMax = CraftDesign.blockMin(a), CraftDesign.blockMax(a)
	local bMin, bMax = CraftDesign.blockMin(b), CraftDesign.blockMax(b)
	return aMin.X < bMax.X
		and bMin.X < aMax.X
		and aMin.Y < bMax.Y
		and bMin.Y < aMax.Y
		and aMin.Z < bMax.Z
		and bMin.Z < aMax.Z
end

-- True if the blocks share a face with non-zero overlap area (the attachment rule).
function CraftDesign.touches(a: Block, b: Block): boolean
	local aMin, aMax = CraftDesign.blockMin(a), CraftDesign.blockMax(a)
	local bMin, bMax = CraftDesign.blockMin(b), CraftDesign.blockMax(b)
	local function overlap1(aLo: number, aHi: number, bLo: number, bHi: number): boolean
		return aLo < bHi and bLo < aHi
	end
	local ox = overlap1(aMin.X, aMax.X, bMin.X, bMax.X)
	local oy = overlap1(aMin.Y, aMax.Y, bMin.Y, bMax.Y)
	local oz = overlap1(aMin.Z, aMax.Z, bMin.Z, bMax.Z)
	local tx = aMax.X == bMin.X or bMax.X == aMin.X
	local ty = aMax.Y == bMin.Y or bMax.Y == aMin.Y
	local tz = aMax.Z == bMin.Z or bMax.Z == aMin.Z
	return (tx and oy and oz) or (ty and ox and oz) or (tz and ox and oy)
end

-- Axis-aligned bounds of the whole design (min, max). Returns zero vectors for an empty design.
function CraftDesign.bounds(design: Design): (Vector3, Vector3)
	if #design.blocks == 0 then
		return Vector3.zero, Vector3.zero
	end
	local minV = Vector3.new(math.huge, math.huge, math.huge)
	local maxV = -minV
	for _, block in design.blocks do
		minV = minV:Min(CraftDesign.blockMin(block))
		maxV = maxV:Max(CraftDesign.blockMax(block))
	end
	return minV, maxV
end

function CraftDesign.findBlock(design: Design, id: number): Block?
	for _, block in design.blocks do
		if block.id == id then
			return block
		end
	end
	return nil
end

-- The root block: the command part with the lowest id, or nil.
function CraftDesign.rootBlock(design: Design): Block?
	local root: Block? = nil
	for _, block in design.blocks do
		if Parts.isCommand(Parts.get(block.type)) and (root == nil or block.id < (root :: Block).id) then
			root = block
		end
	end
	return root
end

function CraftDesign.clone(design: Design): Design
	local blocks = table.create(#design.blocks)
	for index, block in design.blocks do
		blocks[index] = table.clone(block)
	end
	return { version = design.version, name = design.name, blocks = blocks }
end

-- Returns a copy whose blocks are shifted by an integer offset.
function CraftDesign.translated(design: Design, dx: number, dy: number, dz: number): Design
	local copy = CraftDesign.clone(design)
	for _, block in copy.blocks do
		block.gx += dx
		block.gy += dy
		block.gz += dz
	end
	return copy
end

--============================================================================
-- Validation
--============================================================================

export type Limits = {
	maxBlocks: number,
	boundsMin: Vector3?, -- inclusive minimum corner allowed
	boundsMax: Vector3?, -- inclusive maximum corner allowed
}

local function isInteger(n: any): boolean
	return type(n) == "number" and n == n and n % 1 == 0 and math.abs(n) <= COORD_LIMIT
end

-- Checks structure, part ids, orientations, integer coordinates, unique ids, overlaps and optional bounds.
function CraftDesign.validate(design: Design, limits: Limits): (boolean, string?)
	if type(design) ~= "table" or type(design.blocks) ~= "table" then
		return false, "malformed design"
	end
	if type(design.name) ~= "string" or #design.name > MAX_NAME_LENGTH then
		return false, "bad name"
	end
	if #design.blocks > limits.maxBlocks then
		return false, `too many blocks ({#design.blocks} > {limits.maxBlocks})`
	end
	local ids: { [number]: boolean } = {}
	for _, block in design.blocks do
		if type(block) ~= "table" then
			return false, "malformed block"
		end
		if not isInteger(block.id) or block.id < 1 or block.id > 65535 then
			return false, "bad block id"
		end
		if ids[block.id] then
			return false, `duplicate block id {block.id}`
		end
		ids[block.id] = true
		if type(block.type) ~= "string" or Parts.find(block.type) == nil then
			return false, `unknown part {tostring(block.type)}`
		end
		if not isInteger(block.rot) or block.rot < 0 or block.rot > 23 then
			return false, "bad orientation"
		end
		if not (isInteger(block.gx) and isInteger(block.gy) and isInteger(block.gz)) then
			return false, "non-integer position"
		end
		if block.stageOverride ~= nil and (not isInteger(block.stageOverride) or block.stageOverride < 1) then
			return false, "bad stage override"
		end
		if block.color ~= nil and (not isInteger(block.color) or not Paint.isValid(block.color)) then
			return false, "bad paint colour"
		end
		if limits.boundsMin and limits.boundsMax then
			local minV, maxV = CraftDesign.blockMin(block), CraftDesign.blockMax(block)
			local lo, hi = limits.boundsMin :: Vector3, limits.boundsMax :: Vector3
			if minV.X < lo.X or minV.Y < lo.Y or minV.Z < lo.Z or maxV.X > hi.X or maxV.Y > hi.Y or maxV.Z > hi.Z then
				return false, "block outside the build volume"
			end
		end
	end
	local blocks = design.blocks
	for i = 1, #blocks do
		for j = i + 1, #blocks do
			if CraftDesign.overlaps(blocks[i], blocks[j]) then
				return false, `blocks {blocks[i].id} and {blocks[j].id} overlap`
			end
		end
	end
	return true, nil
end

--============================================================================
-- JSON (persistence)
--============================================================================

function CraftDesign.toJson(design: Design): string
	local blocks = table.create(#design.blocks)
	for index, block in design.blocks do
		local entry: { [string]: any } = {
			id = block.id,
			t = block.type,
			x = block.gx,
			y = block.gy,
			z = block.gz,
			r = block.rot,
		}
		if block.stageOverride then
			entry.s = block.stageOverride
		end
		if block.color then
			entry.c = block.color
		end
		blocks[index] = entry
	end
	return Json.encode({ v = JSON_VERSION, name = design.name, blocks = blocks })
end

-- Parses a saved design. Returns nil and a reason on malformed input (does not validate overlaps/limits).
function CraftDesign.fromJson(text: string): (Design?, string?)
	local ok, decoded = pcall(Json.decode, text)
	if not ok then
		return nil, tostring(decoded)
	end
	if type(decoded) ~= "table" or type(decoded.blocks) ~= "table" then
		return nil, "not a design"
	end
	local version = decoded.v
	if version ~= JSON_VERSION then
		return nil, `unsupported design version {tostring(version)}`
	end
	local design = CraftDesign.new(if type(decoded.name) == "string" then decoded.name else "Untitled")
	for _, entry in decoded.blocks do
		if type(entry) ~= "table" then
			return nil, "malformed block"
		end
		table.insert(design.blocks, {
			id = entry.id,
			type = entry.t,
			gx = entry.x,
			gy = entry.y,
			gz = entry.z,
			rot = entry.r,
			stageOverride = if type(entry.s) == "number" then entry.s else nil,
			color = if type(entry.c) == "number" then entry.c else nil,
		})
	end
	return design, nil
end

--============================================================================
-- Buffer (network)
--============================================================================

-- Layout: u8 version, u8 nameLength, name bytes, u16 blockCount, then 11 bytes per block.
function CraftDesign.toBuffer(design: Design): buffer
	local name = string.sub(design.name, 1, MAX_NAME_LENGTH)
	local count = #design.blocks
	local b = buffer.create(1 + 1 + #name + 2 + count * BLOCK_BYTES)
	buffer.writeu8(b, 0, BUFFER_VERSION)
	buffer.writeu8(b, 1, #name)
	buffer.writestring(b, 2, name)
	local offset = 2 + #name
	buffer.writeu16(b, offset, count)
	offset += 2
	for _, block in design.blocks do
		buffer.writeu16(b, offset, block.id)
		buffer.writeu8(b, offset + 2, Parts.get(block.type).SortOrder)
		buffer.writei16(b, offset + 3, block.gx)
		buffer.writei16(b, offset + 5, block.gy)
		buffer.writei16(b, offset + 7, block.gz)
		buffer.writeu8(b, offset + 9, block.rot)
		buffer.writeu8(b, offset + 10, block.stageOverride or NO_STAGE)
		buffer.writeu8(b, offset + 11, block.color or NO_COLOR)
		offset += BLOCK_BYTES
	end
	return b
end

-- Decodes a design buffer. Returns nil and a reason if it is malformed.
function CraftDesign.fromBuffer(b: buffer): (Design?, string?)
	local length = buffer.len(b)
	if length < 4 then
		return nil, "buffer too short"
	end
	if buffer.readu8(b, 0) ~= BUFFER_VERSION then
		return nil, "unsupported buffer version"
	end
	local nameLength = buffer.readu8(b, 1)
	if 2 + nameLength + 2 > length then
		return nil, "buffer too short"
	end
	local design = CraftDesign.new(buffer.readstring(b, 2, nameLength))
	local offset = 2 + nameLength
	local count = buffer.readu16(b, offset)
	offset += 2
	if offset + count * BLOCK_BYTES ~= length then
		return nil, "buffer length mismatch"
	end
	for _ = 1, count do
		local def = Parts.byIndex(buffer.readu8(b, offset + 2))
		if def == nil then
			return nil, "unknown part index"
		end
		local stage = buffer.readu8(b, offset + 10)
		local color = buffer.readu8(b, offset + 11)
		table.insert(design.blocks, {
			id = buffer.readu16(b, offset),
			type = def.Id,
			gx = buffer.readi16(b, offset + 3),
			gy = buffer.readi16(b, offset + 5),
			gz = buffer.readi16(b, offset + 7),
			rot = buffer.readu8(b, offset + 9),
			stageOverride = if stage == NO_STAGE then nil else stage,
			color = if color == NO_COLOR then nil else color,
		})
		offset += BLOCK_BYTES
	end
	return design, nil
end

return table.freeze(CraftDesign)
