local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local Version = require("Modules.Optimizer.Version")
local PatchSkillCatalogFingerprint = require("Modules.Optimizer.PatchSkillCatalogFingerprint")
local TestSupport = require("OptimizerTestSupport")
local json = require("dkjson")
local sha = require("sha2")
local ffi = require("ffi")

local standardAscendancies = {
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
local ascendClassIds = {
	Ascendant = 1,
	Berserker = 2, Chieftain = 3, Juggernaut = 1,
	Deadeye = 2, Pathfinder = 3, Raider = 1,
	Elementalist = 2, Necromancer = 3, Occultist = 1,
	Champion = 3, Gladiator = 2, Slayer = 1,
	Guardian = 3, Hierophant = 2, Inquisitor = 1,
	Assassin = 1, Saboteur = 3, Trickster = 2,
}
for _, ascendancy in ipairs(standardAscendancies) do
	ascendancy.ascendClassId = ascendClassIds[ascendancy.id]
end
local classNames = { [0] = "Scion", "Marauder", "Ranger", "Witch", "Duelist", "Templar", "Shadow" }
local firstAscendancyByClass = { }
for _, ascendancy in ipairs(standardAscendancies) do
	if not firstAscendancyByClass[ascendancy.classId] then firstAscendancyByClass[ascendancy.classId] = ascendancy end
end

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

local function makeDirectory(path)
	path = path:gsub("[/\\]+$", "")
	local result = isWindows and crt._mkdir(path) or ffi.C.mkdir(path, 493)
	if result == 0 then return true end
	local exists = isWindows and crt._access(path, 0) == 0 or (not isWindows and ffi.C.access(path, 0) == 0)
	if exists then return nil, "No error" end
	return nil, "could not create test directory"
end

local function removeDirectory(path)
	if isWindows then return crt._rmdir(path) end
	return ffi.C.rmdir(path)
end

local function catalogPatchFingerprint(patch)
	return assert(PatchSkillCatalogFingerprint.Compute(patch))
end

local function writeFixtureCatalog(paths, currentTree, gemId, effectId)
	makeDirectory(paths.catalogDirectory)
	local bloodlineNodeIds = { }
	for rawId, node in pairs(currentTree.nodes or { }) do
		if type(node) == "table" and node.isBloodline == true then bloodlineNodeIds[#bloodlineNodeIds + 1] = tonumber(node.id or rawId) end
	end
	table.sort(bloodlineNodeIds)
	local patches = { }
	local pobTags = { ["3.26"] = "v2.54.0", ["3.27"] = "v2.58.0", ["3.28"] = "v2.61.0", ["3.29"] = "v2.67.2" }
	for _, patchName in ipairs({ "3.26", "3.27", "3.28", "3.29" }) do
		local patch = {
			patch = patchName, pobTag = pobTags[patchName], sourceRef = pobTags[patchName], sourceLabel = patchName .. " fixture",
			commit = string.rep("a", 40), treeVersion = patchName:gsub("%.", "_"),
			sourceHashes = { gems = string.rep("c", 64), tree = string.rep("d", 64),
				skills = string.rep("e", 64), data = string.rep("f", 64) },
			standardAscendancies = standardAscendancies,
			excludedAlternateAscendancies = { }, excludedLeagueSpecificAscendancies = { },
			bloodlineNodeIds = patchName == "3.29" and bloodlineNodeIds or { },
			skills = {
				{ gemId = gemId, gameId = gemId, variantId = "Fireball",
					variantKey = gemId .. "|Fireball", name = "Fireball", baseName = "Fireball",
					grantedEffectId = effectId, secondaryGrantedEffectId = "", category = "normal", tags = { "spell" } },
				{ gemId = "Metadata/Items/Gems/SkillGemFlameWall", gameId = "Metadata/Items/Gems/SkillGemFlameWall",
					variantId = "FlameWall", variantKey = "Metadata/Items/Gems/SkillGemFlameWall|FlameWall",
					name = "Flame Wall", baseName = "Flame Wall", grantedEffectId = "FlameWall",
					secondaryGrantedEffectId = "", category = "normal", tags = { "spell" } },
			},
			counts = { standardAscendancies = #standardAscendancies, totalActiveGemRecords = 2, normal = 2,
				transfigured = 0, vaal = 0, vaalAlternateVariants = 0, supportGrantedEffects = 0,
				support_granted_effect = 0, excludedAlternateAscendancies = 0,
				excludedLeagueSpecificAscendancies = 0, other = 0 },
		}
		patch.catalogFingerprint = catalogPatchFingerprint(patch)
		patches[#patches + 1] = patch
	end
	local encoded = assert(json.encode({ schema = "pob-ai-planner-patch-skill-catalog", schemaVersion = 5,
		featureSchemaVersion = 1, source = { method = "fixture" }, patches = patches }))
	local file = assert(io.open(paths.patchSkillCatalog, "wb"))
	assert(file:write(encoded))
	assert(file:close())
end

local function buildProfile(engine, classId, gemId, effectId, allocated, ascendancyOverride)
	local ascendancy = ascendancyOverride or assert(firstAscendancyByClass[classId])
	local nodeIds = { }
	for _, value in ipairs(allocated) do nodeIds[#nodeIds + 1] = tostring(value) end
	return {
		schema = "pob-ai-planner-build-profile", schemaVersion = 1, engine = engine,
		character = { classId = classId, class = classNames[classId], ascendancyId = ascendancy.ascendClassId,
			ascendancy = ascendancy.id, secondaryAscendancyId = 0, secondaryAscendancy = "None" },
		configuredSkillEffects = { { gemId = gemId, gameId = gemId, variantId = "Fireball", effectId = effectId } },
		allocatedNodeIds = allocated,
		mainSkill = { gemId = gemId, gameId = gemId, variantId = "Fireball", effectId = effectId, name = "Fireball" },
		skillGroups = { { selectedMainGroup = true, enabled = true, slotEnabled = true,
			gems = { { gemId = gemId, gameId = gemId, variantId = "Fireball", enabled = true, isSupport = false } },
			skills = { { selectedMainSkill = true, name = "Fireball", effects = { {
				gemId = gemId, gameId = gemId, variantId = "Fireball", effectId = effectId, selected = true,
			} } } } } },
		activeSpec = { index = 1, treeVersion = engine.treeVersion, classId = classId, ascendancyId = ascendancy.ascendClassId,
			secondaryAscendancyId = 0, allocatedNodeIds = allocated },
	}
end

local function setProfileMainSkill(profile, gemId, variantId, effectId, name)
	local skill = { gemId = gemId, gameId = gemId, variantId = variantId, effectId = effectId, name = name }
	profile.mainSkill = skill
	profile.configuredSkillEffects = { { gemId = gemId, gameId = gemId, variantId = variantId, effectId = effectId } }
	profile.skillGroups[1].gems[1] = { gemId = gemId, gameId = gemId, variantId = variantId, enabled = true, isSupport = false }
	profile.skillGroups[1].skills[1].name = name
	profile.skillGroups[1].skills[1].effects[1] = { gemId = gemId, gameId = gemId, variantId = variantId,
		effectId = effectId, selected = true }
	return profile
end

local function writeArchiveObservation(paths, objectFiles, objectDirectories, lineage, profile)
	local allocated = { }
	for _, nodeId in ipairs(profile.allocatedNodeIds) do allocated[#allocated + 1] = tostring(nodeId) end
	local xmlText = string.format('<PathOfBuilding><Tree activeSpec="1"><Spec treeVersion="%s" classId="%d" ascendClassId="%d" secondaryAscendClassId="0" nodes="%s"/></Tree></PathOfBuilding>',
		profile.engine.treeVersion, profile.character.classId, profile.character.ascendancyId, table.concat(allocated, ","))
	local digest = sha.sha256(xmlText)
	local shard = digest:sub(1, 2)
	local directory = paths.objects .. "\\" .. shard
	makeDirectory(paths.objects)
	makeDirectory(directory)
	local path = directory .. "\\" .. digest .. ".xml"
	local file = assert(io.open(path, "wb"))
	assert(file:write(xmlText))
	assert(file:close())
	objectFiles[#objectFiles + 1] = path
	objectDirectories[directory] = true
	return assert(json.encode({ recordType = "build_archive_observation", schemaVersion = 1,
		lineageSha256 = lineage, xmlSha256 = digest, object = "objects/" .. shard .. "/" .. digest .. ".xml",
		profile = profile }))
end

local function treeEdge(nodes)
	for rawId, node in pairs(nodes or { }) do
		local nodeId = tonumber(rawId)
		if nodeId and type(node) == "table" and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
			and node.type ~= "Mastery" and node.type ~= "Socket" and not node.ascendancyName
			and node.isBloodline ~= true and not node.isMultipleChoiceOption then
			for key, value in pairs(node.out or node.connections or { }) do
				local otherId = tonumber(value) or tonumber(key)
				local otherNode = otherId and (nodes[otherId] or nodes[tostring(otherId)])
				if otherId and otherId ~= nodeId and type(otherNode) == "table"
					and otherNode.type ~= "ClassStart" and otherNode.type ~= "AscendClassStart"
					and otherNode.type ~= "Mastery" and otherNode.type ~= "Socket" and not otherNode.ascendancyName
					and otherNode.isBloodline ~= true and not otherNode.isMultipleChoiceOption then
					return math.min(nodeId, otherId), math.max(nodeId, otherId)
				end
			end
		end
	end
end

describe("AI Planner imported passive-node graph evidence", function()
	local root, paths, objectFiles, objectDirectories, sourceUserRoot, sourceConfigPath

	after_each(function()
		if objectFiles then for _, path in ipairs(objectFiles) do os.remove(path) end end
		if sourceConfigPath then os.remove(sourceConfigPath) end
		if sourceUserRoot then
			local sourceUserPaths = StudyBuilds.GetPaths(sourceUserRoot)
			if sourceUserPaths then removeDirectory(sourceUserPaths.studies) end
			removeDirectory(sourceUserRoot)
		end
		if paths then
			os.remove(paths.index)
			os.remove(paths.patchSkillCatalog)
			if objectDirectories then for directory in pairs(objectDirectories) do removeDirectory(directory) end end
			removeDirectory(paths.objects)
			removeDirectory(paths.catalogDirectory)
			removeDirectory(paths.root)
			removeDirectory(paths.studies)
		end
		if root then removeDirectory(root) end
		root, paths, objectFiles, objectDirectories, sourceUserRoot, sourceConfigPath = nil, nil, nil, nil, nil, nil
	end)

	it("builds same-patch tree evidence across PoB versions and deduplicates imported lineages", function()
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		local snapshot = Version.Snapshot(build)
		local catalog = assert(SkillCatalog.ListAllActiveEffects(build, ""))
		local gemId, effectId
		for _, effect in ipairs(catalog.effects or { }) do
			if effect.gemId == "Metadata/Items/Gems/SkillGemFireball" then
				gemId, effectId = effect.gemId, effect.effectId
				break
			end
		end
		assert.is_truthy(gemId, "the PoB 3.29 active-gem catalog should expose Fireball")
		local leftId, rightId = treeEdge(build.spec.tree.nodes)
		assert.is_truthy(leftId and rightId, "the loaded PoB passive tree should expose native connected nodes")
		local currentClassId = tonumber(build.spec.curClassId)
		local alternateClassId
		for classId in pairs(build.spec.tree.classes or { }) do
			local numericId = tonumber(classId)
			if numericId and numericId ~= currentClassId and firstAscendancyByClass[numericId] then alternateClassId = numericId; break end
		end
		assert.is_truthy(alternateClassId, "the loaded native tree should expose another base-class root")

		root = os.tmpname()
		os.remove(root)
		root = root .. "_imported_node_graph"
		assert(makeDirectory(root))
		paths = assert(StudyBuilds.GetPaths(root))
		assert(makeDirectory(paths.studies))
		assert(makeDirectory(paths.root))
		assert(makeDirectory(paths.catalogDirectory))
		assert(makeDirectory(paths.objects))
		objectFiles, objectDirectories = { }, { }
		writeFixtureCatalog(paths, build.spec.tree, gemId, effectId)
		local firstValidObservation = writeArchiveObservation(paths, objectFiles, objectDirectories, string.rep("a", 64),
			buildProfile(snapshot, currentClassId, gemId, effectId, { leftId, rightId }))
		local historicalEngineProfile = buildProfile(snapshot, currentClassId, gemId, effectId, { leftId, rightId })
		historicalEngineProfile.engine = { }
		for key, value in pairs(snapshot) do historicalEngineProfile.engine[key] = value end
		historicalEngineProfile.engine.pobVersion = "2.50.0"
		historicalEngineProfile.engine.pobBranch = "archive-release"
		historicalEngineProfile.engine.manifestFingerprint = nil
		historicalEngineProfile.engine.manifestFingerprintStatus = "unavailable"
		local cachePoison = assert(json.decode(firstValidObservation))
		cachePoison.object = "objects/../invalid.xml"
		local rows = {
			-- An invalid object path with the same digest must not cache a parse
			-- failure and poison the valid content-addressed object below.
			assert(json.encode(cachePoison)),
			firstValidObservation,
			-- A copied import of the same exact lineage must not inflate support.
			writeArchiveObservation(paths, objectFiles, objectDirectories, string.rep("a", 64),
				buildProfile(snapshot, currentClassId, gemId, effectId, { leftId })),
			writeArchiveObservation(paths, objectFiles, objectDirectories, string.rep("b", 64),
				historicalEngineProfile),
		}
		local utilityOnlyProfile = buildProfile(snapshot, currentClassId, gemId, effectId, { leftId, rightId })
		local utilityGemId = "Metadata/Items/Gems/SkillGemFlameWall"
		utilityOnlyProfile.mainSkill = { gemId = utilityGemId, gameId = utilityGemId,
			variantId = "FlameWall", effectId = "FlameWall", name = "Flame Wall" }
		utilityOnlyProfile.skillGroups[1].gems[1] = { gemId = utilityGemId, gameId = utilityGemId,
			variantId = "FlameWall", enabled = true, isSupport = false }
		utilityOnlyProfile.skillGroups[1].skills[1].effects[1] = { gemId = utilityGemId,
			gameId = utilityGemId, variantId = "FlameWall", effectId = "FlameWall", selected = true }
		-- Fireball is configured as a secondary utility skill but is not the main
		-- skill; it must not contribute Fireball route evidence.
		rows[#rows + 1] = writeArchiveObservation(paths, objectFiles, objectDirectories, string.rep("g", 64), utilityOnlyProfile)
		local donorClassId, donorAscendancies
		for _, row in ipairs(standardAscendancies) do
			if row.classId ~= currentClassId and row.classId ~= alternateClassId then
				donorAscendancies = donorAscendancies or { }
				if donorClassId and donorClassId ~= row.classId then donorAscendancies = nil end
				if not donorClassId or donorClassId == row.classId then
					donorClassId = row.classId
					donorAscendancies = donorAscendancies or { }
					donorAscendancies[#donorAscendancies + 1] = row
					if #donorAscendancies == 2 then break end
				end
			end
		end
		assert.is_truthy(donorClassId and donorAscendancies and #donorAscendancies == 2,
			"the fixture should provide a different native class with two standard ascendancies")
		for index, lineage in ipairs({ "4", "5" }) do
			local crossSkillProfile = buildProfile(snapshot, donorClassId, gemId, effectId,
				{ leftId, rightId }, donorAscendancies[index])
			setProfileMainSkill(crossSkillProfile, "Metadata/Items/Gems/SkillGemFlameWall", "FlameWall", "FlameWall", "Flame Wall")
			rows[#rows + 1] = writeArchiveObservation(paths, objectFiles, objectDirectories, string.rep(lineage, 64), crossSkillProfile)
		end
		local forgedCatalogEffectProfile = buildProfile(snapshot, currentClassId, gemId, effectId, { leftId, rightId })
		forgedCatalogEffectProfile.mainSkill.effectId = "ForgedFireball"
		forgedCatalogEffectProfile.skillGroups[1].skills[1].effects[1].effectId = "ForgedFireball"
		forgedCatalogEffectProfile.configuredSkillEffects[1].effectId = "ForgedFireball"
		rows[#rows + 1] = writeArchiveObservation(paths, objectFiles, objectDirectories, string.rep("8", 64), forgedCatalogEffectProfile)
		local wrongVersion = { }
		for key, value in pairs(snapshot) do wrongVersion[key] = value end
		wrongVersion.dataVersion = "old-patch"
		local wrongVersionProfile = buildProfile(wrongVersion, currentClassId, gemId, effectId, { leftId, rightId })
		rows[#rows + 1] = assert(json.encode({ recordType = "build_archive_observation", schemaVersion = 1,
			lineageSha256 = string.rep("c", 64), xmlSha256 = string.rep("c", 64), profile = wrongVersionProfile }))
		local wrongSkillProfile = buildProfile(snapshot, currentClassId, "OtherGem", effectId, { leftId, rightId })
		rows[#rows + 1] = assert(json.encode({ recordType = "build_archive_observation", schemaVersion = 1,
			lineageSha256 = string.rep("d", 64), xmlSha256 = string.rep("d", 64), profile = wrongSkillProfile }))
		for _, lineage in ipairs({ "e", "f" }) do
			local alternateProfile = buildProfile(snapshot, alternateClassId, gemId, effectId, { leftId, rightId })
			rows[#rows + 1] = writeArchiveObservation(paths, objectFiles, objectDirectories, string.rep(lineage, 64), alternateProfile)
		end
		-- Malformed rows and rows with an XML hash but no archived object must be
		-- skipped without throwing or influencing the structural prior.
		local noXmlHashProfile = buildProfile(snapshot, currentClassId, gemId, effectId, { leftId, rightId })
		rows[#rows + 1] = assert(json.encode({ recordType = "build_archive_observation", schemaVersion = 1,
			lineageSha256 = string.rep("1", 64), profile = noXmlHashProfile }))
		local noObjectProfile = buildProfile(snapshot, currentClassId, gemId, effectId, { leftId, rightId })
		rows[#rows + 1] = assert(json.encode({ recordType = "build_archive_observation", schemaVersion = 1,
			lineageSha256 = string.rep("2", 64), xmlSha256 = string.rep("2", 64), profile = noObjectProfile }))
		local file = assert(io.open(paths.index, "wb"))
		assert(file:write(table.concat(rows, "\n"), "\n"))
		assert(file:close())
		-- This ignored oversized row pushes the index above the old 32 MiB cap.
		-- A bounded read must continue past it to finish the current archive.
		file = assert(io.open(paths.index, "ab"))
		local filler = string.rep("x", 64 * 1024)
		for _ = 1, 640 do assert(file:write(filler)) end
		assert(file:write("\n"))
		assert(file:close())

		sourceUserRoot = os.tmpname()
		os.remove(sourceUserRoot)
		sourceUserRoot = sourceUserRoot .. "_archive_source_user"
		assert(makeDirectory(sourceUserRoot))
		local sourceUserPaths = assert(StudyBuilds.GetPaths(sourceUserRoot))
		assert(makeDirectory(sourceUserPaths.studies))
		sourceConfigPath = sourceUserPaths.studies .. (package.config:sub(1, 1)) .. "BuildArchiveSource.json"
		local sourceConfig = assert(io.open(sourceConfigPath, "wb"))
		assert(sourceConfig:write(assert(json.encode({ schema = "pob-ai-planner-archive-source", schemaVersion = 1,
			root = root, readOnly = true }))))
		assert(sourceConfig:close())
		local archiveSource = assert(StudyBuilds.GetPlannerArchiveSource(sourceUserRoot))
		assert.are.equal("project_archive", archiveSource.mode)
		assert.are.equal("ready", archiveSource.status)
		assert.are.equal(root, archiveSource.root)
		local evidence = assert(StudyBuilds.NodeEvidence(sourceUserRoot, build, gemId, { effectId }, nil, nil, archiveSource.root))
		assert.are.equal("ready", evidence.status)
		assert.are.equal(2, evidence.compatibleBuildCount)
		local oldBranch, oldDevMode = launch.versionBranch, launch.devMode
		launch.versionBranch, launch.devMode = nil, false
		local branchlessEvidence = assert(StudyBuilds.NodeEvidence(sourceUserRoot, build,
			gemId, { effectId }, nil, nil, archiveSource.root))
		launch.versionBranch, launch.devMode = oldBranch, oldDevMode
		assert.are.equal("ready", branchlessEvidence.status,
			"official PoB manifests without a branch attribute still have exact data/tree identities for structural archive evidence")
		assert.are.equal("selected_skill", evidence.skillScope,
			"the default evidence query remains restricted to the currently selected Main Skill")
		assert.are.equal(5, evidence.malformedRows,
			"malformed rows, the oversized ignored row, and failed content-addressed objects are skipped safely; observed " .. tostring(evidence.malformedRows))
		assert.is_false(evidence.archiveTruncated,
			"the bounded archive scan must finish past a row that exceeds the previous 32 MiB cap")
		assert.is_true(evidence.scannedBytes > 32 * 1024 * 1024,
			"the regression fixture must exercise an archive larger than the previous byte limit")
		assert.is_false(evidence.causal)
		assert.is_true(evidence.readOnly)
		assert.is_true(evidence.proposalOrderingOnly)
		assert.is_true(evidence.proposalGenerationAvailable)
		assert.are.equal(1, evidence.routePatternCount,
			"identical trees from distinct exact-compatible lineages should collapse into one proposal pattern")
		assert.are.equal(2, evidence.routePatterns[1].supportCount)
		assert.are.equal(2, evidence.routePatterns[1].sampleCount)
		assert.is_true(#evidence.routePatterns[1].nodeIds > 0)
		assert.are.equal(2, evidence.nodeCounts[leftId].supportCount)
		assert.are.equal(2, evidence.nodeCounts[rightId].supportCount)
		assert.are.equal(1, evidence.priorities[leftId])
		local connectedEdge
		for _, edge in ipairs(evidence.edges) do
			if edge.nodeA == leftId and edge.nodeB == rightId then connectedEdge = edge break end
		end
		assert.is_truthy(connectedEdge, "the graph should retain native allocated-tree connectivity")
		assert.are.equal(2, connectedEdge.supportCount)
		assert.are.equal(1, evidence.edgePriorities[tostring(leftId) .. ":" .. tostring(rightId)],
			"the complete compatible archive should expose frequency only for its observed native connection")
		local classTreeEvidence = assert(StudyBuilds.NodeEvidence(sourceUserRoot, build, gemId,
			{ effectId }, nil, donorClassId, archiveSource.root, "class_tree"))
		assert.are.equal("ready", classTreeEvidence.status)
		assert.are.equal("class_tree", classTreeEvidence.skillScope)
		assert.are.equal(2, classTreeEvidence.compatibleBuildCount,
			"same-class, same-tree builds with another verified Main Skill and standard ascendancy can supply structural route patterns")
		assert.are.equal(1, classTreeEvidence.routePatternCount)
		assert.are.equal(2, classTreeEvidence.routePatterns[1].supportCount)
		assert.is_true(classTreeEvidence.proposalGenerationAvailable)
		file = assert(io.open(paths.index, "wb"))
		assert(file:write(table.concat(rows, "\n"), "\n"))
		assert(file:close())
		local forgedEffectEvidence = assert(StudyBuilds.NodeEvidence(root, build, gemId, { "ForgedFireball" }))
		assert.are.equal("no_compatible_builds", forgedEffectEvidence.status)
		assert.are.equal(0, forgedEffectEvidence.compatibleBuildCount,
			"the selected effect must match one of the exact gem effects in the pinned patch catalog")
		local selectedClassEvidence = assert(StudyBuilds.NodeEvidence(root, build, gemId, { effectId }, nil, alternateClassId))
		assert.are.equal("ready", selectedClassEvidence.status)
		assert.are.equal(2, selectedClassEvidence.compatibleBuildCount,
			"the selected planner class should match its own imported lineage when it differs from the active build")
		local unfiltered = assert(StudyBuilds.NodeEvidence(root, build, gemId, { }))
		assert.are.equal("unavailable", unfiltered.status,
			"an empty effect filter must never broaden the query to every variant of the gem")
		assert.are.equal("selected_skill_effect_missing", unfiltered.reason)
		assert.are.same({ }, unfiltered.priorities)
		assert.are.same({ }, unfiltered.edgePriorities)
	end)

	it("withholds priors without a compatible archive or verified engine identity", function()
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		root = os.tmpname()
		os.remove(root)
		root = root .. "_empty_node_graph"
		assert(makeDirectory(root))
		local empty = assert(StudyBuilds.NodeEvidence(root, build, gemId, { "Fireball" }))
		assert.are.equal("no_archive", empty.status)
		assert.are.same({ }, empty.priorities)
		assert.are.same({ }, empty.edgePriorities)
		local oldFingerprint, oldStatus = launch.manifestFingerprint, launch.manifestFingerprintStatus
		launch.manifestFingerprint, launch.manifestFingerprintStatus = nil, "unavailable"
		local unverified = assert(StudyBuilds.NodeEvidence(root, build, gemId, { "Fireball" }))
		launch.manifestFingerprint, launch.manifestFingerprintStatus = oldFingerprint, oldStatus
		assert.are.equal("unavailable", unverified.status)
		assert.are.equal("current_engine_fingerprint_unverified", unverified.reason)
		assert.are.same({ }, unverified.priorities)
		assert.are.same({ }, unverified.edgePriorities)
	end)
end)
