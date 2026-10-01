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
	  * bodies without air: 1 above the ground view;
	  * with air: smoothstep from the proxy handover altitude to the top of the atmosphere.
	Below the handover the ground view is drawn and Roblox's skybox is the sky (blue by day, starry by night).

	The cube's half-size follows the draw distance (everything ScaledSpace draws stays inside it, D10) and is
	capped so panels stay at most PANEL_MAX studs (part size limit 2048). At very low graphics quality the engine
	may cull far panels; Roblox's sky then shows through there.

	If EditableImage is unavailable the panels are plain near-black (space without stars).

	API:
		SkyCube.init(parent)                                  -- parent: workspace.ClientUniverse
		SkyCube.update(ctx, surfaceMode, handoverAltitude)    -- every frame, after ScaledSpace
]]

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Bodies = require(ReplicatedStorage.Shared.Config.Bodies)
local RenderContext = require(script.Parent.RenderContext)

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
--============================================================================

local SkyCube = {}

type Panel = { part: Part, background: Frame, stars: ImageLabel, localCFrame: CFrame }

local folder: Folder? = nil
local home: Folder? = nil -- where the cube folder is parented while shown
local panels: { Panel } = {}
local parts: { BasePart } = {}
local cframes: { CFrame } = {}
local images: { EditableImage } = {} -- kept alive (a destroyed EditableImage blanks its users)
local halfSize = 0
local opacity = -1
local shown = false

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

local function makeStarImages(): { Content }
	local contents: { Content } = {}
	for _ = 1, STAR_IMAGES do
		local ok, result = pcall(function(): EditableImage?
			return AssetService:CreateEditableImage({ Size = Vector2.new(STAR_IMAGE_SIZE, STAR_IMAGE_SIZE) })
		end)
		local image: EditableImage? = if ok then result else nil
		if not image then
			warn("[SkyCube] EditableImage unavailable (" .. tostring(result) .. "); space is drawn without stars.")
			return {}
		end
		local buf = paintStars()
		local written, err = pcall(function()
			image:WritePixelsBuffer(Vector2.zero, image.Size, buf)
		end)
		if not written then
			warn("[SkyCube] could not paint stars (" .. tostring(err) .. "); space is drawn without stars.")
			return {}
		end
		table.insert(images, image)
		table.insert(contents, Content.fromObject(image))
	end
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
				-- lookAt from the panel toward the centre: its -Z (Front) faces inward, +Y along u
				panel.localCFrame = CFrame.lookAt(position, Vector3.zero, u)
				panel.part.Size = Vector3.new(panelSize, panelSize, PANEL_DEPTH)
			end
		end
	end
	halfSize = h
end

local function setOpacity(value: number)
	opacity = value
	local transparency = 1 - value
	for _, panel in panels do
		panel.background.BackgroundTransparency = transparency
		panel.stars.ImageTransparency = transparency
	end
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
local function spaceOpacity(ctx: RenderContext.RenderContext, surfaceMode: boolean, handover: number): number
	if surfaceMode then
		return 0
	end
	local body = Bodies.find(ctx.dominantBodyId)
	local atmosphere = if body then body.Atmosphere else nil
	if atmosphere == nil then
		return 1
	end
	return smoothstep(handover, atmosphere.Top, ctx.altitude)
end

function SkyCube.update(ctx: RenderContext.RenderContext, surfaceMode: boolean, handover: number)
	local f = folder
	if f == nil then
		return
	end
	local target = spaceOpacity(ctx, surfaceMode, handover)
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
	local h = math.clamp(ctx.drawDistance * HALF_SIZE_FRACTION, HALF_SIZE_MIN, HALF_SIZE_MAX)
	if math.abs(h - halfSize) > RESIZE_THRESHOLD * halfSize then
		layout(h)
	end
	-- universe axes (stars fixed in space), centred on the camera
	local base = CFrame.new(ctx.camera.Position) * ctx.frame.refRotInv
	for index, panel in panels do
		cframes[index] = base * panel.localCFrame
	end
	Workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

return SkyCube
