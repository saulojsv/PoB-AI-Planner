-- Bounded zlib decompression for untrusted PoB build-code imports.
-- The destination buffer is allocated at the configured ceiling, so inflate
-- cannot grow memory in proportion to a compressed payload's expansion ratio.
local boundedInflate = { }
local MAX_OUTPUT_BYTES = 33554432
local MAX_TRUSTED_STATIC_OUTPUT_BYTES = 134217728
local MAX_TRUSTED_STATIC_COMPRESSED_BYTES = 33554432
local Z_OK = 0
local Z_BUF_ERROR = -5
local floor = math.floor
local huge = math.huge

local ffi
local zlib
local attemptedLoad = false

local function loadZlib()
	if zlib then return zlib end
	if attemptedLoad then return nil end
	attemptedLoad = true

	local ffiOk, ffiModule = pcall(require, "ffi")
	if not ffiOk or type(ffiModule) ~= "table" then return nil end
	ffi = ffiModule
	local cdefOk = pcall(ffi.cdef, [[
		typedef unsigned char PoBBoundedByte;
		typedef unsigned long PoBBoundedULong;
		int uncompress(PoBBoundedByte *dest, PoBBoundedULong *destLen,
			const PoBBoundedByte *source, PoBBoundedULong sourceLen);
	]])
	if not cdefOk then return nil end

	local candidates = { }
	local function addCandidate(name)
		if type(name) ~= "string" or name == "" then return end
		for _, existing in ipairs(candidates) do
			if existing == name then return end
		end
		candidates[#candidates + 1] = name
	end
	if ffi.os == "Windows" then
		if type(GetRuntimePath) == "function" then
			local pathOk, runtimePath = pcall(GetRuntimePath)
			if pathOk and type(runtimePath) == "string" and runtimePath ~= "" then
				addCandidate(runtimePath:gsub("[/\\]+$", "") .. "/zlib1.dll")
			end
		end
		addCandidate("runtime/zlib1.dll")
		addCandidate("../runtime/zlib1.dll")
		addCandidate("zlib1")
		addCandidate("zlib1.dll")
	else
		addCandidate("z")
		addCandidate("libz.so.1")
		addCandidate("libz.dylib")
	end

	for _, name in ipairs(candidates) do
		local loadOk, library = pcall(ffi.load, name)
		if loadOk then
			local symbolOk = pcall(function() return library.uncompress end)
			if symbolOk then
				zlib = library
				return zlib
			end
		end
	end
	return nil
end

local function inflateWithLimit(compressed, outputLimit)
	if type(compressed) ~= "string" or compressed == "" then return nil, "invalid_code" end
	local library = loadZlib()
	if not library then return nil, "inflater_unavailable" end

	local ok, output, reason = pcall(function()
		local destination = ffi.new("PoBBoundedByte[?]", outputLimit)
		local destinationLength = ffi.new("PoBBoundedULong[1]", outputLimit)
		local source = ffi.cast("const PoBBoundedByte *", compressed)
		local result = library.uncompress(destination, destinationLength, source, #compressed)
		if result == Z_OK then
			return ffi.string(destination, tonumber(destinationLength[0]))
		elseif result == Z_BUF_ERROR and tonumber(destinationLength[0]) >= outputLimit then
			return nil, "payload_too_large"
		end
		return nil, "invalid_code"
	end)
	if not ok then return nil, "decompression_failed" end
	return output, reason
end

--- Inflate untrusted PoB build-code streams without exceeding the 32 MiB ceiling.
--- A smaller caller limit is useful for constrained contexts and tests; callers
--- cannot raise the import ceiling.
function boundedInflate.inflate(compressed, requestedLimit)
	local outputLimit = MAX_OUTPUT_BYTES
	if type(requestedLimit) == "number" and requestedLimit == requestedLimit
		and requestedLimit ~= huge and requestedLimit ~= -huge and requestedLimit >= 1 then
		outputLimit = math.min(floor(requestedLimit), MAX_OUTPUT_BYTES)
	end
	return inflateWithLimit(compressed, outputLimit)
end

--- Inflate fixed, shipped PoB data files whose verified payloads can exceed the
--- build-code limit. This path is only used by DataJewelFileLoader for files in
--- the installed game's Data/TimelessJewelData directory; never use it for user
--- imports or network payloads.
function boundedInflate.inflateTrustedStaticData(compressed)
	if type(compressed) ~= "string" or compressed == "" then return nil, "invalid_code" end
	if #compressed > MAX_TRUSTED_STATIC_COMPRESSED_BYTES then return nil, "payload_too_large" end
	return inflateWithLimit(compressed, MAX_TRUSTED_STATIC_OUTPUT_BYTES)
end

boundedInflate.MAX_OUTPUT_BYTES = MAX_OUTPUT_BYTES
return boundedInflate
