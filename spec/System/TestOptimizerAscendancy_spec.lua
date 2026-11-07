local Inputs = require("Modules.Optimizer.Inputs")
local Candidate = require("Modules.Optimizer.Candidate")
local TreeSearch = require("Modules.Optimizer.TreeSearch")
local AscendancySearch = require("Modules.Optimizer.AscendancySearch")
local Anoints = require("Modules.Optimizer.Anoints")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local Calcs = require("Modules.Calcs")
local Scenario = require("Modules.Optimizer.Scenario")
local json = require("dkjson")

describe("Optimizer automatic main-ascendancy search", function()
	it("round-robins PoB-native ascendancy routes and enforces the separate eight-point budget", function()
		newBuild()
		local signature = Candidate.BuildSignature(build)
		local classId = build.spec.curClassId
		local candidates, coverage = AscendancySearch.BuildCandidates(build, classId, 100)
		assert.is_true(#coverage.availableAscendancies > 0)
		assert.is_true(#candidates >= #coverage.availableAscendancies)
		local seenAscendancies = { }
		local parsed = assert(Inputs.Parse({ }))
		for _, candidate in ipairs(candidates) do
			local variant = candidate.ascendancyVariant
			assert.is_truthy(variant)
			seenAscendancies[variant.ascendClassId] = true
			local specProxy, err = Candidate.BuildPassiveSpec(build, candidate.nodeIds, { }, {
				ascendancyVariant = variant,
			})
			assert.is_truthy(specProxy, err)
			local mainPoints, ascendancyPoints = specProxy:CountAllocNodes()
			assert.is_true(mainPoints <= 120)
			assert.is_true(ascendancyPoints > 0 and ascendancyPoints <= 8)
			local valid, reason = TreeSearch.ValidateCandidate(
				build.spec,
				candidate.nodeIds,
				parsed,
				TreeSearch.BuildRegionMap(build.spec),
				{ },
				specProxy
			)
			assert.is_true(valid, reason)
			for _, nodeId in ipairs(specProxy.optimizerAddedNodeIds or { }) do
				local node = specProxy.nodes[nodeId]
				assert.is_true(node.type ~= "ClassStart" and node.type ~= "AscendClassStart")
			end
		end
		for _, ascendancy in ipairs(coverage.availableAscendancies) do
			assert.is_true(seenAscendancies[ascendancy.ascendClassId], "every selectable ascendancy needs an initial candidate")
		end
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("rebuilds a different selected base class and ascendancy without using the active class start", function()
		newBuild()
		local selectedClassId = build.spec.tree.classNameMap.Witch
		assert.is_truthy(selectedClassId)
		local candidates, coverage = AscendancySearch.BuildCandidates(build, selectedClassId, 12)
		assert.is_true(#coverage.availableAscendancies > 0)
		assert.is_true(#candidates > 0)
		local candidate = candidates[1]
		local specProxy, err = Candidate.BuildPassiveSpec(build, candidate.nodeIds, { }, {
			classId = selectedClassId,
			ascendancyVariant = candidate.ascendancyVariant,
		})
		assert.is_truthy(specProxy, err)
		assert.are.equal(selectedClassId, specProxy.curClassId)
		assert.are.equal(candidate.ascendancyVariant.ascendClassId, specProxy.curAscendClassId)
		local valid, reason = TreeSearch.ValidateCandidate(
			specProxy,
			candidate.nodeIds,
			assert(Inputs.Parse({ })),
			TreeSearch.BuildRegionMap(specProxy),
			{ },
			specProxy
		)
		assert.is_true(valid, reason)
		for _, nodeId in ipairs(specProxy.optimizerAddedNodeIds or { }) do
			local node = specProxy.nodes[nodeId]
			assert.is_true(node.type ~= "ClassStart" and node.type ~= "AscendClassStart")
		end
	end)

	it("limits Route Planner ascendancy candidates to the loaded main ascendancy and Bloodline", function()
		newBuild()
		local tree = build.spec.tree
		local classId = assert(tree.classNameMap.Witch)
		build.spec:SelectClass(classId)
		local unascended, unascendedCoverage = AscendancySearch.BuildCandidates(
			build, classId, 12, nil, nil, 0, nil, 0)
		assert.are.equal(0, #unascended, "an unascended seed must not be given an implicit ascendancy")
		assert.are.equal("preserved_no_ascendancy", unascendedCoverage.status)
		local mainAscendancyId
		for id, ascendancy in pairs(tree.classes[classId].classes or { }) do
			if id > 0 and ascendancy.startNodeId then mainAscendancyId = id break end
		end
		assert.is_truthy(mainAscendancyId, "fixture Witch class needs a native ascendancy")
		build.spec:SelectAscendClass(mainAscendancyId)

		local function assertConstrainedCandidates(secondaryAscendancyId)
			local candidates, coverage = AscendancySearch.BuildCandidates(
				build, classId, 12, nil, nil, mainAscendancyId, nil, secondaryAscendancyId)
			assert.is_true(#candidates > 0, "the selected ascendancy should still produce legal route choices")
			for _, candidate in ipairs(candidates) do
				assert.are.equal(mainAscendancyId, candidate.ascendancyVariant.ascendClassId,
					"route generation must not switch the selected main ascendancy")
				assert.are.equal(secondaryAscendancyId, candidate.ascendancyVariant.secondaryAscendClassId,
					"route generation must not add or replace a Bloodline implicitly")
			end
			assert.are.equal(1, #coverage.availableAscendancies,
				"coverage should list only the selected main ascendancy for a constrained search")
			for _, secondary in ipairs(coverage.availableSecondaryAscendancies or { }) do
				assert.are.equal(secondaryAscendancyId, secondary.ascendClassId,
					"coverage must describe only the exact Bloodline selection")
			end
		end

		assertConstrainedCandidates(0)
		local bloodlineId
		for id, bloodline in pairs(tree.alternate_ascendancies or { }) do
			if id > 0 and bloodline.startNodeId then bloodlineId = id break end
		end
		assert.is_truthy(bloodlineId, "the current tree should expose at least one native secondary ascendancy")
		build.spec:SelectSecondaryAscendClass(bloodlineId)
		assertConstrainedCandidates(bloodlineId)
	end)

	it("preserves a selected secondary Bloodline start when cloning an exact passive candidate", function()
		newBuild()
		local tree = build.spec.tree
		local classId = tree.classNameMap.Witch
		assert.is_truthy(tree.alternate_ascendancies, "the current PoE tree must provide native secondary Bloodlines")
		local mainAscendancyId, bloodlineId, bloodline
		for id, ascendancy in pairs(tree.classes[classId].classes) do
			if ascendancy.name == "Elementalist" or ascendancy.id == "Elementalist" then
				mainAscendancyId = id
				break
			end
		end
		for id, candidateBloodline in pairs(tree.alternate_ascendancies) do
			if candidateBloodline.name == "Lycia Bloodline" or candidateBloodline.id == "Lycia" then
				bloodlineId, bloodline = id, candidateBloodline
				break
			end
		end
		assert.is_truthy(mainAscendancyId)
		assert.is_truthy(bloodlineId)

		build.spec:SelectClass(classId)
		build.spec:SelectAscendClass(mainAscendancyId)
		build.spec:SelectSecondaryAscendClass(bloodlineId)
		local undoState = build.spec:CreateUndoState()
		assert.are.equal(bloodlineId, undoState.secondaryAscendClassId,
			"undo state must capture the selected secondary ascendancy ID")

		local classStart = tree.classes[classId].startNodeId
		local addedNodeId
		for _, node in ipairs(build.spec.nodes[classStart].linked or { }) do
			if node.path and (node.type == "Normal" or node.type == "Notable") then
				addedNodeId = node.id
				break
			end
		end
		assert.is_truthy(addedNodeId, "fixture class start must expose a legal connected passive")
		local proxy, proxyError = Candidate.BuildPassiveSpec(build, { addedNodeId }, { })
		assert.is_truthy(proxy, proxyError)
		assert.are.equal(bloodlineId, proxy.curSecondaryAscendClassId)
		assert.is_truthy(proxy.allocNodes[bloodline.startNodeId], "the selected Bloodline start must remain allocated")
		local valid, reason = TreeSearch.ValidateCandidate(
			build.spec,
			proxy.optimizerAddedNodeIds,
			assert(Inputs.Parse({ })),
			TreeSearch.BuildRegionMap(build.spec),
			proxy.optimizerRemovedNodeIds,
			proxy
		)
		assert.is_true(valid, reason)
	end)

	it("runs a tree foundation from the selected native root, including the current class, and excludes other phases", function()
		newBuild()
		local sourceSpec = build.spec
		local sourceSignature = Candidate.BuildSignature(build)
		local classId = build.spec.curClassId
		local parsed = assert(Inputs.Parse({
			generationPhase = "tree",
			baseClassId = tostring(classId),
			objectiveMetric = "TotalEHP",
			evaluationBudget = "12",
			maxAddedPoints = "2",
			maxTotalPoints = "120",
		}))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 5000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "tree foundation should finish; last phase: " .. tostring(job.progress and job.progress.phase))
		assert.is_true(status ~= "error", result and result.message or job.error)
		local firstViolation = result and result.bestObservedViolations and result.bestObservedViolations[1]
		assert.are.equal("feasible", status, firstViolation and (firstViolation.label .. ": " .. tostring(firstViolation.reason)) or result and result.message)
		assert.are.equal("tree", result.generationPhase)
		assert.are.equal(classId, result.candidate.classVariant.classId, "same-class foundation must still reset to its native start")
		assert.are.equal(0, result.searchCoverage.phase.generatedSkillCandidates)
		assert.are.equal(0, result.searchCoverage.phase.generatedEquipmentCandidates)
		assert.are.equal(0, result.searchCoverage.equipment.exactEvaluations)
		assert.is_true(result.searchCoverage.phase.generatedTreeCandidates > 0)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "tree search and exact PoB calculation must not mutate the active build")
		local applied, applyError = Candidate.Apply(build, result.candidate)
		assert.is_true(applied, applyError)
		assert.are.equal(classId, build.spec.curClassId)
		assert.are_not.equal(sourceSpec, build.spec, "apply must create a reversible native tree variation even for the same class")
	end)

	it("keeps the Skills phase on the applied tree and sends only gem variants to exact PoB", function()
		newBuild()
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			generationPhase = "skills",
			objectiveMetric = "TotalEHP",
			evaluationBudget = "8",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
		}))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 5000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "skills-only search should finish; last phase: " .. tostring(job.progress and job.progress.phase))
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.are.equal("skills", result.generationPhase)
		assert.is_true(result.searchCoverage.phase.generatedSkillCandidates > 0, "supported gem variants must reach the bounded candidate list")
		assert.are.equal(0, result.searchCoverage.phase.generatedTreeCandidates)
		assert.are.equal(0, result.searchCoverage.phase.generatedEquipmentCandidates)
		assert.are.equal(result.evaluations, result.searchCoverage.phase.exactEvaluations)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "gem search must preserve the active tree and source build")
	end)

	it("searches native Bloodlines and exact-calculates a combined main and secondary route", function()
		newBuild()
		-- This integration fixture intentionally models an endgame character; the
		-- L1 default now correctly suppresses unavailable Labyrinth routes.
		build.characterLevel = 100
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local tree = build.spec.tree
		local selectedClassId = tree.classNameMap.Witch
		assert.is_truthy(tree.alternate_ascendancies, "the active 3.29 tree should expose native secondary Bloodlines")
		local availableBloodlines = 0
		for _, bloodline in pairs(tree.alternate_ascendancies) do
			if bloodline.startNodeId then availableBloodlines = availableBloodlines + 1 end
		end
		assert.is_true(availableBloodlines > 0)

	local candidates, coverage = AscendancySearch.BuildCandidates(build, selectedClassId, 512)
	assert.are.equal(availableBloodlines, coverage.availableBloodlines)
	assert.is_true(coverage.secondaryAscendancySearched)
	assert.is_true(coverage.secondaryCombinationSearched)
	assert.are.equal(availableBloodlines, coverage.representedBloodlines,
		"a sufficiently large quota must include every available native Bloodline")
	assert.are.equal(coverage.availableCombinations, coverage.representedCombinations,
		"a sufficiently large quota must represent every legal main/Bloodline pair")
	assert.are.equal(#coverage.availableAscendancies, coverage.availableMainAscendancies)
	assert.are.equal(coverage.availableMainAscendancies, coverage.representedMainAscendancies)
	assert.is_true(coverage.availableBloodlineCombinations > 0)
	assert.are.equal(coverage.availableBloodlineCombinations, coverage.representedBloodlineCombinations)
	assert.is_true(coverage.secondaryCombinationSearched)
	local smallQuota = #coverage.availableAscendancies + 2
	local smallCandidates, smallCoverage = AscendancySearch.BuildCandidates(build, selectedClassId, smallQuota)
	local mainsWithBloodlineSeeds = { }
	for _, candidate in ipairs(smallCandidates) do
		if candidate.ascendancyVariant.secondaryAscendClassId > 0 then
			mainsWithBloodlineSeeds[candidate.ascendancyVariant.ascendClassId] = true
		end
	end
	local mainSeedCount = 0
	for _ in pairs(mainsWithBloodlineSeeds) do mainSeedCount = mainSeedCount + 1 end
	assert.is_true(mainSeedCount > 1,
		"a small quota must interleave Bloodline seeds across multiple native main ascendancies")
	assert.is_true(smallCoverage.budgetLimited, "small quota must report that native pairs remain unsearched")

	local parsed = assert(Inputs.Parse({ maxTotalPoints = "120" }))
	local combinedCandidate, projected
	for _, candidate in ipairs(candidates) do
		if candidate.secondaryAscendancyPointCost > 0 and candidate.mainAscendancyPointCost > 0 then
			local specProxy, err = Candidate.BuildPassiveSpec(build, candidate.nodeIds, { }, {
				classId = selectedClassId,
				ascendancyVariant = candidate.ascendancyVariant,
			})
			assert.is_truthy(specProxy, err)
			assert.are.equal(candidate.ascendancyVariant.secondaryAscendClassId, specProxy.curSecondaryAscendClassId)
			local valid, reason = TreeSearch.ValidateCandidate(
				specProxy,
				candidate.nodeIds,
				parsed,
				TreeSearch.BuildRegionMap(specProxy),
				{ },
				specProxy
			)
			assert.is_true(valid, reason)
			local mainPoints, secondaryPoints = 0, 0
			for _, node in pairs(specProxy.allocNodes) do
				if node.type ~= "AscendClassStart" and node.ascendancyName and not node.isMultipleChoiceOption then
					if tree.secondaryAscendNameMap[node.ascendancyName] then
						secondaryPoints = secondaryPoints + 1
					else
						mainPoints = mainPoints + 1
					end
				end
			end
			assert.is_true(mainPoints <= 8 and secondaryPoints <= 8, "each PoB ascendancy has an independent eight-point cap")
			assert.is_true(mainPoints > 0 and secondaryPoints > 0, "the proposal must spend points in both selected branches")
			combinedCandidate, projected = candidate, specProxy
			break
		end
	end
	assert.is_truthy(combinedCandidate, "bounded coverage must include a cross-branch proposal")

	local isolatedBuild = { spec = projected }
	setmetatable(isolatedBuild, { __index = build })
	local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
	local output = exactCalc({ spec = projected }, true)
	assert.is_truthy(output, "combined Bloodline candidate must reach PoB's exact calculator")

	local pipelineInputs = assert(Inputs.Parse({
		evaluationBudget = "40",
		maxTotalPoints = "120",
		baseClassId = tostring(selectedClassId),
	}))
	local job = PhantomSim.RunPhantomSim(build, pipelineInputs, { cancelled = false })
	local status, result = "running", nil
	local sawYieldedAscendancyProgress = false
	for _ = 1, 5000 do
		status, result = job:Step()
		if job.progress and job.progress.phase == "Generating native ascendancy routes" then
			sawYieldedAscendancyProgress = true
		end
		if status ~= "running" then break end
	end
	assert.is_true(status ~= "running", "bounded Witch + Bloodline search should finish; last phase: " .. tostring(job.progress and job.progress.phase))
	assert.is_true(status ~= "error", result and result.message or job.error)
	assert.is_true(sawYieldedAscendancyProgress, "route-root construction must yield progress to the UI coroutine")
	assert.is_true(result.searchCoverage.ascendancies.exactBloodlineEvaluations > 0,
		"at least one Bloodline proposal must reach exact PoB evaluation")
	assert.is_true(result.searchCoverage.ascendancies.exactCombinedEvaluations > 0,
		"at least one main + Bloodline route pair must reach exact PoB evaluation")
	assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "search and exact simulation must leave the source build unchanged")
	end)

	it("builds legal combined Bloodline seeds from all seven native class starts", function()
		newBuild()
		local tree = build.spec.tree
		local classIds = { }
		for classId, class in pairs(tree.classes) do
			if class and class.startNodeId and class.classes then classIds[#classIds + 1] = classId end
		end
		table.sort(classIds)
		assert.are.equal(7, #classIds, "the loaded native tree should expose all seven starting classes")
		local parsed = assert(Inputs.Parse({ maxTotalPoints = "120" }))
		local sourceSignature = Candidate.BuildSignature(build)
		for _, classId in ipairs(classIds) do
			local mainCount = 0
			for ascendClassId, ascendClass in pairs(tree.classes[classId].classes) do
				if type(ascendClassId) == "number" and ascendClassId > 0 and ascendClass and ascendClass.startNodeId then
					mainCount = mainCount + 1
				end
			end
			assert.is_true(mainCount > 0, "each native class must expose a main ascendancy")
			local candidates, coverage = AscendancySearch.BuildCandidates(build, classId, mainCount + 1)
			assert.is_true(coverage.availableBloodlines > 0, "the loaded tree must expose secondary choices")
			assert.is_true(coverage.secondaryCombinationSearched,
				"a quota of one route beyond all primary baselines must seed a combined secondary route")
			local combined
			for _, candidate in ipairs(candidates) do
				if candidate.secondaryAscendancyPointCost > 0 and candidate.mainAscendancyPointCost > 0 then
					combined = candidate
					break
				end
			end
			assert.is_truthy(combined, "each class quota must seed at least one main/Bloodline route")
			local projected, err = Candidate.BuildPassiveSpec(build, combined.nodeIds, { }, {
				classId = classId,
				ascendancyVariant = combined.ascendancyVariant,
			})
			assert.is_truthy(projected, err)
			assert.are.equal(classId, projected.curClassId)
			assert.are.equal(combined.ascendancyVariant.secondaryAscendClassId, projected.curSecondaryAscendClassId)
			local valid, reason = TreeSearch.ValidateCandidate(
				projected,
				combined.nodeIds,
				parsed,
				TreeSearch.BuildRegionMap(projected),
				{ },
				projected
			)
			assert.is_true(valid, reason)
			local mainPoints, secondaryPoints = 0, 0
			for _, node in pairs(projected.allocNodes) do
				if node.type ~= "AscendClassStart" and node.ascendancyName and not node.isMultipleChoiceOption then
					if tree.secondaryAscendNameMap[node.ascendancyName] then
						secondaryPoints = secondaryPoints + 1
					else
						mainPoints = mainPoints + 1
					end
				end
			end
			assert.is_true(mainPoints > 0 and mainPoints <= 8)
			assert.is_true(secondaryPoints > 0 and secondaryPoints <= 8)
		end
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
	end)

	it("adds and removes exact offense and life routes from all seven native class starts", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0 1")
		build.mainSocketGroup = 1
		build.calcsTab:BuildOutput()

		local tree = build.spec.tree
		local classIds = { }
		for classId, class in pairs(tree.classes) do
			if class and class.startNodeId and class.classes then classIds[#classIds + 1] = classId end
		end
		table.sort(classIds)
		assert.are.equal(7, #classIds, "the loaded PoB tree must expose exactly seven native class roots")
		local targets = {
			{ id = 13164, name = "Divine Judgement", metric = "CombinedDPS", kind = "offense" },
			{ id = 61198, name = "Heart of the Warrior", metric = "TotalEHP", kind = "defense" },
		}
		for _, target in ipairs(targets) do
			assert.are.equal(target.name, build.spec.nodes[target.id].dn or build.spec.nodes[target.id].name,
				"the versioned target node must retain its expected PoB identity")
		end

		local sourceSignature = Candidate.BuildSignature(build)
		local function calculate(spec, items)
			local isolatedBuild = { spec = spec, itemsTab = items or build.itemsTab }
			setmetatable(isolatedBuild, { __index = build })
			local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
			local output = exactCalc({ spec = spec }, true)
			assert.is_truthy(output, "class-root and route candidates must reach PoB's exact calculator")
			return output
		end
		local parsedEmpty = assert(Inputs.Parse({ maxTotalPoints = "120", maxAddedPoints = "60" }))
		for _, classId in ipairs(classIds) do
			local rootSpec, rootError, rootItems = Candidate.BuildPassiveSpec(build, { }, { }, { classId = classId })
			assert.is_truthy(rootSpec, rootError)
			local rootBuild = { spec = rootSpec, itemsTab = rootItems }
			setmetatable(rootBuild, { __index = build })
			local rootOutput = calculate(rootSpec, rootItems)
			assert.is_true(type(rootOutput.CombinedDPS) == "number" and rootOutput.CombinedDPS > 0,
				"each native class root must calculate the selected Fireball output")
			assert.is_true(type(rootOutput.TotalEHP) == "number" and rootOutput.TotalEHP > 0,
				"each native class root must calculate exact defenses")

			for _, target in ipairs(targets) do
				local parsedAdd = assert(Inputs.Parse({
					addNodeIds = tostring(target.id),
					maxAddedPoints = "60",
					maxTotalPoints = "120",
					objectiveMetric = "CombinedDPS",
				}))
				local candidates, pathError = TreeSearch.BuildCandidateNodes(rootSpec, parsedAdd, 1, nil, 60)
				assert.is_nil(pathError, "A* must find the " .. target.kind .. " target from class " .. tostring(classId))
				assert.is_true(#candidates > 0, "A* must return a route for class " .. tostring(classId))
				local route = candidates[1]
				local containsTarget = false
				for _, nodeId in ipairs(route.nodeIds) do if nodeId == target.id then containsTarget = true end end
				assert.is_true(containsTarget, "the route must include its requested " .. target.kind .. " node")

				local addedSpec, addError, addedItems = Candidate.BuildPassiveSpec(rootBuild, route.nodeIds, { })
				assert.is_truthy(addedSpec, addError)
				assert.are.equal(classId, addedSpec.curClassId)
				local allocatedStarts = 0
				for nodeId, node in pairs(addedSpec.allocNodes) do
					if node.type == "ClassStart" then
						allocatedStarts = allocatedStarts + 1
						assert.are.equal(tree.classes[classId].startNodeId, nodeId,
							"route must retain only the selected class's native origin")
					end
					assert.is_true(node.connectedToStart ~= false,
						"added " .. target.kind .. " route must remain connected at node " .. tostring(nodeId))
				end
				assert.are.equal(1, allocatedStarts, "a route must never add a second class start")
				assert.is_true(addedSpec:CountAllocNodes() <= 61,
					"the 60-point route budget plus its class origin must remain bounded")
				assert.is_true(TreeSearch.ValidateCandidate(rootSpec, route.nodeIds, parsedAdd, nil, { }, addedSpec),
					"the complete PoB tree validator must accept a connected, point-bounded route")
				local addedOutput = calculate(addedSpec, addedItems)
				assert.is_true(addedOutput[target.metric] > rootOutput[target.metric],
					"the exact " .. target.metric .. " must improve for the selected " .. target.kind .. " route from class " .. tostring(classId))

				local addedBuild = { spec = addedSpec, itemsTab = addedItems }
				setmetatable(addedBuild, { __index = build })
				local removedSpec, removeError, removedItems = Candidate.BuildPassiveSpec(addedBuild, { }, { target.id })
				assert.is_truthy(removedSpec, removeError)
				assert.is_nil(removedSpec.allocNodes[target.id], "removing a target must deallocate it through PoB's native dependency graph")
				for nodeId, node in pairs(removedSpec.allocNodes) do
					assert.is_true(node.connectedToStart ~= false,
						"native removal must not leave a disconnected allocation at node " .. tostring(nodeId))
				end
				assert.is_true(removedSpec:CountAllocNodes() <= addedSpec:CountAllocNodes(),
					"removal must not exceed the source route's point count")
				assert.is_true(TreeSearch.ValidateCandidate(addedSpec, { }, parsedEmpty, nil, { target.id }, removedSpec),
					"the complete PoB validator must accept the connected removal candidate")
				calculate(removedSpec, removedItems)
			end
		end
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
			"all seven classes, both route types, exact calculations, and removals must preserve the active source build")
	end)

	it("applies a verified ascendancy as a separate passive-tree variation", function()
		newBuild()
		local originalSpec = build.spec
		local originalAscendancy = originalSpec.curAscendClassId
		local signature = Candidate.BuildSignature(build)
		local candidates = AscendancySearch.BuildCandidates(build, originalSpec.curClassId, 12)
		assert.is_true(#candidates > 0)
		local proposed = candidates[1]
		local projected, err = Candidate.BuildPassiveSpec(build, proposed.nodeIds, { }, {
			ascendancyVariant = proposed.ascendancyVariant,
		})
		assert.is_truthy(projected, err)
		local verified = {
			feasible = true,
			sourceSignature = signature,
			nodeIds = projected.optimizerAddedNodeIds,
			removeNodeIds = projected.optimizerRemovedNodeIds,
			ascendancyVariant = proposed.ascendancyVariant,
			label = proposed.label,
		}
		local applied, message = Candidate.Apply(build, verified)
		assert.is_true(applied, message)
		assert.is_true(build.spec ~= originalSpec, "the result should be a separate active tree variation")
		assert.is_true(build.spec.curAscendClassId == proposed.ascendancyVariant.ascendClassId)
		assert.is_true(originalSpec.curAscendClassId == originalAscendancy, "the original tree variation must remain unchanged")
		assert.is_true(Candidate.BuildSignature(build) ~= signature, "the newly active variation should update the build signature")
	end)

	it("applies the user's selected base class and a PoB-native ascendancy in one variation", function()
		newBuild()
		local originalSpec = build.spec
		local signature = Candidate.BuildSignature(build)
		local selectedClassId = originalSpec.tree.classNameMap.Witch
		local candidates = AscendancySearch.BuildCandidates(build, selectedClassId, 8)
		assert.is_true(#candidates > 0)
		local proposed = candidates[1]
		local projected, err = Candidate.BuildPassiveSpec(build, proposed.nodeIds, { }, {
			classId = selectedClassId,
			ascendancyVariant = proposed.ascendancyVariant,
		})
		assert.is_truthy(projected, err)
		local applied, message = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = signature,
			classVariant = { classId = selectedClassId },
			ascendancyVariant = proposed.ascendancyVariant,
			nodeIds = projected.optimizerAddedNodeIds,
			removeNodeIds = projected.optimizerRemovedNodeIds,
			label = proposed.label,
		})
		assert.is_true(applied, message)
		assert.is_true(build.spec.curClassId == selectedClassId)
		assert.is_true(build.spec.curAscendClassId == proposed.ascendancyVariant.ascendClassId)
		assert.is_true(originalSpec.curClassId ~= selectedClassId, "the original class-start variation must remain intact")
		assert.is_true(Candidate.BuildSignature(build) ~= signature)
	end)

	it("evaluates native anoint passives exactly and applies them as a reversible item-set variation", function()
		newBuild()
		build.characterLevel = 40
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 12/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		local amulet = new("Item"):Item("Optimizer Anoint Test\nAmber Amulet")
		build.itemsTab:AddItem(amulet, true)
		local sourceSetId = build.itemsTab.activeItemSetId
		build.itemsTab.activeItemSet.Amulet.selItemId = amulet.id
		build.itemsTab.slots.Amulet.selItemId = amulet.id
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.itemsTab:AddUndoState()
		build.calcsTab:BuildOutput()

		local signature = Candidate.BuildSignature(build)
		local candidates = TreeSearch.BuildAnointCandidates(build.spec, 1)
		assert.is_true(#candidates > 0, "the native tree should expose legal recipe notables")
		local proposed = candidates[1]
		local projected, err, isolatedItems = Candidate.BuildPassiveSpec(build, { }, { }, {
			anointVariant = proposed.anointVariant,
		})
		assert.is_truthy(projected, err)
		assert.is_truthy(isolatedItems.items[amulet.id]:BuildRaw():find("Allocates " .. build.spec.nodes[proposed.anointVariant.nodeId].dn, 1, true))
		assert.is_nil(amulet:BuildRaw():find("Allocates " .. build.spec.nodes[proposed.anointVariant.nodeId].dn, 1, true), "phantom evaluation must not alter the source item")

		local isolatedBuild = { spec = projected, itemsTab = isolatedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local output, env = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_truthy(output and output.TotalDPS)
		assert.is_truthy(env and env.grantedPassives[proposed.anointVariant.nodeId], "CalcSetup must resolve the anoint through the native GrantedPassive path")
		assert.are.equal(signature, Candidate.BuildSignature(build))

		local parsed = assert(Inputs.Parse({ evaluationBudget = "8", maxAddedPoints = "0", maxTotalPoints = "120" }))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, searchResult = "running", nil
		local anointReachedExactCalc = false
		for _ = 1, 3000 do
			status, searchResult = job:Step()
			if job.progress and job.progress.phase == "Exact calculations"
				and tostring(job.progress.current):find("Anoint ", 1, true) then
				anointReachedExactCalc = true
			end
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "bounded anoint search should finish; last phase: " .. tostring(job.progress and job.progress.phase))
		assert.is_true(status ~= "error", searchResult and searchResult.message or job.error)
		assert.is_true(anointReachedExactCalc, "at least one generated anoint must reach exact PoB evaluation within budget")
		assert.is_true(searchResult.searchCoverage.anoints.generatedCandidates > 0)
		assert.is_true(searchResult.searchCoverage.anoints.availableCandidates >= searchResult.searchCoverage.anoints.generatedCandidates)
		assert.are.equal(signature, Candidate.BuildSignature(build), "the full phantom search must preserve the equipped source item")

		local originalSpec = build.spec
		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = signature,
			nodeIds = { },
			removeNodeIds = { },
			anointVariant = proposed.anointVariant,
			label = proposed.label,
		})
		assert.is_true(applied, applyError)
		assert.are.equal(originalSpec, build.spec, "an anoint does not fabricate a passive tree allocation")
		assert.are.equal(sourceSetId, build.itemsTab.itemSetOrderList[1])
		assert.are_not.equal(sourceSetId, build.itemsTab.activeItemSetId)
		assert.are.equal(amulet.id, build.itemsTab.itemSets[sourceSetId].Amulet.selItemId, "the original set must keep the original amulet")
		local activeItemId = build.itemsTab.activeItemSet.Amulet.selItemId
		assert.are_not.equal(amulet.id, activeItemId)
		assert.is_truthy(build.itemsTab.items[activeItemId]:BuildRaw():find("Allocates " .. build.spec.nodes[proposed.anointVariant.nodeId].dn, 1, true))
		build.itemsTab:Undo()
		assert.are.equal(sourceSetId, build.itemsTab.activeItemSetId, "the item-set mutation must be undoable")
		assert.are.equal(amulet.id, build.itemsTab.activeItemSet.Amulet.selItemId)

		local closestNode, closestPathCost
		for _, node in pairs(build.spec.nodes) do
			if node.recipe and #node.recipe > 0 and not build.spec.allocNodes[node.id] and node.path then
				local pathCost = #node.path
				if not closestPathCost or pathCost < closestPathCost then
					closestNode, closestPathCost = node, pathCost
				end
			end
		end
		assert.is_truthy(closestNode, "the native tree should expose a reachable notable for the point-refund case")
		local routeSignature = Candidate.BuildSignature(build)
		local routeSpec, routeError = Candidate.BuildPassiveSpec(build, { closestNode.id }, { }, { })
		assert.is_truthy(routeSpec, routeError)
		assert.is_true(routeSpec:CountAllocNodes() <= 122, "the chosen short route must stay within the native level-100 point ceiling")
		local routeApplied, routeApplyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = routeSignature,
			nodeIds = routeSpec.optimizerAddedNodeIds,
			removeNodeIds = routeSpec.optimizerRemovedNodeIds,
		})
		assert.is_true(routeApplied, routeApplyError)
		local routedSpec = build.spec
		local routedPointCount = routedSpec:CountAllocNodes()
		local refundCandidate
		for _, candidate in ipairs(TreeSearch.BuildAnointCandidates(build.spec, 10000)) do
			if candidate.anointVariant.nodeId == closestNode.id then refundCandidate = candidate break end
		end
		assert.is_truthy(refundCandidate, "an allocated anointable notable should generate a refund candidate")
		assert.are.equal(1, #refundCandidate.removeNodeIds)
		assert.are.equal(closestNode.id, refundCandidate.removeNodeIds[1])
		local refundedSpec, refundError, refundItems = Candidate.BuildPassiveSpec(build, { }, refundCandidate.removeNodeIds, {
			anointVariant = refundCandidate.anointVariant,
		})
		assert.is_truthy(refundedSpec, refundError)
		assert.is_nil(refundedSpec.allocNodes[closestNode.id], "the anointed notable must be removed from the paid tree allocation")
		assert.is_true(refundedSpec:CountAllocNodes() < routedPointCount, "deallocating the anointed notable should refund its travel path")
		local refundBuild = { spec = refundedSpec, itemsTab = refundItems }
		setmetatable(refundBuild, { __index = build })
		local refundCalc = Calcs.getMiscCalculator(refundBuild)
		local refundOutput, refundEnv = refundCalc({ spec = refundedSpec, returnEnv = true }, true)
		assert.is_truthy(refundOutput and refundOutput.TotalDPS)
		assert.is_truthy(refundEnv and refundEnv.grantedPassives[closestNode.id], "PoB must grant the refunded notable from the anoint")
		local refundSignature = Candidate.BuildSignature(build)
		local refundApplied, refundApplyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = refundSignature,
			nodeIds = refundedSpec.optimizerAddedNodeIds,
			removeNodeIds = refundedSpec.optimizerRemovedNodeIds,
			anointVariant = refundCandidate.anointVariant,
		})
		assert.is_true(refundApplied, refundApplyError)
		assert.is_true(build.spec:CountAllocNodes() < routedPointCount)
		assert.are.equal(routedPointCount, routedSpec:CountAllocNodes(), "the previous tree variation must remain intact")
	end)

	it("limits multi-anoint proposals to existing slots and the next free slot", function()
		local amulet = {
			id = 101,
			base = { type = "Amulet" },
			canHaveThreeEnchants = true,
			enchantModLines = { { line = "Allocates Existing Enchant" } },
			implicitModLines = { { line = "Allocates Existing Implicit" } },
			BuildRaw = function() return "unused because skipped slot is rejected before cloning" end,
		}
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = { Amulet = { selItemId = amulet.id } },
			slots = { Amulet = { selItemId = amulet.id, active = true } },
			items = { [amulet.id] = amulet },
		}
		local nodes = {
			[1] = { id = 1, dn = "Existing Enchant", recipe = { "Oil" } },
			[2] = { id = 2, dn = "Existing Implicit", recipe = { "Oil" } },
			[3] = { id = 3, dn = "New Notable A", recipe = { "Oil" } },
			[4] = { id = 4, dn = "New Notable B", recipe = { "Oil" } },
		}
		local tree = {
			nodes = nodes,
			notableMap = {
				["existing enchant"] = nodes[1],
				["existing implicit"] = nodes[2],
				["new notable a"] = nodes[3],
				["new notable b"] = nodes[4],
			},
		}
		local spec = {
			build = { itemsTab = itemsTab },
			tree = tree,
			allocNodes = { },
		}
		local candidates, availableCount, coverage = Anoints.BuildCandidates(spec, 100)
		assert.are.equal(5, availableCount, "single and paired anoints should respect item capacity and contiguous slots")
		assert.are.equal(5, #candidates)
		assert.are.equal(4, coverage.generatedSingleCandidates)
		assert.are.equal(1, coverage.generatedPairedCandidates)
		assert.are.equal(1, coverage.availablePairedCandidates)
		local paired
		for _, candidate in ipairs(candidates) do
			if candidate.anointVariants then
				paired = candidate
				assert.are.equal(2, #candidate.anointVariants)
				assert.are.equal(candidate.anointVariants[1].itemId, candidate.anointVariants[2].itemId)
				assert.are_not.equal(candidate.anointVariants[1].enchantSlot, candidate.anointVariants[2].enchantSlot)
				assert.is_true(candidate.anointVariants[1].enchantSlot >= 1 and candidate.anointVariants[1].enchantSlot <= 2)
				assert.is_true(candidate.anointVariants[2].enchantSlot >= 2 and candidate.anointVariants[2].enchantSlot <= 3,
					"pair proposals must append contiguously and never skip an enchant array index")
			else
				assert.is_true(candidate.anointVariant.enchantSlot >= 1 and candidate.anointVariant.enchantSlot <= 2,
					"single proposals must never skip over an empty enchant array index")
				assert.is_true(candidate.anointVariant.nodeId == 3 or candidate.anointVariant.nodeId == 4)
			end
		end
		assert.is_truthy(paired, "a multi-slot amulet should receive a deterministic paired-anoint proposal")
		local invalidClone, cloneError = Anoints.CloneItem({ itemsTab = itemsTab, spec = spec }, {
			itemId = amulet.id,
			slotName = "Amulet",
			nodeId = 3,
			enchantSlot = 3,
		}, { })
		assert.is_nil(invalidClone)
		assert.are.equal("The requested anoint slot is unavailable on this item", cloneError,
			"direct candidate reconstruction must reject skipped enchant slots too")
	end)

	it("enumerates bounded single-to-quad anoint combinations within native capacity", function()
		local amulet = {
			id = 102,
			base = { type = "Amulet" },
			canHaveFourEnchants = true,
			enchantModLines = { { line = "Allocates Existing Enchant" } },
			BuildRaw = function() return "unused by candidate generation" end,
		}
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = { Amulet = { selItemId = amulet.id } },
			slots = { Amulet = { selItemId = amulet.id, active = true } },
			items = { [amulet.id] = amulet },
		}
		local nodes = { }
		local notableMap = { }
		for nodeId = 1, 5 do
			local name = "Notable " .. string.char(64 + nodeId)
			nodes[nodeId] = { id = nodeId, dn = name, recipe = { "Oil" } }
			notableMap[name:lower()] = nodes[nodeId]
		end
		local spec = {
			build = { itemsTab = itemsTab },
			tree = { nodes = nodes, notableMap = notableMap },
			allocNodes = { },
		}
		local candidates, availableCount, coverage = Anoints.BuildCandidates(spec, 100)
		assert.are.equal(10, coverage.availableSingleCandidates, "five unallocated notables × the current and next contiguous enchant slots")
		assert.are.equal(10, coverage.availableAnointCandidatesByCount[1])
		assert.are.equal(20, coverage.availableAnointCandidatesByCount[2])
		assert.are.equal(20, coverage.availableAnointCandidatesByCount[3])
		assert.are.equal(5, coverage.availableAnointCandidatesByCount[4])
		assert.are.equal(55, availableCount)
		assert.are.equal(55, #candidates)
		for arity = 1, 4 do
			assert.are.equal(coverage.availableAnointCandidatesByCount[arity], coverage.generatedAnointCandidatesByCount[arity])
		end
		local found = { }
		for _, candidate in ipairs(candidates) do
			local variants = candidate.anointVariants or { candidate.anointVariant }
			local arity = #variants
			found[arity] = true
			local plannedEnchantCount = #amulet.enchantModLines
			local seenNodes = { }
			for _, variant in ipairs(variants) do
				assert.are.equal(amulet.id, variant.itemId)
				assert.is_nil(seenNodes[variant.nodeId], "a notable cannot appear twice in one combination")
				seenNodes[variant.nodeId] = true
				assert.is_true(variant.enchantSlot <= plannedEnchantCount + 1, "new slots must be appended contiguously")
				plannedEnchantCount = math.max(plannedEnchantCount, variant.enchantSlot)
			end
		end
		for arity = 1, 4 do assert.is_true(found[arity], "the four-slot amulet should expose arity " .. arity) end
	end)

	it("evaluates and applies two anoints through PoB's exact GrantedPassive pipeline", function()
		newBuild()
		build.characterLevel = 40
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 12/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		local amulet = new("Item"):Item("Optimizer Multi Anoint Test\nAmber Amulet\nCan have 2 additional Enchantment Modifiers")
		assert.is_true(amulet.canHaveThreeEnchants, "PoB must parse the native three-enchant item capability")
		build.itemsTab:AddItem(amulet, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = amulet.id
		build.itemsTab.slots.Amulet.selItemId = amulet.id
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.itemsTab:AddUndoState()
		build.calcsTab:BuildOutput()

		local signature = Candidate.BuildSignature(build)
		local candidates, _, coverage = TreeSearch.BuildAnointCandidates(build.spec, 24)
		assert.is_true(coverage.generatedPairedCandidates > 0)
		assert.is_true(coverage.availablePairedCandidates >= coverage.generatedPairedCandidates)
		local paired
		for _, candidate in ipairs(candidates) do
			if candidate.anointVariants and #(candidate.removeNodeIds or { }) == 0 then paired = candidate break end
		end
		assert.is_truthy(paired, "the bounded native search should include a paired proposal")
		local projected, err, isolatedItems = Candidate.BuildPassiveSpec(build, { }, paired.removeNodeIds, {
			anointVariants = paired.anointVariants,
		})
		assert.is_truthy(projected, err)
		local isolatedItem = isolatedItems.items[amulet.id]
		assert.is_truthy(isolatedItem)
		for _, variant in ipairs(paired.anointVariants) do
			local name = build.spec.nodes[variant.nodeId].dn
			assert.is_truthy(isolatedItem:BuildRaw():find("Allocates " .. name, 1, true))
		end
		assert.is_nil(amulet:BuildRaw():find("Allocates ", 1, true), "phantom paired anoints must not mutate the equipped source")

		local isolatedBuild = { spec = projected, itemsTab = isolatedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local output, env = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_truthy(output and output.TotalDPS)
		for _, variant in ipairs(paired.anointVariants) do
			assert.is_truthy(env and env.grantedPassives[variant.nodeId], "both anoints must resolve through PoB's native GrantedPassive path")
		end
		assert.are.equal(signature, Candidate.BuildSignature(build))

		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = signature,
			nodeIds = { },
			removeNodeIds = paired.removeNodeIds,
			anointVariants = paired.anointVariants,
		})
		assert.is_true(applied, applyError)
		local activeItem = build.itemsTab.items[build.itemsTab.activeItemSet.Amulet.selItemId]
		assert.is_truthy(activeItem)
		for _, variant in ipairs(paired.anointVariants) do
			assert.is_truthy(activeItem:BuildRaw():find("Allocates " .. build.spec.nodes[variant.nodeId].dn, 1, true))
		end
		build.itemsTab:Undo()
		assert.are.equal(signature, Candidate.BuildSignature(build), "undo must restore the original build after applying paired anoints")
	end)

	it("evaluates a four-anoint item through the exact PoB GrantedPassive pipeline", function()
		newBuild()
		build.characterLevel = 40
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 12/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		local amulet = new("Item"):Item("Optimizer Four Anoint Test\nAmber Amulet\nCan have 3 additional Enchantment Modifiers")
		assert.is_true(amulet.canHaveFourEnchants, "PoB must parse the native four-enchant item capability")
		build.itemsTab:AddItem(amulet, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = amulet.id
		build.itemsTab.slots.Amulet.selItemId = amulet.id
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.itemsTab:AddUndoState()
		build.calcsTab:BuildOutput()

		local signature = Candidate.BuildSignature(build)
		local sourceSetId = build.itemsTab.activeItemSetId
		local candidates, _, coverage = TreeSearch.BuildAnointCandidates(build.spec, 64)
		assert.is_true(coverage.generatedAnointCandidatesByCount[3] > 0)
		assert.is_true(coverage.generatedAnointCandidatesByCount[4] > 0)
		local fourAnoints
		for _, candidate in ipairs(candidates) do
			if candidate.anointVariants and #candidate.anointVariants == 4 and #(candidate.removeNodeIds or { }) == 0 then
				fourAnoints = candidate
				break
			end
		end
		assert.is_truthy(fourAnoints, "bounded generation should include a four-anoint proposal without passive refunds")
		local projected, err, isolatedItems = Candidate.BuildPassiveSpec(build, { }, fourAnoints.removeNodeIds, {
			anointVariants = fourAnoints.anointVariants,
		})
		assert.is_truthy(projected, err)
		local isolatedBuild = { spec = projected, itemsTab = isolatedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local output, env = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_truthy(output and output.TotalDPS)
		for _, variant in ipairs(fourAnoints.anointVariants) do
			assert.is_truthy(env and env.grantedPassives[variant.nodeId], "all four anoints must resolve through PoB's native GrantedPassive path")
		end
		assert.are.equal(signature, Candidate.BuildSignature(build), "the exact phantom evaluation must preserve the equipped source item")
		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = signature,
			nodeIds = { },
			removeNodeIds = fourAnoints.removeNodeIds,
			anointVariants = fourAnoints.anointVariants,
			label = fourAnoints.label,
		})
		assert.is_true(applied, applyError)
		assert.are_not.equal(sourceSetId, build.itemsTab.activeItemSetId,
			"a four-anoint result must be applied as a separate reversible item-set variation")
		local activeItem = build.itemsTab.items[build.itemsTab.activeItemSet.Amulet.selItemId]
		for _, variant in ipairs(fourAnoints.anointVariants) do
			assert.is_truthy(activeItem:BuildRaw():find("Allocates " .. build.spec.nodes[variant.nodeId].dn, 1, true))
		end
		build.itemsTab:Undo()
		assert.are.equal(signature, Candidate.BuildSignature(build), "undo must restore the original build after applying four anoints")

		local parsed = assert(Inputs.Parse({ evaluationBudget = "40", maxAddedPoints = "0", maxTotalPoints = "120" }))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		local fourAnointReachedExactCalc = false
		for _ = 1, 6000 do
			status, result = job:Step()
			if job.progress and job.progress.phase == "Exact calculations" then
				local _, plusCount = tostring(job.progress.current):gsub("%+", "")
				if tostring(job.progress.current):find("Anoint ", 1, true) and plusCount >= 3 then
					fourAnointReachedExactCalc = true
				end
			end
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "the bounded four-anoint search should finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.is_true(fourAnointReachedExactCalc,
			"the exact search must evaluate a four-anoint proposal within its native 15% mutation quota")
		assert.are.equal(1, result.searchCoverage.anoints.generatedAnointCandidatesByCount[4])
		assert.are.equal(signature, Candidate.BuildSignature(build), "the full phantom search must preserve the source build")
	end)

	it("evaluates generated ascendancy routes through the exact PoB optimizer pipeline", function()
		newBuild()
		build.characterLevel = 40
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 12/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local signature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({ evaluationBudget = "10", maxAddedPoints = "3", maxTotalPoints = "120" }))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local evaluatedAscendancy = false
		local status, result = "running", nil
		for _ = 1, 3000 do
			status, result = job:Step()
			if job.progress and job.progress.phase == "Exact calculations"
				and tostring(job.progress.current):find("Ascendancy", 1, true) then
				evaluatedAscendancy = true
			end
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "the bounded exact search should finish; last phase: " .. tostring(job.progress and job.progress.phase))
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.is_true(evaluatedAscendancy, "at least one generated ascendancy must reach exact PoB calculation")
		assert.is_true(result.evaluations > 1)
		assert.is_true(result.searchCoverage.ascendancies.generatedCandidates > 0)
		assert.are.equal(signature, Candidate.BuildSignature(build))
	end)

	it("calculates a user-selected base class through exact PoB before returning the result", function()
		newBuild()
		build.characterLevel = 40
		build.characterLevelAutoMode = false
		build.calcsTab:BuildOutput()
		local signature = Candidate.BuildSignature(build)
		local selectedClassId = build.spec.tree.classNameMap.Witch
		local parsed = assert(Inputs.Parse({
			baseClassId = tostring(selectedClassId),
			objectiveMetric = "TotalEHP",
			evaluationBudget = "12",
			maxAddedPoints = "2",
			maxTotalPoints = "120",
		}))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 3000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "the bounded class-switch evaluation should finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.are.equal("feasible", result.status, result.message)
		assert.are.equal("Witch", result.evaluation.selectedBaseClassName)
		assert.is_truthy(result.candidate.classVariant)
		assert.are.equal(selectedClassId, result.candidate.classVariant.classId)
		assert.are.equal(signature, Candidate.BuildSignature(build), "evaluating the selected class must not mutate the active build")
	end)

	it("searches every native class with an equal budget and returns only exact feasible results", function()
		newBuild()
		build.characterLevel = 40
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		-- The class-root comparison is about exact passive-root effects; keep its
		-- fixed skill package sustainable for every class so the native sustain
		-- gate does not correctly reject every one-evaluation class budget.
		build.configTab.configSets[build.configTab.activeConfigSetId].customModsList[1].text = "Regenerate 100 Mana per second"
		build.configTab:BuildModList()
		build.calcsTab:BuildOutput()
		local tab = build.optimizerTab
		local signature = Candidate.BuildSignature(build)
		local classCount = 0
		for _, class in pairs(build.spec.tree.classes) do if class.startNodeId then classCount = classCount + 1 end end
		assert.are.equal(7, classCount)

		local started, budgetError = tab:StartOptimizer({ searchAllClasses = true, baseClassId = "", targetSkillGroupIndex = "1", targetSkillIndex = "1", evaluationBudget = "6", maxAddedPoints = "0" })
		assert.is_false(started)
		assert.is_truthy(budgetError:find("at least 7", 1, true))

		started = tab:StartOptimizer({
			searchAllClasses = true,
			baseClassId = "",
			targetSkillGroupIndex = "1",
			targetSkillIndex = "1",
			objectiveMetric = "CombinedDPS",
			evaluationBudget = "7",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
		})
		assert.is_true(started, tab.statusMessage)
		local status, result = "running", nil
		for _ = 1, 6000 do
			status, result = tab.job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "equal-budget class search should finish: " .. tostring(tab.job and tab.job.progress and tab.job.progress.phase))
		local classDiagnostics = { }
		for _, row in ipairs(result and result.classSearch and result.classSearch.results or { }) do
			local firstViolation = row.bestObservedViolations and row.bestObservedViolations[1]
			classDiagnostics[#classDiagnostics + 1] = tostring(row.class) .. " [" .. tostring(row.status) .. "]"
				.. (firstViolation and (": " .. tostring(firstViolation.reason)) or "")
		end
		assert.are.equal("feasible", status, (result and result.message or "all native roots must complete exact PoB evaluation")
			.. (#classDiagnostics > 0 and ("; per class: " .. table.concat(classDiagnostics, "; ")) or ""))
		assert.are.equal(7, result.classSearch.classCount)
		assert.are.equal(7, result.classSearch.totalBudget)
		assert.are.equal(7, result.classSearch.usedBudget)
		assert.is_false(result.classSearch.exhaustive)
		assert.is_truthy(result.candidate.classVariant)
		assert.is_truthy(result.candidate.evaluation.metrics.CombinedDPS)
		assert.are.equal(7, #result.classSearch.results)
		for _, row in ipairs(result.classSearch.results) do
			assert.are.equal(1, row.quota)
			assert.are.equal(1, row.evaluations)
			assert.are.equal("feasible", row.status, row.error)
			assert.is_truthy(row.bestCandidate, "each class result must identify its best exact candidate")
			assert.is_truthy(row.ascendancyCoverage, "each class result must state route-search coverage")
			assert.are.equal("budget_exhausted", row.ascendancyCoverage.status,
				"a one-evaluation class quota must report that ascendancy generation was not reached")
		end
		assert.are.equal(signature, Candidate.BuildSignature(build), "class search must preserve the active build")
	end)

	it("compares exact candidate trees independently from all seven native class roots", function()
		newBuild()
		build.characterLevel = 40
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.configTab.configSets[build.configTab.activeConfigSetId].customModsList[1].text = "Regenerate 100 Mana per second"
		build.configTab:BuildModList()
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local inputs = assert(Inputs.Parse({ maxTotalPoints = "120" }))
		local started, startError = build.optimizerTab:StartOptimizer({
			searchAllClasses = true,
			baseClassId = "",
			targetSkillGroupIndex = "1",
			targetSkillIndex = "1",
			objectiveMetric = "CombinedDPS",
			evaluationBudget = "70",
			maxAddedPoints = "6",
			maxTotalPoints = "120",
		})
		assert.is_true(started, startError or build.optimizerTab.statusMessage)
		local searchJob = build.optimizerTab.job
		local status, result = "running", nil
		for _ = 1, 12000 do
			status, result = searchJob:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "seven-class route search should finish within its bounded evaluation budget")
		assert.are.equal("feasible", status, result and result.message)
		assert.are.equal(70, result.classSearch.totalBudget)
		assert.are.equal(7, #result.classSearch.results)
		local totalExact = 0
		local classEvidence = { }
		for index, publicRow in ipairs(result.classSearch.results) do
			local row = searchJob.classResults[index]
			assert.is_truthy(row and row.bestCandidate, "the internal exact result must retain its class route")
			assert.are.equal(publicRow.classId, row.classId)
			assert.are.equal(10, row.quota, "each native class must receive the same exact evaluation quota")
			assert.are.equal("feasible", row.status, row.error)
			assert.is_true(row.evaluations <= row.quota, "a class search must not overspend its equal exact-evaluation quota")
			assert.is_true(row.evaluations >= math.floor(row.quota * 0.7),
				row.class .. " must use most of its equal exact-evaluation quota")
			assert.is_true(row.searchCoverage.phase.largestExactTreePointCount > 0,
				row.class .. " must exact-evaluate a main-tree route in addition to its class root")
			assert.is_true(publicRow.treeCoverage.largestExactTreePointCount > 0,
				"the public per-class result must expose exact main-tree route coverage")
			assert.are.equal(row.evaluations, publicRow.treeCoverage.exactEvaluations,
				"the public route coverage must report the exact engine evaluations used for this class")
			assert.is_truthy(row.bestCandidate)
			assert.are.equal(row.classId, row.bestCandidate.classVariant.classId)
			assert.are.equal(row.class, row.bestCandidate.evaluation.selectedBaseClassName)
			assert.is_true(row.bestCandidate.evaluation.passivePointsUsed <= 120)
			assert.is_true(#(row.bestCandidate.nodeIds or { }) > 0,
				row.class .. " must return a tree mutation selected by the exact class search")
			local proxy, proxyError = Candidate.BuildPassiveSpec(build,
				row.bestCandidate.nodeIds, row.bestCandidate.removeNodeIds or { }, {
					classId = row.classId,
					ascendancyVariant = row.bestCandidate.ascendancyVariant,
				})
			assert.is_truthy(proxy, proxyError)
			assert.are.equal(row.classId, proxy.curClassId)
			local reconstructedMainPoints, reconstructedAscendancyPoints, reconstructedBloodlinePoints = proxy:CountAllocNodes()
			assert.are.equal(row.bestCandidate.evaluation.passivePointsUsed, reconstructedMainPoints,
				row.class .. " exact evaluation point count must match its reconstructed native tree")
			assert.are.equal(row.bestCandidate.evaluation.ascendancyPointsUsed, reconstructedAscendancyPoints,
				row.class .. " exact ascendancy count must match its reconstructed native tree")
			assert.are.equal(row.bestCandidate.evaluation.secondaryAscendancyPointsUsed, reconstructedBloodlinePoints,
				row.class .. " exact Bloodline count must match its reconstructed native tree")
			local rootCount = 0
			for nodeId in pairs(proxy.allocNodes or { }) do
				local node = proxy.nodes[nodeId]
				if node and node.type == "ClassStart" then
					rootCount = rootCount + 1
					assert.are.equal(proxy.curClass.startNodeId, nodeId,
						"the candidate may allocate only its selected native class start")
				end
			end
			assert.are.equal(1, rootCount, "every candidate tree must have exactly one class root")
			local valid, reason = TreeSearch.ValidateCandidate(proxy, row.bestCandidate.nodeIds, inputs,
				TreeSearch.BuildRegionMap(proxy), row.bestCandidate.removeNodeIds or { }, proxy)
			assert.is_true(valid, reason)
			classEvidence[#classEvidence + 1] = {
				class = row.class,
				evaluations = row.evaluations,
				quota = row.quota,
				combinedDPS = row.bestCandidate.evaluation.metrics.CombinedDPS,
				fullDPS = row.bestCandidate.evaluation.metrics.FullDPS,
				passivePoints = row.bestCandidate.evaluation.passivePointsUsed,
				ascendancyPoints = row.bestCandidate.evaluation.ascendancyPointsUsed,
				bloodlinePoints = row.bestCandidate.evaluation.secondaryAscendancyPointsUsed,
				largestExactMainTreePointCount = row.searchCoverage.phase.largestExactTreePointCount,
				generatedProgressiveBundles = row.searchCoverage.phase.generatedProgressiveTreeBundles,
				exactProgressiveBundles = row.searchCoverage.phase.exactProgressiveTreeBundleEvaluations,
				reconstructedMainPoints = reconstructedMainPoints,
				addedPassives = #(row.bestCandidate.nodeIds or { }),
			}
			totalExact = totalExact + row.evaluations
		end
		assert.are.equal(totalExact, result.classSearch.usedBudget)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
			"all seven exact class-route searches must preserve the active source build")
		print("QA_CASE " .. json.encode({
			fixture = "seven-class-fireball-exact-class-search",
			objectiveMetric = "CombinedDPS",
			classCount = result.classSearch.classCount,
			quotaPerClass = 10,
			totalBudget = result.classSearch.totalBudget,
			usedBudget = result.classSearch.usedBudget,
			selectedClass = result.candidate.evaluation.selectedBaseClassName,
			selectedCombinedDPS = result.candidate.evaluation.metrics.CombinedDPS,
			selectedPassivePoints = result.candidate.evaluation.passivePointsUsed,
			classResults = classEvidence,
			sourcePreserved = true,
			certification = "bounded_exact_fixture_not_global_class_optimum",
		}))
	end)

	it("optimizes native Bandit/Pantheon choices through exact PoB and applies them as a config-set variation", function()
		newBuild()
		build.characterLevel = 40
		build.characterLevelAutoMode = false
		local configTab = build.configTab
		local sourceConfigId = configTab.activeConfigSetId
		local sourceSet = configTab.configSets[sourceConfigId]
		local originalBandit = sourceSet.input.bandit
		local originalMajor = sourceSet.input.pantheonMajorGod
		local originalMinor = sourceSet.input.pantheonMinorGod
		local originalEnemyDamageType = sourceSet.input.enemyDamageType
		local originalEnemyFireDamage = sourceSet.input.enemyFireDamage
		sourceSet.input.enemyDamageType = "DamageOverTime"
		sourceSet.input.enemyFireDamage = 10
		configTab:BuildModList()
		build.calcsTab:BuildOutput()
		local baseOutput = build.calcsTab.mainOutput
		local baseExtraPoints = baseOutput.ExtraPoints
		local baseFireDegen = baseOutput.FireEnemyDegen
		assert.is_true(type(baseFireDegen) == "number" and baseFireDegen > 0, "the native fire-degen control must be active")
		sourceSet.input.enemyDamageType = originalEnemyDamageType
		sourceSet.input.enemyFireDamage = originalEnemyFireDamage
		configTab:BuildModList()
		build.calcsTab:BuildOutput()
		local signature = Candidate.BuildSignature(build)

		-- Independent ordinary-PoB control: select Oak in the live config, record
		-- the native result, then restore the original config before optimization.
		sourceSet.input.bandit = "Oak"
		configTab:BuildModList()
		build.calcsTab:BuildOutput()
		local nativeOakLife = build.calcsTab.mainOutput.Life
		local nativeOakExtraPoints = build.calcsTab.mainOutput.ExtraPoints
		assert.are.equal(baseExtraPoints - 1, nativeOakExtraPoints, "PoB's Oak choice must remove the kill-all passive point")
		sourceSet.input.bandit = originalBandit
		configTab:BuildModList()
		build.calcsTab:BuildOutput()
		assert.are.equal(signature, Candidate.BuildSignature(build), "the independent control must restore the source config")

		-- Pantheon mitigation is parsed from PoB's generated data and modifier
		-- pipeline, not estimated by the optimizer.
		local isolatedBuild = { }
		setmetatable(isolatedBuild, { __index = build })
		local isolatedConfig, isolatedItems, _, scenarioError = Scenario.Create(build, "Current", isolatedBuild, nil, {
			bandit = originalBandit, pantheonMajorGod = "Arakaali", pantheonMinorGod = originalMinor,
		})
		assert.is_nil(scenarioError)
		isolatedConfig.input.enemyDamageType = "DamageOverTime"
		isolatedConfig.input.enemyFireDamage = 10
		isolatedConfig:BuildModList()
		isolatedBuild.configTab = isolatedConfig
		isolatedBuild.itemsTab = isolatedItems
		local pantheonCalc = Calcs.getMiscCalculator(isolatedBuild)
		local pantheonOutput = pantheonCalc({ returnEnv = true }, true)
		assert.is_true(pantheonOutput.FireEnemyDegen < baseFireDegen,
			"Arakaali's native 10% reduced Damage over Time taken must reduce the exact fire degen output")
		assert.are.equal(signature, Candidate.BuildSignature(build), "isolated Pantheon evaluation must leave the source config unchanged")

		local parsed = assert(Inputs.Parse({
			objectiveMetric = "TotalEHP",
			evaluationBudget = "2",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
		}))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 1000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.are.equal("feasible", status, job.error or (result and ((result.message or "") .. " " .. require("dkjson").encode(result.bestObservedViolations or { }))))
		assert.are.equal(2, result.evaluations)
		assert.are.equal("Oak", result.candidate.configurationVariant.bandit)
		assert.are.equal(nativeOakLife, result.evaluation.metrics.Life, "phantom result must match the ordinary PoB Oak calculation")
		assert.are.equal(nativeOakExtraPoints, result.evaluation.extraPassivePoints, "the candidate audit must retain PoB's exact ExtraPoints output")
		local expectedOakPointLimit = build:GetPassivePointLimitForLevel(40, result.evaluation.extraPassivePoints)
		assert.are.equal(expectedOakPointLimit, result.evaluation.passivePointLimit,
			string.format("candidate point limit must use Oak's exact native ExtraPoints result (expected %s, got %s; ExtraPoints %s)", tostring(expectedOakPointLimit), tostring(result.evaluation.passivePointLimit), tostring(nativeOakExtraPoints)))
		assert.is_true(result.searchCoverage.configuration.totalCombinations > 1)
		assert.are.equal(signature, Candidate.BuildSignature(build), "configuration search must leave the selected source set unchanged")

		local applied, applyMessage = Candidate.Apply(build, result.candidate)
		assert.is_true(applied, applyMessage)
		assert.are.equal(2, #configTab.configSetOrderList)
		assert.are_not.equal(sourceConfigId, configTab.activeConfigSetId)
		assert.is_truthy(configTab.configSets[configTab.activeConfigSetId].title:find("Help Oak", 1, true))
		assert.are.equal("Oak", configTab.input.bandit)
		assert.are.equal(originalMajor, configTab.input.pantheonMajorGod)
		assert.are.equal(originalMinor, configTab.input.pantheonMinorGod)
		assert.are.equal(originalBandit, sourceSet.input.bandit, "the original config set must remain selectable and unchanged")
		assert.are.equal(originalMajor, sourceSet.input.pantheonMajorGod)
		assert.are.equal(originalMinor, sourceSet.input.pantheonMinorGod)
		configTab:SetActiveConfigSet(sourceConfigId)
		assert.are.equal(signature, Candidate.BuildSignature(build), "selecting the original config set must restore the original build state")
	end)

	it("partitions every active PoB node into a versioned spatial zone", function()
		newBuild()
		local regions, coverage = TreeSearch.BuildRegionMap(build.spec, "spatial")
		assert.is_truthy(regions)
		assert.are.equal("spatial-v1", coverage.partitionVersion)
		local nodeCount = 0
		for nodeId in pairs(build.spec.nodes) do
			nodeCount = nodeCount + 1
			assert.is_truthy(regions[nodeId], "active node is missing from spatial partition: " .. tostring(nodeId))
		end
		assert.are.equal(nodeCount, coverage.totalNodeCount)
		assert.are.equal(nodeCount, coverage.assignedNodeCount)
		assert.are.equal(0, coverage.unassignedNodeCount)
		assert.are.equal("Hub", regions[build.spec.curClass.startNodeId], "the native Scion origin is the spatial hub anchor")
		for _, regionName in ipairs({ "NorthWest", "NorthEast", "SouthWest", "SouthEast" }) do
			assert.is_true(coverage.counts[regionName] > 0, "loaded tree has no nodes assigned to " .. regionName)
		end

		build.characterLevel = 40
		build.characterLevelAutoMode = false
		local signature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({ allowedRegions = "NW", objectiveMetric = "TotalEHP", maxAddedPoints = "40" }))
		local validTree, treeError = Inputs.ValidateAgainstTree(parsed, build.spec.tree)
		assert.is_true(validTree, treeError)
		local candidates, pathError = TreeSearch.BuildCandidateNodes(build.spec, parsed, 1, nil, 40, nil, regions)
		assert.is_nil(pathError)
		assert.are.equal(1, #candidates)
		for _, nodeId in ipairs(candidates[1].nodeIds) do
			assert.is_true(regions[nodeId] == "Hub" or regions[nodeId] == "NorthWest", "native route escaped its zone mask at node " .. tostring(nodeId))
		end
		local projected, projectionError, isolatedItems = Candidate.BuildPassiveSpec(build, candidates[1].nodeIds, { })
		assert.is_truthy(projected, projectionError)
		assert.is_true(TreeSearch.ValidateCandidate(build.spec, projected.optimizerAddedNodeIds, parsed, regions,
			projected.optimizerRemovedNodeIds, projected))
		local isolatedBuild = { spec = projected, itemsTab = isolatedItems or build.itemsTab }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local exactOutput = exactCalc({ spec = projected }, true)
		assert.is_true(exactOutput and type(exactOutput.TotalEHP) == "number" and exactOutput.TotalEHP > 0,
			"the spatially masked candidate must reach PoB's exact calculator")
		assert.are.equal(signature, Candidate.BuildSignature(build), "spatial route evaluation must leave the source build unchanged")

		local searchInputs = assert(Inputs.Parse({
			allowedRegions = "NW",
			objectiveMetric = "TotalEHP",
			evaluationBudget = "8",
			maxAddedPoints = "40",
			maxTotalPoints = "120",
		}))
		local searchJob = PhantomSim.RunPhantomSim(build, searchInputs, { cancelled = false })
		local searchStatus, searchResult = "running", nil
		for _ = 1, 3000 do
			searchStatus, searchResult = searchJob:Step()
			if searchStatus ~= "running" then break end
		end
		assert.is_true(searchStatus ~= "running", "the bounded spatial search should finish")
		assert.is_true(searchStatus ~= "error", searchResult and searchResult.message or searchJob.error)
		assert.is_truthy(searchResult.searchCoverage.topology)
		assert.are.equal(nodeCount, searchResult.searchCoverage.topology.assignedNodeCount)
		assert.are.equal(signature, Candidate.BuildSignature(build), "the full spatial search must preserve the source build")
	end)

	it("locks the selected ascendancy and exact-calculates its combinations with passive routes", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 1/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()

		local tree = build.spec.tree
		local witchId = tree.classNameMap.Witch
		local witch = tree.classes[witchId]
		local elementalistId
		for id, ascendancy in pairs(witch.classes or { }) do
			if ascendancy.name == "Elementalist" or ascendancy.id == "Elementalist" then
				elementalistId = id
				break
			end
		end
		assert.is_truthy(elementalistId, "the loaded PoB tree must provide Witch/Elementalist")
		local root, rootError = Candidate.BuildPassiveSpec(build, { }, { }, {
			classId = witchId,
			ascendClassId = elementalistId,
		})
		assert.is_truthy(root, rootError)
		local requiredAscendancyNode
		for nodeId, node in pairs(root.nodes) do
			if node.ascendancyName and node.ascendancyName == "Elementalist"
				and (node.type == "Notable" or node.type == "Keystone") then
				requiredAscendancyNode = nodeId
				break
			end
		end
		assert.is_truthy(requiredAscendancyNode, "the selected ascendancy must expose native allocatable notables")

		local signature = Candidate.BuildSignature(build)
		local parsed, parseError = Inputs.Parse({
			generationPhase = "tree",
			baseClassId = tostring(witchId),
			ascendancyId = tostring(elementalistId),
			requiredNodeIds = tostring(requiredAscendancyNode),
			objectiveMetric = "TotalEHP",
			evaluationBudget = "32",
			maxAddedPoints = "6",
			maxTotalPoints = "111",
		})
		assert.is_truthy(parsed, parseError)
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 5000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "the locked-ascendancy search should finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.are.equal("feasible", status, result and result.message or "the native ascendancy route should satisfy its required node")
		assert.are.equal(elementalistId, result.candidate.ascendancyVariant.ascendClassId)
		assert.are.equal("Elementalist", result.evaluation.selectedAscendancyName)
		assert.is_true(result.evaluation.ascendancyPointsUsed > 0, "a locked ascendancy must have a native route, not only a selected label")
		assert.is_true(result.searchCoverage.ascendancies.lockedAscendancyId == elementalistId)
		assert.is_true(result.searchCoverage.phase.generatedTreeAscendancyCombinations > 0)
		assert.is_true(result.searchCoverage.phase.exactTreeAscendancyCombinations > 0,
			"at least one ascendancy/passive route combination must reach the exact PoB engine; coverage="
				.. require("dkjson").encode(result.searchCoverage.phase))
		local projected, projectionError = Candidate.BuildPassiveSpec(build, result.candidate.nodeIds,
			result.candidate.removeNodeIds, {
				classId = result.candidate.classVariant.classId,
				ascendancyVariant = result.candidate.ascendancyVariant,
			})
		assert.is_truthy(projected, projectionError)
		assert.is_truthy(projected.allocNodes[requiredAscendancyNode], "the exact candidate must retain the requested Elementalist notable")
		assert.are.equal(signature, Candidate.BuildSignature(build), "locked ascendancy optimization must preserve the active source build")
	end)
end)
