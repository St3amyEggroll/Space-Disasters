--!strict
--[[
	FarLayer (CHANGED (Far layer): new)
	The far ground as a BACKDROP layer, the way KSP draws its scaled scenery: behind every real 3D object, with its
	own exact depth order inside it.

	Why: Roblox draws nothing beyond its draw distance, so TerrainMesh draws far ground bands shrunk toward the camera
	while the near band (the ground the rocket, the base and the players stand on) stays at true scale. Wherever a
	true-scale ridge or crater rim hides farther ground, that farther ground, drawn shrunk, lands IN FRONT of the
	ridge (ring ground at a true 1.2 km drawn at 0.5x = 600 studs, in front of a true ridge at 800 studs). Only one
	uniform scale about the camera keeps the order from every camera, and the near band must stay at scale 1, so no
	depth map or culling can close that seam from every camera (D45-D51a; Steamy kept seeing it, "even when not
	flying ... craters and mountains mess it up").

	How:
	  * A cube of six panels (one part per face, workspace axes) around the camera, like Render/SkyCube's, but
	    nearer (FarLayerMath.halfSize: inside the draw distance and in front of the SkyCube, at most ~1020 studs so
	    one part covers a face). Each panel carries an unlit SurfaceGui (LightInfluence 0) holding a ViewportFrame
	    whose camera sits at the eye, looks along the face's normal with a 90-degree view (a little more for the
	    panels' overlap) and a square frame, so the six pictures form an exact cubemap of the backdrop scene seen from
	    the eye (FarLayerMath). The panels are far, so ANY real 3D geometry nearer than them (the near band, the
	    base, rockets, players, effects) draws in front of the picture.
	  * The backdrop scene: a copy of EVERY terrain band (the near band too, so far ground that near ridges hide is
	    hidden inside the picture as well), all at ONE uniform scale about the eye (backdropScale: the largest band
	    fits the part limit). A uniform scale about the eye keeps every direction and the order of every depth, so
	    the picture is the true one from wherever the camera is: no per-band factors, no depth map, no drift.
	    TerrainMesh builds its bands as true geometry while the layer is on (no depth map, no culling) and draws only
	    the bands at true scale in the 3D world; the scaled ones live only here. The copies are clones of the band
	    parts (the same EditableMesh: no Editable memory), parented to each ViewportFrame.
	  * Where the backdrop shows no ground its ViewportFrame is clear (BackgroundTransparency 1): Roblox's sky, or
	    the SkyCube's painted Mars sky behind it, shows through.
	  * Light inside the ViewportFrames (Ambient, LightColor, LightDirection) follows the sun and Roblox's outdoor
	    light (SkyLighting's values); day / night and the distance haze are baked into the vertex colours already.
	  * Cost: only the faces that can show in the camera's view are drawn (FarLayerMath.visibleFaces, usually 2-4);
	    the copies are posed only when the camera moved (a turning camera rewrites nothing). Resolution per Quality
	    tier (CanvasSize). Low (phones) keeps today's 3D bands by default (the "mesh" mode): every visible face draws
	    every band again; /farground still turns the layer on there.
	  * /farground (DebugService -> DebugView "farground") switches between "layer" (default on Medium / High) and
	    "mesh" (the depth-mapped 3D bands of D51a); TerrainMesh rebuilds its bands for the new mode. /bands tints the
	    copies too (their part colour). The F3 "Terrain:" line shows the mode (summary()).
	Only Studio can confirm: band clones rendering inside ViewportFrames, the picture's sharpness and seams at the
	tier's CanvasSize, the cost per visible face, and the light match between the 3D near band and the picture.

	API (driven by TerrainMesh, and DebugView for toggle):
		FarLayer.init(parent)                    the cube's folder goes under `parent` while shown
		FarLayer.active(): boolean               the layer draws the scaled bands (mode "layer")
		FarLayer.mode(): string                  "layer" | "mesh"
		FarLayer.toggle(): string                /farground: the other mode (kept for the session), returns it
		FarLayer.consumeChanged(): boolean       true once after the mode changed (TerrainMesh re-plans)
		FarLayer.clear()                         a new set of bands follows (placeBands, every frame)
		FarLayer.setBand(id, part, offset, rot, size)
		                                         band `id`: its part, its box centre minus the camera (workspace
		                                         axes, studs = metres), its rotation, its true size
		FarLayer.commit(ctx)                     draws the set given since clear() (none: hidden)
		FarLayer.hide()                          nothing to draw (no ground, plates, another mode)
		FarLayer.isShown(): boolean              the backdrop is on screen (TerrainMesh.groundReach)
		FarLayer.setTint(on, colours, further)   the /bands view: band i's copies in colours[i] (further: the rest)
		FarLayer.summary(): string               the F3 line's mode
]]

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local FarLayerMath = require(script.Parent.FarLayerMath)
local Quality = require(script.Parent.Quality)
local RenderContext = require(script.Parent.RenderContext)

--============================================================================
-- Tunables
--============================================================================
-- per Quality tier: the default mode and the SurfaceGui canvas (pixels across a face; at 1080p and a 70-degree view
-- a face spans ~1500 pixels on screen, the far ground is hazy)
type TierParams = { mode: string, canvas: number }
-- CHANGED (Far layer off by default): Steamy in Studio: "i cant see any of the planet really ... untill i go to space":
-- the backdrop drew no ground in Studio (the band copies do not show in the ViewportFrames), so every tier defaults to
-- "mesh" again until that is fixed; /farground still switches to "layer" for testing
local TIERS: { [string]: TierParams } = {
	Low = { mode = "mesh", canvas = 384 },
	Medium = { mode = "mesh", canvas = 640 },
	High = { mode = "mesh", canvas = 1024 },
}
local HALF_SIZE: FarLayerMath.HalfSizeParams = {
	fraction = 0.8, -- x the draw distance (the face centres stay drawn)
	min = 300, -- studs
	max = 1020, -- studs: one part per face (2 x 1020 x (1 + PANEL_OVERLAP) within the 2048-stud part limit)
	skyFraction = 0.9, -- Render/SkyCube's HALF_SIZE_FRACTION / HALF_SIZE_MIN: the backdrop stays in front of it
	skyMin = 400,
}
local PART_LIMIT = 2040 -- studs: the largest band copy (engine limit 2048)
local PANEL_OVERLAP = 0.003 -- panels are this much larger than their face (no hairline seam; FOV matches)
local PANEL_DEPTH = 0.2 -- studs
local MAX_GUI_DISTANCE = 1e6 -- studs (SurfaceGui.MaxDistance)
local RESIZE_THRESHOLD = 0.02 -- relative half-size change that re-lays out the panels
local VISIBLE_MARGIN = math.rad(12) -- a face this close to the view's sampled rays is drawn too
local LIGHT_PER_BRIGHTNESS = 0.4 -- ViewportFrame LightColor = white x Lighting.Brightness x this (at most 1)
local LIGHT_STEP = 0.01 -- rewrite a ViewportFrame's light only when it moved more than this
local POSE_STEP = 1e-3 -- studs: rewrite a copy's CFrame only when it moved more than this
local FOLDER_NAME = "FarLayer"
local NEAR_BAND = 0 -- TerrainMath.NEAR_BAND (keeps its own colours under /bands)
--============================================================================

type Copy = { copy: MeshPart, source: MeshPart, size: Vector3, at: Vector3, rot: CFrame }
type Panel = {
	part: Part,
	gui: SurfaceGui,
	view: ViewportFrame,
	camera: Camera,
	face: FarLayerMath.Face,
	copies: { [number]: Copy }, -- band id -> its copy in this face's ViewportFrame
	shown: boolean,
}
type Band = { part: MeshPart, offset: Vector3, rot: CFrame, size: Vector3 }

local FarLayer = {}

local folder: Folder? = nil
local home: Instance? = nil
local panels: { Panel } = {}
local panelParts: { BasePart } = {}
local panelCFrames: { CFrame } = {} -- about the eye
local panelMoved: { CFrame } = {} -- this frame's (BulkMoveTo)
local halfSize = 0
local canvas = TIERS.High.canvas
local tierName = "High"
local modeState = FarLayerMath.newModeState() -- /farground's choice for the session (FarLayerMath)
local current: { [number]: Band } = {} -- the bands given since clear()
local pool: { Band } = {}
local visible: { boolean } = { false, false, false, false, false, false }
local shownNow = false
local scaleNow = 1
local light = { ambient = Color3.new(), color = Color3.new(), direction = Vector3.zero }
local tint: { on: boolean, colours: { Color3 }, further: Color3 } =
	{ on = false, colours = {}, further = Color3.new(1, 1, 1) }

local function newPanel(parent: Folder, face: FarLayerMath.Face): Panel
	local part = Instance.new("Part")
	part.Name = "FarPanel"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, PANEL_DEPTH)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Far"
	gui.Face = Enum.NormalId.Front -- looks at the eye (FarLayerMath.panelCFrame)
	gui.LightInfluence = 0
	gui.Brightness = 1
	gui.AlwaysOnTop = false
	gui.MaxDistance = MAX_GUI_DISTANCE
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(canvas, canvas)
	gui.ClipsDescendants = true
	gui.Enabled = false -- commit draws only the faces that can show
	gui.Adornee = part
	gui.Parent = part

	local view = Instance.new("ViewportFrame")
	view.Name = "Ground"
	view.BorderSizePixel = 0
	view.Size = UDim2.fromScale(1, 1)
	view.BackgroundTransparency = 1 -- the sky (Roblox's, or the SkyCube's) shows where there is no ground
	view.Parent = gui

	local camera = Instance.new("Camera")
	camera.Name = "Eye"
	camera.FieldOfView = FarLayerMath.fieldOfView(PANEL_OVERLAP)
	camera.CFrame = FarLayerMath.faceCamera(face)
	camera.Parent = view
	view.CurrentCamera = camera

	part.Parent = parent
	return { part = part, gui = gui, view = view, camera = camera, face = face, copies = {}, shown = false }
end

local function layout(h: number)
	for index, panel in panels do
		local side = 2 * h * (1 + PANEL_OVERLAP)
		panel.part.Size = Vector3.new(side, side, PANEL_DEPTH)
		panelCFrames[index] = FarLayerMath.panelCFrame(panel.face, h)
	end
	halfSize = h
end

local function destroyCopy(panel: Panel, id: number)
	local entry = panel.copies[id]
	if entry then
		entry.copy:Destroy()
		panel.copies[id] = nil
	end
end

local function releaseCopies()
	for _, panel in panels do
		for id in panel.copies do
			destroyCopy(panel, id)
		end
	end
end

local function tintOf(id: number): Color3
	if not tint.on or id == NEAR_BAND then
		return Color3.new(1, 1, 1) -- vertex colours carry the biome (the near band keeps its own under /bands too)
	end
	return tint.colours[id] or tint.further
end

-- A copy of a band part for one face (the same mesh content: no Editable memory). Nil if it cannot be cloned.
local function newCopy(panel: Panel, id: number, source: MeshPart): Copy?
	local ok, made = pcall(function(): Instance?
		return source:Clone()
	end)
	if not ok or made == nil or not made:IsA("MeshPart") then
		return nil
	end
	local copy = made :: MeshPart
	for _, child in copy:GetChildren() do
		child:Destroy() -- e.g. the /bands Highlight (Highlights do not draw in a ViewportFrame)
	end
	copy.Name = "Far" .. source.Name
	copy.Anchored = true
	copy.CastShadow = false
	copy.Transparency = 0
	copy.Color = tintOf(id)
	copy.Parent = panel.view
	return {
		copy = copy,
		source = source,
		size = Vector3.zero,
		at = Vector3.new(math.huge, 0, 0),
		rot = CFrame.identity,
	}
end

-- Poses every band's copy in one face (cloning new parts), at the backdrop's one scale about the eye.
local function syncFace(panel: Panel, scale: number)
	for id, band in current do
		local existing: Copy? = panel.copies[id]
		if existing and existing.source ~= band.part then
			destroyCopy(panel, id) -- the band was rebuilt: a new part
			existing = nil
		end
		local copy = existing or newCopy(panel, id, band.part)
		if copy == nil then
			continue
		end
		panel.copies[id] = copy
		local size = band.size * scale
		if size ~= copy.size then
			copy.copy.Size = size
			copy.size = size
		end
		local at = FarLayerMath.pose(band.offset, scale)
		if (at - copy.at).Magnitude > POSE_STEP or copy.rot ~= band.rot then
			copy.copy.CFrame = CFrame.new(at) * band.rot
			copy.at, copy.rot = at, band.rot
		end
	end
	for id in panel.copies do
		if current[id] == nil then
			destroyCopy(panel, id)
		end
	end
end

-- The sun and Roblox's outdoor light, for every ViewportFrame (only when they moved).
local function updateLight(ctx: RenderContext.RenderContext)
	local ambient = Lighting.OutdoorAmbient
	local level = math.clamp(Lighting.Brightness * LIGHT_PER_BRIGHTNESS, 0, 1)
	local color = Color3.new(level, level, level)
	local direction = -ctx.sunDirection
	local function moved(a: Color3, b: Color3): boolean
		return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) > LIGHT_STEP
	end
	if
		not moved(ambient, light.ambient)
		and not moved(color, light.color)
		and (direction - light.direction).Magnitude <= LIGHT_STEP
	then
		return
	end
	light.ambient, light.color, light.direction = ambient, color, direction
	for _, panel in panels do
		panel.view.Ambient = ambient
		panel.view.LightColor = color
		panel.view.LightDirection = direction
	end
end

local function applyTier(name: string)
	local wanted = TIERS[name] or TIERS.High
	tierName = name
	if wanted.canvas ~= canvas then
		canvas = wanted.canvas
		for _, panel in panels do
			panel.gui.CanvasSize = Vector2.new(canvas, canvas)
		end
	end
end

function FarLayer.init(parent: Instance)
	local f = Instance.new("Folder")
	f.Name = FOLDER_NAME
	folder = f
	home = parent
	applyTier(Quality.tier())
	Quality.onChanged(function(name: Quality.Tier)
		applyTier(name)
	end)
	for index, face in FarLayerMath.FACES do
		local panel = newPanel(f, face)
		panels[index] = panel
		panelParts[index] = panel.part
		panelCFrames[index] = CFrame.identity
	end
	layout(HALF_SIZE.min)
end

function FarLayer.mode(): string
	return FarLayerMath.modeOf(modeState, (TIERS[tierName] or TIERS.High).mode)
end

function FarLayer.active(): boolean
	return folder ~= nil and FarLayer.mode() == "layer"
end

function FarLayer.toggle(): string
	return FarLayerMath.toggle(modeState, (TIERS[tierName] or TIERS.High).mode)
end

function FarLayer.consumeChanged(): boolean
	return FarLayerMath.consumeChanged(modeState, FarLayer.active())
end

function FarLayer.clear()
	for id, band in current do
		table.insert(pool, band)
		current[id] = nil
	end
end

function FarLayer.setBand(id: number, part: MeshPart, offset: Vector3, rot: CFrame, size: Vector3)
	local band: Band? = table.remove(pool)
	if band then
		band.part, band.offset, band.rot, band.size = part, offset, rot, size
		current[id] = band
	else
		current[id] = { part = part, offset = offset, rot = rot, size = size }
	end
end

function FarLayer.hide()
	local f = folder
	if f and shownNow then
		shownNow = false
		f.Parent = nil
	end
	if not FarLayer.active() then
		releaseCopies() -- the other mode: nothing kept
	end
end

function FarLayer.commit(ctx: RenderContext.RenderContext)
	local f = folder
	if f == nil or not FarLayer.active() or next(current) == nil then
		FarLayer.hide()
		return
	end
	if not shownNow then
		shownNow = true
		f.Parent = home
	end
	-- one scale for the whole backdrop: the largest band fits the part limit
	local extent = 0
	for _, band in current do
		extent = math.max(extent, band.size.X, band.size.Y, band.size.Z)
	end
	scaleNow = FarLayerMath.backdropScale(extent, PART_LIMIT)
	local h = FarLayerMath.halfSize(ctx.drawDistance, HALF_SIZE)
	if math.abs(h - halfSize) > RESIZE_THRESHOLD * halfSize then
		layout(h)
	end
	-- the cube follows the eye (workspace axes)
	local eye = ctx.camera.Position
	for index in panels do
		panelMoved[index] = panelCFrames[index] + eye
	end
	Workspace:BulkMoveTo(panelParts, panelMoved, Enum.BulkMoveMode.FireCFrameChanged)
	-- only the faces that can show in the view are drawn and posed
	local camera = Workspace.CurrentCamera
	local fov = if camera then camera.FieldOfView else 70
	local viewport = if camera then camera.ViewportSize else Vector2.new(16, 9)
	local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9
	FarLayerMath.visibleFaces(ctx.camera.LookVector, ctx.camera.UpVector, fov, aspect, VISIBLE_MARGIN, visible)
	updateLight(ctx)
	for index, panel in panels do
		local show = visible[index]
		if show then
			syncFace(panel, scaleNow)
		end
		if panel.shown ~= show then
			panel.shown = show
			panel.gui.Enabled = show
		end
	end
end

-- CHANGED (Far layer): the backdrop is on screen this frame (SkyCube: the ground beyond its panels is in it)
function FarLayer.isShown(): boolean
	return shownNow
end

function FarLayer.setTint(on: boolean, colours: { Color3 }, further: Color3)
	tint.on, tint.colours, tint.further = on, colours, further
	for _, panel in panels do
		for id, entry in panel.copies do
			entry.copy.Color = tintOf(id)
		end
	end
end

function FarLayer.summary(): string
	if not FarLayer.active() then
		return "far: mesh" .. (if modeState.override then "" else " (tier)")
	end
	local faces = 0
	for _, show in visible do
		faces += if show then 1 else 0
	end
	return string.format("far: layer %d/6 faces x%.3f %d studs %dpx", faces, scaleNow, halfSize, canvas)
end

return table.freeze(FarLayer)
