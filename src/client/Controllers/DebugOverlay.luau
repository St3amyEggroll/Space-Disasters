--!strict
--[[
	DebugOverlay (F3)
	A text panel with live diagnostics. Other controllers add their own lines and timings:

		DebugOverlay.addLine("pocket", 30, function() return "Pocket: 3 CRAFT_ALIGNED epoch 7" end)
		DebugOverlay.recordTiming("Universe", elapsedMs)   -- shown as a smoothed average (CHANGED (Far layer smooth):
		                                                     -- and the peak of the last ~1 s: a hitch shows)
		DebugOverlay.countBytes("CraftStates", bytes)      -- CHANGED (Phase 3): received bytes/s per stream

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
local PeakMeter = require(script.Parent.Parent.Render.PeakMeter) -- CHANGED (Far layer smooth): peaks (hitches)
local UniverseTime = require(ReplicatedStorage.Shared.Sim.UniverseTime)

--============================================================================
-- Tunables
--============================================================================
local TOGGLE_KEY = Enum.KeyCode.F3
local REFRESH_S = GameConfig.DEBUG_OVERLAY_REFRESH
local PART_COUNT_REFRESH_S = 2 -- counting descendants is not free
local SMOOTHING = 0.1 -- exponential moving average factor for FPS and timings
local PEAK_WINDOW_S = 1 -- CHANGED (Far layer smooth): the peaks shown are of the last one to two of these
local FONT = Enum.Font.Code
local TEXT_SIZE = 14
local BACKGROUND = Color3.fromRGB(10, 12, 18)
local BACKGROUND_TRANSPARENCY = 0.35
local TEXT_COLOR = Color3.fromRGB(220, 255, 220)
local CLIENT_UNIVERSE_NAME = "ClientUniverse" -- render folder created by UniverseRenderer (Phase 2)
local STREAM_WINDOW_S = 1 -- CHANGED (Phase 3): byte counters are averaged over this window
local NET_BUDGET_KB = GameConfig.NET_BUDGET_BYTES_PER_S / 1000 -- CHANGED (Phase 3): shown next to stream rates
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
local timingPeaks: { [string]: PeakMeter.Meter } = {} -- CHANGED (Far layer smooth)
local framePeak = PeakMeter.new(PEAK_WINDOW_S) -- CHANGED (Far layer smooth): the longest frame
local timingOrder: { string } = {}
local visible = false
local gui: ScreenGui? = nil
local label: TextLabel? = nil

local smoothedFrameMs = 16.7

-- CHANGED (Phase 3): per-stream received byte counters (e.g. CraftStates), shown as bytes/s
type StreamCounter = {
	bytes: number,
	packets: number,
	windowStart: number,
	bytesPerSecond: number,
	packetsPerSecond: number,
}
local streams: { [string]: StreamCounter } = {}
local streamOrder: { string } = {}
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

-- Records how long a system took this frame (ms); displayed as a smoothed average. CHANGED (Far layer smooth): and
-- the peak of the last ~1 s (Steamy's "the rocket sometimes jitters": one slow frame hides in an average)
function DebugOverlay.recordTiming(name: string, ms: number)
	local peak = timingPeaks[name]
	if peak == nil then
		peak = PeakMeter.new(PEAK_WINDOW_S)
		timingPeaks[name] = peak
	end
	PeakMeter.add(peak, os.clock(), ms)
	local previous = timings[name]
	if previous == nil then
		timings[name] = ms
		table.insert(timingOrder, name)
		table.sort(timingOrder)
	else
		timings[name] = previous + (ms - previous) * SMOOTHING
	end
end

local function rollStream(counter: StreamCounter, now: number)
	local span = now - counter.windowStart
	if span >= STREAM_WINDOW_S then
		counter.bytesPerSecond = counter.bytes / span
		counter.packetsPerSecond = counter.packets / span
		counter.bytes = 0
		counter.packets = 0
		counter.windowStart = now
	end
end

-- CHANGED (Phase 3): counts one received packet of `bytes` payload bytes on a named stream (shown per second).
function DebugOverlay.countBytes(name: string, bytes: number)
	local now = os.clock()
	local counter = streams[name]
	if counter == nil then
		counter = { bytes = 0, packets = 0, windowStart = now, bytesPerSecond = 0, packetsPerSecond = 0 }
		streams[name] = counter
		table.insert(streamOrder, name)
		table.sort(streamOrder)
	end
	rollStream(counter, now)
	counter.bytes += bytes
	counter.packets += 1
end

-- CHANGED (Phase 3): bytes per second received on a named stream over the last full window.
function DebugOverlay.streamBytesPerSecond(name: string): number
	local counter = streams[name]
	if counter == nil then
		return 0
	end
	rollStream(counter, os.clock())
	return counter.bytesPerSecond
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
		table.insert(out, "Timings (ms, average / peak ~1 s):") -- CHANGED (Far layer smooth): + the peak
		local now = os.clock()
		for _, name in timingOrder do
			local peak = timingPeaks[name]
			table.insert(
				out,
				string.format(
					"  %-18s %6.3f / %6.2f",
					name,
					timings[name],
					if peak then PeakMeter.peak(peak, now) else 0
				)
			)
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
		-- CHANGED (Far layer smooth): + the longest frame of the last ~1 s (a hitch)
		return string.format(
			"FPS %.0f  (%.2f ms, longest %.1f ms)",
			1000 / math.max(smoothedFrameMs, 1e-3),
			smoothedFrameMs,
			PeakMeter.peak(framePeak, os.clock())
		)
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
	-- CHANGED (Phase 3): per-stream receive rates (this client), against the per-client network budget
	DebugOverlay.addLine("streams", 4.5, function()
		if #streamOrder == 0 then
			return string.format("Streams: none yet  (budget %.0f KB/s)", NET_BUDGET_KB)
		end
		local parts = {}
		for _, name in streamOrder do
			local counter = streams[name]
			rollStream(counter, os.clock())
			table.insert(
				parts,
				string.format("%s %.2f KB/s %.0f pkt/s", name, counter.bytesPerSecond / 1000, counter.packetsPerSecond)
			)
		end
		return `Streams in: {table.concat(parts, "  ")}  (budget {NET_BUDGET_KB} KB/s)`
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
		PeakMeter.add(framePeak, os.clock(), dt * 1000) -- CHANGED (Far layer smooth)
	end)

	while true do
		if visible and label then
			label.Text = buildText()
		end
		task.wait(REFRESH_S)
	end
end

return DebugOverlay
