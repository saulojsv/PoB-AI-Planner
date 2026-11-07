local CatalogCoverage = require("Modules.Optimizer.CatalogCoverage")
local json = require("dkjson")
local ffi = require("ffi")

pcall(ffi.cdef, [[
	int _mkdir(const char *dirname);
	int _rmdir(const char *dirname);
	int _access(const char *path, int mode);
	int mkdir(const char *path, unsigned int mode);
	int rmdir(const char *path);
	int access(const char *path, int mode);
]])

local isWindows = package.config and package.config:sub(1, 1) == "\\"
local crt = isWindows and ffi.load("msvcr100") or nil

local function directoryExists(path)
	if isWindows then return crt._access(path, 0) == 0 end
	return ffi.C.access(path, 0) == 0
end

local function makeDirectory(path)
	path = path:gsub("[/\\]+$", "")
	local result = isWindows and crt._mkdir(path) or ffi.C.mkdir(path, 493)
	if result == 0 then return true end
	if directoryExists(path) then return nil, "No error" end
	return nil, "could not create test directory"
end

local function removeDirectory(path)
	if isWindows then return crt._rmdir(path) end
	return ffi.C.rmdir(path)
end

local function activeGem(id, name, tagString, effects)
	local effect = { id = name, name = name, color = 3, levels = { { levelRequirement = 1 } } }
	return {
		id = id, name = name, variantId = name:gsub(" ", ""), gameId = "Game/" .. name,
		grantedEffectId = name, grantedEffect = effect, grantedEffectList = effects or { effect },
		tags = { grants_active_skill = true }, tagString = tagString, naturalMaxLevel = 20,
	}
end

local function supportGem(id, variant, gameId, effectId)
	local effect = { id = effectId, name = "Added Cold Damage", support = true, color = 3, levels = { } }
	return {
		id = id, name = "Added Cold Damage", variantId = variant, gameId = gameId,
		grantedEffectId = effectId, grantedEffect = effect, tagString = "Support, Cold",
	}
end

local function fixtureBuild(reverse)
	local arc = activeGem("arc", "Arc", "Spell, Lightning, Chaining")
	local vaalEffects = {
		{ id = "VaalArc", name = "Vaal Arc", color = 3 },
		{ id = "Arc", name = "Arc", color = 3 },
	}
	local vaalArc = activeGem("vaal-arc", "Vaal Arc", "Spell, Lightning, Vaal", vaalEffects)
	vaalArc.gameId = "Game/Arc"
	local unsupportedActive = activeGem("unsupported-active", "Unsupported Active", "Spell, Fire")
	unsupportedActive.grantedEffect.unsupported = true
	local missingActive = {
		id = "missing-active", name = "Missing Active", variantId = "MissingActive", gameId = "Game/MissingActive",
		tags = { grants_active_skill = true }, tagString = "Spell, Cold",
	}
	local mislabeledSupport = {
		id = "mislabeled-support", name = "Support Effect Tagged Active", variantId = "MislabeledSupport",
		gameId = "Game/MislabeledSupport", grantedEffect = { id = "SupportEffect", support = true },
		tags = { grants_active_skill = true }, tagString = "Support, Cold",
	}
	local entries = {
		{ "arc", arc },
		{ "vaal-arc", vaalArc },
		{ "added-cold-a", supportGem("added-cold-a", "normal", "Support/AddCold", "SupportAddedCold") },
		{ "added-cold-b", supportGem("added-cold-b", "alternate", "Support/AddCold", "SupportAddedColdAlt") },
		{ "unsupported", { id = "unsupported", name = "Unsupported", grantedEffect = { unsupported = true } } },
		{ "unsupported-active", unsupportedActive },
		{ "missing-active", missingActive },
		{ "mislabeled-support", mislabeledSupport },
	}
	if reverse then
		for left = 1, math.floor(#entries / 2) do
			local right = #entries - left + 1
			entries[left], entries[right] = entries[right], entries[left]
		end
	end
	local gems = { }
	for _, entry in ipairs(entries) do gems[entry[1]] = entry[2] end
	return { data = { version = "3.29", gems = gems }, spec = { treeVersion = "3_29" } }
end

describe("Optimizer versioned loaded skill catalog coverage", function()
	it("records complete supported selectors, overlapping tags, and separate Vaal/support variants", function()
		local report = assert(CatalogCoverage.Build(fixtureBuild(false)))
		assert.are.equal("pob-skill-catalog-coverage", report.schema)
		assert.are.equal(2, report.schemaVersion)
		assert.are.equal("catalog_only", report.evaluationStatus)
		assert.is_false(report.exactEvaluated)
		assert.are.equal("not_evaluated", report.combinationCoverage)
		assert.are.equal(8, report.counts.loadedGemRecords)
		assert.are.equal(5, report.counts.includedGemRecords,
			"the mislabeled record remains included once as a support gem, while excluded from active-skill selection")
		assert.are.equal(3, report.counts.nonSelectableGemRecords)
		assert.are.equal(2, report.counts.recordsWithUnsupportedEffects)
		assert.are.equal(2, report.counts.activeGemEntries)
		assert.are.equal(5, report.counts.declaredActiveSkillGemRecords)
		assert.are.equal(2, report.counts.selectableActiveSkillGemRecords)
		assert.are.equal(3, report.counts.excludedActiveSkillGemRecords)
		assert.are.equal(1, report.counts.unsupportedActiveSkillGemRecords)
		assert.are.equal(1, report.counts.activeSkillGemRecordsMissingEffect)
		assert.are.equal(3, report.counts.activeSkillEffects)
		assert.are.equal(3, report.counts.supportGemVariants)
		assert.are.equal(2, report.counts.supportGameIds)
		assert.are.equal(3, report.counts.supportEffects)
		assert.are.equal(2, #report.catalogs.activeGemVariants)
		assert.are.equal(3, #report.catalogs.activeSkillEffects)
		assert.are.equal(3, #report.catalogs.supportGemVariants)
		assert.are.equal("Arc", report.catalogs.activeGemVariants[1].name)
		assert.are.equal("Chaining", report.catalogs.activeGemVariants[1].tags[1])
		assert.are.equal(2, report.tagCoverage.activeGemVariants.Spell)
		assert.are.equal(3, report.tagCoverage.activeSkillEffects.Spell)
		assert.are.equal(3, report.tagCoverage.supportGemVariants.Cold)
		assert.are.equal(2, report.tagCoverage.excludedActiveSkillGemVariants.Cold)
		assert.are.equal(1, report.tagCoverage.excludedActiveSkillGemVariants.Fire)
		assert.are.equal(3, #report.catalogs.excludedActiveSkillGemVariants)
		assert.are.equal("Missing Active", report.catalogs.excludedActiveSkillGemVariants[1].name)
		assert.are.equal("missing_granted_effect", report.catalogs.excludedActiveSkillGemVariants[1].reason)
		assert.are.equal("Support Effect Tagged Active", report.catalogs.excludedActiveSkillGemVariants[2].name)
		assert.are.equal("support_effect_not_main_skill", report.catalogs.excludedActiveSkillGemVariants[2].reason)
		assert.are.equal("Unsupported Active", report.catalogs.excludedActiveSkillGemVariants[3].name)
		assert.are.equal("unsupported_by_pob", report.catalogs.excludedActiveSkillGemVariants[3].reason)
		assert.are.equal("SHA-256", report.fingerprintAlgorithm)
		assert.are.equal(64, #report.fingerprint)
	end)

	it("produces the same fingerprint regardless of gem-table insertion order", function()
		local first = assert(CatalogCoverage.Build(fixtureBuild(false)))
		local second = assert(CatalogCoverage.Build(fixtureBuild(true)))
		assert.are.equal(first.fingerprint, second.fingerprint)
		assert.are.equal(json.encode(first.catalogs), json.encode(second.catalogs))
	end)

	it("writes only below PoB user data and reuses an identical versioned export", function()
		local separator = package.config:sub(1, 1)
		local temporary = os.tmpname()
		os.remove(temporary)
		local root = temporary .. "_optimizer_catalog"
		assert(makeDirectory(root))
		local storeDirectory = root .. separator .. "OptimizerStudies"
		assert(makeDirectory(storeDirectory))
		local createCount = 0
		local function createExportDirectory(path)
			createCount = createCount + 1
			return makeDirectory(path)
		end
		local first, exportError = CatalogCoverage.Export(root, fixtureBuild(false), createExportDirectory)
		assert.is_truthy(first, exportError)
		assert.is_true(first.exported)
		assert.is_false(first.exactEvaluated)
		assert.are.equal("not_evaluated", first.combinationCoverage)
		assert.is_truthy(first.storeFile:match("^OptimizerStudies/SkillCatalogs/poe1%-skill%-catalog%-v2%-%x+%.json$"))
		local exportPath = storeDirectory .. separator .. "SkillCatalogs" .. separator .. first.storeFile:match("([^/]+)$")
		local file = assert(io.open(exportPath, "rb"))
		local saved = assert(json.decode(file:read("*a")))
		file:close()
		assert.are.equal(first.fingerprint, saved.fingerprint)
		assert.are.equal(2, #saved.catalogs.activeGemVariants)
		assert.are.equal(3, #saved.catalogs.excludedActiveSkillGemVariants)
		local second = assert(CatalogCoverage.Export(root, fixtureBuild(true), createExportDirectory))
		assert.is_true(second.reused)
		assert.are.equal("already_current", second.status)
		assert.are.equal(first.fingerprint, second.fingerprint)
		assert.are.equal(2, createCount)
		saved.counts.activeGemEntries = 999
		local tampered = assert(io.open(exportPath, "wb"))
		assert(tampered:write(assert(json.encode(saved))))
		assert(tampered:close())
		local rejected, integrityError = CatalogCoverage.Export(root, fixtureBuild(false), createExportDirectory)
		assert.is_nil(rejected)
		assert.is_truthy(integrityError:find("failed integrity verification", 1, true))
		assert(os.remove(exportPath))
		assert.are.equal(0, removeDirectory(storeDirectory .. separator .. "SkillCatalogs"))
		assert.are.equal(0, removeDirectory(storeDirectory))
		assert.are.equal(0, removeDirectory(root))
	end)

	it("rejects missing user paths before invoking the directory creator", function()
		local called = false
		local result, err = CatalogCoverage.Export(nil, fixtureBuild(false), function() called = true end)
		assert.is_nil(result)
		assert.is_truthy(err)
		assert.is_false(called)
	end)

	it("partitions the loaded PoE1 active-gem database without dropping declared variants", function()
		newBuild()
		local report = assert(CatalogCoverage.Build(build))
		local counts = report.counts
		local reasons, supportIds = { }, { }
		for _, row in ipairs(report.catalogs.supportGemVariants) do supportIds[row.id] = true end
		assert.are.equal(counts.declaredActiveSkillGemRecords,
			counts.selectableActiveSkillGemRecords + counts.excludedActiveSkillGemRecords)
		assert.are.equal(counts.excludedActiveSkillGemRecords, #report.catalogs.excludedActiveSkillGemVariants)
		for _, row in ipairs(report.catalogs.excludedActiveSkillGemVariants) do
			assert.is_truthy(row.id)
			assert.is_truthy(row.reason)
			reasons[row.reason] = (reasons[row.reason] or 0) + 1
			if row.reason == "support_effect_not_main_skill" then
				assert.is_true(supportIds[row.id], "native support effect must remain discoverable as a support gem")
			end
		end
		print("QA_CASE " .. json.encode({ fixture = "loaded-poe1-active-gem-catalog-partition",
			dataVersion = report.version.dataVersion, declared = counts.declaredActiveSkillGemRecords,
			selectable = counts.selectableActiveSkillGemRecords, excluded = counts.excludedActiveSkillGemRecords,
			exclusionReasons = reasons,
			excludedRecords = report.catalogs.excludedActiveSkillGemVariants,
			unsupported = counts.unsupportedActiveSkillGemRecords,
			missingEffect = counts.activeSkillGemRecordsMissingEffect,
			combinationsEvaluated = report.exactEvaluated, certification = "catalog_partition_only" }))
	end)
end)
