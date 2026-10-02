--!strict
--[[
	ShadowGate (CHANGED (Rocket shudder / orbit shadows): new)
	The one owner of CastShadow on parts that several systems want to keep from casting a shadow.

	Steamy (screenshot in orbit at 684 m/s, scaled mode): "still a shaddow forming": a line of five dark, rocket-shaped
	shadows trailing on the planet below the craft. Above the proxy handover the ground is a ScaledSpace proxy drawn
	a few hundred studs from the camera (NEAR_RENDER_RADIUS), wrapped in nested translucent atmosphere shells (up to
	four, PlanetDetail.atmosphereLayers). Roblox's sun shadows from the TRUE-SCALE craft land on the fake surface AND
	on every shell, each one deeper along the sun ray: one shadow per receiving layer, offset along the sun's
	projected direction (ground + four shells = the five copies). A true-scale shadow on a scaled proxy is wrong at
	any scale, so while the camera is not in surface mode nothing true-scale casts a shadow.

	Reasons
	  Several systems may want a part's shadow off for different reasons (PocketController hides other pockets,
	  this gate hides true-scale shadows above the handover). Each one suppresses / releases with its own reason; the
	  part's original CastShadow is saved on the first suppression and restored when the last reason is released.
	  So the reasons never fight (a part hidden by its pocket AND gated by scaled mode gets its shadow back only
	  when both are gone, and never a stale "false" saved by the other system).

	Scaled-mode gate (UniverseRenderer, every frame; cheap: a table lookup per root unless the mode changes)
	  ShadowGate.setScaledMode(on, roots)  on = the ground is a proxy (not ScaledSpace.isSurfaceMode()). While on,
	      every BasePart under each root (the pocket's folder: its crafts; RemoteCrafts: copies, markers, puppets;
	      the Effects folder; every player's character: seated crew, astronauts, the EVA jetpack) is suppressed, and
	      parts added under a root later too (DescendantAdded). Off releases every part it suppressed, wherever it
	      went since (a craft moved to another pocket keeps no stale "off").

	API:
	  ShadowGate.suppress(part, reason)   shadow off for this reason (saves the original once)
	  ShadowGate.release(part, reason)    drops the reason; restores the original when no reason is left
	  ShadowGate.setScaledMode(on, roots)
	  ShadowGate.isScaledMode() -> boolean
]]

--============================================================================
-- Tunables
--============================================================================
local SCALED_REASON = "ScaledSpace"
--============================================================================

local ShadowGate = {}

-- per part: original CastShadow and the reasons it is suppressed for (weak keys: destroyed parts drop out)
local original: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local reasons: { [BasePart]: { [string]: boolean } } = setmetatable({}, { __mode = "k" }) :: any

local scaledOn = false
local gatedParts: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local watched: { [Instance]: RBXScriptConnection } = {}

function ShadowGate.suppress(part: BasePart, reason: string)
	local set = reasons[part]
	if set == nil then
		set = {}
		reasons[part] = set
		original[part] = part.CastShadow
	end
	assert(set)
	set[reason] = true
	if part.CastShadow then
		part.CastShadow = false
	end
end

function ShadowGate.release(part: BasePart, reason: string)
	local set = reasons[part]
	if set == nil or not set[reason] then
		return
	end
	set[reason] = nil
	if next(set) ~= nil then
		return
	end
	reasons[part] = nil
	local saved = original[part]
	original[part] = nil
	if saved ~= nil and part.CastShadow ~= saved then
		part.CastShadow = saved
	end
end

local function gate(instance: Instance)
	if instance:IsA("BasePart") then
		gatedParts[instance] = true
		ShadowGate.suppress(instance, SCALED_REASON)
	end
end

local function watch(root: Instance)
	if watched[root] then
		return
	end
	gate(root)
	for _, descendant in root:GetDescendants() do
		gate(descendant)
	end
	watched[root] = root.DescendantAdded:Connect(gate)
end

function ShadowGate.setScaledMode(on: boolean, roots: { Instance })
	if on then
		scaledOn = true
		for _, root in roots do
			watch(root)
		end
		for root, connection in watched do
			if root.Parent == nil then -- a gone character or folder: stop listening (its parts stay gated until off)
				connection:Disconnect()
				watched[root] = nil
			end
		end
		return
	end
	if not scaledOn then
		return
	end
	scaledOn = false
	for root, connection in watched do
		connection:Disconnect()
		watched[root] = nil
	end
	for part in gatedParts do
		ShadowGate.release(part, SCALED_REASON)
	end
	table.clear(gatedParts)
end

function ShadowGate.isScaledMode(): boolean
	return scaledOn
end

return table.freeze(ShadowGate)
