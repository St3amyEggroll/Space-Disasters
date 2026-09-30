--!strict
-- Fixture designs shared by the craft specs. Parts are stacked bottom-to-top, centred on x = z = 0.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)

local Fixtures = {}

-- Builds a vertical stack; returns the design and the block id of each entry (same order as `types`).
function Fixtures.stack(name: string, types: { string }): (CraftDesign.Design, { number })
	local design = CraftDesign.new(name)
	local ids = {}
	local y = 0
	for index, partId in types do
		local size = Parts.get(partId).Size
		table.insert(design.blocks, {
			id = index,
			type = partId,
			gx = -math.floor(size.X / 2),
			gy = y,
			gz = -math.floor(size.Z / 2),
			rot = 0,
		})
		ids[index] = index
		y += size.Y
	end
	return design, ids
end

function Fixtures.add(
	design: CraftDesign.Design,
	partId: string,
	gx: number,
	gy: number,
	gz: number,
	rot: number?
): number
	local id = #design.blocks + 1
	table.insert(design.blocks, { id = id, type = partId, gx = gx, gy = gy, gz = gz, rot = rot or 0 })
	return id
end

-- The Section 6.2 sanity rocket: engine, long tank, decoupler, pod, parachute (bottom to top).
function Fixtures.sanity(): (CraftDesign.Design, { number })
	return Fixtures.stack("Sanity", { "engine_s", "tank_s_long", "decoupler_s", "pod_mk1", "chute_s" })
end

return Fixtures
