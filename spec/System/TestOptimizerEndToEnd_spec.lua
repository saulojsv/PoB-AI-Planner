local Candidate = require("Modules.Optimizer.Candidate")
local SkillSeed = require("Modules.Optimizer.SkillSeed")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local TreeSearch = require("Modules.Optimizer.TreeSearch")
local Inputs = require("Modules.Optimizer.Inputs")
local Scenario = require("Modules.Optimizer.Scenario")
local Activity = require("Modules.Optimizer.Activity")
local Calcs = require("Modules.Calcs")
local json = require("dkjson")
local MCP = require("Modules.Optimizer.MCPBridge")
local PathExperience = require("Modules.Optimizer.PathExperience")
local Version = require("Modules.Optimizer.Version")
local TestSupport = require("OptimizerTestSupport")
local ffi = require("ffi")

pcall(ffi.cdef, [[
	int _mkdir(const char *dirname);
	int _rmdir(const char *dirname);
	int _access(const char *path, int mode);
	int mkdir(const char *dirname, unsigned int mode);
	int rmdir(const char *dirname);
	int access(const char *path, int mode);
]])

local isWindows = package.config and package.config:sub(1, 1) == "\\"
local crt = isWindows and ffi.load("msvcr100") or nil

local function makeTestDirectory(path)
	path = path:gsub("[/\\]+$", "")
	local result
	if isWindows then
		result = crt._mkdir(path)
	else
		result = ffi.C.mkdir(path, 493)
	end
	if result == 0 then return true end
	local exists = isWindows and crt._access(path, 0) == 0 or (not isWindows and ffi.C.access(path, 0) == 0)
	if exists then return nil, "No error" end
	return nil, "could not create test directory"
end

local function removeTestDirectory(path)
	if not path then return end
	if isWindows then return crt._rmdir(path) end
	return ffi.C.rmdir(path)
end

local function cleanupTestStore(root)
	if not root then return end
	local path, directory = PathExperience.GetStorePath(root)
	if path then os.remove(path) end
	if directory then removeTestDirectory(directory) end
	removeTestDirectory(root)
end

describe("AI Planner explicit Witch Necromancer generation", function()
	local fixtureJobId
	local fixtureJobIds = { }
	local originalUserPath, originalMakeDir, storageRoot
	before_each(function()
		originalUserPath, originalMakeDir = main.userPath, MakeDir
		storageRoot = os.tmpname() .. "_optimizer_end_to_end"
		os.remove(storageRoot)
		assert(makeTestDirectory(storageRoot))
		main.userPath = storageRoot
		MakeDir = makeTestDirectory
	end)
	after_each(function()
		for _, jobId in ipairs(fixtureJobIds) do
			MCP.jobs[jobId] = nil
			if MCP.activeJobId == jobId then MCP.activeJobId = nil end
		end
		fixtureJobIds = { }
		fixtureJobId = nil
		main.userPath, MakeDir = originalUserPath, originalMakeDir
		cleanupTestStore(storageRoot)
		storageRoot = nil
	end)
local function generate(gemId, expectUncertifiedMinion, useLocalMcp, scenarioProfile, scenarioEnemyPreset, strictCombined, fullTreeBudget, fullTreeOnly, scenarioEnemyLevel)
		newBuild()
		TestSupport.MarkCalculationContentVerified()
		build.characterLevel, build.characterLevelAutoMode = 90, false
		local witchId = assert(build.spec.tree.classNameMap.Witch)
		local necromancerId, requiredAscendancyNode
		for id, class in pairs(build.spec.tree.classes[witchId].classes) do
			if class.name == "Necromancer" or class.id == "Necromancer" then necromancerId = id end
		end
		assert.is_truthy(necromancerId)
		for id, node in pairs(build.spec.nodes) do
			if node.ascendancyName == "Necromancer" and node.name == "Mindless Aggression" then requiredAscendancyNode = id end
		end
		assert.is_truthy(requiredAscendancyNode)
		local seed, seedError = SkillSeed.Create(build, gemId, witchId)
		assert.is_truthy(seed, seedError)
		build.skillsTab.socketGroupList[seed.groupIndex].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local tab, stages = build.optimizerTab, { }
		local lastPhaseResult
		local strictFloors = {
			Life = 3000, EnergyShield = 1000, TotalEHP = 20000,
			PhysicalMaximumHitTaken = 5000, FireMaximumHitTaken = 10000,
			ColdMaximumHitTaken = 10000, LightningMaximumHitTaken = 10000,
			ChaosMaximumHitTaken = 3000, FireResist = 75, ColdResist = 75,
			LightningResist = 75, ChaosResist = 0, ManaSustainMargin = 0, CombinedDPS = 10000,
		}
		local function runPhase(phase, budget)
			local storedBefore = PathExperience.Open(main.userPath, Version.Snapshot(build))
			assert.is_true(storedBefore.status == "empty" or storedBefore.status == "ready", json.encode(storedBefore))
			local maxAddedPoints = (phase == "tree" or phase == "combined") and 6 or 0
			local nativeTreePointLimit
			if phase == "tree" and fullTreeBudget then
				local extraPoints = build.calcsTab.mainOutput and build.calcsTab.mainOutput.ExtraPoints or 0
				local levelLimit = build.characterLevelAutoMode and 120
					or build:GetPassivePointLimitForLevel(build.characterLevel, extraPoints)
				maxAddedPoints = math.min(120, 111, levelLimit)
				nativeTreePointLimit = maxAddedPoints
			end
			local matrix = {
				generationPhase = phase, baseClassId = tostring(witchId),
				scenarioProfile = scenarioProfile or "Current",
				scenarioEnemyPreset = scenarioEnemyPreset or "Active",
				scenarioEnemyLevel = scenarioEnemyLevel and tostring(scenarioEnemyLevel) or "",
				ascendancyId = (phase == "tree" or phase == "combined") and tostring(necromancerId) or "",
				requiredNodeIds = (phase == "tree" or phase == "combined") and tostring(requiredAscendancyNode) or "",
				objectiveMetric = "FullDPS", damageFocus = "Minions",
				targetSkillGroupIndex = tostring(seed.groupIndex), targetSkillIndex = tostring(seed.skillIndex),
				targetSkillGemId = gemId, maxAddedPoints = tostring(maxAddedPoints),
				maxTotalPoints = "111", evaluationBudget = tostring(budget), seed = "21102026",
                searchStoredItems = (phase == "equipment" or phase == "combined") and "true" or "false",
                searchSyntheticGear = (phase == "equipment" or phase == "combined") and "true" or "false",
                syntheticItemLevel = (phase == "equipment" or phase == "combined") and "86" or "",
                damageFocus = gemId == "Metadata/Items/Gems/SkillGemRaiseZombie" and "Minions" or "Fire",
			}
			if phase == "combined" and strictCombined then
				for metric, value in pairs(strictFloors) do matrix[metric] = tostring(value) end
			end
			local before = Candidate.BuildSignature(build)
			local started, startError
			if expectUncertifiedMinion or useLocalMcp then
				assert.is_nil(MCP.listener, "This regression must use the native tool route without a TCP listener")
				local response
				response, startError = MCP:CallLocal("optimizer_start", { matrix = matrix })
				fixtureJobId = response and response.jobId
				if fixtureJobId then fixtureJobIds[#fixtureJobIds + 1] = fixtureJobId end
				started = fixtureJobId ~= nil
			else
				started, startError = tab:StartOptimizer(matrix)
			end
			assert.is_true(started, startError)
			for _ = 1, 10000 do
				if not tab.job then break end
				tab:Tick()
			end
			assert.is_nil(tab.job, "The bounded " .. phase .. " search must terminate")
			assert.are.equal(before, Candidate.BuildSignature(build), "Search must preserve the source before Apply")
			local result = assert(tab.result, "No result in " .. phase .. ": " .. tostring(tab.statusMessage))
			lastPhaseResult = result
			if phase == "tree" and fullTreeBudget and result.status == "feasible" then
				assert.is_true(result.evaluation.passivePointsUsed <= maxAddedPoints,
					"Full-scope tree result must stay inside its level-derived candidate budget")
				assert.is_true(result.evaluation.passivePointsUsed <= build:GetPassivePointLimitForLevel(build.characterLevel,
					build.calcsTab.mainOutput.ExtraPoints or 0), "Full-scope tree result must obey PoB's native level/quest limit")
				if result.evaluation.passivePointsUsed < maxAddedPoints then
					assert.is_truthy(tab.statusMessage:find("Partial tree checkpoint", 1, true),
						"A bounded candidate that spends fewer points must be labeled as an incomplete tree checkpoint")
				end
			end
			local learning = assert(result.searchCoverage.pathLearning, "The exact search must report its path-memory outcome")
			assert.are.equal(result.evaluations, learning.exactObservations, json.encode(learning))
			assert.are.equal("ready", learning.storageStatus, json.encode(learning))
			assert.are.equal(learning.exactObservations, (learning.storedThisRun or 0) + (learning.duplicatesThisRun or 0),
				"Every exact observation must be persisted or identified as a duplicate")
			local storedAfter = PathExperience.Open(main.userPath, Version.Snapshot(build))
			assert.are.equal("ready", storedAfter.status, json.encode({ learning = learning, stored = storedAfter }))
			assert.are.equal(storedAfter.totalRecords, storedAfter.compatibleRecords)
			assert.are.equal(storedBefore.compatibleRecords + learning.storedThisRun, storedAfter.compatibleRecords,
				"Reopening the store must read every newly persisted exact observation")
			if phase == "combined" and strictCombined then
				if result.status == "feasible" then
					for metric, required in pairs(strictFloors) do
						assert.is_true(type(result.evaluation.metrics[metric]) == "number" and result.evaluation.metrics[metric] >= required,
							"A Combined candidate must satisfy the unrounded strict QA floor for " .. metric)
					end
				else
					assert.are.equal("no_feasible_candidate", result.status)
					assert.is_nil(result.candidate, "Strict Combined must never expose an infeasible fallback")
					assert.is_true(result.evaluations > 0)
					assert.is_true(result.searchBaseline and result.searchBaseline.exact)
					assert.is_truthy(result.bestObservedIdentity)
					assert.is_true(#(result.bestObservedViolations or { }) > 0,
						"An infeasible bounded Combined run must preserve its exact best-observed deficits")
					assert.is_true(result.searchCoverage.syntheticGear.generatedCandidates > 0,
						"Strict Combined must generate native synthetic gear proposals")
					assert.is_true(result.searchCoverage.syntheticGear.exactEvaluations > 0,
					"A locked Necromancer route must not structurally discard every synthetic gear candidate before exact PoB: "
						.. json.encode(result.searchCoverage.syntheticGear))
					assert.is_true(#(result.nearMisses or { }) > 0,
						"Exact failed combinations must be preserved as non-deliverable near misses for the AI Planner")
					for _, nearMiss in ipairs(result.nearMisses) do
						assert.is_true(nearMiss.exact)
						assert.is_false(nearMiss.feasible)
						assert.is_table(nearMiss.metrics)
						for _, violation in ipairs(nearMiss.violations or { }) do
							assert.is_false(violation.key == "passive_point_limit" or violation.key == "passive_point_cap",
								"A candidate over PoB's native passive-point budget is not a legal near miss")
						end
					end
					local applyResult, applyError
					if useLocalMcp then
						local status, statusError = MCP:CallLocal("optimizer_status", { jobId = fixtureJobId })
						assert.is_truthy(status, statusError)
						assert.are.equal("no_feasible_candidate", status.status)
						assert.is_nil(status.best, "Ask AI status must not advertise an infeasible fallback")
						applyResult, applyError = MCP:CallLocal("optimizer_apply", { jobId = fixtureJobId, candidateIndex = 0 })
						assert.is_nil(applyResult, "MCP Apply must reject a Combined result with unmet hard floors")
						assert.is_truthy(tostring(applyError):find("no candidate that passed every hard gate", 1, true), applyError)
					else
					applyResult = tab:ApplyResult()
					assert.is_false(applyResult)
				end
					assert.are.equal(before, Candidate.BuildSignature(build), "Rejected strict Combined output must leave the source unchanged")
					print("QA_CASE " .. json.encode({ fixture = "witch-necromancer-fireball-strict-combined", status = result.status,
						exactEvaluations = result.evaluations, candidateDelivered = false, sourcePreserved = true,
						bestObservedMetrics = result.bestObservedMetrics, bestObservedViolations = result.bestObservedViolations,
						qualityFloors = strictFloors, searchCoverage = result.searchCoverage,
						applyRejected = true }))
					return false
				end
			end
			if expectUncertifiedMinion then
				assert.are.equal("no_feasible_candidate", result.status)
				assert.is_nil(result.candidate)
				assert.is_true(result.searchBaseline and result.searchBaseline.exact,
					"The bounded run should expose its exact baseline even when every candidate fails a hard gate")
				assert.is_true(type(result.searchBaseline.metrics.FullDPS) == "number")
				assert.are.equal("exact_calculation", result.failureEvidence,
					"An omitted-node structural penalty must not hide exact unsupported minion cadence")
				assert.is_true(result.evaluations > 0)
				assert.is_true(type(result.bestObservedMetrics.FullDPS) == "number" and result.bestObservedMetrics.FullDPS > 0)
				assert.is_truthy(result.bestObservedIdentity)
				assert.are.equal("Witch", result.bestObservedIdentity.baseClass)
				assert.are.equal("Necromancer", result.bestObservedIdentity.ascendancy)
				local cadenceGate
				for _, violation in ipairs(result.bestObservedViolations) do
					if violation.key == "activity_sustain_unsupported" then cadenceGate = violation end
				end
				assert.is_truthy(cadenceGate, "Raise Zombie's unmodeled summon/replacement cadence must remain explicit")
				local summary, summaryError = MCP:CallLocal("optimizer_status", { jobId = fixtureJobId })
				assert.is_truthy(summary, summaryError)
				assert.are.equal("exact_calculation", summary.failureEvidence)
				assert.are.equal("no_feasible_candidate", summary.status)
				assert.is_nil(summary.best)
				assert.are.equal("Witch", summary.bestObservedIdentity.baseClass)
				assert.are.equal("Necromancer", summary.bestObservedIdentity.ascendancy)
				assert.are.equal(result.bestObservedMetrics.FullDPS, summary.bestObservedMetrics.FullDPS)
				local mcpCadenceGate
				for _, violation in ipairs(summary.bestObservedViolations) do
					if violation.key == "activity_sustain_unsupported" then mcpCadenceGate = violation end
				end
				assert.is_truthy(mcpCadenceGate)
				assert.are.equal(cadenceGate.reason, mcpCadenceGate.reason)
				local applied = tab:ApplyResult()
				assert.is_false(applied)
				assert.are.equal(before, Candidate.BuildSignature(build))
				print("QA_CASE " .. json.encode({ fixture = "witch-necromancer-raise-zombie", status = result.status,
					evidence = result.failureEvidence, exactEvaluations = result.evaluations, fullDPS = result.bestObservedMetrics.FullDPS,
					blockedReason = cadenceGate.reason, sourcePreserved = true, candidateDelivered = false }))
				return
			end
			assert.are.equal("feasible", result.status, phase .. ": " .. tostring(tab.statusMessage) .. " / " .. tostring(result.message)
				.. " / deficits=" .. json.encode(result.bestObservedViolations or { }))
			assert.is_true(result.evaluations > 0)
			assert.are.equal(phase, result.generationPhase)
			assert.is_true(result.searchBaseline and result.searchBaseline.exact,
				"The exact search baseline must accompany each feasible candidate")
			assert.is_true(type(result.searchBaseline.metrics.FullDPS) == "number")
			if scenarioEnemyPreset then
				assert.are.equal(scenarioProfile, result.evaluation.scenario.profile)
				assert.are.equal(scenarioEnemyPreset, result.evaluation.scenario.enemyIsBoss,
					"the completed exact evaluation must report the native enemy preset applied to its isolated config clone")
			end
			if scenarioEnemyLevel then
				assert.are.equal(scenarioEnemyLevel, result.evaluation.scenario.enemyLevelOverride,
					"the exact result must report the explicit native PoB enemy-level override")
				assert.are.equal(scenarioEnemyLevel, result.evaluation.scenario.resolvedEnemyLevel,
					"PoB ConfigTab must resolve the requested enemy level in the isolated exact calculation")
				assert.are.equal("native_enemy_level_only_no_area_specific_monster_data", result.evaluation.scenario.enemyLevelScope)
			end
			local applied, applyError
			if useLocalMcp then
				local summary, summaryError = MCP:CallLocal("optimizer_status", { jobId = fixtureJobId })
				assert.is_truthy(summary, summaryError)
				assert.is_truthy(summary.best and summary.best.feasible, "MCP status must return the exact-feasible candidate")
				assert.is_table(summary.best.enabledSkillsPayability,
					"MCP status must expose the strict enabled-skill upfront-payability gate")
				assert.are.equal("pass", summary.best.enabledSkillsPayability.status)
				assert.are.equal(phase, summary.best.generationPhase)
				assert.is_true(summary.searchBaseline and summary.searchBaseline.exact,
					"MCP status must expose the exact baseline used for the search")
				assert.is_true(summary.baselineComparison and summary.baselineComparison.exact,
					"MCP status must expose exact candidate-minus-baseline metric deltas")
				assert.are.equal(result.searchBaseline.metrics.FullDPS, summary.searchBaseline.metrics.FullDPS)
				assert.are.equal(result.evaluation.metrics.FullDPS - result.searchBaseline.metrics.FullDPS,
					summary.baselineComparison.metricDelta.FullDPS)
				assert.are.equal(summary.baselineComparison.metricDelta.FullDPS,
					summary.best.metricDeltaFromSearchBaseline.FullDPS)
				for _, alternative in ipairs(summary.alternatives or { }) do
					assert.is_table(alternative.metricDeltaFromSearchBaseline,
						"Every exact Pareto alternative must include its delta from the same search baseline")
				end
				if scenarioEnemyPreset then
					assert.are.equal(scenarioProfile, summary.scenario.profile)
					assert.are.equal(scenarioEnemyPreset, summary.scenario.enemyIsBoss,
						"the local MCP status must expose the enemy tier used by the exact PoB calculation")
				end
				if scenarioEnemyLevel then
					assert.are.equal(scenarioEnemyLevel, summary.scenario.enemyLevelOverride,
						"the local MCP status must expose the exact enemy level used by the isolated PoB calculation")
					assert.are.equal(scenarioEnemyLevel, summary.scenario.resolvedEnemyLevel,
						"the local MCP status must preserve the enemy level resolved by PoB ConfigTab")
				end
				if phase == "skills" then
					assert.is_true(summary.best.unlinkedMainSkillPlan,
						"The Skills checkpoint must tell the chat that the seed is still unlinked")
                elseif phase == "equipment" or phase == "combined" then
                    assert.is_true(summary.best.requiresSocketedMainSkill,
                        "Equipment and Combined must declare that the selected Main Skill requires native socket proof")
                    assert.are.equal("linked", summary.best.skillSocket and summary.best.skillSocket.status,
                        "MCP status must expose PoB's native socket/link proof")
                    if phase == "equipment" then
                        local binding = summary.best.gearVariant and summary.best.gearVariant.socketBinding
                        assert.is_truthy(binding, "MCP Equipment status must expose the exact generated socket binding")
                        assert.are.equal(seed.groupIndex, binding.groupIndex)
                        assert.are.equal(binding.slotName, summary.best.skillSocket.slot)
                        assert.are.equal(binding.socketCount, summary.best.skillSocket.socketCount)
                        assert.are.equal(binding.linkGroup, summary.best.skillSocket.linkGroup)
                        local invalidCandidate = { }
                        for key, value in pairs(result.candidate) do invalidCandidate[key] = value end
                        invalidCandidate.evaluation = { }
                        for key, value in pairs(result.candidate.evaluation) do invalidCandidate.evaluation[key] = value end
                        invalidCandidate.evaluation.skillSocket = nil
                        local invalidApplied, invalidApplyError = Candidate.Apply(build, invalidCandidate)
                        assert.is_false(invalidApplied, "Equipment Apply must fail closed without exact native socket evidence")
                        assert.is_truthy(tostring(invalidApplyError):find("exact PoB Main Skill socket/link proof", 1, true))
                        assert.are.equal(before, Candidate.BuildSignature(build), "A rejected socket proof must not mutate the source build")
                    end
				end
				local applyResponse
				applyResponse, applyError = MCP:CallLocal("optimizer_apply", { jobId = fixtureJobId, candidateIndex = 0 })
				applied = applyResponse and applyResponse.applied == true
			else
				applied, applyError = tab:ApplyResult()
			end
			assert.is_true(applied, applyError)
			build.calcsTab:BuildOutput()
			local appliedExactOutput
			if (not scenarioProfile or scenarioProfile == "Current") and not scenarioEnemyLevel then
				appliedExactOutput = build.calcsTab.mainOutput
				assert.are.equal(result.evaluation.metrics.FullDPS, build.calcsTab.mainOutput.FullDPS,
					"The applied Current-scenario result must match the optimizer's exact FullDPS")
			else
				local proxy = { spec = build.spec, skillsTab = build.skillsTab, itemsTab = build.itemsTab }
				setmetatable(proxy, { __index = build })
				local scenarioConfig, scenarioItems, details, scenarioError = Scenario.Create(build, scenarioProfile, proxy,
					require("Modules.ConfigOptions"), result.candidate.configurationVariant, scenarioEnemyPreset, scenarioEnemyLevel)
				assert.is_nil(scenarioError)
				proxy.configTab, proxy.itemsTab = scenarioConfig, scenarioItems
				local override = Scenario.CalculationOverride(scenarioProfile)
				override.spec = build.spec
				override.returnEnv = true
				local exactScenarioCalc = Calcs.getMiscCalculator(proxy, Scenario.CalculationOverride(scenarioProfile))
				local exactScenarioOutput = exactScenarioCalc(override, true)
				appliedExactOutput = exactScenarioOutput
				assert.are.equal(scenarioEnemyPreset, details.enemyIsBoss)
				if scenarioEnemyLevel then
					assert.are.equal(scenarioEnemyLevel, details.enemyLevelOverride)
					assert.are.equal(scenarioEnemyLevel, details.resolvedEnemyLevel)
				end
				assert.are.equal(result.evaluation.metrics.FullDPS, exactScenarioOutput.FullDPS,
					"An applied candidate must reproduce the same FullDPS when recalculated in its exact isolated scenario")
			end
			-- Compare strict Matrix metrics against the native scalar CALCS output
			-- after Apply. This covers every numeric gate, not only the objective.
			local appliedMetrics = Candidate.CopyMetrics(appliedExactOutput, Inputs.metricDefinitions)
			for _, definition in ipairs(Inputs.metricDefinitions) do
				local metricKey = definition.metricKey or definition.key
				local expected = result.evaluation.metrics[metricKey]
				local actual = appliedMetrics[metricKey]
				if expected ~= nil then
					assert.are.equal(expected, actual, "Apply changed exact hard-gate metric " .. metricKey)
				end
				local requested = matrix[definition.key]
				if requested ~= nil and tostring(requested):match("%S") then
					assert.is_true(type(actual) == "number", "Applied PoB output omitted requested hard-gate metric " .. metricKey)
				end
			end
			-- Activity-ledger metrics come from PoB's per-skill records, not scalar
			-- CALCS fields; recalculate and compare those independently.
			local appliedActivity = Activity.Evaluate(assert(Inputs.Parse(matrix)),
				appliedExactOutput.OptimizerMainSkillActivity, appliedExactOutput.FullDPSActivity,
				appliedExactOutput.FullDPSActivityTruncated)
			local expectedActivity = result.evaluation.activitySustain
			assert.are.equal(expectedActivity.status, appliedActivity.status, "Apply changed native activity certification")
			for key, value in pairs(expectedActivity.metrics or { }) do
				assert.are.equal(value, appliedActivity.metrics[key], "Apply changed exact activity metric " .. key)
			end
			local appliedSocketInfo
			if useLocalMcp and phase == "equipment" then
				local linked, socketDetails = SkillCatalog.ValidateSocketGroup(build, seed.groupIndex)
				assert.is_true(linked, type(socketDetails) == "string" and socketDetails or "MCP Apply must create a native linked group")
				appliedSocketInfo = socketDetails
			end
			stages[#stages + 1] = { phase = phase, evaluations = result.evaluations,
				passivePoints = result.evaluation.passivePointsUsed, maxAddedPoints = maxAddedPoints,
				nativeTreePointLimit = nativeTreePointLimit,
				fullDPS = build.calcsTab.mainOutput.FullDPS, life = build.calcsTab.mainOutput.Life,
				energyShield = build.calcsTab.mainOutput.EnergyShield }
			if useLocalMcp and phase == "skills" then
				local snapshot, snapshotError = MCP:CallLocal("get_build_snapshot", { })
				assert.is_truthy(snapshot, snapshotError)
				assert.are.equal("", snapshot.skillGroups[seed.groupIndex].slot,
					"The Skills checkpoint must remain explicitly unlinked before Equipment is applied")
			end
			if useLocalMcp and phase == "equipment" then
				local snapshot, snapshotError = MCP:CallLocal("get_build_snapshot", { })
				assert.is_truthy(snapshot, snapshotError)
				local group = assert(snapshot.skillGroups[seed.groupIndex])
				assert.are.equal(appliedSocketInfo.slot, group.slot)
				local activeSlot
				for _, equippedSlot in ipairs(snapshot.equippedSlots) do
					if equippedSlot.slot == group.slot and equippedSlot.active then activeSlot = equippedSlot break end
				end
				assert.is_truthy(activeSlot, "MCP snapshot must identify the active item behind the skill group")
				local item = assert(snapshot.items[activeSlot.itemId])
				assert.are.equal(activeSlot.itemId, item.id)
				assert.are.equal(#group.gems, #item.sockets,
					"MCP snapshot must expose one native socket per gem in the selected group")
				local linkGroups = { }
				for _, socket in ipairs(item.sockets) do linkGroups[socket.linkGroup] = true end
				local linkGroupCount = 0
				for _ in pairs(linkGroups) do linkGroupCount = linkGroupCount + 1 end
				assert.are.equal(1, linkGroupCount, "Main Skill and supports must share one native PoB link group")
				assert.are.equal(appliedSocketInfo.linkGroup, item.sockets[1].linkGroup)
			end
			return true
		end
		runPhase("tree", 32)
		if fullTreeOnly then
			assert.are.equal("tree", stages[1].phase)
			assert.is_true(stages[1].evaluations > 0)
			assert.is_true(stages[1].passivePoints <= stages[1].nativeTreePointLimit)
			local routeCoverage = assert(lastPhaseResult.searchCoverage.phase)
			local routePoolCoverage = assert(lastPhaseResult.searchCoverage.zones)
			assert.is_true(routeCoverage.generatedProgressiveTreeBundles > 0,
				"Full-range tree search should generate progressive multi-goal candidates")
			assert.is_true(routeCoverage.maxProgressiveRouteCount > 0,
				"Progressive search coverage should report the number of distinct useful routes in its largest bundle")
			assert.is_true(routePoolCoverage.progressiveRouteDistinctGoals > 0,
				"Broad proposal generation should report distinct passive goals, not only exact-evaluation slots")
			local populatedRouteRegions = 0
			for _, goalCount in pairs(routePoolCoverage.progressiveRouteGoalsByRegion or { }) do
				if goalCount > 0 then populatedRouteRegions = populatedRouteRegions + 1 end
			end
			assert.is_true(populatedRouteRegions >= 5,
				"Broad route proposals should cover several native passive-tree regions")
			local progressiveRouteDiagnostics = {
				generatedBundles = routeCoverage.generatedProgressiveTreeBundles,
				proposedBundles = routeCoverage.proposedProgressiveTreeBundles,
				retainedBundles = routeCoverage.retainedProgressiveTreeBundles,
				proposedSelectedAscendancyBundles = routeCoverage.proposedLockedProgressiveAscendancyCandidates,
				retainedSelectedAscendancyBundles = routeCoverage.retainedLockedProgressiveAscendancyCandidates,
				progressiveAscendancyReservationStatus = routeCoverage.progressiveTreeAscendancyReservationStatus,
				progressiveAscendancyReservationPosition = routeCoverage.progressiveTreeAscendancyReservationPosition,
				generatedTreeAscendancyCombinations = routeCoverage.generatedTreeAscendancyCombinations,
				exactTreeAscendancyCombinations = routeCoverage.exactTreeAscendancyCombinations,
				exactProgressiveTreeBundleEvaluations = routeCoverage.exactProgressiveTreeBundleEvaluations,
				exactProgressiveTreeAscendancyBundleEvaluations = routeCoverage.exactProgressiveTreeAscendancyBundleEvaluations,
				structuralTreeRejections = routeCoverage.structuralTreeRejections,
				structuralProgressiveTreeBundleRejections = routeCoverage.structuralProgressiveTreeBundleRejections,
				firstProgressiveTreeStructuralRejection = routeCoverage.firstProgressiveTreeStructuralRejection,
				progressiveTreeEvaluationSummaries = routeCoverage.progressiveTreeEvaluationSummaries,
				generatedCandidates = routeCoverage.generatedCandidates,
				uniqueCandidates = routeCoverage.uniqueCandidates,
				retainedCandidates = routeCoverage.retainedCandidates,
				discardedByProposalBudget = routeCoverage.discardedByProposalBudget,
				proposalFamilyCountsAfter = routeCoverage.proposalFamilyCountsAfter,
				progressiveRoutePool = routePoolCoverage,
			}
			assert.is_true(routeCoverage.exactProgressiveTreeBundleEvaluations > 0,
				"A progressive route must be paired with the selected ascendancy and reach exact PoB evaluation: "
					.. json.encode(progressiveRouteDiagnostics))
			assert.are.equal("reserved", routeCoverage.progressiveTreeAscendancyReservationStatus,
				"The post-ranking exact prefix must reserve one paired progressive bundle: " .. json.encode(progressiveRouteDiagnostics))
			assert.are.equal(2, routeCoverage.progressiveTreeAscendancyReservationPosition,
				"Keep the exact baseline first and the selected progressive route second: " .. json.encode(progressiveRouteDiagnostics))
			assert.is_true(routeCoverage.retainedLockedProgressiveAscendancyCandidates > 0,
				"At least one selected-ascendancy bundle must survive the proposal cap: " .. json.encode(progressiveRouteDiagnostics))
			assert.is_true(routeCoverage.exactProgressiveTreeAscendancyBundleEvaluations > 0,
				"A progressive bundle carrying the selected ascendancy must reach exact PoB evaluation: "
					.. json.encode(progressiveRouteDiagnostics))
			assert.is_true(routeCoverage.exactTreeAscendancyCombinations > 0,
				"A paired tree/ascendancy candidate must reach an exact PoB evaluation: "
					.. json.encode(progressiveRouteDiagnostics))
			local evaluatedSelectedAscendancy = false
			for _, summary in ipairs(routeCoverage.progressiveTreeEvaluationSummaries or { }) do
				if summary.selectedAscendancy == "Necromancer" and summary.combinedTreeAscendancy then
					evaluatedSelectedAscendancy = true
					break
				end
			end
			assert.is_true(evaluatedSelectedAscendancy,
				"The exact progressive tree evaluation must retain the paired Necromancer ascendancy: "
					.. json.encode(progressiveRouteDiagnostics))
			assert.is_true(routeCoverage.largestProposedTreePointCount <= stages[1].nativeTreePointLimit,
				"Progressive main-tree proposals must stay within PoB's legal point ceiling")
			assert.is_true(routeCoverage.largestExactTreePointCount <= stages[1].nativeTreePointLimit,
				"Every exact candidate must remain inside PoB's level/quest point limit")
			if stages[1].passivePoints < stages[1].nativeTreePointLimit then
				assert.is_truthy(tab.statusMessage:find("Partial tree checkpoint", 1, true),
					"Apply must retain the partial-tree warning after the result is committed as a reversible checkpoint")
			end
			print("QA_CASE " .. json.encode({ fixture = "witch-necromancer-fireball-full-level-tree-budget",
				candidateMainPoints = stages[1].passivePoints, maxAddedPoints = stages[1].maxAddedPoints,
				nativeTreePointLimit = stages[1].nativeTreePointLimit,
				exactEvaluations = stages[1].evaluations, nativeLevel = build.characterLevel,
				routeCoverage = routeCoverage,
				routePoolCoverage = routePoolCoverage,
				objectiveValue = lastPhaseResult.evaluation and lastPhaseResult.evaluation.metrics
					and lastPhaseResult.evaluation.metrics.FullDPS,
				class = build.spec.curClass.name, sourceUnmodifiedDuringSearch = true,
				certification = "bounded_level_legal_tree_phase_only" }))
			newBuild()
			return
		end
		if expectUncertifiedMinion then newBuild(); return end
		assert.are.equal(witchId, build.spec.curClassId)
		assert.are.equal(necromancerId, build.spec.curAscendClassId)
		assert.is_truthy(build.spec.allocNodes[requiredAscendancyNode])
		runPhase("skills", 36)
		assert.are.equal("AI Planner — Skills checkpoint", main.popups[1].title)
		main.popups[1].controls.yes:Click()
		runPhase("equipment", 32)
		local linked, socketInfo = SkillCatalog.ValidateSocketGroup(build, seed.groupIndex)
		assert.is_true(linked, type(socketInfo) == "string" and socketInfo or "A real item link is required")
		assert.are.equal("linked", socketInfo.status)
		local combinedApplied = runPhase("combined", 48)
		if strictCombined and combinedApplied == false then newBuild(); return end
		linked, socketInfo = SkillCatalog.ValidateSocketGroup(build, seed.groupIndex)
		assert.is_true(linked, type(socketInfo) == "string" and socketInfo or "Combined must preserve the native Main Skill link")
		assert.are.equal("linked", socketInfo.status)
		local topology, topologyError = TreeSearch.ValidateCandidate(build.spec, { },
			assert(Inputs.Parse({ maxTotalPoints = "111" })), TreeSearch.BuildRegionMap(build.spec), { }, build.spec)
		assert.is_true(topology, topologyError)
		local mainPoints, ascendancyPoints = build.spec:CountAllocNodes()
		assert.is_true(mainPoints <= 111 and ascendancyPoints > 0 and ascendancyPoints <= 8)
		local output = build.calcsTab.mainOutput
		assert.is_true(type(output.FullDPS) == "number" and output.FullDPS > 0)
		assert.are.equal(witchId, build.spec.curClassId)
		assert.are.equal(necromancerId, build.spec.curAscendClassId)
		for id, class in pairs(build.spec.tree.classes) do
			if id ~= witchId then assert.is_nil(build.spec.allocNodes[class.startNodeId], "Only the selected class root may be allocated") end
		end
		local beforeReload = { FullDPS = output.FullDPS, Life = output.Life, EnergyShield = output.EnergyShield, Mana = output.Mana }
		local xml = assert(build:SaveDB("AI Planner QA control"))
		loadBuildFromXML(xml, "AI Planner QA control")
		build.calcsTab:BuildOutput()
		assert.are.equal(witchId, build.spec.curClassId)
		assert.are.equal(necromancerId, build.spec.curAscendClassId)
		for metric, value in pairs(beforeReload) do
			assert.are.equal(value, build.calcsTab.mainOutput[metric], "Native XML round-trip changed " .. metric)
		end
		local reloadedLinked = SkillCatalog.ValidateSocketGroup(build, seed.groupIndex)
		assert.is_true(reloadedLinked)
		print("QA_CASE " .. json.encode({ fixture = "witch-necromancer-fireball-control", treeVersion = build.spec.treeVersion,
			class = build.spec.curClass.name, ascendancy = build.spec.curAscendClass.name,
			mainPoints = mainPoints, ascendancyPoints = ascendancyPoints, linked = linked, stages = stages, nativeXMLRoundTrip = true,
			applyRoute = useLocalMcp and "direct_local_mcp" or "optimizer_tab",
			certification = "bounded_native_generation_only_not_endgame_or_campaign_quality" }))
		newBuild()
	end
	it("reports exact minion cadence failures rather than an unrelated rejected route and refuses Apply", function()
		generate("Metadata/Items/Gems/SkillGemRaiseZombie", true)
	end)
	it("runs tree, skills and linked equipment for a Witch Necromancer spell control through the native planner", function()
		generate("Metadata/Items/Gems/SkillGemFireball", false)
	end)
	it("uses PoB's exact level allowance for a bounded full-scope fresh tree search", function()
		generate("Metadata/Items/Gems/SkillGemFireball", false, false, nil, nil, false, true, true)
	end)
	it("runs tree, skills and linked equipment through the direct local MCP start/status/apply path", function()
		generate("Metadata/Items/Gems/SkillGemFireball", false, true, "PinnacleUnbuffed", "Uber")
	end)
	it("uses a custom PoB enemy level in the isolated exact optimizer and MCP calculation", function()
		generate("Metadata/Items/Gems/SkillGemFireball", false, true, "Current", "Boss", false, false, false, 68)
	end)
	it("fails closed on unmet Combined defense, sustain, and offense floors through MCP", function()
		generate("Metadata/Items/Gems/SkillGemFireball", false, true, "PinnacleUnbuffed", "Uber", true)
	end)
	it("bounds direct job history and cancellation without relying on the transport polling loop", function()
		newBuild()
		assert.is_nil(MCP.listener)
		local source = Candidate.BuildSignature(build)
		local previousId
		for _ = 1, 12 do
			local started, startError = MCP:CallLocal("optimizer_start", { matrix = {
				generationPhase = "tree", objectiveMetric = "TotalEHP", evaluationBudget = "1", maxAddedPoints = "0",
			} })
			assert.is_truthy(started, startError)
			fixtureJobId = started.jobId
			assert.are_not.equal(previousId, fixtureJobId)
			previousId = fixtureJobId
			assert.is_truthy(MCP:CallLocal("optimizer_cancel", { jobId = fixtureJobId }))
			for _ = 1, 1000 do if not build.optimizerTab.job then break end; build.optimizerTab:Tick() end
			local status = assert(MCP:CallLocal("optimizer_status", { jobId = fixtureJobId }))
			assert.are.equal("cancelled", status.status)
			assert.are.equal(0, status.evaluations)
			local count = 0
			for _ in pairs(MCP.jobs) do count = count + 1 end
			assert.is_true(count <= 8, "Direct Ask AI must not retain an unbounded job history while TCP is offline")
			assert.are.equal(source, Candidate.BuildSignature(build))
		end
		newBuild()
	end)
end)
