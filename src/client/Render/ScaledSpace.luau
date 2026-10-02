--!strict
--[[
	ScaledSpace (universe render layer 2)
	Draws every celestial body as a small "proxy" near the camera: a body at true distance D with radius R is drawn at
	a fake distance d with radius r = R * d / D, so its angular size is exact while everything stays inside the
	engine's draw distance. The Sun is a Neon ball with a BillboardGui glow.

	  ScaledSpace.init(parent)             creates every part under `parent` (yields once for CreateMeshPartAsync)
	  ScaledSpace.update(ctx, forceScaled?) once per frame, after the camera moved (CHANGED (Night review):
	                                       forceScaled: no surface handover, the main menu view)
	  ScaledSpace.isSurfaceMode()          true while the dominant body's proxy is hidden (the Surface layer draws)
	  ScaledSpace.proxyMinAltitude(id)     current proxy -> surface handover altitude for that body (m)

	Fake distance (spec 7.6): d = near + (far - near) * clamp((ln D - LOG_D_MIN) / (LOG_D_MAX - LOG_D_MIN), 0, 1),
	monotonic in D. near / far / the largest proxy radius are scaled down to the measured draw distance (D10).
	Then, in order of true distance:
	  * dominant body: pushed out to d >= NEAR_RENDER_RADIUS / (1 - R/D) so the proxy's nearest surface point stays
	    outside the true-scale near zone. Together with the cap below this gives r = maxRadius at the handover
	    altitude PROXY_MIN_ALT = NEAR_RENDER_RADIUS * R / maxRadius, which is what the Surface layer relies on.
	  * depth order: every body's nearest surface is kept behind the centres of all nearer bodies, so a planet
	    always hides whatever is behind it (the dominant proxy can be pushed far out at low altitude).
	  * caps: r <= maxRadius (d <= maxRadius * D / R), and the limb distance d * sqrt(1 - (R/D)^2) <= 0.85 *
	    drawDistance (CHANGED Phase 2a: the far hemisphere is never visible, so only the limb must stay drawn).

	Proxy mesh (D11): all 24 cube-sphere patches are rotated copies of ONE shared EditableMesh holding the quarter
	of the +Y cube face with x, z in [-1, 0], projected on the unit sphere. The 24 proper rotations of the cube map
	that quarter onto the 24 face quarters one-to-one. If EditableMesh is unavailable (e.g. a published place
	without "Allow Mesh / Image APIs") each body falls back to one Ball part (radius <= 1024).

	All positions are camera-relative (camera position + direction * d), so any pocket slot renders the same.
	Planets do not rotate in v1: body axes = universe axes, which are frame.refRotInv in the pocket.

	CHANGED (Phase 2a feedback): textured planets. The shared patch mesh has UVs (Biome's texture-space mapping),
	and every patch MeshPart gets its own EditableImage painted from Biome (Earth's continents, oceans, ice caps;
	Mun's maria and craters). Images are painted progressively by a background thread (init spawns it) that
	yields every TEXTURE_BUDGET_S of work; until a patch is ready it shows the body's average biome colour.
	Earth also gets a cloud shell (24 more patch clones with a transparent cloud texture via SurfaceAppearance)
	and an atmosphere shell (translucent patch clones in the body's AtmosphereColor: a halo around the limb).
	If EditableImage or SurfaceAppearance texturing is unavailable, the planets stay flat-coloured / cloudless
	with one warning.

	CHANGED (Planet detail): Steamy: "when i am in orbit i feel like the planet is a small little planet by the level
	of detail on it". Per graphics tier (Render/Quality, settings in Render/PlanetDetail):
	  * detail slots: besides its base image every patch near the camera's ground point gets a sharper one (High 8 x
	    1024 px, Medium 6 x 512, Low 2 x 512 on Earth; half on the Mun; CHANGED (Memory budget): now High 4 x 512,
	    Medium 2 x 512, none on Low, 2 x 256 on the Mun). The background painter moves the slots to
	    the nearest patches of the dominant body (with hysteresis) and swaps a patch back to its base image when its
	    slot moves on, in the same frame the slot's new pixels are written, so nothing ever shows wrong pixels.
	  * every ground texture bakes in the relief shade of the real ground (Sim/Relief through BiomeDetail): valleys
	    and crater bowls darker, crests lighter, slopes shaded.
	  * paint order: the dominant body's base images nearest first, then its slots, then clouds, then other bodies.
	    Work per frame is the tier's paintBudgetS; one painter step is a fraction of a millisecond.
	  * atmosphere: up to four nested shells (pale near the ground, deeper blue above), so the halo beyond the limb
	    fades outward; Low keeps the single original shell.
	  * clouds (Medium+): a sparse wispy shell whose alpha comes from its texture (MeshPart.TextureContent, which
	    scripts may write, unlike SurfaceAppearance.ColorMapContent), fading out toward the proxy handover altitude
	    (the surface view below it draws no cloud shell).
	The proxy mesh stays 24 x 24 quads per patch: its chord sag (~8 m on the 60 km Earth) is ~0.2 px at the limb
	seen from 10 km, so a finer mesh would add triangles nobody can see.

	CHANGED (Memory budget): every EditableMesh / EditableImage goes through Render/EditableBudget (one memory budget
	for the whole client, shared with the terrain meshes). Studio ran out of it ("reaching memory budget limits"):
	the detail slots and clouds switched off for the session and the Mun stayed a grey ball. Now:
	  * priorities: the patch mesh (top), base images of the dominant body while its proxy is drawn, base images of
	    the other bodies (the Mun is always painted; above the far terrain bands), base images of the dominant body
	    while the surface view hides it, detail slots, clouds (lowest). A lower priority gives its image back when
	    a higher one needs the memory: a slot's patch shows its base image again, a cloud patch hides.
	  * a refused image is retried after REFUSED_RETRY_S (nothing switches off for the session any more, unless the
	    API itself is unavailable); one warning if base images had to wait (slots and clouds wait silently)
	  * painted base pixels are kept in Lua buffers (normal memory, not the Editable budget), so a released base
	    image comes back in a frame without repainting
	  * released when not needed for HIDDEN_RELEASE_S: the dominant body's images while the surface view hides its
	    proxy (restored from the buffers just before the handover), detail slots below / far above their altitude
	    band, cloud images while the cloud shell is invisible
	  * paint order: the dominant body's base images first; the other bodies, slots and clouds only once the terrain
	    around the camera is built (setExtrasGate, at most STARTUP_HOLD_S after init), so nothing that is not on
	    screen competes with the base's ground at join
	  * a patch without an image shows its own average colour (sampled from Biome: maria darker, highlands lighter)
	    instead of the body's single average grey
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local EditableBudget = require(script.Parent.EditableBudget) -- CHANGED (Memory budget)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local PlanetDetail = require(script.Parent.PlanetDetail) -- CHANGED (Planet detail)
local Quality = require(script.Parent.Quality) -- CHANGED (Planet detail)
local Relief = require(ReplicatedStorage.Shared.Sim.Relief) -- CHANGED (Planet detail)
local RenderContext = require(script.Parent.RenderContext)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local PATCH_SUBDIVISIONS = 24 -- quads per patch edge: 625 vertices, 1152 triangles per patch
local MAX_PART_SIZE = 2048 -- engine limit per axis
local FALLBACK_MAX_RADIUS = 1024 -- Ball fallback: 2048-stud diameter limit
local SIZE_REWRITE_THRESHOLD = 0.003 -- only rewrite Size when the radius changed by more than 0.3%

local DRAW_DISTANCE_CAP = 20000 -- studs; drawDistance above this (or unknown / infinite) is treated as this
local BUDGET_FRACTION = 0.85 -- everything stays within this fraction of the draw distance
local FAR_EDGE_ALLOWANCE = 0.02 -- room for the radius of the farthest proxies when scaling near / far
local MIN_DISTANCE_SCALE = 0.15 -- near / far never shrink below this fraction of the config values
local NEAR_FLOOR_FRACTION = 0.5 -- near >= NEAR_RENDER_RADIUS * this (unless far itself is smaller)
local MIN_PROXY_RADIUS = 20 -- studs; floor for the largest proxy radius on absurdly small draw distances
local DEPTH_ORDER_GAP = 1.01 -- a farther body's nearest surface stays 1% behind nearer bodies' centres
local MAX_SIN_RADIUS = 0.9999 -- R / D at or above this means the camera is (almost) inside the body: hidden

local SUN_MIN_APPARENT_RADIUS_DEG = 0.6 -- the real 0.27 deg sun is too small to read on screen
local SUN_GLOW_DIAMETERS = 7 -- glow billboard size in sun diameters
-- Concentric glow discs (size as a fraction of the billboard, transparency), outermost first.
local SUN_GLOW_LAYERS: { { size: number, transparency: number } } = {
	{ size = 1.0, transparency = 0.94 },
	{ size = 0.72, transparency = 0.88 },
	{ size = 0.5, transparency = 0.78 },
	{ size = 0.34, transparency = 0.6 },
	{ size = 0.22, transparency = 0.35 },
}

local PATCH_MATERIAL = Enum.Material.SmoothPlastic

-- CHANGED (Phase 2a feedback): planet textures, clouds and atmosphere
-- CHANGED (Planet detail): texture sizes, detail slots, atmosphere layers, cloud shell and paint budgets per tier
-- live in Render/PlanetDetail
type TextureSpec = PlanetDetail.TextureSpec
-- CHANGED (Memory budget): MAX_EDITABLE_IMAGES is gone: Render/EditableBudget holds every image under one ceiling
-- CHANGED (Phase 2a playtest): Studio refused SurfaceAppearance.ColorMapContent from game scripts ("lacking
-- capability Plugin"), so the cloud shell cannot be made at runtime; off until clouds have another route.
-- CHANGED (Planet detail): clouds are back through MeshPart.TextureContent (an EditableImage with alpha, which
-- scripts may set), sparse and wispy, Medium+ only (PlanetDetail.cloudTexture)
local CLOUDS_ENABLED = true
local CLOUD_MIN_TRANSPARENCY = 0.04 -- the cloud parts always render in the transparent pass (texture alpha)
local CLOUD_FADE_STEP = 0.02 -- rewrite cloud part transparency when the fade moved by more than this
local ATMOSPHERE_ENABLED = true
local ATMOSPHERE_MATERIAL = Enum.Material.SmoothPlastic -- lit by the sun; ForceField / Neon glow instead
local RELIEF_SHADE = true -- CHANGED (Planet detail): bake the ground's relief shade into the ground textures
local SLOT_SWAP_MARGIN = 0.02 -- a detail slot moves only to a patch this much closer (cos) than the one it shows
local PAINT_IDLE_S = 0.25 -- nothing to paint: look again after this long
-- CHANGED (Memory budget)
local REFUSED_RETRY_S = 5 -- s before a kind of image refused by the memory budget is asked for again
local HIDDEN_RELEASE_S = 10 -- s an image is not needed (hidden proxy, slots / clouds not shown) before it goes
local RESTORE_FRACTION = 0.75 -- the dominant body's base images come back above this x the handover altitude
local CLOUD_PREPAINT = 1.3 -- cloud images are made once the shell would show at this x the camera's altitude
local STARTUP_HOLD_S = 20 -- s after init the extras (other bodies, slots, clouds) wait for the terrain at most
local PATCH_COLOR_SAMPLES = 5 -- per patch edge: the patch's own average colour (shown while it has no image)
local MAX_SHELL_SCALE = math.max(1, PlanetDetail.MAX_SHELL_SCALE) -- largest patch clone per body
local SUN_MATERIAL = Enum.Material.Neon
local RENDER_FIDELITY = Enum.RenderFidelity.Precise -- no LOD decimation of the silhouette
local COLLISION_FIDELITY = Enum.CollisionFidelity.Box -- never collides; keeps creation cheap

local NEAR_RENDER_RADIUS = GameConfig.NEAR_RENDER_RADIUS
local SCALED_NEAR = GameConfig.SCALED_NEAR
local SCALED_FAR = GameConfig.SCALED_FAR
local PROXY_MAX_RADIUS = GameConfig.PROXY_MAX_RADIUS
local LOG_D_MIN = GameConfig.LOG_D_MIN
local LOG_D_MAX = GameConfig.LOG_D_MAX
local HYSTERESIS = GameConfig.PROXY_HANDOVER_HYSTERESIS
--============================================================================

type Point = { x: number, y: number, z: number }

-- Unit-sphere patch geometry in plain numbers (testable offline).
type PatchGeometry = {
	points: { Point }, -- unit-sphere vertex directions, index = i * (n + 1) + j + 1 (i along x, j along z)
	uvs: { { number } }, -- CHANGED (Phase 2a feedback): texture UV {u, v} per point (Biome texture space)
	triangles: { { number } }, -- vertex index triples, counter-clockwise seen from outside
	centre: Point, -- bounding-box centre
	size: Point, -- bounding-box size
}

-- What the pure distance solver needs per drawn body.
type Entry = {
	D: number, -- true distance camera -> body centre (m); math.huge for the sun
	s: number, -- R / D = sine of the angular radius
	dominant: boolean,
	active: boolean, -- drawn this frame (hidden bodies do not take part in depth ordering)
	d: number, -- out: fake centre distance (studs)
	r: number, -- out: fake radius (studs)
}

type Limits = {
	near: number, -- studs, fake distance of the nearest bodies
	far: number, -- studs, fake distance of the farthest bodies
	budget: number, -- studs, nothing may reach farther than this
	maxRadius: number, -- studs, largest proxy radius
}

type Kind = "Patches" | "Ball" | "Sun"

type Slot = {
	image: EditableImage?,
	handle: EditableBudget.Handle?, -- CHANGED (Memory budget)
	size: number, -- pixels per side of `image` (0 = none yet)
	visual: Visual?, -- the body whose patch shows it
	patch: number, -- that patch (0 = none)
}

type Visual = {
	id: number,
	radius: number, -- true radius (m); 0 for the sun
	kind: Kind,
	parts: { BasePart },
	-- CHANGED (Phase 2a feedback): per part (Patches only): cube rotation index, radius scale of its shell, and
	-- the Transparency it shows with (1 keeps it hidden, e.g. a cloud patch whose texture is not ready)
	partPatch: { number },
	partScale: { number },
	partAlpha: { number },
	-- CHANGED (Planet detail): per patch index (1..24): its ground / cloud part, base / cloud image, the detail slot
	-- showing on it; the part indices of each atmosphere layer and of the cloud shell
	groundPart: { [number]: MeshPart },
	baseImage: { [number]: EditableImage },
	slotOn: { [number]: Slot },
	cloudPart: { [number]: MeshPart },
	cloudImage: { [number]: EditableImage },
	cloudIndex: { [number]: number },
	-- CHANGED (Memory budget): budget handles, painted base pixels kept in Lua memory, release callbacks, the
	-- patch's own average colour, whether the proxy is (about to be) drawn, timers for releasing unused images
	baseHandle: { [number]: EditableBudget.Handle },
	baseCache: { [number]: buffer },
	baseCacheSize: number, -- pixels per side of the cached buffers (0 = none)
	baseRelease: { [number]: () -> () },
	cloudHandle: { [number]: EditableBudget.Handle },
	patchColor: { [number]: Color3 },
	wanted: boolean,
	basePriority: number,
	hiddenSince: number?,
	cloudWanted: boolean,
	cloudIdleSince: number?,
	atmosphereIndex: { { number } },
	cloudFade: number, -- cloud shell visibility last applied (0..1)
	camDir: Vec3d, -- unit direction body centre -> camera (body axes)
	camKnown: boolean,
	altitude: number, -- camera altitude above the body radius (m)
	glow: BillboardGui?,
	entry: Entry,
	dirUni: Vec3d, -- unit direction camera -> body, universe axes
	dirPocket: Vector3, -- same in pocket axes
	appliedRadius: number, -- radius last written into Size (0 = never)
	shown: boolean,
}

local ScaledSpace = {}

--============================================================================
-- Pure geometry
--============================================================================

-- Quarter of the +Y cube face (x, z in [-1, 0]) projected onto the unit sphere.
local function patchGeometry(n: number): PatchGeometry
	local points: { Point } = table.create((n + 1) * (n + 1))
	local uvs: { { number } } = table.create((n + 1) * (n + 1))
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for i = 0, n do
		for j = 0, n do
			local x, y, z = -1 + i / n, 1, -1 + j / n
			-- CHANGED (Phase 2a feedback): UVs from Biome's patch parametrisation, so painted pixels line up
			local u, v = Biome.paramToUV(Biome.cubeToParam(x), Biome.cubeToParam(z))
			uvs[i * (n + 1) + j + 1] = { u, v }
			local length = math.sqrt(x * x + y * y + z * z)
			x, y, z = x / length, y / length, z / length
			points[i * (n + 1) + j + 1] = { x = x, y = y, z = z }
			minX, minY, minZ = math.min(minX, x), math.min(minY, y), math.min(minZ, z)
			maxX, maxY, maxZ = math.max(maxX, x), math.max(maxY, y), math.max(maxZ, z)
		end
	end
	-- (b - a) x (c - a) points outward (+Y) for both triangles: counter-clockwise seen from outside (S6 / S12).
	local triangles: { { number } } = table.create(2 * n * n)
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local a = i * (n + 1) + j + 1 -- (i, j)
			local b = a + 1 -- (i, j + 1)
			local c = a + n + 1 -- (i + 1, j)
			local d = c + 1 -- (i + 1, j + 1)
			table.insert(triangles, { a, b, c })
			table.insert(triangles, { b, d, c })
		end
	end
	return {
		points = points,
		uvs = uvs,
		triangles = triangles,
		centre = { x = (minX + maxX) / 2, y = (minY + maxY) / 2, z = (minZ + maxZ) / 2 },
		size = { x = maxX - minX, y = maxY - minY, z = maxZ - minZ },
	}
end

-- The 24 proper rotations of the cube (signed permutation matrices with determinant +1), row-major 3x3.
-- CHANGED (Phase 2a feedback): shared with Biome so patch index i is painted with the rotation it is drawn with.
local function patchMatrices(): { { number } }
	return Biome.cubeRotations()
end

local geometry = patchGeometry(PATCH_SUBDIVISIONS)
local patchRadiusLimit = MAX_PART_SIZE / math.max(geometry.size.x, geometry.size.y, geometry.size.z)

--============================================================================
-- Pure distance mapping
--============================================================================

-- Scales near / far / the largest proxy radius to the current draw distance (decision D10).
local function computeLimits(drawDistance: number, fallback: boolean, out: Limits?): Limits
	local dd = drawDistance
	if dd ~= dd or dd <= 0 or dd > DRAW_DISTANCE_CAP then
		dd = DRAW_DISTANCE_CAP
	end
	local budget = BUDGET_FRACTION * dd
	local scale = math.clamp(budget / (SCALED_FAR * (1 + FAR_EDGE_ALLOWANCE)), MIN_DISTANCE_SCALE, 1)
	local far = SCALED_FAR * scale
	local near = math.max(SCALED_NEAR * scale, math.min(NEAR_RENDER_RADIUS * NEAR_FLOOR_FRACTION, far * 0.5))
	-- Largest proxy radius: config maximum, a fraction of the draw distance, the part-size limit, and small enough
	-- that at the handover (nearest surface = NEAR_RENDER_RADIUS, r = maxRadius) the far side 2r + NRR fits.
	-- CHANGED (Phase 2a feedback): the largest shell (atmosphere) must also fit the part-size limit
	local partLimit = if fallback then FALLBACK_MAX_RADIUS else patchRadiusLimit / MAX_SHELL_SCALE
	-- CHANGED (Phase 2a integration): only the camera-facing hemisphere up to the limb is ever visible, so the
	-- budget constrains the LIMB distance sqrt(d^2 - r^2), not the far side. At the handover (d = r + NRR) that
	-- gives r <= (budget^2 - NRR^2) / (2 NRR), which keeps the full PROXY_MAX_RADIUS on medium+ quality.
	local limbRadius = (budget * budget - NEAR_RENDER_RADIUS * NEAR_RENDER_RADIUS) / (2 * NEAR_RENDER_RADIUS)
	local maxRadius = math.min(PROXY_MAX_RADIUS, limbRadius, partLimit)
	maxRadius = math.max(maxRadius, math.min(MIN_PROXY_RADIUS, partLimit))
	local result: Limits = out or { near = 0, far = 0, budget = 0, maxRadius = 0 }
	result.near, result.far, result.budget, result.maxRadius = near, far, budget, maxRadius
	return result
end

-- Monotonic log mapping of true distance (m) to fake distance (studs).
local function baseDistance(D: number, limits: Limits): number
	local t = math.clamp((math.log(D) - LOG_D_MIN) / (LOG_D_MAX - LOG_D_MIN), 0, 1)
	return limits.near + (limits.far - limits.near) * t
end

-- Proxy -> surface handover altitude (m) for a body of radius R.
local function proxyMinAlt(radius: number, limits: Limits): number
	return NEAR_RENDER_RADIUS * radius / limits.maxRadius
end

-- Hysteresis: surface below (1 - h) * minAlt, proxy above (1 + h) * minAlt, unchanged in between.
local function nextSurfaceMode(current: boolean, altitude: number, minAlt: number): boolean
	if current then
		return altitude <= (1 + HYSTERESIS) * minAlt
	end
	return altitude < (1 - HYSTERESIS) * minAlt
end

-- Fills entry.d / entry.r for active entries. `entries` must be sorted by D ascending.
local function solveDistances(entries: { Entry }, limits: Limits)
	local nearestCentre = 0
	for _, e in entries do
		if not e.active then
			continue
		end
		local s = e.s
		local d = baseDistance(e.D, limits)
		if e.dominant then
			-- nearest surface point d * (1 - R/D) must stay outside the near zone
			d = math.max(d, NEAR_RENDER_RADIUS / (1 - s))
		end
		if nearestCentre > 0 then
			d = math.max(d, nearestCentre * DEPTH_ORDER_GAP / (1 - s))
		end
		if s > 0 then
			d = math.min(d, limits.maxRadius / s)
		end
		-- keep the limb (the farthest visible point, at distance d * sqrt(1 - s^2)) inside the draw budget
		d = math.min(d, limits.budget / math.sqrt(math.max(1 - s * s, 1e-6)))
		e.d = d
		e.r = d * s
		nearestCentre = math.max(nearestCentre, d)
	end
end

local function byDistance(a: Entry, b: Entry): boolean
	return a.D < b.D
end

--============================================================================
-- Module state
--============================================================================
local patchCentre = Vector3.new(geometry.centre.x, geometry.centre.y, geometry.centre.z)
local patchSize = Vector3.new(geometry.size.x, geometry.size.y, geometry.size.z)
local patchMatrixList = patchMatrices()
local patchRotations: { CFrame } = {}
for _, m in patchMatrixList do
	table.insert(patchRotations, CFrame.new(0, 0, 0, m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9]))
end

local initialised = false
local fallback = false
local keepAlive: { EditableMesh } = {} -- MeshParts vanish when their EditableMesh is destroyed: keep it referenced
-- CHANGED (Memory budget): live EditableImages are referenced by their visual / slot (Visual.baseImage, cloudImage,
-- Slot.image) and held through Render/EditableBudget (handles)
local tier: Quality.Tier = "Medium"
local slots: { Slot } = {}
local slotGeneration = 0 -- bumped when the slots are released (tier change): a slot job painted before is dropped
local paintFocus: Visual? = nil -- the dominant body's visual (its textures first, detail slots go there)
local refusedUntil: { [string]: number } = {} -- CHANGED (Memory budget): image kind -> when to ask again
local extrasGate: (() -> boolean)? = nil -- CHANGED (Memory budget): true once the terrain around the camera is built
local startedAt = 0 -- CHANGED (Memory budget): os.clock() of init
local slotIdleSince: number? = nil -- CHANGED (Memory budget): since when no detail slot is wanted
local patchTemplate: MeshPart? = nil -- unparented source of every patch clone (kept, never destroyed)
local workspaceRef: Workspace? = nil
local limits: Limits = computeLimits(DRAW_DISTANCE_CAP, false)
local visuals: { Visual } = {}
local visualById: { [number]: Visual } = {}
local surfaceMode = false
local surfaceBodyId: number? = nil

-- per-frame scratch (no allocation in the hot path beyond Universe's own)
local sortedEntries: { Entry } = {}
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local scratchOffset: Vec3d = Vec3d.zero()

-- CHANGED (Phase 2a feedback): texture jobs, painted by the generator thread
-- CHANGED (Planet detail): chosen one at a time by priority (pickJob) instead of a fixed queue
type JobKind = "Base" | "Restore" | "Slot" | "Cloud" -- CHANGED (Memory budget): Restore (from the Lua buffer)
type TextureJob = {
	kind: JobKind,
	visual: Visual,
	patch: number,
	spec: TextureSpec,
	slot: Slot?,
	generation: number,
}

--============================================================================
-- Instance creation
--============================================================================

local function configurePart(part: BasePart, name: string, color: Color3, material: Enum.Material)
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Material = material
	part.Color = color
	part.Transparency = 1 -- shown by update()
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
end

-- Builds the shared quarter-face patch mesh and one template MeshPart from it. Errors on failure.
-- CHANGED (Memory budget): created through EditableBudget (top priority, never released)
local function buildPatchTemplate(): (EditableMesh, MeshPart)
	local AssetService = game:GetService("AssetService")
	local created, handle, refusal = EditableBudget.createMesh(
		"ScaledSpace",
		EditableBudget.PRIORITY.PLANET_MESH,
		nil,
		#geometry.points,
		#geometry.triangles
	)
	if created == nil or handle == nil then
		error("CreateEditableMesh refused (" .. tostring(refusal) .. ")", 0)
	end
	local mesh = created :: EditableMesh
	local ok, err = pcall(function()
		local vertexIds: { number } = table.create(#geometry.points)
		local normalIds: { number } = table.create(#geometry.points)
		local uvIds: { number } = table.create(#geometry.points)
		for index, p in geometry.points do
			local direction = Vector3.new(p.x, p.y, p.z)
			vertexIds[index] = mesh:AddVertex(direction - patchCentre)
			normalIds[index] = mesh:AddNormal(direction)
			-- CHANGED (Phase 2a feedback): texture coordinates for the per-patch planet textures
			local uv = geometry.uvs[index]
			uvIds[index] = mesh:AddUV(Vector2.new(uv[1], uv[2]))
		end
		for _, tri in geometry.triangles do
			local a, b, c = tri[1], tri[2], tri[3]
			local face = mesh:AddTriangle(vertexIds[a], vertexIds[b], vertexIds[c])
			mesh:SetFaceNormals(face, { normalIds[a], normalIds[b], normalIds[c] })
			mesh:SetFaceUVs(face, { uvIds[a], uvIds[b], uvIds[c] })
		end
	end)
	if not ok then
		EditableBudget.destroy(handle)
		error(err, 0)
	end
	local partOk, part = pcall(function(): MeshPart
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = COLLISION_FIDELITY,
			RenderFidelity = RENDER_FIDELITY,
		})
	end)
	if not partOk then
		EditableBudget.destroy(handle)
		error(tostring(part), 0)
	end
	return mesh, part
end

local function newEntry(): Entry
	return { D = math.huge, s = 0, dominant = false, active = false, d = 0, r = 0 }
end

local function newVisual(id: number, radius: number, kind: Kind, parts: { BasePart }, glow: BillboardGui?): Visual
	return {
		id = id,
		radius = radius,
		kind = kind,
		parts = parts,
		partPatch = {},
		partScale = {},
		partAlpha = {},
		groundPart = {},
		baseImage = {},
		slotOn = {},
		cloudPart = {},
		cloudImage = {},
		cloudIndex = {},
		baseHandle = {}, -- CHANGED (Memory budget)
		baseCache = {},
		baseCacheSize = 0,
		baseRelease = {},
		cloudHandle = {},
		patchColor = {},
		wanted = true,
		basePriority = EditableBudget.PRIORITY.OTHER_BASE,
		hiddenSince = nil,
		cloudWanted = false,
		cloudIdleSince = nil,
		atmosphereIndex = {},
		cloudFade = 0,
		camDir = Vec3d.zero(),
		camKnown = false,
		altitude = math.huge,
		glow = glow,
		entry = newEntry(),
		dirUni = Vec3d.zero(),
		dirPocket = Vector3.zAxis,
		appliedRadius = 0,
		shown = false,
	}
end

-- CHANGED (Phase 2a feedback): the body's average biome colour (shown until textures are ready, and by the Ball)
local function averageColor(body: Bodies.Body): Color3
	local r, g, b = Biome.averageColor(body.Id)
	return Color3.new(r, g, b)
end

-- CHANGED (Memory budget): a patch's own average colour (shown while it has no image: better than one flat grey),
-- from PATCH_COLOR_SAMPLES^2 Biome samples over the patch (patch-local directions turned by its cube rotation).
local function patchColor(bodyId: number, patch: number): Color3
	local m = patchMatrixList[patch]
	local n = PATCH_SUBDIVISIONS
	local r, g, b, count = 0, 0, 0, 0
	for a = 0, PATCH_COLOR_SAMPLES - 1 do
		for c = 0, PATCH_COLOR_SAMPLES - 1 do
			local i = math.floor((a + 0.5) * n / PATCH_COLOR_SAMPLES)
			local j = math.floor((c + 0.5) * n / PATCH_COLOR_SAMPLES)
			local p = geometry.points[i * (n + 1) + j + 1]
			local x = m[1] * p.x + m[2] * p.y + m[3] * p.z
			local y = m[4] * p.x + m[5] * p.y + m[6] * p.z
			local z = m[7] * p.x + m[8] * p.y + m[9] * p.z
			local sr, sg, sb = Biome.sample(bodyId, x, y, z)
			r, g, b, count = r + sr, g + sg, b + sb, count + 1
		end
	end
	return Color3.new(r / count, g / count, b / count)
end

-- Adds one shell of 24 patch clones to a Patches visual; returns its part indices by patch index.
-- CHANGED (Planet detail): textures are no longer queued here (the generator picks them by priority)
local function addShell(
	visual: Visual,
	template: MeshPart,
	folder: Folder,
	name: string,
	scale: number,
	color: Color3,
	material: Enum.Material,
	shownAlpha: number
): { number }
	local indices: { number } = {}
	for index = 1, #patchRotations do
		local part = template:Clone()
		configurePart(part, string.format("%s%02d", name, index), color, material)
		part.Parent = folder
		table.insert(visual.parts, part)
		table.insert(visual.partPatch, index)
		table.insert(visual.partScale, scale)
		table.insert(visual.partAlpha, shownAlpha)
		indices[index] = #visual.parts
	end
	return indices
end

-- CHANGED (Planet detail): shows part `index` of a visual with transparency `alpha` (1 = hidden).
local function setPartAlpha(visual: Visual, index: number, alpha: number)
	visual.partAlpha[index] = alpha
	if visual.shown then
		visual.parts[index].Transparency = alpha
	end
end

-- CHANGED (Planet detail): the tier's atmosphere layers on a body's shells (extra shells hidden).
local function applyAtmosphere(visual: Visual)
	local layers = PlanetDetail.atmosphereLayers(tier)
	for k, indices in visual.atmosphereIndex do
		local layer = layers[k]
		for _, index in indices do
			if layer then
				visual.partScale[index] = layer.scale
				visual.parts[index].Color = layer.color
				setPartAlpha(visual, index, layer.transparency)
			else
				setPartAlpha(visual, index, 1)
			end
		end
	end
	visual.appliedRadius = 0 -- shell scales may have changed: rewrite every Size
end

local function createBodyVisual(body: Bodies.Body, parent: Folder): Visual
	local folder = Instance.new("Folder")
	folder.Name = body.Name
	local color = averageColor(body)
	local template = patchTemplate
	local visual: Visual
	if template then
		visual = newVisual(body.Id, body.Radius, "Patches", {}, nil)
		local ground = addShell(visual, template, folder, "Patch", 1, color, PATCH_MATERIAL, 0)
		for patch, index in ground do
			local part = visual.parts[index] :: MeshPart
			visual.groundPart[patch] = part
			-- CHANGED (Memory budget): each patch shows its own average colour until (and whenever) it has no image
			local own = patchColor(body.Id, patch)
			visual.patchColor[patch] = own
			part.Color = own
		end
		if CLOUDS_ENABLED and Biome.hasClouds(body.Id) then
			-- hidden (alpha 1) until each patch's cloud texture is applied and the tier / altitude show clouds
			local clouds = addShell(
				visual,
				template,
				folder,
				"Cloud",
				PlanetDetail.CLOUD_SHELL_SCALE,
				Color3.new(1, 1, 1),
				PATCH_MATERIAL,
				1
			)
			for patch, index in clouds do
				visual.cloudIndex[patch] = index
				visual.cloudPart[patch] = visual.parts[index] :: MeshPart
			end
		end
		local atmosphereColor = body.AtmosphereColor
		if ATMOSPHERE_ENABLED and atmosphereColor then
			-- CHANGED (Planet detail): nested layers, configured per tier by applyAtmosphere
			for k = 1, PlanetDetail.ATMOSPHERE_MAX_LAYERS do
				local indices = addShell(
					visual,
					template,
					folder,
					"Atmosphere" .. k,
					PlanetDetail.MAX_SHELL_SCALE,
					atmosphereColor,
					ATMOSPHERE_MATERIAL,
					1
				)
				table.insert(visual.atmosphereIndex, indices)
			end
			applyAtmosphere(visual)
		end
	else
		local part = Instance.new("Part")
		part.Shape = Enum.PartType.Ball
		configurePart(part, "Ball", color, PATCH_MATERIAL)
		part.Parent = folder
		visual = newVisual(body.Id, body.Radius, "Ball", { part }, nil)
	end
	folder.Parent = parent
	return visual
end

local function createSunVisual(body: Bodies.Body, parent: Folder): Visual
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	configurePart(part, "Sun", body.Color, SUN_MATERIAL)

	local glow = Instance.new("BillboardGui")
	glow.Name = "Glow"
	glow.AlwaysOnTop = false -- depth-tested, so planets in front hide it
	glow.LightInfluence = 0
	glow.ClipsDescendants = false
	glow.Enabled = false
	glow.Size = UDim2.fromScale(1, 1)
	for index, layer in SUN_GLOW_LAYERS do
		local disc = Instance.new("Frame")
		disc.Name = "Layer" .. index
		disc.AnchorPoint = Vector2.new(0.5, 0.5)
		disc.Position = UDim2.fromScale(0.5, 0.5)
		disc.Size = UDim2.fromScale(layer.size, layer.size)
		disc.BackgroundColor3 = body.Color
		disc.BackgroundTransparency = layer.transparency
		disc.BorderSizePixel = 0
		disc.ZIndex = index
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = disc
		disc.Parent = glow
	end
	glow.Adornee = part
	glow.Parent = part
	part.Parent = parent

	local visual = newVisual(body.Id, 0, "Sun", { part }, glow)
	local angularDeg = math.max(body.AngularRadiusDeg or 0, SUN_MIN_APPARENT_RADIUS_DEG)
	visual.entry.s = math.sin(math.rad(angularDeg))
	return visual
end

--============================================================================
-- Per-frame helpers
--============================================================================

local function setShown(visual: Visual, shown: boolean)
	if visual.shown == shown then
		return
	end
	visual.shown = shown
	local alphas = visual.partAlpha
	for index, part in visual.parts do
		-- CHANGED (Phase 2a feedback): each part shows with its own transparency (atmosphere / clouds)
		part.Transparency = if shown then alphas[index] or 0 else 1
	end
	local glow = visual.glow
	if glow then
		glow.Enabled = shown
	end
end

local function radiusLimitFor(visual: Visual): number
	if visual.kind == "Patches" then
		return patchRadiusLimit
	end
	return FALLBACK_MAX_RADIUS
end

-- Writes Size when the radius moved by more than the threshold; returns the radius the parts are sized for.
local function applyRadius(visual: Visual, r: number): number
	local radius = math.min(r, radiusLimitFor(visual))
	local applied = visual.appliedRadius
	if applied > 0 and math.abs(radius - applied) <= SIZE_REWRITE_THRESHOLD * applied then
		return applied
	end
	visual.appliedRadius = radius
	if visual.kind == "Patches" then
		local scales = visual.partScale
		for index, part in visual.parts do
			-- CHANGED (Phase 2a feedback): shells are larger copies
			part.Size = patchSize * (radius * scales[index])
		end
	else
		visual.parts[1].Size = Vector3.one * (2 * radius)
		local glow = visual.glow
		if glow then
			local glowSize = 2 * radius * SUN_GLOW_DIAMETERS
			glow.Size = UDim2.fromScale(glowSize, glowSize)
		end
	end
	return radius
end

-- Is the visual completely behind the dominant body's disc? (Only needed in surface mode, where the dominant
-- proxy that would normally hide it is not drawn.)
local function fullyOccluded(visual: Visual, domDir: Vec3d, domAngle: number): boolean
	local dot = math.clamp(Vec3d.dot(visual.dirUni, domDir), -1, 1)
	return math.acos(dot) + math.asin(visual.entry.s) < domAngle
end

--============================================================================
-- Texture generation (CHANGED Phase 2a feedback)
--============================================================================
local texturesDisabled = false -- CHANGED (Memory budget): only when the API itself is unavailable (not the budget)
local cloudsDisabled = false
local slotsDisabled = false -- CHANGED (Planet detail)
local PRIORITY = EditableBudget.PRIORITY -- CHANGED (Memory budget)
local extrasReleased = false -- CHANGED (Memory budget): the startup hold is over (it never comes back)

--[[
	CHANGED (Memory budget): every image this module creates goes through Render/EditableBudget. A "budget" refusal
	makes that kind of image wait REFUSED_RETRY_S (one warning for base images; slots and clouds give way silently,
	by design); "unavailable" (the API is off) is handled by the caller (that kind switches off with the setup hint).
]]
local function createImage(
	kind: JobKind,
	owner: string,
	size: number,
	priority: number,
	release: (() -> ())?
): (EditableImage?, EditableBudget.Handle?, EditableBudget.Refusal?)
	local image, handle, refusal = EditableBudget.createImage(owner, Vector2.new(size, size), priority, release)
	if image == nil and refusal == "budget" then
		local key: string = if kind == "Restore" then "Base" else kind
		refusedUntil[key] = os.clock() + REFUSED_RETRY_S
		-- slots and clouds give way by design (silently); a base image waiting is worth one line
		if key == "Base" then
			EditableBudget.warnOnce(
				"ScaledSpace.Base",
				"[ScaledSpace] planet textures wait for Editable memory (budget); patches show their own colour"
					.. " until there is room."
			)
		end
	end
	return image, handle, refusal
end

-- CHANGED (Memory budget): is this kind of image waiting after a budget refusal?
local function waiting(kind: string): boolean
	local untilTime = refusedUntil[kind]
	return untilTime ~= nil and os.clock() < untilTime
end

-- Sets a MeshPart's texture (nil clears it). Returns false (and disables textures with one warning) on failure.
local function setTexture(part: MeshPart, image: EditableImage?): boolean
	local ok, err = pcall(function()
		part.TextureContent = if image then Content.fromObject(image) else Content.none
	end)
	if not ok then
		texturesDisabled = true
		warn("[ScaledSpace] planet textures are unavailable (" .. tostring(err) .. "); planets stay flat-coloured.")
	end
	return ok
end

-- Patches of a visual nearest the camera first (index order while the camera direction is unknown).
local function patchOrder(visual: Visual): { number }
	if not visual.camKnown then
		local order: { number } = {}
		for patch = 1, #patchRotations do
			table.insert(order, patch)
		end
		return order
	end
	local c = visual.camDir
	return PlanetDetail.desiredPatches(patchMatrixList, c.x, c.y, c.z, #patchRotations)
end

local function closenessOf(visual: Visual, patch: number): number
	local c = visual.camDir
	return PlanetDetail.closeness(patchMatrixList[patch], c.x, c.y, c.z)
end

-- CHANGED (Memory budget): the budget owner of a body's base images (also the name of its demand)
local function baseOwner(visual: Visual): string
	return "ScaledSpace.base" .. visual.id
end

-- CHANGED (Memory budget): the priority of a body's base images now (header)
local function basePriorityOf(visual: Visual): number
	if visual ~= paintFocus then
		return PRIORITY.OTHER_BASE
	end
	return if visual.wanted then PRIORITY.DOMINANT_BASE else PRIORITY.HIDDEN_BASE
end

-- CHANGED (Planet detail): the cloud shell's transparency for the current fade and tier.
local function applyCloudAlpha(visual: Visual)
	local show = PlanetDetail.cloudTexture(tier) ~= nil and not cloudsDisabled
	for patch, index in visual.cloudIndex do
		local alpha = 1
		if show and visual.cloudImage[patch] and visual.cloudFade > 0 then
			alpha = math.max(CLOUD_MIN_TRANSPARENCY, 1 - visual.cloudFade)
		end
		if visual.partAlpha[index] ~= alpha then
			setPartAlpha(visual, index, alpha)
		end
	end
end

--[[
	CHANGED (Memory budget): gives a base image back: the patch shows its detail slot if it has one, else its own
	average colour. Its pixels stay in baseCache (a Restore job brings it back without repainting).
]]
local function releaseBase(visual: Visual, patch: number)
	local handle = visual.baseHandle[patch]
	visual.baseHandle[patch] = nil
	visual.baseImage[patch] = nil
	local part = visual.groundPart[patch]
	if part and visual.slotOn[patch] == nil then
		setTexture(part, nil)
	end
	EditableBudget.destroy(handle)
end

-- CHANGED (Memory budget): the budget's release callback of one base image (made once per patch)
local function baseReleaseFor(visual: Visual, patch: number): () -> ()
	local existing = visual.baseRelease[patch]
	if existing then
		return existing
	end
	local fresh = function()
		releaseBase(visual, patch)
	end
	visual.baseRelease[patch] = fresh
	return fresh
end

local function releaseAllBase(visual: Visual)
	local patches: { number } = {}
	for patch in visual.baseHandle do
		table.insert(patches, patch)
	end
	for _, patch in patches do
		releaseBase(visual, patch)
	end
end

-- CHANGED (Memory budget): gives a cloud image back (that cloud patch hides).
local function releaseCloud(visual: Visual, patch: number)
	local handle = visual.cloudHandle[patch]
	visual.cloudHandle[patch] = nil
	visual.cloudImage[patch] = nil
	local part = visual.cloudPart[patch]
	if part then
		setTexture(part, nil)
	end
	EditableBudget.destroy(handle)
	applyCloudAlpha(visual)
end

local function releaseAllClouds(visual: Visual)
	local patches: { number } = {}
	for patch in visual.cloudHandle do
		table.insert(patches, patch)
	end
	for _, patch in patches do
		releaseCloud(visual, patch)
	end
end

--[[
	CHANGED (Memory budget): keeps the budget's view of a body's base images current: the memory the body wants
	(demand: lower priorities, i.e. far terrain bands, never plan to use it) and the priority of what it holds.
]]
local function refreshBase(visual: Visual)
	local priority = basePriorityOf(visual)
	local bytes = #patchRotations * PlanetDetail.imageBytes(PlanetDetail.baseTexture(tier, visual.id))
	EditableBudget.setDemand(baseOwner(visual), if texturesDisabled then 0 else bytes, priority)
	if priority == visual.basePriority then
		return
	end
	visual.basePriority = priority
	for patch, handle in visual.baseHandle do
		EditableBudget.setPriority(handle, priority, baseReleaseFor(visual, patch))
	end
end

-- The next base ground image of `visual` to paint (nearest patch first), or nil.
-- CHANGED (Memory budget): only while the proxy is (about to be) drawn; a patch whose pixels are cached is restored
-- (Restore) instead of repainted, unless base images wait after a budget refusal
local function nextBaseJob(visual: Visual?): TextureJob?
	if visual == nil or visual.kind ~= "Patches" or texturesDisabled or not visual.wanted then
		return nil
	end
	local spec = PlanetDetail.baseTexture(tier, visual.id)
	local restoring = not waiting("Base")
	for _, patch in patchOrder(visual) do
		if not visual.baseImage[patch] then
			local cached = visual.baseCache[patch] ~= nil and visual.baseCacheSize == spec.size
			if not cached or restoring then
				return {
					kind = if cached then "Restore" else "Base",
					visual = visual,
					patch = patch,
					spec = spec,
					slot = nil,
					generation = slotGeneration,
				}
			end
		end
	end
	return nil
end

-- Takes a slot off the patch it shows on (that patch goes back to its base image).
local function releaseSlot(slot: Slot)
	local visual = slot.visual
	if visual then
		local patch = slot.patch
		if visual.slotOn[patch] == slot then
			visual.slotOn[patch] = nil
			setTexture(visual.groundPart[patch], visual.baseImage[patch])
		end
	end
	slot.visual = nil
	slot.patch = 0
end

-- CHANGED (Memory budget): takes a slot off its patch and gives its image back (the budget's release callback).
local function dropSlotImage(slot: Slot)
	releaseSlot(slot)
	local handle = slot.handle
	slot.image, slot.handle, slot.size = nil, nil, 0
	EditableBudget.destroy(handle)
end

-- CHANGED (Planet detail): drops every slot (tier change; CHANGED (Memory budget): or no slot is wanted).
local function releaseAllSlots()
	slotGeneration += 1
	for _, slot in slots do
		dropSlotImage(slot)
	end
	table.clear(slots)
end

-- The next detail-slot repaint on the dominant body: the nearest wanted patch without a slot, taking a free slot,
-- one on another body, or the slot on the least close unwanted patch (if the wanted one is clearly closer).
-- CHANGED (Memory budget): only while the proxy is drawn; slots per body (PlanetDetail.slotCount)
local function nextSlotJob(visual: Visual?): TextureJob?
	if
		visual == nil
		or visual.kind ~= "Patches"
		or texturesDisabled
		or slotsDisabled
		or not visual.camKnown
		or not visual.shown
		or waiting("Slot")
	then
		return nil
	end
	local spec = PlanetDetail.slotTexture(tier, visual.id)
	local count = PlanetDetail.slotCount(tier, visual.id)
	if spec == nil or count <= 0 or not PlanetDetail.slotsWanted(visual.altitude, visual.radius) then
		return nil
	end
	while #slots > count do
		local extra = table.remove(slots)
		if extra then
			dropSlotImage(extra)
		end
	end
	while #slots < count do
		table.insert(slots, { image = nil, handle = nil, size = 0, visual = nil, patch = 0 })
	end
	local c = visual.camDir
	local wanted = PlanetDetail.desiredPatches(patchMatrixList, c.x, c.y, c.z, count)
	local wantedSet: { [number]: boolean } = {}
	for _, patch in wanted do
		wantedSet[patch] = true
	end
	for _, patch in wanted do
		if visual.slotOn[patch] == nil then
			local victim: Slot? = nil
			local victimScore = math.huge
			for _, slot in slots do
				local score
				if slot.visual == nil then
					score = -math.huge -- free
				elseif slot.visual ~= visual then
					score = -10 -- on another body
				elseif not wantedSet[slot.patch] then
					score = closenessOf(visual, slot.patch)
				else
					score = math.huge -- still wanted where it is
				end
				if score < victimScore then
					victim, victimScore = slot, score
				end
			end
			if victim and closenessOf(visual, patch) > victimScore + SLOT_SWAP_MARGIN then
				return {
					kind = "Slot",
					visual = visual,
					patch = patch,
					spec = spec,
					slot = victim,
					generation = slotGeneration,
				}
			end
			return nil -- the nearest missing patch cannot take a slot yet, so no farther one can either
		end
	end
	return nil
end

-- The next cloud image to paint (High), nearest the camera first, or nil.
-- CHANGED (Memory budget): only while the cloud shell is (about to be) visible
local function nextCloudJob(): TextureJob?
	local spec = PlanetDetail.cloudTexture(tier)
	if spec == nil or not CLOUDS_ENABLED or cloudsDisabled or texturesDisabled or waiting("Cloud") then
		return nil
	end
	for _, visual in visuals do
		if visual.cloudWanted and next(visual.cloudPart) ~= nil then
			for _, patch in patchOrder(visual) do
				if not visual.cloudImage[patch] then
					return {
						kind = "Cloud",
						visual = visual,
						patch = patch,
						spec = spec,
						slot = nil,
						generation = slotGeneration,
					}
				end
			end
		end
	end
	return nil
end

-- CHANGED (Memory budget): may the extras (other bodies, slots, clouds) paint yet? Not at join until the terrain
-- around the camera is built (setExtrasGate) or STARTUP_HOLD_S passed; once open it stays open.
local function extrasOpen(): boolean
	if extrasReleased then
		return true
	end
	local gate = extrasGate
	local open = gate == nil or os.clock() - startedAt >= STARTUP_HOLD_S
	if not open and gate then
		local ok, result = pcall(gate)
		open = not ok or result
	end
	extrasReleased = open
	return open
end

-- Priority: the dominant body's base images, then (CHANGED (Memory budget): after the startup hold) every other
-- body's base images (the Mun is always painted), the dominant body's detail slots, clouds.
local function pickJob(): TextureJob?
	local dominant = paintFocus
	local job = nextBaseJob(dominant)
	if job then
		return job
	end
	if not extrasOpen() then
		return nil
	end
	for _, visual in visuals do
		if visual ~= dominant then
			job = nextBaseJob(visual)
			if job then
				return job
			end
		end
	end
	return nextSlotJob(dominant) or nextCloudJob()
end

-- CHANGED (Memory budget): makes the image for a job through the budget (nil: refused / unavailable, handled).
local function imageFor(job: TextureJob): (EditableImage?, EditableBudget.Handle?)
	local visual, patch, size = job.visual, job.patch, job.spec.size
	if job.kind == "Slot" then
		local slot = job.slot :: Slot
		if slot.image == nil then
			local created, handle, refusal = createImage("Slot", "ScaledSpace.slot", size, PRIORITY.SLOT, function()
				dropSlotImage(slot)
			end)
			if created == nil then
				if refusal == "unavailable" then
					slotsDisabled = true
					warn(
						"[ScaledSpace] detail textures disabled (EditableImage unavailable); planets keep their base images."
					)
				end
				return nil, nil
			end
			slot.image, slot.handle, slot.size = created, handle, size
		end
		return slot.image, slot.handle
	end
	local created, handle, refusal
	if job.kind == "Cloud" then
		created, handle, refusal = createImage("Cloud", "ScaledSpace.cloud", size, PRIORITY.CLOUD, function()
			releaseCloud(visual, patch)
		end)
		if created == nil and refusal == "unavailable" then
			cloudsDisabled = true
			warn("[ScaledSpace] cloud textures disabled (EditableImage unavailable).")
		end
	else
		created, handle, refusal =
			createImage(job.kind, baseOwner(visual), size, visual.basePriority, baseReleaseFor(visual, patch))
		if created == nil and refusal == "unavailable" then
			texturesDisabled = true
			warn(
				"[ScaledSpace] CreateEditableImage is unavailable ("
					.. tostring(EditableBudget.unavailableReason("Image"))
					.. "); planet patches stay flat-coloured. Enable Game Settings > Security >"
					.. " 'Allow Mesh / Image APIs'."
			)
		end
	end
	return created, handle
end

-- Puts a painted buffer on its target. Runs without yielding, so a slot moves in one frame.
-- CHANGED (Memory budget): images through the budget (imageFor); base pixels are cached; a job whose target is no
-- longer needed (hidden proxy, invisible clouds) or already done (restored meanwhile) creates nothing
local function applyJob(job: TextureJob, buf: buffer): boolean
	local visual, patch, size = job.visual, job.patch, job.spec.size
	local slot = job.slot
	if job.kind == "Base" then
		local copy = buffer.create(buffer.len(buf))
		buffer.copy(copy, 0, buf)
		if visual.baseCacheSize ~= size then
			table.clear(visual.baseCache)
			visual.baseCacheSize = size
		end
		visual.baseCache[patch] = copy
	end
	if job.kind == "Base" or job.kind == "Restore" then
		if visual.baseImage[patch] or not visual.wanted then
			return true
		end
	elseif job.kind == "Cloud" then
		if visual.cloudImage[patch] or not visual.cloudWanted then
			return true
		end
	else
		assert(slot)
		releaseSlot(slot) -- its old patch shows its base image again before the pixels change
		if slot.image and slot.size ~= size then
			local old = slot.handle
			slot.image, slot.handle, slot.size = nil, nil, 0
			EditableBudget.destroy(old)
		end
	end
	local image, handle = imageFor(job)
	if image == nil then
		return false
	end
	local written, writeErr = pcall(function()
		image:WritePixelsBuffer(Vector2.zero, image.Size, buf)
	end)
	if not written then
		texturesDisabled = true
		warn("[ScaledSpace] WritePixelsBuffer failed (" .. tostring(writeErr) .. "); planet textures disabled.")
		if slot then
			dropSlotImage(slot)
		else
			EditableBudget.destroy(handle)
		end
		return false
	end
	if job.kind == "Base" or job.kind == "Restore" then
		visual.baseImage[patch] = image
		if handle then
			visual.baseHandle[patch] = handle
		end
		if visual.slotOn[patch] == nil then
			return setTexture(visual.groundPart[patch], image)
		end
		return true
	elseif job.kind == "Slot" then
		assert(slot)
		slot.visual, slot.patch = visual, patch
		visual.slotOn[patch] = slot
		return setTexture(visual.groundPart[patch], image)
	end
	visual.cloudImage[patch] = image
	if handle then
		visual.cloudHandle[patch] = handle
	end
	if not setTexture(visual.cloudPart[patch], image) then
		cloudsDisabled = true
		return false
	end
	return true
end

--[[
	The background painter (CHANGED (Planet detail): runs for the whole session): picks the most useful texture
	(pickJob), paints it with Biome's painter in budgeted slices, and applies it. Idles PAINT_IDLE_S when there is
	nothing to do (e.g. the detail slots already sit on the nearest patches).
	CHANGED (Memory budget): a Restore job writes the cached pixels (no painting).
]]
local function generateTextures()
	local painters: { [string]: Biome.Painter } = {}
	local sliceStart = os.clock()
	local function yieldIfDue()
		if os.clock() - sliceStart >= PlanetDetail.tierSpec(tier).paintBudgetS then
			task.wait()
			sliceStart = os.clock()
		end
	end
	while not texturesDisabled do
		local job = pickJob()
		if job == nil then
			task.wait(PAINT_IDLE_S)
			sliceStart = os.clock()
			continue
		end
		if job.kind == "Restore" then
			local cached = job.visual.baseCache[job.patch]
			if cached then
				applyJob(job, cached)
			end
			yieldIfDue()
			continue
		end
		local spec = job.spec
		local key = spec.size .. ":" .. spec.cells
		local painter = painters[key]
		if painter == nil then
			local fresh = Biome.newPainter(spec.size, spec.cells, buffer.create(spec.size * spec.size * 4))
			painters[key] = fresh
			painter = fresh
		end
		assert(painter)
		local layer: Biome.Layer = if job.kind == "Cloud" then "Clouds" else "Ground"
		local height = if RELIEF_SHADE and layer == "Ground" then Relief.heightFn(job.visual.id) else nil
		Biome.beginPatch(painter, job.visual.id, layer, patchMatrixList[job.patch], spec.detail, height)
		while not Biome.paintStep(painter) do
			yieldIfDue()
		end
		-- a slot job painted across a tier change (slots released) is stale
		if job.kind ~= "Slot" or job.generation == slotGeneration then
			if applyJob(job, painter.buf) and job.kind == "Cloud" then
				applyCloudAlpha(job.visual)
			end
		end
		yieldIfDue()
	end
end

--[[
	CHANGED (Memory budget): which images are needed this frame (header): the dominant body's base images while its
	proxy is drawn or the camera is above RESTORE_FRACTION x the handover altitude, every other body's always; the
	cloud images while the shell would show at CLOUD_PREPAINT x the altitude; the detail slots while their body's
	proxy is drawn low enough. What is not needed for HIDDEN_RELEASE_S is given back.
]]
local function updateNeeds(dominantVisual: Visual?, altitude: number, now: number)
	for _, visual in visuals do
		if visual.kind ~= "Patches" then
			continue
		end
		local handover = proxyMinAlt(visual.radius, limits)
		local wanted = true
		if visual == dominantVisual then
			wanted = visual.entry.active or (surfaceMode and altitude > RESTORE_FRACTION * handover)
		end
		visual.wanted = wanted
		visual.cloudWanted = visual.shown
			and next(visual.cloudIndex) ~= nil
			and PlanetDetail.cloudTexture(tier) ~= nil
			and PlanetDetail.cloudFade(visual.altitude * CLOUD_PREPAINT, handover) > 0
		refreshBase(visual)
		if wanted then
			visual.hiddenSince = nil
		else
			local since = visual.hiddenSince or now
			visual.hiddenSince = since
			if now - since >= HIDDEN_RELEASE_S and next(visual.baseHandle) ~= nil then
				releaseAllBase(visual)
			end
		end
		if visual.cloudWanted or next(visual.cloudHandle) == nil then
			visual.cloudIdleSince = nil
		else
			local since = visual.cloudIdleSince or now
			visual.cloudIdleSince = since
			if now - since >= HIDDEN_RELEASE_S then
				releaseAllClouds(visual)
			end
		end
	end
	local focus = paintFocus
	local slotsActive = focus ~= nil
		and focus.shown
		and PlanetDetail.slotCount(tier, focus.id) > 0
		and PlanetDetail.slotsWanted(focus.altitude, focus.radius)
	if slotsActive or #slots == 0 then
		slotIdleSince = nil
	else
		local since = slotIdleSince or now
		slotIdleSince = since
		if now - since >= HIDDEN_RELEASE_S then
			releaseAllSlots()
			slotIdleSince = nil
		end
	end
end

-- CHANGED (Planet detail): a new graphics tier: atmosphere layers, cloud visibility and detail slots follow it.
-- CHANGED (Memory budget): base images of another size (and their cached pixels) go and are repainted; clouds go
-- (repainted if the new tier shows them)
local function applyTier(newTier: Quality.Tier)
	if newTier == tier and initialised then
		return
	end
	tier = newTier
	releaseAllSlots()
	for _, visual in visuals do
		if visual.kind == "Patches" then
			local size = PlanetDetail.baseTexture(tier, visual.id).size
			if visual.baseCacheSize ~= size then
				releaseAllBase(visual)
				table.clear(visual.baseCache)
				visual.baseCacheSize = size
			end
			releaseAllClouds(visual)
			applyAtmosphere(visual)
			applyCloudAlpha(visual)
			refreshBase(visual)
		end
	end
end

--============================================================================
-- API
--============================================================================

function ScaledSpace.init(parent: Folder)
	if initialised then
		return
	end
	workspaceRef = game:GetService("Workspace")
	startedAt = os.clock() -- CHANGED (Memory budget): the startup hold of the extras

	local ok, meshOrError, part = pcall(buildPatchTemplate)
	if ok then
		table.insert(keepAlive, meshOrError)
		patchTemplate = part
	else
		fallback = true
		warn(
			"[ScaledSpace] EditableMesh proxies are unavailable ("
				.. tostring(meshOrError)
				.. "); drawing bodies as single Ball parts (radius <= 1024) instead. Enable Game Settings > Security >"
				.. " 'Allow Mesh / Image APIs' for smooth cube-sphere proxies."
		)
	end
	computeLimits(DRAW_DISTANCE_CAP, fallback, limits)
	tier = Quality.tier() -- CHANGED (Planet detail): before the shells are made (atmosphere layers per tier)

	for _, body in Bodies.List do
		local visual: Visual
		if body.Kind == "Star" then
			visual = createSunVisual(body, parent)
		elseif not body.VisualOnly then
			visual = createBodyVisual(body, parent)
		else
			continue
		end
		table.insert(visuals, visual)
		visualById[body.Id] = visual
	end
	initialised = true
	-- CHANGED (Planet detail): follow the graphics tier (detail slots, atmosphere layers, clouds)
	Quality.onChanged(applyTier)
	-- CHANGED (Phase 2a feedback): paint the planet textures in the background
	if patchTemplate then
		task.spawn(generateTextures)
	end
end

-- CHANGED (Night review): `forceScaled` keeps the dominant body a proxy whatever the altitude (the main menu's
-- view: at quality 1 the 10 km viewpoint is below the handover altitude, and the menu has no surface to draw).
function ScaledSpace.update(ctx: RenderContext.RenderContext, forceScaled: boolean?)
	local ws = workspaceRef
	if not initialised or ws == nil then
		return
	end
	computeLimits(ctx.drawDistance, fallback, limits)
	local frame = ctx.frame
	local camPos = ctx.camera.Position
	local dominantId = ctx.dominantBodyId
	local dominantVisual = visualById[dominantId]
	-- CHANGED (Planet detail): the painter's detail slots follow the dominant body
	paintFocus = if dominantVisual and dominantVisual.kind == "Patches" then dominantVisual else nil

	-- 1. proxy <-> surface handover for the dominant body
	if forceScaled then
		surfaceBodyId = nil -- the handover is decided afresh once the override ends
		surfaceMode = false
	elseif dominantVisual and dominantVisual.kind ~= "Sun" then
		local minAlt = proxyMinAlt(dominantVisual.radius, limits)
		if surfaceBodyId ~= dominantId then
			surfaceBodyId = dominantId
			surfaceMode = ctx.altitude < minAlt
		else
			surfaceMode = nextSurfaceMode(surfaceMode, ctx.altitude, minAlt)
		end
	else
		surfaceBodyId = nil
		surfaceMode = false
	end

	-- 2. true directions and distances (doubles)
	for _, visual in visuals do
		local entry = visual.entry
		if visual.kind == "Sun" then
			entry.D = math.huge
			entry.dominant = false
			visual.dirPocket = ctx.sunDirection
			Frames.vectorFromWorkspace(frame, ctx.sunDirection, visual.dirUni)
			entry.active = true
			continue
		end
		local offset = scratchOffset
		if visual.id == dominantId then
			Vec3d.scaleInto(offset, ctx.cameraDominant, -1)
		else
			local bodyOffset = Universe.bodyOffset(visual.id, frame.refBodyId, ctx.ut)
			Vec3d.subInto(offset, bodyOffset, ctx.cameraAbs)
		end
		local D = Vec3d.length(offset)
		local s = if D > 0 then visual.radius / D else math.huge
		entry.D = D
		entry.s = s
		entry.dominant = visual.id == dominantId
		entry.active = s < MAX_SIN_RADIUS and not (entry.dominant and surfaceMode)
		if D > 0 then
			Vec3d.scaleInto(visual.dirUni, offset, 1 / D)
			visual.dirPocket = Frames.vectorToWorkspace(frame, visual.dirUni)
			-- CHANGED (Planet detail): where the camera is over this body (detail slots, paint order, cloud fade)
			Vec3d.scaleInto(visual.camDir, visual.dirUni, -1)
			visual.camKnown = true
			visual.altitude = D - visual.radius
			if next(visual.cloudIndex) ~= nil then
				local fade = PlanetDetail.cloudFade(visual.altitude, proxyMinAlt(visual.radius, limits))
				local moved = math.abs(fade - visual.cloudFade)
				if moved > CLOUD_FADE_STEP or (moved > 0 and (fade == 0 or fade == 1)) then
					visual.cloudFade = fade
					applyCloudAlpha(visual)
				end
			end
		end
	end

	-- 3. in surface mode nothing hides what is below the horizon: hide bodies fully behind the dominant body
	if surfaceMode and dominantVisual then
		local domEntry = dominantVisual.entry
		local domAngle = math.asin(math.min(domEntry.s, 1))
		for _, visual in visuals do
			if visual ~= dominantVisual and visual.entry.active then
				if fullyOccluded(visual, dominantVisual.dirUni, domAngle) then
					visual.entry.active = false
				end
			end
		end
	end

	-- 4. fake distances
	table.clear(sortedEntries)
	for _, visual in visuals do
		table.insert(sortedEntries, visual.entry)
	end
	table.sort(sortedEntries, byDistance)
	solveDistances(sortedEntries, limits)

	-- 5. placement
	table.clear(moveParts)
	table.clear(moveCFrames)
	for _, visual in visuals do
		local entry = visual.entry
		setShown(visual, entry.active)
		if not entry.active then
			continue
		end
		local r = applyRadius(visual, entry.r)
		-- keep the angular size exact with the radius the parts are actually sized for
		local d = if entry.s > 0 then r / entry.s else entry.d
		local centre = camPos + visual.dirPocket * d
		if visual.kind == "Patches" then
			local bodyRot = frame.refRotInv
			local centreCFrame = CFrame.new(centre)
			local patchIndex = visual.partPatch
			local scales = visual.partScale
			local alphas = visual.partAlpha
			for index, part in visual.parts do
				if alphas[index] >= 1 then
					continue -- CHANGED (Planet detail): hidden shells (unused atmosphere layers, clouds) stay put
				end
				-- CHANGED (Phase 2a feedback): per-part cube rotation and shell scale
				table.insert(moveParts, part)
				table.insert(
					moveCFrames,
					centreCFrame
						* (bodyRot * patchRotations[patchIndex[index]])
						* CFrame.new(patchCentre * (r * scales[index]))
				)
			end
		else
			table.insert(moveParts, visual.parts[1])
			table.insert(moveCFrames, CFrame.new(centre))
		end
	end
	if #moveParts > 0 then
		ws:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end

	-- 6. CHANGED (Memory budget): which images are needed (priorities, releases)
	if patchTemplate then
		updateNeeds(dominantVisual, ctx.altitude, os.clock())
	end
end

--[[
	CHANGED (Memory budget): `gate` returns true once the terrain around the camera is built; until then (at most
	STARTUP_HOLD_S after init) only the dominant body's base images are painted.
]]
function ScaledSpace.setExtrasGate(gate: (() -> boolean)?)
	extrasGate = gate
end

function ScaledSpace.isSurfaceMode(): boolean
	return surfaceMode
end

function ScaledSpace.proxyMinAltitude(bodyId: number): number
	local body = Bodies.find(bodyId)
	if body == nil or body.Radius <= 0 then
		return 0
	end
	return proxyMinAlt(body.Radius, limits)
end

-- Pure helpers for offline tests (Lune has no EditableMesh / BulkMoveTo).
ScaledSpace._test = {
	PATCH_SUBDIVISIONS = PATCH_SUBDIVISIONS,
	MAX_PART_SIZE = MAX_PART_SIZE,
	patchGeometry = patchGeometry,
	patchMatrices = patchMatrices,
	computeLimits = computeLimits,
	baseDistance = baseDistance,
	proxyMinAlt = proxyMinAlt,
	nextSurfaceMode = nextSurfaceMode,
	solveDistances = solveDistances,
	byDistance = byDistance,
	patchRotations = patchRotations, -- CHANGED (Phase 2a feedback): exposed for tooling
}

return ScaledSpace
