--!strict
--[[
	MapBodies (CHANGED (Map planets): new file. Steamy: "planets dont look good" on the map (M). Before this every
	body was one flat Neon ball.)
	Draws Sol, the planets and the Mun on the map for Controllers/MapViewController, plus their icons and labels.
	Pure maths (night images, limb disc, screen sizes, icon switch, rim gradient) lives in Render/MapBodiesMath.

	1. Real surfaces: each planet / moon is ScaledSpace's 24 cube-sphere patches, cloned from ScaledSpace's shared
	   patch mesh (ScaledSpace.mapSurface), each showing the SAME base EditableImage as the flight view
	   (ScaledSpace.mapPatch, Content.fromObject on the same image): no Editable memory for surfaces. A patch without
	   an image shows its own average colour (as in flight) and swaps its texture in the moment ScaledSpace paints it
	   (ScaledSpace.setMapView's listener; also told just before an image is destroyed). The surface is turned by the
	   body's real axes at the map's time (Universe.axesRotation into the map body's axes), so it spins at its day
	   rate and matches the view from orbit. No EditableMesh (ScaledSpace's Ball fallback): today's coloured balls.
	   Clouds are not drawn on the map (CHANGED (Map planets fix): their shell is MeshPart texture alpha, which the
	   night shell could not show in Studio, and white clouds would sit under the night image's edge anyway).
	2. Day and night: the map is flat-lit (SkyLighting.updateMap) and every planet / moon has a LIMB DISC: an
	   invisible thin part through its point nearest the camera, square to the line from the camera to its centre,
	   whose SurfaceGui circle lands exactly on the ball's true silhouette (MapBodiesMath header). On it a black
	   NIGHT IMAGE darkens the half facing away from Sol with a soft terminator, painted in true perspective for Sol's
	   real direction from that body (doubles), so Earth and Mars around Sol are each lit correctly at once. It is
	   repainted (one body per frame, from a kept per-pixel table) only when the angle to Sol seen from the camera or
	   the body's size moved, and turned on screen by ImageLabel.Rotation.
	   CHANGED (Map planets fix): this replaces the night shell (24 more black patch clones whose MeshPart texture
	   alpha was to darken the night side), which showed no night side in Studio; GUI alpha is what the rim proved.
	   Sol is not shaded: a Neon ball with a smooth glow image (stacked discs until it is painted or if images are
	   unavailable).
	3. Atmosphere glow: on the same limb disc, over the night image, Earth / Mars (RIMS: blue, orange-pink thinner and
	   fainter; the Mun has none) show a radial rim image whose ring sits exactly on the limb. Medium+ turn a
	   UIGradient toward Sol on screen: the sunlit limb bright, the night limb faint. Without the image: today's
	   translucent air shell. CHANGED (Map planets fix): was a camera-facing BillboardGui, a screen circle that missed
	   the limb of a ball off the screen centre (perspective draws it oval) and drew its ring across the planet.
	4. Never shrinks to nothing: below MapBodiesMath.ICON_BELOW_PX of on-screen radius (back above BALL_ABOVE_PX) a
	   body is drawn as an icon: a round dot in its colour with its name (KSP style), clickable / tappable to focus
	   it. As a ball its name sits just under its limb, so it never covers the ball. A moon's icon hides next to its
	   parent's icon.

	Tiers (Render/Quality, read when the map opens): every tier gets surfaces (they reuse ScaledSpace's mesh and
	images) and night images; images are smaller on Low (night 32 px, rim 64, glow 64: 3 x 4 KB + 2 x 16 KB + 16 KB =
	60 KB), and Low's rim is an even ring (no gradient updates). Medium: night 48, rim 128, glow 128
	(27 + 128 + 64 = 219 KB); High: night 64, rim 256, glow 256 (48 + 512 + 256 = 816 KB). All through EditableBudget
	(OTHER_BASE priority with release callbacks: a released image falls back as above and is asked for again
	IMAGE_RETRY_S later). The rims and glow are painted once by a background thread while the map is open
	(PAINT_BUDGET_S a frame), and kept; a night image repaint is one pass over its pixels (Medium 2,304).
	Parts: 24 ground patches per drawn planet / moon plus a ball and its limb disc; a body drawn as an icon has its
	parts unparented. Nothing here runs while the map is closed (update() is called by the map's render step only).

	API (MapViewController):
		MapBodies.build(folder, root, onFocus)   once, when the map is built; onFocus(bodyId) on an icon / label click
		MapBodies.open() / MapBodies.close()    the map opens / closes
		MapBodies.update(view)                   every frame while open, after the map camera moved
		MapBodies.summary(): string              F3 line
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d)
local EditableBudget = require(script.Parent.EditableBudget)
local MapBodiesMath = require(script.Parent.MapBodiesMath)
local Quality = require(script.Parent.Quality)
local ScaledSpace = require(script.Parent.ScaledSpace)
local Theme = require(script.Parent.Parent.UI.Theme)

type Vec3d = Vec3d.Vec3d

--============================================================================
-- Tunables
--============================================================================
type TierSpec = {
	phaseSize: number, -- px per side of a body's night image -- CHANGED (Map planets fix): was the shell images
	rimSize: number, -- px per side of a rim image
	rimGradient: boolean, -- turn the rim's bright side toward Sol (else an even ring)
	glowSize: number, -- px per side of Sol's glow image
}
type RimSpec = { color: Color3, inner: number, outer: number, peak: number }

local TIERS: { [string]: TierSpec } = {
	Low = { phaseSize = 32, rimSize = 64, rimGradient = false, glowSize = 64 },
	Medium = { phaseSize = 48, rimSize = 128, rimGradient = true, glowSize = 128 },
	High = { phaseSize = 64, rimSize = 256, rimGradient = true, glowSize = 256 },
}
-- Atmosphere rims (widths in limb radii; peak = strongest alpha). Bodies with air but no entry get DEFAULT_RIM.
local RIMS: { [number]: RimSpec } = {
	[Bodies.HOMEWORLD] = { color = Color3.fromRGB(150, 190, 255), inner = 0.035, outer = 0.075, peak = 0.95 },
	[Bodies.MARS] = { color = Color3.fromRGB(232, 168, 128), inner = 0.02, outer = 0.045, peak = 0.6 },
}
local DEFAULT_RIM: RimSpec = { color = Color3.fromRGB(200, 200, 220), inner = 0.02, outer = 0.04, peak = 0.5 }
-- Icon dot colours (bright, readable on black); other bodies use their Bodies colour
local ICON_COLORS: { [number]: Color3 } = {
	[Bodies.SUN] = Color3.fromRGB(255, 226, 150),
	[Bodies.HOMEWORLD] = Color3.fromRGB(110, 170, 255),
	[Bodies.MOON] = Color3.fromRGB(190, 188, 182),
	[Bodies.MARS] = Color3.fromRGB(236, 128, 82),
}
local FALLBACK_TIER = "Medium"
local MAX_BALL_SIZE = 2040 -- studs (part size limit 2048), as the map always had
local MIN_BALL_DIAMETER = 0.05 -- studs
local SURFACE_MATERIAL = Enum.Material.SmoothPlastic -- flat-lit by SkyLighting.updateMap
-- CHANGED (Map planets fix): the limb disc (night image + rim) replaces the night shell
local DISC_THICKNESS = 0.05 -- studs (an invisible part: only its SurfaceGui shows)
local DISC_CANVAS_PX = 256 -- SurfaceGui canvas per side (its images are placed by scale)
local DISC_REWRITE = 0.002 -- rewrite the disc's Size when it changed by more than 0.2% (the ring stays on the limb)
local PHASE_REPAINT_DEG = 0.75 -- repaint a night image when the angle to Sol seen from the camera moved this much ...
local PHASE_REPAINT_Q = 0.01 -- ... or radius / distance by this fraction (its per-pixel table is rebuilt too)
local PHASE_PAINTS_PER_FRAME = 1 -- night images repainted per frame (bodies take turns while the camera turns)
local ROTATION_REWRITE_DEG = 0.05 -- rewrite the night image's Rotation when it turned by more than this
local FALLBACK_BRIGHTNESS = 0.55 -- the old Neon balls' colour multiplier (fallback look)
local SOL_BRIGHTNESS = 0.95 -- Sol's Neon ball
local AIR_SHELL_TRANSPARENCY = 0.82 -- fallback atmosphere shell (no rim image)
local AIR_SHELL_DIM = 0.6
local SIZE_REWRITE_THRESHOLD = 0.003 -- only rewrite Size when the radius moved by more than 0.3%
local RIM_FRONT_MIN = 0.5 -- studs: closer than this to the body's front point the limb disc hides
local RIM_MAX_PX = 6000 -- the rim hides above this on-screen radius (the limb is far off screen)
local RIM_REWRITE = 0.02 -- gradient transparency change that rewrites the keypoints
local GLOW_DIAMETERS = 5 -- Sol's glow image: this many ball diameters across ...
local GLOW_MIN_PX = 130 -- ... but at least this many pixels ...
local GLOW_MAX_PX = 4000 -- ... and at most this many
local GLOW_COLOR = Color3.fromRGB(255, 220, 160)
-- Disc glow (until the glow image is painted, or without images): size fraction, transparency; outermost first
local GLOW_DISCS: { { size: number, transparency: number } } = {
	{ size = 1.0, transparency = 0.94 },
	{ size = 0.72, transparency = 0.88 },
	{ size = 0.5, transparency = 0.78 },
	{ size = 0.34, transparency = 0.6 },
}
local LABEL_MAX_PX = 2000 -- a ball's name hides above this on-screen radius
local LABEL_GAP_PX = 3 -- between the limb (or the dot) and the name
local ICON_DOT_PX = 9
local ICON_HIT_PX = 22 -- the dot's clickable square (touch)
local ICON_GUI_SIZE = Vector2.new(160, 44)
local IMAGE_RETRY_S = 5 -- s before a refused image is asked for again
local PAINT_BUDGET_S = 0.002 -- image painting work per frame (s), in chunks of PAINT_ROWS rows
local PAINT_ROWS = 4
local IMAGE_PRIORITY = EditableBudget.PRIORITY.OTHER_BASE
local OWNER = "MapBodies"
--============================================================================

export type View = {
	ut: number,
	mapBodyId: number, -- the body whose centre and axes the map is drawn in
	focusAbs: Vec3d, -- the focus, relative to the map body (m)
	scale: number, -- studs per metre
	origin: Vector3, -- the map origin (workspace)
	extent: number, -- studs around the origin where things are drawn
	camera: Camera,
}

type MapImage = {
	image: EditableImage?,
	handle: EditableBudget.Handle?,
	size: number,
	retryAt: number,
}

type BodyView = {
	body: Bodies.Body,
	id: number,
	isSun: boolean,
	group: Folder,
	ball: Part,
	patches: { MeshPart },
	air: Part?,
	-- CHANGED (Map planets fix): the limb disc (night image, rim) instead of the night shell and the rim billboard
	disc: Part?,
	discGui: SurfaceGui?,
	discSize: number, -- Size written last
	nightImage: ImageLabel?,
	nightReady: boolean, -- the night image shows its EditableImage
	phaseTable: MapBodiesMath.PhaseTable?,
	phaseBuf: buffer?,
	phasePhi: number, -- degrees, painted last (-1000: repaint)
	phaseQ: number, -- radius / distance painted last
	rimImage: ImageLabel?,
	rimReady: boolean, -- the rim image shows its EditableImage
	rimGradient: UIGradient?,
	rimT: { number }, -- night / day transparency last written
	glowAnchor: Attachment?,
	glowGui: BillboardGui?,
	glowImage: ImageLabel?,
	glowDiscs: Frame?,
	iconAnchor: Attachment,
	icon: BillboardGui,
	dot: Frame,
	iconMode: boolean,
	drawn: boolean,
	appliedRadius: number,
	world: Vector3, -- centre this frame (workspace)
	textured: number, -- patches showing an image
}

local MapBodies = {}

local built = false
local isOpen = false
local mapFolder: Folder? = nil
local focusCallback: ((bodyId: number) -> ())? = nil
local surface: ScaledSpace.MapSurface? = nil
local views: { BodyView } = {}
local viewById: { [number]: BodyView } = {}
local tierSpec: TierSpec = TIERS[FALLBACK_TIER]
local tierName = "" -- the tier the images were made for (a new tier repaints them)
local phaseImages: { [number]: MapImage } = {} -- CHANGED (Map planets fix): night images by body id (were shells)
local rimImages: { [number]: MapImage } = {}
local glowImage: MapImage = { image = nil, handle = nil, size = 0, retryAt = 0 }
local imagesUnavailable = false
local painting = false
local phasePaints = 0 -- night images repainted this frame

-- per-frame scratch
local moveParts: { BasePart } = {}
local moveCFrames: { CFrame } = {}
local scratchRel: Vec3d = Vec3d.zero()
local scratchSol: Vec3d = Vec3d.zero()

--============================================================================
-- Instances
--============================================================================

local function newPart(name: string, color: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.Shape = Enum.PartType.Ball
	p.Size = Vector3.one
	p.Material = material
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function dim(color: Color3, factor: number): Color3
	return Color3.new(color.R * factor, color.G * factor, color.B * factor)
end

local function cloneSurface(template: MeshPart, name: string, color: Color3, parent: Instance): MeshPart
	local part = template:Clone()
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Massless = true
	part.Material = SURFACE_MATERIAL
	part.Color = color
	part.Transparency = 0
	part.Parent = parent
	return part
end

local function setContent(apply: () -> ()): boolean
	local ok, err = pcall(function()
		apply()
	end)
	if not ok then
		imagesUnavailable = true
		EditableBudget.warnOnce(
			"MapBodies.content",
			"[MapBodies] map images are unavailable (" .. tostring(err) .. "); the map keeps its plain look."
		)
	end
	return ok
end

-- The icon / label of a body: a BillboardGui in PlayerGui (clickable), its dot and name (KSP style).
local function buildIcon(view: BodyView)
	local gui = Instance.new("BillboardGui")
	gui.Name = "MapBody_" .. view.body.Name
	gui.Adornee = view.iconAnchor
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = math.huge
	gui.Size = UDim2.fromOffset(ICON_GUI_SIZE.X, ICON_GUI_SIZE.Y)
	gui.ResetOnSpawn = false
	gui.Enabled = false
	local bodyId = view.id
	local function focus()
		local callback = focusCallback
		if callback then
			callback(bodyId)
		end
	end
	local hit = Instance.new("TextButton")
	hit.Name = "Dot"
	hit.AnchorPoint = Vector2.new(0.5, 0.5)
	hit.Position = UDim2.fromScale(0.5, 0.5)
	hit.Size = UDim2.fromOffset(ICON_HIT_PX, ICON_HIT_PX)
	hit.BackgroundTransparency = 1
	hit.Text = ""
	hit.AutoButtonColor = false
	hit.Activated:Connect(focus)
	hit.Parent = gui
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(ICON_DOT_PX, ICON_DOT_PX)
	dot.BackgroundColor3 = ICON_COLORS[view.id] or view.body.Color
	dot.BorderSizePixel = 0
	dot.Parent = hit
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = dot
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.new(0, 0, 0)
	stroke.Thickness = 1
	stroke.Transparency = 0.25
	stroke.Parent = dot
	local label = Instance.new("TextButton")
	label.Name = "Name"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0.5, ICON_DOT_PX / 2 + LABEL_GAP_PX)
	label.Size = UDim2.new(1, 0, 0, Theme.TextSizes.Small + 3)
	label.BackgroundTransparency = 1
	label.Font = Theme.Fonts.Bold
	label.TextSize = Theme.TextSizes.Small + 1
	label.TextColor3 = Theme.Colors.DigitText
	label.TextStrokeTransparency = 0.35
	label.AutoButtonColor = false
	label.Text = view.body.DisplayName
	label.Activated:Connect(focus)
	label.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	view.icon = gui
	view.dot = dot
end

-- Camera-facing BillboardGui (depth-tested, unlit) holding one image, on its own attachment under the map root.
local function billboard(name: string, root: BasePart): (Attachment, BillboardGui, ImageLabel)
	local anchor = Instance.new("Attachment")
	anchor.Name = name
	anchor.Parent = root
	local gui = Instance.new("BillboardGui")
	gui.Name = name
	gui.Adornee = anchor
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.MaxDistance = math.huge
	gui.ClipsDescendants = false
	gui.Size = UDim2.fromScale(1, 1)
	gui.Enabled = false
	local image = Instance.new("ImageLabel")
	image.BackgroundTransparency = 1
	image.Size = UDim2.fromScale(1, 1)
	image.Visible = false
	image.Parent = gui
	gui.Parent = anchor
	return anchor, gui, image
end

-- One image on the limb disc's SurfaceGui, centred, `canvas` limb radii to each edge.
local function discImage(name: string, canvas: number, zIndex: number, parent: Instance): ImageLabel
	local share = canvas / MapBodiesMath.RIM_CANVAS
	local image = Instance.new("ImageLabel")
	image.Name = name
	image.AnchorPoint = Vector2.new(0.5, 0.5)
	image.Position = UDim2.fromScale(0.5, 0.5)
	image.Size = UDim2.fromScale(share, share)
	image.BackgroundTransparency = 1
	image.ZIndex = zIndex
	image.Visible = false
	image.Parent = parent
	return image
end

--[[
	CHANGED (Map planets fix): the limb disc of a planet / moon (MapBodiesMath header): an invisible thin part whose
	Front face is turned toward the camera every frame, and a SurfaceGui (unlit, depth-tested) on it spanning
	RIM_CANVAS limb radii, holding the night image and, for bodies with air, the rim image over it.
]]
local function buildDisc(view: BodyView)
	local disc = Instance.new("Part")
	disc.Name = view.body.Name .. "LimbDisc"
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanTouch = false
	disc.CanQuery = false
	disc.CastShadow = false
	disc.Transparency = 1
	disc.Size = Vector3.new(1, 1, DISC_THICKNESS)
	disc.Parent = view.group
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Limb"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(DISC_CANVAS_PX, DISC_CANVAS_PX)
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	gui.ClipsDescendants = false
	gui.MaxDistance = math.huge
	gui.Enabled = false
	gui.Parent = disc
	view.disc, view.discGui = disc, gui
	view.nightImage = discImage("Night", MapBodiesMath.PHASE_CANVAS, 1, gui)
end

local function buildRim(view: BodyView)
	local image = discImage("Rim", MapBodiesMath.RIM_CANVAS, 2, view.discGui :: SurfaceGui)
	local gradient = Instance.new("UIGradient")
	gradient.Parent = image
	view.rimImage, view.rimGradient = image, gradient
	local air = newPart(
		view.body.Name .. "Air",
		dim(view.body.AtmosphereColor or DEFAULT_RIM.color, AIR_SHELL_DIM),
		Enum.Material.Neon,
		view.group
	)
	air.Transparency = AIR_SHELL_TRANSPARENCY
	view.air = air
end

local function buildGlow(view: BodyView, root: BasePart)
	local anchor, gui, image = billboard("SolGlow", root)
	local discs = Instance.new("Frame")
	discs.Name = "Discs"
	discs.BackgroundTransparency = 1
	discs.Size = UDim2.fromScale(1, 1)
	discs.Parent = gui
	for index, layer in GLOW_DISCS do
		local disc = Instance.new("Frame")
		disc.AnchorPoint = Vector2.new(0.5, 0.5)
		disc.Position = UDim2.fromScale(0.5, 0.5)
		disc.Size = UDim2.fromScale(layer.size, layer.size)
		disc.BackgroundColor3 = view.body.Color
		disc.BackgroundTransparency = layer.transparency
		disc.BorderSizePixel = 0
		disc.ZIndex = index
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = disc
		disc.Parent = discs
	end
	view.glowAnchor, view.glowGui, view.glowImage, view.glowDiscs = anchor, gui, image, discs
end

local function buildView(body: Bodies.Body, root: BasePart): BodyView
	local group = Instance.new("Folder")
	group.Name = body.Name
	local isSun = body.Kind == "Star"
	local color = if isSun then dim(body.Color, SOL_BRIGHTNESS) else dim(body.Color, FALLBACK_BRIGHTNESS)
	local ball = newPart(body.Name, color, Enum.Material.Neon, group)
	ball.CanQuery = true -- picked by clicks (MapViewController's raycast includes only the map folder)
	ball:SetAttribute("BodyId", body.Id)
	local anchor = Instance.new("Attachment")
	anchor.Name = body.Name .. "Icon"
	anchor.Parent = root
	local view: BodyView = {
		body = body,
		id = body.Id,
		isSun = isSun,
		group = group,
		ball = ball,
		patches = {},
		air = nil,
		disc = nil,
		discGui = nil,
		discSize = 0,
		nightImage = nil,
		nightReady = false,
		phaseTable = nil,
		phaseBuf = nil,
		phasePhi = -1000,
		phaseQ = 0,
		rimImage = nil,
		rimReady = false,
		rimGradient = nil,
		rimT = { -1, -1 },
		glowAnchor = nil,
		glowGui = nil,
		glowImage = nil,
		glowDiscs = nil,
		iconAnchor = anchor,
		icon = (nil :: any) :: BillboardGui, -- set by buildIcon
		dot = (nil :: any) :: Frame,
		iconMode = false,
		drawn = false,
		appliedRadius = 0,
		world = Vector3.zero,
		textured = 0,
	}
	buildIcon(view)
	if not isSun then
		buildDisc(view) -- CHANGED (Map planets fix)
		if body.Atmosphere then
			buildRim(view)
		end
	end
	if isSun then
		buildGlow(view, root)
	end
	return view
end

--============================================================================
-- Surfaces and textures
--============================================================================

-- A body's map patch shows ScaledSpace's current base image of that patch (or the patch's own colour).
local function applyPatch(view: BodyView, patch: number)
	local part: MeshPart? = view.patches[patch]
	if part == nil then
		return
	end
	local image, color = ScaledSpace.mapPatch(view.id, patch)
	if color then
		part.Color = color
	end
	local hadTexture = part:GetAttribute("Textured") == true
	local ok = setContent(function()
		part.TextureContent = if image then Content.fromObject(image) else Content.none
	end)
	local textured = ok and image ~= nil
	if textured ~= hadTexture then
		part:SetAttribute("Textured", textured)
		view.textured += if textured then 1 else -1
	end
end

-- ScaledSpace's listener: a base image appeared or is about to be destroyed.
local function onScaledTexture(bodyId: number, patch: number)
	local view = viewById[bodyId]
	if isOpen and view then
		applyPatch(view, patch)
	end
end

-- Builds every planet / moon's ground patches once ScaledSpace's mesh exists.
local function ensureSurfaces()
	if surface ~= nil then
		return
	end
	local found = ScaledSpace.mapSurface()
	if found == nil then
		return
	end
	surface = found
	for _, view in views do
		if view.isSun then
			continue
		end
		for patch = 1, #found.rotations do
			local _, color = ScaledSpace.mapPatch(view.id, patch)
			local ground =
				cloneSurface(found.template, string.format("Ground%02d", patch), color or view.body.Color, view.group)
			ground:SetAttribute("Textured", false)
			view.patches[patch] = ground
		end
		-- the ball stays as the click target (invisible) under the textured ground
		view.ball.Transparency = 1
		view.appliedRadius = 0
	end
end

local function applyRimImage(view: BodyView)
	local imageLabel = view.rimImage
	if imageLabel == nil then
		return
	end
	local entry = rimImages[view.id]
	local image = entry and entry.image
	local shown = image ~= nil
		and setContent(function()
			imageLabel.ImageContent = Content.fromObject(image :: EditableImage)
		end)
	imageLabel.Visible = shown
	view.rimReady = shown
	view.rimT[1], view.rimT[2] = -1, -1
	if tierSpec.rimGradient then
		imageLabel.ImageTransparency = 0
	else
		local _, even = MapBodiesMath.rimGradient(Vector3.new(0, 0, 1))
		imageLabel.ImageTransparency = even
		local gradient = view.rimGradient
		if gradient then
			gradient.Transparency = NumberSequence.new(0)
			gradient.Rotation = 0
		end
	end
end

-- CHANGED (Map planets fix): a body's night image appeared or went (released); a new one is repainted next frame.
local function applyNightImage(view: BodyView)
	local imageLabel = view.nightImage
	if imageLabel == nil then
		return
	end
	local entry = phaseImages[view.id]
	local image = entry and entry.image
	local shown = image ~= nil
		and setContent(function()
			imageLabel.ImageContent = Content.fromObject(image :: EditableImage)
		end)
	imageLabel.Visible = shown
	view.nightReady = shown
	view.phasePhi = -1000
end

local function applyGlowImage(view: BodyView)
	local imageLabel, discs = view.glowImage, view.glowDiscs
	if imageLabel == nil or discs == nil then
		return
	end
	local image = glowImage.image
	local shown = image ~= nil
		and setContent(function()
			imageLabel.ImageContent = Content.fromObject(image :: EditableImage)
		end)
	imageLabel.Visible = shown
	discs.Visible = not shown
end

--============================================================================
-- Images (night images, rims, glow): made in the background, kept
--============================================================================

local function releaseImage(entry: MapImage)
	local handle = entry.handle
	entry.image, entry.handle, entry.size = nil, nil, 0
	EditableBudget.destroy(handle)
end

-- Paints rows 0..size-1 a few at a time, yielding whenever PAINT_BUDGET_S of work is done this frame. Stops as
-- soon as the map closes (nothing of the map runs while it is closed).
local function paintRows(size: number, paintRange: (y0: number, y1: number) -> ())
	local sliceStart = os.clock()
	for y0 = 0, size - 1, PAINT_ROWS do
		if not isOpen then
			return
		end
		paintRange(y0, math.min(y0 + PAINT_ROWS, size) - 1)
		if os.clock() - sliceStart >= PAINT_BUDGET_S then
			task.wait()
			sliceStart = os.clock()
		end
	end
end

--[[
	Paints one image's pixels (spread over frames) and only then creates it through the budget and writes it, so a
	budget release can never hit a half-painted image. False when it could not be made now (refused, unavailable,
	or the map closed meanwhile).
]]
local function makeImage(
	entry: MapImage,
	size: number,
	paint: (buf: buffer, y0: number, y1: number) -> (),
	onRelease: () -> ()
): boolean
	if entry.image and entry.size == size then
		return true
	end
	if entry.image then
		releaseImage(entry)
	end
	if os.clock() < entry.retryAt or imagesUnavailable then
		return false
	end
	local buf = buffer.create(size * size * 4)
	paintRows(size, function(y0: number, y1: number)
		paint(buf, y0, y1)
	end)
	if not isOpen then
		return false
	end
	local release = function()
		entry.image, entry.handle, entry.size = nil, nil, 0
		entry.retryAt = os.clock() + IMAGE_RETRY_S
		onRelease()
	end
	local image, handle, refusal = EditableBudget.createImage(OWNER, Vector2.new(size, size), IMAGE_PRIORITY, release)
	if image == nil then
		if refusal == "unavailable" then
			imagesUnavailable = true
		else
			entry.retryAt = os.clock() + IMAGE_RETRY_S
		end
		return false
	end
	local ok = pcall(function()
		image:WritePixelsBuffer(Vector2.zero, image.Size, buf)
	end)
	if not ok then
		EditableBudget.destroy(handle)
		imagesUnavailable = true
		return false
	end
	entry.image, entry.handle, entry.size = image, handle, size
	return true
end

local function phaseEntry(bodyId: number): MapImage
	local entry = phaseImages[bodyId]
	if entry == nil then
		entry = { image = nil, handle = nil, size = 0, retryAt = 0 }
		phaseImages[bodyId] = entry
	end
	return entry
end

local function rimEntry(bodyId: number): MapImage
	local entry = rimImages[bodyId]
	if entry == nil then
		entry = { image = nil, handle = nil, size = 0, retryAt = 0 }
		rimImages[bodyId] = entry
	end
	return entry
end

-- Does any image still need painting (and may be asked for now)?
local function imagesMissing(): boolean
	if imagesUnavailable then
		return false
	end
	local now = os.clock()
	local function missing(entry: MapImage?, size: number): boolean
		return entry == nil or ((entry.image == nil or entry.size ~= size) and now >= entry.retryAt)
	end
	for _, view in views do
		if view.nightImage and missing(phaseImages[view.id], tierSpec.phaseSize) then
			return true
		end
		if view.rimImage and missing(rimImages[view.id], tierSpec.rimSize) then
			return true
		end
	end
	return missing(glowImage, tierSpec.glowSize) and viewById[Bodies.SUN] ~= nil
end

-- The background painter: one image per frame while the map is open.
local function paintImages()
	if painting or not imagesMissing() then
		return
	end
	painting = true
	task.spawn(function()
		local spec = tierSpec
		-- CHANGED (Map planets fix): night images (clear until update() paints them for Sol's real direction)
		for _, view in views do
			if not isOpen then
				break
			end
			if view.nightImage then
				local target = view
				makeImage(phaseEntry(view.id), spec.phaseSize, function() end, function()
					applyNightImage(target)
				end)
				applyNightImage(view)
			end
		end
		for _, view in views do
			if not isOpen then
				break
			end
			if view.rimImage then
				local rim = RIMS[view.id] or DEFAULT_RIM
				local target = view
				makeImage(rimEntry(view.id), spec.rimSize, function(buf: buffer, y0: number, y1: number)
					MapBodiesMath.paintRim(spec.rimSize, rim.color, rim.inner, rim.outer, rim.peak, buf, y0, y1)
				end, function()
					applyRimImage(target)
				end)
				applyRimImage(view)
			end
		end
		local sun = viewById[Bodies.SUN]
		if isOpen and sun then
			makeImage(glowImage, spec.glowSize, function(buf: buffer, y0: number, y1: number)
				MapBodiesMath.paintGlow(spec.glowSize, GLOW_COLOR, buf, y0, y1)
			end, function()
				applyGlowImage(sun)
			end)
			applyGlowImage(sun)
		end
		painting = false
	end)
end

--============================================================================
-- Per frame
--============================================================================

local function setDrawn(view: BodyView, drawn: boolean)
	if view.drawn == drawn then
		return
	end
	view.drawn = drawn
	view.group.Parent = if drawn then mapFolder else nil
	if not drawn then
		local disc, glow = view.discGui, view.glowGui
		if disc then
			disc.Enabled = false
		end
		if glow then
			glow.Enabled = false
		end
	end
end

local function resize(view: BodyView, radius: number)
	local applied = view.appliedRadius
	if applied > 0 and math.abs(radius - applied) <= SIZE_REWRITE_THRESHOLD * applied then
		return
	end
	view.appliedRadius = radius
	view.ball.Size = Vector3.one * (2 * radius)
	local air = view.air
	local atmosphere = view.body.Atmosphere
	if air and atmosphere then
		air.Size = Vector3.one * (2 * radius * (view.body.Radius + atmosphere.Top) / view.body.Radius)
	end
	local found = surface
	if found then
		for _, part in view.patches do
			part.Size = found.size * radius
		end
	end
end

-- Ground patch CFrames of a drawn body (appended to the BulkMoveTo lists).
local function placePatches(view: BodyView, centre: CFrame, radius: number, bodyRot: CFrame)
	local found = surface
	if found == nil or #view.patches == 0 then
		return
	end
	local rotations = found.rotations
	local groundOffset = CFrame.new(found.centre * radius)
	for patch, part in view.patches do
		table.insert(moveParts, part)
		table.insert(moveCFrames, centre * (bodyRot * rotations[patch]) * groundOffset)
	end
end

--[[
	CHANGED (Map planets fix): repaints a body's night image when the angle to Sol seen from the camera (phi) or
	radius / distance (q) moved enough, at most PHASE_PAINTS_PER_FRAME bodies a frame (MapBodiesMath.paintPhaseFrom;
	the per-pixel table is rebuilt only with q).
]]
local function repaintPhase(view: BodyView, cosPhi: number, q: number)
	local entry = phaseImages[view.id]
	local image = entry and entry.image
	if entry == nil or image == nil or phasePaints >= PHASE_PAINTS_PER_FRAME then
		return
	end
	local phi = math.deg(math.acos(math.clamp(cosPhi, -1, 1)))
	local qMoved = math.abs(q - view.phaseQ) > PHASE_REPAINT_Q * q
	if math.abs(phi - view.phasePhi) <= PHASE_REPAINT_DEG and not qMoved then
		return
	end
	phasePaints += 1
	local size = entry.size
	local tbl = view.phaseTable
	if tbl == nil or tbl.size ~= size or qMoved then
		tbl = MapBodiesMath.phaseTable(size, q, tbl)
		view.phaseTable = tbl
	end
	local buf = view.phaseBuf
	if buf == nil or buffer.len(buf) ~= size * size * 4 then
		buf = buffer.create(size * size * 4)
		view.phaseBuf = buf
	end
	local pixels = buf :: buffer
	local geometry = tbl :: MapBodiesMath.PhaseTable
	MapBodiesMath.paintPhaseFrom(geometry, cosPhi, pixels)
	local ok = pcall(function()
		image:WritePixelsBuffer(Vector2.zero, image.Size, pixels)
	end)
	if ok then
		view.phasePhi = phi
		view.phaseQ = geometry.q
	end
end

--[[
	CHANGED (Map planets fix): the limb disc (was the rim billboard): at the body's point nearest the camera, square to
	the line from the camera to its centre, so its circle is the ball's true silhouette. The night image turns toward
	Sol and is repainted for Sol's angle; the rim's bright side turns toward Sol (Medium+).
]]
local function placeDisc(view: BodyView, radius: number, camera: CFrame, sun: Vector3?, px: number)
	local disc, gui = view.disc, view.discGui
	if disc == nil or gui == nil then
		return
	end
	local air = view.air
	if air then
		air.Transparency = if view.rimReady then 1 else AIR_SHELL_TRANSPARENCY
	end
	local distance = (camera.Position - view.world).Magnitude
	local show = (view.rimReady or view.nightReady) and distance - radius > RIM_FRONT_MIN
	local frame, limb = CFrame.identity, 0
	if show then
		frame, limb = MapBodiesMath.discFrame(camera.Position, view.world, radius, camera.UpVector)
	end
	local size = 2 * limb * MapBodiesMath.RIM_CANVAS
	show = show and size <= MAX_BALL_SIZE
	gui.Enabled = show
	if not show then
		return
	end
	if math.abs(size - view.discSize) > DISC_REWRITE * view.discSize then
		view.discSize = size
		disc.Size = Vector3.new(size, size, DISC_THICKNESS)
	end
	table.insert(moveParts, disc)
	table.insert(moveCFrames, frame)
	local rimLabel, nightLabel = view.rimImage, view.nightImage
	local rimShown = view.rimReady and px < RIM_MAX_PX
	if rimLabel and rimLabel.Visible ~= rimShown then
		rimLabel.Visible = rimShown
	end
	if sun == nil then
		return
	end
	local sunView = MapBodiesMath.discSun(frame, sun)
	if nightLabel and view.nightReady then
		local rotation = MapBodiesMath.screenRotation(sunView)
		if math.abs(nightLabel.Rotation - rotation) > ROTATION_REWRITE_DEG then
			nightLabel.Rotation = rotation
		end
		repaintPhase(view, sunView.Z, radius / distance)
	end
	local gradient = view.rimGradient
	if gradient == nil or not tierSpec.rimGradient or not view.rimReady then
		return
	end
	local rotation, tNight, tDay = MapBodiesMath.rimGradient(sunView)
	gradient.Rotation = rotation
	local last = view.rimT
	if math.abs(last[1] - tNight) > RIM_REWRITE or math.abs(last[2] - tDay) > RIM_REWRITE then
		last[1], last[2] = tNight, tDay
		local e0, e1 = MapBodiesMath.rimKeypoints(MapBodiesMath.RIM_CANVAS)
		gradient.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, tNight),
			NumberSequenceKeypoint.new(e0, tNight),
			NumberSequenceKeypoint.new(e1, tDay),
			NumberSequenceKeypoint.new(1, tDay),
		})
	end
end

-- Sol's glow: centred on Sol (its middle is hidden by the ball), GLOW_DIAMETERS across within pixel limits.
local function placeGlow(view: BodyView, centre: Vector3, radius: number, pxPerStud: number)
	local gui, anchor = view.glowGui, view.glowAnchor
	if gui == nil or anchor == nil then
		return
	end
	anchor.Position = centre
	local studs = math.max(2 * radius * GLOW_DIAMETERS, GLOW_MIN_PX / pxPerStud)
	studs = math.min(studs, GLOW_MAX_PX / pxPerStud)
	gui.Size = UDim2.fromScale(studs, studs)
	gui.Enabled = true
end

-- Icon (dot + name) or the ball's name under its limb.
local function placeIcon(view: BodyView, centre: Vector3, inRange: boolean, drawn: boolean, px: number, limb: number)
	view.iconAnchor.Position = centre
	local icon = view.icon
	if not inRange or not (view.iconMode or drawn) or (not view.iconMode and px > LABEL_MAX_PX) then
		icon.Enabled = false
		return
	end
	icon.Enabled = true
	view.dot.Visible = view.iconMode
	local offset = if view.iconMode then Vector3.zero else Vector3.new(0, -limb, 0)
	if icon.StudsOffset ~= offset then
		icon.StudsOffset = offset
	end
end

local function updateBody(view: BodyView, v: View, solRel: Vec3d, camera: CFrame, tanHalf: number, height: number)
	local rel = Universe.bodyOffset(view.id, v.mapBodyId, v.ut, scratchRel)
	local f, s = v.focusAbs, v.scale
	local centre = Vector3.new((rel.x - f.x) * s, (rel.y - f.y) * s, (rel.z - f.z) * s)
	local radius = view.body.Radius * s
	local world = v.origin + centre
	view.world = world
	local distance = (world - camera.Position).Magnitude
	local px = MapBodiesMath.pixelRadius(distance, radius, tanHalf, height)
	view.iconMode = MapBodiesMath.nextIconMode(view.iconMode, px)
	local drawable = 2 * radius <= MAX_BALL_SIZE
		and centre.Magnitude - radius <= v.extent
		and 2 * radius > MIN_BALL_DIAMETER
	local drawn = drawable and not view.iconMode
	setDrawn(view, drawn)
	placeIcon(view, centre, centre.Magnitude <= v.extent, drawn, px, MapBodiesMath.limbRadius(distance, radius))
	if not drawn then
		return
	end
	resize(view, radius)
	local centreCFrame = CFrame.new(world)
	table.insert(moveParts, view.ball)
	table.insert(moveCFrames, centreCFrame)
	local air = view.air
	if air then
		table.insert(moveParts, air)
		table.insert(moveCFrames, centreCFrame)
	end
	if view.isSun then
		placeGlow(view, centre, radius, height * 0.5 / (math.max(distance, 1e-3) * tanHalf))
		return
	end
	local sun = MapBodiesMath.sunDirection(rel, solRel)
	placePatches(view, centreCFrame, radius, Universe.axesRotation(view.id, v.mapBodyId, v.ut))
	placeDisc(view, radius, camera, sun, px) -- CHANGED (Map planets fix): night image + rim on the limb disc
end

-- A moon's icon hides while its parent's icon sits right next to it on screen.
local function mergeMoonIcons(camera: Camera)
	for _, view in views do
		local parentId = view.body.ParentId
		local parent = if parentId then viewById[parentId] else nil
		if parent and view.iconMode and view.icon.Enabled and parent.iconMode and parent.icon.Enabled then
			local a = camera:WorldToViewportPoint(view.world)
			local b = camera:WorldToViewportPoint(parent.world)
			local gap = Vector2.new(a.X - b.X, a.Y - b.Y).Magnitude
			if MapBodiesMath.moonIconHidden(true, gap) then
				view.icon.Enabled = false
			end
		end
	end
end

--============================================================================
-- API
--============================================================================

function MapBodies.build(folder: Folder, root: BasePart, onFocus: (bodyId: number) -> ())
	if built then
		return
	end
	built = true
	mapFolder, focusCallback = folder, onFocus
	for _, body in Bodies.physicalBodies() do
		local view = buildView(body, root)
		table.insert(views, view)
		viewById[body.Id] = view
	end
end

function MapBodies.open()
	if not built or isOpen then
		return
	end
	isOpen = true
	local tier = Quality.tier()
	tierSpec = TIERS[tier] or TIERS[FALLBACK_TIER]
	if tier ~= tierName then
		-- a new graphics tier: the images are made again at its sizes (nothing shows the old ones meanwhile)
		tierName = tier
		for _, entry in phaseImages do
			releaseImage(entry)
		end
		for _, entry in rimImages do
			releaseImage(entry)
		end
		releaseImage(glowImage)
	end
	ensureSurfaces()
	ScaledSpace.setMapView(true, onScaledTexture)
	for _, view in views do
		for patch in view.patches do
			applyPatch(view, patch)
		end
		applyNightImage(view)
		applyRimImage(view)
		applyGlowImage(view)
		view.iconMode = false
	end
	paintImages()
end

function MapBodies.close()
	if not isOpen then
		return
	end
	isOpen = false
	ScaledSpace.setMapView(false, nil)
	for _, view in views do
		view.icon.Enabled = false
		setDrawn(view, false)
	end
end

function MapBodies.update(v: View)
	if not isOpen then
		return
	end
	local camera = v.camera
	local cameraCFrame = camera.CFrame
	local tanHalf = math.tan(math.rad(camera.FieldOfView) * 0.5)
	local height = math.max(camera.ViewportSize.Y, 1)
	local solRel = Universe.bodyOffset(Bodies.SUN, v.mapBodyId, v.ut, scratchSol)
	phasePaints = 0
	table.clear(moveParts)
	table.clear(moveCFrames)
	for _, view in views do
		updateBody(view, v, solRel, cameraCFrame, tanHalf, height)
	end
	if #moveParts > 0 then
		Workspace:BulkMoveTo(moveParts, moveCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
	mergeMoonIcons(camera)
	paintImages() -- after a refusal: asks again once IMAGE_RETRY_S passed (cheap check otherwise)
end

function MapBodies.summary(): string
	local textured, total = 0, 0
	for _, view in views do
		textured += view.textured
		total += #view.patches
	end
	local rims, nights = 0, 0
	for _, entry in rimImages do
		if entry.image then
			rims += 1
		end
	end
	for _, view in views do
		if view.nightReady then
			nights += 1
		end
	end
	return string.format(
		"bodies: ground %d/%d  night %d  rims %d  glow %s%s",
		textured,
		total,
		nights,
		rims,
		if glowImage.image then "on" else "off",
		if surface == nil then "  (no mesh: plain balls)" else ""
	)
end

return MapBodies
