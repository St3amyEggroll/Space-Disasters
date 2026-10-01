--!strict
--[[
	SkyLighting
	Owns Roblox's Lighting for the local client (spec 7.6 "Lighting"). Called once per frame by UniverseRenderer
	with the RenderContext.

	Sun (spike S5):
	  Roblox has no "sun direction" property, so we solve for Lighting.ClockTime and Lighting.GeographicLatitude
	  until Lighting:GetSunDirection() matches ctx.sunDirection (pocket axes). The solve is warm-started from the
	  previous frame: a damped Gauss-Newton step on finite differences (2-3 evaluations per iteration), with a small
	  pattern search as fallback, usually 1-7 GetSunDirection evaluations per frame. A full cold grid search
	  (~1100 evaluations, a one-frame hitch of a few ms) runs only on the first frame, after the target jumped
	  more than COLD_JUMP_DEG, or when the warm error stayed above COLD_ERROR_DEG for COLD_AFTER_FRAMES frames.
	  The latitude search range goes beyond +/-90 (the engine accepts it; the S5 misses were at that clamp), and
	  latitude is wrapped into [-180, 180) as an angle (ASSUMPTION: the engine's sun model is trigonometric in
	  latitude; set LAT_WRAP = false to clamp instead if Studio shows otherwise).

	Shadow side (decision Q1 = A):
	  Below the pocket horizon Roblox switches to night/moonlight whatever we do. We let it, and restyle it:
	  warm dim-grey Ambient/OutdoorAmbient bright enough to read the craft, low Lighting.Brightness, no moon disc.
	  The blend runs over HORIZON_Y_DARK..HORIZON_Y_LIT in ctx.sunDirection.Y, so nothing pops.
	  The same look is used when a body's sphere blocks the sun as seen from the camera (planet shadow): an
	  angular ray-sphere test (the sun is blocked when the angle between the sun and the body centre is below the
	  body's angular radius asin(R / d)), softened over +/-SHADOW_SOFT_DEG. Below the surface d is treated as R,
	  which makes the test the true geometric horizon.

	Atmosphere: CHANGED (Phase 2a playtest): NONE. Whenever an Atmosphere instance exists Roblox draws its own
	procedural sky, even at Density 0 (S4's "the skybox shows at Density 0" turned out wrong in play): a sky with a
	fixed grey "below the horizon" half that split the screen and kept space blue. Any Atmosphere in Lighting is
	removed.

	Sky (CHANGED Phase 2a playtest 4): CelestialBodiesShown = false (ScaledSpace draws the sun). Roblox's own skybox
	stays UPRIGHT (SkyboxOrientation 0): near the ground it is the sky, blue with clouds by day and dark with
	Roblox's stars at night (flight pockets are horizon-aligned there, D31, so Roblox's day/night follows the real
	sun). Space is drawn in front of it by SkyCube (black with stars, fixed to universe axes). Painting the Sky's
	own faces with EditableImages did not work in Studio, and rotating the stock skybox stood its clouds on end.

	Lighting.Technology (Future) is set in the place file and never touched here.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local RenderContext = require(script.Parent.RenderContext)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
-- Sun solve
local SOLVE_TOLERANCE_DEG = 0.02 -- stop refining below this error
local WARM_MAX_EVALS = 40 -- hard cap on GetSunDirection evaluations per warm frame (~0.3 ms)
local GN_MAX_ITERATIONS = 4
local GN_CLOCK_H = 0.01 -- h, finite-difference step
local GN_LAT_H = 0.1 -- degrees, finite-difference step
local GN_DAMPING = 1e-3 -- Levenberg-Marquardt damping (relative)
local GN_MAX_CLOCK_STEP = 3 -- h per iteration
local GN_MAX_LAT_STEP = 30 -- degrees per iteration
local GN_BACKTRACKS = 3
local PATTERN_TRIGGER_DEG = 0.1 -- run the pattern-search fallback when Gauss-Newton ends above this
local PATTERN_CLOCK_STEP = 0.1 -- h
local PATTERN_LAT_STEP = 1.5 -- degrees
local COLD_JUMP_DEG = 20 -- target moved more than this since last frame -> cold solve
local COLD_ERROR_DEG = 1 -- warm error above this ...
local COLD_AFTER_FRAMES = 3 -- ... for this many consecutive frames -> cold solve
local COLD_COOLDOWN_FRAMES = 60 -- after a cold solve that itself missed (unreachable target), wait this long
-- before another error-triggered one (jump-triggered ones are never limited)
local COLD_CLOCK_STEPS = 36 -- every 40 min
local COLD_LAT_MIN = -150 -- degrees; beyond +/-90 on purpose (S5)
local COLD_LAT_MAX = 150
local COLD_LAT_STEPS = 31 -- every 10 degrees
local COLD_REFINE_EVALS = 200
local LAT_WRAP = true -- latitude is an angle: wrap into [-180, 180) so a solve never sticks at a clamp. Set
-- false if the engine turns out to clamp or misbehave beyond +/-180; the solve then clamps at +/-LAT_LIMIT.
local LAT_LIMIT = 175 -- degrees, clamp used when LAT_WRAP is false

-- Shadow side
local HORIZON_Y_DARK = 0.02 -- sunDirection.Y at or below which the full shadow-side look applies
local HORIZON_Y_LIT = 0.12 -- sunDirection.Y at or above which the normal lit look applies
local SHADOW_SOFT_DEG = 1.0 -- planet-shadow edge half-width (the sun disc is 0.27 deg; wider avoids pops)
local SHADOW_AMBIENT = Color3.fromRGB(62, 56, 50) -- warm dim grey
local SHADOW_OUTDOOR_AMBIENT = Color3.fromRGB(112, 100, 88)
local SHADOW_BRIGHTNESS = 0.3 -- what is left of the direct light (moon at night, sun in planet shadow)

-- Lit look
local SPACE_AMBIENT = Color3.fromRGB(12, 12, 16) -- near black: harsh KSP-style shadows
local SPACE_OUTDOOR_AMBIENT = Color3.fromRGB(25, 25, 32)
local SPACE_BRIGHTNESS = 3
local GROUND_AMBIENT = Color3.fromRGB(40, 40, 44) -- sea level, daylight
local GROUND_OUTDOOR_AMBIENT = Color3.fromRGB(128, 128, 132)
local GROUND_BRIGHTNESS = 2.5

-- Environment / sky
local ENVIRONMENT_DIFFUSE_SCALE = 0.4
local ENVIRONMENT_SPECULAR_SCALE = 0.6
local FOG_END = 1e6
local STAR_COUNT = 3000 -- Roblox's own night stars (ground level at night; SkyCube draws space)
local MOON_ANGULAR_SIZE = 0.5 -- degrees; the disc is hidden anyway (CelestialBodiesShown = false)

-- Write thresholds (avoid touching Lighting properties that did not really change)
local NUMBER_EPSILON = 1e-3
local COLOR_EPSILON = 1 / 512
--============================================================================

type Evaluator = (clock: number, lat: number) -> Vector3

type Solution = { clock: number, lat: number, err: number }

type SolverState = {
	evaluate: Evaluator,
	evals: number, -- evaluations in the current step (for budgets and tests)
	best: Solution?,
	lastTarget: Vector3?,
	badFrames: number, -- consecutive warm frames with error above COLD_ERROR_DEG
	framesSinceCold: number,
	lastColdErr: number, -- error the last cold solve reached (large = the engine cannot reach that direction)
	lastCold: boolean, -- the last step ran a cold search
}

local SkyLighting = {}

local initialized = false
local sky: Sky? = nil

local physicalBodies = Bodies.physicalBodies()
local scratchSun = Vec3d.zero()
local scratchCam = Vec3d.zero()
local scratchDominantAbs = Vec3d.zero()
local scratchOtherAbs = Vec3d.zero()

--============================================================================
-- Pure helpers
--============================================================================

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Angle between two unit vectors in degrees, accurate for small angles (2 asin(|a - b| / 2)).
local function angleDeg(a: Vector3, b: Vector3): number
	local d = (a - b).Magnitude
	return math.deg(2 * math.asin(math.clamp(d * 0.5, 0, 1)))
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- 1 = full shadow-side look (sun at/below the pocket horizon), 0 = lit. Monotonic non-increasing in sunY.
local function horizonShadowFactor(sunY: number): number
	return 1 - smoothstep(HORIZON_Y_DARK, HORIZON_Y_LIT, sunY)
end

--[[
	How much of the sun a sphere hides, seen from a point. p = point relative to the sphere centre, s = unit
	direction toward the sun (same axes, doubles). 1 = sun fully blocked, 0 = clear. Equivalent to a ray-sphere
	test from p along s (hit with t > 0 <=> the angle between s and the centre is below asin(R / |p|)),
	softened over +/-SHADOW_SOFT_DEG. Points below the surface use |p| = R (the geometric horizon).
]]
local function bodyShadowFactor(p: Vec3d, s: Vec3d, radius: number): number
	if radius <= 0 then
		return 0
	end
	local dist = math.sqrt(p.x * p.x + p.y * p.y + p.z * p.z)
	if dist < 1e-6 then
		return 0 -- degenerate: at the centre
	end
	local alpha = if dist <= radius then math.pi / 2 else math.asin(radius / dist)
	local cosTheta = -(p.x * s.x + p.y * s.y + p.z * s.z) / dist
	local theta = math.acos(math.clamp(cosTheta, -1, 1))
	local soft = math.rad(SHADOW_SOFT_DEG)
	return 1 - smoothstep(alpha - soft, alpha + soft, theta)
end

-- Sky.SkyboxOrientation (degrees) for a rotation, assuming the BasePart.Orientation convention (header).
local function skyboxOrientationDegrees(rot: CFrame): Vector3
	local rx, ry, rz = rot:ToOrientation()
	return Vector3.new(math.deg(rx), math.deg(ry), math.deg(rz))
end

-- Inverse of skyboxOrientationDegrees (tests and debugging).
local function skyboxRotationFromDegrees(degrees: Vector3): CFrame
	return CFrame.fromOrientation(math.rad(degrees.X), math.rad(degrees.Y), math.rad(degrees.Z))
end

-- Rotation angle (degrees) between two rotation-only CFrames.
local function rotationDeltaDeg(a: CFrame, b: CFrame): number
	local _, angle = (a:Inverse() * b):ToAxisAngle()
	return math.deg(math.abs(angle))
end

-- Atmosphere factor: 1 at sea level, 0 at/above the top and for bodies without an atmosphere.
local function airFactor(bodyId: number, altitude: number): number
	local body = Bodies.find(bodyId)
	if body == nil or body.Atmosphere == nil then
		return 0
	end
	local top = body.Atmosphere.Top
	if top <= 0 or altitude >= top then
		return 0
	end
	return 1 - math.clamp(altitude / top, 0, 1)
end

--============================================================================
-- Sun solve (evaluator-driven so tests can use a synthetic sun model)
--============================================================================

local function evalErr(state: SolverState, target: Vector3, clock: number, lat: number): number
	state.evals += 1
	return angleDeg(state.evaluate(clock, lat), target)
end

local function wrapClock(clock: number): number
	return clock % 24
end

local function clampLat(lat: number): number
	if LAT_WRAP then
		return (lat + 180) % 360 - 180
	end
	return math.clamp(lat, -LAT_LIMIT, LAT_LIMIT)
end

-- Damped Gauss-Newton on the 3D residual target - dir(clock, lat). Returns the improved solution.
local function refineGaussNewton(
	state: SolverState,
	target: Vector3,
	start: Solution,
	maxIterations: number,
	maxEvals: number
): Solution
	local best = start
	for _ = 1, maxIterations do
		if best.err <= SOLVE_TOLERANCE_DEG or state.evals + 3 > maxEvals then
			break
		end
		local f0 = state.evaluate(best.clock, best.lat)
		local fc = state.evaluate(best.clock + GN_CLOCK_H, best.lat)
		local fl = state.evaluate(best.clock, best.lat + GN_LAT_H)
		state.evals += 3
		local j1 = (fc - f0) / GN_CLOCK_H
		local j2 = (fl - f0) / GN_LAT_H
		local r = target - f0
		local a11 = j1:Dot(j1)
		local a12 = j1:Dot(j2)
		local a22 = j2:Dot(j2)
		local b1 = j1:Dot(r)
		local b2 = j2:Dot(r)
		a11 += GN_DAMPING * a11 + 1e-12
		a22 += GN_DAMPING * a22 + 1e-12
		local det = a11 * a22 - a12 * a12
		if math.abs(det) < 1e-18 then
			break
		end
		local dc = math.clamp((a22 * b1 - a12 * b2) / det, -GN_MAX_CLOCK_STEP, GN_MAX_CLOCK_STEP)
		local dl = math.clamp((a11 * b2 - a12 * b1) / det, -GN_MAX_LAT_STEP, GN_MAX_LAT_STEP)
		local improved = false
		for _ = 0, GN_BACKTRACKS do
			if state.evals >= maxEvals then
				break
			end
			local clock = wrapClock(best.clock + dc)
			local lat = clampLat(best.lat + dl)
			local err = evalErr(state, target, clock, lat)
			if err < best.err then
				best = { clock = clock, lat = lat, err = err }
				improved = true
				break
			end
			dc *= 0.5
			dl *= 0.5
		end
		if not improved then
			break
		end
	end
	return best
end

local PATTERN_DIRECTIONS = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } }

-- Compass pattern search (the S5 spike's refine), bounded by an evaluation budget.
local function refinePattern(
	state: SolverState,
	target: Vector3,
	start: Solution,
	clockStep: number,
	latStep: number,
	maxEvals: number
): Solution
	local best = start
	local cs, ls = clockStep, latStep
	while state.evals + #PATTERN_DIRECTIONS <= maxEvals and best.err > SOLVE_TOLERANCE_DEG do
		local improved = false
		for _, d in PATTERN_DIRECTIONS do
			local clock = wrapClock(best.clock + d[1] * cs)
			local lat = clampLat(best.lat + d[2] * ls)
			local err = evalErr(state, target, clock, lat)
			if err < best.err then
				best = { clock = clock, lat = lat, err = err }
				improved = true
			end
		end
		if not improved then
			cs *= 0.5
			ls *= 0.5
			if cs < 1e-5 then
				break
			end
		end
	end
	return best
end

local function solveCold(state: SolverState, target: Vector3): Solution
	local best: Solution = { clock = 0, lat = 0, err = math.huge }
	for i = 0, COLD_CLOCK_STEPS - 1 do
		local clock = 24 * i / COLD_CLOCK_STEPS
		for j = 0, COLD_LAT_STEPS - 1 do
			local lat = COLD_LAT_MIN + (COLD_LAT_MAX - COLD_LAT_MIN) * j / (COLD_LAT_STEPS - 1)
			local err = evalErr(state, target, clock, lat)
			if err < best.err then
				best = { clock = clock, lat = lat, err = err }
			end
		end
	end
	local budget = state.evals + COLD_REFINE_EVALS
	best = refineGaussNewton(state, target, best, 12, budget)
	if best.err > SOLVE_TOLERANCE_DEG then
		best = refinePattern(
			state,
			target,
			best,
			24 / COLD_CLOCK_STEPS,
			(COLD_LAT_MAX - COLD_LAT_MIN) / (COLD_LAT_STEPS - 1),
			budget
		)
		best = refineGaussNewton(state, target, best, 6, budget + 30)
	end
	return best
end

local function newSolver(evaluate: Evaluator): SolverState
	return {
		evaluate = evaluate,
		evals = 0,
		best = nil,
		lastTarget = nil,
		badFrames = 0,
		framesSinceCold = 0,
		lastColdErr = 0,
		lastCold = false,
	}
end

-- One frame of solving. Returns the solution the caller should apply.
local function solveStep(state: SolverState, target: Vector3): Solution
	state.evals = 0
	state.lastCold = false
	local previous = state.best
	local lastTarget = state.lastTarget
	local needCold = previous == nil
		or lastTarget == nil
		or angleDeg(lastTarget, target) > COLD_JUMP_DEG
		or (
			state.badFrames >= COLD_AFTER_FRAMES
			and (state.lastColdErr <= COLD_ERROR_DEG or state.framesSinceCold >= COLD_COOLDOWN_FRAMES)
		)
	local result: Solution
	if needCold or previous == nil then
		result = solveCold(state, target)
		state.lastCold = true
		state.badFrames = 0
		state.framesSinceCold = 0
		state.lastColdErr = result.err
	else
		local start: Solution = {
			clock = previous.clock,
			lat = previous.lat,
			err = evalErr(state, target, previous.clock, previous.lat),
		}
		result = refineGaussNewton(state, target, start, GN_MAX_ITERATIONS, WARM_MAX_EVALS)
		if result.err > PATTERN_TRIGGER_DEG then
			result = refinePattern(state, target, result, PATTERN_CLOCK_STEP, PATTERN_LAT_STEP, WARM_MAX_EVALS)
		end
		state.framesSinceCold += 1
		if result.err > COLD_ERROR_DEG then
			state.badFrames += 1
		else
			state.badFrames = 0
		end
	end
	state.best = result
	state.lastTarget = target
	return result
end

--============================================================================
-- Engine state
--============================================================================

local function robloxSunDirection(clock: number, lat: number): Vector3
	Lighting.ClockTime = clock
	Lighting.GeographicLatitude = lat
	return Lighting:GetSunDirection()
end

local solver = newSolver(robloxSunDirection)

local function colorChanged(a: Color3, b: Color3): boolean
	return math.abs(a.R - b.R) > COLOR_EPSILON
		or math.abs(a.G - b.G) > COLOR_EPSILON
		or math.abs(a.B - b.B) > COLOR_EPSILON
end

local function numberChanged(a: number, b: number): boolean
	return math.abs(a - b) > NUMBER_EPSILON * math.max(1, math.abs(b))
end

-- Keeps the first child of a class (the template or spike place may have added one) and removes the rest.
local function adoptChild(className: string): Instance
	local kept: Instance? = nil
	for _, child in Lighting:GetChildren() do
		if child.ClassName == className then
			if kept == nil then
				kept = child
			else
				child:Destroy()
			end
		end
	end
	if kept then
		return kept
	end
	local created = Instance.new(className)
	created.Parent = Lighting
	return created
end

function SkyLighting.init()
	if initialized then
		return
	end
	initialized = true

	local newSky = adoptChild("Sky") :: Sky
	newSky.Name = "SkyLightingSky"
	newSky.CelestialBodiesShown = false
	newSky.StarCount = STAR_COUNT
	-- CHANGED (Phase 2a playtest 4): Roblox's skybox stays upright (it is the daytime sky near the ground;
	-- rotating it to universe axes stood the clouds on end). Space is drawn by SkyCube.
	newSky.SkyboxOrientation = Vector3.zero
	newSky.MoonTextureId = ""
	newSky.MoonAngularSize = MOON_ANGULAR_SIZE
	sky = newSky

	-- No Atmosphere at all (header): remove any the place or another script adds.
	for _, child in Lighting:GetChildren() do
		if child:IsA("Atmosphere") then
			child:Destroy()
		end
	end
	Lighting.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Atmosphere") then
			task.defer(child.Destroy, child)
		end
	end)

	Lighting.GlobalShadows = true
	Lighting.EnvironmentDiffuseScale = ENVIRONMENT_DIFFUSE_SCALE
	Lighting.EnvironmentSpecularScale = ENVIRONMENT_SPECULAR_SCALE
	Lighting.FogEnd = FOG_END
	Lighting.Ambient = SPACE_AMBIENT
	Lighting.OutdoorAmbient = SPACE_OUTDOOR_AMBIENT
	Lighting.Brightness = SPACE_BRIGHTNESS
end

local function updateSun(sunDirection: Vector3)
	if sunDirection.Magnitude < 0.5 then
		return -- no valid direction this frame; keep the last solution
	end
	local result = solveStep(solver, sunDirection.Unit)
	-- The last evaluation may not have been the best one: apply the best.
	Lighting.ClockTime = result.clock
	Lighting.GeographicLatitude = result.lat
end

-- Largest planet-shadow factor over all bodies, seen from the camera.
local function planetShadow(ctx: RenderContext.RenderContext): number
	local sun = Frames.vectorFromWorkspace(ctx.frame, ctx.sunDirection, scratchSun)
	local length = Vec3d.length(sun)
	if length < 1e-6 then
		return 0
	end
	Vec3d.set(sun, sun.x / length, sun.y / length, sun.z / length)

	local factor = 0
	local dominant = Bodies.find(ctx.dominantBodyId)
	if dominant then
		factor = bodyShadowFactor(ctx.cameraDominant, sun, dominant.Radius)
	end
	if factor >= 1 then
		return 1
	end
	Universe.bodyPosition(ctx.dominantBodyId, ctx.ut, scratchDominantAbs)
	for _, body in physicalBodies do
		if body.Id ~= ctx.dominantBodyId and body.Radius > 0 then
			-- camera relative to this body = cameraDominant + abs(dominant) - abs(body)
			Universe.bodyPosition(body.Id, ctx.ut, scratchOtherAbs)
			local c = ctx.cameraDominant
			Vec3d.set(
				scratchCam,
				c.x + scratchDominantAbs.x - scratchOtherAbs.x,
				c.y + scratchDominantAbs.y - scratchOtherAbs.y,
				c.z + scratchDominantAbs.z - scratchOtherAbs.z
			)
			factor = math.max(factor, bodyShadowFactor(scratchCam, sun, body.Radius))
		end
	end
	return factor
end

local function updateLighting(air: number, shadow: number)
	local ambient = SPACE_AMBIENT:Lerp(GROUND_AMBIENT, air):Lerp(SHADOW_AMBIENT, shadow)
	local outdoor = SPACE_OUTDOOR_AMBIENT:Lerp(GROUND_OUTDOOR_AMBIENT, air):Lerp(SHADOW_OUTDOOR_AMBIENT, shadow)
	local brightness = lerp(lerp(SPACE_BRIGHTNESS, GROUND_BRIGHTNESS, air), SHADOW_BRIGHTNESS, shadow)
	if colorChanged(Lighting.Ambient, ambient) then
		Lighting.Ambient = ambient
	end
	if colorChanged(Lighting.OutdoorAmbient, outdoor) then
		Lighting.OutdoorAmbient = outdoor
	end
	if numberChanged(Lighting.Brightness, brightness) then
		Lighting.Brightness = brightness
	end
	if Lighting.FogEnd < FOG_END then
		Lighting.FogEnd = FOG_END
	end
end

function SkyLighting.update(ctx: RenderContext.RenderContext)
	if not initialized then
		SkyLighting.init()
	end

	updateSun(ctx.sunDirection)

	local air = airFactor(ctx.dominantBodyId, ctx.altitude)
	local shadow = math.max(horizonShadowFactor(ctx.sunDirection.Y), planetShadow(ctx))
	updateLighting(air, shadow)

	local currentSky = sky
	if currentSky then
		if currentSky.SkyboxOrientation ~= Vector3.zero then
			currentSky.SkyboxOrientation = Vector3.zero
		end
	end
end

-- Test hook: pure helpers only (the Lune suite has no GetSunDirection).
SkyLighting._test = table.freeze({
	smoothstep = smoothstep,
	angleDeg = angleDeg,
	horizonShadowFactor = horizonShadowFactor,
	bodyShadowFactor = bodyShadowFactor,
	skyboxOrientationDegrees = skyboxOrientationDegrees,
	skyboxRotationFromDegrees = skyboxRotationFromDegrees,
	rotationDeltaDeg = rotationDeltaDeg,
	airFactor = airFactor,
	newSolver = newSolver,
	solveStep = solveStep,
})

return SkyLighting
