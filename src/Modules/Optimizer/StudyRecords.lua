-- Path of Building
--
-- Module: Local exact-result records for controlled optimizer experiments.
-- Records are appended only by an explicit typed MCP operation and are stored
-- below PoB's configured user-data directory. Imported build text is data, not
-- executable instructions, and all model-training admission remains fail-closed.

local json = require("dkjson")
local sha = require("sha2")
local TrainingData = require("Modules.Optimizer.TrainingData")
local records = { }

local STORE_FOLDER = "OptimizerStudies"
local STORE_FILE = "paired-experiments.jsonl"
local REVIEW_FILE = "training-reviews.jsonl"
local MAX_RECORD_BYTES = 65536
local MAX_STORE_BYTES = 33554432
local MAX_REVIEW_BYTES = 8388608
local MAX_REVIEW_LINE_BYTES = 4096
local MAX_WITHDRAWAL_BYTES = 8388608
local MAX_WITHDRAWAL_LINE_BYTES = 4096
local MAX_LIST_LIMIT = 25
local REVIEW_SCHEMA_VERSION = 3
local LOCAL_TRAINING_RIGHTS_SCOPE = "offline_local_model_training"
local sequence = 0

local COVERAGE_CLASSES = { "Duelist", "Marauder", "Ranger", "Scion", "Shadow", "Templar", "Witch" }
local ENGINE_IDENTITY_KEYS = { "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }
local COVERAGE_CLASS_SET = { }
for _, className in ipairs(COVERAGE_CLASSES) do COVERAGE_CLASS_SET[className] = true end

local function normalizeRightsEvidence(value)
	if type(value) ~= "table" then return nil, "Source-use evidence is required for local model training" end
	local basis = value.basis
	if basis ~= "user_authored" and basis ~= "creator_permission" and basis ~= "open_license" then
		return nil, "Choose user-authored work, explicit creator permission, or an open license"
	end
	if value.scope ~= nil and value.scope ~= LOCAL_TRAINING_RIGHTS_SCOPE then
		return nil, "Rights evidence scope must be offline local-model training only"
	end
	local result = { basis = basis, scope = LOCAL_TRAINING_RIGHTS_SCOPE }
	if basis == "open_license" then
		local licenseId, licenseUrl = value.licenseId, value.licenseUrl
		if type(licenseId) ~= "string" or #licenseId < 2 or #licenseId > 80
			or not licenseId:match("^[%w%.%+%-]+$") then
			return nil, "Open-license evidence requires a valid license identifier"
		end
		local host = type(licenseUrl) == "string" and licenseUrl:match("^https://([^/]+)/")
		if type(licenseUrl) ~= "string" or #licenseUrl > 256 or licenseUrl:find("[%c@?#]")
			or not licenseUrl:match("^https://[%w%-%.]+/[%w%._~/%%-]+$")
			or not host or host:find("..", 1, true) or host:find("^%.") or host:find("%.$") then
			return nil, "Open-license evidence requires a canonical HTTPS license URL without query or fragment"
		end
		result.licenseId = licenseId
		result.licenseUrl = licenseUrl
	elseif basis == "creator_permission" then
		local reference = value.permissionReference
		if type(reference) ~= "string" or #reference < 8 or #reference > 128
			or not reference:match("^[%w%._:/%-]+$") then
			return nil, "Creator permission requires a non-personal evidence reference (8–128 letters, digits, . _ : / or -)"
		end
		result.permissionReference = reference
	end
	return result
end

local function rightsSummary(evidence)
	if type(evidence) ~= "table" then return nil end
	return {
		basis = evidence.basis,
		licenseId = evidence.licenseId,
		scope = evidence.scope,
	}
end

function records.NormalizeRightsEvidence(value)
	return normalizeRightsEvidence(value)
end

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function joinPath(left, right, separator)
	local base = tostring(left or "")
	while base:sub(-1) == "/" or base:sub(-1) == "\\" do base = base:sub(1, -2) end
	return base .. separator .. right
end

function records.GetStorePath(userPath)
	if type(userPath) ~= "string" or userPath == "" then
		return nil, "PoB's configured user-data directory is unavailable"
	end
	local separator = package.config and package.config:sub(1, 1) or "\\"
	local directory = joinPath(userPath, STORE_FOLDER, separator)
	return joinPath(directory, STORE_FILE, separator), directory
end

function records.GetReviewPath(userPath)
	local storePath, directoryOrError = records.GetStorePath(userPath)
	if not storePath then return nil, directoryOrError end
	local separator = package.config and package.config:sub(1, 1) or "\\"
	return joinPath(directoryOrError, REVIEW_FILE, separator), directoryOrError
end

local function nextRecordId()
	sequence = sequence + 1
	local randomPart = math.random and math.random(0, 2147483647) or sequence
	return "study-" .. os.date("!%Y%m%dT%H%M%SZ") .. "-" .. tostring(randomPart) .. "-" .. tostring(sequence)
end

-- Produce stable JSON for semantic comparison. dkjson correctly preserves the
-- record data, but Lua's pairs() order is intentionally unspecified, so raw
-- encoded lines cannot serve as duplicate keys across app sessions.
local function canonicalJson(value, stack, path)
	if type(value) ~= "table" or value == json.null then
		local encoded, encodeError = json.encode(value)
		if type(encoded) ~= "string" then return nil, encodeError or "Could not encode study identity" end
		return encoded
	end
	stack = stack or { }
	path = path or "$"
	if stack[value] then return nil, "Study identity contains a cycle at " .. path end
	stack[value] = true
	local count, maxIndex, isArray = 0, 0, true
	for key in pairs(value) do
		count = count + 1
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			isArray = false
		elseif key > maxIndex then
			maxIndex = key
		end
	end
	local parts = { }
	if isArray and maxIndex == count then
		for index = 1, count do
			local encoded, encodeError = canonicalJson(value[index], stack, path .. "[" .. index .. "]")
			if not encoded then stack[value] = nil return nil, encodeError end
			parts[#parts + 1] = encoded
		end
		stack[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys, sourceKeys = { }, { }
	for key in pairs(value) do
		local normalizedKey
		if type(key) == "string" then
			normalizedKey = key
		elseif isFinite(key) and key == math.floor(key) and math.abs(key) <= 9007199254740991 then
			-- Some PoB snapshots use sparse node-ID/index maps. JSON object
			-- keys are strings, so normalize safe integer keys exactly as the
			-- persisted representation does instead of rejecting the record.
			normalizedKey = string.format("%.0f", key)
		else
			stack[value] = nil
			return nil, "Study identity has an unsupported object key at " .. path
		end
		if sourceKeys[normalizedKey] ~= nil then
			stack[value] = nil
			return nil, "Study identity has colliding object keys at " .. path .. "." .. normalizedKey
		end
		sourceKeys[normalizedKey] = key
		keys[#keys + 1] = normalizedKey
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local encodedKey, keyError = json.encode(key)
		local sourceKey = sourceKeys[key]
		local encodedValue, valueError = canonicalJson(value[sourceKey], stack, path .. "." .. key)
		if type(encodedKey) ~= "string" or not encodedValue then
			stack[value] = nil
			return nil, keyError or valueError or "Could not encode study identity"
		end
		parts[#parts + 1] = encodedKey .. ":" .. encodedValue
	end
	stack[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

local function experimentIdentity(record)
	-- Require the complete exact-result pair contract. Incomplete legacy or test
	-- records remain readable, but are not collapsed based on sparse metadata.
	if type(record) ~= "table" or type(record.kind) ~= "string"
		or type(record.engine) ~= "table" or type(record.buildState) ~= "table"
		or type(record.experiment) ~= "table" or type(record.baseline) ~= "table"
		or type(record.candidate) ~= "table" or type(record.baseline.metrics) ~= "table"
		or type(record.candidate.metrics) ~= "table" then
		return nil
	end
	local experiment = { }
	for key, value in pairs(record.experiment) do
		-- A hypothesis label is useful provenance, but it does not create a new
		-- independent evaluation of the same one-factor state change.
		if key ~= "label" then experiment[key] = value end
	end
	local identity = {
		kind = record.kind,
		engine = {
			pobVersion = record.engine.pobVersion,
			pobBranch = record.engine.pobBranch,
			dataVersion = record.engine.dataVersion,
			treeVersion = record.engine.treeVersion,
			manifestFingerprint = record.engine.manifestFingerprint,
			lookupTableStatus = record.engine.lookupTableStatus,
		},
		lineage = record.lineage,
		buildState = record.buildState,
		experiment = experiment,
		baseline = record.baseline,
		candidate = record.candidate,
		factorial = record.factorial,
		metricDelta = record.metricDelta,
	}
	-- Validate the live Lua maps before JSON encoding. dkjson can serialize a
	-- numeric key and an identical numeric-looking string key as duplicate JSON
	-- members; decoding that payload would hide the collision by keeping one.
	local _, liveIdentityError = canonicalJson(identity)
	if liveIdentityError then return nil, liveIdentityError end
	-- Match identity to the persisted JSON representation. PoB snapshots can
	-- contain numeric mastery-node keys; dkjson serializes those object keys as
	-- strings, so canonicalizing the live Lua table first would reject a valid
	-- record and make a later read produce a different duplicate key. The live
	-- pass above is validation only; this normalized form remains the idempotency
	-- key used for both newly written and previously persisted records.
	local encoded, encodeError = json.encode(identity)
	if type(encoded) ~= "string" then return nil, encodeError or "Could not encode study identity" end
	local ok, normalized = pcall(json.decode, encoded)
	if not ok or type(normalized) ~= "table" then return nil, "Could not normalize study identity through JSON" end
	return canonicalJson(normalized)
end

local function findDuplicateRecord(path, identity)
	if not identity then return nil end
	local file, openError = io.open(path, "rb")
	if not file then
		local message = tostring(openError or "")
		if message:lower():find("no such file", 1, true) or message:lower():find("cannot find", 1, true) then
			return nil
		end
		return nil, "Could not inspect the local study record store: " .. message
	end
	local size = file:seek("end") or 0
	if size > MAX_STORE_BYTES then file:close() return nil, "The study record store exceeds its safety limit" end
	file:seek("set", 0)
	for line in file:lines() do
		if #line <= MAX_RECORD_BYTES then
			local ok, existing = pcall(json.decode, line)
			if ok and type(existing) == "table" and existing.recordId then
				local existingIdentity = experimentIdentity(existing)
				if existingIdentity and existingIdentity == identity then
					file:close()
					return existing
				end
			end
		end
	end
	file:close()
	return nil
end

local function prepareRecord(record)
	if type(record) ~= "table" then return nil, "Study record must be an object" end
	record.schemaVersion = TrainingData.RECORD_SCHEMA_VERSION
	record.recordId = nextRecordId()
	record.recordedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
	local source = type(record.source) == "table" and record.source or { type = "active_build" }
	record.source = source
	local lineageIdentity
	local lineageBasis
	local snapshotIdentity
	if type(record.engine) == "table" and type(record.buildState) == "table" then
		snapshotIdentity = {
			engine = {
				pobVersion = record.engine.pobVersion,
				pobBranch = record.engine.pobBranch,
				dataVersion = record.engine.dataVersion,
				treeVersion = record.engine.treeVersion,
				manifestFingerprint = record.engine.manifestFingerprint,
			},
			buildState = record.buildState,
		}
	end
	local snapshotJson = snapshotIdentity and canonicalJson(snapshotIdentity) or nil
	local snapshotFingerprint = snapshotJson and sha.sha256(snapshotJson) or nil
	if source.type == "public_build_study" then
		local provider = type(source.provider) == "string" and #source.provider <= 96 and source.provider or nil
		local sourceUrl = type(source.sourceUrl) == "string" and #source.sourceUrl <= 2048 and source.sourceUrl or nil
		if provider and not provider:find("[%c]") and sourceUrl and not sourceUrl:find("[%c]")
			and sourceUrl:match("^https://") then
			lineageIdentity = { type = source.type, provider = provider, sourceUrl = sourceUrl }
			lineageBasis = "public_source_url"
		end
	elseif source.type == "active_build" or source.type == "native_comparison_build" then
		if snapshotFingerprint then
			lineageIdentity = { type = source.type, snapshotFingerprint = snapshotFingerprint }
			lineageBasis = "exact_build_snapshot"
		end
	end
	local lineageJson = lineageIdentity and canonicalJson(lineageIdentity) or nil
	if lineageJson then
		record.lineage = {
			schemaVersion = 1,
			fingerprint = sha.sha256(lineageJson),
			snapshotFingerprint = snapshotFingerprint,
			basis = lineageBasis,
		}
	else
		record.lineage = nil
	end
	-- Research observations are never promoted directly into supervised labels.
	-- A later ingestion pipeline must review scenario/activity and LUT coverage.
	record.trainingEligible = false
	record.quarantine = record.quarantine or {
		status = "pending_review",
		reasons = {
			"scenario conditions are not fully certified",
			"full encounter activity is not certified",
			"jewel lookup-table coverage is not audited",
		},
	}
	local encoded, encodeError = json.encode(record)
	if type(encoded) ~= "string" then return nil, encodeError or "Could not encode the exact study record" end
	-- Exact research snapshots can include node names, verbose readiness and,
	-- for factorial builds, an expanded all-skills cost audit. Compact only when
	-- the 64 KiB boundary requires it: versioned node IDs, skills, items,
	-- configuration, requirements and exact factorial cells remain available.
	local buildState = record.buildState
	if #encoded > MAX_RECORD_BYTES and type(buildState) == "table" then
		local omittedFields = { }
		local optionalFields = { "allocatedNodes", "buildReadiness", "manualActionAudit" }
		if record.kind == "passive_factorial_interaction"
			or record.kind == "skill_support_factorial_interaction"
			or record.kind == "skill_skill_factorial_interaction"
			or record.kind == "passive_support_factorial_interaction"
			or record.kind == "skill_item_slot_factorial_interaction"
			or record.kind == "passive_item_slot_factorial_interaction" then
			-- A factorial carries four exact per-cell payability/activity results.
			-- The verbose all-skills cost audit can be regenerated from its retained
			-- skill groups, selected metrics and exact cell results when needed.
			optionalFields[#optionalFields + 1] = "skillCostAudit"
		end
		for _, field in ipairs(optionalFields) do
			if #encoded <= MAX_RECORD_BYTES then break end
			if buildState[field] ~= nil then
				buildState[field] = nil
				omittedFields[#omittedFields + 1] = field
				buildState.recordCompaction = {
					schemaVersion = 1,
					omittedFields = omittedFields,
					rationale = "Oversized study snapshot; exact tree node IDs, versions, skills, items, scenario and metric cells are retained; verbose derived diagnostics are omitted",
				}
				encoded, encodeError = json.encode(record)
				if type(encoded) ~= "string" then return nil, encodeError or "Could not encode the compact exact study record" end
			end
		end
	end
	if #encoded > MAX_RECORD_BYTES then return nil, "The study record exceeds the 64 KiB size limit" end
	return encoded
end

function records.AppendToPath(record, path)
	if type(path) ~= "string" or path == "" then return nil, "Study record path is unavailable" end
	local encoded, encodeError = prepareRecord(record)
	if not encoded then return nil, encodeError end
	local identity, identityError = experimentIdentity(record)
	if identityError then return nil, identityError end
	local duplicate, duplicateError = findDuplicateRecord(path, identity)
	if duplicateError then return nil, duplicateError end
	if duplicate then
		return {
			recordId = duplicate.recordId,
			duplicate = true,
			storeFile = STORE_FOLDER .. "/" .. STORE_FILE,
			storedBytes = 0,
		}
	end
	local file, openError = io.open(path, "ab")
	if not file then return nil, "Could not open the local study record store: " .. tostring(openError) end
	local size = file:seek("end") or 0
	if size + #encoded + 1 > MAX_STORE_BYTES then
		file:close()
		return nil, "The local study record store reached its 32 MiB limit; archive it before recording more experiments"
	end
	local written, writeError = file:write(encoded, "\n")
	if written then
		local flushed, flushError = file:flush()
		if not flushed then writeError = flushError end
	end
	file:close()
	if not written or writeError then return nil, "Could not append the local study record: " .. tostring(writeError or "write failed") end
	return { recordId = record.recordId, duplicate = false, storeFile = STORE_FOLDER .. "/" .. STORE_FILE, storedBytes = #encoded + 1 }
end

function records.Append(record, userPath, createDirectory)
	local path, directoryOrError = records.GetStorePath(userPath)
	if not path then return nil, directoryOrError end
	if type(createDirectory) ~= "function" then return nil, "PoB's native directory creator is unavailable" end
	local callOk, created, createError = pcall(createDirectory, directoryOrError .. (package.config and package.config:sub(1, 1) or "\\"))
	-- The native PoB MakeDir API reports (nil, "No error") when the directory
	-- already exists, matching the credential-storage helper's convention.
	if not callOk then return nil, "Could not create the local study directory: " .. tostring(created) end
	if not created and createError ~= "No error" then
		return nil, "Could not create the local study directory: " .. tostring(createError or "unknown error")
	end
	return records.AppendToPath(record, path)
end

local function currentVersionStatus(record, expectedEngine)
	local engine = record.engine or { }
	if type(expectedEngine) ~= "table" then return "unverified", true end
	if type(engine.manifestFingerprint) ~= "string" or #engine.manifestFingerprint ~= 64
		or not engine.manifestFingerprint:match("^[%da-f]+$")
		or type(expectedEngine.manifestFingerprint) ~= "string" or #expectedEngine.manifestFingerprint ~= 64
		or not expectedEngine.manifestFingerprint:match("^[%da-f]+$") then return "unverified", true end
	for _, key in ipairs(ENGINE_IDENTITY_KEYS) do
		if type(engine[key]) ~= "string" or engine[key] == "" or type(expectedEngine[key]) ~= "string" or expectedEngine[key] == "" then
			return "unverified", true
		end
		if tostring(engine[key]) ~= tostring(expectedEngine[key]) then return "version_mismatch", true end
	end
	return "current", false
end

local function openStore(path)
	if type(path) ~= "string" or path == "" then return nil, "Study record path is unavailable" end
	local file, openError = io.open(path, "rb")
	if not file then
		if tostring(openError):lower():find("no such file", 1, true) or tostring(openError):lower():find("cannot find", 1, true) then
			return nil, "empty"
		end
		return nil, "Could not read the local study record store: " .. tostring(openError)
	end
	local size = file:seek("end") or 0
	if size > MAX_STORE_BYTES then file:close() return nil, "The study record store exceeds its safety limit" end
	file:seek("set", 0)
	return file
end

local function reviewPathForStore(path)
	if type(path) ~= "string" or path == "" then return nil end
	local directory = path:match("^(.*[/\\])") or ""
	local filename = path:match("[^/\\]+$") or path
	local reviewName = filename == STORE_FILE and REVIEW_FILE or filename .. ".reviews.jsonl"
	if directory == "" then return reviewName end
	return directory .. reviewName
end

local function validRecordId(recordId)
	return type(recordId) == "string" and #recordId >= 1 and #recordId <= 96
		and recordId:match("^[%w][%w%._%-]*$") ~= nil
end

local function withdrawalPathForStore(path)
	local directory = path:match("^(.*[/\\])") or ""
	if path:sub(-#STORE_FILE) == STORE_FILE then return directory .. "withdrawn-records.jsonl" end
	return path .. ".withdrawn-records.jsonl"
end

local function invalidationPathForStore(path)
	if type(path) ~= "string" or path == "" then return nil end
	local directory = path:match("^(.*[/\\])") or ""
	local filename = path:match("[^/\\]+$") or path
	if filename == STORE_FILE then return directory .. "training-artifacts-invalidated.json" end
	return path .. ".training-artifacts-invalidated.json"
end

local function isMissingFileError(message)
	message = tostring(message or ""):lower()
	return message:find("no such file", 1, true) ~= nil
		or message:find("cannot find", 1, true) ~= nil
		or message:find("does not exist", 1, true) ~= nil
end

local function fileExists(path)
	local file = io.open(path, "rb")
	if not file then return false end
	file:close()
	return true
end

local function trainingInvalidationState(storePath)
	local path = invalidationPathForStore(storePath)
	if not path then return nil, "Study record path is unavailable" end
	local file, openError = io.open(path, "rb")
	if file then file:close(); return true end
	if isMissingFileError(openError) then return false end
	return nil, "Could not inspect the local training-invalidation marker: " .. tostring(openError or "unknown read error")
end

local ffiOk, ffi = pcall(require, "ffi")
local windowsMoveFileApi
local function replaceFileAtomically(sourcePath, targetPath)
	if ffiOk and ffi.os == "Windows" then
		if not windowsMoveFileApi then
			local defined, defineError = pcall(ffi.cdef, [[
				typedef unsigned long POB_STUDY_DWORD;
				typedef int POB_STUDY_BOOL;
				int MultiByteToWideChar(unsigned int, POB_STUDY_DWORD, const char *, int, wchar_t *, int);
				POB_STUDY_BOOL MoveFileExW(const wchar_t *, const wchar_t *, POB_STUDY_DWORD);
				POB_STUDY_DWORD GetLastError(void);
			]])
			if not defined then return nil, "Could not initialize atomic Windows file replacement: " .. tostring(defineError) end
			local loaded, kernel32 = pcall(ffi.load, "kernel32.dll")
			if not loaded then return nil, "Atomic Windows file replacement is unavailable" end
			windowsMoveFileApi = kernel32
		end
		local function toWide(path)
			local needed = windowsMoveFileApi.MultiByteToWideChar(65001, 0, path, #path, nil, 0)
			if needed <= 0 then return nil, "Could not convert a study-data path for Windows" end
			local output = ffi.new("wchar_t[?]", needed + 1)
			if windowsMoveFileApi.MultiByteToWideChar(65001, 0, path, #path, output, needed) <= 0 then
				return nil, "Could not convert a study-data path for Windows"
			end
			output[needed] = 0
			return output
		end
		local sourceWide, sourceError = toWide(sourcePath)
		local targetWide, targetError = toWide(targetPath)
		if not sourceWide or not targetWide then return nil, sourceError or targetError end
		if windowsMoveFileApi.MoveFileExW(sourceWide, targetWide, 0x1 + 0x8) == 0 then
			return nil, "Windows error " .. tostring(windowsMoveFileApi.GetLastError())
		end
		return true
	end
	local ok, err = os.rename(sourcePath, targetPath)
	if not ok then return nil, err or "rename failed" end
	return true
end

local function writeFileAtomically(path, contents, replaceFile)
	if type(path) ~= "string" or path == "" or type(contents) ~= "string" then
		return nil, "Atomic study-data replacement received invalid arguments"
	end
	replaceFile = replaceFile or replaceFileAtomically
	local tempPath
	for attempt = 1, 16 do
		sequence = sequence + 1
		local randomPart = math.random and math.random(0, 2147483647) or sequence
		local candidate = path .. ".optimizer-tmp-" .. tostring(randomPart) .. "-" .. tostring(sequence)
		if not fileExists(candidate) then tempPath = candidate break end
	end
	if not tempPath then return nil, "Could not reserve a unique temporary study-data file" end
	local file, openError = io.open(tempPath, "wb")
	if not file then return nil, "Could not create a temporary study-data file: " .. tostring(openError) end
	local written, writeError = file:write(contents)
	local flushed, flushError
	if written then flushed, flushError = file:flush() end
	local closed, closeError = file:close()
	if not written or not flushed or not closed then
		os.remove(tempPath)
		return nil, "Could not write study data safely: " .. tostring(writeError or flushError or closeError or "file operation failed")
	end
	local replaced, replaceError = replaceFile(tempPath, path)
	if not replaced then
		os.remove(tempPath)
		return nil, "Could not atomically replace local study data: " .. tostring(replaceError or "replacement failed")
	end
	return true
end

local function recordFingerprint(record)
	local encoded, encodeError = canonicalJson(record)
	if not encoded then return nil, encodeError end
	return sha.sha256(encoded)
end

local function reviewId()
	sequence = sequence + 1
	local randomPart = math.random and math.random(0, 2147483647) or sequence
	return "review-" .. os.date("!%Y%m%dT%H%M%SZ") .. "-" .. tostring(randomPart) .. "-" .. tostring(sequence)
end

local function hasScientificAttestations(attestations)
	return type(attestations) == "table"
		and attestations.exactPair == true
		and attestations.scenario == true
		and attestations.activity == true
		and attestations.lookupTables == true
end

local function hasLegacyAttestations(attestations)
	return hasScientificAttestations(attestations)
		and attestations.localTrainingConsent == true
		and attestations.sourceRightsVerified == true
end

local function hasAllAttestations(attestations, rightsEvidence)
	return hasLegacyAttestations(attestations) and normalizeRightsEvidence(rightsEvidence) ~= nil
end

local function validReviewEntry(value)
	if type(value) ~= "table" or value.recordType ~= "training_review"
		or (value.schemaVersion ~= 1 and value.schemaVersion ~= 2 and value.schemaVersion ~= REVIEW_SCHEMA_VERSION)
		or not validRecordId(value.recordId)
		or type(value.recordFingerprint) ~= "string" or not value.recordFingerprint:match("^[%da-f]+$") or #value.recordFingerprint ~= 64
		or type(value.reviewId) ~= "string" or #value.reviewId < 1 or #value.reviewId > 128
		or type(value.reviewedAt) ~= "string" or #value.reviewedAt > 32
		or (value.decision ~= "approved" and value.decision ~= "rejected")
		or value.reviewerType ~= "human_local" or type(value.attestations) ~= "table" then
		return false
	end
	if value.decision == "approved" and value.schemaVersion == 1 and not hasScientificAttestations(value.attestations) then return false end
	if value.decision == "approved" and value.schemaVersion == 2 and not hasLegacyAttestations(value.attestations) then return false end
	if value.schemaVersion ~= REVIEW_SCHEMA_VERSION and value.sourceRightsEvidence ~= nil then return false end
	if value.schemaVersion == REVIEW_SCHEMA_VERSION and value.decision ~= "approved" and value.sourceRightsEvidence ~= nil then return false end
	if value.decision == "approved" and value.schemaVersion == REVIEW_SCHEMA_VERSION
		and (not hasAllAttestations(value.attestations, value.sourceRightsEvidence)
			or value.sourceRightsEvidence.verifiedAt ~= value.reviewedAt) then return false end
	return true
end

local function missingFileError(message)
	return isMissingFileError(message)
end

local function readJsonlRows(path, maxBytes, maxLineBytes, validate, label, missingIsEmpty)
	local file, openError = io.open(path, "rb")
	if not file then
		if missingIsEmpty and missingFileError(openError) then return { } end
		return nil, "Could not read the local " .. label .. ": " .. tostring(openError)
	end
	local size = file:seek("end") or 0
	if size > maxBytes then file:close() return nil, "The local " .. label .. " exceeds its safety limit" end
	file:seek("set", 0)
	local rows, lineNumber = { }, 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if #line > maxLineBytes then
			file:close()
			return nil, "Local " .. label .. " line " .. tostring(lineNumber) .. " exceeds its safety limit"
		end
		if line == "" then
			rows[#rows + 1] = { raw = line }
		else
			local ok, value = pcall(json.decode, line)
			if not ok or not validate(value) then
				file:close()
				return nil, "Local " .. label .. " line " .. tostring(lineNumber) .. " is invalid; cleanup was refused"
			end
			rows[#rows + 1] = { raw = line, value = value }
		end
	end
	file:close()
	return rows
end

local function validStoredRecord(value)
	return type(value) == "table" and validRecordId(value.recordId)
end

local function validWithdrawal(value)
	return type(value) == "table" and value.recordType == "study_withdrawal"
		and value.schemaVersion == 1
		and type(value.recordIdHash) == "string" and #value.recordIdHash == 64
		and value.recordIdHash:match("^[%da-f]+$") ~= nil
		and (value.status == "pending" or value.status == "complete")
end

local function loadWithdrawalStates(path)
	local withdrawalPath = withdrawalPathForStore(path)
	local rows, readError = readJsonlRows(withdrawalPath, MAX_WITHDRAWAL_BYTES, MAX_WITHDRAWAL_LINE_BYTES,
		validWithdrawal, "study withdrawal ledger", true)
	if not rows then return nil, readError end
	local states = { }
	for _, row in ipairs(rows) do
		if row.value then states[row.value.recordIdHash] = row.value.status end
	end
	return states
end

local function serializeWithdrawalStates(states)
	local hashes = { }
	for recordIdHash, status in pairs(states) do
		if type(recordIdHash) ~= "string" or #recordIdHash ~= 64 or not recordIdHash:match("^[%da-f]+$")
			or (status ~= "pending" and status ~= "complete") then
			return nil, "The local study withdrawal ledger contains invalid state"
		end
		hashes[#hashes + 1] = recordIdHash
	end
	table.sort(hashes)
	local lines = { }
	for _, recordIdHash in ipairs(hashes) do
		local encoded, encodeError = json.encode({ recordType = "study_withdrawal", schemaVersion = 1,
			recordIdHash = recordIdHash, status = states[recordIdHash] })
		if type(encoded) ~= "string" or #encoded > MAX_WITHDRAWAL_LINE_BYTES then
			return nil, encodeError or "A local study withdrawal entry exceeds its safety limit"
		end
		lines[#lines + 1] = encoded
	end
	local content = #lines > 0 and table.concat(lines, "\n") .. "\n" or ""
	if #content > MAX_WITHDRAWAL_BYTES then return nil, "The local study withdrawal ledger reached its safety limit" end
	return content
end

local function writeWithdrawalStates(path, states, replaceFile)
	local content, encodeError = serializeWithdrawalStates(states)
	if not content then return nil, encodeError end
	local withdrawalPath = withdrawalPathForStore(path)
	if #content == 0 then
		if not fileExists(withdrawalPath) then return true end
		local written, writeError = writeFileAtomically(withdrawalPath, "", replaceFile)
		if not written then return nil, writeError end
		return true
	end
	return writeFileAtomically(withdrawalPath, content, replaceFile)
end

local function hasPendingWithdrawals(states)
	for _, status in pairs(states) do if status == "pending" then return true end end
	return false
end

local function markTrainingArtifactsInvalidated(storePath, replaceFile)
	local path = invalidationPathForStore(storePath)
	if not path then return nil, "Study record path is unavailable" end
	local exists, inspectError = trainingInvalidationState(storePath)
	if exists == nil then return nil, inspectError end
	if exists then return true end
	local encoded, encodeError = json.encode({ schemaVersion = 1, status = "study_withdrawal_cleanup_pending" })
	if type(encoded) ~= "string" then return nil, encodeError or "Could not encode the training invalidation marker" end
	return writeFileAtomically(path, encoded, replaceFile)
end

local function clearTrainingArtifactsInvalidated(storePath)
	local path = invalidationPathForStore(storePath)
	if not path then return nil, "Study record path is unavailable" end
	local exists, inspectError = trainingInvalidationState(storePath)
	if exists == nil then return nil, inspectError end
	if not exists then return true end
	local removed, removeError = os.remove(path)
	if removed or not fileExists(path) then return true end
	return nil, "Could not clear the study-withdrawal training block: " .. tostring(removeError or "file remains")
end

local function loadLatestReviews(path)
	local journalPath = reviewPathForStore(path)
	if not journalPath then return nil, "Study review journal path is unavailable" end
	local file, openError = io.open(journalPath, "rb")
	if not file then
		local message = tostring(openError or ""):lower()
		if message:find("no such file", 1, true) or message:find("cannot find", 1, true) then return { } end
		return nil, "Could not read the local study review journal: " .. tostring(openError)
	end
	local size = file:seek("end") or 0
	if size > MAX_REVIEW_BYTES then file:close() return nil, "The local study review journal exceeds its 8 MiB safety limit" end
	file:seek("set", 0)
	local latest, lineNumber = { }, 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if #line > MAX_REVIEW_LINE_BYTES then file:close() return nil, "Study review journal line " .. tostring(lineNumber) .. " exceeds the 4 KiB safety limit" end
		if line ~= "" then
			local ok, value = pcall(json.decode, line)
			if not ok or not validReviewEntry(value) then
				file:close()
				return nil, "Study review journal line " .. tostring(lineNumber) .. " is invalid; training remains disabled"
			end
			latest[value.recordId] = value
		end
	end
	file:close()
	return latest
end

local function applyLatestReview(record, reviews)
	local review = type(reviews) == "table" and reviews[record.recordId]
	if record.kind == "passive_factorial_interaction" or record.kind == "skill_support_factorial_interaction"
		or record.kind == "skill_skill_factorial_interaction"
		or record.kind == "passive_support_factorial_interaction"
		or record.kind == "skill_item_slot_factorial_interaction"
		or record.kind == "passive_item_slot_factorial_interaction" then
		-- The current supervised schema only models one-factor metric deltas.
		-- Even a legacy or externally injected approval must not promote a
		-- difference-in-differences record into that incompatible label space.
		record.trainingEligible = false
		record.quarantine = { status = "training_schema_unsupported", reasons = { "factorial_training_schema_unsupported" } }
		record.quarantined = true
		record.quarantineStatus = "training_schema_unsupported"
		if review then record.reviewStatus = "blocked_unsupported_schema" end
		return record
	end
	if not review then return record end
	local fingerprint = recordFingerprint(record)
	if not fingerprint or fingerprint ~= review.recordFingerprint then
		record.reviewStatus = "stale_record_changed"
		record.quarantined = true
		record.quarantineStatus = "stale_review"
		record.trainingEligible = false
		return record
	end
	record.certification = {
		reviewStatus = review.decision,
		reviewSchemaVersion = review.schemaVersion,
		reviewId = review.reviewId,
		reviewedAt = review.reviewedAt,
		reviewerType = review.reviewerType,
		attestations = review.attestations,
		sourceRights = rightsSummary(review.sourceRightsEvidence),
	}
	record.reviewStatus = review.decision
	record.reviewedAt = review.reviewedAt
	record.reviewId = review.reviewId
	if review.decision == "approved" then
		local currentReview = record.schemaVersion == TrainingData.RECORD_SCHEMA_VERSION
			and review.schemaVersion == REVIEW_SCHEMA_VERSION
			and hasAllAttestations(review.attestations, review.sourceRightsEvidence)
			and record.lineage and record.lineage.schemaVersion == 1
			and type(record.lineage.fingerprint) == "string" and #record.lineage.fingerprint == 64
			and (record.lineage.basis == "public_source_url" or record.lineage.basis == "exact_build_snapshot")
		record.trainingEligible = not not currentReview
		record.quarantine = currentReview and { status = "approved", reasons = { } }
			or { status = "review_requires_current_consent", reasons = { "lineage_consent_or_source_rights_review_required" } }
		local engine = { }
		for key, value in pairs(record.engine or { }) do engine[key] = value end
		engine.lookupTableStatus = "certified"
		record.engine = engine
		local admission = { }
		for key, value in pairs(record.admission or { }) do admission[key] = value end
		admission.scenarioConditionsCertified = true
		admission.activitySustainCertified = true
		admission.activityRatesFeasible = true
		admission.activityStatus = record.candidate and record.candidate.activitySustain and record.candidate.activitySustain.status or "pass"
		admission.lookupTablesCertified = true
		admission.trainingEligible = record.trainingEligible
		record.admission = admission
	else
		record.trainingEligible = false
		record.quarantine = { status = "rejected", reasons = { "human_review_rejected" } }
	end
	return record
end

local function loadRecordsForTraining(path)
	local invalidated, invalidationError = trainingInvalidationState(path)
	if invalidated == nil then return nil, invalidationError end
	if invalidated then
		return nil, "Training export is blocked while study withdrawal cleanup is pending"
	end
	local withdrawalStates, withdrawalError = loadWithdrawalStates(path)
	if not withdrawalStates then return nil, withdrawalError end
	local file, openError = openStore(path)
	if not file then
		if openError == "empty" then return { }, 0 end
		return nil, openError
	end
	local uniqueRecords, seen, seenIds = { }, { }, { }
	local duplicateRecords = 0
	local lineNumber = 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if #line > MAX_RECORD_BYTES then
			file:close()
			return nil, "Training export refused: study record line " .. tostring(lineNumber) .. " exceeds the 64 KiB safety limit"
		end
		if line ~= "" then
			local ok, value = pcall(json.decode, line)
			if not ok or type(value) ~= "table" or type(value.recordId) ~= "string" then
				file:close()
				return nil, "Training export refused: study record line " .. tostring(lineNumber) .. " is not a valid local record"
			end
			if not validRecordId(value.recordId) then
				file:close()
				return nil, "Training export refused: study record ID is invalid"
			end
			if not withdrawalStates[sha.sha256(value.recordId)] then
				local identity = experimentIdentity(value)
				local priorId = seenIds[value.recordId]
				if priorId and priorId ~= identity then
					file:close()
					return nil, "Training export refused: a local record ID has conflicting contents"
				end
				seenIds[value.recordId] = identity
				local index = identity and seen[identity]
				if index then
					duplicateRecords = duplicateRecords + 1
					uniqueRecords[index] = value -- retain the latest exact semantic observation
				else
					uniqueRecords[#uniqueRecords + 1] = value
					if identity then seen[identity] = #uniqueRecords end
				end
			end
		end
	end
	file:close()
	local reviews, reviewError = loadLatestReviews(path)
	if not reviews then return nil, reviewError end
	for _, record in ipairs(uniqueRecords) do applyLatestReview(record, reviews) end
	return uniqueRecords, duplicateRecords
end

local function fileExists(path)
	local file = io.open(path, "rb")
	if not file then return false end
	file:close()
	return true
end

local function safeVersion(value)
	local result = tostring(value or "unknown"):gsub("[^%w%-]", "-"):sub(1, 32)
	if result == "" then return "unknown" end
	return result
end

local function writeDataset(directory, dataset)
	local encoded, metadataOrError = TrainingData.EncodeJsonl(dataset)
	if not encoded then return nil, metadataOrError end
	local engine = dataset.rows[1].engine
	local filename, tempPath
	for attempt = 1, 16 do
		sequence = sequence + 1
		local randomPart = math.random and math.random(0, 2147483647) or sequence
		filename = table.concat({
			"optimizer-training-v" .. tostring(metadataOrError.datasetSchemaVersion),
			safeVersion(engine.pobVersion), safeVersion(engine.dataVersion), safeVersion(engine.treeVersion),
			os.date("!%Y%m%dT%H%M%SZ"), tostring(randomPart), tostring(sequence),
		}, "-") .. ".jsonl"
		local separator = package.config and package.config:sub(1, 1) or "\\"
		local outputPath = joinPath(directory, filename, separator)
		tempPath = joinPath(directory, "." .. filename .. ".tmp", separator)
		if not fileExists(outputPath) and not fileExists(tempPath) then break end
		filename, tempPath = nil, nil
	end
	if not filename or not tempPath then return nil, "Training export could not reserve a unique local filename" end
	local file, openError = io.open(tempPath, "wb")
	if not file then return nil, "Training export could not create its temporary file: " .. tostring(openError) end
	local written, writeError = file:write(encoded)
	local flushed, flushError = file:flush()
	local closed, closeError = file:close()
	if not written or not flushed or not closed then
		os.remove(tempPath)
		return nil, "Training export write failed: " .. tostring(writeError or flushError or closeError or "unknown file error")
	end
	local separator = package.config and package.config:sub(1, 1) or "\\"
	local outputPath = joinPath(directory, filename, separator)
	local renamed, renameError = os.rename(tempPath, outputPath)
	if not renamed then
		os.remove(tempPath)
		return nil, "Training export could not finalize its local file: " .. tostring(renameError or "rename failed")
	end
	return {
		path = STORE_FOLDER .. "/TrainingDatasets/" .. filename,
		bytes = metadataOrError.bytes,
		rows = metadataOrError.rows,
		trainingRows = metadataOrError.trainingRows,
		holdoutRows = metadataOrError.holdoutRows,
		sourceLineages = metadataOrError.sourceLineages,
		trainingSourceLineages = metadataOrError.trainingSourceLineages,
		holdoutSourceLineages = metadataOrError.holdoutSourceLineages,
		datasetSchemaVersion = metadataOrError.datasetSchemaVersion,
		featurePolicy = metadataOrError.featurePolicy,
		groupingPolicy = metadataOrError.groupingPolicy,
	}
end

local function readRawRecordById(path, recordId)
	if not validRecordId(recordId) then
		return nil, "recordId is not a valid local study record ID"
	end
	local file, openError = openStore(path)
	if not file then
		if openError == "empty" then return nil, "No local study records have been saved" end
		return nil, openError
	end
	local found
	for line in file:lines() do
		if #line <= MAX_RECORD_BYTES then
			local ok, value = pcall(json.decode, line)
			if not ok then value = nil end
			if type(value) == "table" and value.recordId == recordId then found = value end
		end
	end
	file:close()
	if not found then return nil, "Local study record was not found" end
	return found
end

function records.ReadById(path, recordId, currentDataVersion, currentTreeVersion, currentPobVersion, currentPobBranch, currentManifestFingerprint)
	if not validRecordId(recordId) then return nil, "recordId is not a valid local study record ID" end
	local withdrawalStates, withdrawalError = loadWithdrawalStates(path)
	if not withdrawalStates then return nil, withdrawalError end
	if withdrawalStates[sha.sha256(recordId)] then return nil, "Local study record has been withdrawn or deleted" end
	local found, readError = readRawRecordById(path, recordId)
	if not found then return nil, readError end
	local reviews, reviewError = loadLatestReviews(path)
	if not reviews then return nil, reviewError end
	applyLatestReview(found, reviews)
	local expectedEngine = { dataVersion = currentDataVersion, treeVersion = currentTreeVersion,
		pobVersion = currentPobVersion, pobBranch = currentPobBranch, manifestFingerprint = currentManifestFingerprint }
	found.versionStatus, found.quarantined = currentVersionStatus(found, expectedEngine)
	found.quarantined = found.versionStatus ~= "current" or found.trainingEligible ~= true
	if found.versionStatus ~= "current" then
		found.quarantineStatus = found.versionStatus
	elseif found.reviewStatus == "stale_record_changed" then
		found.quarantineStatus = "stale_review"
	else
		found.quarantineStatus = found.quarantine and found.quarantine.status or "pending_review"
	end
	found.reviewStatus = found.reviewStatus or "pending_review"
	found.reviewAssessment = TrainingData.AssessReview(found, {
		dataVersion = currentDataVersion,
		treeVersion = currentTreeVersion,
		pobVersion = currentPobVersion,
		pobBranch = currentPobBranch,
		manifestFingerprint = currentManifestFingerprint,
	})
	return found
end

local MANAGED_TRAINING_DIRECTORIES = { "OptimizerStudies/TrainingDatasets", "OptimizerModels" }

function records.PurgeDerivedTrainingArtifacts(clearDirectory)
	if type(clearDirectory) ~= "function" then
		return nil, "The managed training-artifact cleaner is unavailable", { }
	end
	local cleared = { }
	for _, relativePath in ipairs(MANAGED_TRAINING_DIRECTORIES) do
		local callOk, removed, removeError = pcall(clearDirectory, relativePath)
		if not callOk or removed ~= true then
			return nil, "Could not invalidate managed training artifact directory " .. relativePath .. ": "
				.. tostring(callOk and removeError or removed or "cleanup failed"), cleared
		end
		cleared[#cleared + 1] = relativePath
	end
	return true, nil, cleared
end

local function rewriteJsonlRows(path, rows, keepRow, replaceFile)
	local output = { }
	local removed = 0
	for _, row in ipairs(rows) do
		if row.value and not keepRow(row.value) then
			removed = removed + 1
		else
			output[#output + 1] = row.raw
		end
	end
	if removed == 0 then return true, 0 end
	local contents = #output > 0 and table.concat(output, "\n") .. "\n" or ""
	local written, writeError = writeFileAtomically(path, contents, replaceFile)
	if not written then return nil, writeError, removed end
	return true, removed
end

local function readMutationRows(path)
	local storeRows, storeError = readJsonlRows(path, MAX_STORE_BYTES, MAX_RECORD_BYTES,
		validStoredRecord, "study record store", true)
	if not storeRows then return nil, nil, storeError end
	local reviewPath = reviewPathForStore(path)
	if not reviewPath then return nil, nil, "Study review journal path is unavailable" end
	local reviewRows, reviewError = readJsonlRows(reviewPath, MAX_REVIEW_BYTES, MAX_REVIEW_LINE_BYTES,
		validReviewEntry, "study review journal", true)
	if not reviewRows then return nil, nil, reviewError end
	return storeRows, reviewRows
end

local function setPendingWithdrawal(path, userPath, recordIds, states, replaceFile)
	local unique = { }
	for _, recordId in ipairs(recordIds) do
		if validRecordId(recordId) then
			local recordIdHash = sha.sha256(recordId)
			states[recordIdHash] = "pending"
			unique[recordIdHash] = true
		end
	end
	local marked, markerError = markTrainingArtifactsInvalidated(path, replaceFile)
	if not marked then return nil, markerError end
	local stored, storeError = writeWithdrawalStates(path, states, replaceFile)
	if not stored then return nil, "Training is blocked, but the withdrawal ledger could not be written: " .. tostring(storeError) end
	return unique
end

local function finishPendingWithdrawals(path, userPath, states, pendingHashes, storeRows, reviewRows, replaceFile)
	local reviewPath = reviewPathForStore(path)
	local function pendingRecord(recordId)
		return validRecordId(recordId) and pendingHashes[sha.sha256(recordId)] == true
	end
	local reviewsWritten, removedReviews = rewriteJsonlRows(reviewPath, reviewRows, function(value)
		return not pendingRecord(value.recordId)
	end, replaceFile)
	if not reviewsWritten then
		return { status = "cleanup_pending", deleted = false, sourceRecordsHidden = true,
			derivedArtifactsPurged = true, trainingBlocked = true, removedReviewEntries = removedReviews or 0,
			message = "The withdrawal is recorded and training is blocked, but the local review journal could not be rewritten. Retry cleanup." }
	end
	local storeWritten, removedRecords = rewriteJsonlRows(path, storeRows, function(value)
		return not pendingRecord(value.recordId)
	end, replaceFile)
	if not storeWritten then
		return { status = "cleanup_pending", deleted = false, sourceRecordsHidden = true,
			derivedArtifactsPurged = true, trainingBlocked = true, removedReviewEntries = removedReviews,
			message = "The withdrawal is recorded and the review was removed, but the source record store could not be rewritten. The record remains blocked from reading and training; retry cleanup." }
	end
	for recordIdHash in pairs(pendingHashes) do states[recordIdHash] = "complete" end
	local stored, ledgerError = writeWithdrawalStates(path, states, replaceFile)
	if not stored then
		return { status = "cleanup_pending", deleted = true, sourceRecordsHidden = true,
			derivedArtifactsPurged = true, trainingBlocked = true, removedRecords = removedRecords,
			removedReviewEntries = removedReviews,
			message = "Source data and managed exports were removed, but the local withdrawal ledger could not be finalized: " .. tostring(ledgerError) }
	end
	if not hasPendingWithdrawals(states) then
		local cleared, clearError = clearTrainingArtifactsInvalidated(path)
		if not cleared then
			return { status = "cleanup_pending", deleted = true, sourceRecordsHidden = true,
				derivedArtifactsPurged = true, trainingBlocked = true, removedRecords = removedRecords,
				removedReviewEntries = removedReviews, message = tostring(clearError) }
		end
	end
	return { status = "deleted", deleted = removedRecords > 0, sourceRecordsHidden = true,
		derivedArtifactsPurged = true, trainingBlocked = hasPendingWithdrawals(states),
		removedRecords = removedRecords, removedReviewEntries = removedReviews,
		message = "The requested study data and managed derived training artifacts were removed." }
end

local function completeWithdrawals(path, recordIds, clearDirectory, replaceFile)
	local storeRows, reviewRows, rowsError = readMutationRows(path)
	if not storeRows then return nil, rowsError end
	local states, statesError = loadWithdrawalStates(path)
	if not states then return nil, statesError end
	local pendingHashes, markError = setPendingWithdrawal(path, nil, recordIds, states, replaceFile)
	if not pendingHashes then
		local markerPresent = trainingInvalidationState(path)
		return { status = "cleanup_pending", deleted = false, sourceRecordsHidden = false,
			trainingBlocked = markerPresent ~= false, message = tostring(markError) }
	end
	for recordIdHash, status in pairs(states) do
		if status == "pending" or status == "complete" then pendingHashes[recordIdHash] = true end
	end
	local cleared, purgeError, clearedPaths = records.PurgeDerivedTrainingArtifacts(clearDirectory)
	if not cleared then
		return { status = "cleanup_pending", deleted = false, sourceRecordsHidden = true,
			derivedArtifactsPurged = false, trainingBlocked = true, clearedArtifactDirectories = clearedPaths,
			message = "Training is blocked and withdrawn rows are hidden, but managed derived artifacts remain: " .. tostring(purgeError) }
	end
	return finishPendingWithdrawals(path, nil, states, pendingHashes, storeRows, reviewRows, replaceFile)
end

local function isValidUtcTimestamp(timestamp)
	if type(timestamp) ~= "string" then return false end
	local year, month, day, hour, minute, second = timestamp:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
	if not year then return false end
	year, month, day = tonumber(year), tonumber(month), tonumber(day)
	hour, minute, second = tonumber(hour), tonumber(minute), tonumber(second)
	if month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59 then return false end
	local daysInMonth = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
	if year % 400 == 0 or (year % 4 == 0 and year % 100 ~= 0) then daysInMonth[2] = 29 end
	return day >= 1 and day <= daysInMonth[month]
end

function records.DeleteById(path, recordId, clearDirectory, replaceFile)
	if type(path) ~= "string" or path == "" then return nil, "Study record path is unavailable" end
	if not validRecordId(recordId) then return nil, "recordId is not a valid local study record ID" end
	local storeRows, reviewRows, rowsError = readMutationRows(path)
	if not storeRows then return nil, rowsError end
	local states, statesError = loadWithdrawalStates(path)
	if not states then return nil, statesError end
	local recordIdHash = sha.sha256(recordId)
	local recordPresent = false
	for _, row in ipairs(storeRows) do
		if row.value and row.value.recordId == recordId then recordPresent = true break end
	end
	local markerExists, markerError = trainingInvalidationState(path)
	if markerExists == nil then return nil, markerError end
	if not recordPresent and not markerExists and not hasPendingWithdrawals(states) then
		if states[recordIdHash] == "complete" then
			return { status = "already_deleted", deleted = false, sourceRecordsHidden = true,
				derivedArtifactsPurged = true, trainingBlocked = false, removedRecords = 0, removedReviewEntries = 0,
				message = "This study record was already deleted." }
		end
		return nil, "Local study record was not found"
	end
	local ids = { }
	if recordPresent or states[recordIdHash] == "pending" then ids[1] = recordId end
	return completeWithdrawals(path, ids, clearDirectory, replaceFile)
end

function records.PruneOlderThan(path, olderThanDays, clearDirectory, replaceFile)
	if type(path) ~= "string" or path == "" then return nil, "Study record path is unavailable" end
	if not isFinite(olderThanDays) or olderThanDays ~= math.floor(olderThanDays) or olderThanDays < 1 or olderThanDays > 3650 then
		return nil, "olderThanDays must be an integer from 1 to 3650"
	end
	local storeRows, reviewRows, rowsError = readMutationRows(path)
	if not storeRows then return nil, rowsError end
	local states, statesError = loadWithdrawalStates(path)
	if not states then return nil, statesError end
	local cutoff = os.date("!%Y-%m-%dT%H:%M:%SZ", os.time() - olderThanDays * 86400)
	local ids, seen = { }, { }
	for _, row in ipairs(storeRows) do
		local value = row.value
		local timestamp = type(value) == "table" and value.recordedAt
		if isValidUtcTimestamp(timestamp)
			and timestamp < cutoff and not seen[value.recordId] then
			ids[#ids + 1] = value.recordId
			seen[value.recordId] = true
		end
	end
	local hasPending = hasPendingWithdrawals(states)
	local markerExists, markerError = trainingInvalidationState(path)
	if markerExists == nil then return nil, markerError end
	if #ids == 0 and not hasPending and not markerExists then
		return { status = "no_records_to_prune", prunedRecords = 0, cutoff = cutoff,
			preservedUndatedRecords = true, derivedArtifactsPurged = false, trainingBlocked = false }
	end
	local result, resultError = completeWithdrawals(path, ids, clearDirectory, replaceFile)
	if not result then return nil, resultError end
	result.prunedRecords = result.removedRecords or 0
	result.cutoff = cutoff
	result.olderThanDays = olderThanDays
	result.preservedUndatedRecords = true
	return result
end

function records.AssessForReview(record, expectedEngine)
	return TrainingData.AssessReview(record, expectedEngine)
end

function records.ReviewToPath(path, recordId, decision, attestations, expectedEngine, createDirectory)
	if not validRecordId(recordId) then return nil, "recordId is not a valid local study record ID" end
	if decision ~= "approved" and decision ~= "rejected" then return nil, "decision must be approved or rejected" end
	if type(expectedEngine) ~= "table" then return nil, "Current PoB engine identity is required for study review" end
	local withdrawalStates, withdrawalError = loadWithdrawalStates(path)
	if not withdrawalStates then return nil, withdrawalError end
	if withdrawalStates[sha.sha256(recordId)] then return nil, "A withdrawn or deleted study record cannot be reviewed" end
	local record, readError = readRawRecordById(path, recordId)
	if not record then return nil, readError end
	local reviewPath = reviewPathForStore(path)
	if not reviewPath then return nil, "Study review journal path is unavailable" end
	local sourceRightsEvidence
	if decision == "approved" then
		if not hasLegacyAttestations(attestations) then
			return nil, "Approval requires local review, explicit local-training consent, and verified source-use rights"
		end
		local rightsError
		sourceRightsEvidence, rightsError = normalizeRightsEvidence(attestations.sourceRightsEvidence)
		if not sourceRightsEvidence then return nil, rightsError end
		local assessment = TrainingData.AssessReview(record, expectedEngine)
		if not assessment.canApprove then
			return nil, "Study record is not ready for human review: " .. table.concat(assessment.blockers, ", ")
		end
	end
	local directory = path:match("^(.*)[/\\][^/\\]+$")
	if directory and type(createDirectory) == "function" then
		local separator = package.config and package.config:sub(1, 1) or "\\"
		local callOk, created, createError = pcall(createDirectory, directory .. separator)
		if not callOk then return nil, "Could not create the local study review directory: " .. tostring(created) end
		if not created and createError ~= "No error" then
			return nil, "Could not create the local study review directory: " .. tostring(createError or "unknown error")
		end
	end
	local fingerprint, fingerprintError = recordFingerprint(record)
	if not fingerprint then return nil, fingerprintError or "Could not fingerprint the exact study record" end
	local reviews, reviewError = loadLatestReviews(path)
	if not reviews then return nil, reviewError end
	local prior = reviews[recordId]
	local sameRights = decision ~= "approved"
	if decision == "approved" and prior and prior.sourceRightsEvidence and sourceRightsEvidence then
		local priorRights = normalizeRightsEvidence(prior.sourceRightsEvidence)
		local priorKey = priorRights and canonicalJson(priorRights)
		local currentKey = canonicalJson(sourceRightsEvidence)
		sameRights = priorKey ~= nil and priorKey == currentKey
	end
	if prior and prior.schemaVersion == REVIEW_SCHEMA_VERSION and prior.recordFingerprint == fingerprint and prior.decision == decision
		and (decision ~= "approved" or (hasAllAttestations(attestations, sourceRightsEvidence) and sameRights)) then
		return { recordId = recordId, reviewId = prior.reviewId, decision = prior.decision, duplicate = true,
			storeFile = STORE_FOLDER .. "/" .. REVIEW_FILE }
	end
	local reviewedAt = os.date("!%Y-%m-%dT%H:%M:%SZ")
	if sourceRightsEvidence then sourceRightsEvidence.verifiedAt = reviewedAt end
	local entry = {
		recordType = "training_review",
		schemaVersion = REVIEW_SCHEMA_VERSION,
		recordId = recordId,
		recordFingerprint = fingerprint,
		reviewId = reviewId(),
		reviewedAt = reviewedAt,
		decision = decision,
		reviewerType = "human_local",
		attestations = {
			exactPair = attestations and attestations.exactPair == true or false,
			scenario = attestations and attestations.scenario == true or false,
			activity = attestations and attestations.activity == true or false,
			lookupTables = attestations and attestations.lookupTables == true or false,
			localTrainingConsent = attestations and attestations.localTrainingConsent == true or false,
			sourceRightsVerified = attestations and attestations.sourceRightsVerified == true or false,
		},
		sourceRightsEvidence = sourceRightsEvidence,
	}
	local encoded, encodeError = json.encode(entry)
	if type(encoded) ~= "string" or #encoded > MAX_REVIEW_LINE_BYTES then
		return nil, encodeError or "The study review entry exceeds the 4 KiB safety limit"
	end
	local file, openError = io.open(reviewPath, "ab")
	if not file then return nil, "Could not open the local study review journal: " .. tostring(openError) end
	local size = file:seek("end") or 0
	if size + #encoded + 1 > MAX_REVIEW_BYTES then
		file:close()
		return nil, "The local study review journal reached its 8 MiB limit"
	end
	local written, writeError = file:write(encoded, "\n")
	if written then
		local flushed, flushError = file:flush()
		if not flushed then writeError = flushError end
	end
	file:close()
	if not written or writeError then return nil, "Could not append the local study review: " .. tostring(writeError or "write failed") end
	return { recordId = recordId, reviewId = entry.reviewId, decision = decision, duplicate = false,
		storeFile = STORE_FOLDER .. "/" .. REVIEW_FILE, storedBytes = #encoded + 1 }
end

local function summaryOf(record, expectedEngine)
	local versionStatus, quarantined = currentVersionStatus(record, expectedEngine)
	local source = record.source or { }
	local experiment = record.experiment or { }
	local before, after = experiment.before, experiment.after
	if experiment.unit == "one_item_slot" then
		local function itemSummary(item)
			if type(item) ~= "table" then return nil end
			-- Keep full PoB item text in get_study_record only; summaries should
			-- remain small enough to list many experiments in one MCP response.
			return { itemId = item.itemId, name = item.name, base = item.base, rarity = item.rarity }
		end
		before, after = itemSummary(before), itemSummary(after)
	end
	local experimentSummary = {
		slot = experiment.slot,
		unit = experiment.unit,
		changedParameter = experiment.changedParameter,
		before = before,
		after = after,
	}
	local factorial = record.factorial
	local factorialSummary = type(factorial) == "table" and {
		formula = factorial.formula,
		factorANodeId = experiment.factorA and experiment.factorA.nodeId,
		factorBNodeId = experiment.factorB and experiment.factorB.nodeId,
		factorA = experiment.factorA,
		factorB = experiment.factorB,
		socketStatus = experiment.socketStatus,
		metricCount = factorial.metricCount,
	} or nil
	local baseline = record.baseline or { }
	local candidate = record.candidate or { }
	return {
		recordId = record.recordId,
		recordedAt = record.recordedAt,
		kind = record.kind,
		label = record.label,
		sourceType = source.type,
		provider = source.provider,
		sourceUrlRedacted = type(source.sourceUrl) == "string" and source.sourceUrl ~= "",
		dataVersion = record.engine and record.engine.dataVersion,
		treeVersion = record.engine and record.engine.treeVersion,
		class = record.buildState and record.buildState.class and record.buildState.class.class,
		mainSkill = record.buildState and record.buildState.mainSkill,
		addedNodeIds = experiment.addedNodeIds,
		removedNodeIds = experiment.removedNodeIds,
		experiment = experimentSummary,
		factorial = factorialSummary,
		baselineMetrics = baseline.metrics,
		candidateMetrics = candidate.metrics,
		metricDelta = record.metricDelta,
		useRequirementsFeasible = record.admission and record.admission.useRequirementsFeasible,
		activityStatus = record.admission and record.admission.activityStatus,
		reviewStatus = record.reviewStatus or "pending_review",
		reviewedAt = record.reviewedAt,
		trainingEligible = record.trainingEligible == true,
		versionStatus = versionStatus,
		quarantined = quarantined or record.trainingEligible ~= true,
	}
end

local function coverageSkillName(value)
	return type(value) == "string" and #value > 0 and #value <= 120 and not value:find("[%c]") and value or nil
end

local function coverageFamily(kind)
	if kind == "passive_node_pair" then return "passiveNodePairs" end
	if kind == "gem_variant_pair" then return "gemVariantPairs" end
	if kind == "mastery_effect_pair" then return "masteryEffectPairs" end
	if kind == "item_slot_pair" then return "itemSlotPairs" end
	if kind == "passive_factorial_interaction" then return "passiveFactorialInteractions" end
	if kind == "skill_support_factorial_interaction" then return "skillSupportFactorialInteractions" end
	if kind == "skill_skill_factorial_interaction" then return "skillSkillFactorialInteractions" end
	if kind == "passive_support_factorial_interaction" then return "passiveSupportFactorialInteractions" end
	if kind == "skill_item_slot_factorial_interaction" then return "skillItemFactorialInteractions" end
	if kind == "passive_item_slot_factorial_interaction" then return "passiveItemFactorialInteractions" end
	if type(kind) == "string" and kind:find("factorial", 1, true) then return "otherFactorialInteractions" end
	return "otherExactPairs"
end

local function addHashedIdentity(set, value)
	if type(value) ~= "table" then return end
	local encoded = canonicalJson(value)
	if encoded then set[sha.sha256(encoded)] = true end
end

local function uniqueCount(set)
	local count = 0
	for _ in pairs(set) do count = count + 1 end
	return count
end

local function hasNumericMetric(metrics)
	if type(metrics) ~= "table" then return false end
	for _, value in pairs(metrics) do
		if isFinite(value) then return true end
	end
	return false
end

local function summarizeLearningCoverage(recordsToSummarize, expectedEngine, duplicateRecordsSuppressed, trainingReadiness)
	local familyCounts = {
		passiveNodePairs = 0,
		gemVariantPairs = 0,
		masteryEffectPairs = 0,
		itemSlotPairs = 0,
		passiveFactorialInteractions = 0,
		skillSupportFactorialInteractions = 0,
		skillSkillFactorialInteractions = 0,
		passiveSupportFactorialInteractions = 0,
		skillItemFactorialInteractions = 0,
		passiveItemFactorialInteractions = 0,
		otherFactorialInteractions = 0,
		otherExactPairs = 0,
	}
	local versionCounts = { current = 0, mismatch = 0, unverified = 0 }
	local reviewCounts = { pending = 0, approved = 0, rejected = 0 }
	local classes, skillContexts, sourceBuildStates, scenarioContexts = { }, { }, { }, { }
	local exactPairRows, unverifiedPairRows, unscopedSkillRows = 0, 0, 0
	local requiredEngineKeys = ENGINE_IDENTITY_KEYS

	for _, record in ipairs(recordsToSummarize or { }) do
		local family = coverageFamily(record.kind)
		if type(record.admission) == "table" and record.admission.exactCalculated == true
			and type(record.baseline) == "table" and hasNumericMetric(record.baseline.metrics)
			and type(record.candidate) == "table" and hasNumericMetric(record.candidate.metrics) then
			exactPairRows = exactPairRows + 1
			familyCounts[family] = familyCounts[family] + 1
		else
			unverifiedPairRows = unverifiedPairRows + 1
		end

		local engine = type(record.engine) == "table" and record.engine or { }
		local completeEngine, currentEngineComplete, matchesExpected = true, true, true
		for _, key in ipairs(requiredEngineKeys) do
			if type(engine[key]) ~= "string" or engine[key] == "" then completeEngine = false end
			if not expectedEngine or type(expectedEngine[key]) ~= "string" or expectedEngine[key] == "" then
				currentEngineComplete, matchesExpected = false, false
			elseif tostring(engine[key] or "") ~= tostring(expectedEngine[key]) then
				matchesExpected = false
			end
		end
		if not completeEngine or not currentEngineComplete then
			versionCounts.unverified = versionCounts.unverified + 1
		elseif matchesExpected then
			versionCounts.current = versionCounts.current + 1
		else
			versionCounts.mismatch = versionCounts.mismatch + 1
		end

		local reviewStatus = record.reviewStatus == "approved" and "approved"
			or record.reviewStatus == "rejected" and "rejected" or "pending"
		reviewCounts[reviewStatus] = reviewCounts[reviewStatus] + 1

		local state = type(record.buildState) == "table" and record.buildState or { }
		local class = type(state.class) == "table" and state.class.class or state.class
		if type(class) == "string" and COVERAGE_CLASS_SET[class] then classes[class] = true end
		local mainSkill = coverageSkillName(state.mainSkill)
		if mainSkill then
			local classKey = type(class) == "string" and COVERAGE_CLASS_SET[class] and class or "unclassified"
			local skillIdentity = { class = classKey, mainSkill = mainSkill,
				dataVersion = engine.dataVersion, treeVersion = engine.treeVersion, skillGroups = state.skillGroups }
			addHashedIdentity(skillContexts, skillIdentity)
		else
			unscopedSkillRows = unscopedSkillRows + 1
		end
		addHashedIdentity(sourceBuildStates, { engine = engine, buildState = state })
		if type(state.configuration) == "table" then
			addHashedIdentity(scenarioContexts, { engine = engine, configuration = state.configuration })
		end
	end

	local currentRecords = versionCounts.current
	local nextStudyFocus
	if exactPairRows == 0 or currentRecords == 0 then
		nextStudyFocus = "capture_current_version_exact_pairs"
	elseif familyCounts.gemVariantPairs == 0 then
		nextStudyFocus = "collect_controlled_gem_and_support_variants"
	elseif familyCounts.passiveNodePairs == 0 then
		nextStudyFocus = "collect_exact_passive_node_deltas"
	elseif familyCounts.itemSlotPairs == 0 then
		nextStudyFocus = "collect_existing_item_slot_ab_tests"
	elseif familyCounts.skillSupportFactorialInteractions == 0 then
		nextStudyFocus = "test_selected_skill_support_interactions_after_one_factor_baselines"
	elseif familyCounts.passiveItemFactorialInteractions == 0 then
		nextStudyFocus = "collect_exact_passive_item_slot_interactions"
	elseif familyCounts.passiveSupportFactorialInteractions == 0 then
		nextStudyFocus = "measure_passive_support_synergy_after_passive_baselines"
	elseif trainingReadiness and trainingReadiness.status ~= "dataset_ready_for_offline_evaluation" then
		nextStudyFocus = "add_independently_reviewed_rows_from_distinct_build_states"
	else
		nextStudyFocus = "compare_surrogate_with_deterministic_search_on_held_out_builds"
	end

	return {
		schemaVersion = 1,
		status = exactPairRows == 0 and "no_exact_pairs" or "observations_only",
		uniqueRecords = #(recordsToSummarize or { }),
		duplicateRecordsSuppressed = duplicateRecordsSuppressed or 0,
		exactPairRows = exactPairRows,
		unverifiedPairRows = unverifiedPairRows,
		-- These counts are observational context diversity only. TrainingData owns
		-- the stricter certification and source-build holdout grouping contract.
		versionRows = versionCounts,
		reviewRows = reviewCounts,
		experimentFamilies = familyCounts,
		contextDiversity = {
			sourceBuildStatesObserved = uniqueCount(sourceBuildStates),
			classStartsObserved = uniqueCount(classes),
			mainSkillContextsObserved = uniqueCount(skillContexts),
			scenarioContextsObserved = uniqueCount(scenarioContexts),
			unscopedSkillRows = unscopedSkillRows,
		},
		combinationCoverage = "not_measured",
		graphRole = "report_only",
		modelTrainingEnabled = false,
		nextStudyFocus = nextStudyFocus,
	}
end

function records.List(path, limit, currentDataVersion, currentTreeVersion, currentPobVersion, currentPobBranch, currentManifestFingerprint)
	local expectedEngine = {
		dataVersion = currentDataVersion,
		treeVersion = currentTreeVersion,
		pobVersion = currentPobVersion,
		pobBranch = currentPobBranch,
		manifestFingerprint = currentManifestFingerprint,
	}
	limit = tonumber(limit) or 10
	if not isFinite(limit) or limit ~= math.floor(limit) or limit < 1 or limit > MAX_LIST_LIMIT then
		return nil, "limit must be an integer between 1 and 25"
	end
	local withdrawalStates, withdrawalError = loadWithdrawalStates(path)
	if not withdrawalStates then return nil, withdrawalError end
	local withdrawalCleanupPending, markerError = trainingInvalidationState(path)
	if withdrawalCleanupPending == nil then return nil, markerError end
	local file, openError = openStore(path)
	if not file then
		if openError == "empty" then
			local readiness = TrainingData.Prepare({ }, expectedEngine)
			local trainingReadiness = TrainingData.Summary(readiness)
			trainingReadiness.withdrawalCleanupPending = withdrawalCleanupPending
			return { records = { }, totalRecords = 0, trainingEligible = 0, trainingReadiness = trainingReadiness,
			withdrawalCleanupPending = withdrawalCleanupPending,
			trainingExportBlocked = withdrawalCleanupPending,
			learningCoverage = summarizeLearningCoverage({ }, expectedEngine, 0, trainingReadiness) }
		end
		return nil, openError
	end
	local summaries, uniqueRecords, seen = { }, { }, { }
	local count, duplicateRecords = 0, 0
	for line in file:lines() do
		if #line <= MAX_RECORD_BYTES then
			local ok, value = pcall(json.decode, line)
			if not ok then value = nil end
			if type(value) == "table" and validRecordId(value.recordId)
				and not withdrawalStates[sha.sha256(value.recordId)] then
				local identity = experimentIdentity(value)
				local index = identity and seen[identity]
				if index then
					duplicateRecords = duplicateRecords + 1
					uniqueRecords[index] = value -- retain the most recent exact observation
				else
					uniqueRecords[#uniqueRecords + 1] = value
					if identity then seen[identity] = #uniqueRecords end
				end
			end
		end
	end
	file:close()
	local reviews, reviewError = loadLatestReviews(path)
	if not reviews then return nil, reviewError end
	for _, value in ipairs(uniqueRecords) do applyLatestReview(value, reviews) end
	count = #uniqueRecords
	for index = math.max(1, count - limit + 1), count do
		local value = uniqueRecords[index]
		summaries[#summaries + 1] = summaryOf(value, expectedEngine)
	end
	local trainingDataset = TrainingData.Prepare(uniqueRecords, expectedEngine)
	local trainingReadiness = TrainingData.Summary(trainingDataset)
	trainingReadiness.withdrawalCleanupPending = withdrawalCleanupPending
	return { records = summaries, totalRecords = count, trainingEligible = trainingDataset.eligibleRows,
		trainingReadiness = trainingReadiness, duplicateRecordsSuppressed = duplicateRecords, returned = #summaries,
		withdrawalCleanupPending = withdrawalCleanupPending,
		trainingExportBlocked = withdrawalCleanupPending,
		learningCoverage = summarizeLearningCoverage(uniqueRecords, expectedEngine, duplicateRecords, trainingReadiness) }
end

function records.ExportTrainingDataset(userPath, expectedEngine, createDirectory)
	local storePath, storeDirectoryOrError = records.GetStorePath(userPath)
	if not storePath then return nil, storeDirectoryOrError end
	local invalidated, invalidationError = trainingInvalidationState(storePath)
	if invalidated == nil then return nil, invalidationError end
	if invalidated then
		return { exported = false, status = "withdrawal_cleanup_pending", trainingBlocked = true,
			message = "No dataset exported: a study withdrawal is pending cleanup of managed datasets and the active model" }
	end
	local datasetRecords, duplicateRecordsOrError = loadRecordsForTraining(storePath)
	if not datasetRecords then return nil, duplicateRecordsOrError end
	local dataset = TrainingData.Prepare(datasetRecords, expectedEngine)
	local readiness = TrainingData.Summary(dataset)
	if dataset.status ~= "dataset_ready_for_offline_evaluation" or dataset.trainingRows < 1 or dataset.holdoutRows < 1 then
		return {
			exported = false,
			status = dataset.status,
			readiness = readiness,
			duplicateRecordsSuppressed = duplicateRecordsOrError,
		message = "No dataset exported: supervised rows lack consent, current certification, or two disjoint origin/snapshot groups",
		}
	end
	if type(createDirectory) ~= "function" then return nil, "PoB's native directory creator is unavailable" end
	local separator = package.config and package.config:sub(1, 1) or "\\"
	local exportDirectory = joinPath(storeDirectoryOrError, "TrainingDatasets", separator)
	local callOk, created, createError = pcall(createDirectory, exportDirectory .. separator)
	if not callOk then return nil, "Could not create the local training export directory: " .. tostring(created) end
	if not created and createError ~= "No error" then
		return nil, "Could not create the local training export directory: " .. tostring(createError or "unknown error")
	end
	local exported, exportError = writeDataset(exportDirectory, dataset)
	if not exported then return nil, exportError end
	exported.exported = true
	exported.status = "exported"
	exported.readiness = readiness
	exported.duplicateRecordsSuppressed = duplicateRecordsOrError
	return exported
end

function records.RedactForAI(record)
	if type(record) ~= "table" then return nil end
	local result = { }
	for key, value in pairs(record) do
		if key ~= "source" and key ~= "lineage" then result[key] = value end
	end
	local source = type(record.source) == "table" and record.source or { }
	result.source = {
		type = source.type,
		provider = source.provider,
		sourceUrlRedacted = type(source.sourceUrl) == "string" and source.sourceUrl ~= "",
	}
	local lineage = type(record.lineage) == "table" and record.lineage or { }
	result.lineage = {
		verified = lineage.schemaVersion == 1 and type(lineage.fingerprint) == "string"
			and #lineage.fingerprint == 64 and lineage.fingerprint:match("^[%da-f]+$") ~= nil,
		basis = lineage.basis,
	}
	return result
end

records.MAX_RECORD_BYTES = MAX_RECORD_BYTES
records.MAX_STORE_BYTES = MAX_STORE_BYTES
records.MAX_LIST_LIMIT = MAX_LIST_LIMIT

return records
