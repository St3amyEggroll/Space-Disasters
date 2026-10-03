--!strict
--[[
	StarterCraft (new file, Solar system; D51)
	The default starter rocket the admin panel spawns when the player's hangar holds nothing that can fly (empty, no
	Command Pod, or loose blocks): the Section 6.2 sanity rocket, stacked bottom to top: Small Engine, Long Small
	Tank, Decoupler, Command Pod, Parachute (~4.15 t, ~2,100 m/s of delta-v, TWR ~2.9 on Earth). Pure module.

	API:
	  StarterCraft.design() -> CraftDesign.Design   a fresh copy, centred on the grid's x = z = 0 column
]]

local CraftDesign = require(script.Parent.CraftDesign)
local Parts = require(script.Parent.Parent.Config.Parts)

--============================================================================
-- Tunables
--============================================================================
local NAME = "Starter Rocket"
local STACK = { "engine_s", "tank_s_long", "decoupler_s", "pod_mk1", "chute_s" } -- bottom to top
--============================================================================

local StarterCraft = {}

function StarterCraft.design(): CraftDesign.Design
	local design = CraftDesign.new(NAME)
	local y = 0
	for index, partId in STACK do
		local size = Parts.get(partId).Size
		table.insert(design.blocks, {
			id = index,
			type = partId,
			gx = -math.floor(size.X / 2),
			gy = y,
			gz = -math.floor(size.Z / 2),
			rot = 0,
		})
		y += size.Y
	end
	return design
end

return table.freeze(StarterCraft)
