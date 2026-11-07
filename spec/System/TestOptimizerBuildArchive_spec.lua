local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local BuildReviewPair = require("Modules.Optimizer.BuildReviewPair")
local Candidate = require("Modules.Optimizer.Candidate")
local PatchSkillCatalogFingerprint = require("Modules.Optimizer.PatchSkillCatalogFingerprint")
local TestSupport = require("OptimizerTestSupport")
local json = require("dkjson")
local sha = require("sha2")
local ffi = require("ffi")

local fixtureStandardAscendancies = {
	{ classId = 0, className = "Scion", id = "Ascendant", name = "Ascendant" },
	{ classId = 1, className = "Marauder", id = "Berserker", name = "Berserker" },
	{ classId = 1, className = "Marauder", id = "Chieftain", name = "Chieftain" },
	{ classId = 1, className = "Marauder", id = "Juggernaut", name = "Juggernaut" },
	{ classId = 2, className = "Ranger", id = "Deadeye", name = "Deadeye" },
	{ classId = 2, className = "Ranger", id = "Pathfinder", name = "Pathfinder" },
	{ classId = 2, className = "Ranger", id = "Raider", name = "Raider" },
	{ classId = 3, className = "Witch", id = "Elementalist", name = "Elementalist" },
	{ classId = 3, className = "Witch", id = "Necromancer", name = "Necromancer" },
	{ classId = 3, className = "Witch", id = "Occultist", name = "Occultist" },
	{ classId = 4, className = "Duelist", id = "Champion", name = "Champion" },
	{ classId = 4, className = "Duelist", id = "Gladiator", name = "Gladiator" },
	{ classId = 4, className = "Duelist", id = "Slayer", name = "Slayer" },
	{ classId = 5, className = "Templar", id = "Guardian", name = "Guardian" },
	{ classId = 5, className = "Templar", id = "Hierophant", name = "Hierophant" },
	{ classId = 5, className = "Templar", id = "Inquisitor", name = "Inquisitor" },
	{ classId = 6, className = "Shadow", id = "Assassin", name = "Assassin" },
	{ classId = 6, className = "Shadow", id = "Saboteur", name = "Saboteur" },
	{ classId = 6, className = "Shadow", id = "Trickster", name = "Trickster" },
}
local fixtureAscendancyIndices = {
	Ascendant = 1,
	Berserker = 2, Chieftain = 3, Juggernaut = 1,
	Deadeye = 2, Pathfinder = 3, Raider = 1,
	Elementalist = 2, Necromancer = 3, Occultist = 1,
	Champion = 3, Gladiator = 2, Slayer = 1,
	Guardian = 3, Hierophant = 2, Inquisitor = 1,
	Assassin = 1, Saboteur = 3, Trickster = 2,
}
for _, ascendancy in ipairs(fixtureStandardAscendancies) do
	ascendancy.ascendClassId = fixtureAscendancyIndices[ascendancy.id]
end

pcall(ffi.cdef, [[
typedef int archiveBOOL;
archiveBOOL __stdcall CreateDirectoryA(const char *lpPathName, void *lpSecurityAttributes);
unsigned long __stdcall GetLastError(void);
unsigned long __stdcall GetCurrentProcessId(void);
]])
local kernel32 = ffi.load("kernel32")

local function createDirectory(path)
	path = tostring(path):gsub("[/\\]+$", "")
	if kernel32.CreateDirectoryA(path, nil) ~= 0 then return true end
	if tonumber(kernel32.GetLastError()) == 183 then return true end
	return nil, "CreateDirectoryA failed with Windows error " .. tostring(tonumber(kernel32.GetLastError()))
end

local function newArchiveUserPath()
	local processId = tonumber(kernel32.GetCurrentProcessId())
	local path = os.tmpname() .. "-pob-build-learning-" .. tostring(processId)
	os.remove(path)
	assert.is_truthy(createDirectory(path))
	return path
end

local function writeText(path, text)
	local file = assert(io.open(path, "wb"))
	assert(file:write(text))
	assert(file:close())
end

local function writeArchiveObject(paths, payload)
	local digest = sha.sha256(payload)
	local shard = digest:sub(1, 2)
	local objectDirectory = paths.root .. "\\objects\\" .. shard .. "\\"
	assert.is_truthy(createDirectory(paths.root .. "\\objects\\"))
	assert.is_truthy(createDirectory(objectDirectory))
	local objectPath = objectDirectory .. digest .. ".xml"
	writeText(objectPath, payload)
	return digest, "objects/" .. shard .. "/" .. digest .. ".xml"
end

local function activeSpecXml(spec, title, activeIndex)
	local nodes = { }
	for _, nodeId in ipairs(spec.allocatedNodeIds or { }) do nodes[#nodes + 1] = tostring(nodeId) end
	return string.format('<PathOfBuilding title="%s"><Tree activeSpec="%s"><Spec treeVersion="%s" classId="%s" ascendClassId="%s" secondaryAscendClassId="%s" nodes="%s"/></Tree></PathOfBuilding>',
		title or "fixture", tostring(activeIndex or 1), tostring(spec.treeVersion or ""), tostring(spec.classId or ""),
		tostring(spec.ascendancyId or ""), tostring(spec.secondaryAscendancyId or ""), table.concat(nodes, ","))
end

local function coverageObservation(lineageCharacter, xmlCharacter, treeVersion, ascendancy, mainSkill, claim, oldProfile, claimedPatch, codeSha256, codePath)
	local ascendancyId = ascendancy == "Hierophant" and 2 or 99
	local profile = {
		schema = "pob-ai-planner-build-profile", schemaVersion = 1,
		engine = { treeVersion = treeVersion, dataVersion = treeVersion:gsub("_", "."), pobVersion = "2.67.2" },
		character = { classId = 5, class = "Templar", ascendancyId = ascendancyId, ascendancy = ascendancy,
			secondaryAscendancyId = 0, secondaryAscendancy = "None", level = 95 },
		allocatedNodeIds = { },
		activeSpec = { index = 1, treeVersion = treeVersion, classId = 5, ascendancyId = ascendancyId,
			secondaryAscendancyId = 0, allocatedNodeIds = { }, allocatedBloodlineNodeIds = { } },
		configuredSkillEffects = {
			{ effectId = "Fireball", name = "Fireball", gemId = "Game/Fireball", gameId = "Game/Fireball", variantId = "Fireball" },
			{ effectId = "FlameWall", name = "Flame Wall", gemId = "Game/FlameWall", gameId = "Game/FlameWall", variantId = "FlameWall" },
		},
	}
	if oldProfile then
		profile.skillGroups = { { selectedMainGroup = true, enabled = true, slotEnabled = true,
			gems = { { gemId = "Game/Fireball", gameId = "Game/Fireball", variantId = "Fireball", enabled = true, isSupport = false } },
			skills = { { selectedMainSkill = true, name = "Fireball", effects = { { gemId = "Game/Fireball",
				effectId = "Fireball", name = "Fireball", gameId = "Game/Fireball", variantId = "Fireball", selected = true } } } } } }
	else
		profile.mainSkill = mainSkill
		if type(mainSkill) == "table" then
		local gemId = mainSkill.gemId or mainSkill.gameId
			profile.skillGroups = { { selectedMainGroup = true, enabled = true, slotEnabled = true,
				gems = { { gemId = gemId, gameId = mainSkill.gameId, variantId = mainSkill.variantId, enabled = true, isSupport = false } },
				skills = { { selectedMainSkill = true,
				name = mainSkill.name or mainSkill.variantId, effects = { {
					gemId = gemId, effectId = mainSkill.effectId or mainSkill.variantId,
					name = mainSkill.name or mainSkill.variantId, gameId = mainSkill.gameId,
					variantId = mainSkill.variantId, selected = true,
				} } } } } }
		end
	end
	return json.encode({
		recordType = "build_archive_observation", schemaVersion = 1,
		lineageSha256 = string.rep(lineageCharacter, 64), xmlSha256 = string.rep(xmlCharacter, 64),
		source = { provider = "fixture", claimedLeague = claim, claimedPatch = claimedPatch,
			codeSha256 = codeSha256, codePath = codePath }, profile = profile,
	})
end

local function targetProfile(treeVersion, ascendancy, mainSkill, secondaryAscendancyId, allocatedNodeIds)
	local ascendancyId = ascendancy == "Hierophant" and 2 or 99
	secondaryAscendancyId = secondaryAscendancyId == nil and 0 or secondaryAscendancyId
	allocatedNodeIds = allocatedNodeIds or { }
	local skillGroups = { }
	if type(mainSkill) == "table" then
		local effectId = mainSkill.effectId or mainSkill.variantId
		local gemId = mainSkill.gemId or mainSkill.gameId
		skillGroups = { { groupIndex = 1, selectedMainGroup = true, enabled = true, slotEnabled = true,
			gems = { { gemId = gemId, gameId = mainSkill.gameId, variantId = mainSkill.variantId,
				skillId = mainSkill.skillId, enabled = true, isSupport = false } },
			skills = { { skillIndex = 1, selectedMainSkill = true,
			name = mainSkill.name or mainSkill.variantId, effects = { {
				gemId = gemId, effectId = effectId, name = mainSkill.name or mainSkill.variantId,
				gameId = mainSkill.gameId, variantId = mainSkill.variantId, selected = true,
			} } } } } }
	end
	return {
		engine = { treeVersion = treeVersion },
		character = { classId = 5, class = "Templar", ascendancyId = ascendancyId, ascendancy = ascendancy,
			secondaryAscendancyId = secondaryAscendancyId },
		allocatedNodeIds = allocatedNodeIds,
		activeSpec = { index = 1, treeVersion = treeVersion, classId = 5, ascendancyId = ascendancyId,
			secondaryAscendancyId = secondaryAscendancyId,
			allocatedNodeIds = allocatedNodeIds },
		mainSkill = mainSkill,
		skillGroups = skillGroups,
	}
end

local function catalogPatchFingerprint(patch)
	return assert(PatchSkillCatalogFingerprint.Compute(patch))
end

local function writeCurrentPatchFixtureCatalog(userPath, currentTree)
	local paths = assert(StudyBuilds.GetPaths(userPath))
	for _, path in ipairs({ paths.studies, paths.root, paths.catalogDirectory }) do assert(createDirectory(path)) end
	local bloodlineNodeIds = { }
	for rawId, node in pairs(currentTree.nodes or { }) do
		if type(node) == "table" and node.isBloodline == true then bloodlineNodeIds[#bloodlineNodeIds + 1] = tonumber(node.id or rawId) end
	end
	table.sort(bloodlineNodeIds)
	local pobTags = { ["3.26"] = "v2.54.0", ["3.27"] = "v2.58.0", ["3.28"] = "v2.61.0", ["3.29"] = "v2.67.2" }
	local skillRows = {
		{ gemId = "Metadata/Items/Gems/SkillGemFireball", gameId = "Metadata/Items/Gems/SkillGemFireball", variantId = "Fireball",
			variantKey = "Metadata/Items/Gems/SkillGemFireball|Fireball",
			name = "Fireball", baseName = "Fireball", grantedEffectId = "Fireball", secondaryGrantedEffectId = "",
			category = "normal", tags = { "spell", "fire" } },
		{ gemId = "Metadata/Items/Gems/SkillGemFlameWall", gameId = "Metadata/Items/Gems/SkillGemFlameWall", variantId = "FlameWall",
			variantKey = "Metadata/Items/Gems/SkillGemFlameWall|FlameWall",
			name = "Flame Wall", baseName = "Flame Wall", grantedEffectId = "FlameWall", secondaryGrantedEffectId = "",
			category = "normal", tags = { "spell", "fire" } },
	}
	local patches = { }
	for _, patchName in ipairs({ "3.26", "3.27", "3.28", "3.29" }) do
		local patch = {
			patch = patchName, pobTag = pobTags[patchName], sourceRef = pobTags[patchName],
			sourceLabel = patchName .. " fixture", commit = string.rep("a", 40),
			treeVersion = patchName:gsub("%.", "_"),
			sourceHashes = { gems = string.rep("c", 64), tree = string.rep("d", 64),
				skills = string.rep("e", 64), data = string.rep("f", 64) },
			standardAscendancies = fixtureStandardAscendancies,
			excludedAlternateAscendancies = { }, excludedLeagueSpecificAscendancies = { },
			bloodlineNodeIds = patchName == "3.29" and bloodlineNodeIds or { },
			skills = skillRows,
			counts = { standardAscendancies = #fixtureStandardAscendancies, totalActiveGemRecords = #skillRows,
				normal = #skillRows, transfigured = 0, vaal = 0, vaalAlternateVariants = 0,
				supportGrantedEffects = 0, support_granted_effect = 0, other = 0,
				excludedAlternateAscendancies = 0, excludedLeagueSpecificAscendancies = 0 },
		}
		patch.catalogFingerprint = catalogPatchFingerprint(patch)
		patches[#patches + 1] = patch
	end
	writeText(paths.patchSkillCatalog, assert(json.encode({
		schema = "pob-ai-planner-patch-skill-catalog", schemaVersion = 5, featureSchemaVersion = 1,
		source = { method = "fixture" }, patches = patches,
	})))
end

describe("AI Planner persistent build archive", function()
	local build

	before_each(function()
		newBuild()
		build = _G.build
		TestSupport.MarkCalculationContentVerified()
		-- Summary now only aggregates skill combinations after proving standard
		-- ascendancy identity from the active XML Spec.
		build.spec:SelectAscendClass(1)
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.skillsTab:PasteSocketGroup("Flame Wall 1/0  1")
		build.mainSocketGroup = 1
		build.calcsTab:BuildOutput()
	end)

	it("returns a stable missing-reference result before the first local XML archive", function()
		local userPath = newArchiveUserPath()
		local archived, lookupError, lookupCode = StudyBuilds.FindArchivedObservationByReference(userPath,
			"local-xml://sha256/" .. string.rep("a", 64))
		assert.is_nil(archived)
		assert.are.equal("No archived build matches this source reference", lookupError)
		assert.are.equal("source_reference_not_archived", lookupCode)
	end)

	it("archives the original XML once and counts unique build lineages by configured effect", function()
		local userPath = newArchiveUserPath()
		writeCurrentPatchFixtureCatalog(userPath, build.spec.tree)
		local xmlText = assert(build:SaveDB("archive fixture"))
		local sourceXmlText, sourceSkillReplacements = xmlText:gsub('skillId="Fireball"', 'skillId="HistoricalFireball"', 1)
		assert.are.equal(1, sourceSkillReplacements)
		local sourceXmlSha256 = sha.sha256(sourceXmlText)
		local sourceXmlPath = "source-xml/LocalXML/localxml-" .. sourceXmlSha256 .. ".xml"
		local archivePaths = assert(StudyBuilds.GetPaths(userPath))
		local sourceDirectory = archivePaths.root .. "\\source-xml\\LocalXML\\"
		assert.is_truthy(createDirectory(archivePaths.root .. "\\source-xml\\"))
		assert.is_truthy(createDirectory(sourceDirectory))
		writeText(sourceDirectory .. "localxml-" .. sourceXmlSha256 .. ".xml", sourceXmlText)
		local first, firstError = StudyBuilds.ArchiveXML(build, xmlText, userPath, {
			type = "public_build_study", provider = "fixture-source", reference = "https://example.invalid/build/1",
			claimedLeague = "Affliction",
			sourceUrl = "https://example.invalid/guide/1", claimedPatch = "3.27",
			rightsStatus = "unverified", rightsEvidenceUrl = "https://example.invalid/terms",
			acquisitionMethod = "visible_ui_copy", codeSha256 = string.rep("a", 64),
			codePath = "source-codes/fixture/one.pob", acquiredAt = "2026-10-24T12:00:00Z",
			sourceXmlSha256 = sourceXmlSha256, sourceXmlPath = sourceXmlPath,
			claimedMainSkill = { gemId = "Metadata/Items/Gems/SkillGemFireball",
				gameId = "Metadata/Items/Gems/SkillGemFireball", variantId = "Fireball", effectId = "Fireball",
				name = "Fireball", evidenceUrl = "https://example.invalid/guide/1", basis = "fixture_source_claim" },
		}, createDirectory, sourceXmlText)
		assert.is_truthy(first, firstError)
		assert.are.equal("stored", first.storageStatus)
		assert.are.equal("reviewed_hypotheses_untested", first.buildReview.status, tostring(first.buildReview.error))
		assert.is_true(first.buildReview.hypothesisCount > 0)
		assert.is_truthy(first.objectPath)
		local archivedSnapshot, snapshotError = StudyBuilds.FindArchivedObservationByReference(userPath,
			"https://example.invalid/build/1")
		assert.is_truthy(archivedSnapshot, snapshotError)
		assert.are.equal(first.observationId, archivedSnapshot.observationId)
		assert.are.equal(first.xmlSha256, archivedSnapshot.xmlSha256)
		assert.are.equal(first.lineageSha256, archivedSnapshot.lineageSha256)
		assert.are.equal("https://example.invalid/guide/1", archivedSnapshot.source.sourceUrl)
		assert.are.equal("3.27", archivedSnapshot.source.claimedPatch)
		assert.are.equal("unverified", archivedSnapshot.source.rightsStatus)
		assert.are.equal("https://example.invalid/terms", archivedSnapshot.source.rightsEvidenceUrl)
		assert.are.equal("visible_ui_copy", archivedSnapshot.source.acquisitionMethod)
		assert.are.equal(string.rep("a", 64), archivedSnapshot.source.codeSha256)
		assert.are.equal("source-codes/fixture/one.pob", archivedSnapshot.source.codePath)
		assert.are.equal(sourceXmlSha256, archivedSnapshot.source.sourceXmlSha256)
		assert.are.equal(sourceXmlPath, archivedSnapshot.source.sourceXmlPath)
		assert.are.equal("HistoricalFireball", archivedSnapshot.profile.mainSkill.sourcePatchSkillId)
		assert.are.equal(sourceXmlSha256, archivedSnapshot.profile.mainSkill.sourcePatchSkillIdSourceXmlSha256)
		assert.are.equal("2026-10-24T12:00:00Z", archivedSnapshot.source.acquiredAt)
		assert.are.equal("Metadata/Items/Gems/SkillGemFireball", archivedSnapshot.source.claimedMainSkill.gemId)
		assert.are.equal("Metadata/Items/Gems/SkillGemFireball", archivedSnapshot.source.claimedMainSkill.gameId)
		assert.are.equal("Fireball", archivedSnapshot.source.claimedMainSkill.variantId)
		assert.are.equal("https://example.invalid/guide/1", archivedSnapshot.source.claimedMainSkill.evidenceUrl)
		local object = assert(io.open(first.objectPath, "rb"))
		assert.are.equal(xmlText, object:read("*a"))
		object:close()

		local duplicate, duplicateError = StudyBuilds.ArchiveXML(build, xmlText, userPath, {
			type = "public_build_study", provider = "second-source", reference = "https://example.invalid/build/2",
		}, createDirectory)
		assert.is_truthy(duplicate, duplicateError)
		assert.are.equal("duplicate", duplicate.storageStatus)
		assert.are.equal("already_reviewed", duplicate.buildReview.status)
		assert.are_not.equal(first.observationId, duplicate.observationId)
		local patchedCatalogFile = assert(io.open(archivePaths.patchSkillCatalog, "rb"))
		local patchedCatalogText = patchedCatalogFile:read("*a")
		patchedCatalogFile:close()
		local patchedCatalog = assert(json.decode(patchedCatalogText))
		for _, patch in ipairs(patchedCatalog.patches) do
			if patch.patch == "3.29" then
				for _, skill in ipairs(patch.skills) do
					if skill.gameId == "Metadata/Items/Gems/SkillGemFireball" and skill.variantId == "Fireball" then
						skill.grantedEffectId = "HistoricalFireball"
					end
				end
				patch.catalogFingerprint = catalogPatchFingerprint(patch)
			end
		end
		writeText(archivePaths.patchSkillCatalog, assert(json.encode(patchedCatalog)))

		local summary, summaryError = StudyBuilds.Summary(userPath, build)
		assert.is_truthy(summary, summaryError)
		assert.are.equal(2, summary.storage.sourceObservations)
		assert.are.equal(1, summary.storage.objectCount)
		assert.are.equal(1, summary.storage.uniqueBuildLineages)
		assert.is_true(summary.catalog.activeEffectCount > 0)
		assert.is_true(summary.catalog.coveredEffects >= 1,
			"expected strict build coverage; audit=" .. assert(json.encode(summary.patchSkillCatalog.audit.excludedByReason))
				.. "; identity=" .. assert(json.encode(assert(StudyBuilds.ProfileFromBuild(build)).character)))
		if first.configuredEffectCount >= 2 then
			assert.is_true(#summary.observedPairs >= 1, "expected configured pair; profile=" .. assert(json.encode(assert(StudyBuilds.ProfileFromBuild(build)).configuredSkillEffects))
				.. "; audit=" .. assert(json.encode(summary.patchSkillCatalog.audit.excludedByReason)))
			assert.are.equal("co_observed_only_synergy_untested", summary.observedPairs[1].evidence)
			assert.are.equal("3.29", summary.observedPairs[1].patch)
			assert.is_true(summary.observedPairs[1].exactVariantIdentity)
		else
			assert.are.equal(0, #summary.observedPairs,
				"one configured main effect does not establish a multi-skill co-observation")
		end
		assert.are.equal("unverified_source_claims", summary.leagueClaims.status)
		assert.are.equal("Affliction", summary.leagueClaims.rows[1].claim)
		assert.are.equal(1, summary.leagueClaims.rows[1].uniqueBuildLineages)
		assert.are.equal("unknown", assert(StudyBuilds.ProfileFromBuild(build)).league.status)
		assert.is_false(assert(StudyBuilds.ProfileFromBuild(build)).configuredSkillEffects[1].trainingEligible == true)
		local reviewSummary = assert(BuildReviewPair.Summary(userPath))
		assert.are.equal(1, reviewSummary.storage.reviewedLineages)
		assert.is_true(reviewSummary.counts.hypotheses > 0)
		assert.is_true(reviewSummary.counts.critiquesAndQuestions > 0)
		assert.is_true(reviewSummary.counts.scoutProposed > 0)
		assert.is_true(reviewSummary.counts.scoutCandidates >= reviewSummary.counts.scoutProposed)
		assert.are.equal(reviewSummary.counts.scoutCandidates - reviewSummary.counts.scoutProposed,
			reviewSummary.counts.scoutUnreviewedCandidates)
		assert.are.equal(0, reviewSummary.counts.exactTests)
		local reviewCards = assert(BuildReviewPair.ListPage(userPath, "facts", nil, 1, 20))
		assert.is_true(#reviewCards.items > 0)
		assert.are.equal(first.observationId, reviewCards.items[1].archiveObservationId)
		assert.are.equal(first.xmlSha256, reviewCards.items[1].xmlSha256)
		assert.are.equal("https://example.invalid/build/1", reviewCards.items[1].sourceReference)
	end)

	it("rejects oversized or missing build inputs before writing", function()
		local userPath = newArchiveUserPath()
		local archived, archiveError = StudyBuilds.ArchiveXML(build, string.rep("x", 16 * 1024 * 1024 + 1), userPath, { }, createDirectory)
		assert.is_nil(archived)
		assert.is_truthy(archiveError and archiveError:find("16 MiB", 1, true))
		archived, archiveError = StudyBuilds.ArchiveXML(build, "", userPath, { }, createDirectory)
		assert.is_nil(archived)
		assert.is_truthy(archiveError)
	end)

	it("resolves a source revision by code hash when the public reference has several snapshots", function()
		local userPath = newArchiveUserPath()
		local paths = assert(StudyBuilds.GetPaths(userPath))
		assert.is_truthy(createDirectory(paths.studies))
		assert.is_truthy(createDirectory(paths.root))
		local sourceDirectory = paths.root .. "\\source-codes"
		local fixtureDirectory = sourceDirectory .. "\\fixture"
		assert.is_truthy(createDirectory(sourceDirectory))
		assert.is_truthy(createDirectory(fixtureDirectory))

		local reference = "https://example.invalid/build/revised"
		local firstCode, secondCode = "fixture-source-revision-one", "fixture-source-revision-two"
		local firstCodeHash, secondCodeHash = sha.sha256(firstCode), sha.sha256(secondCode)
		writeText(fixtureDirectory .. "\\revision-one.pob", firstCode)
		writeText(fixtureDirectory .. "\\revision-two.pob", secondCode)

		local firstXml = assert(build:SaveDB("source revision one"))
		local first, firstError = StudyBuilds.ArchiveXML(build, firstXml, userPath, {
			type = "curated_public_build", provider = "fixture", reference = reference,
			codeSha256 = firstCodeHash, codePath = "source-codes/fixture/revision-one.pob",
		}, createDirectory)
		assert.is_truthy(first, firstError)

		build.characterLevel = build.characterLevel + 1
		build.calcsTab:BuildOutput()
		local secondXml = assert(build:SaveDB("source revision two"))
		assert.are_not.equal(sha.sha256(firstXml), sha.sha256(secondXml))
		local second, secondError = StudyBuilds.ArchiveXML(build, secondXml, userPath, {
			type = "curated_public_build", provider = "fixture", reference = reference,
			codeSha256 = secondCodeHash, codePath = "source-codes/fixture/revision-two.pob",
			targetScopeStatus = "out_of_target_scope", targetScopeReason = "skill_category_out_of_scope",
			nativeImportStatus = "native_imported",
		}, createDirectory)
		assert.is_truthy(second, secondError)

		local ambiguous, referenceError = StudyBuilds.FindArchivedObservationByReference(userPath, reference)
		assert.is_nil(ambiguous)
		assert.is_truthy(referenceError and referenceError:find("multiple archived snapshots", 1, true))
		local firstRevision = assert(StudyBuilds.FindArchivedObservationBySourceCode(userPath, reference, firstCodeHash))
		local secondRevision = assert(StudyBuilds.FindArchivedObservationBySourceCode(userPath, reference, secondCodeHash))
		assert.are.equal(first.observationId, firstRevision.observationId)
		assert.are.equal(second.observationId, secondRevision.observationId)
		assert.are_not.equal(firstRevision.observationId, secondRevision.observationId)
		assert.are.equal("out_of_target_scope", secondRevision.source.targetScopeStatus)
		assert.are.equal("skill_category_out_of_scope", secondRevision.source.targetScopeReason)
		assert.are.equal("native_imported", secondRevision.source.nativeImportStatus)
	end)

	it("skips a previously archived lineage when public ingestion requests unique builds", function()
		local userPath = newArchiveUserPath()
		writeCurrentPatchFixtureCatalog(userPath, build.spec.tree)
		local xmlText = assert(build:SaveDB("unique-lineage fixture"))
		local first, firstError = StudyBuilds.ArchiveXML(build, xmlText, userPath, {
			type = "curated_public_build", provider = "fixture", reference = "https://example.invalid/build/unique-1",
		}, createDirectory)
		assert.is_truthy(first, firstError)
		local duplicate, duplicateError = StudyBuilds.ArchiveXML(build, xmlText, userPath, {
			type = "curated_public_build", provider = "fixture", reference = "https://example.invalid/build/unique-2",
			skipDuplicateLineage = true,
		}, createDirectory)
		assert.is_truthy(duplicate, duplicateError)
		assert.is_true(duplicate.duplicateLineage)
		assert.are.equal("duplicate_lineage", duplicate.storageStatus)
		assert.are.equal(first.lineageSha256, duplicate.lineageSha256)
		local summary, summaryError = StudyBuilds.Summary(userPath, build)
		assert.is_truthy(summary, summaryError)
		assert.are.equal(1, summary.storage.sourceObservations)
		assert.are.equal(1, summary.storage.objectCount)
		assert.are.equal(1, summary.storage.uniqueBuildLineages)
	end)

	it("keeps source rights pending and records co-occurrence as unverified league-neutral data", function()
		local profile = assert(StudyBuilds.ProfileFromBuild(build))
		assert.are.equal("observation_only_pending_rights_and_exact_labels", profile.trainingStatus)
		assert.are.equal("native_profile_complete", profile.archiveReadinessStatus)
		assert.are.equal("unknown", profile.league.status)
		assert.is_nil(profile.league.value)
		assert.is_truthy(#profile.configuredSkillEffects >= 2)
		assert.is_table(profile.mainSkill)
		assert.are.equal("identified", profile.mainSkillStatus)
		assert.are.equal("selected_main_skill_identified", profile.mainSkillResolutionStatus)
		assert.is_truthy(#profile.mainSkillCandidates >= 1)
		assert.is_true(#profile.skillGroups > 0)
		assert.are.equal("normal", profile.mainSkill.category)
	end)

	it("archives a complete profile and exposes configured skills when no single Main Skill is selected", function()
		build.mainSocketGroup = 0
		local profile = assert(StudyBuilds.ProfileFromBuild(build))
		assert.are.equal("native_profile_complete", profile.archiveReadinessStatus)
		assert.are.equal("unidentified", profile.mainSkillStatus)
		assert.are.equal("configured_skill_effects_preserved_without_single_selection", profile.mainSkillResolutionStatus)
		assert.is_nil(profile.mainSkill)
		local candidatesByName = { }
		for _, candidate in ipairs(profile.mainSkillCandidates) do candidatesByName[candidate.name] = true end
		assert.is_true(candidatesByName.Fireball, "Fireball identity must remain searchable as a configured effect")
		assert.is_true(candidatesByName["Flame Wall"], "Flame Wall identity must remain searchable as a configured effect")
	end)

	it("profiles socketed and Bitterdream-granted supports with exact target and item origin", function()
		build.skillsTab:PasteSocketGroup("Slot: Weapon 1\nWinter Orb 20/0  1\nControlled Destruction 20/0  1\n")
		local item = new("Item"):Item("Rarity: Unique\nBitterdream\nShadow Sceptre\n--------\n"
			.. "20% increased Elemental Damage\n"
			.. "Socketed Gems are Supported by Level 15 Bonechill\n"
			.. "Socketed Gems are Supported by Level 15 Hypothermia\n"
			.. "Socketed Gems are Supported by Level 15 Ice Bite\n"
			.. "Socketed Gems are Supported by Level 15 Cold Penetration\n"
			.. "Socketed Gems are Supported by Level 15 Added Cold Damage\n"
			.. "Socketed Gems are Supported by Level 15 Inspiration")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Weapon 1"].selItemId = item.id
		build.itemsTab.slots["Weapon 1"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.mainSocketGroup = #build.skillsTab.socketGroupList
		build.calcsTab:BuildOutput()

		local profile = assert(StudyBuilds.ProfileFromBuild(build))
		assert.are.equal(2, profile.supportFeatureSchemaVersion)
		local group = profile.skillGroups[build.mainSocketGroup]
		assert.are.equal(2, group.supportProfileVersion)
		assert.is_true(group.socketValidation.valid)
		assert.are.equal("linked", group.socketValidation.status)
		local skill = group.skills[1]
		assert.are.equal(2, skill.supportProfileVersion)
		local socketed, granted, supportSummary = nil, nil, { }
		for _, support in ipairs(skill.supports) do
			supportSummary[#supportSummary + 1] = table.concat({ tostring(support.effectId), tostring(support.origin),
				tostring(support.level), tostring(support.active) }, "/")
			if support.origin == "socketed_gem" and support.effectId == "SupportControlledDestruction" then socketed = support end
			if support.origin == "item_granted" and support.active then granted = granted or support end
		end
		assert.is_truthy(socketed, "socketed support must remain distinguishable from item grants")
		assert.is_true(socketed.active)
		assert.is_true(socketed.calculatorApplied)
		assert.is_true(socketed.playableActive)
		assert.are.equal("matched", socketed.socketState)
		assert.are.equal("validated_link", socketed.linkState)
		assert.are.equal(build.mainSocketGroup, socketed.targetGroupIndex)
		assert.are.equal(1, socketed.targetSkillIndex)
		assert.are.equal("WinterOrb", socketed.targetEffectId)
		assert.is_truthy(granted, "Bitterdream should contribute a native item-granted support; observed: " .. table.concat(supportSummary, ","))
		assert.are.equal("Weapon 1", granted.sourceSlot)
		assert.are.equal(15, granted.level)
		assert.are.equal(64, #granted.sourceItemFingerprint)
		assert.are.equal(profile.itemSlots[1].itemFingerprint, granted.sourceItemFingerprint)
		assert.is_true(granted.active)
		assert.is_true(granted.playableActive)
		assert.are.equal("not_applicable", granted.socketState)
		assert.are.equal("verified_item_local", granted.linkState)
		assert.is_true(table.concat(profile.itemGrantedSupportEffectIds, ","):find(granted.effectId, 1, true) ~= nil)

		local availableSupport
		for _, effect in ipairs(profile.availableSkillEffects) do
			if effect.effectId == granted.effectId then availableSupport = effect; break end
		end
		assert.is_truthy(availableSupport)
		assert.are_not.equal(profile.mainSkill.gemId, availableSupport.gemId,
			"available item-granted support identity must not inherit the Winter Orb gem ID")

		local itemSocketIndex = profile.skillGroups[build.mainSocketGroup].socketValidation.firstSocketIndex + 1
		build.itemsTab.items[item.id].sockets[itemSocketIndex].color = "R"
		local invalidProfile = assert(StudyBuilds.ProfileFromBuild(build))
		local invalidSkill = invalidProfile.skillGroups[build.mainSocketGroup].skills[1]
		local invalidSocketed
		for _, support in ipairs(invalidSkill.supports) do
			if support.origin == "socketed_gem" and support.effectId == socketed.effectId then invalidSocketed = support end
		end
		assert.is_truthy(invalidSocketed)
		assert.is_true(invalidSocketed.calculatorApplied,
			"PoB may apply the configured support while its physical socket state is invalid")
		assert.is_false(invalidSocketed.playableActive,
			"a calculator-applied support with an invalid physical socket/link must not become playable")
		assert.are.equal("invalid", invalidSocketed.socketState)
		assert.are.equal("invalid", invalidSocketed.linkState)
	end)

	it("counts ten-build targets by patch, exact main gem variant and standard ascendancy", function()
		local userPath = newArchiveUserPath()
		local paths = assert(StudyBuilds.GetPaths(userPath))
		assert.is_truthy(createDirectory(paths.studies))
		assert.is_truthy(createDirectory(paths.root))
		assert.is_truthy(createDirectory(paths.catalogDirectory))
		local sourceCodeDirectory = paths.root .. "\\source-codes\\"
		assert.is_truthy(createDirectory(sourceCodeDirectory))
		local sourceCodePath = "source-codes\\same-build.pob"
		local sourceCodeText = "fixture source code shared by metadata reimports"
		writeText(paths.root .. "\\" .. sourceCodePath, sourceCodeText)
		local sourceCodeSha256 = sha.sha256(sourceCodeText)
		local patches = { }
		for _, patch in ipairs({ "3.26", "3.27", "3.28", "3.29" }) do
			local pobTags = { ["3.26"] = "v2.54.0", ["3.27"] = "v2.58.0", ["3.28"] = "v2.61.0", ["3.29"] = "v2.67.2" }
			patches[#patches + 1] = {
				patch = patch, pobTag = pobTags[patch], sourceRef = pobTags[patch], sourceLabel = patch .. " fixture",
				commit = string.rep("a", 40), treeVersion = patch:gsub("%.", "_"),
				catalogFingerprint = string.rep("b", 64), sourceHashes = { gems = string.rep("c", 64), tree = string.rep("d", 64),
					skills = string.rep("e", 64), data = string.rep("f", 64) },
				counts = { standardAscendancies = #fixtureStandardAscendancies, totalActiveGemRecords = 0, normal = 0, transfigured = 0,
					vaal = 0, vaalAlternateVariants = 0, supportGrantedEffects = 0, support_granted_effect = 0, other = 0,
					excludedAlternateAscendancies = 0, excludedLeagueSpecificAscendancies = 0 }, standardAscendancies = fixtureStandardAscendancies,
				bloodlineNodeIds = { 542, 10696 }, skills = { }, excludedAlternateAscendancies = { }, excludedLeagueSpecificAscendancies = { },
			}
		end
		patches[3].skills = {
			{ gemId = "Game/Fireball", gameId = "Game/Fireball", variantId = "Fireball", variantKey = "Game/Fireball|Fireball",
				name = "Fireball", baseName = "Fireball", category = "normal", grantedEffectId = "Fireball",
				secondaryGrantedEffectId = "", tags = { "spell" } },
			{ gemId = "Game/IceNova", gameId = "Game/IceNova", variantId = "IceNovaAltX", variantKey = "Game/IceNova|IceNovaAltX",
				name = "Ice Nova of Frostbolts", baseName = "Ice Nova of Frostbolts", category = "transfigured",
				grantedEffectId = "IceNovaAltX", secondaryGrantedEffectId = "", tags = { "spell", "cold" } },
			{ gemId = "support-prismatic-burst", gameId = "Game/PrismaticBurst", variantId = "PrismaticBurst",
				variantKey = "Game/PrismaticBurst|PrismaticBurst", name = "Prismatic Burst", category = "support_granted_effect",
				baseName = "Prismatic Burst", grantedEffectId = "PrismaticBurst", secondaryGrantedEffectId = "", tags = { "support", "spell" } },
			{ gemId = "Metadata/Items/Gems/SkillGemVaalIceNova", gameId = "Metadata/Items/Gems/SkillGemVaalIceNova",
				variantId = "IceNovaAltX", variantKey = "Metadata/Items/Gems/SkillGemVaalIceNova|IceNovaAltX",
				name = "Vaal Ice Nova of Frostbolts", baseName = "Vaal Ice Nova of Frostbolts", category = "vaal",
				grantedEffectId = "VaalIceNovaAltX", secondaryGrantedEffectId = "", tags = { "vaal", "spell" } },
			{ gemId = "Metadata/Items/Gems/SkillGemVaalIceNovaAltX", gameId = "Metadata/Items/Gems/SkillGemVaalIceNova",
				variantId = "VaalIceNovaAltX", variantKey = "Metadata/Items/Gems/SkillGemVaalIceNova|VaalIceNovaAltX",
				name = "Vaal Ice Nova of Frostbolts", baseName = "Ice Nova of Frostbolts", category = "vaal", origin = "native_vaal_alt_derivation",
				grantedEffectId = "VaalIceNova", secondaryGrantedEffectId = "IceNovaAltX", tags = { "vaal", "spell" } },
			{ gemId = "Game/FlameWall", gameId = "Game/FlameWall", variantId = "FlameWall", variantKey = "Game/FlameWall|FlameWall",
				name = "Flame Wall", baseName = "Flame Wall", category = "normal", grantedEffectId = "FlameWall",
				secondaryGrantedEffectId = "", tags = { "spell", "fire" } },
		}
		patches[3].counts = { standardAscendancies = #fixtureStandardAscendancies, totalActiveGemRecords = 6, normal = 2,
			transfigured = 1, vaal = 2, vaalAlternateVariants = 1,
				supportGrantedEffects = 1, support_granted_effect = 1, other = 0,
				excludedAlternateAscendancies = 0, excludedLeagueSpecificAscendancies = 0 }
		for _, patch in ipairs(patches) do patch.catalogFingerprint = catalogPatchFingerprint(patch) end
		local catalogText = assert(json.encode({
			schema = "pob-ai-planner-patch-skill-catalog", schemaVersion = 5, featureSchemaVersion = 1,
			source = { method = "fixture" }, patches = patches,
		}))
		writeText(paths.patchSkillCatalog, catalogText)
		local normalProfile = targetProfile("3_28", "Hierophant", { gameId = "Game/Fireball", variantId = "Fireball" })
		local standardNormal, normalRejection = StudyBuilds.ValidateTargetBuild(userPath, normalProfile)
		assert.is_truthy(standardNormal, tostring(normalRejection) .. "; activeSpec=" .. tostring(type(normalProfile.activeSpec))
			.. "; activeSpecTree=" .. tostring(normalProfile.activeSpec and normalProfile.activeSpec.treeVersion)
			.. "; bloodlineIds=" .. tostring(patches[3].bloodlineNodeIds and #patches[3].bloodlineNodeIds))
		assert.are.equal("3.28", standardNormal.patch)
		assert.are.equal("normal", standardNormal.category)
		local normalScope = StudyBuilds.ClassifyTargetScope(userPath, normalProfile)
		assert.are.equal("in_scope", normalScope.status)
		assert.are.same(standardNormal, normalScope.eligibility)
		local mismatchedEffectProfile = targetProfile("3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "FlameWall" })
		local mismatchedEffect, mismatchedEffectReason = StudyBuilds.ValidateTargetBuild(userPath, mismatchedEffectProfile)
		assert.is_nil(mismatchedEffect)
		assert.are.equal("skill_effect_catalog_mismatch", mismatchedEffectReason)
		local standardTransfigured = assert(StudyBuilds.ValidateTargetBuild(userPath,
			targetProfile("3_28", "Hierophant", { gameId = "Game/IceNova", variantId = "IceNovaAltX" })))
		assert.are.equal("transfigured", standardTransfigured.category)
		local historicalAliasXml = '<PathOfBuilding><Build mainSkillIndex="1"/><Skills activeSkillSet="1"><SkillSet id="1">'
			.. '<Skill enabled="true" mainActiveSkill="1"><Gem gemId="Game/IceNova" variantId="IceNovaAltX" '
			.. 'skillId="IceNovaAltX" enabled="true"/></Skill></SkillSet></Skills></PathOfBuilding>'
		local historicalAliasProfile = targetProfile("3_28", "Hierophant", {
			gameId = "Game/IceNova", variantId = "IceNovaAltX", effectId = "RuntimeIceNovaAltX",
		})
		local historicalAlias, historicalAliasReason = StudyBuilds.ValidateTargetBuild(userPath,
			historicalAliasProfile, historicalAliasXml)
		assert.is_truthy(historicalAlias, tostring(historicalAliasReason))
		assert.are.equal("IceNovaAltX", historicalAlias.sourcePatchSkillId)
		local forgedAliasXml = historicalAliasXml:gsub('skillId="IceNovaAltX"', 'skillId="ForgedIceNovaAltX"')
		local forgedAlias, forgedAliasReason = StudyBuilds.ValidateTargetBuild(userPath, historicalAliasProfile, forgedAliasXml)
		assert.is_nil(forgedAlias)
		assert.are.equal("skill_effect_catalog_mismatch", forgedAliasReason)
		local unprovenAlias, unprovenAliasReason = StudyBuilds.ValidateTargetBuild(userPath, historicalAliasProfile)
		assert.is_nil(unprovenAlias)
		assert.are.equal("skill_effect_catalog_mismatch", unprovenAliasReason)
		local supportTarget, supportRejection = StudyBuilds.ValidateTargetBuild(userPath,
			targetProfile("3_28", "Hierophant", { gameId = "Game/PrismaticBurst", variantId = "PrismaticBurst" }))
		assert.is_nil(supportTarget)
		assert.are.equal("support_granted_effect_not_independent_target", supportRejection)
		local supportScope = StudyBuilds.ClassifyTargetScope(userPath,
			targetProfile("3_28", "Hierophant", { gameId = "Game/PrismaticBurst", variantId = "PrismaticBurst" }))
		assert.are.equal("out_of_target_scope", supportScope.status)
		assert.are.equal(supportRejection, supportScope.reason)
		local vaalAlternate, vaalRejection = StudyBuilds.ValidateTargetBuild(userPath,
			targetProfile("3_28", "Hierophant", { gameId = "Metadata/Items/Gems/SkillGemVaalIceNova", variantId = "IceNovaAltX" }))
		assert.is_nil(vaalAlternate)
		assert.are.equal("skill_category_out_of_scope", vaalRejection)
		local excluded, rejection = StudyBuilds.ValidateTargetBuild(userPath,
			targetProfile("3_28", "Reliquarian", { gameId = "Game/Fireball", variantId = "Fireball" }))
		assert.is_nil(excluded)
		assert.are.equal("nonstandard_or_missing_ascendancy", rejection)
		local secondaryAscendancy, secondaryReason = StudyBuilds.ValidateTargetBuild(userPath,
			targetProfile("3_28", "Hierophant", { gameId = "Game/Fireball", variantId = "Fireball" }, 6))
		assert.is_nil(secondaryAscendancy)
		assert.are.equal("event_secondary_ascendancy", secondaryReason)
		local bloodlineNode, bloodlineReason = StudyBuilds.ValidateTargetBuild(userPath,
			targetProfile("3_28", "Hierophant", { gameId = "Game/Fireball", variantId = "Fireball" }, 0, { 542 }))
		assert.is_nil(bloodlineNode)
		assert.are.equal("event_bloodline_node_allocated", bloodlineReason)
		local mismatchedActiveSpec = targetProfile("3_28", "Hierophant", { gameId = "Game/Fireball", variantId = "Fireball" })
		mismatchedActiveSpec.activeSpec.treeVersion = "3_29"
		local mismatchedTarget, mismatchReason = StudyBuilds.ValidateTargetBuild(userPath, mismatchedActiveSpec)
		assert.is_nil(mismatchedTarget)
		assert.are.equal("active_spec_profile_mismatch", mismatchReason)
		local mismatchedSecondary = targetProfile("3_28", "Hierophant", { gameId = "Game/Fireball", variantId = "Fireball" })
		mismatchedSecondary.character.secondaryAscendancyId = 6
		local mismatchedSecondaryTarget, mismatchedSecondaryReason = StudyBuilds.ValidateTargetBuild(userPath, mismatchedSecondary)
		assert.is_nil(mismatchedSecondaryTarget)
		assert.are.equal("active_spec_profile_mismatch", mismatchedSecondaryReason)
		local malformedSecondary = targetProfile("3_28", "Hierophant", { gameId = "Game/Fireball", variantId = "Fireball" }, "invalid")
		local malformedSecondaryTarget, malformedSecondaryReason = StudyBuilds.ValidateTargetBuild(userPath, malformedSecondary)
		assert.is_nil(malformedSecondaryTarget)
		assert.are.equal("secondary_ascendancy_unverified", malformedSecondaryReason)
		local mismatchedAscendancyName = targetProfile("3_28", "Hierophant", { gameId = "Game/Fireball", variantId = "Fireball" })
		mismatchedAscendancyName.character.ascendancy = "Guardian"
		local mismatchedAscendancyTarget, mismatchedAscendancyReason = StudyBuilds.ValidateTargetBuild(userPath, mismatchedAscendancyName)
		assert.is_nil(mismatchedAscendancyTarget)
		assert.are.equal("nonstandard_or_missing_ascendancy", mismatchedAscendancyReason)
		local truncatedCatalog = assert(json.decode(catalogText))
		table.remove(truncatedCatalog.patches[3].bloodlineNodeIds)
		writeText(paths.patchSkillCatalog, assert(json.encode(truncatedCatalog)))
		local truncatedCatalogTarget, truncatedCatalogReason = StudyBuilds.ValidateTargetBuild(userPath, normalProfile)
		assert.is_nil(truncatedCatalogTarget)
		assert.are.equal("catalog_fingerprint_mismatch", truncatedCatalogReason)
		local editedSkillCatalog = assert(json.decode(catalogText))
		editedSkillCatalog.patches[3].skills[1].name = "Forged Catalog Skill"
		writeText(paths.patchSkillCatalog, assert(json.encode(editedSkillCatalog)))
		local editedSkillTarget, editedSkillReason = StudyBuilds.ValidateTargetBuild(userPath, normalProfile)
		assert.is_nil(editedSkillTarget)
		assert.are.equal("catalog_fingerprint_mismatch", editedSkillReason)
		local editedAscendancyCatalog = assert(json.decode(catalogText))
		for _, ascendancy in ipairs(editedAscendancyCatalog.patches[3].standardAscendancies) do
			if ascendancy.id == "Hierophant" then ascendancy.name = "Reliquarian" end
		end
		editedAscendancyCatalog.patches[3].catalogFingerprint = catalogPatchFingerprint(editedAscendancyCatalog.patches[3])
		writeText(paths.patchSkillCatalog, assert(json.encode(editedAscendancyCatalog)))
		local editedAscendancyTarget, editedAscendancyReason = StudyBuilds.ValidateTargetBuild(userPath, normalProfile)
		assert.is_nil(editedAscendancyTarget)
		assert.are.equal("catalog_standard_ascendancy_invalid", editedAscendancyReason)
		local editedAscendancyIndex = assert(json.decode(catalogText))
		for _, ascendancy in ipairs(editedAscendancyIndex.patches[3].standardAscendancies) do
			if ascendancy.id == "Inquisitor" then ascendancy.ascendClassId = 2
			elseif ascendancy.id == "Hierophant" then ascendancy.ascendClassId = 1 end
		end
		editedAscendancyIndex.patches[3].catalogFingerprint = catalogPatchFingerprint(editedAscendancyIndex.patches[3])
		writeText(paths.patchSkillCatalog, assert(json.encode(editedAscendancyIndex)))
		local editedAscendancyIndexTarget, editedAscendancyIndexReason = StudyBuilds.ValidateTargetBuild(userPath, normalProfile)
		assert.is_nil(editedAscendancyIndexTarget)
		assert.are.equal("catalog_standard_ascendancy_invalid", editedAscendancyIndexReason)
		local sparseCatalog = assert(json.decode(catalogText))
		sparseCatalog.patches[3].bloodlineNodeIds[2] = json.null
		sparseCatalog.patches[3].bloodlineNodeIds[3] = 10696
		writeText(paths.patchSkillCatalog, assert(json.encode(sparseCatalog)))
		local sparseCatalogTarget, sparseCatalogReason = StudyBuilds.ValidateTargetBuild(userPath, normalProfile)
		assert.is_nil(sparseCatalogTarget)
		assert.are.equal("catalog_bloodline_nodes_invalid", sparseCatalogReason)
		writeText(paths.patchSkillCatalog, catalogText)
		local outOfRange, versionRejection = StudyBuilds.ValidateTargetBuild(userPath, {
			engine = { treeVersion = "3_30" },
			character = { classId = 5, class = "Templar", ascendancy = "Hierophant" },
			mainSkill = { gameId = "Game/Fireball", variantId = "Fireball" },
		})
		assert.is_nil(outOfRange)
		assert.are.equal("tree_not_in_3_24_to_3_29", versionRejection)
		local historicalScope = StudyBuilds.ClassifyTargetScope(userPath, {
			engine = { treeVersion = "3_23" },
			character = { classId = 5, class = "Templar", ascendancy = "Hierophant" },
			mainSkill = { gameId = "Game/Fireball", variantId = "Fireball" },
		})
		assert.are.equal("out_of_target_scope", historicalScope.status)
		assert.are.equal(versionRejection, historicalScope.reason)
		local rows = {
			coverageObservation("1", "a", "3_28", "Hierophant", nil, "", true, "3.29", sourceCodeSha256, "source-codes/same-build.pob"),
			coverageObservation("2", "b", "3_28", "Hierophant", {
				gameId = "Game/IceNova", variantId = "IceNovaAltX", effectId = "IceNovaAltX", category = "transfigured",
			}, "3.28 Mirage", false),
			coverageObservation("5", "c", "3_28", "Hierophant", {
				gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
			}, "", false, "3.29", sourceCodeSha256, "source-codes/same-build.pob"),
			coverageObservation("3", "d", "3_28", "Reliquarian", {
				gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
			}, "3.28 Mirage", false),
			coverageObservation("4", "e", "3_28_alternate", "Scavenger", {
				gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
			}, "Legacy of Phrecia", false),
		}
		local matchingClaimRow = assert(json.decode(rows[2]))
		matchingClaimRow.source.claimedMainSkill = {
			gemId = "Game/IceNova", gameId = "Game/IceNova", variantId = "IceNovaAltX", effectId = "IceNovaAltX",
		}
		rows[2] = assert(json.encode(matchingClaimRow))
		local firstCoverageRow = assert(json.decode(rows[1]))
		firstCoverageRow.source.reference = "https://example.invalid/build/source-code"
		local legacyXml = '<?xml version="1.0"?><PathOfBuilding><Tree activeSpec="2">'
			.. '<Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="6" nodes="542"/>'
			.. '<Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="0" nodes=""/>'
			.. '</Tree></PathOfBuilding>'
		local legacyXmlSha256, legacyObjectPath = writeArchiveObject(paths, legacyXml)
		firstCoverageRow.profile.activeSpec = nil
		firstCoverageRow.object = legacyObjectPath
		firstCoverageRow.xmlSha256 = legacyXmlSha256
		rows[1] = assert(json.encode(firstCoverageRow))
		for index = 2, #rows do
			local observation = assert(json.decode(rows[index]))
			local digest, object = writeArchiveObject(paths, activeSpecXml(observation.profile.activeSpec, "fixture-" .. index))
			observation.xmlSha256 = digest
			observation.object = object
			rows[index] = assert(json.encode(observation))
		end
		writeText(paths.index, table.concat(rows, "\n") .. "\n")
		local archivedSource = assert(StudyBuilds.FindArchivedObservationBySourceCode(userPath,
			"https://example.invalid/build/source-code", sourceCodeSha256))
		assert.are.equal(firstCoverageRow.observationId, archivedSource.observationId)
		local unmatchedSource, unmatchedError = StudyBuilds.FindArchivedObservationBySourceCode(userPath,
			"https://example.invalid/build/source-code", string.rep("e", 64))
		assert.is_nil(unmatchedSource)
		assert.are.equal("source_code_not_archived", unmatchedError)
		local summary = assert(StudyBuilds.Summary(userPath, build))
		assert.are.equal("ready", summary.patchSkillCatalog.status)
		assert.are.equal(1, summary.patchSkillCatalog.audit.claimTreeDisagreements,
			"a claimed patch must be audited without overriding the exact tree patch; observed " .. tostring(summary.patchSkillCatalog.audit.claimTreeDisagreements))
		local patch = summary.patchSkillCatalog.patches[3]
		assert.are.equal("3.28", patch.patch)
		assert.are.equal(3, patch.counts.targetSkills)
		assert.are.equal(1, patch.counts.supportGrantedEffects)
		assert.are.equal(2, patch.counts.vaalSkills)
		assert.are.equal(2, patch.counts.targetBuildLineages)
		assert.are.equal(2, patch.counts.eligibleBuildLineages)
		assert.are.equal(2, patch.counts.skillsWithBuilds)
		local fireballTarget, iceNovaTarget
		for _, skill in ipairs(patch.skills) do
			if skill.variantId == "Fireball" then fireballTarget = skill
			elseif skill.variantId == "IceNovaAltX" then iceNovaTarget = skill end
		end
		assert.is_truthy(fireballTarget)
		assert.is_truthy(iceNovaTarget)
		assert.are.equal(1, fireballTarget.uniqueBuilds,
			"different PoB signatures with the same verified source-code hash count once; secondary configured effects do not count as Main Skill")
		assert.are.equal(1, iceNovaTarget.uniqueBuilds)
		-- Schema 2 remains a supported format after adding the schema-3 native
		-- Vaal derivation provenance and source hashes.
		local catalogFile = assert(io.open(paths.patchSkillCatalog, "rb"))
		local schema2Catalog = assert(json.decode(catalogFile:read("*a")))
		catalogFile:close()
		schema2Catalog.schemaVersion = 2
		writeText(paths.patchSkillCatalog, assert(json.encode(schema2Catalog)))
		local schema2Summary = assert(StudyBuilds.Summary(userPath, build))
		assert.are.equal("ready", schema2Summary.patchSkillCatalog.status)
		-- Schema-1 catalogs stored support-granted effects under the normal raw
		-- count. Tags remain sufficient to keep those records out of coverage.
		table.remove(patches[3].skills, 5)
		patches[3].skills[3].category = "normal"
		patches[3].skills[4].category = "transfigured"
		patches[3].counts = { standardAscendancies = #fixtureStandardAscendancies, totalActiveGemRecords = 5, normal = 3,
			transfigured = 2, vaal = 0, other = 0 }
		writeText(paths.patchSkillCatalog, assert(json.encode({
			schema = "pob-ai-planner-patch-skill-catalog", schemaVersion = 1, featureSchemaVersion = 1,
			source = { method = "legacy-fixture" }, patches = patches,
		})))
		local legacySummary = assert(StudyBuilds.Summary(userPath, build))
		local legacyPatch = legacySummary.patchSkillCatalog.patches[3]
		assert.are.equal(3, legacyPatch.counts.targetSkills)
		assert.are.equal(1, legacyPatch.counts.supportGrantedEffects)
		assert.are.equal(1, legacyPatch.counts.vaalSkills,
			"legacy Vaal alternate identity must take precedence over the shared AltX transfigured suffix")
		assert.are.equal(5, summary.storage.sourceObservations)
		assert.are.equal(5, summary.storage.objectCount)
		assert.are.equal(4, summary.storage.uniqueBuildLineages,
			"verified identical source code counts as one sample lineage; observations without code hashes fall back to PoB signatures")
		local fireballEffect
		for _, effect in ipairs(summary.effects) do
			if effect.effectId == "Fireball" then fireballEffect = effect; break end
		end
		assert.is_truthy(fireballEffect)
		assert.are.equal(2, fireballEffect.uniqueBuilds,
			"configured-effect counts must require a verified standard active tree and source-code identity")
		local observedPair
		for _, pair in ipairs(summary.observedPairs) do
			if pair.patch == "3.28" then observedPair = pair; break end
		end
		assert.is_truthy(observedPair)
		assert.are.equal(2, observedPair.uniqueBuilds,
			"co-occurrence counts must exclude event ascendancies and unsupported tree keys")
		assert.are.equal(1, summary.patchSkillCatalog.audit.excludedByReason.nonstandard_or_missing_ascendancy)
		assert.are.equal(1, summary.patchSkillCatalog.audit.excludedByReason.tree_not_in_3_24_to_3_29)

		local duplicateTree = assert(json.decode(coverageObservation("6", "f", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		-- Keep a valid Main Skill but forge a secondary configured effect. The
		-- dashboard may retain Fireball while excluding that side effect and pair.
		duplicateTree.profile.configuredSkillEffects[2].effectId = "ForgedFlameWall"
		duplicateTree.profile.activeSpec = nil
		local duplicateTreeXml = '<PathOfBuilding><Tree activeSpec="1"><Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="6" nodes=""/></Tree>'
			.. '<Tree activeSpec="1"><Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="0" nodes=""/></Tree></PathOfBuilding>'
		duplicateTree.xmlSha256, duplicateTree.object = writeArchiveObject(paths, duplicateTreeXml)
		local poisonedDuplicateTree = assert(json.decode(assert(json.encode(duplicateTree))))
		poisonedDuplicateTree.object = "objects/00/invalid-content-address.xml"

		local legacyTopLevelSpec = assert(json.decode(coverageObservation("b", "b", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "", false)))
		legacyTopLevelSpec.profile.activeSpec = nil
		legacyTopLevelSpec.profile.character.secondaryAscendancyId = nil
		local legacySpecsXml = '<PathOfBuilding><Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="6" nodes="542"/>'
			.. '<Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="0" nodes=""/></PathOfBuilding>'
		legacyTopLevelSpec.xmlSha256, legacyTopLevelSpec.object = writeArchiveObject(paths, legacySpecsXml)

		local missingObject = assert(json.decode(coverageObservation("7", "7", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		missingObject.profile.activeSpec = nil
		missingObject.xmlSha256 = sha.sha256(activeSpecXml({ treeVersion = "3_28", classId = 5, ascendancyId = 2,
			secondaryAscendancyId = 0, allocatedNodeIds = { } }, "missing-object"))

		local invalidActiveIndex = assert(json.decode(coverageObservation("8", "8", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		invalidActiveIndex.profile.activeSpec = nil
		local invalidIndexXml = '<PathOfBuilding><Tree activeSpec="not-a-number"><Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="0" nodes=""/></Tree></PathOfBuilding>'
		invalidActiveIndex.xmlSha256, invalidActiveIndex.object = writeArchiveObject(paths, invalidIndexXml)

		local invalidSecondary = assert(json.decode(coverageObservation("9", "9", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		invalidSecondary.profile.activeSpec = nil
		local invalidSecondaryXml = '<PathOfBuilding><Tree activeSpec="1"><Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="garbage" nodes=""/></Tree></PathOfBuilding>'
		invalidSecondary.xmlSha256, invalidSecondary.object = writeArchiveObject(paths, invalidSecondaryXml)

		local ambiguousMainSkill = assert(json.decode(coverageObservation("a", "a", "3_28", "Hierophant", nil,
			"3.28 Mirage", true)))
		ambiguousMainSkill.profile.mainSkill = { gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball" }
		local selectedEffects = ambiguousMainSkill.profile.skillGroups[1].skills[1].effects
		selectedEffects[#selectedEffects + 1] = { effectId = "FlameWall", name = "Flame Wall",
			gameId = "Game/FlameWall", variantId = "FlameWall", selected = true }
		local ambiguousXml = activeSpecXml(ambiguousMainSkill.profile.activeSpec, "ambiguous-main")
		ambiguousMainSkill.xmlSha256, ambiguousMainSkill.object = writeArchiveObject(paths, ambiguousXml)

		local directOnlyMainSkill = assert(json.decode(coverageObservation("c", "c", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "", false)))
		directOnlyMainSkill.profile.skillGroups = nil
		local directOnlyXml = activeSpecXml(directOnlyMainSkill.profile.activeSpec, "direct-main-only")
		directOnlyMainSkill.xmlSha256, directOnlyMainSkill.object = writeArchiveObject(paths, directOnlyXml)
		local disabledMainGem = assert(json.decode(coverageObservation("d", "d", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		disabledMainGem.profile.skillGroups[1].gems[1].enabled = false
		local disabledMainGemXml = activeSpecXml(disabledMainGem.profile.activeSpec, "disabled-main-gem")
		disabledMainGem.xmlSha256, disabledMainGem.object = writeArchiveObject(paths, disabledMainGemXml)
		local wrongRoot = assert(json.decode(coverageObservation("e", "e", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		wrongRoot.profile.activeSpec = nil
		local wrongRootXml = '<NotPathOfBuilding><Tree activeSpec="1"><Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="0" nodes=""/></Tree></NotPathOfBuilding>'
		wrongRoot.xmlSha256, wrongRoot.object = writeArchiveObject(paths, wrongRootXml)
		local mixedLegacySpec = assert(json.decode(coverageObservation("f", "f", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		mixedLegacySpec.profile.activeSpec = nil
		mixedLegacySpec.profile.character.secondaryAscendancyId = 6
		local mixedLegacyXml = '<PathOfBuilding><Tree activeSpec="1"><Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="0" nodes=""/></Tree>'
			.. '<Spec treeVersion="3_28" classId="5" ascendClassId="2" secondaryAscendClassId="6" nodes=""/></PathOfBuilding>'
		mixedLegacySpec.xmlSha256, mixedLegacySpec.object = writeArchiveObject(paths, mixedLegacyXml)
		local invalidProfileSecondary = assert(json.decode(coverageObservation("0", "0", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		invalidProfileSecondary.profile.activeSpec = nil
		invalidProfileSecondary.profile.character.secondaryAscendancyId = "garbage"
		local invalidProfileSecondaryXml = activeSpecXml(invalidProfileSecondary.profile.activeSpec or {
			treeVersion = "3_28", classId = 5, ascendancyId = 2, secondaryAscendancyId = 0,
		}, "invalid-profile-secondary")
		invalidProfileSecondary.xmlSha256, invalidProfileSecondary.object = writeArchiveObject(paths, invalidProfileSecondaryXml)
		local catalogEffectMismatch = assert(json.decode(coverageObservation("0", "0", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "ForgedFireball", category = "normal",
		}, "3.28 Mirage", false)))
		catalogEffectMismatch.profile.configuredSkillEffects[1].effectId = "ForgedFireball"
		local mismatchedEffectXml = activeSpecXml(catalogEffectMismatch.profile.activeSpec, "mismatched-catalog-effect")
		catalogEffectMismatch.xmlSha256, catalogEffectMismatch.object = writeArchiveObject(paths, mismatchedEffectXml)
		local sourceClaimMismatch = assert(json.decode(coverageObservation("a", "a", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		sourceClaimMismatch.lineageSha256 = sha.sha256("source-claim-mismatch")
		sourceClaimMismatch.source.claimedMainSkill = {
			gemId = "Game/FlameWall", gameId = "Game/FlameWall", variantId = "FlameWall", effectId = "FlameWall",
		}
		local malformedSourceClaim = assert(json.decode(coverageObservation("b", "b", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		malformedSourceClaim.lineageSha256 = sha.sha256("malformed-source-claim")
		malformedSourceClaim.source.claimedMainSkill = { gameId = "Game/Fireball", variantId = "Fireball" }
		for index, observation in ipairs({ sourceClaimMismatch, malformedSourceClaim }) do
			local digest, object = writeArchiveObject(paths,
				activeSpecXml(observation.profile.activeSpec, "source-claim-fixture-" .. tostring(index)))
			observation.xmlSha256, observation.object = digest, object
		end
		local reviewedNativeMainResolution = assert(json.decode(coverageObservation("e", "e", "3_28", "Hierophant", {
			gemId = "Game/Fireball", gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		reviewedNativeMainResolution.lineageSha256 = sha.sha256("reviewed-native-main-resolution")
		reviewedNativeMainResolution.source.claimedMainSkill = {
			gemId = "Game/FlameWall", gameId = "Game/FlameWall", variantId = "FlameWall", effectId = "FlameWall",
			name = "Flame Wall", evidenceUrl = "https://example.invalid/guide/source-title", basis = "source_guide_title",
		}
		reviewedNativeMainResolution.source.buildQualityAudit = {
			schemaVersion = 1, status = "reviewed_valid", reportPath = "QA/native-main-resolution.md",
			reviewMethod = "independent_native_xml_audits_with_cross_challenge", reviewerRoles = { "Scout", "Critic" },
			crossChallenge = "both_reviewers_confirmed_native_Main_identity_and_resolved_cross_challenge", trainingEligible = false,
			nativeMainSkillResolution = {
				schemaVersion = 1, status = "reviewed_native_main_group", evidence = "native_active_spec_main_skill_group",
				mainSkill = { gemId = "Game/Fireball", gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball" },
			},
		}
		local reviewedNativeMainXmlDigest, reviewedNativeMainObject = writeArchiveObject(paths,
			activeSpecXml(reviewedNativeMainResolution.profile.activeSpec, "reviewed-native-main-resolution"))
		reviewedNativeMainResolution.xmlSha256, reviewedNativeMainResolution.object = reviewedNativeMainXmlDigest, reviewedNativeMainObject
		local invalidNativeMainResolution = assert(json.decode(coverageObservation("g", "g", "3_28", "Hierophant", {
			gemId = "Game/Fireball", gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		invalidNativeMainResolution.lineageSha256 = sha.sha256("invalid-native-main-resolution")
		invalidNativeMainResolution.source.claimedMainSkill = {
			gemId = "Game/FlameWall", gameId = "Game/FlameWall", variantId = "FlameWall", effectId = "FlameWall",
		}
		invalidNativeMainResolution.source.buildQualityAudit = {
			schemaVersion = 1, status = "reviewed_valid", reportPath = "QA/invalid-native-main-resolution.md",
			reviewMethod = "independent_native_xml_audits_with_cross_challenge", reviewerRoles = { "Scout", "Critic" },
			crossChallenge = "both_reviewers_confirmed_native_Main_identity_and_resolved_cross_challenge", trainingEligible = false,
			nativeMainSkillResolution = {
				schemaVersion = 1, status = "reviewed_native_main_group", evidence = "native_active_spec_main_skill_group",
				mainSkill = { gemId = "Game/Fireball", gameId = "Game/Fireball", variantId = "Fireball", effectId = "FlameWall" },
			},
		}
		local invalidNativeMainXmlDigest, invalidNativeMainObject = writeArchiveObject(paths,
			activeSpecXml(invalidNativeMainResolution.profile.activeSpec, "invalid-native-main-resolution"))
		invalidNativeMainResolution.xmlSha256, invalidNativeMainResolution.object = invalidNativeMainXmlDigest, invalidNativeMainObject
		local quarantinedSourceQuality = assert(json.decode(coverageObservation("c", "c", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		quarantinedSourceQuality.lineageSha256 = sha.sha256("source-quality-quarantined")
		quarantinedSourceQuality.source.buildQualityAudit = {
			schemaVersion = 1, status = "quarantined", reasonCode = "active_spec_build_integrity_invalid",
			reportPath = "QA/source-quality-quarantined.md",
		}
		quarantinedSourceQuality.xmlSha256, quarantinedSourceQuality.object = writeArchiveObject(paths,
			activeSpecXml(quarantinedSourceQuality.profile.activeSpec, "source-quality-quarantined"))
		local malformedQualityAudit = assert(json.decode(coverageObservation("d", "d", "3_28", "Hierophant", {
			gameId = "Game/Fireball", variantId = "Fireball", effectId = "Fireball", category = "normal",
		}, "3.28 Mirage", false)))
		malformedQualityAudit.lineageSha256 = sha.sha256("source-quality-audit-invalid")
		malformedQualityAudit.source.buildQualityAudit = {
			schemaVersion = 1, status = "quarantined", reasonCode = "missing_report_path",
		}
		malformedQualityAudit.xmlSha256, malformedQualityAudit.object = writeArchiveObject(paths,
			activeSpecXml(malformedQualityAudit.profile.activeSpec, "source-quality-audit-invalid"))

		local extraRows = { poisonedDuplicateTree, duplicateTree, legacyTopLevelSpec, missingObject,
			invalidActiveIndex, invalidSecondary, ambiguousMainSkill, directOnlyMainSkill,
			disabledMainGem, wrongRoot, mixedLegacySpec, invalidProfileSecondary, catalogEffectMismatch,
			sourceClaimMismatch, malformedSourceClaim, reviewedNativeMainResolution, invalidNativeMainResolution,
			quarantinedSourceQuality, malformedQualityAudit }
		local appended = { }
		for _, row in ipairs(extraRows) do appended[#appended + 1] = assert(json.encode(row)) end
		local originalIndex = assert(io.open(paths.index, "rb"))
		local originalIndexText = originalIndex:read("*a")
		originalIndex:close()
		writeText(paths.index, originalIndexText .. table.concat(appended, "\n") .. "\n")
		-- Restore the versioned schema-5 catalog after the compatibility checks
		-- above, so the strict XML gate has authoritative Bloodline node IDs.
		writeText(paths.patchSkillCatalog, catalogText)
		local strictSummary = assert(StudyBuilds.Summary(userPath, build))
		local strictPatch = strictSummary.patchSkillCatalog.patches[3]
		assert.are.equal(5, strictPatch.counts.targetBuildLineages,
			"only a reviewer-verified native Main Skill resolution may lift a conflicting source-title claim")
		local strictFireball
		for _, skill in ipairs(strictPatch.skills) do if skill.variantId == "Fireball" then strictFireball = skill break end end
		assert.is_truthy(strictFireball)
		assert.are.equal(4, strictFireball.uniqueBuilds,
			"duplicate-Tree, last legacy-Spec, and paired native-Main resolution observations should count once each")
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.active_spec_object_path_invalid)
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.active_spec_object_missing)
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.active_spec_index_invalid)
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.active_spec_secondary_ascendancy_invalid)
		assert.are.equal(3, strictSummary.patchSkillCatalog.audit.excludedByReason.main_skill_not_identifiable)
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.active_spec_xml_invalid)
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.event_secondary_ascendancy)
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.secondary_ascendancy_invalid)
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.skill_effect_catalog_mismatch)
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.source_main_skill_mismatch,
			"a public source title that claims a different Main Skill must not inflate target coverage")
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.source_main_skill_resolution_invalid,
			"a paired native-Main resolution with a mismatched exact identity must fail closed")
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.claimed_main_skill_claim_invalid,
			"an incomplete source Main Skill identity must remain out of strict coverage")
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.source_build_quality_quarantined,
			"a manually quarantined source remains archived but cannot inflate skill coverage")
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.source_build_quality_audit_invalid,
			"an incomplete quality audit must fail closed rather than silently re-enter coverage")
		for _, effect in ipairs(strictSummary.effects) do
			assert.are_not.equal("ForgedFireball", effect.effectId,
				"a build with an unverified Main Skill must not inflate configured-effect frequency")
			assert.are_not.equal("ForgedFlameWall", effect.effectId,
				"a configured secondary effect must match the patch catalog before aggregation")
		end
		for _, pair in ipairs(strictSummary.observedPairs) do
			assert.are_not.equal("ForgedFireball", pair.leftEffectId,
				"a build with an unverified Main Skill must not create a forged left-hand co-occurrence")
			assert.are_not.equal("ForgedFireball", pair.rightEffectId,
				"a build with an unverified Main Skill must not create a forged right-hand co-occurrence")
			assert.are_not.equal("ForgedFlameWall", pair.leftEffectId,
				"a forged secondary effect must not create a left-hand co-occurrence")
			assert.are_not.equal("ForgedFlameWall", pair.rightEffectId,
				"a forged secondary effect must not create a right-hand co-occurrence")
		end
		assert.are.equal(0, strictSummary.catalog.archivedHistoricalEffectCount,
			"rejected Main Skill or secondary effects must not enter historical-effect discovery")
		assert.are.equal(1, strictSummary.patchSkillCatalog.audit.excludedByReason.configured_effect_catalog_mismatch,
			"the dashboard should expose the rejected secondary configured effect")
	end)

	it("opens the learning dashboard without mutating the current PoB build", function()
		local signature = Candidate.BuildSignature(build)
		local tab = assert(build.optimizerTab)
		tab:OpenBuildLearningDashboard()
		local popup = assert(main.popups[1])
		assert.are.equal("AI Planner — Build archive e aprendizado", popup.title)
		assert.is_truthy(popup.controls.summary)
		assert.is_truthy(popup.controls.effect)
		assert.is_truthy(popup.controls.patch)
		assert.is_truthy(popup.controls.skill)
		assert.is_truthy(popup.controls.archiveCurrent)
		assert.is_truthy(popup.controls.refresh)
		assert.is_truthy(popup.controls.leagueNotice)
		local auditLabel = popup.controls.leagueNotice:GetProperty("label")
		assert.is_truthy(auditLabel:find("Auditoria:", 1, true))
		assert.is_truthy(auditLabel:find("qualidade Q", 1, true))
		assert.is_truthy(popup.controls.leagueNotice.tooltipText:find("Tree.Spec", 1, true))
		assert.is_truthy(popup.controls.leagueNotice.tooltipText:find("Main Skill nativa", 1, true))
		main:ClosePopup(popup)
		tab:OpenBuildReviewDashboard()
		local reviewPopup = assert(main.popups[1])
		assert.are.equal("AI Planner — Caderno A/B e hipóteses", reviewPopup.title)
		assert.is_truthy(reviewPopup.controls.runtime)
		assert.is_truthy(reviewPopup.controls.runtime:GetProperty("label"))
		assert.is_truthy(reviewPopup.controls.counts)
		assert.is_truthy(reviewPopup.controls.facts)
		assert.is_truthy(reviewPopup.controls.ideas)
		assert.is_truthy(reviewPopup.controls.next)
		main:ClosePopup(reviewPopup)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)
end)
