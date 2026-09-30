--!strict
--[[
	Parts
	Stats for every buildable part. Visuals live separately in Shared/Craft/PartVisuals so meshes can be swapped in later.

	Engine rules (KSP-style):
	  mdot   = ThrustVac / (IspVac * g0)              constant fuel flow at full throttle
	  thrust = mdot * Isp(p) * g0                     Isp lerps IspVac -> IspAsl by pressure ratio (rho / rho0)
	  Solid boosters (Throttleable = false) ignore the throttle.

	Units: Size in studs (integer grid, = meters), masses in kg, thrust in N, torque in N*m, areas in m^2.
	Pure module (no services).
]]

--============================================================================
-- Tunables
--============================================================================
local DEFAULT_UNLOCK = "starter" -- every v1 part is unlocked from the start (progression is Backlog)
local DEFAULT_DRAG_FACTOR = 1
--============================================================================

export type Category = "Command" | "FuelTank" | "Engine" | "Coupling" | "Aero" | "Utility" | "Structural"

export type EngineStats = {
	ThrustVac: number, -- N
	IspVac: number, -- s
	IspAsl: number, -- s
	GimbalDeg: number,
	Throttleable: boolean,
}

export type DecouplerStats = {
	Impulse: number, -- N*s applied to each side on separation
	Radial: boolean,
}

export type ChuteStats = {
	SemiCdA: number, -- m^2
	FullCdA: number, -- m^2
	MaxDeploySpeed: number, -- m/s
	FullAltitude: number, -- m above the surface
}

export type LegStats = {
	Spring: number, -- N/m
	Damper: number, -- N*s/m
}

export type FinStats = {
	Area: number, -- m^2
	LiftCoef: number,
}

export type PartDef = {
	Id: string,
	DisplayName: string,
	Category: Category,
	Size: Vector3, -- studs, integer grid
	DryMass: number, -- kg
	FuelMass: number, -- kg (0 when the part holds no fuel)
	Engine: EngineStats?,
	Torque: number, -- N*m of reaction-wheel torque (0 for none)
	Seats: number, -- number of seats (0 for none)
	PilotSeat: boolean, -- the first seat is a pilot seat
	Walkable: boolean, -- has a walkable interior
	Hatch: boolean,
	Windows: boolean,
	Climbable: boolean, -- rendered as a TrussPart
	Decoupler: DecouplerStats?,
	Chute: ChuteStats?,
	Leg: LegStats?,
	Fin: FinStats?,
	DragFactor: number, -- nose cones reduce drag when leading
	CrashTolerance: number, -- m/s impact speed that destroys the part
	UnlockId: string,
	SortOrder: number, -- palette order
}

-- Fields every definition may omit; filled with defaults by define().
type PartInput = {
	Id: string,
	DisplayName: string,
	Category: Category,
	Size: Vector3,
	DryMass: number,
	FuelMass: number?,
	Engine: EngineStats?,
	Torque: number?,
	Seats: number?,
	PilotSeat: boolean?,
	Walkable: boolean?,
	Hatch: boolean?,
	Windows: boolean?,
	Climbable: boolean?,
	Decoupler: DecouplerStats?,
	Chute: ChuteStats?,
	Leg: LegStats?,
	Fin: FinStats?,
	DragFactor: number?,
	CrashTolerance: number,
	UnlockId: string?,
}

local CATEGORY_ORDER: { Category } = { "Command", "FuelTank", "Engine", "Coupling", "Aero", "Utility", "Structural" }

local list: { PartDef } = {}
local byId: { [string]: PartDef } = {}

local function isGridInteger(n: number): boolean
	return n >= 1 and n == math.floor(n)
end

local function define(input: PartInput)
	assert(byId[input.Id] == nil, "Duplicate part id " .. input.Id)
	assert(
		isGridInteger(input.Size.X) and isGridInteger(input.Size.Y) and isGridInteger(input.Size.Z),
		"Part size must be positive integers: " .. input.Id
	)
	local def: PartDef = table.freeze({
		Id = input.Id,
		DisplayName = input.DisplayName,
		Category = input.Category,
		Size = input.Size,
		DryMass = input.DryMass,
		FuelMass = input.FuelMass or 0,
		Engine = if input.Engine then table.freeze(input.Engine) else nil,
		Torque = input.Torque or 0,
		Seats = input.Seats or 0,
		PilotSeat = input.PilotSeat or false,
		Walkable = input.Walkable or false,
		Hatch = input.Hatch or false,
		Windows = input.Windows or false,
		Climbable = input.Climbable or false,
		Decoupler = if input.Decoupler then table.freeze(input.Decoupler) else nil,
		Chute = if input.Chute then table.freeze(input.Chute) else nil,
		Leg = if input.Leg then table.freeze(input.Leg) else nil,
		Fin = if input.Fin then table.freeze(input.Fin) else nil,
		DragFactor = input.DragFactor or DEFAULT_DRAG_FACTOR,
		CrashTolerance = input.CrashTolerance,
		UnlockId = input.UnlockId or DEFAULT_UNLOCK,
		SortOrder = #list + 1,
	})
	table.insert(list, def)
	byId[def.Id] = def
end

--============================================================================
-- Command
--============================================================================
define({
	Id = "pod_mk1",
	DisplayName = "Command Pod",
	Category = "Command",
	Size = Vector3.new(6, 5, 6),
	DryMass = 800,
	Torque = 15000,
	Seats = 1,
	PilotSeat = true,
	Windows = true,
	CrashTolerance = 12,
})
define({
	Id = "cabin_l",
	DisplayName = "Crew Cabin",
	Category = "Command",
	Size = Vector3.new(10, 8, 10),
	DryMass = 2500,
	Torque = 40000,
	Seats = 4,
	PilotSeat = true,
	Walkable = true,
	Hatch = true,
	Windows = true,
	CrashTolerance = 10,
})

--============================================================================
-- Fuel tanks
--============================================================================
define({
	Id = "tank_s_short",
	DisplayName = "Small Tank",
	Category = "FuelTank",
	Size = Vector3.new(6, 4, 6),
	DryMass = 250,
	FuelMass = 1000,
	CrashTolerance = 7,
})
define({
	Id = "tank_s_long",
	DisplayName = "Small Tank Long",
	Category = "FuelTank",
	Size = Vector3.new(6, 8, 6),
	DryMass = 450,
	FuelMass = 2000,
	CrashTolerance = 7,
})
define({
	Id = "tank_l_short",
	DisplayName = "Large Tank",
	Category = "FuelTank",
	Size = Vector3.new(10, 5, 10),
	DryMass = 900,
	FuelMass = 4000,
	CrashTolerance = 7,
})
define({
	Id = "tank_l_long",
	DisplayName = "Large Tank Long",
	Category = "FuelTank",
	Size = Vector3.new(10, 10, 10),
	DryMass = 1600,
	FuelMass = 8000,
	CrashTolerance = 7,
})

--============================================================================
-- Engines
--============================================================================
define({
	Id = "engine_s",
	DisplayName = "Small Engine",
	Category = "Engine",
	Size = Vector3.new(6, 4, 6),
	DryMass = 700,
	Engine = { ThrustVac = 90000, IspVac = 330, IspAsl = 290, GimbalDeg = 3, Throttleable = true },
	CrashTolerance = 7,
})
define({
	Id = "engine_l",
	DisplayName = "Large Engine",
	Category = "Engine",
	Size = Vector3.new(10, 6, 10),
	DryMass = 2800,
	Engine = { ThrustVac = 400000, IspVac = 320, IspAsl = 280, GimbalDeg = 2, Throttleable = true },
	CrashTolerance = 7,
})
define({
	Id = "srb_s",
	DisplayName = "Solid Booster",
	Category = "Engine",
	Size = Vector3.new(4, 14, 4),
	DryMass = 600,
	FuelMass = 3000,
	Engine = { ThrustVac = 195000, IspVac = 220, IspAsl = 200, GimbalDeg = 0, Throttleable = false },
	CrashTolerance = 8,
})

--============================================================================
-- Coupling
--============================================================================
define({
	Id = "decoupler_s",
	DisplayName = "Small Decoupler",
	Category = "Coupling",
	Size = Vector3.new(6, 1, 6),
	DryMass = 100,
	Decoupler = { Impulse = 500, Radial = false },
	CrashTolerance = 8,
})
define({
	Id = "decoupler_l",
	DisplayName = "Large Decoupler",
	Category = "Coupling",
	Size = Vector3.new(10, 1, 10),
	DryMass = 300,
	Decoupler = { Impulse = 1500, Radial = false },
	CrashTolerance = 8,
})
define({
	Id = "decoupler_r",
	DisplayName = "Radial Decoupler",
	Category = "Coupling",
	Size = Vector3.new(1, 2, 1),
	DryMass = 60,
	Decoupler = { Impulse = 300, Radial = true },
	CrashTolerance = 8,
})
define({
	Id = "adapter_s_l",
	DisplayName = "Size Adapter",
	Category = "Coupling",
	Size = Vector3.new(10, 3, 10),
	DryMass = 300,
	CrashTolerance = 8,
})

--============================================================================
-- Aero
--============================================================================
define({
	Id = "nose_s",
	DisplayName = "Small Nose Cone",
	Category = "Aero",
	Size = Vector3.new(6, 4, 6),
	DryMass = 100,
	DragFactor = 0.5,
	CrashTolerance = 8,
})
define({
	Id = "nose_l",
	DisplayName = "Large Nose Cone",
	Category = "Aero",
	Size = Vector3.new(10, 6, 10),
	DryMass = 250,
	DragFactor = 0.5,
	CrashTolerance = 8,
})
define({
	Id = "fin",
	DisplayName = "Fin",
	Category = "Aero",
	Size = Vector3.new(1, 4, 3),
	DryMass = 60,
	Fin = { Area = 6, LiftCoef = 1.2 },
	CrashTolerance = 8,
})

--============================================================================
-- Utility
--============================================================================
define({
	Id = "chute_s",
	DisplayName = "Parachute",
	Category = "Utility",
	Size = Vector3.new(3, 2, 3),
	DryMass = 100,
	Chute = { SemiCdA = 30, FullCdA = 500, MaxDeploySpeed = 250, FullAltitude = 800 },
	CrashTolerance = 8,
})
define({
	Id = "leg",
	DisplayName = "Landing Leg",
	Category = "Utility",
	Size = Vector3.new(2, 5, 2),
	DryMass = 100,
	Leg = { Spring = 50000, Damper = 8000 },
	CrashTolerance = 12,
})
define({
	Id = "ladder",
	DisplayName = "Ladder",
	Category = "Utility",
	Size = Vector3.new(1, 4, 1),
	DryMass = 10,
	Climbable = true,
	CrashTolerance = 10,
})
define({
	Id = "seat_ext",
	DisplayName = "External Seat",
	Category = "Utility",
	Size = Vector3.new(2, 2, 2),
	DryMass = 30,
	Seats = 1,
	CrashTolerance = 10,
})

--============================================================================
-- Structural
--============================================================================
define({
	Id = "block_1",
	DisplayName = "Block",
	Category = "Structural",
	Size = Vector3.new(1, 1, 1),
	DryMass = 20,
	CrashTolerance = 10,
})
define({
	Id = "beam_4",
	DisplayName = "Beam",
	Category = "Structural",
	Size = Vector3.new(1, 1, 4),
	DryMass = 60,
	CrashTolerance = 10,
})
define({
	Id = "plate_4",
	DisplayName = "Plate",
	Category = "Structural",
	Size = Vector3.new(4, 1, 4),
	DryMass = 80,
	CrashTolerance = 10,
})

--============================================================================
-- Public API
--============================================================================
local Parts = {}

Parts.List = table.freeze(list)
Parts.Categories = table.freeze(CATEGORY_ORDER)

-- Returns the part definition, or errors for an unknown id (use find() for untrusted input).
function Parts.get(id: string): PartDef
	local def = byId[id]
	if def == nil then
		error(`Unknown part id '{id}'`, 2)
	end
	return def
end

function Parts.find(id: string): PartDef?
	return byId[id]
end

function Parts.isCommand(def: PartDef): boolean
	return def.Category == "Command"
end

function Parts.wetMass(def: PartDef): number
	return def.DryMass + def.FuelMass
end

-- Constant fuel flow (kg/s) at full throttle.
function Parts.massFlow(engine: EngineStats, g0: number): number
	return engine.ThrustVac / (engine.IspVac * g0)
end

-- Isp for a pressure ratio p = rho / rho0 (0 in vacuum, 1 at sea level).
function Parts.ispAt(engine: EngineStats, pressureRatio: number): number
	local p = math.clamp(pressureRatio, 0, 1)
	return engine.IspVac + (engine.IspAsl - engine.IspVac) * p
end

-- Thrust (N) at full throttle for a pressure ratio.
function Parts.thrustAt(engine: EngineStats, pressureRatio: number, g0: number): number
	return Parts.massFlow(engine, g0) * Parts.ispAt(engine, pressureRatio) * g0
end

-- Parts grouped by category in palette order.
function Parts.byCategory(): { [Category]: { PartDef } }
	local out: { [Category]: { PartDef } } = {}
	for _, category: Category in CATEGORY_ORDER do
		out[category] = {}
	end
	for _, def in list do
		table.insert(out[def.Category], def)
	end
	return out
end

return table.freeze(Parts)
