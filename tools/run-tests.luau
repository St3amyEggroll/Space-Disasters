--[[
	Offline test runner (Lune). Runs the same *.spec modules as RunTests.server.luau, outside Roblox.

	Usage: lune run tools/run-tests <sourcemap.json>
	Build the sourcemap with: rojo sourcemap default.project.json -o <sourcemap.json>

	It rebuilds the instance tree from the Rojo sourcemap with Lune's Roblox DOM, so `script.Parent.X` and
	`game:GetService("ReplicatedStorage").Shared...` resolve exactly as in Studio. Only pure modules (no engine
	services beyond instance lookup) can be tested this way; the Studio runner covers the rest.
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
local TESTS_PATH = { "ServerScriptService", "Server", "Tests" }
local SPEC_SUFFIX = ".spec"
--============================================================================

local Instance = roblox.Instance

type SourcemapNode = {
	name: string,
	className: string,
	filePaths: { string }?,
	children: { SourcemapNode }?,
}

local sourcemapPath = process.args[1] or DEFAULT_SOURCEMAP
local sourcemap: SourcemapNode = serde.decode("json", fs.readFile(sourcemapPath))

-- Keyed by GetFullName(): Lune may hand out different userdata wrappers for the same instance.
local sourceFileOf: { [string]: string } = {}
local moduleCache: { [string]: any } = {}
local loading: { [string]: boolean } = {}

local function scriptFile(node: SourcemapNode): string?
	if node.filePaths == nil then
		return nil
	end
	for _, path in node.filePaths do
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
	if file == nil then
		error("require: no source file for " .. instance:GetFullName(), 2)
	end
	if loading[key] then
		error("require: cyclic dependency at " .. instance:GetFullName(), 2)
	end
	loading[key] = true
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
			UDim = roblox.UDim, -- CHANGED (Physics feel): HomeBase.spec builds the site (SurfaceGui labels)
			UDim2 = roblox.UDim2,
		},
	})
	local result = chunk()
	loading[key] = nil
	moduleCache[key] = if result == nil then false else result
	return result
end

customRequire = function(target: any): any
	if type(target) == "string" then
		return require(target)
	end
	return loadModule(target)
end

local testsFolder: any = game
for _, name in TESTS_PATH do
	testsFolder = if testsFolder == game then game:GetService(name) else testsFolder:FindFirstChild(name)
	assert(testsFolder, "Tests folder not found in sourcemap: " .. name)
end

local TestKit = loadModule(testsFolder:FindFirstChild("TestKit"))

local specs = {}
for _, child in testsFolder:GetChildren() do
	if string.sub(child.Name, -#SPEC_SUFFIX) == SPEC_SUFFIX then
		local ok, runner = pcall(loadModule, child)
		if ok and type(runner) == "function" then
			table.insert(specs, { name = child.Name, run = runner })
		else
			print("could not load " .. child.Name .. ": " .. tostring(runner))
			process.exit(1)
		end
	end
end
table.sort(specs, function(a, b)
	return a.name < b.name
end)

local result = TestKit.run(specs, print)
if result.failed > 0 then
	process.exit(1)
end
