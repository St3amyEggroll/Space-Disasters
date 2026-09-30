--!strict
--[[
	CraftBuilder
	Design -> Roblox models.

	Modes:
	  "Real"      server-side craft/hangar parts: collidable where PartVisuals says so, seats and prompts present.
	  "Cosmetic"  client-side copies: no collision/queries/touch, massless, no prompts or seats.
	  "Ghost"     the builder's placement preview: cosmetic, translucent, tinted by a Highlight.

	Every block becomes a Model named "Block_<id>" with attributes BlockId, PartId, GX, GY, GZ, Rot (and Stage when
	it has a stage override), pivoted to origin * CraftDesign.blockCFrame(block). All parts are Anchored
	(DECISIONS S9). readDesign() rebuilds a Design from those attributes (the client mirrors hangar builds this way).
]]

local CraftDesign = require(script.Parent.CraftDesign)
local Parts = require(script.Parent.Parent.Config.Parts)
local PartVisuals = require(script.Parent.PartVisuals)

type Block = CraftDesign.Block
type Design = CraftDesign.Design

--============================================================================
-- Tunables
--============================================================================
local GHOST_TRANSPARENCY = 0.55
local GHOST_VALID_COLOR = Color3.fromRGB(80, 220, 120)
local GHOST_INVALID_COLOR = Color3.fromRGB(235, 60, 60)
local BLOCK_PREFIX = "Block_"
--============================================================================

export type Mode = "Real" | "Cosmetic" | "Ghost"

local CraftBuilder = {}

CraftBuilder.BLOCK_PREFIX = BLOCK_PREFIX

local function tagBlock(model: Model, block: Block)
	model.Name = BLOCK_PREFIX .. block.id
	model:SetAttribute("BlockId", block.id)
	model:SetAttribute("PartId", block.type)
	model:SetAttribute("GX", block.gx)
	model:SetAttribute("GY", block.gy)
	model:SetAttribute("GZ", block.gz)
	model:SetAttribute("Rot", block.rot)
	model:SetAttribute("Stage", block.stageOverride)
end

-- Moves a freshly built (origin-centred) model to `cf` by transforming its parts directly. Equivalent to
-- Model:PivotTo for a model whose PrimaryPart sits at the identity, and also works in the offline test runner.
local function placeFresh(model: Model, cf: CFrame)
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CFrame = cf * descendant.CFrame
		end
	end
end

-- Builds one block model at origin * blockCFrame. Not parented.
function CraftBuilder.buildBlock(block: Block, mode: Mode, origin: CFrame): Model
	local def = Parts.get(block.type)
	local model = PartVisuals.build(def, if mode == "Real" then "Real" else "Cosmetic")
	tagBlock(model, block)
	placeFresh(model, origin * CraftDesign.blockCFrame(block))
	if mode == "Ghost" then
		for _, descendant in model:GetDescendants() do
			if descendant:IsA("BasePart") and descendant.Name ~= "Bounds" then
				descendant.Transparency = math.max(descendant.Transparency, GHOST_TRANSPARENCY)
				descendant.CastShadow = false
			end
		end
		local highlight = Instance.new("Highlight")
		highlight.Name = "GhostHighlight"
		highlight.FillTransparency = 0.5
		highlight.OutlineTransparency = 0.2
		highlight.FillColor = GHOST_VALID_COLOR
		highlight.OutlineColor = GHOST_VALID_COLOR
		highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		highlight.Parent = model
	end
	return model
end

-- Tints a ghost model green (valid) or red (invalid).
function CraftBuilder.setGhostValid(model: Model, valid: boolean)
	local highlight = model:FindFirstChild("GhostHighlight")
	if highlight and highlight:IsA("Highlight") then
		local color = if valid then GHOST_VALID_COLOR else GHOST_INVALID_COLOR
		highlight.FillColor = color
		highlight.OutlineColor = color
	end
end

-- Builds a whole design into a Model named `name`, block models as children, PrimaryPart = the root block's
-- Bounds when the design has a command part. Not parented.
function CraftBuilder.build(design: Design, mode: Mode, origin: CFrame, name: string?): Model
	local craft = Instance.new("Model")
	craft.Name = name or design.name
	local root = CraftDesign.rootBlock(design)
	for _, block in design.blocks do
		local model = CraftBuilder.buildBlock(block, mode, origin)
		model.Parent = craft
		if root and block.id == root.id then
			craft.PrimaryPart = model.PrimaryPart
		end
	end
	craft:SetAttribute("RootBlockId", if root then root.id else nil)
	return craft
end

-- Rebuilds a Design from block models (children of `container` named Block_<id> with the block attributes).
function CraftBuilder.readDesign(container: Instance, name: string?): Design
	local design = CraftDesign.new(name)
	for _, child in container:GetChildren() do
		if child:IsA("Model") and string.sub(child.Name, 1, #BLOCK_PREFIX) == BLOCK_PREFIX then
			local id = child:GetAttribute("BlockId")
			local partId = child:GetAttribute("PartId")
			local gx, gy, gz = child:GetAttribute("GX"), child:GetAttribute("GY"), child:GetAttribute("GZ")
			local rot = child:GetAttribute("Rot")
			local stage = child:GetAttribute("Stage")
			if
				type(id) == "number"
				and type(partId) == "string"
				and Parts.find(partId) ~= nil
				and type(gx) == "number"
				and type(gy) == "number"
				and type(gz) == "number"
				and type(rot) == "number"
			then
				table.insert(design.blocks, {
					id = id,
					type = partId,
					gx = gx,
					gy = gy,
					gz = gz,
					rot = rot,
					stageOverride = if type(stage) == "number" then stage else nil,
				})
			end
		end
	end
	table.sort(design.blocks, function(a, b)
		return a.id < b.id
	end)
	return design
end

-- The block model for a block id inside a craft/hangar container, or nil.
function CraftBuilder.findBlockModel(container: Instance, blockId: number): Model?
	local child = container:FindFirstChild(BLOCK_PREFIX .. blockId)
	if child and child:IsA("Model") then
		return child
	end
	return nil
end

return table.freeze(CraftBuilder)
