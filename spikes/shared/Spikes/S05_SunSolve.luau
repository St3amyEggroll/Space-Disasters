--!strict
--[[
	S5: Can a solve over Lighting.ClockTime and Lighting.GeographicLatitude reach arbitrary sun directions?

	Automatic part: solves for 300 random unit directions (full sphere), reports the error distribution and
	timing, then tests warm-started tracking of a slowly moving target (what SkyLightingController does each frame).
	Visual part: checks whether a sun BELOW the horizon still lights the scene like daylight (if Roblox switches to
	moonlight/night instead, the pocket frame cannot put the sun below pocket-down without a fallback).
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local SpikeKit = require(script.Parent.Parent.SpikeKit)

--============================================================================
-- Tunables
--============================================================================
local RANDOM_TARGETS = 300
local GRID_CLOCK_STEPS = 48 -- coarse search: every 0.5 h
local GRID_LAT_STEPS = 37 -- every 5 degrees from -90 to 90
local REFINE_ITERATIONS = 60
local TRACK_STEPS = 240 -- warm-start tracking path length
local TRACK_STEP_DEG = 1.0
local TRACK_REFINE_ITERATIONS = 12
local GOOD_ERROR_DEG = 0.5
local SEED = 1234
--============================================================================

type Solution = { clock: number, lat: number, err: number }

local function sunDirFor(clock: number, lat: number): Vector3
	Lighting.ClockTime = clock
	Lighting.GeographicLatitude = lat
	return Lighting:GetSunDirection()
end

local function angleDeg(a: Vector3, b: Vector3): number
	return math.deg(math.acos(math.clamp(a.Unit:Dot(b.Unit), -1, 1)))
end

-- Pattern search around a starting point.
local function refine(
	target: Vector3,
	start: Solution,
	iterations: number,
	clockStep: number,
	latStep: number
): Solution
	local best = start
	local cs, ls = clockStep, latStep
	for _ = 1, iterations do
		local improved = false
		for _, delta in
			{ { cs, 0 }, { -cs, 0 }, { 0, ls }, { 0, -ls }, { cs, ls }, { -cs, -ls }, { cs, -ls }, { -cs, ls } }
		do
			local clock = (best.clock + delta[1]) % 24
			local lat = math.clamp(best.lat + delta[2], -90, 90)
			local err = angleDeg(sunDirFor(clock, lat), target)
			if err < best.err then
				best = { clock = clock, lat = lat, err = err }
				improved = true
			end
		end
		if not improved then
			cs *= 0.5
			ls *= 0.5
		end
	end
	return best
end

local function solveCold(target: Vector3): Solution
	local best: Solution = { clock = 0, lat = 0, err = math.huge }
	for i = 0, GRID_CLOCK_STEPS - 1 do
		local clock = 24 * i / GRID_CLOCK_STEPS
		for j = 0, GRID_LAT_STEPS - 1 do
			local lat = -90 + 180 * j / (GRID_LAT_STEPS - 1)
			local err = angleDeg(sunDirFor(clock, lat), target)
			if err < best.err then
				best = { clock = clock, lat = lat, err = err }
			end
		end
	end
	return refine(target, best, REFINE_ITERATIONS, 24 / GRID_CLOCK_STEPS, 180 / (GRID_LAT_STEPS - 1))
end

local function randomUnit(rng: Random): Vector3
	local z = rng:NextNumber(-1, 1)
	local phi = rng:NextNumber(0, 2 * math.pi)
	local r = math.sqrt(1 - z * z)
	return Vector3.new(r * math.cos(phi), z, r * math.sin(phi))
end

local function percentile(sorted: { number }, p: number): number
	local index = math.clamp(math.ceil(#sorted * p), 1, #sorted)
	return sorted[index]
end

local function runAutomatic(ctx: SpikeKit.ClientContext)
	-- Property ranges: does the engine accept/clamp latitude beyond +/-90?
	Lighting.GeographicLatitude = 135
	ctx.report(string.format("GeographicLatitude set to 135 reads back as %.3f", Lighting.GeographicLatitude))
	Lighting.GeographicLatitude = -135
	ctx.report(string.format("GeographicLatitude set to -135 reads back as %.3f", Lighting.GeographicLatitude))

	-- Does GetSunDirection follow the sun below the horizon, or flip to the moon?
	local below = sunDirFor(0, 0)
	local moon = Lighting:GetMoonDirection()
	ctx.report(
		string.format(
			"Midnight at lat 0: GetSunDirection=(%.3f, %.3f, %.3f) GetMoonDirection=(%.3f, %.3f, %.3f)",
			below.X,
			below.Y,
			below.Z,
			moon.X,
			moon.Y,
			moon.Z
		)
	)

	ctx.status("S5: cold-solving random directions...")
	local rng = Random.new(SEED)
	local errors: { number } = {}
	local worst: Solution = { clock = 0, lat = 0, err = 0 }
	local worstTarget = Vector3.zero
	local good = 0
	local startTime = os.clock()
	for index = 1, RANDOM_TARGETS do
		local target = randomUnit(rng)
		local solution = solveCold(target)
		table.insert(errors, solution.err)
		if solution.err <= GOOD_ERROR_DEG then
			good += 1
		end
		if solution.err > worst.err then
			worst = solution
			worstTarget = target
		end
		if index % 25 == 0 then
			task.wait() -- keep the client responsive
		end
	end
	local coldMs = (os.clock() - startTime) * 1000 / RANDOM_TARGETS
	table.sort(errors)
	ctx.report(
		string.format(
			"Cold solve over %d random directions: median %.4f deg, p95 %.4f deg, max %.4f deg, %d/%d within %.1f deg, %.2f ms per cold solve",
			RANDOM_TARGETS,
			percentile(errors, 0.5),
			percentile(errors, 0.95),
			errors[#errors],
			good,
			RANDOM_TARGETS,
			GOOD_ERROR_DEG,
			coldMs
		)
	)
	ctx.report(
		string.format(
			"Worst target (%.3f, %.3f, %.3f) -> clock %.3f lat %.3f err %.4f deg",
			worstTarget.X,
			worstTarget.Y,
			worstTarget.Z,
			worst.clock,
			worst.lat,
			worst.err
		)
	)

	ctx.status("S5: warm-start tracking...")
	-- Track a target moving along a tilted great circle (covers above and below the horizon).
	local axis = Vector3.new(0.3, 0.2, 1).Unit
	local start = Vector3.new(1, 0.4, 0).Unit
	local current = solveCold(start)
	local trackErrors: { number } = {}
	local trackStart = os.clock()
	for step = 1, TRACK_STEPS do
		local target = CFrame.fromAxisAngle(axis, math.rad(step * TRACK_STEP_DEG)):VectorToWorldSpace(start)
		current.err = angleDeg(sunDirFor(current.clock, current.lat), target)
		current = refine(target, current, TRACK_REFINE_ITERATIONS, 0.25, 2)
		table.insert(trackErrors, current.err)
	end
	local trackMs = (os.clock() - trackStart) * 1000 / TRACK_STEPS
	table.sort(trackErrors)
	ctx.report(
		string.format(
			"Warm-start tracking (%d steps of %.1f deg, %d refine iterations): median %.4f deg, p95 %.4f deg, max %.4f deg, %.3f ms per step",
			TRACK_STEPS,
			TRACK_STEP_DEG,
			TRACK_REFINE_ITERATIONS,
			percentile(trackErrors, 0.5),
			percentile(trackErrors, 0.95),
			trackErrors[#trackErrors],
			trackMs
		)
	)
end

local function buildTestCube(): (Part, Part)
	local cube = Instance.new("Part")
	cube.Name = "S5_Cube"
	cube.Anchored = true
	cube.Size = Vector3.new(8, 8, 8)
	cube.Color = Color3.fromRGB(230, 230, 230)
	cube.Material = Enum.Material.SmoothPlastic
	cube.CFrame = CFrame.new(0, 12, -30)
	cube.Parent = Workspace

	-- Orange marker on the +X face so Steamy knows which face should be lit
	local marker = Instance.new("Part")
	marker.Name = "S5_Marker"
	marker.Anchored = true
	marker.CanCollide = false
	marker.Size = Vector3.new(0.2, 2, 2)
	marker.Color = Color3.fromRGB(255, 120, 0)
	marker.Material = Enum.Material.Neon
	marker.CFrame = cube.CFrame * CFrame.new(4.1, 0, 0)
	marker.Parent = Workspace
	return cube, marker
end

local function solveAndApply(target: Vector3): Solution
	local solution = solveCold(target.Unit)
	Lighting.ClockTime = solution.clock
	Lighting.GeographicLatitude = solution.lat
	return solution
end

local function runVisual(ctx: SpikeKit.ClientContext)
	local cube, marker = buildTestCube()

	ctx.status("S5 visual: walk so you can see the cube's orange-marked side (the +X side). Then answer below.")

	-- Baseline: sun 30 degrees above the horizon, from +X
	local above = solveAndApply(Vector3.new(math.cos(math.rad(30)), math.sin(math.rad(30)), 0))
	ctx.report(string.format("Visual baseline: sun 30 deg above horizon from +X (solve error %.3f deg)", above.err))
	ctx.ask(
		"BASELINE: sun is 30 deg above the horizon on the orange-marked side. Is the marked side of the cube brightly sunlit, with a shadow on the far side?",
		{ "Yes", "No", "Unsure" }
	)

	-- Below the horizon: sun 30 degrees below, still from +X
	local belowSolution = solveAndApply(Vector3.new(math.cos(math.rad(30)), -math.sin(math.rad(30)), 0))
	local readBack = Lighting:GetSunDirection()
	ctx.report(
		string.format(
			"Visual below-horizon: target 30 deg below from +X, solve error %.3f deg, GetSunDirection=(%.3f, %.3f, %.3f)",
			belowSolution.err,
			readBack.X,
			readBack.Y,
			readBack.Z
		)
	)
	ctx.ask(
		"BELOW HORIZON: the sun is now 30 deg BELOW the horizon. How does the scene look?",
		{ "Still daylight, lit from below-side", "Night / moonlight", "Dark but not night", "Unsure" }
	)

	-- Straight down (the extreme a CRAFT_ALIGNED pocket can produce)
	local down = solveAndApply(Vector3.new(0.001, -1, 0))
	ctx.report(string.format("Visual straight down: solve error %.3f deg", down.err))
	ctx.ask("STRAIGHT DOWN: the sun points up from under the floor. Is the scene lit at all (not night)?", {
		"Lit",
		"Night / moonlight",
		"Unsure",
	})

	cube:Destroy()
	marker:Destroy()
end

local spike: SpikeKit.SpikeDef = {
	Id = "S5",
	Title = "Sun direction solve (ClockTime + latitude)",
	Players = 1,
	Instructions = "Automatic for about 10-30 s (the client may stutter), then 3 visual questions about a cube with an orange marker in front of spawn.",
	Server = nil,
	Client = function(ctx: SpikeKit.ClientContext)
		runAutomatic(ctx)
		runVisual(ctx)
	end,
}

return spike
