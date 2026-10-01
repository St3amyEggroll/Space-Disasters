--!strict
--[[
	HudData
	The flight HUD's input, produced by FlightController.hudData() every frame while the local player is aboard a
	craft (pilot or passenger), nil otherwise. Pure data: the HUD never reads the simulation directly.
]]

export type StageInfo = {
	stage: number, -- stage number (1 = first to fire)
	dvVac: number, -- m/s left in this stage (current fuel), vacuum
	fuelFraction: number, -- 0..1 fuel left in this stage's burning groups
	isNext: boolean, -- the stage Space will fire next
}

export type HudData = {
	craftName: string,
	isPilot: boolean,
	prelaunch: boolean, -- on the pad; Space launches
	countdown: number?, -- seconds left in the launch countdown, when counting down
	bodyName: string, -- display name of the SOI body
	altitude: number, -- m above sea level
	radarAltitude: number, -- m above the ground under the craft
	verticalSpeed: number, -- m/s (positive = climbing)
	surfaceSpeed: number, -- m/s relative to the surface
	orbitalSpeed: number, -- m/s relative to the body centre (equal to surface speed while planets do not rotate)
	throttle: number, -- 0..1
	sas: boolean,
	twr: number, -- current thrust-to-weight at full throttle on the SOI body's local gravity
	dvRemaining: number, -- m/s vacuum, all remaining stages
	stages: { StageInfo }, -- remaining stages, next first
	burning: boolean,
	inAtmosphere: boolean,
	pressure: number, -- 0..1
	-- CHANGED (Phase 5): orbit and navball
	apoapsis: number?, -- m above sea level; nil on an open (escape) orbit or while landed
	periapsis: number?, -- m above sea level (negative = below the surface); nil while landed
	timeToApoapsis: number?, -- s; nil when not applicable
	timeToPeriapsis: number?, -- s; nil when not applicable (open orbit past periapsis)
	onRails: boolean,
	attitude: CFrame?, -- craft axes -> universe axes (navball); nil hides the navball
	horizon: CFrame?, -- local horizon frame (X east, Y up, Z north) in universe axes
	velocity: Vector3?, -- orbital velocity, universe axes (prograde / retrograde markers)
}

-- ModuleScripts must return exactly one value; this module only exports types.
return table.freeze({})
