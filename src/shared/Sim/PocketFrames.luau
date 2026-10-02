--!strict
--[[
	PocketFrames (Phase 6, spec 7.5 / 7.9)
	The reference of a SOLO pocket: the pocket an astronaut on EVA gets when he floats away from every craft. Pure
	module (no services, no Instances): the server (PocketService, BubbleService) and every client (PocketController,
	Puppets) compute the same frame from the same pocket folder attributes, and the Lune suite tests it.

	Two modes (the pocket folder's FrameMode attribute):
	  INERTIAL         in space or high in the air. The reference is a free-falling point: a state (pos, vel) relative
	                   to RefBodyId at RefUT, propagated on its two-body conic (Kepler.propagate), so it follows the
	                   astronaut's orbit and nobody has to stream anything. Deviation from the spec's fixed INERTIAL
	                   axes: the axes are the flight pockets' horizon / sun-facing axes (Universe.pocketRotation, D31),
	                   so Roblox's sky, sun and day / night stay right. The astronaut's own motion lives in universe
	                   axes (Shared/Sim/Eva), so turning axes never move him.
	  SURFACE_ALIGNED  on (or just above) the ground. The reference is a fixed ground point (the feet of the astronaut
	                   when it was made), axes X east / Y = the ground tile's normal / Z north, so walking with
	                   workspace gravity is right (pocket y = 0 is the ground there, like the base pocket).
	The server moves the reference (a rebase, a PocketTransfer in place) when the astronaut drifts more than
	EVA_REBASE_DIST from it, when the mode should change (desiredMode, with hysteresis) and on SOI changes.

	Attributes (toAttributes / fromAttributes): FrameMode, RefBodyId, RefX/RefY/RefZ (m, doubles), RefVX/RefVY/RefVZ
	(m/s), RefUT, RefRot (the axes at RefUT; fixed for SURFACE_ALIGNED).

	API:
	  PocketFrames.solo(mode, bodyId, pos, vel, ut) -> Reference      a reference for an astronaut at pos / vel
	  PocketFrames.referenceAt(ref, ut) -> (Vec3d, Vec3d)              reference position and velocity at ut
	  PocketFrames.rotationAt(ref, pos, ut) -> CFrame                  pocket axes in universe axes
	  PocketFrames.toAttributes(ref) -> { [string]: any }
	  PocketFrames.fromAttributes(get: (name) -> unknown) -> Reference?   nil when anything is missing or not finite
	  PocketFrames.desiredMode(current, feetHeight, groundSpeed) -> Mode
	  PocketFrames.soiAt(ref, ut) -> number                            the SOI body containing the reference at ut
	  PocketFrames.needsRebase(ref, ut, pos) -> boolean                 pos (relative to ref.bodyId) too far away
]]

local Bodies = require(script.Parent.Parent.Config.Bodies)
local Frames = require(script.Parent.Parent.Math.Frames)
local GameConfig = require(script.Parent.Parent.Config.GameConfig)
local Kepler = require(script.Parent.Kepler)
local SurfaceHeight = require(script.Parent.SurfaceHeight)
local Universe = require(script.Parent.Universe)
local Vec3d = require(script.Parent.Parent.Math.Vec3d)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
local REBASE_DIST = GameConfig.EVA_REBASE_DIST -- m
local SURFACE_ENTER_HEIGHT = GameConfig.EVA_SURFACE_ENTER_HEIGHT -- m of the feet above the ground
local SURFACE_EXIT_HEIGHT = GameConfig.EVA_SURFACE_EXIT_HEIGHT
local SURFACE_MAX_SPEED = GameConfig.EVA_SURFACE_MAX_SPEED -- m/s relative to the ground
local SURFACE_EXIT_SPEED = GameConfig.EVA_SURFACE_EXIT_SPEED
local MAX_COORDINATE = 1e12 -- m; attributes beyond this are rejected as garbage
--============================================================================

export type Mode = "INERTIAL" | "SURFACE_ALIGNED"

export type Reference = {
	mode: Mode,
	bodyId: number,
	pos: Vec3d, -- at ut, relative to the body's centre, universe axes
	vel: Vec3d, -- zero for SURFACE_ALIGNED
	ut: number,
	rot: CFrame, -- pocket axes at ut (fixed for SURFACE_ALIGNED)
}

local PocketFrames = {}

local function finite(n: unknown): boolean
	return type(n) == "number" and n == n and math.abs(n) < MAX_COORDINATE
end

--[[
	A reference for an astronaut at pos / vel (relative to bodyId) at ut. INERTIAL: the astronaut's own state.
	SURFACE_ALIGNED: the ground point under him (the tile plane SurfaceHeight uses) with the tile's normal as up.
]]
function PocketFrames.solo(mode: Mode, bodyId: number, pos: Vec3d, vel: Vec3d, ut: number): Reference
	if mode == "SURFACE_ALIGNED" then
		local h, up = SurfaceHeight.height(bodyId, pos)
		local ground = Vec3d.addScaled(pos, up, -h)
		return {
			mode = mode,
			bodyId = bodyId,
			pos = ground,
			vel = Vec3d.zero(),
			ut = ut,
			rot = Frames.surfaceRotation(up),
		}
	end
	local p = Vec3d.clone(pos)
	return {
		mode = mode,
		bodyId = bodyId,
		pos = p,
		vel = Vec3d.clone(vel),
		ut = ut,
		rot = Universe.pocketRotation(bodyId, p, ut),
	}
end

-- Reference position and velocity at ut (relative to ref.bodyId).
function PocketFrames.referenceAt(ref: Reference, ut: number): (Vec3d, Vec3d)
	if ref.mode ~= "INERTIAL" then
		return Vec3d.clone(ref.pos), Vec3d.zero()
	end
	return Kepler.propagate(Bodies.get(ref.bodyId).Mu, ref.pos, ref.vel, ut - ref.ut)
end

-- Pocket axes (in universe axes) when the reference is at pos at ut.
function PocketFrames.rotationAt(ref: Reference, pos: Vec3d, ut: number): CFrame
	if ref.mode ~= "INERTIAL" then
		return ref.rot
	end
	return Universe.pocketRotation(ref.bodyId, pos, ut)
end

function PocketFrames.toAttributes(ref: Reference): { [string]: any }
	return {
		FrameMode = ref.mode,
		RefBodyId = ref.bodyId,
		RefX = ref.pos.x,
		RefY = ref.pos.y,
		RefZ = ref.pos.z,
		RefVX = ref.vel.x,
		RefVY = ref.vel.y,
		RefVZ = ref.vel.z,
		RefUT = ref.ut,
		RefRot = ref.rot,
	}
end

-- Reads a reference from pocket attributes (`get(name)` returns the attribute); nil if missing or malformed.
function PocketFrames.fromAttributes(get: (string) -> unknown): Reference?
	local mode = get("FrameMode")
	if mode ~= "INERTIAL" and mode ~= "SURFACE_ALIGNED" then
		return nil
	end
	local bodyId = get("RefBodyId")
	if type(bodyId) ~= "number" or Bodies.find(bodyId) == nil then
		return nil
	end
	local x, y, z = get("RefX"), get("RefY"), get("RefZ")
	local ut = get("RefUT")
	local rot = get("RefRot")
	if not (finite(x) and finite(y) and finite(z)) or typeof(rot) ~= "CFrame" then
		return nil
	end
	local vx, vy, vz = get("RefVX"), get("RefVY"), get("RefVZ")
	local hasVel = finite(vx) and finite(vy) and finite(vz)
	if mode == "INERTIAL" and not (hasVel and finite(ut)) then
		return nil
	end
	return {
		mode = mode :: Mode,
		bodyId = bodyId,
		pos = Vec3d.new(x :: number, y :: number, z :: number),
		vel = if hasVel and mode == "INERTIAL"
			then Vec3d.new(vx :: number, vy :: number, vz :: number)
			else Vec3d.zero(),
		ut = if finite(ut) then ut :: number else 0,
		rot = Frames.rotationOnly(rot :: CFrame),
	}
end

--[[
	The mode a solo astronaut's pocket should have, with hysteresis: SURFACE_ALIGNED low and slow, INERTIAL high or
	fast, otherwise unchanged. feetHeight = his feet above the ground (m), groundSpeed relative to the ground (m/s).
]]
function PocketFrames.desiredMode(current: Mode, feetHeight: number, groundSpeed: number): Mode
	if feetHeight ~= feetHeight or groundSpeed ~= groundSpeed then
		return current
	end
	if current == "SURFACE_ALIGNED" then
		if feetHeight > SURFACE_EXIT_HEIGHT or groundSpeed > SURFACE_EXIT_SPEED then
			return "INERTIAL"
		end
		return current
	end
	if feetHeight < SURFACE_ENTER_HEIGHT and groundSpeed < SURFACE_MAX_SPEED then
		return "SURFACE_ALIGNED"
	end
	return current
end

-- The SOI body that contains the reference at ut (its own body when nothing changed).
function PocketFrames.soiAt(ref: Reference, ut: number): number
	local pos = PocketFrames.referenceAt(ref, ut)
	local body = Universe.soiTransition(ref.bodyId, pos, ut)
	return body
end

-- Is `pos` (relative to ref.bodyId, at ut) farther than EVA_REBASE_DIST from the reference?
function PocketFrames.needsRebase(ref: Reference, ut: number, pos: Vec3d): boolean
	local refPos = PocketFrames.referenceAt(ref, ut)
	return Vec3d.distance(refPos, pos) > REBASE_DIST
end

return table.freeze(PocketFrames)
