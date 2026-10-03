--!strict
--[[
	GameConfig
	Global tunables for Space Disasters. Every number that is not specific to one body or one part lives here.

	Rules:
	  * This module must stay pure (no services, no Instances) so it can be required anywhere,
	    including the offline Lune test runner.
	  * Units follow the spec: meters (= studs), kilograms, seconds, newtons, radians unless a name says otherwise.

	Scale (CHANGED (Physics feel)): distances are true metres, 1 stud = 1 m, for positions, gravity, orbits, the
	planets (Bodies: 60 km Earth) and the ground. Parts are 4-stud blocks (GRID_SIZE) but keep KSP 1.25 m masses
	and thrusts (Parts), so their faces are ~10x the area a part of that mass would have. Aerodynamics therefore
	sees every part at its VISUAL size: a 4-stud block reads as ~1.2 m next to a character, so every aerodynamic
	area (body drag, fin lift, and the Phase 2b parachute CdA) is multiplied by AERO_METERS_PER_STUD^2.
]]

local GameConfig = {
	--========================================================================
	-- Identity
	--========================================================================
	GAME_NAME = "Space Disasters",
	BASE_SITE_NAME = "Space Disasters Inc.",

	--========================================================================
	-- Physics constants
	--========================================================================
	G0 = 9.80665, -- standard gravity for Isp (m/s^2)
	CHARACTER_GRAVITY = 196.2, -- workspace.Gravity for characters at 1 g (Roblox default feel)

	--========================================================================
	-- Flight model
	--========================================================================
	ROTATION_ASSIST = 2.0, -- multiplier on control torque so small crafts feel responsive
	CD_BASE = 0.8, -- base drag coefficient applied to projected bounding-box area
	-- CHANGED (Physics feel): aerodynamic areas are computed as if parts were their visual size (~0.3 m per stud next
	-- to a character, so a 4-stud block face is 1.2 m wide), not 1 m per stud. Every aero area (MassProps drag
	-- areas, fin lift areas, and the Phase 2b chute CdA, which must use it too) is multiplied by this squared (0.09).
	-- Without it drag per kg was ~11x too strong and rockets stalled near 100 m/s in the lower air.
	AERO_METERS_PER_STUD = 0.3,
	ATMOSPHERE_FADE_BAND = 1000, -- m below atmosphere top over which density fades to zero
	SIM_RATE = 60, -- fixed steps per second
	SIM_SUBSTEPS_FLIGHT = 2, -- 120 Hz in flight
	SIM_SUBSTEPS_NEAR_SURFACE = 4, -- 240 Hz when any hull point is near the surface
	SIM_NEAR_SURFACE_DIST = 20, -- m, hull-point height that triggers near-surface substepping
	SIM_MAX_STEPS_PER_FRAME = 8, -- accumulator clamp to avoid a spiral of death
	CONTACT_SPRING = 400000, -- N/m per hull point (non-leg)
	CONTACT_DAMPER = 40000, -- N*s/m per hull point (non-leg)
	CONTACT_FRICTION = 0.8, -- Coulomb friction coefficient
	LANDED_SPEED = 0.3, -- m/s relative to surface
	LANDED_ANGULAR_SPEED = 0.05, -- rad/s
	LANDED_TIME = 1.0, -- s the craft must stay below both thresholds
	MASS_PROPS_FUEL_RATE = 2, -- Hz, mass/CoM/inertia refresh while fuel drains
	LAUNCH_COUNTDOWN_S = 1.0, -- unused since the Phase 2a feedback (flight starts when the pilot sits; Space ignites)
	MAX_HULL_POINTS = 64,
	-- CHANGED (Phase 2a): flight controls, SAS and simulation tunables
	THROTTLE_RATE = 0.8, -- throttle change per second while Shift/Ctrl is held
	SAS_KP = 4.0, -- attitude-hold proportional gain (1/s^2, scaled by the torque budget)
	SAS_KD = 3.0, -- attitude-hold derivative gain (1/s)
	MAX_ANGULAR_SPEED = 3.0, -- rad/s clamp so a tiny craft cannot spin itself apart numerically
	DEBRIS_SIM_RATE = 30, -- Hz for server-simulated uncrewed crafts (substeps still apply near the surface)
	CRAFT_STATE_RATE = 20, -- Hz relay tick; CHANGED (Phase 3): per-client rates come from interest management
	CRASH_REPORT_MARGIN = 5, -- m/s slack when the server checks a reported crash for plausibility

	--========================================================================
	-- Pockets
	--========================================================================
	POCKET_SPACING = 4000, -- studs between slot lattice points
	POCKET_SLOT_X_RANGE = 3, -- ix in [-3, 3]
	POCKET_SLOT_Y_MIN = 1, -- iy in [1, 3]
	POCKET_SLOT_Y_MAX = 3,
	POCKET_SLOT_Z_RANGE = 3, -- iz in [-3, 3]
	POCKET_TRANSFER_ACK_TIMEOUT = 3, -- s before the server teleports a character itself
	BUBBLE_MERGE_DIST = 250,
	BUBBLE_SPLIT_DIST = 400,
	BASE_BUBBLE = 600,
	BUBBLE_CHECK_RATE = 4, -- Hz

	--========================================================================
	-- Universe rendering
	--========================================================================
	NEAR_RENDER_RADIUS = 300, -- studs; true-scale zone around the camera
	SCALED_NEAR = 400, -- studs; fake distance for the nearest scaled-space objects
	SCALED_FAR = 1800, -- studs; fake distance for the farthest scaled-space objects
	PROXY_MAX_RADIUS = 2800, -- studs; largest dominant-body proxy radius
	LOG_D_MIN = math.log(1e3), -- ln(1 km)
	LOG_D_MAX = math.log(1e11), -- ln(1e11 m)
	PROXY_HANDOVER_HYSTERESIS = 0.1, -- +/-10% around PROXY_MIN_ALT
	-- CHANGED (Phase 8): the heightmap terrain (Render/TerrainMesh) replaced the v1 tile cap; NEAR_CAP_RADIUS,
	-- TILE_THICKNESS and TILE_COLLIDE_RADIUS are no longer read. TILE_SIZE still sizes SurfaceHeight's tile grid,
	-- which SurfaceProps cuts into prop cells.
	NEAR_CAP_RADIUS = 8000, -- m; v1 true-scale surface tile cap radius (unused since Phase 8)
	TILE_SIZE = 2048, -- m; tile edge length (max part size)
	TILE_THICKNESS = 20, -- unused since Phase 8
	TILE_COLLIDE_RADIUS = 1000, -- studs; v1 tile collision radius (unused since Phase 8: Render/TerrainCollision)
	STAR_SHELL_RADIUS = 1950,
	STAR_COUNT = 600,
	CRAFT_MARKER_ANGLE_DEG = 0.15, -- below this angular size a craft becomes a marker
	CRAFT_SCALE_UPDATE_RATE = 4, -- Hz, max Model:ScaleTo rate
	CRAFT_SCALE_UPDATE_THRESHOLD = 0.05, -- only rescale on >5% change
	-- CHANGED (Phase 2a): camera
	CHASE_ZOOM_MIN = 20,
	CHASE_ZOOM_MAX = 400,
	CHASE_ZOOM_DEFAULT = 60,

	--========================================================================
	-- Networking
	--========================================================================
	PILOT_STATE_RATE = 20, -- Hz
	INTEREST_NEAR = 50000, -- m
	INTEREST_RATE_NEAR = 20, -- Hz
	INTEREST_RATE_SOI = 2, -- Hz
	INTEREST_RATE_FAR = 0.5, -- Hz
	MAX_STATES_PER_PACKET = 11,
	UNRELIABLE_PAYLOAD_LIMIT = 900, -- bytes; confirm with spike S7
	NET_BUDGET_BYTES_PER_S = 20000,
	INTERP_DELAY = 0.1, -- s
	EXTRAPOLATE_MAX = 0.25, -- s
	PUPPET_DISTANCE = 300,
	-- CHANGED (Phase 3): interest management, LOD markers, puppets, snapshots
	CRAFT_STATES_BUDGET = 18000, -- bytes/s of CraftStates payload per client (the rest of NET_BUDGET is headroom)
	EXTRAPOLATE_MAX_SLOW = 2.5, -- s; extrapolation limit for slow (2 Hz / 0.5 Hz) streams and map markers
	COPY_MAX_DISTANCE = 30000, -- m; cosmetic copies farther than this become markers (Phase 4 adds scaled copies)
	PUPPET_ABOARD_RADIUS = 40, -- m beyond a craft's own radius where a standing character still counts as aboard
	SNAPSHOT_COOLDOWN_S = 5, -- s between two join snapshots for the same player
	-- CHANGED (Ground puppets): players on foot in other pockets (the base, a landing site), drawn where they are
	GROUND_PUPPET_DISTANCE = 1500, -- m from the camera; on-foot players farther away are not drawn
	GROUND_PUPPET_MAX = 12, -- nearest on-foot puppets drawn at once

	--========================================================================
	-- Orbits and debris
	--========================================================================
	RAILS_IDLE_TIME = 0.5, -- s without input before a craft may go on rails
	SOI_CHECK_INTERVAL = 1, -- s of UT
	SOI_BISECTION_TOLERANCE = 0.01, -- s
	DEBRIS_DESPAWN_DIST = 30000,
	-- CHANGED (Phase 5): rails, debris cleanup and the map view
	RAILS_MIN_ALTITUDE = 500, -- m above sea level; rails need max(this, atmosphere top) and end below it
	RAILS_ALTITUDE_HYSTERESIS = 100, -- m above that minimum before a craft may go on rails
	RAILS_SAS_MAX_RATE = 0.05, -- rad/s; with SAS on, the craft must have settled below this to go on rails
	RAILS_RETRY_S = 5, -- s a pilot waits before proposing rails again after the server refused
	RAILS_POS_TOLERANCE = 50, -- m between a proposed rail and the server's last valid state
	RAILS_VEL_TOLERANCE = 5, -- m/s, same
	DEBRIS_CHECK_INTERVAL = 1, -- s between suborbital-debris despawn checks
	-- CHANGED (Physics feel): the three map scales are halved for the 60 km Earth so the map frames it as before
	MAP_SCALE = 0.001, -- studs per metre when the map opens (Earth: 60 studs in radius)
	-- CHANGED (Solar system): was 0.00005 (the Earth-Mun system); now Mars' 15,000 km orbit fits (300 studs)
	MAP_SCALE_MIN = 0.00002, -- fully zoomed out: the whole solar system fits on screen
	MAP_SCALE_MAX = 0.015, -- fully zoomed in (Earth's ball 1800 studs, its 68 km air shell 2040: under the part limit)
	MAP_ZOOM_STEP = 1.2, -- scale factor per mouse-wheel notch (logarithmic zoom)
	-- CHANGED (Map planets fix): was 160 at a 70 degree field of view. Perspective draws a ball off the view axis as an
	-- oval (Earth under the craft looked 10% wider than tall); 1.5 x farther with a narrower view frames the focus
	-- exactly as before (160 * tan 35 = 240 * tan 25): Earth under the craft, two zoom notches in, goes from 10.5% to
	-- 5% wider than tall (MapBodies.spec). Not farther: quality 1 stops drawing small parts past ~300 studs (S11)
	MAP_CAMERA_DISTANCE = 240, -- studs; the map camera never moves farther, zoom changes the scale instead
	MAP_FIELD_OF_VIEW = 50, -- degrees (vertical), the map camera's (CHANGED (Map planets fix): was 70)
	MAP_EXTENT = 650, -- studs around the focus where map objects are drawn (inside the map's star cube)
	MAP_ORIGIN_OFFSET = 2000, -- studs between the pocket's slot origin and the map origin (up or down)
	MAP_ORBIT_SEGMENTS = 256, -- line segments per orbit patch of the focused craft
	MAP_OTHER_ORBIT_SEGMENTS = 64, -- line segments for other crafts' orbits
	MAP_PREDICT_PATCHES = 3, -- conic patches predicted through SOI changes

	--========================================================================
	-- EVA
	--========================================================================
	EVA_THRUST_ACCEL = 3, -- m/s^2
	EVA_PROPELLANT_S = 60, -- s of full thrust
	EVA_REBASE_DIST = 300,
	EVA_SURFACE_HOP_G = 1.5, -- vertical jetpack thrust as a multiple of body g
	-- CHANGED (Phase 6): EVA, bubbles and boarding (Shared/Sim/Eva, Shared/Sim/Bubbles, BubbleService)
	EVA_REFILL_S = 4, -- s to refill an empty jetpack while seated in a craft
	BASE_JOIN_HEIGHT = 150, -- m above the ground under which an astronaut within BASE_BUBBLE joins the base pocket
	BUBBLE_SWITCH_RATIO = 0.5, -- an astronaut changes pocket when another pocket's nearest craft is this much closer
	EVA_SURFACE_ENTER_HEIGHT = 30, -- m: a solo astronaut lower than this (and slow) gets a SURFACE_ALIGNED pocket
	EVA_SURFACE_EXIT_HEIGHT = 300, -- m: ... and an INERTIAL one again above this
	EVA_SURFACE_MAX_SPEED = 30, -- m/s relative to the ground for a SURFACE_ALIGNED pocket
	EVA_SURFACE_EXIT_SPEED = 60, -- m/s: faster than this goes back to INERTIAL

	--========================================================================
	-- Time
	--========================================================================
	DAY_LENGTH_S = 1200, -- s for the sun to go once around the +Y axis
	WARP_RATES = table.freeze({ 1, 2, 5, 10, 25, 50 }),
	WARP_LOOKAHEAD = 30, -- s

	--========================================================================
	-- Base, builder and limits
	--========================================================================
	MAX_PLAYERS = 12,
	MAX_BLOCKS_PER_CRAFT = 250,
	MAX_ACTIVE_CRAFTS_PER_PLAYER = 3,
	MAX_DEBRIS = 40,
	GRID_SIZE = 4, -- CHANGED (Phase 1 rework): studs per build block (about 3/4 of a character's height)
	BUILD_VOLUME = table.freeze({ X = 20, Y = 50, Z = 20 }), -- CHANGED (Phase 1 rework): in BLOCKS (80 x 200 x 80 studs)
	LAUNCH_PAD_COUNT = 8, -- shared pads in the launch area
	BUILD_OPS_PER_SECOND = 20,
	UNDO_STACK_SIZE = 50,
	SAVE_SLOTS = 10,
	PAD_DESPAWN_GRACE_S = 60,
	DEFAULT_BOARDING = "Public", -- "Private" | "Friends" | "Public"
	-- CHANGED (Boarding): boarding a craft that flies in another pocket from the base (Shared/Craft/Boarding)
	BOARD_MAX_SPEED = 5, -- m/s relative to the ground; faster crafts cannot be boarded from the base
	BOARD_RANGE = 25, -- m beyond the craft's bounding radius within which a player on foot may board it
	HOME_BASE_MAX_PARTS = 1500,

	--========================================================================
	-- Debug and tests
	--========================================================================
	-- CHANGED (Studio test timeout): off by default: the specs run offline (tools/check.sh) and in Studio they cost
	-- seconds of server time at every Play. Set true to run them in Studio (Studio only; RunTests also checks IsStudio)
	RUN_TESTS = false,
	DEBUG_USER_IDS = table.freeze({} :: { number }), -- players allowed to use debug commands outside Studio
	-- CHANGED (Solar system): the admin panel (F7 or its button: spawn your ship in orbit or landed on any body).
	-- Admins: everyone in Studio; in live servers the place's creator (a group game's owner) and these user ids.
	ADMIN_USER_IDS = table.freeze({} :: { number }),
	ADMIN_SPAWN_COOLDOWN_S = 3, -- s between two accepted spawn requests of one player
	DEBUG_OVERLAY_REFRESH = 0.25, -- s between overlay text refreshes
}

return table.freeze(GameConfig)
