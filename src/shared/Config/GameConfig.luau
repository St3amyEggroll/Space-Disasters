--!strict
--[[
	GameConfig
	Global tunables for Space Disasters. Every number that is not specific to one body or one part lives here.

	Rules:
	  * This module must stay pure (no services, no Instances) so it can be required anywhere,
	    including the offline Lune test runner.
	  * Units follow the spec: meters (= studs), kilograms, seconds, newtons, radians unless a name says otherwise.
]]

local GameConfig = {
	--========================================================================
	-- Identity
	--========================================================================
	GAME_NAME = "Space Disasters",
	BASE_SITE_NAME = "Oopsie Point Launch Complex",

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
	NEAR_CAP_RADIUS = 8000, -- m; true-scale surface tile cap radius
	TILE_SIZE = 2048, -- m; tile edge length (max part size)
	TILE_THICKNESS = 20,
	TILE_COLLIDE_RADIUS = 1000, -- studs; tiles closer than this to the local player collide
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

	--========================================================================
	-- Orbits and debris
	--========================================================================
	RAILS_IDLE_TIME = 0.5, -- s without input before a craft may go on rails
	SOI_CHECK_INTERVAL = 1, -- s of UT
	SOI_BISECTION_TOLERANCE = 0.01, -- s
	DEBRIS_DESPAWN_DIST = 30000,

	--========================================================================
	-- EVA
	--========================================================================
	EVA_THRUST_ACCEL = 3, -- m/s^2
	EVA_PROPELLANT_S = 60, -- s of full thrust
	EVA_REBASE_DIST = 300,
	EVA_SURFACE_HOP_G = 1.5, -- vertical jetpack thrust as a multiple of body g

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
	HOME_BASE_MAX_PARTS = 1500,

	--========================================================================
	-- Debug and tests
	--========================================================================
	RUN_TESTS = true, -- Studio only; RunTests also checks RunService:IsStudio()
	DEBUG_USER_IDS = table.freeze({} :: { number }), -- players allowed to use debug commands outside Studio
	DEBUG_OVERLAY_REFRESH = 0.25, -- s between overlay text refreshes
}

return table.freeze(GameConfig)
