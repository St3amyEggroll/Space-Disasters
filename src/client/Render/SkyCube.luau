--!strict
--[[
	SkyCube (Phase 2a playtest 4)
	Space, drawn in front of Roblox's own sky: a cube of flat panels around the camera, each carrying a SurfaceGui
	(LightInfluence 0, so it is unlit) with a near-black background and a painted star image (EditableImage in an
	ImageLabel, the engine's main EditableImage use). The cube is oriented to universe axes, so the stars stay
	fixed while the pocket and the rocket turn.

	Why not the Sky itself: painting the Sky's faces with EditableImages did not show in Studio, Roblox's
	Atmosphere draws a procedural sky with a grey lower half, and Roblox's skybox can only be blue (day) or dark
	(night) by the sun's elevation, while space must be black in full sunlight.

	Opacity (0 = Roblox's sky shows, 1 = black space):
	  * in surface mode (the true-scale ground is drawn): 0, so far ground tiles are never hidden behind the cube;
	    CHANGED (Far layer): except on bodies without air (the Mun): 1 while the ground drawn in the 3D world lies
	    inside the cube (the far ground's backdrop, Render/FarLayer, is in front of it), so their sky is space;
	  * bodies without air: 1 above the ground view;
	  * with air: smoothstep from the proxy handover altitude to the top of the atmosphere.
	Below the handover the ground view is drawn and Roblox's skybox is the sky (blue by day, starry by night).

	The cube's half-size follows the draw distance (everything ScaledSpace draws stays inside it, D10) and is
	capped so panels stay at most PANEL_MAX studs (part size limit 2048). At very low graphics quality the engine
	may cull far panels; Roblox's sky then shows through there.

	If EditableImage is unavailable the panels are plain near-black (space without stars).

	CHANGED (Memory budget): the star images are created through Render/EditableBudget (priority STARS, 9 x 256 x 256
	x 4 = 2.25 MiB, declared as a demand so nothing lower plans to use it). A budget refusal is retried every
	STAR_RETRY_S from update (the panels stay starless black meanwhile); images made before a refusal or a failed
	paint are destroyed (they leaked before).

	CHANGED (Solar system):
	  * the stars are fixed to Sol's axes (the heliocentric frame), so they slowly turn across Earth's and Mars'
	    night skies (each planet turns its own axes) and stay put when a craft changes SOI;
	  * a body whose air has a SkyColor (Mars) gets its whole sky from the cube, in the air and on the ground (Roblox's
	    sky is blue): by day the panels are that colour (butterscotch) without stars, fading to black space with
	    stars by night and with altitude (day = sun elevation at the camera, air = 1 at the ground .. 0 at the top).
	    Risk: the cube (0.9 x draw distance) can cover the farthest terrain triangles at the horizon there.

	API:
		SkyCube.init(parent)                                  -- parent: workspace.ClientUniverse
		SkyCube.update(ctx, surfaceMode, handoverAltitude, groundReach?)
		                                                      -- every frame, after ScaledSpace and Surface;
		                                                      -- CHANGED (Far layer): groundReach: studs the 3D
		                                                      -- world's ground reaches (Surface.groundReach)
		SkyCube.setOverride(opacity?, halfSize?)              -- CHANGED (Phase 5): fixed opacity / size (map view);
		                                                      -- nil restores the automatic behaviour
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local EditableBudget = require(script.Parent.EditableBudget) -- CHANGED (Memory budget)
local Frames = require(ReplicatedStorage.Shared.Math.Frames) -- CHANGED (Solar system)
local RenderContext = require(script.Parent.RenderContext)
local Universe = require(ReplicatedStorage.Shared.Sim.Universe) -- CHANGED (Solar system)
local Vec3d = require(ReplicatedStorage.Shared.Math.Vec3d) -- CHANGED (Solar system)

--============================================================================
-- Tunables
--============================================================================
local PANELS_PER_EDGE = 3 -- panels along each cube edge (6 * 3 * 3 = 54 panels)
local HALF_SIZE_FRACTION = 0.9 -- cube half-size as a fraction of the draw distance (ScaledSpace stays within 0.85)
local HALF_SIZE_MIN = 400 -- studs
local HALF_SIZE_MAX = 2900 -- studs; ScaledSpace's farthest drawn surface stays near 2,000 studs (D10 limits)
local RESIZE_THRESHOLD = 0.02 -- relative half-size change that rebuilds panel sizes
local SPACE_COLOR = Color3.fromRGB(3, 3, 8) -- near black with a hint of blue
local STAR_IMAGE_SIZE = 256 -- pixels per star image
local STAR_IMAGES = 9 -- distinct star images, shared round-robin by the panels
local STARS_PER_IMAGE = 160
local BRIGHT_STAR_FRACTION = 0.05
local MIN_BRIGHTNESS = 0.25
local BRIGHTNESS_POWER = 3
local TINT_STRENGTH = 0.25
local SEED = 1337
local OPACITY_STEP = 0.01 -- rewrite transparencies only when opacity moved more than this
local MAX_GUI_DISTANCE = 1e6 -- studs (SurfaceGui.MaxDistance)
local PANEL_DEPTH = 0.2 -- studs
local PANEL_OVERLAP = 0.01 -- panels are 1% larger than their grid cell so no hairline seams show
local STAR_RETRY_S = 20 -- CHANGED (Memory budget): s between attempts after the memory budget refused the stars
local BUDGET_OWNER = "SkyCube" -- CHANGED (Memory budget)
-- CHANGED (Solar system): painted day sky (bodies whose air has a SkyColor: Mars)
local SKY_DAY_ELEVATION0 = -0.08 -- sin of the sun's elevation where the day sky starts ...
local SKY_DAY_ELEVATION1 = 0.12 -- ... and is full
local SKY_AIR_POWER = 0.7 -- sky amount = day * air^this (as Roblox's sky thins with height)
local SKY_COLOR_STEP = 0.01 -- rewrite panel colours only when the sky amount moved more than this
-- CHANGED (Far layer): an airless body's sky is space on the ground too while the 3D world's ground stays within
-- this x the cube's half-size (SkyCube.update's groundReach)
local GROUND_CLEARANCE = 0.97
--============================================================================

local SkyCube = {}

-- CHANGED (Phase 5): the map view draws inside a fully opaque cube of a fixed size
type Override = { opacity: number, halfSize: number }
local override: Override? = nil

type Panel = { part: Part, background: Frame, stars: ImageLabel, localCFrame: CFrame }

local folder: Folder? = nil
local home: Folder? = nil -- where the cube folder is parented while shown
local panels: { Panel } = {}
local parts: { BasePart } = {}
local cframes: { CFrame } = {}
local images: { EditableImage } = {} -- kept alive (a destroyed EditableImage blanks its users)
local handles: { EditableBudget.Handle } = {} -- CHANGED (Memory budget): their budget handles
local starRetryAt = math.huge -- CHANGED (Memory budget): when to try the stars again (after a budget refusal)
local halfSize = 0
local opacity = -1
local shown = false
local skyAmount = -1 -- CHANGED (Solar system): 0 = space (black, stars) .. 1 = a painted day sky
local skyTint: Color3? = nil

-- Deterministic generator (LCG), [0, 1).
local rngState = SEED
local function random(): number
	rngState = (rngState * 1103515245 + 12345) % 2147483648
	return rngState / 2147483648
end

local function smoothstep(edge0: number, edge1: number, x: number): number
	if edge1 <= edge0 then
		return if x >= edge1 then 1 else 0
	end
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

-- Transparent background with point stars (RGBA, alpha 0 except the stars).
local function paintStars(): buffer
	local size = STAR_IMAGE_SIZE
	local buf = buffer.create(size * size * 4) -- zero = fully transparent
	local function put(x: number, y: number, r: number, g: number, b: number, a: number)
		if x < 0 or y < 0 or x >= size or y >= size then
			return
		end
		local offset = (y * size + x) * 4
		buffer.writeu8(buf, offset, r)
		buffer.writeu8(buf, offset + 1, g)
		buffer.writeu8(buf, offset + 2, b)
		buffer.writeu8(buf, offset + 3, math.max(buffer.readu8(buf, offset + 3), a))
	end
	for _ = 1, STARS_PER_IMAGE do
		local x = math.floor(random() * size)
		local y = math.floor(random() * size)
		local brightness = MIN_BRIGHTNESS + (1 - MIN_BRIGHTNESS) * random() ^ BRIGHTNESS_POWER
		local tint = (random() * 2 - 1) * TINT_STRENGTH
		local r = math.floor(255 * math.clamp(1 + math.max(tint, 0) - math.max(-tint, 0) * 0.5, 0, 1))
		local g = 255
		local b = math.floor(255 * math.clamp(1 + math.max(-tint, 0) - math.max(tint, 0) * 0.5, 0, 1))
		local a = math.floor(255 * brightness)
		put(x, y, r, g, b, a)
		if random() < BRIGHT_STAR_FRACTION then
			local halo = math.floor(a * 0.45)
			put(x + 1, y, r, g, b, halo)
			put(x - 1, y, r, g, b, halo)
			put(x, y + 1, r, g, b, halo)
			put(x, y - 1, r, g, b, halo)
		end
	end
	return buf
end

-- CHANGED (Memory budget): through EditableBudget; on any failure every image made so far is destroyed (no leak)
-- and the panels stay starless (a budget refusal is retried later from update).
local function makeStarImages(): { Content }
	local contents: { Content } = {}
	local function fail(message: string?): { Content }
		for _, handle in handles do
			EditableBudget.destroy(handle)
		end
		table.clear(handles)
		table.clear(images)
		if message then
			EditableBudget.warnOnce("SkyCube", message)
		end
		return {}
	end
	EditableBudget.setDemand(
		BUDGET_OWNER,
		STAR_IMAGES * EditableBudget.imageBytes(STAR_IMAGE_SIZE, STAR_IMAGE_SIZE),
		EditableBudget.PRIORITY.STARS
	)
	for _ = 1, STAR_IMAGES do
		local image, handle, refusal = EditableBudget.createImage(
			BUDGET_OWNER,
			Vector2.new(STAR_IMAGE_SIZE, STAR_IMAGE_SIZE),
			EditableBudget.PRIORITY.STARS,
			nil
		)
		if image == nil or handle == nil then
			if refusal == "budget" then
				starRetryAt = os.clock() + STAR_RETRY_S
				return fail("[SkyCube] star images wait for Editable memory (budget); space is starless until then.")
			end
			EditableBudget.setDemand(BUDGET_OWNER, 0, EditableBudget.PRIORITY.STARS)
			return fail("[SkyCube] EditableImage unavailable; space is drawn without stars.")
		end
		table.insert(handles, handle)
		local buf = paintStars()
		local written, err = pcall(function()
			image:WritePixelsBuffer(Vector2.zero, image.Size, buf)
		end)
		if not written then
			EditableBudget.setDemand(BUDGET_OWNER, 0, EditableBudget.PRIORITY.STARS)
			return fail("[SkyCube] could not paint stars (" .. tostring(err) .. "); space is drawn without stars.")
		end
		table.insert(images, image)
		table.insert(contents, Content.fromObject(image))
	end
	starRetryAt = math.huge
	return contents
end

local function newPanel(parent: Folder, starContent: Content?): Panel
	local part = Instance.new("Part")
	part.Name = "SkyPanel"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Locked = true
	part.Transparency = 1
	part.Size = Vector3.new(1, 1, PANEL_DEPTH)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "Sky"
	gui.Face = Enum.NormalId.Front -- the panel's front faces the camera (cube centre)
	gui.LightInfluence = 0
	gui.Brightness = 1
	gui.AlwaysOnTop = false
	gui.MaxDistance = MAX_GUI_DISTANCE
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(STAR_IMAGE_SIZE, STAR_IMAGE_SIZE)
	gui.ClipsDescendants = true
	gui.Adornee = part
	gui.Parent = part

	local background = Instance.new("Frame")
	background.Name = "Space"
	background.BorderSizePixel = 0
	background.Size = UDim2.fromScale(1, 1)
	background.BackgroundColor3 = SPACE_COLOR
	background.BackgroundTransparency = 1
	background.Parent = gui

	local stars = Instance.new("ImageLabel")
	stars.Name = "Stars"
	stars.BackgroundTransparency = 1
	stars.Size = UDim2.fromScale(1, 1)
	stars.ImageTransparency = 1
	stars.ScaleType = Enum.ScaleType.Stretch
	if starContent then
		stars.ImageContent = starContent
	end
	stars.Parent = background

	part.Parent = parent
	return { part = part, background = background, stars = stars, localCFrame = CFrame.identity }
end

-- Panel layout for a cube of half-size h around the origin: each panel's front (-Z) looks at the centre.
local function layout(h: number)
	local panelSize = 2 * h / PANELS_PER_EDGE
	local normals = { Vector3.xAxis, -Vector3.xAxis, Vector3.yAxis, -Vector3.yAxis, Vector3.zAxis, -Vector3.zAxis }
	local index = 0
	for _, n in normals do
		local u = if math.abs(n.Y) > 0.5 then Vector3.xAxis else Vector3.yAxis
		local v = n:Cross(u)
		for i = 1, PANELS_PER_EDGE do
			for j = 1, PANELS_PER_EDGE do
				index += 1
				local a = (i - 0.5) * panelSize - h
				local b = (j - 0.5) * panelSize - h
				local position = n * h + u * a + v * b
				local panel = panels[index]
				-- CHANGED (Phase 2a playtest 5): every panel lies flat in its cube face (front = -n, inward).
				-- Aiming each panel at the centre tilted the off-centre ones, and the Roblox sky showed through
				-- wedge-shaped gaps between them.
				panel.localCFrame = CFrame.lookAt(position, position - n, u)
				local overlap = panelSize * (1 + PANEL_OVERLAP)
				panel.part.Size = Vector3.new(overlap, overlap, PANEL_DEPTH)
			end
		end
	end
	halfSize = h
end

-- CHANGED (Solar system): the stars fade out as the painted day sky comes in (skyAmount)
local function setOpacity(value: number)
	opacity = value
	local transparency = 1 - value
	local starTransparency = 1 - value * (1 - math.max(skyAmount, 0))
	for _, panel in panels do
		panel.background.BackgroundTransparency = transparency
		panel.stars.ImageTransparency = starTransparency
	end
end

-- CHANGED (Solar system): panel colour for a sky amount (0 = space) in a body's SkyColor, then the stars' fade.
local function setSky(amount: number, tint: Color3?)
	skyAmount = amount
	skyTint = tint
	local color = if tint then SPACE_COLOR:Lerp(tint, amount) else SPACE_COLOR
	for _, panel in panels do
		panel.background.BackgroundColor3 = color
	end
	setOpacity(math.max(opacity, 0))
end

-- CHANGED (Solar system): the day-sky amount at the camera on a body whose air has a SkyColor (header).
local function daySkyAmount(ctx: RenderContext.RenderContext, body: Bodies.Body): number
	local atmosphere = body.Atmosphere
	if atmosphere == nil or atmosphere.Top <= 0 or ctx.altitude >= atmosphere.Top then
		return 0
	end
	local air = 1 - math.clamp(ctx.altitude / atmosphere.Top, 0, 1)
	-- radial up at the camera, in the frame body's axes (the sun direction's axes)
	local centre = Universe.bodyOffset(body.Id, ctx.frame.refBodyId, ctx.ut)
	local radial = Vec3d.sub(ctx.cameraAbs, centre)
	local length = Vec3d.length(radial)
	if length < 1 then
		return 0
	end
	local sun = Frames.vectorFromWorkspace(ctx.frame, ctx.sunDirection)
	local elevation = Vec3d.dot(radial, sun) / length
	local day = smoothstep(SKY_DAY_ELEVATION0, SKY_DAY_ELEVATION1, elevation)
	return day * air ^ SKY_AIR_POWER
end

function SkyCube.init(parent: Folder)
	local f = Instance.new("Folder")
	f.Name = "SkyCube"
	folder = f
	local contents = makeStarImages()
	for index = 1, 6 * PANELS_PER_EDGE * PANELS_PER_EDGE do
		local content = if #contents > 0 then contents[(index - 1) % #contents + 1] else nil
		local panel = newPanel(f, content)
		table.insert(panels, panel)
		table.insert(parts, panel.part)
		table.insert(cframes, CFrame.identity)
	end
	layout(HALF_SIZE_MIN)
	setOpacity(0)
	home = parent
	shown = false
end

-- Space opacity for this frame (header).
-- CHANGED (Solar system): a body with a SkyColor (Mars) is always fully covered (the cube paints its day sky too).
-- CHANGED (Far layer): a body without air is space on the ground too (Steamy: "mun should be space cause it has no
-- atmophere": Roblox's blue sky showed there), as long as the ground drawn in the 3D world lies inside the cube
-- (groundReach < GROUND_CLEARANCE x h): the far ground's backdrop sits in front of the cube; "mesh" mode's 3D bands
-- reach ~1.7 km (Low's 1500-stud draw distance gives a 1350-stud cube: Roblox's sky stays there)
local function spaceOpacity(
	ctx: RenderContext.RenderContext,
	surfaceMode: boolean,
	handover: number,
	h: number,
	groundReach: number?
): number
	local body = Bodies.find(ctx.dominantBodyId)
	local atmosphere = if body then body.Atmosphere else nil
	if atmosphere and atmosphere.SkyColor then
		return 1
	end
	if surfaceMode then
		if body and atmosphere == nil and groundReach ~= nil and groundReach < GROUND_CLEARANCE * h then
			return 1
		end
		return 0
	end
	if atmosphere == nil then
		return 1
	end
	return smoothstep(handover, atmosphere.Top, ctx.altitude)
end

-- CHANGED (Phase 5): forces the opacity and half-size (studs) until called with nil.
function SkyCube.setOverride(value: number?, halfSize: number?)
	if value == nil then
		override = nil
	else
		override =
			{ opacity = math.clamp(value, 0, 1), halfSize = math.clamp(halfSize or HALF_SIZE_MIN, 50, HALF_SIZE_MAX) }
	end
end

function SkyCube.update(
	ctx: RenderContext.RenderContext,
	surfaceMode: boolean,
	handover: number,
	groundReach: number? -- CHANGED (Far layer): studs the 3D world's ground reaches (Surface.groundReach)
)
	local f = folder
	if f == nil then
		return
	end
	-- CHANGED (Memory budget): stars refused by the memory budget: try again now and then
	if os.clock() >= starRetryAt then
		starRetryAt = math.huge
		local contents = makeStarImages()
		for index, panel in panels do
			if #contents > 0 then
				panel.stars.ImageContent = contents[(index - 1) % #contents + 1]
			end
		end
	end
	local forced = override
	-- CHANGED (Solar system): the painted day sky (Mars); none in the map view (override)
	local dominant = Bodies.find(ctx.dominantBodyId)
	local tint = if dominant and dominant.Atmosphere and not forced then dominant.Atmosphere.SkyColor else nil
	local amount = if tint and dominant then daySkyAmount(ctx, dominant) else 0
	if tint ~= skyTint or math.abs(amount - skyAmount) > SKY_COLOR_STEP or (amount == 0 and skyAmount ~= 0) then
		setSky(amount, tint)
	end
	-- CHANGED (Far layer): the half-size first (an airless body's ground must lie inside the cube)
	local h = if forced
		then forced.halfSize
		else math.clamp(ctx.drawDistance * HALF_SIZE_FRACTION, HALF_SIZE_MIN, HALF_SIZE_MAX)
	local target = if forced then forced.opacity else spaceOpacity(ctx, surfaceMode, handover, h, groundReach)
	if target <= 0 then
		if shown then
			shown = false
			f.Parent = nil
		end
		return
	end
	if not shown then
		shown = true
		f.Parent = home
	end
	if math.abs(target - opacity) > OPACITY_STEP or (target >= 1 and opacity < 1) then
		setOpacity(target)
	end
	if math.abs(h - halfSize) > RESIZE_THRESHOLD * halfSize then
		layout(h)
	end
	-- universe axes (stars fixed in space), centred on the camera
	-- CHANGED (Solar system): Sol's axes (the heliocentric frame), whatever body the pocket is on
	local base = CFrame.new(ctx.camera.Position)
		* ctx.frame.refRotInv
		* Universe.axesRotation(Bodies.ROOT, ctx.frame.refBodyId, ctx.ut)
	for index, panel in panels do
		cframes[index] = base * panel.localCFrame
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

return SkyCube
