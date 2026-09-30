--!strict
-- Tests for Shared/Util/Json.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TestKit = require(script.Parent.TestKit)
local Json = require(ReplicatedStorage.Shared.Util.Json)

return function(t: TestKit.Context)
	t.test("round trips nested values", function()
		local value = {
			name = 'He said "hi"\n\ttab\\',
			list = { 1, 2.5, -3e-7, 123456789012 },
			flag = true,
			off = false,
			nested = { deeper = { 1 } },
		}
		local decoded = Json.decode(Json.encode(value))
		t.expectEqual(decoded.name, value.name)
		t.expectEqual(decoded.list[3], -3e-7)
		t.expectEqual(decoded.list[4], 123456789012)
		t.expectEqual(decoded.flag, true)
		t.expectEqual(decoded.off, false)
		t.expectEqual(decoded.nested.deeper[1], 1)
	end)

	t.test("doubles survive exactly", function()
		local x = 0.1 + 0.2
		t.expectEqual(Json.decode(Json.encode({ x }))[1], x)
	end)

	t.test("null and unicode escapes", function()
		local decoded = Json.decode('{"a":null,"b":"\\u0041\\u00e9"}')
		t.expectTrue(decoded.a == Json.null)
		t.expectEqual(decoded.b, "A" .. utf8.char(0xe9))
	end)

	t.test("malformed input errors", function()
		for _, text in { "", "{", "[1,]", '{"a" 1}', "tru", "1 2", '"unterminated' } do
			t.expectError(function()
				Json.decode(text)
			end, "should reject: " .. text)
		end
	end)

	t.test("refuses non-finite numbers", function()
		t.expectError(function()
			Json.encode({ 0 / 0 })
		end)
		t.expectError(function()
			Json.encode({ math.huge })
		end)
	end)
end
