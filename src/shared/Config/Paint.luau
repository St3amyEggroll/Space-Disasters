--!strict
--[[
	Paint
	The paint palette for the builder's paint tool (Plane Crazy-style). A block's `color` is an index into
	Paint.List (1-based); nil means "the part's own default colours". Indices are stored in saves and on the wire,
	so only ever append colours.
]]

export type PaintColor = { Name: string, Color: Color3 }

local list: { PaintColor } = {
	{ Name = "White", Color = Color3.fromRGB(242, 243, 243) },
	{ Name = "Light Grey", Color = Color3.fromRGB(175, 180, 190) },
	{ Name = "Dark Grey", Color = Color3.fromRGB(88, 92, 102) },
	{ Name = "Black", Color = Color3.fromRGB(27, 29, 34) },
	{ Name = "Red", Color = Color3.fromRGB(214, 48, 49) },
	{ Name = "Orange", Color = Color3.fromRGB(255, 140, 40) },
	{ Name = "Yellow", Color = Color3.fromRGB(255, 209, 64) },
	{ Name = "Lime", Color = Color3.fromRGB(140, 214, 60) },
	{ Name = "Green", Color = Color3.fromRGB(46, 160, 90) },
	{ Name = "Teal", Color = Color3.fromRGB(38, 180, 170) },
	{ Name = "Sky", Color = Color3.fromRGB(92, 180, 255) },
	{ Name = "Blue", Color = Color3.fromRGB(45, 95, 220) },
	{ Name = "Purple", Color = Color3.fromRGB(130, 80, 220) },
	{ Name = "Pink", Color = Color3.fromRGB(255, 120, 190) },
	{ Name = "Brown", Color = Color3.fromRGB(125, 85, 55) },
	{ Name = "Tan", Color = Color3.fromRGB(215, 190, 140) },
}
for index, entry in list do
	list[index] = table.freeze(entry)
end

local Paint = {}

Paint.List = table.freeze(list)

-- The Color3 for a paint index, or nil for "default" / out of range.
function Paint.color(index: number?): Color3?
	if index == nil then
		return nil
	end
	local entry = list[index]
	return if entry then entry.Color else nil
end

function Paint.isValid(index: number): boolean
	return index >= 1 and index <= #list and index % 1 == 0
end

return table.freeze(Paint)
