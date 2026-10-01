--!strict
--[[
	Kepler (Phase 5, spec 5 "Math modules" and 7.8)
	Two-body orbital mechanics in doubles (invariant I1: every position and velocity is a Vec3d). Pure module.

	  propagate(mu, r0, v0, dt)            universal-variable propagation (Curtis, Algorithms 3.3-3.4) with Stumpff
	                                       functions; elliptic, parabolic, hyperbolic and radial orbits. Kepler's
	                                       equation is solved by Newton's method inside a bracket that always
	                                       contains the root (f' = r > 0, so the equation is monotonic); a Newton
	                                       step that leaves the bracket is replaced by bisection. Elliptic orbits
	                                       first reduce dt modulo the period, so ten orbits are as precise as one.
	  elements(mu, r, v)                   orbital elements for display (a, e, i, RAAN, argument of periapsis, true
	                                       anomaly), periapsis / apoapsis radii, period and time to each apsis.
	                                       Robust for near-circular, near-equatorial and radial orbits.
	  stateFromElements(mu, el)            the inverse (tests and tools).
	  findRadiusCrossing / findSphereEntry the first time |r| crosses a radius, or the distance to a moving point
	                                       (a child body) drops below a radius, found by conservative stepping
	                                       (steps never longer than |gap| / max closing speed, so no crossing is
	                                       skipped) and then bisection to SOI_BISECTION_TOLERANCE (0.01 s).
	  conicPoints(mu, r0, v0, t0, t1, n)   n + 1 points along the orbit between two times (map lines), evenly
	                                       spaced in eccentric / hyperbolic anomaly.

	Element angles use a reference frame whose pole is the angular momentum of an eastward ("prograde") orbit.
	In the universe frame (+Y = north pole, longitude grows toward +Z) an eastward orbit has h along -Y, so the
	reference axes are I = +X, J = +Z, K = -Y (right-handed). Prograde equatorial orbits have i = 0 and the Moon's
	orbit is the reference plane. Conventions for undefined angles: equatorial orbits have RAAN = 0 (the node line
	is +X); circular orbits have argPe = 0 and the true anomaly is the argument of latitude; radial orbits have
	i = RAAN = argPe = trueAnomaly = 0.
]]

local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local SERIES_Z = 0.1 -- |z| below this uses the Stumpff power series
local SERIES_TERMS = 8
local NEWTON_MAX_ITERATIONS = 200
local CHI_TOLERANCE = 1e-13 -- relative tolerance on the universal anomaly
local BRACKET_MAX_DOUBLINGS = 400
local PARABOLIC_EPSILON = 1e-10 -- |alpha * r| below this is treated as parabolic
local CIRCULAR_EPSILON = 1e-9 -- eccentricity below this is circular
local EQUATORIAL_EPSILON = 1e-9 -- |node| / |h| below this is equatorial
local RADIAL_EPSILON = 1e-9 -- |h| / (|r| |v|) below this is radial
local CROSSING_TOLERANCE = GameConfig.SOI_BISECTION_TOLERANCE -- s
local MIN_SEARCH_STEP = 0.05 -- s; floor of the conservative search step (grazing passes)
local MAX_SEARCH_ITERATIONS = 20000
--============================================================================

local TWO_PI = 2 * math.pi

export type OrbitKind = "Elliptic" | "Parabolic" | "Hyperbolic"

export type Elements = {
	kind: OrbitKind,
	a: number, -- semi-major axis (m): negative for hyperbolic, math.huge for parabolic
	e: number, -- eccentricity
	p: number, -- semi-latus rectum (m), 0 for radial orbits
	i: number, -- inclination (rad, 0..pi)
	raan: number, -- right ascension of the ascending node (rad, 0..2pi)
	argPe: number, -- argument of periapsis (rad, 0..2pi)
	trueAnomaly: number, -- rad, 0..2pi
	periapsis: number, -- periapsis radius (m)
	apoapsis: number, -- apoapsis radius (m), math.huge when the orbit is open
	period: number, -- s, math.huge when the orbit is open
	meanMotion: number, -- rad/s (0 for parabolic)
	timeSincePeriapsis: number, -- s (negative while approaching periapsis on an open orbit)
	timeToPeriapsis: number?, -- s; nil on an open orbit that has passed periapsis
	timeToApoapsis: number?, -- s; nil unless elliptic
	energy: number, -- specific orbital energy (J/kg)
	h: number, -- specific angular momentum (m^2/s)
	radial: boolean,
	circular: boolean,
	equatorial: boolean,
}

-- Input of stateFromElements: give either p or a (p = a (1 - e^2)).
export type ElementsInput = {
	a: number?,
	p: number?,
	e: number,
	i: number,
	raan: number,
	argPe: number,
	trueAnomaly: number,
}

local Kepler = {}

Kepler.CROSSING_TOLERANCE = CROSSING_TOLERANCE

--============================================================================
-- Reference frame (I = +X, J = +Z, K = -Y; see header)
--============================================================================
local function toRef(v: Vec3d): Vec3d
	return Vec3d.new(v.x, v.z, -v.y)
end

local function fromRef(x: number, y: number, z: number): Vec3d
	return Vec3d.new(x, -z, y)
end

local function wrap2pi(angle: number): number
	local wrapped = angle % TWO_PI
	if wrapped < 0 then
		wrapped += TWO_PI
	end
	return wrapped
end

--============================================================================
-- Stumpff functions
--============================================================================

-- C(z) and S(z) (Curtis eqs. 3.52-3.53), with a power series near z = 0 where the closed forms cancel.
function Kepler.stumpff(z: number): (number, number)
	if z > SERIES_Z then
		local s = math.sqrt(z)
		return (1 - math.cos(s)) / z, (s - math.sin(s)) / (s * s * s)
	elseif z < -SERIES_Z then
		local s = math.sqrt(-z)
		return (math.cosh(s) - 1) / -z, (math.sinh(s) - s) / (s * s * s)
	end
	local c, s = 0, 0
	local termC, termS = 0.5, 1 / 6
	for k = 0, SERIES_TERMS - 1 do
		c += termC
		s += termS
		termC *= -z / ((2 * k + 3) * (2 * k + 4))
		termS *= -z / ((2 * k + 4) * (2 * k + 5))
	end
	return c, s
end

local stumpff = Kepler.stumpff

--============================================================================
-- Propagation
--============================================================================

function Kepler.period(mu: number, a: number): number
	if a <= 0 or a == math.huge then
		return math.huge
	end
	return TWO_PI * math.sqrt(a * a * a / mu)
end

-- Solves the universal Kepler equation for chi (Newton inside a maintained bracket).
local function solveChi(
	alpha: number,
	r0: number,
	vr0: number,
	sqrtMu: number,
	dt: number,
	ellipticPeriodChi: number?
): number
	local A = r0 * vr0 / sqrtMu
	local B = 1 - alpha * r0
	local target = sqrtMu * dt

	local function evaluate(chi: number): (number, number)
		local chi2 = chi * chi
		local z = alpha * chi2
		local c, s = stumpff(z)
		local f = A * chi2 * c + B * chi2 * chi * s + r0 * chi - target
		local fp = A * chi * (1 - z * s) + B * chi2 * c + r0
		return f, fp
	end

	local lo, hi
	local guess: number
	if ellipticPeriodChi then
		-- dt in [0, T): chi in [0, 2 pi sqrt(a)]
		lo, hi = 0, ellipticPeriodChi
		guess = math.clamp(sqrtMu * alpha * dt, 0, ellipticPeriodChi)
	else
		guess = target / r0 -- d(chi)/dt = sqrt(mu) / r
		if dt >= 0 then
			lo = 0
			hi = math.max(guess, 1e-9)
			local doublings = 0
			while (evaluate(hi)) < 0 and doublings < BRACKET_MAX_DOUBLINGS do
				lo = hi
				hi *= 2
				doublings += 1
			end
		else
			hi = 0
			lo = math.min(guess, -1e-9)
			local doublings = 0
			while (evaluate(lo)) > 0 and doublings < BRACKET_MAX_DOUBLINGS do
				hi = lo
				lo *= 2
				doublings += 1
			end
		end
	end

	local chi = guess
	if not (chi > lo and chi < hi) then
		chi = 0.5 * (lo + hi)
	end
	-- Newton with bisection whenever a step leaves the bracket or does not at least halve it (an exponential
	-- hyperbolic equation approached from above would otherwise creep down one anomaly unit per step).
	local previousWidth = hi - lo
	for _ = 1, NEWTON_MAX_ITERATIONS do
		local f, fp = evaluate(chi)
		if f == 0 then
			return chi
		elseif f < 0 then
			lo = chi
		else
			hi = chi
		end
		local width = hi - lo
		local nextChi = chi - f / fp
		if not (nextChi > lo and nextChi < hi) or math.abs(f / fp) > 0.5 * previousWidth then
			nextChi = 0.5 * (lo + hi)
		end
		previousWidth = width
		local scale = math.max(1, math.abs(nextChi))
		if math.abs(nextChi - chi) <= CHI_TOLERANCE * scale then
			return nextChi
		end
		chi = nextChi
		if hi - lo <= CHI_TOLERANCE * scale then
			return chi
		end
	end
	return chi
end

--[[
	State after dt seconds (dt may be negative) on the two-body orbit through (r0, v0) about a body with
	gravitational parameter mu. Returns new Vec3ds (or writes into outR / outV).
]]
function Kepler.propagate(mu: number, r0: Vec3d, v0: Vec3d, dt: number, outR: Vec3d?, outV: Vec3d?): (Vec3d, Vec3d)
	local r = outR or Vec3d.zero()
	local v = outV or Vec3d.zero()
	local r0mag = Vec3d.length(r0)
	if dt == 0 or r0mag == 0 then
		local x, y, z = r0.x, r0.y, r0.z
		local vx, vy, vz = v0.x, v0.y, v0.z
		Vec3d.set(r, x, y, z)
		Vec3d.set(v, vx, vy, vz)
		return r, v
	end
	local v0sq = Vec3d.lengthSq(v0)
	local sqrtMu = math.sqrt(mu)
	local vr0 = Vec3d.dot(r0, v0) / r0mag
	local alpha = 2 / r0mag - v0sq / mu

	local ellipticChi: number? = nil
	local t = dt
	if alpha * r0mag > PARABOLIC_EPSILON then
		local a = 1 / alpha
		local period = TWO_PI * math.sqrt(a * a * a / mu)
		t = dt - period * math.floor(dt / period)
		if t >= period then
			t = 0
		end
		ellipticChi = TWO_PI * math.sqrt(a)
	end

	local chi = solveChi(alpha, r0mag, vr0, sqrtMu, t, ellipticChi)
	local chi2 = chi * chi
	local z = alpha * chi2
	local c, s = stumpff(z)
	local f = 1 - chi2 / r0mag * c
	local g = t - chi2 * chi * s / sqrtMu
	local rx = f * r0.x + g * v0.x
	local ry = f * r0.y + g * v0.y
	local rz = f * r0.z + g * v0.z
	local rmag = math.sqrt(rx * rx + ry * ry + rz * rz)
	local fdot = sqrtMu / (rmag * r0mag) * (z * s - 1) * chi
	local gdot = 1 - chi2 / rmag * c
	local vx = fdot * r0.x + gdot * v0.x
	local vy = fdot * r0.y + gdot * v0.y
	local vz = fdot * r0.z + gdot * v0.z
	Vec3d.set(r, rx, ry, rz)
	Vec3d.set(v, vx, vy, vz)
	return r, v
end

--============================================================================
-- Elements
--============================================================================

function Kepler.elements(mu: number, r: Vec3d, v: Vec3d): Elements
	local rmag = Vec3d.length(r)
	local v2 = Vec3d.lengthSq(v)
	local rv = Vec3d.dot(r, v)
	local energy = 0.5 * v2 - mu / rmag
	local alpha = 2 / rmag - v2 / mu
	local hVec = Vec3d.cross(r, v)
	local hmag = Vec3d.length(hVec)
	local k = v2 - mu / rmag
	local eVec = Vec3d.new((k * r.x - rv * v.x) / mu, (k * r.y - rv * v.y) / mu, (k * r.z - rv * v.z) / mu)
	local e = Vec3d.length(eVec)
	local radial = v2 == 0 or hmag <= RADIAL_EPSILON * rmag * math.sqrt(v2)
	local p = if radial then 0 else hmag * hmag / mu
	if radial then
		e = 1
	end

	local kind: OrbitKind
	if alpha * rmag > PARABOLIC_EPSILON then
		kind = "Elliptic"
	elseif alpha * rmag < -PARABOLIC_EPSILON then
		kind = "Hyperbolic"
	else
		kind = "Parabolic"
	end
	local a = if kind == "Parabolic" then math.huge else 1 / alpha

	local periapsis = if radial then 0 else p / (1 + e)
	local apoapsis = math.huge
	local period = math.huge
	if kind == "Elliptic" then
		apoapsis = 2 * a - periapsis
		period = TWO_PI * math.sqrt(a * a * a / mu)
	end

	-- Angles in the reference frame
	local inclination, raan, argPe, trueAnomaly = 0, 0, 0, 0
	local equatorial = true
	local circular = not radial and e < CIRCULAR_EPSILON
	if not radial then
		local hR = toRef(hVec)
		local hHat = Vec3d.scale(hR, 1 / hmag)
		inclination = math.atan2(math.sqrt(hHat.x * hHat.x + hHat.y * hHat.y), hHat.z) -- acos loses precision near 0
		local nx, ny = -hR.y, hR.x
		local nmag = math.sqrt(nx * nx + ny * ny)
		equatorial = nmag <= EQUATORIAL_EPSILON * hmag
		local nHat = if equatorial then Vec3d.new(1, 0, 0) else Vec3d.new(nx / nmag, ny / nmag, 0)
		raan = if equatorial then 0 else wrap2pi(math.atan2(nHat.y, nHat.x))
		local rR = toRef(r)
		if circular then
			argPe = 0
			trueAnomaly = wrap2pi(math.atan2(Vec3d.dot(hHat, Vec3d.cross(nHat, rR)), Vec3d.dot(nHat, rR)))
		else
			local eR = toRef(eVec)
			argPe = wrap2pi(math.atan2(Vec3d.dot(hHat, Vec3d.cross(nHat, eR)), Vec3d.dot(nHat, eR)))
			trueAnomaly = wrap2pi(math.atan2(Vec3d.dot(hHat, Vec3d.cross(eR, rR)), Vec3d.dot(eR, rR)))
		end
	end

	-- Timing (via eccentric / hyperbolic anomaly from r and r.v: no division by e, so radial orbits work too)
	local meanMotion = 0
	local timeSince = 0
	local timeToPe: number? = nil
	local timeToAp: number? = nil
	if kind == "Elliptic" then
		meanMotion = math.sqrt(mu / (a * a * a))
		local ecosE = 1 - rmag / a
		local esinE = rv / math.sqrt(mu * a)
		local E = math.atan2(esinE, ecosE)
		local M = wrap2pi(E - esinE)
		timeSince = M / meanMotion
		timeToPe = wrap2pi(-M) / meanMotion
		timeToAp = wrap2pi(math.pi - M) / meanMotion
	elseif kind == "Hyperbolic" then
		local absA = -a
		meanMotion = math.sqrt(mu / (absA * absA * absA))
		local esinhF = rv / math.sqrt(mu * absA)
		local F = math.log(esinhF / e + math.sqrt((esinhF / e) ^ 2 + 1)) -- asinh
		local M = esinhF - F
		timeSince = M / meanMotion
		timeToPe = if M < 0 then -M / meanMotion else nil
	else
		local sqrtMu = math.sqrt(mu)
		local D = rv / sqrtMu
		timeSince = (p * D + D * D * D / 3) / (2 * sqrtMu)
		timeToPe = if timeSince < 0 then -timeSince else nil
	end

	return {
		kind = kind,
		a = a,
		e = e,
		p = p,
		i = inclination,
		raan = raan,
		argPe = argPe,
		trueAnomaly = trueAnomaly,
		periapsis = periapsis,
		apoapsis = apoapsis,
		period = period,
		meanMotion = meanMotion,
		timeSincePeriapsis = timeSince,
		timeToPeriapsis = timeToPe,
		timeToApoapsis = timeToAp,
		energy = energy,
		h = hmag,
		radial = radial,
		circular = circular,
		equatorial = equatorial,
	}
end

-- Position and velocity (universe axes) from elements (not for radial orbits: p must be > 0).
function Kepler.stateFromElements(mu: number, el: ElementsInput): (Vec3d, Vec3d)
	local e = el.e
	local p = el.p or ((el.a :: number) * (1 - e * e))
	assert(p > 0, "stateFromElements needs p > 0")
	local nu = el.trueAnomaly
	local cosNu, sinNu = math.cos(nu), math.sin(nu)
	local rp = p / (1 + e * cosNu)
	local px, py = rp * cosNu, rp * sinNu
	local vScale = math.sqrt(mu / p)
	local vx, vy = -vScale * sinNu, vScale * (e + cosNu)

	local cO, sO = math.cos(el.raan), math.sin(el.raan)
	local ci, si = math.cos(el.i), math.sin(el.i)
	local cw, sw = math.cos(el.argPe), math.sin(el.argPe)
	local q11 = cO * cw - sO * sw * ci
	local q12 = -cO * sw - sO * cw * ci
	local q21 = sO * cw + cO * sw * ci
	local q22 = -sO * sw + cO * cw * ci
	local q31 = sw * si
	local q32 = cw * si
	local r = fromRef(q11 * px + q12 * py, q21 * px + q22 * py, q31 * px + q32 * py)
	local v = fromRef(q11 * vx + q12 * vy, q21 * vx + q22 * vy, q31 * vx + q32 * vy)
	return r, v
end

--============================================================================
-- Crossing searches
--============================================================================

--[[
	Upper bound of the speed along the orbit while it stays at or above `floorRadius` (the speed is largest at
	the smallest radius reached; vis-viva).
]]
function Kepler.speedBound(mu: number, r: Vec3d, v: Vec3d, floorRadius: number?): number
	local el = Kepler.elements(mu, r, v)
	local rmin = math.max(el.periapsis, floorRadius or 0)
	local speed2 = Vec3d.lengthSq(v)
	if rmin <= 0 then
		return math.huge
	end
	return math.sqrt(math.max(speed2, 2 * el.energy + 2 * mu / rmin))
end

--[[
	First t in [t0, t1] where gap(t) changes sign from its sign at t0, given an upper bound `rate` of |d gap/dt|.
	Steps of |gap| / rate can never skip a sign change; MIN_SEARCH_STEP bounds the work near grazing passes.
	The crossing is then bisected to `tolerance`; the returned time is on the far side of the crossing.
]]
function Kepler.firstSignChange(
	gap: (number) -> number,
	rate: number,
	t0: number,
	t1: number,
	tolerance: number?
): number?
	local tol = tolerance or CROSSING_TOLERANCE
	local g0 = gap(t0)
	if g0 == 0 then
		return t0
	end
	local positive = g0 > 0
	local minStep = math.max(MIN_SEARCH_STEP, (t1 - t0) / MAX_SEARCH_ITERATIONS)
	local t, g = t0, g0
	local iterations = 0
	while t < t1 and iterations < MAX_SEARCH_ITERATIONS + 10 do
		iterations += 1
		local step = if rate > 0 and rate < math.huge then math.abs(g) / rate else minStep
		step = math.min(math.max(step, minStep), t1 - t)
		local tNext = t + step
		local gNext = gap(tNext)
		if gNext == 0 or (gNext > 0) ~= positive then
			local lo, hi = t, tNext
			while hi - lo > tol do
				local mid = 0.5 * (lo + hi)
				local gm = gap(mid)
				if gm ~= 0 and (gm > 0) == positive then
					lo = mid
				else
					hi = mid
				end
			end
			return hi
		end
		t, g = tNext, gNext
	end
	return nil
end

--[[
	First time dt in [t0, t1] (seconds after the state (r0, v0)) at which |r| crosses `radius`, in whichever
	direction leads away from where the craft is at t0 (outward if inside, inward if outside). `floorRadius`
	(e.g. the body's radius) caps the speed bound for orbits that dive below it. Returns nil if it does not cross.
]]
function Kepler.findRadiusCrossing(
	mu: number,
	r0: Vec3d,
	v0: Vec3d,
	radius: number,
	t0: number,
	t1: number,
	floorRadius: number?,
	tolerance: number?
): number?
	if t1 < t0 then
		return nil
	end
	local start = if t0 == 0 then r0 else Kepler.propagate(mu, r0, v0, t0)
	local startR = Vec3d.length(start)
	local el = Kepler.elements(mu, r0, v0)
	if startR > radius and el.periapsis > radius then
		return nil -- never comes down that far
	end
	if startR < radius and el.kind == "Elliptic" and el.apoapsis < radius then
		return nil -- never gets that high
	end
	local vmax = Kepler.speedBound(mu, r0, v0, floorRadius)
	local radialMax = if el.radial or el.p <= 0 then vmax else el.e * math.sqrt(mu / el.p)
	local rate = math.min(vmax, radialMax * 1.0000001 + 1e-9)
	local r, v = Vec3d.zero(), Vec3d.zero()
	return Kepler.firstSignChange(function(t: number): number
		Kepler.propagate(mu, r0, v0, t, r, v)
		return Vec3d.length(r) - radius
	end, rate, t0, t1, tolerance)
end

--[[
	First time dt in [t0, t1] at which the craft (r0, v0) comes within `sphereRadius` of a moving centre
	`centerAt(dt)` (same frame as r0), whose speed never exceeds `centerSpeed`. Returns t0 if it starts inside.
]]
function Kepler.findSphereEntry(
	mu: number,
	r0: Vec3d,
	v0: Vec3d,
	centerAt: (number) -> Vec3d,
	centerSpeed: number,
	sphereRadius: number,
	t0: number,
	t1: number,
	floorRadius: number?,
	tolerance: number?
): number?
	if t1 < t0 then
		return nil
	end
	local rate = Kepler.speedBound(mu, r0, v0, floorRadius) + centerSpeed
	local r, v = Vec3d.zero(), Vec3d.zero()
	local function gap(t: number): number
		Kepler.propagate(mu, r0, v0, t, r, v)
		return Vec3d.distance(r, centerAt(t)) - sphereRadius
	end
	if gap(t0) <= 0 then
		return t0
	end
	return Kepler.firstSignChange(gap, rate, t0, t1, tolerance)
end

--============================================================================
-- Geometry (map lines)
--============================================================================

type Basis = {
	kind: OrbitKind,
	a: number,
	e: number,
	P: Vec3d, -- unit, toward periapsis (or the start point on a circular orbit)
	Q: Vec3d, -- unit, 90 degrees ahead in the direction of motion
	circular: boolean,
}

local function basisOf(mu: number, r: Vec3d, v: Vec3d): Basis?
	local el = Kepler.elements(mu, r, v)
	if el.radial or el.kind == "Parabolic" then
		return nil
	end
	local h = Vec3d.normalize(Vec3d.cross(r, v))
	local P: Vec3d
	if el.circular then
		P = Vec3d.normalize(r)
	else
		local rmag = Vec3d.length(r)
		local rv = Vec3d.dot(r, v)
		local k = Vec3d.lengthSq(v) - mu / rmag
		P = Vec3d.normalize(Vec3d.new(k * r.x - rv * v.x, k * r.y - rv * v.y, k * r.z - rv * v.z))
	end
	return {
		kind = el.kind,
		a = el.a,
		e = if el.circular then 0 else el.e,
		P = P,
		Q = Vec3d.cross(h, P),
		circular = el.circular,
	}
end

-- Eccentric (elliptic) or hyperbolic anomaly of a point on the orbit described by `basis`.
local function anomalyOf(basis: Basis, mu: number, r: Vec3d, v: Vec3d): number
	if basis.kind == "Elliptic" then
		if basis.circular then
			return math.atan2(Vec3d.dot(r, basis.Q), Vec3d.dot(r, basis.P))
		end
		local a = basis.a
		local ecosE = 1 - Vec3d.length(r) / a
		local esinE = Vec3d.dot(r, v) / math.sqrt(mu * a)
		return math.atan2(esinE, ecosE)
	end
	local esinhF = Vec3d.dot(r, v) / math.sqrt(mu * -basis.a)
	local x = esinhF / basis.e
	return math.log(x + math.sqrt(x * x + 1))
end

--[[
	count + 1 points (relative to the body, universe axes) along the orbit through (r0, v0) from t0 to t1 seconds
	after that state, evenly spaced in eccentric / hyperbolic anomaly (or in time for radial and parabolic
	orbits). An elliptic span of a full period or more returns the closed ellipse (last point = first point).
]]
function Kepler.conicPoints(
	mu: number,
	r0: Vec3d,
	v0: Vec3d,
	t0: number,
	t1: number,
	count: number,
	out: { Vec3d }?
): { Vec3d }
	local points: { Vec3d } = out or {}
	local n = math.max(1, math.floor(count))
	local rs, vs = Kepler.propagate(mu, r0, v0, t0)
	local basis = basisOf(mu, rs, vs)
	local function setPoint(index: number, x: number, y: number, z: number)
		local existing = points[index]
		if existing then
			Vec3d.set(existing, x, y, z)
		else
			points[index] = Vec3d.new(x, y, z)
		end
	end
	if basis == nil then
		for index = 0, n do
			local t = t0 + (t1 - t0) * index / n
			local r = Kepler.propagate(mu, r0, v0, t)
			setPoint(index + 1, r.x, r.y, r.z)
		end
	else
		local b = basis :: Basis
		local startAnomaly = anomalyOf(b, mu, rs, vs)
		local span: number
		local period = Kepler.period(mu, b.a)
		if b.kind == "Elliptic" and t1 - t0 >= period * (1 - 1e-9) then
			span = TWO_PI
		else
			local re, ve = Kepler.propagate(mu, r0, v0, t1)
			local endAnomaly = anomalyOf(b, mu, re, ve)
			if b.kind == "Elliptic" then
				span = wrap2pi(endAnomaly - startAnomaly)
				if span == 0 and t1 > t0 then
					span = TWO_PI
				end
			else
				span = endAnomaly - startAnomaly
			end
		end
		local a, e = b.a, b.e
		local P, Q = b.P, b.Q
		for index = 0, n do
			local anomaly = startAnomaly + span * index / n
			local x, y
			if b.kind == "Elliptic" then
				x = a * (math.cos(anomaly) - e)
				y = a * math.sqrt(math.max(0, 1 - e * e)) * math.sin(anomaly)
			else
				x = a * (math.cosh(anomaly) - e)
				y = -a * math.sqrt(math.max(0, e * e - 1)) * math.sinh(anomaly)
			end
			setPoint(index + 1, P.x * x + Q.x * y, P.y * x + Q.y * y, P.z * x + Q.z * y)
		end
	end
	for index = #points, n + 2, -1 do
		points[index] = nil
	end
	return points
end

return table.freeze(Kepler)
