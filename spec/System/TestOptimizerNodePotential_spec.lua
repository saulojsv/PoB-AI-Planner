local Candidate = require("Modules.Optimizer.Candidate")
local Calcs = require("Modules.Calcs")
local Inputs = require("Modules.Optimizer.Inputs")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local SkillSeed = require("Modules.Optimizer.SkillSeed")
local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local TreeSearch = require("Modules.Optimizer.TreeSearch")
local OptimizerTab = require("Classes.OptimizerTab")

local function lower(value)
	return tostring(value or ""):lower()
end

describe("AI Planner exact node-potential review", function()
	it("uses explicit damage and defense preferences to order normal route proposals", function()
		newBuild()
		local rootSpec, rootError = Candidate.BuildPassiveSpec(build, { }, { }, { classId = build.spec.curClassId })
		assert.is_truthy(rootSpec, rootError)
		local regions = assert(TreeSearch.BuildRegionMap(rootSpec, "class"))
		local automatic = assert(Inputs.Parse({
			generationPhase = "combined", maxAddedPoints = "12", evaluationBudget = "12", seed = "19",
		}))
		local focused = assert(Inputs.Parse({
			generationPhase = "combined", maxAddedPoints = "12", evaluationBudget = "12", seed = "19",
			damageFocus = "Fire", defenseProfile = "Life",
		}))
		assert.is_false(automatic.search.nodePotentialAnalysis)
		assert.is_false(focused.search.nodePotentialAnalysis)
		local function orderedTargets(parsed)
			local candidates, err = TreeSearch.BuildCandidateNodes(rootSpec, parsed, 12, nil, 12, nil, regions)
			assert.is_truthy(candidates, err)
			local targetIds = { }
			for _, candidate in ipairs(candidates) do
				if candidate.targetId then targetIds[#targetIds + 1] = candidate.targetId end
			end
			return targetIds
		end
		local automaticTargets = orderedTargets(automatic)
		local focusedTargets = orderedTargets(focused)
		local repeatedFocusedTargets = orderedTargets(focused)
		assert.is_true(#automaticTargets > 0)
		assert.is_true(#focusedTargets > 0)
		assert.are_not.equal(table.concat(automaticTargets, ","), table.concat(focusedTargets, ","),
			"an explicit focus should change which routes fit first in the bounded proposal list")
		assert.are.same(focusedTargets, repeatedFocusedTargets, "preference-guided proposal order must remain deterministic")
	end)

	it("uses compatible imported node frequency to order ordinary tree proposals when enabled", function()
		newBuild()
		local rootSpec, rootError = Candidate.BuildPassiveSpec(build, { }, { }, { classId = build.spec.curClassId })
		assert.is_truthy(rootSpec, rootError)
		local regions = assert(TreeSearch.BuildRegionMap(rootSpec, "class"))
		local parsed = assert(Inputs.Parse({ generationPhase = "tree",
			maxAddedPoints = "3", evaluationBudget = "256", seed = "19", damageFocus = "Auto", defenseProfile = "Auto" }))
		local function targetsByRegion(inputs)
			local candidates, err = TreeSearch.BuildCandidateNodes(rootSpec, inputs, 256, nil, 3, nil, regions)
			assert.is_truthy(candidates, err)
			local result, seen = { }, { }
			for _, candidate in ipairs(candidates) do
				local region = candidate.targetId and regions[candidate.targetId]
				if region and not seen[candidate.targetId] then
					seen[candidate.targetId] = true
					result[region] = result[region] or { }
					result[region][#result[region] + 1] = candidate.targetId
				end
			end
			return result
		end
		local baseline = targetsByRegion(parsed)
		local selectedRegion, selectedNode
		for region, nodes in pairs(baseline) do
			if #nodes >= 2 then selectedRegion, selectedNode = region, nodes[2]; break end
		end
		assert.is_truthy(selectedNode, "the bounded passive search should expose multiple targets in one class region")
		parsed.search.nodeEvidencePriorities = { [selectedNode] = 1 }
		parsed.search.importedRouteMemoryEnabled = false
		local memoryOff = targetsByRegion(parsed)
		assert.are_not.equal(selectedNode, memoryOff[selectedRegion][1], "historical data must remain inert when the preference is off")
		parsed.search.importedRouteMemoryEnabled = true
		local prioritized = targetsByRegion(parsed)
		assert.are.equal(selectedNode, prioritized[selectedRegion][1],
			"an imported node pattern should move the tied target earlier in the bounded ordinary tree search")
		assert.are.equal(#baseline[selectedRegion], #prioritized[selectedRegion])
		for _, nodeIds in pairs(prioritized) do
			for _, nodeId in ipairs(nodeIds) do
				assert.is_truthy(rootSpec.nodes[nodeId], "historical priority must not invent or disconnect a passive node")
			end
		end
	end)

	it("uses already-calculated Show Node Power values as a deterministic route-ordering hint", function()
		newBuild()
		local rootSpec, rootError = Candidate.BuildPassiveSpec(build, { }, { }, { classId = build.spec.curClassId })
		assert.is_truthy(rootSpec, rootError)
		local regions = assert(TreeSearch.BuildRegionMap(rootSpec, "class"))
		local parsed = assert(Inputs.Parse({ generationPhase = "tree", maxAddedPoints = "3", evaluationBudget = "256", seed = "19" }))
		local function targetsByRegion(inputs)
			local candidates, err = TreeSearch.BuildCandidateNodes(rootSpec, inputs, 256, nil, 3, nil, regions)
			assert.is_truthy(candidates, err)
			local result = { }
			for _, candidate in ipairs(candidates) do
				local region = candidate.targetId and regions[candidate.targetId]
				if region then
					result[region] = result[region] or { }
					result[region][#result[region] + 1] = candidate.targetId
				end
			end
			return result
		end
		local baseline = targetsByRegion(parsed)
		local selectedRegion, selectedNode
		for region, nodeIds in pairs(baseline) do
			if #nodeIds >= 2 then selectedRegion, selectedNode = region, nodeIds[2]; break end
		end
		assert.is_truthy(selectedNode, "need two passive targets in one class region for an ordering comparison")
		for nodeId, node in pairs(rootSpec.nodes) do
			if not node.alloc and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
				node.power = { singleStat = 1, pathPower = 1, distance = 1 }
			end
		end
		rootSpec.nodes[selectedNode].power = { singleStat = 1000, pathPower = 1000, distance = 1 }
		parsed.search.useShowNodePower = true
		parsed.search.nodePowerStat = "CombinedDPS"
		parsed.search.nodePowerFocusStat = "CombinedDPS"
		local powered = targetsByRegion(parsed)
		assert.are.equal(selectedNode, powered[selectedRegion][1], "the native Node Power winner should lead its region")
		assert.are.equal("used", parsed.search.nodePowerCoverage.status)
		assert.is_true(parsed.search.nodePowerCoverage.prioritizedTargets > 0)
	end)

	it("uses matching native marginal Node Power to choose an equal-cost route connector", function()
		newBuild()
		local start = { id = 1, type = "ClassStart", alloc = true, x = 0, y = 0, linked = { } }
		local left = { id = 2, type = "Normal", alloc = false, x = 1, y = 0, linked = { } }
		local right = { id = 3, type = "Normal", alloc = false, x = 0, y = 1, linked = { } }
		local target = { id = 4, type = "Notable", alloc = false, x = 1, y = 1, linked = { } }
		local function connect(first, second)
			first.linked[#first.linked + 1] = second
			second.linked[#second.linked + 1] = first
		end
		connect(start, left)
		connect(left, target)
		connect(start, right)
		connect(right, target)
		local spec = {
			nodes = { [1] = start, [2] = left, [3] = right, [4] = target },
			allocNodes = { [1] = start },
			tree = { classes = { [1] = { name = "Test", startNodeId = 1 } } },
		}
		local parsed = assert(Inputs.Parse({ generationPhase = "tree", maxAddedPoints = "2",
			evaluationBudget = "8", seed = "17" }))
		parsed.targetNodeIds = { target.id }
		local function firstPath(inputs)
			local candidates, err = TreeSearch.BuildCandidateNodes(spec, inputs, 8, nil, 2)
			assert.is_truthy(candidates and candidates[1], err)
			assert.are.equal(2, candidates[1].routePointCost)
			return candidates[1]
		end
		local baseline = firstPath(parsed)
		local baselineConnector = baseline.nodeIds[1] == target.id and baseline.nodeIds[2] or baseline.nodeIds[1]
		local preferredConnector = baselineConnector == left.id and right or left
		preferredConnector.power = { singleStat = 1000 }
		parsed.search.useShowNodePower = true
		parsed.search.nodePowerStat = "CombinedDPS"
		parsed.search.nodePowerFocusStat = "CombinedDPS"
		local powered = firstPath(parsed)
		local usedPreferredConnector = powered.nodeIds[1] == preferredConnector.id
			or powered.nodeIds[2] == preferredConnector.id
		assert.is_true(usedPreferredConnector,
			"the matching native marginal Node Power should break a shortest-path tie")
		assert.are.equal("used", parsed.search.nodePowerCoverage.status)
		assert.are.equal("available", parsed.search.nodePowerCoverage.routePath.status)
		assert.are.equal(1, parsed.search.nodePowerCoverage.routePath.hintedNodes)

		left.power, right.power = nil, nil
		for nodeId = 100, 229 do
			local leaf = { id = nodeId, type = "Normal", alloc = false, x = nodeId, y = 2, linked = { } }
			spec.nodes[nodeId] = leaf
			connect(start, leaf)
		end
		local broadParsed = assert(Inputs.Parse({ generationPhase = "tree", maxAddedPoints = "2",
			evaluationBudget = "8", seed = "17" }))
		local function broadRouteToTarget(inputs)
			local candidates, err = TreeSearch.BuildCandidateNodes(spec, inputs, 32, nil, 2)
			assert.is_truthy(candidates, err)
			for _, candidate in ipairs(candidates) do
				if candidate.targetId == target.id then return candidate end
			end
			return nil
		end
		local broadBaseline = assert(broadRouteToTarget(broadParsed),
			"the shared route field should retain the requested Notable as a target")
		local broadBaselineConnector = broadBaseline.nodeIds[1] == target.id
			and broadBaseline.nodeIds[2] or broadBaseline.nodeIds[1]
		local broadPreferred = broadBaselineConnector == left.id and right or left
		broadPreferred.power = { singleStat = 1000 }
		target.power = { singleStat = 1 }
		broadParsed.search.useShowNodePower = true
		broadParsed.search.nodePowerStat = "CombinedDPS"
		broadParsed.search.nodePowerFocusStat = "CombinedDPS"
		local broadPowered = assert(broadRouteToTarget(broadParsed))
		assert.is_true(broadPowered.nodeIds[1] == broadPreferred.id or broadPowered.nodeIds[2] == broadPreferred.id,
			"the shared path field should use native marginal power to choose an equal-cost connector")
		assert.are.equal(2, broadPowered.routePointCost)

		parsed.search.nodePowerFocusStat = "TotalEHP"
		local mismatched = firstPath(parsed)
		assert.are.same(baseline.nodeIds, mismatched.nodeIds,
			"a cache for another stat must not guide the route")
		assert.are.equal("unavailable", parsed.search.nodePowerCoverage.routePath.status)
		newBuild()
	end)

	it("uses native Node Power utility to accept a longer path within the point cap", function()
		newBuild()
		local start = { id = 1, type = "ClassStart", alloc = true, linked = { } }
		local direct = { id = 2, type = "Normal", alloc = false, linked = { } }
		local highA = { id = 3, type = "Normal", alloc = false, linked = { } }
		local highB = { id = 4, type = "Normal", alloc = false, linked = { } }
		local target = { id = 5, type = "Notable", alloc = false, linked = { }, dn = "Target" }
		local function connect(left, right)
			left.linked[#left.linked + 1] = right
			right.linked[#right.linked + 1] = left
		end
		connect(start, direct)
		connect(direct, target)
		connect(start, highA)
		connect(highA, highB)
		connect(highB, target)
		local spec = {
			nodes = { [1] = start, [2] = direct, [3] = highA, [4] = highB, [5] = target },
			allocNodes = { [1] = start },
			tree = { classes = { [1] = { name = "Test", startNodeId = 1 } } },
		}
		local parsed = assert(Inputs.Parse({ generationPhase = "tree", maxAddedPoints = "3",
			evaluationBudget = "8", seed = "41" }))
		parsed.targetNodeIds = { target.id }
		local baseline = assert(TreeSearch.BuildCandidateNodes(spec, parsed, 8, nil, 3))[1]
		assert.are.same({ 2, 5 }, baseline.nodeIds, "without native power the shorter legal path should win")
		direct.power = { singleStat = -1000 }
		highA.power = { singleStat = 1000 }
		highB.power = { singleStat = 1000 }
		parsed.search.useShowNodePower = true
		parsed.search.nodePowerStat = "CombinedDPS"
		parsed.search.nodePowerFocusStat = "CombinedDPS"
		local powered = assert(TreeSearch.BuildCandidateNodes(spec, parsed, 8, nil, 3))[1]
		assert.are.same({ 3, 4, 5 }, powered.nodeIds,
			"utility-weighted A* should choose the longer path when its native power compensates for one extra point")
		assert.are.equal(3, powered.routePointCost)
		assert.is_true(powered.nodePowerGuidedPath)
		assert.are.equal(2, powered.nodePowerPathUtility)
		assert.is_true(parsed.search.nodePowerCoverage.routePath.utilityGuidedPathsGenerated > 0)
		newBuild()
	end)

	it("uses utility-weighted route cost in the shared path field", function()
		newBuild()
		local start = { id = 1, type = "ClassStart", alloc = true, linked = { } }
		local direct = { id = 2, type = "Normal", alloc = false, linked = { } }
		local highA = { id = 3, type = "Normal", alloc = false, linked = { } }
		local highB = { id = 4, type = "Normal", alloc = false, linked = { } }
		local target = { id = 5, type = "Notable", alloc = false, linked = { }, dn = "Target" }
		local function connect(left, right)
			left.linked[#left.linked + 1] = right
			right.linked[#right.linked + 1] = left
		end
		connect(start, direct)
		connect(direct, target)
		connect(start, highA)
		connect(highA, highB)
		connect(highB, target)
		local nodes = { [1] = start, [2] = direct, [3] = highA, [4] = highB, [5] = target }
		for nodeId = 6, 135 do
			local leaf = { id = nodeId, type = "Normal", alloc = false, linked = { } }
			nodes[nodeId] = leaf
			connect(start, leaf)
		end
		local spec = { nodes = nodes, allocNodes = { [1] = start },
			tree = { classes = { [1] = { name = "Test", startNodeId = 1 } } } }
		local parsed = assert(Inputs.Parse({ generationPhase = "tree", maxAddedPoints = "3",
			evaluationBudget = "32", seed = "43" }))
		local baselineCandidates = assert(TreeSearch.BuildCandidateNodes(spec, parsed, 32, nil, 3))
		local baseline
		for _, candidate in ipairs(baselineCandidates) do if candidate.targetId == target.id then baseline = candidate break end end
		assert.is_truthy(baseline, "the broad baseline should include the selected notable")
		assert.are.same({ 2, 5 }, baseline.nodeIds)
		direct.power = { singleStat = -1000 }
		highA.power = { singleStat = 1000 }
		highB.power = { singleStat = 1000 }
		target.power = { singleStat = 1 }
		parsed.search.useShowNodePower = true
		parsed.search.nodePowerStat = "CombinedDPS"
		parsed.search.nodePowerFocusStat = "CombinedDPS"
		local poweredCandidates = assert(TreeSearch.BuildCandidateNodes(spec, parsed, 32, nil, 3))
		local powered
		for _, candidate in ipairs(poweredCandidates) do if candidate.targetId == target.id then powered = candidate break end end
		assert.is_truthy(powered, "the broad weighted path field should retain the positive native target")
		assert.are.same({ 3, 4, 5 }, powered.nodeIds)
		assert.are.equal(3, powered.routePointCost)
		assert.is_true(powered.nodePowerGuidedPath)
		assert.is_true(parsed.search.nodePowerCoverage.routePath.utilityGuidedPathsGenerated > 0)
		assert.is_true(parsed.search.nodePowerCoverage.routePath.nonpositiveTargetsPruned > 0)
		newBuild()
	end)

	it("proposes bounded connected Node Power hotspot chains and reuses valid tree adjacency", function()
		newBuild()
		local start = { id = 1, type = "ClassStart", alloc = true, x = 0, y = 0, linked = { } }
		local first = { id = 2, type = "Notable", alloc = false, x = 1, y = 0, linked = { }, dn = "First Hotspot" }
		local connector = { id = 3, type = "Normal", alloc = false, x = 1, y = 1, linked = { } }
		local second = { id = 4, type = "Notable", alloc = false, x = 2, y = 1, linked = { }, dn = "Second Hotspot" }
		local function connect(left, right)
			left.linked[#left.linked + 1] = right
			right.linked[#right.linked + 1] = left
		end
		connect(start, first)
		connect(start, connector)
		connect(connector, second)
		first.power = { singleStat = 100 }
		second.power = { singleStat = 90 }
		local spec = {
			nodes = { [1] = start, [2] = first, [3] = connector, [4] = second },
			allocNodes = { [1] = start },
			tree = { classes = { [1] = { name = "Test", startNodeId = 1 } } },
		}
		local parsed = assert(Inputs.Parse({ generationPhase = "tree", maxAddedPoints = "4",
			evaluationBudget = "8", seed = "29" }))
		parsed.search.useShowNodePower = true
		parsed.search.nodePowerStat = "CombinedDPS"
		parsed.search.nodePowerFocusStat = "CombinedDPS"
		local function buildCandidates()
			local candidates, err = TreeSearch.BuildCandidateNodes(spec, parsed, 8, nil, 4)
			assert.is_truthy(candidates, err)
			return candidates
		end
		local candidates = buildCandidates()
		local chain
		for _, candidate in ipairs(candidates) do
			if candidate.routeFamily == "node_power_hotspot_chain" then chain = candidate; break end
		end
		assert.is_truthy(chain, "matching native values should add a connected hotspot proposal")
		assert.are.same({ 2, 4 }, chain.hotspotNodeIds)
		assert.are.same({ 2, 3, 4 }, chain.nodeIds,
			"the connector route should retain seed-to-target order across both hotspots")
		assert.are.equal(3, chain.hotspotHopDistance,
			"the precomputed key-node index should report the native tree hop distance")
		assert.are.equal(1, parsed.search.nodePowerCoverage.routePath.hotspotChainsGenerated)
		assert.are.equal("rebuilt", parsed.search.routeGraphCache.status)
		assert.are.equal("built", parsed.search.routeGraphCache.keyNodeDistanceIndex.status)
		assert.are.equal(2, parsed.search.routeGraphCache.keyNodeDistanceIndex.nodes)
		assert.are.equal(2, parsed.search.routeGraphCache.keyNodeDistanceIndex.reachablePairs)
		buildCandidates()
		assert.are.equal("hit", parsed.search.routeGraphCache.status,
			"repeated searches over the same immutable tree should reuse compact adjacency")
		assert.are.equal("reused", parsed.search.routeGraphCache.keyNodeDistanceIndex.status,
			"repeated searches should reuse the precomputed Notable/Keystone distances")
		table.remove(start.linked, 2)
		table.remove(connector.linked, 1)
		buildCandidates()
		assert.are.equal("rebuilt", parsed.search.routeGraphCache.status,
			"a topology change must invalidate adjacency even when the node set is unchanged")
		assert.are.equal("built", parsed.search.routeGraphCache.keyNodeDistanceIndex.status,
			"a topology change must rebuild key-node distances")
		assert.are.equal(0, parsed.search.routeGraphCache.keyNodeDistanceIndex.reachablePairs,
			"disconnected key nodes must not retain stale reachable distances")
		spec.nodes[5] = { id = 5, type = "Normal", alloc = false, x = 3, y = 1, linked = { } }
		buildCandidates()
		assert.are.equal("rebuilt", parsed.search.routeGraphCache.status,
			"a changed node set must invalidate cached adjacency")
		assert.are.equal("built", parsed.search.routeGraphCache.keyNodeDistanceIndex.status,
			"a changed node set must rebuild the key-node distance index")
		assert.are.equal(5, parsed.search.routeGraphCache.nodes)
		newBuild()
	end)

	it("ranks hotspot pairs by native power per precomputed tree hop", function()
		newBuild()
		local start = { id = 1, type = "ClassStart", alloc = true, x = 0, y = 0, linked = { } }
		local first = { id = 2, type = "Notable", alloc = false, x = 1, y = 0, linked = { }, dn = "High Power" }
		local nearby = { id = 3, type = "Notable", alloc = false, x = 0, y = 1, linked = { }, dn = "Nearby Power" }
		local distant = { id = 4, type = "Notable", alloc = false, x = 5, y = 0, linked = { }, dn = "Distant Power" }
		local connectorA = { id = 5, type = "Normal", alloc = false, linked = { } }
		local connectorB = { id = 6, type = "Normal", alloc = false, linked = { } }
		local connectorC = { id = 7, type = "Normal", alloc = false, linked = { } }
		local function connect(left, right)
			left.linked[#left.linked + 1] = right
			right.linked[#right.linked + 1] = left
		end
		connect(start, first)
		connect(start, nearby)
		connect(first, connectorA)
		connect(connectorA, connectorB)
		connect(connectorB, connectorC)
		connect(connectorC, distant)
		first.power = { singleStat = 100 }
		nearby.power = { singleStat = 80 }
		distant.power = { singleStat = 90 }
		local spec = {
			nodes = { [1] = start, [2] = first, [3] = nearby, [4] = distant,
				[5] = connectorA, [6] = connectorB, [7] = connectorC },
			allocNodes = { [1] = start },
			tree = { classes = { [1] = { name = "Test", startNodeId = 1 } } },
		}
		local parsed = assert(Inputs.Parse({ generationPhase = "tree", maxAddedPoints = "10",
			evaluationBudget = "8", seed = "31" }))
		parsed.search.useShowNodePower = true
		parsed.search.nodePowerStat = "CombinedDPS"
		parsed.search.nodePowerFocusStat = "CombinedDPS"
		local candidates, err = TreeSearch.BuildCandidateNodes(spec, parsed, 8, nil, 10)
		assert.is_truthy(candidates, err)
		assert.are.equal("node_power_hotspot_chain", candidates[1].routeFamily)
		assert.are.same({ 2, 3 }, candidates[1].hotspotNodeIds,
			"the stronger nearby pair should rank ahead of a slightly weaker but much longer pair")
		assert.are.equal(2, candidates[1].hotspotHopDistance)
		newBuild()
	end)

	it("cancels while incrementally building the key-node distance cache", function()
		newBuild()
		local start = { id = 1, type = "ClassStart", alloc = true, linked = { } }
		local nodes = { [1] = start }
		for nodeId = 2, 18 do
			nodes[nodeId] = { id = nodeId, type = "Notable", alloc = false, linked = { }, power = { singleStat = nodeId } }
		end
		for nodeId = 1, 17 do
			local left, right = nodes[nodeId], nodes[nodeId + 1]
			left.linked[#left.linked + 1] = right
			right.linked[#right.linked + 1] = left
		end
		local spec = {
			nodes = nodes,
			allocNodes = { [1] = start },
			tree = { classes = { [1] = { name = "Test", startNodeId = 1 } } },
		}
		local parsed = assert(Inputs.Parse({ generationPhase = "tree", maxAddedPoints = "20",
			evaluationBudget = "8", seed = "37" }))
		parsed.search.useShowNodePower = true
		parsed.search.nodePowerStat = "CombinedDPS"
		parsed.search.nodePowerFocusStat = "CombinedDPS"
		local control = { cancelled = false }
		local candidates, err, cancelled = TreeSearch.BuildCandidateNodes(spec, parsed, 20,
			function(done, total, _expanded, _targetId, operation)
				if operation == "Node Power distance index" and done >= 16 and total == 17 then
					control.cancelled = true
				end
			end, 20, control)
		assert.is_true(cancelled)
		assert.is_nil(err)
		assert.are.same({ }, candidates)
		newBuild()
	end)

	it("feeds bounded imported graph evidence into the ordinary Run action", function()
		newBuild()
		local seed, seedError = SkillSeed.Create(build, "Metadata/Items/Gems/SkillGemFireball")
		assert.is_truthy(seed, seedError)
		local tab = build.optimizerTab
		local sourceSignature = Candidate.BuildSignature(build)
		local oldEvidence, oldRun = StudyBuilds.NodeEvidence, PhantomSim.RunPhantomSim
		local captured, cancelCalls, evidenceCalls, capturedGemId, capturedEffectIds = nil, 0, 0, nil, nil
		StudyBuilds.NodeEvidence = function(_userPath, _queriedBuild, gemId, effectIds)
			evidenceCalls = evidenceCalls + 1
			capturedGemId, capturedEffectIds = gemId, effectIds
			return { status = "ready", compatibleBuildCount = 3, nodes = { }, edges = { }, nodeCounts = { },
				priorities = { [101] = 0.8, ["202"] = 4, [-1] = 1, [303] = math.huge },
				edgePriorities = { ["101:202"] = 0.75, ["202:303"] = 4, ["303:101"] = 1,
					["0:1"] = 1, ["1:2:3"] = 1, ["1:2147483648"] = 1, ["4:5"] = math.huge }, causal = false }
		end
		PhantomSim.RunPhantomSim = function(_, parsed)
			captured = parsed
			return { status = "running", Cancel = function() cancelCalls = cancelCalls + 1 end }
		end
		local runOk, runError = pcall(function()
			local ok, jobOrError = tab:RunOptimizer()
			assert.is_true(ok, tostring(jobOrError))
			assert.are.equal("ready", tab.nodeEvidence.status)
			assert.are.equal("Metadata/Items/Gems/SkillGemFireball", capturedGemId)
			assert.are.equal(1, #capturedEffectIds,
				"the overview route-memory lookup must constrain imported evidence to one exact PoB effect")
			local targetGroup = build.skillsTab.socketGroupList[tonumber(tab.textValues.targetSkillGroupIndex)]
			local targetSkill = targetGroup.displaySkillList[tonumber(tab.textValues.targetSkillIndex)]
			assert.are.equal(targetSkill.activeEffect.grantedEffect.id, capturedEffectIds[1],
				"route evidence must follow the exact effect selected in the Planner's target skill slot")
			assert.are.equal(0.8, captured.search.nodeEvidencePriorities[101])
			assert.are.equal(1, captured.search.nodeEvidencePriorities[202], "numeric-string IDs are normalized and their weight is clamped")
			assert.is_nil(captured.search.nodeEvidencePriorities[-1])
			assert.is_nil(captured.search.nodeEvidencePriorities[303])
			assert.are.equal(0.75, captured.search.edgeEvidencePriorities["101:202"])
			assert.are.equal(1, captured.search.edgeEvidencePriorities["202:303"], "edge frequencies are clamped")
			assert.is_nil(captured.search.edgeEvidencePriorities["303:101"], "edge keys must be canonical and ordered")
			assert.is_nil(captured.search.edgeEvidencePriorities["0:1"])
			assert.is_nil(captured.search.edgeEvidencePriorities["1:2:3"])
			assert.is_nil(captured.search.edgeEvidencePriorities["1:2147483648"])
			assert.is_nil(captured.search.edgeEvidencePriorities["4:5"])
			assert.is_false(captured.search.nodePotentialAnalysis)
			assert.is_true(captured.search.importedRouteMemoryEnabled)
			assert.are.equal("overview", tab.innerView, "Run from the overview must keep progress and results visible there")
			assert.is_true(tab.controls.overviewCancel.shown(), "the overview must expose cancellation while the job is running")
			assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "reading local route evidence and starting Run must preserve the active build")
			local workflow = table.concat(OptimizerTab.FormatGuidedWorkflowDiagnostics(tab, { }), "\n")
			assert.is_truthy(workflow:find("Memória de builds — prioridade ativa", 1, true))
			assert.is_truthy(workflow:find("3 builds compatíveis", 1, true))
			tab.controls.overviewCancel:Click()
			assert.are.equal(1, cancelCalls, "the visible overview cancel button must cancel the exact-search job")
			tab.job = nil
			local importedRouteControl = tab.controls.overviewUseImportedRoutes
			importedRouteControl.state = false
			importedRouteControl.changeFunc(false)
			local disabledOk, disabledJob = tab:RunOptimizer()
			assert.is_true(disabledOk, tostring(disabledJob))
			assert.are.equal("disabled", tab.nodeEvidence.status)
			assert.are.equal(1, evidenceCalls, "the opt-out must skip the local archive scan")
			assert.is_false(captured.search.importedRouteMemoryEnabled)
		end)
		StudyBuilds.NodeEvidence, PhantomSim.RunPhantomSim = oldEvidence, oldRun
		tab.job = nil
		assert.is_true(runOk, runError)
	end)

	it("validates the Matrix before scanning imported route memory", function()
		newBuild()
		local seed, seedError = SkillSeed.Create(build, "Metadata/Items/Gems/SkillGemFireball")
		assert.is_truthy(seed, seedError)
		local tab = build.optimizerTab
		tab.textValues.objectiveMetric = "NotAPoBMetric"
		local oldEvidence, evidenceCalls = StudyBuilds.NodeEvidence, 0
		StudyBuilds.NodeEvidence = function()
			evidenceCalls = evidenceCalls + 1
			return { status = "ready", priorities = { }, nodes = { }, edges = { } }
		end
		local ok, err = pcall(function()
			local started, startError = tab:RunOptimizer()
			assert.is_false(started)
			assert.is_truthy(startError)
			assert.are.equal(0, evidenceCalls, "invalid objective must stop before reading the local build archive")
		end)
		StudyBuilds.NodeEvidence = oldEvidence
		assert.is_true(ok, err)
	end)

	it("prioritizes routes that can address native PoB attribute requirements", function()
		newBuild()
		local rootSpec, rootError = Candidate.BuildPassiveSpec(build, { }, { }, { classId = 3 })
		assert.is_truthy(rootSpec, rootError)
		local regions = assert(TreeSearch.BuildRegionMap(rootSpec, "class"))
		local nativeRequirementInputs = assert(Inputs.Parse({
			generationPhase = "tree", maxAddedPoints = "12", evaluationBudget = "64", seed = "19",
			damageFocus = "Fire",
		}))
		local nativeNeeds = TreeSearch.ConfigureRequirementAttributeFocus(nativeRequirementInputs, { Int = 32, ReqInt = 81 })
		assert.is_true(nativeNeeds.Int, "an exact PoB ReqInt deficit must focus Intelligence routes without a manual floor")
		assert.is_nil(nativeRequirementInputs.hard.Int, "native requirement guidance must not invent a Matrix hard floor")
		local parsed = assert(Inputs.Parse({
			generationPhase = "tree", maxAddedPoints = "12", evaluationBudget = "64", seed = "19",
			damageFocus = "Fire", Int = "81",
		}))
		local focused = TreeSearch.ConfigureRequirementAttributeFocus(parsed, { Int = 32, ReqInt = 81 })
		assert.is_true(focused.Int)
		local candidates, err = TreeSearch.BuildCandidateNodes(rootSpec, nativeRequirementInputs, 64, nil, 12, nil, regions)
		assert.is_truthy(candidates, err)
		local firstWitchTarget
		for _, candidate in ipairs(candidates) do
			if candidate.targetId and regions[candidate.targetId] == "Witch" then
				firstWitchTarget = rootSpec.nodes[candidate.targetId]
				break
			end
		end
		assert.is_truthy(firstWitchTarget, "the Witch region should contribute a bounded route target")
		local description = lower((firstWitchTarget.dn or "") .. " " .. (firstWitchTarget.name or ""))
		assert.is_true(description:find("intelligence", 1, true) ~= nil or description:find("all attributes", 1, true) ~= nil,
			"the first Witch-region route should address the exact unmet Intelligence need")
	end)

	it("derives attribute route focus from a real exact PoB skill-use requirement", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 20/0  1\nAdded Chaos Damage 20/0  1")
		build.mainSocketGroup = 1
		build.calcsTab:BuildOutput()
		local exactOutput = assert(build.calcsTab.mainOutput)
		assert.is_true(exactOutput.ReqInt > exactOutput.Int,
			"PoB should expose the support's use requirement in its current exact skill output")
		local parsed = assert(Inputs.Parse({ generationPhase = "tree" }))
		local focus = TreeSearch.ConfigureRequirementAttributeFocus(parsed, exactOutput)
		assert.is_true(focus.Int)
		assert.is_nil(parsed.hard.Int, "native requirements guide routes without becoming a user-authored hard floor")
	end)

	it("routes an Omniscience floor toward attributes and verifies the result with native PoB", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local unconvertedInputs = assert(Inputs.Parse({ generationPhase = "tree", Omni = "1" }))
		local unconvertedFocus = TreeSearch.ConfigureRequirementAttributeFocus(unconvertedInputs, { Omni = 0 }, {
			omniAttributeConversionActive = false,
		})
		assert.is_true(unconvertedFocus.Omni, "the Omniscience floor remains a strict target even without an attribute conversion flag")
		assert.is_false(unconvertedInputs.search.omniAttributeConversionActive,
			"ordinary Strength/Dexterity/Intelligence nodes must not be prioritized as Omniscience without PoB's native conversion flag")

		local amulet = new("Item"):Item("Rarity: Rare\nOmniscience Route Fixture\nAmber Amulet\n--------\nModifiers to Attributes instead apply to Omniscience")
		build.itemsTab:AddItem(amulet, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = amulet.id
		build.itemsTab.slots.Amulet:SetSelItemId(amulet.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local _, baseline, baselineEnv = Calcs.getMiscCalculator(build)
		assert.is_true(type(baseline.Omni) == "number", "PoB must expose exact Omniscience output")
		assert.is_true(baselineEnv.modDB:Flag(nil, "Omniscience"), "the fixture must activate PoB's native attribute-to-Omniscience flag")
		local parsed, parseError = Inputs.Parse({
			generationPhase = "tree", Omni = string.format("%.0f", baseline.Omni + 1),
			maxAddedPoints = "12", evaluationBudget = "128", seed = "37",
		})
		assert.is_truthy(parsed, parseError)
		local focused = TreeSearch.ConfigureRequirementAttributeFocus(parsed, baseline, {
			omniAttributeConversionActive = baselineEnv.modDB:Flag(nil, "Omniscience"),
		})
		assert.is_true(focused.Omni, "an unmet exact Omniscience floor must focus attribute routes")
		assert.is_true(parsed.search.omniAttributeConversionActive, "attribute route hints require PoB's exact conversion flag")

		local rootSpec, rootError = Candidate.BuildPassiveSpec(build, { }, { }, { classId = 3 })
		assert.is_truthy(rootSpec, rootError)
		local regions = assert(TreeSearch.BuildRegionMap(rootSpec, "class"))
		local proposals, proposalError = TreeSearch.BuildCandidateNodes(rootSpec, parsed, 128, nil, 12, nil, regions)
		assert.is_truthy(proposals, proposalError)
		local sourceSignature = Candidate.BuildSignature(build)
		local exactRoute
		for _, proposal in ipairs(proposals) do
			local target = proposal.targetId and rootSpec.nodes[proposal.targetId]
			local description = lower(target and ((target.dn or "") .. " " .. (target.name or "")))
			if target and regions[target.id] == "Witch"
				and (description:find("strength", 1, true) or description:find("dexterity", 1, true)
					or description:find("intelligence", 1, true) or description:find("all attributes", 1, true)) then
				local candidateSpec, candidateError, candidateItems = Candidate.BuildPassiveSpec(build, proposal.nodeIds, { }, { classId = 3 })
				assert.is_truthy(candidateSpec, candidateError)
				local _, candidateOutput = Calcs.getMiscCalculator(candidateItems.build)
				if candidateOutput.Omni > baseline.Omni then
					exactRoute = { target = target, output = candidateOutput }
					break
				end
			end
		end
		assert.is_truthy(exactRoute, "a prioritized Witch attribute route must increase Omniscience in PoB's exact calculation")
		assert.is_true(exactRoute.output.Omni >= parsed.hard.Omni.value,
			"the exact route must meet the configured Omniscience floor")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "candidate route evaluation must preserve the source build")
	end)

	it("stratifies passive targets across class regions and remains deterministic", function()
		newBuild()
		local parsed = assert(Inputs.Parse({
			generationPhase = "combined",
			nodePotentialAnalysis = "true",
			damageFocus = "Cold",
			defenseProfile = "EnergyShield",
			maxAddedPoints = "30",
			evaluationBudget = "32",
			seed = "19",
		}))
		local rootSpec, rootError = Candidate.BuildPassiveSpec(build, { }, { }, { classId = build.spec.curClassId })
		assert.is_truthy(rootSpec, rootError)
		local regions = assert(TreeSearch.BuildRegionMap(rootSpec, "class"))
		local first = assert(TreeSearch.BuildCandidateNodes(rootSpec, parsed, 31, nil, 30, nil, regions))
		local second = assert(TreeSearch.BuildCandidateNodes(rootSpec, parsed, 31, nil, 30, nil, regions))
		local targetRegions, firstTargets, secondTargets = { }, { }, { }
		for _, candidate in ipairs(first) do
			if candidate.targetId then
				firstTargets[#firstTargets + 1] = candidate.targetId
				targetRegions[regions[candidate.targetId]] = true
			end
		end
		for _, candidate in ipairs(second) do
			if candidate.targetId then secondTargets[#secondTargets + 1] = candidate.targetId end
		end
		local regionCount = 0
		for _ in pairs(targetRegions) do regionCount = regionCount + 1 end
		assert.is_true(regionCount >= 3, "node analysis should not spend its bounded proposals in one class region")
		assert.are.equal(#firstTargets, #secondTargets)
		for index, targetId in ipairs(firstTargets) do
			assert.are.equal(targetId, secondTargets[index], "seeded node proposal order must be reproducible")
		end
	end)

	it("compares exact per-skill damage and defense deltas without changing the active build", function()
		newBuild()
		build.characterLevel = 10
		build.characterLevelAutoMode = false
		local seed, seedError = SkillSeed.Create(build, "Metadata/Items/Gems/SkillGemFireball")
		assert.is_truthy(seed, seedError)
		local tab = build.optimizerTab
		tab.textValues.damageFocus = "Cold"
		tab.textValues.defenseProfile = "SpellSuppression"
		tab.textValues.evaluationBudget = "24"
		tab.textValues.maxAddedPoints = "3"
		tab.textValues.seed = "29"
		local savedPhase = tab.textValues.generationPhase
		local signature = Candidate.BuildSignature(build)
		local ok, jobOrError = tab:RunNodePotential()
		assert.is_true(ok, tostring(jobOrError))
		local frames = 0
		while tab.job and tab.job.status == "running" do
			tab:Tick()
			frames = frames + 1
			assert.is_true(frames < 5000, "node-potential job did not finish")
		end
		local result = tab.nodePotentialResult
		assert.is_truthy(result, "node-potential result should be visible after the job")
		assert.are.equal("node_potential_complete", result.status)
		assert.are.equal("Fireball", result.skillName)
		assert.is_truthy(result.skillTags and #result.skillTags > 0, "the active PoB gem tags should be recorded")
		assert.is_true(result.evaluations > 1, "exact baseline and route calculations should run")
		assert.is_true(result.exactRouteEvaluations > 0, "at least one route should pass native tree and level gates")
		assert.is_true(type(result.baselineMetrics.CombinedDPS) == "number")
		assert.is_true(type(result.baselineMetrics.TotalEHP) == "number")
		assert.are.equal("CombinedDPS", result.focusMetrics[1].key,
			"element preference should use the exact selected-skill total because the review has no element-isolated DPS output")
		assert.are.equal("SpellSuppressionChance", result.focusMetrics[2].key,
			"defense focus must use the selected exact PoB defensive layer")
		assert.is_true(#result.focusNotes > 0, "element focus limitations should be stated clearly")
		for _, route in ipairs(result.results) do
			if route.exactCalculated then
				assert.is_true(type(route.metricDelta.CombinedDPS) == "number")
				assert.is_true(type(route.metricDelta.SpellSuppressionChance) == "number")
				assert.is_true(type(route.paretoRank) == "number", "exact routes should have a Pareto rank")
				assert.is_true(#route.routeNodes > 0, "exact candidate should retain its connected route for review")
			end
		end
		assert.are.equal(signature, Candidate.BuildSignature(build), "read-only analysis must preserve the active build")
		assert.are.equal(savedPhase, tab.textValues.generationPhase)
		assert.are.equal("false", tab.textValues.nodePotentialAnalysis)
		assert.are.equal("nodes", tab.innerView)
	end)

	it("reports native point-limit blockers as not evaluated, not as hard-gate failures", function()
		newBuild()
		build.characterLevel = 1
		build.characterLevelAutoMode = false
		local seed, seedError = SkillSeed.Create(build, "Metadata/Items/Gems/SkillGemFireball")
		assert.is_truthy(seed, seedError)
		local tab = build.optimizerTab
		tab.textValues.evaluationBudget = "12"
		tab.textValues.maxAddedPoints = "3"
		local signature = Candidate.BuildSignature(build)
		local ok, jobOrError = tab:RunNodePotential()
		assert.is_true(ok, tostring(jobOrError))
		local frames, frameLimit = 0, 1000
		while tab.job and tab.job.status == "running" do
			tab:Tick()
			frames = frames + 1
			local progress = tab.job and tab.job.progress or { }
			frameLimit = math.min(5000, math.max(frameLimit,
				math.ceil((tonumber(progress.total) or 0) / 8) + 256))
			assert.is_true(frames < frameLimit, "point-limit analysis did not finish: phase="
				.. tostring(progress.phase) .. ", processed=" .. tostring(progress.processed)
				.. ", total=" .. tostring(progress.total) .. ", current=" .. tostring(progress.current))
		end
		local result = tab.nodePotentialResult
		assert.is_truthy(result, "blocked route review should still produce a result")
		assert.are.equal(0, result.exactRouteEvaluations)
		local blockedRoute
		for _, route in ipairs(result.results or { }) do
			if route.exactCalculated == false then blockedRoute = route break end
		end
		local firstResult = result.results and result.results[1]
		assert.is_truthy(blockedRoute, "the native level/quest point limit should block all new routes at level 1"
			.. "; rows=" .. tostring(#(result.results or { }))
			.. ", first=" .. tostring(firstResult and firstResult.label)
			.. ", firstExact=" .. tostring(firstResult and firstResult.exactCalculated)
			.. ", firstReason=" .. tostring(firstResult and firstResult.reason)
			.. ", status=" .. tostring(result.status))
		assert.is_truthy(blockedRoute.reason and blockedRoute.reason:find("level 1 limit", 1, true),
			"the route should retain PoB's exact structural blocker")
		assert.is_false(blockedRoute.feasible)
		assert.are.equal(signature, Candidate.BuildSignature(build), "blocked read-only analysis must preserve the active build")
	end)
end)
