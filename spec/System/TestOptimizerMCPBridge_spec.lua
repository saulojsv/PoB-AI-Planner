local Candidate = require("Modules.Optimizer.Candidate")
local MCPBridge = require("Modules.Optimizer.MCPBridge")
local CatalogCoverage = require("Modules.Optimizer.CatalogCoverage")
local StudyRecords = require("Modules.Optimizer.StudyRecords")
local RelationGraph = require("Modules.Optimizer.RelationGraph")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local StudyContext = require("Modules.Optimizer.StudyContext")
local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local json = require("dkjson")
local TestSupport = require("OptimizerTestSupport")

describe("Optimizer local MCP bridge endpoint lifecycle", function()
	it("advertises versioned passive/support factorial capabilities in ping", function()
		newBuild()
		local ping = assert(MCPBridge:CallLocal("ping", { }))
		assert.is_true(ping.connected)
		assert.are.equal(1, ping.operationCapabilities.contractVersion)
		assert.is_true(ping.operationCapabilities.passiveSupportFactorial.start)
		assert.is_true(ping.operationCapabilities.passiveSupportFactorial.status)
		assert.is_true(ping.operationCapabilities.passiveSupportFactorial.cancel)
		assert.is_true(ping.operationCapabilities.skillSkillFactorial.start)
		assert.is_true(ping.operationCapabilities.skillSkillFactorial.status)
		assert.is_true(ping.operationCapabilities.skillSkillFactorial.cancel)
	end)

	it("publishes and cleans up an endpoint unique to its listener", function()
		assert.is_nil(MCPBridge.listener, "HeadlessWrapper must not leave a desktop bridge running")
		local started, startError = MCPBridge:Start()
		assert.is_true(started, startError)

		local endpointPath, healthPath = MCPBridge.endpointPath, MCPBridge.healthPath
		local ok, err = pcall(function()
			assert.is_true(MCPBridge.port >= 1 and MCPBridge.port <= 65535)
			assert.are.equal("pob-" .. tostring(MCPBridge.port) .. "-", MCPBridge.instanceId:sub(1, #("pob-" .. tostring(MCPBridge.port) .. "-")))
			assert.are.equal("pob-optimizer-mcp-instance-" .. tostring(MCPBridge.port) .. ".json", endpointPath:match("[^/\\]+$"))
			assert.is_false(endpointPath:find("pob-optimizer-mcp.json", 1, true) ~= nil, "the bridge must not claim the legacy shared endpoint")

			local endpointFile = assert(io.open(endpointPath, "rb"))
			local endpoint, decodeError = json.decode(endpointFile:read("*a"))
			endpointFile:close()
			assert.is_truthy(endpoint, decodeError)
			assert.are.equal(MCPBridge.port, endpoint.port)
			assert.are.equal(MCPBridge.instanceId, endpoint.instanceId)
			assert.is_truthy(type(endpoint.token) == "string" and #endpoint.token >= 32)
			assert.are.equal("published", MCPBridge:GetEndpointStatus().status)

			os.remove(endpointPath)
			assert.are.equal("missing", MCPBridge:GetEndpointStatus().status)
			local unavailableHealth = MCPBridge:GetConnectionHealth()
			assert.are.equal("missing", unavailableHealth.companionEndpointStatus)
			local qaStart, qaError = MCPBridge:CallLocal("qa_start", { suite = "integration" })
			assert.is_truthy(qaStart, qaError)
			MCPBridge:StepQASuites()
			local qaResult = assert(MCPBridge:CallLocal("qa_status", { jobId = qaStart.jobId }))
			assert.are.equal("failed", qaResult.status)
			assert.are.equal("Authenticated loopback MCP listener and companion endpoint", qaResult.checks[1].name)
			assert.are.equal("fail", qaResult.checks[1].status)

			MCPBridge.nextEndpointPublishCheck = 0
			MCPBridge:Poll()
			assert.are.equal("published", MCPBridge:GetEndpointStatus().status, "the live UI loop must republish a missing companion endpoint")

			MCPBridge:FrameComplete()
			local recoveredHealth = MCPBridge:GetConnectionHealth()
			assert.are.equal("fresh", recoveredHealth.status)
			assert.are.equal("published", recoveredHealth.companionEndpointStatus)
			local healthFile = assert(io.open(healthPath, "rb"))
			local heartbeat = assert(json.decode(healthFile:read("*a")))
			healthFile:close()
			assert.are.equal(MCPBridge.port, heartbeat.port)
			assert.are.equal(MCPBridge.instanceId, heartbeat.instanceId)
		end)

		MCPBridge:Stop()
		assert.is_true(ok, tostring(err))
		assert.is_nil(io.open(endpointPath, "rb"), "the bridge must remove only its own endpoint on stop")
		assert.is_nil(io.open(healthPath, "rb"), "the bridge must remove its own heartbeat on stop")
	end)

	it("returns privacy-safe learning coverage through the typed study-list MCP method", function()
		newBuild()
		local oldUserPath = main.userPath
		local isolatedPath = os.tmpname()
		os.remove(isolatedPath)
		main.userPath = isolatedPath
		local ok, resultOrError = pcall(function()
			local result, listError = MCPBridge:CallLocal("list_study_records", { limit = 25 })
			assert.is_truthy(result, listError)
			assert.are.equal("no_exact_pairs", result.learningCoverage.status)
			assert.are.equal("not_measured", result.learningCoverage.combinationCoverage)
			assert.are.equal("report_only", result.learningCoverage.graphRole)
			assert.is_false(result.learningCoverage.modelTrainingEnabled)
			assert.are.equal(0, result.learningCoverage.contextDiversity.sourceBuildStatesObserved)
			assert.is_true(#assert(json.encode(result.learningCoverage)) < 4096)
			local storePath = assert(StudyRecords.GetStorePath(isolatedPath))
			assert.is_nil(io.open(storePath, "rb"), "listing coverage must not create a study store")
		end)
		main.userPath = oldUserPath
		assert.is_true(ok, tostring(resultOrError))
	end)

	it("requires explicit confirmation before study deletion or retention pruning", function()
		local oldUserPath = main.userPath
		local isolatedPath = os.tmpname()
		os.remove(isolatedPath)
		main.userPath = isolatedPath
		local ok, resultOrError = pcall(function()
			local deleted, deleteError = MCPBridge:CallLocal("delete_study_record", {
				recordId = "study-20261022T000000Z-1-1", confirm = false,
			})
			assert.is_nil(deleted)
			assert.is_truthy(deleteError:find("confirm=true is required", 1, true))
			local pruned, pruneError = MCPBridge:CallLocal("prune_study_records", {
				olderThanDays = 30, confirm = false,
			})
			assert.is_nil(pruned)
			assert.is_truthy(pruneError:find("confirm=true is required", 1, true))
			local storePath = assert(StudyRecords.GetStorePath(isolatedPath))
			assert.is_nil(io.open(storePath, "rb"), "unconfirmed cleanup must not create or rewrite the source store")
			assert.is_nil(io.open((storePath:gsub("paired%-experiments%.jsonl$", "training-artifacts-invalidated.json")), "rb"),
				"unconfirmed cleanup must not block training")
		end)
		main.userPath = oldUserPath
		assert.is_true(ok, tostring(resultOrError))
	end)

	it("creates an exact PoB skill seed through the typed MCP operation", function()
		newBuild()
		local sourceBuild = build
		local sourceSetId = sourceBuild.skillsTab.activeSkillSetId
		local sourceClassId = sourceBuild.spec.curClassId
		local baseClassId
		for classId, class in pairs(sourceBuild.spec.tree.classes) do
			if class.name == "Witch" then baseClassId = classId break end
		end
		assert.is_truthy(baseClassId)
		assert.are_not.equal(sourceClassId, baseClassId)
		local created, createError = MCPBridge:CallLocal("create_optimizer_skill_seed", {
			gemId = "Metadata/Items/Gems/SkillGemFireball",
			baseClassId = baseClassId,
		})
		assert.is_truthy(created, createError)
		assert.is_true(created.created)
		assert.is_false(created.linked)
		assert.are.equal(baseClassId, created.baseClassId)
		assert.are.equal(sourceClassId, sourceBuild.spec.curClassId,
			"selecting a class for the planner must not change the active source tree")
		assert.are_not.equal(sourceSetId, sourceBuild.skillsTab.activeSkillSetId)
		assert.are.equal("Metadata/Items/Gems/SkillGemFireball",
			sourceBuild.skillsTab.socketGroupList[created.groupIndex].displaySkillList[created.skillIndex].activeEffect.srcInstance.gemData.id)
		assert.are.equal(tostring(baseClassId), sourceBuild.optimizerTab.textValues.baseClassId)
		assert.are.equal("tree", sourceBuild.optimizerTab.textValues.generationPhase)

		local beforeInvalidCall = sourceBuild.skillsTab.activeSkillSetId
		local rejected, rejectError = MCPBridge:CallLocal("create_optimizer_skill_seed", { gemId = "not-a-loaded-gem" })
		assert.is_nil(rejected)
		assert.is_truthy(rejectError)
		assert.are.equal(beforeInvalidCall, sourceBuild.skillsTab.activeSkillSetId,
			"an invalid MCP gem ID must not mutate the native skill set")

		sourceBuild.skillsTab:Undo()
		assert.are.equal(sourceSetId, sourceBuild.skillsTab.activeSkillSetId)
		newBuild()
	end)

	it("does not inherit omitted MCP optimizer fields from the saved UI Matrix", function()
		newBuild()
		local sourceBuild = build
		sourceBuild.spec:SelectClass(assert(sourceBuild.spec.tree.classNameMap.Witch))
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.skillsTab.socketGroupList[1].mainActiveSkill = 1
		sourceBuild.calcsTab:BuildOutput()
		local tab = sourceBuild.optimizerTab
		tab.textValues.conversionRoute = "Physical>Cold"
		tab.textValues.conversionMin = "100"
		tab.textValues.Life = "999999"
		tab.textValues.targetSkillGroupIndex = "9"
		tab.textValues.targetSkillIndex = "1"
		tab.textValues.targetSkillGemId = "Metadata/Items/Gems/SkillGemArc"
		tab.textValues.searchSyntheticGear = "true"
		tab.textValues.generationPhase = "tree"

		local originalRun = PhantomSim.RunPhantomSim
		local capturedParsed
		PhantomSim.RunPhantomSim = function(_, parsed)
			capturedParsed = parsed
			return { status = "running", progress = 0, Cancel = function(self) self.status = "cancelled" end }
		end
		local started, startError
		local ok, testError = pcall(function()
			started, startError = MCPBridge:CallLocal("optimizer_start", {
				matrix = { objectiveMetric = "CombinedDPS", evaluationBudget = 1 },
			})
			assert.is_truthy(started, startError)
			assert.is_truthy(capturedParsed)
			assert.are.equal(0, #capturedParsed.conversion.route, "an omitted MCP route must not become a hard conversion gate")
			assert.is_nil(capturedParsed.hard.Life, "an omitted hard floor must not leak from the UI Matrix")
			assert.is_nil(capturedParsed.search.targetSkillGroupIndex, "an omitted target must use the current native Main Skill")
			assert.is_nil(capturedParsed.search.targetSkillGemId)
			assert.is_false(capturedParsed.search.searchSyntheticGear, "an omitted generation option must use its API default")
			assert.are.equal("combined", capturedParsed.search.generationPhase, "sparse MCP calls use the documented mixed-search default")
			assert.are.equal("ObjectiveFirst", capturedParsed.preferences.rankingPriority, "sparse MCP calls use the legacy exact objective-first ranking default")
			assert.are.equal("", tab.textValues.conversionRoute, "the visible Matrix should match the MCP request that started the job")
		end)
		PhantomSim.RunPhantomSim = originalRun
		if started and started.jobId then
			MCPBridge.jobs[started.jobId] = nil
			if MCPBridge.activeJobId == started.jobId then MCPBridge.activeJobId = nil end
		end
		assert.is_true(ok, tostring(testError or startError))
	end)

	it("uses typed imported-route memory only as a bounded ordering prior and reports counts", function()
		newBuild()
		local sourceBuild = build
		sourceBuild.spec:SelectClass(assert(sourceBuild.spec.tree.classNameMap.Witch))
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.skillsTab.socketGroupList[1].mainActiveSkill = 1
		sourceBuild.calcsTab:BuildOutput()
		local nativeNodeId
		for nodeId, node in pairs(sourceBuild.spec.tree.nodes) do
			if tonumber(nodeId) and node.type ~= "ClassStart" and node.type ~= "Ascendancy" then nativeNodeId = tonumber(nodeId); break end
		end
		assert.is_truthy(nativeNodeId)
		local originalNodeEvidence, originalRun = StudyBuilds.NodeEvidence, PhantomSim.RunPhantomSim
		local capturedParsed, capturedClassId, evidenceCalls = nil, nil, 0
		StudyBuilds.NodeEvidence = function(_userPath, queriedBuild, gemId, _effectIds, _maxOutputNodes, requestedClassId)
			evidenceCalls = evidenceCalls + 1
			assert.are.equal(sourceBuild, queriedBuild)
			assert.are.equal("Metadata/Items/Gems/SkillGemFireball", gemId)
			capturedClassId = requestedClassId
			return {
				status = "ready", compatibleBuildCount = 2,
				nodes = { { nodeId = nativeNodeId } }, edges = { { from = nativeNodeId, to = nativeNodeId + 1 } },
				priorities = { [nativeNodeId] = 0.8 }, causal = false, readOnly = true,
			}
		end
		PhantomSim.RunPhantomSim = function(_, parsed)
			capturedParsed = parsed
			return { status = "running", progress = 0, Cancel = function(self) self.status = "cancelled" end }
		end
		local started, startError, routeStatus, disabledStart
		local ok, testError = pcall(function()
			started, startError = MCPBridge:CallLocal("optimizer_start", {
				matrix = {
					objectiveMetric = "CombinedDPS", evaluationBudget = 1,
					baseClassId = sourceBuild.spec.curClassId,
					targetSkillGroupIndex = 1, targetSkillIndex = 1,
					targetSkillGemId = "Metadata/Items/Gems/SkillGemFireball",
					useImportedRouteMemory = true,
				},
			})
			assert.is_truthy(started, startError)
			assert.is_true(capturedParsed.search.importedRouteMemoryEnabled)
			assert.are.equal(0.8, capturedParsed.search.nodeEvidencePriorities[nativeNodeId])
			assert.are.equal(sourceBuild.spec.curClassId, capturedClassId)
			assert.are.equal("ready", started.importedRouteMemory.status)
			assert.are.equal(2, started.importedRouteMemory.compatibleBuildCount)
			assert.are.equal(1, started.importedRouteMemory.nodeCount)
			assert.are.equal(1, started.importedRouteMemory.edgeCount)
			assert.is_true(started.importedRouteMemory.proposalOrderingOnly)
			assert.is_true(started.importedRouteMemory.readOnly)
			assert.is_nil(started.importedRouteMemory.nodes, "MCP summary must not return imported build node records")
			routeStatus = assert(MCPBridge:CallLocal("optimizer_status", { jobId = started.jobId }))
			assert.are.equal(1, routeStatus.importedRouteMemory.nodeCount)
			assert.is_nil(routeStatus.importedRouteMemory.edges)
			local singleBuildSummary = MCPBridge.importedRouteMemorySummary({ status = "single_build_only", compatibleBuildCount = 1, nodes = { }, edges = { } })
			assert.are.equal("single_build_only", singleBuildSummary.status)
			local allClassSummary = MCPBridge.importedRouteMemorySummary({ status = "disabled",
				reason = "class_specific_prior_disabled_for_all_class_comparison", compatibleBuildCount = 0, nodes = { }, edges = { } })
			assert.are.equal("disabled", allClassSummary.status)
			assert.are.equal("class_specific_prior_disabled_for_all_class_comparison", allClassSummary.reason)
			MCPBridge.jobs[started.jobId] = nil
			if MCPBridge.activeJobId == started.jobId then MCPBridge.activeJobId = nil end
			if sourceBuild.optimizerTab.job and sourceBuild.optimizerTab.job.Cancel then sourceBuild.optimizerTab.job:Cancel() end
			sourceBuild.optimizerTab.job = nil
			disabledStart = assert(MCPBridge:CallLocal("optimizer_start", {
				matrix = {
					objectiveMetric = "CombinedDPS", evaluationBudget = 1,
					baseClassId = sourceBuild.spec.curClassId,
					targetSkillGroupIndex = 1, targetSkillIndex = 1,
					targetSkillGemId = "Metadata/Items/Gems/SkillGemFireball",
					useImportedRouteMemory = false,
				},
			}))
			assert.is_false(capturedParsed.search.importedRouteMemoryEnabled)
			assert.are.equal(1, evidenceCalls, "an explicit MCP opt-out must not scan the local archive")
			assert.are.equal("disabled", disabledStart.importedRouteMemory.status)
			MCPBridge.jobs[disabledStart.jobId] = nil
			if MCPBridge.activeJobId == disabledStart.jobId then MCPBridge.activeJobId = nil end
		end)
		StudyBuilds.NodeEvidence, PhantomSim.RunPhantomSim = originalNodeEvidence, originalRun
		if started and started.jobId then
			MCPBridge.jobs[started.jobId] = nil
			if MCPBridge.activeJobId == started.jobId then MCPBridge.activeJobId = nil end
		end
		if disabledStart and disabledStart.jobId then
			MCPBridge.jobs[disabledStart.jobId] = nil
			if MCPBridge.activeJobId == disabledStart.jobId then MCPBridge.activeJobId = nil end
		end
		assert.is_true(ok, tostring(testError or startError))
		newBuild()
	end)

	it("reports loaded PoE1 skill catalog coverage without claiming exact evaluations", function()
		newBuild()
		local sourceBuild = build
		local result, err = MCPBridge:CallLocal("skill_catalog_coverage", { })
		assert.is_truthy(result, err)
		assert.is_true(result.readOnly)
		assert.are.equal("catalog_only", result.status)
		assert.is_false(result.exactEvaluated)
		assert.are.equal("Path of Exile 1", result.game)
		assert.are.equal("loaded_pob_gem_database", result.source)
		assert.is_truthy(result.dataVersion)
		assert.is_truthy(result.counts.activeGemEntries)
		assert.is_truthy(result.counts.declaredActiveSkillGemRecords)
		assert.is_truthy(result.counts.selectableActiveSkillGemRecords)
		assert.is_truthy(result.counts.excludedActiveSkillGemRecords ~= nil)
		assert.is_truthy(result.counts.activeSkillEffects)
		assert.is_truthy(result.counts.supportGemVariants)
		assert.is_truthy(result.counts.supportEffects)
		local rejected, rejectError = MCPBridge:CallLocal("skill_catalog_coverage", { url = "https://example.invalid" })
		assert.is_nil(rejected)
		assert.is_truthy(rejectError)
		local rejectedExport, exportError = MCPBridge:CallLocal("export_skill_catalog_coverage", { path = "C:\\outside-poe" })
		assert.is_nil(rejectedExport)
		assert.is_truthy(exportError)
		local originalExport = CatalogCoverage.Export
		local receivedPath, receivedBuild, receivedDirectoryCreator
		CatalogCoverage.Export = function(userPath, targetBuild, createDirectory)
			receivedPath, receivedBuild, receivedDirectoryCreator = userPath, targetBuild, createDirectory
			return { exported = true, exactEvaluated = false }
		end
		local routedExport, routedError = MCPBridge:CallLocal("export_skill_catalog_coverage", { })
		CatalogCoverage.Export = originalExport
		assert.is_truthy(routedExport, routedError)
		assert.is_true(routedExport.exported)
		assert.are.equal(main.userPath, receivedPath)
		assert.are.equal(sourceBuild, receivedBuild)
		assert.is_truthy(receivedDirectoryCreator)
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local knowledge, knowledgeError = MCPBridge:CallLocal("search_local_knowledge", {
			query = "selected Main Skill setup", knowledgeScope = "build_readiness",
		})
		assert.is_truthy(knowledge, knowledgeError)
		assert.is_true(knowledge.readOnly)
		assert.is_false(knowledge.modelUsed)
		assert.are.equal("current_matches", knowledge.status)
		assert.is_truthy(#knowledge.results > 0)
		assert.are.equal("docs/optimizer/BUILD_READINESS.md", knowledge.results[1].path)
		assert.is_truthy(knowledge.results[1].startLine >= 1)
		assert.are.equal("local_retrieval", knowledge.results[1].usageScope)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild), "local knowledge retrieval must not edit the active build")
		local rejectedKnowledge, knowledgeParamError = MCPBridge:CallLocal("search_local_knowledge", {
			query = "build", knowledgeScope = "external_guides",
		})
		assert.is_nil(rejectedKnowledge)
		assert.is_truthy(knowledgeParamError)
		local rejectedPath, knowledgePathError = MCPBridge:CallLocal("search_local_knowledge", {
			query = "build", knowledgeScope = "build_readiness", path = "C:\\outside-poe",
		})
		assert.is_nil(rejectedPath)
		assert.is_truthy(knowledgePathError)
		local noSource, noSourceError = MCPBridge:CallLocal("analyze_comparison_skill", { groupIndex = 1, skillIndex = 1 })
		assert.is_nil(noSource)
		assert.is_truthy(noSourceError)
		local bothSources, bothError = MCPBridge:CallLocal("analyze_comparison_skill", {
			studyId = "study-a", comparisonId = "comparison-a", groupIndex = 1, skillIndex = 1,
		})
		assert.is_nil(bothSources)
		assert.is_truthy(bothError)
		newBuild()
	end)

	it("exports native Main Skill breakdown and exact per-node damage-type deltas without mutation", function()
		newBuild()
		local sourceBuild = build
		sourceBuild.characterLevel = 90
		sourceBuild.characterLevelAutoMode = false
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 20/0  1\nAdded Fire Damage 20/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(sourceBuild)

		local snapshot, snapshotError = MCPBridge:CallLocal("get_build_snapshot", { })
		assert.is_truthy(snapshot, snapshotError)
		assert.are.equal(2, snapshot.supportFeatureSchemaVersion)
		local skillGroup = snapshot.skillGroups[1]
		assert.are.equal(2, skillGroup.supportProfileVersion)
		assert.is_false(skillGroup.socketValidation.valid,
			"an unlinked planning group must remain distinguishable from a playable socket group")
		local addedFireProfile
		for _, activeSkill in ipairs(skillGroup.skills) do
			for _, support in ipairs(activeSkill.supports) do
				if support.effectId == "SupportAddedFireDamage" then addedFireProfile = support end
			end
		end
		assert.is_truthy(addedFireProfile)
		assert.is_true(addedFireProfile.calculatorApplied)
		assert.is_false(addedFireProfile.playableActive)
		local breakdown = snapshot.mainSkillBreakdown
		assert.is_table(breakdown)
		assert.are.equal("exact", breakdown.status)
		assert.are.equal(snapshot.mainSkillMechanics.effect.id, breakdown.selectedEffectId)
		assert.are.equal("exact", breakdown.player.status)
		assert.are.equal("player", breakdown.player.actor)
		assert.is_true(breakdown.player.numericOutput.TotalDPS > 0)
		assert.is_true(breakdown.player.numericOutput.CritChance >= 0)
		assert.is_true(#breakdown.player.damageTypes == 5)
		local fireBucket
		for _, bucket in ipairs(breakdown.player.damageTypes) do
			if bucket.damageType == "Fire" then fireBucket = bucket break end
		end
		assert.is_truthy(fireBucket)
		assert.is_true(fireBucket.baseMin > 0)
		assert.is_true(fireBucket.hitAverage > 0)
		assert.is_true(#fireBucket.displayRows > 0)
		assert.is_truthy(breakdown.displayCaveat:find("rounded", 1, true))

		local encoded = assert(json.encode(breakdown))
		assert.is_true(#encoded < 20000, "the MCP breakdown must remain bounded and JSON-safe")

		local startNodeId = sourceBuild.spec.curClass and sourceBuild.spec.curClass.startNodeId
		local candidateNodeId
		for nodeId, node in pairs(sourceBuild.spec.nodes) do
			local connected = false
			for _, linked in ipairs(node.linked or { }) do
				if linked.id == startNodeId or sourceBuild.spec.allocNodes[linked.id] then connected = true break end
			end
			if connected and not sourceBuild.spec.allocNodes[nodeId] and node.type ~= "Mastery" and node.type ~= "Socket"
				and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not node.isProxy
				and not node.isMultipleChoiceOption and not node.isTattoo and not node.ascendancyName then
				candidateNodeId = nodeId
				break
			end
		end
		assert.is_truthy(candidateNodeId, "the native class start should have a legal passive add for the exact A/B probe")
		local delta, deltaError = MCPBridge:CallLocal("evaluate_passive_delta", { addNodeIds = { candidateNodeId } })
		assert.is_truthy(delta, deltaError)
		assert.are.equal("exact", delta.mainSkillDamageComparison.status)
		assert.are.equal("exact", delta.mainSkillDamageComparison.player.status)
		local beforeFire, afterFire, fireDelta
		for index, bucket in ipairs(delta.mainSkillDamageComparison.player.baseline.damageTypes) do
			if bucket.damageType == "Fire" then
				beforeFire = bucket
				afterFire = delta.mainSkillDamageComparison.player.candidate.damageTypes[index]
				fireDelta = delta.mainSkillDamageComparison.player.delta[index]
				break
			end
		end
		assert.is_truthy(beforeFire and afterFire and fireDelta)
		assert.is_true(type(beforeFire.hitAverage) == "number" and type(afterFire.hitAverage) == "number")
		assert.are.equal(afterFire.hitAverage - beforeFire.hitAverage, fireDelta.hitAverage)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild), "reading the breakdown must preserve the live build")
		newBuild()
	end)

	it("exact-calculates a non-main skill from an imported comparison without changing either selection", function()
		newBuild()
		local sourceBuild = build
		sourceBuild.characterLevel = 90
		sourceBuild.characterLevelAutoMode = false
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		sourceBuild.skillsTab:PasteSocketGroup("Arc 1/0  1")
		sourceBuild.mainSocketGroup = 1
		for _, group in ipairs(sourceBuild.skillsTab.socketGroupList) do group.includeInFullDPS = true end
		sourceBuild.calcsTab:BuildOutput()
		local compareTab = sourceBuild.compareTab
		assert.is_true(compareTab:ImportBuild(sourceBuild:SaveDB("comparison skill analysis fixture"), "Skill analysis fixture"))
		local compareEntry = compareTab.compareEntries[1]
		local listed = assert(MCPBridge:CallLocal("list_comparison_builds", { }))
		assert.are.equal(1, listed.count)
		local comparisonId = listed.entries[1].comparisonId
		local comparisonSkills, comparisonSkillsError = MCPBridge:CallLocal("list_active_skills", { comparisonId = comparisonId })
		assert.is_truthy(comparisonSkills, comparisonSkillsError)
		assert.is_false(comparisonSkills.isActiveBuild)
		assert.is_true(comparisonSkills.readOnly)
		assert.are.equal("native_comparison_build", comparisonSkills.buildReference.type)
		assert.are.equal(comparisonId, comparisonSkills.buildReference.comparisonId)
		assert.are.equal("Arc", comparisonSkills.skills[2].name)
		local invalidSkillSource, invalidSkillSourceError = MCPBridge:CallLocal("list_active_skills", {
			studyId = "fixture", comparisonId = comparisonId,
		})
		assert.is_nil(invalidSkillSource)
		assert.is_truthy(invalidSkillSourceError:find("either studyId or comparisonId", 1, true))
		local activeSetId = sourceBuild.skillsTab.activeSkillSetId
		local activeGroupIndex = sourceBuild.mainSocketGroup
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local comparisonSignature = Candidate.BuildSignature(compareEntry)
		local compareSelection = compareTab.activeCompareIndex
		local result, err = MCPBridge:CallLocal("analyze_comparison_skill", {
			comparisonId = comparisonId, groupIndex = 2, skillIndex = 1,
		})
		assert.is_truthy(result, err)
		assert.are.equal("exact", result.status)
		assert.is_true(result.exactCalculated)
		assert.is_true(result.readOnly)
		assert.is_false(result.isActiveBuild)
		assert.are.equal("native_comparison_build", result.buildReference.type)
		assert.are.equal("Arc", result.target.name)
		assert.is_table(result.metrics)
		assert.is_table(result.mechanics)
		assert.are.equal(activeSetId, sourceBuild.skillsTab.activeSkillSetId)
		assert.are.equal(activeGroupIndex, sourceBuild.mainSocketGroup)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild))
		assert.are.equal(comparisonSignature, Candidate.BuildSignature(compareEntry))
		assert.are.equal(compareSelection, compareTab.activeCompareIndex)
		compareTab:RemoveBuild(1)
		newBuild()
	end)

	it("records a four-cell passive interaction from isolated exact PoB calculations", function()
		newBuild()
		local sourceBuild = build
		sourceBuild.characterLevel = 90
		sourceBuild.characterLevelAutoMode = false
		sourceBuild.configTab.varControls.bandit:SetSel(1) -- Kill all bandits: +1 passive point
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.calcsTab:BuildOutput()
		local exactExtraPoints = sourceBuild.calcsTab.mainOutput.ExtraPoints
		assert.are.equal(1, exactExtraPoints, "the native Kill All bandit choice grants one exact passive point")
		local exactPointLimit = sourceBuild:GetPassivePointLimitForLevel(sourceBuild.characterLevel, exactExtraPoints)
		local targetPointCount = exactPointLimit - 2
		while sourceBuild.spec:CountAllocNodes() < targetPointCount do
			local frontier = { }
			for nodeId, node in pairs(sourceBuild.spec.nodes) do
				local directlyConnected = false
				for _, linked in ipairs(node.linked or { }) do
					if sourceBuild.spec.allocNodes[linked.id] then
						directlyConnected = true
						break
					end
				end
				if directlyConnected and not sourceBuild.spec.allocNodes[nodeId] and node.type ~= "Mastery"
					and node.type ~= "Socket" and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
					and not node.isProxy and not node.isMultipleChoiceOption and not node.isTattoo and not node.ascendancyName then
					local unallocatedPathNodes = 0
					for _, pathNode in ipairs(node.path or { }) do
						if not pathNode.alloc then unallocatedPathNodes = unallocatedPathNodes + 1 end
					end
					if unallocatedPathNodes == 1 then frontier[#frontier + 1] = node end
				end
			end
			table.sort(frontier, function(a, b) return a.id < b.id end)
			assert.is_truthy(frontier[1], "the native passive tree should expose a one-point connected path")
			local previousCount = sourceBuild.spec:CountAllocNodes()
			sourceBuild.spec:AllocNode(frontier[1])
			assert.are.equal(previousCount + 1, sourceBuild.spec:CountAllocNodes(), "fixture allocation must consume one point")
		end
		assert.are.equal(targetPointCount, sourceBuild.spec:CountAllocNodes())
		local startNodeId = sourceBuild.spec.curClass and sourceBuild.spec.curClass.startNodeId
		local candidates = { }
		for nodeId, node in pairs(sourceBuild.spec.nodes) do
			local directlyConnected = false
			for _, linked in ipairs(node.linked or { }) do
				if sourceBuild.spec.allocNodes[linked.id] or linked.id == startNodeId then
					directlyConnected = true
					break
				end
			end
			if directlyConnected and not sourceBuild.spec.allocNodes[nodeId] and node.type ~= "Mastery"
				and node.type ~= "Socket" and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
				and not node.isProxy and not node.isMultipleChoiceOption and not node.isTattoo and not node.ascendancyName then
				candidates[#candidates + 1] = nodeId
			end
		end
		table.sort(candidates)
		assert.is_true(#candidates >= 2, "the native class start should expose two direct ordinary passive candidates")
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local sourceClassId = sourceBuild.spec.curClassId
		local sourceSkillSetId = sourceBuild.skillsTab.activeSkillSetId
		local originalAppend, capturedRecord = StudyRecords.Append, nil
		StudyRecords.Append = function(record, userPath, createDirectory)
			capturedRecord = record
			record.schemaVersion = 2
			record.trainingEligible = false
			record.quarantine = { status = "pending_review", reasons = { "factorial interaction requires independent review" } }
			return { recordId = "study-factorial-contract", storeFile = "OptimizerStudies/paired-experiments.jsonl", duplicate = false }
		end
		local ok, testError = pcall(function()
			local started, startError = MCPBridge:CallLocal("record_passive_factorial_experiment", {
				factorANodeId = candidates[1], factorBNodeId = candidates[2], label = "Headless exact interaction fixture",
			})
			assert.is_truthy(started, startError)
			assert.are.equal("running", started.status)
			assert.is_true(started.readOnly)
			assert.are.equal(sourceBuild, build)
			local status
			for frame = 1, 6 do
				MCPBridge:StepFactorialJobs()
				status = assert(MCPBridge:CallLocal("record_passive_factorial_status", { jobId = started.jobId }))
				assert.are.equal(math.min(frame, 4), status.completedCells,
					"each UI-loop step may complete at most one exact factorial cell")
				if status.status == "completed" or status.status == "failed" or status.status == "stale_build" then break end
			end
			assert.are.equal("completed", status.status, status.error)
			assert.are.equal(4, status.completedCells)
			assert.is_truthy(status.result)
			assert.are.equal(exactPointLimit, status.result.cells.baseline.passivePointLimit)
			assert.are.equal(exactPointLimit, status.result.cells.combined.passivePointLimit)
			assert.are.equal(exactExtraPoints, status.result.cells.combined.extraPassivePoints)
			assert.are.equal(exactPointLimit, status.result.cells.combined.passivePointsUsed)
			assert.are.equal("exact_factorial_recorded", status.result.status)
			assert.are.equal("combined - factorA - factorB + baseline", status.result.formula)
			assert.is_true(status.result.interactionMetricCount > 0)
			for metric, values in pairs(status.result.interaction) do
				local cells = status.result.cells
				local expected = cells.combined.metrics[metric] - cells.factorA.metrics[metric]
					- cells.factorB.metrics[metric] + cells.baseline.metrics[metric]
				assert.are.equal(expected, values.interaction, "raw exact interaction for " .. metric)
			end
			assert.is_truthy(capturedRecord)
			assert.are.equal("passive_factorial_interaction", capturedRecord.kind)
			assert.is_false(capturedRecord.trainingEligible)
			assert.are.equal(candidates[1], capturedRecord.experiment.factorA.nodeId)
			assert.are.equal(candidates[2], capturedRecord.experiment.factorB.nodeId)
			assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild))
			assert.are.equal(sourceClassId, sourceBuild.spec.curClassId)
			assert.are.equal(sourceSkillSetId, sourceBuild.skillsTab.activeSkillSetId)
			local duplicateFactor, duplicateError = MCPBridge:CallLocal("record_passive_factorial_experiment", {
				factorANodeId = candidates[1], factorBNodeId = candidates[1],
			})
			assert.is_nil(duplicateFactor)
			assert.is_truthy(duplicateError)
			local injected, injectedError = MCPBridge:CallLocal("record_passive_factorial_experiment", {
				factorANodeId = candidates[1], factorBNodeId = candidates[2], path = "C:\\outside",
			})
			assert.is_nil(injected)
			assert.is_truthy(injectedError)
		end)
		StudyRecords.Append = originalAppend
		newBuild()
		assert.is_true(ok, tostring(testError))
	end)

	it("cancels a factorial study before calculating or persisting a partial record", function()
		newBuild()
		local sourceBuild = build
		local startNodeId = sourceBuild.spec.curClass and sourceBuild.spec.curClass.startNodeId
		local candidates = { }
		for nodeId, node in pairs(sourceBuild.spec.nodes) do
			local directlyConnected = false
			for _, linked in ipairs(node.linked or { }) do
				if sourceBuild.spec.allocNodes[linked.id] or linked.id == startNodeId then directlyConnected = true break end
			end
			if directlyConnected and not sourceBuild.spec.allocNodes[nodeId] and node.type ~= "Mastery"
				and node.type ~= "Socket" and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
				and not node.isProxy and not node.isMultipleChoiceOption and not node.isTattoo and not node.ascendancyName then
				candidates[#candidates + 1] = nodeId
			end
		end
		table.sort(candidates)
		assert.is_true(#candidates >= 2)
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local originalAppend, appendCount = StudyRecords.Append, 0
		StudyRecords.Append = function() appendCount = appendCount + 1; return { recordId = "unexpected" } end
		local ok, testError = pcall(function()
			local started, startError = MCPBridge:CallLocal("record_passive_factorial_experiment", {
				factorANodeId = candidates[1], factorBNodeId = candidates[2],
			})
			assert.is_truthy(started, startError)
			local cancelled, cancelError = MCPBridge:CallLocal("record_passive_factorial_cancel", { jobId = started.jobId })
			assert.is_truthy(cancelled, cancelError)
			assert.are.equal("cancelled", cancelled.status)
			MCPBridge:StepFactorialJobs()
			local status = assert(MCPBridge:CallLocal("record_passive_factorial_status", { jobId = started.jobId }))
			assert.are.equal("cancelled", status.status)
			assert.are.equal(0, appendCount)
			assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild))
		end)
		StudyRecords.Append = originalAppend
		newBuild()
		assert.is_true(ok, tostring(testError))
	end)

	it("records a four-cell skill/support interaction through isolated exact PoB builds", function()
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		local sourceBuild = build
		sourceBuild.characterLevel = 90
		sourceBuild.characterLevelAutoMode = false
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 20/0  1\nAdded Fire Damage 20/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.calcsTab:BuildOutput()
		local group = sourceBuild.skillsTab.socketGroupList[sourceBuild.mainSocketGroup]
		local selectedSkill = group.displaySkillList[group.mainActiveSkill or 1]
		local sourceSkillGemIndex
		for gemIndex, gem in ipairs(group.gemList) do
			if selectedSkill.activeEffect.srcInstance == gem then sourceSkillGemIndex = gemIndex break end
		end
		local sourceSupportGemIndex
		for gemIndex, gem in ipairs(group.gemList) do
			local effect = gem.grantedEffect or (gem.gemData and gem.gemData.grantedEffect)
			if effect and effect.support then sourceSupportGemIndex = gemIndex break end
		end
		assert.is_truthy(sourceSkillGemIndex)
		assert.is_truthy(sourceSupportGemIndex)
		local function loadedGemId(name)
			for gemId, gemData in pairs(sourceBuild.data.gems) do
				if gemData.name == name then return gemData.id or gemId end
			end
			assert.is_truthy(false, "Expected loaded PoB gem: " .. name)
		end
		local alternativeSkillId = loadedGemId("Arc")
		local alternativeSupportId = loadedGemId("Controlled Destruction")
		local alternativeSkillData = sourceBuild.data.gems[alternativeSkillId]
		local alternativeSkillEffect
		for _, effect in ipairs(alternativeSkillData.grantedEffectList or { alternativeSkillData.grantedEffect }) do
			if effect and not effect.support and not effect.unsupported then alternativeSkillEffect = effect break end
		end
		assert.is_truthy(alternativeSkillEffect)
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local studyStorePath = os.tmpname()
		os.remove(studyStorePath)
		local studyReviewPath = studyStorePath .. ".reviews.jsonl"
		local originalAppend, capturedRecord, appendCount = StudyRecords.Append, nil, 0
		StudyRecords.Append = function(record)
			local stored, storeError = StudyRecords.AppendToPath(record, studyStorePath)
			if stored then
				capturedRecord = record
				appendCount = appendCount + 1
			end
			return stored, storeError
		end
		local ok, testError = pcall(function()
			local wrongEffect, wrongEffectError = MCPBridge:CallLocal("record_skill_support_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = sourceSkillGemIndex,
				skillGemId = alternativeSkillId, skillEffectId = tostring(selectedSkill.activeEffect.grantedEffect.id),
				supportGemIndex = sourceSupportGemIndex, supportGemId = alternativeSupportId,
			})
			assert.is_nil(wrongEffect)
			assert.is_truthy(wrongEffectError:find("not an active effect granted by skillGemId", 1, true))
			local started, startError = MCPBridge:CallLocal("record_skill_support_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = sourceSkillGemIndex,
				skillGemId = alternativeSkillId, skillEffectId = tostring(alternativeSkillEffect.id),
				supportGemIndex = sourceSupportGemIndex, supportGemId = alternativeSupportId,
				label = "Fireball to Arc with controlled support",
			})
			assert.is_truthy(started, startError)
			assert.are.equal("running", started.status)
			assert.is_true(started.readOnly)
			local status
			for frame = 1, 7 do
				MCPBridge:StepFactorialJobs()
				status = assert(MCPBridge:CallLocal("record_skill_support_factorial_status", { jobId = started.jobId }))
				assert.are.equal(math.min(frame, 4), status.completedCells,
					"each UI-loop step may complete at most one exact skill/support cell")
				if status.status == "completed" or status.status == "failed" or status.status == "stale_build" then break end
			end
			assert.are.equal("completed", status.status, status.error)
			assert.are.equal(4, status.completedCells)
			assert.are.equal("exact_skill_support_factorial_recorded", status.result.status)
			assert.are.equal("unlinked_planning_group", status.result.socketStatus)
			assert.is_false(status.result.trainingEligible)
			assert.is_true(status.result.cells.baseline.selectedSkill.supportApplied)
			assert.is_true(status.result.cells.factorA.selectedSkill.supportApplied)
			assert.is_true(status.result.cells.factorB.selectedSkill.supportApplied)
			assert.is_true(status.result.cells.combined.selectedSkill.supportApplied)
			assert.is_true(status.result.interactionMetricCount > 0)
			assert.is_truthy(capturedRecord)
			for _, cellName in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
				local cell = status.result.cells[cellName]
				assert.is_true(cell.exactCalculated, cellName .. " must carry its own exact-calculation certificate")
				assert.are.equal("calcs_getMiscCalculator", cell.evaluationMethod)
				assert.are.equal(status.result.socketStatus, cell.socketStatus)
				local evidence = cell.evidenceContext
				assert.are.equal(1, evidence.schemaVersion)
				assert.are.equal("sha256", evidence.buildSignatureAlgorithm)
				assert.are.equal(1, evidence.buildSignatureVersion)
				assert.are.equal(StudyContext.BuildSignature(sourceSignature), evidence.buildSignature)
				assert.are.equal(capturedRecord.source.scenarioSignature, evidence.scenarioSignature)
				assert.are.equal(StudyContext.ScenarioSignature(capturedRecord.buildState.configuration), evidence.scenarioSignature)
				assert.are.equal(capturedRecord.engine.pobVersion, evidence.engine.pobVersion)
				assert.are.equal(capturedRecord.engine.pobBranch, evidence.engine.pobBranch)
				assert.are.equal(capturedRecord.engine.dataVersion, evidence.engine.dataVersion)
				assert.are.equal(capturedRecord.engine.treeVersion, evidence.engine.treeVersion)
				assert.are.equal(capturedRecord.engine.manifestFingerprint, evidence.engine.manifestFingerprint)
			end
			for metric, value in pairs(status.result.interaction) do
				local cells = status.result.cells
				assert.are.equal(cells.combined.metrics[metric] - cells.factorA.metrics[metric]
					- cells.factorB.metrics[metric] + cells.baseline.metrics[metric], value.interaction)
			end
			assert.are.equal("skill_support_factorial_interaction", capturedRecord.kind)
			assert.are.equal("replace_selected_main_skill_gem", capturedRecord.experiment.factorA.operation)
			assert.are.equal("replace_support_gem", capturedRecord.experiment.factorB.operation)
			assert.is_false(capturedRecord.trainingEligible)
			assert.are.equal("sha256", capturedRecord.source.buildSignatureAlgorithm)
			assert.are.equal(1, capturedRecord.source.buildSignatureVersion)
			assert.are.equal(StudyContext.BuildSignature(sourceSignature), capturedRecord.source.buildSignature)
			assert.are.equal(StudyContext.ScenarioSignature(capturedRecord.buildState.configuration), capturedRecord.source.scenarioSignature)
			assert.are.equal(capturedRecord.engine.dataVersion, capturedRecord.buildState.dataVersion)
			assert.are.equal(capturedRecord.engine.treeVersion, capturedRecord.buildState.treeVersion)
			assert.are.equal(1, appendCount)

			local persisted = assert(StudyRecords.ReadById(studyStorePath, capturedRecord.recordId,
				capturedRecord.engine.dataVersion, capturedRecord.engine.treeVersion, capturedRecord.engine.pobVersion,
				capturedRecord.engine.pobBranch, capturedRecord.engine.manifestFingerprint))
			assert.is_false(persisted.trainingEligible)
			assert.is_true(persisted.quarantined,
				"factorial records must remain quarantined even when their schema is not eligible for review")
			local graph = assert(RelationGraph.Build({ persisted }, capturedRecord.engine, 25))
			local graphFailure = graph.discarded[1] and graph.discarded[1].reason or "no graph edge returned"
			assert.are.equal(1, graph.edgeCount, graphFailure)
			assert.are.equal("main_skill_gem_x_support_gem", graph.edges[1].edgeType)
			assert.are.equal(1, graph.aggregationDiagnostics.eligibleEdgeCount,
				json.encode(graph.aggregationDiagnostics.excludedReasons))
			assert.are.equal(0, graph.aggregationDiagnostics.excludedEdgeCount)
			assert.is_false(graph.edges[1].trainingEligible)
			assert.is_false(graph.edges[1].rankingEligible)
			local coverage = assert(StudyRecords.List(studyStorePath, 25,
				capturedRecord.engine.dataVersion, capturedRecord.engine.treeVersion, capturedRecord.engine.pobVersion,
				capturedRecord.engine.pobBranch, capturedRecord.engine.manifestFingerprint))
			assert.are.equal(1, coverage.learningCoverage.experimentFamilies.skillSupportFactorialInteractions)
			assert.are.equal(1, coverage.learningCoverage.reviewRows.pending)
			assert.are.equal(0, coverage.trainingReadiness.eligibleRows)
			assert.is_false(coverage.trainingReadiness.modelTrainingEnabled)
			assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild))
		end)
		StudyRecords.Append = originalAppend
		os.remove(studyStorePath)
		os.remove(studyReviewPath)
		newBuild()
		assert.is_true(ok, tostring(testError))
	end)

	it("records two distinct linked Full DPS skills as four exact isolated interaction cells", function()
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		local sourceBuild = build
		sourceBuild.characterLevel = 90
		sourceBuild.characterLevelAutoMode = false
		local function equip(slotName, itemText)
			local item = new("Item"):Item(itemText)
			sourceBuild.itemsTab:AddItem(item, true)
			sourceBuild.itemsTab.activeItemSet[slotName].selItemId = item.id
			sourceBuild.itemsTab.slots[slotName]:SetSelItemId(item.id)
			sourceBuild.itemsTab:PopulateSlots()
			return item
		end
		equip("Weapon 1", "Rarity: RARE\nAI Planner Skill Pair Staff\nJudgement Staff\nQuality: 0\nSockets: G-G-G-G\nImplicits: 0\n")
		equip("Body Armour", "Rarity: RARE\nAI Planner Skill Pair Body\nVaal Regalia\nQuality: 0\nSockets: B\nImplicits: 0\n")
		local function gemId(name)
			for id, data in pairs(sourceBuild.data.gems) do if data.name == name then return data.id or id end end
			assert.is_truthy(false, "Expected loaded PoB gem: " .. name)
		end
		local cycloneId, fireballId = gemId("Cyclone"), gemId("Fireball")
		local frostBladesId, arcId = gemId("Frost Blades"), gemId("Arc")
		sourceBuild.skillsTab:PasteSocketGroup("Slot: Weapon 1\nCyclone 20/0 1\nCyclone 20/0 1\n")
		local groupA = sourceBuild.skillsTab.socketGroupList[1]
		groupA.gemList[1].gemId = cycloneId
		groupA.gemList[2].gemId = cycloneId
		sourceBuild.skillsTab:ProcessSocketGroup(groupA)
		sourceBuild.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 20/0 1\n")
		local groupB = sourceBuild.skillsTab.socketGroupList[2]
		groupB.gemList[1].gemId = fireballId
		sourceBuild.skillsTab:ProcessSocketGroup(groupB)
		groupA.includeInFullDPS, groupB.includeInFullDPS = true, true
		groupA.mainActiveSkill, groupB.mainActiveSkill = 2, 1
		sourceBuild.mainSocketGroup = 1
		sourceBuild.skillsTab:UpdateSocketGroups()
		sourceBuild:SyncLoadouts()
		sourceBuild.calcsTab:BuildOutput()
		local validA, proofA = SkillCatalog.ValidateSocketGroup(sourceBuild, 1)
		local validB, proofB = SkillCatalog.ValidateSocketGroup(sourceBuild, 2)
		assert.is_true(validA, type(proofA) == "string" and proofA or "factor A must use native linked sockets")
		assert.is_true(validB, type(proofB) == "string" and proofB or "factor B must use native linked sockets")
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local compareTab = sourceBuild.compareTab
		assert.is_true(compareTab:ImportBuild(sourceBuild:SaveDB("skill factorial comparison source"), "Skill factorial source"))
		local comparisonEntry = compareTab.compareEntries[1]
		local comparisonId = assert(MCPBridge:CallLocal("list_comparison_builds", { })).entries[1].comparisonId
		local comparisonSignature = Candidate.BuildSignature(comparisonEntry)
		local comparisonSelection = compareTab.activeCompareIndex
		local comparisonSkills = assert(MCPBridge:CallLocal("list_active_skills", { comparisonId = comparisonId }))
		assert.is_false(comparisonSkills.isActiveBuild)
		assert.is_true(comparisonSkills.readOnly)
		assert.are.equal(comparisonId, comparisonSkills.buildReference.comparisonId)
		assert.are.equal("Cyclone", comparisonSkills.skills[1].name)
		local studyStorePath = os.tmpname()
		os.remove(studyStorePath)
		local originalAppend, capturedRecord, capturedRecordId, appendCount = StudyRecords.Append, nil, nil, 0
		StudyRecords.Append = function(record)
			local stored, storeError = StudyRecords.AppendToPath(record, studyStorePath)
			if stored then capturedRecord, capturedRecordId = record, stored.recordId; appendCount = appendCount + 1 end
			return stored, storeError
		end
		local ok, testError = pcall(function()
			local sameGroup, sameGroupError = MCPBridge:CallLocal("record_skill_skill_factorial_experiment", {
				groupAIndex = 1, skillGemAIndex = 2, skillGemAId = frostBladesId,
				skillEffectAId = tostring(sourceBuild.data.gems[frostBladesId].grantedEffect.id),
				groupBIndex = 1, skillGemBIndex = 1, skillGemBId = arcId,
				skillEffectBId = tostring(sourceBuild.data.gems[arcId].grantedEffect.id),
			})
			assert.is_nil(sameGroup)
			assert.is_truthy(sameGroupError:find("distinct socket groups", 1, true))
			local cancelledStart, cancelledStartError = MCPBridge:CallLocal("record_skill_skill_factorial_experiment", {
				groupAIndex = 1, skillGemAIndex = 2, skillGemAId = frostBladesId,
				skillEffectAId = tostring(sourceBuild.data.gems[frostBladesId].grantedEffect.id),
				groupBIndex = 2, skillGemBIndex = 1, skillGemBId = arcId,
				skillEffectBId = tostring(sourceBuild.data.gems[arcId].grantedEffect.id),
				comparisonId = comparisonId,
			})
			assert.is_truthy(cancelledStart, cancelledStartError)
			local cancelled, cancelError = MCPBridge:CallLocal("record_skill_skill_factorial_cancel", { jobId = cancelledStart.jobId })
			assert.is_truthy(cancelled, cancelError)
			assert.are.equal("cancelled", cancelled.status)
			assert.are.equal(0, cancelled.completedCells)
			assert.are.equal(0, appendCount, "cancellation before the first cell must not persist a partial study")
			local started, startError = MCPBridge:CallLocal("record_skill_skill_factorial_experiment", {
				groupAIndex = 1, skillGemAIndex = 2, skillGemAId = frostBladesId,
				skillEffectAId = tostring(sourceBuild.data.gems[frostBladesId].grantedEffect.id),
				groupBIndex = 2, skillGemBIndex = 1, skillGemBId = arcId,
				skillEffectBId = tostring(sourceBuild.data.gems[arcId].grantedEffect.id),
				label = "Cyclone and Fireball replacement interaction",
				comparisonId = comparisonId,
			})
			assert.is_truthy(started, startError)
			assert.is_false(started.isActiveBuild)
			assert.is_true(started.readOnly)
			assert.are.equal(comparisonId, started.buildReference.comparisonId)
			local status
			for frame = 1, 8 do
				MCPBridge:StepFactorialJobs()
				status = assert(MCPBridge:CallLocal("record_skill_skill_factorial_status", { jobId = started.jobId }))
				assert.are.equal(math.min(frame, 4), status.completedCells)
				if status.status ~= "running" then break end
			end
			assert.are.equal("completed", status.status, status.error)
			assert.are.equal("exact_skill_skill_factorial_recorded", status.result.status)
			assert.is_false(status.result.trainingEligible)
			assert.is_true(status.result.interaction.FullDPS ~= nil,
				"the combination metric must come from PoB's native aggregate Full DPS")
			assert.is_truthy(capturedRecord)
			assert.are.equal("skill_skill_factorial_interaction", capturedRecord.kind)
			assert.are.equal("native_comparison_build", capturedRecord.source.type)
			assert.are.equal(comparisonId, capturedRecord.source.comparisonId)
			assert.are.equal("native_linked_groups", capturedRecord.experiment.socketStatus)
			for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
				local cell = status.result.cells[name]
				assert.is_true(cell.exactCalculated)
				assert.are.equal("calcs_getMiscCalculator", cell.evaluationMethod)
				assert.is_true(cell.selectedSkills.factorA.fullDPSIncluded)
				assert.is_true(cell.selectedSkills.factorB.fullDPSIncluded)
				assert.is_true(cell.selectedSkills.factorA.fullDPSActivityIdentity ~= "")
				assert.is_true(cell.selectedSkills.factorB.fullDPSActivityIdentity ~= "")
				assert.are.equal(2, cell.selectedSkills.factorA.fullDPSActivityGemIndex,
					"Full DPS proof must retain the selected second gem slot")
			end
			local persisted = assert(StudyRecords.ReadById(studyStorePath, capturedRecordId,
				capturedRecord.engine.dataVersion, capturedRecord.engine.treeVersion, capturedRecord.engine.pobVersion,
				capturedRecord.engine.pobBranch, capturedRecord.engine.manifestFingerprint))
			assert.is_false(persisted.trainingEligible)
			local graph = assert(RelationGraph.Build({ persisted }, capturedRecord.engine, 25))
			assert.are.equal(1, graph.edgeCount, graph.discarded[1] and graph.discarded[1].reason or "skill×skill edge missing")
			assert.are.equal("active_skill_gem_x_active_skill_gem", graph.edges[1].edgeType)
			local listed = assert(StudyRecords.List(studyStorePath, 25, capturedRecord.engine.dataVersion,
				capturedRecord.engine.treeVersion, capturedRecord.engine.pobVersion,
				capturedRecord.engine.pobBranch, capturedRecord.engine.manifestFingerprint))
			assert.are.equal(1, listed.learningCoverage.experimentFamilies.skillSkillFactorialInteractions)
			assert.is_false(listed.learningCoverage.modelTrainingEnabled)
			assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild))
			assert.are.equal(comparisonSignature, Candidate.BuildSignature(comparisonEntry))
			assert.are.equal(comparisonSelection, compareTab.activeCompareIndex)
			assert.are.equal(cycloneId, sourceBuild.skillsTab.socketGroupList[1].gemList[1].gemData.id)
			assert.are.equal(cycloneId, sourceBuild.skillsTab.socketGroupList[1].gemList[2].gemData.id)
			assert.are.equal(fireballId, sourceBuild.skillsTab.socketGroupList[2].gemList[1].gemData.id)
		end)
		StudyRecords.Append = originalAppend
		os.remove(studyStorePath)
		os.remove(studyStorePath .. ".reviews.jsonl")
		compareTab:RemoveBuild(1)
		newBuild()
		assert.is_true(ok, tostring(testError))
	end)

	it("records a four-cell passive/support interaction with exact node and support isolation", function()
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		local sourceBuild = build
		sourceBuild.characterLevel = 90
		sourceBuild.characterLevelAutoMode = false
		sourceBuild.skillsTab:PasteSocketGroup("Fireball 20/0  1\nAdded Fire Damage 20/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.calcsTab:BuildOutput()
		local group = sourceBuild.skillsTab.socketGroupList[sourceBuild.mainSocketGroup]
		local selected = group.displaySkillList[group.mainActiveSkill or 1]
		local skillGemIndex
		for index, gem in ipairs(group.gemList) do
			if selected.activeEffect.srcInstance == gem then skillGemIndex = index break end
		end
		local supportGemIndex
		for index, gem in ipairs(group.gemList) do
			local effect = gem.grantedEffect or (gem.gemData and gem.gemData.grantedEffect)
			if effect and effect.support then supportGemIndex = index break end
		end
		assert.is_truthy(skillGemIndex)
		assert.is_truthy(supportGemIndex)
		local nodeCandidates = { }
		for nodeId, node in pairs(sourceBuild.spec.nodes) do
			local directlyConnected = false
			for _, linked in ipairs(node.linked or { }) do
				if sourceBuild.spec.allocNodes[linked.id] or linked.id == sourceBuild.spec.curClass.startNodeId then
					directlyConnected = true
					break
				end
			end
			if directlyConnected and not sourceBuild.spec.allocNodes[nodeId] and node.type ~= "Mastery"
				and node.type ~= "Socket" and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
				and not node.isProxy and not node.isMultipleChoiceOption and not node.isTattoo and not node.ascendancyName then
				nodeCandidates[#nodeCandidates + 1] = nodeId
			end
		end
		table.sort(nodeCandidates)
		assert.is_true(#nodeCandidates > 0)
		local function loadedGemId(name)
			for gemId, gemData in pairs(sourceBuild.data.gems) do
				if gemData.name == name then return gemData.id or gemId end
			end
			assert.is_truthy(false, "Expected loaded PoB gem: " .. name)
		end
		local alternateSupportId = loadedGemId("Controlled Destruction")
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local originalAppend, capturedRecord = StudyRecords.Append, nil
		StudyRecords.Append = function(record)
			capturedRecord = record
			record.schemaVersion = 2
			record.trainingEligible = false
			record.quarantined = true
			record.quarantine = { status = "training_schema_unsupported", reasons = { "factorial interaction requires independent review" } }
			return { recordId = "study-passive-support-factorial-contract", storeFile = "OptimizerStudies/paired-experiments.jsonl", duplicate = false }
		end
		local ok, testError = pcall(function()
			local invalidNode, invalidNodeError = MCPBridge:CallLocal("record_passive_support_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = skillGemIndex,
				supportGemIndex = supportGemIndex, supportGemId = alternateSupportId,
				nodeId = selected.activeEffect.srcInstance and sourceBuild.spec.curClass.startNodeId,
			})
			assert.is_nil(invalidNode)
			assert.is_truthy(invalidNodeError)
			local started, startError = MCPBridge:CallLocal("record_passive_support_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = skillGemIndex,
				supportGemIndex = supportGemIndex, supportGemId = alternateSupportId,
				nodeId = nodeCandidates[1], label = "Fireball passive and support interaction",
			})
			assert.is_truthy(started, startError)
			assert.are.equal("running", started.status)
			assert.is_true(started.readOnly)
			local status
			for frame = 1, 6 do
				MCPBridge:StepFactorialJobs()
				status = assert(MCPBridge:CallLocal("record_passive_support_factorial_status", { jobId = started.jobId }))
				assert.are.equal(math.min(frame, 4), status.completedCells,
					"each UI-loop step completes at most one exact passive/support cell")
				if status.status == "completed" or status.status == "failed" or status.status == "stale_build" then break end
			end
			assert.are.equal("completed", status.status, status.error)
			assert.are.equal("exact_passive_support_factorial_recorded", status.result.status)
			assert.are.equal("unlinked_planning_group", status.result.socketStatus)
			assert.is_false(status.result.trainingEligible)
			local cells = status.result.cells
			assert.is_true(cells.baseline.selectedSkill.supportApplied)
			assert.is_true(cells.factorA.selectedSkill.supportApplied)
			assert.is_true(cells.factorB.selectedSkill.supportApplied)
			assert.is_true(cells.combined.selectedSkill.supportApplied)
			assert.are.equal(cells.baseline.selectedSkill.gemId, cells.combined.selectedSkill.gemId)
			assert.are.equal(cells.baseline.selectedSkill.effectId, cells.combined.selectedSkill.effectId)
			assert.are.equal(sourceBuild.spec:CountAllocNodes(), cells.baseline.passivePointsUsed)
			assert.are.equal(cells.baseline.passivePointsUsed + 1, cells.factorA.passivePointsUsed)
			assert.are.equal(cells.baseline.passivePointsUsed, cells.factorB.passivePointsUsed)
			assert.are.equal(cells.baseline.passivePointsUsed + 1, cells.combined.passivePointsUsed)
			assert.are.equal(nodeCandidates[1], cells.factorA.addedNodeIds[1])
			assert.are.equal(nodeCandidates[1], cells.combined.addedNodeIds[1])
			assert.are.equal(cells.baseline.selectedSkill.supportGemId, cells.factorA.selectedSkill.supportGemId)
			assert.are.equal(alternateSupportId, cells.factorB.selectedSkill.supportGemId)
			assert.are.equal(alternateSupportId, cells.combined.selectedSkill.supportGemId)
			assert.is_true(status.result.interactionMetricCount > 0)
			for metric, value in pairs(status.result.interaction) do
				assert.are.equal(cells.combined.metrics[metric] - cells.factorA.metrics[metric]
					- cells.factorB.metrics[metric] + cells.baseline.metrics[metric], value.interaction)
			end
			assert.is_truthy(capturedRecord)
			assert.are.equal("passive_support_factorial_interaction", capturedRecord.kind)
			assert.are.equal("add_passive_node", capturedRecord.experiment.factorA.operation)
			assert.are.equal("replace_support_gem", capturedRecord.experiment.factorB.operation)
			assert.is_false(capturedRecord.trainingEligible)
			local expectedEngine = {
				pobVersion = capturedRecord.engine.pobVersion, pobBranch = capturedRecord.engine.pobBranch,
				dataVersion = capturedRecord.engine.dataVersion, treeVersion = capturedRecord.engine.treeVersion,
				manifestFingerprint = capturedRecord.engine.manifestFingerprint,
			}
			local graph = assert(RelationGraph.Build({ capturedRecord }, expectedEngine, 25))
			local evidence = capturedRecord.factorial.cells.baseline.evidenceContext
			local graphFailure = graph.discarded[1] and graph.discarded[1].reason or "no graph edge returned"
			assert.are.equal(1, graph.edgeCount, graphFailure .. " " .. json.encode({
				sourceSignature = capturedRecord.source.buildSignature,
				cellSignature = evidence.buildSignature,
				sourceScenario = capturedRecord.source.scenarioSignature,
				cellScenario = evidence.scenarioSignature,
				cellEngine = evidence.engine, recordEngine = capturedRecord.engine, expectedEngine = expectedEngine,
			}))
			assert.are.equal("passive_node_x_support_gem", graph.edges[1].edgeType)
			assert.is_false(graph.edges[1].trainingEligible)
			assert.is_false(graph.edges[1].rankingEligible)
			assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild))
		end)
		StudyRecords.Append = originalAppend
		newBuild()
		assert.is_true(ok, tostring(testError))
	end)

	it("records exact skill×item-slot cells without changing the linked source build", function()
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		local sourceBuild = build
		sourceBuild.characterLevel = 90
		sourceBuild.characterLevelAutoMode = false
		local function addStoredItem(raw)
			sourceBuild.itemsTab:CreateDisplayItemFromRaw(raw)
			local item = sourceBuild.itemsTab.displayItem
			assert.is_truthy(item and item.base)
			sourceBuild.itemsTab:AddDisplayItem(true)
			return item
		end
		local socketItem = addStoredItem("Rarity: Rare\nLinked Study Chest\nSimple Robe\nSockets: B-R\nImplicits: 0\n+60 to maximum Life")
		local replacementHelmet = addStoredItem("Rarity: Rare\nSynergy Helmet\nIron Hat\nImplicits: 0\n+80 to maximum Life")
		local duplicateRing = addStoredItem("Rarity: Rare\nDuplicate Study Ring\nIron Ring\nImplicits: 0\n+25 to maximum Life")
		local removableRing = addStoredItem("Rarity: Rare\nRemovable Study Ring\nGold Ring\nImplicits: 0\n+18 to maximum Life")
		sourceBuild.itemsTab:EquipItemInSet(socketItem, sourceBuild.itemsTab.activeItemSetId)
		sourceBuild.itemsTab:EquipItemInSet(duplicateRing, sourceBuild.itemsTab.activeItemSetId)
		sourceBuild.itemsTab.slots["Ring 2"]:SetSelItemId(removableRing.id)
		sourceBuild.itemsTab:PopulateSlots()
		sourceBuild.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 20/0  1\nAdded Fire Damage 20/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.itemsTab:PopulateSlots()
		sourceBuild.calcsTab:BuildOutput()
		local group = sourceBuild.skillsTab.socketGroupList[sourceBuild.mainSocketGroup]
		assert.are.equal(socketItem.id, sourceBuild.itemsTab.activeItemSet["Body Armour"].selItemId)
		local selected = group.displaySkillList[group.mainActiveSkill or 1]
		local skillGemIndex
		for index, gem in ipairs(group.gemList or { }) do
			if selected.activeEffect.srcInstance == gem then skillGemIndex = index break end
		end
		assert.is_truthy(skillGemIndex)
		local alternativeSkillId
		for gemId, gemData in pairs(sourceBuild.data.gems) do
			if gemData.name == "Arc" and SkillCatalog.IsActiveSkillGem(gemData) then alternativeSkillId = gemData.id or gemId break end
		end
		assert.is_truthy(alternativeSkillId)
		local alternateSkill = sourceBuild.data.gems[alternativeSkillId]
		local alternateEffect
		for _, effect in ipairs(alternateSkill.grantedEffectList or { alternateSkill.grantedEffect }) do
			if effect and not effect.support and not effect.unsupported then alternateEffect = effect break end
		end
		assert.is_truthy(alternateEffect)
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local studyStorePath = os.tmpname()
		os.remove(studyStorePath)
		local studyReviewPath = studyStorePath .. ".reviews.jsonl"
		local originalAppend, captured, appendCount = StudyRecords.Append, nil, 0
		StudyRecords.Append = function(record)
			local stored, storeError = StudyRecords.AppendToPath(record, studyStorePath)
			if stored then
				appendCount = appendCount + 1
				captured = record
			end
			return stored, storeError
		end
		local ok, testError = pcall(function()
			local rejected, rejectedError = MCPBridge:CallLocal("record_skill_item_slot_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = skillGemIndex,
				skillGemId = alternativeSkillId, skillEffectId = tostring(alternateEffect.id),
				slot = "Body Armour", itemId = socketItem.id,
			})
			assert.is_nil(rejected)
			assert.is_truthy(rejectedError and rejectedError:find("socket item", 1, true), tostring(rejectedError))
			rejected, rejectedError = MCPBridge:CallLocal("record_skill_item_slot_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = skillGemIndex,
				skillGemId = alternativeSkillId, skillEffectId = tostring(alternateEffect.id),
				slot = "Ring 2", itemId = duplicateRing.id,
			})
			assert.is_nil(rejected)
			assert.is_truthy(rejectedError and rejectedError:find("already equipped in another active slot", 1, true), tostring(rejectedError))
			local originalWeaponSwap = sourceBuild.itemsTab.activeItemSet.useSecondWeaponSet
			sourceBuild.itemsTab.activeItemSet.useSecondWeaponSet = true
			rejected, rejectedError = MCPBridge:CallLocal("record_skill_item_slot_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = skillGemIndex,
				skillGemId = alternativeSkillId, skillEffectId = tostring(alternateEffect.id),
				slot = "Weapon 1", itemId = 0,
			})
			sourceBuild.itemsTab.activeItemSet.useSecondWeaponSet = originalWeaponSwap
			assert.is_nil(rejected)
			assert.is_truthy(rejectedError and rejectedError:find("active and shown", 1, true), tostring(rejectedError))
			local started, startError = MCPBridge:CallLocal("record_skill_item_slot_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = skillGemIndex,
				skillGemId = alternativeSkillId, skillEffectId = tostring(alternateEffect.id),
				slot = "Helmet", itemId = replacementHelmet.id,
				label = "Fireball/Arc × helmet slot",
			})
			assert.is_truthy(started, startError)
			assert.are.equal("running", started.status)
			local cancelled = assert(MCPBridge:CallLocal("record_skill_item_slot_factorial_cancel", { jobId = started.jobId }))
			assert.are.equal("cancelled", cancelled.status)
			MCPBridge:StepFactorialJobs()
			assert.are.equal("cancelled", assert(MCPBridge:CallLocal("record_skill_item_slot_factorial_status", { jobId = started.jobId })).status)
			assert.are.equal(0, appendCount, "cancellation before the first cell must not persist a partial record")

			started, startError = MCPBridge:CallLocal("record_skill_item_slot_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = skillGemIndex,
				skillGemId = alternativeSkillId, skillEffectId = tostring(alternateEffect.id),
				slot = "Helmet", itemId = replacementHelmet.id,
			})
			assert.is_truthy(started, startError)
			local status
			for frame = 1, 7 do
				MCPBridge:StepFactorialJobs()
				status = assert(MCPBridge:CallLocal("record_skill_item_slot_factorial_status", { jobId = started.jobId }))
				assert.are.equal(math.min(frame, 4), status.completedCells,
					"each UI-loop step may complete at most one exact skill/item cell")
				if status.status == "completed" or status.status == "failed" or status.status == "stale_build" then break end
			end
			assert.are.equal("completed", status.status, status.error)
			assert.are.equal(4, status.completedCells)
			assert.are.equal("exact_skill_item_slot_factorial_recorded", status.result.status)
			assert.are.equal("native_linked_group", status.result.socketStatus)
			assert.is_false(status.result.trainingEligible)
			assert.is_true(status.result.interactionMetricCount > 0)
			for metric, value in pairs(status.result.interaction) do
				local cells = status.result.cells
				assert.are.equal(cells.combined.metrics[metric] - cells.factorA.metrics[metric]
					- cells.factorB.metrics[metric] + cells.baseline.metrics[metric], value.interaction)
			end
			assert.is_truthy(captured)
			assert.are.equal("skill_item_slot_factorial_interaction", captured.kind)
			assert.are.equal("replace_item_in_slot", captured.experiment.factorB.operation)
			assert.are.equal("Helmet", captured.experiment.factorB.slot)
			assert.are.equal(sourceSignature and StudyContext.BuildSignature(sourceSignature), captured.source.buildSignature)
			assert.are.equal("sha256", captured.source.buildSignatureAlgorithm)
			assert.are.equal(1, captured.source.buildSignatureVersion)
			assert.are.equal(StudyContext.ScenarioSignature(captured.buildState.configuration), captured.source.scenarioSignature)
			assert.are.equal("3.29", captured.engine.dataVersion)
			assert.are.equal("3_29", captured.engine.treeVersion)
			assert.are.equal("native_linked_group", captured.experiment.socketStatus)
			local expectedCells = {
				baseline = { skill = tostring(selected.activeEffect.srcInstance.gemData.id), effect = tostring(selected.activeEffect.grantedEffect.id), itemId = tonumber(sourceBuild.itemsTab.activeItemSet["Helmet"].selItemId) or 0 },
				factorA = { skill = tostring(alternativeSkillId), effect = tostring(alternateEffect.id), itemId = tonumber(sourceBuild.itemsTab.activeItemSet["Helmet"].selItemId) or 0 },
				factorB = { skill = tostring(selected.activeEffect.srcInstance.gemData.id), effect = tostring(selected.activeEffect.grantedEffect.id), itemId = replacementHelmet.id },
				combined = { skill = alternativeSkillId, effect = tostring(alternateEffect.id), itemId = replacementHelmet.id },
			}
			local expectedSocketedSupportGemIds = { tostring(group.gemList[2].gemData.id) }
			local expectedAppliedSupportGemIds = expectedSocketedSupportGemIds
			local expectedAppliedSupportEffectIds = { tostring(group.gemList[2].gemData.grantedEffectId) }
			assert.is_truthy(expectedAppliedSupportEffectIds[1] and expectedAppliedSupportEffectIds[1] ~= "nil")
			for cellName, identity in pairs(expectedCells) do
				local cell = captured.factorial.cells[cellName]
				local selectedSkill = cell.selectedSkill
				assert.is_true(cell.exactCalculated)
				assert.are.equal("calcs_getMiscCalculator", cell.evaluationMethod)
				assert.are.equal("native_linked_group", cell.socketStatus)
				assert.are.equal(identity.skill, selectedSkill.gemId)
				assert.are.equal(identity.effect, selectedSkill.effectId)
				assert.are.equal(sourceBuild.mainSocketGroup, selectedSkill.groupIndex)
				assert.are.equal(skillGemIndex, selectedSkill.gemIndex)
				assert.are.same(expectedAppliedSupportGemIds, selectedSkill.supportGemIds)
				assert.are.same(expectedAppliedSupportEffectIds, selectedSkill.supportEffectIds)
				assert.are.same(expectedSocketedSupportGemIds, selectedSkill.socketedSupportGemIds)
				assert.are.equal("Helmet", cell.selectedItem.slot)
				assert.are.equal(identity.itemId, cell.selectedItem.itemId)
				assert.are.equal(captured.source.buildSignature, cell.evidenceContext.buildSignature)
				assert.are.equal(captured.source.scenarioSignature, cell.evidenceContext.scenarioSignature)
				assert.are.equal(captured.engine.dataVersion, cell.evidenceContext.engine.dataVersion)
				assert.are.equal(captured.engine.treeVersion, cell.evidenceContext.engine.treeVersion)
				assert.are.equal(captured.engine.pobVersion, cell.evidenceContext.engine.pobVersion)
				assert.are.equal(captured.engine.pobBranch, cell.evidenceContext.engine.pobBranch)
			end
			assert.is_false(captured.trainingEligible)
			assert.are.equal(1, appendCount)

			local storedFile = assert(io.open(studyStorePath, "rb"))
			local storedRecord = assert(json.decode(assert(storedFile:read("*l"))))
			storedFile:close()
			assert.are.equal("skill_item_slot_factorial_interaction", storedRecord.kind)
			for _, cellName in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
				assert.is_true(storedRecord.factorial.cells[cellName].exactCalculated,
					"the isolated persisted record must retain each exact PoB cell")
			end
			local coverage = assert(StudyRecords.List(studyStorePath, 25,
				storedRecord.engine.dataVersion, storedRecord.engine.treeVersion,
				storedRecord.engine.pobVersion, storedRecord.engine.pobBranch, storedRecord.engine.manifestFingerprint))
			assert.are.equal(1, coverage.totalRecords)
			assert.are.equal(1, coverage.learningCoverage.exactPairRows)
			assert.are.equal(1, coverage.learningCoverage.experimentFamilies.skillItemFactorialInteractions)
			assert.are.equal(1, coverage.learningCoverage.reviewRows.pending)
			assert.are.equal(0, coverage.trainingReadiness.eligibleRows)
			assert.is_false(coverage.trainingReadiness.modelTrainingEnabled)

			started, startError = MCPBridge:CallLocal("record_skill_item_slot_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = skillGemIndex,
				skillGemId = alternativeSkillId, skillEffectId = tostring(alternateEffect.id),
				slot = "Ring 2", itemId = 0, label = "Fireball/Arc × empty Ring 2",
			})
			assert.is_truthy(started, startError)
			for frame = 1, 7 do
				MCPBridge:StepFactorialJobs()
				status = assert(MCPBridge:CallLocal("record_skill_item_slot_factorial_status", { jobId = started.jobId }))
				if status.status == "completed" or status.status == "failed" or status.status == "stale_build" then break end
			end
			assert.are.equal("completed", status.status, status.error)
			assert.are.equal(0, captured.experiment.factorB.after.itemId)
			assert.are.equal(0, captured.factorial.cells.factorB.selectedItem.itemId)
			assert.are.equal(2, appendCount)
			coverage = assert(StudyRecords.List(studyStorePath, 25,
				captured.engine.dataVersion, captured.engine.treeVersion,
				captured.engine.pobVersion, captured.engine.pobBranch, captured.engine.manifestFingerprint))
			assert.are.equal(2, coverage.totalRecords)
			assert.are.equal(2, coverage.learningCoverage.exactPairRows)
			assert.are.equal(2, coverage.learningCoverage.experimentFamilies.skillItemFactorialInteractions)
			assert.are.equal(2, coverage.learningCoverage.reviewRows.pending)
			assert.are.equal(0, coverage.trainingReadiness.eligibleRows)
			assert.is_false(coverage.trainingReadiness.modelTrainingEnabled)
			assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild))

			started, startError = MCPBridge:CallLocal("record_skill_item_slot_factorial_experiment", {
				groupIndex = sourceBuild.mainSocketGroup, skillGemIndex = skillGemIndex,
				skillGemId = alternativeSkillId, skillEffectId = tostring(alternateEffect.id),
				slot = "Ring 2", itemId = 0,
			})
			assert.is_truthy(started, startError)
			MCPBridge:StepFactorialJobs()
			assert.are.equal(1, assert(MCPBridge:CallLocal("record_skill_item_slot_factorial_status", { jobId = started.jobId })).completedCells)
			local originalConfigSetId = sourceBuild.configTab.activeConfigSetId
			sourceBuild.configTab.activeConfigSetId = assert(tonumber(originalConfigSetId)) + 1000
			MCPBridge:StepFactorialJobs()
			sourceBuild.configTab.activeConfigSetId = originalConfigSetId
			status = assert(MCPBridge:CallLocal("record_skill_item_slot_factorial_status", { jobId = started.jobId }))
			assert.are.equal("stale_build", status.status)
			assert.are.equal(2, appendCount, "a scenario/source change between exact cells must not persist partial factorial evidence")
		end)
		StudyRecords.Append = originalAppend
		os.remove(studyStorePath)
		os.remove(studyReviewPath)
		assert.is_nil(io.open(studyStorePath, "rb"), "the isolated factorial store must be removed after the test")
		assert.is_nil(io.open(studyReviewPath, "rb"), "the isolated review journal must be removed after the test")
		newBuild()
		assert.is_true(ok, tostring(testError))
	end)

	it("records an exact connected passive×item interaction without mutating the source", function()
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		local sourceBuild = build
		sourceBuild.characterLevel = 90
		sourceBuild.characterLevelAutoMode = false
		sourceBuild.spec:SelectClass(assert(sourceBuild.spec.tree.classNameMap.Witch))
		local function addStoredItem(raw)
			sourceBuild.itemsTab:CreateDisplayItemFromRaw(raw)
			local item = sourceBuild.itemsTab.displayItem
			assert.is_truthy(item and item.base)
			sourceBuild.itemsTab:AddDisplayItem(true)
			return item
		end
		local socketItem = addStoredItem("Rarity: Rare\nLinked Study Chest\nSimple Robe\nSockets: B-R\nImplicits: 0\n+60 to maximum Life")
		local replacementHelmet = addStoredItem("Rarity: Rare\nSynergy Helmet\nIron Hat\nImplicits: 0\n+80 to maximum Life")
		sourceBuild.itemsTab:EquipItemInSet(socketItem, sourceBuild.itemsTab.activeItemSetId)
		sourceBuild.skillsTab:PasteSocketGroup("Slot: Body Armour\nFireball 20/0  1\nAdded Fire Damage 20/0  1")
		sourceBuild.mainSocketGroup = 1
		sourceBuild.itemsTab:PopulateSlots()
		sourceBuild.calcsTab:BuildOutput()
		local nodeId
		local remoteNodeId
		for candidateId, node in pairs(sourceBuild.spec.nodes) do
			local directlyConnected = false
			for _, linked in ipairs(node.linked or { }) do
				if sourceBuild.spec.allocNodes[linked.id] then directlyConnected = true break end
			end
			local ordinary = node.type ~= "Mastery" and node.type ~= "Socket" and node.type ~= "ClassStart"
				and node.type ~= "AscendClassStart" and not node.isProxy and not node.isMultipleChoiceOption
				and not node.isTattoo and not node.ascendancyName
			if directlyConnected and not sourceBuild.spec.allocNodes[candidateId] and ordinary then
				nodeId = candidateId
			elseif not sourceBuild.spec.allocNodes[candidateId] and ordinary then
				local unallocatedPathNodes = 0
				for _, pathNode in ipairs(node.path or { }) do if not pathNode.alloc then unallocatedPathNodes = unallocatedPathNodes + 1 end end
				if unallocatedPathNodes > 1 then remoteNodeId = candidateId end
			end
			if nodeId and remoteNodeId then break end
		end
		assert.is_truthy(nodeId, "Witch's current tree should expose a directly connected ordinary passive")
		assert.is_truthy(remoteNodeId, "the native tree should expose a multi-node route that the one-node interaction tool rejects")
		local sourceSignature = Candidate.BuildSignature(sourceBuild)
		local studyStorePath = os.tmpname()
		os.remove(studyStorePath)
		local studyReviewPath = studyStorePath .. ".reviews.jsonl"
		local originalAppend, captured, appendCount = StudyRecords.Append, nil, 0
		StudyRecords.Append = function(record)
			captured = record
			local stored, storeError = StudyRecords.AppendToPath(record, studyStorePath)
			if stored then appendCount = appendCount + 1 end
			return stored, storeError
		end
		local ok, testError = pcall(function()
			local rejected, rejectError = MCPBridge:CallLocal("record_passive_item_slot_factorial_experiment", {
				nodeId = 0, slot = "Helmet", itemId = replacementHelmet.id,
			})
			assert.is_nil(rejected)
			assert.is_truthy(rejectError)
			rejected, rejectError = MCPBridge:CallLocal("record_passive_item_slot_factorial_experiment", {
				nodeId = remoteNodeId, slot = "Helmet", itemId = replacementHelmet.id,
			})
			assert.is_nil(rejected)
			assert.is_truthy(rejectError and rejectError:find("direct one-node addition", 1, true), tostring(rejectError))
			local cancelStart, cancelStartError = MCPBridge:CallLocal("record_passive_item_slot_factorial_experiment", {
				nodeId = nodeId, slot = "Helmet", itemId = replacementHelmet.id,
			})
			assert.is_truthy(cancelStart, cancelStartError)
			local cancelled, cancelError = MCPBridge:CallLocal("record_passive_item_slot_factorial_cancel", { jobId = cancelStart.jobId })
			assert.is_truthy(cancelled, cancelError)
			assert.are.equal("cancelled", cancelled.status)
			MCPBridge:StepFactorialJobs()
			assert.are.equal("cancelled", assert(MCPBridge:CallLocal("record_passive_item_slot_factorial_status", { jobId = cancelStart.jobId })).status)
			assert.are.equal(0, appendCount, "cancelling before the first exact cell must not persist partial evidence")
			local started, startError = MCPBridge:CallLocal("record_passive_item_slot_factorial_experiment", {
				nodeId = nodeId, slot = "Helmet", itemId = replacementHelmet.id,
				label = "Witch passive × helmet",
			})
			assert.is_truthy(started, startError)
			assert.are.equal("running", started.status)
			assert.are.equal(4, started.totalCells)
			assert.is_true(started.readOnly)
			local status
			for frame = 1, 7 do
				MCPBridge:StepFactorialJobs()
				status = assert(MCPBridge:CallLocal("record_passive_item_slot_factorial_status", { jobId = started.jobId }))
				assert.are.equal(math.min(frame, 4), status.completedCells)
				if status.status == "completed" or status.status == "failed" or status.status == "stale_build" then break end
			end
			assert.are.equal("completed", status.status, status.error)
			assert.are.equal("exact_passive_item_slot_factorial_recorded", status.result.status)
			assert.are.equal(nodeId, status.result.nodeId)
			assert.are.equal("Helmet", status.result.slot)
			assert.are.equal(replacementHelmet.id, status.result.itemId)
			assert.is_false(status.result.trainingEligible)
			assert.are.equal(1, appendCount)
			for _, cellName in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
				local cell = status.result.cells[cellName]
				assert.is_true(cell.exactCalculated)
				assert.are.equal("calcs_getMiscCalculator", cell.evaluationMethod)
				assert.are.equal(nodeId, cell.nodeId)
				assert.are.same((cellName == "factorA" or cellName == "combined") and { nodeId } or { }, cell.addedNodeIds)
				assert.are.equal("Helmet", cell.selectedItem.slot)
				assert.are.equal("native_linked_group", cell.socketStatus)
				assert.are.equal(sourceSignature and StudyContext.BuildSignature(sourceSignature), cell.evidenceContext.buildSignature)
			end
			local exactDpsInteraction = status.result.cells.combined.metrics.CombinedDPS
				- status.result.cells.factorA.metrics.CombinedDPS - status.result.cells.factorB.metrics.CombinedDPS
				+ status.result.cells.baseline.metrics.CombinedDPS
			assert.are.equal(exactDpsInteraction, status.result.interaction.CombinedDPS.interaction)
			assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild), "the factorial run must preserve the source build")
			assert.are.equal("passive_item_slot_factorial_interaction", captured.kind)
			assert.is_false(captured.trainingEligible)
			assert.is_true(captured.quarantined)
			local listed = assert(StudyRecords.List(studyStorePath, 25, captured.engine.dataVersion,
				captured.engine.treeVersion, captured.engine.pobVersion, captured.engine.pobBranch, captured.engine.manifestFingerprint))
			assert.are.equal(1, listed.learningCoverage.experimentFamilies.passiveItemFactorialInteractions)
			assert.are.equal(0, listed.trainingReadiness.eligibleRows)
			local graph = assert(RelationGraph.Build({ captured }, captured.engine, 25))
			assert.are.equal(1, graph.edgeCount)
			assert.are.equal("passive_node_x_item_slot", graph.edges[1].edgeType)
			assert.are.equal(exactDpsInteraction, graph.edges[1].metrics.CombinedDPS.interaction)
			assert.is_false(graph.optimizerInput)

			local originalLevel = sourceBuild.characterLevel
			sourceBuild.characterLevel = originalLevel - 1
			local staleStart, staleStartError = MCPBridge:CallLocal("record_passive_item_slot_factorial_experiment", {
				nodeId = nodeId, slot = "Helmet", itemId = replacementHelmet.id,
			})
			sourceBuild.characterLevel = originalLevel
			assert.is_truthy(staleStart, staleStartError)
			MCPBridge:StepFactorialJobs()
			local staleStatus = assert(MCPBridge:CallLocal("record_passive_item_slot_factorial_status", { jobId = staleStart.jobId }))
			assert.are.equal("stale_build", staleStatus.status)
			assert.are.equal(0, staleStatus.completedCells, "a changed source must be rejected before the next exact cell")
			assert.are.equal(1, appendCount, "a stale factorial job must not append a second record")
			assert.are.equal(sourceSignature, Candidate.BuildSignature(sourceBuild))
		end)
		StudyRecords.Append = originalAppend
		os.remove(studyStorePath)
		os.remove(studyReviewPath)
		newBuild()
		assert.is_true(ok, tostring(testError))
	end)

	it("serves only bounded current-version report-only synergy graph queries", function()
		newBuild()
		local originalList = StudyRecords.List
		StudyRecords.List = function(_, limit)
			assert.are.equal(3, limit)
			return { records = { }, totalRecords = 7 }
		end
		local ok, testError = pcall(function()
			local graph, graphError = MCPBridge:CallLocal("get_synergy_graph", { limit = 3 })
			assert.is_truthy(graph, graphError)
			assert.are.equal("report_only_evidence_graph", graph.status)
			assert.are.equal(0, graph.edgeCount)
			assert.are.equal(0, #graph.interactionSummaries)
			assert.are.equal(0, graph.aggregationDiagnostics.eligibleEdgeCount)
			assert.is_false(graph.aggregationDiagnostics.independentSamplesConfirmed)
			assert.are.equal(7, graph.totalStoredRecords)
			assert.is_false(graph.optimizerInput)
			assert.is_false(graph.trainingEligible)
			local invalidLimit, limitError = MCPBridge:CallLocal("get_synergy_graph", { limit = 26 })
			assert.is_nil(invalidLimit)
			assert.is_truthy(limitError:find("1 to 25", 1, true))
			local extra, extraError = MCPBridge:CallLocal("get_synergy_graph", { limit = 3, path = "C:\\outside" })
			assert.is_nil(extra)
			assert.is_truthy(extraError:find("Unsupported", 1, true))
		end)
		StudyRecords.List = originalList
		newBuild()
		assert.is_true(ok, tostring(testError))
	end)

	it("allows claimed ChatGPT MCP edits on the same build and rejects edits made before claim", function()
		local previousListener, previousRequests = MCPBridge.listener, MCPBridge.userRequests
		MCPBridge.listener = { testOnly = true }
		MCPBridge.userRequests = { }
		newBuild()
		local activeBuild = main.modes.BUILD
		local originalLevel = activeBuild.characterLevel
		local ok, testError = pcall(function()
			local requestId, queueError = MCPBridge:QueueUserRequest(activeBuild, "Change the passive tree through typed PoB tools")
			assert.is_truthy(requestId, queueError)
			local claimed = assert(MCPBridge:GetPendingUserRequest())
			assert.are.equal(requestId, claimed.requestId)
			assert.are.equal("processing", claimed.status)

			activeBuild.characterLevel = originalLevel + 1
			local processing = assert(MCPBridge:GetUserRequestStatus(requestId, activeBuild))
			assert.are.equal("processing", processing.status)
			assert.is_true(processing.buildChanged, "typed PoB edits after the ChatGPT claim are expected work, not a stale request")
			local completed, completionError = MCPBridge:CompleteUserRequest(requestId, "completed", "PoB exact recalculation completed.")
			assert.is_truthy(completed, completionError)
			assert.are.equal("completed", completed.status)

			activeBuild.characterLevel = originalLevel
			local staleId, staleQueueError = MCPBridge:QueueUserRequest(activeBuild, "A second request")
			assert.is_truthy(staleId, staleQueueError)
			activeBuild.characterLevel = originalLevel + 2
			local noPending = assert(MCPBridge:GetPendingUserRequest())
			assert.is_false(noPending.pending)
			assert.are.equal(staleId, noPending.staleRequestIds[1])
			local stale = assert(MCPBridge:GetUserRequestStatus(staleId, activeBuild))
			assert.are.equal("stale", stale.status)
		end)
		activeBuild.characterLevel = originalLevel
		MCPBridge.listener, MCPBridge.userRequests = previousListener, previousRequests
		newBuild()
		assert.is_true(ok, tostring(testError))
	end)
end)
