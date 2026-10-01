--!strict
--[[
	ScaledSpace (universe render layer 2)
	Draws every celestial body as a small "proxy" near the camera: a body at true distance D with radius R is drawn at
	a fake distance d with radius r = R * d / D, so its angular size is exact while everything stays inside the
	engine's draw distance. The Sun is a Neon ball with a BillboardGui glow.

	  ScaledSpace.init(parent)             creates every part under `parent` (yields once for CreateMeshPartAsync)
	  ScaledSpace.update(ctx)              once per frame, after the camera moved
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
	and every patch MeshPart gets its own EditableImage painted from Biome (Kablamo's continents, oceans, ice caps;
	Dent's maria and craters). Images are painted progressively by a background thread (init spawns it) that
	yields every TEXTURE_BUDGET_S of work; until a patch is ready it shows the body's average biome colour.
	Kablamo also gets a cloud shell (24 more patch clones with a transparent cloud texture via SurfaceAppearance)
	and an atmosphere shell (translucent patch clones in the body's AtmosphereColor: a halo around the limb).
	If EditableImage or SurfaceAppearance texturing is unavailable, the planets stay flat-coloured / cloudless
	with one warning.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
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
type TextureSpec = { size: number, cells: number } -- pixels per patch side, Biome coarse grid cells per side
local GROUND_TEXTURES: { [number]: TextureSpec } = {
	[Bodies.HOMEWORLD] = { size = 256, cells = 64 },
	[Bodies.MOON] = { size = 128, cells = 32 },
}
local DEFAULT_TEXTURE: TextureSpec = { size = 128, cells = 32 } -- any other body
local CLOUD_TEXTURE: TextureSpec = { size = 128, cells = 32 }
local TEXTURE_DETAIL = 1 -- Biome detail level for scaled-space textures (ground tiles use more)
local TEXTURE_BUDGET_S = 0.004 -- painting work per frame before the generator yields
local MAX_EDITABLE_IMAGES = 96 -- hard cap on images this module creates (3 x 24 patches today)
-- CHANGED (Phase 2a playtest): Studio refused SurfaceAppearance.ColorMapContent from game scripts ("lacking
-- capability Plugin"), so the cloud shell cannot be made at runtime; off until clouds have another route.
local CLOUDS_ENABLED = false
local CLOUD_SHELL_SCALE = 1.012 -- cloud shell radius / body radius
local ATMOSPHERE_ENABLED = true
local ATMOSPHERE_SHELL_SCALE = 1.045 -- rim shell radius / body radius (a thin halo around the limb)
local ATMOSPHERE_MATERIAL = Enum.Material.SmoothPlastic -- lit by the sun; ForceField / Neon glow instead
local ATMOSPHERE_TRANSPARENCY = 0.78
local MAX_SHELL_SCALE = math.max(1, CLOUD_SHELL_SCALE, ATMOSPHERE_SHELL_SCALE) -- largest patch clone per body
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
local keepAliveImages: { EditableImage } = {} -- CHANGED (Phase 2a feedback): same for the patch textures
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

-- CHANGED (Phase 2a feedback): texture jobs, painted in order by the generator thread
type TextureJob = {
	visual: Visual,
	part: MeshPart,
	partIndex: number,
	bodyId: number,
	layer: Biome.Layer,
	matrix: { number },
	spec: TextureSpec,
}
local textureJobs: { TextureJob } = {}

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
local function buildPatchTemplate(): (EditableMesh, MeshPart)
	local AssetService = game:GetService("AssetService")
	local mesh = AssetService:CreateEditableMesh()
	if mesh == nil then
		error("CreateEditableMesh returned nil", 0)
	end
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
		mesh:Destroy()
		error(err, 0)
	end
	local partOk, part = pcall(function(): MeshPart
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = COLLISION_FIDELITY,
			RenderFidelity = RENDER_FIDELITY,
		})
	end)
	if not partOk then
		mesh:Destroy()
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

local function textureSpecFor(bodyId: number): TextureSpec
	return GROUND_TEXTURES[bodyId] or DEFAULT_TEXTURE
end

-- Adds one shell of 24 patch clones to a Patches visual (and queues their texture jobs when `layer` is given).
local function addShell(
	visual: Visual,
	template: MeshPart,
	folder: Folder,
	name: string,
	scale: number,
	color: Color3,
	material: Enum.Material,
	shownAlpha: number,
	layer: Biome.Layer?,
	spec: TextureSpec
)
	for index = 1, #patchRotations do
		local part = template:Clone()
		configurePart(part, string.format("%s%02d", name, index), color, material)
		part.Parent = folder
		table.insert(visual.parts, part)
		table.insert(visual.partPatch, index)
		table.insert(visual.partScale, scale)
		table.insert(visual.partAlpha, shownAlpha)
		if layer then
			table.insert(textureJobs, {
				visual = visual,
				part = part,
				partIndex = #visual.parts,
				bodyId = visual.id,
				layer = layer,
				matrix = patchMatrixList[index],
				spec = spec,
			})
		end
	end
end

local function createBodyVisual(body: Bodies.Body, parent: Folder): Visual
	local folder = Instance.new("Folder")
	folder.Name = body.Name
	local color = averageColor(body)
	local template = patchTemplate
	local visual: Visual
	if template then
		visual = newVisual(body.Id, body.Radius, "Patches", {}, nil)
		addShell(visual, template, folder, "Patch", 1, color, PATCH_MATERIAL, 0, "Ground", textureSpecFor(body.Id))
		if CLOUDS_ENABLED and Biome.hasClouds(body.Id) then
			-- hidden (alpha 1) until each patch's cloud texture is applied
			addShell(
				visual,
				template,
				folder,
				"Cloud",
				CLOUD_SHELL_SCALE,
				Color3.new(1, 1, 1),
				PATCH_MATERIAL,
				1,
				"Clouds",
				CLOUD_TEXTURE
			)
		end
		local atmosphereColor = body.AtmosphereColor
		if ATMOSPHERE_ENABLED and atmosphereColor then
			addShell(
				visual,
				template,
				folder,
				"Atmosphere",
				ATMOSPHERE_SHELL_SCALE,
				atmosphereColor,
				ATMOSPHERE_MATERIAL,
				ATMOSPHERE_TRANSPARENCY,
				nil,
				DEFAULT_TEXTURE
			)
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
local texturesDisabled = false
local cloudsDisabled = false

-- Puts a finished image on its patch. Returns false (and disables that layer with one warning) on failure.
local function applyTexture(job: TextureJob, image: EditableImage): boolean
	local content = Content.fromObject(image)
	if job.layer == "Clouds" then
		local ok, err = pcall(function()
			local appearance = Instance.new("SurfaceAppearance")
			appearance.AlphaMode = Enum.AlphaMode.Transparency
			appearance.ColorMapContent = content
			appearance.Parent = job.part
		end)
		if not ok then
			cloudsDisabled = true
			warn(
				"[ScaledSpace] cloud textures are unavailable ("
					.. tostring(err)
					.. "); Kablamo is drawn without clouds."
			)
			return false
		end
		-- reveal this cloud patch (it stayed hidden until now)
		job.visual.partAlpha[job.partIndex] = 0
		if job.visual.shown then
			job.part.Transparency = 0
		end
		return true
	end
	local ok, err = pcall(function()
		job.part.TextureContent = content
	end)
	if not ok then
		texturesDisabled = true
		warn("[ScaledSpace] planet textures are unavailable (" .. tostring(err) .. "); planets stay flat-coloured.")
		return false
	end
	return true
end

-- Paints every queued patch texture in order, yielding whenever TEXTURE_BUDGET_S of work has been done.
local function generateTextures()
	local AssetService = game:GetService("AssetService")
	local painters: { [string]: Biome.Painter } = {}
	local sliceStart = os.clock()
	local function yieldIfDue()
		if os.clock() - sliceStart >= TEXTURE_BUDGET_S then
			task.wait()
			sliceStart = os.clock()
		end
	end
	for _, job in textureJobs do
		if texturesDisabled or #keepAliveImages >= MAX_EDITABLE_IMAGES then
			break
		end
		if job.layer == "Clouds" and cloudsDisabled then
			continue
		end
		local spec = job.spec
		local created, image = pcall(function(): EditableImage
			return AssetService:CreateEditableImage({ Size = Vector2.new(spec.size, spec.size) })
		end)
		if not created then
			texturesDisabled = true
			warn(
				"[ScaledSpace] CreateEditableImage failed ("
					.. tostring(image)
					.. "); remaining planet patches stay flat-coloured. Enable Game Settings > Security >"
					.. " 'Allow Mesh / Image APIs'."
			)
			break
		end
		local key = spec.size .. ":" .. spec.cells
		local painter = painters[key]
		if painter == nil then
			local fresh = Biome.newPainter(spec.size, spec.cells, buffer.create(spec.size * spec.size * 4))
			painters[key] = fresh
			painter = fresh
		end
		assert(painter)
		Biome.beginPatch(painter, job.bodyId, job.layer, job.matrix, TEXTURE_DETAIL)
		while not Biome.paintStep(painter) do
			yieldIfDue()
		end
		local written, err = pcall(function()
			image:WritePixelsBuffer(Vector2.zero, image.Size, painter.buf)
		end)
		if not written then
			image:Destroy()
			texturesDisabled = true
			warn("[ScaledSpace] WritePixelsBuffer failed (" .. tostring(err) .. "); planet textures disabled.")
			break
		end
		if applyTexture(job, image) then
			table.insert(keepAliveImages, image)
		else
			image:Destroy()
		end
		yieldIfDue()
	end
	table.clear(textureJobs)
end

--============================================================================
-- API
--============================================================================

function ScaledSpace.init(parent: Folder)
	if initialised then
		return
	end
	workspaceRef = game:GetService("Workspace")

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
	-- CHANGED (Phase 2a feedback): paint the planet textures in the background
	if #textureJobs > 0 then
		task.spawn(generateTextures)
	end
end

function ScaledSpace.update(ctx: RenderContext.RenderContext)
	local ws = workspaceRef
	if not initialised or ws == nil then
		return
	end
	computeLimits(ctx.drawDistance, fallback, limits)
	local frame = ctx.frame
	local camPos = ctx.camera.Position
	local dominantId = ctx.dominantBodyId
	local dominantVisual = visualById[dominantId]

	-- 1. proxy <-> surface handover for the dominant body
	if dominantVisual and dominantVisual.kind ~= "Sun" then
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
			for index, part in visual.parts do
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
