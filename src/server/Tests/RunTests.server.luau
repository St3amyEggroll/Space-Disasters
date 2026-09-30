--!strict
--[[
	RunTests
	Runs every *.spec module in this folder when GameConfig.RUN_TESTS is true and we are in Studio.
	Output goes to the Output window with a [Tests] prefix.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.Config.GameConfig)
local TestKit = require(script.Parent.TestKit)

--============================================================================
-- Tunables
--============================================================================
local SPEC_SUFFIX = ".spec"
local START_DELAY_S = 1 -- let the bootstraps finish first so test output is not interleaved
--============================================================================

if not (GameConfig.RUN_TESTS and RunService:IsStudio()) then
	return
end

task.delay(START_DELAY_S, function()
	local specs: { TestKit.Spec } = {}
	for _, child in script.Parent:GetChildren() do
		if child:IsA("ModuleScript") and string.sub(child.Name, -#SPEC_SUFFIX) == SPEC_SUFFIX then
			local ok, runner = pcall(require, child)
			if ok and type(runner) == "function" then
				table.insert(specs, { name = child.Name, run = runner :: any })
			else
				warn(`[Tests] could not load {child.Name}: {runner}`)
			end
		end
	end
	table.sort(specs, function(a, b)
		return a.name < b.name
	end)

	local result = TestKit.run(specs, function(line: string)
		print("[Tests] " .. line)
	end)
	if result.failed > 0 then
		warn(`[Tests] {result.failed} FAILED`)
		for _, failure in result.failures do
			warn("[Tests]   " .. failure)
		end
	end
end)
