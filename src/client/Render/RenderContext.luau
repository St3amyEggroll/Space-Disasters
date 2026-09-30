--!strict
--[[
	RenderContext
	What UniverseRenderer hands every render layer once per frame (RunService.PreRender, after the camera moved).

	All universe quantities are relative to `frame.refBodyId` (the pocket's reference body) unless noted; pocket
	directions are unit Vector3s in pocket (= workspace) axes. Layers must never store true positions in
	Vector3/CFrame (invariant I1); convert with Frames only after subtracting a nearby reference.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Frames = require(ReplicatedStorage.Shared.Math.Frames)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)

export type RenderContext = {
	frame: Frames.Frame, -- current pocket frame (reference body, reference point, rotation, slot origin)
	ut: number, -- render UT
	camera: CFrame, -- workspace camera CFrame
	cameraAbs: Vec3d.Vec3d, -- camera true position relative to frame.refBodyId's centre (doubles)
	dominantBodyId: number, -- body whose SOI contains the camera
	cameraDominant: Vec3d.Vec3d, -- camera true position relative to the dominant body's centre (doubles)
	altitude: number, -- camera altitude above the dominant body's sea level (m)
	sunDirection: Vector3, -- unit, pocket axes, from the camera toward the sun
	pocketId: number, -- current pocket (0 = base)
	drawDistance: number, -- studs: parts much farther than this may be culled by the engine at the current quality
	dt: number, -- seconds since the previous frame
}

-- ModuleScripts must return exactly one value; this module only exports types.
return table.freeze({})
