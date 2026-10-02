--!strict
-- CHANGED (Memory budget): tests for Render/EditableBudget, the client's single gate for EditableMesh /
-- EditableImage creation: size estimates, priorities and eviction (lower priorities give way, higher ones are never
-- starved by work started earlier), demands, real refusals (cap lowered, one retry, no spam), recovery, an
-- unavailable API, and that each tier's designed load fits its ceiling and the ~80 MiB measured by spike S12.

local TestKit = require(script.Parent.TestKit)
local Render = game:GetService("StarterPlayer").StarterPlayerScripts.Client.Render
local EditableBudget = require(Render.EditableBudget)

--============================================================================
-- Tunables
--============================================================================
local MIB = 1024 * 1024
local S12_POOL = 80 * MIB -- the desktop budget measured by spike S12 (19 x 4 MiB images, 8 meshes)
local ENGINE_MESH_BYTES = 10 * MIB -- what Roblox charged per EditableMesh in S12
--============================================================================

local P = EditableBudget.PRIORITY

type Fake = {
	backend: EditableBudget.Backend,
	pool: number,
	held: number,
	calls: number,
	refusals: number,
	warnings: { string },
	now: number,
	tier: string,
	mobile: boolean,
	fail: string?,
}

-- A fake engine: a pool of `pool` bytes (meshes cost ENGINE_MESH_BYTES), nil when full, an error when `fail` is set.
local function fakeEngine(pool: number, tier: string): Fake
	local fake: Fake
	fake = {
		backend = {
			createMesh = function(): any
				fake.calls += 1
				local failure = fake.fail
				if failure then
					error(failure, 0)
				end
				if fake.held + ENGINE_MESH_BYTES > fake.pool then
					fake.refusals += 1
					return nil
				end
				fake.held += ENGINE_MESH_BYTES
				return { bytes = ENGINE_MESH_BYTES }
			end,
			createImage = function(size: Vector2): any
				fake.calls += 1
				local failure = fake.fail
				if failure then
					error(failure, 0)
				end
				local bytes = size.X * size.Y * 4
				if fake.held + bytes > fake.pool then
					fake.refusals += 1
					return nil
				end
				fake.held += bytes
				return { bytes = bytes }
			end,
			destroy = function(object: any)
				fake.held -= object.bytes
			end,
			clock = function(): number
				return fake.now
			end,
			tier = function(): string
				return fake.tier
			end,
			mobile = function(): boolean
				return fake.mobile
			end,
			warn = function(message: string)
				table.insert(fake.warnings, message)
			end,
		},
		pool = pool,
		held = 0,
		calls = 0,
		refusals = 0,
		warnings = {},
		now = 0,
		tier = tier,
		mobile = false,
		fail = nil,
	}
	EditableBudget._configure(fake.backend)
	return fake
end

local function image(owner: string, size: number, priority: number, release: (() -> ())?): EditableBudget.Handle?
	local _, handle = EditableBudget.createImage(owner, Vector2.new(size, size), priority, release)
	return handle
end

return function(t: TestKit.Context)
	t.test("size estimates: images w*h*4, meshes at least the fixed charge S12 measured", function()
		fakeEngine(S12_POOL, "High")
		t.expectEqual(EditableBudget.imageBytes(256, 256), 256 * 256 * 4)
		t.expectEqual(EditableBudget.meshBytes(625, 1152), EditableBudget.MESH_FIXED_BYTES)
		t.expectTrue(EditableBudget.MESH_FIXED_BYTES >= S12_POOL / 9, "9 meshes must not fit the S12 pool")
		t.expectTrue(EditableBudget.meshBytes(60000, 20000) >= EditableBudget.MESH_FIXED_BYTES)
	end)

	t.test("ceilings stay under the S12 desktop pool with room for each tier's designed load", function()
		for tier, ceiling in EditableBudget.BUDGET_BYTES do
			t.expectTrue(ceiling <= 0.9 * S12_POOL, `{tier}: {ceiling / MIB} MiB`)
			-- planet mesh + (bands + 1 being built) terrain meshes + stars + the base images of the body you are on
			-- (hidden: released) and of the Mun: what the base needs at once
			local bands = if tier == "Low" then 3 else 4
			local base = (1 + bands + 1) * EditableBudget.MESH_FIXED_BYTES
				+ 9 * EditableBudget.imageBytes(256, 256)
				+ 24 * EditableBudget.imageBytes(128, 128)
			t.expectTrue(base <= ceiling, `{tier}: the base needs {base / MIB} MiB`)
		end
	end)

	t.test("phones get the mobile ceiling (room for 3 terrain bands)", function()
		local fake = fakeEngine(S12_POOL, "Medium")
		local desktop = EditableBudget.ceiling()
		fake.mobile = true
		t.expectEqual(EditableBudget.ceiling(), math.min(desktop, EditableBudget.MOBILE_BUDGET_BYTES))
		local base = (1 + 3 + 1) * EditableBudget.MESH_FIXED_BYTES
			+ 9 * EditableBudget.imageBytes(256, 256)
			+ 24 * EditableBudget.imageBytes(128, 128)
		t.expectTrue(base <= EditableBudget.ceiling())
	end)

	t.test("a higher priority evicts lower ones (lowest first) and never asks Roblox in vain", function()
		local fake = fakeEngine(S12_POOL, "High")
		local ceiling = EditableBudget.ceiling()
		local released: { string } = {}
		-- fill the ceiling with clouds (lowest) and slots
		local slotCount, cloudCount = 0, 0
		while EditableBudget.used() + EditableBudget.imageBytes(512, 512) <= ceiling - 8 * MIB do
			slotCount += 1
			local handle: EditableBudget.Handle?
			handle = image("Test.slot", 512, P.SLOT, function()
				table.insert(released, "slot")
				EditableBudget.destroy(handle)
			end)
			t.expectTrue(handle ~= nil)
		end
		while EditableBudget.used() + EditableBudget.imageBytes(512, 512) <= ceiling do
			cloudCount += 1
			local handle: EditableBudget.Handle?
			handle = image("Test.cloud", 512, P.CLOUD, function()
				table.insert(released, "cloud")
				EditableBudget.destroy(handle)
			end)
			t.expectTrue(handle ~= nil)
		end
		t.expectTrue(slotCount > 0 and cloudCount > 0)
		local calls = fake.calls
		-- a terrain band (started later) still gets its mesh: clouds go first, then slots
		local mesh, handle, refusal = EditableBudget.createMesh("TerrainMesh", P.TERRAIN_FAR, nil, 11000, 19000)
		t.expectTrue(mesh ~= nil and handle ~= nil, tostring(refusal))
		t.expectEqual(fake.calls, calls + 1)
		t.expectEqual(released[1], "cloud")
		t.expectTrue(EditableBudget.used() <= ceiling)
		t.expectEqual(fake.refusals, 0)
		-- a lower priority cannot take memory from a non-evictable higher one: refused before Roblox is asked
		while EditableBudget.used() + EditableBudget.MESH_FIXED_BYTES <= ceiling do
			EditableBudget.createMesh("TerrainMesh", P.TERRAIN_FAR, nil)
		end
		calls = fake.calls
		local cloud, _, why = EditableBudget.createImage("Test.cloud", Vector2.new(512, 512), P.CLOUD, nil)
		t.expectEqual(cloud, nil)
		t.expectEqual(why, "budget")
		t.expectEqual(fake.calls, calls)
		t.expectTrue(EditableBudget.stats().deferred >= 1)
	end)

	t.test("demands: lower priorities do not plan with memory a higher one is about to use", function()
		fakeEngine(S12_POOL, "High")
		local ceiling = EditableBudget.ceiling()
		EditableBudget.setDemand("ScaledSpace.base1", 6 * MIB, P.DOMINANT_BASE)
		t.expectEqual(EditableBudget.room(P.TERRAIN_FAR, "TerrainMesh"), ceiling - 6 * MIB)
		t.expectEqual(EditableBudget.room(P.TERRAIN_NEAR, "TerrainMesh"), ceiling)
		-- what the demand already holds is not counted twice
		local h = image("ScaledSpace.base1", 256, P.DOMINANT_BASE, nil)
		t.expectTrue(h ~= nil)
		t.expectEqual(EditableBudget.room(P.TERRAIN_FAR, "TerrainMesh"), ceiling - 6 * MIB)
		-- the owner's own holdings count as available to it
		EditableBudget.createMesh("TerrainMesh", P.TERRAIN_FAR, nil)
		t.expectEqual(EditableBudget.room(P.TERRAIN_FAR, "TerrainMesh"), ceiling - 6 * MIB)
		EditableBudget.setDemand("ScaledSpace.base1", 6 * MIB, P.HIDDEN_BASE)
		t.expectEqual(EditableBudget.room(P.TERRAIN_FAR, "TerrainMesh"), ceiling - 256 * 256 * 4)
	end)

	t.test("a real refusal lowers the cap, frees lower priorities, retries once and warns once", function()
		local fake = fakeEngine(40 * MIB, "High") -- a smaller device than the ceiling assumes
		local released = 0
		for _ = 1, 3 do
			local handle: EditableBudget.Handle?
			handle = image("Test.slot", 1024, P.SLOT, function()
				released += 1
				EditableBudget.destroy(handle)
			end)
		end
		local meshes = 0
		for _ = 1, 6 do
			local mesh = EditableBudget.createMesh("TerrainMesh", P.TERRAIN_FAR, nil)
			if mesh then
				meshes += 1
			end
		end
		-- 40 MiB: 3 x 4 MiB slots + 2 meshes, then the refusal: slots go, a third mesh fits on the retry
		t.expectEqual(meshes, 3)
		t.expectTrue(released >= 1)
		t.expectTrue(EditableBudget.ceiling() < 40 * MIB, `cap {EditableBudget.ceiling() / MIB}`)
		t.expectEqual(#fake.warnings, 1)
		-- after the cap is learned, nothing more is asked of Roblox that would not fit
		local refusals = fake.refusals
		for _ = 1, 5 do
			EditableBudget.createMesh("TerrainMesh", P.TERRAIN_FAR, nil)
		end
		t.expectEqual(fake.refusals, refusals)
		t.expectEqual(#fake.warnings, 1)
		-- the cap creeps back up later
		local cap = EditableBudget.ceiling()
		fake.now += 1000
		t.expectTrue(EditableBudget.ceiling() > cap)
	end)

	t.test("an unavailable API is reported once and never retried", function()
		local fake = fakeEngine(S12_POOL, "Medium")
		fake.fail = "EditableImage is not enabled for this experience"
		local img, _, why = EditableBudget.createImage("Test", Vector2.new(64, 64), P.OTHER_BASE, nil)
		t.expectEqual(img, nil)
		t.expectEqual(why, "unavailable")
		local calls = fake.calls
		local _, _, again = EditableBudget.createImage("Test", Vector2.new(64, 64), P.OTHER_BASE, nil)
		t.expectEqual(again, "unavailable")
		t.expectEqual(fake.calls, calls)
		-- meshes are judged on their own
		fake.fail = nil
		t.expectTrue(EditableBudget.createMesh("ScaledSpace", P.PLANET_MESH, nil) ~= nil)
	end)

	t.test("destroy is idempotent and frees the bytes; priorities can change", function()
		fakeEngine(S12_POOL, "Low")
		local h = image("Test", 256, P.HIDDEN_BASE, nil)
		t.expectTrue(h ~= nil)
		local used = EditableBudget.used()
		EditableBudget.destroy(h)
		EditableBudget.destroy(h)
		t.expectEqual(EditableBudget.used(), used - 256 * 256 * 4)
		t.expectEqual(EditableBudget.stats().images, 0)
		-- a hidden terrain mesh becomes evictable for a visible image
		local freed = false
		local _, mesh = EditableBudget.createMesh("TerrainMesh", P.TERRAIN_FAR, nil)
		EditableBudget.setPriority(mesh, P.HIDDEN_TERRAIN, function()
			freed = true
		end)
		while EditableBudget.used() + EditableBudget.imageBytes(512, 512) <= EditableBudget.ceiling() do
			image("Test.other", 512, P.OTHER_BASE, nil)
		end
		t.expectTrue(image("Test.other", 512, P.OTHER_BASE, nil) ~= nil)
		t.expectTrue(freed)
	end)
end
