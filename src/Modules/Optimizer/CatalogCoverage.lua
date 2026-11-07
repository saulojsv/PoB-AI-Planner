-- Path of Building
--
-- Module: versioned, reproducible export of the loaded PoE 1 gem catalog.
-- This records source-data coverage only; it does not evaluate gem packages.

local json = require("dkjson")
local sha = require("sha2")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local coverage = { }

local STORE_FOLDER = "OptimizerStudies"
local CATALOG_FOLDER = "SkillCatalogs"
local MAX_EXPORT_BYTES = 8388608

local function joinPath(left, right, separator)
	local base = tostring(left or "")
	while base:sub(-1) == "/" or base:sub(-1) == "\\" do base = base:sub(1, -2) end
	return base .. separator .. right
end

local function canonicalJson(value, stack)
	if type(value) ~= "table" or value == json.null then
		local encoded, encodeError = json.encode(value)
		if type(encoded) ~= "string" then return nil, encodeError or "Could not encode catalog identity" end
		return encoded
	end
	stack = stack or { }
	if stack[value] then return nil, "Catalog identity contains a cycle" end
	stack[value] = true
	local count, maximum, isArray = 0, 0, getmetatable(value) and getmetatable(value).__jsontype == "array"
	if not isArray and not (getmetatable(value) and getmetatable(value).__jsontype == "object") then
		isArray = true
		for key in pairs(value) do
			count = count + 1
			if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
				isArray = false
			elseif key > maximum then
				maximum = key
			end
		end
	else
		for key in pairs(value) do
			count = count + 1
			if type(key) == "number" and key > maximum then maximum = key end
		end
	end
	if isArray and maximum == count then
		local parts = { }
		for index = 1, count do
			local encoded, encodeError = canonicalJson(value[index], stack)
			if not encoded then stack[value] = nil return nil, encodeError end
			parts[#parts + 1] = encoded
		end
		stack[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = { }
	for key in pairs(value) do
		if type(key) ~= "string" then stack[value] = nil return nil, "Catalog identity has a non-string object key" end
		keys[#keys + 1] = key
	end
	table.sort(keys)
	local parts = { }
	for _, key in ipairs(keys) do
		local encodedKey, keyError = json.encode(key)
		local encodedValue, valueError = canonicalJson(value[key], stack)
		if type(encodedKey) ~= "string" or not encodedValue then
			stack[value] = nil
			return nil, keyError or valueError or "Could not encode catalog identity"
		end
		parts[#parts + 1] = encodedKey .. ":" .. encodedValue
	end
	stack[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

local function tagCountObjects(report)
	for _, group in pairs(report.tagCoverage or { }) do
		if type(group) == "table" then setmetatable(group, { __jsontype = "object" }) end
	end
	setmetatable(report.tagCoverage or { }, { __jsontype = "object" })
end

local function fingerprintOf(report)
	if type(report) ~= "table" or report.fingerprintAlgorithm ~= "SHA-256" then
		return nil, "Catalog fingerprint algorithm is missing or unsupported"
	end
	local identity = { }
	for key, value in pairs(report) do
		if key ~= "fingerprint" then identity[key] = value end
	end
	tagCountObjects(identity)
	local encoded, encodeError = canonicalJson(identity)
	if not encoded then return nil, encodeError end
	return sha.sha256(encoded)
end

function coverage.Build(build)
	local report, reportError = SkillCatalog.CoverageReport(build)
	if not report then return nil, reportError end
	tagCountObjects(report)
	report.fingerprintAlgorithm = "SHA-256"
	local fingerprint, fingerprintError = fingerprintOf(report)
	if not fingerprint then return nil, fingerprintError end
	report.fingerprint = fingerprint
	return report
end

local function resultFor(report, path, reused, byteCount)
	local relativePath = STORE_FOLDER .. "/" .. CATALOG_FOLDER .. "/" .. path:match("([^/\\]+)$")
	return {
		exported = true,
		status = reused and "already_current" or "exported",
		reused = reused == true,
		readOnly = false,
		evaluationStatus = report.evaluationStatus,
		exactEvaluated = report.exactEvaluated,
		combinationCoverage = report.combinationCoverage,
		version = report.version,
		fingerprint = report.fingerprint,
		fingerprintAlgorithm = report.fingerprintAlgorithm,
		counts = report.counts,
		storeFile = relativePath,
		bytes = byteCount,
	}
end

function coverage.Export(userPath, build, createDirectory)
	if type(userPath) ~= "string" or userPath == "" then
		return nil, "PoB's configured user-data directory is unavailable"
	end
	if type(createDirectory) ~= "function" then
		return nil, "PoB's native directory creator is unavailable"
	end
	local report, reportError = coverage.Build(build)
	if not report then return nil, reportError end
	local encoded, encodeError = json.encode(report)
	if type(encoded) ~= "string" then return nil, encodeError or "Could not encode skill catalog report" end
	if #encoded > MAX_EXPORT_BYTES then return nil, "Skill catalog report exceeds the local export size limit" end

	local separator = package.config and package.config:sub(1, 1) or "\\"
	local storeDirectory = joinPath(userPath, STORE_FOLDER, separator)
	local exportDirectory = joinPath(storeDirectory, CATALOG_FOLDER, separator)
	local callOk, created, createError = pcall(createDirectory, exportDirectory .. separator)
	if not callOk then return nil, "Could not create the local catalog export directory: " .. tostring(created) end
	if not created and createError ~= "No error" then
		return nil, "Could not create the local catalog export directory: " .. tostring(createError or "unknown error")
	end

	local fileName = "poe1-skill-catalog-v" .. tostring(report.schemaVersion) .. "-" .. report.fingerprint .. ".json"
	local exportPath = joinPath(exportDirectory, fileName, separator)
	local existing = io.open(exportPath, "rb")
	if existing then
		local existingSize = existing:seek("end") or 0
		existing:seek("set", 0)
		local existingText = existingSize <= MAX_EXPORT_BYTES and existing:read("*a") or nil
		existing:close()
		local previous = existingText and json.decode(existingText)
		local previousFingerprint = type(previous) == "table" and fingerprintOf(previous) or nil
		if type(previous) == "table" and previousFingerprint == previous.fingerprint
			and previous.fingerprint == report.fingerprint then
			return resultFor(report, exportPath, true, existingSize)
		end
		return nil, "A catalog report already exists at the fingerprint path but failed integrity verification"
	end

	local temporaryPath = exportPath .. ".tmp"
	local file, openError = io.open(temporaryPath, "wb")
	if not file then return nil, "Could not open the temporary catalog report: " .. tostring(openError) end
	local wrote, writeError = file:write(encoded)
	local closed, closeError = file:close()
	if not wrote or not closed then
		pcall(os.remove, temporaryPath)
		return nil, "Could not write the catalog report: " .. tostring(writeError or closeError or "unknown error")
	end
	local moved, moveError = os.rename(temporaryPath, exportPath)
	if not moved then
		pcall(os.remove, temporaryPath)
		return nil, "Could not atomically publish the catalog report: " .. tostring(moveError or "unknown error")
	end
	return resultFor(report, exportPath, false, #encoded)
end

coverage.MAX_EXPORT_BYTES = MAX_EXPORT_BYTES
coverage.Fingerprint = fingerprintOf
return coverage
