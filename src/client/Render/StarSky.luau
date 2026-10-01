--!strict
--[[
	StarSky (Phase 2a playtest)
	The whole sky, painted at runtime into six EditableImages used as the Sky's skybox faces (no uploaded assets).
	Roblox's Atmosphere is NOT used: whenever an Atmosphere exists Roblox draws its own procedural sky (even at
	Density 0) with a fixed "below the horizon" grey half, which split the screen in two and kept space blue.

	The faces are a blend of two layers:
	  * space: near-black with point stars (fixed to universe axes by SkyLighting's SkyboxOrientation)
	  * day:   one flat sky colour (blue, warmer toward sunset), chosen by SkyLighting
	  pixel = space * (1 - day) + dayColor * day
	`day` is 1 in daylight low in the air and 0 at night or in space. A flat day colour needs no knowledge of the
	skybox faces' directions, so it can never show seams. Stars are additive over the background, so a repaint is
	a fast fill of the background colour (buffer doubling copies) plus the ~1% of pixels that hold stars, and it
	only runs when `day` or the colour changed noticeably. Faces are written round-robin to spread the cost.

	If EditableImage or the Sky *Content properties are unavailable, it warns once and leaves the Sky alone.

	API:
		StarSky.init()                              -- prepares the star layer in the background
		StarSky.update(sky, day, dayColor)          -- every frame; cheap when nothing changed
		StarSky.isReady(): boolean
]]

local AssetService = game:GetService("AssetService")

--============================================================================
-- Tunables
--============================================================================
local FACE_SIZE = 512 -- pixels per skybox face
local STARS_PER_FACE = 1100
local BRIGHT_STAR_FRACTION = 0.04 -- stars drawn with a small cross around them
local BRIGHT_STAR_HALO = 0.45 -- brightness of the cross pixels relative to the star
local MIN_BRIGHTNESS = 0.18
local BRIGHTNESS_POWER = 3 -- most stars are faint, a few are bright
local TINT_STRENGTH = 0.25 -- +/- blue/orange tint of star colours
local SPACE_BACKGROUND = Color3.fromRGB(2, 2, 6) -- near black with a hint of blue
local SEED = 20261001
local REPAINT_DAY_STEP = 0.01 -- repaint when the day factor moved more than this
local REPAINT_COLOR_STEP = 2 / 255 -- ... or a channel of the day colour moved more than this
local FACES_PER_FRAME = 2 -- face images rewritten per frame while a repaint is in progress
local PREPARE_BUDGET_S = 0.004 -- seconds of star preparation per frame before yielding
--============================================================================

local FACES: { string } = { "Back", "Down", "Front", "Left", "Right", "Up" }

type FaceData = {
	image: EditableImage,
	buf: buffer,
	starOffsets: { number }, -- byte offsets of star pixels
	starAdd: { number }, -- packed additive colour per star pixel: r + g * 256 + b * 65536
}

local StarSky = {}

local faces: { FaceData } = {}
local ready = false
local failed = false
local started = false
local appliedTo: Sky? = nil
local paintedDay = -1
local paintedColor = Color3.new(-1, -1, -1)
local pendingFace = 0 -- 0 = no repaint in progress, else the next face index to write
local targetDay = 0
local targetColor = Color3.new(0, 0, 0)

-- Small deterministic generator (LCG), returns [0, 1).
local rngState = SEED
local function random(): number
	rngState = (rngState * 1103515245 + 12345) % 2147483648
	return rngState / 2147483648
end

local function addStarPixel(face: FaceData, x: number, y: number, r: number, g: number, b: number)
	if x < 0 or y < 0 or x >= FACE_SIZE or y >= FACE_SIZE then
		return
	end
	table.insert(face.starOffsets, (y * FACE_SIZE + x) * 4)
	table.insert(face.starAdd, r + g * 256 + b * 65536)
end

local function prepareStars(face: FaceData)
	for _ = 1, STARS_PER_FACE do
		local x = math.floor(random() * FACE_SIZE)
		local y = math.floor(random() * FACE_SIZE)
		local brightness = MIN_BRIGHTNESS + (1 - MIN_BRIGHTNESS) * random() ^ BRIGHTNESS_POWER
		local tint = (random() * 2 - 1) * TINT_STRENGTH
		local r = math.floor(255 * brightness * (1 + math.max(tint, 0)) / (1 + TINT_STRENGTH))
		local g = math.floor(255 * brightness / (1 + TINT_STRENGTH * 0.5))
		local b = math.floor(255 * brightness * (1 + math.max(-tint, 0)) / (1 + TINT_STRENGTH))
		addStarPixel(face, x, y, r, g, b)
		if random() < BRIGHT_STAR_FRACTION then
			local hr, hg, hb =
				math.floor(r * BRIGHT_STAR_HALO), math.floor(g * BRIGHT_STAR_HALO), math.floor(b * BRIGHT_STAR_HALO)
			addStarPixel(face, x + 1, y, hr, hg, hb)
			addStarPixel(face, x - 1, y, hr, hg, hb)
			addStarPixel(face, x, y + 1, hr, hg, hb)
			addStarPixel(face, x, y - 1, hr, hg, hb)
		end
	end
end

-- Fills the whole buffer with one RGBA pixel by repeatedly doubling the filled prefix.
local function fill(buf: buffer, r: number, g: number, b: number)
	buffer.writeu32(buf, 0, r + g * 256 + b * 65536 + 255 * 16777216)
	local size = buffer.len(buf)
	local filled = 4
	while filled < size do
		local count = math.min(filled, size - filled)
		buffer.copy(buf, filled, buf, 0, count)
		filled += count
	end
end

-- Paints one face for the target blend and writes it to its image.
local function paintFace(face: FaceData, day: number, color: Color3)
	local night = 1 - day
	local bgR = math.floor((SPACE_BACKGROUND.R * night + color.R * day) * 255 + 0.5)
	local bgG = math.floor((SPACE_BACKGROUND.G * night + color.G * day) * 255 + 0.5)
	local bgB = math.floor((SPACE_BACKGROUND.B * night + color.B * day) * 255 + 0.5)
	local buf = face.buf
	fill(buf, bgR, bgG, bgB)
	if night > 0.004 then
		local offsets, adds = face.starOffsets, face.starAdd
		for index, offset in offsets do
			local add = adds[index]
			local r = add % 256
			local g = math.floor(add / 256) % 256
			local b = math.floor(add / 65536)
			-- stars add on top of whatever is there (overlapping halos accumulate)
			buffer.writeu8(buf, offset, math.min(255, buffer.readu8(buf, offset) + math.floor(r * night)))
			buffer.writeu8(buf, offset + 1, math.min(255, buffer.readu8(buf, offset + 1) + math.floor(g * night)))
			buffer.writeu8(buf, offset + 2, math.min(255, buffer.readu8(buf, offset + 2) + math.floor(b * night)))
		end
	end
	face.image:WritePixelsBuffer(Vector2.zero, face.image.Size, buf)
end

local function prepare()
	local startedAt = os.clock()
	for _ = 1, #FACES do
		local ok, result = pcall(function(): EditableImage?
			return AssetService:CreateEditableImage({ Size = Vector2.new(FACE_SIZE, FACE_SIZE) })
		end)
		local image: EditableImage? = if ok then result else nil
		if not image then
			failed = true
			warn("[StarSky] EditableImage unavailable (" .. tostring(result) .. "); the sky stays Roblox's default.")
			return
		end
		local face: FaceData = {
			image = image,
			buf = buffer.create(FACE_SIZE * FACE_SIZE * 4),
			starOffsets = {},
			starAdd = {},
		}
		prepareStars(face)
		table.insert(faces, face)
		if os.clock() - startedAt > PREPARE_BUDGET_S then
			task.wait()
			startedAt = os.clock()
		end
	end
	-- first paint: whatever the last update asked for
	local ok, err = pcall(function()
		for _, face in faces do
			paintFace(face, targetDay, targetColor)
		end
	end)
	if not ok then
		failed = true
		warn("[StarSky] could not paint the sky (" .. tostring(err) .. "); the sky stays Roblox's default.")
		return
	end
	paintedDay, paintedColor = targetDay, targetColor
	ready = true
end

local function attach(sky: Sky): boolean
	local ok, err = pcall(function()
		sky.SkyboxBackContent = Content.fromObject(faces[1].image)
		sky.SkyboxDownContent = Content.fromObject(faces[2].image)
		sky.SkyboxFrontContent = Content.fromObject(faces[3].image)
		sky.SkyboxLeftContent = Content.fromObject(faces[4].image)
		sky.SkyboxRightContent = Content.fromObject(faces[5].image)
		sky.SkyboxUpContent = Content.fromObject(faces[6].image)
	end)
	if not ok then
		failed = true
		warn("[StarSky] the Sky does not accept painted faces (" .. tostring(err) .. "); the sky stays default.")
		return false
	end
	return true
end

local function colorDelta(a: Color3, b: Color3): number
	return math.max(math.abs(a.R - b.R), math.abs(a.G - b.G), math.abs(a.B - b.B))
end

function StarSky.init()
	if started then
		return
	end
	started = true
	task.spawn(prepare)
end

function StarSky.isReady(): boolean
	return ready and not failed
end

-- day: 0 (space / night) .. 1 (full daylight sky); dayColor: the daylight sky colour.
function StarSky.update(sky: Sky, day: number, dayColor: Color3)
	targetDay = math.clamp(day, 0, 1)
	targetColor = dayColor
	if failed or not ready then
		return
	end
	if appliedTo ~= sky then
		if not attach(sky) then
			return
		end
		appliedTo = sky
	end
	if pendingFace == 0 then
		local moved = math.abs(targetDay - paintedDay) > REPAINT_DAY_STEP
			or (targetDay > 0 and colorDelta(targetColor, paintedColor) > REPAINT_COLOR_STEP)
		if not moved then
			return
		end
		paintedDay, paintedColor = targetDay, targetColor
		pendingFace = 1
	end
	local ok, err = pcall(function()
		for _ = 1, FACES_PER_FRAME do
			paintFace(faces[pendingFace], paintedDay, paintedColor)
			pendingFace += 1
			if pendingFace > #faces then
				pendingFace = 0
				break
			end
		end
	end)
	if not ok then
		failed = true
		warn("[StarSky] repaint failed (" .. tostring(err) .. "); the sky keeps its last look.")
	end
end

return StarSky
