--!strict
--[[
	MenuSceneFlare (Phase 11)
	The main menu's lens flare: a soft glare around the sun's screen position, a thin horizontal streak through it
	and a few soft coloured circles (and one ring) placed along the line from the sun through the screen centre, as
	a camera lens would. Plain GUI frames (no image assets), built inside a full-screen layer of the menu's
	ScreenGui (IgnoreGuiInset, so screen pixels = viewport pixels). Render/MenuScene drives it every frame with the
	sun's viewport position and a strength (0 hides it: sun off-screen, behind the camera, Earth, the Mun or the
	avatar).

	API:
	  MenuSceneFlare.new(parent: GuiObject) -> Flare
	  flare.update(sunX, sunY, strength, width, height)   viewport px; strength 0..1
	  flare.hide()
	  flare.destroy()
]]

local MenuSceneMath = require(script.Parent.MenuSceneMath)

--============================================================================
-- Tunables
--============================================================================
type Element = {
	t: number, -- position along sun -> screen centre (0 = the sun, 1 = the centre, 2 = mirrored)
	size: number, -- diameter as a fraction of the screen height
	color: Color3,
	alpha: number, -- opacity at full strength
	ring: boolean, -- a thin ring instead of a soft disc
}
local ELEMENTS: { Element } = {
	{ t = 0, size = 0.5, color = Color3.fromRGB(255, 236, 200), alpha = 0.16, ring = false }, -- the glare
	{ t = 0, size = 0.12, color = Color3.fromRGB(255, 250, 235), alpha = 0.3, ring = false },
	{ t = 0.38, size = 0.045, color = Color3.fromRGB(255, 214, 120), alpha = 0.22, ring = false },
	{ t = 0.62, size = 0.09, color = Color3.fromRGB(150, 230, 140), alpha = 0.1, ring = false },
	{ t = 0.95, size = 0.03, color = Color3.fromRGB(255, 160, 90), alpha = 0.24, ring = false },
	{ t = 1.24, size = 0.17, color = Color3.fromRGB(120, 170, 255), alpha = 0.12, ring = true },
	{ t = 1.5, size = 0.06, color = Color3.fromRGB(190, 130, 255), alpha = 0.14, ring = false },
	{ t = 1.86, size = 0.12, color = Color3.fromRGB(110, 220, 220), alpha = 0.08, ring = false },
}
-- A soft disc is three nested circles: (diameter fraction, share of the element's opacity), outermost first.
local SOFT_LAYERS: { { size: number, share: number } } = {
	{ size = 1, share = 0.35 },
	{ size = 0.66, share = 0.6 },
	{ size = 0.36, share = 1 },
}
local RING_THICKNESS = 2 -- px
local STREAK_WIDTH = 0.9 -- fraction of the screen width
local STREAK_HEIGHT = 3 -- px
local STREAK_COLOR = Color3.fromRGB(200, 220, 255)
local STREAK_ALPHA = 0.3
local MIN_STRENGTH = 0.01 -- below this the flare is hidden
--============================================================================

export type Flare = {
	update: (sunX: number, sunY: number, strength: number, width: number, height: number) -> (),
	hide: () -> (),
	destroy: () -> (),
}

type Built = {
	element: Element,
	root: Frame,
	discs: { Frame }, -- soft disc layers (empty for a ring)
	stroke: UIStroke?, -- the ring's stroke
}

local MenuSceneFlare = {}

local function circle(parent: Instance, name: string, size: UDim2, color: Color3): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = size
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame
	frame.Parent = parent
	return frame
end

local function buildElement(layer: Frame, element: Element, index: number): Built
	local root = Instance.new("Frame")
	root.Name = `Flare{index}`
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.BackgroundTransparency = 1
	root.BorderSizePixel = 0
	root.Parent = layer
	local built: Built = { element = element, root = root, discs = {}, stroke = nil }
	if element.ring then
		local ring = circle(root, "Ring", UDim2.fromScale(1, 1), element.color)
		local stroke = Instance.new("UIStroke")
		stroke.Color = element.color
		stroke.Thickness = RING_THICKNESS
		stroke.Transparency = 1
		stroke.Parent = ring
		built.stroke = stroke
	else
		for _, soft in SOFT_LAYERS do
			table.insert(built.discs, circle(root, "Disc", UDim2.fromScale(soft.size, soft.size), element.color))
		end
	end
	return built
end

function MenuSceneFlare.new(parent: GuiObject): Flare
	local layer = Instance.new("Frame")
	layer.Name = "LensFlare"
	layer.BackgroundTransparency = 1
	layer.BorderSizePixel = 0
	layer.Size = UDim2.fromScale(1, 1)
	layer.Visible = false
	layer.Parent = parent

	local built: { Built } = {}
	for index, element in ELEMENTS do
		table.insert(built, buildElement(layer, element, index))
	end

	local streak = Instance.new("Frame")
	streak.Name = "Streak"
	streak.AnchorPoint = Vector2.new(0.5, 0.5)
	streak.BackgroundColor3 = STREAK_COLOR
	streak.BackgroundTransparency = 1
	streak.BorderSizePixel = 0
	local fade = Instance.new("UIGradient")
	fade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 0),
		NumberSequenceKeypoint.new(1, 1),
	})
	fade.Parent = streak
	streak.Parent = layer

	local function hide()
		layer.Visible = false
	end

	local function update(sunX: number, sunY: number, strength: number, width: number, height: number)
		if strength < MIN_STRENGTH or width <= 0 or height <= 0 then
			hide()
			return
		end
		layer.Visible = true
		local centreX, centreY = width / 2, height / 2
		for _, item in built do
			local element = item.element
			local x, y = MenuSceneMath.flarePoint(sunX, sunY, centreX, centreY, element.t)
			local diameter = element.size * height
			item.root.Position = UDim2.fromOffset(x, y)
			item.root.Size = UDim2.fromOffset(diameter, diameter)
			local opacity = element.alpha * strength
			local stroke = item.stroke
			if stroke then
				stroke.Transparency = 1 - opacity
			end
			for index, disc in item.discs do
				disc.BackgroundTransparency = 1 - opacity * SOFT_LAYERS[index].share
			end
		end
		streak.Position = UDim2.fromOffset(sunX, sunY)
		streak.Size = UDim2.fromOffset(STREAK_WIDTH * width, STREAK_HEIGHT)
		streak.BackgroundTransparency = 1 - STREAK_ALPHA * strength
	end

	return {
		update = update,
		hide = hide,
		destroy = function()
			layer:Destroy()
		end,
	}
end

return table.freeze(MenuSceneFlare)
