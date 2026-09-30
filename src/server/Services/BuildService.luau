--!strict
--[[
	BuildService
	Authoritative hangar building (spec 7.2). Each plot's design lives here; the server builds the block models
	(Real mode) into Workspace.Pockets.Pocket_0.Builds.Plot_<i>, and they replicate to everyone, so all players see
	each other's builds live. Clients mirror the design from those models (CraftBuilder.readDesign).

	Validation of every operation: plot owner only, inside BUILD_VOLUME, no overlap (occupancy grid), block count
	<= MAX_BLOCKS_PER_CRAFT, rate <= BUILD_OPS_PER_SECOND (token bucket), and connectivity (a new block must touch an
	existing block; only the first block may sit on the floor with nothing to touch).

	Remotes: PlaceBlock, RemoveBlock, ClearPlot, SaveDesign, LoadDesign (+ SaveSlots / Notify replies).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseLayout = require(ReplicatedStorage.Shared.Config.BaseLayout)
local CraftBuilder = require(ReplicatedStorage.Shared.Craft.CraftBuilder)
local CraftDesign = require(ReplicatedStorage.Shared.Craft.CraftDesign)
local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local Paint = require(ReplicatedStorage.Shared.Config.Paint)
local Parts = require(ReplicatedStorage.Shared.Config.Parts)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local PlotService = require(script.Parent.PlotService)
local PocketService = require(script.Parent.PocketService)
local SaveService = require(script.Parent.SaveService)

type Block = CraftDesign.Block
type Design = CraftDesign.Design

--============================================================================
-- Tunables
--============================================================================
local OPS_PER_SECOND = GameConfig.BUILD_OPS_PER_SECOND
local OPS_BURST = GameConfig.BUILD_OPS_PER_SECOND -- token bucket size
local MAX_BLOCKS = GameConfig.MAX_BLOCKS_PER_CRAFT
local MAX_BLOCK_ID = 65535
local LOAD_OP_COST = 10 -- tokens a whole-design load/clear costs
--============================================================================

type PlotState = {
	index: number,
	design: Design,
	occupancy: { [number]: number }, -- cell key -> block id
	nextId: number,
	folder: Folder,
	tokens: number,
	lastRefill: number,
}

local BuildService = {}

local plots: { [number]: PlotState } = {}
local notifyRemote: RemoteEvent
local slotsRemote: RemoteEvent
local ackRemote: RemoteEvent

local BUILD_SIZE = BaseLayout.GRID_SIZE -- CHANGED (Phase 1 rework): the build volume in blocks

local function cellKey(x: number, y: number, z: number): number
	return (x * 128 + y) * 128 + z
end

local function notify(player: Player, text: string, kind: string?)
	notifyRemote:FireClient(player, text, kind or "Info")
end

local function forEachCell(block: Block, callback: (key: number) -> boolean?): boolean
	local size = CraftDesign.blockSize(block)
	for x = block.gx, block.gx + size.X - 1 do
		for y = block.gy, block.gy + size.Y - 1 do
			for z = block.gz, block.gz + size.Z - 1 do
				if callback(cellKey(x, y, z)) == false then
					return false
				end
			end
		end
	end
	return true
end

local function plotOrigin(state: PlotState): CFrame
	return CFrame.new(BaseLayout.plot(state.index).buildOrigin)
end

local function takeToken(state: PlotState, cost: number): boolean
	local now = os.clock()
	state.tokens = math.min(OPS_BURST, state.tokens + (now - state.lastRefill) * OPS_PER_SECOND)
	state.lastRefill = now
	if state.tokens < cost then
		return false
	end
	state.tokens -= cost
	return true
end

local function isInteger(value: unknown): boolean
	return type(value) == "number" and value == value and value % 1 == 0 and math.abs(value) < 10000
end

local function insideVolume(block: Block): boolean
	local size = CraftDesign.blockSize(block)
	return block.gx >= 0
		and block.gy >= 0
		and block.gz >= 0
		and block.gx + size.X <= BUILD_SIZE.X
		and block.gy + size.Y <= BUILD_SIZE.Y
		and block.gz + size.Z <= BUILD_SIZE.Z
end

-- Returns nil if the block may be placed, else a reason.
function BuildService.checkPlacement(state: PlotState, block: Block): string?
	if #state.design.blocks >= MAX_BLOCKS then
		return `Block limit reached ({MAX_BLOCKS})`
	end
	if not insideVolume(block) then
		return "Outside the build area"
	end
	local free = forEachCell(block, function(key: number): boolean?
		return state.occupancy[key] == nil
	end)
	if not free then
		return "Something is already there"
	end
	if #state.design.blocks == 0 then
		if block.gy ~= 0 then
			return "The first block must sit on the floor"
		end
		return nil
	end
	for _, other in state.design.blocks do
		if CraftDesign.touches(block, other) then
			return nil
		end
	end
	return "Blocks must attach to the craft"
end

local function addBlock(state: PlotState, block: Block)
	table.insert(state.design.blocks, block)
	forEachCell(block, function(key: number): boolean?
		state.occupancy[key] = block.id
		return nil
	end)
	local model = CraftBuilder.buildBlock(block, "Real", plotOrigin(state))
	model.Parent = state.folder
end

local function removeBlock(state: PlotState, blockId: number)
	for index, block in state.design.blocks do
		if block.id == blockId then
			table.remove(state.design.blocks, index)
			forEachCell(block, function(key: number): boolean?
				if state.occupancy[key] == blockId then
					state.occupancy[key] = nil
				end
				return nil
			end)
			break
		end
	end
	local model = CraftBuilder.findBlockModel(state.folder, blockId)
	if model then
		model:Destroy()
	end
end

local function clear(state: PlotState)
	state.design = CraftDesign.new(state.design.name)
	state.occupancy = {}
	state.nextId = 1
	state.folder:ClearAllChildren()
end

-- Replaces the plot contents with a design (renumbering ids). Returns false and a reason if it does not fit.
local function loadDesign(state: PlotState, design: Design): (boolean, string?)
	local ok, reason = CraftDesign.validate(design, {
		maxBlocks = MAX_BLOCKS,
		boundsMin = Vector3.zero,
		boundsMax = BUILD_SIZE,
	})
	if not ok then
		return false, reason
	end
	clear(state)
	state.design.name = design.name
	local sorted = table.clone(design.blocks)
	table.sort(sorted, function(a, b)
		return a.id < b.id
	end)
	for _, block in sorted do
		local copy = table.clone(block)
		copy.id = state.nextId
		state.nextId += 1
		addBlock(state, copy)
	end
	return true, nil
end

local function stateFor(player: Player): PlotState?
	local index = PlotService.plotOf(player)
	return if index then plots[index] else nil
end

local function sendSlots(player: Player)
	-- string keys: a sparse number-keyed table would be truncated by remote serialization
	local names: { [string]: string } = {}
	for slot, json in SaveService.getSlots(player) do
		local design = CraftDesign.fromJson(json)
		names[tostring(slot)] = if design then design.name else "(unreadable)"
	end
	slotsRemote:FireClient(player, names)
end

local function ack(player: Player, seq: unknown, kind: string, block: Block, color: number?)
	if type(seq) == "number" and seq > 0 and seq % 1 == 0 then
		ackRemote:FireClient(player, seq, kind, block.type, block.gx, block.gy, block.gz, block.rot, color or 0)
	end
end

-- Valid UTF-8, no control characters, at most MAX_NAME_LENGTH characters (not bytes). nil if unusable.
local function cleanName(raw: string): string?
	if utf8.len(raw) == nil then
		return nil
	end
	local stripped = string.gsub(raw, "%c", "")
	local cut = utf8.offset(stripped, CraftDesign.MAX_NAME_LENGTH + 1)
	if cut then
		stripped = string.sub(stripped, 1, cut - 1)
	end
	return stripped
end

--============================================================================
-- Remote handlers
--============================================================================

local function onPlace(
	player: Player,
	partId: unknown,
	gx: unknown,
	gy: unknown,
	gz: unknown,
	rot: unknown,
	seq: unknown,
	color: unknown
)
	local state = stateFor(player)
	if state == nil then
		return
	end
	if type(partId) ~= "string" or Parts.find(partId) == nil then
		return
	end
	if not (isInteger(gx) and isInteger(gy) and isInteger(gz) and isInteger(rot)) then
		return
	end
	if (rot :: number) < 0 or (rot :: number) > 23 then
		return
	end
	if not takeToken(state, 1) then
		notify(player, "Slow down!", "Error")
		return
	end
	if state.nextId > MAX_BLOCK_ID then
		-- renumber by reloading the current design
		loadDesign(state, CraftDesign.clone(state.design))
	end
	local block: Block = {
		id = state.nextId,
		type = partId :: string,
		gx = gx :: number,
		gy = gy :: number,
		gz = gz :: number,
		rot = rot :: number,
		color = if isInteger(color) and Paint.isValid(color :: number) then color :: number else nil,
	}
	local reason = BuildService.checkPlacement(state, block)
	if reason then
		notify(player, reason, "Error")
		return
	end
	state.nextId += 1
	addBlock(state, block)
	ack(player, seq, "place", block, block.color)
end

local function onPaint(player: Player, gx: unknown, gy: unknown, gz: unknown, color: unknown, seq: unknown)
	local state = stateFor(player)
	if state == nil or not (isInteger(gx) and isInteger(gy) and isInteger(gz) and isInteger(color)) then
		return
	end
	local newColor: number? = color :: number
	if newColor == 0 then
		newColor = nil
	elseif not Paint.isValid(newColor :: number) then
		return
	end
	if not takeToken(state, 1) then
		notify(player, "Slow down!", "Error")
		return
	end
	local x, y, z = gx :: number, gy :: number, gz :: number
	if x < 0 or y < 0 or z < 0 or x >= BUILD_SIZE.X or y >= BUILD_SIZE.Y or z >= BUILD_SIZE.Z then
		return
	end
	local blockId = state.occupancy[cellKey(x, y, z)]
	local block = if blockId then CraftDesign.findBlock(state.design, blockId) else nil
	if block == nil or block.color == newColor then
		return
	end
	local previous = block.color
	block.color = newColor
	local model = CraftBuilder.findBlockModel(state.folder, block.id)
	if model then
		CraftBuilder.paintBlock(model, newColor)
	end
	ack(player, seq, "paint", block, previous)
end

local function onRemove(player: Player, gx: unknown, gy: unknown, gz: unknown, seq: unknown)
	local state = stateFor(player)
	if state == nil or not (isInteger(gx) and isInteger(gy) and isInteger(gz)) then
		return
	end
	if not takeToken(state, 1) then
		notify(player, "Slow down!", "Error")
		return
	end
	local x, y, z = gx :: number, gy :: number, gz :: number
	if x < 0 or y < 0 or z < 0 or x >= BUILD_SIZE.X or y >= BUILD_SIZE.Y or z >= BUILD_SIZE.Z then
		return
	end
	local blockId = state.occupancy[cellKey(x, y, z)]
	local block = if blockId then CraftDesign.findBlock(state.design, blockId) else nil
	if blockId and block then
		local removed = table.clone(block)
		removeBlock(state, blockId)
		ack(player, seq, "remove", removed, removed.color)
	end
end

local function onClear(player: Player)
	local state = stateFor(player)
	if state and takeToken(state, LOAD_OP_COST) then
		clear(state)
	end
end

local function onSave(player: Player, slot: unknown, name: unknown)
	local state = stateFor(player)
	if state == nil or not isInteger(slot) or (slot :: number) < 1 or (slot :: number) > GameConfig.SAVE_SLOTS then
		return
	end
	if type(name) ~= "string" then
		return
	end
	if not takeToken(state, LOAD_OP_COST) then
		notify(player, "Slow down!", "Error")
		return
	end
	local cleaned = cleanName(name :: string)
	if cleaned == nil then
		notify(player, "That name has invalid characters", "Error")
		return
	end
	local finalName = if cleaned == "" then `Craft {slot}` else cleaned
	if #state.design.blocks == 0 then
		notify(player, "Nothing to save", "Error")
		return
	end
	state.design.name = finalName
	local saved = SaveService.setSlot(player, slot :: number, CraftDesign.toJson(state.design))
	if saved then
		notify(
			player,
			if SaveService.isPersistent()
				then `Saved "{finalName}" to slot {slot}`
				else `Saved "{finalName}" to slot {slot} (this session only: DataStores unavailable)`
		)
	else
		notify(player, "Saves are still loading, try again in a moment", "Error")
	end
	sendSlots(player)
end

local function onLoad(player: Player, slot: unknown)
	local state = stateFor(player)
	if state == nil or not isInteger(slot) then
		return
	end
	if not takeToken(state, LOAD_OP_COST) then
		notify(player, "Slow down!", "Error")
		return
	end
	local json = SaveService.getSlot(player, slot :: number)
	if json == nil then
		notify(player, `Slot {slot} is empty`, "Error")
		return
	end
	local design, reason = CraftDesign.fromJson(json)
	if design == nil then
		notify(player, `Could not read slot {slot}: {reason}`, "Error")
		return
	end
	local ok, loadReason = loadDesign(state, design)
	if ok then
		notify(player, `Loaded "{design.name}"`)
	else
		notify(player, `Could not load slot {slot}: {loadReason}`, "Error")
	end
end

--============================================================================
-- Lifecycle
--============================================================================

local function onAssigned(player: Player, index: number)
	local state = plots[index]
	clear(state)
	state.tokens = OPS_BURST
	if SaveService.waitForLoad(player) and player.Parent and PlotService.plotOf(player) == index then
		local current = SaveService.getCurrent(player)
		if current then
			local design = CraftDesign.fromJson(current)
			if design then
				loadDesign(state, design)
			end
		end
		sendSlots(player)
	end
end

local function onFreed(player: Player, index: number)
	local state = plots[index]
	SaveService.setCurrent(player, if #state.design.blocks > 0 then CraftDesign.toJson(state.design) else nil)
	clear(state)
end

function BuildService.Init()
	Remotes.createAll()
	notifyRemote = Remotes.event("Notify")
	slotsRemote = Remotes.event("SaveSlots")
	ackRemote = Remotes.event("BuildAck")

	local builds = PocketService.baseBuilds()
	for index = 1, BaseLayout.PLOT_COUNT do
		local folder = Instance.new("Folder")
		folder.Name = `Plot_{index}`
		folder:SetAttribute("PlotIndex", index)
		folder.Parent = builds
		plots[index] = {
			index = index,
			design = CraftDesign.new("Untitled"),
			occupancy = {},
			nextId = 1,
			folder = folder,
			tokens = OPS_BURST,
			lastRefill = os.clock(),
		}
	end

	PlotService.onAssigned(onAssigned)
	PlotService.onFreed(onFreed)

	-- Capture every hangar into `current` before the final save flush on shutdown.
	SaveService.addShutdownHook(function()
		for _, player in Players:GetPlayers() do
			local state = stateFor(player)
			if state then
				SaveService.setCurrent(
					player,
					if #state.design.blocks > 0 then CraftDesign.toJson(state.design) else nil
				)
			end
		end
	end)
end

function BuildService.Start()
	Remotes.event("PlaceBlock").OnServerEvent:Connect(onPlace)
	Remotes.event("RemoveBlock").OnServerEvent:Connect(onRemove)
	Remotes.event("PaintBlock").OnServerEvent:Connect(onPaint)
	Remotes.event("ClearPlot").OnServerEvent:Connect(onClear)
	Remotes.event("SaveDesign").OnServerEvent:Connect(onSave)
	Remotes.event("LoadDesign").OnServerEvent:Connect(onLoad)
	-- Keep `current` fresh so a crash/shutdown still restores the hangar
	Players.PlayerRemoving:Connect(function(player: Player)
		local state = stateFor(player)
		if state then
			SaveService.setCurrent(player, if #state.design.blocks > 0 then CraftDesign.toJson(state.design) else nil)
		end
	end)
end

-- A copy of the player's hangar design (plot grid coordinates), or nil.
function BuildService.designOf(player: Player): Design?
	local state = stateFor(player)
	return if state then CraftDesign.clone(state.design) else nil
end

function BuildService.notify(player: Player, text: string, kind: string?)
	notify(player, text, kind)
end

return BuildService
