-- Import a downloaded, provenance-tagged JSONL batch through PoB's own
-- bounded decoder, XML loader, calculator, serializer, archive and A/B review.
assert(os.getenv("CI") == "1", "CI=1 is required to isolate the HeadlessWrapper")
-- The extracted stock LuaJIT used by headless QA does not include the one
-- compound-assignment extension supported by PoB's pinned runtime. Translate
-- only that known expression in memory, matching the existing contract runner.
local nativeLoadfile = loadfile
local compatibilityTranslations = 0
function loadfile(path, ...)
	if path:gsub("\\", "/") == "Modules/Main.lua" then
		local sourceFile = assert(io.open(path, "rb"))
		local source = sourceFile:read("*a")
		sourceFile:close()
		local translated, count = source:gsub("count %+= 1", "count = count + 1")
		assert(count == 1, "Expected the known PoB Main.lua compatibility expression")
		compatibilityTranslations = count
		return loadstring(translated, "@" .. path)
	end
	return nativeLoadfile(path, ...)
end
local nativePrint = print
local activeBuildWarnings
print = function(...)
	if activeBuildWarnings then
		local parts = { }
		for index = 1, select("#", ...) do parts[index] = tostring(select(index, ...)) end
		local message = table.concat(parts, " ")
		if (message:find("Missing LUT", 1, true) or message:find("Failed to load", 1, true))
			and #activeBuildWarnings < 24 then
			local duplicate = false
			for _, previous in ipairs(activeBuildWarnings) do if previous == message then duplicate = true; break end end
			if not duplicate then activeBuildWarnings[#activeBuildWarnings + 1] = message:sub(1, 240) end
		end
	end
	return nativePrint(...)
end
dofile("HeadlessWrapper.lua")
assert(not __mainObject__.promptMsg, "PoB startup returned an error")
assert(compatibilityTranslations == 1, "The PoB compatibility expression was not translated")

local json = require("dkjson")
local importLifecycle = require("Modules.Optimizer.ImportLifecycle")
local LocalXMLIngestion = require("Modules.Optimizer.LocalXMLIngestion")
local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local Candidate = require("Modules.Optimizer.Candidate")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local BuildReviewPair = require("Modules.Optimizer.BuildReviewPair")
local sha = require("sha2")
local ffi = require("ffi")
ffi.cdef[[
	typedef unsigned short pob_wchar;
	typedef unsigned long pob_dword;
	typedef int pob_bool;
	int __stdcall MultiByteToWideChar(unsigned int codePage, pob_dword flags, const char *input, int inputLength, pob_wchar *output, int outputLength);
	pob_bool __stdcall CreateDirectoryW(const pob_wchar *path, void *securityAttributes);
	pob_dword __stdcall GetFileAttributesW(const pob_wchar *path);
	pob_dword __stdcall GetLastError(void);
]]
local kernel32 = ffi.load("kernel32")
local inputPath = assert(os.getenv("POB_PUBLIC_INGEST_BATCH"), "POB_PUBLIC_INGEST_BATCH is required")
local userPath = assert(os.getenv("POB_PUBLIC_INGEST_USER_PATH"), "POB_PUBLIC_INGEST_USER_PATH is required")
local latestResultsPath = os.getenv("POB_PUBLIC_INGEST_LATEST_RESULTS")
local reviewOnly = os.getenv("POB_PUBLIC_INGEST_REVIEW_ONLY") == "1"
local file = assert(io.open(inputPath, "rb"), "could not open the staged public-build batch")

local function widePath(path)
	path = tostring(path):gsub("[\\/]+$", "")
	local length = tonumber(kernel32.MultiByteToWideChar(65001, 8, path, -1, nil, 0))
	assert(length and length > 0, "could not convert an archive path to UTF-16")
	local result = ffi.new("pob_wchar[?]", length)
	assert(kernel32.MultiByteToWideChar(65001, 8, path, -1, result, length) > 0, "could not convert an archive path to UTF-16")
	return result
end

local function createArchiveDirectory(path)
	local wide = widePath(path)
	if kernel32.CreateDirectoryW(wide, nil) ~= 0 then return true end
	local errorCode = tonumber(kernel32.GetLastError())
	if errorCode == 183 then
		local attributes = tonumber(kernel32.GetFileAttributesW(wide))
		if attributes and attributes ~= 4294967295 and require("bit").band(attributes, 0x10) ~= 0 then
			return nil, "No error"
		end
	end
	return nil, "CreateDirectoryW failed with Windows error " .. tostring(errorCode)
end

local sourceXmlSequence = 0
local function archiveSourceXML(record, xmlText)
	if type(record) ~= "table" then return nil, nil, "Source XML provenance fields are missing or invalid" end
	local sourceIdentityHash = record.sourceFormat == "pob_xml" and record.sourceXmlSha256 or record.codeSha256
	if type(record.id) ~= "string" or not record.id:match("^[A-Za-z0-9_-]+$")
		or type(sourceIdentityHash) ~= "string" or #sourceIdentityHash ~= 64 or not sourceIdentityHash:match("^%x+$") then
		return nil, nil, "Source XML provenance fields are missing or invalid"
	end
	if type(xmlText) ~= "string" or xmlText == "" or #xmlText > importLifecycle.MAX_POB_XML_BYTES then
		return nil, nil, "Decoded source XML is empty or exceeds the bounded archive limit"
	end
	local providerFolders = { PoEDB = "PoEDB", PoBCodes = "PoBCodes", PoBBinPage = "PoBBinPage", PoBKR = "PoBKR", Maxroll = "Maxroll", PoeNinja = "PoeNinja", LocalXML = "LocalXML" }
	local folder = providerFolders[record.providerId]
	if not folder then return nil, nil, "Unsupported source provider for XML archive" end
	local archiveRoot = userPath:gsub("[\\/]+$", "") .. "\\OptimizerStudies\\Builds"
	local sourceRoot = archiveRoot .. "\\source-xml"
	local providerRoot = sourceRoot .. "\\" .. folder
	for _, directory in ipairs({ archiveRoot, sourceRoot, providerRoot }) do
		local created, createError = createArchiveDirectory(directory)
		if not created and createError ~= "No error" then return nil, nil, createError end
	end
	local relativePath = "source-xml/" .. folder .. "/" .. record.id .. "-" .. sourceIdentityHash:sub(1, 16) .. ".xml"
	local path = archiveRoot .. "\\" .. relativePath:gsub("/", "\\")
	local digest = sha.sha256(xmlText)
	local existing = io.open(path, "rb")
	if existing then
		local size = existing:seek("end") or 0
		existing:seek("set", 0)
		local current = size <= importLifecycle.MAX_POB_XML_BYTES and existing:read("*a") or nil
		existing:close()
		if type(current) ~= "string" or sha.sha256(current) ~= digest then
			return nil, nil, "An existing source XML archive object failed its SHA-256 check"
		end
		return relativePath, digest
	end
	sourceXmlSequence = sourceXmlSequence + 1
	local temporaryPath = path .. ".tmp-" .. tostring(os.time()) .. "-" .. tostring(sourceXmlSequence)
	local fileHandle, openError = io.open(temporaryPath, "wb")
	if not fileHandle then return nil, nil, "Could not create source XML archive object: " .. tostring(openError):sub(1, 180) end
	local wrote, writeError = fileHandle:write(xmlText)
	local flushed, flushError = wrote and fileHandle:flush()
	local closed, closeError = fileHandle:close()
	if not wrote or not flushed or not closed then
		os.remove(temporaryPath)
		return nil, nil, "Could not write source XML archive object: " .. tostring(writeError or flushError or closeError or "write failed"):sub(1, 180)
	end
	local renamed, renameError = os.rename(temporaryPath, path)
	if not renamed then
		os.remove(temporaryPath)
		return nil, nil, "Could not finalize source XML archive object: " .. tostring(renameError or "rename failed"):sub(1, 180)
	end
	local verify = io.open(path, "rb")
	local saved = verify and verify:read("*a") or nil
	if verify then verify:close() end
	if type(saved) ~= "string" or sha.sha256(saved) ~= digest then
		return nil, nil, "New source XML archive object failed its SHA-256 check"
	end
	return relativePath, digest
end

local function emit(value)
	local encoded, err = json.encode(value)
	assert(type(encoded) == "string", "could not encode ingestion result: " .. tostring(err))
	if type(latestResultsPath) == "string" and latestResultsPath ~= "" and type(value) == "table" then
		local archive = type(value.archive) == "table" and value.archive or { }
		local profile = type(archive.profile) == "table" and archive.profile or { }
		local engine = type(value.engine) == "table" and value.engine
			or type(value.pobEngine) == "table" and value.pobEngine
			or type(profile.engine) == "table" and profile.engine or { }
		local mainSkill = type(value.mainSkill) == "table" and value.mainSkill
			or type(profile.mainSkill) == "table" and profile.mainSkill or { }
		local character = type(value.character) == "table" and value.character
			or type(profile.character) == "table" and profile.character or { }
		local patch = tostring(engine.dataVersion or "")
		if patch == "" then
			local treeVersion = tostring(engine.treeVersion or "")
			patch = treeVersion:match("^3_(2[4-9])$") and ("3." .. treeVersion:sub(3)) or ""
		end
		local source = type(archive.source) == "table" and archive.source or { }
		local mainSkillCategory = tostring(mainSkill.category or "")
		local archiveObjectPath = type(archive.object) == "string" and archive.object:gsub("\\", "/") or nil
		if archiveObjectPath then
			archiveObjectPath = archiveObjectPath:match("([Oo]bjects/[0-9a-fA-F][0-9a-fA-F]/[0-9a-fA-F]+%.xml)$")
		end
		local latest = {
			schema = "pob-ai-planner-ingestion-result", schemaVersion = 1,
			id = value.id, status = value.status, reason = value.reason or value.error,
			patch = patch, skill = mainSkill.name, category = mainSkillCategory,
			gemId = mainSkill.gemId, gameId = mainSkill.gameId,
			variantId = mainSkill.variantId, effectId = mainSkill.effectId,
			nativeSerializationStatus = value.nativeSerializationStatus,
			archiveReadinessStatus = value.archiveReadinessStatus or profile.archiveReadinessStatus,
			mainSkillResolutionStatus = value.mainSkillResolutionStatus or profile.mainSkillResolutionStatus,
			mainSkillCandidateCount = value.mainSkillCandidateCount or #(profile.mainSkillCandidates or { }),
			sourceDisposition = value.sourceDisposition,
			sourceXmlPath = value.sourceXmlPath or source.sourceXmlPath,
			sourceXmlSha256 = value.sourceXmlSha256 or source.sourceXmlSha256,
			objectPath = archiveObjectPath, xmlSha256 = archive.xmlSha256 or value.xmlSha256,
			ascendancy = character.ascendancy,
		}
		local summaryLine = json.encode(latest)
		if type(summaryLine) == "string" then
			local resultFile = io.open(latestResultsPath, "ab")
			if resultFile then resultFile:write(summaryLine, "\n"); resultFile:flush(); resultFile:close() end
		end
	end
	print("INGEST_RESULT " .. encoded)
	io.flush()
end

local function metricsFromBuild(activeBuild)
	local result = { }
	local mainOutput = activeBuild.calcsTab and activeBuild.calcsTab.mainOutput or { }
	local calcsOutput = activeBuild.calcsTab and activeBuild.calcsTab.calcsOutput or { }
	local skillMetrics = { CombinedDPS = true, CritChance = true, CritMultiplier = true, Speed = true, ActionSpeedMod = true }
	for _, key in ipairs({
		"CombinedDPS", "FullDPS", "FullDotDPS", "TotalDPS", "TotalDotDPS", "WithDotDPS", "WithPoisonDPS",
		"WithIgniteDPS", "WithBleedDPS", "WithImpaleDPS", "CritChance", "CritMultiplier", "ActionSpeedMod", "Speed",
		"Life", "LifeReserved", "LifeUnreserved", "LifeReservedPercent", "EnergyShield", "Mana", "ManaReserved",
		"ManaUnreserved", "ManaReservedPercent", "Ward", "TotalEHP", "PhysicalMaximumHitTaken", "FireMaximumHitTaken",
		"ColdMaximumHitTaken", "LightningMaximumHitTaken", "ChaosMaximumHitTaken", "FireResist", "ColdResist",
		"LightningResist", "ChaosResist", "BlockChance", "SpellBlockChance", "SpellSuppressionChance", "Armour", "Evasion",
		"LifePerSecondCost", "ManaPerSecondCost", "ESPerSecondCost", "LifeRegenRecovery", "ManaRegenRecovery",
		"EnergyShieldRegenRecovery", "LifeLeechGainRate", "ManaLeechGainRate", "EnergyShieldLeechGainRate",
	}) do
		-- The native Main Skill output is the optimizer's primary skill context.
		-- Calcs may be displaying a different socket group (including an aura),
		-- so its skill-specific values must never overwrite the selected Main Skill.
		local value = tonumber(mainOutput[key])
		if not value then value = tonumber(calcsOutput[key]) end
		if value and value == value and value ~= math.huge and value ~= -math.huge then result[key] = value end
		if skillMetrics[key] then
			local calculatorValue = tonumber(calcsOutput[key])
			if calculatorValue and calculatorValue == calculatorValue and calculatorValue ~= math.huge
				and calculatorValue ~= -math.huge then
				result["Calculator" .. key] = calculatorValue
			end
		end
	end
	return result
end

local function calculationContext(activeBuild)
	local calcsTab = activeBuild.calcsTab or { }
	local skillGroups = activeBuild.skillsTab and activeBuild.skillsTab.socketGroupList or { }
	local mainGroupIndex = activeBuild.mainSocketGroup
	local mainGroup = mainGroupIndex and skillGroups[mainGroupIndex]
	local calculatorGroupIndex = calcsTab.input and calcsTab.input.skill_number
	local calculatorGroup = calculatorGroupIndex and skillGroups[calculatorGroupIndex]
	local calculatorSkillIndex = calculatorGroup and calculatorGroup.mainActiveSkillCalcs or 1
	local calculatorSkill = calculatorGroup and calculatorGroup.displaySkillListCalcs
		and calculatorGroup.displaySkillListCalcs[calculatorSkillIndex]
	local calculatorSourceInstance = calculatorSkill and calculatorSkill.activeEffect and calculatorSkill.activeEffect.srcInstance
	local function name(activeSkill)
		local effect = activeSkill and (activeSkill.activeEffect or (activeSkill.effectList and activeSkill.effectList[1]))
		return effect and effect.grantedEffect and effect.grantedEffect.name or nil
	end
	local includedActivities = { }
	for _, activity in ipairs(calcsTab.mainOutput and calcsTab.mainOutput.FullDPSActivity or { }) do
		includedActivities[#includedActivities + 1] = {
			name = activity.name,
			group = activity.group,
			skillPart = activity.skillPart,
			sourceGemIndex = activity.sourceGemIndex,
		}
	end
	return {
		mainSkill = name(calcsTab.mainEnv and calcsTab.mainEnv.player and calcsTab.mainEnv.player.mainSkill),
		mainSocketGroupIndex = mainGroupIndex,
		mainActiveSkillIndex = mainGroup and mainGroup.mainActiveSkill or nil,
		calculatorSkill = name(calcsTab.calcsEnv and calcsTab.calcsEnv.player and calcsTab.calcsEnv.player.mainSkill),
		calculatorSocketGroupIndex = calculatorGroupIndex,
		calculatorActiveSkillIndex = calculatorGroup and calculatorSkillIndex or nil,
		calculatorBuffMode = calcsTab.input and calcsTab.input.misc_buffMode or nil,
		calculatorShowMinion = calcsTab.input and calcsTab.input.showMinion == true or false,
		calculatorSkillPartIndex = calculatorSourceInstance and calculatorSourceInstance.skillPartCalcs or nil,
		calculatorSkillStageCount = calculatorSourceInstance and calculatorSourceInstance.skillStageCountCalcs or nil,
		calculatorMineCount = calculatorSourceInstance and calculatorSourceInstance.skillMineCountCalcs or nil,
		calculatorMinionId = calculatorSourceInstance and calculatorSourceInstance.skillMinionCalcs or nil,
		calculatorMinionItemSetId = calculatorSourceInstance and calculatorSourceInstance.skillMinionItemSetCalcs or nil,
		calculatorMinionSkillIndex = calculatorSourceInstance and calculatorSourceInstance.skillMinionSkillCalcs or nil,
		fullDPSIncludedActivities = includedActivities,
		fullDPSIncludedActivityCount = #includedActivities,
		metricSources = {
			CombinedDPS = "MAIN selected Main Skill",
			CritChance = "MAIN selected Main Skill",
			CritMultiplier = "MAIN selected Main Skill",
			Speed = "MAIN selected Main Skill",
			ActionSpeedMod = "MAIN selected Main Skill",
			FullDPS = "MAIN included FullDPS groups",
			CalculatorSkillMetrics = "CALCS currently selected group/effect, stored with Calculator prefix",
		},
	}
end

local function effectSummary(profile)
	local rows = { }
	for _, effect in ipairs(profile.configuredSkillEffects or { }) do
		rows[#rows + 1] = { effectId = effect.effectId, name = effect.name, gemId = effect.gemId, variantId = effect.variantId }
	end
	table.sort(rows, function(left, right) return tostring(left.effectId or "") < tostring(right.effectId or "") end)
	return rows
end

local function nativeMainSkillEvidence(activeBuild)
	local groups = activeBuild and activeBuild.skillsTab and activeBuild.skillsTab.socketGroupList or { }
	local groupIndex = tonumber(activeBuild and activeBuild.mainSocketGroup)
	local group = groupIndex and groups[groupIndex]
	if not group then return { mainSocketGroup = groupIndex, groupFound = false } end
	local evidence = {
		mainSocketGroup = groupIndex,
		groupFound = true,
		groupEnabled = group.enabled ~= false,
		slotEnabled = group.slotEnabled ~= false,
		mainActiveSkill = tonumber(group.mainActiveSkill),
		gemList = { },
		displaySkills = { },
	}
	for index, gem in ipairs(group.gemList or { }) do
		if index > 16 then break end
		local gemData = gem.gemData or { }
		evidence.gemList[#evidence.gemList + 1] = {
			gemId = gem.gemId or gemData.id,
			gameId = gemData.gameId,
			variantId = gemData.variantId,
			skillId = gem.skillId or gemData.grantedEffectId,
			name = gemData.name or gem.nameSpec,
			enabled = gem.enabled ~= false,
		}
	end
	for index, skill in ipairs(group.displaySkillList or { }) do
		if index > 16 then break end
		local activeEffect = skill.activeEffect or skill.effectList and skill.effectList[1]
		local source = activeEffect and activeEffect.srcInstance
		local sourceData = source and source.gemData or { }
		evidence.displaySkills[#evidence.displaySkills + 1] = {
			index = index,
			name = skill.name,
			activeEffectId = activeEffect and activeEffect.grantedEffect and activeEffect.grantedEffect.id,
			activeEffectName = activeEffect and activeEffect.grantedEffect and activeEffect.grantedEffect.name,
			sourceGemId = source and (source.gemId or sourceData.id),
			sourceGameId = sourceData.gameId,
			sourceVariantId = sourceData.variantId,
			sourceSkillId = source and source.skillId or sourceData.grantedEffectId,
			effectCount = #(skill.effectList or { }),
		}
	end
	return evidence
end

local function calculateBuild(activeBuild)
	if activeBuild.calcsTab and type(activeBuild.calcsTab.BuildOutput) == "function" then
		return pcall(activeBuild.calcsTab.BuildOutput, activeBuild.calcsTab)
	end
	return false, "PoB calculation tab is unavailable"
end

local function calculationStatus(ok, warnings, engine)
	if not ok then return "archive_only_calculation_failed" end
	if engine and engine.dataVersionSource == "tree_compatibility_key" then
		return "current_pob_calculation_patch_dataset_unverified"
	end
	local treeVersion = engine and tostring(engine.treeVersion or "") or ""
	local dataVersion = engine and tostring(engine.dataVersion or "") or ""
	local treeDataVersion = treeVersion:gsub("_", ".")
	if treeDataVersion ~= "" and dataVersion ~= "" and treeDataVersion ~= dataVersion then
		return "current_pob_calculation_not_patch_exact"
	end
	return #warnings > 0 and "exact_pob_build_output_completed_with_data_warnings" or "exact_pob_build_output_completed"
end

local treeLoadRecorderStatus = "not_installed"
local treeLoadRecorderEvents = { }

local function nativeTreeEvidence(activeBuild)
	local treeTab = activeBuild and activeBuild.treeTab or { }
	local rows = { }
	local specList = treeTab.specList or { }
	for index, spec in pairs(specList) do
		if type(spec) == "table" then
			rows[#rows + 1] = {
				index = tonumber(index) or tostring(index),
				active = tostring(index) == tostring(treeTab.activeSpec),
				title = spec.title,
				classId = tonumber(spec.curClassId),
				class = spec.curClassName,
				ascendancyId = tonumber(spec.curAscendClassId),
				ascendancy = spec.curAscendClassName,
				treeVersion = spec.treeVersion,
			}
		end
	end
	table.sort(rows, function(left, right) return tostring(left.index) < tostring(right.index) end)
	local sections = { }
	local sourceTreeSpecs = { }
	for _, section in ipairs(activeBuild and activeBuild.xmlSectionList or { }) do
		if type(section) == "table" and type(section.elem) == "string" then
			sections[#sections + 1] = section.elem
			if section.elem == "Tree" then
				for _, child in pairs(section) do
					if type(child) == "table" and child.elem == "Spec" then
						sourceTreeSpecs[#sourceTreeSpecs + 1] = {
							title = child.attrib and child.attrib.title,
							classId = child.attrib and tonumber(child.attrib.classId),
							ascendancyId = child.attrib and tonumber(child.attrib.ascendClassId),
							treeVersion = child.attrib and child.attrib.treeVersion,
						}
					end
				end
			end
		end
	end
	table.sort(sections)
	return {
		mode = __mainObject__.main.mode,
		buildTargetVersion = activeBuild and activeBuild.targetVersion or nil,
		treeLoadRecorderStatus = treeLoadRecorderStatus,
		treeLoadRecorderEvents = treeLoadRecorderEvents,
		activeSpecIndex = tonumber(treeTab.activeSpec),
		specCount = #rows,
		specListLength = #specList,
		specListType = type(treeTab.specList),
		treeLoadCall = treeTab.ingestionTreeLoadEvidence,
		specs = rows,
		sourceTreeSpecCount = #sourceTreeSpecs,
		sourceTreeSpecs = sourceTreeSpecs,
		loadedXmlSections = sections,
	}
end

local function installTreeLoadEvidenceRecorder()
	if type(common) ~= "table" then treeLoadRecorderStatus = "common_missing"; return end
	if type(common.classes) ~= "table" then treeLoadRecorderStatus = "class_registry_missing"; return end
	local treeClass = common.classes.TreeTab
	if type(treeClass) ~= "table" then treeLoadRecorderStatus = "tree_class_missing"; return end
	if type(treeClass.Load) ~= "function" then treeLoadRecorderStatus = "tree_load_method_missing"; return end
	if treeClass.ingestionLoadRecorderInstalled then treeLoadRecorderStatus = "already_installed"; return end
	local nativeLoad = treeClass.Load
	treeClass.Load = function(self, xml, dbFileName)
		local sourceSpecs = { }
		for _, child in pairs(type(xml) == "table" and xml or { }) do
			if type(child) == "table" and child.elem == "Spec" then
				sourceSpecs[#sourceSpecs + 1] = {
					classId = child.attrib and tonumber(child.attrib.classId),
					ascendancyId = child.attrib and tonumber(child.attrib.ascendClassId),
					treeVersion = child.attrib and child.attrib.treeVersion,
				}
			end
		end
		local result = nativeLoad(self, xml, dbFileName)
		local evidence = {
			receivedElement = type(xml) == "table" and xml.elem or nil,
			sourceSpecCount = #sourceSpecs,
			sourceSpecs = sourceSpecs,
			activeSpecIndexAfterLoad = tonumber(self.activeSpec),
			loadedSpecCount = #(self.specList or { }),
			result = result,
		}
		self.ingestionTreeLoadEvidence = evidence
		treeLoadRecorderEvents[#treeLoadRecorderEvents + 1] = {
			evidence = evidence,
		}
		return result
	end
	treeClass.ingestionLoadRecorderInstalled = true
	treeLoadRecorderStatus = "installed"
end

local function restoreSourceTreeSection(activeBuild, fileName)
	local treeTab = activeBuild and activeBuild.treeTab
	local sections = activeBuild and activeBuild.xmlSectionList or { }
	local sourceTree
	local sourceTimelessItemIds = { }
	local sourceItemIds = { }
	for _, section in ipairs(sections) do
		if type(section) == "table" and section.elem == "Tree" then
			if sourceTree then return nil, "The source XML contains more than one Tree section" end
			sourceTree = section
		elseif type(section) == "table" and section.elem == "Items" then
			for _, itemNode in ipairs(section) do
				if type(itemNode) == "table" and itemNode.elem == "Item" then
					local itemId = tonumber(itemNode.attrib and itemNode.attrib.id)
					if itemId then
						sourceItemIds[itemId] = true
						for _, itemText in ipairs(itemNode) do
							if type(itemText) == "string" then
								for line in itemText:gmatch("[^\r\n]+") do
									if line:match("^%s*Timeless Jewel%s*$") then
										sourceTimelessItemIds[itemId] = true
										break
									end
								end
							end
							if sourceTimelessItemIds[itemId] then break end
						end
					end
				end
			end
		end
	end
	if not sourceTree then return nil, "The source XML Tree section was not retained by the native loader" end
	if type(treeTab) ~= "table" then return nil, "The active native Tree tab is unavailable" end
	local expectedIndex = math.max(1, tonumber(sourceTree.attrib and sourceTree.attrib.activeSpec) or 1)
	local expectedSpec, sourceSpecCount, sourceSpecs
	sourceSpecCount, sourceSpecs = 0, { }
	for _, child in ipairs(sourceTree) do
		if type(child) == "table" and child.elem == "Spec" then
			sourceSpecCount = sourceSpecCount + 1
			sourceSpecs[sourceSpecCount] = child
			if sourceSpecCount == expectedIndex then expectedSpec = child end
		end
	end
	if not expectedSpec then return nil, "The source Tree activeSpec does not reference an available Spec" end
	local function isTimelessSocket(socket)
		local itemId = tonumber(socket and socket.attrib and socket.attrib.itemId)
		local item = itemId and activeBuild.itemsTab and activeBuild.itemsTab.items
			and activeBuild.itemsTab.items[itemId]
		-- ItemsTab drops an item it cannot resolve to a current native base. Use
		-- the immutable source Items section as a second exact check so an older
		-- Timeless Jewel is still excluded from the derived tree replay and then
		-- restored to its original socket map after skill resolution.
		return (item and item.baseName == "Timeless Jewel") or sourceTimelessItemIds[itemId] == true
	end
	local function collectSourceTimelessJewelSockets()
		local socketsBySpec, total = { }, 0
		for index, sourceSpec in ipairs(sourceSpecs) do
			local sockets = { }
			for _, child in ipairs(sourceSpec) do
				if type(child) == "table" and child.elem == "Sockets" then
					for _, socket in ipairs(child) do
						if type(socket) == "table" and socket.elem == "Socket" and isTimelessSocket(socket) then
							sockets[#sockets + 1] = {
								nodeId = tonumber(socket.attrib and socket.attrib.nodeId),
								itemId = tonumber(socket.attrib and socket.attrib.itemId),
							}
							total = total + 1
						end
					end
				end
			end
			socketsBySpec[index] = sockets
		end
		return socketsBySpec, total
	end
	local function collectUnparsedTreeSocketItemIds()
		local itemIds = { }
		for _, sourceSpec in ipairs(sourceSpecs) do
			for _, child in ipairs(sourceSpec) do
				if type(child) == "table" and child.elem == "Sockets" then
					for _, socket in ipairs(child) do
						if type(socket) == "table" and socket.elem == "Socket" then
							local itemId = tonumber(socket.attrib and socket.attrib.itemId)
							if itemId and itemId > 0 and sourceItemIds[itemId]
								and not (activeBuild.itemsTab and activeBuild.itemsTab.items and activeBuild.itemsTab.items[itemId]) then
								itemIds[itemId] = true
							end
						end
					end
				end
			end
		end
		local result = { }
		for itemId in pairs(itemIds) do result[#result + 1] = itemId end
		table.sort(result)
		return result
	end
	local function matchesExpected()
		local activeSpec = treeTab.specList and treeTab.specList[treeTab.activeSpec]
		return activeSpec and activeBuild.spec == activeSpec
			and tonumber(treeTab.activeSpec) == expectedIndex
			and #(treeTab.specList or { }) == sourceSpecCount
			and tonumber(activeSpec.curClassId) == tonumber(expectedSpec.attrib.classId)
			and tonumber(activeSpec.curAscendClassId) == tonumber(expectedSpec.attrib.ascendClassId)
			and tostring(activeSpec.treeVersion or "") == tostring(expectedSpec.attrib.treeVersion or "")
	end
	if matchesExpected() then
		local sourceTimelessJewelSockets, timelessSocketCount = collectSourceTimelessJewelSockets()
		return { status = "native_tree_tab_matches_source", activeSpecIndex = tonumber(treeTab.activeSpec),
			sourceSpecCount = sourceSpecCount, treeVersion = expectedSpec.attrib.treeVersion,
			timelessJewelSocketCount = timelessSocketCount,
			sourceTimelessJewelSocketsBySpec = sourceTimelessJewelSockets,
			unparsedTreeSocketItemIds = collectUnparsedTreeSocketItemIds(),
			itemSocketReconciliation = timelessSocketCount > 0
				and "source_mappings_preserved_for_skill_resolution; exact_historical_timeless_lut_unavailable"
				or "native_source_sockets_loaded_without_timeless_jewel_lut_recovery" }
	end
	-- The HeadlessWrapper Build lifecycle retained the source Tree XML but left
	-- the active TreeTab with no Specs. Construct every source Spec with PoB's
	-- native PassiveSpec loader, then bind its source activeSpec directly. The
	-- 3.26 snapshot does not contain every historical Timeless Jewel LUT. Such
	-- sockets are omitted only from a derived copy during native node/path load;
	-- their exact source item/node mapping is restored after PostLoad for profile
	-- and serialization. The immutable archived source XML is never edited.
	local function cloneXml(value)
		if type(value) ~= "table" then return value end
		local copy = { }
		for key, child in pairs(value) do copy[key] = cloneXml(child) end
		return copy
	end
	local recoveredSpecs, sourceTimelessJewelSockets = { }, { }
	local timelessSocketCount = 0
	for index, sourceSpec in ipairs(sourceSpecs) do
		local treeVersion = sourceSpec.attrib and sourceSpec.attrib.treeVersion or latestTreeVersion
		local spec = new("PassiveSpec"):PassiveSpec(activeBuild, treeVersion)
		local derivedSpec = cloneXml(sourceSpec)
		local preservedTimelessSockets = { }
		for childIndex, child in ipairs(derivedSpec) do
			if type(child) == "table" and child.elem == "Sockets" then
				local filteredSockets = { elem = "Sockets" }
				for _, socket in ipairs(child) do
					if type(socket) == "table" and socket.elem == "Socket" and isTimelessSocket(socket) then
						preservedTimelessSockets[#preservedTimelessSockets + 1] = {
							nodeId = tonumber(socket.attrib and socket.attrib.nodeId),
							itemId = tonumber(socket.attrib and socket.attrib.itemId),
						}
						timelessSocketCount = timelessSocketCount + 1
					else
						filteredSockets[#filteredSockets + 1] = cloneXml(socket)
					end
				end
				derivedSpec[childIndex] = filteredSockets
			end
		end
		local loadOk, loadResult = pcall(spec.Load, spec, derivedSpec, fileName)
		if not loadOk then
			return nil, "The native PassiveSpec loader raised while reading source Spec " .. tostring(index) .. ": " .. tostring(loadResult):sub(1, 180), "native_tree_load_unconfirmed"
		end
		if loadResult == true then
			-- PassiveSpec:Load returns true only after it has shown an explicit
			-- source-format error (for example a missing classId or socket itemId).
			-- That source cannot be repaired by repeating the same import. Preserve
			-- the XML evidence and quarantine the malformed document as terminal.
			return nil, "The native PassiveSpec loader rejected source Spec " .. tostring(index) .. " as structurally incomplete", "source_incomplete_or_corrupt"
		end
		if type(spec.PostLoad) == "function" then
			local postOk, postError = pcall(spec.PostLoad, spec)
			if not postOk then return nil, "The native PassiveSpec post-load step failed for Spec "
				.. tostring(index) .. ": " .. tostring(postError):sub(1, 180) end
		end
		sourceTimelessJewelSockets[index] = preservedTimelessSockets
		recoveredSpecs[index] = spec
	end
	treeTab.specList = recoveredSpecs
	treeTab.activeSpec = expectedIndex
	treeTab.activeCompareSpec = math.min(tonumber(treeTab.activeCompareSpec) or 1, #recoveredSpecs)
	treeTab.compareSpec = recoveredSpecs[treeTab.activeCompareSpec]
	treeTab.showConvert = not tostring(expectedSpec.attrib.treeVersion or ""):match("^" .. latestTreeVersion)
	activeBuild.spec = recoveredSpecs[expectedIndex]
	data.setJewelRadiiGlobally(activeBuild.spec.treeVersion)
	if type(activeBuild.UpdateClassDropdowns) == "function" then
		local dropdownOk, dropdownError = pcall(activeBuild.UpdateClassDropdowns, activeBuild, activeBuild.spec.treeVersion)
		if not dropdownOk then return nil, "Native class dropdown context failed after Spec replay: " .. tostring(dropdownError):sub(1, 180) end
	end
	if activeBuild.itemsTab and activeBuild.itemsTab.controls and activeBuild.itemsTab.controls.specSelect then
		activeBuild.itemsTab.controls.specSelect.selIndex = expectedIndex
	end
	if activeBuild.skillsTab and type(activeBuild.skillsTab.UpdateSocketGroups) == "function" then
		local skillsOk, skillsError = pcall(activeBuild.skillsTab.UpdateSocketGroups, activeBuild.skillsTab)
		if not skillsOk then return nil, "Skill groups could not reconcile after tree load: " .. tostring(skillsError):sub(1, 180) end
	end
	if activeBuild.optimizerTab and type(activeBuild.optimizerTab.FinalizeBuildContext) == "function" then
		local contextOk, contextError = pcall(activeBuild.optimizerTab.FinalizeBuildContext, activeBuild.optimizerTab)
		if not contextOk then return nil, "Optimizer context could not reconcile after tree load: " .. tostring(contextError):sub(1, 180) end
	end
	if not matchesExpected() then return nil, "The active native Spec still disagrees with the source Tree activeSpec after native replay" end
	return { status = "source_passive_specs_replayed_with_exact_source_jewel_sockets",
		activeSpecIndex = tonumber(treeTab.activeSpec), sourceSpecCount = sourceSpecCount,
		classId = tonumber(expectedSpec.attrib.classId), ascendancyId = tonumber(expectedSpec.attrib.ascendClassId),
		treeVersion = expectedSpec.attrib.treeVersion,
		timelessJewelSocketCount = timelessSocketCount,
		sourceTimelessJewelSocketsBySpec = sourceTimelessJewelSockets,
		unparsedTreeSocketItemIds = collectUnparsedTreeSocketItemIds(),
		itemSocketReconciliation = timelessSocketCount > 0
			and "source_mappings_preserved_for_skill_resolution; exact_historical_timeless_lut_unavailable"
			or "native_source_sockets_loaded_without_timeless_jewel_lut_recovery" }
end

local function restoreSourceTimelessJewelSockets(activeBuild, recovery)
	local specs = activeBuild and activeBuild.treeTab and activeBuild.treeTab.specList or { }
	local sourceRows = recovery and recovery.sourceTimelessJewelSocketsBySpec
	if type(sourceRows) ~= "table" then return nil, "Source Timeless Jewel mappings are unavailable" end
	local activeSpecIndex = tonumber(recovery.activeSpecIndex)
	if not activeSpecIndex or not specs[activeSpecIndex] then
		return nil, "The source active Spec was not recovered, so its Timeless Jewel mappings cannot be restored"
	end
	local unrecoveredInactiveSpecs, unrecoveredInactiveTimelessSockets = 0, 0
	for specIndex, rows in ipairs(sourceRows) do
		local spec = specs[specIndex]
		if type(spec) ~= "table" then
			if specIndex == activeSpecIndex then return nil, "The source active Spec is unavailable for Timeless Jewel restoration" end
			unrecoveredInactiveSpecs = unrecoveredInactiveSpecs + 1
			unrecoveredInactiveTimelessSockets = unrecoveredInactiveTimelessSockets + #(rows or { })
		else
			if type(spec.jewels) ~= "table" then return nil, "Recovered Spec jewel map is unavailable" end
			for _, socket in ipairs(rows or { }) do
				if not socket.nodeId or not socket.itemId or socket.itemId <= 0 then
					return nil, "The source Timeless Jewel socket row has invalid node/item IDs"
				end
				local existingItemId = tonumber(spec.jewels[socket.nodeId])
				if existingItemId and existingItemId ~= socket.itemId then
					return nil, "A source Timeless Jewel socket conflicts with a loaded native socket row"
				end
				if not existingItemId then spec.jewels[socket.nodeId] = socket.itemId end
			end
		end
	end
	if #specs ~= #sourceRows then
		recovery.preserveSourceXmlAsCanonical = true
		recovery.unrecoveredInactiveSpecCount = unrecoveredInactiveSpecs + math.max(0, #specs - #sourceRows)
		recovery.unrecoveredInactiveTimelessSocketCount = unrecoveredInactiveTimelessSockets
		recovery.itemSocketReconciliation = "active_source_spec_restored; inactive_source_specs_preserved_in_immutable_xml"
	end
	return true, recovery.itemSocketReconciliation
end

local lineNumber = 0
for line in file:lines() do
	lineNumber = lineNumber + 1
	local decoded, record, position, decodeError = pcall(json.decode, line)
	if not decoded or type(record) ~= "table" then
		emit({ line = lineNumber, status = "invalid_staged_record", error = tostring(decodeError or record):sub(1, 240) })
	else
		local buildWarnings = { }
		-- Build teardown may flush diagnostics from the previous snapshot. Do not
		-- attribute those to the next source; only capture warnings after its
		-- fresh native mode exists and immediately before loading its XML.
		activeBuildWarnings = nil
		local sourceXmlPath, sourceXmlSha256, nativeBuildVersionConversionApplied, nativeTreeLoadRecovery
		local preliminaryCalcOk, preliminaryCalcError
		local ok, outcome = pcall(function()
			local xmlText, coverage
			if record.sourceFormat == "pob_xml" then
				xmlText, coverage = LocalXMLIngestion.Read(record, importLifecycle, sha)
				if not xmlText then return { id = record.id, title = record.title, reference = record.reference,
					status = "source_incomplete_or_corrupt", sourceDisposition = "quarantined_incomplete_or_corrupt",
					reason = coverage } end
			elseif record.sourceFormat == nil or record.sourceFormat == "pob_code" then
				xmlText, coverage = importLifecycle.DecodeBuildCode(record.code)
				if not xmlText then return { id = record.id, title = record.title, reference = record.reference,
					status = "source_incomplete_or_corrupt", sourceDisposition = "quarantined_incomplete_or_corrupt",
					reason = coverage } end
			else
				return { id = record.id, title = record.title, reference = record.reference,
					status = "source_incomplete_or_corrupt", sourceDisposition = "quarantined_incomplete_or_corrupt",
					reason = "unsupported_source_format" }
			end
			local sourcePath, sourceHash, sourceError = archiveSourceXML(record, xmlText)
			if not sourcePath then return { id = record.id, title = record.title, reference = record.reference,
				status = "source_xml_archive_failed", reason = tostring(sourceError):sub(1, 220) } end
			sourceXmlPath, sourceXmlSha256 = sourcePath, sourceHash
			-- The source game's Build targetVersion may predate this local PoB. Use
			-- PoB's native convertBuild path to open the same XML, while preserving
			-- its exact Spec treeVersion (3.24–3.29). The immutable original XML was
			-- archived above; native calculations remain marked patch-unverified
			-- when the local snapshot only has a tree compatibility key.
			nativeBuildVersionConversionApplied = coverage and coverage.targetVersion ~= liveTargetVersion or false
			-- A prior legacy/converted build can leave the reusable Build mode without
			-- its saver registry. Start a fresh native mode for every independent XML.
			newBuild()
			for key in pairs(treeLoadRecorderEvents) do treeLoadRecorderEvents[key] = nil end
			treeLoadRecorderStatus = "not_installed"
			installTreeLoadEvidenceRecorder()
			activeBuildWarnings = buildWarnings
			local loadOk, loadError = pcall(loadBuildFromXML, xmlText, record.title or "Public PoE build",
				nativeBuildVersionConversionApplied)
			if not loadOk then return { id = record.id, title = record.title, reference = record.reference,
				status = "native_load_failed", error = tostring(loadError):sub(1, 240) } end
			build = __mainObject__.main.modes["BUILD"]
			if type(build) ~= "table" or type(build.spec) ~= "table" or type(build.SaveDB) ~= "function" then
				return { id = record.id, title = record.title, reference = record.reference, status = "native_load_unconfirmed" }
			end
			-- Build:LoadDB clears build.savers after all sections have been loaded and
			-- post-processed. A nil saver registry here is the normal completed-load
			-- state, not evidence that a matching engine is required. Confirm the
			-- initialized native spec and calculation tab instead; exact patch and
			-- skill eligibility are validated below from the loaded build itself.
			if __mainObject__.main.mode ~= "BUILD" or type(build.spec.treeVersion) ~= "string" or type(build.calcsTab) ~= "table"
				or type(build.calcsTab.BuildOutput) ~= "function" then
				return { id = record.id, title = record.title, reference = record.reference,
					status = "native_load_unconfirmed", targetVersion = build.targetVersion,
					reason = "PoB did not leave an active BUILD mode with an initialized spec and calculation tab." }
			end
			local treeRecovered, treeRecoveryError, treeFailureStatus = restoreSourceTreeSection(build, record.title or "Public PoE build")
			if not treeRecovered then
				if treeFailureStatus == "source_incomplete_or_corrupt" then
					return { id = record.id, title = record.title, reference = record.reference,
						status = "source_incomplete_or_corrupt", sourceDisposition = "quarantined_incomplete_or_corrupt",
						reason = treeRecoveryError, nativeTreeEvidence = nativeTreeEvidence(build) }
				end
				return { id = record.id, title = record.title, reference = record.reference,
					status = "native_tree_load_unconfirmed", reason = treeRecoveryError,
					nativeTreeEvidence = nativeTreeEvidence(build) }
			end
			nativeTreeLoadRecovery = treeRecovered
			build.sourceUnparsedTreeSocketItemIds = treeRecovered.unparsedTreeSocketItemIds or { }
			-- BuildOutput populates PoB's native displaySkillList, which is required
			-- to bind the selected main effect to its exact socketed gem. In a
			-- historical Timeless case the recovered Spec is still on the derived
			-- tree (with that LUT-dependent socket temporarily absent); output is
			-- used only to resolve skill identity, never as a performance label.
			preliminaryCalcOk, preliminaryCalcError = calculateBuild(build)
			local jewelSocketsRestored, jewelSocketRestoreStatus = restoreSourceTimelessJewelSockets(build, nativeTreeLoadRecovery)
			if not jewelSocketsRestored then
				return { id = record.id, title = record.title, reference = record.reference,
					status = "native_tree_load_unconfirmed", reason = jewelSocketRestoreStatus,
					nativeTreeEvidence = nativeTreeEvidence(build) }
			end
			build.sourceTreeRecoveryStatus = nativeTreeLoadRecovery.status
			build.sourceInactiveSpecRecoveryGap = nativeTreeLoadRecovery.unrecoveredInactiveSpecCount or 0
			if (tonumber(nativeTreeLoadRecovery.timelessJewelSocketCount) or 0) > 0 then
				nativeTreeLoadRecovery.itemSocketReconciliation = "exact_source_mappings_restored_after_skill_identity_resolution; historical_timeless_lut_unavailable_for_exact_calculation"
			end
			local profile, profileError = StudyBuilds.ProfileFromBuild(build)
			if not profile then return { status = "profile_failed", error = tostring(profileError):sub(1, 240) } end
			local targetScope = StudyBuilds.ClassifyTargetScope(userPath, profile, xmlText)
			local targetEligibility = type(targetScope.eligibility) == "table" and targetScope.eligibility or nil
			local targetRejection = targetScope.reason
			local nativeMainSkill = type(profile.mainSkill) == "table" and profile.mainSkill or { }
			local nativeGameId, nativeVariantId = tostring(nativeMainSkill.gameId or ""), tostring(nativeMainSkill.variantId or "")
			local nativeMainSkillKey = nativeGameId ~= "" and nativeVariantId ~= ""
				and (nativeGameId .. "|" .. nativeVariantId) or nil
			if not reviewOnly and (type(record.codeSha256) == "string" or record.sourceFormat == "pob_xml") then
				local archivedSource, sourceLookupError, sourceLookupCode
				if record.sourceFormat == "pob_xml" then
					archivedSource, sourceLookupError, sourceLookupCode = StudyBuilds.FindArchivedObservationByReference(userPath, record.reference)
				else
					archivedSource, sourceLookupError = StudyBuilds.FindArchivedObservationBySourceCode(
						userPath, record.reference, record.codeSha256)
				end
				if archivedSource then
					return {
						id = record.id, title = record.title, reference = record.reference,
						status = "already_archived", archiveObservationId = archivedSource.observationId,
						lineageSha256 = archivedSource.lineageSha256, xmlSha256 = archivedSource.xmlSha256,
						patch = targetEligibility and targetEligibility.patch or nil,
						mainSkillKey = targetEligibility and targetEligibility.mainSkillKey or nativeMainSkillKey,
						mainSkillName = targetEligibility and targetEligibility.mainSkillName or nativeMainSkill.name,
						category = targetEligibility and targetEligibility.category or nativeMainSkill.category,
						ascendancy = targetEligibility and targetEligibility.ascendancy or profile.character and profile.character.ascendancy,
						targetScopeStatus = targetScope.status, targetScopeReason = targetRejection,
			nativeImportStatus = "native_imported", archiveReadinessStatus = profile.archiveReadinessStatus,
			mainSkillStatus = profile.mainSkillStatus, mainSkillResolutionStatus = profile.mainSkillResolutionStatus,
			mainSkillCandidateCount = #(profile.mainSkillCandidates or { }),
						engine = profile.engine, mainSkill = profile.mainSkill, character = profile.character,
					}
				elseif not (record.sourceFormat == "pob_xml" and sourceLookupCode == "source_reference_not_archived")
					and sourceLookupError ~= "source_code_not_archived" then
					return {
						id = record.id, title = record.title, reference = record.reference,
						status = "archive_source_lookup_failed", error = tostring(sourceLookupError):sub(1, 240),
					}
				end
			end
			local calcSkippedForSourceTreeJewelSlots = nativeTreeLoadRecovery
				and (tonumber(nativeTreeLoadRecovery.timelessJewelSocketCount) or 0) > 0
			local calcOk, calcError = preliminaryCalcOk, preliminaryCalcError
			if calcSkippedForSourceTreeJewelSlots then
				calcOk, calcError = false, "Skipped as a source metric: preliminary PoB output resolved skill identity with the historical Timeless Jewel temporarily omitted; the immutable source socket was restored, but this calculation is not patch-complete."
			end
			local calcStatus = calcSkippedForSourceTreeJewelSlots
				and "source_tree_profiled_calculation_unavailable_historical_jewel_lut"
				or calculationStatus(calcOk, buildWarnings, profile.engine)
			if reviewOnly then
				-- Keep the current reconstruction fingerprint for audit only. The
				-- review below uses the original archived profile and lineage.
				local savedOk, canonicalXML = pcall(build.SaveDB, build, record.title or "Public PoE build")
				if not savedOk or type(canonicalXML) ~= "string" or canonicalXML == "" then
					return { status = "native_serialize_failed", error = tostring(canonicalXML):sub(1, 240) }
				end
				record.canonicalXMLSha256 = sha.sha256(canonicalXML)
			end
			if reviewOnly then
				local signatureOk, signature = pcall(Candidate.BuildSignature, build)
				if not signatureOk or type(signature) ~= "string" then return { status = "lineage_failed" } end
				local sourceReconstructionLineageSha256 = sha.sha256(signature)
				local archiveObservation, archiveError
				if type(record.codeSha256) == "string" and record.codeSha256 ~= "" then
					-- Public source URLs can now point to several revisions. When the
					-- incoming PoB code has a verified source hash, bind review to that
					-- exact immutable archive observation instead of guessing by URL.
					archiveObservation, archiveError = StudyBuilds.FindArchivedObservationBySourceCode(
						userPath, record.reference, record.codeSha256)
				else
					-- Legacy locally supplied code without a source hash may only be
					-- reviewed when the reference resolves unambiguously.
					archiveObservation, archiveError = StudyBuilds.FindArchivedObservationByReference(userPath, record.reference)
				end
				if not archiveObservation then
					return { status = "archive_snapshot_unresolved", id = record.id, title = record.title,
						reference = record.reference, error = tostring(archiveError):sub(1, 240) }
				end
				local catalogOk, catalog = pcall(SkillCatalog.ListAllActiveEffects, build, "")
				if not catalogOk or type(catalog) ~= "table" or catalog.truncated ~= false then
					return { status = "review_catalog_unavailable", id = record.id, title = record.title,
						reference = record.reference, canonicalXMLSha256 = record.canonicalXMLSha256,
						archiveLineageSha256 = archiveObservation.lineageSha256 }
				end
				local lineageSha256 = archiveObservation.lineageSha256
				local review, reviewError = BuildReviewPair.Process(archiveObservation.profile, catalog, { }, userPath,
					lineageSha256, createArchiveDirectory, archiveObservation)
				if not review then
					return { status = "review_failed", id = record.id, title = record.title,
						reference = record.reference, lineageSha256 = lineageSha256,
						sourceReconstructionLineageSha256 = sourceReconstructionLineageSha256,
						canonicalXMLSha256 = record.canonicalXMLSha256,
						error = tostring(reviewError):sub(1, 240) }
				end
				return {
					status = "reviewed",
					id = record.id,
					title = record.title,
					reference = record.reference,
					lineageSha256 = lineageSha256,
					archiveObservationId = archiveObservation.observationId,
					xmlSha256 = archiveObservation.xmlSha256,
					sourceReconstructionLineageSha256 = sourceReconstructionLineageSha256,
					canonicalXMLSha256 = record.canonicalXMLSha256,
					engine = archiveObservation.profile.engine,
					catalogEngine = profile.engine,
					configuredEffects = effectSummary(archiveObservation.profile),
					metrics = not calcSkippedForSourceTreeJewelSlots and metricsFromBuild(build) or nil,
					calculationContext = not calcSkippedForSourceTreeJewelSlots and calculationContext(build)
						or { status = "not_calculated", reason = "historical Timeless Jewel UI slots were not reconciled" },
					calculationStatus = calcStatus,
					calculationError = not calcOk and tostring(calcError):sub(1, 240) or nil,
					calculationWarnings = buildWarnings,
					buildReview = review,
				}
			end
			local savedOk, canonicalXML = false, nil
			local nativeSerializationStatus = "native_reserialized"
			local nativeSerializationReason
			local sourceOnlyTreeDetails = nativeTreeLoadRecovery
				and ((tonumber(nativeTreeLoadRecovery.timelessJewelSocketCount) or 0) > 0
					or nativeTreeLoadRecovery.preserveSourceXmlAsCanonical == true
					or #(nativeTreeLoadRecovery.unparsedTreeSocketItemIds or { }) > 0)
			if sourceOnlyTreeDetails then
				-- Keep every source Spec, item id and historical tree mapping byte-for-
				-- byte when the local PoB snapshot cannot reproduce those details.
				canonicalXML = xmlText
				nativeSerializationStatus = "source_xml_preserved_historical_tree_data"
				nativeSerializationReason = "The source XML is structurally valid and its active native profile was recovered; the exact source document preserves historical tree details unavailable to this local data snapshot."
			else
				savedOk, canonicalXML = pcall(build.SaveDB, build, record.title or "Public PoE build")
			end
			if not sourceOnlyTreeDetails and (not savedOk or type(canonicalXML) ~= "string" or canonicalXML == "") then
				local saveError = tostring(canonicalXML)
				local mayPreserveOriginal = not savedOk and type(build.savers) ~= "table"
					and saveError:find("bad argument #1 to 'pairs' (table expected, got nil)", 1, true) ~= nil
					and type(xmlText) == "string" and #xmlText > 0
					and type(sourceXmlSha256) == "string" and sha.sha256(xmlText) == sourceXmlSha256
				if mayPreserveOriginal then
					local sourceValidation = importLifecycle.ValidateXML(xmlText)
					local coverage = sourceValidation and sourceValidation.sectionCoverage
					if coverage and coverage.Build == true and coverage.Tree == true
						and coverage.Skills == true and coverage.Items == true then
						-- PoB loaded the source, extracted its native profile/tree, and only
						-- lost the transient SaveDB saver registry during legacy shutdown.
						-- Preserve the exact, hash-verified PoB source XML instead of emitting
						-- a partial document or mislabeling it as reserialized.
						canonicalXML = xmlText
						nativeSerializationStatus = "source_xml_preserved_after_native_save_error"
						nativeSerializationReason = saveError:sub(1, 240)
					else
						return { status = "native_serialize_failed", error = saveError:sub(1, 240) }
					end
				else
					return { status = "native_serialize_failed", error = saveError:sub(1, 240) }
				end
			end
			local archiveSource = {
				type = record.sourceFormat == "pob_xml" and "local_xml_import" or "curated_public_build",
				provider = record.providerId or "PoBCodes",
				reference = record.reference,
				sourceUrl = record.sourceUrl,
				label = record.label or record.title or "Public PoE build",
				locale = record.locale,
				claimedLeague = record.claimedLeague,
				claimedPatch = record.claimedPatch,
				claimedMainSkill = record.claimedMainSkill,
				targetScopeStatus = targetScope.status,
				targetScopeReason = targetRejection,
				nativeImportStatus = "native_imported",
				nativeSerializationStatus = nativeSerializationStatus,
				nativeSerializationReason = nativeSerializationReason,
				rightsStatus = record.rightsStatus,
				rightsEvidenceUrl = record.rightsEvidenceUrl,
				acquisitionMethod = record.acquisitionMethod,
				codeSha256 = record.codeSha256,
				codePath = record.codePath,
				sourceXmlSha256 = sourceXmlSha256,
				sourceXmlPath = sourceXmlPath,
				acquiredAt = record.acquiredAt,
				skipDuplicateLineage = true,
			}
			local archived, archiveError = StudyBuilds.ArchiveXML(build, canonicalXML, userPath, archiveSource,
				createArchiveDirectory, xmlText)
			if not archived then return { status = "archive_failed", error = tostring(archiveError):sub(1, 240) } end
			if archived.duplicateLineage == true then
				return {
					status = "already_archived_duplicate_lineage",
					id = record.id,
					title = record.title,
					reference = record.reference,
					codeSha256 = record.codeSha256,
					lineageSha256 = archived.lineageSha256,
					patch = targetEligibility and targetEligibility.patch or nil,
					mainSkillKey = targetEligibility and targetEligibility.mainSkillKey or nativeMainSkillKey,
					mainSkillName = targetEligibility and targetEligibility.mainSkillName or nativeMainSkill.name,
					targetScopeStatus = targetScope.status,
					targetScopeReason = targetRejection,
					nativeImportStatus = "native_imported_duplicate_lineage_skipped",
					archiveReadinessStatus = profile.archiveReadinessStatus,
					mainSkillStatus = profile.mainSkillStatus,
					mainSkillResolutionStatus = profile.mainSkillResolutionStatus,
				}
			end
			local validation = importLifecycle.ValidateXML(xmlText)
			return {
				status = "archived",
				id = record.id,
				title = record.title,
				creator = record.creator,
				reference = record.reference,
				codeSha256 = record.codeSha256,
				claimedMainSkill = record.claimedMainSkill,
				claimedLeague = record.claimedLeague,
				claimedPatch = record.claimedPatch,
				patch = targetEligibility and targetEligibility.patch or nil,
				mainSkillKey = targetEligibility and targetEligibility.mainSkillKey or nativeMainSkillKey,
				mainSkillName = targetEligibility and targetEligibility.mainSkillName or nativeMainSkill.name,
				category = targetEligibility and targetEligibility.category or nativeMainSkill.category,
				ascendancy = targetEligibility and targetEligibility.ascendancy or profile.character and profile.character.ascendancy,
				targetScopeStatus = targetScope.status,
				targetScopeReason = targetRejection,
				nativeImportStatus = "native_imported",
				nativeSerializationStatus = nativeSerializationStatus,
				nativeSerializationReason = nativeSerializationReason,
				mainSkillStatus = profile.mainSkillStatus,
				mainSkillResolutionStatus = profile.mainSkillResolutionStatus,
				mainSkillCandidateCount = #(profile.mainSkillCandidates or { }),
				archiveReadinessStatus = profile.archiveReadinessStatus,
				xmlDeclaredTargetVersion = validation and validation.targetVersion or nil,
				pobEngine = profile.engine,
				mainSkill = profile.mainSkill,
				character = profile.character,
				sectionCoverage = coverage and coverage.sectionCoverage or nil,
				configuredEffects = effectSummary(profile),
				metrics = not calcSkippedForSourceTreeJewelSlots and metricsFromBuild(build) or nil,
				calculationContext = not calcSkippedForSourceTreeJewelSlots and calculationContext(build)
					or { status = "not_calculated", reason = "historical Timeless Jewel UI slots were not reconciled" },
				calculationStatus = calcStatus,
				calculationError = not calcOk and tostring(calcError):sub(1, 240) or nil,
				calculationWarnings = buildWarnings,
				archive = archived,
			}
		end)
		activeBuildWarnings = nil
		if ok then
			if type(outcome) == "table" then
				outcome.id = outcome.id or record.id
				outcome.providerId = outcome.providerId or record.providerId
				if sourceXmlPath then
					outcome.sourceXmlPath, outcome.sourceXmlSha256 = sourceXmlPath, sourceXmlSha256
					outcome.nativeBuildVersionConversionApplied = nativeBuildVersionConversionApplied
					outcome.nativeTreeLoadRecovery = nativeTreeLoadRecovery
				end
			end
			emit(outcome)
		else
			emit({ line = lineNumber, id = record.id, providerId = record.providerId, title = record.title,
				reference = record.reference, status = "ingestion_exception", sourceXmlPath = sourceXmlPath,
				sourceXmlSha256 = sourceXmlSha256,
				nativeBuildVersionConversionApplied = nativeBuildVersionConversionApplied,
				nativeTreeLoadRecovery = nativeTreeLoadRecovery,
				error = tostring(outcome):sub(1, 240) })
		end
	end
end
file:close()
