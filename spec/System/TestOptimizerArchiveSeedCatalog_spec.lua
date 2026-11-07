local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local Version = require("Modules.Optimizer.Version")
local Sha = require("sha2")
local Json = require("dkjson")

describe("AI Planner archived build seed catalog", function()
	local userPath, archiveRoot
	local function join(left, right)
		local separator = package.config:sub(1, 1)
		return left:gsub("[/\\]+$", "") .. separator .. right:gsub("[/\\]", separator)
	end
	local function makeDirectory(path)
		assert.is_false(path:find('[%c"&|<>^%%!()]') ~= nil, "temporary QA path contains a shell metacharacter")
		local created, mode, code = os.execute('mkdir "' .. path .. '"')
		assert.is_true(created == true or created == 0 or code == 0,
			"could not create temporary QA directory: " .. tostring(mode or code or created))
	end
	local function removeTemporaryDirectory(path)
		if not path then return end
		local tempRoot = tostring(os.getenv("TEMP") or os.getenv("TMP") or ""):gsub("[/\\]+$", "")
		local normalized = tostring(path):gsub("/", "\\")
		local prefix = tempRoot:gsub("/", "\\") .. "\\"
		assert.is_true(tempRoot ~= "" and normalized:lower():sub(1, #prefix) == prefix:lower(),
			"refusing to remove a QA folder outside the system temporary directory")
		assert.is_false(normalized:find('[%c"&|<>^%%!()]') ~= nil, "temporary QA path contains a shell metacharacter")
		os.execute('rmdir /S /Q "' .. normalized .. '"')
	end
	local function writeFile(path, content)
		local file = assert(io.open(path, "wb"))
		assert.is_truthy(file:write(content))
		assert.is_true(file:close())
	end

	after_each(function()
		removeTemporaryDirectory(userPath)
		removeTemporaryDirectory(archiveRoot)
		userPath, archiveRoot = nil, nil
	end)

	it("deduplicates imported XMLs, filters by current patch/tree, and verifies a selected file hash", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Witch))
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()

		local temporaryBase = os.tmpname()
		os.remove(temporaryBase)
		userPath = temporaryBase .. "-seed-user"
		archiveRoot = temporaryBase .. "-seed-archive"
		local archivePaths = assert(StudyBuilds.GetPaths(archiveRoot))
		for _, directory in ipairs({ userPath, join(userPath, "OptimizerStudies"), archiveRoot,
			archivePaths.studies, archivePaths.root, archivePaths.catalogDirectory, archivePaths.objects }) do
			makeDirectory(directory)
		end
		local configPath = join(join(userPath, "OptimizerStudies"), "BuildArchiveSource.json")
		writeFile(configPath, assert(Json.encode({
			schema = "pob-ai-planner-archive-source", schemaVersion = 1,
			root = archiveRoot, readOnly = true,
		})))
		writeFile(archivePaths.patchSkillCatalog, "{}")

		local xmlText = assert(build:SaveDB("QA archived seed"))
		local xmlHash = Sha.sha256(xmlText)
		local shard = xmlHash:sub(1, 2)
		local shardDirectory = join(archivePaths.objects, shard)
		makeDirectory(shardDirectory)
		local relativeObject = "objects/" .. shard .. "/" .. xmlHash .. ".xml"
		local objectPath = join(archivePaths.objects, shard .. "/" .. xmlHash .. ".xml")
		writeFile(objectPath, xmlText)

		local profile = assert(StudyBuilds.ProfileFromBuild(build))
		profile.engine = profile.engine or { }
		profile.engine.dataVersion = tostring(Version.Data(build))
		profile.engine.treeVersion = tostring(Version.Tree(build))
		profile.character = profile.character or { }
		profile.character.class = "Witch"
		profile.character.ascendancy = "Elementalist"
		profile.character.level = 90
		profile.trainingStatus = "observation_only_pending_rights_and_exact_labels"
		local function row(observationId, observedAt, label, dataVersion, treeVersion)
			local profileCopy = { }
			for key, value in pairs(profile) do profileCopy[key] = value end
			profileCopy.engine = { dataVersion = dataVersion or profile.engine.dataVersion,
				treeVersion = treeVersion or profile.engine.treeVersion }
			return {
				recordType = "build_archive_observation", schemaVersion = 1,
				observationId = Sha.sha256(observationId), lineageSha256 = Sha.sha256("lineage-" .. observationId),
				observedAt = observedAt, xmlSha256 = xmlHash, object = relativeObject,
				source = { type = "curated_public_build", label = label, rightsStatus = "unverified" },
				profile = profileCopy,
			}
		end
		writeFile(archivePaths.index, assert(Json.encode(row("first", 1, "Older label")) .. "\n"
			.. Json.encode(row("latest", 2, "Latest label")) .. "\n"
			.. Json.encode(row("other-patch", 3, "Other patch", "3.28", "3_28")) .. "\n"))

		local seeds, summary = StudyBuilds.ListArchivedSeeds(userPath, {
			dataVersion = tostring(Version.Data(build)), treeVersion = tostring(Version.Tree(build)),
		})
		assert.is_table(seeds)
		assert.are.equal(3, summary.observationCount)
		assert.are.equal(1, #seeds)
		assert.are.equal(xmlHash, seeds[1].xmlSha256)
		assert.are.equal("Latest label", seeds[1].label, "duplicate XML observations should use the newest metadata")
		assert.are.equal("unverified", seeds[1].rightsStatus)
		assert.are.equal("observation_only_pending_rights_and_exact_labels", seeds[1].trainingStatus)

		local loaded, loadError = StudyBuilds.ReadArchivedSeed(userPath, xmlHash, {
			dataVersion = tostring(Version.Data(build)), treeVersion = tostring(Version.Tree(build)),
		})
		assert.is_nil(loadError)
		assert.are.equal(xmlText, loaded.xmlText)
		assert.are.equal(xmlHash, Sha.sha256(loaded.xmlText))

		writeFile(objectPath, xmlText .. "tampered")
		local rejected, integrityError = StudyBuilds.ReadArchivedSeed(userPath, xmlHash, {
			dataVersion = tostring(Version.Data(build)), treeVersion = tostring(Version.Tree(build)),
		})
		assert.is_nil(rejected)
		assert.is_truthy(integrityError:find("SHA-256", 1, true))
		newBuild()
	end)

	it("falls back to the local archive when the configured project archive is unavailable", function()
		local temporaryBase = os.tmpname()
		os.remove(temporaryBase)
		userPath = temporaryBase .. "-fallback-user"
		archiveRoot = temporaryBase .. "-missing-project-archive"
		makeDirectory(archiveRoot)
		local localPaths = assert(StudyBuilds.GetPaths(userPath))
		for _, directory in ipairs({ userPath, localPaths.studies, localPaths.root, localPaths.catalogDirectory }) do
			makeDirectory(directory)
		end
		writeFile(localPaths.index, "")
		writeFile(localPaths.patchSkillCatalog, "{}")
		writeFile(join(localPaths.studies, "BuildArchiveSource.json"), assert(Json.encode({
			schema = "pob-ai-planner-archive-source", schemaVersion = 1,
			root = archiveRoot, readOnly = true,
		})))

		local source, sourceError = StudyBuilds.GetPlannerArchiveSource(userPath)
		assert.is_nil(sourceError)
		assert.are.equal("local_fallback", source.mode)
		assert.are.equal("ready", source.status)
		assert.are.equal(userPath, source.root)
		assert.are.equal(archiveRoot, source.configuredRoot)
		assert.are.equal("no_imported_build_archive", source.fallbackReason)
		assert.is_true(source.readOnly)
	end)

	it("reads a configured external archive and hash-checks one current-patch seed", function()
		newBuild()
		local engine = Version.Snapshot(build)
		local sourceUserPath = main.userPath
		local archiveSource = StudyBuilds.GetPlannerArchiveSource(sourceUserPath)
		print("ARCHIVE_SOURCE_CHECK " .. tostring(archiveSource and archiveSource.mode or "unavailable")
			.. " " .. tostring(archiveSource and archiveSource.status or "missing"))
		if not archiveSource or archiveSource.mode ~= "project_archive" or archiveSource.status ~= "ready" then return end
		local seeds, summary = StudyBuilds.ListArchivedSeeds(sourceUserPath, {
			dataVersion = tostring(engine.dataVersion), treeVersion = tostring(engine.treeVersion),
		})
		assert.is_table(seeds)
		assert.is_true(#seeds > 0, "the configured archive should contain a current-patch seed")
		assert.is_truthy(summary.observationCount >= #seeds)
		local seed = assert(StudyBuilds.ReadArchivedSeed(sourceUserPath, seeds[1].xmlSha256, {
			dataVersion = tostring(engine.dataVersion), treeVersion = tostring(engine.treeVersion),
		}))
		assert.are.equal(seeds[1].xmlSha256, Sha.sha256(seed.xmlText))
		assert.are.equal("unverified", seed.rightsStatus)
		assert.are.equal("observation_only_pending_rights_and_exact_labels", seed.trainingStatus)
		print(string.format("ARCHIVE_SEEDS %s | %d observations | %d unique compatible seeds",
			tostring(engine.dataVersion), summary.observationCount, #seeds))
		newBuild()
	end)

	it("imports one selected current-patch seed through PoB's native new-build loader", function()
		newBuild()
		local sourceUserPath = main.userPath
		local archiveSource = StudyBuilds.GetPlannerArchiveSource(sourceUserPath)
		if not archiveSource or archiveSource.mode ~= "project_archive" or archiveSource.status ~= "ready" then return end
		local engine = Version.Snapshot(build)
		local seeds = assert(StudyBuilds.ListArchivedSeeds(sourceUserPath, {
			dataVersion = tostring(engine.dataVersion), treeVersion = tostring(engine.treeVersion),
		}))
		assert.is_true(#seeds > 0)
		local seed = assert(StudyBuilds.ReadArchivedSeed(sourceUserPath, seeds[1].xmlSha256, {
			dataVersion = tostring(engine.dataVersion), treeVersion = tostring(engine.treeVersion),
		}))
		local importTab = assert(build.importTab)
		local imported, importError = importTab:ImportArchivedSeed(seed.xmlText, seed.buildName)
		if main.popups and main.popups[1] then main:ClosePopup() end
		local importState = require("Modules.Optimizer.ImportLifecycle").Snapshot(build.importTab)
		local calculated = build.calcsTab and build.calcsTab.mainOutput ~= nil
		newBuild()
		assert.is_true(imported, tostring(importError))
		assert.are.equal("loaded", importState.status, "the native PoB import should be confirmed as loaded")
		assert.is_true(calculated, "the imported seed should reach exact native PoB calculation")
	end)

	it("rebases archived seed planner context and keeps the user's route goals", function()
		newBuild()
		local duelistId = assert(build.spec.tree.classNameMap.Duelist)
		build.spec:SelectClass(duelistId)
		build.skillsTab:PasteSocketGroup("Cyclone 1/0 1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.skillsTab:UpdateSocketGroups()
		build.calcsTab:BuildOutput()

		local sourceOptimizer = build.optimizerTab
		sourceOptimizer.textValues.baseClassId = "0" -- Stale Scion selector from the archived XML.
		sourceOptimizer.textValues.routePlannerDpsTier = "TIER_1M_TO_5M"
		sourceOptimizer.textValues.damageFocus = "Cold"
		sourceOptimizer.textValues.defenseProfile = "Auto"
		sourceOptimizer.textValues.targetNodeIds = "999999"
		sourceOptimizer.textValues.routePlannerModelPackageId = "seed-package-from-another-engine"
		sourceOptimizer.textValues.routePlannerModelMode = "approved_gnn"
		local seedXml = assert(build:SaveDB("QA archived seed with stale Planner context"))

		-- Preferences chosen in the currently open Planner take precedence over
		-- values embedded in the archived seed XML.
		sourceOptimizer.textValues.routePlannerDpsTier = "TIER_50M_PLUS"
		sourceOptimizer.textValues.damageFocus = "Fire"
		sourceOptimizer.textValues.defenseProfile = "EnergyShield"
		sourceOptimizer.textValues.routePlannerProposalLimit = "100000"
		sourceOptimizer.textValues.routePlannerExactEvaluationBudget = "10000"
		sourceOptimizer.textValues.targetNodeIds = "123456"
		local imported, importError = build.importTab:ImportArchivedSeed(seedXml, "QA archived seed")
		local importState = require("Modules.Optimizer.ImportLifecycle").Snapshot(build.importTab)
		local importedOptimizer = build.optimizerTab
		local importedSkillGem = require("Modules.Optimizer.SkillCatalog").CurrentMainGemId(build, build.mainSocketGroup,
			build.skillsTab.socketGroupList[build.mainSocketGroup].mainActiveSkill)
		local importedClassId = build.spec.curClassId
		newBuild()

		assert.is_true(imported, tostring(importError))
		assert.are.equal("loaded", importState.status)
		assert.are.equal(tostring(duelistId), importedOptimizer.textValues.baseClassId,
			"the planner must use the native class loaded from the seed tree")
		assert.are.equal(tostring(importedClassId), importedOptimizer.textValues.baseClassId)
		assert.are.equal(tostring(importedSkillGem or ""), importedOptimizer.textValues.targetSkillGemId,
			"the planner must bind to the imported Main Skill")
		assert.are.equal("TIER_50M_PLUS", importedOptimizer.textValues.routePlannerDpsTier)
		assert.are.equal("Fire", importedOptimizer.textValues.damageFocus)
		assert.are.equal("EnergyShield", importedOptimizer.textValues.defenseProfile)
		assert.are.equal("100000", importedOptimizer.textValues.routePlannerProposalLimit)
		assert.are.equal("10000", importedOptimizer.textValues.routePlannerExactEvaluationBudget)
		assert.are.equal("", importedOptimizer.textValues.targetNodeIds)
		assert.are.equal("", importedOptimizer.textValues.routePlannerModelPackageId)
		assert.are.equal("deterministic_fallback", importedOptimizer.textValues.routePlannerModelMode)
	end)
end)
