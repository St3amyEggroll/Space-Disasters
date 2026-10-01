--[[
	Part preview exporter (Lune). Builds every part with the game's own PartVisuals (Cosmetic mode) and writes the
	primitives as JSON for the part preview page (docs/part-preview). Nothing here runs in the game.

	Usage: lune run tools/export-parts <sourcemap.json> <out.json>
	Build the sourcemap with: rojo sourcemap default.project.json -o <sourcemap.json>
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

--============================================================================
-- Tunables
--============================================================================
local DEFAULT_SOURCEMAP = ".tools/out/sourcemap.json"
local DEFAULT_OUT = ".tools/out/parts.json"
local DECIMALS = 1e4 -- rounding of exported numbers
--============================================================================

local Instance = roblox.Instance

type SourcemapNode = { name: string, className: string, filePaths: { string }?, children: { SourcemapNode }? }

local sourcemapPath = process.args[1] or DEFAULT_SOURCEMAP
local outPath = process.args[2] or DEFAULT_OUT
local sourcemap: SourcemapNode = serde.decode("json", fs.readFile(sourcemapPath))

local sourceFileOf: { [string]: string } = {}
local moduleCache: { [string]: any } = {}

local function scriptFile(node: SourcemapNode): string?
	for _, path in node.filePaths or {} do
		if string.sub(path, -5) == ".luau" or string.sub(path, -4) == ".lua" then
			return path
		end
	end
	return nil
end

local game = Instance.new("DataModel")

local function build(node: SourcemapNode, parent: any)
	local instance
	if parent == game then
		instance = game:GetService(node.className)
	else
		local ok, created = pcall(Instance.new, node.className)
		instance = if ok then created else Instance.new("Folder")
		instance.Name = node.name
		instance.Parent = parent
	end
	local file = scriptFile(node)
	if file then
		sourceFileOf[instance:GetFullName()] = file
	end
	for _, child in node.children or {} do
		build(child, instance)
	end
end

for _, child in sourcemap.children or {} do
	build(child, game)
end

local customRequire
local function loadModule(instance: any): any
	local key = instance:GetFullName()
	if moduleCache[key] ~= nil then
		return moduleCache[key]
	end
	local file = sourceFileOf[key]
	assert(file, "require: no source file for " .. key)
	local chunk = luau.load(fs.readFile(file), {
		debugName = file,
		environment = {
			script = instance,
			require = customRequire,
			game = game,
			workspace = game:GetService("Workspace"),
			Vector3 = roblox.Vector3,
			Vector2 = roblox.Vector2,
			CFrame = roblox.CFrame,
			Color3 = roblox.Color3,
			Enum = roblox.Enum,
			Instance = roblox.Instance,
		},
	})
	local result = chunk()
	moduleCache[key] = if result == nil then false else result
	return result
end
customRequire = function(target: any): any
	if type(target) == "string" then
		return require(target)
	end
	return loadModule(target)
end

local shared = game:GetService("ReplicatedStorage"):FindFirstChild("Shared")
local Parts = loadModule(shared:FindFirstChild("Config"):FindFirstChild("Parts"))
local PartVisuals = loadModule(shared:FindFirstChild("Craft"):FindFirstChild("PartVisuals"))
local GameConfig = loadModule(shared:FindFirstChild("Config"):FindFirstChild("GameConfig"))

local function r(x: number): number
	return math.round(x * DECIMALS) / DECIMALS
end

local function enumName(value: any): string
	local text = tostring(value)
	return string.match(text, "([^%.]+)$") or text
end

local parts = {}
for _, def in Parts.List do
	local model = PartVisuals.build(def, "Cosmetic")
	local prims = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "Bounds" then
			local cf = d.CFrame
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = cf:GetComponents()
			local kind = d.ClassName
			if d:IsA("Part") then
				kind = enumName(d.Shape) -- Block / Cylinder / Ball / Wedge / CornerWedge
			end
			table.insert(prims, {
				name = d.Name,
				kind = kind,
				size = { r(d.Size.X), r(d.Size.Y), r(d.Size.Z) },
				cf = { r(x), r(y), r(z), r(r00), r(r01), r(r02), r(r10), r(r11), r(r12), r(r20), r(r21), r(r22) },
				color = { math.round(d.Color.R * 255), math.round(d.Color.G * 255), math.round(d.Color.B * 255) },
				material = enumName(d.Material),
				transparency = r(d.Transparency),
				paint = d:GetAttribute("Paint") == true,
			})
		end
	end
	local size = def.Size * GameConfig.GRID_SIZE
	table.insert(parts, {
		id = def.Id,
		name = def.DisplayName,
		category = def.Category,
		size = { size.X, size.Y, size.Z },
		prims = prims,
	})
end

fs.writeFile(outPath, serde.encode("json", { grid = GameConfig.GRID_SIZE, parts = parts }, false))
local total = 0
for _, p in parts do
	total += #p.prims
end
print(string.format("exported %d parts (%d primitives) to %s", #parts, total, outPath))
