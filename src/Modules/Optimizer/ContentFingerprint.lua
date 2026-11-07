-- Path of Building
--
-- Module: asynchronous identity for calculation-relevant manifest files.
-- This verifies local file bytes against the SHA-1 values declared by PoB's
-- updater, then builds a stable SHA-256 identity from those verified entries.

local sha = require("sha2")
local fingerprint = { }

local allowedParts = { default = true, program = true, runtime = true, tree = true }
local ignoredMedia = {
	png = true, jpg = true, jpeg = true, webp = true, tga = true,
	svg = true, gif = true, ico = true, bmp = true,
}
local MAX_FILES = 2048
local MAX_FILE_BYTES = 67108864
local MAX_TOTAL_BYTES = 1073741824

local function safeRelativePath(path)
	if type(path) ~= "string" or path == "" or #path > 512 or path:find("[%c]")
		or path:find("\\", 1, true) or path:sub(1, 1) == "/" or path:match("^[%a]:") then
		return false
	end
	for segment in path:gmatch("[^/]+") do if segment == ".." or segment == "." then return false end end
	return true
end

local function isCalculationFile(part, path)
	if not allowedParts[part] or not safeRelativePath(path) then return false end
	if part == "tree" and not path:match("^TreeData/") then return false end
	local extension = path:match("%.([^%.]+)$")
	if extension and ignoredMedia[extension:lower()] then return false end
	return true
end

local function validDigest(value, length)
	return type(value) == "string" and #value == length and value:match("^%x+$") ~= nil
end

local function manifestRows(manifest)
	local root = type(manifest) == "table" and manifest[1]
	if type(root) ~= "table" or root.elem ~= "PoBVersion" then return nil, "manifest_root_invalid" end
	local rows, seen, present = { }, { }, { }
	for _, node in ipairs(root) do
		if type(node) == "table" and node.elem == "File" then
			local attr = node.attrib or { }
			local part, path, expected = attr.part, attr.name, attr.sha1
			if not allowedParts[part] or not safeRelativePath(path)
				or not validDigest(expected, 40) then
				return nil, "manifest_file_entry_invalid"
			end
			if attr.runtime ~= nil and (type(attr.runtime) ~= "string" or #attr.runtime > 40 or attr.runtime:find("[%c]")) then
				return nil, "manifest_runtime_invalid"
			end
			local key = part .. "\0" .. path
			if seen[key] then return nil, "manifest_file_entry_duplicate" end
			seen[key], present[part] = true, true
			if isCalculationFile(part, path) then
				rows[#rows + 1] = { part = part, path = path, expectedSha1 = expected:lower(), runtime = attr.runtime or "" }
			end
		end
	end
	if #rows == 0 then return nil, "calculation_file_inventory_empty" end
	for part in pairs(allowedParts) do
		if not present[part] then return nil, "manifest_part_missing:" .. part end
	end
	if #rows > MAX_FILES then return nil, "calculation_file_inventory_too_large" end
	table.sort(rows, function(left, right)
		local leftKey = left.part .. "\0" .. left.path
		local rightKey = right.part .. "\0" .. right.path
		return leftKey < rightKey
	end)
	return rows
end

function fingerprint.BuildEntries(manifest)
	return manifestRows(manifest)
end

function fingerprint.SerializeEntries(rows)
	if type(rows) ~= "table" or #rows > MAX_FILES then return nil, "calculation_file_inventory_invalid" end
	local lines = { }
	for _, row in ipairs(rows) do
		if type(row) ~= "table" or not allowedParts[row.part] or not safeRelativePath(row.path)
			or not validDigest(row.expectedSha1, 40) then return nil, "calculation_file_entry_invalid" end
		lines[#lines + 1] = table.concat({ row.part, row.path, row.expectedSha1:lower(), row.runtime or "" }, "\t")
	end
	return table.concat(lines, "\n")
end

function fingerprint.ParseEntries(serialized)
	if type(serialized) ~= "string" or #serialized > 524288 then return nil, "calculation_file_inventory_invalid" end
	local rows, seen = { }, { }
	for line in (serialized .. "\n"):gmatch("(.-)\n") do
		if line ~= "" then
			local part, path, expected, runtime = line:match("^([^\t]+)\t([^\t]+)\t([^\t]+)\t([^\t]*)$")
			if not allowedParts[part] or not safeRelativePath(path) or not validDigest(expected, 40)
				or #runtime > 40 or runtime:find("[%c]") then return nil, "calculation_file_entry_invalid" end
			local key = part .. "\0" .. path
			if seen[key] then return nil, "calculation_file_entry_duplicate" end
			seen[key] = true
			rows[#rows + 1] = { part = part, path = path, expectedSha1 = expected:lower(), runtime = runtime }
			if #rows > MAX_FILES then return nil, "calculation_file_inventory_too_large" end
		end
	end
	if #rows == 0 then return nil, "calculation_file_inventory_empty" end
	table.sort(rows, function(left, right)
		return left.part .. "\0" .. left.path < right.part .. "\0" .. right.path
	end)
	return rows
end

local function joinPath(root, relative)
	if type(root) ~= "string" or root == "" then return nil end
	local separator = package.config and package.config:sub(1, 1) or "/"
	-- PoB's updater manifest escapes spaces as `{space}`. Resolve that token
	-- before opening files, matching UpdateCheck/UpdateApply and the package path.
	local normalizedRelative = relative:gsub("{space}", " ")
	return root:gsub("[/\\]+$", "") .. separator .. normalizedRelative:gsub("/", separator)
end

local function readFile(path)
	local file, openError = io.open(path, "rb")
	if not file then return nil, "calculation_file_unavailable" end
	local content = file:read("*a")
	file:close()
	if type(content) ~= "string" then return nil, "calculation_file_read_failed" end
	return content
end

local function canonicalManifestContent(content)
	-- update_manifest.py hashes text after normalizing every newline to CRLF.
	-- Match that canonical representation while preserving binary payloads.
	if not content:find("\0", 1, true) then
		content = content:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\n", "\r\n")
	end
	return content
end

function fingerprint.Compute(rows, roots, inventoryFingerprint, fileReader)
	if type(rows) ~= "table" or #rows == 0 or #rows > MAX_FILES
		or not validDigest(inventoryFingerprint, 64) then
		return nil, "unavailable", 0, 0, "calculation_identity_input_invalid"
	end
	fileReader = fileReader or readFile
	local payload = { "pob-calculation-content-v1", inventoryFingerprint:lower(), tostring(#rows) }
	local byteCount = 0
	for _, row in ipairs(rows) do
		local root = roots and roots[row.part]
		local path = joinPath(root, row.path)
		if not path then return nil, "unavailable", #payload - 3, byteCount, "calculation_root_unavailable:" .. row.part end
		local content, readError = fileReader(path, row)
		if type(content) ~= "string" then
			return nil, "unavailable", #payload - 3, byteCount, readError or "calculation_file_unavailable"
		end
		if #content > MAX_FILE_BYTES then
			return nil, "unavailable", #payload - 3, byteCount, "calculation_file_too_large:" .. row.part .. "/" .. row.path
		end
		byteCount = byteCount + #content
		if byteCount > MAX_TOTAL_BYTES then
			return nil, "unavailable", #payload - 3, byteCount, "calculation_inventory_too_large"
		end
		local canonicalContent = canonicalManifestContent(content)
		local actualSha1 = sha.sha1(canonicalContent)
		if actualSha1:lower() ~= row.expectedSha1:lower() then
			canonicalContent = nil
			return nil, "mismatch", #payload - 3, byteCount, "manifest_sha1_mismatch:" .. row.part .. "/" .. row.path
				.. ":expected=" .. row.expectedSha1:lower() .. ":actual=" .. actualSha1:lower() .. ":file=" .. path
		end
		-- The native manifest already defines the per-file SHA-1 contract. Verify
		-- each real file once, then SHA-256 the compact verified inventory rather
		-- than hashing hundreds of MiB a second time in pure Lua.
		payload[#payload + 1] = table.concat({ row.part, row.path, tostring(#canonicalContent), actualSha1:lower() }, "\0")
		content, canonicalContent = nil, nil
	end
	local digest = sha.sha256(table.concat(payload, "\n"))
	return digest, "verified", #rows, byteCount
end

function fingerprint.ComputeSerialized(serialized, roots, inventoryFingerprint)
	local rows, parseError = fingerprint.ParseEntries(serialized)
	if not rows then return nil, "unavailable", 0, 0, parseError end
	return fingerprint.Compute(rows, roots, inventoryFingerprint)
end

function fingerprint.Start(manifest, roots, inventoryFingerprint, callback, errorCallback)
	if type(LaunchSubScript) ~= "function" then return nil, "subscript_runtime_unavailable" end
	if type(launch) ~= "table" or type(launch.subScripts) ~= "table" then return nil, "subscript_registry_unavailable" end
	if type(callback) ~= "function" or type(errorCallback) ~= "function" then return nil, "subscript_callback_invalid" end
	local rows, rowError = fingerprint.BuildEntries(manifest)
	if not rows then return nil, rowError end
	local serialized, serializeError = fingerprint.SerializeEntries(rows)
	if not serialized then return nil, serializeError end
	local worker = [[
		local serialized, defaultRoot, scriptRoot, runtimeRoot, inventoryFingerprint = ...
		local integrity = require("Modules.Optimizer.ContentFingerprint")
		local roots = { default = defaultRoot, program = scriptRoot, tree = scriptRoot, runtime = runtimeRoot }
		return integrity.ComputeSerialized(serialized, roots, inventoryFingerprint)
	]]
	local id, startError = LaunchSubScript(worker, "", "", serialized, roots.default, roots.program, roots.runtime, inventoryFingerprint)
	if not id then return nil, startError or "subscript_start_failed" end
	launch.subScripts[id] = { type = "CUSTOM", callback = callback, errorCallback = errorCallback }
	return id, #rows
end

return fingerprint
