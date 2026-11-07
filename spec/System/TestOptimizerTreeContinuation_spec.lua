local Inputs = require("Modules.Optimizer.Inputs")
local Candidate = require("Modules.Optimizer.Candidate")
local SkillSeed = require("Modules.Optimizer.SkillSeed")
local PhantomSim = require("Modules.Optimizer.PhantomSim")

local function runJob(build, matrix)
	local inputs, inputError = Inputs.Parse(matrix)
	assert.is_truthy(inputs, inputError)
	local job = PhantomSim.RunPhantomSim(build, inputs, { cancelled = false })
	local steps = 0
	while job.status == "running" and steps < 20000 do
		job:Step()
		steps = steps + 1
	end
	assert.are_not.equal("running", job.status, "bounded tree continuation must finish")
	local result = job.result or { }
	local coverage = result.searchCoverage or { }
	local phase = coverage.phase or { }
	local detail = table.concat({
		"status=" .. tostring(job.status),
		"message=" .. tostring(job.error or result.message or "none"),
		"exact=" .. tostring(result.evaluations or 0),
		"generated=" .. tostring(phase.generatedCandidates or 0),
		"retained=" .. tostring(phase.retainedCandidates or 0),
		"bestDeficit=" .. tostring(result.bestObservedDeficit or "none"),
	}, "; ")
	assert.are.equal("feasible", job.status, detail)
	return job.result, steps
end

describe("Optimizer applied partial-tree continuation", function()
	it("applies a different explicitly selected guided gem together with its exact tree route", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local witchId = assert(build.spec.tree.classNameMap.Witch)
		local seed, seedError = SkillSeed.Create(build,
			"Metadata/Items/Gems/SkillGemFireball", witchId)
		assert.is_truthy(seed, seedError)
		local activeGroupSeed, activeGroupError = SkillSeed.Create(build,
			"Metadata/Items/Gems/SkillGemFireball", witchId)
		assert.is_truthy(activeGroupSeed, activeGroupError)
		assert.are_not.equal(seed.groupIndex, activeGroupSeed.groupIndex)
		build.skillsTab.socketGroupList[seed.groupIndex].includeInFullDPS = true
		build.skillsTab.socketGroupList[activeGroupSeed.groupIndex].includeInFullDPS = false
		build.calcsTab:BuildOutput()

		local sourceSignature = Candidate.BuildSignature(build)
		local result = runJob(build, {
			generationPhase = "tree", baseClassId = tostring(witchId), objectiveMetric = "TotalEHP",
			targetSkillGroupIndex = tostring(seed.groupIndex), targetSkillIndex = "1",
			targetSkillGemId = "Metadata/Items/Gems/SkillGemPortal", damageFocus = "Fire",
			maxAddedPoints = "2", maxTotalPoints = "111", evaluationBudget = "48", seed = "23102026",
		})
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
			"search must preserve the active build before explicit Apply")

		local routeCandidate
		for _, candidate in ipairs(result.paretoFront or { }) do
			local selectedSkill = false
			for _, variant in ipairs(candidate.gemVariants or { }) do
				if variant.kind == "selected_main_skill"
					and variant.groupIndex == seed.groupIndex
					and variant.gemId == "Metadata/Items/Gems/SkillGemPortal" then
					selectedSkill = true
				end
			end
			if selectedSkill and #(candidate.nodeIds or { }) > 0 then routeCandidate = candidate break end
		end
		assert.is_truthy(routeCandidate,
			"tree finalists must carry the chosen Main Skill and at least one connected passive route")
		assert.is_true(routeCandidate.selectedMainSkillContext)
		assert.is_true(routeCandidate.unlinkedMainSkillPlan,
			"an unlinked skill group must remain explicitly identified as a planning seed")
		local selectedContextCount = result.searchCoverage.phase.selectedMainSkillContextCandidates
		assert.is_true(selectedContextCount > 0,
			"tree phase coverage must identify selected-skill context candidates separately from gem search")

		local applied, applyError = Candidate.Apply(build, routeCandidate)
		assert.is_true(applied, applyError)
		assert.are.equal(seed.groupIndex, build.mainSocketGroup,
			"the applied native skill-set variation must select the skill used for the exact route calculation")
		local activeGroup = build.skillsTab.socketGroupList[seed.groupIndex]
		assert.are.equal("Metadata/Items/Gems/SkillGemPortal", activeGroup.gemList[1].gemId)
		build.calcsTab:BuildOutput()
		assert.are.equal(routeCandidate.evaluation.metrics.CombinedDPS, build.calcsTab.mainOutput.CombinedDPS,
			"ordinary PoB output after Apply must reproduce the exact Main Skill calculation")
		print("QA_CASE " .. require("dkjson").encode({
			fixture = "selected-main-skill-context-applied-with-tree-route",
			selectedGemId = activeGroup.gemList[1].gemId,
			selectedGroupIndex = build.mainSocketGroup,
			routeNodeCount = #routeCandidate.nodeIds,
			contextCandidates = selectedContextCount,
			exactCandidateCombinedDPS = routeCandidate.evaluation.metrics.CombinedDPS,
			postApplyCombinedDPS = build.calcsTab.mainOutput.CombinedDPS,
			sourcePreservedDuringSearch = true,
			exactApplyParity = routeCandidate.evaluation.metrics.CombinedDPS == build.calcsTab.mainOutput.CombinedDPS,
		}))
	end)

	it("extends the applied tree through exact one-point potential to PoB's 111-point limit", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local witchId = assert(build.spec.tree.classNameMap.Witch)
		local necromancerId, requiredNodeId
		for id, class in pairs(build.spec.tree.classes[witchId].classes) do
			if class.name == "Necromancer" or class.id == "Necromancer" then necromancerId = id end
		end
		for id, node in pairs(build.spec.nodes) do
			if node.ascendancyName == "Necromancer" and node.name == "Mindless Aggression" then requiredNodeId = id end
		end
		assert.is_truthy(necromancerId)
		assert.is_truthy(requiredNodeId)
		local seed, seedError = SkillSeed.Create(build, "Metadata/Items/Gems/SkillGemFireball", witchId)
		assert.is_truthy(seed, seedError)
		build.skillsTab.socketGroupList[seed.groupIndex].includeInFullDPS = true
		build.calcsTab:BuildOutput()

		local first, firstSteps = runJob(build, {
			generationPhase = "tree", baseClassId = tostring(witchId), ascendancyId = tostring(necromancerId),
			requiredNodeIds = tostring(requiredNodeId), objectiveMetric = "FullDPS", damageFocus = "Fire",
			targetSkillGroupIndex = tostring(seed.groupIndex), targetSkillIndex = tostring(seed.skillIndex),
			targetSkillGemId = "Metadata/Items/Gems/SkillGemFireball", maxAddedPoints = "111",
			maxTotalPoints = "111", evaluationBudget = "32", seed = "21102026",
		})
		assert.is_true(first.evaluation.passivePointsUsed < 111,
			"the controlled fresh-tree search should leave room for a continuation stage")
		local firstPoints = first.evaluation.passivePointsUsed
		local originalSignature = Candidate.BuildSignature(build)
		local applied, applyError = Candidate.Apply(build, first.candidate)
		assert.is_true(applied, applyError)
		build.calcsTab:BuildOutput()
		local extensionSourceSignature = Candidate.BuildSignature(build)
		assert.are.equal(first.candidate.sourceSignature, originalSignature)
		assert.are.equal(firstPoints, first.evaluation.passivePointsUsed)

		local extension, extensionSteps = runJob(build, {
			generationPhase = "combined", objectiveMetric = "FullDPS", damageFocus = "Fire",
			maxAddedPoints = tostring(111 - firstPoints), maxTotalPoints = "111",
			evaluationBudget = "32", seed = "21102027",
			searchStoredItems = "false", searchSyntheticGear = "false",
		})
		assert.are.equal(extensionSourceSignature, Candidate.BuildSignature(build),
			"The exact extension experiment must preserve the applied partial-tree source")
		assert.is_true(extension.evaluation.passivePointsUsed > firstPoints,
			"Combined search must continue from the applied tree instead of rebuilding from class root")
		assert.is_true(extension.evaluation.passivePointsUsed < 111,
			"the one-point review should still have a legal point available")
		assert.is_true(extension.evaluation.metrics.FullDPS > first.evaluation.metrics.FullDPS,
			"the exact continuation should improve the configured FullDPS objective")
		local extendedApplied, extensionApplyError = Candidate.Apply(build, extension.candidate)
		assert.is_true(extendedApplied, extensionApplyError)
		build.calcsTab:BuildOutput()
		local nodePotentialSourceSignature = Candidate.BuildSignature(build)
		local nodeInputs, nodeInputError = Inputs.Parse({
			generationPhase = "combined", nodePotentialAnalysis = "true", objectiveMetric = "FullDPS",
			damageFocus = "Fire", maxAddedPoints = "1", maxTotalPoints = "111",
			evaluationBudget = "80", seed = "21102029",
		})
		assert.is_truthy(nodeInputs, nodeInputError)
		local nodeJob = PhantomSim.RunPhantomSim(build, nodeInputs, { cancelled = false })
		local nodeSteps = 0
		while nodeJob.status == "running" and nodeSteps < 20000 do
			nodeJob:Step()
			nodeSteps = nodeSteps + 1
		end
		assert.are.equal("node_potential_complete", nodeJob.status, nodeJob.error or "one-point node review must finish")
		assert.are.equal(nodePotentialSourceSignature, Candidate.BuildSignature(build),
			"one-point potential review must preserve the applied continuation source")
		assert.are.equal(extension.evaluation.metrics.FullDPS, nodeJob.result.baselineMetrics.FullDPS,
			"node potential must use the exact applied-continuation calculation as its baseline")
		local bestSinglePoint
		for _, entry in ipairs(nodeJob.result.results or { }) do
			if entry.exactCalculated and entry.feasible and entry.pointsAdded > 0
				and (not bestSinglePoint or entry.metrics.FullDPS > bestSinglePoint.metrics.FullDPS) then
				bestSinglePoint = entry
			end
		end
		assert.is_truthy(bestSinglePoint, "the native exact node review must evaluate at least one one-point addition")
		assert.are.equal(1, bestSinglePoint.pointsAdded)
		local targetId = assert(bestSinglePoint.nodeIds[1])
		local targeted, targetedSteps = runJob(build, {
			generationPhase = "combined", objectiveMetric = "FullDPS", damageFocus = "Fire",
			targetNodeIds = tostring(targetId), maxAddedPoints = "1", maxTotalPoints = "111",
			evaluationBudget = "24", seed = "21102030",
			searchStoredItems = "false", searchSyntheticGear = "false",
		})
		assert.are.equal(targetId, targeted.candidate.nodeIds[1], "the exact target run must retain the best one-point passive")
		assert.are.equal(111, targeted.evaluation.passivePointsUsed)
		assert.are.equal(bestSinglePoint.metrics.FullDPS, targeted.evaluation.metrics.FullDPS,
			"the selected one-point target must reproduce the exact node-potential cell")
		assert.is_true(targeted.evaluation.metrics.FullDPS > nodeJob.result.baselineMetrics.FullDPS)
		local finalApplied, finalApplyError = Candidate.Apply(build, targeted.candidate)
		assert.is_true(finalApplied, finalApplyError)
		build.calcsTab:BuildOutput()
		assert.are.equal(targeted.evaluation.metrics.FullDPS, build.calcsTab.mainOutput.FullDPS,
			"the fully extended tree must reproduce the exact PoB result after isolated Apply")
		print("QA_CASE " .. require("dkjson").encode({
			fixture = "witch-necromancer-fireball-applied-tree-extension",
			initialPoints = firstPoints,
			initialDPS = first.evaluation.metrics.FullDPS,
			initialSteps = firstSteps,
			extendedPoints = extension.evaluation.passivePointsUsed,
			extendedDPS = extension.evaluation.metrics.FullDPS,
			extensionSteps = extensionSteps,
			exactOnePointEvaluations = nodeJob.result.exactRouteEvaluations,
			onePointBaselineDPS = nodeJob.result.baselineMetrics.FullDPS,
			bestOnePointDPS = bestSinglePoint.metrics.FullDPS,
			bestOnePointDelta = bestSinglePoint.metrics.FullDPS - nodeJob.result.baselineMetrics.FullDPS,
			bestOnePointLabel = bestSinglePoint.label,
			bestOnePointIds = bestSinglePoint.nodeIds,
			onePointSteps = nodeSteps,
			appliedTreePoints = targeted.evaluation.passivePointsUsed,
			appliedTreeFullDPS = build.calcsTab.mainOutput.FullDPS,
			targetedExactEvaluations = targeted.evaluations,
			targetedSteps = targetedSteps,
			progressiveCoverage = extension.searchCoverage.zones,
			phaseCoverage = extension.searchCoverage.phase,
			interpretation = "staged_exact_tree_continuation_not_global_optimum_proof",
		}))
	end)
end)
