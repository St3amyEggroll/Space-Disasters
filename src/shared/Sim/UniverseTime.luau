--!strict
--[[
	UniverseTime
	The Universal Time (UT) clock shared by server and clients (invariant I10: all simulation is a function of UT).

	  UT = utAnchor + (workspace:GetServerTimeNow() - serverTimeAnchor) * warpRate

	The server (TimeService) owns the anchors and writes them to ReplicatedStorage.Globals. They are stored in ONE
	string attribute ("TimeAnchors" = "<utAnchor>|<serverTimeAnchor>|<warpRate>", full double precision) so a
	re-anchor replicates atomically; three separate attributes could be seen half-updated for a frame, which would
	make UT jump. See DECISIONS.md.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

--============================================================================
-- Tunables
--============================================================================
local GLOBALS_NAME = "Globals"
local ANCHORS_ATTRIBUTE = "TimeAnchors"
local WAIT_FOR_GLOBALS_TIMEOUT = 30 -- s
--============================================================================

export type Anchors = {
	utAnchor: number,
	serverTimeAnchor: number,
	warpRate: number,
}

local UniverseTime = {}

UniverseTime.GLOBALS_NAME = GLOBALS_NAME
UniverseTime.ANCHORS_ATTRIBUTE = ANCHORS_ATTRIBUTE

local anchors: Anchors = { utAnchor = 0, serverTimeAnchor = 0, warpRate = 1 }
local bound: Instance? = nil
local rateChanged = Instance.new("BindableEvent")

function UniverseTime.encode(value: Anchors): string
	return string.format("%.17g|%.17g|%.17g", value.utAnchor, value.serverTimeAnchor, value.warpRate)
end

function UniverseTime.decode(text: string): Anchors?
	local a, b, c = string.match(text, "^([^|]+)|([^|]+)|([^|]+)$")
	local ut, serverTime, rate = tonumber(a), tonumber(b), tonumber(c)
	if ut == nil or serverTime == nil or rate == nil then
		return nil
	end
	return { utAnchor = ut, serverTimeAnchor = serverTime, warpRate = rate }
end

local function readAnchors(globals: Instance)
	local raw = globals:GetAttribute(ANCHORS_ATTRIBUTE)
	if type(raw) ~= "string" then
		return
	end
	local decoded = UniverseTime.decode(raw)
	if decoded == nil then
		warn(`[UniverseTime] malformed {ANCHORS_ATTRIBUTE}: {raw}`)
		return
	end
	local oldRate = anchors.warpRate
	anchors = decoded
	if decoded.warpRate ~= oldRate then
		rateChanged:Fire(decoded.warpRate)
	end
end

-- Starts following the anchors on a Globals instance. Idempotent.
function UniverseTime.bind(globals: Instance)
	if bound == globals then
		return
	end
	assert(bound == nil, "UniverseTime is already bound to another Globals instance")
	bound = globals
	readAnchors(globals)
	globals:GetAttributeChangedSignal(ANCHORS_ATTRIBUTE):Connect(function()
		readAnchors(globals)
	end)
end

-- Yields until ReplicatedStorage.Globals exists (created by TimeService), then binds to it.
function UniverseTime.waitForGlobals(): Instance
	local globals = ReplicatedStorage:WaitForChild(GLOBALS_NAME, WAIT_FOR_GLOBALS_TIMEOUT)
	if globals == nil then
		error("[UniverseTime] ReplicatedStorage.Globals never appeared; is the server bootstrap running?")
	end
	UniverseTime.bind(globals)
	return globals
end

function UniverseTime.isBound(): boolean
	return bound ~= nil
end

-- Current Universal Time in seconds (double).
function UniverseTime.now(): number
	return anchors.utAnchor + (Workspace:GetServerTimeNow() - anchors.serverTimeAnchor) * anchors.warpRate
end

-- UT at a given server-clock time (for timestamping events that happened at a known server time).
function UniverseTime.atServerTime(serverTime: number): number
	return anchors.utAnchor + (serverTime - anchors.serverTimeAnchor) * anchors.warpRate
end

function UniverseTime.warpRate(): number
	return anchors.warpRate
end

function UniverseTime.anchors(): Anchors
	return table.clone(anchors)
end

-- Fires with the new rate whenever the warp rate changes.
function UniverseTime.onRateChanged(callback: (rate: number) -> ()): RBXScriptConnection
	return rateChanged.Event:Connect(callback)
end

-- "T+ 1d 02:03:04.5" style display (days of 24 h, for readability; not the in-game day length).
function UniverseTime.format(ut: number): string
	local sign = if ut < 0 then "-" else "+"
	local t = math.abs(ut)
	local days = math.floor(t / 86400)
	t -= days * 86400
	local hours = math.floor(t / 3600)
	t -= hours * 3600
	local minutes = math.floor(t / 60)
	local seconds = t - minutes * 60
	if days > 0 then
		return string.format("T%s %dd %02d:%02d:%04.1f", sign, days, hours, minutes, seconds)
	end
	return string.format("T%s %02d:%02d:%04.1f", sign, hours, minutes, seconds)
end

return table.freeze(UniverseTime)
