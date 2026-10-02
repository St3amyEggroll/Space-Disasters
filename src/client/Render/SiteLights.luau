--!strict
--[[
	SiteLights (CHANGED (Night review): new; Steamy: "this should all be working on mobile ... and should go with
	graphics quality")
	The launch site's Lights (HomeBase: 16 street / launch-road lamps and 8 launch-tower beacons, all PointLights)
	follow Render/Quality: they are only drawn on the tiers in LIGHT_TIERS ("High"; phones are at most "Medium", and
	like EffectsMath's budgets no PointLights are drawn there). Applied to the real base (workspace.Pockets.Pocket_0's
	Site, from UniverseRenderer) and to Surface's cosmetic copy, again on every Quality.onChanged, and to lights added
	under a tracked root later.

	A light that is off is UNPARENTED (remembered here with its parent) rather than disabled: PocketController hides
	other pockets by saving and restoring Light.Enabled, so writing Enabled here would fight it (a restore could turn
	a light back on on Medium). An unparented light cannot be touched by it, and when it is put back
	PocketController's DescendantAdded hooks hide or show it like any new instance. Only this client changes.

	API:
		SiteLights.track(root): () -> ()      applies the tier to root's lights now and on every change; returns the
		                                      function that stops tracking it (call it before destroying root)
		SiteLights.watchBase()                tracks the base pocket's Site once it has replicated (UniverseRenderer)
		SiteLights.lightsOn(tier): boolean    whether a tier draws the site's lights
]]

local Workspace = game:GetService("Workspace")

local Quality = require(script.Parent.Quality)

--============================================================================
-- Tunables
--============================================================================
local LIGHT_TIERS: { [string]: boolean } = { High = true } -- tiers that draw the site's lights
local POCKETS_NAME = "Pockets"
local BASE_POCKET_NAME = "Pocket_0" -- PocketService's base pocket folder
local SITE_NAME = "Site"
--============================================================================

type Tracked = {
	root: Instance,
	homes: { [Light]: Instance }, -- every light seen under root -> the parent it belongs under
	connection: RBXScriptConnection,
}

local SiteLights = {}

local tracked: { [Tracked]: boolean } = {}
local tierConnection: RBXScriptConnection? = nil
local baseWatched = false

function SiteLights.lightsOn(tier: string): boolean
	return LIGHT_TIERS[tier] == true
end

-- Puts one light where the tier wants it (pcall: the light or its parent may be mid-destroy).
local function place(light: Light, home: Instance, on: boolean)
	if on then
		if light.Parent == nil and home.Parent ~= nil then
			pcall(function()
				light.Parent = home
			end)
		end
	elseif light.Parent ~= nil then
		pcall(function()
			light.Parent = nil
		end)
	end
end

local function apply(entry: Tracked)
	local on = SiteLights.lightsOn(Quality.tier())
	for light, home in entry.homes do
		place(light, home, on)
	end
end

local function remember(entry: Tracked, instance: Instance)
	if instance:IsA("Light") and not entry.homes[instance] then
		local home = instance.Parent
		if home then
			entry.homes[instance] = home
			place(instance, home, SiteLights.lightsOn(Quality.tier()))
		end
	end
end

function SiteLights.track(root: Instance): () -> ()
	local entry: Tracked
	entry = {
		root = root,
		homes = {},
		connection = root.DescendantAdded:Connect(function(instance: Instance)
			remember(entry, instance)
		end),
	}
	for _, instance in root:GetDescendants() do
		remember(entry, instance)
	end
	tracked[entry] = true
	if tierConnection == nil then
		tierConnection = Quality.onChanged(function()
			for each in tracked do
				apply(each)
			end
		end)
	end
	return function()
		if tracked[entry] then
			tracked[entry] = nil
			entry.connection:Disconnect()
		end
	end
end

function SiteLights.watchBase()
	if baseWatched then
		return
	end
	baseWatched = true
	task.spawn(function()
		local pockets = Workspace:WaitForChild(POCKETS_NAME)
		local base = pockets:WaitForChild(BASE_POCKET_NAME)
		local site = base:WaitForChild(SITE_NAME)
		SiteLights.track(site)
	end)
end

return table.freeze(SiteLights)
