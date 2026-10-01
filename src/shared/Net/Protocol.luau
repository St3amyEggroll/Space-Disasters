--!strict
--[[
	Protocol
	Buffer encoding for craft states on the wire (spec 7.7).

	State block (77 bytes): craftId u16, ut f64, bodyId u8, pos 3 x f64, vel 3 x f32, rot quaternion 4 x f32,
	angVel 3 x f32, throttle u8 (0..255), flags u8.
	PilotState (client -> server, 81 bytes) = state block + activeFuel f32 (total fuel left, kg).
	CraftStates (server -> client) = u8 count + count state blocks (at most MAX_STATES_PER_PACKET per packet).
	A lone state (inside reliable messages) = one state block.
	CHANGED (Phase 3): packStateBlocks builds CraftStates packets from blocks encoded once per tick (per-client relay).
	CHANGED (Phase 5): Rails (CraftRails, CraftSpawned info.rails, RequestRails; 101 bytes): craftId u16, bodyId u8,
	epochUT f64, r0 3 x f64, v0 3 x f64, rot quaternion 4 x f32, angVel 3 x f32, com 3 x f32, throttle u8, flags u8.
	r0 AND v0 are doubles: the rail is propagated analytically for hours, so velocity rounding would grow.

	Positions stay f64 (invariant I1); velocities and rotations are small and fine as f32.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

--============================================================================
-- Tunables
--============================================================================
local STATE_BYTES = 77
local PILOT_BYTES = STATE_BYTES + 4
local MAX_PER_PACKET = GameConfig.MAX_STATES_PER_PACKET
local RAILS_BYTES = 101 -- CHANGED (Phase 5)
--============================================================================

-- Structurally identical to FlightModel.CraftState (kept here so Net does not depend on Sim).
export type State = {
	bodyId: number,
	pos: Vec3d.Vec3d,
	vel: Vec3d.Vec3d,
	rot: CFrame,
	angVel: Vector3,
	throttle: number,
	flags: number,
	ut: number,
}

export type Entry = { craftId: number, state: State }

-- CHANGED (Phase 5): the wire part of Rails.Rails (Shared/Sim/Rails rebuilds the derived fields).
export type RailsData = {
	bodyId: number,
	epochUT: number,
	r0: Vec3d.Vec3d,
	v0: Vec3d.Vec3d,
	rot: CFrame,
	angVel: Vector3,
	com: Vector3,
	throttle: number,
	flags: number,
}

local Protocol = {}

Protocol.STATE_BYTES = STATE_BYTES
Protocol.PILOT_BYTES = PILOT_BYTES
Protocol.MAX_PER_PACKET = MAX_PER_PACKET
Protocol.RAILS_BYTES = RAILS_BYTES

local function toQuaternion(cf: CFrame): (number, number, number, number)
	local axis, angle = cf:ToAxisAngle()
	local half = angle / 2
	local s = math.sin(half)
	return axis.X * s, axis.Y * s, axis.Z * s, math.cos(half)
end

local function fromQuaternion(x: number, y: number, z: number, w: number): CFrame
	local len = math.sqrt(x * x + y * y + z * z + w * w)
	if len < 1e-9 then
		return CFrame.identity
	end
	return CFrame.new(0, 0, 0, x / len, y / len, z / len, w / len)
end

local function finite(n: number): boolean
	return n == n and n ~= math.huge and n ~= -math.huge
end

local function writeState(b: buffer, offset: number, craftId: number, state: State)
	buffer.writeu16(b, offset, craftId)
	buffer.writef64(b, offset + 2, state.ut)
	buffer.writeu8(b, offset + 10, state.bodyId)
	buffer.writef64(b, offset + 11, state.pos.x)
	buffer.writef64(b, offset + 19, state.pos.y)
	buffer.writef64(b, offset + 27, state.pos.z)
	buffer.writef32(b, offset + 35, state.vel.x)
	buffer.writef32(b, offset + 39, state.vel.y)
	buffer.writef32(b, offset + 43, state.vel.z)
	local qx, qy, qz, qw = toQuaternion(state.rot)
	buffer.writef32(b, offset + 47, qx)
	buffer.writef32(b, offset + 51, qy)
	buffer.writef32(b, offset + 55, qz)
	buffer.writef32(b, offset + 59, qw)
	buffer.writef32(b, offset + 63, state.angVel.X)
	buffer.writef32(b, offset + 67, state.angVel.Y)
	buffer.writef32(b, offset + 71, state.angVel.Z)
	buffer.writeu8(b, offset + 75, math.clamp(math.round(state.throttle * 255), 0, 255))
	buffer.writeu8(b, offset + 76, bit32.band(state.flags, 255))
end

-- Reads a state block; returns nil if any number is not finite (malformed or hostile packet).
local function readState(b: buffer, offset: number): (number, State?)
	local craftId = buffer.readu16(b, offset)
	local state: State = {
		ut = buffer.readf64(b, offset + 2),
		bodyId = buffer.readu8(b, offset + 10),
		pos = Vec3d.new(buffer.readf64(b, offset + 11), buffer.readf64(b, offset + 19), buffer.readf64(b, offset + 27)),
		vel = Vec3d.new(buffer.readf32(b, offset + 35), buffer.readf32(b, offset + 39), buffer.readf32(b, offset + 43)),
		rot = CFrame.identity,
		angVel = Vector3.new(
			buffer.readf32(b, offset + 63),
			buffer.readf32(b, offset + 67),
			buffer.readf32(b, offset + 71)
		),
		throttle = buffer.readu8(b, offset + 75) / 255,
		flags = buffer.readu8(b, offset + 76),
	}
	local qx, qy, qz, qw =
		buffer.readf32(b, offset + 47),
		buffer.readf32(b, offset + 51),
		buffer.readf32(b, offset + 55),
		buffer.readf32(b, offset + 59)
	for _, n in { state.ut, qx, qy, qz, qw, state.angVel.X, state.angVel.Y, state.angVel.Z } do
		if not finite(n) then
			return craftId, nil
		end
	end
	if not (Vec3d.isFinite(state.pos) and Vec3d.isFinite(state.vel)) then
		return craftId, nil
	end
	state.rot = fromQuaternion(qx, qy, qz, qw)
	return craftId, state
end

function Protocol.encodeState(craftId: number, state: State): buffer
	local b = buffer.create(STATE_BYTES)
	writeState(b, 0, craftId, state)
	return b
end

function Protocol.decodeState(b: unknown): (number?, State?)
	if typeof(b) ~= "buffer" or buffer.len(b :: buffer) ~= STATE_BYTES then
		return nil, nil
	end
	return readState(b :: buffer, 0)
end

function Protocol.encodePilotState(craftId: number, state: State, activeFuel: number): buffer
	local b = buffer.create(PILOT_BYTES)
	writeState(b, 0, craftId, state)
	buffer.writef32(b, STATE_BYTES, activeFuel)
	return b
end

function Protocol.decodePilotState(b: unknown): (number?, State?, number?)
	if typeof(b) ~= "buffer" or buffer.len(b :: buffer) ~= PILOT_BYTES then
		return nil, nil, nil
	end
	local craftId, state = readState(b :: buffer, 0)
	local fuel = buffer.readf32(b :: buffer, STATE_BYTES)
	if state == nil or not finite(fuel) then
		return nil, nil, nil
	end
	return craftId, state, fuel
end

-- Splits entries into as many CraftStates packets as needed.
function Protocol.encodeStates(entries: { Entry }): { buffer }
	local packets: { buffer } = {}
	local index = 1
	while index <= #entries do
		local count = math.min(MAX_PER_PACKET, #entries - index + 1)
		local b = buffer.create(1 + count * STATE_BYTES)
		buffer.writeu8(b, 0, count)
		for k = 0, count - 1 do
			local entry = entries[index + k]
			writeState(b, 1 + k * STATE_BYTES, entry.craftId, entry.state)
		end
		table.insert(packets, b)
		index += count
	end
	return packets
end

-- CHANGED (Phase 3): packs pre-encoded state blocks (Protocol.encodeState results, one per craft, encoded once per
-- relay tick and shared by every client) into CraftStates packets, at most MAX_PER_PACKET blocks each. The bytes are
-- identical to encodeStates for the same states.
function Protocol.packStateBlocks(blocks: { buffer }): { buffer }
	local packets: { buffer } = {}
	local index = 1
	while index <= #blocks do
		local count = math.min(MAX_PER_PACKET, #blocks - index + 1)
		local b = buffer.create(1 + count * STATE_BYTES)
		buffer.writeu8(b, 0, count)
		for k = 0, count - 1 do
			buffer.copy(b, 1 + k * STATE_BYTES, blocks[index + k], 0, STATE_BYTES)
		end
		table.insert(packets, b)
		index += count
	end
	return packets
end

function Protocol.decodeStates(b: unknown): { Entry }
	local result: { Entry } = {}
	if typeof(b) ~= "buffer" then
		return result
	end
	local data = b :: buffer
	local length = buffer.len(data)
	if length < 1 then
		return result
	end
	local count = buffer.readu8(data, 0)
	if length ~= 1 + count * STATE_BYTES then
		return result
	end
	for k = 0, count - 1 do
		local craftId, state = readState(data, 1 + k * STATE_BYTES)
		if state then
			table.insert(result, { craftId = craftId, state = state })
		end
	end
	return result
end

--============================================================================
-- CHANGED (Phase 5): rails
--============================================================================

function Protocol.encodeRails(craftId: number, rails: RailsData): buffer
	local b = buffer.create(RAILS_BYTES)
	buffer.writeu16(b, 0, craftId)
	buffer.writeu8(b, 2, rails.bodyId)
	buffer.writef64(b, 3, rails.epochUT)
	buffer.writef64(b, 11, rails.r0.x)
	buffer.writef64(b, 19, rails.r0.y)
	buffer.writef64(b, 27, rails.r0.z)
	buffer.writef64(b, 35, rails.v0.x)
	buffer.writef64(b, 43, rails.v0.y)
	buffer.writef64(b, 51, rails.v0.z)
	local qx, qy, qz, qw = toQuaternion(rails.rot)
	buffer.writef32(b, 59, qx)
	buffer.writef32(b, 63, qy)
	buffer.writef32(b, 67, qz)
	buffer.writef32(b, 71, qw)
	buffer.writef32(b, 75, rails.angVel.X)
	buffer.writef32(b, 79, rails.angVel.Y)
	buffer.writef32(b, 83, rails.angVel.Z)
	buffer.writef32(b, 87, rails.com.X)
	buffer.writef32(b, 91, rails.com.Y)
	buffer.writef32(b, 95, rails.com.Z)
	buffer.writeu8(b, 99, math.clamp(math.round(rails.throttle * 255), 0, 255))
	buffer.writeu8(b, 100, bit32.band(rails.flags, 255))
	return b
end

-- Returns nil for anything malformed (wrong size, non-finite numbers).
function Protocol.decodeRails(b: unknown): (number?, RailsData?)
	if typeof(b) ~= "buffer" or buffer.len(b :: buffer) ~= RAILS_BYTES then
		return nil, nil
	end
	local data = b :: buffer
	local craftId = buffer.readu16(data, 0)
	local r0 = Vec3d.new(buffer.readf64(data, 11), buffer.readf64(data, 19), buffer.readf64(data, 27))
	local v0 = Vec3d.new(buffer.readf64(data, 35), buffer.readf64(data, 43), buffer.readf64(data, 51))
	local epochUT = buffer.readf64(data, 3)
	local numbers = table.create(13)
	for offset = 59, 95, 4 do
		local n = buffer.readf32(data, offset)
		if not finite(n) then
			return nil, nil
		end
		table.insert(numbers, n)
	end
	if not (finite(epochUT) and Vec3d.isFinite(r0) and Vec3d.isFinite(v0)) then
		return nil, nil
	end
	return craftId,
		{
			bodyId = buffer.readu8(data, 2),
			epochUT = epochUT,
			r0 = r0,
			v0 = v0,
			rot = fromQuaternion(numbers[1], numbers[2], numbers[3], numbers[4]),
			angVel = Vector3.new(numbers[5], numbers[6], numbers[7]),
			com = Vector3.new(numbers[8], numbers[9], numbers[10]),
			throttle = buffer.readu8(data, 99) / 255,
			flags = buffer.readu8(data, 100),
		}
end

return table.freeze(Protocol)
