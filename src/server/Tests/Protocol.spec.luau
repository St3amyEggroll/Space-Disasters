--!strict
-- Tests for Shared/Net/Protocol: every packet type round-trips.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Protocol = require(ReplicatedStorage.Shared.Net.Protocol)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

local function sample(seed: number): Protocol.State
	return {
		bodyId = 2,
		pos = Vec3d.new(450123.25 + seed, -1234.5, 98765.125),
		vel = Vec3d.new(710.5, -3.25, 12),
		rot = CFrame.Angles(0.3 * seed, -1.1, 2.4),
		angVel = Vector3.new(0.1, -0.2, 0.3),
		throttle = 0.5,
		flags = 5,
		ut = 12345.678 + seed,
	}
end

local function same(t: TestKit.Context, a: Protocol.State, b: Protocol.State)
	t.expectEqual(b.bodyId, a.bodyId)
	t.expectEqual(b.pos.x, a.pos.x) -- f64: exact
	t.expectEqual(b.ut, a.ut)
	t.expectNear(b.vel.x, a.vel.x, 1e-3)
	t.expectNear((b.rot.LookVector - a.rot.LookVector).Magnitude, 0, 1e-5)
	t.expectNear((b.rot.UpVector - a.rot.UpVector).Magnitude, 0, 1e-5)
	t.expectNear(b.angVel.Y, a.angVel.Y, 1e-6)
	t.expectNear(b.throttle, a.throttle, 1 / 255)
	t.expectEqual(b.flags, a.flags)
end

return function(t: TestKit.Context)
	t.test("single state round trip (77 bytes)", function()
		local b = Protocol.encodeState(42, sample(1))
		t.expectEqual(buffer.len(b), 77)
		local id, state = Protocol.decodeState(b)
		t.expectEqual(id, 42)
		same(t, sample(1), state :: Protocol.State)
	end)

	t.test("pilot state round trip (81 bytes)", function()
		local b = Protocol.encodePilotState(7, sample(2), 1234.5)
		t.expectEqual(buffer.len(b), 81)
		local id, state, fuel = Protocol.decodePilotState(b)
		t.expectEqual(id, 7)
		t.expectNear(fuel :: number, 1234.5, 1e-3)
		same(t, sample(2), state :: Protocol.State)
	end)

	t.test("craft states split into packets under the payload limit", function()
		local entries = {}
		for i = 1, 25 do
			table.insert(entries, { craftId = i, state = sample(i) })
		end
		local packets = Protocol.encodeStates(entries)
		t.expectEqual(#packets, 3)
		local seen = 0
		for _, packet in packets do
			t.expectTrue(buffer.len(packet) <= 900, "packet size " .. buffer.len(packet))
			for _, entry in Protocol.decodeStates(packet) do
				seen += 1
				same(t, sample(entry.craftId), entry.state)
			end
		end
		t.expectEqual(seen, 25)
	end)

	-- CHANGED (Phase 3): the per-client relay packs blocks encoded once per tick
	t.test("packed state blocks match encodeStates byte for byte", function()
		local entries = {}
		local blocks = {}
		for i = 1, 23 do
			table.insert(entries, { craftId = i, state = sample(i) })
			table.insert(blocks, Protocol.encodeState(i, sample(i)))
		end
		local encoded = Protocol.encodeStates(entries)
		local packed = Protocol.packStateBlocks(blocks)
		t.expectEqual(#packed, #encoded)
		for index, packet in packed do
			t.expectEqual(buffer.tostring(packet), buffer.tostring(encoded[index]))
			t.expectTrue(buffer.len(packet) <= 900, "packet size " .. buffer.len(packet))
		end
		t.expectEqual(#Protocol.packStateBlocks({}), 0)
	end)

	t.test("malformed packets are rejected", function()
		t.expectTrue((Protocol.decodeState(buffer.create(10))) == nil)
		t.expectTrue((Protocol.decodePilotState("nope")) == nil)
		local bad = Protocol.encodeState(1, sample(1))
		buffer.writef64(bad, 11, 0 / 0) -- NaN position
		local _, state = Protocol.decodeState(bad)
		t.expectTrue(state == nil)
		t.expectEqual(#Protocol.decodeStates(buffer.create(5)), 0)
	end)
end
