--!strict
--[[
	SpikeKit
	Shared plumbing for the Phase 0 engine spikes. Spikes run in a throwaway place (spikes.project.json), never in
	the game place.

	Each spike is a ModuleScript in SpikeShared/Spikes that returns a SpikeDef. The client shows a menu; clicking a
	spike tells the server to start it, the server runs def.Server (if any) and tells every client to run
	def.Client (if any). All results are printed on the SERVER with the prefix "[SPIKE <id>]", so Steamy copies
	one Output window (the Server window in a multi-client test, or the single Output in Play Solo).

	Client helpers:
	  ctx.report(line)                 send a result line to the server Output
	  ctx.ask(question, options)       show a question with buttons, yield for the answer, report "Q => A"
	  ctx.status(text)                 show a status line on screen (not reported)
	  ctx.remote(name) / unreliableRemote(name)   spike-scoped remotes created by the server side
	Server helpers:
	  ctx.report(line), ctx.remote(name), ctx.unreliableRemote(name), ctx.players()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

--============================================================================
-- Tunables
--============================================================================
local REMOTES_FOLDER_NAME = "SpikeRemotes"
local REMOTE_WAIT_TIMEOUT = 15 -- s a client waits for a spike remote before erroring
local UI_FONT = Enum.Font.GothamMedium
local UI_BG = Color3.fromRGB(20, 22, 30)
local UI_ACCENT = Color3.fromRGB(255, 140, 40)
local UI_TEXT = Color3.fromRGB(235, 235, 240)
--============================================================================

export type ServerContext = {
	id: string,
	report: (line: string) -> (),
	remote: (name: string) -> RemoteEvent,
	unreliableRemote: (name: string) -> UnreliableRemoteEvent,
	players: () -> { Player },
}

export type ClientContext = {
	id: string,
	player: Player,
	isFirstPlayer: boolean, -- true for the player who joined first (role assignment in 2-player spikes)
	report: (line: string) -> (),
	ask: (question: string, options: { string }) -> string,
	status: (text: string) -> (),
	remote: (name: string) -> RemoteEvent,
	unreliableRemote: (name: string) -> UnreliableRemoteEvent,
}

export type SpikeDef = {
	Id: string, -- "S1" .. "S10"
	Title: string,
	Players: number, -- players required (1 = Play Solo is fine, 2 = Test > Clients and Servers with 2 players)
	Instructions: string, -- shown before starting; say what to look at
	Server: ((ctx: ServerContext) -> ())?,
	Client: ((ctx: ClientContext) -> ())?,
}

local SpikeKit = {}

SpikeKit.CONTROL_NAME = "Control"
SpikeKit.REPORT_NAME = "Report"

--============================================================================
-- Registry
--============================================================================

local function spikeOrder(id: string): number
	return tonumber(string.match(id, "%d+")) or 999
end

-- All spike definitions, sorted S1..S10.
function SpikeKit.all(): { SpikeDef }
	local folder = script.Parent:WaitForChild("Spikes")
	local defs: { SpikeDef } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") then
			local ok, def = pcall(require, child)
			if ok and type(def) == "table" then
				table.insert(defs, def :: SpikeDef)
			else
				warn(`[SpikeKit] failed to load {child.Name}: {def}`)
			end
		end
	end
	table.sort(defs, function(a, b)
		return spikeOrder(a.Id) < spikeOrder(b.Id)
	end)
	return defs
end

function SpikeKit.find(id: string): SpikeDef?
	for _, def in SpikeKit.all() do
		if def.Id == id then
			return def
		end
	end
	return nil
end

--============================================================================
-- Remotes
--============================================================================

-- Server: returns (creating if needed) the shared remotes folder.
function SpikeKit.remotesFolder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	assert(RunService:IsServer(), "Only the server creates the spike remotes folder")
	local folder = Instance.new("Folder")
	folder.Name = REMOTES_FOLDER_NAME
	folder.Parent = ReplicatedStorage
	return folder
end

local function serverRemote(fullName: string, className: "RemoteEvent" | "UnreliableRemoteEvent"): Instance
	local folder = SpikeKit.remotesFolder()
	local existing = folder:FindFirstChild(fullName)
	if existing then
		assert(existing.ClassName == className, `Remote {fullName} exists with class {existing.ClassName}`)
		return existing
	end
	local remote = Instance.new(className)
	remote.Name = fullName
	remote.Parent = folder
	return remote
end

local function clientRemote(fullName: string): Instance
	local folder = ReplicatedStorage:WaitForChild(REMOTES_FOLDER_NAME, REMOTE_WAIT_TIMEOUT)
	assert(folder, "Spike remotes folder never appeared (is SpikeServer running?)")
	local remote = folder:WaitForChild(fullName, REMOTE_WAIT_TIMEOUT)
	assert(remote, `Spike remote {fullName} never appeared`)
	return remote
end

function SpikeKit.serverRemote(name: string): RemoteEvent
	return serverRemote(name, "RemoteEvent") :: RemoteEvent
end

function SpikeKit.clientRemote(name: string): RemoteEvent
	local remote = clientRemote(name)
	assert(remote:IsA("RemoteEvent"), `{name} is not a RemoteEvent`)
	return remote
end

--============================================================================
-- Contexts
--============================================================================

function SpikeKit.serverContext(id: string): ServerContext
	return {
		id = id,
		report = function(line: string)
			print(`[SPIKE {id}] {line}`)
		end,
		remote = function(name: string): RemoteEvent
			return serverRemote(id .. "_" .. name, "RemoteEvent") :: RemoteEvent
		end,
		unreliableRemote = function(name: string): UnreliableRemoteEvent
			return serverRemote(id .. "_" .. name, "UnreliableRemoteEvent") :: UnreliableRemoteEvent
		end,
		players = function(): { Player }
			return Players:GetPlayers()
		end,
	}
end

--============================================================================
-- Client UI
--============================================================================

local function makeGui(player: Player): ScreenGui
	local playerGui = player:WaitForChild("PlayerGui")
	local existing = playerGui:FindFirstChild("SpikeAskGui")
	if existing and existing:IsA("ScreenGui") then
		return existing
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "SpikeAskGui"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 100
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local status = Instance.new("TextLabel")
	status.Name = "Status"
	status.AnchorPoint = Vector2.new(0.5, 0)
	status.Position = UDim2.new(0.5, 0, 0, 48)
	status.Size = UDim2.new(0.6, 0, 0, 28)
	status.BackgroundColor3 = UI_BG
	status.BackgroundTransparency = 0.25
	status.TextColor3 = UI_TEXT
	status.Font = UI_FONT
	status.TextSize = 16
	status.Text = ""
	status.Visible = false
	status.Parent = gui

	return gui
end

-- Shows a question with one button per option at the bottom of the screen and yields until one is clicked.
function SpikeKit.ask(player: Player, question: string, options: { string }): string
	local gui = makeGui(player)
	local panel = Instance.new("Frame")
	panel.Name = "Question"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.new(0.5, 0, 1, -24)
	panel.Size = UDim2.new(0, 720, 0, 150)
	panel.BackgroundColor3 = UI_BG
	panel.BackgroundTransparency = 0.1
	panel.Parent = gui

	local stroke = Instance.new("UIStroke")
	stroke.Color = UI_ACCENT
	stroke.Thickness = 2
	stroke.Parent = panel

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.new(0, 12, 0, 8)
	label.Size = UDim2.new(1, -24, 0, 80)
	label.Font = UI_FONT
	label.TextSize = 18
	label.TextWrapped = true
	label.TextColor3 = UI_TEXT
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Text = question
	label.Parent = panel

	local row = Instance.new("Frame")
	row.BackgroundTransparency = 1
	row.Position = UDim2.new(0, 12, 1, -52)
	row.Size = UDim2.new(1, -24, 0, 40)
	row.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, 8)
	layout.Parent = row

	local chosen: string? = nil
	local signal = Instance.new("BindableEvent")
	for _, option in options do
		local button = Instance.new("TextButton")
		button.Size = UDim2.new(0, math.max(90, 10 * #option + 24), 1, 0)
		button.BackgroundColor3 = UI_ACCENT
		button.TextColor3 = Color3.new(0, 0, 0)
		button.Font = UI_FONT
		button.TextSize = 16
		button.Text = option
		button.Parent = row
		button.Activated:Connect(function()
			if chosen == nil then
				chosen = option
				signal:Fire()
			end
		end)
	end

	signal.Event:Wait()
	signal:Destroy()
	panel:Destroy()
	return chosen :: string
end

function SpikeKit.status(player: Player, text: string)
	local gui = makeGui(player)
	local status = gui:FindFirstChild("Status")
	if status and status:IsA("TextLabel") then
		status.Text = text
		status.Visible = text ~= ""
	end
end

-- Deterministic on every client: the player whose name sorts first ("Player1" in a Studio multi-client test).
local function isFirstPlayer(player: Player): boolean
	for _, other in Players:GetPlayers() do
		if other.Name < player.Name then
			return false
		end
	end
	return true
end

function SpikeKit.clientContext(id: string, player: Player): ClientContext
	local reportRemote = SpikeKit.clientRemote(SpikeKit.REPORT_NAME)
	local function report(line: string)
		reportRemote:FireServer(id, line)
	end
	return {
		id = id,
		player = player,
		isFirstPlayer = isFirstPlayer(player),
		report = report,
		ask = function(question: string, options: { string }): string
			local answer = SpikeKit.ask(player, question, options)
			report(`Q: {question} => {answer}`)
			return answer
		end,
		status = function(text: string)
			SpikeKit.status(player, text)
		end,
		remote = function(name: string): RemoteEvent
			local remote = clientRemote(id .. "_" .. name)
			assert(remote:IsA("RemoteEvent"), `{name} is not a RemoteEvent`)
			return remote
		end,
		unreliableRemote = function(name: string): UnreliableRemoteEvent
			local remote = clientRemote(id .. "_" .. name)
			assert(remote:IsA("UnreliableRemoteEvent"), `{name} is not an UnreliableRemoteEvent`)
			return remote
		end,
	}
end

return SpikeKit
