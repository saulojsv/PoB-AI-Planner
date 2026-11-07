-- Runs through HeadlessWrapper and PoB's native cluster-jewel graph builder.
local Inputs = require("Modules.Optimizer.Inputs")
local Candidate = require("Modules.Optimizer.Candidate")
local Calcs = require("Modules.Calcs")
local ClusterSearch = require("Modules.Optimizer.ClusterSearch")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local TreeSearch = require("Modules.Optimizer.TreeSearch")

local function addItem(raw)
	local item = new("Item"):Item(raw)
	build.itemsTab:AddItem(item, true)
	return item
end

local function assertSocketEmpty(spec, socketId, message)
	assert.are.equal(0, tonumber(spec.jewels[socketId]) or 0, message)
end

local function largeCluster()
	return addItem([[Rarity: RARE
New Item
Large Cluster Jewel
Cluster Jewel Skill: affliction_chaos_damage
Cluster Jewel Node Count: 8
Implicits: 3
Adds 8 Passive Skills
2 Added Passive Skills are Jewel Sockets
Added Small Passive Skills grant: 12% increased Chaos Damage]])
end

local function largeElementalCluster()
	return addItem([[Rarity: RARE
New Item
Large Cluster Jewel
Cluster Jewel Skill: affliction_elemental_damage
Cluster Jewel Node Count: 8
Implicits: 3
Adds 8 Passive Skills
2 Added Passive Skills are Jewel Sockets
Added Small Passive Skills grant: 10% increased Elemental Damage]])
end

local function smallCluster()
	return addItem([[Rarity: UNIQUE
One With Nothing
Small Cluster Jewel
Implicits: 0
Adds Hollow Palm Technique]])
end

local function allocateOuterSocket(spec)
	local start
	for _, node in pairs(spec.allocNodes or { }) do
		if node.type == "ClassStart" then start = node break end
	end
	assert.is_truthy(start, "fresh PoB spec must have its native class start")

	local queue, parent, visited = { start }, { }, { [start.id] = true }
	local cursor, target = 1, nil
	while cursor <= #queue do
		local node = queue[cursor]
		cursor = cursor + 1
		if node.expansionJewel and node.expansionJewel.size == 2 then
			target = node
			break
		end
		for _, linked in ipairs(node.linked or { }) do
			if not visited[linked.id] and linked.type ~= "AscendClassStart" and not linked.ascendancyName then
				visited[linked.id] = true
				parent[linked.id] = node
				queue[#queue + 1] = linked
			end
		end
	end
	assert.is_truthy(target, "active PoB tree must expose a reachable outer expansion socket")

	local reversePath, node = { }, target
	while node do
		reversePath[#reversePath + 1] = node
		node = parent[node.id]
	end
	for index = #reversePath, 1, -1 do
		local pathNode = spec.nodes[reversePath[index].id]
		if not spec.allocNodes[pathNode.id] then spec:AllocNode(pathNode) end
	end
	spec:BuildAllDependsAndPaths()
	return spec.nodes[target.id]
end

local function calculateProjected(projected, isolatedItems)
	local isolatedBuild = { spec = projected, itemsTab = isolatedItems }
	setmetatable(isolatedBuild, { __index = build })
	local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
	local output, env = exactCalc({ spec = projected, returnEnv = true }, true)
	assert.is_truthy(output, "cluster candidate must reach PoB's exact calculator")
	assert.is_truthy(env, "cluster candidate exact calculation must return the native environment")
	return output
end

describe("Optimizer native Cluster Jewel candidates", function()
	before_each(function()
		newBuild()
	end)

	it("uses the native outer cluster graph, checks point and region rules, calculates exactly, and applies virtual nodes", function()
		local sourceSpec = build.spec
		local socket = allocateOuterSocket(sourceSpec)
		local jewel = largeCluster()
		assert.is_truthy(jewel.clusterJewel and jewel.jewelData and jewel.jewelData.clusterJewelValid)
		local sourceRaw = jewel:BuildRaw()
		local sourceSignature = Candidate.BuildSignature(build)
		local sourcePoints = sourceSpec:CountAllocNodes()
		local parsed = assert(Inputs.Parse({}))
		local regions = TreeSearch.BuildRegionMap(sourceSpec, parsed.branch.partition)
		local candidates, coverage = ClusterSearch.BuildCandidates(build, 12, 4, parsed, regions, nil, { cancelled = false })
		local selected
		for _, option in ipairs(candidates) do
			if option.jewelVariant and option.jewelVariant.sourceKind == "cluster"
				and option.jewelVariant.itemId == jewel.id and option.jewelVariant.toNodeId == socket.id then
				selected = option
				break
			end
		end
		assert.is_truthy(selected, "search should produce a target from the native outer cluster graph")
		assert.is_true(coverage.projectedPlacements > 0)
		assert.is_true(coverage.generatedCandidates > 0)
		local targetId = selected.nodeIds[1]
		assert.is_nil(sourceSpec.nodes[targetId], "cluster node IDs must come from PoB's generated subgraph")

		local projected, projectionError, isolatedItems = Candidate.BuildPassiveSpec(build, selected.nodeIds, { }, {
			jewelVariant = selected.jewelVariant,
		})
		assert.is_truthy(projected, projectionError)
		assert.is_truthy(projected.nodes[targetId])
		assert.is_true(projected:CountAllocNodes() - sourcePoints <= 4, "native path repair must respect the selected point budget")
		assert.is_true(projected:CountAllocNodes() - sourcePoints > 0)
		local valid, validationError = TreeSearch.ValidateCandidate(sourceSpec, projected.optimizerAddedNodeIds, parsed,
			regions, projected.optimizerRemovedNodeIds, projected)
		assert.is_true(valid, validationError)
		calculateProjected(projected, isolatedItems)
		local searchInputs = assert(Inputs.Parse({
			objectiveMetric = "TotalEHP",
			maxAddedPoints = "4",
			evaluationBudget = "10",
			seed = "17",
		}))
		local job = PhantomSim.RunPhantomSim(build, searchInputs, { cancelled = false })
		local steps = 0
		while job.status == "running" do
			job:Step()
			steps = steps + 1
			assert.is_true(steps < 100, "bounded cluster search must yield and terminate")
		end
		assert.are.equal("feasible", job.status, job.error or "exact optimizer should retain the feasible native baseline")
		assert.is_true(job.result.searchCoverage.clusters.generatedCandidates > 0)
		assert.is_true(job.result.searchCoverage.clusters.exactEvaluations > 0,
			string.format("ClusterSearch proposals must reach exact PoB calculation through PhantomSim (generated=%s exact=%s projected=%s targets=%s evals=%s)",
				tostring(job.result.searchCoverage.clusters.generatedCandidates),
				tostring(job.result.searchCoverage.clusters.exactEvaluations),
				tostring(job.result.searchCoverage.clusters.projectedPlacements),
				tostring(job.result.searchCoverage.clusters.availableTargets),
				tostring(job.result.evaluations)))

		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "projection must not mutate the source build")
		assert.are.equal(sourceRaw, jewel:BuildRaw(), "projection must not edit the inventory jewel")
		assertSocketEmpty(sourceSpec, socket.id, "exact search must keep the source expansion socket empty")
		assert.is_nil(sourceSpec.allocNodes[targetId])

		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = projected.optimizerAddedNodeIds,
			removeNodeIds = projected.optimizerRemovedNodeIds,
			jewelVariant = selected.jewelVariant,
			label = selected.label,
		})
		assert.is_true(applied, applyError)
		assert.are_not.equal(sourceSpec, build.spec)
		assert.are.equal(jewel.id, build.spec.jewels[socket.id])
		assert.is_truthy(build.spec.allocNodes[targetId], "PoB must restore the allocated virtual node after rebuilding the cluster graph")
		assertSocketEmpty(sourceSpec, socket.id, "applying the variation must preserve the source spec")
		assert.is_nil(sourceSpec.allocNodes[targetId])
	end)

	it("resolves nested cluster-node regions through their native parent sockets", function()
		local sourceSpec = build.spec
		local outerSocket = allocateOuterSocket(sourceSpec)
		local parentJewel = largeCluster()
		sourceSpec.jewels[outerSocket.id] = parentJewel.id
		sourceSpec:BuildClusterJewelGraphs()

		local nestedSocket
		for _, subGraph in pairs(sourceSpec.subGraphs) do
			for _, node in ipairs(subGraph.nodes or { }) do
				if node.type == "Socket" and node.expansionJewel and node.expansionJewel.size < 2 then
					nestedSocket = node
					break
				end
			end
			if nestedSocket then break end
		end
		assert.is_truthy(nestedSocket, "large native cluster must expose a nested expansion socket")
		sourceSpec:AllocNode(sourceSpec.nodes[nestedSocket.id])
		sourceSpec:BuildClusterJewelGraphs()
		local nestedJewel = smallCluster()
		local parsed = assert(Inputs.Parse({}))
		local regions = TreeSearch.BuildRegionMap(sourceSpec, parsed.branch.partition)
		local candidates = ClusterSearch.BuildCandidates(build, 12, 4, parsed, regions, nil, { cancelled = false })
		local selected
		for _, option in ipairs(candidates) do
			if option.jewelVariant and option.jewelVariant.itemId == nestedJewel.id
				and option.jewelVariant.toNodeId == nestedSocket.id then
				selected = option
				break
			end
		end
		assert.is_truthy(selected, "search should discover allocated nested sockets in the source subgraph")

		local projected, projectionError = Candidate.BuildPassiveSpec(build, selected.nodeIds, { }, {
			jewelVariant = selected.jewelVariant,
		})
		assert.is_truthy(projected, projectionError)
		local virtualParents = TreeSearch.BuildVirtualParentSocketMap(projected)
		local region = TreeSearch.ResolveNodeRegion(projected, selected.nodeIds[1], "class", regions, nil, virtualParents)
		assert.are.equal(regions[outerSocket.id], region, "nested virtual nodes inherit the region of the outer native socket")
	end)

	it("builds, calculates, and applies a fresh parent-child Cluster Jewel pair through PoB's native graphs", function()
		local sourceSpec = build.spec
		local outerSocket = allocateOuterSocket(sourceSpec)
		local parentJewel = largeCluster()
		local childJewel = smallCluster()
		local sourceSignature = Candidate.BuildSignature(build)
		local sourcePoints = sourceSpec:CountAllocNodes()
		local parsed = assert(Inputs.Parse({
			objectiveMetric = "TotalEHP",
			maxAddedPoints = "8",
			evaluationBudget = "10",
			seed = "19",
		}))
		local regions = TreeSearch.BuildRegionMap(sourceSpec, parsed.branch.partition)
		local candidates, coverage = ClusterSearch.BuildCandidates(build, 12, 8, parsed, regions, nil, { cancelled = false })
		local selected
		for _, option in ipairs(candidates) do
			if option.jewelCombination == "parent_child_cluster" and option.jewelVariants
				and #option.jewelVariants == 2 and option.jewelVariants[1].itemId == parentJewel.id
				and option.jewelVariants[2].itemId == childJewel.id then
				selected = option
				break
			end
		end
		assert.is_truthy(selected, "search should compose an inventory child cluster in a socket generated by its parent")
		assert.is_true(coverage.nestedAvailableSockets > 0)
		assert.is_true(coverage.nestedProjectedPlacements > 0)
		assert.is_true(coverage.nestedGeneratedCandidates > 0)
		assert.are.equal(outerSocket.id, selected.jewelVariants[1].toNodeId)
		local childSocketId = selected.jewelVariants[2].toNodeId
		assert.is_nil(sourceSpec.nodes[childSocketId], "the child destination must be generated by the selected parent jewel")

		local projected, projectionError, isolatedItems = Candidate.BuildPassiveSpec(build, selected.nodeIds, { }, {
			jewelVariants = selected.jewelVariants,
		})
		assert.is_truthy(projected, projectionError)
		assert.are.equal(parentJewel.id, projected.jewels[outerSocket.id])
		assert.are.equal(childJewel.id, projected.jewels[childSocketId])
		local targetId = selected.nodeIds[#selected.nodeIds]
		assert.is_truthy(projected.nodes[targetId], "the nested target must exist in the recursively generated PoB graph")
		local addedClusterSocket = false
		for _, nodeId in ipairs(projected.optimizerAddedNodeIds or { }) do
			if projected.nodes[nodeId] and projected.nodes[nodeId].type == "Socket" then addedClusterSocket = true break end
		end
		assert.is_true(addedClusterSocket, "a parent-child route must charge its allocated nested socket as a passive point")
		assert.are.equal(projected:CountAllocNodes() - sourcePoints,
			PhantomSim.CountAddedMainPoints(projected, projected.optimizerAddedNodeIds),
			"the per-candidate cap must count every newly allocated PoB main-tree point")
		assert.is_true(projected:CountAllocNodes() - sourcePoints <= 8,
			"the native parent path, child socket, and child target must respect the exact point budget")
		local childGraphExists = false
		for _, subGraph in pairs(projected.subGraphs or { }) do
			if subGraph.parentSocket and subGraph.parentSocket.id == childSocketId then childGraphExists = true break end
		end
		assert.is_true(childGraphExists, "PoB must create the child subgraph from the allocated virtual socket")
		local valid, validationError = TreeSearch.ValidateCandidate(sourceSpec, projected.optimizerAddedNodeIds, parsed,
			regions, projected.optimizerRemovedNodeIds, projected)
		assert.is_true(valid, validationError)
		calculateProjected(projected, isolatedItems)

		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local steps = 0
		while job.status == "running" do
			job:Step()
			steps = steps + 1
			assert.is_true(steps < 100, "bounded nested-cluster search must yield and terminate")
		end
		assert.are.equal("feasible", job.status, job.error or "exact search should retain the feasible source baseline")
		assert.is_true(job.result.searchCoverage.clusters.nestedExactEvaluations > 0,
			string.format("parent-child proposals must reach exact PoB calculation (nestedGenerated=%s nestedExact=%s clusterExact=%s evaluations=%s deficit=%s)",
				tostring(job.result.searchCoverage.clusters.nestedGeneratedCandidates),
				tostring(job.result.searchCoverage.clusters.nestedExactEvaluations),
				tostring(job.result.searchCoverage.clusters.exactEvaluations),
				tostring(job.result.evaluations), tostring(job.result.bestObservedDeficit)))
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "search must preserve the source build")
		assertSocketEmpty(sourceSpec, outerSocket.id, "the original spec must retain its empty outer socket")

		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = projected.optimizerAddedNodeIds,
			removeNodeIds = projected.optimizerRemovedNodeIds,
			jewelVariants = selected.jewelVariants,
			jewelCombination = selected.jewelCombination,
			label = selected.label,
		})
		assert.is_true(applied, applyError)
		assert.are_not.equal(sourceSpec, build.spec)
		assert.are.equal(parentJewel.id, build.spec.jewels[outerSocket.id])
		assert.are.equal(childJewel.id, build.spec.jewels[childSocketId])
		assert.is_truthy(build.spec.allocNodes[targetId], "PoB must restore the nested virtual target in the applied variation")
		assertSocketEmpty(sourceSpec, outerSocket.id, "applying must retain the original passive spec unchanged")
	end)

	it("replaces an unused installed Cluster Jewel through an isolated native projection", function()
		local sourceSpec = build.spec
		local outerSocket = allocateOuterSocket(sourceSpec)
		local installedJewel = largeCluster()
		local replacementJewel = largeElementalCluster()
		sourceSpec.jewels[outerSocket.id] = installedJewel.id
		sourceSpec:BuildClusterJewelGraphs()
		build.itemsTab:PopulateSlots()
		local sourceSignature = Candidate.BuildSignature(build)
		local sourcePoints = sourceSpec:CountAllocNodes()
		local parsed = assert(Inputs.Parse({ maxAddedPoints = "8", evaluationBudget = "12", seed = "23" }))
		local regions = TreeSearch.BuildRegionMap(sourceSpec, parsed.branch.partition)
		local candidates, coverage = ClusterSearch.BuildCandidates(build, 12, 8, parsed, regions, nil, { cancelled = false })
		local selected
		for _, option in ipairs(candidates) do
			if option.jewelVariant and option.jewelVariant.replacesCluster
				and option.jewelVariant.toNodeId == outerSocket.id
				and option.jewelVariant.itemId == replacementJewel.id then
				selected = option
				break
			end
		end
		assert.is_true(coverage.replaceableClusterSockets > 0, "an unused native parent graph should be replaceable")
		assert.is_true(coverage.replacementPlacements > 0, "replacement items should be paired with an installed cluster socket")
		assert.is_truthy(selected, "search should expose the in-inventory replacement for the installed cluster")
		assert.is_truthy(selected.label:find("Replace", 1, true))
		assert.are.equal(installedJewel.id, selected.jewelVariant.targetItemId)

		local projected, projectionError, isolatedItems = Candidate.BuildPassiveSpec(build, selected.nodeIds, { }, {
			jewelVariant = selected.jewelVariant,
		})
		assert.is_truthy(projected, projectionError)
		assert.are.equal(replacementJewel.id, projected.jewels[outerSocket.id])
		assert.are.equal(installedJewel.id, sourceSpec.jewels[outerSocket.id], "projection must preserve the original cluster assignment")
		local addedPoints = #projected.optimizerAddedNodeIds
		assert.is_true(addedPoints > 0, "replacement target must add a connected native cluster route")
		assert.are.equal(addedPoints, projected:CountAllocNodes() - sourcePoints,
			"the added-point budget must count every newly allocated native point, including sockets")
		local valid, validationError = TreeSearch.ValidateCandidate(sourceSpec, projected.optimizerAddedNodeIds,
			parsed, regions, projected.optimizerRemovedNodeIds, projected)
		assert.is_true(valid, validationError)
		calculateProjected(projected, isolatedItems)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "exact projection must leave the source build unchanged")

		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = projected.optimizerAddedNodeIds,
			removeNodeIds = projected.optimizerRemovedNodeIds,
			jewelVariant = selected.jewelVariant,
			label = selected.label,
		})
		assert.is_true(applied, applyError)
		assert.are.equal(replacementJewel.id, build.spec.jewels[outerSocket.id], "the new variation should apply the selected replacement")
		assert.are.equal(installedJewel.id, sourceSpec.jewels[outerSocket.id], "the source variation must keep its original cluster")
		assert.are_not.equal(sourceSpec, build.spec)
	end)

	it("does not replace a Cluster Jewel whose generated subgraph is allocated", function()
		local sourceSpec = build.spec
		local outerSocket = allocateOuterSocket(sourceSpec)
		local installedJewel = largeCluster()
		local replacementJewel = largeElementalCluster()
		sourceSpec.jewels[outerSocket.id] = installedJewel.id
		sourceSpec:BuildClusterJewelGraphs()
		local allocatedClusterNode
		for _, subGraph in pairs(sourceSpec.subGraphs or { }) do
			if subGraph.parentSocket and subGraph.parentSocket.id == outerSocket.id then
				for _, node in ipairs(subGraph.nodes or { }) do
					if node.type ~= "Socket" and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
						and node.type ~= "Mastery" and node.path and #node.path > 0 then
						allocatedClusterNode = node
						break
					end
				end
			end
			if allocatedClusterNode then break end
		end
		assert.is_truthy(allocatedClusterNode, "the native cluster graph must expose an allocatable node")
		sourceSpec:AllocNode(allocatedClusterNode)
		assert.is_truthy(sourceSpec.allocNodes[allocatedClusterNode.id])

		local parsed = assert(Inputs.Parse({ maxAddedPoints = "8", evaluationBudget = "12", seed = "29" }))
		local regions = TreeSearch.BuildRegionMap(sourceSpec, parsed.branch.partition)
		local candidates, coverage = ClusterSearch.BuildCandidates(build, 12, 8, parsed, regions, nil, { cancelled = false })
		assert.are.equal(0, coverage.replaceableClusterSockets, "used subgraphs must fail closed for replacement")
		for _, option in ipairs(candidates) do
			assert.is_false(option.jewelVariant and option.jewelVariant.replacesCluster
				and option.jewelVariant.toNodeId == outerSocket.id,
				"search must not silently discard the allocated source subgraph")
		end
		assert.are.equal(installedJewel.id, sourceSpec.jewels[outerSocket.id])
		assert.is_truthy(sourceSpec.allocNodes[allocatedClusterNode.id])
		assert.are.equal(replacementJewel.id, build.itemsTab.items[replacementJewel.id].id,
			"the rejected replacement must remain in the original inventory")
	end)
end)
