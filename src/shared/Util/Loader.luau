--!strict
--[[
	Loader
	Drives the service/controller lifecycle for one side (server or client):

	  1. require every listed ModuleScript in the given order
	  2. call Init() on each, in order (must not yield: set up state, create instances, connect remotes)
	  3. call Start() on each, in order, each in its own thread (may yield: loops, waiting on other systems)

	Modules may require each other directly; Init order only matters for work done inside Init.
	A module that fails to load or Init is reported loudly and skipped, so one broken system does not take
	the whole game down during development.
]]

--============================================================================
-- Tunables
--============================================================================
local SLOW_INIT_WARN_MS = 250 -- warn when a single Init takes longer than this
--============================================================================

export type Module = {
	Init: (() -> ())?,
	Start: (() -> ())?,
}

export type BootReport = {
	loaded: { string },
	failed: { string },
	totalMs: number,
}

local Loader = {}

local function report(label: string, message: string)
	warn(`[{label}] {message}`)
end

--[[
	folder:  the Services or Controllers folder
	order:   every ModuleScript name in the folder, in boot order
	label:   prefix for log lines ("Server" / "Client")
]]
function Loader.run(label: string, folder: Instance, order: { string }): BootReport
	local startClock = os.clock()
	local result: BootReport = { loaded = {}, failed = {}, totalMs = 0 }

	-- Every module in the folder must be listed exactly once, or it would silently never run.
	local listed: { [string]: boolean } = {}
	for _, name in order do
		if listed[name] then
			report(label, `boot order lists {name} twice`)
		end
		listed[name] = true
	end
	for _, child in folder:GetChildren() do
		if child:IsA("ModuleScript") and not listed[child.Name] then
			report(label, `{child.Name} is in {folder.Name} but not in the boot order; it will not run`)
		end
	end

	-- 1. require
	local modules: { { name: string, module: Module } } = {}
	for _, name in order do
		local instance = folder:FindFirstChild(name)
		if instance == nil or not instance:IsA("ModuleScript") then
			report(label, `boot order lists {name}, but {folder:GetFullName()} has no such ModuleScript`)
			table.insert(result.failed, name)
			continue
		end
		local ok, loaded = pcall(require, instance)
		if not ok then
			report(label, `failed to require {name}: {loaded}`)
			table.insert(result.failed, name)
			continue
		end
		if type(loaded) ~= "table" then
			report(label, `{name} must return a table with Init/Start`)
			table.insert(result.failed, name)
			continue
		end
		table.insert(modules, { name = name, module = loaded :: Module })
	end

	-- 2. Init (synchronous, in order)
	local initialized: { { name: string, module: Module } } = {}
	for _, entry in modules do
		local init = entry.module.Init
		if init then
			local t0 = os.clock()
			local ok, err = xpcall(function()
				init()
			end, debug.traceback)
			local ms = (os.clock() - t0) * 1000
			if not ok then
				report(label, `{entry.name}.Init failed: {err}`)
				table.insert(result.failed, entry.name)
				continue
			end
			if ms > SLOW_INIT_WARN_MS then
				report(label, string.format("%s.Init took %.0f ms", entry.name, ms))
			end
		end
		table.insert(initialized, entry)
	end

	-- 3. Start (each in its own thread, in order)
	for _, entry in initialized do
		local start = entry.module.Start
		if start then
			task.spawn(function()
				local ok, err = xpcall(function()
					start()
				end, debug.traceback)
				if not ok then
					report(label, `{entry.name}.Start failed: {err}`)
				end
			end)
		end
		table.insert(result.loaded, entry.name)
	end

	result.totalMs = (os.clock() - startClock) * 1000
	print(string.format("[%s] booted %d module(s) in %.1f ms", label, #result.loaded, result.totalMs))
	if #result.failed > 0 then
		report(label, `{#result.failed} module(s) failed to boot: {table.concat(result.failed, ", ")}`)
	end
	return result
end

return table.freeze(Loader)
