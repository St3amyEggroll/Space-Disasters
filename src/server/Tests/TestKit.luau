--!strict
--[[
	TestKit
	Minimal test framework (no external packages). Used by RunTests.server.luau in Studio and by the offline
	Lune runner (tools/run-tests.luau), so it must stay pure Luau with no Roblox services.

	A spec module returns a function that receives a Context:

		return function(t: TestKit.Context)
			t.test("adds", function()
				t.expectNear(1 + 1, 2, 1e-9)
			end)
		end
]]

--============================================================================
-- Tunables
--============================================================================
local FAIL_PREFIX = "  FAIL "
local PASS_PREFIX = "  ok   "
--============================================================================

export type Context = {
	test: (name: string, fn: () -> ()) -> (),
	expectTrue: (condition: boolean, message: string?) -> (),
	expectEqual: (actual: any, expected: any, message: string?) -> (),
	expectNear: (actual: number, expected: number, tolerance: number, message: string?) -> (),
	expectRelNear: (actual: number, expected: number, relTolerance: number, message: string?) -> (),
	expectError: (fn: () -> (), message: string?) -> (),
}

export type Spec = {
	name: string,
	run: (Context) -> (),
}

export type Result = {
	passed: number,
	failed: number,
	failures: { string },
}

local TestKit = {}

local function fail(message: string, detail: string?)
	if detail then
		error(message .. ": " .. detail, 3)
	end
	error(message, 3)
end

local function describe(value: any): string
	if type(value) == "number" then
		return string.format("%.17g", value)
	end
	return tostring(value)
end

-- Runs every spec and reports through `log`. Never throws.
-- CHANGED (Studio test timeout): `yield` (optional) runs between tests, so a long run never trips Roblox's script
-- timeout (RunTests passes task.wait; the Lune runner passes nothing)
function TestKit.run(specs: { Spec }, log: (string) -> (), yield: (() -> ())?): Result
	local result: Result = { passed = 0, failed = 0, failures = {} }

	for _, spec in specs do
		log(spec.name)
		local tests: { { name: string, fn: () -> () } } = {}

		local context: Context = {
			test = function(name: string, fn: () -> ())
				table.insert(tests, { name = name, fn = fn })
			end,
			expectTrue = function(condition: boolean, message: string?)
				if not condition then
					fail(message or "expected true")
				end
			end,
			expectEqual = function(actual: any, expected: any, message: string?)
				if actual ~= expected then
					fail(message or "values differ", "expected " .. describe(expected) .. ", got " .. describe(actual))
				end
			end,
			expectNear = function(actual: number, expected: number, tolerance: number, message: string?)
				local diff = math.abs(actual - expected)
				if not (diff <= tolerance) then
					fail(
						message or "values not near",
						"expected "
							.. describe(expected)
							.. ", got "
							.. describe(actual)
							.. " (diff "
							.. describe(diff)
							.. " > "
							.. describe(tolerance)
							.. ")"
					)
				end
			end,
			expectRelNear = function(actual: number, expected: number, relTolerance: number, message: string?)
				local scale = math.max(math.abs(expected), 1e-300)
				local rel = math.abs(actual - expected) / scale
				if not (rel <= relTolerance) then
					fail(
						message or "values not relatively near",
						"expected "
							.. describe(expected)
							.. ", got "
							.. describe(actual)
							.. " (rel "
							.. describe(rel)
							.. " > "
							.. describe(relTolerance)
							.. ")"
					)
				end
			end,
			expectError = function(fn: () -> (), message: string?)
				local ok = pcall(fn)
				if ok then
					fail(message or "expected an error")
				end
			end,
		}

		local collectOk, collectErr = pcall(function()
			spec.run(context)
		end)
		if not collectOk then
			result.failed += 1
			local line = spec.name .. " (setup): " .. tostring(collectErr)
			table.insert(result.failures, line)
			log(FAIL_PREFIX .. line)
		end

		for _, test in tests do
			local ok, err = pcall(function()
				test.fn()
			end)
			if ok then
				result.passed += 1
				log(PASS_PREFIX .. test.name)
			else
				result.failed += 1
				local line = spec.name .. " > " .. test.name .. ": " .. tostring(err)
				table.insert(result.failures, line)
				log(FAIL_PREFIX .. test.name .. ": " .. tostring(err))
			end
			if yield then
				yield()
			end
		end
	end

	log(string.format("%d passed, %d failed", result.passed, result.failed))
	return result
end

return table.freeze(TestKit)
