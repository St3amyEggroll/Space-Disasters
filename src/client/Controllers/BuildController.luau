--!strict
--[[
	BuildController
	Plane Crazy-style grid building in the player's own hangar (spec 7.2).

	Active while the local character stands in its own hangar. The server owns the design; this controller mirrors
	it from the replicated block models (Pocket_0.Builds.Plot_<i>), shows a ghost preview (red when invalid),
	and sends PlaceBlock / RemoveBlock requests. The same placement rules as BuildService are checked locally for
	the ghost colour; the server re-checks everything.

	Controls: click place / delete, R yaw 90, T pitch 90, X delete mode, 1 / 2 / 4 radial symmetry around the
	hangar's vertical build axis, Ctrl+Z undo (local stack of 50).
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
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local BuildUI = require(script.Parent.Parent.UI.BuildUI)

type Block = CraftDesign.Block
type Design = CraftDesign.Design

--============================================================================
-- Tunables
--============================================================================
local DEFAULT_PART = "pod_mk1"
local HANGAR_MARGIN = 3 -- studs outside the build footprint that still count as "in the hangar"
local STATS_INTERVAL_S = 0.25
local RAY_LENGTH = 1000
local UNDO_LIMIT = GameConfig.UNDO_STACK_SIZE
local CAMERA_MAX_ZOOM = 260
local DELETE_HIGHLIGHT_COLOR = Color3.fromRGB(255, 70, 70)
--============================================================================

type Placement = { type: string, gx: number, gy: number, gz: number, rot: number }
type UndoEntry = { kind: "place" | "remove", blocks: { Placement } }

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
local rotation = 0
local deleteMode = false
local symmetry = 1
local active = false
local undoStack: { UndoEntry } = {}
-- Undo entries are filled from the server's BuildAck, so only operations the server accepted can be undone.
local nextSeq = 0
local entryBySeq: { [number]: UndoEntry } = {}
local SEQ_RETENTION = 400 -- forget pending seqs older than this (rejected ops never get an ack)

local ghostFolder: Folder
local ghostPool: { [string]: Model } = {}
local deleteBox: SelectionBox

local UP_NAMES = { "+Y", "+X", "-X", "+Z", "-Z", "-Y" }

local function rotationText(): string
	local upIndex = rotation // 4
	return `up {UP_NAMES[upIndex + 1]}  yaw {(rotation % 4) * 90}`
end

local function refreshModeUI()
	ui.setMode(deleteMode, symmetry, rotationText())
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
	local rows = {}
	for _, stat in stageStats do
		table.insert(rows, { stage = stat.stage, dvVac = stat.dvVac, dvAsl = stat.dvAsl, twrAsl = stat.twrAsl })
	end
	local warnings = table.clone(graph.warnings)
	if #design.blocks == 0 then
		warnings = { "Pick a part on the left and click the floor to start" }
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
-- Placement maths (plot grid coordinates)
--============================================================================

local function isInsideVolume(block: Block): boolean
	local size = CraftDesign.blockSize(block)
	local limit = BaseLayout.BUILD_SIZE
	return block.gx >= 0
		and block.gy >= 0
		and block.gz >= 0
		and block.gx + size.X <= limit.X
		and block.gy + size.Y <= limit.Y
		and block.gz + size.Z <= limit.Z
end

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
	-- the server applies symmetric copies one after another, so earlier copies count as existing blocks
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

-- Symmetric copies (including the original first) around the hangar's vertical centre axis.
local function symmetricCopies(block: Block): { Block }
	local copies = { block }
	if symmetry <= 1 then
		return copies
	end
	local axis = Vector3.new(BaseLayout.BUILD_SIZE.X / 2, 0, BaseLayout.BUILD_SIZE.Z / 2)
	local center = CraftDesign.blockCenter(block)
	for k = 1, symmetry - 1 do
		local yaw = CFrame.Angles(0, k * 2 * math.pi / symmetry, 0)
		local rot = CraftDesign.rotateOrientation(block.rot, yaw)
		local size = CraftDesign.orientedSize(block.type, rot)
		local rotatedCenter = axis + yaw:VectorToWorldSpace(center - axis)
		local minCorner = rotatedCenter - size / 2
		local copy: Block = {
			id = 0,
			type = block.type,
			gx = math.round(minCorner.X),
			gy = math.round(minCorner.Y),
			gz = math.round(minCorner.Z),
			rot = rot,
		}
		local duplicate = false
		for _, existing in copies do
			if CraftDesign.overlaps(existing, copy) then
				duplicate = true
				break
			end
		end
		if not duplicate then
			table.insert(copies, copy)
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

local function blockFromHit(hit: Instance): Block?
	local model = hit:FindFirstAncestorOfClass("Model")
	if model == nil then
		return nil
	end
	local id = model:GetAttribute("BlockId")
	if type(id) ~= "number" then
		return nil
	end
	return CraftDesign.findBlock(design, id)
end

-- The placement for the selected part under the mouse, or nil.
local function targetPlacement(): Block?
	local info = plotInfo
	local result = mouseRay()
	if info == nil or result == nil then
		return nil
	end
	local size = CraftDesign.orientedSize(selectedPart, rotation)
	local p = result.Position - info.buildOrigin
	local n = result.Normal
	local block: Block = { id = 0, type = selectedPart, gx = 0, gy = 0, gz = 0, rot = rotation }
	local hitBlock = blockFromHit(result.Instance)

	local function lateral(value: number, extent: number): number
		return math.round(value - extent / 2)
	end

	if hitBlock == nil then
		-- the hangar floor: sit on it, clamped inside the build area
		block.gy = 0
		block.gx = math.clamp(lateral(p.X, size.X), 0, BaseLayout.BUILD_SIZE.X - size.X)
		block.gz = math.clamp(lateral(p.Z, size.Z), 0, BaseLayout.BUILD_SIZE.Z - size.Z)
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

--============================================================================
-- Ghosts
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
	if not active or deleteMode or info == nil then
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
		if used[ghost] then
			-- same part + orientation twice (e.g. symmetric copy with identical rotation): clone once more
			continue
		end
		used[ghost] = true
		ghost:PivotTo(origin * CraftDesign.blockCFrame(copy))
		CraftBuilder.setGhostValid(ghost, isValid(copy, placed))
		table.insert(placed, copy)
		ghost.Parent = ghostFolder
	end
	hideGhosts(used)
end

local function updateDeleteHighlight()
	if not (active and deleteMode) then
		deleteBox.Adornee = nil
		return
	end
	local result = mouseRay()
	local hitBlock = if result then blockFromHit(result.Instance) else nil
	if hitBlock and result then
		deleteBox.Adornee = result.Instance:FindFirstAncestorOfClass("Model")
	else
		deleteBox.Adornee = nil
	end
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

-- Allocates a sequence number whose acknowledgement will add the accepted block to `entry`.
local function trackSeq(entry: UndoEntry): number
	nextSeq += 1
	entryBySeq[nextSeq] = entry
	entryBySeq[nextSeq - SEQ_RETENTION] = nil
	return nextSeq
end

local function onAck(seq: unknown, kind: unknown, partId: unknown, gx: unknown, gy: unknown, gz: unknown, rot: unknown)
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
		table.insert(entry.blocks, { type = partId, gx = gx, gy = gy, gz = gz, rot = rot })
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
	local result = mouseRay()
	local hitBlock = if result then blockFromHit(result.Instance) else nil
	if hitBlock == nil then
		return
	end
	local entry: UndoEntry = { kind = "remove", blocks = {} }
	remotes.RemoveBlock:FireServer(hitBlock.gx, hitBlock.gy, hitBlock.gz, trackSeq(entry))
	pushUndo(entry)
end

local function undo()
	-- skip entries whose operations were all rejected by the server
	local entry = table.remove(undoStack)
	while entry and #entry.blocks == 0 do
		entry = table.remove(undoStack)
	end
	if entry == nil then
		ui.toast("Nothing to undo")
		return
	end
	if entry.kind == "place" then
		for _, block in entry.blocks do
			remotes.RemoveBlock:FireServer(block.gx, block.gy, block.gz)
		end
	else
		for _, block in entry.blocks do
			remotes.PlaceBlock:FireServer(block.type, block.gx, block.gy, block.gz, block.rot)
		end
	end
end

local function rotate(by: CFrame)
	rotation = CraftDesign.rotateOrientation(rotation, by)
	refreshModeUI()
end

--============================================================================
-- Hangar detection
--============================================================================

local function isInOwnHangar(): boolean
	local info = plotInfo
	local character = player.Character
	local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
	if info == nil or root == nil or not root:IsA("BasePart") then
		return false
	end
	local p = root.Position - info.buildOrigin
	return p.X >= -HANGAR_MARGIN
		and p.X <= info.buildSize.X + HANGAR_MARGIN
		and p.Z >= -HANGAR_MARGIN
		and p.Z <= info.buildSize.Z + HANGAR_MARGIN
		and p.Y >= -5
		and p.Y <= info.buildSize.Y + 10
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
	folder.ChildAdded:Connect(function()
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
		{ "PlaceBlock", "RemoveBlock", "ClearPlot", "SaveDesign", "LoadDesign", "RollOut", "SetBoardingPermission" }
	do
		remotes[name] = Remotes.event(name)
	end

	ghostFolder = Instance.new("Folder")
	ghostFolder.Name = "BuildGhosts"
	ghostFolder.Parent = Workspace

	deleteBox = Instance.new("SelectionBox")
	deleteBox.Name = "DeleteHighlight"
	deleteBox.Color3 = DELETE_HIGHLIGHT_COLOR
	deleteBox.LineThickness = 0.08
	deleteBox.SurfaceTransparency = 0.8
	deleteBox.SurfaceColor3 = DELETE_HIGHLIGHT_COLOR
	deleteBox.Parent = ghostFolder

	ui = BuildUI.create({
		onSelectPart = function(partId: string)
			selectedPart = partId
			deleteMode = false
			ui.setSelected(partId)
			refreshModeUI()
		end,
		onUndo = undo,
		onToggleDelete = function()
			deleteMode = not deleteMode
			refreshModeUI()
		end,
		onSymmetry = function(count: number)
			symmetry = count
			refreshModeUI()
		end,
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
	})
	ui.setSelected(selectedPart)
	refreshModeUI()
end

function BuildController.Start()
	player.CameraMaxZoomDistance = math.max(player.CameraMaxZoomDistance, CAMERA_MAX_ZOOM)

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
		if gameProcessed or not active then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			if deleteMode then
				remove()
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
		elseif key == Enum.KeyCode.R then
			rotate(CFrame.Angles(0, math.pi / 2, 0))
		elseif key == Enum.KeyCode.T then
			rotate(CFrame.Angles(math.pi / 2, 0, 0))
		elseif key == Enum.KeyCode.X then
			deleteMode = not deleteMode
			refreshModeUI()
		elseif key == Enum.KeyCode.One then
			symmetry = 1
			refreshModeUI()
		elseif key == Enum.KeyCode.Two then
			symmetry = 2
			refreshModeUI()
		elseif key == Enum.KeyCode.Four then
			symmetry = 4
			refreshModeUI()
		end
	end)

	RunService.RenderStepped:Connect(function()
		local index = player:GetAttribute("PlotIndex")
		if type(index) == "number" and index ~= plotIndex then
			attachToPlot(index)
		end
		local nowActive = isInOwnHangar()
		if nowActive ~= active then
			active = nowActive
			ui.setVisible(active)
			statsDirty = true
		end
		if designDirty then
			refreshDesign()
			lastStats = 0
		end
		if active and statsDirty and os.clock() - lastStats >= STATS_INTERVAL_S then
			lastStats = os.clock()
			statsDirty = false
			updateStats()
		end
		updateGhosts()
		updateDeleteHighlight()
	end)
end

return BuildController
