local Progression = require("Modules.Optimizer.Progression")
local Candidate = require("Modules.Optimizer.Candidate")
local MCPBridge = require("Modules.Optimizer.MCPBridge")

describe("Optimizer native progression audit", function()
	local originalProgressionJobs, originalQaJobs

	before_each(function()
		originalProgressionJobs, originalQaJobs = MCPBridge.progressionJobs, MCPBridge.qaJobs
		MCPBridge.progressionJobs, MCPBridge.qaJobs = { }, { }
	end)

	after_each(function()
		MCPBridge.progressionJobs, MCPBridge.qaJobs = originalProgressionJobs, originalQaJobs
	end)

	local function stagesFor(build, options)
		local tree = options.active.treeSpecIndex
		local item = options.active.itemSetId
		local skill = options.active.skillSetId
		local config = options.active.configSetId
		local stages = { }
		for index, level in ipairs({ 12, 28, 68, 90 }) do
			stages[index] = {
				level = level,
				treeSpecIndex = tree,
				itemSetId = item,
				skillSetId = skill,
				configSetId = config,
				mainSocketGroup = options.active.mainSocketGroup,
				mainSkillIndex = 1,
			}
		end
		return stages
	end

	it("lists saved PoB loadouts and rejects malformed or missing stage references", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		local options = assert(Progression.ListOptions(build))
		assert.are.same({ 12, 28, 68, 90 }, options.requiredLevels)
		assert.is_true(#options.treeSpecs > 0)
		assert.is_true(#options.itemSets > 0)
		assert.is_true(#options.skillSets > 0)
		assert.is_true(#options.configSets > 0)
		assert.is_true(#options.baseClasses >= 7)
		assert.are.equal(build.spec.curClassId, options.active.baseClassId)
		assert.is_truthy(options.certificationScope:find("isolated stage proposals", 1, true))
		assert.are.equal(12, options.stageProposalLimits.gemSlots)
		local stages = stagesFor(build, options)
		assert.is_true(Progression.ValidateStages(build, stages))
		stages[1].gemVariants = { { groupIndex = 1, gemIndex = 1, gemId = 123, level = 1, quality = 20 } }
		local gemValid, gemError = Progression.ValidateStages(build, stages)
		assert.is_false(gemValid)
		assert.is_truthy(gemError:find("gemId must be a loaded PoB gem ID string", 1, true))
		stages[1].gemVariants = nil
		stages[2].level = 29
		local valid, err = Progression.ValidateStages(build, stages)
		assert.is_false(valid)
		assert.is_truthy(err:find("must be 28", 1, true))
		stages[2].level = 28
		stages[4].treeSpecIndex = 9999
		valid, err = Progression.ValidateStages(build, stages)
		assert.is_false(valid)
		assert.is_truthy(err:find("saved native PoB tree spec", 1, true))
	end)

	it("generates reproducible, point-bounded campaign prefixes from the active native tree", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		local start = build.spec.nodes[build.spec.curClass.startNodeId]
		local firstNode
		for _, node in ipairs(start.linked or { }) do
			if node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then firstNode = node break end
		end
		assert.is_truthy(firstNode, "native class start must expose an allocated-path candidate")
		build.spec:AllocNode(firstNode)
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local generated = assert(Progression.GenerateStages(build))
		assert.are.equal("not_certified", generated.campaignAvailability)
		assert.are.equal("not_certified", generated.campaignAudit.status)
		assert.are.equal("legality_and_metrics_only", generated.campaignAudit.exactPoBScope)
		assert.are.same({
			"quest_progress_and_rewards", "gem_vendor_and_drop_availability",
			"item_acquisition_and_crafting", "ascendancy_unlock_timing",
		}, {
			generated.campaignAudit.unverified[1].key,
			generated.campaignAudit.unverified[2].key,
			generated.campaignAudit.unverified[3].key,
			generated.campaignAudit.unverified[4].key,
		})
		local nativeExtraPoints = build.calcsTab.mainOutput.ExtraPoints
		local nativeActSchedule = assert(Progression.BuildNativeActSchedule(build, nativeExtraPoints))
		assert.are.same(nativeActSchedule, generated.actSchedule,
			"progression preview and Build Direction notes must share the same PoB-native act schedule")
		assert.are.equal(1, generated.actSchedule[1].firstLevel)
		assert.are.equal(100, generated.actSchedule[#generated.actSchedule].lastLevel)
		local coveredLevel = 1
		for _, actStage in ipairs(generated.actSchedule) do
			assert.are.equal(coveredLevel, actStage.firstLevel, "native act ranges must be contiguous from level 1")
			assert.is_truthy(actStage.actLabel)
			local startPoints, startAct = build:GetPassivePointLimitForLevel(actStage.firstLevel, nativeExtraPoints)
			local endPoints, endAct = build:GetPassivePointLimitForLevel(actStage.lastLevel, nativeExtraPoints)
			assert.are.equal(startAct, actStage.act)
			assert.are.equal(endAct, actStage.act)
			assert.are.equal(startPoints, actStage.firstPointLimit)
			assert.are.equal(endPoints, actStage.lastPointLimit)
			coveredLevel = actStage.lastLevel + 1
		end
		assert.are.equal(101, coveredLevel, "native act ranges must cover every level through 100")
		assert.are.same({ 12, 28, 68, 90 }, {
			generated.stages[1].level, generated.stages[2].level,
			generated.stages[3].level, generated.stages[4].level,
		})
		assert.is_truthy(#generated.limitations >= 3)
		for index, stage in ipairs(generated.stages) do
			assert.is_true(Progression.ValidateStages(build, generated.stages))
			local nativeLimit, nativeAct = build:GetPassivePointLimitForLevel(stage.level, nativeExtraPoints)
			local nativeActLabel
			for _, actStage in ipairs(nativeActSchedule) do
				if stage.level >= actStage.firstLevel and stage.level <= actStage.lastLevel then
					nativeActLabel = actStage.actLabel
					break
				end
			end
			assert.are.equal(nativeAct, generated.checkpoints[index].act,
				"each checkpoint must report the same act index as PoB's native method")
			assert.are.equal(nativeActLabel, generated.checkpoints[index].actLabel)
			assert.are.equal(nativeLimit, generated.checkpoints[index].pointLimit)
			assert.are.equal(generated.checkpoints[index].plannedMainTreePoints,
				math.min(select(1, build.treeTab.specList[stage.treeSpecIndex]:CountAllocNodes()), generated.checkpoints[index].pointLimit))
		end
		local repeated = assert(MCPBridge:CallLocal("progression_generate", { }))
		assert.are.same(generated.stages, repeated.stages, "generation must be deterministic for unchanged PoB state")
		local job = assert(Progression.Start(build, generated.stages, "generated-progression-test"))
		while job.status == "running" do Progression.Step(job, build) end
		local summary = Progression.Summary(job)
		assert.are.equal("completed", summary.status)
		assert.is_true(summary.exactEngine)
		assert.are.equal("not_certified", summary.campaignAudit.status,
			"exact PoB stage success must not imply that campaign acquisition was certified")
		for index, stageResult in ipairs(summary.results) do
			assert.is_true(stageResult.exactEngine)
			assert.are.equal("not_certified", stageResult.campaignAudit.status)
			assert.are.equal("legality_and_metrics_only", stageResult.campaignAudit.exactPoBScope)
			assert.is_true(stageResult.passivePoints.used <= stageResult.passivePoints.limit)
			assert.are.equal(generated.checkpoints[index].act, stageResult.passivePoints.act)
			assert.are.equal(generated.checkpoints[index].actLabel, stageResult.passivePoints.actLabel)
			assert.are.equal(generated.checkpoints[index].plannedMainTreePoints, stageResult.passivePoints.used)
		end
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "campaign generation and exact evaluation must preserve the active build")
	end)

	it("rebuilds all four level checkpoints from a selected native class root before exact evaluation", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local options = assert(Progression.ListOptions(build))
		local stages = stagesFor(build, options)
		local selectedClassId = build.spec.tree.classNameMap.Witch
		assert.is_truthy(selectedClassId)
		assert.are_not.equal(build.spec.curClassId, selectedClassId)
		local class = build.spec.tree.classes[selectedClassId]
		local start = build.spec.nodes[class.startNodeId]
		local addNodeId
		for _, node in ipairs(start.linked or { }) do
			if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then addNodeId = node.id break end
		end
		assert.is_truthy(addNodeId, "selected PoB class root must have a native allocatable neighbor")
		stages[1].addNodeIds = { addNodeId }
		assert.is_true(Progression.ValidateStages(build, stages, selectedClassId))
		local invalidClass, classError = Progression.ValidateStages(build, stages, 2147483647)
		assert.is_false(invalidClass)
		assert.is_truthy(classError:find("native PoB classes", 1, true))
		local sourceSignature = Candidate.BuildSignature(build)
		local invalidRequest, invalidError = MCPBridge:CallLocal("progression_start", { stages = stages, baseClassId = 0 })
		assert.is_nil(invalidRequest)
		assert.is_truthy(invalidError:find("positive integer", 1, true))
		local started = assert(MCPBridge:CallLocal("progression_start", { stages = stages, baseClassId = selectedClassId }))
		assert.are.equal("running", started.status)
		for expectedCompleted = 1, 4 do
			MCPBridge:StepProgressionJobs()
			local progress = assert(MCPBridge:CallLocal("progression_status", { jobId = started.jobId }))
			assert.are.equal(expectedCompleted, progress.completedStages)
		end
		local summary = assert(MCPBridge:CallLocal("progression_status", { jobId = started.jobId }))
		assert.are.equal("completed", summary.status)
		assert.are.equal(selectedClassId, summary.baseClassId)
		assert.is_true(summary.exactEngine)
		assert.are.equal(selectedClassId, summary.results[1].loadout.classId)
		assert.are.equal(addNodeId, summary.results[1].loadout.treeAddedNodeIds[1])
		for _, result in ipairs(summary.results) do assert.are.equal(selectedClassId, result.loadout.classId) end
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "generated stage roots must not mutate the active PoB build")
	end)

	it("calculates each selected stage through PoB and leaves the active build unchanged", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local options = assert(MCPBridge:CallLocal("progression_options", { }))
		local stages = stagesFor(build, options)
		local signature = Candidate.BuildSignature(build)
		local job = assert(MCPBridge:CallLocal("progression_start", { stages = stages }))
		assert.are.equal("running", job.status)
		assert.are.equal(0, #job.results)
		for expectedCompleted = 1, 4 do
			MCPBridge:StepProgressionJobs()
			local progress = assert(MCPBridge:CallLocal("progression_status", { jobId = job.jobId }))
			assert.are.equal(expectedCompleted, progress.completedStages)
		end
		local summary = assert(MCPBridge:CallLocal("progression_status", { jobId = job.jobId }))
		assert.are.equal("completed", summary.status)
		assert.are.equal(4, summary.completedStages)
		assert.is_true(summary.exactEngine)
		for index, level in ipairs({ 12, 28, 68, 90 }) do
			local result = summary.results[index]
			assert.are.equal(level, result.level)
			assert.is_true(result.exactEngine)
			assert.is_true(result.passivePoints.used <= result.passivePoints.limit)
			assert.is_true(result.legal)
			assert.are.equal(stages[index].treeSpecIndex, result.loadout.treeSpecIndex)
			assert.are.equal(stages[index].itemSetId, result.loadout.itemSetId)
			assert.are.equal(stages[index].skillSetId, result.loadout.skillSetId)
			assert.are.equal(stages[index].configSetId, result.loadout.configSetId)
			assert.are.equal(stages[index].mainSkillIndex, result.loadout.mainSkillIndex)
		end
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("compares bounded campaign routes through exact PoB per stage and never delivers a fallback", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local options = assert(Progression.ListOptions(build))
		local baselineStages = stagesFor(build, options)
		local alternateStages = stagesFor(build, options)
		local classStart = build.spec.nodes[build.spec.curClass.startNodeId]
		local routeNodeId
		for _, node in ipairs(classStart.linked or { }) do
			if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not build.spec.allocNodes[node.id] then
				routeNodeId = node.id
				break
			end
		end
		assert.is_truthy(routeNodeId, "The native class start must expose a legal route alternative")
		alternateStages[4].addNodeIds = { routeNodeId }
		local plans = {
			{ label = "BFS baseline", stages = baselineStages },
			{ label = "One-point route", stages = alternateStages },
		}
		assert.is_true(Progression.ValidatePlans(build, plans, "CombinedDPS"))
		local duplicate = {
			{ label = "Same", stages = baselineStages },
			{ label = " same ", stages = alternateStages },
		}
		local duplicateValid, duplicateError = Progression.ValidatePlans(build, duplicate, "CombinedDPS")
		assert.is_false(duplicateValid)
		assert.is_truthy(duplicateError:find("labels must be unique", 1, true))
		local invalidObjective, objectiveError = Progression.ValidatePlans(build, plans, "PassivePoints")
		assert.is_false(invalidObjective)
		assert.is_truthy(objectiveError:find("supported PoB optimizer objective", 1, true))

		local before = Candidate.BuildSignature(build)
		local started, startError = MCPBridge:CallLocal("progression_compare", {
			plans = plans, objective = "CombinedDPS",
		})
		assert.is_truthy(started, startError)
		assert.are.equal("comparison", MCPBridge.progressionJobs[started.jobId].kind)
		assert.are.equal("running", started.status)
		assert.are.equal("not_certified", started.campaignAudit.status)
		assert.is_false(started.candidateDelivered)
		for expectedCompleted = 1, 8 do
			MCPBridge:StepProgressionJobs()
			local progress = assert(MCPBridge:CallLocal("progression_status", { jobId = started.jobId }))
			if expectedCompleted == 4 then
				assert.are.equal(2, progress.progress.currentPlan,
					"the comparison must finish the first route before calculating the second")
				assert.are.equal(1, progress.progress.completedPlans)
			end
		end
		local summary = assert(MCPBridge:CallLocal("progression_status", { jobId = started.jobId }))
		assert.are.equal("completed", summary.status)
		assert.are.equal("campaign_route_comparison", summary.kind)
		assert.is_true(summary.exactEngine)
		assert.are.equal("BFS baseline", summary.comparisonReference)
		assert.are.equal(2, #summary.alternatives)
		assert.are.equal(2, #summary.ranking)
		assert.is_false(summary.candidateDelivered)
		if summary.bestEnginePassingPlan then
			assert.is_true(summary.bestEnginePassingPlan == "BFS baseline" or summary.bestEnginePassingPlan == "One-point route")
		end
		for _, plan in ipairs(summary.alternatives) do
			assert.is_true(plan.exactEngine)
			assert.are.equal(4, #plan.stages)
			assert.are.equal("not_certified", plan.campaignAudit.status)
			for index, result in ipairs(plan.stages) do
				assert.is_true(result.exactEngine)
				assert.is_true(result.passivePoints.used <= result.passivePoints.limit)
				assert.is_true(type(plan.objectiveValuesByStage[index]) == "number")
			end
		end
		local baselinePlan, alternatePlan = summary.alternatives[1], summary.alternatives[2]
		assert.are.equal(0, baselinePlan.objectiveDeltasFromReference[1] or 0)
		assert.are.equal(
			alternatePlan.objectiveValuesByStage[4] - baselinePlan.objectiveValuesByStage[4],
			alternatePlan.objectiveDeltasFromReference[4])
		assert.are.equal(before, Candidate.BuildSignature(build), "Exact campaign comparison must preserve the source build")

		local cancelled = assert(MCPBridge:CallLocal("progression_compare", {
			plans = plans, objective = "CombinedDPS",
		}))
		MCPBridge:StepProgressionJobs()
		assert.is_truthy(MCPBridge:CallLocal("progression_cancel", { jobId = cancelled.jobId }))
		MCPBridge:StepProgressionJobs()
		local cancelSummary = assert(MCPBridge:CallLocal("progression_status", { jobId = cancelled.jobId }))
		assert.are.equal("cancelled", cancelSummary.status)
		assert.are.equal("cancelled", cancelSummary.alternatives[1].status,
			"Cancelling a comparison must release its active child progression job")
		assert.is_false(cancelSummary.exactEngine)
		assert.are.equal(before, Candidate.BuildSignature(build))

		local stale = assert(MCPBridge:CallLocal("progression_compare", {
			plans = plans, objective = "CombinedDPS",
		}))
		Progression.Step(MCPBridge.progressionJobs[stale.jobId], { })
		local staleSummary = assert(MCPBridge:CallLocal("progression_status", { jobId = stale.jobId }))
		assert.are.equal("stale_build", staleSummary.status)
		assert.are.equal("stale_build", staleSummary.alternatives[1].status,
			"A stale source build must also close its active child job")
		assert.is_false(staleSummary.candidateDelivered)
		assert.are.equal(before, Candidate.BuildSignature(build))
	end)

	it("exactly recalculates isolated stage tree and gem proposals and rejects failed stage gates", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local options = assert(Progression.ListOptions(build))
		local stages = stagesFor(build, options)
		local gem = build.skillsTab.socketGroupList[1].gemList[1]
		local gemId = gem.gemData and gem.gemData.id
		assert.is_truthy(type(gemId) == "string" and gemId ~= "")
		local classStart = build.spec.nodes[build.spec.curClass.startNodeId]
		local nodeId
		for _, node in ipairs(classStart.linked or { }) do
			if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not build.spec.allocNodes[node.id] then
				nodeId = node.id
				break
			end
		end
		assert.is_truthy(nodeId, "The fixture class start must have an available native neighbor")
		stages[1].addNodeIds = { nodeId }
		stages[1].gemVariants = { { groupIndex = 1, gemIndex = 1, gemId = gemId, level = gem.level or 1, quality = 20 } }
		local signature = Candidate.BuildSignature(build)
		local proposal = assert(Progression.Start(build, stages, "progression-proposal-test"))
		while proposal.status == "running" do Progression.Step(proposal, build) end
		local proposed = Progression.Summary(proposal)
		local first = proposed.results[1]
		assert.are.equal("completed", proposed.status)
		assert.is_true(proposed.exactEngine)
		assert.are.equal("failed", first.status)
		assert.are.equal("violated", first.activitySustain.status)
		assert.is_truthy(first.violations[1].reason:find("recurring activity cost", 1, true))
		assert.are.equal(nodeId, first.loadout.treeAddedNodeIds[1])
		assert.are.equal(gemId, first.loadout.gemChanges[1].gemId)
		assert.are.equal(20, first.loadout.gemChanges[1].quality)
		assert.are.equal(signature, Candidate.BuildSignature(build))

		stages[1].addNodeIds = nil
		stages[1].gemVariants = nil
		stages[1].hardConstraints = { { key = "TotalEHP", value = 1e30 } }
		stages[1].conversion = { route = { "Fire", "Cold" }, minimumPercent = 100 }
		stages[1].requiredTriggerRate = 1000
		local gated = assert(Progression.Start(build, stages, "progression-hard-gate-test"))
		while gated.status == "running" do Progression.Step(gated, build) end
		local gatedFirst = Progression.Summary(gated).results[1]
		assert.are.equal("failed", gatedFirst.status)
		assert.is_true(#gatedFirst.hardConstraints.violations > 0)
		assert.is_false(gatedFirst.conversion.satisfied)
		assert.is_true(gatedFirst.serverBreakpoint.status == "violated" or gatedFirst.serverBreakpoint.status == "unsupported")
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("cancels between stage calculations and invalidates a job when a selected loadout changes", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].mainActiveSkill = 1
		build.calcsTab:BuildOutput()
		local options = assert(Progression.ListOptions(build))
		local stages = stagesFor(build, options)
		local cancelled = assert(Progression.Start(build, stages, "progression-cancel-test"))
		Progression.Step(cancelled, build)
		assert.are.equal(1, #cancelled.results)
		assert.is_true(Progression.Cancel(cancelled))
		Progression.Step(cancelled, build)
		assert.are.equal("cancelled", cancelled.status)
		assert.are.equal(1, #cancelled.results)

		local stale = assert(Progression.Start(build, stages, "progression-stale-test"))
		build.configTab.configSets[stages[1].configSetId].input.__progressionMutation = true
		Progression.Step(stale, build)
		build.configTab.configSets[stages[1].configSetId].input.__progressionMutation = nil
		assert.are.equal("stale_build", stale.status)
		assert.are.equal(0, #stale.results)
		assert.is_false(Progression.Summary(stale).exactEngine)
		local failedCalculation = Progression.Summary({
			jobId = "progression-calculation-error-test", status = "failed", stages = { { }, { }, { }, { } },
			results = { { exactEngine = true }, { exactEngine = false }, { exactEngine = true }, { exactEngine = true } },
		})
		assert.is_false(failedCalculation.exactEngine)
	end)
end)
