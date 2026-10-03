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
	    the bands at true scale in the 3D world; the scaled ones live only here. The copies share the band's
	    EditableMesh (no Editable memory), in a Model under each ViewportFrame.
	  * Where the backdrop shows no ground its ViewportFrame is clear (BackgroundTransparency 1): Roblox's sky, or
	    the SkyCube's painted Mars sky behind it, shows through.
	  * Light inside the ViewportFrames (Ambient, LightColor, LightDirection) follows the sun and Roblox's outdoor
	    light (SkyLighting's values); day / night and the distance haze are baked into the vertex colours already.
	  * Cost: only the faces that can show in the camera's view are drawn (FarLayerMath.visibleFaces, usually 2-4);
	    the copies are posed only when the camera moved (a turning camera rewrites nothing). Resolution per Quality
	    tier (CanvasSize). Low (phones) keeps today's 3D bands by default (the "mesh" mode): every visible face draws
	    every band again; /farground still turns the layer on there.
	  * /farground (DebugService -> DebugView "farground") switches between "layer" and "mesh" (the depth-mapped 3D
	    bands of D51a); TerrainMesh rebuilds its bands for the new mode. /bands tints the copies too (their part
	    colour). The F3 "Terrain:" line shows the mode (summary()).

	CHANGED (Far layer fix): Studio test 1 (layer mode): "i cant see any of the planet really ... untill i go to
	space": the near band showed, the backdrop drew nothing. The panels are built exactly like Render/SkyCube's
	(Transparency 1 parts, unlit SurfaceGuis, which do draw in Studio), so the suspects are the ViewportFrame's
	content. Each one is now handled:
	  * copies are made with AssetService:CreateMeshPartAsync(Content.fromObject(the band's EditableMesh)) (async,
	    COPY_STARTS_PER_FRAME new ones a frame, one per band per drawn face, made again only when the band is
	    rebuilt), the way S12 saw MeshParts share one EditableMesh; a Clone of the band part (which may not keep the
	    EditableMesh link) is only the fallback
	  * a 2 x 2 white texture on every copy (WHITE_TEXTURE: vertex-coloured meshes are reported not to draw in
	    ViewportFrames without a texture; white x vertex colour = the vertex colour). /farground tex switches it.
	  * every copy is re-parented KICK_DELAYS after it was added (ViewportFrames are reported to skip a mesh that was
	    added before it loaded); copies live in a Model in the ViewportFrame (the other reported fix)
	  * the ViewportFrame's ambient never drops below AMBIENT_FLOOR (black ground at night otherwise), its image is
	    explicitly opaque and untinted
	Diagnostics (cheap, always on):
	  * the F3 "Far layer:" line (details; the "Terrain:" line keeps the mode and the verdict): faces drawn, bands
	    given, copies (made with CreateMeshPartAsync / Clone / failed / loading), how many have a mesh the engine
	    reports (MeshContent set, MeshSize > 0), the white texture, the panel distance vs the draw distance, the last
	    error, and a verdict (FarLayerMath.verdict: the first thing wrong)
	  * one "[FarLayer] ..." line in Output once the layer's first copies are made (or REPORT_TIMEOUT after it
	    started): the same counts, every pcall error
	  * /farground test: reference objects in the backdrop scene of every face (a red cube toward +Z, a green ball
	    toward +X, a plain MeshPart (the classic sword mesh, or a yellow Part if it cannot load) toward -Z, all just
	    above the horizon), a faint magenta tint and a label on every panel, all six faces drawn. They show
	    separately whether the panels draw, whether ViewportFrames draw plain parts / plain meshes, and whether they
	    draw the EditableMesh copies (the ground).
	The backdrop's reach (reach()): other bodies' proxies (ScaledSpace) are placed beyond the panels' farthest corner
	while the backdrop is shown, so the picture's ground hides them and its clear sky shows them.
	If ViewportFrames turn out not to draw EditableMesh content at all, the fallback is a CPU-painted picture per
	face (DECISIONS D53, Studio test 1).


	CHANGED (Far layer smooth): Studio drew the backdrop (adorned PlayerGui SurfaceGuis, D53's probes), but Steamy:
	"game is super jittery, the ground and the rocket" with the layer on, gone with it off. The causes and the fixes:
	  * every copy's CFrame was rewritten every frame the camera moved (they were posed about the eye), so every
	    visible face's ViewportFrame re-rendered every band every frame, and each band rebuild started a
	    CreateMeshPartAsync per face at once. Now the backdrop scene is STATIC: each band sits at its true place about
	    an anchor (FarLayerMath.scenePoint: (centre - anchor) x the one scale, body axes) and only each face's camera
	    moves (FarLayerMath.sceneCamera: the eye's scene point, turned by the inverse of the pocket frame's rotation,
	    so turning and moving pocket frames cost one CFrame per face). The cameras are rewritten only when the picture
	    would change by more than PIXEL_TOLERANCE screen pixels (FarLayerMath.viewDue: the eye's move over the nearest
	    ground the backdrop can show, plus the frame's turn); a copy only when its band moves past the same threshold
	    (a stale band pushed back), is rebuilt, or the anchor / scale changed. Standing still writes nothing.
	  * a face is drawn while it can show and FACE_HOLD_S after (FarLayerMath.faceHeld): turning no longer enables /
	    disables SurfaceGuis every few frames; a face out of view is not updated (its camera catches up when shown)
	  * new copies (first copies and rebuilt bands) start at most COPY_STARTS_PER_FRAME a frame
	  * smaller canvases (TIERS): the far ground is hazy, 768 / 512 px per face is enough
	  * the panels move (BulkMoveTo) only when the eye moved; all of it runs in UniverseRenderer's step after the
	    camera (Camera + 10), so nothing here can delay the camera or the craft (PocketController: Camera - 2)
	  * the F3 "Far layer:" line shows the Lua cost per frame (average / peak over ~1 s, Render/PeakMeter) and the
	    property writes per frame (face cameras, copies)
	Colour (Steamy's screenshot at the pads: the picture's ground was darker and yellower than the near band at the
	seam, 3D (154, 198, 108) vs (138, 181, 70)): the ViewportFrames' light is FarLayerMath.viewportLight, the old base
	light x the per-channel gain measured there (SEAM_GAIN), faded out toward night. The white texture is off by
	default (WHITE_TEXTURE: Steamy's dusk screenshot drew the ground with /farground tex off).
	The magenta line along the horizon and the faces' borders: the ViewportFrame's clear background carried the test
	tint's colour into the picture's anti-aliased edges. It is now the ground's own colour lit the same way
	(FarLayerMath.shade of the body's colour), fully transparent; the tint is only for /farground test.

	API (driven by TerrainMesh, and DebugView for toggle):
		FarLayer.init(parent)                    the cube's folder goes under `parent` while shown
		FarLayer.active(): boolean               the layer draws the scaled bands (mode "layer")
		FarLayer.mode(): string                  "layer" | "mesh"
		FarLayer.toggle(): string                /farground: the other mode (kept for the session), returns it
		FarLayer.toggleTest(): boolean           CHANGED (Far layer fix): /farground test (turns the layer on)
		FarLayer.toggleTexture(): boolean        CHANGED (Far layer fix): /farground tex (the white texture)
		FarLayer.consumeChanged(): boolean       true once after the mode changed (TerrainMesh re-plans)
		FarLayer.clear()                         a new set of bands follows (placeBands, every frame)
		FarLayer.setBand(id, part, mesh, origin, rot, size, push, inWorld)
		                                         CHANGED (Far layer smooth): band `id`: its part, its EditableMesh,
		                                         its box centre (dominant-body coordinates, doubles), its rotation
		                                         (body axes), its true size, the stale push (1: none), whether it is
		                                         drawn in the 3D world too (true scale)
		FarLayer.commit(ctx, toWorkspace)        draws the set given since clear() (none: hidden); CHANGED (Far
		                                         layer smooth): + the body-to-workspace rotation
		FarLayer.hide()                          nothing to draw (no ground, plates, another mode)
		FarLayer.isShown(): boolean              the backdrop is on screen (TerrainMesh.groundReach)
		FarLayer.reach(): number                 CHANGED (Far layer fix): studs to the panels' farthest point while
		                                         shown, else 0 (ScaledSpace keeps other bodies beyond it)
		FarLayer.setTint(on, colours, further)   the /bands view: band i's copies in colours[i] (further: the rest)
		FarLayer.summary(): string               the F3 "Terrain:" line's part (mode, verdict)
		FarLayer.details(): string               CHANGED (Far layer fix): the F3 "Far layer:" line (diagnostics)
]]

local AssetService = game:GetService("AssetService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players") -- CHANGED (Far layer probe): the panels' SurfaceGuis live in the PlayerGui
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- CHANGED (Far layer smooth): Bodies, Vec3d
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies) -- CHANGED (Far layer smooth): the ground's colour
local EditableBudget = require(script.Parent.EditableBudget) -- CHANGED (Far layer fix): the white texture
local FarLayerMath = require(script.Parent.FarLayerMath)
local PeakMeter = require(script.Parent.PeakMeter) -- CHANGED (Far layer smooth): the F3 cost line
local Quality = require(script.Parent.Quality)
local RenderContext = require(script.Parent.RenderContext)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d) -- CHANGED (Far layer smooth): the scene's anchor

--============================================================================
-- Tunables
--============================================================================
-- per Quality tier: the default mode and the SurfaceGui canvas (pixels across a face; at 1080p and a 70-degree view
-- a face spans ~1500 pixels on screen, the far ground is hazy)
type TierParams = { mode: string, canvas: number }
-- CHANGED (Far layer off by default): Steamy in Studio: "i cant see any of the planet really ... untill i go to space":
-- the backdrop drew no ground in Studio (the band copies do not show in the ViewportFrames), so every tier defaults to
-- "mesh" again until that is fixed; /farground still switches to "layer" for testing
-- CHANGED (Far layer fix): still "mesh" everywhere until Studio confirms the fixed layer draws
-- CHANGED (Far layer smooth): it draws (adorned PlayerGui SurfaceGuis) and is smooth now: "layer" on Medium and High
-- (exact depth order, no depth-mapped bands drifting and snapping at the horizon); Low (phones) keeps "mesh" (every
-- visible face draws every band again); canvases 768 / 512 (was 1024 / 640)
local TIERS: { [string]: TierParams } = {
	Low = { mode = "mesh", canvas = 384 },
	Medium = { mode = "layer", canvas = 512 },
	High = { mode = "layer", canvas = 768 },
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
local FOLDER_NAME = "FarLayer"
local NEAR_BAND = 0 -- TerrainMath.NEAR_BAND (keeps its own colours under /bands)
-- CHANGED (Far layer fix): the Studio test 1 fixes and diagnostics (header)
-- CHANGED (Far layer smooth): 1 a frame (was 4)
local COPY_STARTS_PER_FRAME = 1 -- new band copies started per frame (CreateMeshPartAsync calls, or Clones)
-- CHANGED (Far layer smooth): a rebuilt band's copies: its old copies vanish with its old mesh (TerrainMesh destroys
-- it on the swap), so the faces in view get theirs at once (visible faces first), the rest at this rate
local REPLACE_STARTS_PER_FRAME = 4
local COPY_MATERIAL = Enum.Material.SmoothPlastic -- TerrainMesh's MESH_MATERIAL
local KICK_DELAYS = { 0.3, 2 } -- s after a copy is added: re-parent it (a ViewportFrame may skip an unloaded mesh)
-- CHANGED (Far layer smooth): off (Steamy's dusk screenshot: the copies draw without it)
local WHITE_TEXTURE = false -- a white texture on the copies (vertex colours in ViewportFrames); /farground tex
local WHITE_SIZE = 2 -- pixels across the white texture
local AMBIENT_FLOOR = 0.25 -- the ViewportFrames' ambient never goes below this grey
local REPORT_TIMEOUT = 6 -- s: the [FarLayer] report prints when the first copies are made, or this long after start
local ERROR_CHARS = 90 -- characters of the last error shown on the F3 line
-- CHANGED (Far layer smooth): the static scene, its change thresholds, the light match (header)
local PIXEL_TOLERANCE = 0.5 -- screen pixels the picture may lag the truth before a face camera / copy is rewritten
local NEAREST_FLOOR = 60 -- studs: the nearest backdrop ground assumed at least this far (the threshold's distance)
local ANCHOR_RANGE = 4000 -- m: the scene's anchor moves to the eye once it is this far (every copy re-posed once)
local FACE_HOLD_S = 2 -- s a face stays drawn after it left the view
local EYE_STEP = 1e-3 -- studs: the panels move only when the eye moved more than this
-- the 3D near band / the backdrop per channel at the seam by day (Steamy's screenshot at the pads, day:
-- (154, 198, 108) / (138, 181, 70)); 1 = the old light. FarLayerMath.viewportLight, DECISIONS D53
local SEAM_GAIN = { 1.12, 1.09, 1.54 }
local SEAM_DARK = -0.05 -- sun up component where the gain is gone (night) ...
local SEAM_LIT = 0.25 -- ... and whole (day)
local METER_WINDOW = 1 -- s: the F3 line's average / peak window
local TEST = {
	DISTANCE = 700, -- studs from the eye in the backdrop scene (inside every face camera's view)
	LIFT = 90, -- studs above the eye's horizon (the whole object: FarLayer.spec)
	SIZE = 90, -- studs across
	MESH = "rbxasset://fonts/sword.mesh", -- a plain mesh shipped with Roblox (the classic sword)
	TINT = Color3.fromRGB(255, 0, 255), -- the panels' background in test mode ...
	-- CHANGED (Far layer probe): opaque (was 0.85): Steamy's probe showed a mostly clear SurfaceGui frame drawing dark
	TINT_TRANSPARENCY = 0.3, -- ... the panel shows even if its ViewportFrame draws nothing
	STATE_INTERVAL = 3, -- s between [FarLayer] panel state lines in test mode
	LABEL_INTERVAL = 0.5, -- s between label rewrites
}
--============================================================================

type Vec3d = Vec3d.Vec3d

-- CHANGED (Far layer fix): `copy` is nil while CreateMeshPartAsync runs ("loading") or after everything failed;
-- `how`: "loading" | "async" | "clone" | "failed"
-- CHANGED (Far layer smooth): `version`: the band pose it shows (Band.version; -1: not posed yet)
type Copy = {
	copy: MeshPart?,
	source: MeshPart,
	size: Vector3,
	version: number,
	how: string,
	parented: boolean,
	addedAt: number, -- os.clock() when it was parented (KICK_DELAYS)
	kicks: number,
	previous: MeshPart?, -- the rebuilt band's old copy, kept (unmoved) until this one is in place: no gap
}
-- CHANGED (Far layer fix): /farground test's reference objects; CHANGED (Far layer smooth): + where they sit about
-- the eye (workspace axes): they follow the face camera in the scene
type Ref = { part: BasePart, offset: Vector3 }
type Panel = {
	part: Part,
	gui: SurfaceGui,
	view: ViewportFrame,
	scene: Model, -- CHANGED (Far layer fix): the copies' (and test objects') parent in the ViewportFrame
	label: TextLabel, -- CHANGED (Far layer fix): /farground test's label
	refs: { Ref },
	camera: Camera,
	face: FarLayerMath.Face,
	name: string,
	copies: { [number]: Copy }, -- band id -> its copy in this face's ViewportFrame
	shown: boolean,
	seenAt: number, -- CHANGED (Far layer smooth): os.clock() when it last could show (FACE_HOLD_S)
	viewVersion: number, -- CHANGED (Far layer smooth): the view its camera shows (-1: none)
}
-- CHANGED (Far layer smooth): kept per band id across frames (was rebuilt every frame from a pool): its pose in the
-- static scene and a version every copy compares with
type Band = {
	part: MeshPart,
	mesh: EditableMesh?,
	origin: Vec3d, -- box centre, dominant-body coordinates (doubles)
	rot: CFrame, -- body axes
	size: Vector3, -- true
	push: number, -- 1, or the stale band's push back about the camera
	inWorld: boolean, -- drawn in the 3D world too (true scale)
	seen: boolean, -- given since clear()
	at: Vector3, -- the scene point its copies show (scenePoint)
	scaled: Vector3, -- the size they show
	version: number,
}

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
local current: { [number]: Band } = {} -- CHANGED (Far layer smooth): every band id given (seen: since clear())
local visible: { boolean } = { false, false, false, false, false, false }
local shownNow = false
local scaleNow = 1
-- CHANGED (Far layer smooth): + the background (fringe) colour and the body it is for
local light = {
	ambient = Color3.new(),
	color = Color3.new(),
	direction = Vector3.zero,
	background = Color3.new(),
	fresh = true,
}
local tint: { on: boolean, colours: { Color3 }, further: Color3 } =
	{ on = false, colours = {}, further = Color3.new(1, 1, 1) }
-- CHANGED (Far layer smooth): the static scene: its anchor (dominant-body coordinates; body -1: none yet), the view
-- the face cameras were last written for (the eye minus the anchor, true; the body-to-workspace rotation), the last
-- eye the panels were moved to, and the F3 meters
local anchor = { x = 0, y = 0, z = 0, body = -1 }
local viewState = {
	cam = Vector3.new(math.huge, 0, 0),
	rot = CFrame.identity,
	version = 0,
	eye = Vector3.new(math.huge, 0, 0),
}
local meters = {
	cost = PeakMeter.new(METER_WINDOW), -- ms of Lua per commit
	cameras = PeakMeter.new(METER_WINDOW), -- face camera writes per frame
	copies = PeakMeter.new(METER_WINDOW), -- copy writes (CFrame / Size) per frame
	starts = 0, -- copies started this frame (for the meter below)
	started = PeakMeter.new(METER_WINDOW), -- copies started per frame
	nearest = 0, -- studs: the threshold's nearest ground (F3)
}
local writes = { cameras = 0, copies = 0 }
-- CHANGED (Far layer fix): diagnostics (summary, the [FarLayer] report) and the test / texture switches
local diag = {
	lastError = "none",
	errors = 0,
	pending = 0, -- CreateMeshPartAsync calls running
	startsLeft = 0, -- copies this frame may still start
	replacesLeft = 0, -- CHANGED (Far layer smooth): rebuilt bands' copies this frame may still start
	reportDue = false,
	startedAt = 0,
	drawDistance = 0,
	labelAt = 0,
}
local testOn = false
local textureOn = WHITE_TEXTURE
-- the white texture: state "untried" | "ok" | "released" | "refused (...)" | "failed"
local white: { image: EditableImage?, handle: EditableBudget.Handle?, state: string } =
	{ image = nil, handle = nil, state = "untried" }

-- CHANGED (Far layer fix): remembers a failure for the F3 line and the report
local function noteError(where: string, err: unknown)
	diag.errors += 1
	diag.lastError = FarLayerMath.clip(where .. ": " .. tostring(err), ERROR_CHARS)
end

local function newPanel(parent: Folder, face: FarLayerMath.Face, name: string): Panel
	local part = Instance.new("Part")
	part.Name = "FarPanel" .. name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Transparency = 1 -- as Render/SkyCube's panels, whose SurfaceGuis draw in Studio
	part.Size = Vector3.new(1, 1, PANEL_DEPTH)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Far"
	gui.Face = Enum.NormalId.Front -- looks at the eye (FarLayerMath.panelCFrame)
	gui.LightInfluence = 0
	gui.Brightness = 1
	gui.AlwaysOnTop = false -- depth-tested: nearer 3D things draw in front
	gui.ZOffset = 0
	gui.MaxDistance = MAX_GUI_DISTANCE
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(canvas, canvas)
	gui.ClipsDescendants = true
	gui.Enabled = false -- commit draws only the faces that can show
	gui.Adornee = part
	-- CHANGED (Far layer probe): in the PlayerGui, adorned to the panel. Steamy's /farground probe in Studio: a
	-- SurfaceGui parented to its part draws Frames and labels but never its ViewportFrame (not even its background),
	-- at any distance; the same SurfaceGui in the PlayerGui with Adornee = the part draws it, 80 and 1000 studs away
	local player = Players.LocalPlayer
	local playerGui = if player then player:FindFirstChildOfClass("PlayerGui") else nil
	if playerGui then
		gui.ResetOnSpawn = false
		gui.Name = "FarLayer" .. name
		gui.Parent = playerGui
	else
		gui.Parent = part
	end

	local view = Instance.new("ViewportFrame")
	view.Name = "Ground"
	view.BorderSizePixel = 0
	view.Size = UDim2.fromScale(1, 1)
	-- CHANGED (Far layer smooth): the ground's colour (updateLight), not the test tint: the clear background's colour
	-- showed in the picture's anti-aliased edges (Steamy's magenta line along the horizon and the faces' borders)
	view.BackgroundColor3 = Color3.new(0.3, 0.4, 0.3)
	view.BackgroundTransparency = 1 -- the sky (Roblox's, or the SkyCube's) shows where there is no ground
	-- CHANGED (Far layer fix): explicitly opaque and untinted, lit (updateLight sets the real values)
	view.ImageTransparency = 0
	view.ImageColor3 = Color3.new(1, 1, 1)
	view.Ambient = Color3.new(0.8, 0.8, 0.8)
	view.LightColor = Color3.new(0.55, 0.55, 0.55)
	view.Parent = gui

	-- CHANGED (Far layer fix): the copies live in a Model (a reported fix for meshes missing in ViewportFrames)
	local scene = Instance.new("Model")
	scene.Name = "Scene"
	scene.Parent = view

	local camera = Instance.new("Camera")
	camera.Name = "Eye"
	camera.FieldOfView = FarLayerMath.fieldOfView(PANEL_OVERLAP) -- degrees, vertical (the frame is square)
	camera.CFrame = FarLayerMath.faceCamera(face)
	camera.Parent = view
	view.CurrentCamera = camera

	-- CHANGED (Far layer fix): /farground test's label (a sibling of the ViewportFrame, drawn over it)
	local label = Instance.new("TextLabel")
	label.Name = "Test"
	label.BackgroundTransparency = 0.3
	label.BackgroundColor3 = Color3.new(0, 0, 0)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Size = UDim2.fromScale(0.6, 0.06)
	label.Position = UDim2.fromScale(0.2, 0.3) -- CHANGED (Far layer probe): lower, in view near the horizon
	label.ZIndex = 2
	label.Visible = false
	label.Text = name
	label.Parent = gui

	part.Parent = parent
	return {
		part = part,
		gui = gui,
		view = view,
		scene = scene,
		label = label,
		refs = {},
		camera = camera,
		face = face,
		name = name,
		copies = {},
		shown = false,
		seenAt = -math.huge,
		viewVersion = -1,
	}
end

local function layout(h: number)
	for index, panel in panels do
		local side = 2 * h * (1 + PANEL_OVERLAP)
		panel.part.Size = Vector3.new(side, side, PANEL_DEPTH)
		panelCFrames[index] = FarLayerMath.panelCFrame(panel.face, h)
	end
	halfSize = h
	viewState.eye = Vector3.new(math.huge, 0, 0) -- CHANGED (Far layer smooth): the panels move this frame
end

local function destroyCopy(panel: Panel, id: number)
	local entry = panel.copies[id]
	if entry then
		panel.copies[id] = nil -- a CreateMeshPartAsync still running sees this and drops its part
		local copy, previous = entry.copy, entry.previous
		if copy then
			copy:Destroy()
		end
		if previous then
			previous:Destroy()
		end
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

-- CHANGED (Far layer fix): a 2 x 2 white EditableImage for the copies' texture (made once, through the budget:
-- 16 bytes; given back if the budget needs the room, the copies then go untextured), or nil
local function whiteContent(): Content?
	if not textureOn then
		return nil
	end
	local image = white.image
	if image then
		return Content.fromObject(image)
	end
	if white.state ~= "untried" then
		return nil -- refused, failed or given back: not retried every copy (/farground tex tries again)
	end
	local made, handle, refusal = EditableBudget.createImage(
		"FarLayer",
		Vector2.new(WHITE_SIZE, WHITE_SIZE),
		EditableBudget.PRIORITY.STARS,
		function()
			-- the budget needs the room: the copies go untextured (a destroyed image must not stay on them)
			white.image, white.handle, white.state = nil, nil, "released"
			for _, panel in panels do
				for _, entry in panel.copies do
					local copy = entry.copy
					if copy then
						pcall(function()
							copy.TextureContent = Content.none
						end)
					end
				end
			end
		end
	)
	if made == nil then
		white.state = "refused (" .. tostring(refusal) .. ")"
		return nil
	end
	local pixels = buffer.create(WHITE_SIZE * WHITE_SIZE * 4)
	buffer.fill(pixels, 0, 255)
	local ok, err = pcall(function()
		made:WritePixelsBuffer(Vector2.zero, made.Size, pixels)
	end)
	if not ok then
		EditableBudget.destroy(handle)
		white.state = "failed"
		noteError("white texture", err)
		return nil
	end
	white.image, white.handle, white.state = made, handle, "ok"
	return Content.fromObject(made)
end

-- CHANGED (Far layer fix): what a copy needs, whichever way it was made
local function configureCopy(copy: MeshPart, id: number, source: MeshPart)
	for _, child in copy:GetChildren() do
		child:Destroy() -- e.g. the /bands Highlight (Highlights do not draw in a ViewportFrame)
	end
	copy.Name = "Far" .. source.Name
	copy.Anchored = true
	copy.CanCollide = false
	copy.CanQuery = false
	copy.CanTouch = false
	copy.CastShadow = false
	copy.Material = COPY_MATERIAL
	copy.Transparency = 0
	copy.Color = tintOf(id)
	local texture = whiteContent()
	local ok, err = pcall(function()
		copy.TextureContent = texture or Content.none
	end)
	if not ok then
		noteError("TextureContent", err)
	end
end

-- The Clone fallback (it may not keep the EditableMesh link: kept only for when CreateMeshPartAsync fails).
local function cloneOf(source: MeshPart): MeshPart?
	local ok, made = pcall(function(): Instance?
		return source:Clone()
	end)
	if not ok then
		noteError("Clone", made)
		return nil
	end
	if made == nil or not made:IsA("MeshPart") then
		noteError("Clone", "returned nothing (Archivable?)")
		return nil
	end
	return made :: MeshPart
end

-- CHANGED (Far layer fix): a copy of a band for one face, made with CreateMeshPartAsync from the band's own
-- EditableMesh (async: `copy` stays nil until it is made; the frames after pose and parent it), else a Clone.
local function newCopy(panel: Panel, id: number, band: Band): Copy
	local entry: Copy = {
		copy = nil,
		source = band.part,
		size = Vector3.zero,
		version = -1,
		how = "loading",
		parented = false,
		addedAt = 0,
		kicks = 0,
		previous = nil,
	}
	meters.starts += 1 -- CHANGED (Far layer smooth)
	local source = band.part
	local function fallback()
		local cloned = cloneOf(source)
		if cloned then
			configureCopy(cloned, id, source)
			entry.copy, entry.how = cloned, "clone"
		else
			entry.how = "failed"
		end
	end
	local mesh = band.mesh
	if mesh == nil then
		fallback()
		return entry
	end
	diag.pending += 1
	-- deferred: the caller stores the entry first (an immediate failure must find it to fall back)
	task.defer(function()
		local ok, made = pcall(function(): MeshPart
			return AssetService:CreateMeshPartAsync(Content.fromObject(mesh), {
				CollisionFidelity = Enum.CollisionFidelity.Box,
				RenderFidelity = Enum.RenderFidelity.Precise,
			})
		end)
		diag.pending -= 1
		if panel.copies[id] ~= entry then
			if ok then
				made:Destroy() -- the band was rebuilt or the layer left meanwhile
			end
			return
		end
		if ok then
			configureCopy(made, id, source)
			entry.copy, entry.how = made, "async"
		else
			noteError("CreateMeshPartAsync", made)
			fallback()
		end
	end)
	return entry
end

-- CHANGED (Far layer fix): parents a made copy (pcall: the error goes to the report) and re-parents it at KICK_DELAYS
local function parentCopy(panel: Panel, entry: Copy, copy: MeshPart)
	if not entry.parented then
		local ok, err = pcall(function()
			copy.Parent = panel.scene
		end)
		entry.parented = true
		entry.addedAt = os.clock()
		if not ok then
			noteError("parent", err)
		end
		local previous = entry.previous
		if previous then
			entry.previous = nil
			previous:Destroy() -- the rebuilt band's old copy: this one replaces it now
		end
	elseif FarLayerMath.kickDue(os.clock() - entry.addedAt, entry.kicks, KICK_DELAYS) then
		entry.kicks += 1
		pcall(function()
			copy.Parent = nil
			copy.Parent = panel.scene
		end)
	end
end

-- Keeps one face's copies in step with the bands (making new ones). CHANGED (Far layer smooth): the copies stand
-- still in the static scene; a copy is only written when its band's pose changed (Band.version); new copies and
-- rebuilt bands' copies start at most COPY_STARTS_PER_FRAME / REPLACE_STARTS_PER_FRAME a frame
local function syncFace(panel: Panel)
	for id, band in current do
		local existing: Copy? = panel.copies[id]
		if existing and existing.source ~= band.part then
			if diag.replacesLeft <= 0 then
				continue -- the band was rebuilt: its old copy stays until a start is free (unless its mesh is gone)
			end
			diag.replacesLeft -= 1
			local made = newCopy(panel, id, band)
			local oldCopy, oldPrevious = existing.copy, existing.previous
			if oldCopy and oldPrevious then
				oldPrevious:Destroy() -- rebuilt twice before a copy was in place: the older one goes
				oldPrevious = nil
			end
			made.previous = oldCopy or oldPrevious
			existing.copy, existing.previous = nil, nil
			panel.copies[id] = made
			existing = made
		end
		local entry = existing
		if entry == nil then
			if diag.startsLeft <= 0 then
				continue -- CHANGED (Far layer fix): a few new copies a frame
			end
			diag.startsLeft -= 1
			local made = newCopy(panel, id, band)
			panel.copies[id] = made
			entry = made
		end
		assert(entry)
		local copy = entry.copy
		if copy == nil then
			continue -- loading, or failed (until the band is rebuilt)
		end
		if entry.version ~= band.version then
			if band.scaled ~= entry.size then
				copy.Size = band.scaled
				entry.size = band.scaled
			end
			copy.CFrame = CFrame.new(band.at) * band.rot
			entry.version = band.version
			writes.copies += 1
		end
		parentCopy(panel, entry, copy)
	end
	for id in panel.copies do
		if current[id] == nil then
			destroyCopy(panel, id)
		end
	end
end

-- The sun and Roblox's outdoor light, for every ViewportFrame (only when they moved). CHANGED (Far layer smooth):
-- matched to the 3D near band at the seam (FarLayerMath.viewportLight, SEAM_GAIN); the direction in the scene's
-- (body) axes; the clear background in the ground's lit colour (no stray colour in the anti-aliased edges)
local function updateLight(ctx: RenderContext.RenderContext, toWorkspace: CFrame)
	local sunUp = ctx.sunDirection.Y
	local ambient, color = FarLayerMath.viewportLight({
		outdoor = Lighting.OutdoorAmbient,
		brightness = Lighting.Brightness,
		sunUp = sunUp,
		perBrightness = LIGHT_PER_BRIGHTNESS,
		floor = AMBIENT_FLOOR,
		gain = SEAM_GAIN,
		dark = SEAM_DARK,
		lit = SEAM_LIT,
	})
	local direction = toWorkspace:VectorToObjectSpace(-ctx.sunDirection)
	local background = FarLayerMath.shade(Bodies.get(ctx.dominantBodyId).Color, ambient, color, sunUp)
	local function moved(a: Color3, b: Color3): boolean
		return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) > LIGHT_STEP
	end
	if
		not light.fresh
		and not moved(ambient, light.ambient)
		and not moved(color, light.color)
		and not moved(background, light.background)
		and (direction - light.direction).Magnitude <= LIGHT_STEP
	then
		return
	end
	light.ambient, light.color, light.direction, light.background, light.fresh =
		ambient, color, direction, background, false
	for _, panel in panels do
		panel.view.Ambient = ambient
		panel.view.LightColor = color
		panel.view.LightDirection = direction
		panel.view.BackgroundColor3 = if testOn then TEST.TINT else background
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

--============================================================================
-- CHANGED (Far layer smooth): the static scene
--============================================================================

-- The anchor moves to the eye on another body or once the eye is ANCHOR_RANGE away (then every copy and camera is
-- rewritten once). Returns whether it moved.
local function placeAnchor(cam: Vec3d, body: number): boolean
	local dx, dy, dz = cam.x - anchor.x, cam.y - anchor.y, cam.z - anchor.z
	if anchor.body == body and dx * dx + dy * dy + dz * dz <= ANCHOR_RANGE * ANCHOR_RANGE then
		return false
	end
	anchor.x, anchor.y, anchor.z, anchor.body = cam.x, cam.y, cam.z, body
	return true
end

-- How near the ground the backdrop shows can be (FarLayerMath.nearestGround about the near band; without one, the
-- floor): the distance the change thresholds are taken at.
local function nearestGround(cam: Vec3d): number
	local near = current[NEAR_BAND]
	if near == nil or not near.seen then
		return NEAREST_FLOOR
	end
	local o = near.origin
	local eye = near.rot:VectorToObjectSpace(Vector3.new(cam.x - o.x, cam.y - o.y, cam.z - o.z))
	return FarLayerMath.nearestGround(eye, near.size, near.inWorld, NEAREST_FLOOR)
end

-- Every band's scene pose: rewritten (a new version) when forced or when it moved past the threshold.
local function poseBands(cam: Vec3d, force: boolean, nearest: number, tolerance: number)
	for _, band in current do
		local at = FarLayerMath.scenePoint(band.origin, cam, anchor, band.push, scaleNow)
		local scaled = band.size * band.push * scaleNow
		if
			force
			or scaled ~= band.scaled
			or FarLayerMath.viewDue((at - band.at).Magnitude / scaleNow, 0, nearest, tolerance)
		then
			band.at, band.scaled = at, scaled
			band.version += 1
		end
	end
end

-- /farground test's reference objects follow the eye (workspace offsets, turned into the scene's axes).
local function poseReferences(eyeScene: Vector3, toWorkspace: CFrame)
	for _, panel in panels do
		for _, ref in panel.refs do
			ref.part.CFrame = CFrame.new(eyeScene + toWorkspace:VectorToObjectSpace(ref.offset))
		end
	end
end

--============================================================================
-- CHANGED (Far layer fix): diagnostics
--============================================================================

-- The engine's own idea of a copy's mesh: content set and a box.
local function hasMesh(copy: MeshPart): boolean
	local ok, valid = pcall(function(): boolean
		local content = copy.MeshContent
		local size = copy.MeshSize
		local set = content.SourceType == Enum.ContentSourceType.Uri
			or (content.SourceType == Enum.ContentSourceType.Object and content.Object ~= nil)
			or content.SourceType == Enum.ContentSourceType.Opaque
		return set and size.X > 0 and size.Y > 0 and size.Z > 0
	end)
	return ok and valid
end

type Counts = {
	stats: FarLayerMath.Stats,
	async: number,
	clone: number,
	perFace: { string },
}

local function count(): Counts
	local bands = 0
	for _ in current do
		bands += 1
	end
	local stats: FarLayerMath.Stats = {
		shown = shownNow,
		bands = bands,
		faces = 0,
		copies = 0,
		valid = 0,
		pending = diag.pending,
		failed = 0,
	}
	local counts: Counts = { stats = stats, async = 0, clone = 0, perFace = {} }
	for _, panel in panels do
		if not panel.shown then
			continue
		end
		stats.faces += 1
		local made = 0
		for _, entry in panel.copies do
			local copy = entry.copy
			if entry.how == "failed" then
				stats.failed += 1
			elseif copy then
				made += 1
				stats.copies += 1
				stats.valid += if hasMesh(copy) then 1 else 0
				counts.async += if entry.how == "async" then 1 else 0
				counts.clone += if entry.how == "clone" then 1 else 0
			end
		end
		table.insert(counts.perFace, panel.name .. ":" .. made)
	end
	return counts
end

local function report(): string
	local c = count()
	local s = c.stats
	return string.format(
		"%s | faces %s (%s) | bands %d | copies %d (CreateMeshPartAsync %d, Clone %d, failed %d, loading %d), "
			.. "%d with a mesh | white texture %s | panels %d studs (corner %d) vs draw distance %d | %dpx%s | "
			.. "errors %d, last: %s",
		FarLayerMath.verdict(s),
		FarLayerMath.faceList(visible),
		table.concat(c.perFace, " "),
		s.bands,
		s.copies,
		c.async,
		c.clone,
		s.failed,
		s.pending,
		s.valid,
		if textureOn then white.state else "off (/farground tex)",
		math.floor(halfSize),
		math.floor(FarLayerMath.reach(halfSize, PANEL_OVERLAP)),
		math.floor(diag.drawDistance),
		canvas,
		if testOn then " | TEST" else "",
		diag.errors,
		diag.lastError
	)
end

-- /farground test's reference objects for one face's scene (every face has its own: an instance draws in one
-- ViewportFrame only); the plain mesh loads asynchronously. CHANGED (Far layer smooth): placed about the eye by
-- poseReferences (the scene no longer has the eye at its origin)
local function addReferences(panel: Panel)
	local function place(part: BasePart, offset: Vector3, colour: Color3)
		part.Anchored = true
		part.CanCollide = false
		part.CastShadow = false
		part.Material = Enum.Material.SmoothPlastic
		part.Color = colour
		part.CFrame = CFrame.new(offset)
		part.Parent = panel.scene
		table.insert(panel.refs, { part = part, offset = offset })
	end
	local cube = Instance.new("Part")
	cube.Name = "TestRedCube+Z"
	cube.Size = Vector3.one * TEST.SIZE
	place(cube, Vector3.new(0, TEST.LIFT, TEST.DISTANCE), Color3.new(1, 0, 0))
	local ball = Instance.new("Part")
	ball.Name = "TestGreenBall+X"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.one * TEST.SIZE
	place(ball, Vector3.new(TEST.DISTANCE, TEST.LIFT, 0), Color3.new(0, 1, 0))
	task.spawn(function()
		local ok, made = pcall(function(): MeshPart
			return AssetService:CreateMeshPartAsync(Content.fromUri(TEST.MESH))
		end)
		local first = panel.refs[1]
		if not testOn or first == nil or first.part ~= cube then
			if ok then
				made:Destroy() -- test mode ended meanwhile
			end
			return
		end
		local plain: BasePart
		if ok then
			made.Name = "TestMesh-Z"
			made.Size = made.Size * (TEST.SIZE / math.max(made.Size.X, made.Size.Y, made.Size.Z, 1e-3))
			plain = made
		else
			noteError("test mesh", made)
			local part = Instance.new("Part")
			part.Name = "TestYellowPart-Z"
			part.Size = Vector3.new(TEST.SIZE, TEST.SIZE / 2, TEST.SIZE / 2)
			plain = part
		end
		place(plain, Vector3.new(0, TEST.LIFT, -TEST.DISTANCE), Color3.new(1, 0.85, 0))
	end)
end

local function setTestLook(on: boolean)
	for _, panel in panels do
		for _, ref in panel.refs do
			ref.part:Destroy()
		end
		table.clear(panel.refs)
		if on then
			addReferences(panel)
		end
		panel.view.BackgroundTransparency = if on then TEST.TINT_TRANSPARENCY else 1
		panel.view.BackgroundColor3 = if on then TEST.TINT else light.background -- CHANGED (Far layer smooth)
		panel.label.Visible = on
	end
end

-- the labels in test mode: face, copies made / with a mesh / loading
-- CHANGED (Far layer probe): in test mode, where each panel really is (Steamy saw none of them while /farground
-- probe's panels of the same size drew): its place in the tree, distance from the camera, size, facing, Enabled
local stateAt = 0
local function printPanelState()
	local now = os.clock()
	if now < stateAt then
		return
	end
	stateAt = now + TEST.STATE_INTERVAL
	local camera = Workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else Vector3.zero
	for _, panel in panels do
		local part = panel.part
		local toEye = eye - part.Position
		local facing = if toEye.Magnitude > 0 then part.CFrame.LookVector:Dot(toEye.Unit) else 0
		print(
			string.format(
				"[FarLayer] panel %s: in workspace %s, parent %s, %.0f studs from the camera, size %.0f, facing %.2f, gui %s, shown %s, view %dx%d",
				panel.name,
				tostring(part:IsDescendantOf(Workspace)),
				if part.Parent then part.Parent:GetFullName() else "nil",
				toEye.Magnitude,
				part.Size.X,
				facing,
				if panel.gui.Enabled then "on" else "off",
				tostring(panel.shown),
				math.floor(panel.view.AbsoluteSize.X),
				math.floor(panel.view.AbsoluteSize.Y)
			)
		)
	end
end

local function updateLabels()
	printPanelState()
	local now = os.clock()
	if now < diag.labelAt then
		return
	end
	diag.labelAt = now + TEST.LABEL_INTERVAL
	for _, panel in panels do
		local made, valid, loading = 0, 0, 0
		for _, entry in panel.copies do
			local copy = entry.copy
			if copy then
				made += 1
				valid += if hasMesh(copy) then 1 else 0
			elseif entry.how == "loading" then
				loading += 1
			end
		end
		panel.label.Text =
			string.format("FarLayer %s: copies %d, mesh %d, loading %d", panel.name, made, valid, loading)
	end
end

--============================================================================
-- API
--============================================================================

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
		local panel = newPanel(f, face, FarLayerMath.FACE_NAMES[index])
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

-- CHANGED (Far layer fix): /farground test: reference objects in every face, tinted labelled panels, all six faces
-- drawn; turning it on turns the layer on too. Returns whether it is on.
function FarLayer.toggleTest(): boolean
	testOn = not testOn
	if testOn and FarLayer.mode() ~= "layer" then
		FarLayer.toggle()
	end
	setTestLook(testOn)
	diag.reportDue = true -- a fresh [FarLayer] report
	diag.startedAt = os.clock()
	return testOn
end

-- CHANGED (Far layer fix): /farground tex: the copies' white texture on / off (new copies follow; the rest now)
function FarLayer.toggleTexture(): boolean
	textureOn = not textureOn
	if textureOn and white.state ~= "ok" then
		white.state = "untried" -- try to make it again
	end
	local texture = whiteContent()
	for _, panel in panels do
		for _, entry in panel.copies do
			local copy = entry.copy
			if copy then
				pcall(function()
					copy.TextureContent = texture or Content.none
				end)
			end
		end
	end
	diag.reportDue = true
	diag.startedAt = os.clock()
	return textureOn
end

function FarLayer.consumeChanged(): boolean
	return FarLayerMath.consumeChanged(modeState, FarLayer.active())
end

-- CHANGED (Far layer smooth): the bands stay (their scene poses and versions); only marked unseen until given again
function FarLayer.clear()
	for _, band in current do
		band.seen = false
	end
end

-- CHANGED (Far layer fix): + `mesh`, the band's EditableMesh (the copies are made from it)
-- CHANGED (Far layer smooth): its centre in body coordinates (doubles; was centre minus camera in workspace axes),
-- its body-axes rotation, the stale push and whether it is in the 3D world too (the threshold's nearest ground)
function FarLayer.setBand(
	id: number,
	part: MeshPart,
	mesh: EditableMesh?,
	origin: Vec3d,
	rot: CFrame,
	size: Vector3,
	push: number,
	inWorld: boolean
)
	local band = current[id]
	if band == nil or band.part ~= part then
		current[id] = {
			part = part,
			mesh = mesh,
			origin = origin,
			rot = rot,
			size = size,
			push = push,
			inWorld = inWorld,
			seen = true,
			at = Vector3.new(math.huge, 0, 0), -- posed this frame (poseBands)
			scaled = Vector3.zero,
			version = if band then band.version + 1 else 0,
		}
		return
	end
	band.mesh, band.origin, band.rot, band.size, band.push, band.inWorld, band.seen =
		mesh, origin, rot, size, push, inWorld, true
end

function FarLayer.hide()
	local f = folder
	if f and shownNow then
		shownNow = false
		f.Parent = nil
		-- CHANGED (Far layer smooth): the PlayerGui SurfaceGuis off too (their adornees left the world)
		for _, panel in panels do
			panel.shown = false
			panel.gui.Enabled = false
			panel.seenAt = -math.huge
		end
	end
	if not FarLayer.active() then
		releaseCopies() -- the other mode: nothing kept
		table.clear(current) -- CHANGED (Far layer smooth)
		diag.reportDue, diag.startedAt = false, 0 -- CHANGED (Far layer fix): the next start reports again
	end
end

-- CHANGED (Far layer smooth): + `toWorkspace`, the body-to-workspace rotation (TerrainMesh's rotWs): the scene is in
-- body axes, the panels in workspace axes, the face cameras carry the difference
function FarLayer.commit(ctx: RenderContext.RenderContext, toWorkspace: CFrame)
	local started = os.clock()
	-- CHANGED (Far layer smooth): the bands not given this time are gone
	for id, band in current do
		if not band.seen then
			current[id] = nil
		end
	end
	local f = folder
	-- CHANGED (Far layer fix): test mode shows the cube even without bands (its reference objects)
	if f == nil or not FarLayer.active() or (next(current) == nil and not testOn) then
		FarLayer.hide()
		return
	end
	if not shownNow then
		shownNow = true
		f.Parent = home
		viewState.version += 1 -- CHANGED (Far layer smooth): every shown face's camera is written
		light.fresh = true
		if not diag.reportDue and diag.startedAt == 0 then
			diag.reportDue = true -- CHANGED (Far layer fix): the first start of the session reports
			diag.startedAt = os.clock()
		end
	end
	writes.cameras, writes.copies, meters.starts = 0, 0, 0
	diag.drawDistance = if ctx.drawDistance == ctx.drawDistance then math.min(ctx.drawDistance, 1e9) else 0
	-- one scale for the whole backdrop: the largest band fits the part limit
	local extent = 0
	for _, band in current do
		extent = math.max(extent, band.size.X * band.push, band.size.Y * band.push, band.size.Z * band.push)
	end
	local scale = FarLayerMath.backdropScale(extent, PART_LIMIT)
	local h = FarLayerMath.halfSize(ctx.drawDistance, HALF_SIZE)
	if math.abs(h - halfSize) > RESIZE_THRESHOLD * halfSize then
		layout(h)
	end
	-- the cube follows the eye (workspace axes). CHANGED (Far layer smooth): only when the eye moved
	local eye = ctx.camera.Position
	if (eye - viewState.eye).Magnitude > EYE_STEP then
		viewState.eye = eye
		for index in panels do
			panelMoved[index] = panelCFrames[index] + eye
		end
		Workspace:BulkMoveTo(panelParts, panelMoved, Enum.BulkMoveMode.FireCFrameChanged)
	end
	-- CHANGED (Far layer smooth): the static scene. Copies are re-posed only when their band moved past the
	-- threshold, was rebuilt, or the anchor / scale changed; the face cameras only when the eye moved or the pocket
	-- frame turned past it
	local camera = Workspace.CurrentCamera
	local fov = if camera then camera.FieldOfView else 70
	local viewport = if camera then camera.ViewportSize else Vector2.new(16, 9)
	local cam = ctx.cameraDominant
	local force = placeAnchor(cam, ctx.dominantBodyId) or scale ~= scaleNow
	scaleNow = scale
	local tolerance = FarLayerMath.pixelAngle(PIXEL_TOLERANCE, fov, viewport.Y)
	local nearest = nearestGround(cam)
	meters.nearest = nearest
	poseBands(cam, force, nearest, tolerance)
	local camScene = Vector3.new(cam.x - anchor.x, cam.y - anchor.y, cam.z - anchor.z)
	if
		force
		or FarLayerMath.viewDue(
			(camScene - viewState.cam).Magnitude,
			FarLayerMath.turnAngle(viewState.rot, toWorkspace),
			nearest,
			tolerance
		)
	then
		viewState.cam, viewState.rot = camScene, toWorkspace
		viewState.version += 1
	end
	if testOn then
		poseReferences(viewState.cam * scaleNow, viewState.rot)
	end
	-- only the faces that can show in the view (and FACE_HOLD_S after) are drawn and kept up to date
	local aspect = if viewport.Y > 0 then viewport.X / viewport.Y else 16 / 9
	FarLayerMath.visibleFaces(ctx.camera.LookVector, ctx.camera.UpVector, fov, aspect, VISIBLE_MARGIN, visible)
	updateLight(ctx, toWorkspace)
	diag.startsLeft, diag.replacesLeft = COPY_STARTS_PER_FRAME, REPLACE_STARTS_PER_FRAME
	local now = os.clock()
	for index, panel in panels do
		if visible[index] then
			panel.seenAt = now
		end
	end
	-- the faces in view first (they get the copy starts first), then the held ones
	for pass = 1, 2 do
		for index, panel in panels do
			if (pass == 1) ~= visible[index] then
				continue
			end
			-- CHANGED (Far layer fix): test mode draws all six
			local show = testOn or FarLayerMath.faceHeld(visible[index], panel.seenAt, now, FACE_HOLD_S)
			if show then
				syncFace(panel)
				if panel.viewVersion ~= viewState.version then
					panel.viewVersion = viewState.version
					panel.camera.CFrame = FarLayerMath.sceneCamera(panel.face, viewState.rot, viewState.cam * scaleNow)
					writes.cameras += 1
				end
			end
			if panel.shown ~= show then
				panel.shown = show
				panel.gui.Enabled = show
			end
		end
	end
	if testOn then
		updateLabels()
	end
	-- CHANGED (Far layer fix): one [FarLayer] line once the first copies are made (or after REPORT_TIMEOUT)
	if diag.reportDue then
		local c = count().stats
		if (c.copies > 0 and c.pending == 0) or os.clock() - diag.startedAt > REPORT_TIMEOUT then
			diag.reportDue = false
			print("[FarLayer] " .. report())
		end
	end
	-- CHANGED (Far layer smooth): the F3 meters
	local finished = os.clock()
	PeakMeter.add(meters.cost, finished, (finished - started) * 1000)
	PeakMeter.add(meters.cameras, finished, writes.cameras)
	PeakMeter.add(meters.copies, finished, writes.copies)
	PeakMeter.add(meters.started, finished, meters.starts)
end

-- CHANGED (Far layer): the backdrop is on screen this frame (SkyCube: the ground beyond its panels is in it)
function FarLayer.isShown(): boolean
	return shownNow
end

-- CHANGED (Far layer fix): how far the panels reach from the eye (their farthest corner) while the backdrop is
-- shown, else 0: ScaledSpace keeps other bodies' proxies beyond it, so the picture's ground hides them (Earth seen
-- from the Mun behind the far hills) and its clear sky shows them
function FarLayer.reach(): number
	if not shownNow then
		return 0
	end
	return FarLayerMath.reach(halfSize, PANEL_OVERLAP)
end

function FarLayer.setTint(on: boolean, colours: { Color3 }, further: Color3)
	tint.on, tint.colours, tint.further = on, colours, further
	for _, panel in panels do
		for id, entry in panel.copies do
			local copy = entry.copy
			if copy then
				copy.Color = tintOf(id)
			end
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
	-- CHANGED (Far layer fix): + the verdict; the rest is on the F3 "Far layer:" line (details)
	return string.format("far: layer %d/6 faces x%.3f [%s]", faces, scaleNow, FarLayerMath.verdict(count().stats))
end

-- CHANGED (Far layer fix): the F3 "Far layer:" line (UniverseRenderer adds it under "Terrain:")
-- CHANGED (Far layer smooth): + the Lua cost per frame (average / peak, ms), the writes per frame (face cameras /
-- copies, average / peak), copies started per frame and the threshold's nearest ground
function FarLayer.details(): string
	if not FarLayer.active() then
		return "Far layer: off (far ground: mesh; /farground or /farground test turns it on)"
	end
	local c = count()
	local s = c.stats
	local now = os.clock()
	return string.format(
		"Far layer: [%s] faces %s bands %d copies %d (async %d clone %d fail %d load %d) mesh %d/%d tex %s "
			.. "panel %d corner %d / draw %d %dpx%s err %d: %s | lua %.3f ms (peak %.2f) writes/f cam %.2f (%d) "
			.. "copy %.2f (%d) starts %.2f near %d",
		FarLayerMath.verdict(s),
		FarLayerMath.faceList(visible),
		s.bands,
		s.copies,
		c.async,
		c.clone,
		s.failed,
		s.pending,
		s.valid,
		s.copies,
		if textureOn then white.state else "off",
		math.floor(halfSize),
		math.floor(FarLayerMath.reach(halfSize, PANEL_OVERLAP)),
		math.floor(diag.drawDistance),
		canvas,
		if testOn then " TEST" else "",
		diag.errors,
		diag.lastError,
		PeakMeter.average(meters.cost, now),
		PeakMeter.peak(meters.cost, now),
		PeakMeter.average(meters.cameras, now),
		PeakMeter.peak(meters.cameras, now),
		PeakMeter.average(meters.copies, now),
		PeakMeter.peak(meters.copies, now),
		PeakMeter.average(meters.started, now),
		math.floor(meters.nearest)
	)
end

return table.freeze(FarLayer)
