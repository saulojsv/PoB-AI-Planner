local MCPBridge = require("Modules.Optimizer.MCPBridge")
local Candidate = require("Modules.Optimizer.Candidate")
local StudyRecords = require("Modules.Optimizer.StudyRecords")
local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local PathExperience = require("Modules.Optimizer.PathExperience")
local SkillSeed = require("Modules.Optimizer.SkillSeed")
local Version = require("Modules.Optimizer.Version")
local BoundedInflate = require("Modules.Optimizer.BoundedInflate")
local FireballFlameWallFixture = require("System.fixtures.OptimizerSkillPackages_3_29")
local TestSupport = require("OptimizerTestSupport")

describe("Optimizer public build study imports", function()
	local originalDownloadBuild
	local originalDownloadPage
	local originalBoundedInflate
	local originalListener
	local originalPort
	local originalToken
	local originalHealthPath
	local originalHealthWrite
	local originalEndpointPath
	local originalInstanceId
	local originalPollCount
	local originalFrameCount
	local originalRecordAppend
	local originalBuildArchive
	local originalPathExperienceCreate
	local originalPathExperienceAppend
	local healthFixturePath
	local endpointFixturePath

	before_each(function()
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		MCPBridge.studyJobs = { }
		MCPBridge.studyBuilds = { }
		MCPBridge.comparisonOwner = nil
		MCPBridge.comparisonTab = nil
		MCPBridge.comparisonEntriesById = nil
		MCPBridge.comparisonIdByEntry = nil
		MCPBridge.qaJobs = { }
		MCPBridge.nextStudyJob = 0
		MCPBridge.nextStudy = 0
		originalDownloadBuild = buildSites.DownloadBuild
		originalDownloadPage = launch.DownloadPage
		originalBoundedInflate = BoundedInflate.inflate
		originalListener, originalPort, originalToken = MCPBridge.listener, MCPBridge.port, MCPBridge.token
		originalHealthPath, originalHealthWrite = MCPBridge.healthPath, MCPBridge.lastHealthWrite
		originalEndpointPath, originalInstanceId = MCPBridge.endpointPath, MCPBridge.instanceId
		originalPollCount, originalFrameCount = MCPBridge.pollCount, MCPBridge.frameCount
		originalRecordAppend = StudyRecords.Append
		originalBuildArchive = StudyBuilds.ArchiveXML
		StudyBuilds.ArchiveXML = function(archiveBuild, xmlText, userPath, source)
			return {
				observationId = "fixture-build-observation",
				xmlSha256 = string.rep("a", 64),
				lineageSha256 = string.rep("b", 64),
				storageStatus = "stored",
				relativeRoot = "OptimizerStudies/Builds",
				configuredEffectCount = 1,
				availableEffectCount = 1,
				trainingStatus = "observation_only_pending_rights_and_exact_labels",
			}
		end
		originalPathExperienceCreate = PathExperience.CreateRecord
		originalPathExperienceAppend = PathExperience.AppendBatch
		-- These imports exercise PoB's base64/XML/native-loader path. The bounded
		-- zlib contract is covered with actual compressed streams in its own suite.
		-- HeadlessWrapper's Deflate stub emits no stream, so return these fixture
		-- bytes at the exact decompression boundary rather than weakening production.
		BoundedInflate.inflate = function(data) return data end
	end)

	local function publishFixtureEndpoint()
		endpointFixturePath = os.tmpname()
		os.remove(endpointFixturePath)
		MCPBridge.endpointPath = endpointFixturePath
		MCPBridge.instanceId = "fixture-study-instance"
		local endpointFile = assert(io.open(endpointFixturePath, "wb"))
		endpointFile:write(assert(require("dkjson").encode({
			host = "127.0.0.1", port = MCPBridge.port, token = MCPBridge.token,
			protocol = "pob-mcp-1", instanceId = MCPBridge.instanceId,
		})))
		endpointFile:close()
	end

	it("runs bounded read-only integration QA and preserves the active build", function()
		MCPBridge.listener, MCPBridge.port, MCPBridge.token = { }, 49152, "fixture-auth-token"
		publishFixtureEndpoint()
		local signature = Candidate.BuildSignature(build)
		local started, startError = MCPBridge:CallLocal("qa_start", { suite = "integration" })
		assert.is_nil(startError)
		assert.are.equal("running", started.status)
		for _ = 1, 12 do
			MCPBridge:StepQASuites()
			local current = assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId }))
			if current.status ~= "running" then break end
		end
		local result = assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId }))
		assert.are.equal("passed", result.status, result.error)
		assert.is_true(result.readOnly)
		assert.is_true(result.activeBuildPreserved)
		assert.is_true(#result.checks >= 5)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("runs one exact no-op optimizer QA calculation without applying a candidate", function()
		local signature = Candidate.BuildSignature(build)
		local started, startError = MCPBridge:CallLocal("qa_start", { suite = "optimizer_smoke" })
		assert.is_nil(startError)
		for _ = 1, 40 do
			MCPBridge:StepQASuites()
			local current = assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId }))
			if current.status ~= "running" then break end
		end
		local result = assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId }))
		assert.are.equal("passed", result.status, result.error)
		assert.are.equal(1, result.exactEvaluations)
		assert.is_true(result.exactMetric.matchesCurrentPoB)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("surfaces an unsustainable active damage build as a readiness warning", function()
		build.characterLevel = 9
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local snapshotBeforeQA = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
		local costAudit = snapshotBeforeQA.skillCostAudit
		assert.are.equal("pass", costAudit.status)
		assert.are.equal("reported_schedule_available", costAudit.recurringStatus)
		assert.are.equal(1, costAudit.auditedSkills)
		assert.are.equal("Fireball", costAudit.skills[1].name)
		assert.is_true(costAudit.skills[1].resources.mana.perSecond > 0)
		local signature = Candidate.BuildSignature(build)
		local started = assert(MCPBridge:CallLocal("qa_start", { suite = "build" }))
		for _ = 1, 16 do
			MCPBridge:StepQASuites()
			local current = assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId }))
			if current.status ~= "running" then break end
		end
		local result = assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId }))
		assert.are.equal("passed_with_warnings", result.status, result.error)
		local sustain, costAuditCheck
		for _, check in ipairs(result.checks or { }) do
			if check.name == "Native recurring activity sustain" then sustain = check end
			if check.name == "Native per-skill upfront and recurring costs" then costAuditCheck = check end
		end
		assert.is_truthy(sustain)
		assert.are.equal("warning", sustain.status)
		assert.is_truthy(sustain.detail:find("Exact PoB recovery", 1, true))
		assert.is_truthy(costAuditCheck)
		assert.are.equal("pass", costAuditCheck.status)
		assert.is_truthy(costAuditCheck.detail:find("all-enabled-skills schedule estimates recurring resources only", 1, true))
		assert.are.equal(signature, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("evaluates an explicit Main Skill schedule with PoB rates and preserves the active build", function()
		build.characterLevel = 9
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local before = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
		local activity = assert(before.activitySustain.activities[1])
		assert.is_truthy(activity.identity)
		assert.is_table(activity.poBDamage)
		assert.is_true(activity.poBDamage.player.TotalDPS > 0)
		local signature = Candidate.BuildSignature(build)
		local result, scheduleError = MCPBridge:CallLocal("evaluate_activity_schedule", {
			scope = "main_skill",
			activities = { { identity = activity.identity, mode = "scheduled", ratePercent = 25 } },
		})
		assert.is_nil(scheduleError)
		assert.are.equal("sustain_estimate", result.status)
		assert.are.equal("pass", result.sustainStatus)
		assert.is_true(result.sustainFeasible)
		assert.is_nil(result.feasible)
		assert.is_true(result.readOnly)
		assert.is_true(result.activeBuildPreserved)
		assert.is_false(result.damageScheduleCertified)
		assert.is_true(result.metrics.SustainedManaMargin > 0)
		assert.are.equal("linear_per_activity_estimate", result.activities[1].poBDamageProjection.status)
		assert.is_true(result.activities[1].poBDamageProjection.perActivity.player.TotalDPS > 0)
		assert.is_nil(result.damageScheduleProjection.combinedDPS)
		assert.are.equal(signature, Candidate.BuildSignature(build))
		local rejectedSelfDependency, selfDependencyError = MCPBridge:CallLocal("evaluate_activity_schedule", {
			scope = "main_skill",
			activities = { { identity = activity.identity, mode = "continuous", requires = { activity.identity } } },
		})
		assert.is_nil(rejectedSelfDependency)
		assert.is_truthy(selfDependencyError:find("cannot require itself", 1, true))
		local invalid, invalidError = MCPBridge:CallLocal("evaluate_activity_schedule", {
			scope = "main_skill",
			activities = { { identity = "untrusted-identity", mode = "continuous" } },
		})
		assert.is_nil(invalid)
		assert.is_truthy(invalidError:find("identity from PoB", 1, true))
		newBuild()
	end)

	it("keeps the versioned Flame Wall and Fireball package exact-resource-only", function()
		assert.are.equal(FireballFlameWallFixture.pobAppVersion, tostring(launch.versionNumber), "fixture must be reviewed when PoB changes")
		assert.are.equal(FireballFlameWallFixture.dataVersion, tostring(Version.Data(build)), "fixture must be reviewed when PoE game data advances")
		assert.are.equal(FireballFlameWallFixture.treeVersion, tostring(Version.Tree(build)), "fixture is bound to its native passive-tree data")
		build.characterLevel = FireballFlameWallFixture.characterLevel
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup(FireballFlameWallFixture.socketGroups[1])
		build.mainSocketGroup = FireballFlameWallFixture.mainSocketGroup
		build.calcsTab:BuildOutput()
		local baselineDPS = build.calcsTab.mainOutput.CombinedDPS
		build.skillsTab:PasteSocketGroup(FireballFlameWallFixture.socketGroups[2])
		build.configTab:BuildModList()
		build.calcsTab:BuildOutput()
		local noSetupConditionDPS = build.calcsTab.mainOutput.CombinedDPS
		local configChange, configError = MCPBridge:CallLocal("set_config_options", {
			values = { [FireballFlameWallFixture.exactConfigAblation.key] = true },
		})
		assert.is_nil(configError)
		assert.are.equal(true, configChange.changed[FireballFlameWallFixture.exactConfigAblation.key])
		assert.are.equal(false, configChange.previous[FireballFlameWallFixture.exactConfigAblation.key])
		build.calcsTab:BuildOutput()
		local configuredDPS = build.calcsTab.mainOutput.CombinedDPS
		local expected = FireballFlameWallFixture.exactConfigAblation
		assert.is_true(math.abs(baselineDPS - expected.baselineCombinedDPS) < 1e-8)
		assert.is_true(math.abs(noSetupConditionDPS - expected.withoutConfigCombinedDPS) < 1e-8)
		assert.is_true(math.abs(configuredDPS - expected.withConfigCombinedDPS) < 1e-8)
		assert.is_true(configuredDPS > noSetupConditionDPS, "only the native Flame Wall travel condition should increase Fireball DPS")

		local before = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
		local records = before.skillCostAudit and before.skillCostAudit.scheduleActivities or { }
		local byName = { }
		for _, record in ipairs(records) do
			assert.is_true(record.exact, "each fixture skill must expose an exact native resource record")
			byName[record.name] = record
		end
		local setup = assert(byName[FireballFlameWallFixture.setupSkill], "PoB omitted the setup skill from all enabled skills")
		local payoff = assert(byName[FireballFlameWallFixture.payoffSkill], "PoB omitted the payoff skill from all enabled skills")
		assert.is_truthy(setup.identity)
		assert.is_truthy(payoff.identity)
		local signature = Candidate.BuildSignature(build)

		local result, scheduleError = MCPBridge:CallLocal("evaluate_activity_schedule", {
			scope = "all_enabled_skills",
			activities = {
				{ identity = setup.identity, mode = "setup", ratePercent = FireballFlameWallFixture.setupRatePercent },
				{ identity = payoff.identity, mode = "scheduled", ratePercent = FireballFlameWallFixture.payoffRatePercent, requires = { setup.identity } },
			},
		})
		assert.is_nil(scheduleError)
		assert.are.equal("sustain_estimate", result.status)
		assert.is_true(result.resourceOnly)
		assert.is_true(result.exactPoBActivityRates)
		assert.are.equal("structure_only", result.dependencyAudit.status)
		assert.are.equal(1, result.dependencyAudit.edgeCount)
		assert.is_false(result.dependencyAudit.timingCertified)
		assert.is_false(result.damageScheduleCertified)
		assert.are.equal("not_computed_resource_only", result.damageScheduleProjection.status)
		assert.is_nil(result.damageScheduleProjection.combinedDPS)
		assert.is_nil(result.feasible, "a resource-only schedule is not whole-build feasibility")
		assert.is_true(result.activeBuildPreserved)
		assert.are.equal(signature, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("keeps a versioned guard utility independent from the primary damage activity", function()
		local fixture = FireballFlameWallFixture.independentUtility
		assert.are.equal(fixture.pobAppVersion, tostring(launch.versionNumber), "utility fixture must be reviewed when PoB changes")
		assert.are.equal(FireballFlameWallFixture.dataVersion, tostring(Version.Data(build)), "utility fixture must be reviewed when PoE game data advances")
		assert.are.equal(FireballFlameWallFixture.treeVersion, tostring(Version.Tree(build)), "utility fixture is bound to its native passive-tree data")
		build.characterLevel = fixture.characterLevel
		build.characterLevelAutoMode = false
		for _, socketGroup in ipairs(fixture.socketGroups) do
			build.skillsTab:PasteSocketGroup(socketGroup)
		end
		build.mainSocketGroup = fixture.mainSocketGroup
		build.calcsTab:BuildOutput()

		local before = assert(MCPBridge:CallLocal("get_build_snapshot", { }))
		local byName = { }
		for _, record in ipairs(before.skillCostAudit.scheduleActivities or { }) do
			assert.is_true(record.exact, "each fixture skill must expose an exact native resource record")
			byName[record.name] = record
		end
		local primary = assert(byName[fixture.primarySkill], "PoB omitted the primary skill from all enabled skills")
		local utility = assert(byName[fixture.utilitySkill], "PoB omitted the guard utility from all enabled skills")
		local signature = Candidate.BuildSignature(build)
		local result, scheduleError = MCPBridge:CallLocal("evaluate_activity_schedule", {
			scope = "all_enabled_skills",
			activities = {
				{ identity = primary.identity, mode = "scheduled", ratePercent = fixture.primaryRatePercent },
				{ identity = utility.identity, mode = "setup", ratePercent = fixture.utilityRatePercent },
			},
		})
		assert.is_nil(scheduleError)
		assert.are.equal("sustain_estimate", result.status)
		assert.are.equal("none", result.dependencyAudit.status)
		assert.are.equal(0, result.dependencyAudit.edgeCount)
		assert.is_false(result.dependencyAudit.timingCertified)
		assert.is_false(result.damageScheduleCertified)
		assert.are.equal("not_computed_resource_only", result.damageScheduleProjection.status)
		assert.is_nil(result.damageScheduleProjection.combinedDPS)
		assert.is_true(result.activeBuildPreserved)
		assert.are.equal(signature, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("rejects unknown QA suites and supports cancellation before work starts", function()
		local unknown, unknownError = MCPBridge:CallLocal("qa_start", { suite = "arbitrary-code" })
		assert.is_nil(unknown)
		assert.is_truthy(unknownError)
		local started = assert(MCPBridge:CallLocal("qa_start", { suite = "build" }))
		local cancelled = assert(MCPBridge:CallLocal("qa_cancel", { jobId = started.jobId }))
		assert.are.equal("cancelled", cancelled.status)
	end)

	it("reports in-process loop health without exposing the endpoint token", function()
		MCPBridge.listener, MCPBridge.port, MCPBridge.token = { }, 49152, "fixture-auth-token"
		MCPBridge.pollCount = 17
		MCPBridge.frameCount = 12
		MCPBridge:FrameComplete()
		local health = assert(MCPBridge:CallLocal("connection_health", { }))
		assert.are.equal("fresh", health.status)
		assert.are.equal(5, health.snapshotContractVersion)
		assert.are.equal(17, health.pollCount)
		assert.are.equal(13, health.frameCount)
		assert.is_nil(health.token)
	end)

	it("publishes only frame and poll diagnostics in its local heartbeat file", function()
		local json = require("dkjson")
		healthFixturePath = os.tmpname()
		os.remove(healthFixturePath)
		MCPBridge.healthPath = healthFixturePath
		MCPBridge.listener, MCPBridge.port, MCPBridge.token = { }, 49152, "fixture-auth-token"
		MCPBridge.pollCount = 17
		MCPBridge.frameCount = 12
		MCPBridge.lastHealthWrite = 0
		MCPBridge:FrameComplete()
		local file = assert(io.open(healthFixturePath, "r"))
		local heartbeat = json.decode(file:read("*a"))
		file:close()
		assert.are.equal("pob-mcp-health-1", heartbeat.protocol)
		assert.are.equal(5, heartbeat.snapshotContractVersion)
		assert.are.equal(49152, heartbeat.port)
		assert.are.equal(17, heartbeat.pollCount)
		assert.are.equal(13, heartbeat.frameCount)
		assert.is_truthy(heartbeat.timestampMs > 0)
		assert.is_nil(heartbeat.token)
	end)

	it("keeps QA history bounded while retaining a new completed suite", function()
		MCPBridge.listener, MCPBridge.port, MCPBridge.token = { }, 49152, "fixture-auth-token"
		publishFixtureEndpoint()
		for _ = 1, 8 do
			local started = assert(MCPBridge:CallLocal("qa_start", { suite = "integration" }))
			for _ = 1, 8 do
				MCPBridge:StepQASuites()
				local current = assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId }))
				if current.status ~= "running" then break end
			end
			assert.are.equal("passed", assert(MCPBridge:CallLocal("qa_status", { jobId = started.jobId })).status)
		end
		local newest = assert(MCPBridge:CallLocal("qa_start", { suite = "integration" }))
		assert.are.equal("running", newest.status)
		local count = 0
		for _ in pairs(MCPBridge.qaJobs) do count = count + 1 end
		assert.is_true(count <= 8)
	end)

	after_each(function()
		buildSites.DownloadBuild = originalDownloadBuild
		launch.DownloadPage = originalDownloadPage
		BoundedInflate.inflate = originalBoundedInflate
		MCPBridge.listener, MCPBridge.port, MCPBridge.token = originalListener, originalPort, originalToken
		MCPBridge.healthPath, MCPBridge.lastHealthWrite = originalHealthPath, originalHealthWrite
		MCPBridge.endpointPath, MCPBridge.instanceId = originalEndpointPath, originalInstanceId
		MCPBridge.pollCount, MCPBridge.frameCount = originalPollCount, originalFrameCount
		StudyRecords.Append = originalRecordAppend
		StudyBuilds.ArchiveXML = originalBuildArchive
		PathExperience.CreateRecord = originalPathExperienceCreate
		PathExperience.AppendBatch = originalPathExperienceAppend
		if healthFixturePath then os.remove(healthFixturePath) healthFixturePath = nil end
		if endpointFixturePath then os.remove(endpointFixturePath) endpointFixturePath = nil end
	end)

	local function encodedBuild()
		local xmlText = build:SaveDB("study fixture")
		assert.is_truthy(xmlText and #xmlText > 0, "PoB failed to serialize the active build")
		local encoded = common.base64.encode(xmlText)
		assert.is_truthy(encoded and #encoded > 0, "PoB failed to encode the active build")
		return encoded
	end

	local function prepareWitchNecromancerFireball()
		build.characterLevel, build.characterLevelAutoMode = 90, false
		local witchId = assert(build.spec.tree.classNameMap.Witch)
		build.spec:SelectClass(witchId)
		local necromancerId
		for id, ascendancy in pairs(build.spec.curClass.classes or { }) do
			if ascendancy.name == "Necromancer" or ascendancy.id == "Necromancer" then necromancerId = id break end
		end
		assert.is_truthy(necromancerId, "PoB 3.29 must expose Witch/Necromancer")
		build.spec:SelectAscendClass(necromancerId)
		local seed, seedError = SkillSeed.Create(build, "Metadata/Items/Gems/SkillGemFireball", witchId)
		assert.is_truthy(seed, seedError)
		build.skillsTab.socketGroupList[seed.groupIndex].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		return seed, witchId, necromancerId
	end

	it("learns sanitized exact route outcomes from an imported build without mutating either build", function()
		local seed, witchId = prepareWitchNecromancerFireball()
		local code = encodedBuild()
		buildSites.DownloadBuild = function(_, _, callback)
			callback(true, code, "https://pobb.in/pob/optimizer-study-fixture")
		end
		local activeSignature = Candidate.BuildSignature(build)
		local startedImport = assert(MCPBridge:CallLocal("import_build_url", {
			url = "https://pobb.in/optimizer-study-fixture", label = "Optimizer study fixture",
		}))
		assert.are.equal("complete", startedImport.status, startedImport.error)
		local studyId = assert(startedImport.studyId)
		local entry = build.compareTab.compareEntries[#build.compareTab.compareEntries]
		assert.are_not.equal(build, entry)
		local sourceSignature = Candidate.BuildSignature(entry)
		local activeSelection = build.compareTab.activeCompareIndex
		local sourceCreates, sourceAppends, sourceRows = 0, 0, { }
		PathExperience.CreateRecord = function(...)
			sourceCreates = sourceCreates + 1
			return originalPathExperienceCreate(...)
		end
		PathExperience.AppendBatch = function(_, records)
			sourceAppends = sourceAppends + 1
			for _, record in ipairs(records or { }) do sourceRows[#sourceRows + 1] = record end
			return { stored = #records, duplicates = 0, status = "ready" }
		end

		local started, startError = MCPBridge:CallLocal("optimizer_start", {
			studyId = studyId,
			matrix = {
				generationPhase = "skills", objectiveMetric = "FullDPS", evaluationBudget = "2",
				maxAddedPoints = "0", maxTotalPoints = "120",
				targetSkillGroupIndex = tostring(seed.groupIndex), targetSkillIndex = tostring(seed.skillIndex),
				targetSkillGemId = "Metadata/Items/Gems/SkillGemFireball",
			},
		})
		assert.is_nil(startError)
		assert.is_truthy(started and started.jobId)
		assert.is_true(started.isolatedStudyReadOnly)
		assert.are.equal("public_build_study", started.sourceBuild.type)
		assert.are.equal(studyId, started.sourceBuild.studyId)
		assert.is_true(MCPBridge:IsStudyOptimizerRunning())
		local jobRecord = assert(MCPBridge.jobs[started.jobId])
		assert.are_not.equal(build.optimizerTab, jobRecord.tab, "isolated optimization must never borrow the visible active tab instance")
		assert.are_not.equal(build, jobRecord.build)

		local result
		for _ = 1, 5000 do
			MCPBridge:Poll()
			result = assert(MCPBridge:CallLocal("optimizer_status", { jobId = started.jobId }))
			if result.status ~= "running" then break end
		end
		assert.is_true(result.status == "feasible" or result.status == "no_feasible_candidate", result.message)
		assert.is_true((result.evaluations or 0) > 0, "the imported build must reach exact PoB evaluation")
		assert.is_true(result.isolatedStudyReadOnly)
		assert.are.equal(studyId, result.sourceBuild.studyId)
		assert.is_true(result.searchBaseline and result.searchBaseline.exact)
		local pathLearning = assert(result.searchCoverage and result.searchCoverage.pathLearning)
		assert.is_true(pathLearning.recordWritesEnabled)
		assert.are.equal("exact_imported_study_observations", pathLearning.recordWritePolicy)
		assert.is_true((pathLearning.exactObservations or 0) >= 2,
			"baseline and at least one candidate must be captured exactly: " .. assert(require("dkjson").encode(pathLearning)))
		assert.are.equal(pathLearning.exactObservations, sourceCreates)
		assert.is_true(sourceAppends > 0)
		assert.are.equal(pathLearning.exactObservations, #sourceRows)
		local hasBaseline, hasCandidate = false, false
		for _, record in ipairs(sourceRows) do
			assert.are.equal("imported_study", record.context.observationSource)
			assert.are.equal(64, #record.sourceBuildHash, "source identity must be stored as a SHA-256 digest")
			assert.is_truthy(record.sourceBuildHash:match("^[%da-f]+$"))
			hasBaseline = hasBaseline or record.candidate.isBaseline
			hasCandidate = hasCandidate or not record.candidate.isBaseline
		end
		assert.is_true(hasBaseline and hasCandidate, "route learning requires exact baseline/candidate pairs")
		local encodedPathRows = assert(require("dkjson").encode(sourceRows))
		assert.is_nil(encodedPathRows:find("https://pobb.in/optimizer-study-fixture", 1, true), "path memory must not persist import URLs")
		assert.are.equal(activeSignature, Candidate.BuildSignature(build), "active build signature must remain unchanged")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(entry), "imported source must remain unchanged")
		assert.are.equal(activeSelection, build.compareTab.activeCompareIndex, "optimizer must preserve the Compare selection")
		assert.is_nil(build.optimizerTab.job, "isolated job must not be attached to the visible active tab")
		local applied, applyError = MCPBridge:CallLocal("optimizer_apply", { jobId = started.jobId, candidateIndex = 0 })
		assert.is_nil(applied)
		assert.is_truthy(applyError and applyError:find("read%-only"))
		assert.are.equal(activeSignature, Candidate.BuildSignature(build))
		assert.are.equal(sourceSignature, Candidate.BuildSignature(entry))
	end)

	it("marks an isolated optimizer stale and cancels it when its imported source is removed", function()
		local code = encodedBuild()
		buildSites.DownloadBuild = function(_, _, callback)
			callback(true, code, "https://pobb.in/pob/optimizer-stale-fixture")
		end
		local activeSignature = Candidate.BuildSignature(build)
		local imported = assert(MCPBridge:CallLocal("import_build_url", {
			url = "https://pobb.in/optimizer-stale-fixture", label = "Stale optimizer fixture",
		}))
		assert.are.equal("complete", imported.status, imported.error)
		local started, startError = MCPBridge:CallLocal("optimizer_start", {
			studyId = imported.studyId,
			matrix = { generationPhase = "tree", objectiveMetric = "TotalEHP", evaluationBudget = "100", maxAddedPoints = "5", maxTotalPoints = "120" },
		})
		assert.is_nil(startError)
		assert.is_truthy(started and started.jobId)
		assert.is_truthy(MCPBridge:CallLocal("remove_study_build", { studyId = imported.studyId }))
		MCPBridge:Poll()
		local status = assert(MCPBridge:CallLocal("optimizer_status", { jobId = started.jobId }))
		assert.are.equal("stale_build", status.status)
		assert.is_truthy(status.message and status.message:find("removed", 1, true))
		local applied, applyError = MCPBridge:CallLocal("optimizer_apply", { jobId = started.jobId, candidateIndex = 0 })
		assert.is_nil(applied)
		assert.is_truthy(applyError and applyError:find("read%-only"))
		assert.are.equal(activeSignature, Candidate.BuildSignature(build))
		assert.is_nil(MCPBridge:CallLocal("get_study_build_snapshot", { studyId = imported.studyId }))
	end)

	it("imports through PoB's native URL importer as an exact isolated comparison and releases it", function()
		local code = encodedBuild()
		buildSites.DownloadBuild = function(_, _, callback)
			callback(true, code, "https://pobb.in/pob/studyfixture")
		end
		local signature = Candidate.BuildSignature(build)
		local compareTab = build.compareTab
		local previousSelection = compareTab.activeCompareIndex
		local previousCount = #compareTab.compareEntries
		local previousViewMode = build.viewMode

		local started, startError = MCPBridge:CallLocal("import_build_url", {
			url = "https://pobb.in/studyfixture",
			label = "Study fixture",
			league = "Affliction",
		})
		assert.is_nil(startError)
		assert.are.equal("complete", started.status, started.error or "import did not complete")
		assert.is_true(started.activeBuildPreserved)
		assert.is_truthy(started.studyId)
		assert.are.equal(signature, Candidate.BuildSignature(build))
		assert.are.equal(previousViewMode, build.viewMode)
		assert.are.equal(previousSelection, compareTab.activeCompareIndex)
		assert.are.equal(previousCount + 1, #compareTab.compareEntries)

		local entry = compareTab.compareEntries[previousCount + 1]
		assert.is_nil(entry.xmlText)
		assert.is_nil(entry.xmlSectionList)
		-- SocketIdURL data is stored beside named item slots under numeric node
		-- IDs; the public snapshot must treat it as metadata, not an equip slot.
		entry.itemsTab.activeItemSet[123456] = { pbURL = "https://pobb.in/pob/socket-fixture" }
		entry.itemsTab.items[9999] = {
			id = 9999,
			name = "Fixture Helmet",
			type = "Helmet",
			rarity = "RARE",
			base = { name = "Fixture Base" },
		}
		local snapshot = assert(MCPBridge:CallLocal("get_study_build_snapshot", { studyId = started.studyId }))
		assert.is_false(snapshot.isActiveBuild)
		assert.are.equal("pobb.in", snapshot.study.provider)
		assert.are.equal("Affliction", snapshot.study.claimedLeague)
		assert.is_table(snapshot.study.archive)
		assert.are.equal("OptimizerStudies/Builds", snapshot.study.archive.relativeRoot)
		assert.are.equal(1, snapshot.study.archive.configuredEffectCount)
		assert.is_table(snapshot.exactMetrics)
		local fixtureItem
		for _, item in ipairs(snapshot.availableItems) do
			if item.id == 9999 then fixtureItem = item break end
		end
		assert.is_truthy(fixtureItem, "snapshot omitted the valid named-slot item")
		assert.are.equal(1, #fixtureItem.validActiveSetSlots)
		assert.are.equal("Helmet", fixtureItem.validActiveSetSlots[1])
		if entry.calcsTab.mainOutput.TotalEHP then
			assert.are.equal(entry.calcsTab.mainOutput.TotalEHP, snapshot.exactMetrics.TotalEHP)
		end

		local removed = assert(MCPBridge:CallLocal("remove_study_build", { studyId = started.studyId }))
		assert.is_true(removed.removed)
		assert.is_true(removed.activeBuildPreserved)
		assert.are.equal(previousCount, #compareTab.compareEntries)
		assert.is_nil(MCPBridge:CallLocal("get_study_build_snapshot", { studyId = started.studyId }))
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("does not keep a study comparison when its persistent build archive write fails", function()
		buildSites.DownloadBuild = function(_, _, callback)
			callback(true, encodedBuild(), "https://pobb.in/pob/archive-failure-fixture")
		end
		StudyBuilds.ArchiveXML = function() return nil, "simulated archive write failure" end
		local signature = Candidate.BuildSignature(build)
		local compareTab = build.compareTab
		local previousCount = #compareTab.compareEntries
		local started = assert(MCPBridge:CallLocal("import_build_url", {
			url = "https://pobb.in/archive-failure-fixture", label = "Archive failure fixture",
		}))
		assert.are.equal("failed", started.status)
		assert.is_truthy(started.error and started.error:find("simulated archive write failure", 1, true))
		assert.are.equal(previousCount, #compareTab.compareEntries)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("imports PoBB profile URLs through the provider's raw profile export route", function()
		local tree = build.spec.tree
		local witchId = assert(tree.classNameMap.Witch)
		build.spec:SelectClass(witchId)
		local elementalistId
		for id, ascendancy in pairs(build.spec.curClass.classes) do
			if ascendancy.name == "Elementalist" then elementalistId = id break end
		end
		assert.is_truthy(elementalistId, "PoB's 3.29 tree must expose Witch/Elementalist")
		build.spec:SelectAscendClass(elementalistId)
		local code = encodedBuild()
		local requestedURL
		launch.DownloadPage = function(_, url, callback)
			requestedURL = url
			callback({ body = code })
		end
		local activeSignature = Candidate.BuildSignature(build)
		local originalCompareCount = #build.compareTab.compareEntries
		local profileURL = "https://pobb.in/u/cappenkek%232501/YR2YJ1dd29ls"
		local started, startError = MCPBridge:CallLocal("import_build_url", { url = profileURL })
		assert.is_nil(startError)
		assert.are.equal("complete", started.status, started.error or "profile import did not complete")
		assert.are.equal("pobb.in", started.provider)
		assert.are.equal("https://pobb.in/pob/cappenkek%232501:YR2YJ1dd29ls", requestedURL)
		assert.is_truthy(started.studyId)
		assert.are.equal(originalCompareCount + 1, #build.compareTab.compareEntries)
		assert.are.equal(activeSignature, Candidate.BuildSignature(build))

		local snapshot = assert(MCPBridge:CallLocal("get_study_build_snapshot", { studyId = started.studyId }))
		assert.is_false(snapshot.isActiveBuild)
		assert.is_table(snapshot.exactMetrics)
		assert.are.equal("Witch", snapshot.class.class)
		assert.are.equal("Elementalist", snapshot.class.ascendancy)
		assert.are.equal("3_29", snapshot.treeVersion)

		local removed = assert(MCPBridge:CallLocal("remove_study_build", { studyId = started.studyId }))
		assert.is_true(removed.removed)
		assert.are.equal(originalCompareCount, #build.compareTab.compareEntries)
		assert.are.equal(activeSignature, Candidate.BuildSignature(build))
	end)

	it("rejects malformed PoBB profile paths before making a network request", function()
		local requests = 0
		launch.DownloadPage = function()
			requests = requests + 1
		end
		local started = assert(MCPBridge:CallLocal("import_build_url", {
			url = "https://pobb.in/u/cappenkek%232501/YR2YJ1dd29ls?redirect=elsewhere",
		}))
		assert.are.equal("failed", started.status)
		assert.is_truthy(started.error and started.error:find("Invalid PoBB profile build URL", 1, true))
		assert.are.equal(0, requests)
		assert.are.equal(0, #build.compareTab.compareEntries)
	end)

	it("rejects control characters in optional imported league claims", function()
		local requests = 0
		launch.DownloadPage = function()
			requests = requests + 1
		end
		local started, failure = MCPBridge:CallLocal("import_build_url", {
			url = "https://pobb.in/study-fixture", league = "Affliction\nprivate marker",
		})
		assert.is_nil(started)
		assert.is_truthy(failure and failure:find("league must be plain text", 1, true))
		assert.are.equal(0, requests)
		assert.are.equal(0, #build.compareTab.compareEntries)
	end)

	it("reads user-imported native comparison builds by opaque ID without changing either selection", function()
		local xmlText = build:SaveDB("local comparison fixture")
		assert.is_truthy(xmlText and #xmlText > 0)
		local compareTab = build.compareTab
		assert.is_true(compareTab:ImportBuild(xmlText, "Local fixture build"))
		local entry = compareTab.compareEntries[1]
		local signature = Candidate.BuildSignature(build)
		local compareSelection = compareTab.activeCompareIndex

		local listed = assert(MCPBridge:CallLocal("list_comparison_builds", { }))
		assert.is_true(listed.activeBuildPreserved)
		assert.are.equal(1, listed.count)
		assert.are.equal(1, #listed.entries)
		local summary = listed.entries[1]
		assert.is_truthy(summary.comparisonId)
		assert.are.equal("Local fixture build", summary.label)
		assert.are.equal(entry.characterLevel, summary.characterLevel)
		assert.are.equal(Version.Data(entry), summary.dataVersion)
		assert.are.equal(entry.spec.treeVersion, summary.treeVersion)
		assert.are.equal(entry.calcsTab.mainOutput.TotalEHP, summary.exactMetrics.TotalEHP)
		assert.are.equal(compareSelection, compareTab.activeCompareIndex)
		assert.are.equal(signature, Candidate.BuildSignature(build))

		local snapshot = assert(MCPBridge:CallLocal("get_comparison_build_snapshot", { comparisonId = summary.comparisonId }))
		assert.is_false(snapshot.isActiveBuild)
		assert.are.equal(summary.comparisonId, snapshot.comparison.id)
		assert.are.equal("Local fixture build", snapshot.comparison.label)
		assert.are.equal(1, snapshot.comparison.index)
		assert.are.equal(entry.calcsTab.mainOutput.TotalEHP, snapshot.exactMetrics.TotalEHP)
		assert.are.equal(compareSelection, compareTab.activeCompareIndex)
		assert.are.equal(signature, Candidate.BuildSignature(build))

		compareTab:RemoveBuild(1)
		local stale, staleError = MCPBridge:CallLocal("get_comparison_build_snapshot", { comparisonId = summary.comparisonId })
		assert.is_nil(stale)
		assert.is_truthy(staleError and staleError:find("removed", 1, true))
		local empty = assert(MCPBridge:CallLocal("list_comparison_builds", { }))
		assert.are.equal(0, empty.count)
		assert.are.equal(0, #empty.entries)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("runs exact passive, gem, item, and mastery A/B experiments against a native comparison build", function()
		build.characterLevel = 68
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		local baseAmulet = new("Item"):Item("Rarity: Rare\nOptimizer Record Base\nAmber Amulet\n--------\n+30 to maximum Life\n+20% to Fire Resistance")
		local replacementAmulet = new("Item"):Item("Rarity: Rare\nOptimizer Record Candidate\nAmber Amulet\n--------\n+50 to maximum Life\n+35% to Fire Resistance")
		build.itemsTab:AddItem(baseAmulet, true)
		build.itemsTab:AddItem(replacementAmulet, true)
		build.itemsTab.slots.Amulet:SetSelItemId(baseAmulet.id)
		build.itemsTab:PopulateSlots()
		local allocatedMasteryNode, selectedMasteryEffectId
		for _, candidateNode in pairs(build.spec.nodes) do
			if candidateNode.type == "Mastery" and candidateNode.path then
				local supportedEffects = { }
				for _, option in ipairs(candidateNode.masteryEffects or { }) do
					if build.spec.tree.masteryEffects[option.effect] then
						supportedEffects[#supportedEffects + 1] = option.effect
					end
				end
				if #supportedEffects >= 2 then
					allocatedMasteryNode, selectedMasteryEffectId = candidateNode, supportedEffects[1]
				end
			end
			if allocatedMasteryNode then break end
		end
		assert.is_truthy(allocatedMasteryNode, "fixture must expose a native mastery node with a supported effect")
		build.spec:AllocNode(allocatedMasteryNode)
		build.spec.masterySelections[allocatedMasteryNode.id] = selectedMasteryEffectId
		build.spec:BuildAllDependsAndPaths()
		build.calcsTab:BuildOutput()
		local compareTab = build.compareTab
		assert.is_true(compareTab:ImportBuild(build:SaveDB("comparison experiment fixture"), "Experiment fixture"))
		local originalSelection = compareTab.activeCompareIndex
		local entry = compareTab.compareEntries[1]
		local listed = assert(MCPBridge:CallLocal("list_comparison_builds", { }))
		local comparisonId = listed.entries[1].comparisonId
		local comparedSnapshot = assert(MCPBridge:CallLocal("get_comparison_build_snapshot", { comparisonId = comparisonId }))
		local activities = comparedSnapshot.activitySustain and comparedSnapshot.activitySustain.activities or { }
		local activity = activities[1]
		assert.is_truthy(activity and activity.identity, "fixture must expose a native PoB activity identity")
		local activityResult = assert(MCPBridge:CallLocal("evaluate_activity_schedule", {
			scope = "main_skill", activities = { { identity = activity.identity, mode = "continuous" } }, comparisonId = comparisonId,
		}))
		assert.is_false(activityResult.isActiveBuild)
		assert.is_true(activityResult.activeBuildPreserved)
		assert.are.equal("native_comparison_build", activityResult.buildReference.type)
		local activeSignature = Candidate.BuildSignature(build)
		local entrySignature = Candidate.BuildSignature(entry)
		local appendCalls = { }
		local forceDuplicate = false
		StudyRecords.Append = function(record)
			appendCalls[#appendCalls + 1] = record
			if forceDuplicate then
				return { recordId = "fixture-record-1", storeFile = "fixture", duplicate = true }
			end
			return { recordId = "fixture-record-" .. tostring(#appendCalls), storeFile = "fixture", duplicate = false }
		end

		local addNodeId
		for allocatedId in pairs(entry.spec.allocNodes or { }) do
			local allocatedNode = entry.spec.nodes[allocatedId]
			for _, neighbor in ipairs(allocatedNode and allocatedNode.linked or { }) do
				local node = entry.spec.nodes[neighbor.id]
				if node and not entry.spec.allocNodes[node.id] and node.type ~= "Mastery" and node.type ~= "Socket"
					and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not node.isProxy
					and not node.isMultipleChoiceOption and not node.isTattoo then
					addNodeId = node.id
					break
				end
			end
			if addNodeId then break end
		end
		assert.is_truthy(addNodeId, "fixture must expose a legal adjacent passive node")
		local node = assert(MCPBridge:CallLocal("get_passive_node", { nodeId = addNodeId, comparisonId = comparisonId }))
		assert.is_false(node.isActiveBuild)
		assert.is_table(node.neighbors)
		local query = tostring(node.name):sub(1, 2)
		local search = assert(MCPBridge:CallLocal("search_passive_nodes", { query = query, comparisonId = comparisonId }))
		assert.is_false(search.isActiveBuild)
		assert.is_true(search.totalMatches > 0)

		local passive = assert(MCPBridge:CallLocal("evaluate_passive_delta", {
			addNodeIds = { addNodeId }, removeNodeIds = { }, comparisonId = comparisonId,
		}))
		assert.is_false(passive.isActiveBuild)
		assert.is_true(passive.activeBuildPreserved)
		assert.are.equal("native_comparison_build", passive.buildReference.type)
		assert.is_table(passive.metricDelta)
		local recordedPassive = assert(MCPBridge:CallLocal("record_passive_experiment", {
			addNodeIds = { addNodeId }, removeNodeIds = { }, comparisonId = comparisonId,
		}))
		assert.is_true(recordedPassive.recorded)
		assert.is_false(recordedPassive.duplicate)
		assert.are.equal("native_comparison_build", appendCalls[1].source.type)
		assert.are.equal(comparisonId, appendCalls[1].source.comparisonId)
		forceDuplicate = true
		local duplicatePassive = assert(MCPBridge:CallLocal("record_passive_experiment", {
			addNodeIds = { addNodeId }, removeNodeIds = { }, comparisonId = comparisonId,
		}))
		assert.is_false(duplicatePassive.recorded)
		assert.is_true(duplicatePassive.duplicate)
		assert.are.equal("fixture-record-1", duplicatePassive.recordId)
		forceDuplicate = false

		local group = entry.skillsTab.socketGroupList[1]
		local gemIndex, gem
		for index, candidateGem in ipairs(group and group.gemList or { }) do
			if candidateGem.gemId then gemIndex, gem = index, candidateGem break end
		end
		assert.is_truthy(gemIndex, "fixture must have an enabled gem to compare")
		local quality = tonumber(gem.quality) or 0
		local nextQuality = quality < 23 and quality + 1 or quality - 1
		local gemResult = assert(MCPBridge:CallLocal("evaluate_gem_swap", {
			groupIndex = 1, gemIndex = gemIndex, gemId = gem.gemId,
			level = tonumber(gem.level) or 1, quality = nextQuality, comparisonId = comparisonId,
		}))
		assert.is_false(gemResult.isActiveBuild)
		assert.is_true(gemResult.activeBuildPreserved)
		assert.are.equal("native_comparison_build", gemResult.buildReference.type)
		local recordedGem = assert(MCPBridge:CallLocal("record_gem_experiment", {
			groupIndex = 1, gemIndex = gemIndex, quality = nextQuality, comparisonId = comparisonId,
		}))
		assert.is_true(recordedGem.recorded)
		assert.is_false(recordedGem.duplicate)
		assert.are.equal("native_comparison_build", appendCalls[3].source.type)
		assert.are.equal(comparisonId, appendCalls[3].source.comparisonId)
		local noOpItem, noOpError = MCPBridge:CallLocal("record_item_experiment", {
			slot = "Amulet", itemId = baseAmulet.id, comparisonId = comparisonId,
		})
		assert.is_nil(noOpItem)
		assert.is_truthy(noOpError and noOpError:find("already equipped", 1, true))
		local invalidItemLabel, invalidItemLabelError = MCPBridge:CallLocal("record_item_experiment", {
			slot = "Amulet", itemId = replacementAmulet.id, comparisonId = comparisonId, label = string.rep("x", 121),
		})
		assert.is_nil(invalidItemLabel)
		assert.is_truthy(invalidItemLabelError and invalidItemLabelError:find("plain text", 1, true))
		local itemResult = assert(MCPBridge:CallLocal("record_item_experiment", {
			slot = "Amulet", itemId = replacementAmulet.id, comparisonId = comparisonId,
		}))
		assert.is_false(itemResult.isActiveBuild)
		assert.is_true(itemResult.activeBuildPreserved)
		assert.is_true(itemResult.recorded)
		assert.is_false(itemResult.duplicate)
		assert.are.equal("native_comparison_build", itemResult.buildReference.type)
		assert.are.equal(baseAmulet:BuildRaw(), appendCalls[4].experiment.before.poBItemText)
		assert.are.equal(replacementAmulet:BuildRaw(), appendCalls[4].experiment.after.poBItemText)
		assert.are.equal(comparisonId, appendCalls[4].source.comparisonId)
		forceDuplicate = true
		local duplicateItem = assert(MCPBridge:CallLocal("record_item_experiment", {
			slot = "Amulet", itemId = replacementAmulet.id, comparisonId = comparisonId,
		}))
		assert.is_false(duplicateItem.recorded)
		assert.is_true(duplicateItem.duplicate)
		assert.are.equal("fixture-record-1", duplicateItem.recordId)
		forceDuplicate = false

		local masteryNodeId, beforeEffectId, afterEffectId
		for selectedNodeId, selectedEffectId in pairs(entry.spec.masterySelections or { }) do
			local masteryNode = entry.spec.nodes[selectedNodeId]
			for _, option in ipairs(masteryNode and masteryNode.masteryEffects or { }) do
				if option.effect ~= selectedEffectId and entry.spec.tree.masteryEffects[option.effect] then
					masteryNodeId, beforeEffectId, afterEffectId = selectedNodeId, selectedEffectId, option.effect
					break
				end
			end
			if masteryNodeId then break end
		end
		assert.is_truthy(masteryNodeId, "fixture must expose an alternate native effect on its allocated mastery")
		local noOpMastery, noOpMasteryError = MCPBridge:CallLocal("record_mastery_experiment", {
			masteryNodeId = masteryNodeId, effectId = beforeEffectId, comparisonId = comparisonId,
		})
		assert.is_nil(noOpMastery)
		assert.is_truthy(noOpMasteryError and noOpMasteryError:find("already selected", 1, true))
		local invalidMastery, invalidMasteryError = MCPBridge:CallLocal("record_mastery_experiment", {
			masteryNodeId = masteryNodeId, effectId = 2147483647, comparisonId = comparisonId,
		})
		assert.is_nil(invalidMastery)
		assert.is_truthy(invalidMasteryError and invalidMasteryError:find("not an option", 1, true))
		local invalidMasteryLabel, invalidMasteryLabelError = MCPBridge:CallLocal("record_mastery_experiment", {
			masteryNodeId = masteryNodeId, effectId = afterEffectId, comparisonId = comparisonId, label = string.rep("x", 121),
		})
		assert.is_nil(invalidMasteryLabel)
		assert.is_truthy(invalidMasteryLabelError and invalidMasteryLabelError:find("plain text", 1, true))
		local masteryResult = assert(MCPBridge:CallLocal("record_mastery_experiment", {
			masteryNodeId = masteryNodeId, effectId = afterEffectId, comparisonId = comparisonId,
		}))
		assert.is_false(masteryResult.isActiveBuild)
		assert.is_true(masteryResult.activeBuildPreserved)
		assert.is_true(masteryResult.recorded)
		assert.is_false(masteryResult.duplicate)
		assert.are.equal("native_comparison_build", masteryResult.buildReference.type)
		assert.are.equal(beforeEffectId, masteryResult.beforeEffectId)
		assert.are.equal(afterEffectId, masteryResult.afterEffectId)
		assert.are.equal("one_mastery_effect", appendCalls[6].experiment.unit)
		assert.are.equal(masteryNodeId, appendCalls[6].experiment.masteryNodeId)
		assert.are.equal(beforeEffectId, appendCalls[6].experiment.before.effectId)
		assert.are.equal(afterEffectId, appendCalls[6].experiment.after.effectId)
		assert.is_false(appendCalls[6].admission.trainingEligible)
		assert.are.equal(comparisonId, appendCalls[6].source.comparisonId)
		forceDuplicate = true
		local duplicateMastery = assert(MCPBridge:CallLocal("record_mastery_experiment", {
			masteryNodeId = masteryNodeId, effectId = afterEffectId, comparisonId = comparisonId,
		}))
		assert.is_false(duplicateMastery.recorded)
		assert.is_true(duplicateMastery.duplicate)
		assert.are.equal("fixture-record-1", duplicateMastery.recordId)
		forceDuplicate = false

		local itemSet = entry.itemsTab.activeItemSet or entry.itemsTab.itemSets[entry.itemsTab.activeItemSetId]
		local slotName
		for name, slot in pairs(itemSet or { }) do
			if type(name) == "string" and type(slot) == "table" then slotName = name break end
		end
		assert.is_truthy(slotName, "fixture must have a native equipment slot")
		local itemSwap = assert(MCPBridge:CallLocal("evaluate_item_swap", { slot = slotName, itemId = 0, comparisonId = comparisonId }))
		assert.is_false(itemSwap.isActiveBuild)
		assert.are.equal("native_comparison_build", itemSwap.buildReference.type)
		assert.are.equal(originalSelection, compareTab.activeCompareIndex)
		assert.are.equal(activeSignature, Candidate.BuildSignature(build))
		assert.are.equal(entrySignature, Candidate.BuildSignature(entry))

		local conflict, conflictError = MCPBridge:CallLocal("get_passive_node", {
			nodeId = addNodeId, studyId = "fixture", comparisonId = comparisonId,
		})
		assert.is_nil(conflict)
		assert.is_truthy(conflictError and conflictError:find("not both", 1, true))
		compareTab:RemoveBuild(1)
		local stale, staleError = MCPBridge:CallLocal("evaluate_passive_delta", {
			addNodeIds = { addNodeId }, removeNodeIds = { }, comparisonId = comparisonId,
		})
		assert.is_nil(stale)
		assert.is_truthy(staleError and staleError:find("removed", 1, true))
	end)

	it("invalidates native comparison IDs when the active PoB build is replaced", function()
		local xmlText = build:SaveDB("stale comparison fixture")
		assert.is_true(build.compareTab:ImportBuild(xmlText, "Stale fixture"))
		local listed = assert(MCPBridge:CallLocal("list_comparison_builds", { }))
		local comparisonId = listed.entries[1].comparisonId
		assert.is_truthy(comparisonId)

		newBuild()
		local stale, staleError = MCPBridge:CallLocal("get_comparison_build_snapshot", { comparisonId = comparisonId })
		assert.is_nil(stale)
		assert.is_truthy(staleError and staleError:find("different active build", 1, true))
		local current = assert(MCPBridge:CallLocal("list_comparison_builds", { }))
		assert.are.equal(0, current.count)
	end)

	it("rejects URLs outside the exact HTTPS hosts accepted by PoB", function()
		for _, url in ipairs({
			"http://pobb.in/studyfixture",
			"https://pobb.in.evil.example/studyfixture",
			"https://user@pobb.in/studyfixture",
			"https://pobb.in:443/studyfixture",
			"https://unknown.example/studyfixture",
		}) do
			local result, err = MCPBridge:CallLocal("import_build_url", { url = url })
			assert.is_nil(result)
			assert.is_truthy(err)
		end
		assert.are.equal(0, #build.compareTab.compareEntries)
	end)

	it("recognizes supported build hosts and rejects third-party PoE Ninja build endpoints", function()
		buildSites.DownloadBuild = function(_, _, callback)
			callback(false, "offline fixture")
		end
		local sources = {
			{ "https://maxroll.gg/poe/pob/study-fixture", "Maxroll" },
			{ "https://pob.codes/b/study-fixture", "pob.codes" },
			{ "https://pobb.in/studyfixture", "pobb.in" },
			{ "https://pastebin.com/StudyFixture", "Pastebin.com" },
			{ "https://pastebinp.com/StudyFixture", "PastebinP.com" },
			{ "https://rentry.co/StudyFixture", "Rentry.co" },
			{ "https://poedb.tw/pob/studyfixture", "poedb.tw" },
		}
		for _, source in ipairs(sources) do
			local started = assert(MCPBridge:CallLocal("import_build_url", { url = source[1] }))
			assert.are.equal(source[2], started.provider, source[1])
			assert.are.equal("failed", started.status)
		end
		local ninjaRequestCount = 0
		buildSites.DownloadBuild = function() ninjaRequestCount = ninjaRequestCount + 1 end
		local rejected, rejectError = MCPBridge:CallLocal("import_build_url", { url = "https://poe.ninja/poe1/pob/StudyFixture" })
		assert.is_nil(rejected)
		assert.is_truthy(rejectError and rejectError:find("not available for third-party use", 1, true))
		assert.are.equal(0, ninjaRequestCount)
		assert.are.equal(0, #build.compareTab.compareEntries)
	end)

	it("rejects provider redirects in optimizer study download mode", function()
		local provider
		for _, site in ipairs(buildSites.websiteList) do
			if site.id == "POBBin" then provider = site break end
		end
		assert.is_truthy(provider)
		local requestOptions
		local result
		launch.DownloadPage = function(_, url, callback, options)
			requestOptions = options
			callback({
				header = "HTTP/1.1 302 Found\r\nLocation: https://poe.ninja/poe1/pob/raw/StudyFixture\r\n",
				body = "",
			}, "Response code: 302")
			return 1
		end
		buildSites.DownloadBuild("https://pobb.in/study-fixture", provider, function(isSuccess, data, resolvedUrl, reason)
			result = { isSuccess = isSuccess, data = data, resolvedUrl = resolvedUrl, reason = reason }
		end, { followRedirects = false })

		assert.is_false(requestOptions.followRedirects)
		assert.is_false(result.isSuccess)
		assert.are.equal("redirect_disallowed", result.reason)
		assert.is_truthy(result.data:find("do not follow redirects", 1, true))
		assert.are.equal("https://pobb.in/pob/study-fixture", result.resolvedUrl)
	end)

	it("sets redirect refusal on MCP study imports without changing native imports", function()
		local requestOptions
		buildSites.DownloadBuild = function(_, _, callback, options)
			requestOptions = options
			callback(false, "Optimizer study imports do not follow redirects; use the provider's canonical PoB URL or a local PoB export", nil, "redirect_disallowed")
		end
		local started = assert(MCPBridge:CallLocal("import_build_url", { url = "https://pobb.in/study-fixture" }))

		assert.is_false(requestOptions.followRedirects)
		assert.are.equal("failed", started.status)
		assert.is_truthy(started.error:find("do not follow redirects", 1, true))
	end)

	it("fails a delayed import if the live build changes while it downloads", function()
		local code = encodedBuild()
		local pendingCallback
		buildSites.DownloadBuild = function(_, _, callback)
			pendingCallback = callback
		end
		local originalLevel = build.characterLevel
		local originalCount = #build.compareTab.compareEntries
		local started = assert(MCPBridge:CallLocal("import_build_url", { url = "https://pobb.in/studyfixture" }))
		assert.are.equal("running", started.status)

		build.characterLevel = originalLevel == 99 and 98 or originalLevel + 1
		pendingCallback(true, code, "https://pobb.in/pob/studyfixture")
		local status = assert(MCPBridge:CallLocal("import_build_status", { jobId = started.jobId }))
		assert.are.equal("failed", status.status)
		assert.is_truthy(status.error and status.error:find("active PoB build was edited", 1, true), status.error or "expected build-signature guard error")
		assert.are.equal(originalCount, #build.compareTab.compareEntries)
		build.characterLevel = originalLevel
	end)

	it("surfaces native downloader failures as failed import jobs", function()
		buildSites.DownloadBuild = function(_, _, callback)
			callback(false, "fixture returned 404")
		end
		local started = assert(MCPBridge:CallLocal("import_build_url", { url = "https://pobb.in/missingfixture" }))
		assert.are.equal("failed", started.status)
		assert.is_truthy(started.error:find("404", 1, true))
	end)
end)
