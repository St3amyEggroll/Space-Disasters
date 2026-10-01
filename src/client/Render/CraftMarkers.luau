--!strict
--[[
	CraftMarkers (Phase 3, spec 7.6 Layer 4 / 7.7 LOD markers)
	Client-only BillboardGui markers for crafts that are too far for a cosmetic copy, or too small on screen
	(RemoteCraftRenderer decides which). Each marker shows the craft name, its owner and the true distance.

	Placement (invariant I1): RemoteCraftRenderer passes the direction to the craft in pocket axes (computed from the
	true positions in doubles, after subtracting the camera's true position) and the true distance. The marker's
	attachment is put at most ANCHOR_DISTANCE studs from the camera along that direction, so it always sits well
	inside the engine's draw distance and its float position stays small; on screen it is in the same place as the
	craft. Markers draw on top of everything; RemoteCraftRenderer hides those whose line of sight a planet blocks.

	All markers hang off one anchored, invisible, non-colliding part in the RemoteCrafts folder (never inside a
	pocket, so PocketController's hiding never touches them).
]]

local Players = game:GetService("Players")

--============================================================================
-- Tunables
--============================================================================
local ANCHOR_DISTANCE = 200 -- studs from the camera
local GUI_SIZE = UDim2.fromOffset(180, 80) -- the dot is at the centre, the two text lines above it
local DOT_SIZE = 9 -- px
local NAME_TEXT_SIZE = 14
local DISTANCE_TEXT_SIZE = 12
local NAME_MAX_CHARS = 28
local OWN_COLOR = Color3.fromRGB(120, 255, 150) -- your own crafts
local OTHER_COLOR = Color3.fromRGB(140, 210, 255)
local DISTANCE_COLOR = Color3.fromRGB(215, 225, 235)
local STROKE_COLOR = Color3.fromRGB(0, 0, 0)
local STROKE_TRANSPARENCY = 0.35
local FONT = Enum.Font.GothamBold
local DISTANCE_FONT = Enum.Font.Gotham
--============================================================================

type Marker = {
	attachment: Attachment,
	gui: BillboardGui,
	nameLabel: TextLabel,
	distanceLabel: TextLabel,
	lastDistanceText: string,
}

local CraftMarkers = {}

local anchorPart: Part? = nil
local markers: { [number]: Marker } = {}

local function label(parent: Instance, name: string, font: Enum.Font, size: number, color: Color3, y: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.BackgroundTransparency = 1
	text.AnchorPoint = Vector2.new(0.5, 1)
	text.Position = UDim2.new(0.5, 0, 0, y)
	text.Size = UDim2.new(1, 0, 0, size + 2)
	text.Font = font
	text.TextSize = size
	text.TextColor3 = color
	text.TextStrokeColor3 = STROKE_COLOR
	text.TextStrokeTransparency = STROKE_TRANSPARENCY
	text.TextXAlignment = Enum.TextXAlignment.Center
	text.TextTruncate = Enum.TextTruncate.AtEnd
	text.Text = ""
	text.Parent = parent
	return text
end

-- Short, readable distance: 850 m, 12.3 km, 1,234 km.
function CraftMarkers.formatDistance(meters: number): string
	if meters < 1000 then
		return string.format("%d m", math.floor(meters + 0.5))
	elseif meters < 100000 then
		return string.format("%.1f km", meters / 1000)
	end
	local km = tostring(math.floor(meters / 1000 + 0.5))
	local grouped = string.reverse((string.gsub(string.reverse(km), "(%d%d%d)", "%1,")))
	if string.sub(grouped, 1, 1) == "," then
		grouped = string.sub(grouped, 2)
	end
	return grouped .. " km"
end

local function create(id: number, title: string, own: boolean): Marker
	local anchor = anchorPart :: Part
	local attachment = Instance.new("Attachment")
	attachment.Name = `Marker_{id}`
	attachment.Parent = anchor

	local gui = Instance.new("BillboardGui")
	gui.Name = "CraftMarker"
	gui.Size = GUI_SIZE
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = math.huge
	gui.ClipsDescendants = false
	gui.ResetOnSpawn = false
	gui.Adornee = attachment
	gui.Parent = attachment

	-- the dot sits exactly on the craft (the gui's centre); the text sits above it
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(DOT_SIZE, DOT_SIZE)
	dot.Rotation = 45
	dot.BackgroundColor3 = if own then OWN_COLOR else OTHER_COLOR
	dot.BorderSizePixel = 0
	dot.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Color = STROKE_COLOR
	stroke.Thickness = 1
	stroke.Transparency = STROKE_TRANSPARENCY
	stroke.Parent = dot

	local half = GUI_SIZE.Y.Offset / 2
	local nameLabel = label(gui, "Name", FONT, NAME_TEXT_SIZE, if own then OWN_COLOR else OTHER_COLOR, half - 22)
	local distanceLabel = label(gui, "Distance", DISTANCE_FONT, DISTANCE_TEXT_SIZE, DISTANCE_COLOR, half - 8)
	nameLabel.Text = if #title > NAME_MAX_CHARS then string.sub(title, 1, NAME_MAX_CHARS - 1) .. "…" else title

	local marker: Marker = {
		attachment = attachment,
		gui = gui,
		nameLabel = nameLabel,
		distanceLabel = distanceLabel,
		lastDistanceText = "",
	}
	markers[id] = marker
	return marker
end

function CraftMarkers.init(parent: Instance)
	local anchor = Instance.new("Part")
	anchor.Name = "MarkerAnchor"
	anchor.Size = Vector3.one * 0.2
	anchor.Transparency = 1
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.CFrame = CFrame.identity
	anchor.Parent = parent
	anchorPart = anchor
end

--[[
	Shows (or moves) the marker of craft `id`. `direction` = unit vector from the camera toward the craft in pocket
	(workspace) axes; `distance` = true distance in metres; `title` = "Name (Owner)"; `ownerUserId` colours your own.
]]
function CraftMarkers.show(
	id: number,
	cameraPosition: Vector3,
	direction: Vector3,
	distance: number,
	title: string,
	ownerUserId: number
)
	if anchorPart == nil then
		return
	end
	local marker = markers[id]
	if marker == nil then
		local localPlayer = Players.LocalPlayer
		marker = create(id, title, localPlayer ~= nil and ownerUserId == localPlayer.UserId)
	end
	local m = marker :: Marker
	m.attachment.Position = cameraPosition + direction * math.min(distance, ANCHOR_DISTANCE)
	local text = CraftMarkers.formatDistance(distance)
	if text ~= m.lastDistanceText then
		m.lastDistanceText = text
		m.distanceLabel.Text = text
	end
	if not m.gui.Enabled then
		m.gui.Enabled = true
	end
end

function CraftMarkers.hide(id: number)
	local marker = markers[id]
	if marker and marker.gui.Enabled then
		marker.gui.Enabled = false
	end
end

function CraftMarkers.remove(id: number)
	local marker = markers[id]
	if marker then
		marker.attachment:Destroy()
		markers[id] = nil
	end
end

-- Markers currently shown (debug overlay).
function CraftMarkers.shownCount(): number
	local count = 0
	for _, marker in markers do
		if marker.gui.Enabled then
			count += 1
		end
	end
	return count
end

return CraftMarkers
