--!strict
--[[
	DebugOverlay (F3)
	A text panel with live diagnostics. Other controllers add their own lines and timings:

		DebugOverlay.addLine("pocket", 30, function() return "Pocket: 3 CRAFT_ALIGNED epoch 7" end)
		DebugOverlay.recordTiming("Universe", elapsedMs)   -- shown as a smoothed average

	Built-in lines: UT, warp rate, FPS / frame time, ping, network in/out, memory, part counts, character position.
	Line order is by the `order` number (lower first). Built-ins use 0-19; systems should use 20+.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)

--============================================================================
-- Tunables
--============================================================================
local TOGGLE_KEY = Enum.KeyCode.F3
local REFRESH_S = GameConfig.DEBUG_OVERLAY_REFRESH
local PART_COUNT_REFRESH_S = 2 -- counting descendants is not free
local SMOOTHING = 0.1 -- exponential moving average factor for FPS and timings
local FONT = Enum.Font.Code
local TEXT_SIZE = 14
local BACKGROUND = Color3.fromRGB(10, 12, 18)
local BACKGROUND_TRANSPARENCY = 0.35
local TEXT_COLOR = Color3.fromRGB(220, 255, 220)
local CLIENT_UNIVERSE_NAME = "ClientUniverse" -- render folder created by UniverseRenderer (Phase 2)
--============================================================================

type LineProvider = () -> string

type Line = {
	key: string,
	order: number,
	provider: LineProvider,
}

local DebugOverlay = {}

local lines: { Line } = {}
local timings: { [string]: number } = {}
local timingOrder: { string } = {}
local visible = false
local gui: ScreenGui? = nil
local label: TextLabel? = nil

local smoothedFrameMs = 16.7
local partCount = 0
local universePartCount = 0
local lastPartCount = -math.huge

local function sortLines()
	table.sort(lines, function(a, b)
		if a.order == b.order then
			return a.key < b.key
		end
		return a.order < b.order
	end)
end

-- Adds or replaces a line. The provider runs only while the overlay is visible.
function DebugOverlay.addLine(key: string, order: number, provider: LineProvider)
	for index, line in lines do
		if line.key == key then
			lines[index] = { key = key, order = order, provider = provider }
			sortLines()
			return
		end
	end
	table.insert(lines, { key = key, order = order, provider = provider })
	sortLines()
end

function DebugOverlay.removeLine(key: string)
	for index, line in lines do
		if line.key == key then
			table.remove(lines, index)
			return
		end
	end
end

-- Records how long a system took this frame (ms); displayed as a smoothed average.
function DebugOverlay.recordTiming(name: string, ms: number)
	local previous = timings[name]
	if previous == nil then
		timings[name] = ms
		table.insert(timingOrder, name)
		table.sort(timingOrder)
	else
		timings[name] = previous + (ms - previous) * SMOOTHING
	end
end

function DebugOverlay.isVisible(): boolean
	return visible
end

local function countParts()
	local now = os.clock()
	if now - lastPartCount < PART_COUNT_REFRESH_S then
		return
	end
	lastPartCount = now
	local total = 0
	for _, descendant in Workspace:GetDescendants() do
		if descendant:IsA("BasePart") then
			total += 1
		end
	end
	partCount = total
	local universe = Workspace:FindFirstChild(CLIENT_UNIVERSE_NAME)
	local universeTotal = 0
	if universe then
		for _, descendant in universe:GetDescendants() do
			if descendant:IsA("BasePart") then
				universeTotal += 1
			end
		end
	end
	universePartCount = universeTotal
end

local function buildText(): string
	local out = table.create(#lines + #timingOrder + 2)
	for _, line in lines do
		local ok, text = pcall(line.provider)
		table.insert(out, if ok then tostring(text) else `{line.key}: <error {text}>`)
	end
	if #timingOrder > 0 then
		table.insert(out, "Timings (ms):")
		for _, name in timingOrder do
			table.insert(out, string.format("  %-18s %6.3f", name, timings[name]))
		end
	end
	return table.concat(out, "\n")
end

local function createGui()
	local player = Players.LocalPlayer
	local screen = Instance.new("ScreenGui")
	screen.Name = "DebugOverlay"
	screen.ResetOnSpawn = false
	screen.DisplayOrder = 1000
	screen.Enabled = false

	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.Position = UDim2.fromOffset(8, 8)
	text.Size = UDim2.fromOffset(0, 0)
	text.AutomaticSize = Enum.AutomaticSize.XY
	text.BackgroundColor3 = BACKGROUND
	text.BackgroundTransparency = BACKGROUND_TRANSPARENCY
	text.BorderSizePixel = 0
	text.Font = FONT
	text.TextSize = TEXT_SIZE
	text.TextColor3 = TEXT_COLOR
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Text = ""
	text.Parent = screen

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 6)
	padding.PaddingBottom = UDim.new(0, 6)
	padding.PaddingLeft = UDim.new(0, 8)
	padding.PaddingRight = UDim.new(0, 8)
	padding.Parent = text

	screen.Parent = player:WaitForChild("PlayerGui")
	gui = screen
	label = text
end

local function addBuiltInLines()
	DebugOverlay.addLine("title", 0, function()
		return `{GameConfig.GAME_NAME} debug  [{TOGGLE_KEY.Name} to hide]`
	end)
	DebugOverlay.addLine("ut", 1, function()
		local ut = UniverseTime.now()
		return string.format("UT %s  (%.2f s)", UniverseTime.format(ut), ut)
	end)
	DebugOverlay.addLine("warp", 2, function()
		return string.format("Warp %gx", UniverseTime.warpRate())
	end)
	DebugOverlay.addLine("fps", 3, function()
		return string.format("FPS %.0f  (%.2f ms)", 1000 / math.max(smoothedFrameMs, 1e-3), smoothedFrameMs)
	end)
	DebugOverlay.addLine("net", 4, function()
		local ping = Players.LocalPlayer:GetNetworkPing() * 1000
		return string.format(
			"Net in %.2f KB/s  out %.2f KB/s  ping %.0f ms",
			Stats.DataReceiveKbps,
			Stats.DataSendKbps,
			ping
		)
	end)
	DebugOverlay.addLine("memory", 5, function()
		return string.format("Memory %.0f MB", Stats:GetTotalMemoryUsageMb())
	end)
	DebugOverlay.addLine("parts", 6, function()
		countParts()
		return string.format("Parts: workspace %d  ClientUniverse %d", partCount, universePartCount)
	end)
	DebugOverlay.addLine("position", 7, function()
		local character = Players.LocalPlayer.Character
		local root = if character then character:FindFirstChild("HumanoidRootPart") else nil
		if root and root:IsA("BasePart") then
			local p = root.Position
			return string.format("Character (%.1f, %.1f, %.1f)  gravity %.1f", p.X, p.Y, p.Z, Workspace.Gravity)
		end
		return "Character: none"
	end)
end

local function setVisible(value: boolean)
	visible = value
	if gui then
		gui.Enabled = value
	end
end

function DebugOverlay.Init()
	createGui()
	addBuiltInLines()
end

function DebugOverlay.Start()
	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then
			return
		end
		if input.KeyCode == TOGGLE_KEY then
			setVisible(not visible)
		end
	end)

	RunService.PreRender:Connect(function(dt: number)
		smoothedFrameMs += (dt * 1000 - smoothedFrameMs) * SMOOTHING
	end)

	while true do
		if visible and label then
			label.Text = buildText()
		end
		task.wait(REFRESH_S)
	end
end

return DebugOverlay
