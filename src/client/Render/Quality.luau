--!strict
--[[
	Quality (Steamy: "this should all be working on mobile ... and should go with graphics quality")
	One place that turns the player's Roblox graphics quality and device into a detail tier for our own render
	layers (effects, terrain, props). Every costly client layer reads this instead of polling UserGameSettings.

	Tier from UserGameSettings.SavedQualityLevel (0 = Automatic, 1..10):
	  * 1..3  -> "Low", 4..6 -> "Medium", 7..10 -> "High"
	  * Automatic -> "Medium" on phones / tablets (touch without a keyboard), "High" otherwise
	A phone never goes above "Medium", whatever its slider says (thermals and battery).

	API:
		Quality.tier(): Tier                      "Low" | "Medium" | "High"
		Quality.scale(): number                   detail multiplier for counts / rates (LOW_SCALE .. 1)
		Quality.pick<T>(low: T, medium: T, high: T): T
		Quality.isMobile(): boolean
		Quality.onChanged(fn: (tier: Tier) -> ()): RBXScriptConnection
	The tier is re-read every POLL_S seconds (the graphics slider has no change event).
]]

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

--============================================================================
-- Tunables
--============================================================================
local POLL_S = 1
local LOW_MAX_LEVEL = 3 -- SavedQualityLevel 1..3 is Low
local MEDIUM_MAX_LEVEL = 6 -- 4..6 is Medium, 7..10 High
local LOW_SCALE = 0.35
local MEDIUM_SCALE = 0.65
local HIGH_SCALE = 1
--============================================================================

export type Tier = "Low" | "Medium" | "High"

local Quality = {}

local userGameSettings = UserSettings():GetService("UserGameSettings")
local changed = Instance.new("BindableEvent")
local current: Tier = "High"
local pollTimer = 0
local started = false

function Quality.isMobile(): boolean
	return UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
end

local function compute(): Tier
	local level = userGameSettings.SavedQualityLevel.Value
	local mobile = Quality.isMobile()
	local tier: Tier
	if level == 0 then
		tier = if mobile then "Medium" else "High"
	elseif level <= LOW_MAX_LEVEL then
		tier = "Low"
	elseif level <= MEDIUM_MAX_LEVEL then
		tier = "Medium"
	else
		tier = "High"
	end
	if mobile and tier == "High" then
		tier = "Medium"
	end
	return tier
end

local function refresh()
	local tier = compute()
	if tier ~= current then
		current = tier
		changed:Fire(tier)
	end
end

local function ensureStarted()
	if started then
		return
	end
	started = true
	current = compute()
	RunService.Heartbeat:Connect(function(dt: number)
		pollTimer += dt
		if pollTimer >= POLL_S then
			pollTimer = 0
			refresh()
		end
	end)
end

function Quality.tier(): Tier
	ensureStarted()
	return current
end

function Quality.scale(): number
	local tier = Quality.tier()
	return if tier == "Low" then LOW_SCALE elseif tier == "Medium" then MEDIUM_SCALE else HIGH_SCALE
end

function Quality.pick<T>(low: T, medium: T, high: T): T
	local tier = Quality.tier()
	return if tier == "Low" then low elseif tier == "Medium" then medium else high
end

function Quality.onChanged(fn: (tier: Tier) -> ()): RBXScriptConnection
	ensureStarted()
	return changed.Event:Connect(fn)
end

return Quality
