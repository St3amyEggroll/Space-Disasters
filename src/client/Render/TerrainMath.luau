--!strict
--!native
--[[
	TerrainMath (CHANGED (Phase 8): surface terrain)
	Pure helpers of the terrain renderer (Render/TerrainMesh), testable offline:

	  * Quadtree: every cube face of a body is a quadtree whose depth-d node (face, d, x, y) covers the lattice cells
	    of SurfaceHeight [x, x + 1) * CHUNK * 2^(maxDepth - d) along i (same along j). A leaf is drawn as a CHUNK x CHUNK
	    grid of quads at that stride, so the deepest leaves use every lattice node: they ARE the physics ground.
	  * select(): nodes beyond the horizon are dropped; a node splits while the camera is closer than splitK times its
	    size (mergeK, a little larger, for nodes that were split last time: hysteresis); the whole selection is retried
	    with a smaller splitK while it has more than maxLeaves leaves.
	  * Bands: leaves are drawn in batches (one mesh each), one per level of detail: band id = levels above the
	    deepest (0 = the physics resolution), except that every level from mergeLevel up shares one band (the mesh
	    budget). A level's leaves form a ring around the camera about twice as far out as it is in, so each band is
	    either small enough to draw at true scale (the finest) or is drawn uniformly scaled down about the camera
	    (bandScale) to fit the draw distance and the 2048-stud part limit; thin rings keep that scale close between
	    neighbouring bands, so depth stays nearly in order and far bands stay well behind the craft.
	  * Chunk geometry (buildChunk): CHUNK + 1 squared vertices on the lattice (same triangles and diagonal as
	    SurfaceHeight), smooth normals from the neighbouring nodes (also across chunk and face edges), Biome vertex
	    colours (Earth: steep slopes turn to rock), and a skirt hanging below every edge, deep enough to cover the
	    crack to a neighbour up to two levels coarser. Positions are relative to the chunk's centre point and sit
	    RENDER_DROP below the true ground (no z-fighting with the launch site's ground plate).
	  * Collision: the lattice triangles near a point (collisionTriangles) and the two WedgeParts that fill a triangle
	    (wedgePair), solid below it.

	CHANGED (Night review): the band layout and band boxes.
	  * Band frames (tangentAxes, bestAxes): a band's mesh is stored in a tangent frame at the camera's nadir (Y up,
	    X along the face lattice or rotated in steps, whichever gives the smallest box; the universe axes are a
	    candidate too), so its box is close to the ground's real extent (a tangent square seen in universe axes is
	    up to 1.41x wider: lower scale factors, smaller true-scale area). frameBounds is the exact
	    vertex box in such a frame, sunk union leaves included (the mesh origin is the box centre, so the engine has
	    nothing to recentre).
	  * Near band (assignBands with a Near): true-scale objects (other crafts, dropped stages, puppets, explosions,
	    the smoke trail) are hidden by ground that is drawn scaled down about the camera (nearer than it is). The
	    finest-level band was a quadtree-aligned patch, so the camera often sat near its edge (true-scale ground
	    only ~0.4-0.6 km away on some side), and at altitude no band was at true scale at all. With a Near, the
	    leaves whose centre lies inside a square of +-half around the ground under the camera form band 0 (one
	    part of at most ~2 km: true scale while its centre is within the draw budget, also below a climbing
	    camera), every other leaf a band per level as before. select() splits every node over the square down to
	    near.maxLeaf, and grades the sizes around it (at most 4x per step) so the skirts still close the seams.
	    (Why not 4 true-scale quadrant pieces of 2 km: with 6 meshes the rest of the ground would be 2 bands, the
	    far one spanning ~2 km to the horizon at a scale of ~0.02-0.03, i.e. drawn ~50 m from the camera: anything
	    farther than that, seen against it, would be covered. One band per level keeps that distance at ~250-450 m.)
	  * planStep: the order in which a plan builds, retires and unions bands; nothing is built while more than
	    `bandCount` bands are alive (a plan needs at most bandCount + 1 meshes: the experience-wide budget; it used
	    to build two new bands in a row after a camera jump).
	  * collisionCells / cellTriangles: the collision cells around a point (TerrainCollision updates cell by cell).

	CHANGED (Terrain polish): Steamy's Studio test: terrain covered the launch site from the ground ("a flat green
	surface slices through the base", towers sticking out of a ridge that is really kilometres behind the site) and
	far ground showed through nearer hills ("I see through the earth"). Both come from bands drawn scaled down about
	the camera, i.e. nearer than they are: a band of factor k covers anything true-scale (or any band of a larger
	factor) that is really in front of it but farther than k x its distance.
	  * Ring bands (planRings, assignBands with a RingContext): the leaves outside the near square are cut into
	    rings by their distance from the square's centre, with the cuts placed so the smallest "nearest drawn
	    depth" (k x nearest ground) of any ring is as large as possible (was one band per level of detail, whose
	    last band held everything from ~5 km to the horizon at k ~0.03: mountains drawn ~200 studs away).
	  * bandScales: the scaled bands share ONE factor (the smallest, the outermost ring's) so they keep their true
	    order among themselves, except bands whose ground starts within the protected depth, which get just the
	    factor that draws it there.
	  * Seams (stitchCode / stitchChunk): where two bands meet, the outer band's skirt (which faced the camera and,
	    drawn nearer, painted walls and blue stripes over the inner band) is cut to SKIRT_INNER, and the finer of
	    the two edges is moved onto the coarser one, so there is no crack to cover.
	  * The drawn ground under the base's 20-stud ground plate is sunk SITE_SINK m (no z-fighting, never through
	    the plate when drawn scaled), and the vertex colours have slope soil / rock, high-ground and dry tints,
	    brightness noise at three scales and cavity shading (groundColour).

	CHANGED (See-through fix): far bands drawn in front of nearer ground (Render/TerrainMesh's header has the audit):
	  * seamCode (moved here from TerrainMesh): every LOD seam inside a cube face is stitched (the finer edge onto the
	    coarser one, whichever band each is in) and keeps only the SKIRT_INNER skirt; only cube-edge seams keep
	    buildChunk's deep skirt, which faced the camera on far leaves and was drawn over nearer bands.
	  * bulge culling for the scaled bands (bulgeOccluder / occluded / cullChunk): triangles facing the camera but
	    hidden behind the body's bulge from every camera within a reach are left out of a band, so they cannot be
	    drawn over the nearer ground that hides them (the grey-blue slabs along the horizon).

	All positions are body-relative metres (body axes = universe axes) in doubles.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local CHUNK = SurfaceHeight.LATTICE_CHUNK -- quads per chunk edge (8)
local HORIZON_MARGIN = 0.02 -- rad beyond the geometric horizon that is still drawn
local NODE_RADIUS_PAD = 0.15 -- bounding radius allowance per metre of node size (relief inside the node)
local FLAT_TOLERANCE = 0.05 -- m: a node whose nine samples agree this well is flat (open sea)
local FLAT_SPLIT_FACTOR = 0.4 -- flat nodes split at this fraction of the usual distance
local TOP_PAD = 0.3 -- a node's highest ground is taken as its highest sample + this x its size (unsampled peaks)
local MAX_BAND_LEAVES = 95 -- leaves of one level at most (EditableMesh: 20,000 triangles per mesh; 192 per leaf)
local MAX_SELECT_RETRIES = 5
local RETRY_FACTOR = 0.8 -- splitK multiplier per retry when there are too many leaves
local SKIRT_MIN = 2 -- m
local SKIRT_ERROR_MULT = 1.5 -- x the largest gap to a 2x / 4x coarser or 2x finer neighbour's edge
local SKIRT_ERROR_PAD = 1 -- m (skirts stay short: a deep skirt of a scaled-down band would cover nearer ground)
local RENDER_DROP = 0.12 -- m the drawn ground sits below the true ground
local ROCK_SLOPE0 = 0.2 -- 1 - cos(slope): steep Earth ground starts turning to rock here (~37 deg)
local ROCK_SLOPE1 = 0.42 -- fully rock (~55 deg)
local ROCK_COLOR = { 0.47, 0.43, 0.39 }
-- CHANGED (Terrain polish): richer vertex colours (groundColour): the land is no longer one flat green
local SOIL_SLOPE0 = 0.04 -- 1 - cos(slope): bare soil starts showing on Earth slopes here (~16 deg) ...
local SOIL_SLOPE1 = 0.17 -- ... at most SOIL_MAX of it by ~34 deg
local SOIL_MAX = 0.35
local SOIL_COLOR = { 0.46, 0.39, 0.29 }
local HIGH_COLOR = { 0.5, 0.53, 0.42 } -- alpine meadow / scree tint on high ground
local HIGH_H0 = 250 -- m: high ground tint starts here ...
local HIGH_H1 = 1100 -- ... and reaches HIGH_MAX here
local HIGH_MAX = 0.4
local DRY_COLOR = { 0.66, 0.62, 0.34 } -- patches of drier grass
local DRY_MAX = 0.28
local NOISE_WAVELENGTHS = { 900, 260, 70 } -- m: brightness noise (largest first)
local NOISE_AMPS = { 0.07, 0.05, 0.035 } -- +- brightness share per wavelength
local DRY_WAVELENGTH = 1400 -- m: dry patches
local CAVITY_FULL = 0.06 -- m of hollow per m of vertex spacing that gives the full CAVITY_SHADE
local CAVITY_SHADE = 0.12 -- hollows this much darker, crests this much brighter
local MOON_NOISE_AMP = 0.6 -- the Mun's brightness noise, as a share of NOISE_AMPS
local NOISE_SPREAD = 1.4 -- math.noise -> about -1..1
local SKIRT_INNER = 0.3 -- m: skirt on an edge facing a nearer band (stitchChunk; that band closes the seam)
local SITE_SINK = 4 -- m: ground under the base's ground plate (20 studs thick) is drawn this much lower ...
local SITE_SINK_SPACINGS = 1.05 -- ... where the vertex is at least this many quad spacings inside the plate edge
-- the launch site's ground plate (HomeBase "Ground", 99 / 102 / 107) painted into the terrain, so the base still shows
-- as a grey square from high up, where its parts are not drawn (Surface hides the site copy over scaled terrain)
local SITE_PLATE_COLOR = { 99 / 255, 102 / 255, 107 / 255 }
local SITE_PLATE_HALF = BaseLayout.SITE_HALF_EXTENT -- m, in the site's tangent plane
local NODE_CACHE_MAX = 6000 -- cached quadtree nodes before the cache is cleared (a selection visits ~1000)
local MIN_SCALE = 1e-4 -- smallest band scale factor
local TRUE_SCALE_FACTOR = 0.9999 -- CHANGED (Terrain polish): a band factor at or above this is true scale
local VERTEX_BYTES = 36 -- chunk vertex record: position, normal, colour (9 f32)
-- CHANGED (Review 3): the baked distance haze follows the daylight (daylight / hazeColour)
local HAZE_NIGHT_SUN = -0.1 -- sine of the sun's elevation at and below which the haze is the night colour ...
local HAZE_DAY_SUN = 0.2 -- ... and at and above which it is the day colour
local HAZE_LIGHT_STEP = 0.25 -- daylight is rounded to these steps (a band is rebuilt when its step changes)
local HAZE_NIGHT_BRIGHTNESS = 0.1 -- night haze: the atmosphere colour this bright ...
local HAZE_NIGHT_GREY = 0.5 -- ... and this much greyer (toward its own luminance)
-- CHANGED (Night review): the near band (assignBands / select with a Near)
local NEAR_BAND = 0 -- band id of the near square's leaves (the other bands are 1 + level)
local NEAR_GRADE = 4 -- around the near square, node sizes grow at most this much per step (skirts close 4x seams)
local NEAR_SIZE_PAD = 1.1 -- a node's footprint is taken this much larger than its size (cube-sphere distortion)
local NEAR_MIN_COS = 0.5 -- only nodes within 60 deg of the near origin count (never the far side of the body)
local SIZE_TOLERANCE = 1.01 -- leaf sizes compared with near.maxLeaf
local FRAME_CANDIDATES = 4 -- band frame orientations tried about the up axis (bestAxes), plus the universe axes
-- CHANGED (Terrain polish): ring bands around the near square (planRings / assignBands with a RingContext)
local RING_SEARCH_STEPS = 18 -- binary search steps for the protected depth
local RING_DEPTH_MAX = 8000 -- studs: upper end of that search
local RING_KEEP = 0.85 -- the last plan's ring bounds stay while they protect at least this x the best depth
local RING_TIE = 1e-6 -- m: leaf ring distances closer than this are one group (never split by a bound)
-- CHANGED (See-through fix): ground hidden behind the body's bulge is left out of the scaled bands (cullChunk)
local OCCLUDER_SLACK = 1 -- m: the occluding sphere stays this much below the lowest drawn ground (plus the drops)
-- CHANGED (Far slabs fix): the horizon profile the scaled bands are also culled against (newProfile / cullChunk).
-- One table (the module's chunk is near Roblox's 200-locals limit).
local PROFILE = table.freeze({
	AZIMUTHS = 384, -- azimuth bins around the camera's nadir (0.94 deg)
	DISTANCES = 128, -- distance bins: [0, NEAR) then log-spaced by RATIO (out to ~70 km)
	NEAR = 40, -- m: ground nearer than this to the nadir is no occluder (rays to far ground pass high over it)
	RATIO = 1.06,
	-- the drawn ground's lower bound is taken from the leaves' lattice vertices (the drawn LOD) per 2 x 2 quads (the
	-- quad of the leaf one level coarser), minus MARGIN m plus MARGIN_PER_SPACING x its quad spacing (the detail a
	-- finer level adds; a union's sunk leaves sit less than this low)
	MARGIN = 3,
	MARGIN_PER_SPACING = 0.2,
	UNKNOWN = -1e30, -- no ground known there: nothing occludes
})
--============================================================================

export type Config = {
	bodyId: number,
	radius: number, -- m
	n: number, -- lattice cells per face edge
	maxDepth: number, -- deepest quadtree level (its leaves use stride 1)
	cellArc: number, -- m, lattice cell edge at a face centre
	minHeight: number,
	maxHeight: number,
}

export type Node = {
	key: number,
	face: number,
	depth: number,
	x: number,
	y: number,
	i0: number, -- first lattice index along u
	j0: number, -- along v
	stride: number, -- lattice cells per chunk quad
	size: number, -- m, edge length
	cx: number, -- centre ground point (body-relative, m)
	cy: number,
	cz: number,
	dx: number, -- unit direction of the centre
	dy: number,
	dz: number,
	radius: number, -- m, bounding radius around the centre point
	flat: boolean, -- all nine samples (corners, edge middles, centre) at the same height (open sea): splits later
	top: number, -- m, highest ground the node may hold (samples + TOP_PAD x size, at most the body's maximum)
}

export type Params = {
	splitK: number,
	mergeK: number,
	maxLeaves: number,
	maxLeafSize: number?, -- m: nodes bigger than this always split (Part fallback: Part size limit)
	maxDistance: number?, -- m: nodes farther than this from the camera are dropped
	pause: (() -> ())?, -- called for every node visited (a caller in a thread may yield there)
	bandCount: number?, -- bands the leaves will be drawn in (TerrainMath.bandOf): none may exceed MAX_BAND_LEAVES
	horizonLead: number?, -- m: the horizon is taken this much higher than the camera (it climbs while meshes build)
	near: Near?, -- CHANGED (Night review): near band (assignBands): nodes over the square split to near.maxLeaf
	rings: RingContext?, -- CHANGED (Terrain polish): ring bands around the near square (assignBands)
}

--[[
	CHANGED (Terrain polish): what the ring layout (planRings) needs: the camera, the engine limits TerrainMesh draws
	a band within (bandScale) and the last plan's bounds (kept while still good: fewer rebuilds).
]]
export type RingContext = {
	cam: Vec3d, -- body-relative camera
	budget: number, -- studs: a band's box centre stays within this (engine culling)
	farLimit: number, -- studs: a band's far end stays within this
	partLimit: number, -- studs per part axis
	previous: { number }?, -- ring bounds of the displayed plan
}

-- CHANGED (Night review): a right-handed tangent frame (body axes): x along the face lattice, y up, z = x cross y.
export type Axes = {
	x: Vec3d,
	y: Vec3d,
	z: Vec3d,
}

-- CHANGED (Night review): the near square: leaves whose centre is within +-half (tangent x / z) of the origin.
export type Near = {
	origin: Vec3d, -- body-relative point on the body's sphere under the camera
	axes: Axes, -- tangent frame at the origin
	half: number, -- m
	maxLeaf: number, -- m: largest leaf inside the square
}

-- CHANGED (Night review): what a plan does next (planStep).
export type StepKind = "build" | "retire" | "union"

export type Selection = {
	leaves: { Node },
	split: { [number]: boolean },
	splitK: number, -- the splitK that was finally used
}

export type Chunk = {
	key: number,
	depth: number,
	ox: number, -- origin = the node's centre ground point (body-relative, m)
	oy: number,
	oz: number,
	vertexCount: number,
	triangleCount: number,
	data: buffer, -- per vertex VERTEX_BYTES: position (relative to the origin), unit normal, colour (9 f32)
	tris: { number }, -- vertex index triples (1-based), counter-clockwise seen from above (shared: never modify)
	skirt: number, -- m
	minX: number, -- bounding box of the vertices (relative to the origin)
	minY: number,
	minZ: number,
	maxX: number,
	maxY: number,
	maxZ: number,
}

--[[
	CHANGED (See-through fix): a sphere about the body centre that lies entirely below the drawn ground (bulgeOccluder),
	seen from a camera: whatever lies behind it from EVERY camera within `reach` of `cam` is hidden by the ground.
]]
export type Occluder = {
	x: number, -- camera (body-relative, m)
	y: number,
	z: number,
	c2: number, -- |cam|^2 - radius^2 (> 0: the camera is outside the sphere)
	reach: number, -- m: the camera may move this far before the culling must be redone
}

--[[
	CHANGED (Far slabs fix): the horizon profile of the drawn ground seen from a camera (newProfile): in the camera's
	tangent frame (y up, heights relative to the camera), polar bins around its nadir. `low` holds a lower bound of
	the drawn ground's height in each bin (any level of detail a leaf may be drawn at), `slope` (finishProfile) the
	running maximum, outward along each azimuth, of the lowest slope from any camera within `reach` to that ground.
]]
export type Profile = {
	cx: number, -- camera (body-relative, m)
	cy: number,
	cz: number,
	ux: number, -- up
	uy: number,
	uz: number,
	ex: number, -- tangent axes
	ey: number,
	ez: number,
	fx: number,
	fy: number,
	fz: number,
	reach: number, -- m
	low: buffer, -- f32 per bin (azimuth-major): lowest drawn ground (m relative to the camera), +inf = none yet
	slope: buffer, -- f32 per bin: occluding slope (finishProfile)
	finished: boolean,
}

export type Triangle = { number } -- ax, ay, az, bx, by, bz, cx, cy, cz (body-relative, m), counter-clockwise from above

--[[
	CHANGED (Depth order fix): the radial depth map every scaled band is baked with (depthMap / mapDepth / depthChunk):
	a point d m from the band's build camera is stored at depth f(d) along the same ray. f runs through the anchors
	(dist[i], depth[i]) as a power law between neighbours (linear below the first, the last segment's power beyond
	the last): continuous and strictly increasing.
]]
export type DepthMap = {
	dist: { number }, -- m, increasing
	depth: { number }, -- studs, increasing
	power: { number }, -- exponent of the segment from anchor i to i + 1 (the last one continues past the end)
}

local TerrainMath = {}

TerrainMath.CHUNK = CHUNK
TerrainMath.MAX_BAND_LEAVES = MAX_BAND_LEAVES

-- CHANGED (Night review): vertex indices of a chunk's four ground corners (bestAxes)
local CORNER_VERTICES = { 1, CHUNK + 1, CHUNK * (CHUNK + 1) + 1, (CHUNK + 1) * (CHUNK + 1) }
TerrainMath.RENDER_DROP = RENDER_DROP
TerrainMath.SITE_SINK = SITE_SINK -- CHANGED (Terrain polish)

local function smoothstep(e0: number, e1: number, v: number): number
	local t = (v - e0) / (e1 - e0)
	if t <= 0 then
		return 0
	elseif t >= 1 then
		return 1
	end
	return t * t * (3 - 2 * t)
end

local function mix(r: number, g: number, b: number, c: { number }, w: number): (number, number, number)
	return r + (c[1] - r) * w, g + (c[2] - g) * w, b + (c[3] - b) * w
end

--[[
	CHANGED (Terrain polish): the drawn colour of a ground vertex (not the launch site): Biome's colour plus, on
	Earth's land, dry patches on grass, a high-ground tint, bare soil on slopes and rock on steep ones; everywhere
	brightness noise at three scales and a cavity shade (hollows darker, crests lighter: `cavity` is the vertex's
	depth below its four neighbours' mean per metre of spacing), so the ground reads as shaped land instead of one
	flat colour. Water only gets a little of the noise.
]]
local function groundColour(
	bodyId: number,
	kind: string,
	dx: number,
	dy: number,
	dz: number,
	r: number,
	g: number,
	b: number,
	slope: number,
	cavity: number,
	height: number
): (number, number, number)
	local radius = Bodies.get(bodyId).Radius
	local earth = bodyId == Bodies.HOMEWORLD
	local amp = if earth then NOISE_SPREAD else NOISE_SPREAD * MOON_NOISE_AMP
	local bright = 1
	for index, wavelength in NOISE_WAVELENGTHS do
		local f = radius / wavelength
		local o = index * 5.3
		bright += amp * NOISE_AMPS[index] * math.noise(dx * f + o, dy * f + 2 * o, dz * f + 3 * o)
	end
	if kind == "Ocean" or kind == "Lake" then -- CHANGED (Planet detail): lakes and rivers are water too
		bright = 1 + (bright - 1) * 0.3
		return math.clamp(r * bright, 0, 1), math.clamp(g * bright, 0, 1), math.clamp(b * bright, 0, 1)
	end
	if earth then
		if kind == "Grass" then
			local f = radius / DRY_WAVELENGTH
			local dry = math.clamp(math.noise(dx * f + 11.3, dy * f + 4.1, dz * f + 9.9) * NOISE_SPREAD * 2, 0, 1)
			r, g, b = mix(r, g, b, DRY_COLOR, dry * DRY_MAX)
		end
		if kind == "Grass" or kind == "Forest" then
			r, g, b = mix(r, g, b, HIGH_COLOR, smoothstep(HIGH_H0, HIGH_H1, height) * HIGH_MAX)
		end
		if kind ~= "Snow" then
			r, g, b = mix(r, g, b, SOIL_COLOR, smoothstep(SOIL_SLOPE0, SOIL_SLOPE1, slope) * SOIL_MAX)
		end
		r, g, b = mix(r, g, b, ROCK_COLOR, smoothstep(ROCK_SLOPE0, ROCK_SLOPE1, slope))
	end
	bright *= 1 - CAVITY_SHADE * math.clamp(cavity / CAVITY_FULL, -1, 1)
	return math.clamp(r * bright, 0, 1), math.clamp(g * bright, 0, 1), math.clamp(b * bright, 0, 1)
end

--[[
	CHANGED (Terrain polish): how far (m) the drawn ground at unit direction (x, y, z) is sunk under the base's
	ground plate: SITE_SINK where a quad `spacingCells` lattice cells wide around it lies under the plate, else 0.
]]
local function siteSink(config: Config, x: number, y: number, z: number, spacingCells: number): number
	if config.bodyId ~= Bodies.HOMEWORLD or x <= 0 then
		return 0
	end
	local inset = SITE_PLATE_HALF - spacingCells * config.cellArc * SITE_SINK_SPACINGS
	local radius = config.radius
	if math.abs(z) * radius / x <= inset and math.abs(y) * radius / x <= inset then
		return SITE_SINK
	end
	return 0
end

--============================================================================
-- Quadtree
--============================================================================
local configs: { [number]: Config } = {}
local noConfig: { [number]: boolean } = {}

-- The terrain configuration of a body (nil for bodies without a surface).
function TerrainMath.config(bodyId: number): Config?
	local cached = configs[bodyId]
	if cached then
		return cached
	elseif noConfig[bodyId] then
		return nil
	end
	local n = SurfaceHeight.latticeSize(bodyId)
	if n <= 0 then
		noConfig[bodyId] = true
		return nil
	end
	local radius = Bodies.get(bodyId).Radius
	local minHeight, maxHeight = SurfaceHeight.bounds(bodyId)
	local config: Config = {
		bodyId = bodyId,
		radius = radius,
		n = n,
		maxDepth = math.round(math.log(n / CHUNK, 2)),
		cellArc = radius * (math.pi / 2) / n,
		minHeight = minHeight,
		maxHeight = maxHeight,
	}
	configs[bodyId] = config
	return config
end

-- A stable number for a node: (body, face, depth, x, y), x and y < 2^15.
function TerrainMath.nodeKey(bodyId: number, face: number, depth: number, x: number, y: number): number
	return (((bodyId * 8 + face) * 32 + depth) * 32768 + x) * 32768 + y
end

local nodeCaches: { [number]: { [number]: Node } } = {}
local nodeCounts: { [number]: number } = {}

local function groundPoint(bodyId: number, radius: number, face: number, i: number, j: number): (number, number, number)
	local x, y, z = SurfaceHeight.nodeDirection(bodyId, face, i, j)
	local r = radius + SurfaceHeight.nodeHeight(bodyId, face, i, j)
	return x * r, y * r, z * r
end

-- The quadtree node (face, depth, x, y) of a body (cached).
function TerrainMath.node(config: Config, face: number, depth: number, x: number, y: number): Node
	local bodyId = config.bodyId
	local key = TerrainMath.nodeKey(bodyId, face, depth, x, y)
	local cache = nodeCaches[bodyId]
	if cache == nil then
		cache = {}
		nodeCaches[bodyId] = cache
		nodeCounts[bodyId] = 0
	end
	assert(cache)
	local hit = cache[key]
	if hit then
		return hit
	end
	local stride = 2 ^ (config.maxDepth - depth)
	local span = CHUNK * stride
	local i0, j0 = x * span, y * span
	local half = span / 2
	local radius = config.radius
	local dx, dy, dz = SurfaceHeight.nodeDirection(bodyId, face, i0 + half, j0 + half)
	local cx, cy, cz = groundPoint(bodyId, radius, face, i0 + half, j0 + half)
	local reach = 0
	local centreHeight = SurfaceHeight.nodeHeight(bodyId, face, i0 + half, j0 + half)
	local flat = true
	local top = centreHeight
	for sample = 0, 8 do
		local si = i0 + (sample % 3) * half
		local sj = j0 + math.floor(sample / 3) * half
		local px, py, pz = groundPoint(bodyId, radius, face, si, sj)
		local d = math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2 + (pz - cz) ^ 2)
		if d > reach then
			reach = d
		end
		local h = SurfaceHeight.nodeHeight(bodyId, face, si, sj)
		if math.abs(h - centreHeight) > FLAT_TOLERANCE then
			flat = false
		end
		if h > top then
			top = h
		end
	end
	local size = span * config.cellArc
	-- highest ground the node may hold: its samples plus an allowance for peaks between them
	top = math.min(top + (if flat then 0 else TOP_PAD * size), config.maxHeight)
	local node: Node = {
		key = key,
		face = face,
		depth = depth,
		x = x,
		y = y,
		i0 = i0,
		j0 = j0,
		stride = stride,
		size = size,
		cx = cx,
		cy = cy,
		cz = cz,
		dx = dx,
		dy = dy,
		dz = dz,
		radius = reach + NODE_RADIUS_PAD * size,
		flat = flat,
		top = top,
	}
	if nodeCounts[bodyId] >= NODE_CACHE_MAX then
		table.clear(cache)
		nodeCounts[bodyId] = 0
	end
	cache[key] = node
	nodeCounts[bodyId] += 1
	return node
end

--[[
	Angle (rad) from the camera's nadir within which ground up to `top` m high can be seen over the horizon (plus
	HORIZON_MARGIN). The horizon is taken at the body's lowest ground, so this never hides anything visible.
]]
function TerrainMath.horizonAngle(config: Config, cameraRadius: number, top: number?): number
	local low = config.radius + config.minHeight
	local high = config.radius + math.max(top or config.maxHeight, config.minHeight)
	local fromCamera = if cameraRadius > low then math.acos(low / cameraRadius) else 0
	return fromCamera + math.acos(math.min(low / high, 1)) + HORIZON_MARGIN
end

-- CHANGED (Night review): tangent coordinates (along axes.x, axes.z) of body-relative point (x, y, z) about the
-- near origin, and whether it lies within NEAR_MIN_COS of the origin's direction.
local function nearCoords(near: Near, x: number, y: number, z: number): (number, number, boolean)
	local o, ax, az, up = near.origin, near.axes.x, near.axes.z, near.axes.y
	local rx, ry, rz = x - o.x, y - o.y, z - o.z
	local len = math.sqrt(x * x + y * y + z * z)
	local facing = len > 0 and (x * up.x + y * up.y + z * up.z) / len > NEAR_MIN_COS
	return rx * ax.x + ry * ax.y + rz * ax.z, rx * az.x + ry * az.y + rz * az.z, facing
end

--[[
	CHANGED (Night review): largest node size allowed at `node` around the near square: near.maxLeaf over it, then
	NEAR_GRADE times more per ring of that width outward (two rings), unlimited beyond.
]]
local function nearSizeLimit(near: Near, node: Node): number
	local u, v, facing = nearCoords(near, node.cx, node.cy, node.cz)
	if not facing then
		return math.huge
	end
	local gap = math.max(math.abs(u), math.abs(v)) - node.size * NEAR_SIZE_PAD / 2 - near.half
	local step = near.maxLeaf
	if gap <= 0 then
		return step
	end
	local reach = 0
	for _ = 1, 2 do
		step *= NEAR_GRADE
		reach += step
		if gap < reach then
			return step
		end
	end
	return math.huge
end

local function selectOnce(
	config: Config,
	cam: Vec3d,
	params: Params,
	splitK: number,
	prevSplit: { [number]: boolean }?
): ({ Node }, { [number]: boolean })
	local leaves: { Node } = {}
	local split: { [number]: boolean } = {}
	local rc = Vec3d.length(cam)
	local cdx, cdy, cdz = cam.x / rc, cam.y / rc, cam.z / rc
	local low = config.radius + config.minHeight
	local rcHorizon = rc + (params.horizonLead or 0)
	local fromCamera = (if rcHorizon > low then math.acos(low / rcHorizon) else 0) + HORIZON_MARGIN
	local invRadius = 1 / config.radius
	local maxDepth = config.maxDepth
	local mergeK = math.max(params.mergeK * splitK / params.splitK, splitK)
	local maxLeafSize = params.maxLeafSize or math.huge
	local maxDistance = params.maxDistance or math.huge
	local pause = params.pause
	local near = params.near -- CHANGED (Night review)
	local function visit(face: number, depth: number, x: number, y: number)
		if pause then
			pause()
		end
		local node = TerrainMath.node(config, face, depth, x, y)
		local cosA = node.dx * cdx + node.dy * cdy + node.dz * cdz
		if cosA > 1 then
			cosA = 1
		elseif cosA < -1 then
			cosA = -1
		end
		-- over the horizon: the node's highest ground cannot be seen from the camera
		local beyond = math.acos(low / (config.radius + math.max(node.top, config.minHeight)))
		if math.acos(cosA) - node.radius * invRadius > fromCamera + beyond then
			return
		end
		local ex, ey, ez = cam.x - node.cx, cam.y - node.cy, cam.z - node.cz
		local dist = math.sqrt(ex * ex + ey * ey + ez * ez) - node.radius
		if dist < 0 then
			dist = 0
		end
		if dist > maxDistance then
			return
		end
		local k = if prevSplit and prevSplit[node.key] then mergeK else splitK
		if node.flat then
			k *= FLAT_SPLIT_FACTOR
		end
		-- CHANGED (Night review): + nodes over (or graded around) the near square split down to its leaf size
		local forced = near ~= nil
			and node.size > near.maxLeaf * SIZE_TOLERANCE
			and node.size > nearSizeLimit(near, node)
		if depth < maxDepth and (dist < k * node.size or node.size > maxLeafSize or forced) then
			split[node.key] = true
			local cx, cy = 2 * x, 2 * y
			visit(face, depth + 1, cx, cy)
			visit(face, depth + 1, cx + 1, cy)
			visit(face, depth + 1, cx, cy + 1)
			visit(face, depth + 1, cx + 1, cy + 1)
		else
			table.insert(leaves, node)
		end
	end
	for face = 1, 6 do
		visit(face, 0, 0, 0)
	end
	return leaves, split
end

-- Would any band hold over MAX_BAND_LEAVES?
-- CHANGED (Night review): bands as assignBands lays them out (the near band too), not only one per level.
-- CHANGED (Terrain polish): + ring bands (no layout fits: crowded)
local function crowded(config: Config, leaves: { Node }, bandCount: number, near: Near?, rings: RingContext?): boolean
	local perBand: { [number]: number } = {}
	local assigned, _, fits = TerrainMath.assignBands(config, leaves, bandCount, near, rings)
	if not fits then
		return true
	end
	for _, band in assigned do
		local count = (perBand[band] or 0) + 1
		if count > MAX_BAND_LEAVES then
			return true
		end
		perBand[band] = count
	end
	return false
end

--[[
	The leaves to draw for a camera at `cam` (body-relative). `prevSplit` is the previous selection's split set
	(hysteresis). Retries with a smaller splitK while there are more than params.maxLeaves leaves (or more than
	MAX_BAND_LEAVES in one level).
]]
function TerrainMath.select(config: Config, cam: Vec3d, params: Params, prevSplit: { [number]: boolean }?): Selection
	local splitK = params.splitK
	local leaves, split = selectOnce(config, cam, params, splitK, prevSplit)
	local tries = 1
	local bandCount = params.bandCount or math.huge
	while
		(#leaves > params.maxLeaves or crowded(config, leaves, bandCount, params.near, params.rings))
		and tries < MAX_SELECT_RETRIES
	do
		splitK *= RETRY_FACTOR
		leaves, split = selectOnce(config, cam, params, splitK, prevSplit)
		tries += 1
	end
	return { leaves = leaves, split = split, splitK = splitK }
end

-- Levels above the deepest (0 = the physics resolution) of a node.
function TerrainMath.levelOf(config: Config, node: Node): number
	return config.maxDepth - node.depth
end

--[[
	First level that shares a band for a selection drawn with `bandCount` bands: the finest level present plus
	bandCount - 1 (every coarser level joins that last band).
]]
function TerrainMath.mergeLevel(config: Config, leaves: { Node }, bandCount: number): number
	local finest = math.huge
	for _, node in leaves do
		local level = config.maxDepth - node.depth
		if level < finest then
			finest = level
		end
	end
	if finest == math.huge then
		finest = 0
	end
	return finest + math.max(bandCount, 1) - 1
end

-- Band id of a leaf: its level, or mergeLevel for every coarser level.
function TerrainMath.bandOf(config: Config, node: Node, mergeLevel: number): number
	return math.min(config.maxDepth - node.depth, mergeLevel)
end

--[[
	CHANGED (Night review): the tangent frame at body-relative `pos` (any height): y = the radial up, x = the face
	lattice's u direction projected into the tangent plane, z = x cross y (right-handed, CFrame.fromMatrix order).
	Leaves near `pos` are squares along x and z, so a band stored in this frame has a tight box.
]]
function TerrainMath.tangentAxes(config: Config, pos: Vec3d): Axes
	local up = Vec3d.normalize(pos)
	local face = SurfaceHeight.latticeCoords(config.bodyId, pos)
	local _, u = SurfaceHeight.faceFrame(face)
	local x = Vec3d.sub(u, Vec3d.scale(up, Vec3d.dot(u, up)))
	if Vec3d.lengthSq(x) < 1e-12 then
		local _, _, v = SurfaceHeight.faceFrame(face)
		x = Vec3d.sub(v, Vec3d.scale(up, Vec3d.dot(v, up)))
	end
	x = Vec3d.normalize(x)
	return { x = x, y = up, z = Vec3d.cross(x, up) }
end

-- CHANGED (Night review): a near square of +-half m (leaves up to maxLeaf m) around the ground under `pos`.
function TerrainMath.newNear(config: Config, pos: Vec3d, half: number, maxLeaf: number): Near
	local axes = TerrainMath.tangentAxes(config, pos)
	return { origin = Vec3d.scale(axes.y, config.radius), axes = axes, half = half, maxLeaf = maxLeaf }
end

--[[
	CHANGED (Night review): where to centre a near square of +-nearHalf for a camera at `cam`: the ground under it,
	except that a square of +-keepHalf around `keep` (the launch site) is kept inside it while the camera's nadir
	is within `range` (tangent, per axis) of the positions that do that. Body-relative, on the body's sphere.
	CHANGED (Review 3): also returns whether the keep square is what placed it (TerrainMesh then recentres a square
	that no longer holds the keep square, whatever its slack).
]]
function TerrainMath.nearTarget(
	config: Config,
	cam: Vec3d,
	keep: Vec3d?,
	keepHalf: number,
	nearHalf: number,
	range: number
): (Vec3d, boolean)
	local nadir = Vec3d.scale(Vec3d.normalize(cam), config.radius)
	local room = nearHalf - keepHalf
	if keep == nil or room < 0 then
		return nadir, false
	end
	local frame = TerrainMath.newNear(config, keep, keepHalf, 0)
	local u, v, facing = nearCoords(frame, nadir.x, nadir.y, nadir.z)
	if not facing or math.max(math.abs(u), math.abs(v)) > room + range then
		return nadir, false
	end
	local cu, cv = math.clamp(u, -room, room), math.clamp(v, -room, room)
	local p = Vec3d.add(frame.origin, Vec3d.add(Vec3d.scale(frame.axes.x, cu), Vec3d.scale(frame.axes.z, cv)))
	return Vec3d.scale(Vec3d.normalize(p), config.radius), true
end

-- CHANGED (Night review): tangent coordinates (x, z) of body-relative `pos` about the near origin.
function TerrainMath.nearOffset(near: Near, pos: Vec3d): (number, number)
	local u, v = nearCoords(near, pos.x, pos.y, pos.z)
	return u, v
end

--============================================================================
-- CHANGED (Terrain polish): ring bands
--============================================================================
--[[
	Why rings: every band except the near one is drawn uniformly scaled down about the camera (bandScale), so it is
	drawn NEARER than it is, by its factor k. Wherever a true-scale thing (the launch site, a craft, the near band's
	own hills) is seen against such a band, the band covers it if k x (the band's distance there) is less than the
	thing's distance. With one band per level of detail, the last band held every coarse level from ~5 km to the
	horizon: k ~0.03-0.04, i.e. mountains 6 km away were drawn ~200 studs from the camera, in front of the launch
	towers (Steamy's Studio screenshots), and the per-level rings drew their nearest ground at ~400-500 studs.
	A part's size limit fixes k <= partLimit / (the band's box), so a band's nearest ground is drawn at most at
	partLimit x (its nearest distance / its box): the best layout keeps every band's box small next to how far it
	starts. planRings cuts the leaves outside the near square into rings by their distance from the near square's
	centre (Chebyshev, in its tangent frame: leaves are squares in that frame, so rings are tight square annuli) and
	places the cuts so that the smallest predicted "nearest drawn depth" of any ring (k x its nearest ground) is as
	large as possible (a binary search over that depth with a greedy cut), within the band count and the leaves per
	mesh. Everything true-scale nearer than that depth is never covered by a scaled band behind it.
]]
type RingAcc = {
	minU: number,
	maxU: number,
	minV: number,
	maxV: number,
	top: number,
	dmin: number,
	dfar: number,
	count: number,
}

type RingLeaf = {
	c: number, -- Chebyshev distance of the leaf centre from the near origin (tangent, m)
	u0: number, -- the leaf's square (tangent, m)
	u1: number,
	v0: number,
	v1: number,
	top: number, -- highest ground (m above the radius)
	dmin: number, -- nearest distance from the camera (m, at least 1)
	dfar: number, -- farthest distance from the camera (m)
}

local function ringLeaf(near: Near, cam: Vec3d, node: Node): RingLeaf
	local u, v = nearCoords(near, node.cx, node.cy, node.cz)
	local h = node.size * NEAR_SIZE_PAD / 2
	local ex, ey, ez = node.cx - cam.x, node.cy - cam.y, node.cz - cam.z
	local d = math.sqrt(ex * ex + ey * ey + ez * ez)
	return {
		c = math.max(math.abs(u), math.abs(v)),
		u0 = u - h,
		u1 = u + h,
		v0 = v - h,
		v1 = v + h,
		top = node.top,
		dmin = math.max(d - node.radius, 1),
		dfar = d + node.radius,
	}
end

local function ringAdd(acc: RingAcc, leaf: RingLeaf)
	acc.minU = math.min(acc.minU, leaf.u0)
	acc.maxU = math.max(acc.maxU, leaf.u1)
	acc.minV = math.min(acc.minV, leaf.v0)
	acc.maxV = math.max(acc.maxV, leaf.v1)
	acc.top = math.max(acc.top, leaf.top)
	acc.dmin = math.min(acc.dmin, leaf.dmin)
	acc.dfar = math.max(acc.dfar, leaf.dfar)
	acc.count += 1
end

local function ringEmpty(): RingAcc
	return {
		minU = math.huge,
		maxU = -math.huge,
		minV = math.huge,
		maxV = -math.huge,
		top = -math.huge,
		dmin = math.huge,
		dfar = 0,
		count = 0,
	}
end

-- The predicted nearest drawn depth (studs) of a ring: bandScale's factor (box from the leaf squares plus the
-- sphere's drop, centre on the tangent plane) times its nearest ground.
local function ringDepth(config: Config, near: Near, ctx: RingContext, acc: RingAcc): number
	local reach = math.max(-acc.minU, acc.maxU, -acc.minV, acc.maxV)
	local ext = math.max(
		acc.maxU - acc.minU,
		acc.maxV - acc.minV,
		acc.top - config.minHeight + reach * reach / (2 * config.radius)
	)
	local uc, vc = (acc.minU + acc.maxU) / 2, (acc.minV + acc.maxV) / 2
	local o, ax, az, cam = near.origin, near.axes.x, near.axes.z, ctx.cam
	local dx = o.x + ax.x * uc + az.x * vc - cam.x
	local dy = o.y + ax.y * uc + az.y * vc - cam.y
	local dz = o.z + ax.z * uc + az.z * vc - cam.z
	local k = TerrainMath.bandScale(
		math.sqrt(dx * dx + dy * dy + dz * dz),
		acc.dfar,
		ext,
		ctx.budget,
		ctx.farLimit,
		ctx.partLimit
	)
	return k * acc.dmin
end

-- Ring index (0-based) of distance c for ascending bounds.
local function ringIndex(bounds: { number }, c: number): number
	local index = 0
	for _, b in bounds do
		if c >= b then
			index += 1
		end
	end
	return index
end

--[[
	Greedy cut of `leaves` (sorted by c) into rings whose predicted depth is at least `target`, at most
	MAX_BAND_LEAVES each; leaves at the same c (RING_TIE) stay together. Returns the bounds, or nil when it takes more
	than `maxRings` rings (or one group alone misses the target).
]]
local function greedyRings(
	config: Config,
	near: Near,
	ctx: RingContext,
	leaves: { RingLeaf },
	target: number,
	maxRings: number
): { number }?
	local bounds: { number } = {}
	local acc: RingAcc? = nil
	local n = #leaves
	local i = 1
	while i <= n do
		local j = i
		while j < n and leaves[j + 1].c - leaves[i].c <= RING_TIE do
			j += 1
		end
		local trial = ringEmpty()
		local current = acc
		if current then
			trial.minU, trial.maxU, trial.minV, trial.maxV = current.minU, current.maxU, current.minV, current.maxV
			trial.top, trial.dmin, trial.dfar, trial.count = current.top, current.dmin, current.dfar, current.count
		end
		for k = i, j do
			ringAdd(trial, leaves[k])
		end
		local fits = trial.count <= MAX_BAND_LEAVES and ringDepth(config, near, ctx, trial) >= target
		if not fits and current then
			-- close the ring before this group
			table.insert(bounds, leaves[i].c)
			if #bounds + 1 > maxRings then
				return nil
			end
			trial = ringEmpty()
			for k = i, j do
				ringAdd(trial, leaves[k])
			end
			fits = trial.count <= MAX_BAND_LEAVES and ringDepth(config, near, ctx, trial) >= target
		end
		if not fits then
			return nil
		end
		acc = trial
		i = j + 1
	end
	return bounds
end

-- Predicted depth (smallest over the rings) and whether every ring fits a mesh, for given bounds.
local function evaluateRings(
	config: Config,
	near: Near,
	ctx: RingContext,
	leaves: { RingLeaf },
	bounds: { number },
	maxRings: number
): (boolean, number)
	if #bounds + 1 > maxRings then
		return false, 0
	end
	local accs: { RingAcc } = {}
	for index = 1, #bounds + 1 do
		accs[index] = ringEmpty()
	end
	for _, leaf in leaves do
		ringAdd(accs[ringIndex(bounds, leaf.c) + 1], leaf)
	end
	local depth = math.huge
	for _, acc in accs do
		if acc.count > MAX_BAND_LEAVES then
			return false, 0
		elseif acc.count > 0 then
			depth = math.min(depth, ringDepth(config, near, ctx, acc))
		end
	end
	return true, depth
end

--[[
	CHANGED (Terrain polish): ring bounds (ascending Chebyshev distances from the near origin, m; ring i holds the
	leaves with bounds[i] <= c < bounds[i + 1]) for the leaves outside the near band, drawn with `maxRings` bands,
	and their predicted nearest drawn depth (studs). nil when no layout fits (too many leaves: select() retries).
	The previous bounds are kept while they still fit and reach RING_KEEP of the best depth.
]]
function TerrainMath.planRings(
	config: Config,
	nodes: { Node },
	maxRings: number,
	near: Near,
	ctx: RingContext
): ({ number }?, number)
	local leaves: { RingLeaf } = table.create(#nodes)
	for _, node in nodes do
		table.insert(leaves, ringLeaf(near, ctx.cam, node))
	end
	table.sort(leaves, function(a: RingLeaf, b: RingLeaf): boolean
		return a.c < b.c
	end)
	if #leaves == 0 then
		return {}, RING_DEPTH_MAX
	end
	local best = greedyRings(config, near, ctx, leaves, 0, maxRings)
	if best == nil then
		return nil, 0
	end
	local lo, hi = 0, RING_DEPTH_MAX
	for _ = 1, RING_SEARCH_STEPS do
		local mid = (lo + hi) / 2
		local cut = greedyRings(config, near, ctx, leaves, mid, maxRings)
		if cut then
			best, lo = cut, mid
		else
			hi = mid
		end
	end
	local chosen = best :: { number }
	local _, depth = evaluateRings(config, near, ctx, leaves, chosen, maxRings)
	local previous = ctx.previous
	if previous then
		local fits, kept = evaluateRings(config, near, ctx, leaves, previous, maxRings)
		if fits and kept >= RING_KEEP * depth then
			return previous, kept
		end
	end
	return chosen, depth
end

--[[
	CHANGED (Night review): band id of every leaf (by key) when drawn with `bandCount` bands.
	Without `near`: one band per level (id = the level), every level from mergeLevel up shares the last one.
	With `near` (bandCount >= 2): the leaves up to near.maxLeaf whose centre lies in the near square go to band 0
	(one part, at true scale while its centre is within the draw budget), every other leaf to a band per level as
	above, shifted by one (id = 1 + level; the levels from the finest leaf of the selection + bandCount - 2 up share
	the last one).
	CHANGED (Terrain polish): with `near` and `rings`, the other leaves go to ring bands instead (id = 1 + ring index,
	TerrainMath.planRings). Also returns the ring bounds (nil without rings) and whether a layout fits (false: too
	many leaves for the bands; the ids are then per level).
]]
function TerrainMath.assignBands(
	config: Config,
	leaves: { Node },
	bandCount: number,
	near: Near?,
	rings: RingContext?
): ({ [number]: number }, { number }?, boolean)
	local result: { [number]: number } = {}
	if near == nil or bandCount < 2 then
		local merge = TerrainMath.mergeLevel(config, leaves, bandCount)
		for _, node in leaves do
			result[node.key] = TerrainMath.bandOf(config, node, merge)
		end
		return result, nil, true
	end
	local limit = near.maxLeaf * SIZE_TOLERANCE
	local half = near.half
	local ring: { Node } = {}
	for _, node in leaves do
		local inside = false
		if node.size <= limit then
			local u, v, facing = nearCoords(near, node.cx, node.cy, node.cz)
			inside = facing and math.abs(u) <= half and math.abs(v) <= half
		end
		if inside then
			result[node.key] = NEAR_BAND
		else
			table.insert(ring, node)
		end
	end
	-- CHANGED (Terrain polish): ring bands
	if rings then
		local bounds = TerrainMath.planRings(config, ring, bandCount - 1, near, rings)
		if bounds then
			for _, node in ring do
				local u, v = nearCoords(near, node.cx, node.cy, node.cz)
				result[node.key] = NEAR_BAND + 1 + ringIndex(bounds, math.max(math.abs(u), math.abs(v)))
			end
			return result, bounds, true
		end
	end
	-- the levels are counted from the finest of ALL leaves (not just these), so a few finest leaves crossing the
	-- square's edge do not shift every band id by one (a plan would rebuild them all)
	local merge = TerrainMath.mergeLevel(config, leaves, bandCount - 1)
	for _, node in ring do
		result[node.key] = NEAR_BAND + 1 + TerrainMath.bandOf(config, node, merge)
	end
	return result, nil, rings == nil
end

TerrainMath.NEAR_BAND = NEAR_BAND

--[[
	CHANGED (Night review): the next step of a plan that swaps bands (pure; TerrainMesh runs it).
	  pending   band ids that still need their final mesh       covered  band ids whose new leaves are on screen
	  deps      id -> ids holding the replacements of its outgoing leaves
	  alive     id -> whether a mesh is on screen for it         empty    id -> whether its target is empty
	  liveCount meshes on screen; bandCount the bands the budget allows
	Returns ("build", id): build its final mesh (ready: every dependency covered; bands that go away first, then
	replaced ones, new ones last, lowest id first); ("union", id): bands wait on each other, show its new leaves
	while keeping its outgoing ones (an existing band first); ("retire", id): drop a band that goes away BEFORE its
	replacements are up, because a mesh must be built next and more than bandCount bands are alive (a new band was
	added while the one it replaces still waits; the caller marks the coverage broken: plates fill in until the plan
	is done); nil: nothing can make progress.
]]
function TerrainMath.planStep(
	pending: { [number]: boolean },
	covered: { [number]: boolean },
	deps: { [number]: { [number]: boolean } },
	alive: { [number]: boolean },
	empty: { [number]: boolean },
	liveCount: number,
	bandCount: number
): (StepKind?, number?)
	local chosen: number? = nil
	local rank = math.huge
	for id in pending do
		local ready = true
		local waits = deps[id]
		if waits then
			for dep in waits do
				if not covered[dep] then
					ready = false
					break
				end
			end
		end
		if ready then
			local r = if empty[id] then 1 elseif alive[id] then 2 else 3
			if r < rank or (r == rank and id < (chosen :: number)) then
				chosen, rank = id, r
			end
		end
	end
	local kind: StepKind = "build"
	if chosen == nil then
		-- bands waiting on each other: a union, on an existing band if any
		for id in pending do
			if not covered[id] then
				local better = chosen == nil
					or (alive[id] and not alive[chosen :: number])
					or (alive[id] == alive[chosen :: number] and id < (chosen :: number))
				if better then
					chosen = id
				end
			end
		end
		if chosen == nil then
			return nil, nil
		end
		kind = "union"
	end
	local id = chosen :: number
	if not empty[id] and liveCount > bandCount then
		-- a build needs a mesh on top of the live ones (bandCount + 1 at most): free one first (a new band was
		-- just added while one going away still waits for it) - the band going away with the highest id
		local doomed: number? = nil
		for other in pending do
			if empty[other] and alive[other] and (doomed == nil or other > (doomed :: number)) then
				doomed = other
			end
		end
		if doomed then
			return "retire", doomed
		end
	end
	return kind, id
end

-- Key of the parent of node (face, depth, x, y) (nil at depth 0).
function TerrainMath.parentKey(bodyId: number, face: number, depth: number, x: number, y: number): number?
	if depth <= 0 then
		return nil
	end
	return TerrainMath.nodeKey(bodyId, face, depth - 1, x // 2, y // 2)
end

--[[
	Uniform scale about the camera for a band whose box centre is `distCentre` m away, whose farthest point is
	`distFar` m away and whose box is `extent` m across at most: 1 (true scale) when it fits. The engine culls a part
	by where it is (its centre within the draw budget keeps it drawn, vertices and all: S11), the far end must stay
	inside `farLimit` (the farthest anything is drawn at the best quality) and the part size limit always holds.
]]
function TerrainMath.bandScale(
	distCentre: number,
	distFar: number,
	extent: number,
	budget: number,
	farLimit: number,
	partLimit: number
): number
	local k = 1
	if distCentre * k > budget then
		k = budget / distCentre
	end
	if distFar * k > farLimit then
		k = farLimit / distFar
	end
	if extent * k > partLimit then
		k = partLimit / extent
	end
	if k < MIN_SCALE then
		k = MIN_SCALE
	end
	return k
end

--[[
	CHANGED (Terrain polish): the factor each band is drawn at this frame. maxScales[i] is band i's largest factor
	(bandScale), nearest[i] how near its ground comes (m). A band that fits at true scale stays so. The others are
	drawn at the SAME factor - the smallest maximum among them (the outermost ring's) - so they keep their true
	order among themselves (two bands scaled differently draw the farther one in front wherever the nearer one hides
	it: distant sea and mountains showed through nearer hills, "see through the earth"), except that a band whose
	ground starts within `protect` / that factor of the camera gets just the factor that draws that ground at
	`protect` studs (so true-scale things nearer than `protect` are never covered by it), up to its maximum.
]]
function TerrainMath.bandScales(maxScales: { number }, nearest: { number }, protect: number): { number }
	local floor = 1
	for _, k in maxScales do
		if k < TRUE_SCALE_FACTOR then
			floor = math.min(floor, k)
		end
	end
	local scales: { number } = table.create(#maxScales, 1)
	for index, k in maxScales do
		if k >= TRUE_SCALE_FACTOR then
			scales[index] = k
		else
			scales[index] = math.min(k, math.max(floor, protect / math.max(nearest[index], 1)))
		end
	end
	return scales
end

--[[
	CHANGED (Review 3): the factor to draw a true-scale object (the launch-site copy) scaled about the camera by when
	the ground under it is drawn at `terrainScale` (< 1): at most that (never behind its own ground), and in front
	of every scaled band behind it (`depthScale`, TerrainMesh.depthScale) - but never nearer than `protect` studs
	(TerrainMesh.protectDepth: bandScales keeps scaled ground that far away, so true-scale things nearer than that,
	a craft hovering over the site, its smoke trail, a dropped stage, are never covered by it). `nearest` is the
	object's true distance from the camera (m, a lower bound). Where the two disagree the protected depth wins:
	ground behind the object may then cover a strip of it, as it would cover any true-scale object there.
]]
function TerrainMath.objectScale(terrainScale: number, depthScale: number, protect: number, nearest: number): number
	return math.min(terrainScale, math.max(depthScale, protect / math.max(nearest, 1)))
end

--[[
	CHANGED (Review 3): what Surface draws for the launch site, from the factor of the ground under the real plate
	(`terrainScale`), whether the camera is in the base pocket (`inBase`, where the real base is) and near the site
	(`nearSite`), and the objectScale inputs. Returns the copy's wanted factor (nil: no copy) and whether the scaled
	ground under the plate must be hidden (TerrainMesh.hideScaledAt):
	  * ground under the plate at true scale: nothing in the base pocket (the real base is right), a true-scale
	    copy elsewhere (a craft on its pad stands on it)
	  * scaled ground, base pocket, near the site: never the copy (it would be drawn in front of the player, the
	    rockets on the pads and everyone on the base); that ground is hidden instead and the real plate shows
	  * otherwise the copy at objectScale
]]
function TerrainMath.siteCopyScale(
	terrainScale: number,
	inBase: boolean,
	nearSite: boolean,
	depthScale: number,
	protect: number,
	nearest: number
): (number?, boolean)
	if terrainScale >= TRUE_SCALE_FACTOR then
		return if inBase then nil else 1, false
	end
	if inBase and nearSite then
		return nil, true
	end
	return TerrainMath.objectScale(terrainScale, depthScale, protect, nearest), false
end

--[[
	CHANGED (Review 3): how much daylight the baked haze shows (0 night .. 1 day, in HAZE_LIGHT_STEP steps) for the
	sine of the sun's elevation at the camera. The haze is baked into the vertex colours, and the scene's lighting
	multiplies it like the ground's own colour, so a bright day haze made the far ground 2-3x brighter than the
	near grass at night (a pale band under a dark sky).
]]
function TerrainMath.daylight(sunUp: number): number
	local x = math.clamp((sunUp - HAZE_NIGHT_SUN) / (HAZE_DAY_SUN - HAZE_NIGHT_SUN), 0, 1)
	local smooth = x * x * (3 - 2 * x)
	return math.floor(smooth / HAZE_LIGHT_STEP + 0.5) * HAZE_LIGHT_STEP
end

-- CHANGED (Review 3): the haze colour for a daylight level: `day` (r, g, b) by day, a dark, greyer version of the
-- body's atmosphere colour at night, blended in between.
function TerrainMath.hazeColour(day: { number }, atmosphere: Color3, light: number): (number, number, number)
	local grey = 0.3 * atmosphere.R + 0.59 * atmosphere.G + 0.11 * atmosphere.B
	local function night(c: number): number
		return HAZE_NIGHT_BRIGHTNESS * (c + (grey - c) * HAZE_NIGHT_GREY)
	end
	local nr, ng, nb = night(atmosphere.R), night(atmosphere.G), night(atmosphere.B)
	local l = math.clamp(light, 0, 1)
	return nr + (day[1] - nr) * l, ng + (day[2] - ng) * l, nb + (day[3] - nb) * l
end

--[[
	CHANGED (Night review): the scale to apply to an object drawn at `applied` when `wanted` is needed, on the
	ladder ratio^n (ratio < 1): always at or below `wanted` (an object drawn like the ground under it stays at or in
	front of it, never behind it); it only grows back once `wanted` is two steps above `applied` (no flicker between
	neighbouring steps), or to 1 (true scale) as soon as the ground is.
]]
function TerrainMath.scaleStep(wanted: number, applied: number, ratio: number): number
	if wanted >= 1 then
		return 1
	end
	if wanted < applied or wanted > applied / (ratio * ratio) then
		local n = math.ceil(math.log(math.max(wanted, MIN_SCALE)) / math.log(ratio) - 1e-9)
		return ratio ^ n
	end
	return applied
end

--============================================================================
-- Chunk geometry
--============================================================================

-- Largest radial gap (m) between an edge's heights and the same edge seen by a neighbour `factor` times coarser.
--[[
	Largest radial gap (m) between an edge's ground points (ex, ey, ez: CHUNK + 1 points) and the straight edge a
	neighbour `factor` times coarser draws through every factor-th of them (chord sag included).
]]
local function edgeGap(ex: { number }, ey: { number }, ez: { number }, factor: number): number
	local worst = 0
	for k = 0, CHUNK do
		local k0 = math.floor(k / factor) * factor
		if k0 == k then
			continue
		end
		local k1 = math.min(k0 + factor, CHUNK)
		local t = (k - k0) / (k1 - k0)
		local cx = ex[k0 + 1] + (ex[k1 + 1] - ex[k0 + 1]) * t
		local cy = ey[k0 + 1] + (ey[k1 + 1] - ey[k0 + 1]) * t
		local cz = ez[k0 + 1] + (ez[k1 + 1] - ez[k0 + 1]) * t
		local px, py, pz = ex[k + 1], ey[k + 1], ez[k + 1]
		local gap = math.abs(math.sqrt(px * px + py * py + pz * pz) - math.sqrt(cx * cx + cy * cy + cz * cz))
		if gap > worst then
			worst = gap
		end
	end
	return worst
end

-- Grid position (a, b) of the k-th vertex along chunk edge 1 (a = 0), 2 (a = CHUNK), 3 (b = 0) or 4 (b = CHUNK).
local function edgeVertex(edge: number, k: number): (number, number)
	if edge == 1 then
		return 0, k
	elseif edge == 2 then
		return CHUNK, k
	elseif edge == 3 then
		return k, 0
	end
	return k, CHUNK
end

local templates: { [number]: { number } } = {}

--[[
	Triangle indices of a chunk (every chunk has the same topology): bit 0 of `mask` flips the ground triangles'
	winding, bit `edge` flips that edge's skirt quads. Shared and frozen.
]]
local function triangleTemplate(mask: number): { number }
	local cached = templates[mask]
	if cached then
		return cached
	end
	local tris: { number } = table.create(3 * (2 * CHUNK * CHUNK + 8 * CHUNK))
	local function vertex(a: number, b: number): number
		return a * (CHUNK + 1) + b + 1
	end
	local flip = mask % 2 == 1
	local function tri(a: number, b: number, c: number)
		if flip then
			b, c = c, b
		end
		table.insert(tris, a)
		table.insert(tris, b)
		table.insert(tris, c)
	end
	for a = 0, CHUNK - 1 do
		for b = 0, CHUNK - 1 do
			-- same split as SurfaceHeight: (a, b) -> (a + 1, b + 1)
			local v00, v10, v11, v01 = vertex(a, b), vertex(a + 1, b), vertex(a + 1, b + 1), vertex(a, b + 1)
			tri(v00, v10, v11)
			tri(v00, v11, v01)
		end
	end
	local surfaceCount = (CHUNK + 1) * (CHUNK + 1)
	for edge = 1, 4 do
		local first = surfaceCount + (edge - 1) * (CHUNK + 1) + 1
		local skirtFlip = math.floor(mask / 2 ^ edge) % 2 == 1
		for k = 0, CHUNK - 1 do
			local a0, b0 = edgeVertex(edge, k)
			local a1, b1 = edgeVertex(edge, k + 1)
			local A, B = vertex(a0, b0), vertex(a1, b1)
			local D, C = first + k, first + k + 1
			if skirtFlip then
				table.insert(tris, A)
				table.insert(tris, C)
				table.insert(tris, B)
				table.insert(tris, A)
				table.insert(tris, D)
				table.insert(tris, C)
			else
				table.insert(tris, A)
				table.insert(tris, B)
				table.insert(tris, C)
				table.insert(tris, A)
				table.insert(tris, C)
				table.insert(tris, D)
			end
		end
	end
	table.freeze(tris)
	templates[mask] = tris
	return tris
end

--[[
	Geometry of a leaf: (CHUNK + 1)^2 ground vertices plus a skirt along each edge. Vertex index of ground vertex
	(a, b) (a along u, b along v, 0 .. CHUNK) is a * (CHUNK + 1) + b + 1.
]]
function TerrainMath.buildChunk(config: Config, node: Node): Chunk
	local bodyId = config.bodyId
	local radius = config.radius
	local face, i0, j0, s = node.face, node.i0, node.j0, node.stride
	local side = CHUNK + 3 -- grid with one ring of neighbours for the normals
	local count = side * side
	local gx: { number } = table.create(count, 0)
	local gy: { number } = table.create(count, 0)
	local gz: { number } = table.create(count, 0)
	local hx: { number } = table.create(count, 0)
	local dxs: { number } = table.create(count, 0)
	local dys: { number } = table.create(count, 0)
	local dzs: { number } = table.create(count, 0)
	for a = -1, CHUNK + 1 do
		for b = -1, CHUNK + 1 do
			local idx = (a + 1) * side + (b + 1) + 1
			local i, j = i0 + a * s, j0 + b * s
			local x, y, z = SurfaceHeight.nodeDirection(bodyId, face, i, j)
			local h = SurfaceHeight.nodeHeight(bodyId, face, i, j)
			local r = radius + h
			gx[idx], gy[idx], gz[idx] = x * r, y * r, z * r
			hx[idx] = h
			dxs[idx], dys[idx], dzs[idx] = x, y, z
		end
	end
	local function g(a: number, b: number): number
		return (a + 1) * side + (b + 1) + 1
	end
	local ox, oy, oz = node.cx, node.cy, node.cz

	local surfaceCount = (CHUNK + 1) * (CHUNK + 1)
	local total = surfaceCount + 4 * (CHUNK + 1)
	local px: { number } = table.create(total, 0)
	local py: { number } = table.create(total, 0)
	local pz: { number } = table.create(total, 0)
	local nx: { number } = table.create(total, 0)
	local ny: { number } = table.create(total, 0)
	local nz: { number } = table.create(total, 0)
	local cr: { number } = table.create(total, 0)
	local cg: { number } = table.create(total, 0)
	local cb: { number } = table.create(total, 0)
	local earth = bodyId == Bodies.HOMEWORLD
	for a = 0, CHUNK do
		for b = 0, CHUNK do
			local idx = g(a, b)
			local v = a * (CHUNK + 1) + b + 1
			local dx, dy, dz = dxs[idx], dys[idx], dzs[idx]
			px[v] = gx[idx] - dx * RENDER_DROP - ox
			py[v] = gy[idx] - dy * RENDER_DROP - oy
			pz[v] = gz[idx] - dz * RENDER_DROP - oz
			-- smooth normal from the neighbouring nodes (central differences)
			local ia, ib = g(a + 1, b), g(a - 1, b)
			local ja, jb = g(a, b + 1), g(a, b - 1)
			local ux, uy, uz = gx[ia] - gx[ib], gy[ia] - gy[ib], gz[ia] - gz[ib]
			local wx, wy, wz = gx[ja] - gx[jb], gy[ja] - gy[jb], gz[ja] - gz[jb]
			local cx, cy, cz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
			local len = math.sqrt(cx * cx + cy * cy + cz * cz)
			if len <= 0 then
				cx, cy, cz, len = dx, dy, dz, 1
			end
			if cx * dx + cy * dy + cz * dz < 0 then
				len = -len
			end
			cx, cy, cz = cx / len, cy / len, cz / len
			nx[v], ny[v], nz[v] = cx, cy, cz
			local r, gg, bb, kind = Biome.sample(bodyId, dx, dy, dz)
			-- CHANGED (Terrain polish): the site test in metres of the site's tangent plane (sink below)
			local siteE = if earth and dx > 0 then math.abs(dz) * radius / dx else math.huge
			local siteN = if earth and dx > 0 then math.abs(dy) * radius / dx else math.huge
			if siteE <= SITE_PLATE_HALF and siteN <= SITE_PLATE_HALF then
				-- base-pocket axes at lat 0 / lon 0: east = universe +Z, north = universe +Y, up = +X
				r, gg, bb = SITE_PLATE_COLOR[1], SITE_PLATE_COLOR[2], SITE_PLATE_COLOR[3]
				-- CHANGED (Terrain polish): under the base's 20-stud ground plate the drawn ground is sunk SITE_SINK m
				-- (every triangle touching such a vertex lies under the plate: it is a full quad spacing inside its
				-- edge), so it can never z-fight the plate or rise through it when drawn scaled about the camera
				local sink = siteSink(config, dx, dy, dz, s)
				px[v] -= dx * sink
				py[v] -= dy * sink
				pz[v] -= dz * sink
			else
				-- CHANGED (Terrain polish): slope, cavity, height and noise detail (groundColour)
				local slope = 1 - (cx * dx + cy * dy + cz * dz)
				local cavity = (hx[ia] + hx[ib] + hx[ja] + hx[jb]) / 4 - hx[idx]
				r, gg, bb =
					groundColour(bodyId, kind, dx, dy, dz, r, gg, bb, slope, cavity / (s * config.cellArc), hx[idx])
			end
			cr[v], cg[v], cb[v] = r, gg, bb
		end
	end

	--[[
		skirt depth: covers the crack along any edge to a neighbour up to 4x coarser (whose straight edge may pass
		below this one's vertices), and to a 2x finer one (whose extra vertices may dip below this edge)
	]]
	local ex: { number } = table.create(CHUNK + 1, 0)
	local ey: { number } = table.create(CHUNK + 1, 0)
	local ez: { number } = table.create(CHUNK + 1, 0)
	local worst = 0
	local half = s / 2
	for edge = 1, 4 do
		for k = 0, CHUNK do
			local idx = g(edgeVertex(edge, k))
			ex[k + 1], ey[k + 1], ez[k + 1] = gx[idx], gy[idx], gz[idx]
		end
		worst = math.max(worst, edgeGap(ex, ey, ez, 2), edgeGap(ex, ey, ez, 4))
		if s >= 2 then
			for k = 0, CHUNK - 1 do
				local a0, b0 = edgeVertex(edge, k)
				local a1, b1 = edgeVertex(edge, k + 1)
				local i = i0 + a0 * s + (a1 - a0) * half
				local j = j0 + b0 * s + (b1 - b0) * half
				local x, y, z = groundPoint(bodyId, radius, face, i, j)
				local cx, cy, cz = (ex[k + 1] + ex[k + 2]) / 2, (ey[k + 1] + ey[k + 2]) / 2, (ez[k + 1] + ez[k + 2]) / 2
				local gap = math.abs(math.sqrt(x * x + y * y + z * z) - math.sqrt(cx * cx + cy * cy + cz * cz))
				if gap > worst then
					worst = gap
				end
			end
		end
	end
	local skirt = math.max(SKIRT_MIN, SKIRT_ERROR_MULT * worst + SKIRT_ERROR_PAD)

	local function vertex(a: number, b: number): number
		return a * (CHUNK + 1) + b + 1
	end
	-- winding: (B - A) x (C - A) must point up (outward) for the cell (0, 0) triangle (00, 10, 11)
	local mask = 0
	do
		local A, B, C = vertex(0, 0), vertex(1, 0), vertex(1, 1)
		local ux, uy, uz = px[B] - px[A], py[B] - py[A], pz[B] - pz[A]
		local wx, wy, wz = px[C] - px[A], py[C] - py[A], pz[C] - pz[A]
		local cx, cy, cz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
		if cx * node.dx + cy * node.dy + cz * node.dz < 0 then
			mask += 1
		end
	end

	-- skirts: a copy of each edge lowered by `skirt`, joined to it with quads facing outward
	local nextVertex = surfaceCount
	for edge = 1, 4 do
		local first = nextVertex + 1
		for k = 0, CHUNK do
			local a, b = edgeVertex(edge, k)
			local src = vertex(a, b)
			local idx = g(a, b)
			nextVertex += 1
			px[nextVertex] = px[src] - dxs[idx] * skirt
			py[nextVertex] = py[src] - dys[idx] * skirt
			pz[nextVertex] = pz[src] - dzs[idx] * skirt
			nx[nextVertex], ny[nextVertex], nz[nextVertex] = nx[src], ny[src], nz[src]
			cr[nextVertex], cg[nextVertex], cb[nextVertex] = cr[src], cg[src], cb[src]
		end
		-- does the quad (A, B, C) face outward (from the chunk centre toward the edge's middle)?
		local ma, mb = edgeVertex(edge, CHUNK / 2)
		local mid, centre = vertex(ma, mb), vertex(CHUNK / 2, CHUNK / 2)
		local outX, outY, outZ = px[mid] - px[centre], py[mid] - py[centre], pz[mid] - pz[centre]
		local a0, b0 = edgeVertex(edge, 0)
		local a1, b1 = edgeVertex(edge, 1)
		local A, B, C = vertex(a0, b0), vertex(a1, b1), first + 1
		local ux, uy, uz = px[B] - px[A], py[B] - py[A], pz[B] - pz[A]
		local wx, wy, wz = px[C] - px[A], py[C] - py[A], pz[C] - pz[A]
		local cx, cy, cz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
		if cx * outX + cy * outY + cz * outZ < 0 then
			mask += 2 ^ edge
		end
	end

	-- pack the vertices (f32: positions are small offsets from the origin)
	local data = buffer.create(nextVertex * VERTEX_BYTES)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for v = 1, nextVertex do
		local x, y, z = px[v], py[v], pz[v]
		if x < minX then
			minX = x
		end
		if x > maxX then
			maxX = x
		end
		if y < minY then
			minY = y
		end
		if y > maxY then
			maxY = y
		end
		if z < minZ then
			minZ = z
		end
		if z > maxZ then
			maxZ = z
		end
		local o = (v - 1) * VERTEX_BYTES
		buffer.writef32(data, o, x)
		buffer.writef32(data, o + 4, y)
		buffer.writef32(data, o + 8, z)
		buffer.writef32(data, o + 12, nx[v])
		buffer.writef32(data, o + 16, ny[v])
		buffer.writef32(data, o + 20, nz[v])
		buffer.writef32(data, o + 24, cr[v])
		buffer.writef32(data, o + 28, cg[v])
		buffer.writef32(data, o + 32, cb[v])
	end
	local tris = triangleTemplate(mask)
	return {
		key = node.key,
		depth = node.depth,
		ox = ox,
		oy = oy,
		oz = oz,
		vertexCount = nextVertex,
		triangleCount = #tris / 3,
		data = data,
		tris = tris,
		skirt = skirt,
		minX = minX,
		minY = minY,
		minZ = minZ,
		maxX = maxX,
		maxY = maxY,
		maxZ = maxZ,
	}
end

-- Vertex v of a chunk: position (relative to the chunk origin), unit normal and colour.
function TerrainMath.chunkVertex(
	chunk: Chunk,
	v: number
): (number, number, number, number, number, number, number, number, number)
	local data, o = chunk.data, (v - 1) * VERTEX_BYTES
	return buffer.readf32(data, o),
		buffer.readf32(data, o + 4),
		buffer.readf32(data, o + 8),
		buffer.readf32(data, o + 12),
		buffer.readf32(data, o + 16),
		buffer.readf32(data, o + 20),
		buffer.readf32(data, o + 24),
		buffer.readf32(data, o + 28),
		buffer.readf32(data, o + 32)
end

--============================================================================
-- CHANGED (Terrain polish): band seams (stitchCode / stitchChunk)
--============================================================================
--[[
	Every band but the near one is drawn scaled down about the camera, nearer than it is, and each band's skirts
	hang below its edges. The skirt on a band's inner edge faces the camera, and since its band is drawn nearer
	than the finer band inside it, it covered that band's ground just inside the seam: walls and stripes (in the
	ground's colour, or blue along coasts) along every band boundary, "see through the earth". So at a seam between
	two bands:
	  * the leaf on the outer side (higher band id) keeps only a SKIRT_INNER skirt on that edge, and
	  * the finer of the two leaves has its edge vertices moved onto the coarser leaf's straight edge (stitched), so
	    the two edges are the same line: no crack to cover, in truth or on screen (both bands are scaled about the
	    camera: points of one line stay on one line).
	A leaf's code packs, per edge (1..4: u-, u+, v-, v+), the stitch (log2 of how much coarser the neighbour is; 0 =
	none) plus 8 if the edge only keeps the short skirt: code = sum(edgeCode * 16^(edge - 1)).
]]
function TerrainMath.stitchCode(stitchLog2: { number }, inner: { boolean }): number
	local code = 0
	for edge = 1, 4 do
		local e = math.clamp(stitchLog2[edge] or 0, 0, 7) + (if inner[edge] then 8 else 0)
		code += e * 16 ^ (edge - 1)
	end
	return code
end

--[[
	CHANGED (See-through fix): `code` with every edge's plain (deep) skirt back, the stitches kept. For the new leaves
	of a union mesh (TerrainMesh): next to them the outgoing leaves are still drawn, sunk, and the neighbours their
	stitches expect are not on screen yet, so the deep skirts close those passing cracks (the union is replaced by
	the band's final mesh within the same plan).
]]
function TerrainMath.plainSkirts(code: number): number
	local out = 0
	for edge = 1, 4 do
		local e = math.floor(code / 16 ^ (edge - 1)) % 16
		out += (e % 8) * 16 ^ (edge - 1)
	end
	return out
end

--============================================================================
-- CHANGED (See-through fix): occlusion by the body's bulge
--============================================================================
--[[
	Why: every band but the near one is drawn scaled down about the camera, i.e. nearer than it is, so where nearer
	ground hides it (in truth) it is drawn IN FRONT of that ground instead. The worst case is the ring that holds the
	ground beyond the horizon (factor ~0.03-0.05, drawn ~200-300 studs away): its hill sides facing the camera lie
	behind the horizon bulge, and were drawn over the nearer ground as hazy grey-blue slabs along the horizon
	(Steamy, 250 m over the plain: "I can see through the planet on the distant ground"). Back-face culling hides the
	flat ground beyond the horizon, but not slopes that face the camera.
	The fix leaves those triangles out of the scaled bands: a triangle is dropped when every vertex is hidden behind
	a sphere that lies entirely below the drawn ground (radius: the body's lowest ground, minus the render drop, the
	site sink and OCCLUDER_SLACK, minus `reach`). Exact and conservative:
	  * the segment from the camera to a hidden point passes below that sphere, so it crosses the drawn (watertight:
	    seamCode) ground before the point: the point is really hidden;
	  * shrinking the sphere by `reach` keeps that true for every camera within `reach` of `cam` (each point of the
	    segment moves by at most `reach`), so the bands stay right while the camera moves that far; TerrainMesh
	    rebuilds them before it moves farther;
	  * behind the plane of the horizon circle the hidden region is convex (the shadow cone), so a triangle whose
	    vertices are hidden is hidden as a whole: no holes.
	nil when the camera is (nearly) inside that sphere.
]]
function TerrainMath.bulgeOccluder(config: Config, cam: Vec3d, reach: number): Occluder?
	local radius = config.radius + config.minHeight - RENDER_DROP - SITE_SINK - OCCLUDER_SLACK - math.max(reach, 0)
	local c2 = cam.x * cam.x + cam.y * cam.y + cam.z * cam.z - radius * radius
	if radius <= 0 or c2 <= 1 then
		return nil
	end
	return { x = cam.x, y = cam.y, z = cam.z, c2 = c2, reach = math.max(reach, 0) }
end

-- CHANGED (See-through fix): distance (m) from body-relative `cam` to the horizon of the body's lowest ground (0 below it)
function TerrainMath.horizonDistance(config: Config, cam: Vec3d): number
	local low = config.radius + config.minHeight
	local d2 = cam.x * cam.x + cam.y * cam.y + cam.z * cam.z - low * low
	return if d2 > 0 then math.sqrt(d2) else 0
end

-- CHANGED (See-through fix): is body-relative point (px, py, pz) hidden behind the occluder's sphere?
function TerrainMath.occluded(o: Occluder, px: number, py: number, pz: number): boolean
	local dx, dy, dz = px - o.x, py - o.y, pz - o.z
	local a = dx * dx + dy * dy + dz * dz
	local b = o.x * dx + o.y * dy + o.z * dz
	-- the closest approach to the centre lies strictly inside the segment, and inside the sphere
	return b < 0 and -b < a and b * b > a * o.c2
end

-- CHANGED (See-through fix): whether cullChunk leaves out the triangle with body-relative vertices a, b, c (front
-- face: (b - a) x (c - a)), for specs.
function TerrainMath.triangleHidden(o: Occluder, a: Vec3d, b: Vec3d, c: Vec3d): boolean
	local n = Vec3d.cross(Vec3d.sub(b, a), Vec3d.sub(c, a))
	return Vec3d.dot(n, Vec3d.sub(Vec3d.new(o.x, o.y, o.z), a)) > 0
		and TerrainMath.occluded(o, a.x, a.y, a.z)
		and TerrainMath.occluded(o, b.x, b.y, b.z)
		and TerrainMath.occluded(o, c.x, c.y, c.z)
end

--============================================================================
-- CHANGED (Far slabs fix): occlusion by the nearer ground (horizon profile)
--============================================================================
--[[
	Why: the scaled bands have different factors (each band's own part size / draw budget limit, and the protected
	depth of the nearest ring), a far band's smaller than a nearer one's. Wherever the nearer ground hides a far band
	in truth, the far band was drawn in FRONT of it (k_far x d_far < k_near x d_near): Steamy's grey / blue slabs (far
	hill and mountain faces) over the green plain, and green slabs through a ridge at night. No layout of uniform
	scales about the camera keeps every band's drawn depth in order (a ring's part limit forces k <= 1020 studs / its
	outer radius, so k falls outward), and the bulge sphere only covers what the lowest ground hides. So the scaled
	bands also leave out what the drawn ground itself hides, from a profile of it:
	  * newProfile / profileAdd: every 2 x 2 quads of every leaf of the plan (and of the bands on screen) write the
	    lowest of their nine lattice vertices, minus PROFILE.MARGIN (+ MARGIN_PER_SPACING x the quad spacing), into
	    the polar bins their footprint overlaps, in the camera's tangent frame. The drawn ground is planar between
	    those vertices, the leaf one level coarser joins every other one (its quad is the 2 x 2 block), and a finer
	    one adds bounded detail (MARGIN): a lower bound of the drawn ground whatever detail the other bands are
	    rebuilt with before this band is.
	  * finishProfile: bins nothing wrote count as no ground; each bin takes the lowest bound within `reach` (the
	    disc a moved camera's ray can stray by), then each azimuth keeps the running maximum of the occluding slope
	    (bound - reach) / distance.
	  * profileHides: a point p (height y_p over the camera, s_p from its nadir) is hidden from every camera within
	    `reach` when (y_p - reach) / s_p < that maximum before s_p: the camera's ray, moved by at most (1 - t) x reach
	    at its point t, then still passes below the ground's bound there (between the camera and p). A triangle is
	    hidden when the bound holds for its highest vertex, its nearest possible distance and every azimuth it spans:
	    exact and conservative for each of its points (no holes), whatever the bands' scales.
]]
local function profileBin(s: number): number
	if s < PROFILE.NEAR then
		return 0
	end
	return math.min(math.floor(math.log(s / PROFILE.NEAR) / math.log(PROFILE.RATIO)) + 1, PROFILE.DISTANCES - 1)
end

-- inner / outer distance (m) of distance bin d
local function profileInner(d: number): number
	return if d <= 0 then 0 else PROFILE.NEAR * PROFILE.RATIO ^ (d - 1)
end

local function profileAzimuth(a: number): number
	local n = PROFILE.AZIMUTHS
	return math.floor((a + math.pi) / (2 * math.pi) * n) % n
end

-- CHANGED (Far slabs fix): an empty profile for body-relative camera `cam`, valid within `reach` of it.
function TerrainMath.newProfile(cam: Vec3d, reach: number): Profile
	local up = Vec3d.normalize(cam)
	local seed = if math.abs(up.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
	local e = Vec3d.normalize(Vec3d.cross(seed, up))
	local f = Vec3d.cross(up, e)
	local cells = PROFILE.AZIMUTHS * PROFILE.DISTANCES
	local low = buffer.create(cells * 4)
	for i = 0, cells - 1 do
		buffer.writef32(low, i * 4, math.huge)
	end
	return {
		cx = cam.x,
		cy = cam.y,
		cz = cam.z,
		ux = up.x,
		uy = up.y,
		uz = up.z,
		ex = e.x,
		ey = e.y,
		ez = e.z,
		fx = f.x,
		fy = f.y,
		fz = f.z,
		reach = math.max(reach, 0),
		low = low,
		slope = buffer.create(cells * 4),
		finished = false,
	}
end

-- Height over the camera, distance from its nadir and azimuth of body-relative (x, y, z).
local function profileCoords(pf: Profile, x: number, y: number, z: number): (number, number, number, number, number)
	local rx, ry, rz = x - pf.cx, y - pf.cy, z - pf.cz
	local h = rx * pf.ux + ry * pf.uy + rz * pf.uz
	local u = rx * pf.ex + ry * pf.ey + rz * pf.ez
	local v = rx * pf.fx + ry * pf.fy + rz * pf.fz
	return h, math.sqrt(u * u + v * v), math.atan2(v, u), u, v
end

-- Smallest arc [lo, hi] (rad, hi - lo <= pi, else nil) holding the angles a, b, c (and d).
local function arcOf(a: number, b: number, c: number, d: number?): (number?, number)
	local tau = 2 * math.pi
	local rb = (b - a + math.pi) % tau - math.pi
	local rc = (c - a + math.pi) % tau - math.pi
	local rd = if d then (d - a + math.pi) % tau - math.pi else 0
	local lo, hi = math.min(0, rb, rc, rd), math.max(0, rb, rc, rd)
	if hi - lo > math.pi then
		return nil, 0
	end
	return a + lo, a + hi
end

--[[
	CHANGED (Far slabs fix): adds the ground of `chunk` (an unstitched buildChunk of `node`, a leaf drawn in some band
	or about to be) to the profile as a lower bound (see above).
]]
function TerrainMath.profileAdd(pf: Profile, chunk: Chunk, node: Node, cellArc: number)
	local side = CHUNK + 1
	local spacing = node.stride * cellArc
	local margin = PROFILE.MARGIN + PROFILE.MARGIN_PER_SPACING * spacing
	local data, ox, oy, oz = chunk.data, chunk.ox, chunk.oy, chunk.oz
	local hs: { number } = table.create(side * side, 0)
	local ss: { number } = table.create(side * side, 0)
	local as: { number } = table.create(side * side, 0)
	local us: { number } = table.create(side * side, 0)
	local vs: { number } = table.create(side * side, 0)
	for v = 1, side * side do
		local off = (v - 1) * VERTEX_BYTES
		hs[v], ss[v], as[v], us[v], vs[v] = profileCoords(
			pf,
			ox + buffer.readf32(data, off),
			oy + buffer.readf32(data, off + 4),
			oz + buffer.readf32(data, off + 8)
		)
	end
	local n, low = PROFILE.AZIMUTHS, pf.low
	local binWidth = 2 * math.pi / n
	-- 2 x 2 quad blocks: the quads of the leaf one level coarser (its vertices are every other one of these)
	for a = 0, CHUNK - 2, 2 do
		for b = 0, CHUNK - 2, 2 do
			local i1 = a * side + b + 1
			local i2, i3, i4 = i1 + 2, i1 + 2 * side, i1 + 2 * side + 2
			local diag = math.max(
				math.sqrt((us[i1] - us[i4]) ^ 2 + (vs[i1] - vs[i4]) ^ 2),
				math.sqrt((us[i2] - us[i3]) ^ 2 + (vs[i2] - vs[i3]) ^ 2)
			)
			local sMin = math.min(ss[i1], ss[i2], ss[i3], ss[i4]) - diag
			if sMin < PROFILE.NEAR then
				continue -- around the nadir: left unknown (no occluder)
			end
			local sMax = math.max(ss[i1], ss[i2], ss[i3], ss[i4])
			local lo, hi = arcOf(as[i1], as[i2], as[i3], as[i4])
			if lo == nil then
				continue
			end
			local value = math.huge
			for r = 0, 2 do
				local row = i1 + r * side
				value = math.min(value, hs[row], hs[row + 1], hs[row + 2])
			end
			value -= margin
			-- the middle vertices may bulge a little past the corners' arc
			local widen = 0.25 * diag / sMin
			local a0 = math.floor(((lo :: number) - widen + math.pi) / binWidth)
			local a1 = math.floor((hi + widen + math.pi) / binWidth)
			local d0, d1 = profileBin(sMin), profileBin(sMax + 0.25 * diag)
			for ab = a0, math.min(a1, a0 + n - 1) do
				local base = (ab % n) * PROFILE.DISTANCES
				for d = d0, d1 do
					local off = (base + d) * 4
					if value < buffer.readf32(low, off) then
						buffer.writef32(low, off, value)
					end
				end
			end
		end
	end
end

-- Sliding minimum over a circular ring `src` (n values), window i - w .. i + w, into `out` (van Herk / Gil-Werman).
local function ringMin(src: { number }, n: number, w: number, out: { number }, g: { number }, h: { number })
	if 2 * w + 1 >= n then
		local m = math.huge
		for i = 1, n do
			m = math.min(m, src[i])
		end
		for i = 1, n do
			out[i] = m
		end
		return
	end
	local k = 2 * w + 1
	local len = n + 2 * w
	for j = 0, len - 1 do
		local value = src[(j - w) % n + 1]
		g[j + 1] = if j % k == 0 then value else math.min(g[j], value)
	end
	for j = len - 1, 0, -1 do
		local value = src[(j - w) % n + 1]
		h[j + 1] = if j % k == k - 1 or j == len - 1 then value else math.min(h[j + 2], value)
	end
	for i = 0, n - 1 do
		out[i + 1] = math.min(h[i + 1], g[i + k])
	end
end

--[[
	CHANGED (Far slabs fix): turns the lower bounds into the occluding slopes (see above). `pause` is called now and
	then (a caller in a thread may yield there).
]]
function TerrainMath.finishProfile(pf: Profile, pause: (() -> ())?)
	local n, m = PROFILE.AZIMUTHS, PROFILE.DISTANCES
	local low, slope, reach = pf.low, pf.slope, pf.reach
	local binWidth = 2 * math.pi / n
	local ring: { number } = table.create(n, 0)
	local out: { number } = table.create(n, 0)
	local g: { number } = table.create(2 * n + 1, 0)
	local h: { number } = table.create(2 * n + 1, 0)
	-- 1. azimuth: the lowest bound within `reach` sideways (+ a bin: the point lies anywhere in its own bin)
	for d = 0, m - 1 do
		local inner = profileInner(d)
		local w = if inner <= reach then n else math.ceil(math.asin(reach / inner) / binWidth) + 1
		for a = 0, n - 1 do
			local value = buffer.readf32(low, (a * m + d) * 4)
			ring[a + 1] = if value == math.huge then PROFILE.UNKNOWN else value
		end
		ringMin(ring, n, math.min(w, n), out, g, h)
		for a = 0, n - 1 do
			buffer.writef32(slope, (a * m + d) * 4, out[a + 1])
		end
		if pause and d % 16 == 15 then
			pause()
		end
	end
	-- 2. distance: the lowest within `reach` along the azimuth, then the running maximum of the occluding slope
	local column: { number } = table.create(m, 0)
	for a = 0, n - 1 do
		local base = a * m
		for d = 0, m - 1 do
			column[d + 1] = buffer.readf32(slope, (base + d) * 4)
		end
		local best = -math.huge
		local first, last = 0, 0
		local windowMin = math.huge
		for d = 0, m - 1 do
			local inner = profileInner(d)
			local outer = profileInner(d + 1)
			local lo, hi = profileBin(math.max(inner - reach, 0)), profileBin(outer + reach)
			-- both ends only move outward: rescan only when the window's start passed the minimum's bin
			if lo > first or d == 0 then
				first = lo
				last = lo - 1
				windowMin = math.huge
			end
			while last < hi do
				last += 1
				windowMin = math.min(windowMin, column[last + 1])
			end
			local bound = windowMin
			local slopeHere = -math.huge
			if bound > PROFILE.UNKNOWN * 0.5 and inner > 0 then
				local num = bound - reach
				slopeHere = if num >= 0 then num / outer else num / inner
			end
			best = math.max(best, slopeHere)
			buffer.writef32(slope, (base + d) * 4, best)
		end
		if pause and a % 64 == 63 then
			pause()
		end
	end
	pf.finished = true
end
-- CHANGED (Far slabs fix): profileHides with the vertices' profileCoords (h, s, azimuth, tangent u, v) given.
local function profileHidesCoords(
	pf: Profile,
	h1: number,
	s1: number,
	a1: number,
	u1: number,
	v1: number,
	h2: number,
	s2: number,
	a2: number,
	u2: number,
	v2: number,
	h3: number,
	s3: number,
	a3: number,
	u3: number,
	v3: number
): boolean
	-- the triangle's nearest point to the nadir is at most its longest edge nearer than its nearest vertex
	local edge =
		math.sqrt(math.max((u1 - u2) ^ 2 + (v1 - v2) ^ 2, (u2 - u3) ^ 2 + (v2 - v3) ^ 2, (u3 - u1) ^ 2 + (v3 - v1) ^ 2))
	local sMin = math.min(s1, s2, s3) - edge
	if sMin < PROFILE.NEAR then
		return false
	end
	local d0 = profileBin(sMin)
	if d0 < 1 then
		return false
	end
	local lo, hi = arcOf(a1, a2, a3)
	if lo == nil then
		return false
	end
	local num = math.max(h1, h2, h3) - pf.reach
	local slopeUp = if num >= 0 then num / sMin else num / math.max(s1, s2, s3)
	local n, m = PROFILE.AZIMUTHS, PROFILE.DISTANCES
	local binWidth = 2 * math.pi / n
	local b0 = math.floor(((lo :: number) + math.pi) / binWidth)
	local b1 = math.floor((hi + math.pi) / binWidth)
	local slope = pf.slope
	for b = b0, b1 do
		if slopeUp >= buffer.readf32(slope, ((b % n) * m + d0 - 1) * 4) then
			return false
		end
	end
	return true
end

-- CHANGED (Far slabs fix): whether the drawn ground (finished profile) hides the whole triangle a, b, c (body-relative)
-- from every camera within the profile's reach.
function TerrainMath.profileHides(pf: Profile, a: Vec3d, b: Vec3d, c: Vec3d): boolean
	if not pf.finished then
		return false
	end
	local h1, s1, a1, u1, v1 = profileCoords(pf, a.x, a.y, a.z)
	local h2, s2, a2, u2, v2 = profileCoords(pf, b.x, b.y, b.z)
	local h3, s3, a3, u3, v3 = profileCoords(pf, c.x, c.y, c.z)
	return profileHidesCoords(pf, h1, s1, a1, u1, v1, h2, s2, a2, u2, v2, h3, s3, a3, u3, v3)
end

--[[
	CHANGED (See-through fix): `chunk` without its triangles hidden behind the occluder (every vertex occluded) that
	face the camera, and only the vertices the kept triangles use (the mesh's box is the drawn geometry's:
	CreateMeshPartAsync centres on it). A triangle facing away is invisible anyway; it stays, so if the camera moves
	beyond the reach before the band is rebuilt, the ground beyond the old horizon is still there (only the culled
	slopes are missing). Returns the chunk itself when nothing is left out, and the number of triangles left out.
	CHANGED (Far slabs fix): + `pf`: also the triangles the drawn nearer ground hides (profileHides) from every
	camera within the profile's reach (the same camera as the occluder's).
]]
function TerrainMath.cullChunk(chunk: Chunk, o: Occluder, pf: Profile?): (Chunk, number)
	local data = chunk.data
	local ox, oy, oz = chunk.ox, chunk.oy, chunk.oz
	local count = chunk.vertexCount
	local hidden: { boolean } = table.create(count, false)
	local any = false
	-- CHANGED (Far slabs fix): and each vertex's place in the horizon profile (the nearer ground hides it too)
	local profile = if pf and pf.finished then pf else nil
	local pointHidden: { boolean } = table.create(if profile then count else 0, false)
	local ph: { number } = table.create(if profile then count else 0, 0)
	local ps: { number } = table.create(if profile then count else 0, 0)
	local pa: { number } = table.create(if profile then count else 0, 0)
	local pu: { number } = table.create(if profile then count else 0, 0)
	local pv: { number } = table.create(if profile then count else 0, 0)
	for v = 1, count do
		local off = (v - 1) * VERTEX_BYTES
		local x, y, z =
			ox + buffer.readf32(data, off), oy + buffer.readf32(data, off + 4), oz + buffer.readf32(data, off + 8)
		local h = TerrainMath.occluded(o, x, y, z)
		hidden[v] = h
		any = any or h
		if profile then
			local hv, sv, av, uv, vv = profileCoords(profile, x, y, z)
			ph[v], ps[v], pa[v], pu[v], pv[v] = hv, sv, av, uv, vv
			-- the vertex alone (a quick necessary condition for its triangles)
			local d = profileBin(sv)
			pointHidden[v] = d >= 1
				and (hv - profile.reach) / sv
					< buffer.readf32(profile.slope, (profileAzimuth(av) * PROFILE.DISTANCES + d - 1) * 4)
		end
	end
	if not any and profile == nil then
		return chunk, 0
	end
	-- the camera relative to the chunk origin
	local cx, cy, cz = o.x - ox, o.y - oy, o.z - oz
	local tris = chunk.tris
	local kept: { number } = {}
	local remap: { number } = table.create(count, 0)
	local used = 0
	local culled = 0
	for t = 1, #tris, 3 do
		local a, b, c = tris[t], tris[t + 1], tris[t + 2]
		local candidate = hidden[a] and hidden[b] and hidden[c]
		if not candidate and profile and pointHidden[a] and pointHidden[b] and pointHidden[c] then
			candidate = profileHidesCoords(
				profile,
				ph[a],
				ps[a],
				pa[a],
				pu[a],
				pv[a],
				ph[b],
				ps[b],
				pa[b],
				pu[b],
				pv[b],
				ph[c],
				ps[c],
				pa[c],
				pu[c],
				pv[c]
			)
		end
		if candidate then
			local ao, bo, co = (a - 1) * VERTEX_BYTES, (b - 1) * VERTEX_BYTES, (c - 1) * VERTEX_BYTES
			local px, py, pz = buffer.readf32(data, ao), buffer.readf32(data, ao + 4), buffer.readf32(data, ao + 8)
			local ux, uy, uz =
				buffer.readf32(data, bo) - px, buffer.readf32(data, bo + 4) - py, buffer.readf32(data, bo + 8) - pz
			local wx, wy, wz =
				buffer.readf32(data, co) - px, buffer.readf32(data, co + 4) - py, buffer.readf32(data, co + 8) - pz
			local nx, ny, nz = uy * wz - uz * wy, uz * wx - ux * wz, ux * wy - uy * wx
			if nx * (cx - px) + ny * (cy - py) + nz * (cz - pz) > 0 then
				culled += 1
				continue
			end
		end
		for _, v in { a, b, c } do
			if remap[v] == 0 then
				used += 1
				remap[v] = used
			end
			table.insert(kept, remap[v])
		end
	end
	if culled == 0 then
		return chunk, 0
	end
	local out = buffer.create(math.max(used, 1) * VERTEX_BYTES)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for v = 1, count do
		local n = remap[v]
		if n > 0 then
			local from, to = (v - 1) * VERTEX_BYTES, (n - 1) * VERTEX_BYTES
			buffer.copy(out, to, data, from, VERTEX_BYTES)
			local x, y, z = buffer.readf32(data, from), buffer.readf32(data, from + 4), buffer.readf32(data, from + 8)
			minX, maxX = math.min(minX, x), math.max(maxX, x)
			minY, maxY = math.min(minY, y), math.max(maxY, y)
			minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
		end
	end
	if used == 0 then
		minX, minY, minZ, maxX, maxY, maxZ = 0, 0, 0, 0, 0, 0
	end
	return {
		key = chunk.key,
		depth = chunk.depth,
		ox = ox,
		oy = oy,
		oz = oz,
		vertexCount = used,
		triangleCount = #kept // 3,
		data = out,
		tris = kept,
		skirt = chunk.skirt,
		minX = minX,
		minY = minY,
		minZ = minZ,
		maxX = maxX,
		maxY = maxY,
		maxZ = maxZ,
	},
		culled
end

--[[
	CHANGED (See-through fix): the seam code (stitchCode) of leaf `node` in a selection (targetBand: leaf key -> band
	id; underBands: key of a split node -> the bands holding leaves under it). Moved here from TerrainMesh.
	Was: only edges to a leaf in ANOTHER band were stitched and short; every other edge kept buildChunk's skirt, which
	is as deep as the worst LOD crack (tens to hundreds of metres on coarse, hilly leaves) and faces outward, so the
	near-edge skirts of far leaves face the camera. Behind the horizon bulge and behind nearer hills they are hidden
	in truth, but their band is drawn scaled down about the camera, i.e. in front of the nearer bands that hide them:
	the offline view audit found ~85% of the wrongly ordered pixels on skirts ("flat slabs", grey and dark walls along
	the horizon and across far mountains). Now every edge inside a cube face is handled here:
	  * a coarser neighbour (any band): this edge is stitched onto its straight edge (no crack at all)
	  * a finer neighbour: that leaf stitches onto this edge
	  * same level: identical lattice vertices
	so these edges only keep the short SKIRT_INNER skirt (float slack). Edges on a cube edge (the neighbour is on
	another face) keep the plain skirt.
]]
function TerrainMath.seamCode(
	config: Config,
	node: Node,
	targetBand: { [number]: number },
	underBands: { [number]: { [number]: boolean } }
): number
	local count = 2 ^ node.depth
	local logs = { 0, 0, 0, 0 }
	local short = { false, false, false, false }
	for edge = 1, 4 do
		local x, y = node.x, node.y
		if edge == 1 then
			x -= 1
		elseif edge == 2 then
			x += 1
		elseif edge == 3 then
			y -= 1
		else
			y += 1
		end
		if x < 0 or y < 0 or x >= count or y >= count then
			continue -- a cube edge: the plain skirt
		end
		short[edge] = true
		local other = targetBand[TerrainMath.nodeKey(config.bodyId, node.face, node.depth, x, y)]
		if other == nil and underBands[TerrainMath.nodeKey(config.bodyId, node.face, node.depth, x, y)] == nil then
			-- a coarser leaf above that node? (none: beyond the selection, e.g. over the horizon)
			local depth, ax, ay, coarser = node.depth, x, y, 0
			while depth > 0 and other == nil do
				depth -= 1
				ax //= 2
				ay //= 2
				coarser += 1
				other = targetBand[TerrainMath.nodeKey(config.bodyId, node.face, depth, ax, ay)]
			end
			if other ~= nil then
				logs[edge] = coarser
			end
		end
	end
	return TerrainMath.stitchCode(logs, short)
end

--[[
	A chunk with its seams handled by `code` (stitchCode): a new Chunk (same triangles, new vertex buffer and box);
	the chunk itself when code is 0. Stitched edge vertices lie on the straight line between the coarser
	neighbour's lattice vertices (its edge, RENDER_DROP below the ground like every drawn vertex); every skirt is
	rebuilt below its (moved) edge, short on edges marked inner.
]]
function TerrainMath.stitchChunk(config: Config, node: Node, chunk: Chunk, code: number): Chunk
	if code == 0 then
		return chunk
	end
	local bodyId, radius = config.bodyId, config.radius
	local face, i0, j0, s = node.face, node.i0, node.j0, node.stride
	local data = buffer.create(buffer.len(chunk.data))
	buffer.copy(data, 0, chunk.data)
	local ox, oy, oz = chunk.ox, chunk.oy, chunk.oz
	local surfaceCount = (CHUNK + 1) * (CHUNK + 1)
	-- a vertex of the coarser neighbour (spacing `cells`), drawn as buildChunk draws it
	local function drawnPoint(i: number, j: number, cells: number): (number, number, number)
		local x, y, z = SurfaceHeight.nodeDirection(bodyId, face, i, j)
		local r = radius + SurfaceHeight.nodeHeight(bodyId, face, i, j) - RENDER_DROP - siteSink(config, x, y, z, cells)
		return x * r, y * r, z * r
	end
	for edge = 1, 4 do
		local e = math.floor(code / 16 ^ (edge - 1)) % 16
		local stitch = e % 8
		local inner = e >= 8
		if stitch == 0 and not inner then
			continue
		end
		local span = s * 2 ^ stitch -- the coarser neighbour's vertex spacing along this edge (lattice cells)
		local skirt = if inner then SKIRT_INNER else chunk.skirt
		local first = surfaceCount + (edge - 1) * (CHUNK + 1)
		for k = 0, CHUNK do
			local a, b = edgeVertex(edge, k)
			local v = a * (CHUNK + 1) + b + 1
			local o = (v - 1) * VERTEX_BYTES
			local i, j = i0 + a * s, j0 + b * s
			local x, y, z = SurfaceHeight.nodeDirection(bodyId, face, i, j)
			local px, py, pz = buffer.readf32(data, o), buffer.readf32(data, o + 4), buffer.readf32(data, o + 8)
			if stitch > 0 then
				-- along the edge: j on edges 1 / 2, i on edges 3 / 4
				local along = if edge <= 2 then j else i
				local rest = along % span
				if rest ~= 0 then
					local t0 = along - rest
					local ax, ay, az, bx, by, bz
					if edge <= 2 then
						ax, ay, az = drawnPoint(i, t0, span)
						bx, by, bz = drawnPoint(i, t0 + span, span)
					else
						ax, ay, az = drawnPoint(t0, j, span)
						bx, by, bz = drawnPoint(t0 + span, j, span)
					end
					local t = rest / span
					px = ax + (bx - ax) * t - ox
					py = ay + (by - ay) * t - oy
					pz = az + (bz - az) * t - oz
					buffer.writef32(data, o, px)
					buffer.writef32(data, o + 4, py)
					buffer.writef32(data, o + 8, pz)
				end
			end
			local so = (first + k) * VERTEX_BYTES
			buffer.writef32(data, so, px - x * skirt)
			buffer.writef32(data, so + 4, py - y * skirt)
			buffer.writef32(data, so + 8, pz - z * skirt)
		end
	end
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for v = 1, chunk.vertexCount do
		local o = (v - 1) * VERTEX_BYTES
		local x, y, z = buffer.readf32(data, o), buffer.readf32(data, o + 4), buffer.readf32(data, o + 8)
		minX, maxX = math.min(minX, x), math.max(maxX, x)
		minY, maxY = math.min(minY, y), math.max(maxY, y)
		minZ, maxZ = math.min(minZ, z), math.max(maxZ, z)
	end
	return {
		key = chunk.key,
		depth = chunk.depth,
		ox = ox,
		oy = oy,
		oz = oz,
		vertexCount = chunk.vertexCount,
		triangleCount = chunk.triangleCount,
		data = data,
		tris = chunk.tris,
		skirt = chunk.skirt,
		minX = minX,
		minY = minY,
		minZ = minZ,
		maxX = maxX,
		maxY = maxY,
		maxZ = maxZ,
	}
end

--[[
	Bounding box of a set of chunks (body-relative): its centre (the band mesh's origin) and size, and the radius of
	its bounding sphere around that centre.
]]
function TerrainMath.bandBounds(chunks: { Chunk }): (Vec3d, Vector3, number)
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for _, c in chunks do
		minX = math.min(minX, c.ox + c.minX)
		minY = math.min(minY, c.oy + c.minY)
		minZ = math.min(minZ, c.oz + c.minZ)
		maxX = math.max(maxX, c.ox + c.maxX)
		maxY = math.max(maxY, c.oy + c.maxY)
		maxZ = math.max(maxZ, c.oz + c.maxZ)
	end
	if minX > maxX then
		return Vec3d.zero(), Vector3.zero, 0
	end
	local centre = Vec3d.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	local size = Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
	local radius = math.sqrt((maxX - minX) ^ 2 + (maxY - minY) ^ 2 + (maxZ - minZ) ^ 2) / 2
	return centre, size, radius
end

--[[
	CHANGED (Night review): the frame (of FRAME_CANDIDATES rotations of `base` about its up axis, and the universe
	axes) in which the chunks' ground corners span the smallest box (largest side): near cube-face corners the
	lattice is skewed, so no single orientation is always the tightest.
]]
function TerrainMath.bestAxes(chunks: { Chunk }, base: Axes): Axes
	local candidates: { Axes } = {}
	for index = 0, FRAME_CANDIDATES - 1 do
		local angle = index * (math.pi / 2) / FRAME_CANDIDATES
		local c, s = math.cos(angle), math.sin(angle)
		local x = Vec3d.add(Vec3d.scale(base.x, c), Vec3d.scale(base.z, s))
		table.insert(candidates, { x = x, y = base.y, z = Vec3d.cross(x, base.y) })
	end
	table.insert(candidates, { x = Vec3d.new(1, 0, 0), y = Vec3d.new(0, 1, 0), z = Vec3d.new(0, 0, 1) })
	local best, bestSize = candidates[1], math.huge
	for _, axes in candidates do
		local ax, ay, az = axes.x, axes.y, axes.z
		local minX, minY, minZ = math.huge, math.huge, math.huge
		local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
		for _, c in chunks do
			for _, v in CORNER_VERTICES do
				local o = (v - 1) * VERTEX_BYTES
				local data = c.data
				local px = c.ox + buffer.readf32(data, o)
				local py = c.oy + buffer.readf32(data, o + 4)
				local pz = c.oz + buffer.readf32(data, o + 8)
				local fx = px * ax.x + py * ax.y + pz * ax.z
				local fy = px * ay.x + py * ay.y + pz * ay.z
				local fz = px * az.x + py * az.y + pz * az.z
				minX, maxX = math.min(minX, fx), math.max(maxX, fx)
				minY, maxY = math.min(minY, fy), math.max(maxY, fy)
				minZ, maxZ = math.min(minZ, fz), math.max(maxZ, fz)
			end
		end
		local size = math.max(maxX - minX, maxY - minY, maxZ - minZ)
		if size < bestSize then
			best, bestSize = axes, size
		end
	end
	return best
end

--[[
	CHANGED (Night review): the exact box of a band's vertices in the frame `axes`: chunk i's vertices lowered by
	drops[i] m along its node's direction (union meshes sink their outgoing leaves; nil / 0: not sunk). Returns
	the box centre in frame coordinates (fx, fy, fz) and its size. `pause` is called after every chunk (a caller
	in a thread may yield there).
]]
function TerrainMath.frameBounds(
	chunks: { Chunk },
	nodes: { Node },
	drops: { number }?,
	axes: Axes,
	pause: (() -> ())?
): (number, number, number, Vector3)
	local ax, ay, az = axes.x, axes.y, axes.z
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	for index, c in chunks do
		local node = nodes[index]
		local drop = if drops then drops[index] or 0 else 0
		local ox, oy, oz = c.ox - node.dx * drop, c.oy - node.dy * drop, c.oz - node.dz * drop
		-- the chunk origin in frame coordinates (doubles), then the small per-vertex offsets
		local bx = ox * ax.x + oy * ax.y + oz * ax.z
		local by = ox * ay.x + oy * ay.y + oz * ay.z
		local bz = ox * az.x + oy * az.y + oz * az.z
		local data = c.data
		for v = 1, c.vertexCount do
			local o = (v - 1) * VERTEX_BYTES
			local px, py, pz = buffer.readf32(data, o), buffer.readf32(data, o + 4), buffer.readf32(data, o + 8)
			local fx = bx + px * ax.x + py * ax.y + pz * ax.z
			local fy = by + px * ay.x + py * ay.y + pz * ay.z
			local fz = bz + px * az.x + py * az.y + pz * az.z
			if fx < minX then
				minX = fx
			end
			if fx > maxX then
				maxX = fx
			end
			if fy < minY then
				minY = fy
			end
			if fy > maxY then
				maxY = fy
			end
			if fz < minZ then
				minZ = fz
			end
			if fz > maxZ then
				maxZ = fz
			end
		end
		if pause then
			pause()
		end
	end
	if minX > maxX then
		return 0, 0, 0, Vector3.zero
	end
	return (minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2, Vector3.new(maxX - minX, maxY - minY, maxZ - minZ)
end

--============================================================================
-- Collision
--============================================================================

--[[
	The lattice triangles (the physics ground) of the cells within `radius` m of body-relative `pos`, on the face
	under it. Appends to `out` (cleared first) and returns it.
]]
function TerrainMath.collisionTriangles(config: Config, pos: Vec3d, radius: number, out: { Triangle }): { Triangle }
	table.clear(out)
	-- CHANGED (Night review): built from collisionCells / cellTriangles (TerrainCollision uses them cell by cell)
	for _, key in TerrainMath.collisionCells(config, pos, radius, {}) do
		local face, i, j = TerrainMath.cellOf(key)
		local first, second = TerrainMath.cellTriangles(config, face, i, j)
		table.insert(out, first)
		table.insert(out, second)
	end
	return out
end

-- CHANGED (Night review): a stable number for lattice cell (face, i, j) of one body (i, j < 2^24).
function TerrainMath.cellKey(face: number, i: number, j: number): number
	return (face * 16777216 + i) * 16777216 + j
end

-- CHANGED (Night review): the cell (face, i, j) of a cellKey.
function TerrainMath.cellOf(key: number): (number, number, number)
	local j = key % 16777216
	local rest = (key - j) / 16777216
	local i = rest % 16777216
	return (rest - i) / 16777216, i, j
end

--[[
	CHANGED (Night review): keys (cellKey) of the lattice cells within `radius` m of body-relative `pos`, on the
	face under it (the cells collisionTriangles fills). Appends to `out` (cleared first) and returns it.
]]
function TerrainMath.collisionCells(config: Config, pos: Vec3d, radius: number, out: { number }): { number }
	table.clear(out)
	local face, fi, fj = SurfaceHeight.latticeCoords(config.bodyId, pos)
	local n = config.n
	local reach = math.ceil(radius / config.cellArc)
	local ci, cj = math.floor(fi), math.floor(fj)
	for i = math.max(ci - reach, 0), math.min(ci + reach, n - 1) do
		for j = math.max(cj - reach, 0), math.min(cj + reach, n - 1) do
			local di, dj = (i + 0.5 - fi) * config.cellArc, (j + 0.5 - fj) * config.cellArc
			if di * di + dj * dj > (radius + config.cellArc) ^ 2 then
				continue
			end
			table.insert(out, TerrainMath.cellKey(face, i, j))
		end
	end
	return out
end

-- CHANGED (Night review): the two lattice triangles of cell (face, i, j) (the physics ground's split).
function TerrainMath.cellTriangles(config: Config, face: number, i: number, j: number): (Triangle, Triangle)
	local bodyId, r = config.bodyId, config.radius
	local ax, ay, az = groundPoint(bodyId, r, face, i, j)
	local bx, by, bz = groundPoint(bodyId, r, face, i + 1, j)
	local cx, cy, cz = groundPoint(bodyId, r, face, i + 1, j + 1)
	local dx, dy, dz = groundPoint(bodyId, r, face, i, j + 1)
	return { ax, ay, az, bx, by, bz, cx, cy, cz }, { ax, ay, az, cx, cy, cz, dx, dy, dz }
end

--[[
	Two WedgeParts (CFrame, Size each) that together fill triangle (a, b, c), `thickness` studs thick, with the
	triangle as their top face and their bulk below it (on the side opposite `up`). Returns nil for degenerate
	triangles.
]]
function TerrainMath.wedgePair(
	a: Vector3,
	b: Vector3,
	c: Vector3,
	up: Vector3,
	thickness: number
): (CFrame?, Vector3?, CFrame?, Vector3?)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	-- make bc the longest edge (a is then opposite it and its foot on bc splits the triangle in two right triangles)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local normal = ac:Cross(ab)
	if normal.Magnitude < 1e-6 or bc.Magnitude < 1e-6 then
		return nil, nil, nil, nil
	end
	local right = normal.Unit
	local upAxis = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(upAxis))
	if height < 1e-4 then
		return nil, nil, nil, nil
	end
	-- the wedges straddle the triangle's plane; move them below it
	local shift = (if right:Dot(up) >= 0 then -right else right) * (thickness / 2)
	local size0 = Vector3.new(thickness, height, math.abs(ab:Dot(back)))
	local cf0 = CFrame.fromMatrix((a + b) / 2 + shift, right, upAxis, back)
	local size1 = Vector3.new(thickness, height, math.abs(ac:Dot(back)))
	local cf1 = CFrame.fromMatrix((a + c) / 2 + shift, -right, upAxis, -back)
	return cf0, size0, cf1, size1
end

--============================================================================
-- CHANGED (Depth order fix): radial depth map of the scaled bands
--============================================================================
--[[
	Why: every scaled band used to be drawn uniformly scaled about the camera by its own factor k, and the part size
	limit makes k fall outward (Studio's 3000-stud draw distance: ~1 / 0.40 / 0.12 / 0.034), so a farther band's hills
	were drawn NEARER than nearer ground and showed through it wherever that ground hides them in truth. No set of
	uniform factors can keep both the order and the part limit, and culling what nearer ground hides (D49, D50) only
	holds for a camera "reach", which is huge for a zoomed-out camera on foot.
	Now every scaled band stores each vertex at u * f(d) about its build camera C0 (u, d: the direction and distance
	from C0), with ONE continuous, strictly increasing f shared by all scaled bands. Points on one ray from C0 keep
	their order and their screen position, so from C0 the picture is the true one, depth order included: a nearer
	ridge always hides the mountains behind it, inside a band and across bands. Bounded: f(d) <= the last anchor's
	depth while d <= its distance (the ring around the camera fits the part limit). Normals stay the true ones.
	depthPose gives the factor a band is posed with while the camera moves away from C0, and its error bound.
]]

-- A depth map through the anchors (dist[i] m -> depth[i] studs; both strictly increasing, depth[1] <= dist[1]).
function TerrainMath.depthMap(dist: { number }, depth: { number }): DepthMap
	assert(#dist >= 2 and #dist == #depth, "depthMap: two anchors or more")
	local power: { number } = table.create(#dist, 1)
	for i = 1, #dist - 1 do
		assert(dist[i + 1] > dist[i] and depth[i + 1] > depth[i] and depth[i] > 0, "depthMap: increasing anchors")
		power[i] = math.log(depth[i + 1] / depth[i]) / math.log(dist[i + 1] / dist[i])
	end
	power[#dist] = power[#dist - 1]
	return table.freeze({ dist = table.clone(dist), depth = table.clone(depth), power = power })
end

-- The drawn depth (studs) of a point `d` m from the build camera.
function TerrainMath.mapDepth(m: DepthMap, d: number): number
	local dist, depth = m.dist, m.depth
	if d <= dist[1] then
		return depth[1] * math.max(d, 0) / dist[1]
	end
	local n = #dist
	local i = 1
	while i < n and d > dist[i + 1] do
		i += 1
	end
	return depth[i] * (d / dist[i]) ^ m.power[i]
end

-- f(d) / d: the factor a point `d` m away is drawn at (seen from the build camera).
function TerrainMath.depthFactor(m: DepthMap, d: number): number
	if d <= m.dist[1] then
		return m.depth[1] / m.dist[1]
	end
	return TerrainMath.mapDepth(m, d) / d
end

--[[
	The factor k to pose a band holding ground `near`..`far` m from its build camera C0 with, and the error bound.
	The band is drawn at C + k (C0 - C) (C: the camera now): a point at d then lies off its true ray from C by at most
	|C - C0| x |k / f(d) - 1 / d| radians (to first order; the error of a band rebuilt for C is 0). Returns the k that
	minimises the largest of those over [near, far] (sampled) and that largest value (radians per metre moved).
]]
function TerrainMath.depthPose(m: DepthMap, near: number, far: number): (number, number)
	near = math.max(near, 1)
	far = math.max(far, near)
	local SAMPLES = 24
	local ds: { number } = table.create(SAMPLES + 1, 0)
	local fs: { number } = table.create(SAMPLES + 1, 0)
	local lo, hi = math.huge, 0
	for i = 0, SAMPLES do
		local d = near * (far / near) ^ (i / SAMPLES)
		local f = TerrainMath.mapDepth(m, d)
		ds[i + 1], fs[i + 1] = d, f
		lo = math.min(lo, f / d)
		hi = math.max(hi, f / d)
	end
	local function worst(k: number): number
		local e = 0
		for i = 1, SAMPLES + 1 do
			e = math.max(e, math.abs(k / fs[i] - 1 / ds[i]))
		end
		return e
	end
	-- convex in k (a max of |linear| terms): ternary search
	for _ = 1, 40 do
		local a = lo + (hi - lo) / 3
		local b = hi - (hi - lo) / 3
		if worst(a) <= worst(b) then
			hi = b
		else
			lo = a
		end
	end
	local k = (lo + hi) / 2
	return k, worst(k)
end

--[[
	`chunk` with every vertex moved along its ray from `cam` (body-relative) to depth mapDepth(m, d) (a new Chunk with
	the same triangles, origin, normals; the box recomputed). `shade(x, y, z, r, g, b)`, if given, recolours each vertex
	from its TRUE body-relative position (the haze). Also returns the nearest and farthest true distance (m).
]]
function TerrainMath.depthChunk(
	chunk: Chunk,
	cam: Vec3d,
	m: DepthMap,
	shade: ((number, number, number, number, number, number) -> (number, number, number))?
): (Chunk, number, number)
	local src = chunk.data
	local data = buffer.create(buffer.len(src))
	buffer.copy(data, 0, src)
	local ox, oy, oz = chunk.ox, chunk.oy, chunk.oz
	local cx, cy, cz = cam.x, cam.y, cam.z
	local minX, minY, minZ = math.huge, math.huge, math.huge
	local maxX, maxY, maxZ = -math.huge, -math.huge, -math.huge
	local near, far = math.huge, 0
	for v = 1, chunk.vertexCount do
		local o = (v - 1) * VERTEX_BYTES
		local px, py, pz = buffer.readf32(src, o), buffer.readf32(src, o + 4), buffer.readf32(src, o + 8)
		local wx, wy, wz = ox + px, oy + py, oz + pz
		local vx, vy, vz = wx - cx, wy - cy, wz - cz
		local d = math.sqrt(vx * vx + vy * vy + vz * vz)
		local q = if d > 0 then TerrainMath.mapDepth(m, d) / d else 1
		near = math.min(near, d)
		far = math.max(far, d)
		local nx, ny, nz = cx + vx * q - ox, cy + vy * q - oy, cz + vz * q - oz
		buffer.writef32(data, o, nx)
		buffer.writef32(data, o + 4, ny)
		buffer.writef32(data, o + 8, nz)
		minX, maxX = math.min(minX, nx), math.max(maxX, nx)
		minY, maxY = math.min(minY, ny), math.max(maxY, ny)
		minZ, maxZ = math.min(minZ, nz), math.max(maxZ, nz)
		if shade then
			local r, g, b =
				shade(wx, wy, wz, buffer.readf32(src, o + 24), buffer.readf32(src, o + 28), buffer.readf32(src, o + 32))
			buffer.writef32(data, o + 24, r)
			buffer.writef32(data, o + 28, g)
			buffer.writef32(data, o + 32, b)
		end
	end
	local out = table.clone(chunk)
	out.data = data
	out.minX, out.minY, out.minZ = minX, minY, minZ
	out.maxX, out.maxY, out.maxZ = maxX, maxY, maxZ
	return out, near, far
end

return table.freeze(TerrainMath)
