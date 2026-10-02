--!strict
--[[
	EditableBudget (CHANGED (Memory budget): Studio's first run after the terrain polish and planet detail printed
	"Failed to create empty EditableMesh / EditableImage ... reaching memory budget limits", the terrain dropped bands
	and rebuilt from scratch, the detail / cloud textures switched off and the Mun stayed a grey ball)

	The one place every EditableMesh / EditableImage of the client is created. Roblox gives each client ONE memory
	budget for both kinds; when it is full, creation fails (and the engine prints a line we cannot suppress). Here
	every creation states an estimated size and a priority, and the module keeps the total under a conservative,
	per-tier ceiling: lower-priority holders give their memory back (their `release` callback falls back cleanly:
	a detail slot -> the base image, a cloud patch -> hidden, hidden terrain -> released) before a higher-priority
	request is refused, so work started earlier never starves more important work started later.

	Size estimates (bytes):
	  * EditableImage: width x height x 4 (RGBA8). Spike S12: 19 images of 1024 x 1024 (19 x 4 MiB) fit, the 20th
	    was refused, so the budget on a desktop in Studio is about 80 MiB.
	  * EditableMesh: max(MESH_FIXED_BYTES, vertices x BYTES_PER_VERTEX + triangles x BYTES_PER_TRIANGLE). S12: 8
	    meshes fit whether they held 81 or 4,225 vertices (the 9th was refused): an empty, growable EditableMesh is
	    charged a fixed ~10 MiB (80 MiB / 8) whatever it holds. A terrain band (~11k vertices, ~18k triangles) is
	    ~1.3 MB by content, so the fixed charge is what counts; the content term is kept as a safety net.
	  The Studio log matches this model: 7 terrain meshes + the planet mesh (80 MiB) plus the base / detail images
	  hit the budget first for a mesh, then for a 64 KB Mun image.

	Ceiling: BUDGET_BYTES per Quality tier (below the ~80 MiB measured on a desktop), at most MOBILE_BUDGET_BYTES on
	phones / tablets (Quality caps them at Medium; their real budget was never measured).
	Real refusals (Create* returned nil or raised a budget error) lower a learned cap to what we held (that much
	fit; REFUSAL_MARGIN less), free lower-priority holders and retry ONCE; the cap creeps back up by RECOVER_STEP every
	RECOVER_S without refusals (at most MAX_REFUSALS refusals per session, then it stays down). Every subsystem warns
	once at most (warnOnce); this module warns once on the first real refusal.

	Demands: a subsystem may declare what it wants at a priority before it holds it (setDemand), e.g. the Earth's
	base images while its proxy is drawn. room() subtracts the unfilled demand of higher priorities, so a lower
	priority (far terrain bands) never plans to use memory a higher one is about to need.

	API:
		EditableBudget.PRIORITY                                    named priorities (higher wins)
		EditableBudget.imageBytes(w, h): number
		EditableBudget.meshBytes(vertices?, triangles?): number
		EditableBudget.createImage(owner, size, priority, release?)  -> (EditableImage?, Handle?, Refusal?)
		EditableBudget.createMesh(owner, priority, release?, vertices?, triangles?) -> (EditableMesh?, Handle?, Refusal?)
		EditableBudget.destroy(handle)                             destroys the object, frees its bytes (idempotent)
		EditableBudget.setPriority(handle, priority, release?)     release nil: never evicted
		EditableBudget.setDemand(name, bytes, priority)            0 bytes clears it
		EditableBudget.room(priority, owner?): number              bytes a request at `priority` could get (owner's
		                                                           own holdings counted as available to it)
		EditableBudget.ceiling() / used(): number
		EditableBudget.stats(): Stats
		EditableBudget.warnOnce(key, message)
		EditableBudget.summary(): string                           F3 debug line
		EditableBudget._configure(backend)                         offline tests / simulations
	Refusal: "budget" (no room now: fall back and retry later) or "unavailable" (the API is off: give up).
	`owner` is "<Subsystem>" or "<Subsystem>.<group>"; demands are matched to holders by owner.
]]

--============================================================================
-- Tunables
--============================================================================
local MIB = 1024 * 1024
-- Conservative ceilings (the desktop budget is ~80 MiB, S12). What fits under them by design is listed in
-- Render/PlanetDetail (images) and Render/TerrainMesh (bands).
local BUDGET_BYTES: { [string]: number } = {
	Low = 56 * MIB,
	Medium = 66 * MIB,
	High = 70 * MIB,
}
local MOBILE_BUDGET_BYTES = 56 * MIB -- phones / tablets (Medium at most): their budget is unknown and likely smaller
local FALLBACK_BUDGET = 56 * MIB
local BYTES_PER_PIXEL = 4
local MESH_FIXED_BYTES = 10 * MIB -- S12: 8 meshes of any size filled the ~80 MiB budget
local BYTES_PER_VERTEX = 64 -- position, normal, colour, UV and the engine's index / bookkeeping, rounded up
local BYTES_PER_TRIANGLE = 48 -- three vertex ids, face normals / colours / UV ids, rounded up
local REFUSAL_MARGIN = 0 -- after a real refusal the cap is what we held (it fit) minus this
local FLOOR_BYTES = 16 * MIB -- the learned cap never drops below this
local RECOVER_S = 20 -- s without refusals before the learned cap is raised again ...
local RECOVER_STEP = 4 * MIB -- ... by this much
local MAX_REFUSALS = 4 -- real refusals per session after which the learned cap stays where it is
-- Named priorities (higher wins; only holders with a release callback and a LOWER priority are ever evicted)
local PRIORITY = table.freeze({
	PLANET_MESH = 110, -- ScaledSpace's shared patch mesh (every planet proxy)
	TERRAIN_NEAR = 100, -- the terrain band under the camera (and the mesh being built for it)
	STARS = 95, -- SkyCube's star images (small)
	DOMINANT_BASE = 90, -- base images of the body the camera is near, while its proxy is drawn
	OTHER_BASE = 80, -- base images of the other bodies (the Mun seen from Earth)
	TERRAIN_FAR = 70, -- the other terrain bands
	HIDDEN_BASE = 40, -- base images of the dominant body while its proxy is hidden (surface view)
	SLOT = 30, -- detail slots
	CLOUD = 20, -- cloud shell images
	HIDDEN_TERRAIN = 10, -- terrain meshes while no ground is drawn or prebuilt
})
--============================================================================

export type Kind = "Mesh" | "Image"
export type Refusal = string -- "budget" | "unavailable" (a plain string: literal unions widen across requires)
export type Handle = {
	id: number,
	owner: string,
	kind: Kind,
	bytes: number,
	priority: number,
	release: (() -> ())?,
	object: any,
	alive: boolean,
}
export type Stats = {
	used: number,
	ceiling: number,
	peak: number,
	meshes: number,
	images: number,
	created: number,
	deferred: number, -- requests refused before asking Roblox (no room for their priority)
	evicted: number, -- holders released for a higher priority
	refusals: number, -- real refusals by Roblox
}
-- What creates the objects (Roblox's AssetService by default; offline tests pass their own).
export type Backend = {
	createMesh: () -> any,
	createImage: (size: Vector2) -> any,
	destroy: (object: any) -> (),
	clock: () -> number,
	tier: () -> string,
	mobile: () -> boolean,
	warn: (message: string) -> (),
}
type Demand = { bytes: number, priority: number }

local EditableBudget = {}
EditableBudget.PRIORITY = PRIORITY
EditableBudget.MESH_FIXED_BYTES = MESH_FIXED_BYTES

-- Roblox's own backend (required lazily: offline tests configure their own and never load Quality).
local function defaultBackend(): Backend
	local AssetService = game:GetService("AssetService")
	local Quality = require(script.Parent.Quality)
	return {
		createMesh = function(): any
			return AssetService:CreateEditableMesh()
		end,
		createImage = function(size: Vector2): any
			return AssetService:CreateEditableImage({ Size = size })
		end,
		destroy = function(object: any)
			object:Destroy()
		end,
		clock = os.clock,
		tier = function(): string
			return Quality.tier()
		end,
		mobile = function(): boolean
			return Quality.isMobile()
		end,
		warn = function(message: string)
			warn(message)
		end,
	}
end

local backend: Backend? = nil
local holders: { [number]: Handle } = {}
local demands: { [string]: Demand } = {}
local nextId = 0
local usedBytes = 0
local learnedCap = math.huge
local lastRefusal = -math.huge
local warned: { [string]: boolean } = {}
local stats: Stats = {
	used = 0,
	ceiling = 0,
	peak = 0,
	meshes = 0,
	images = 0,
	created = 0,
	deferred = 0,
	evicted = 0,
	refusals = 0,
}
local unavailable: { [Kind]: string } = {}

local onTierChanged: () -> () = function() end -- set below (enforce)

local function getBackend(): Backend
	local b = backend
	if b == nil then
		local fresh = defaultBackend()
		backend = fresh
		-- the tier's budget changed: free what no longer fits (evictable holders; terrain shrinks on its next plan)
		local Quality = require(script.Parent.Quality)
		Quality.onChanged(function()
			onTierChanged()
		end)
		return fresh
	end
	return b
end

function EditableBudget.warnOnce(key: string, message: string)
	if warned[key] then
		return
	end
	warned[key] = true
	getBackend().warn(message)
end

function EditableBudget.imageBytes(width: number, height: number): number
	return math.max(width, 1) * math.max(height, 1) * BYTES_PER_PIXEL
end

function EditableBudget.meshBytes(vertices: number?, triangles: number?): number
	return math.max(MESH_FIXED_BYTES, (vertices or 0) * BYTES_PER_VERTEX + (triangles or 0) * BYTES_PER_TRIANGLE)
end

-- The ceiling now: the tier's budget, the learned cap (after real refusals), raised again over time.
function EditableBudget.ceiling(): number
	local b = getBackend()
	local tierBudget = BUDGET_BYTES[b.tier()] or FALLBACK_BUDGET
	if b.mobile() then
		tierBudget = math.min(tierBudget, MOBILE_BUDGET_BYTES)
	end
	if learnedCap < tierBudget and stats.refusals < MAX_REFUSALS and b.clock() - lastRefusal >= RECOVER_S then
		learnedCap += RECOVER_STEP
		lastRefusal = b.clock() -- the next step waits RECOVER_S again
	end
	return math.min(tierBudget, learnedCap)
end

function EditableBudget.used(): number
	return usedBytes
end

local function ownerOf(owner: string): string
	return string.match(owner, "^[^%.]+") or owner
end

-- Bytes held by holders of `owner` (a demand's name).
local function heldBy(owner: string): number
	local bytes = 0
	for _, h in holders do
		if h.owner == owner then
			bytes += h.bytes
		end
	end
	return bytes
end

-- Could holder `h` be evicted for a request at `priority`?
local function evictable(h: Handle, priority: number): boolean
	return h.release ~= nil and h.priority < priority
end

--[[
	Bytes a request at `priority` could get: the ceiling minus what it cannot take (holders it may not evict) minus
	the unfilled demand of higher priorities; `owner`'s own holdings count as available to it.
]]
function EditableBudget.room(priority: number, owner: string?): number
	local blocked = 0
	for _, h in holders do
		if not evictable(h, priority) and h.owner ~= owner and (owner == nil or ownerOf(h.owner) ~= owner) then
			blocked += h.bytes
		end
	end
	for name, d in demands do
		if d.priority > priority and name ~= owner then
			blocked += math.max(d.bytes - heldBy(name), 0)
		end
	end
	return EditableBudget.ceiling() - blocked
end

function EditableBudget.setDemand(name: string, bytes: number, priority: number)
	if bytes <= 0 then
		demands[name] = nil
	else
		local d = demands[name]
		if d then
			d.bytes, d.priority = bytes, priority
		else
			demands[name] = { bytes = bytes, priority = priority }
		end
	end
end

local function forget(h: Handle)
	if holders[h.id] == nil then
		return
	end
	holders[h.id] = nil
	usedBytes -= h.bytes
	if h.kind == "Mesh" then
		stats.meshes -= 1
	else
		stats.images -= 1
	end
end

function EditableBudget.destroy(handle: Handle?)
	if handle == nil or not handle.alive then
		return
	end
	handle.alive = false
	forget(handle)
	local object = handle.object
	handle.object = nil
	if object ~= nil then
		pcall(getBackend().destroy, object)
	end
end

function EditableBudget.setPriority(handle: Handle?, priority: number, release: (() -> ())?)
	if handle and handle.alive then
		handle.priority = priority
		handle.release = release
	end
end

-- The evictable holder to free first for a request at `priority`: the lowest priority, then the newest.
local function victim(priority: number): Handle?
	local best: Handle? = nil
	for _, h in holders do
		if evictable(h, priority) then
			local b = best
			if b == nil or h.priority < b.priority or (h.priority == b.priority and h.id > b.id) then
				best = h
			end
		end
	end
	return best
end

-- Frees lower-priority holders until `bytes` more fit under the ceiling. False when they cannot.
local function makeRoom(bytes: number, priority: number): boolean
	local ceiling = EditableBudget.ceiling()
	while usedBytes + bytes > ceiling do
		local h = victim(priority)
		if h == nil then
			return false
		end
		stats.evicted += 1
		local release = h.release
		if release then
			local ok, err = pcall(function()
				release()
			end)
			if not ok then
				EditableBudget.warnOnce("release:" .. h.owner, `[EditableBudget] {h.owner} failed to release: {err}`)
			end
		end
		EditableBudget.destroy(h) -- whatever the callback did, the object goes
	end
	return true
end

-- Frees what no longer fits after the ceiling went down (tier change, learned cap): evictable holders only.
local function enforce()
	makeRoom(0, math.huge)
end

local function isBudgetError(message: string): boolean
	local lower = string.lower(message)
	return string.find(lower, "budget", 1, true) ~= nil or string.find(lower, "memory", 1, true) ~= nil
end

local function attempt(kind: Kind, size: Vector2?): (any, string?)
	local b = getBackend()
	local ok, result = pcall(function(): any
		if kind == "Mesh" then
			return b.createMesh()
		end
		return b.createImage(size :: Vector2)
	end)
	if not ok then
		return nil, tostring(result)
	end
	return result, nil
end

local REFUSED_BUDGET: Refusal = "budget"
local REFUSED_UNAVAILABLE: Refusal = "unavailable"

local function create(
	owner: string,
	kind: Kind,
	bytes: number,
	priority: number,
	release: (() -> ())?,
	size: Vector2?
): (any, Handle?, Refusal?)
	if unavailable[kind] then
		return nil, nil, REFUSED_UNAVAILABLE
	end
	-- 1. room for this priority (no Roblox call when there is none: no engine error line)
	if bytes > EditableBudget.room(priority, nil) or not makeRoom(bytes, priority) then
		stats.deferred += 1
		return nil, nil, REFUSED_BUDGET
	end
	-- 2. ask Roblox; on a real budget refusal lower the cap, free lower priorities and retry once
	local object, err = attempt(kind, size)
	if object == nil and err ~= nil and not isBudgetError(err) then
		unavailable[kind] = err
		return nil, nil, REFUSED_UNAVAILABLE
	end
	if object == nil then
		local b = getBackend()
		stats.refusals += 1
		lastRefusal = b.clock()
		local before = EditableBudget.ceiling()
		learnedCap = math.max(FLOOR_BYTES, math.min(learnedCap, usedBytes - REFUSAL_MARGIN))
		EditableBudget.warnOnce(
			"refused",
			string.format(
				"[EditableBudget] Roblox refused an Editable%s with ~%.0f MiB in use (ceiling %.0f MiB); holding at"
					.. " most %.0f MiB for now (far terrain, detail textures and clouds give way first).",
				kind,
				usedBytes / MIB,
				before / MIB,
				EditableBudget.ceiling() / MIB
			)
		)
		if not makeRoom(bytes, priority) then
			return nil, nil, REFUSED_BUDGET
		end
		object, err = attempt(kind, size)
		if object == nil then
			if err ~= nil and not isBudgetError(err) then
				unavailable[kind] = err
				return nil, nil, REFUSED_UNAVAILABLE
			end
			stats.refusals += 1
			learnedCap = math.max(FLOOR_BYTES, math.min(learnedCap, usedBytes - REFUSAL_MARGIN))
			enforce()
			return nil, nil, REFUSED_BUDGET
		end
	end
	nextId += 1
	local handle: Handle = {
		id = nextId,
		owner = owner,
		kind = kind,
		bytes = bytes,
		priority = priority,
		release = release,
		object = object,
		alive = true,
	}
	holders[handle.id] = handle
	usedBytes += bytes
	stats.created += 1
	stats.peak = math.max(stats.peak, usedBytes)
	if kind == "Mesh" then
		stats.meshes += 1
	else
		stats.images += 1
	end
	return object, handle, nil
end

function EditableBudget.createImage(
	owner: string,
	size: Vector2,
	priority: number,
	release: (() -> ())?
): (EditableImage?, Handle?, Refusal?)
	local object, handle, refusal =
		create(owner, "Image", EditableBudget.imageBytes(size.X, size.Y), priority, release, size)
	return object :: EditableImage?, handle, refusal :: Refusal?
end

function EditableBudget.createMesh(
	owner: string,
	priority: number,
	release: (() -> ())?,
	vertices: number?,
	triangles: number?
): (EditableMesh?, Handle?, Refusal?)
	local object, handle, refusal =
		create(owner, "Mesh", EditableBudget.meshBytes(vertices, triangles), priority, release, nil)
	return object :: EditableMesh?, handle, refusal :: Refusal?
end

-- Why the last creation of `kind` could not happen at all (the API is off), or nil.
function EditableBudget.unavailableReason(kind: Kind): string?
	return unavailable[kind]
end

function EditableBudget.stats(): Stats
	stats.used = usedBytes
	stats.ceiling = EditableBudget.ceiling()
	return table.clone(stats)
end

-- F3 debug line.
function EditableBudget.summary(): string
	local s = EditableBudget.stats()
	return string.format(
		"Editable: %.1f / %.0f MiB (peak %.1f)  meshes %d  images %d  deferred %d  evicted %d  refused %d",
		s.used / MIB,
		s.ceiling / MIB,
		s.peak / MIB,
		s.meshes,
		s.images,
		s.deferred,
		s.evicted,
		s.refusals
	)
end

-- Offline tests / simulations: a fresh module state with another backend.
function EditableBudget._configure(custom: Backend)
	backend = custom
	table.clear(holders)
	table.clear(demands)
	table.clear(warned)
	table.clear(unavailable)
	nextId = 0
	usedBytes = 0
	learnedCap = math.huge
	lastRefusal = -math.huge
	stats.used, stats.ceiling, stats.peak, stats.meshes, stats.images = 0, 0, 0, 0, 0
	stats.created, stats.deferred, stats.evicted, stats.refusals = 0, 0, 0, 0
end

onTierChanged = enforce

EditableBudget.BUDGET_BYTES = table.freeze(table.clone(BUDGET_BYTES))
EditableBudget.MOBILE_BUDGET_BYTES = MOBILE_BUDGET_BYTES

return EditableBudget
