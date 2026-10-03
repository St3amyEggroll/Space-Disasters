--!strict
--[[
	MapBodiesMath (CHANGED (Map planets): new file. Steamy: "planets dont look good" on the map (M))
	The pure maths behind Render/MapBodies, testable offline (MapBodies.spec). No instances, no engine services.

	Night shading. Roblox has one global light and the map shows several bodies around Sol at once, so the map lights
	nothing: its surfaces are flat-lit (SkyLighting's map look) and every planet / moon gets a NIGHT IMAGE drawn over it:
	  brightness(c) = NIGHT_FLOOR + (1 - NIGHT_FLOOR) * smoothstep(TERMINATOR_IN, TERMINATOR_OUT, c)
	                  * (DAY_MIN + (1 - DAY_MIN) * max(c, 0))
	  nightAlpha(c) = 1 - brightness(c)
	with c the cosine between the ground normal and the direction to Sol: a soft terminator, a near-black night half
	and a day half that still falls off toward the terminator (Lambert-like), so the ball looks round.
	CHANGED (Map planets fix): the night shell (a black sphere of 24 patch clones whose MeshPart texture alpha did the
	darkening) showed no night side in Studio. The night is now a GUI image (GUI alpha blending is what the atmosphere
	rim already proved in Studio) on the body's LIMB DISC: a flat disc through the body's point nearest the camera,
	square to the line from the camera to the centre (discFrame). The tangent cone from the camera cuts that plane in
	a circle of radius frontLimbRadius, so the disc's circle lands exactly on the true silhouette, even off the screen
	centre where perspective draws the ball as an oval (a camera-facing billboard is always a screen circle: it missed
	the limb there and drew its ring across the planet). The whole disc lies in front of the ball.
	paintPhase paints the night alpha as seen from the camera, in true perspective (a disc point -> the sphere point on
	the same ray -> its normal), with Sol's in-image direction along +X; the image is turned on screen by
	screenRotation(discSun). It depends only on the angle between Sol and the camera's view of the centre and on
	radius / distance, so it is repainted only when those move (MapBodies), and a few kilobytes cover a body.

	Screen size: pixelRadius is the on-screen radius of a sphere (true limb, not the centre-plane radius).
	nextIconMode switches a body between its ball and a KSP-style icon (dot + name) with hysteresis (ICON_BELOW_PX /
	BALL_ABOVE_PX), so a body at the threshold does not flicker. moonIconHidden hides a moon's icon while its parent's
	icon sits right next to it on screen (the names would overlap).

	Atmosphere rim: an image on the same limb disc, over the night image (CHANGED (Map planets fix): was a
	camera-facing billboard), its ring exactly on the limb, radial profile rimAlpha (paintRim). rimGradient turns a UIGradient toward Sol's direction on screen:
	the sunlit limb bright, the night limb faint, an even ring when Sol is in front of or behind the body.

	Sol's glow: one smooth radial image (paintGlow), replacing stacked discs.

	API:
		MapBodiesMath.brightness(c) / nightAlpha(c): number
		MapBodiesMath.sunDirection(body: Vec3d, sol: Vec3d): Vector3?        unit, doubles subtracted first
		MapBodiesMath.discFrame(cameraPos, centre, radius, up): (CFrame, number)   limb disc (front face toward the
		                                                                     camera) and its limb radius (studs)
		MapBodiesMath.discSun(disc, sun): Vector3                            Sol in the disc's view axes (X right, Y up,
		                                                                     Z toward the camera)
		MapBodiesMath.screenRotation(v): number                              degrees clockwise turning image +X to v
		MapBodiesMath.phaseTable(size, q, out?): PhaseTable                  a night image's per-pixel normals
		MapBodiesMath.paintPhaseFrom(tbl, cosPhi, buf, y0?, y1?)             RGBA8 night image (cosPhi = discSun.Z)
		MapBodiesMath.paintPhase(size, cosPhi, q, buf, y0?, y1?)             both (q = radius / distance)
		MapBodiesMath.silhouetteAspect(offAxis, angularRadius): number       how oval perspective draws a ball
		MapBodiesMath.pixelRadius(distance, radius, tanHalfFov, viewportHeight): number   math.huge when inside
		MapBodiesMath.limbRadius(distance, radius): number                   limb radius in the centre's plane
		MapBodiesMath.frontLimbRadius(distance, radius): number              same in the plane through the front point
		MapBodiesMath.nextIconMode(isIcon, pixelRadius): boolean
		MapBodiesMath.moonIconHidden(parentIsIcon, screenDistance): boolean
		MapBodiesMath.rimGradient(sunCam: Vector3): (rotationDeg, tNight, tDay)
		MapBodiesMath.rimKeypoints(canvas): (number, number)                 gradient positions of the two limbs
		MapBodiesMath.rimAlpha(rho, inner, outer): number                    rho in limb radii
		MapBodiesMath.paintRim(size, color, inner, outer, peak, buf, y0?, y1?)
		MapBodiesMath.glowAlpha(t): number                                   t in glow radii
		MapBodiesMath.paintGlow(size, color, buf, y0?, y1?)
	The painters fill rows y0..y1 (default: all), so a caller can spread an image over several frames.
		MapBodiesMath.RIM_CANVAS, MapBodiesMath.PHASE_CANVAS
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
-- Night shading (preview-checked; scratchpad mapviews)
local NIGHT_FLOOR = 0.02 -- brightness left on the night side (linear light: a dark grey on screen)
local TERMINATOR_IN = -0.06 -- cos(angle to Sol) where the day light starts ...
local TERMINATOR_OUT = 0.25 -- ... and where the soft terminator is over
local DAY_MIN = 0.35 -- day-side brightness at the terminator, rising to 1 under Sol (looks round)
-- CHANGED (Map planets fix): the night image's half-size in limb radii. Its alpha spills just past the limb (over
-- black space, under the rim), so a soft image edge never leaves a lit sliver along the night limb.
local PHASE_CANVAS = 1.04
-- Ball <-> icon (on-screen radius in pixels)
local ICON_BELOW_PX = 4 -- a ball smaller than this becomes an icon ...
local BALL_ABOVE_PX = 6 -- ... and an icon larger than this a ball again
local MOON_MERGE_PX = 26 -- a moon's icon hides closer than this to its parent's icon
-- Atmosphere rim
local RIM_CANVAS = 1.3 -- the rim image's half-size in limb radii (room for the outer glow)
local RIM_OUTER_POWER = 1.4 -- outer falloff exponent (below 2: a long soft tail)
local RIM_MIN = 0.18 -- rim brightness on the night limb (1 on the sunlit limb)
local RIM_WHITEN = 0.3 -- the brightest part of the rim blends this much toward white
-- Sol's glow image
local GLOW_POWER = 1.8 -- falloff exponent of the halo
local GLOW_PEAK = 0.9 -- halo alpha at the centre
local GLOW_CORE = 0.35 -- extra alpha of the bright core ...
local GLOW_CORE_WIDTH = 0.18 -- ... over this fraction of the glow radius
local GLOW_EDGE = 0.9 -- the halo fades to zero between this fraction of its radius and its edge
local GLOW_WHITEN = 0.4 -- the core blends this much toward white
--============================================================================

local MapBodiesMath = {}

local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

local function byte(x: number): number
	return math.clamp(math.floor(x * 255 + 0.5), 0, 255)
end

-- One RGBA8 pixel; r, g, b, a in 0..1.
local function writePixel(buf: buffer, size: number, px: number, py: number, r: number, g: number, b: number, a: number)
	local offset = (py * size + px) * 4
	buffer.writeu8(buf, offset, byte(r))
	buffer.writeu8(buf, offset + 1, byte(g))
	buffer.writeu8(buf, offset + 2, byte(b))
	buffer.writeu8(buf, offset + 3, byte(a))
end

--============================================================================
-- Night shading
--============================================================================

-- Brightness 0..1 of ground whose normal makes cos `c` with the direction to Sol (header).
function MapBodiesMath.brightness(c: number): number
	local day = smoothstep(TERMINATOR_IN, TERMINATOR_OUT, c) * (DAY_MIN + (1 - DAY_MIN) * math.max(c, 0))
	return NIGHT_FLOOR + (1 - NIGHT_FLOOR) * day
end

-- Alpha of the black night image there (CHANGED (Map planets fix): was the night shell).
function MapBodiesMath.nightAlpha(c: number): number
	return 1 - MapBodiesMath.brightness(c)
end

-- Unit direction from a body's centre to Sol's (both relative to the same body, same axes; doubles).
function MapBodiesMath.sunDirection(body: Vec3d, sol: Vec3d): Vector3?
	local x, y, z = sol.x - body.x, sol.y - body.y, sol.z - body.z
	local length = math.sqrt(x * x + y * y + z * z)
	if length < 1e-6 then
		return nil
	end
	return Vector3.new(x / length, y / length, z / length)
end

--[[
	CHANGED (Map planets fix): the limb disc of a body (header): a frame at the body's point nearest the camera whose
	front face (-Z, LookVector) points at the camera and whose +Y follows `up` (the camera's up), and the disc's limb
	radius in studs. A SurfaceGui on the Front face shows image +X to the viewer's right (the frame's -X) and image
	up along +Y.
]]
function MapBodiesMath.discFrame(cameraPos: Vector3, centre: Vector3, radius: number, up: Vector3): (CFrame, number)
	local toCamera = cameraPos - centre
	local axis = toCamera.Unit
	local front = centre + axis * radius
	-- CFrame.lookAt(front, cameraPos, up) built by hand (columns X, Y, Z; Z = -LookVector): the same in Roblox and
	-- in the offline test runner
	local z = -axis
	local x = up:Cross(z)
	if x.Magnitude < 1e-6 then
		x = (if math.abs(z.X) < 0.9 then Vector3.xAxis else Vector3.zAxis):Cross(z)
	end
	x = x.Unit
	local y = z:Cross(x)
	local frame = CFrame.new(front.X, front.Y, front.Z, x.X, y.X, z.X, x.Y, y.Y, z.Y, x.Z, y.Z, z.Z)
	return frame, MapBodiesMath.frontLimbRadius(toCamera.Magnitude, radius)
end

-- Sol's direction `sun` (unit, the map's axes) in a limb disc's view axes: X right and Y up as seen from the camera,
-- Z toward the camera.
function MapBodiesMath.discSun(disc: CFrame, sun: Vector3): Vector3
	local l = disc:VectorToObjectSpace(sun)
	return Vector3.new(-l.X, l.Y, -l.Z)
end

-- Rotation (degrees, clockwise on screen, as ImageLabel.Rotation and UIGradient.Rotation) that turns an image's +X
-- toward the on-screen direction of `v` (X right, Y up). 0 when `v` points straight at or away from the viewer.
function MapBodiesMath.screenRotation(v: Vector3): number
	if math.abs(v.X) + math.abs(v.Y) < 1e-9 then
		return 0
	end
	return math.deg(math.atan2(-v.Y, v.X))
end

--[[
	The sphere point seen at `rho` limb radii from the disc's centre (0..1), for a sphere at q = radius / distance:
	the ray leaves the camera at beta from the axis (tan(beta) = rho * tan(betaMax), sin(betaMax) = q) and meets the
	sphere at gamma from the axis seen from the centre (law of sines, near intersection): gamma = asin(sin(beta) / q)
	- beta. Returns sin(gamma), cos(gamma): the normal's part across the axis and along it (toward the camera).
]]
local function sphereAngles(rho: number, q: number, tanMax: number): (number, number)
	local tanBeta = rho * tanMax
	local beta = math.atan(tanBeta)
	local sinBeta = tanBeta / math.sqrt(1 + tanBeta * tanBeta)
	local gamma = math.asin(math.min(sinBeta / q, 1)) - beta
	return math.sin(gamma), math.cos(gamma)
end

export type PhaseTable = {
	size: number,
	q: number,
	across: { number }, -- per pixel (row-major): the normal's part along image +X (sin(gamma) * x / rho)
	along: { number }, -- per pixel: the normal's part toward the camera (cos(gamma)); OUTSIDE past the image's disc
}

local OUTSIDE = 2 -- `along` value of a pixel outside the night image's disc (a cosine is never 2)

--[[
	The geometry of a night image (size x size, PHASE_CANVAS limb radii to each edge, image rows downward) for a body
	at q = radius / distance: each pixel's sphere normal in the disc's view axes. It only changes with q (zoom, the
	body's distance), so MapBodies keeps it and repaints a new Sol angle from it cheaply (paintPhaseFrom). Past the
	limb the limb's own normal holds out to PHASE_CANVAS.
]]
function MapBodiesMath.phaseTable(size: number, q: number, out: PhaseTable?): PhaseTable
	local s = math.clamp(q, 1e-6, 1 - 1e-6)
	local tanMax = s / math.sqrt(1 - s * s)
	local result: PhaseTable = out or { size = 0, q = 0, across = {}, along = {} }
	result.size, result.q = size, q
	local across, along = result.across, result.along
	local half = size * 0.5
	local index = 0
	for py = 0, size - 1 do
		for px = 0, size - 1 do
			index += 1
			local x = (px + 0.5 - half) / half * PHASE_CANVAS
			local y = (py + 0.5 - half) / half * PHASE_CANVAS
			local rho = math.sqrt(x * x + y * y)
			if rho <= PHASE_CANVAS then
				local sinG, cosG = sphereAngles(math.min(rho, 1), s, tanMax)
				across[index] = if rho > 1e-9 then sinG * x / rho else 0
				along[index] = cosG
			else
				across[index], along[index] = 0, OUTSIDE
			end
		end
	end
	return result
end

-- RGBA8 pixels (black, alpha = nightAlpha) of a night image from its table, rows y0..y1 (default all), for Sol at
-- cos(phi) = cosPhi toward the camera and sin(phi) along image +X. The corners are clear.
function MapBodiesMath.paintPhaseFrom(tbl: PhaseTable, cosPhi: number, buf: buffer, y0: number?, y1: number?)
	local size = tbl.size
	local cosP = math.clamp(cosPhi, -1, 1)
	local sinP = math.sqrt(1 - cosP * cosP)
	local across, along = tbl.across, tbl.along
	for py = y0 or 0, y1 or size - 1 do
		for px = 0, size - 1 do
			local index = py * size + px + 1
			local up = along[index]
			local a = if up == OUTSIDE then 0 else MapBodiesMath.nightAlpha(across[index] * sinP + up * cosP)
			writePixel(buf, size, px, py, 0, 0, 0, a)
		end
	end
end

-- The same in one call (a fresh table): the night image for Sol at cosPhi and the body at q.
function MapBodiesMath.paintPhase(size: number, cosPhi: number, q: number, buf: buffer, y0: number?, y1: number?)
	MapBodiesMath.paintPhaseFrom(MapBodiesMath.phaseTable(size, q), cosPhi, buf, y0, y1)
end

--[[
	CHANGED (Map planets fix): how oval true perspective draws a ball whose centre is `offAxis` radians from the view
	axis and whose angular radius is `angularRadius`: the silhouette is an ellipse, long along the line from the
	screen centre; this is its long / short axis ratio (1 on the axis). It depends on the camera's distance, not on
	its field of view.
]]
function MapBodiesMath.silhouetteAspect(offAxis: number, angularRadius: number): number
	local cosT, sinA = math.cos(offAxis), math.sin(angularRadius)
	local below = cosT * cosT - sinA * sinA
	if below <= 0 then
		return math.huge
	end
	return math.cos(angularRadius) / math.sqrt(below)
end

--============================================================================
-- Screen size, icons
--============================================================================

-- On-screen radius (px) of a sphere `radius` at `distance` (its centre) for a camera with tan(vertical FOV / 2).
function MapBodiesMath.pixelRadius(distance: number, radius: number, tanHalfFov: number, viewportHeight: number): number
	if distance <= radius then
		return math.huge
	end
	local s = radius / distance
	return s / math.sqrt(1 - s * s) / tanHalfFov * viewportHeight * 0.5
end

-- Radius of the limb circle measured in the plane through the centre, facing the camera.
function MapBodiesMath.limbRadius(distance: number, radius: number): number
	local s = math.min(radius / distance, 0.9999)
	return radius / math.sqrt(1 - s * s)
end

-- Same, in the plane through the sphere's point nearest the camera (distance - radius from it).
function MapBodiesMath.frontLimbRadius(distance: number, radius: number): number
	local s = math.min(radius / distance, 0.9999)
	return (distance - radius) * s / math.sqrt(1 - s * s)
end

-- Is the body drawn as an icon? `isIcon`: what it is now; hysteresis between ICON_BELOW_PX and BALL_ABOVE_PX.
function MapBodiesMath.nextIconMode(isIcon: boolean, pixelRadius: number): boolean
	if isIcon then
		return pixelRadius < BALL_ABOVE_PX
	end
	return pixelRadius < ICON_BELOW_PX
end

-- Is a moon's icon hidden? (its parent is an icon this close on screen)
function MapBodiesMath.moonIconHidden(parentIsIcon: boolean, screenDistance: number): boolean
	return parentIsIcon and screenDistance < MOON_MERGE_PX
end

--============================================================================
-- Atmosphere rim
--============================================================================

--[[
	The rim's UIGradient from Sol's direction in camera space (X right, Y up): the rotation (degrees, clockwise on
	screen, as UIGradient.Rotation) that points the gradient's end (offset 1) at Sol, and the transparency of the
	night limb / sunlit limb. The difference follows how much of Sol's direction lies across the screen: Sol in front
	of or behind the body lights the whole limb evenly.
]]
function MapBodiesMath.rimGradient(sunCam: Vector3): (number, number, number)
	local across = math.sqrt(sunCam.X * sunCam.X + sunCam.Y * sunCam.Y)
	local perp = math.clamp(across / math.max(sunCam.Magnitude, 1e-9), 0, 1)
	local rotation = MapBodiesMath.screenRotation(sunCam)
	local nightBright = RIM_MIN + (1 - RIM_MIN) * (0.5 - 0.5 * perp)
	local dayBright = RIM_MIN + (1 - RIM_MIN) * (0.5 + 0.5 * perp)
	return rotation, 1 - nightBright, 1 - dayBright
end

-- Gradient offsets (0..1 across the image) of the two limb points on the gradient's axis.
function MapBodiesMath.rimKeypoints(canvas: number): (number, number)
	return 0.5 - 0.5 / canvas, 0.5 + 0.5 / canvas
end

-- Rim alpha profile (0..1) at `rho` limb radii from the centre: a thin band inside the limb, a soft tail outside.
function MapBodiesMath.rimAlpha(rho: number, inner: number, outer: number): number
	if rho < 1 then
		local u = (1 - rho) / inner
		return math.exp(-u * u)
	end
	return math.exp(-(((rho - 1) / outer) ^ RIM_OUTER_POWER))
end

-- RGBA8 pixels of a rim image (size x size, RIM_CANVAS limb radii to each edge).
function MapBodiesMath.paintRim(
	size: number,
	color: Color3,
	inner: number,
	outer: number,
	peak: number,
	buf: buffer,
	y0: number?,
	y1: number?
)
	local half = size * 0.5
	local r0, g0, b0 = color.R, color.G, color.B
	for py = y0 or 0, y1 or size - 1 do
		for px = 0, size - 1 do
			local dx, dy = (px + 0.5 - half) / half, (py + 0.5 - half) / half
			local rho = math.sqrt(dx * dx + dy * dy) * RIM_CANVAS
			local a = peak * MapBodiesMath.rimAlpha(rho, inner, outer)
			if rho >= RIM_CANVAS then
				a = 0 -- nothing in the corners (the gradient's rotation must never show the image's square)
			end
			local w = RIM_WHITEN * smoothstep(0.5 * peak, peak, a)
			writePixel(buf, size, px, py, r0 + (1 - r0) * w, g0 + (1 - g0) * w, b0 + (1 - b0) * w, a)
		end
	end
end

--============================================================================
-- Sol's glow
--============================================================================

-- Glow alpha (0..1) at `t` glow radii from the centre (0 at and beyond the edge).
function MapBodiesMath.glowAlpha(t: number): number
	if t >= 1 then
		return 0
	end
	local x = math.max(t, 0)
	local core = x / GLOW_CORE_WIDTH
	local a = GLOW_PEAK * (1 - x) ^ GLOW_POWER + GLOW_CORE * math.exp(-core * core)
	return math.clamp(a, 0, 1) * (1 - smoothstep(GLOW_EDGE, 1, x))
end

-- RGBA8 pixels of the glow image (size x size, the glow's radius to each edge).
function MapBodiesMath.paintGlow(size: number, color: Color3, buf: buffer, y0: number?, y1: number?)
	local half = size * 0.5
	local r0, g0, b0 = color.R, color.G, color.B
	for py = y0 or 0, y1 or size - 1 do
		for px = 0, size - 1 do
			local dx, dy = (px + 0.5 - half) / half, (py + 0.5 - half) / half
			local t = math.sqrt(dx * dx + dy * dy)
			local core = t / GLOW_CORE_WIDTH
			local w = GLOW_WHITEN * math.exp(-core * core)
			writePixel(
				buf,
				size,
				px,
				py,
				r0 + (1 - r0) * w,
				g0 + (1 - g0) * w,
				b0 + (1 - b0) * w,
				MapBodiesMath.glowAlpha(t)
			)
		end
	end
end

MapBodiesMath.RIM_CANVAS = RIM_CANVAS
MapBodiesMath.PHASE_CANVAS = PHASE_CANVAS
MapBodiesMath.ICON_BELOW_PX = ICON_BELOW_PX
MapBodiesMath.BALL_ABOVE_PX = BALL_ABOVE_PX

return table.freeze(MapBodiesMath)
