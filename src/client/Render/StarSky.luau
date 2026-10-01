--!strict
--[[
	StarSky (Phase 2a feedback)
	A black, starry skybox for space, painted at runtime into six EditableImages (no uploaded assets needed).

	SkyLighting owns the Sky and decides when it is space: StarSky.setSpace(sky, true) puts the star faces on,
	setSpace(sky, false) restores the skybox the Sky had before (Roblox's default day sky, which the Atmosphere
	tints blue at low altitude). The star field is the same on every face edge-to-edge (independent point
	stars), and SkyLighting keeps it fixed to universe axes with Sky.SkyboxOrientation.

	If EditableImage or the Sky *Content properties are unavailable (e.g. "Allow Mesh / Image APIs" is off),
	it warns once and space keeps the default sky.

	API:
		StarSky.init()                       -- starts painting in the background (non-blocking)
		StarSky.setSpace(sky, space)         -- every frame or on change; cheap when nothing changes
		StarSky.isReady(): boolean
]]

local AssetService = game:GetService("AssetService")

--============================================================================
-- Tunables
--============================================================================
local FACE_SIZE = 512 -- pixels per skybox face
local STARS_PER_FACE = 1100
local BRIGHT_STAR_FRACTION = 0.04 -- stars drawn as a small cross with a soft glow
local MIN_BRIGHTNESS = 0.18
local BRIGHTNESS_POWER = 3 -- most stars are faint, a few are bright
local TINT_STRENGTH = 0.25 -- +/- blue/orange tint of star colours
local BACKGROUND = { 2, 2, 6 } -- near black with a hint of blue (RGB 0..255)
local SEED = 20261001
local PAINT_BUDGET_S = 0.004 -- seconds of painting per frame before yielding
--============================================================================

local FACES: { string } = { "Back", "Down", "Front", "Left", "Right", "Up" }

local StarSky = {}

local images: { [string]: EditableImage } = {}
local contents: { [string]: Content } = {}
local ready = false
local failed = false
local started = false
local applied: Sky? = nil -- the Sky currently showing stars
local saved: { [string]: string } = {} -- the Sky's original skybox ids, restored when leaving space

-- Small deterministic generator (LCG), returns [0, 1).
local state = SEED
local function random(): number
	state = (state * 1103515245 + 12345) % 2147483648
	return state / 2147483648
end

local function pixel(buf: buffer, x: number, y: number, r: number, g: number, b: number)
	if x < 0 or y < 0 or x >= FACE_SIZE or y >= FACE_SIZE then
		return
	end
	local offset = (y * FACE_SIZE + x) * 4
	-- add (stars may overlap the glow of a neighbour), clamp to 255
	buffer.writeu8(buf, offset, math.min(255, buffer.readu8(buf, offset) + r))
	buffer.writeu8(buf, offset + 1, math.min(255, buffer.readu8(buf, offset + 1) + g))
	buffer.writeu8(buf, offset + 2, math.min(255, buffer.readu8(buf, offset + 2) + b))
end

local function paintFace(): buffer
	local count = FACE_SIZE * FACE_SIZE
	local buf = buffer.create(count * 4)
	local background = BACKGROUND[1] + BACKGROUND[2] * 256 + BACKGROUND[3] * 65536 + 255 * 16777216
	for index = 0, count - 1 do
		buffer.writeu32(buf, index * 4, background)
	end
	for _ = 1, STARS_PER_FACE do
		local x = math.floor(random() * FACE_SIZE)
		local y = math.floor(random() * FACE_SIZE)
		local brightness = MIN_BRIGHTNESS + (1 - MIN_BRIGHTNESS) * random() ^ BRIGHTNESS_POWER
		local tint = (random() * 2 - 1) * TINT_STRENGTH
		local r = math.floor(255 * brightness * (1 + math.max(tint, 0)) / (1 + TINT_STRENGTH))
		local g = math.floor(255 * brightness / (1 + TINT_STRENGTH * 0.5))
		local b = math.floor(255 * brightness * (1 + math.max(-tint, 0)) / (1 + TINT_STRENGTH))
		pixel(buf, x, y, r, g, b)
		if random() < BRIGHT_STAR_FRACTION then
			local half = 0.45
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				pixel(buf, x + d[1], y + d[2], math.floor(r * half), math.floor(g * half), math.floor(b * half))
			end
		end
	end
	return buf
end

local function paintAll()
	local started_at = os.clock()
	for _, face in FACES do
		local ok, result = pcall(function(): EditableImage?
			return AssetService:CreateEditableImage({ Size = Vector2.new(FACE_SIZE, FACE_SIZE) })
		end)
		local created: EditableImage? = if ok then result else nil
		if not created then
			failed = true
			warn("[StarSky] EditableImage unavailable (" .. tostring(result) .. "); space keeps the default sky.")
			return
		end
		local image = created
		local buf = paintFace()
		local written, err = pcall(function()
			image:WritePixelsBuffer(Vector2.zero, image.Size, buf)
		end)
		if not written then
			failed = true
			warn("[StarSky] could not paint the star sky (" .. tostring(err) .. "); space keeps the default sky.")
			return
		end
		images[face] = image
		contents[face] = Content.fromObject(image)
		if os.clock() - started_at > PAINT_BUDGET_S then
			task.wait()
			started_at = os.clock()
		end
	end
	ready = true
end

local ID_PROPERTIES = { "SkyboxBk", "SkyboxDn", "SkyboxFt", "SkyboxLf", "SkyboxRt", "SkyboxUp" }

local function putStars(sky: Sky): boolean
	for _, name in ID_PROPERTIES do
		saved[name] = (sky :: any)[name]
	end
	local ok, err = pcall(function()
		sky.SkyboxBackContent = contents["Back"]
		sky.SkyboxDownContent = contents["Down"]
		sky.SkyboxFrontContent = contents["Front"]
		sky.SkyboxLeftContent = contents["Left"]
		sky.SkyboxRightContent = contents["Right"]
		sky.SkyboxUpContent = contents["Up"]
	end)
	if not ok then
		failed = true
		warn("[StarSky] the Sky does not accept painted faces (" .. tostring(err) .. "); space keeps the default sky.")
		return false
	end
	return true
end

local function restore(sky: Sky)
	pcall(function()
		for _, name in ID_PROPERTIES do
			(sky :: any)[name] = saved[name] or ""
		end
	end)
end

function StarSky.init()
	if started then
		return
	end
	started = true
	task.spawn(paintAll)
end

function StarSky.isReady(): boolean
	return ready and not failed
end

-- Shows the stars on `sky` while `space` is true, the original skybox otherwise.
function StarSky.setSpace(sky: Sky, space: boolean)
	if failed or not ready then
		return
	end
	if space then
		if applied ~= sky then
			if applied then
				restore(applied :: Sky)
			end
			if putStars(sky) then
				applied = sky
			end
		end
	elseif applied then
		restore(applied :: Sky)
		applied = nil
	end
end

-- keep the images alive for the lifetime of the client (a destroyed EditableImage blanks its users)
StarSky._images = images

return StarSky
