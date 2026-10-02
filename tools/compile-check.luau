--[[
	Compile check (Lune). Compiles every .luau file under the given folders the way Roblox can refuse them: without
	optimisation, so locals that the optimiser would fold away still count. Catches "Out of local registers"
	(more than 200 locals in one function or module chunk) and other compile-time limits that luau-lsp does not
	report. Usage: lune run tools/compile-check src spikes tools
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")

--============================================================================
-- Tunables
--============================================================================
local OPTIMIZATION_LEVEL = 0 -- the strictest: constant locals still take registers
--============================================================================

local failed = 0
local checked = 0

local function walk(dir: string)
	for _, name in fs.readDir(dir) do
		local path = dir .. "/" .. name
		if fs.isDir(path) then
			walk(path)
		elseif string.sub(name, -5) == ".luau" then
			checked += 1
			local ok, err = pcall(luau.compile, fs.readFile(path), { optimizationLevel = OPTIMIZATION_LEVEL })
			if not ok then
				failed += 1
				print("COMPILE FAIL " .. path .. ": " .. tostring(err))
			end
		end
	end
end

for _, root in process.args do
	walk(root)
end
print(string.format("compile check: %d files, %d failed", checked, failed))
if failed > 0 then
	process.exit(1)
end
