--!strict
--[[
	Json
	Small, strict JSON encoder/decoder in pure Luau. It exists so craft designs can be saved as versioned JSON and
	round-tripped in the offline test runner, where HttpService is unavailable.

	Supports objects (string keys), arrays (1..n with no holes), strings, finite numbers, booleans and Json.null.
	Numbers are written with %.17g so doubles round-trip exactly.
]]

--============================================================================
-- Tunables
--============================================================================
local MAX_DEPTH = 32
--============================================================================

local Json = {}

-- Sentinel for JSON null (Lua nil cannot be stored in tables).
Json.null = table.freeze({})

local ESCAPES: { [string]: string } = {
	['"'] = '\\"',
	["\\"] = "\\\\",
	["\b"] = "\\b",
	["\f"] = "\\f",
	["\n"] = "\\n",
	["\r"] = "\\r",
	["\t"] = "\\t",
}

local function encodeString(s: string): string
	return '"'
		.. string.gsub(s, '[%c"\\]', function(c: string): string
			return ESCAPES[c] or string.format("\\u%04x", string.byte(c))
		end)
		.. '"'
end

local function isArray(t: { [any]: any }): boolean
	local count = 0
	for key in t do
		if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
			return false
		end
		count += 1
	end
	return count == #t
end

local function encodeValue(value: any, depth: number, out: { string })
	if depth > MAX_DEPTH then
		error("Json.encode: nesting too deep")
	end
	local kind = type(value)
	if value == Json.null then
		table.insert(out, "null")
	elseif kind == "string" then
		table.insert(out, encodeString(value))
	elseif kind == "number" then
		if value ~= value or value == math.huge or value == -math.huge then
			error("Json.encode: non-finite number")
		end
		if value % 1 == 0 and math.abs(value) < 2 ^ 53 then
			table.insert(out, string.format("%d", value))
		else
			table.insert(out, string.format("%.17g", value))
		end
	elseif kind == "boolean" then
		table.insert(out, if value then "true" else "false")
	elseif kind == "table" then
		if next(value) == nil then
			table.insert(out, "[]")
		elseif isArray(value) then
			table.insert(out, "[")
			for index, item in ipairs(value) do
				if index > 1 then
					table.insert(out, ",")
				end
				encodeValue(item, depth + 1, out)
			end
			table.insert(out, "]")
		else
			local keys = {}
			for key in value do
				if type(key) ~= "string" then
					error("Json.encode: object keys must be strings")
				end
				table.insert(keys, key)
			end
			table.sort(keys)
			table.insert(out, "{")
			for index, key in keys do
				if index > 1 then
					table.insert(out, ",")
				end
				table.insert(out, encodeString(key))
				table.insert(out, ":")
				encodeValue(value[key], depth + 1, out)
			end
			table.insert(out, "}")
		end
	else
		error("Json.encode: cannot encode " .. kind)
	end
end

function Json.encode(value: any): string
	local out: { string } = {}
	encodeValue(value, 0, out)
	return table.concat(out)
end

--============================================================================
-- Decoder
--============================================================================

type Reader = { text: string, pos: number }

local function fail(reader: Reader, message: string): never
	error(`Json.decode: {message} at position {reader.pos}`, 0)
end

local function skipWhitespace(reader: Reader)
	local _, finish = string.find(reader.text, "^[ \t\r\n]*", reader.pos)
	reader.pos = (finish or reader.pos - 1) + 1
end

local decodeValue: (Reader, number) -> any

local function decodeString(reader: Reader): string
	local text = reader.text
	local pos = reader.pos + 1 -- skip opening quote
	local parts: { string } = {}
	while true do
		local c = string.sub(text, pos, pos)
		if c == "" then
			reader.pos = pos
			fail(reader, "unterminated string")
		elseif c == '"' then
			reader.pos = pos + 1
			return table.concat(parts)
		elseif c == "\\" then
			local e = string.sub(text, pos + 1, pos + 1)
			if e == "u" then
				local hex = string.sub(text, pos + 2, pos + 5)
				local code = tonumber(hex, 16)
				if code == nil or #hex ~= 4 then
					reader.pos = pos
					fail(reader, "bad \\u escape")
				end
				table.insert(parts, utf8.char(code :: number))
				pos += 6
			else
				local map: { [string]: string } =
					{ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
				local decoded = map[e]
				if decoded == nil then
					reader.pos = pos
					fail(reader, "bad escape")
				end
				table.insert(parts, decoded :: string)
				pos += 2
			end
		else
			local runEnd = string.find(text, '["\\]', pos) or (#text + 1)
			table.insert(parts, string.sub(text, pos, runEnd - 1))
			pos = runEnd
		end
	end
end

local function decodeNumber(reader: Reader): number
	local s, e = string.find(reader.text, "^-?%d+%.?%d*[eE]?[-+]?%d*", reader.pos)
	if s == nil then
		fail(reader, "bad number")
	end
	local n = tonumber(string.sub(reader.text, s :: number, e :: number))
	if n == nil then
		fail(reader, "bad number")
	end
	reader.pos = (e :: number) + 1
	return n :: number
end

decodeValue = function(reader: Reader, depth: number): any
	if depth > MAX_DEPTH then
		fail(reader, "nesting too deep")
	end
	skipWhitespace(reader)
	local c = string.sub(reader.text, reader.pos, reader.pos)
	if c == "{" then
		reader.pos += 1
		local object: { [string]: any } = {}
		skipWhitespace(reader)
		if string.sub(reader.text, reader.pos, reader.pos) == "}" then
			reader.pos += 1
			return object
		end
		while true do
			skipWhitespace(reader)
			if string.sub(reader.text, reader.pos, reader.pos) ~= '"' then
				fail(reader, "expected key")
			end
			local key = decodeString(reader)
			skipWhitespace(reader)
			if string.sub(reader.text, reader.pos, reader.pos) ~= ":" then
				fail(reader, "expected ':'")
			end
			reader.pos += 1
			object[key] = decodeValue(reader, depth + 1)
			skipWhitespace(reader)
			local sep = string.sub(reader.text, reader.pos, reader.pos)
			reader.pos += 1
			if sep == "}" then
				return object
			elseif sep ~= "," then
				reader.pos -= 1
				fail(reader, "expected ',' or '}'")
			end
		end
	elseif c == "[" then
		reader.pos += 1
		local array: { any } = {}
		skipWhitespace(reader)
		if string.sub(reader.text, reader.pos, reader.pos) == "]" then
			reader.pos += 1
			return array
		end
		while true do
			table.insert(array, decodeValue(reader, depth + 1))
			skipWhitespace(reader)
			local sep = string.sub(reader.text, reader.pos, reader.pos)
			reader.pos += 1
			if sep == "]" then
				return array
			elseif sep ~= "," then
				reader.pos -= 1
				fail(reader, "expected ',' or ']'")
			end
		end
	elseif c == '"' then
		return decodeString(reader)
	elseif c == "-" or string.match(c, "%d") then
		return decodeNumber(reader)
	elseif string.sub(reader.text, reader.pos, reader.pos + 3) == "true" then
		reader.pos += 4
		return true
	elseif string.sub(reader.text, reader.pos, reader.pos + 4) == "false" then
		reader.pos += 5
		return false
	elseif string.sub(reader.text, reader.pos, reader.pos + 3) == "null" then
		reader.pos += 4
		return Json.null
	end
	return fail(reader, "unexpected character '" .. c .. "'")
end

-- Decodes a JSON string. Errors (with position) on malformed input; use pcall for untrusted data.
function Json.decode(text: string): any
	local reader: Reader = { text = text, pos = 1 }
	local value = decodeValue(reader, 0)
	skipWhitespace(reader)
	if reader.pos <= #text then
		fail(reader, "trailing characters")
	end
	return value
end

return table.freeze(Json)
