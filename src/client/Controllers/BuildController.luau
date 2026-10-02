--!strict
--[[
	BuildController
	Plane Crazy-style grid building on the player's own open plot (spec 7.2, reworked in Phase 1).

	Active while the local character stands on its own plot. The server owns the design; this controller mirrors
	it from the replicated block models (Pocket_0.Builds.Plot_<i>), shows a ghost preview (red when invalid), and
	sends PlaceBlock / RemoveBlock / PaintBlock requests. The same placement rules as BuildService are checked
	locally for the ghost colour; the server re-checks everything. Undo entries are filled from the server's
	BuildAck, so only accepted operations are undone.

	Grid: design coordinates are blocks of GameConfig.GRID_SIZE studs; the grid origin is the plot baseplate top.

	Tools: Build (B), Paint (P), Delete (X). R yaw 90, T pitch 90. Symmetry: 1 / 2 / 4 = off / radial 2 / radial 4
	around the plot's vertical centre axis; M cycles mirror X -> mirror Z -> mirror X+Z -> off. Ctrl+Z undo (50).

	CHANGED (Phase 11): those keys are the defaults of the SettingsSchema "Build" actions and come from
	Settings/Keybinds (Ctrl+Z stays fixed). While UIState.isInputBlocked() (main menu or a dialog) keys and clicks
	are ignored and no ghost or hover highlight is shown. BuildController.performAction(actionId) runs any Build
	action (or "Undo") exactly like its key, for touch buttons.

	CHANGED (Phase 11, builder UI): the KSP-style BuildUI asks before Clear and before overwriting / replacing a save,
	gets per-stage chips (engines, decouplers, chutes) and burn times for its staging list, has rotate / tilt buttons
	(onAction -> performAction), and while the mouse is over one of its panels no ghost or hover highlight is shown
	and clicks do not build.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local CraftGraph = require(ReplicatedStorage.Shared.Craft.CraftGraph)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local MassProps = require(ReplicatedStorage.Shared.Craft.MassProps)
local Paint = require(ReplicatedStorage.Shared.Config.Paint)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local BuildUI = require(script.Parent.Parent.UI.BuildUI)
local Keybinds = require(script.Parent.Parent.Settings.Keybinds) -- CHANGED (Phase 11)
local PocketController = require(script.Parent.PocketController) -- CHANGED (Night review): zoom cap in flight
local UIState = require(script.Parent.Parent.UI.UIState) -- CHANGED (Phase 11)

type Block = CraftDesign.Block
type Design = CraftDesign.Design

--============================================================================
-- Tunables
--============================================================================
local DEFAULT_PART = "pod_mk1"
local DEFAULT_COLOR = 1 -- white
local PLOT_MARGIN = 3 -- studs off the baseplate that still count as "on the plot"
local STATS_INTERVAL_S = 0.25
local RAY_LENGTH = 1500
local UNDO_LIMIT = GameConfig.UNDO_STACK_SIZE
local CAMERA_MAX_ZOOM = 320
-- CHANGED (Night review): outside the base pocket the stock camera (V in flight, always on EVA) may zoom out at most
-- this far: planets' scaled-space proxies are drawn NEAR_RENDER_RADIUS from the camera, and a craft or astronaut
-- beyond that vanished behind the planet (ChaseCamera has the same cap with the same margin)
local FLIGHT_ZOOM_MARGIN = 20 -- studs
local FLIGHT_MAX_ZOOM = GameConfig.NEAR_RENDER_RADIUS - FLIGHT_ZOOM_MARGIN
local DELETE_HIGHLIGHT_COLOR = Color3.fromRGB(255, 70, 70)
local PAINT_HIGHLIGHT_COLOR = Color3.fromRGB(90, 180, 255)
local SEQ_RETENTION = 400 -- forget pending seqs older than this (rejected ops never get an ack)
local MIRROR_CYCLE: { BuildUI.Symmetry } = { "Off", "MirrorX", "MirrorZ", "MirrorXZ" }
--============================================================================

type Placement = { type: string, gx: number, gy: number, gz: number, rot: number, color: number? }
type UndoEntry = { kind: "place" | "remove" | "paint", blocks: { Placement } }

local BuildController = {}

local player = Players.LocalPlayer
local ui: BuildUI.BuildUI
local remotes: { [string]: RemoteEvent } = {}

local plotIndex: number? = nil
local plotInfo: BaseLayout.PlotInfo? = nil
local buildFolder: Instance? = nil
local buildFloor: BasePart? = nil

local design: Design = CraftDesign.new()
local designDirty = true
local statsDirty = true
local lastStats = 0

local selectedPart = DEFAULT_PART
local selectedColor = DEFAULT_COLOR
local rotation = 0
local tool: BuildUI.Tool = "Build"
local symmetry: BuildUI.Symmetry = "Off"
local active = false

local undoStack: { UndoEntry } = {}
local nextSeq = 0
local entryBySeq: { [number]: UndoEntry } = {}

local ghostFolder: Folder
local ghostPool: { [string]: Model } = {}
local hoverBox: SelectionBox

local UP_NAMES = { "+Y", "+X", "-X", "+Z", "-Z", "-Y" }
local GRID_SIZE = BaseLayout.GRID_SIZE -- build volume in blocks

local function rotationText(): string
	return `up {UP_NAMES[rotation // 4 + 1]}  yaw {(rotation % 4) * 90}`
end

--============================================================================
-- Design mirror and stats
--============================================================================

local function refreshDesign()
	local folder = buildFolder
	if folder == nil then
		return
	end
	design = CraftBuilder.readDesign(folder, design.name)
	designDirty = false
	statsDirty = true
end

local function updateStats()
	local graph = CraftGraph.build(design)
	local props = MassProps.compute(design)
	local stageStats = MassProps.stageStats(graph, GameConfig.G0, Bodies.get(Bodies.HOMEWORLD).SurfaceGravity)
	local totalVac, totalAsl = MassProps.totalDeltaV(stageStats)
	local rows: { BuildUI.StageRow } = {}
	for _, stat in stageStats do
		-- CHANGED (Phase 11): what the stage does, for the staging list's chips (stat.stage indexes graph.stages)
		local stage = graph.stages[stat.stage]
		table.insert(rows, {
			stage = stat.stage,
			dvVac = stat.dvVac,
			dvAsl = stat.dvAsl,
			twrAsl = stat.twrAsl,
			burnTime = stat.burnTime,
			engines = if stage then #stage.ignite else 0,
			decouplers = if stage then #stage.decouple else 0,
			chutes = if stage then #stage.deploy else 0,
		})
	end
	local warnings = table.clone(graph.warnings)
	if #design.blocks == 0 then
		warnings = { "Pick a part and click the baseplate to start" }
	end
	ui.setStats({
		mass = props.mass,
		parts = props.partCount,
		stages = rows,
		totalVac = totalVac,
		totalAsl = totalAsl,
		warnings = warnings,
	})
end

--============================================================================
-- Placement maths (plot grid, blocks)
--============================================================================

local function isInsideVolume(block: Block): boolean
	local size = CraftDesign.blockSize(block)
	return block.gx >= 0
		and block.gy >= 0
		and block.gz >= 0
		and block.gx + size.X <= GRID_SIZE.X
		and block.gy + size.Y <= GRID_SIZE.Y
		and block.gz + size.Z <= GRID_SIZE.Z
end

-- Same rules as BuildService.checkPlacement; `extra` = copies placed earlier in the same click.
local function isValid(block: Block, extra: { Block }): boolean
	if #design.blocks + #extra >= GameConfig.MAX_BLOCKS_PER_CRAFT then
		return false
	end
	if not isInsideVolume(block) then
		return false
	end
	for _, other in design.blocks do
		if CraftDesign.overlaps(block, other) then
			return false
		end
	end
	for _, other in extra do
		if CraftDesign.overlaps(block, other) then
			return false
		end
	end
	if #design.blocks + #extra == 0 then
		return block.gy == 0
	end
	for _, other in design.blocks do
		if CraftDesign.touches(block, other) then
			return true
		end
	end
	for _, other in extra do
		if CraftDesign.touches(block, other) then
			return true
		end
	end
	return false
end

local function withCenter(block: Block, center: Vector3, rot: number): Block
	local size = CraftDesign.orientedSize(block.type, rot)
	local minCorner = center - size / 2
	return {
		id = 0,
		type = block.type,
		gx = math.round(minCorner.X),
		gy = math.round(minCorner.Y),
		gz = math.round(minCorner.Z),
		rot = rot,
		color = block.color,
	}
end

local function mirrored(block: Block, axis: "X" | "Z"): Block
	local center = CraftDesign.blockCenter(block)
	local newCenter = if axis == "X"
		then Vector3.new(GRID_SIZE.X - center.X, center.Y, center.Z)
		else Vector3.new(center.X, center.Y, GRID_SIZE.Z - center.Z)
	return withCenter(block, newCenter, CraftDesign.mirrorOrientation(block.rot, axis))
end

local function radial(block: Block, k: number, count: number): Block
	local axis = Vector3.new(GRID_SIZE.X / 2, 0, GRID_SIZE.Z / 2)
	local yaw = CFrame.Angles(0, k * 2 * math.pi / count, 0)
	local center = axis + yaw:VectorToWorldSpace(CraftDesign.blockCenter(block) - axis)
	return withCenter(block, center, CraftDesign.rotateOrientation(block.rot, yaw))
end

-- The block and its symmetric copies (original first), without duplicates that overlap each other.
local function symmetricCopies(block: Block): { Block }
	local candidates = { block }
	if symmetry == "MirrorX" then
		table.insert(candidates, mirrored(block, "X"))
	elseif symmetry == "MirrorZ" then
		table.insert(candidates, mirrored(block, "Z"))
	elseif symmetry == "MirrorXZ" then
		local mx = mirrored(block, "X")
		table.insert(candidates, mx)
		table.insert(candidates, mirrored(block, "Z"))
		table.insert(candidates, mirrored(mx, "Z"))
	elseif symmetry == "Radial2" or symmetry == "Radial4" then
		local count = if symmetry == "Radial2" then 2 else 4
		for k = 1, count - 1 do
			table.insert(candidates, radial(block, k, count))
		end
	end
	local copies: { Block } = {}
	for _, candidate in candidates do
		local duplicate = false
		for _, existing in copies do
			if CraftDesign.overlaps(existing, candidate) then
				duplicate = true
				break
			end
		end
		if not duplicate then
			table.insert(copies, candidate)
		end
	end
	return copies
end

local function mouseRay(): RaycastResult?
	local folder, floor = buildFolder, buildFloor
	if folder == nil or floor == nil then
		return nil
	end
	local camera = Workspace.CurrentCamera
	local mouse = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { folder, floor }
	return Workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
end

local function blockFromHit(hit: Instance): (Block?, Model?)
	local model = hit:FindFirstAncestorOfClass("Model")
	if model == nil then
		return nil, nil
	end
	local id = model:GetAttribute("BlockId")
	if type(id) ~= "number" then
		return nil, nil
	end
	return CraftDesign.findBlock(design, id), model
end

-- The block (in the current design) that occupies the grid cell containing `cell`, or nil.
local function blockAtCell(x: number, y: number, z: number): Block?
	for _, block in design.blocks do
		local minV, maxV = CraftDesign.blockMin(block), CraftDesign.blockMax(block)
		if x >= minV.X and x < maxV.X and y >= minV.Y and y < maxV.Y and z >= minV.Z and z < maxV.Z then
			return block
		end
	end
	return nil
end

-- The placement for the selected part under the mouse, or nil.
local function targetPlacement(): Block?
	local info = plotInfo
	local result = mouseRay()
	if info == nil or result == nil then
		return nil
	end
	local size = CraftDesign.orientedSize(selectedPart, rotation)
	local p = BaseLayout.worldToGrid(info, result.Position)
	local n = result.Normal
	local block: Block = { id = 0, type = selectedPart, gx = 0, gy = 0, gz = 0, rot = rotation }
	local hitBlock = blockFromHit(result.Instance)

	local function lateral(value: number, extent: number): number
		return math.round(value - extent / 2)
	end

	if hitBlock == nil then
		-- the baseplate: sit on it, clamped inside the build area
		block.gy = 0
		block.gx = math.clamp(lateral(p.X, size.X), 0, GRID_SIZE.X - size.X)
		block.gz = math.clamp(lateral(p.Z, size.Z), 0, GRID_SIZE.Z - size.Z)
		return block
	end

	local minV, maxV = CraftDesign.blockMin(hitBlock), CraftDesign.blockMax(hitBlock)
	local ax, ay, az = math.abs(n.X), math.abs(n.Y), math.abs(n.Z)
	if ax >= ay and ax >= az then
		block.gx = if n.X > 0 then maxV.X else minV.X - size.X
		block.gy = lateral(p.Y, size.Y)
		block.gz = lateral(p.Z, size.Z)
	elseif ay >= az then
		block.gy = if n.Y > 0 then maxV.Y else minV.Y - size.Y
		block.gx = lateral(p.X, size.X)
		block.gz = lateral(p.Z, size.Z)
	else
		block.gz = if n.Z > 0 then maxV.Z else minV.Z - size.Z
		block.gx = lateral(p.X, size.X)
		block.gy = lateral(p.Y, size.Y)
	end
	return block
end

-- For paint/delete: the hovered block plus the existing blocks at its symmetric positions.
local function hoveredWithCopies(): { Block }
	local result = mouseRay()
	local hit = if result then blockFromHit(result.Instance) else nil
	if hit == nil then
		return {}
	end
	local found: { Block } = {}
	for _, copy in symmetricCopies(hit) do
		local center = CraftDesign.blockCenter(copy)
		local existing = blockAtCell(math.floor(center.X), math.floor(center.Y), math.floor(center.Z))
		if existing and not table.find(found, existing) then
			table.insert(found, existing)
		end
	end
	return found
end

--============================================================================
-- Ghosts and hover highlight
--============================================================================

local function ghostFor(partId: string, rot: number): Model
	local key = `{partId}|{rot}`
	local ghost: Model? = ghostPool[key]
	if not ghost then
		ghost = CraftBuilder.buildBlock(
			{ id = 0, type = partId, gx = 0, gy = 0, gz = 0, rot = rot },
			"Ghost",
			CFrame.identity
		)
		ghostPool[key] = ghost
	end
	return ghost :: Model
end

local function hideGhosts(except: { [Model]: boolean }?)
	for _, ghost in ghostPool do
		if not (except and except[ghost]) then
			ghost.Parent = nil
		end
	end
end

local function updateGhosts()
	local info = plotInfo
	-- CHANGED (Phase 11): no ghost while a menu or dialog is open, or while the mouse is over the builder UI
	if not active or tool ~= "Build" or info == nil or UIState.isInputBlocked() or ui.isPointerOverUI() then
		hideGhosts()
		return
	end
	local target = targetPlacement()
	if target == nil then
		hideGhosts()
		return
	end
	local used: { [Model]: boolean } = {}
	local placed: { Block } = {}
	local origin = CFrame.new(info.buildOrigin)
	for _, copy in symmetricCopies(target) do
		local ghost = ghostFor(copy.type, copy.rot)
		if not used[ghost] then
			used[ghost] = true
			ghost:PivotTo(origin * CraftDesign.blockCFrame(copy))
			CraftBuilder.setGhostValid(ghost, isValid(copy, placed))
			ghost.Parent = ghostFolder
		end
		table.insert(placed, copy)
	end
	hideGhosts(used)
end

local function updateHover()
	-- CHANGED (Phase 11): or a menu / dialog, or the mouse over the builder UI
	if not active or tool == "Build" or UIState.isInputBlocked() or ui.isPointerOverUI() then
		hoverBox.Adornee = nil
		return
	end
	local result = mouseRay()
	local model: Model? = nil
	if result then
		local _, hitModel = blockFromHit(result.Instance)
		model = hitModel
	end
	hoverBox.Adornee = model
	local color = if tool == "Delete" then DELETE_HIGHLIGHT_COLOR else PAINT_HIGHLIGHT_COLOR
	hoverBox.Color3 = color
	hoverBox.SurfaceColor3 = if tool == "Paint" then Paint.color(selectedColor) or color else color
end

--============================================================================
-- Actions
--============================================================================

local function pushUndo(entry: UndoEntry)
	table.insert(undoStack, entry)
	if #undoStack > UNDO_LIMIT then
		table.remove(undoStack, 1)
	end
end

local function trackSeq(entry: UndoEntry): number
	nextSeq += 1
	entryBySeq[nextSeq] = entry
	entryBySeq[nextSeq - SEQ_RETENTION] = nil
	return nextSeq
end

local function onAck(
	seq: unknown,
	kind: unknown,
	partId: unknown,
	gx: unknown,
	gy: unknown,
	gz: unknown,
	rot: unknown,
	color: unknown
)
	if type(seq) ~= "number" then
		return
	end
	local entry = entryBySeq[seq]
	entryBySeq[seq] = nil
	if entry == nil or entry.kind ~= kind then
		return
	end
	if
		type(partId) == "string"
		and type(gx) == "number"
		and type(gy) == "number"
		and type(gz) == "number"
		and type(rot) == "number"
	then
		local colorIndex = if type(color) == "number" and color > 0 then color else nil
		table.insert(entry.blocks, { type = partId, gx = gx, gy = gy, gz = gz, rot = rot, color = colorIndex })
	end
end

local function place()
	local target = targetPlacement()
	if target == nil then
		return
	end
	local placed: { Block } = {}
	local entry: UndoEntry = { kind = "place", blocks = {} }
	for _, copy in symmetricCopies(target) do
		if isValid(copy, placed) then
			table.insert(placed, copy)
			remotes.PlaceBlock:FireServer(copy.type, copy.gx, copy.gy, copy.gz, copy.rot, trackSeq(entry))
		end
	end
	if #placed > 0 then
		pushUndo(entry)
	else
		ui.toast("Can't place there", "Error")
	end
end

local function remove()
	local blocks = hoveredWithCopies()
	if #blocks == 0 then
		return
	end
	local entry: UndoEntry = { kind = "remove", blocks = {} }
	for _, block in blocks do
		remotes.RemoveBlock:FireServer(block.gx, block.gy, block.gz, trackSeq(entry))
	end
	pushUndo(entry)
end

local function paint()
	local blocks = hoveredWithCopies()
	if #blocks == 0 then
		return
	end
	local entry: UndoEntry = { kind = "paint", blocks = {} }
	local sent = 0
	for _, block in blocks do
		if block.color ~= selectedColor then
			remotes.PaintBlock:FireServer(block.gx, block.gy, block.gz, selectedColor, trackSeq(entry))
			sent += 1
		end
	end
	if sent > 0 then
		pushUndo(entry)
	end
end

local function undo()
	local entry = table.remove(undoStack)
	while entry and #entry.blocks == 0 do
		entry = table.remove(undoStack)
	end
	if entry == nil then
		ui.toast("Nothing to undo")
		return
	end
	for _, block in entry.blocks do
		if entry.kind == "place" then
			remotes.RemoveBlock:FireServer(block.gx, block.gy, block.gz)
		elseif entry.kind == "remove" then
			remotes.PlaceBlock:FireServer(block.type, block.gx, block.gy, block.gz, block.rot, 0, block.color)
		else
			remotes.PaintBlock:FireServer(block.gx, block.gy, block.gz, block.color or 0)
		end
	end
end

local function setTool(newTool: BuildUI.Tool)
	tool = newTool
	ui.setTool(tool)
end

local function setSymmetry(mode: BuildUI.Symmetry)
	symmetry = mode
	ui.setSymmetry(mode)
end

local function rotate(by: CFrame)
	rotation = CraftDesign.rotateOrientation(rotation, by)
	ui.setRotationText(rotationText())
end

-- CHANGED (Phase 11): every Build action by SettingsSchema id (plus "Undo"), for keys and future touch buttons.
-- Returns false for an unknown action.
function BuildController.performAction(actionId: string): boolean
	if actionId == "RotateY" then
		rotate(CFrame.Angles(0, math.pi / 2, 0))
	elseif actionId == "RotateX" then
		rotate(CFrame.Angles(math.pi / 2, 0, 0))
	elseif actionId == "ToolBuild" then
		setTool("Build")
	elseif actionId == "ToolPaint" then
		setTool("Paint")
	elseif actionId == "ToolDelete" then
		setTool(if tool == "Delete" then "Build" else "Delete")
	elseif actionId == "SymmetryOff" then
		setSymmetry("Off")
	elseif actionId == "SymmetryRadial2" then
		setSymmetry("Radial2")
	elseif actionId == "SymmetryRadial4" then
		setSymmetry("Radial4")
	elseif actionId == "SymmetryMirror" then
		local index = table.find(MIRROR_CYCLE, symmetry) or 0
		setSymmetry(MIRROR_CYCLE[index % #MIRROR_CYCLE + 1])
	elseif actionId == "Undo" then
		undo()
	else
		return false
	end
	return true
end

--============================================================================
-- Plot detection
--============================================================================

local function isOnOwnPlot(): boolean
	local info = plotInfo
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if info == nil or root == nil or not root:IsA("BasePart") then
		return false
	end
	return BaseLayout.isOnPlot(info, root.Position, PLOT_MARGIN)
end

local function attachToPlot(index: number)
	plotIndex = index
	plotInfo = BaseLayout.plot(index)
	local pockets = Workspace:WaitForChild("Pockets")
	local base = pockets:WaitForChild("Pocket_0")
	local folder = base:WaitForChild("Builds"):WaitForChild(`Plot_{index}`)
	local floor =
		base:WaitForChild("Site"):WaitForChild("Plots"):WaitForChild(`Plot_{index}`):WaitForChild("BuildFloor")
	buildFolder = folder
	buildFloor = if floor:IsA("BasePart") then floor else nil
	-- paint changes the Color attribute of an existing block model
	local function watchBlock(child: Instance)
		child:GetAttributeChangedSignal("Color"):Connect(function()
			designDirty = true
		end)
	end
	for _, child in folder:GetChildren() do
		watchBlock(child)
	end
	folder.ChildAdded:Connect(function(child: Instance)
		watchBlock(child)
		designDirty = true
	end)
	folder.ChildRemoved:Connect(function()
		designDirty = true
	end)
	undoStack = {}
	designDirty = true
end

--============================================================================
-- Lifecycle
--============================================================================

function BuildController.Init()
	for _, name in
		{
			"PlaceBlock",
			"RemoveBlock",
			"PaintBlock",
			"ClearPlot",
			"SaveDesign",
			"LoadDesign",
			"RollOut",
			"SetBoardingPermission",
		}
	do
		remotes[name] = Remotes.event(name)
	end

	ghostFolder = Instance.new("Folder")
	ghostFolder.Name = "BuildGhosts"
	ghostFolder.Parent = Workspace

	hoverBox = Instance.new("SelectionBox")
	hoverBox.Name = "BuildHover"
	hoverBox.LineThickness = 0.1
	hoverBox.SurfaceTransparency = 0.7
	hoverBox.Parent = ghostFolder

	ui = BuildUI.create({
		onSelectPart = function(partId: string)
			selectedPart = partId
			ui.setSelectedPart(partId)
			setTool("Build")
		end,
		onTool = setTool,
		onSelectColor = function(index: number)
			if Paint.isValid(index) then
				selectedColor = index
				ui.setSelectedColor(index)
			end
		end,
		onSymmetry = setSymmetry,
		onUndo = undo,
		onClear = function()
			remotes.ClearPlot:FireServer()
			undoStack = {}
		end,
		onSave = function(slot: number, name: string)
			remotes.SaveDesign:FireServer(slot, name)
		end,
		onLoad = function(slot: number)
			remotes.LoadDesign:FireServer(slot)
			undoStack = {}
		end,
		onRollOut = function()
			remotes.RollOut:FireServer()
		end,
		onBoarding = function(mode: string)
			remotes.SetBoardingPermission:FireServer(mode)
		end,
		-- CHANGED (Phase 11): the toolbar's rotate / tilt buttons
		onAction = function(actionId: string)
			BuildController.performAction(actionId)
		end,
	})
	ui.setSelectedPart(selectedPart)
	ui.setSelectedColor(selectedColor)
	ui.setTool(tool)
	ui.setSymmetry(symmetry)
	ui.setRotationText(rotationText())
end

function BuildController.Start()
	player.CameraMaxZoomDistance = math.max(player.CameraMaxZoomDistance, CAMERA_MAX_ZOOM)
	-- CHANGED (Night review): capped at FLIGHT_MAX_ZOOM outside the base pocket, given back at home
	local homeMaxZoom = player.CameraMaxZoomDistance
	local zoomCapped = false
	local function applyZoomLimit(pocketId: number)
		if pocketId ~= 0 and not zoomCapped then
			homeMaxZoom = player.CameraMaxZoomDistance
			player.CameraMaxZoomDistance = math.min(homeMaxZoom, FLIGHT_MAX_ZOOM)
			zoomCapped = true
		elseif pocketId == 0 and zoomCapped then
			player.CameraMaxZoomDistance = homeMaxZoom
			zoomCapped = false
		end
	end
	PocketController.onPocketChanged(applyZoomLimit)
	applyZoomLimit(PocketController.pocketId())

	Remotes.event("Notify").OnClientEvent:Connect(function(text: unknown, kind: unknown)
		if type(text) == "string" then
			ui.toast(text, if type(kind) == "string" then kind else nil)
		end
	end)
	Remotes.event("BuildAck").OnClientEvent:Connect(onAck)
	Remotes.event("SaveSlots").OnClientEvent:Connect(function(names: unknown)
		if type(names) ~= "table" then
			return
		end
		local clean: { [number]: string } = {}
		for slot, name in names :: { [any]: any } do
			local index = tonumber(slot)
			if index and type(name) == "string" then
				clean[index] = name
			end
		end
		ui.setSlots(clean)
	end)

	local function onBoardingChanged()
		local mode = player:GetAttribute("Boarding")
		ui.setBoarding(if type(mode) == "string" then mode else GameConfig.DEFAULT_BOARDING)
	end
	player:GetAttributeChangedSignal("Boarding"):Connect(onBoardingChanged)
	onBoardingChanged()

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		-- CHANGED (Phase 11): menus and dialogs block building (keys and clicks)
		if gameProcessed or not active or UIState.isInputBlocked() then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if ui.isPointerOverUI() then
				return -- CHANGED (Phase 11): a click on a builder panel never builds behind it
			end
			if tool == "Delete" then
				remove()
			elseif tool == "Paint" then
				paint()
			else
				place()
			end
			return
		end
		local key = input.KeyCode
		local ctrl = UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
			or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
		if key == Enum.KeyCode.Z and ctrl then
			undo()
		else
			-- CHANGED (Phase 11): the key's Build action from Keybinds
			local action = Keybinds.actionFor("Build", key)
			if action then
				BuildController.performAction(action)
			end
		end
	end)

	RunService.RenderStepped:Connect(function()
		local index = player:GetAttribute("PlotIndex")
		if type(index) == "number" and index ~= plotIndex then
			attachToPlot(index)
		end
		local nowActive = isOnOwnPlot()
		if nowActive ~= active then
			active = nowActive
			ui.setVisible(active)
			statsDirty = true
		end
		if designDirty then
			refreshDesign()
		end
		if active and statsDirty and os.clock() - lastStats >= STATS_INTERVAL_S then
			lastStats = os.clock()
			statsDirty = false
			updateStats()
		end
		updateGhosts()
		updateHover()
	end)
end

return BuildController
