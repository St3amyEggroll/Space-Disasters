--!strict
--[[
	BaseLayout
	Geometry of the home base (Oopsie Point Launch Complex) in base-pocket coordinates. The base pocket is slot 0
	at the workspace origin and is SURFACE_ALIGNED, so base-pocket coordinates are workspace coordinates.
	Ground level is y = 0.

	Plots sit in two rows facing a central street (spawn in the middle). Each plot is a hangar build area of
	GameConfig.BUILD_VOLUME (40 x 120 x 40) whose grid origin is the hangar's minimum corner at floor level, and
	a launch pad behind the hangar (away from the street). Plots are never rotated, so plot-grid axes = pocket axes.

	Pure module (no services): used by the server (PlotService, BuildService, CraftService), the client
	(BuildController) and the HomeBase site builder.
]]

local GameConfig = require(script.Parent.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local PLOTS_PER_ROW = 6
local PLOT_PITCH_X = 100 -- studs between neighbouring plot origins along X
local ROW_OFFSET_Z = 160 -- distance from the street centre line to the hangar's street-side edge
local PAD_GAP = 20 -- studs between the hangar's back edge and the pad's near edge
local PAD_SIZE = 44 -- square pad edge length
local PAD_HEIGHT = 1 -- pad slab thickness; its top is the launch surface
local SPAWN_POSITION = Vector3.new(0, 0, 0)
local SITE_HALF_EXTENT = 420 -- half size of the square ground plate area the site covers
--============================================================================

export type PlotInfo = {
	index: number,
	row: number, -- 1 = south row (negative Z), 2 = north row (positive Z)
	buildOrigin: Vector3, -- minimum corner of the build grid (integer studs), at floor level y = 0
	buildSize: Vector3, -- GameConfig.BUILD_VOLUME
	hangarCenter: Vector3, -- centre of the build volume footprint at floor level
	padTop: CFrame, -- centre of the pad's top surface, Y up
	padSize: number,
	facingStreet: Vector3, -- unit vector from the hangar toward the street
}

local BaseLayout = {}

BaseLayout.PLOT_COUNT = GameConfig.MAX_PLAYERS
BaseLayout.SPAWN_POSITION = SPAWN_POSITION
BaseLayout.SITE_HALF_EXTENT = SITE_HALF_EXTENT
BaseLayout.PAD_HEIGHT = PAD_HEIGHT
BaseLayout.BUILD_SIZE = Vector3.new(GameConfig.BUILD_VOLUME.X, GameConfig.BUILD_VOLUME.Y, GameConfig.BUILD_VOLUME.Z)

local plots: { PlotInfo } = {}

for index = 1, BaseLayout.PLOT_COUNT do
	local row = if index <= PLOTS_PER_ROW then 1 else 2
	local column = (index - 1) % PLOTS_PER_ROW
	local size = BaseLayout.BUILD_SIZE
	local originX = (column - (PLOTS_PER_ROW - 1) / 2) * PLOT_PITCH_X - size.X / 2
	local originZ: number
	local padCenterZ: number
	local facing: Vector3
	if row == 1 then
		-- south row: street side is +Z (the hangar's max-Z edge), pad further south
		originZ = -ROW_OFFSET_Z - size.Z
		padCenterZ = originZ - PAD_GAP - PAD_SIZE / 2
		facing = Vector3.new(0, 0, 1)
	else
		originZ = ROW_OFFSET_Z
		padCenterZ = originZ + size.Z + PAD_GAP + PAD_SIZE / 2
		facing = Vector3.new(0, 0, -1)
	end
	local origin = Vector3.new(math.floor(originX), 0, originZ)
	plots[index] = table.freeze({
		index = index,
		row = row,
		buildOrigin = origin,
		buildSize = size,
		hangarCenter = origin + Vector3.new(size.X / 2, 0, size.Z / 2),
		padTop = CFrame.new(origin.X + size.X / 2, PAD_HEIGHT, padCenterZ),
		padSize = PAD_SIZE,
		facingStreet = facing,
	})
end

BaseLayout.Plots = table.freeze(plots)

function BaseLayout.plot(index: number): PlotInfo
	local info = plots[index]
	if info == nil then
		error(`No plot {index}`, 2)
	end
	return info
end

-- Is a pocket-space point inside the plot's build volume (x/z footprint, 0..height)?
function BaseLayout.isInsideBuildVolume(info: PlotInfo, point: Vector3): boolean
	local localPoint = point - info.buildOrigin
	return localPoint.X >= 0
		and localPoint.X <= info.buildSize.X
		and localPoint.Z >= 0
		and localPoint.Z <= info.buildSize.Z
		and localPoint.Y >= -2
		and localPoint.Y <= info.buildSize.Y
end

-- Plot index whose build volume contains the point, or nil.
function BaseLayout.plotAt(point: Vector3): number?
	for _, info in plots do
		if BaseLayout.isInsideBuildVolume(info, point) then
			return info.index
		end
	end
	return nil
end

return table.freeze(BaseLayout)
