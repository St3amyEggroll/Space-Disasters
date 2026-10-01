--!strict
--[[
	BaseLayout
	Geometry of the home base (Oopsie Point Launch Complex) in base-pocket coordinates. The base pocket is slot 0
	at the workspace origin and is SURFACE_ALIGNED, so base-pocket coordinates are workspace coordinates.
	Ground level is y = 0.

	CHANGED (Phase 1 rework, Plane Crazy style):
	  * Plots are open, raised baseplates (no hangar building). Two rows of 6 face a central street (spawn in the
	    middle). The build grid is GameConfig.BUILD_VOLUME blocks of GameConfig.GRID_SIZE studs; its origin is the
	    plot baseplate's minimum corner at the baseplate's TOP surface (y = PLOT_TOP).
	  * Launch pads are shared, in a launch area north of the plots. Roll Out puts the craft on a free pad.

	Plots and pads are never rotated, so grid axes = pocket axes. Pure module (no services).
]]

local GameConfig = require(script.Parent.GameConfig)

--============================================================================
-- Tunables
--============================================================================
local GRID = GameConfig.GRID_SIZE
local PLOTS_PER_ROW = 6
local PLOT_PITCH_X = 100 -- studs between neighbouring plot origins along X (80-stud plots + 20-stud gaps)
local STREET_HALF_WIDTH = 50 -- plots start this far from the street centre line
local PLOT_TOP = 1 -- baseplate top surface height (raised 1 stud so it never z-fights the ground)
local PAD_COUNT = GameConfig.LAUNCH_PAD_COUNT
local PAD_PITCH_X = 100
local PAD_SIZE = 88 -- square pad edge (fits the largest 80-stud footprint)
local PAD_HEIGHT = 1 -- pad slab thickness; its top is the launch surface
local LAUNCH_AREA_Z = 280 -- pad centre line (north of the north plot row)
local SPAWN_POSITION = Vector3.new(0, 0, 0)
local SITE_HALF_EXTENT = 420 -- half size of the square ground plate area the site covers
local PLOT_SPAWN_INSET = 6 -- studs from the plot's street edge where players spawn (CHANGED Phase 2a feedback)
--============================================================================

export type PlotInfo = {
	index: number,
	row: number, -- 1 = south row (negative Z), 2 = north row (positive Z)
	buildOrigin: Vector3, -- world position of grid cell (0, 0, 0)'s minimum corner (baseplate top)
	gridSize: Vector3, -- build volume in blocks
	buildSize: Vector3, -- build volume in studs
	center: Vector3, -- centre of the baseplate top
	facingStreet: Vector3, -- unit vector from the plot toward the street
}

export type PadInfo = {
	index: number,
	top: CFrame, -- centre of the pad's top surface, Y up
	size: number,
}

local BaseLayout = {}

BaseLayout.GRID = GRID
BaseLayout.PLOT_COUNT = GameConfig.MAX_PLAYERS
BaseLayout.PAD_COUNT = PAD_COUNT
BaseLayout.SPAWN_POSITION = SPAWN_POSITION
BaseLayout.SITE_HALF_EXTENT = SITE_HALF_EXTENT
BaseLayout.STREET_HALF_WIDTH = STREET_HALF_WIDTH
BaseLayout.PLOT_TOP = PLOT_TOP
BaseLayout.PAD_HEIGHT = PAD_HEIGHT
BaseLayout.PAD_SIZE = PAD_SIZE
BaseLayout.LAUNCH_AREA_Z = LAUNCH_AREA_Z
BaseLayout.GRID_SIZE = Vector3.new(GameConfig.BUILD_VOLUME.X, GameConfig.BUILD_VOLUME.Y, GameConfig.BUILD_VOLUME.Z)
BaseLayout.BUILD_SIZE = BaseLayout.GRID_SIZE * GRID

local plots: { PlotInfo } = {}
for index = 1, BaseLayout.PLOT_COUNT do
	local row = if index <= PLOTS_PER_ROW then 1 else 2
	local column = (index - 1) % PLOTS_PER_ROW
	local studs = BaseLayout.BUILD_SIZE
	local originX = math.floor((column - (PLOTS_PER_ROW - 1) / 2) * PLOT_PITCH_X - studs.X / 2)
	local originZ = if row == 1 then -STREET_HALF_WIDTH - studs.Z else STREET_HALF_WIDTH
	local origin = Vector3.new(originX, PLOT_TOP, originZ)
	plots[index] = table.freeze({
		index = index,
		row = row,
		buildOrigin = origin,
		gridSize = BaseLayout.GRID_SIZE,
		buildSize = studs,
		center = origin + Vector3.new(studs.X / 2, 0, studs.Z / 2),
		facingStreet = if row == 1 then Vector3.new(0, 0, 1) else Vector3.new(0, 0, -1),
	})
end

local pads: { PadInfo } = {}
for index = 1, PAD_COUNT do
	local x = (index - 1 - (PAD_COUNT - 1) / 2) * PAD_PITCH_X
	pads[index] = table.freeze({
		index = index,
		top = CFrame.new(x, PAD_HEIGHT, LAUNCH_AREA_Z),
		size = PAD_SIZE,
	})
end

BaseLayout.Plots = table.freeze(plots)
BaseLayout.Pads = table.freeze(pads)

function BaseLayout.plot(index: number): PlotInfo
	local info = plots[index]
	if info == nil then
		error(`No plot {index}`, 2)
	end
	return info
end

function BaseLayout.pad(index: number): PadInfo
	local info = pads[index]
	if info == nil then
		error(`No pad {index}`, 2)
	end
	return info
end

-- Is a pocket-space point above the plot's baseplate, within the build volume height (plus margins)?
function BaseLayout.isOnPlot(info: PlotInfo, point: Vector3, margin: number?): boolean
	local m = margin or 0
	local p = point - info.buildOrigin
	return p.X >= -m
		and p.X <= info.buildSize.X + m
		and p.Z >= -m
		and p.Z <= info.buildSize.Z + m
		and p.Y >= -4
		and p.Y <= info.buildSize.Y + 8
end

-- Plot index whose area contains the point, or nil.
function BaseLayout.plotAt(point: Vector3): number?
	for _, info in plots do
		if BaseLayout.isOnPlot(info, point) then
			return info.index
		end
	end
	return nil
end

-- World position of a grid point (block units) on a plot.
function BaseLayout.gridToWorld(info: PlotInfo, grid: Vector3): Vector3
	return info.buildOrigin + grid * GRID
end

-- CHANGED (Phase 2a feedback): raised slabs the flight model stands on (rockets now sit on their pad with real
-- physics before ignition). Height (studs above ground level y = 0) of the platform under (x, z), 0 if none.
function BaseLayout.platformHeight(x: number, z: number): number
	local half = PAD_SIZE / 2
	if math.abs(z - LAUNCH_AREA_Z) <= half then
		for _, pad in pads do
			if math.abs(x - pad.top.Position.X) <= half then
				return PAD_HEIGHT
			end
		end
	end
	for _, info in plots do
		local p = info.buildOrigin
		if x >= p.X and x <= p.X + info.buildSize.X and z >= p.Z and z <= p.Z + info.buildSize.Z then
			return PLOT_TOP
		end
	end
	return 0
end

-- Where a player stands when they spawn at their plot: on the baseplate near its street edge, facing the plot.
function BaseLayout.plotSpawn(info: PlotInfo): CFrame
	local position = info.center + info.facingStreet * (info.buildSize.Z / 2 - PLOT_SPAWN_INSET) + Vector3.new(0, 3, 0)
	return CFrame.lookAt(position, position - info.facingStreet)
end

-- Grid position (block units, fractional) of a world point on a plot.
function BaseLayout.worldToGrid(info: PlotInfo, point: Vector3): Vector3
	return (point - info.buildOrigin) / GRID
end

return table.freeze(BaseLayout)
