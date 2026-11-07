-- Path of Building
--
-- Module: stable fingerprints for exact optimizer study context.
-- These fingerprints bind reporting evidence to its source build and scenario;
-- they do not certify training labels or replace exact PoB calculation.

local json = require("dkjson")
local sha = require("sha2")

local context = { }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function canonical(value, stack, depth)
	local kind = type(value)
	if kind == "nil" then return "null" end
	if kind == "string" or kind == "boolean" then
		local encoded, encodeError = json.encode(value)
		if type(encoded) ~= "string" then return nil, encodeError or "Could not encode study context value" end
		return encoded
	end
	if kind == "number" then
		if not isFinite(value) then return nil, "Study context contains a non-finite number" end
		local encoded, encodeError = json.encode(value)
		if type(encoded) ~= "string" then return nil, encodeError or "Could not encode study context number" end
		return encoded
	end
	if kind ~= "table" then return nil, "Study context contains an unsupported value" end
	if depth > 12 then return nil, "Study context nesting exceeds its safety limit" end
	if stack[value] then return nil, "Study context contains a cycle" end
	stack[value] = true

	local count, maximum, array = 0, 0, true
	for key in pairs(value) do
		count = count + 1
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			array = false
		elseif key > maximum then
			maximum = key
		end
	end
	local meta = getmetatable(value)
	if meta and meta.__jsontype == "array" then array = true
	elseif meta and meta.__jsontype == "object" then array = false
	else array = array and count > 0 and maximum == count end

	local parts = { }
	if array then
		for index = 1, maximum do
			local encoded, encodeError = canonical(value[index], stack, depth + 1)
			if not encoded then stack[value] = nil return nil, encodeError end
			parts[#parts + 1] = encoded
		end
		stack[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = { }
	for key in pairs(value) do
		if type(key) ~= "string" then stack[value] = nil return nil, "Study context objects must use string keys" end
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local encodedKey, keyError = json.encode(key)
		local encodedValue, valueError = canonical(value[key], stack, depth + 1)
		if type(encodedKey) ~= "string" or not encodedValue then
			stack[value] = nil
			return nil, keyError or valueError or "Could not encode study context object"
		end
		parts[#parts + 1] = encodedKey .. ":" .. encodedValue
	end
	stack[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

function context.Fingerprint(value, scope)
	if type(scope) ~= "string" or scope == "" then return nil, "Study context fingerprint scope is required" end
	local encoded, encodeError = canonical({ scope = scope, value = value }, { }, 0)
	if not encoded then return nil, encodeError end
	return sha.sha256(encoded)
end

function context.BuildSignature(signature)
	if type(signature) ~= "string" or signature == "" then return nil, "Source build signature is unavailable" end
	return context.Fingerprint(signature, "pob_source_build_signature_v1")
end

function context.ScenarioSignature(configuration)
	if type(configuration) ~= "table" then return nil, "Exact scenario configuration is unavailable" end
	return context.Fingerprint(configuration, "pob_scenario_configuration_v1")
end

function context.IsFingerprint(value)
	return type(value) == "string" and #value == 64 and value:match("^[%da-f]+$") ~= nil
end

return context
