--!strict
--[[
	Gear (Phase 2a remodel)
	Animates landing legs on this client. PartVisuals builds every leg deployed and stores, on each moving part, its
	stowed part-local CFrame (attribute PartVisuals.GEAR_STOWED_ATTRIBUTE). The gear state comes from the craft's
	CraftState.flags (FlightModel.FLAG_GEAR_UP), so the pilot's own simulation and everyone's streamed copies agree.

	Used by PocketController (the real model of the craft whose pocket we are in) and RemoteCraftRenderer (cosmetic
	copies). Both already know the craft's reference frame in workspace each frame.

	API:
		Gear.collect(model, craftFrame) -> { GearPart }   once per model (and again after the server moves it)
		Gear.target(flags) -> number                       1 = deployed, 0 = stowed
		Gear.approach(current, target, dt) -> number       eases the deploy fraction toward the target
		Gear.pose(parts, craftCFrame, fraction)            writes every moving part's CFrame
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FlightModel = require(ReplicatedStorage.Shared.Sim.FlightModel)
local PartVisuals = require(ReplicatedStorage.Shared.Craft.PartVisuals)

--============================================================================
-- Tunables
--============================================================================
local DEPLOY_TIME_S = 1.2 -- seconds for a full stroke
--============================================================================

export type GearPart = {
	part: BasePart,
	blockOffset: CFrame, -- the part's block (its Bounds) relative to the craft reference frame
	deployed: CFrame, -- part-local (Bounds-relative) pose as built
	stowed: CFrame, -- part-local pose when stowed
}

local Gear = {}

-- Finds the moving leg parts of a model. craftFrame = the craft reference frame (workspace) where the model stands
-- right now; part poses are read as built (deployed).
function Gear.collect(model: Model, craftFrame: CFrame): { GearPart }
	local list: { GearPart } = {}
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			local stowed = descendant:GetAttribute(PartVisuals.GEAR_STOWED_ATTRIBUTE)
			local block = descendant.Parent
			local bounds = if block then block:FindFirstChild("Bounds") else nil
			if typeof(stowed) == "CFrame" and bounds and bounds:IsA("BasePart") then
				table.insert(list, {
					part = descendant,
					blockOffset = craftFrame:ToObjectSpace(bounds.CFrame),
					deployed = bounds.CFrame:ToObjectSpace(descendant.CFrame),
					stowed = stowed,
				})
			end
		end
	end
	return list
end

function Gear.target(flags: number?): number
	return if flags and FlightModel.isGearUp(flags) then 0 else 1
end

function Gear.approach(current: number, target: number, dt: number): number
	local step = dt / DEPLOY_TIME_S
	if math.abs(target - current) <= step then
		return target
	end
	return current + (if target > current then step else -step)
end

local function ease(t: number): number
	return t * t * (3 - 2 * t)
end

function Gear.pose(parts: { GearPart }, craftCFrame: CFrame, fraction: number)
	local f = ease(math.clamp(fraction, 0, 1))
	for _, entry in parts do
		local part = entry.part
		if part.Parent ~= nil then
			part.CFrame = craftCFrame * entry.blockOffset * entry.stowed:Lerp(entry.deployed, f)
		end
	end
end

-- True when the part is animated by Gear (callers leave it out of their own moves).
function Gear.isMoving(part: BasePart): boolean
	return typeof(part:GetAttribute(PartVisuals.GEAR_STOWED_ATTRIBUTE)) == "CFrame"
end

return table.freeze(Gear)
