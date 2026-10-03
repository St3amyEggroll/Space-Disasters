--!strict
--[[
	TerrainMesh (CHANGED (Phase 8): surface terrain)
	Draws the dominant body's heightmap ground (SurfaceHeight) around the camera while the Surface layer draws.

	Mesh mode (EditableMesh): the cube-sphere quadtree leaves chosen by TerrainMath.select are drawn in bands, one per
	level of detail (TerrainMath.bandOf: the finest bandCount - 1 levels get their own band, coarser levels share the
	last one), each band ONE EditableMesh + MeshPart (spike S12: an experience only gets ~8 EditableMeshes, so one
	mesh per chunk is impossible; one mesh also holds at most 20,000 triangles). Every frame a band whose box exceeds
	the 2048-stud part limit, whose centre lies beyond the draw budget (engine culling, S11) or whose far edge lies
	beyond FAR_LIMIT is drawn uniformly scaled down about the camera (factor k, TerrainMath.bandScale): its image on
	screen is exact (same directions, so band edges stay glued on screen), only its depth shrinks. The finest band
	(the ground under a landing craft, its props and the launch site) is small enough to stay at true scale. Known
	limit: a near hill can be drawn behind the next, scaled band where that band's ground lies a little beyond it.
	Chunk geometry is cached; a band is rebuilt only when its leaf set changes.

	Rebuilds never leave holes and need only ONE spare mesh: when the quadtree changes, a plan swaps the changed
	bands one at a time, each built in a background thread with a per-frame time budget (Quality tier). A band only
	drops leaves once the leaves replacing them are on screen (its dependencies); when two bands wait on each other
	(splits ahead of a moving camera, merges behind it) one is first rebuilt as a "union" that also keeps its
	outgoing leaves, sunk UNION_DROP below the ground. Bands still showing outgoing leaves are drawn PUSH_BACK
	farther (again an exact uniform scale about the camera), so the new geometry wins wherever both overlap.

	Plates: when meshes are unavailable (unpublished place, "Allow Mesh / Image APIs" off, refused by the budget:
	one warning, then plates for the session) or not ready yet (first build, a teleport), the same quadtree (leaves of
	at most PLATE_MAX_SIZE, out to PLATE_MAX_DISTANCE) is drawn as one tilted, biome-coloured Part per leaf, fitted to
	the leaf's corners.

	Positions are kept in doubles relative to the body and converted only after subtracting the camera (I1).

	CHANGED (Night review): terrain review fixes.
	  * True-scale objects (other crafts, dropped stages, puppets, explosions, the smoke trail) are hidden by ground
	    drawn scaled down about the camera (nearer than it is) behind them. The finest-level band was a
	    quadtree-aligned patch with the camera often near its edge (true-scale ground only ~0.3-0.6 km away on some
	    side), and at altitude no band was at true scale at all. Now band 0 is the near band: every leaf whose centre
	    lies in a +-NEAR_HALF square around the ground under the camera (TerrainMath.assignBands), split down to
	    NEAR_MAX_LEAF by select() (so it also exists below a climbing camera: a smoke trail or a falling stage seen
	    from above), one part of at most ~2 km at true scale while its centre is within the draw budget; the other
	    leaves keep one band per level. The square follows the camera with NEAR_RECENTRE of slack, and keeps the
	    launch site inside while the camera is near it (keepNear). Offline ray audit (objects the engine draws at
	    the tier, 3 places x 5 heights): objects wrongly covered at 150 / 300 / 500 / 800 m: 72 / 91 / 167 / 392
	    before, 0 / 2 / 17 / 260 now. Beyond ~1 km (High only: the engine culls small parts within ~300-650 m on
	    Low / Medium) objects over scaled ground can still be covered. Why not 4 true-scale 2 km quadrant pieces
	    (with far levels merged): with 6 meshes the far ground would be 2 bands, the far one drawn ~50 m from the
	    camera (scale ~0.02-0.03), covering anything farther seen against it. The remaining fix is object-side:
	    drawing such objects scaled like the ground under them (scaleAt), as Surface does for the launch-site copy.
	  * Every band is stored in a tangent frame at the camera's nadir (TerrainMath.bestAxes: the lattice-aligned
	    one, rotated in steps, or the universe axes, whichever gives the smallest box), so its box is close to the
	    ground's real extent (in universe axes a tangent square is up to 1.41x wider: bands were scaled down more
	    than needed). The mesh origin is the exact vertex box (TerrainMath.frameBounds, sunk union leaves
	    included), so CreateMeshPartAsync has nothing to recentre.
	  * Mesh budget: a plan never builds while more than bandCount bands are alive (TerrainMath.planStep retires a
	    band that goes away first, plates fill in), so it needs at most bandCount + 1 meshes; a camera jump (End
	    Flight from altitude: two new band ids before any old one could go) no longer hits the budget and loses a
	    band for the session. A plan that starts while
	    the meshes do not cover the camera at all (a jump) skips the hole-free ordering ("fresh": plates show
	    anyway). After a real refusal (another script holds meshes) bandCount drops as before, but it comes back:
	    every RECOVER_INTERVAL the spare capacity is probed and one band is added back when it is there.
	    (CHANGED (Memory budget): the probing is gone; each plan uses the bands EditableBudget has room for.)
	  * While a plan catches up with a fast, low camera, the displayed meshes stay on screen up to
	    STALE_PLAN_FACTOR x the usual distance (was: plates as soon as the camera left it, swapping back and forth).
	  * scaleAt(): the scale factor the ground under a point is drawn at (Surface draws the launch-site copy with it);
	    version(): bumped whenever the displayed bands change (SurfaceProps re-checks which props stand on
	    true-scale ground).

	CHANGED (Terrain polish): see Render/TerrainMath's header for why bands covered the base and showed far ground
	through nearer hills. Here:
	  * the bands are rings around the near square (TerrainMath.planRings; the last plan's bounds are kept while
	    still good, so a moving camera does not reshuffle every band) and are drawn with TerrainMath.bandScales:
	    one shared factor for the scaled bands (they keep their true order), except near ground, which gets the
	    factor that draws it at the protected depth (PROTECT_*: 520 studs near the ground - the launch site from the
	    pads - down to 160 studs from 500 m up, where only the craft is near the camera)
	  * band seams (TerrainMath.stitchCode, worked out per plan in seamCode; a band is rebuilt when its seams change)
	  * distance haze baked into the vertex colours by each vertex's true distance from the plan's camera (bodies
	    with an atmosphere; Roblox fog would use the drawn distance); a band is rebuilt once the camera has moved
	    HAZE_REBUILD_FRACTION of its distance
	  * depthScale(): the factor that keeps an object in front of every scaled band behind it (the launch-site copy)
	  * no plates while meshes are on their way (PLATE_GRACE_S): the meshes on screen stay, or nothing; isReady()
	    tells the main menu when the ground is drawn (it holds the Play fade on it)
	  * CHANGED (Review 3): the haze colour follows the daylight at the camera (TerrainMath.daylight / hazeColour:
	    HAZE_COLOR by day, a dark version of the atmosphere colour at night); a band is rebuilt when the daylight
	    step it was baked for changes (it was a fixed bright day colour: a pale band on the horizon at night)
	  * MESH_MATERIAL stays SmoothPlastic: a material's texture on a MeshPart is mapped by the mesh's UVs, which
	    these meshes do not have (UVs across a 30 km band would also lose precision far from the origin), so
	    Grass / Ground / Rock would only show one texel of their texture; the detail is in the vertex colours

	CHANGED (Memory budget): Studio's first run after the planet detail work hit Roblox's Editable memory budget
	("Failed to create empty EditableMesh ... memory budget limits"): every EditableMesh is charged ~10 MiB whatever
	it holds (S12), so 6 bands + 1 being built + the planet mesh (80 MiB) filled the ~80 MiB desktop budget before a
	single image. Each refusal then dropped a band AND released every band (a rebuild from nothing: "terrain took a
	while to load"), and the recovery probes printed more refusals.
	  * every mesh goes through Render/EditableBudget: the near band (and the mesh built for it) at TERRAIN_NEAR, the
	    other bands at TERRAIN_FAR, everything at HIDDEN_TERRAIN (released on demand) while no ground is drawn or
	    prebuilt
	  * bands per tier (maxBands: High / Medium 4, Low 3; a plan needs bandCount + 1 meshes) and, at each plan,
	    no more than the budget has room for at TERRAIN_FAR (EditableBudget.room: the planet mesh, the stars and
	    the visible planets' base images come first); raised again at most every BAND_RAISE_INTERVAL. The offline
	    view audit with 4 bands: scaled ground drawn at ~260-390 studs (6 bands: ~400-510), base pixels covered
	    0.0-0.3 %; with 3 (Low, phones): ~130-210 studs, ~1 %
	  * a refused build keeps what is on screen and plans again STARVED_RETRY_S later with what fits (no release of
	    every band, no probing: room() says when a band fits again); only "unavailable" switches to plates
	  * room for fewer than MIN_BANDS + 1 meshes (a small device after real refusals): each band is rebuilt in place
	    of its old mesh (meshLimit: a brief hole there instead of the spare mesh); bands that would exceed the
	    EditableMesh limits are never attempted
	  * setLoadBoost(): a larger per-frame build budget while the main menu (LOAD_BOOST_MENU_S) or the black
	    "Preparing launch site..." cover (LOAD_BOOST_COVER_S) is up; isSettled() tells ScaledSpace when the first
	    ground is built (its other textures wait for it at join)

	CHANGED (See-through fix): Steamy, 250 m over the plain: "I can see through the planet on the distant ground", far
	ground "flat / stripy" with grey and blue streaks that change with the camera; on foot at night: flat green slabs
	cutting through a mountain ridge. Nothing was missing (an offline z-buffer audit found no gaps): every scaled band is
	drawn NEARER than it is, so wherever nearer ground hides it in truth, it was drawn in front of that ground. The
	audit (drawn bands vs the same meshes at true scale, 101 views per tier) found 2.0 % (High) / 2.6 % (Medium) /
	2.8 % (Low) of all pixels showing a farther band over a nearer one, up to 8-10 % in views of a mountain range:
	  * ~85 % of them were skirts: an edge's skirt hung as deep as the worst LOD crack (tens to hundreds of metres on
	    coarse, hilly leaves) and faced outward, so the near-edge skirts of far leaves faced the camera (grey / dark
	    walls and slabs). Every LOD seam inside a cube face is now stitched (TerrainMath.seamCode): no cracks, short
	    skirts.
	  * most of the rest was ground behind the horizon bulge: hill sides facing the camera, drawn as hazy grey-blue
	    slabs along the horizon. A scaled band now leaves out the triangles that face the camera but lie behind a
	    sphere under the lowest ground (TerrainMath.cullChunk; exact and conservative, whatever the bands' detail),
	    for every camera within the plan's reach (CULL: by height, the camera's speed and its distance from its
	    focus, so a zoom or an orbit stays inside it); a band is rebuilt once the camera moved most of that reach, or
	    slowed down (a tighter reach culls more). What is left: thin slivers where a nearer hill hides farther ground
	    (a horizon profile of the drawn ground could cull those too, but a band's culling would then depend on the
	    detail of the bands in front of it, which changes without the culled band being rebuilt).
	  * swapIn poses a new band at once: the builder thread resumes after the frame's update, so a swapped band was
	    missing for a frame (a quarter of the ground, or the near band under the camera, flashing away). A union too
	    big for one mesh keeps the old band on screen until its new mesh replaces it (it was dropped first).
	After: 0.31 % (High) / 0.31 % (Medium) / 0.34 % (Low), at most 0.9-1.6 % (thin slivers along hill and ridge
	lines), still no gaps; the view from 250 m over the site 2.7-3.6 % -> 0.2-0.4 %, a mountain range from the ground
	5-6 % -> 0.7-1.1 %. About a quarter more band builds while the camera moves (the culling's refresh), no new
	memory refusals. The band scales (bandScales, the protected depth), ring layout and memory budget are unchanged.

	CHANGED (Far slabs fix): Steamy, climbing at 95 m/s 100-200 m over the pads: grey / blue-grey slabs (far hill and
	mountain faces) over the green plain, "same thing but slightly better". The bands are drawn at different factors
	(Studio's Automatic quality gives a 3000-stud draw distance, so each band sits at its own part / budget limit:
	~1, 0.40, 0.12, 0.034), so wherever the nearer ground hides a farther band in truth, that band is drawn IN FRONT
	of it, and no layout of uniform scales keeps every band's depth in order (a ring's part limit makes k fall
	outward). The bulge sphere only covered what the LOWEST ground hides, and with a 5 s speed reach (475 m at 95 m/s)
	it culled almost nothing in a climb. Now:
	  * every plan that builds a scaled band first makes a horizon profile of the drawn ground (all its leaves and the
	    bands on screen, TerrainMath.newProfile / profileAdd / finishProfile): a lower bound of the ground in polar
	    bins around the camera's nadir that holds for any detail level the other bands are rebuilt with; the scaled
	    bands also leave out the triangles it hides from every camera within the reach (TerrainMath.cullChunk)
	  * CULL.REACH_SPEED_S 5 -> 1 s (the reach a climbing camera culls for)
	Offline audit (drawn vs the unculled leaves at true scale, High at Studio's 3000-stud draw distance, the climb
	at 25 m/s^2 with the chase camera 35 studs behind, 8 yaws x 100-250 m): wrong order 0.231 % (max 0.80 %) ->
	0.153 % (max 0.57 %), the screenshot-like view 0.6-1.0 % -> 0.12-0.26 % (thin slivers at the horizon left), no
	holes, fewer band builds (139 -> 110). The profile costs ~0.05 s of build time per plan (time-sliced).
	/bands (DebugService -> DebugView): setDebugTint shows each band in a flat colour.

	CHANGED (Depth order fix): Steamy, on foot on the pads at night, camera zoomed out over them: dark slabs cut across
	the ridge beyond the pads, and /bands showed band 3 (yellow) drawn over band 1 and over the near band's ridge. Any
	band drawn uniformly scaled about the camera by its own factor puts a farther band's hills in front of nearer
	ground wherever that ground hides them (the part limit makes the factors fall outward), and the culling of D49 /
	D50 only removes what nearer ground hides from EVERY camera within a reach: zoomed out on foot that reach is up to
	2.5 x 400 studs, so it culled almost nothing. Now the order is right by construction:
	  * every scaled band is baked with ONE radial depth map (TerrainMath.depthMap / depthChunk, CULL.DEPTH_MAP): a
	    vertex d m from the plan's camera C0 is stored at f(d) studs along the same ray, f continuous and strictly
	    increasing, shared by all scaled bands; from C0 the picture is the true one (same rays), depth order
	    included, inside a band and across bands. f(0.9 km) = 520 studs (the old protected depth near the ground),
	    ground beyond 3 km is behind 940 studs (behind the near band's ground), 40 km within 1010 studs (a ring
	    around the camera fits the part limit; beyond that the part is shrunk about the camera). Normals stay the
	    true ones; the haze is baked from the true distance before the mapping.
	  * a mapped band is posed at C + k (C0 - C) (C: the camera now), drifting at most |C - C0| x depthError radians
	    off the true picture (TerrainMath.depthPose), and is rebuilt for the new camera once that reaches
	    CULL.DEPTH_ERROR (the haze / culling refresh machinery); once the camera stands still they are re-planned
	    for where it is (DEPTH_SETTLE), so a still view is exact
	  * only while the camera is slow (CULL.MAP_SPEED / UNMAP_SPEED: on foot, hovering, a slow lift-off): a rigid
	    band cannot follow a fast camera (a 95 m/s climb outruns the rebuilds: cracks along the band seams and the
	    horizon), so a fast camera gets the uniformly scaled bands and the culling as before; a band built in the
	    other mode is rebuilt
	  * a scaled near band (at altitude) is kept at most at the map's factor of its farthest ground: in front of the
	    mapped bands
	  * scaleAt / scaleOver / depthScale give a mapped band's own factor f(d) / d where it is asked
	The bulge / profile culling stays (it still drops hidden triangles the GPU would draw for nothing).
	Offline audit (3000-stud draw distance, drawn vs the unculled leaves at true scale), on foot on the pads with the
	camera 30-150 studs up and zoomed out, 8 yaws, settled: far over near 0.233 / 0.243 / 0.088 % (High / Medium /
	Low; at most 0.64 / 0.78 / 0.22 %) -> 0.034 / 0.037 / 0.036 % (at most 0.09 %: specks where the near band's
	true-scale ground beyond ~520 studs hides ring-1 ground), no holes. Fast flight is unchanged (uniform bands);
	the switch at lift-off can show a hole along a seam or the horizon for a moment while the bands are rebuilt.

	API (driven by Surface):
		TerrainMesh.init(parent)
		TerrainMesh.update(ctx, show, prebuild)   show: draw this frame (surface mode); prebuild: build but keep hidden
		TerrainMesh.isTrueScaleAt(pos, margin)     is body-relative `pos` (dominant body) drawn at true scale?
		TerrainMesh.scaleAt(pos, margin): number?  CHANGED (Night review): smallest scale factor of the ground drawn
		                                           there (1: true scale or plates; nil: no band holds it)
		TerrainMesh.version(): number              CHANGED (Night review): changes whenever the displayed bands change
		TerrainMesh.keepNear(bodyId, pos, half, range?)
		                                           CHANGED (Night review): keep that square in the near band when near
		                                           CHANGED (Review 3): + range (default KEEP_RANGE)
		TerrainMesh.depthScale(far): number        CHANGED (Terrain polish): factor in front of every scaled band behind
		TerrainMesh.protectDepth(): number         CHANGED (Review 3): studs scaled ground keeps from the camera
		TerrainMesh.scaleOver(points): number?     CHANGED (Review 3): scaleAt over a list of points (cached)
		TerrainMesh.hideScaledAt(points?)          CHANGED (Review 3): hide the scaled bands holding those points
		TerrainMesh.isReady(): boolean             CHANGED (Terrain polish): the wanted ground is drawn as meshes
		TerrainMesh.isSettled(): boolean           CHANGED (Memory budget): no plan running for built ground
		TerrainMesh.setLoadBoost(mode?)            CHANGED (Memory budget): "Menu" / "Cover" / nil: build time per frame
		TerrainMesh.summary(): string              F3 debug line
		TerrainMesh.setDebugTint(on)               CHANGED (Far slabs fix): the /bands view (a flat colour per band)
		TerrainMesh.debugTint(): boolean           CHANGED (Far slabs fix)
		TerrainMesh.tintBand(part, id)             CHANGED (Far slabs fix): (internal) one band's /bands tint
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Biome = require(ReplicatedStorage.Shared.Sim.Biome)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies) -- CHANGED (Terrain polish)
local EditableBudget = require(script.Parent.EditableBudget) -- CHANGED (Memory budget)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Quality = require(script.Parent.Quality)
local RenderContext = require(script.Parent.RenderContext)
local SurfaceHeight = require(ReplicatedStorage.Shared.Sim.SurfaceHeight)
local TerrainMath = require(script.Parent.TerrainMath)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d
type Node = TerrainMath.Node
type Chunk = TerrainMath.Chunk
type Config = TerrainMath.Config
type Selection = TerrainMath.Selection
type Axes = TerrainMath.Axes -- CHANGED (Night review)
type Near = TerrainMath.Near -- CHANGED (Night review)

--============================================================================
-- Tunables
--============================================================================
-- CHANGED (Memory budget): the bands per tier are TierParams.maxBands (High / Medium 4, Low 3), fewer when the
-- Editable memory budget has no room (EditableBudget.room); one more mesh is built at a time
local MIN_BANDS = 2 -- the fewest bands a starved budget plans with (the near band and one more)
local MAX_MESH_TRIANGLES = 20000 -- EditableMesh limits: a band beyond them is never attempted ...
local MAX_MESH_VERTICES = 60000
local MAX_MESH_LEAVES = 100 -- leaves per mesh (192 triangles each: under EditableMesh's 20,000 triangles)
local PART_LIMIT = 2040 -- studs per MeshPart axis (engine limit 2048)
local MESH_STORE_EXTENT = 512 -- mesh units across a band's box (vertices are stored normalised; Size scales them)
local BUDGET_FRACTION = 0.85 -- band centres stay within this fraction of the draw distance (culling, S11)
local FAR_LIMIT = 17000 -- studs: no band reaches farther (0.85 x the 20,000 studs drawn at quality 10)
local DRAW_DISTANCE_CAP = 20000 -- studs
local PUSH_BACK = 0.004 -- bands still showing outgoing leaves are drawn this much farther (exact, about the camera)
local UNION_DROP = 2.5 -- m: outgoing leaves kept in a union mesh sit this far below the ground ...
local UNION_DROP_PER_SPACING = 0.15 -- ... plus this x their vertex spacing
local RESELECT_INTERVAL = 0.2 -- s between quadtree selections
local RESELECT_MIN_MOVE = 3 -- m the camera must move before a new selection ...
local RESELECT_MOVE_FRACTION = 0.01 -- ... or this fraction of its height above the ground
local HORIZON_LEAD_MIN = 30 -- m: meshes reach the horizon seen from this much higher than the camera ...
local HORIZON_LEAD_FRACTION = 0.15 -- ... or this fraction of its height (it may climb while they build)
local STALE_MIN = 1500 -- m: the displayed meshes cover the view while the camera stays this close to where ...
local STALE_HEIGHT_FRACTION = 0.6 -- ... they were chosen, or this fraction of its height (else plates show)
local CHUNK_CACHE_MAX = 600 -- cached chunk geometries (~4 KB each)
local MAX_MESH_FAILURES = 3 -- failed builds in a row (at the same band count) before plates for the session
local RETRY_DELAY = 4 -- s after a failed build
local HIDDEN_RELEASE_S = 15 -- s neither shown nor prebuilt before the meshes are released
local SIZE_REWRITE_FRACTION = 0.0005 -- relative change before a band's Size is rewritten
local TRUE_SCALE = 0.9999 -- a band with k at or above this counts as true scale
local MESH_MATERIAL = Enum.Material.SmoothPlastic
local MERGE_FACTOR = 1.15 -- hysteresis: split nodes merge back only this much farther out
local MIN_BAND_RADIUS = 1 -- m
-- CHANGED (Night review): the near band (TerrainMath.assignBands), mesh budget recovery, stale meshes
local NEAR_HALF = 760 -- m: half-size of the near square (its box, ~2 x (NEAR_HALF + NEAR_MAX_LEAF / 2) plus the
-- lattice's skew near cube-face corners, must stay under PART_LIMIT: ~1960 at most over 960 sampled views)
local NEAR_MAX_LEAF = 400 -- m: largest leaf inside the near square (level 1 on Earth and the Mun)
local NEAR_RECENTRE = 100 -- m (tangent x / z) the camera's nadir may move from the square's origin before it moves
local KEEP_RANGE = 400 -- m (tangent): a keepNear square stays in the near band while the camera's nadir is at most
-- this far outside the square's room (the nadir then stays >= NEAR_HALF - KEEP_RANGE inside the near band)
-- CHANGED (Memory budget): RECOVER_INTERVAL (probing for mesh room) is gone: EditableBudget.room() says what fits
local STARVED_RETRY_S = 1 -- s after a build the memory budget refused before planning again (with what fits) ...
local STARVED_RETRY_MAX_S = 8 -- ... doubling while it keeps being refused, up to this
local BAND_RAISE_INTERVAL = 5 -- s at least between band-count raises (each re-lays out every band)
local LOAD_BOOST_MENU_S = 0.008 -- s of building per frame while the main menu is up (setLoadBoost)
local LOAD_BOOST_COVER_S = 0.03 -- ... while the black "Preparing launch site..." cover is up
local BUDGET_OWNER = "TerrainMesh"
local BAND_VERTICES = 11500 -- a full band (MAX_MESH_LEAVES x ~115 vertices): the budget's size estimate per mesh
local BAND_TRIANGLES = 19200 -- ... (MAX_MESH_LEAVES x 192 triangles)
local STALE_PLAN_FACTOR = 2 -- x the stale distance the meshes stay on screen while a plan catches up
local PLATE_GRACE_S = 8 -- CHANGED (Terrain polish): s without mesh coverage before plates show (meshes expected)
-- CHANGED (Terrain polish): distance haze baked into the vertex colours (bodies with an atmosphere). Roblox's fog
-- works on drawn distance, and scaled bands are drawn much nearer than they are, so each vertex is hazed by its
-- true distance from the plan's camera instead: the far, coarse ground fades toward the sky.
local HAZE_COLOR = { 0.63, 0.73, 0.87 } -- CHANGED (Review 3): by day (TerrainMath.hazeColour: darker toward night)
local HAZE_DISTANCE = 26000 -- m: e-folding distance of the haze through sea-level air
local HAZE_SCALE_HEIGHT = 2500 -- m: the haze thins with height like this
local HAZE_MAX = 0.6 -- at most this share of a vertex colour is haze
local HAZE_REBUILD_FRACTION = 0.3 -- a band is rebuilt (fresh haze) once the camera moved this x its nearest ground
local HAZE_REBUILD_MIN = 400 -- m: ... but never for less than this
-- CHANGED (Terrain polish): bands share one factor except near ground (TerrainMath.bandScales): true-scale things
-- nearer than this many studs are never covered by a scaled band behind them (camera height above the ground ->
-- protected depth, interpolated; the launch site, the near band's hills and trees on the ground, the craft in flight)
local PROTECT_LOW_HEIGHT = 60 -- m
local PROTECT_LOW_DEPTH = 520 -- studs
local PROTECT_HIGH_HEIGHT = 500 -- m
local PROTECT_HIGH_DEPTH = 160 -- studs
-- CHANGED (See-through fix): ground facing the camera but hidden behind the body's bulge is left out of the scaled
-- bands (TerrainMath.bulgeOccluder / cullChunk), valid while the camera stays within the plan's reach of where
-- it was built: reach = max(REACH_MIN, REACH_HEIGHT x height, REACH_SPEED_S x camera speed, ZOOM_COVER x the camera's
-- distance from its focus: a zoom or an orbit moves it that far in a moment). One table (the module is near Roblox's
-- 200-locals limit).
local CULL = table.freeze({
	REACH_MIN = 25, -- m
	REACH_HEIGHT = 0.1, -- x the camera's height above the ground
	-- CHANGED (Far slabs fix): was 5 s: at 95 m/s a 475 m reach (the camera raised that much) culled almost nothing,
	-- so a climbing rocket saw the far bands' hidden faces drawn over the plain; with the profile 1 s audits best
	REACH_SPEED_S = 1, -- s of the camera's current speed
	REFRESH = 0.6, -- a band is rebuilt once the camera moved this x its reach ...
	GAIN = 1.5, -- ... (a band that culled nothing: this x its reach, for what the bulge hides now)
	TIGHTEN = 2.5, -- ... or once its reach is this x the reach a new plan would use (the camera slowed down)
	ZOOM_COVER = 2.5, -- x the camera's distance from Workspace.CurrentCamera.Focus ...
	ZOOM_MAX = 400, -- ... counted up to this many studs
	SPEED_SMOOTH_S = 0.5, -- s: the camera speed estimate rises at once and falls with this time constant
	SPEED_JUMP = 3000, -- m/s: a faster move is a jump (teleport, End Flight), not a speed
	-- CHANGED (Depth order fix): every scaled band is baked with one radial depth map (TerrainMath.depthMap: a point
	-- d m from the band's build camera is stored at depth f(d) on its ray), so from that camera the depth order is the
	-- true one. Anchors (m -> studs) of f: scaled ground from ~0.9 km (just outside the near square) starts at the
	-- old protected depth near the ground (520 studs), everything beyond 3 km lies behind 940 studs (behind the near
	-- band's ground: its square reaches ~960 m), and 40 km (beyond the farthest ring) stays within 1010 studs, so a
	-- ring around the camera fits the 2040-stud part limit
	DEPTH_MAP = TerrainMath.depthMap({ 900, 3000, 40000 }, { 520, 940, 1010 }),
	-- radians a scaled band may drift off the true picture while the camera moves away from its build camera
	-- (TerrainMath.depthPose: moved x the band's error per metre) before it is rebuilt for the new camera
	DEPTH_ERROR = 0.003,
	DEPTH_SETTLE = 0.0005, -- ... this many once the camera is still (slower than STILL_SPEED m/s): re-planned at once
	STILL_SPEED = 2,
	-- m/s: the scaled bands are depth-mapped while the camera is slower than MAP_SPEED (on foot, hovering, a slow
	-- lift-off), and drawn uniformly scaled as before once it is faster than UNMAP_SPEED: a band is posed rigidly,
	-- so a mapped band drifts off the true picture as the camera moves (|C - C0| x depthError) and a fast climb
	-- outruns its rebuilds (offline, 95 m/s: cracks along the band seams and the horizon on 1-3 % of the pixels).
	-- Fast, the depth order errors only last as long as the move, and the culling (REACH_SPEED_S) handles the rest
	MAP_SPEED = 12,
	UNMAP_SPEED = 25,
})
-- CHANGED (Far slabs fix): the /bands debug view (setDebugTint): a flat colour per band (Highlight fill; the near
-- band keeps its colours), plates white. One table with its state (`on`, the module is at Roblox's 200-locals limit).
local DEBUG_TINT = {
	BANDS = { Color3.fromRGB(40, 90, 255), Color3.fromRGB(235, 40, 40), Color3.fromRGB(250, 220, 30) }, -- band 1, 2, 3
	FURTHER = Color3.fromRGB(230, 40, 230), -- band 4 and up
	PLATE = Color3.new(1, 1, 1),
	NAME = "BandTint",
	on = false, -- the view is on
}

-- Detail per Quality tier: splitK (LOD distance in node sizes), leaf cap, build time per frame (s), and whether the
-- finest band casts shadows.
-- CHANGED (Memory budget): + maxBands (meshes: maxBands + 1 while building, ~10 MiB each; phones get 3 from the
-- budget's room); the leaf caps fit them (at most TerrainMath.MAX_BAND_LEAVES = 95 leaves, ~18k triangles, per
-- band: 4 x 95 >= 320, 3 x 95 >= 240)
type TierParams = { splitK: number, maxLeaves: number, budgetS: number, shadows: boolean, maxBands: number }
local TIERS: { [string]: TierParams } = {
	Low = { splitK = 0.8, maxLeaves = 180, budgetS = 0.0015, shadows = false, maxBands = 3 },
	Medium = { splitK = 1.05, maxLeaves = 240, budgetS = 0.002, shadows = false, maxBands = 4 },
	High = { splitK = 1.4, maxLeaves = 320, budgetS = 0.003, shadows = true, maxBands = 4 },
}

-- Plates (fallback and placeholder)
local PLATE_MAX_SIZE = 1500 -- m, plates must stay under the 2048-stud part limit
local PLATE_MAX_DISTANCE = 9000 -- m
local PLATE_SPLIT_K = 0.8
local PLATE_MAX_LEAVES = 200
local PLATE_THICKNESS = 12 -- studs ...
local PLATE_THICKNESS_PER_M = 0.03 -- ... plus this per metre of plate size (hides the steps between plates)
local PLATE_OVERLAP = 1.03 -- plates are this much larger than their leaf
local PLATE_DROP = 0.15 -- m, plate tops below the true ground
local PLATE_MAX_EXTENT = 2048
local PLATES_PER_FRAME = 40 -- new plates created per frame at most (nearest first)
local OCEAN_REFLECTANCE = 0.08
local KIND_MATERIALS: { [string]: Enum.Material } = {
	Ocean = Enum.Material.SmoothPlastic,
	Lake = Enum.Material.SmoothPlastic, -- CHANGED (Planet detail)
	Beach = Enum.Material.Sand,
	Grass = Enum.Material.Grass,
	Forest = Enum.Material.Grass,
	Desert = Enum.Material.Sand,
	Rock = Enum.Material.Rock,
	Snow = Enum.Material.Snow,
	Mare = Enum.Material.Slate,
	Highland = Enum.Material.Slate,
	Crater = Enum.Material.Slate,
	Ray = Enum.Material.Slate,
}
local FALLBACK_MATERIAL = Enum.Material.SmoothPlastic
local BULK_MOVE_MODE = Enum.BulkMoveMode.FireCFrameChanged
--============================================================================

type BandMesh = {
	id: number,
	mesh: EditableMesh,
	handle: EditableBudget.Handle, -- CHANGED (Memory budget): its budget handle (destroying it destroys the mesh)
	part: MeshPart,
	origin: Vec3d, -- body-relative centre of the mesh's box
	rot: CFrame, -- CHANGED (Night review): the band frame's axes (body axes); the box is in this frame
	shadow: boolean, -- CHANGED (Night review): casts shadows when the tier allows (the near band)
	size: Vector3, -- box size (m)
	radius: number, -- bounding-sphere radius (m)
	maxExtent: number,
	leaves: { [number]: Node }, -- by key: every leaf in the mesh (outgoing ones of a union included)
	count: number,
	triangles: number,
	stale: boolean, -- shows outgoing leaves at full height (drawn PUSH_BACK farther)
	scale: number, -- k used this frame
	appliedScale: number, -- k its Size was last written for
	-- CHANGED (Terrain polish): how near its ground comes (depthScale)
	planCam: Vec3d, -- the camera of the plan that built it
	nearest: number, -- m from planCam to its nearest leaf (lower bound)
	nearestNow: number, -- m from this frame's camera (lower bound: nearest minus how far the camera moved)
	stitch: { [number]: number }, -- leaf key -> the seam code it was built with (TerrainMath.stitchCode)
	light: number, -- CHANGED (Review 3): the daylight step its haze was baked for (TerrainMath.daylight)
	-- CHANGED (See-through fix): its bulge culling (TerrainMath.cullChunk)
	cullCam: Vec3d, -- the camera it was culled for
	cullReach: number, -- m: valid while the camera stays this close to cullCam
	culled: number, -- triangles left out
	cullable: boolean, -- culled some, or reaches beyond the horizon (more may be hidden after the camera moves)
	-- CHANGED (Depth order fix): baked with the depth map about planCam (0: true geometry, posed uniformly scaled)
	depthK: number, -- the factor it is posed with (TerrainMath.depthPose)
	depthError: number, -- rad per metre the camera moves from planCam
}

type Plan = {
	bodyId: number,
	config: Config,
	cam: Vec3d,
	selection: Selection?, -- chosen by the plan's own thread (time-sliced)
	target: { [number]: { [number]: Node } }, -- band id -> key -> leaf
	pending: { [number]: boolean }, -- band ids that still need their final swap
	covered: { [number]: boolean }, -- band ids whose new leaves are on screen
	deps: { [number]: { [number]: boolean } }, -- band id -> bands holding the replacements of its outgoing leaves
	finished: boolean,
	failed: boolean,
	aborted: boolean,
	error: string?,
	builds: number, -- meshes built so far
	steps: number, -- meshes this plan needs at least
	current: string, -- what is being built (debug)
	buildingMesh: EditableMesh?, -- the mesh being built (released if the plan stops)
	buildingHandle: EditableBudget.Handle?, -- CHANGED (Memory budget)
	buildingId: number?, -- CHANGED (Memory budget): the band it is for
	buildingPart: MeshPart?,
	refusal: EditableBudget.Refusal?, -- CHANGED (Memory budget): why the mesh could not be created
	-- CHANGED (Night review)
	near: Near?, -- the near square (band 0), or nil (one band per level: bandCount < 2)
	axes: Axes, -- the frame every band of this plan is stored in
	fresh: boolean, -- the meshes did not cover the camera when it started: no hole-free ordering (plates show)
	-- CHANGED (Terrain polish)
	rings: TerrainMath.RingContext?, -- ring bands around the near square (nil: one band per level)
	ringBounds: { number }?, -- the ring bounds this plan's selection uses
	stitch: { [number]: number }, -- leaf key -> seam code (TerrainMath.stitchCode) in this plan's selection
	light: number, -- CHANGED (Review 3): the daylight step its bands' haze is baked for
	occluder: TerrainMath.Occluder?, -- CHANGED (See-through fix): the bulge the scaled bands are culled against
	profile: TerrainMath.Profile?, -- CHANGED (Far slabs fix): the drawn ground's horizon profile (the same reach)
	mapped: boolean, -- CHANGED (Depth order fix): its scaled bands are depth-mapped (a slow camera: CULL.MAP_SPEED)
}

type Plate = {
	part: Part,
	pos: Vec3d, -- centre (body-relative)
	rot: CFrame, -- universe rotation
}

local TerrainMesh = {}

--============================================================================
-- State
--============================================================================
local root: Folder? = nil
local meshFolder: Folder? = nil
local plateFolder: Folder? = nil

local meshEnabled = true -- false after EditableMesh failed for good: plates only
local warned = false
local failures = 0
local retryAt = 0
local bandCount = TIERS.High.maxBands -- CHANGED (Memory budget): set per plan (affordableBands)
local liveMeshes = 0
local raiseAt = 0 -- CHANGED (Memory budget): the band count may rise again from then on
local hiddenMode = false -- CHANGED (Memory budget): no ground drawn or prebuilt: the meshes may be released
local loadBoostS = 0 -- CHANGED (Memory budget): setLoadBoost
local updatedOnce = false -- CHANGED (Memory budget): isSettled
local activeLast = false -- CHANGED (Memory budget): the last update drew or prebuilt ground
local starvedRetry = STARVED_RETRY_S -- CHANGED (Memory budget): the next wait after a refused build
local meshLimit = math.huge -- CHANGED (Memory budget): meshes a plan may hold (< bandCount + 1: no spare)

local bodyId: number? = nil
local bands: { [number]: BandMesh } = {} -- by band id
local split: { [number]: boolean } = {}
local displayedCam: Vec3d? = nil
local coverageBroken = false
local plan: Plan? = nil
local lastSelectTime = -math.huge
local lastSelectCam: Vec3d? = nil
local forceSelect = true
local hiddenSince: number? = nil
-- CHANGED (Night review)
local nearSquare: Near? = nil -- the current near square (band 0)
local nearBodyId: number? = nil
local keepBody: number? = nil -- keepNear: a square kept inside the near band while the camera is near it
local keepPos: Vec3d? = nil
local keepHalf = 0
local keepRange = KEEP_RANGE -- CHANGED (Review 3): per keepNear call (Surface: the base's plate out to its near zone)
local bandsVersion = 0 -- bumped whenever the displayed bands change
-- CHANGED (Terrain polish): ring bands
local ringBounds: { number }? = nil -- the displayed plan's ring bounds (the next plan keeps them while good)
local drawBudget = BUDGET_FRACTION * DRAW_DISTANCE_CAP -- studs, from the latest frame's draw distance
-- CHANGED (Review 3): the protected depth placeBands used (protectDepth) and the scaled bands hidden under the
-- launch site's real plate (hideScaledAt: band id -> the band it hid)
local protectNow = PROTECT_LOW_DEPTH
local lightNow = 1 -- CHANGED (Review 3): the daylight step at the camera (TerrainMath.daylight), from update
local holeHidden: { [number]: BandMesh } = {}
-- CHANGED (See-through fix): the camera's speed (m/s, smoothed) and where it was last frame (cull reach)
-- (and its distance from its focus, studs)
local camSpeed: { value: number, cam: Vec3d?, time: number, zoom: number, mapped: boolean } =
	{ value = 0, cam = nil, time = 0, zoom = 0, mapped = true }

local chunkCache: { [number]: Chunk } = {}
local chunkStamp: { [number]: number } = {}
local chunkCount = 0
local stamp = 0

local plates: { [number]: Plate } = {}
local plateSplit: { [number]: boolean } = {}
local platePool: { Part } = {}
local plateParts: { BasePart } = {}
local plateCFrames: { CFrame } = {}
local plateBodyId: number? = nil
local plateLastCam: Vec3d? = nil
local plateLastTime = -math.huge
local platesDirty = true
local platesShown = false
local plateWanted: { [number]: Node }? = nil -- the latest plate selection, until every plate of it exists
local plateQueue: { Node } = {} -- plates still to create (farthest first: popped from the end)
local lastPlateRef: Vec3d = Vec3d.zero()
local lastPlateRot: CFrame = CFrame.identity
local lastPlateSlot: Vector3 = Vector3.zero

local tier: TierParams = TIERS.High
local tierName = "High"

local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local placeOrder: { BandMesh } = {} -- CHANGED (Terrain polish): placeBands scratch
local placeMax: { number } = {}
local placeNearest: { number } = {}
local scratch: Vec3d = Vec3d.zero()
local meshesShown = false
local uncoveredSince: number? = nil -- CHANGED (Terrain polish): when the meshes stopped covering the view (grace)
local wantsGround = false -- CHANGED (Terrain polish): the last update wanted ground drawn (isReady)

--============================================================================
-- Helpers
--============================================================================
local function params(): TerrainMath.Params
	-- CHANGED (Memory budget): no more leaves than the bands of this plan can hold
	local maxLeaves = math.min(tier.maxLeaves, bandCount * TerrainMath.MAX_BAND_LEAVES)
	return { splitK = tier.splitK, mergeK = tier.splitK * MERGE_FACTOR, maxLeaves = maxLeaves }
end

local function disableMeshes(reason: string)
	meshEnabled = false
	if not warned then
		warned = true
		warn(
			"[TerrainMesh] EditableMesh terrain is unavailable ("
				.. reason
				.. "); the ground is drawn with Part plates instead. Enable Game Settings > Security > 'Allow Mesh /"
				.. " Image APIs' for smooth terrain."
		)
	end
end

-- CHANGED (Memory budget): the mesh goes through its budget handle
local function destroyBand(bm: BandMesh)
	bm.part:Destroy()
	EditableBudget.destroy(bm.handle)
	liveMeshes -= 1
	bandsVersion += 1 -- CHANGED (Night review)
end

-- Drops the mesh a plan's builder was working on.
local function releaseBuilding(p: Plan)
	local part = p.buildingPart
	if part then
		part:Destroy()
		p.buildingPart = nil
	end
	local mesh = p.buildingMesh
	if mesh then
		EditableBudget.destroy(p.buildingHandle) -- CHANGED (Memory budget)
		p.buildingMesh = nil
		p.buildingHandle = nil
		liveMeshes -= 1
	end
end

local function releaseAllBands()
	for id, bm in bands do
		destroyBand(bm)
		bands[id] = nil
	end
	displayedCam = nil
	coverageBroken = false
end

local function abortPlan()
	local p = plan
	if p then
		p.aborted = true
		plan = nil
		-- the builder thread drops its unfinished mesh when it next wakes up
	end
end

--[[
	CHANGED (Memory budget): the budget's release callback while no ground is drawn or prebuilt (HIDDEN_TERRAIN):
	everything goes, as after HIDDEN_RELEASE_S (a higher priority needs the memory sooner).
]]
local function releaseHidden()
	abortPlan()
	releaseAllBands()
	table.clear(split)
	forceSelect = true
end

-- CHANGED (Memory budget): the budget priority of band `id`'s meshes (and its release callback, nil: never evicted)
local function bandPriority(id: number): (number, (() -> ())?)
	if hiddenMode then
		return EditableBudget.PRIORITY.HIDDEN_TERRAIN, releaseHidden
	end
	if id == TerrainMath.NEAR_BAND then
		return EditableBudget.PRIORITY.TERRAIN_NEAR, nil
	end
	return EditableBudget.PRIORITY.TERRAIN_FAR, nil
end

-- CHANGED (Memory budget): enters / leaves the hidden mode (every mesh's budget priority follows it).
local function setHidden(hidden: boolean)
	if hidden == hiddenMode then
		return
	end
	hiddenMode = hidden
	for id, bm in bands do
		local priority, release = bandPriority(id)
		EditableBudget.setPriority(bm.handle, priority, release)
	end
	local p = plan
	if p and p.buildingHandle then
		local priority, release = bandPriority(p.buildingId or TerrainMath.NEAR_BAND + 1)
		EditableBudget.setPriority(p.buildingHandle, priority, release)
	end
end

-- CHANGED (Memory budget): the build time per frame (the tier's, or more while the menu / cover is up)
local function buildBudget(): number
	return math.max(tier.budgetS, loadBoostS)
end

local function trimChunkCache(keep: { [number]: boolean })
	if chunkCount <= CHUNK_CACHE_MAX then
		return
	end
	-- drop the least recently used chunks that are not needed
	local entries: { { key: number, stamp: number } } = {}
	for key, s in chunkStamp do
		if not keep[key] then
			table.insert(entries, { key = key, stamp = s })
		end
	end
	table.sort(entries, function(a, b)
		return a.stamp < b.stamp
	end)
	local excess = chunkCount - CHUNK_CACHE_MAX
	for index = 1, math.min(excess, #entries) do
		local key = entries[index].key
		chunkCache[key] = nil
		chunkStamp[key] = nil
		chunkCount -= 1
	end
end

-- Height (m) of the camera above the body's lowest possible ground (cheap, for thresholds).
local function heightAboveGround(config: Config, cam: Vec3d): number
	return Vec3d.length(cam) - config.radius - math.max(config.minHeight, 0)
end

--============================================================================
-- Mesh building (background thread)
--============================================================================

--[[
	Adds a chunk to an EditableMesh: vertices sunk `drop` m along the node's direction, expressed in the band frame
	`axes` relative to the box centre (fx, fy, fz) (frame coordinates), then divided by `store` (meshes are stored
	about MESH_STORE_EXTENT units across; the part's Size scales them back).
	CHANGED (Night review): in the band's tangent frame (was universe axes), normals rotated along.
]]
-- CHANGED (Terrain polish): the haze of a plan (camera body-relative, its height, the body radius)
type Haze = { x: number, y: number, z: number, height: number, radius: number, r: number, g: number, b: number }

--[[
	CHANGED (Terrain polish): share of haze in a vertex colour `d` m from the camera, the camera `hc` m and the
	vertex `hp` m above the radius: the mean air density on the straight path (exponential atmosphere) x d.
]]
local function hazeAmount(d: number, hc: number, hp: number): number
	local h = HAZE_SCALE_HEIGHT
	local dh = hp - hc
	local density
	if math.abs(dh) < 1 then
		density = math.exp(-math.max(hc, 0) / h)
	else
		density = h * (math.exp(-math.max(hc, 0) / h) - math.exp(-math.max(hp, 0) / h)) / dh
	end
	return HAZE_MAX * (1 - math.exp(-d * density / HAZE_DISTANCE))
end

local function addChunk(
	mesh: EditableMesh,
	c: Chunk,
	node: Node,
	drop: number,
	axes: Axes,
	fx: number,
	fy: number,
	fz: number,
	store: number,
	haze: Haze? -- CHANGED (Terrain polish)
)
	local count = c.vertexCount
	local vids: { number } = table.create(count, 0)
	local nids: { number } = table.create(count, 0)
	local cids: { number } = table.create(count, 0)
	local xx, xy, xz = axes.x.x, axes.x.y, axes.x.z
	local yx, yy, yz = axes.y.x, axes.y.y, axes.y.z
	local zx, zy, zz = axes.z.x, axes.z.y, axes.z.z
	-- the chunk origin relative to the box centre, in frame coordinates (doubles)
	local ox, oy, oz = c.ox - node.dx * drop, c.oy - node.dy * drop, c.oz - node.dz * drop
	local bx = ox * xx + oy * xy + oz * xz - fx
	local by = ox * yx + oy * yy + oz * yz - fy
	local bz = ox * zx + oy * zy + oz * zz - fz
	local inv = 1 / store
	for v = 1, count do
		local px, py, pz, nx, ny, nz, r, g, b = TerrainMath.chunkVertex(c, v)
		if haze then
			-- CHANGED (Terrain polish): distance haze toward HAZE_COLOR
			local wx, wy, wz = c.ox + px, c.oy + py, c.oz + pz
			local ex, ey, ez = wx - haze.x, wy - haze.y, wz - haze.z
			local amount = hazeAmount(
				math.sqrt(ex * ex + ey * ey + ez * ez),
				haze.height,
				math.sqrt(wx * wx + wy * wy + wz * wz) - haze.radius
			)
			-- CHANGED (Review 3): toward the plan's haze colour (daylight)
			r += (haze.r - r) * amount
			g += (haze.g - g) * amount
			b += (haze.b - b) * amount
		end
		vids[v] = mesh:AddVertex(
			Vector3.new(
				(bx + px * xx + py * xy + pz * xz) * inv,
				(by + px * yx + py * yy + pz * yz) * inv,
				(bz + px * zx + py * zy + pz * zz) * inv
			)
		)
		nids[v] = mesh:AddNormal(
			Vector3.new(nx * xx + ny * xy + nz * xz, nx * yx + ny * yy + nz * yz, nx * zx + ny * zy + nz * zz)
		)
		cids[v] = mesh:AddColor(Color3.new(r, g, b), 1)
	end
	local tris = c.tris
	for t = 1, #tris, 3 do
		local a, b, d = tris[t], tris[t + 1], tris[t + 2]
		local face = mesh:AddTriangle(vids[a], vids[b], vids[d])
		mesh:SetFaceNormals(face, { nids[a], nids[b], nids[d] })
		mesh:SetFaceColors(face, { cids[a], cids[b], cids[d] })
	end
end

local function configureBandPart(part: MeshPart, id: number, shadow: boolean)
	part.Name = "TerrainBand" .. id
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.Locked = true
	part.CastShadow = shadow and tier.shadows -- CHANGED (Night review): the near band (was id 0, the finest level)
	part.Material = MESH_MATERIAL
	part.Color = Color3.new(1, 1, 1) -- vertex colours carry the biome
	part.Transparency = 0
end

--[[
	Builds one band mesh from `leaves` (those in `sunk` are lowered: outgoing leaves of a union). Yields whenever the
	frame's time budget is spent. Returns the BandMesh, or nil (with p.failed / p.error set unless aborted).
]]
local function buildBand(p: Plan, id: number, leaves: { [number]: Node }, sunk: { [number]: boolean }?): BandMesh?
	local sliceStart = os.clock()
	local function due(): boolean
		if os.clock() - sliceStart >= buildBudget() then -- CHANGED (Memory budget): load boost
			task.wait()
			sliceStart = os.clock()
		end
		return p.aborted
	end
	-- 1. chunk geometry (cached across plans)
	local chunks: { Chunk } = {}
	local nodes: { Node } = {}
	local stitched: { [number]: number } = {} -- CHANGED (Terrain polish)
	for key, node in leaves do
		local chunk = chunkCache[key]
		if chunk == nil then
			local fresh = TerrainMath.buildChunk(p.config, node)
			chunkCache[key] = fresh
			chunkCount += 1
			chunk = fresh
			if due() then
				return nil
			end
		end
		stamp += 1
		chunkStamp[key] = stamp
		-- CHANGED (Terrain polish): seams to other bands (outgoing leaves of a union keep their plain skirts)
		local code = if sunk and sunk[key] then 0 else p.stitch[key] or 0
		if sunk then
			code = TerrainMath.plainSkirts(code) -- CHANGED (See-through fix): a union keeps deep skirts (passing)
		end
		stitched[key] = code
		table.insert(chunks, TerrainMath.stitchChunk(p.config, node, chunk :: Chunk, code))
		table.insert(nodes, node)
	end
	-- 2. the exact vertex box in the plan's band frame, sunk union leaves included
	-- CHANGED (Night review): was the chunks' universe-axes boxes (sink left out: the engine's box could differ)
	local drops: { number } = table.create(#nodes, 0)
	if sunk then
		for index, node in nodes do
			if sunk[node.key] then
				drops[index] = UNION_DROP + UNION_DROP_PER_SPACING * node.stride * p.config.cellArc
			end
		end
	end
	local axes = TerrainMath.bestAxes(chunks, p.axes)
	-- CHANGED (See-through fix): a scaled band leaves out what the bulge hides (outgoing union leaves are kept whole)
	local culled = 0
	local occluder = if id ~= TerrainMath.NEAR_BAND then p.occluder else nil
	if occluder then
		local kept: { Chunk } = table.create(#chunks)
		local left = 0
		for index, c in chunks do
			local cc, n = c, 0
			if not (sunk and sunk[nodes[index].key]) then
				cc, n = TerrainMath.cullChunk(c, occluder, p.profile) -- CHANGED (Far slabs fix): + the nearer ground
			end
			kept[index] = cc
			culled += n
			left += cc.triangleCount
			if index % 8 == 0 and due() then
				return nil
			end
		end
		if culled > 0 and left > 0 then
			chunks = kept
		else
			culled = 0 -- nothing hidden, or everything (a band is never empty: drawn whole)
		end
	end
	-- CHANGED (Depth order fix): a scaled band is stored radially depth-mapped about the plan's camera (hazed by the
	-- true distance first: the mapped positions are not the true ones)
	local depthK, depthError = 0, 0
	local haze: Haze? = nil
	local body = Bodies.get(p.bodyId)
	local atmosphere = body.AtmosphereColor
	if atmosphere ~= nil then
		local cam = p.cam
		local hr, hg, hb = TerrainMath.hazeColour(HAZE_COLOR, atmosphere, p.light) -- CHANGED (Review 3)
		haze = {
			x = cam.x,
			y = cam.y,
			z = cam.z,
			height = Vec3d.length(cam) - body.Radius,
			radius = body.Radius,
			r = hr,
			g = hg,
			b = hb,
		}
	end
	if id ~= TerrainMath.NEAR_BAND and p.mapped then
		local h = haze
		local shade = if h
			then function(x: number, y: number, z: number, r: number, g: number, b: number): (number, number, number)
				local ex, ey, ez = x - h.x, y - h.y, z - h.z
				local amount = hazeAmount(
					math.sqrt(ex * ex + ey * ey + ez * ez),
					h.height,
					math.sqrt(x * x + y * y + z * z) - h.radius
				)
				return r + (h.r - r) * amount, g + (h.g - g) * amount, b + (h.b - b) * amount
			end
			else nil
		local mapped: { Chunk } = table.create(#chunks)
		local near, far = math.huge, 0
		for index, c in chunks do
			local mc, cn, cf = TerrainMath.depthChunk(c, p.cam, CULL.DEPTH_MAP, shade)
			mapped[index] = mc
			near, far = math.min(near, cn), math.max(far, cf)
			if index % 8 == 0 and due() then
				return nil
			end
		end
		chunks = mapped
		haze = nil -- baked
		depthK, depthError = TerrainMath.depthPose(CULL.DEPTH_MAP, near, far)
	end
	local fx, fy, fz, size = TerrainMath.frameBounds(chunks, nodes, drops, axes, function()
		due()
	end)
	if p.aborted then
		return nil
	end
	local origin = Vec3d.add(Vec3d.add(Vec3d.scale(axes.x, fx), Vec3d.scale(axes.y, fy)), Vec3d.scale(axes.z, fz))
	local rot =
		CFrame.fromMatrix(Vector3.zero, Vec3d.toVector3(axes.x), Vec3d.toVector3(axes.y), Vec3d.toVector3(axes.z))
	local radius = size.Magnitude / 2
	-- 3. the mesh
	local store = math.max(size.X, size.Y, size.Z, 1) / MESH_STORE_EXTENT
	-- CHANGED (Memory budget): through EditableBudget, with this band's priority and its exact size
	local vertices, triangleCount = 0, 0
	for _, c in chunks do
		vertices += c.vertexCount
		triangleCount += c.triangleCount
	end
	if triangleCount > MAX_MESH_TRIANGLES or vertices > MAX_MESH_VERTICES then
		-- ... (a crowded selection with few bands): handled like a budget refusal (keep, plan again later)
		p.failed = true
		p.refusal = "budget"
		p.error = string.format("band %d too large (%d triangles)", id, triangleCount)
		return nil
	end
	local priority, release = bandPriority(id)
	p.buildingId = id
	local created, handle, refusal = EditableBudget.createMesh(BUDGET_OWNER, priority, release, vertices, triangleCount)
	if created == nil or handle == nil then
		p.failed = true
		p.refusal = refusal
		p.error = "CreateEditableMesh refused (" .. tostring(refusal) .. ")"
		return nil
	end
	local mesh = created :: EditableMesh
	liveMeshes += 1
	p.buildingMesh = mesh
	p.buildingHandle = handle
	local triangles = 0
	-- CHANGED (Terrain polish): distance haze from the plan's camera (bodies with an atmosphere)
	-- CHANGED (Depth order fix): worked out above (the near band's; the scaled bands' is baked into their chunks)
	for index, c in chunks do
		local node = nodes[index]
		local drop = drops[index]
		local ok, err = pcall(function()
			addChunk(mesh, c, node, drop, axes, fx, fy, fz, store, haze)
		end)
		if not ok then
			p.failed = true
			p.error = tostring(err)
			releaseBuilding(p)
			return nil
		end
		triangles += c.triangleCount
		if due() then
			releaseBuilding(p)
			return nil
		end
	end
	local made, part = pcall(function(): MeshPart
		return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
			CollisionFidelity = Enum.CollisionFidelity.Box,
			RenderFidelity = Enum.RenderFidelity.Precise,
		})
	end)
	if made then
		p.buildingPart = part
	end
	if p.aborted then
		releaseBuilding(p)
		return nil
	end
	if not made then
		p.failed = true
		p.error = tostring(part)
		releaseBuilding(p)
		return nil
	end
	-- CHANGED (Night review): the near band (or, without one, the finest level's) casts shadows
	local shadow = id == TerrainMath.NEAR_BAND
	configureBandPart(part, id, shadow)
	p.buildingMesh = nil
	p.buildingHandle = nil -- CHANGED (Memory budget): now the band's
	p.buildingPart = nil
	-- the engine's own idea of the mesh's box (the same box: it is centred on the exact vertex box)
	local okSize, meshSize = pcall(function(): Vector3
		return part.MeshSize
	end)
	if okSize and meshSize.X > 0 and meshSize.Y > 0 and meshSize.Z > 0 then
		size = meshSize * store
	end
	local count = 0
	local nearest = math.huge -- CHANGED (Terrain polish)
	local farthest = 0 -- CHANGED (See-through fix)
	local cam = p.cam
	for _, node in leaves do
		count += 1
		local centre = math.sqrt((node.cx - cam.x) ^ 2 + (node.cy - cam.y) ^ 2 + (node.cz - cam.z) ^ 2)
		nearest = math.min(nearest, centre - node.radius)
		farthest = math.max(farthest, centre + node.radius)
	end
	-- CHANGED (See-through fix): ground beyond the horizon can be hidden by the bulge (now or after a move)
	local horizon = TerrainMath.horizonDistance(p.config, cam)
	return {
		id = id,
		mesh = mesh,
		handle = handle, -- CHANGED (Memory budget)
		part = part,
		origin = origin,
		rot = rot,
		shadow = shadow,
		size = size,
		radius = math.max(radius, MIN_BAND_RADIUS),
		maxExtent = math.max(size.X, size.Y, size.Z),
		leaves = leaves,
		count = count,
		triangles = triangles,
		stale = false,
		scale = 1,
		appliedScale = 0,
		planCam = Vec3d.clone(cam), -- CHANGED (Terrain polish)
		stitch = stitched,
		nearest = math.max(nearest, 0),
		nearestNow = math.max(nearest, 0),
		light = p.light, -- CHANGED (Review 3)
		-- CHANGED (See-through fix)
		cullCam = Vec3d.clone(cam),
		cullReach = if occluder then occluder.reach else math.huge,
		culled = culled,
		cullable = occluder ~= nil and (culled > 0 or farthest > horizon),
		depthK = depthK, -- CHANGED (Depth order fix)
		depthError = depthError,
	}
end

-- CHANGED (See-through fix): placeBands, defined below (swapIn poses a new band at once)
local placeBands: (ctx: RenderContext.RenderContext) -> ()
local lastPlaceCtx: RenderContext.RenderContext? = nil -- the context placeBands last ran with

--[[
	Puts a freshly built band on screen in place of the old one with the same id (nil: the band is gone).
	CHANGED (See-through fix): the new band is posed and parented right away (placeBands with the latest frame's
	context). It used to wait for the next placeBands while the old band was already destroyed: the builder thread
	resumes after the frame's update, so for one frame that band was missing (the offline climb trace showed a band
	hidden for a frame at every swap: a ~25% hole in the ground, or the near band under the camera, flashing).
]]
local function swapIn(bm: BandMesh?, id: number)
	local old = bands[id]
	if old then
		destroyBand(old)
		bands[id] = nil
	end
	if bm then
		bands[id] = bm
		if DEBUG_TINT.on then
			TerrainMesh.tintBand(bm.part, id) -- CHANGED (Far slabs fix): the /bands view
		end
		-- a band hidden under the launch site's plate (hideScaledAt) stays hidden until that decides again
		if old and holeHidden[id] == old then
			holeHidden[id] = bm
		end
		local ctx = lastPlaceCtx
		if meshesShown and ctx then
			placeBands(ctx)
		end
	end
	bandsVersion += 1 -- CHANGED (Night review)
end

-- Builds band `id` from `leaves` (sunk: outgoing leaves of a union) and swaps it in. False when the plan stopped.
local function buildAndSwap(p: Plan, id: number, leaves: { [number]: Node }, sunk: { [number]: boolean }?): boolean
	local bm: BandMesh? = nil
	if next(leaves) ~= nil then
		p.current = (if sunk then "union " else "band ") .. id
		bm = buildBand(p, id, leaves, sunk)
		if bm == nil then
			releaseBuilding(p)
			if not p.aborted then
				p.finished = true
			end
			return false
		end
		p.builds += 1
	end
	if p.aborted then
		-- the plan was dropped while this mesh was finishing
		if bm then
			bm.part:Destroy()
			EditableBudget.destroy(bm.handle) -- CHANGED (Memory budget)
			liveMeshes -= 1
		end
		return false
	end
	swapIn(bm, id)
	return true
end

-- Runs a plan: builds and swaps the changed bands one at a time, in an order that never leaves holes.
-- CHANGED (Night review): the order comes from TerrainMath.planStep, which never builds while more than bandCount
-- bands are alive (it retires a band that goes away first: plates fill in until the plan is done).
local function runPlan(p: Plan)
	local alive: { [number]: boolean } = {}
	local empty: { [number]: boolean } = {}
	while next(p.pending) ~= nil do
		if p.aborted then
			releaseBuilding(p)
			return
		end
		table.clear(alive)
		table.clear(empty)
		local live = 0
		for id in bands do
			alive[id] = true
			live += 1
		end
		for id in p.pending do
			empty[id] = next(p.target[id]) == nil
		end
		local kind, chosen = TerrainMath.planStep(p.pending, p.covered, p.deps, alive, empty, live, bandCount)
		if kind == nil or chosen == nil then
			break -- nothing can make progress (should not happen): keep what is on screen
		end
		local id = chosen :: number
		if kind == "retire" then
			local doomed = bands[id]
			if doomed then
				destroyBand(doomed)
				bands[id] = nil
			end
			coverageBroken = true
			p.covered[id] = true
			p.pending[id] = nil
			continue
		elseif kind == "build" or (next(p.target[id]) ~= nil and liveMeshes >= meshLimit) then
			-- CHANGED (Memory budget): no room for the spare mesh (meshLimit): the band's own mesh goes first (a
			-- hole there until its new mesh is up), and a union (which needs the old mesh) becomes the final build
			if next(p.target[id]) ~= nil and liveMeshes >= meshLimit then
				local own = bands[id]
				if own then
					destroyBand(own)
					bands[id] = nil
					coverageBroken = true
				end
			end
			-- a band whose replacements are all on screen gets its final mesh
			if not buildAndSwap(p, id, p.target[id], nil) then
				return
			end
			p.covered[id] = true
			p.pending[id] = nil
			continue
		end
		-- bands waiting on each other: show one band's new leaves first, keeping its outgoing ones (sunk)
		local old = bands[id]
		local leaves: { [number]: Node } = {}
		local sunk: { [number]: boolean } = {}
		local count = 0
		for key, node in p.target[id] do
			leaves[key] = node
			count += 1
		end
		if old then
			for key, node in old.leaves do
				if leaves[key] == nil then
					leaves[key] = node
					sunk[key] = true
					count += 1
				end
			end
		end
		if next(sunk) == nil then
			-- nothing outgoing to keep: this is already the band's final mesh
			if not buildAndSwap(p, id, p.target[id], nil) then
				return
			end
			p.pending[id] = nil
		elseif count > MAX_MESH_LEAVES then
			-- too big for one mesh: its final mesh now (plates cover the gap until the plan is done)
			-- CHANGED (See-through fix): the old band stays on screen until that mesh replaces it (swapIn), so only
			-- its outgoing leaves leave a gap (was: the old band was dropped first, a hole over the whole band while
			-- the new mesh was built); without room for the spare mesh it still goes first
			if old and liveMeshes >= meshLimit then
				destroyBand(old)
				bands[id] = nil
			end
			coverageBroken = true
			if not buildAndSwap(p, id, p.target[id], nil) then
				return
			end
			p.pending[id] = nil
		elseif not buildAndSwap(p, id, leaves, sunk) then
			return
		end
		p.covered[id] = true
	end
	p.finished = true
end

-- Bands (ids) that hold, in the target selection, the replacements of a leaf that leaves the screen.
local function replacementBands(
	config: Config,
	node: Node,
	targetBand: { [number]: number },
	underBands: { [number]: { [number]: boolean } },
	out: { [number]: boolean }
)
	-- the same leaf, in another band
	local same = targetBand[node.key]
	if same then
		out[same] = true
		return
	end
	-- split: its descendants
	local below = underBands[node.key]
	if below then
		for id in below do
			out[id] = true
		end
		return
	end
	-- merged: its nearest ancestor that is a leaf now
	local face, depth, x, y = node.face, node.depth, node.x, node.y
	while depth > 0 do
		depth -= 1
		x //= 2
		y //= 2
		local id = targetBand[TerrainMath.nodeKey(config.bodyId, face, depth, x, y)]
		if id then
			out[id] = true
			return
		end
	end
end

-- CHANGED (See-through fix): the seam code of a leaf is TerrainMath.seamCode (every LOD seam is stitched, skirts
-- are short; was: only seams between bands)

-- Works out which bands change for `selection` and what each one waits for (fills the plan).
local function preparePlan(p: Plan, selection: Selection)
	local config = p.config
	-- CHANGED (Night review): the near band + one band per level (TerrainMath.assignBands)
	-- CHANGED (Terrain polish): + ring bands around it (p.rings)
	local assigned, bounds = TerrainMath.assignBands(config, selection.leaves, bandCount, p.near, p.rings)
	p.ringBounds = bounds
	local target: { [number]: { [number]: Node } } = {}
	local targetBand: { [number]: number } = {}
	local underBands: { [number]: { [number]: boolean } } = {}
	for _, node in selection.leaves do
		local id = assigned[node.key]
		local set = target[id]
		if set == nil then
			local fresh: { [number]: Node } = {}
			target[id] = fresh
			set = fresh
		end
		(set :: { [number]: Node })[node.key] = node
		targetBand[node.key] = id
		-- every ancestor knows which bands hold leaves under it (for splits)
		local face, depth, x, y = node.face, node.depth, node.x, node.y
		while depth > 0 do
			depth -= 1
			x //= 2
			y //= 2
			local key = TerrainMath.nodeKey(config.bodyId, face, depth, x, y)
			local under = underBands[key]
			if under == nil then
				local fresh: { [number]: boolean } = {}
				underBands[key] = fresh
				under = fresh
			end
			(under :: { [number]: boolean })[id] = true
		end
	end
	-- CHANGED (Terrain polish): seams between bands
	for _, node in selection.leaves do
		p.stitch[node.key] = TerrainMath.seamCode(config, node, targetBand, underBands) -- CHANGED (See-through fix)
	end
	local pending = p.pending
	local covered = p.covered
	local deps = p.deps
	local ids: { [number]: boolean } = {}
	for id in bands do
		ids[id] = true
	end
	for id in target do
		ids[id] = true
	end
	local steps = 0
	for id in ids do
		local old = bands[id]
		local new: { [number]: Node } = target[id] or {}
		target[id] = new
		local added, removed = false, false
		for key in new do
			if old == nil or old.leaves[key] == nil then
				added = true
				break
			end
		end
		local dep: { [number]: boolean } = {}
		if old then
			for key, node in old.leaves do
				if new[key] == nil then
					removed = true
					if not p.fresh then
						replacementBands(config, node, targetBand, underBands, dep)
					end
				end
			end
		end
		dep[id] = nil -- CHANGED (Night review): a fresh plan (plates on screen) waits for nothing
		-- CHANGED (Terrain polish): a band whose haze was baked for a camera that has moved far, or whose seams to
		-- the other bands changed (a neighbour band's leaf split or merged), is rebuilt too
		local rebuild = false
		if old and not added and not removed then
			-- CHANGED (Review 3): or for another daylight step
			rebuild = Bodies.get(p.bodyId).AtmosphereColor ~= nil
				and (
					old.light ~= p.light
					or Vec3d.distance(p.cam, old.planCam)
						> HAZE_REBUILD_FRACTION * math.max(old.nearest, HAZE_REBUILD_MIN)
				)
			-- CHANGED (Depth order fix): or its depth-mapped picture drifted CULL.DEPTH_ERROR off the true one, or the
			-- plan maps the scaled bands and it is not mapped (or the other way round)
			if not rebuild and old.depthK > 0 then
				local tolerance = if camSpeed.value < CULL.STILL_SPEED then CULL.DEPTH_SETTLE else CULL.DEPTH_ERROR
				rebuild = Vec3d.distance(p.cam, old.planCam) * old.depthError > tolerance
			end
			if not rebuild and id ~= TerrainMath.NEAR_BAND then
				rebuild = (old.depthK > 0) ~= p.mapped
			end
			-- CHANGED (See-through fix): or its bulge culling is no longer sure for this camera (or misses ground the
			-- bulge hides now)
			if not rebuild and old.cullable then
				-- (one that culled nothing only for the gain: after a longer move, or a slower camera)
				local moved = Vec3d.distance(p.cam, old.cullCam)
				local occluder = p.occluder
				rebuild = moved > (if old.culled > 0 then CULL.REFRESH else CULL.GAIN) * old.cullReach
					or (occluder ~= nil and old.cullReach > CULL.TIGHTEN * occluder.reach)
			end
			if not rebuild then
				for key in new do
					if (old.stitch[key] or 0) ~= (p.stitch[key] or 0) then
						rebuild = true
						break
					end
				end
			end
		end
		if rebuild then
			pending[id] = true
			covered[id] = true
			deps[id] = dep
			steps += 1
		end
		if added or removed then
			pending[id] = true
			covered[id] = not added
			deps[id] = dep
			steps += 1
			if old and removed then
				old.stale = true -- drawn a little farther until it is rebuilt
			end
		end
	end
	p.selection = selection
	p.target = target
	p.steps = steps
end

-- The plan's thread: chooses the leaves (time-sliced), then builds and swaps the changed bands.
local function selectAndRun(p: Plan)
	local sliceStart = os.clock()
	local selectParams = params()
	selectParams.bandCount = bandCount
	selectParams.near = p.near -- CHANGED (Night review)
	selectParams.rings = p.rings -- CHANGED (Terrain polish)
	selectParams.horizonLead = math.max(HORIZON_LEAD_MIN, HORIZON_LEAD_FRACTION * heightAboveGround(p.config, p.cam))
	local function pause()
		if os.clock() - sliceStart >= buildBudget() then -- CHANGED (Memory budget): load boost
			task.wait()
			sliceStart = os.clock()
		end
	end
	selectParams.pause = pause
	local selection = TerrainMath.select(p.config, p.cam, selectParams, split)
	if p.aborted then
		return
	end
	preparePlan(p, selection)
	if p.aborted then
		return
	end
	-- CHANGED (Far slabs fix): before a scaled band is built, the profile of every leaf of the plan and of the bands
	-- on screen (it holds for any detail they are drawn at: TerrainMath.profileAdd), for that band's culling
	local occluder = p.occluder
	local scaledPending = false
	for id in p.pending do
		scaledPending = scaledPending or (id ~= TerrainMath.NEAR_BAND and next(p.target[id]) ~= nil)
	end
	if occluder and scaledPending then
		local pf = TerrainMath.newProfile(p.cam, occluder.reach)
		local function add(key: number, node: Node)
			local chunk = chunkCache[key]
			if chunk == nil then
				local fresh = TerrainMath.buildChunk(p.config, node)
				chunkCache[key] = fresh
				chunkCount += 1
				stamp += 1
				chunkStamp[key] = stamp
				chunk = fresh
			end
			TerrainMath.profileAdd(pf, chunk :: Chunk, node, p.config.cellArc)
			pause()
		end
		for _, node in selection.leaves do
			add(node.key, node)
		end
		local planned = (p.selection :: Selection).leaves
		local inPlan: { [number]: boolean } = {}
		for _, node in planned do
			inPlan[node.key] = true
		end
		for _, bm in bands do
			for key, node in bm.leaves do
				if not inPlan[key] then
					add(key, node)
				end
			end
		end
		TerrainMath.finishProfile(pf, pause)
		if p.aborted then
			return
		end
		p.profile = pf
	end
	runPlan(p)
end

-- Wraps up a finished plan (or handles its failure).
local function finishPlan()
	local p = plan
	if p == nil or not p.finished then
		return
	end
	plan = nil
	-- after real work the camera has moved on: look again right away
	forceSelect = p.steps > 0
	if p.failed then
		-- CHANGED (Memory budget): a refusal by the memory budget keeps what is on screen (bands a plan already
		-- swapped stay; stale ones stay pushed back) and plans again soon with the bands that fit (affordableBands);
		-- it used to drop a band AND release every band (the ground rebuilt from nothing)
		if p.refusal == "budget" then
			retryAt = os.clock() + starvedRetry
			starvedRetry = math.min(starvedRetry * 2, STARVED_RETRY_MAX_S)
			forceSelect = true
			EditableBudget.warnOnce(
				"TerrainMesh.budget",
				"[TerrainMesh] terrain waits for Editable memory (budget): fewer, coarser bands until there is room."
			)
			return
		end
		if p.refusal == "unavailable" then
			releaseAllBands()
			disableMeshes(p.error or "EditableMesh unavailable")
			return
		end
		failures += 1
		retryAt = os.clock() + RETRY_DELAY
		if liveMeshes == 0 or failures >= MAX_MESH_FAILURES then
			-- no mesh at all, or still failing: plates for the session
			releaseAllBands()
			disableMeshes(p.error or "unknown error")
		end
		return
	end
	failures = 0
	starvedRetry = STARVED_RETRY_S -- CHANGED (Memory budget)
	local selection = p.selection
	if selection then
		split = selection.split
	end
	ringBounds = p.ringBounds -- CHANGED (Terrain polish)
	displayedCam = p.cam
	coverageBroken = false
	for _, bm in bands do
		bm.stale = false
	end
	local keep: { [number]: boolean } = {}
	for _, bm in bands do
		for key in bm.leaves do
			keep[key] = true
		end
	end
	trimChunkCache(keep)
end

--[[
	How far (m) the camera may be from where the displayed meshes were chosen while they still stand for the view.
	CHANGED (Night review): `catchingUp` (a plan is rebuilding them) allows STALE_PLAN_FACTOR x more: a fast, low
	camera kept swapping the ground between meshes and plates while the plans ran behind.
]]
local function staleDistance(config: Config, cam: Vec3d, catchingUp: boolean): number
	local allowed = math.max(STALE_MIN, STALE_HEIGHT_FRACTION * heightAboveGround(config, cam))
	return if catchingUp then allowed * STALE_PLAN_FACTOR else allowed
end

local function meshCoverage(config: Config, cam: Vec3d): boolean
	local at = displayedCam
	if at == nil or coverageBroken or next(bands) == nil then
		return false
	end
	local p = plan
	return Vec3d.distance(cam, at) <= staleDistance(config, cam, p ~= nil and not p.fresh)
end

-- CHANGED (Night review): the near square for a plan, kept until its wanted centre moves by NEAR_RECENTRE.
local function nearFor(config: Config, cam: Vec3d): Near?
	if bandCount < 2 then
		nearSquare = nil
		return nil
	end
	local keep = if keepBody == config.bodyId then keepPos else nil
	-- CHANGED (Review 3): the keepNear call's range (was always KEEP_RANGE)
	local target, keeping = TerrainMath.nearTarget(config, cam, keep, keepHalf, NEAR_HALF, keepRange)
	local current = nearSquare
	if current and nearBodyId == config.bodyId then
		local u, v = TerrainMath.nearOffset(current, target)
		local holds = true
		if keeping and keep then
			-- CHANGED (Review 3): while the keep square places the target, the square on screen must hold it
			-- (its NEAR_RECENTRE slack left up to 100 m of the launch site's plate in a scaled ring band)
			local ku, kv = TerrainMath.nearOffset(current, keep)
			holds = math.max(math.abs(ku), math.abs(kv)) + keepHalf <= NEAR_HALF
		end
		if holds and math.max(math.abs(u), math.abs(v)) <= NEAR_RECENTRE then
			return current
		end
	end
	local fresh = TerrainMath.newNear(config, target, NEAR_HALF, NEAR_MAX_LEAF)
	nearSquare = fresh
	nearBodyId = config.bodyId
	return fresh
end

--[[
	CHANGED (Memory budget): the bands the next plan may use: what EditableBudget has room for at TERRAIN_FAR (the
	planet mesh, the stars and the visible planets' base images come first; this module's own meshes count as
	available), minus the one being built, within MIN_BANDS..tier.maxBands. Lowered at once, raised at most every
	BAND_RAISE_INTERVAL (a new count re-lays out every band). Replaces the night review's probing (tryRecover), whose
	test creations printed "memory budget" refusals.
]]
-- CHANGED (Memory budget): the bands that fit now and the meshes behind them (pure: no state changes)
local function bandsThatFit(): (number, number)
	local room = EditableBudget.room(EditableBudget.PRIORITY.TERRAIN_FAR, BUDGET_OWNER)
	local meshes = math.floor(room / EditableBudget.meshBytes(BAND_VERTICES, BAND_TRIANGLES))
	return math.clamp(meshes - 1, MIN_BANDS, tier.maxBands), meshes
end

local function affordableBands(): number
	local wanted, meshes = bandsThatFit()
	-- too tight even for MIN_BANDS and a spare: rebuild each band in place of its old mesh (no spare)
	meshLimit = if meshes < wanted + 1 then math.max(meshes, MIN_BANDS) else math.huge
	local now = os.clock()
	if wanted > bandCount and now < raiseAt then
		return bandCount
	end
	if wanted ~= bandCount then
		raiseAt = now + BAND_RAISE_INTERVAL
	end
	return wanted
end

--[[
	CHANGED (Memory budget): a camera that stands still never re-plans, so every BAND_RAISE_INTERVAL an idle terrain
	checks whether a different band count fits now (e.g. after the surface view hid the planet's base images).
]]
local bandCheckAt = 0
local function checkBandCount()
	local now = os.clock()
	if plan ~= nil or forceSelect or now < bandCheckAt then
		return
	end
	bandCheckAt = now + BAND_RAISE_INTERVAL
	if bandsThatFit() ~= bandCount then
		forceSelect = true
	end
end

-- Re-selects the quadtree when the camera moved enough; starts a plan when the leaves changed.
local function maybeSelect(config: Config, cam: Vec3d)
	if plan ~= nil or os.clock() < retryAt then
		return
	end
	local now = os.clock()
	local lastCam = lastSelectCam
	if not forceSelect then
		if now - lastSelectTime < RESELECT_INTERVAL then
			return
		end
		-- CHANGED (Depth order fix): a camera that slowed down (or sped up) re-plans where it is (mapped bands)
		-- (or stopped: the mapped bands are made exact for where it stands)
		local switch = camSpeed.mapped ~= (camSpeed.value < CULL.MAP_SPEED)
			and camSpeed.mapped ~= (camSpeed.value <= CULL.UNMAP_SPEED)
		if not switch and camSpeed.value < CULL.STILL_SPEED then
			for _, bm in bands do
				switch = switch
					or (bm.depthK > 0 and Vec3d.distance(cam, bm.planCam) * bm.depthError > CULL.DEPTH_SETTLE)
			end
		end
		if lastCam and not switch then
			local threshold = math.max(RESELECT_MIN_MOVE, RESELECT_MOVE_FRACTION * heightAboveGround(config, cam))
			if Vec3d.distance(cam, lastCam) < threshold then
				return
			end
		end
	end
	forceSelect = false
	lastSelectTime = now
	lastSelectCam = Vec3d.clone(cam)
	bandCount = affordableBands() -- CHANGED (Memory budget)
	-- CHANGED (Night review): layout, band frame, and whether the meshes on screen still stand for the view at all
	local near = nearFor(config, cam)
	local at = displayedCam
	local fresh = at == nil
		or coverageBroken
		or next(bands) == nil
		or Vec3d.distance(cam, at) > staleDistance(config, cam, true)
	local p: Plan = {
		bodyId = config.bodyId,
		config = config,
		cam = Vec3d.clone(cam),
		selection = nil,
		target = {},
		pending = {},
		covered = {},
		deps = {},
		finished = false,
		failed = false,
		aborted = false,
		error = nil,
		builds = 0,
		steps = 0,
		current = "selecting",
		buildingMesh = nil,
		buildingHandle = nil, -- CHANGED (Memory budget)
		buildingId = nil,
		buildingPart = nil,
		refusal = nil,
		near = near,
		axes = if near then near.axes else TerrainMath.tangentAxes(config, cam),
		fresh = fresh,
		-- CHANGED (Terrain polish): ring bands around the near square
		rings = if near
			then {
				cam = Vec3d.clone(cam),
				budget = drawBudget,
				farLimit = FAR_LIMIT,
				partLimit = PART_LIMIT,
				previous = ringBounds,
			}
			else nil,
		ringBounds = nil,
		stitch = {},
		light = lightNow, -- CHANGED (Review 3)
		-- CHANGED (Depth order fix): depth-mapped scaled bands while the camera is slow (hysteresis)
		mapped = if camSpeed.mapped then camSpeed.value <= CULL.UNMAP_SPEED else camSpeed.value < CULL.MAP_SPEED,
		-- CHANGED (See-through fix): what the bulge hides from every camera within the reach (speed and height)
		occluder = TerrainMath.bulgeOccluder(
			config,
			cam,
			math.max(
				CULL.REACH_MIN,
				CULL.REACH_HEIGHT * heightAboveGround(config, cam),
				CULL.REACH_SPEED_S * camSpeed.value,
				CULL.ZOOM_COVER * math.min(camSpeed.zoom, CULL.ZOOM_MAX)
			)
		),
	}
	camSpeed.mapped = p.mapped -- CHANGED (Depth order fix)
	plan = p
	task.spawn(selectAndRun, p)
end

local function setMeshesShown(shown: boolean)
	if meshesShown == shown then
		return
	end
	meshesShown = shown
	bandsVersion += 1 -- CHANGED (Night review): what is drawn at true scale changed (version)
	if not shown then
		for _, bm in bands do
			bm.part.Parent = nil
		end
	end
	-- shown: placeBands parents each band after posing it
end

-- Places every band: true scale, or uniformly scaled about the camera to fit the draw budget / part limit.
-- CHANGED (See-through fix): assigned to the forward-declared local (swapIn calls it); remembers its context
placeBands = function(ctx: RenderContext.RenderContext)
	lastPlaceCtx = ctx
	local frame = ctx.frame
	local cam = ctx.cameraDominant
	local camWs = ctx.camera.Position
	local budget = drawBudget -- CHANGED (Terrain polish): set in update
	local rotWs = Frames.rotationToWorkspace(frame, CFrame.identity)
	table.clear(moveParts)
	table.clear(moveCFrames)
	-- CHANGED (Terrain polish): each band's largest factor, then the factors they are drawn at (bandScales)
	table.clear(placeOrder)
	table.clear(placeMax)
	table.clear(placeNearest)
	-- CHANGED (Depth order fix): depth-mapped bands are posed apart (below); a scaled true-geometry band (the near
	-- band at altitude) is kept in front of them: at most the depth map's factor at its farthest ground
	local mappedCap = 1
	for _, bm in bands do
		bm.nearestNow = math.max(bm.nearest - Vec3d.distance(cam, bm.planCam), MIN_BAND_RADIUS)
		if bm.depthK > 0 then
			continue
		end
		Vec3d.subInto(scratch, bm.origin, cam)
		local dist = Vec3d.length(scratch)
		table.insert(placeOrder, bm)
		table.insert(
			placeMax,
			TerrainMath.bandScale(dist, dist + bm.radius, bm.maxExtent, budget, FAR_LIMIT, PART_LIMIT)
		)
		table.insert(placeNearest, bm.nearestNow)
		mappedCap = math.min(mappedCap, TerrainMath.depthFactor(CULL.DEPTH_MAP, dist + bm.radius))
	end
	local height = SurfaceHeight.height(ctx.dominantBodyId, cam) -- above the ground under the camera
	local t = math.clamp((height - PROTECT_LOW_HEIGHT) / (PROTECT_HIGH_HEIGHT - PROTECT_LOW_HEIGHT), 0, 1)
	protectNow = PROTECT_LOW_DEPTH + (PROTECT_HIGH_DEPTH - PROTECT_LOW_DEPTH) * t -- CHANGED (Review 3): protectDepth
	local scales = TerrainMath.bandScales(placeMax, placeNearest, protectNow)
	local anyMapped = false
	for _, bm in bands do
		anyMapped = anyMapped or bm.depthK > 0
	end
	for index, bm in placeOrder do
		Vec3d.subInto(scratch, bm.origin, cam)
		local k = scales[index]
		if anyMapped and k < TRUE_SCALE then
			k = math.min(k, mappedCap) -- CHANGED (Depth order fix)
		end
		bm.scale = k
		if bm.stale then
			-- outgoing leaves lose every overlap with the incoming ones (exact: same image, a little deeper)
			local pushed = k * (1 + PUSH_BACK)
			if bm.maxExtent * pushed <= PART_LIMIT then
				k = pushed
			end
		end
		local applied = bm.appliedScale
		if applied <= 0 or math.abs(k - applied) > SIZE_REWRITE_FRACTION * applied then
			bm.part.Size = bm.size * k
			bm.appliedScale = k
		end
		local v = Frames.vectorToWorkspace(frame, scratch)
		table.insert(moveParts, bm.part)
		-- CHANGED (Night review): * the band frame (bands are stored in a tangent frame, not universe axes)
		table.insert(moveCFrames, CFrame.new(camWs + v * bm.appliedScale) * rotWs * bm.rot)
	end
	-- CHANGED (Depth order fix): a depth-mapped band is drawn at C + k (C0 - C) + its mapped geometry (C: the camera,
	-- C0: its build camera, k: depthPose), shrunk about the camera only if its box exceeds the part limit (beyond
	-- the depth map's last anchor) and pushed back while stale
	for _, bm in bands do
		local k = bm.depthK
		if k <= 0 then
			continue
		end
		local shrink = math.min(1, PART_LIMIT / math.max(bm.maxExtent, 1))
		if bm.stale and bm.maxExtent * shrink * (1 + PUSH_BACK) <= PART_LIMIT then
			shrink *= 1 + PUSH_BACK
		end
		bm.scale = k * shrink
		local applied = bm.appliedScale
		if applied <= 0 or math.abs(shrink - applied) > SIZE_REWRITE_FRACTION * applied then
			bm.part.Size = bm.size * shrink
			bm.appliedScale = shrink
		end
		local c0, origin = bm.planCam, bm.origin
		local vx = ((c0.x - cam.x) * k + origin.x - c0.x) * bm.appliedScale
		local vy = ((c0.y - cam.y) * k + origin.y - c0.y) * bm.appliedScale
		local vz = ((c0.z - cam.z) * k + origin.z - c0.z) * bm.appliedScale
		local v = Frames.vectorToWorkspace(frame, Vec3d.new(vx, vy, vz))
		table.insert(moveParts, bm.part)
		table.insert(moveCFrames, CFrame.new(camWs + v) * rotWs * bm.rot)
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, BULK_MOVE_MODE)
	end
	local folder = meshFolder
	for id, bm in bands do
		-- CHANGED (Review 3): a band hidden under the launch site's plate stays hidden (hideScaledAt decides again
		-- this frame, right after)
		if bm.part.Parent ~= folder and holeHidden[id] ~= bm then
			bm.part.Parent = folder
		end
	end
end

--============================================================================
-- Plates
--============================================================================
local function acquirePlate(): Part
	local p = table.remove(platePool)
	if p then
		return p
	end
	local part = Instance.new("Part")
	part.Name = "TerrainPlate"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Locked = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	return part
end

local function releasePlate(plate: Plate)
	plate.part.Parent = nil
	table.insert(platePool, plate.part)
end

local function releaseAllPlates()
	for key, plate in plates do
		releasePlate(plate)
		plates[key] = nil
	end
	table.clear(plateParts)
	table.clear(plateCFrames)
	plateBodyId = nil
	plateLastCam = nil
	table.clear(plateSplit)
	table.clear(plateQueue)
	plateWanted = nil
	platesDirty = true
end

local function groundAt(config: Config, face: number, i: number, j: number): Vec3d
	local x, y, z = SurfaceHeight.nodeDirection(config.bodyId, face, i, j)
	local r = config.radius + SurfaceHeight.nodeHeight(config.bodyId, face, i, j)
	return Vec3d.new(x * r, y * r, z * r)
end

-- A plate for a leaf: a box whose top is the plane fitted to the leaf's corners and centre.
local function newPlate(config: Config, node: Node, folder: Folder): Plate
	local span = TerrainMath.CHUNK * node.stride
	local face = node.face
	local p00 = groundAt(config, face, node.i0, node.j0)
	local p10 = groundAt(config, face, node.i0 + span, node.j0)
	local p11 = groundAt(config, face, node.i0 + span, node.j0 + span)
	local p01 = groundAt(config, face, node.i0, node.j0 + span)
	local pc = Vec3d.new(node.cx, node.cy, node.cz)
	local up = Vec3d.cross(Vec3d.sub(p11, p00), Vec3d.sub(p01, p10))
	if Vec3d.dot(up, pc) < 0 then
		up = Vec3d.scale(up, -1)
	end
	up = Vec3d.normalize(up)
	local alongU = Vec3d.sub(Vec3d.add(p10, p11), Vec3d.add(p00, p01))
	local x = Vec3d.normalize(Vec3d.sub(alongU, Vec3d.scale(up, Vec3d.dot(alongU, up))))
	local z = Vec3d.cross(x, up)
	-- top plane through the mean of the five points, along `up`
	local mean = Vec3d.scale(Vec3d.add(Vec3d.add(Vec3d.add(p00, p10), Vec3d.add(p11, p01)), pc), 0.2)
	local sizeX =
		math.min(0.5 * (Vec3d.distance(p00, p10) + Vec3d.distance(p01, p11)) * PLATE_OVERLAP, PLATE_MAX_EXTENT)
	local sizeZ =
		math.min(0.5 * (Vec3d.distance(p00, p01) + Vec3d.distance(p10, p11)) * PLATE_OVERLAP, PLATE_MAX_EXTENT)
	local thickness = math.min(PLATE_THICKNESS + PLATE_THICKNESS_PER_M * math.max(sizeX, sizeZ), PLATE_MAX_EXTENT)
	local centre = Vec3d.sub(mean, Vec3d.scale(up, thickness / 2 + PLATE_DROP))
	local part = acquirePlate()
	part.Size = Vector3.new(sizeX, thickness, sizeZ)
	local dir = Vec3d.normalize(pc)
	local r, g, b, kind = Biome.sample(config.bodyId, dir.x, dir.y, dir.z)
	part.Color = if DEBUG_TINT.on then DEBUG_TINT.PLATE else Color3.new(r, g, b) -- CHANGED (Far slabs fix): /bands
	part.Material = KIND_MATERIALS[kind] or FALLBACK_MATERIAL
	part.Reflectance = if kind == "Ocean" or kind == "Lake" then OCEAN_REFLECTANCE else 0 -- CHANGED (Planet detail)
	part.Parent = folder
	return {
		part = part,
		pos = centre,
		rot = CFrame.fromMatrix(Vector3.zero, Vec3d.toVector3(x), Vec3d.toVector3(up), Vec3d.toVector3(z)),
	}
end

local function updatePlates(ctx: RenderContext.RenderContext, config: Config)
	local folder = plateFolder
	local parent = root
	if folder == nil or parent == nil then
		return
	end
	if plateBodyId ~= config.bodyId then
		releaseAllPlates()
		plateBodyId = config.bodyId
	end
	local cam = ctx.cameraDominant
	local now = os.clock()
	local last = plateLastCam
	local moved = last == nil
		or Vec3d.distance(cam, last :: Vec3d)
			> math.max(RESELECT_MIN_MOVE, RESELECT_MOVE_FRACTION * heightAboveGround(config, cam))
	if moved and now - plateLastTime >= RESELECT_INTERVAL then
		plateLastTime = now
		plateLastCam = Vec3d.clone(cam)
		local selection = TerrainMath.select(config, cam, {
			splitK = PLATE_SPLIT_K,
			mergeK = PLATE_SPLIT_K * MERGE_FACTOR,
			maxLeaves = PLATE_MAX_LEAVES,
			maxLeafSize = PLATE_MAX_SIZE,
			maxDistance = PLATE_MAX_DISTANCE,
		}, plateSplit)
		plateSplit = selection.split
		local wanted: { [number]: Node } = {}
		for _, node in selection.leaves do
			wanted[node.key] = node
		end
		plateWanted = wanted
		-- nearest first
		table.clear(plateQueue)
		for key, node in wanted do
			if plates[key] == nil then
				table.insert(plateQueue, node)
			end
		end
		table.sort(plateQueue, function(a: Node, b: Node): boolean
			local da = (a.cx - cam.x) ^ 2 + (a.cy - cam.y) ^ 2 + (a.cz - cam.z) ^ 2
			local db = (b.cx - cam.x) ^ 2 + (b.cy - cam.y) ^ 2 + (b.cz - cam.z) ^ 2
			return da > db -- popped from the end
		end)
	end
	-- a few new plates per frame; the old ones go once every wanted plate exists (no holes meanwhile)
	local changed = false
	for _ = 1, PLATES_PER_FRAME do
		local node = table.remove(plateQueue)
		if node == nil then
			break
		end
		if plates[node.key] == nil then
			plates[node.key] = newPlate(config, node, folder)
			changed = true
		end
	end
	local wanted = plateWanted
	if wanted and #plateQueue == 0 then
		for key, plate in plates do
			if wanted[key] == nil then
				releasePlate(plate)
				plates[key] = nil
				changed = true
			end
		end
		plateWanted = nil
	end
	if changed then
		table.clear(plateParts)
		for _, plate in plates do
			table.insert(plateParts, plate.part)
		end
		platesDirty = true
	end
	if folder.Parent ~= parent then
		folder.Parent = parent
		platesDirty = true
	end
	platesShown = true
	local frame = ctx.frame
	if
		platesDirty
		or frame.refPos.x ~= lastPlateRef.x
		or frame.refPos.y ~= lastPlateRef.y
		or frame.refPos.z ~= lastPlateRef.z
		or frame.refRot ~= lastPlateRot
		or frame.slotOrigin ~= lastPlateSlot
	then
		-- relative to the camera (the terrain is the dominant body's; body offsets cancel)
		local camWs = ctx.camera.Position
		local rotWs = Frames.rotationToWorkspace(frame, CFrame.identity)
		table.clear(plateCFrames)
		local i = 0
		for _, plate in plates do
			i += 1
			plateParts[i] = plate.part
			Vec3d.subInto(scratch, plate.pos, cam)
			plateCFrames[i] = CFrame.new(camWs + Frames.vectorToWorkspace(frame, scratch)) * rotWs * plate.rot
		end
		if i > 0 then
			Workspace:BulkMoveTo(plateParts, plateCFrames, BULK_MOVE_MODE)
		end
		Vec3d.copyInto(lastPlateRef, frame.refPos)
		lastPlateRot = frame.refRot
		lastPlateSlot = frame.slotOrigin
		platesDirty = false
	end
end

local function hidePlates()
	if not platesShown then
		return
	end
	platesShown = false
	local folder = plateFolder
	if folder then
		folder.Parent = nil
	end
end

--============================================================================
-- API
--============================================================================
function TerrainMesh.init(parent: Folder)
	root = parent
	local meshes = Instance.new("Folder")
	meshes.Name = "TerrainMesh"
	meshes.Parent = parent
	meshFolder = meshes
	local platesFolderInstance = Instance.new("Folder")
	platesFolderInstance.Name = "TerrainPlates"
	plateFolder = platesFolderInstance
	local function applyTier(name: string)
		local wanted = TIERS[name] or TIERS.High
		if wanted ~= tier then
			tier = wanted
			tierName = name
			forceSelect = true
			for _, bm in bands do
				bm.part.CastShadow = bm.shadow and tier.shadows -- CHANGED (Night review): bm.shadow (was id == 0)
			end
		end
	end
	applyTier(Quality.tier())
	Quality.onChanged(function(name: Quality.Tier)
		applyTier(name)
	end)
end

function TerrainMesh.update(ctx: RenderContext.RenderContext, show: boolean, prebuild: boolean)
	local config = TerrainMath.config(ctx.dominantBodyId)
	updatedOnce = true -- CHANGED (Memory budget)
	if config == nil or Vec3d.lengthSq(ctx.cameraDominant) < 1 or not (show or prebuild) then
		activeLast = false -- CHANGED (Memory budget)
		setHidden(true) -- CHANGED (Memory budget): the meshes may go whenever something visible needs the memory
		wantsGround = false -- CHANGED (Terrain polish)
		uncoveredSince = nil
		setMeshesShown(false)
		hidePlates()
		local now = os.clock()
		local since = hiddenSince
		if since == nil then
			hiddenSince = now
		elseif now - since > HIDDEN_RELEASE_S and (next(bands) ~= nil or plan ~= nil) then
			-- far from any ground for a while: give the meshes back
			abortPlan()
			releaseAllBands()
			table.clear(split)
			forceSelect = true
		end
		return
	end
	hiddenSince = nil
	activeLast = true -- CHANGED (Memory budget)
	setHidden(false)
	-- CHANGED (Terrain polish): the draw budget (placeBands and the ring layout of the next plan)
	local dd = ctx.drawDistance
	if dd ~= dd or dd <= 0 or dd > DRAW_DISTANCE_CAP then
		dd = DRAW_DISTANCE_CAP
	end
	drawBudget = BUDGET_FRACTION * dd
	if bodyId ~= config.bodyId then
		abortPlan()
		releaseAllBands()
		table.clear(split)
		bodyId = config.bodyId
		forceSelect = true
		nearSquare = nil -- CHANGED (Night review)
		ringBounds = nil -- CHANGED (Terrain polish)
		camSpeed.cam = nil -- CHANGED (See-through fix)
	end
	local cam = ctx.cameraDominant
	-- CHANGED (See-through fix): the camera's speed (the bulge culling's reach); a jump (another body, a teleport)
	-- is not a speed
	do
		local now = os.clock()
		local last = camSpeed.cam
		local dt = now - camSpeed.time
		if last and dt > 0 and dt < 1 then
			local v = Vec3d.distance(cam, last) / dt
			if v < CULL.SPEED_JUMP then
				camSpeed.value =
					math.max(v, camSpeed.value + (v - camSpeed.value) * math.min(dt / CULL.SPEED_SMOOTH_S, 1))
			end
		end
		camSpeed.cam = Vec3d.clone(cam)
		camSpeed.time = now
		local camera = Workspace.CurrentCamera
		camSpeed.zoom = if camera then (camera.Focus.Position - ctx.camera.Position).Magnitude else 0
	end
	-- CHANGED (Review 3): the daylight at the camera; bands baked for another step are rebuilt by the next plan
	if Bodies.get(config.bodyId).AtmosphereColor ~= nil then
		local up = Frames.vectorToWorkspace(ctx.frame, Vec3d.normalize(cam))
		lightNow = TerrainMath.daylight(ctx.sunDirection:Dot(up))
		if plan == nil and not forceSelect then
			for _, bm in bands do
				if bm.light ~= lightNow then
					forceSelect = true
					break
				end
			end
		end
	end
	if meshEnabled then
		finishPlan()
		if meshEnabled then
			-- CHANGED (Memory budget): no tryRecover probing; maybeSelect plans with the bands that fit
			checkBandCount()
			maybeSelect(config, cam)
		end
	end
	local covered = meshEnabled and meshCoverage(config, cam)
	wantsGround = show -- CHANGED (Terrain polish): isReady
	if show and covered then
		uncoveredSince = nil
		setMeshesShown(true)
		placeBands(ctx)
		hidePlates()
	elseif show then
		-- CHANGED (Terrain polish): while meshes are on their way (the first build, a jump, a band swap), the plates
		-- (blocky boxes: Steamy's "the terrain looked blocky but then got here") only come after PLATE_GRACE_S;
		-- until then the meshes on screen stay (they are placed exactly, only coarser or short of the view), or
		-- nothing is drawn. Plates stay the fallback when EditableMesh is unavailable.
		local now = os.clock()
		local since = uncoveredSince or now
		uncoveredSince = since
		if meshEnabled and now - since < PLATE_GRACE_S then
			hidePlates()
			if next(bands) ~= nil then
				setMeshesShown(true)
				placeBands(ctx)
			else
				setMeshesShown(false)
			end
		else
			setMeshesShown(false)
			updatePlates(ctx, config)
		end
	else
		uncoveredSince = nil
		setMeshesShown(false)
		hidePlates()
	end
end

--[[
	CHANGED (Terrain polish): whether the ground the Surface layer wants is on screen as meshes (or will only ever
	be plates: EditableMesh unavailable). The main menu holds its Play fade on it (MainMenuController).
]]
function TerrainMesh.isReady(): boolean
	if not wantsGround or not meshEnabled then
		return true
	end
	return meshesShown and not coverageBroken and displayedCam ~= nil and uncoveredSince == nil
end

--[[
	CHANGED (Memory budget): no plan is running and the ground around the camera is built (or no ground is wanted,
	or only plates can be drawn). ScaledSpace holds its other textures at join until this is true.
]]
function TerrainMesh.isSettled(): boolean
	if not updatedOnce then
		return false
	end
	if not meshEnabled or not activeLast then
		return true
	end
	return plan == nil and not forceSelect and displayedCam ~= nil and next(bands) ~= nil
end

--[[
	CHANGED (Memory budget): the build time per frame while loading: "Menu" (the main menu is up), "Cover" (the
	black "Preparing launch site..." cover: nothing else runs), nil: the tier's own budget.
]]
function TerrainMesh.setLoadBoost(mode: string?)
	loadBoostS = if mode == "Cover" then LOAD_BOOST_COVER_S elseif mode == "Menu" then LOAD_BOOST_MENU_S else 0
end

-- Band showing the leaf under body-relative `pos` (nil when none is displayed there).
local function bandAt(config: Config, pos: Vec3d): BandMesh?
	local face, fi, fj = SurfaceHeight.latticeCoords(config.bodyId, pos)
	local x, y = math.floor(fi / TerrainMath.CHUNK), math.floor(fj / TerrainMath.CHUNK)
	local depth = config.maxDepth
	local keys: { number } = {}
	while depth >= 0 do
		table.insert(keys, TerrainMath.nodeKey(config.bodyId, face, depth, x, y))
		depth -= 1
		x //= 2
		y //= 2
	end
	for _, bm in bands do
		for _, key in keys do
			if bm.leaves[key] then
				return bm
			end
		end
	end
	return nil
end

--[[
	CHANGED (Night review): the smallest scale factor of the bands drawing the ground at body-relative `pos` (the
	dominant body) and at `margin` m around it (4 points in its tangent plane): 1 when plates (true scale) or nothing
	is drawn, nil when meshes are drawn but no band holds one of the points.
]]
function TerrainMesh.scaleAt(pos: Vec3d, margin: number): number?
	if not meshesShown then
		return 1
	end
	local id = bodyId
	local config = if id then TerrainMath.config(id) else nil
	if config == nil then
		return 1
	end
	local up = Vec3d.normalize(pos)
	local ref = if math.abs(up.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
	local e1 = Vec3d.normalize(Vec3d.cross(ref, up))
	local e2 = Vec3d.cross(up, e1)
	local scale = math.huge
	for index = 0, if margin > 0 then 4 else 0 do
		local p = pos
		if index > 0 then
			local axis = if index <= 2 then e1 else e2
			p = Vec3d.add(pos, Vec3d.scale(axis, if index % 2 == 0 then margin else -margin))
		end
		local bm = bandAt(config, p)
		if bm == nil then
			return nil
		end
		-- CHANGED (Depth order fix): a depth-mapped band draws that ground at its own factor f(d) / d
		scale = math.min(
			scale,
			if bm.depthK > 0
				then bm.appliedScale * TerrainMath.depthFactor(CULL.DEPTH_MAP, Vec3d.distance(p, bm.planCam))
				else bm.scale
		)
	end
	return math.min(scale, 1)
end

--[[
	CHANGED (Terrain polish): the largest factor (<= 1) an object reaching `far` m from the camera can be drawn
	scaled about the camera by and still lie in front of every scaled band's ground that is farther than `far`
	(a scaled band of factor k whose ground starts d m away draws it k x d away): 1 when nothing is scaled.
	Surface draws the launch-site copy with it when the ground under the site is scaled, so the hills and
	mountains behind the site never cover it.
]]
function TerrainMesh.depthScale(far: number): number
	if not meshesShown or far <= 0 then
		return 1
	end
	local factor = 1
	for _, bm in bands do
		if bm.depthK > 0 then
			-- CHANGED (Depth order fix): a depth-mapped band draws ground d m away f(d) studs away
			local d = math.max(bm.nearestNow, far)
			factor = math.min(factor, bm.appliedScale * TerrainMath.mapDepth(CULL.DEPTH_MAP, d) / far)
		elseif bm.scale < TRUE_SCALE then
			factor = math.min(factor, bm.scale * math.max(bm.nearestNow, far) / far)
		end
	end
	return factor
end

--[[
	Is body-relative `pos` (the dominant body) drawn at true scale this frame, `margin` m around it included? Plates
	are always true scale; meshes only where the band under every checked point is unscaled.
]]
function TerrainMesh.isTrueScaleAt(pos: Vec3d, margin: number): boolean
	local scale = TerrainMesh.scaleAt(pos, margin) -- CHANGED (Night review): shared with scaleAt
	return scale ~= nil and scale >= TRUE_SCALE
end

-- CHANGED (Night review): changes whenever the displayed bands change (a swap, a release).
function TerrainMesh.version(): number
	return bandsVersion
end

--[[
	CHANGED (Night review): keeps a square of +-half m (tangent) around body-relative `pos` on `keepBodyId` inside the
	near band while the camera's nadir is within KEEP_RANGE of fitting it (Surface: the launch site, so the copy and
	a craft on its pad are at true scale together on the pad and in the climb).
	CHANGED (Review 3): `range` (m, default KEEP_RANGE) replaces KEEP_RANGE for this square: Surface keeps the base's
	plate in the near band out to its near zone (no copy there: the real base, with everything on it, is drawn).
]]
function TerrainMesh.keepNear(keepBodyId: number, pos: Vec3d, half: number, range: number?)
	keepBody, keepPos, keepHalf = keepBodyId, Vec3d.clone(pos), half
	keepRange = range or KEEP_RANGE
end

--[[
	CHANGED (Review 3): the depth (studs) scaled bands keep their ground at this frame (bandScales' protected depth:
	true-scale things nearer than this are never covered by a scaled band). Surface never draws the launch-site
	copy nearer than this either (TerrainMath.objectScale).
]]
function TerrainMesh.protectDepth(): number
	return protectNow
end

-- CHANGED (Review 3): does band `bm` hold the leaf under body-relative `pos`?
local function bandHolds(config: Config, bm: BandMesh, pos: Vec3d): boolean
	local face, fi, fj = SurfaceHeight.latticeCoords(config.bodyId, pos)
	local x, y = math.floor(fi / TerrainMath.CHUNK), math.floor(fj / TerrainMath.CHUNK)
	for depth = config.maxDepth, 0, -1 do
		if bm.leaves[TerrainMath.nodeKey(config.bodyId, face, depth, x, y)] then
			return true
		end
		x //= 2
		y //= 2
	end
	return false
end

--[[
	CHANGED (Review 3): the bands holding the ground under any of `points` (body-relative, the dominant body), and
	whether every point is held by one. Which band holds a point only changes with the displayed bands, so the
	answer is cached per points list until version() changes (Surface asks every frame for the base's plate).
]]
local overPoints: { Vec3d }? = nil
local overVersion = -1
local overBody: number? = nil
local overBands: { BandMesh } = {}
local overComplete = false
local function bandsOver(points: { Vec3d }): ({ BandMesh }, boolean)
	if points == overPoints and overVersion == bandsVersion and overBody == bodyId then
		return overBands, overComplete
	end
	overPoints, overVersion, overBody = points, bandsVersion, bodyId
	table.clear(overBands)
	overComplete = false
	local id = bodyId
	local config = if id then TerrainMath.config(id) else nil
	if config == nil then
		return overBands, overComplete
	end
	local held: { [BandMesh]: boolean } = {}
	overComplete = true
	for _, pos in points do
		local any = false
		for _, bm in bands do
			if bandHolds(config, bm, pos) then
				any = true
				if not held[bm] then
					held[bm] = true
					table.insert(overBands, bm)
				end
			end
		end
		overComplete = overComplete and any
	end
	return overBands, overComplete
end

--[[
	CHANGED (Review 3): scaleAt over a list of points (the launch site's plate outline): the smallest factor of the
	ground drawn under them, 1 when plates or nothing is drawn, nil when meshes are drawn but no band holds one.
]]
function TerrainMesh.scaleOver(points: { Vec3d }): number?
	if not meshesShown then
		return 1
	end
	local held, complete = bandsOver(points)
	if not complete then
		return nil
	end
	local scale = 1
	for _, bm in held do
		if bm.depthK > 0 then
			-- CHANGED (Depth order fix): a depth-mapped band's factor where the points are (the nearest is drawn largest)
			local nearest = math.huge
			for _, point in points do
				nearest = math.min(nearest, Vec3d.distance(point, bm.planCam))
			end
			scale = math.min(scale, bm.appliedScale * TerrainMath.depthFactor(CULL.DEPTH_MAP, nearest))
		else
			scale = math.min(scale, bm.scale)
		end
	end
	return scale
end

--[[
	CHANGED (Review 3): hides (this frame, until the next call) every scaled band that holds the ground under any of
	`points` (body-relative, the dominant body); nil shows them all again. Surface calls it every frame after
	update: in the base pocket, near the site, while the ground under the real base's plate is not drawn at true
	scale (a jump home: the meshes on screen were built around the old camera), so no scaled ground is drawn in
	front of the real base and the player on it (the plate fills the hole) until the near band holds it.
]]
function TerrainMesh.hideScaledAt(points: { Vec3d }?)
	if points == nil and next(holeHidden) == nil then
		return
	end
	local hide: { [BandMesh]: boolean } = {}
	if points and meshesShown then
		local held = bandsOver(points)
		for _, bm in held do
			if bm.scale < TRUE_SCALE then
				hide[bm] = true
			end
		end
	end
	local folder = meshFolder
	for bandId, bm in bands do
		if hide[bm] then
			holeHidden[bandId] = bm
			bm.part.Parent = nil
		elseif holeHidden[bandId] ~= nil then
			holeHidden[bandId] = nil
			if meshesShown and bm.part.Parent ~= folder then
				bm.part.Parent = folder
			end
		end
	end
	for bandId in holeHidden do
		if bands[bandId] == nil then
			holeHidden[bandId] = nil
		end
	end
end

-- F3 debug line.
function TerrainMesh.summary(): string
	if not meshEnabled then
		local count = 0
		for _ in plates do
			count += 1
		end
		return string.format("Terrain: plates %d (EditableMesh unavailable)", count)
	end
	local ids: { number } = {}
	for id in bands do
		table.insert(ids, id)
	end
	table.sort(ids)
	local parts: { string } = {}
	local leaves, triangles = 0, 0
	for _, id in ids do
		local bm = bands[id]
		leaves += bm.count
		triangles += bm.triangles
		table.insert(parts, string.format("%d:%d x%.2f%s", id, bm.count, bm.scale, if bm.stale then "*" else ""))
	end
	local p = plan
	return string.format(
		"Terrain: %s  %d leaves  %.1fk tris  [%s]  %s  meshes %d (bands <= %d)  cache %d%s",
		tierName,
		leaves,
		triangles / 1000,
		table.concat(parts, " "),
		if p then string.format("building %s (%d/%d)", p.current, p.builds, p.steps) else "idle",
		liveMeshes,
		bandCount,
		chunkCount,
		if meshesShown then "" elseif platesShown then "  (plates)" else ""
	)
end

--[[
	CHANGED (Far slabs fix): the /bands debug view (Surface.setDebugTint): every scaled band gets a flat colour
	(band 1 blue, 2 red, 3 yellow, further magenta; the near band keeps its own), the fallback plates turn white. No
	rebuild: a Highlight per band (at most 5, under the engine's 31), plates are recreated once. Off by default;
	off costs nothing.
]]
function TerrainMesh.setDebugTint(on: boolean)
	if DEBUG_TINT.on == on then
		return
	end
	DEBUG_TINT.on = on
	for id, bm in bands do
		TerrainMesh.tintBand(bm.part, id)
	end
	releaseAllPlates()
end

function TerrainMesh.debugTint(): boolean
	return DEBUG_TINT.on
end

-- CHANGED (Far slabs fix): gives band `id`'s part its /bands tint while the view is on, or takes it away.
function TerrainMesh.tintBand(part: MeshPart, id: number)
	local existing = part:FindFirstChild(DEBUG_TINT.NAME)
	if not DEBUG_TINT.on or id == TerrainMath.NEAR_BAND then
		if existing then
			existing:Destroy()
		end
		return
	end
	if existing == nil then
		local highlight = Instance.new("Highlight")
		highlight.Name = DEBUG_TINT.NAME
		highlight.FillColor = DEBUG_TINT.BANDS[id] or DEBUG_TINT.FURTHER
		highlight.FillTransparency = 0
		highlight.OutlineTransparency = 1
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		highlight.Parent = part
	end
end

-- Test hook: what is on screen (leaf key -> band id, and band id -> scale), for offline simulations.
TerrainMesh._test = table.freeze({
	displayed = function(): ({ [number]: number }, { [number]: number }, boolean, boolean)
		local leaves: { [number]: number } = {}
		local scales: { [number]: number } = {}
		for id, bm in bands do
			scales[id] = bm.scale
			for key in bm.leaves do
				leaves[key] = id
			end
		end
		return leaves, scales, meshesShown, platesShown
	end,
	liveMeshes = function(): number
		return liveMeshes
	end,
})

return table.freeze(TerrainMesh)
