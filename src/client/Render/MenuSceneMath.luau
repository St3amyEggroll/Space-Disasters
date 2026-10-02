--!strict
--[[
	MenuSceneMath (Phase 11)
	Pure maths for the main menu's space scene (Render/MenuScene): where the menu camera floats above Earth and how
	it is turned, so that Earth fills the lower part of the screen, Sol sits near a chosen screen point (for the
	glare) and the Mun drifts near another; plus the small screen-space helpers for the drifting junk and the lens
	flare. No services and no Instances, so the offline Lune suite tests it (src/server/Tests/MenuSceneMath.spec.luau).

	Camera space: x = right, y = up, z = forward. A direction's screen angles are
	  azimuth   = atan2(x, z)                 (positive = right of the screen centre)
	  elevation = atan2(y, sqrt(x^2 + z^2))   (positive = above it)
	Screen points are normalised: nx, ny in [-1, 1] from the screen centre to its right / top edge; with the
	camera's tan(half field of view) per axis they become screen angles (screenAngles).

	The view solve (solveView), for a viewpoint at distance D from Earth's centre (radius R):
	  * the camera is pitched down from the local horizontal by pitch = acos(R / D) + limbAngle, so Earth's limb
	    (horizon) sits limbAngle (negative = below) from the screen centre, in the centre column;
	  * for the sun to show at screen angles (A, E) the local "up" u must satisfy dot(sun, u) = k with
	    k = cos(pitch) sin(E) - sin(pitch) cos(E) cos(A): u lies on a cone around the sun. `alpha` picks the point on
	    that cone (it moves the viewpoint around Earth without moving the sun on screen);
	  * the heading h (horizontal, perpendicular to u) then follows from the sun's azimuth, and
	      forward = cos(pitch) h - sin(pitch) u,  up = sin(pitch) h + cos(pitch) u,  right = forward x up.
	The menu chooses alpha to bring the Mun near its target screen point (munScore / bestAlpha / refineAlpha).

	API (universe vectors are Vec3d; angles in radians):
	  MenuSceneMath.screenAngles(nx, ny, tanHalfX, tanHalfY) -> (azimuth, elevation)
	  MenuSceneMath.horizonDip(radius, distance) -> number        angle of the horizon below the local horizontal
	  MenuSceneMath.pitchFor(radius, distance, limbAngle) -> number
	  MenuSceneMath.solveView(params, alpha) -> View?             nil only for a degenerate sun target
	  MenuSceneMath.cameraAngles(view, dir) -> (azimuth, elevation)   dir: unit, universe axes
	  MenuSceneMath.cameraDirection(view, azimuth, elevation) -> Vec3d
	  MenuSceneMath.munScore(params, view) -> number              radians off the Mun target (+ penalties)
	  MenuSceneMath.bestAlpha(params, samples?) -> number         global search (menu open)
	  MenuSceneMath.refineAlpha(params, alpha, maxStep) -> number local, rate-limited tracking (every frame)
	  MenuSceneMath.discOcclusion(dir, centreDir, angularRadius, soft) -> number   0 = clear, 1 = fully behind
	  MenuSceneMath.halfExtents(depth, tanHalfX, tanHalfY) -> (halfWidth, halfHeight)  visible area at a depth
	  MenuSceneMath.edgeFade(x, y, width, height, margin) -> number   1 inside, fading to 0 at the screen edges
	  MenuSceneMath.flarePoint(sunX, sunY, centreX, centreY, t) -> (x, y)   along the line sun -> centre
	  MenuSceneMath.smoothstep(edge0, edge1, x) -> number
	  MenuSceneMath.timeOffset(separationAt, span, step, minAngle, maxAngle) -> number
	      CHANGED (Phase 11 review): the menu's own time offset, so the Mun can be on screen (see the function)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local DEGENERATE = 1e-6 -- horizontal sun component below this: the sun target is straight up / down (no heading)
local DEFAULT_ALPHA_SAMPLES = 120 -- global search resolution (3 degrees)
local REFINE_PROBE = math.rad(0.5) -- finite step of the local search
local OCCLUDED_PENALTY = math.pi -- added to the score when Earth hides the Mun
local BEHIND_PENALTY = math.pi -- added when the Mun is behind the camera
--============================================================================

export type ViewParams = {
	earthRadius: number, -- m
	distance: number, -- m, viewpoint to Earth's centre
	sunDir: Vec3d, -- unit, universe axes
	munPos: Vec3d, -- the Mun's centre relative to Earth's centre (m, universe axes)
	munRadius: number, -- m
	pitch: number, -- rad, camera tilt below the local horizontal (pitchFor)
	sunAzimuth: number, -- rad, wanted screen angles of the sun
	sunElevation: number,
	munAzimuth: number, -- rad, wanted screen angles of the Mun
	munElevation: number,
}

export type View = {
	up: Vec3d, -- unit local vertical at the viewpoint (away from Earth's centre)
	pos: Vec3d, -- viewpoint relative to Earth's centre (m)
	right: Vec3d, -- camera axes, unit, universe axes
	cameraUp: Vec3d,
	forward: Vec3d,
}

local MenuSceneMath = {}

function MenuSceneMath.smoothstep(edge0: number, edge1: number, x: number): number
	if edge1 <= edge0 then
		return if x >= edge1 then 1 else 0
	end
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

--[[
	CHANGED (Phase 11 review): alpha never changes the sun / Mun angle, and with the sun pinned at the top right only
	about half of every synodic cycle puts the Mun where the screen can show it (and near new Mun it is dark). The
	menu therefore shows the universe at its own time: `separationAt(offset)` gives the Earth-centred sun / Mun angle
	(radians) `offset` seconds from now; the result is the first offset 0, step, 2 step, ... (up to span) whose angle
	lies in [minAngle, maxAngle], or 0 when none does (or step <= 0).
]]
function MenuSceneMath.timeOffset(
	separationAt: (offset: number) -> number,
	span: number,
	step: number,
	minAngle: number,
	maxAngle: number
): number
	if step <= 0 then
		return 0
	end
	for index = 0, math.floor(math.max(span, 0) / step) do
		local offset = index * step
		local angle = separationAt(offset)
		if angle >= minAngle and angle <= maxAngle then
			return offset
		end
	end
	return 0
end

function MenuSceneMath.screenAngles(nx: number, ny: number, tanHalfX: number, tanHalfY: number): (number, number)
	local x = nx * tanHalfX
	local y = ny * tanHalfY
	return math.atan2(x, 1), math.atan2(y, math.sqrt(x * x + 1))
end

function MenuSceneMath.horizonDip(radius: number, distance: number): number
	return math.acos(math.clamp(radius / math.max(distance, radius), -1, 1))
end

function MenuSceneMath.pitchFor(radius: number, distance: number, limbAngle: number): number
	return MenuSceneMath.horizonDip(radius, distance) + limbAngle
end

-- Any unit vector perpendicular to `v` (unit).
local function perpendicular(v: Vec3d): Vec3d
	local axis = if math.abs(v.y) < 0.9 then Vec3d.new(0, 1, 0) else Vec3d.new(1, 0, 0)
	return Vec3d.normalize(Vec3d.cross(v, axis))
end

function MenuSceneMath.solveView(params: ViewParams, alpha: number): View?
	local s = params.sunDir
	local pitch = params.pitch
	local cT, sT = math.cos(pitch), math.sin(pitch)
	local cE, sE = math.cos(params.sunElevation), math.sin(params.sunElevation)
	local cA, sA = math.cos(params.sunAzimuth), math.sin(params.sunAzimuth)

	-- local up on the cone dot(s, u) = k around the sun
	local k = math.clamp(cT * sE - sT * cE * cA, -1, 1)
	local ring = math.sqrt(math.max(0, 1 - k * k))
	if ring < DEGENERATE then
		return nil
	end
	local e1 = perpendicular(s)
	local e2 = Vec3d.cross(s, e1)
	local u = Vec3d.new(
		k * s.x + ring * (math.cos(alpha) * e1.x + math.sin(alpha) * e2.x),
		k * s.y + ring * (math.cos(alpha) * e1.y + math.sin(alpha) * e2.y),
		k * s.z + ring * (math.cos(alpha) * e1.z + math.sin(alpha) * e2.z)
	)
	u = Vec3d.normalize(u)

	-- heading: the sun's horizontal direction turned by beta about u
	local horizontal = Vec3d.addScaled(s, u, -Vec3d.dot(s, u))
	local n1 = Vec3d.normalize(horizontal)
	local m = Vec3d.cross(u, n1)
	local beta = math.atan2(cE * sA, cE * cA * cT + sT * sE)
	local h = Vec3d.normalize(Vec3d.add(Vec3d.scale(n1, math.cos(beta)), Vec3d.scale(m, math.sin(beta))))

	local forward = Vec3d.normalize(Vec3d.add(Vec3d.scale(h, cT), Vec3d.scale(u, -sT)))
	local cameraUp = Vec3d.normalize(Vec3d.add(Vec3d.scale(h, sT), Vec3d.scale(u, cT)))
	local right = Vec3d.cross(forward, cameraUp)
	return {
		up = u,
		pos = Vec3d.scale(u, params.distance),
		right = right,
		cameraUp = cameraUp,
		forward = forward,
	}
end

function MenuSceneMath.cameraAngles(view: View, dir: Vec3d): (number, number)
	local x = Vec3d.dot(dir, view.right)
	local y = Vec3d.dot(dir, view.cameraUp)
	local z = Vec3d.dot(dir, view.forward)
	return math.atan2(x, z), math.atan2(y, math.sqrt(x * x + z * z))
end

function MenuSceneMath.cameraDirection(view: View, azimuth: number, elevation: number): Vec3d
	local ce = math.cos(elevation)
	local x, y, z = ce * math.sin(azimuth), math.sin(elevation), ce * math.cos(azimuth)
	return Vec3d.new(
		x * view.right.x + y * view.cameraUp.x + z * view.forward.x,
		x * view.right.y + y * view.cameraUp.y + z * view.forward.y,
		x * view.right.z + y * view.cameraUp.z + z * view.forward.z
	)
end

function MenuSceneMath.munScore(params: ViewParams, view: View): number
	local toMun = Vec3d.sub(params.munPos, view.pos)
	local distance = Vec3d.length(toMun)
	if distance <= params.munRadius then
		return OCCLUDED_PENALTY + BEHIND_PENALTY
	end
	local dir = Vec3d.scale(toMun, 1 / distance)
	local target = MenuSceneMath.cameraDirection(view, params.munAzimuth, params.munElevation)
	local score = Vec3d.angle(dir, target)
	if Vec3d.dot(dir, view.forward) <= 0 then
		score += BEHIND_PENALTY
	end
	-- Earth's disc, seen from the viewpoint (its centre is straight down)
	local earthAngle = math.asin(math.clamp(params.earthRadius / params.distance, 0, 1))
	local munAngle = math.asin(math.clamp(params.munRadius / distance, 0, 1))
	local toEarth = Vec3d.scale(view.up, -1)
	if Vec3d.angle(dir, toEarth) < earthAngle + munAngle then
		local earthDistance = params.distance * math.cos(earthAngle)
		if distance > earthDistance then
			score += OCCLUDED_PENALTY
		end
	end
	return score
end

local function scoreAt(params: ViewParams, alpha: number): number
	local view = MenuSceneMath.solveView(params, alpha)
	if view == nil then
		return math.huge
	end
	return MenuSceneMath.munScore(params, view)
end

function MenuSceneMath.bestAlpha(params: ViewParams, samples: number?): number
	local count = math.max(samples or DEFAULT_ALPHA_SAMPLES, 1)
	local best, bestScore = 0, math.huge
	for index = 0, count - 1 do
		local alpha = index / count * 2 * math.pi
		local score = scoreAt(params, alpha)
		if score < bestScore then
			best, bestScore = alpha, score
		end
	end
	return best
end

function MenuSceneMath.refineAlpha(params: ViewParams, alpha: number, maxStep: number): number
	local here = scoreAt(params, alpha)
	local before = scoreAt(params, alpha - REFINE_PROBE)
	local after = scoreAt(params, alpha + REFINE_PROBE)
	if here <= before and here <= after then
		return alpha
	end
	-- move downhill, at most maxStep, by the local slope (in score per radian) times a unit gain
	local slope = (after - before) / (2 * REFINE_PROBE)
	local step = math.clamp(-slope, -maxStep, maxStep)
	if step == 0 then
		step = if after < before then maxStep else -maxStep
	end
	local candidate = alpha + step
	if scoreAt(params, candidate) < here then
		return candidate
	end
	return if after < before then alpha + REFINE_PROBE else alpha - REFINE_PROBE
end

function MenuSceneMath.discOcclusion(dir: Vec3d, centreDir: Vec3d, angularRadius: number, soft: number): number
	local angle = Vec3d.angle(dir, centreDir)
	return 1 - MenuSceneMath.smoothstep(angularRadius - soft, angularRadius + soft, angle)
end

function MenuSceneMath.halfExtents(depth: number, tanHalfX: number, tanHalfY: number): (number, number)
	return depth * tanHalfX, depth * tanHalfY
end

function MenuSceneMath.edgeFade(x: number, y: number, width: number, height: number, margin: number): number
	if width <= 0 or height <= 0 then
		return 0
	end
	local inside = math.min(x, width - x, y, height - y)
	if margin <= 0 then
		return if inside >= 0 then 1 else 0
	end
	return math.clamp(inside / margin, 0, 1)
end

function MenuSceneMath.flarePoint(
	sunX: number,
	sunY: number,
	centreX: number,
	centreY: number,
	t: number
): (number, number)
	return sunX + (centreX - sunX) * t, sunY + (centreY - sunY) * t
end

return table.freeze(MenuSceneMath)
