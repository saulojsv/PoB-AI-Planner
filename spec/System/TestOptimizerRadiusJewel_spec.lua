local Inputs = require("Modules.Optimizer.Inputs")
local Candidate = require("Modules.Optimizer.Candidate")
local Calcs = require("Modules.Calcs")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local TreeSearch = require("Modules.Optimizer.TreeSearch")

local function allocatePathToNearestSocket(spec, excludedSockets)
	excludedSockets = excludedSockets or { }
	local classStart
	for _, node in pairs(spec.allocNodes or { }) do
		if node.type == "ClassStart" then classStart = node break end
	end
	assert.is_truthy(classStart, "the fresh PoB build must have its native class start")

	local queue, parent, visited = { classStart }, { }, { [classStart.id] = true }
	local head, socket = 1, nil
	while head <= #queue do
		local node = queue[head]
		head = head + 1
		if node.isJewelSocket and not excludedSockets[node.id] then socket = node break end
		for _, linked in ipairs(node.linked or { }) do
			if not visited[linked.id] and linked.type ~= "Mastery" and linked.type ~= "AscendClassStart" then
				visited[linked.id] = true
				parent[linked.id] = node
				queue[#queue + 1] = linked
			end
		end
	end
	assert.is_truthy(socket, "the loaded PoB tree must expose a jewel socket")

	local reversePath, node = { }, socket
	while node do
		reversePath[#reversePath + 1] = node
		node = parent[node.id]
	end
	for index = #reversePath, 1, -1 do
		local pathNode = spec.nodes[reversePath[index].id]
		if not spec.allocNodes[pathNode.id] then spec:AllocNode(pathNode) end
	end
	spec:BuildAllDependsAndPaths()
	return spec.nodes[socket.id]
end

local function findOriginLoopRoute(spec)
	local originId = spec.curClass and spec.curClass.startNodeId
	local origin = originId and spec.nodes[originId]
	if not origin then return nil end
	local function routeNode(node)
		return node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and node.type ~= "Mastery"
			and not node.ascendancyName and not node.isMultipleChoiceOption and not node.expansionSkill
	end
	local function sortedLinks(node)
		local links = { }
		for _, link in ipairs(node and node.linked or { }) do
			local linked = link and spec.nodes[link.id]
			if linked then links[#links + 1] = linked end
		end
		table.sort(links, function(first, second) return tostring(first.id) < tostring(second.id) end)
		return links
	end
	for _, first in ipairs(sortedLinks(origin)) do
		if not spec.allocNodes[first.id] and routeNode(first) then
			local queue, parent, visited = { first }, { [first.id] = false }, { [first.id] = true }
			local head = 1
			while head <= #queue do
				local node = queue[head]
				head = head + 1
				for _, linked in ipairs(sortedLinks(node)) do
					if linked.id ~= originId then
						if spec.allocNodes[linked.id] then
							local reversePath, current = { }, node.id
							while current do
								reversePath[#reversePath + 1] = current
								current = parent[current]
							end
							local path = { }
							for index = #reversePath, 1, -1 do path[#path + 1] = reversePath[index] end
							return path
						elseif routeNode(linked) and not visited[linked.id] then
							visited[linked.id] = true
							parent[linked.id] = node.id
							queue[#queue + 1] = linked
						end
					end
				end
			end
		end
	end
	return nil
end

local function newThreadOfHope()
	return new("Item"):Item("Rarity: UNIQUE\n" ..
		"Thread of Hope\nCrimson Jewel\nVariant: Large Ring\nSelected Variant: 1\n" ..
		"Radius: Variable\nImplicits: 0\nOnly affects Passives in Large Ring\n" ..
		"Passives in Radius can be Allocated without being connected to your Tree\n")
end

local function newIntuitiveLeap()
	return new("Item"):Item("Rarity: UNIQUE\nIntuitive Leap\nViridian Jewel\nRadius: Small\nImplicits: 0\n" ..
		"Passive Skills in Radius can be Allocated without being connected to your tree\n")
end

local function newImpossibleEscape(keystoneName)
	return new("Item"):Item("Rarity: UNIQUE\nImpossible Escape\nViridian Jewel\nVariant: " .. tostring(keystoneName) ..
		"\nSelected Variant: 1\nRadius: Small\nImplicits: 0\n" ..
		"Passive Skills in radius of " .. tostring(keystoneName) .. " can be allocated without being connected to your tree\n")
end

local function assertSocketEmpty(spec, socketId, message)
	assert.are.equal(0, tonumber(spec.jewels[socketId]) or 0, message)
end

local function unconnectedRadiusTargets(spec, socket, jewel)
	local targets = { }
	local function includeRadius(nodes)
		for nodeId, node in pairs(nodes or { }) do
			if node and not spec.allocNodes[nodeId] and not node.connectedToStart
				and node.type ~= "Mastery" and node.type ~= "Socket" and not node.ascendancyName then
				targets[nodeId] = true
			end
		end
	end
	if jewel.jewelData.intuitiveLeapLike then
		includeRadius(socket.nodesInRadius and socket.nodesInRadius[jewel.jewelRadiusIndex])
	end
	for keystoneName in pairs(jewel.jewelData.impossibleEscapeKeystones or { }) do
		local keystone = spec.tree and spec.tree.keystoneMap and spec.tree.keystoneMap[keystoneName]
		includeRadius(keystone and keystone.nodesInRadius and keystone.nodesInRadius[jewel.jewelRadiusIndex])
	end
	return targets
end

local function assertRadiusExceptionCandidate(jewel, expectedTargets, label, socket)
	local sourceSpec = build.spec
	socket = socket or allocatePathToNearestSocket(sourceSpec)
	build.itemsTab:AddItem(jewel, true)
	assert.is_truthy(jewel.id and jewel.id > 0, label .. " must be a native inventory item")
	assert.is_truthy(jewel.jewelRadiusIndex, label .. " must use a PoB radius index")
	local sourceSignature = Candidate.BuildSignature(build)
	local sourceRaw = jewel:BuildRaw()
	local parsed = assert(Inputs.Parse({ }))
	local regions = TreeSearch.BuildRegionMap(sourceSpec)
	local options = TreeSearch.BuildJewelCandidates(sourceSpec, 128, 1, 17)
	local selected, projected, isolatedItems
	for _, option in ipairs(options) do
		local variant = option.jewelVariant
		local targetId = option.nodeIds and option.nodeIds[1]
		if variant and variant.itemId == jewel.id and variant.toNodeId == socket.id
			and #option.nodeIds == 1 and expectedTargets[targetId] then
			local testProjection, _, testItems = Candidate.BuildPassiveSpec(build, option.nodeIds, { }, {
				jewelVariant = variant,
			})
			if testProjection and testProjection.nodes[targetId].connectedToStart == false then
				local valid = TreeSearch.ValidateCandidate(sourceSpec, option.nodeIds, parsed, regions, { }, testProjection)
				if valid then
					selected, projected, isolatedItems = option, testProjection, testItems
					break
				end
			end
		end
	end
	assert.is_truthy(selected, label .. " must propose a disconnected passive inside its native radius")
	local targetId = selected.nodeIds[1]
	assert.are.equal(sourceSpec:CountAllocNodes() + 1, projected:CountAllocNodes(), label .. " target must consume exactly one passive point")

	local assignedItemId = projected.jewels[socket.id]
	projected.jewels[socket.id] = nil
	local acceptedWithoutProvider, providerError = TreeSearch.ValidateCandidate(sourceSpec, selected.nodeIds, parsed, regions, { }, projected)
	projected.jewels[socket.id] = assignedItemId
	assert.is_false(acceptedWithoutProvider, label .. " disconnected allocation must fail when its provider is removed")
	assert.is_truthy(providerError:find("disconnected from every selected PoB start", 1, true))

	local isolatedBuild = { spec = projected, itemsTab = isolatedItems }
	setmetatable(isolatedBuild, { __index = build })
	local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
	local exactOutput, exactEnv = exactCalc({ spec = projected, returnEnv = true }, true)
	assert.is_truthy(exactOutput and exactEnv, label .. " must reach PoB's exact calculation pipeline")
	assert.are.equal(sourceSignature, Candidate.BuildSignature(build), label .. " exact evaluation must preserve the source build")
	assert.are.equal(sourceRaw, jewel:BuildRaw(), label .. " exact evaluation must not mutate the inventory item")
	assertSocketEmpty(sourceSpec, socket.id, label .. " exact evaluation must keep the source socket empty")
	assert.is_nil(sourceSpec.allocNodes[targetId], label .. " exact evaluation must preserve the source tree")

	local applied, message = Candidate.Apply(build, {
		feasible = true,
		sourceSignature = sourceSignature,
		nodeIds = projected.optimizerAddedNodeIds,
		removeNodeIds = projected.optimizerRemovedNodeIds,
		jewelVariant = selected.jewelVariant,
		label = label .. " radius candidate",
	})
	assert.is_true(applied, message)
	assert.is_true(build.spec ~= sourceSpec, label .. " apply must create a separate tree spec")
	assert.are.equal(jewel.id, build.spec.jewels[socket.id])
	assert.is_truthy(build.spec.allocNodes[targetId])
	assertSocketEmpty(sourceSpec, socket.id, label .. " apply must preserve the original socket")
	assert.is_nil(sourceSpec.allocNodes[targetId], label .. " apply must preserve the original tree")
end

describe("Optimizer native radius jewel candidates", function()
	before_each(function()
		newBuild()
	end)

	it("keeps the native passive tree loadable when a source socket item is missing", function()
		local spec = build.spec
		local socket = allocatePathToNearestSocket(spec)
		local missingItemId = 2147483647
		local previousItemId = spec.jewels[socket.id]
		spec.jewels[socket.id] = missingItemId

		local ok, loadError = pcall(spec.BuildAllDependsAndPaths, spec)

		spec.jewels[socket.id] = previousItemId
		assert.is_true(ok, "a missing source item must not abort passive-tree recovery: " .. tostring(loadError))
		assert.is_nil(build.itemsTab.items[missingItemId])
		assert.is_true(spec.allocNodes[socket.id] ~= nil)
	end)

	it("places an inventory Thread of Hope, validates native disconnected access, calculates exactly, and applies a separate spec", function()
		local sourceSpec = build.spec
		local socket = allocatePathToNearestSocket(sourceSpec)
		local jewel = newThreadOfHope()
		build.itemsTab:AddItem(jewel, true)
		assert.is_truthy(jewel.id and jewel.id > 0)
		assert.is_truthy(jewel.jewelData and jewel.jewelData.intuitiveLeapLike)
		assert.is_truthy(jewel.jewelRadiusIndex)
		assertSocketEmpty(sourceSpec, socket.id, "the radius jewel begins in inventory")

		local sourceJewelRaw = jewel:BuildRaw()
		local sourceSignature = Candidate.BuildSignature(build)
		local sourcePoints = sourceSpec:CountAllocNodes()
		local options = TreeSearch.BuildJewelCandidates(sourceSpec, 64, 1, 17)
		local selected, projected, isolatedItems, validationReason
		local parsed = assert(Inputs.Parse({ }))
		local regions = TreeSearch.BuildRegionMap(sourceSpec)
		for _, option in ipairs(options) do
			if option.jewelVariant and option.jewelVariant.sourceKind == "inventory"
				and option.jewelVariant.itemId == jewel.id and option.jewelVariant.toNodeId == socket.id
				and #option.nodeIds == 1 then
				local testProjection, projectionError, testItems = Candidate.BuildPassiveSpec(build, option.nodeIds, { }, {
					jewelVariant = option.jewelVariant,
				})
				if testProjection and testProjection.nodes[option.nodeIds[1]].connectedToStart == false then
					local valid, reason = TreeSearch.ValidateCandidate(sourceSpec, option.nodeIds, parsed, regions, { }, testProjection)
					if valid then
						selected, projected, isolatedItems = option, testProjection, testItems
						break
					end
					validationReason = reason
				else
					validationReason = projectionError
				end
			end
		end
		assert.is_truthy(selected, "a legal disconnected radius candidate should be generated and validated: " .. tostring(validationReason))
		assert.are.equal(jewel.id, projected.jewels[socket.id])
		assert.are.equal(sourcePoints + 1, projected:CountAllocNodes(), "only the chosen radius passive costs a point")
		local targetId = selected.nodeIds[1]
		assert.is_false(projected.nodes[targetId].connectedToStart)

		-- Removing the native socket provider must make this same disconnected
		-- allocation fail the final graph validator.
		projected.jewels[socket.id] = nil
		local acceptedWithoutProvider, providerError = TreeSearch.ValidateCandidate(sourceSpec, selected.nodeIds, parsed, regions, { }, projected)
		projected.jewels[socket.id] = jewel.id
		assert.is_false(acceptedWithoutProvider)
		assert.is_truthy(providerError:find("disconnected from every selected PoB start", 1, true))

		local isolatedBuild = { spec = projected, itemsTab = isolatedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local exactOutput, exactEnv = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_truthy(exactOutput and exactEnv, "candidate must reach PoB's exact calculation pipeline")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "phantom evaluation must not mutate the source build")
		assertSocketEmpty(sourceSpec, socket.id, "exact evaluation must keep the source socket empty")
		assert.is_nil(sourceSpec.allocNodes[targetId])
		assert.are.equal(sourceJewelRaw, jewel:BuildRaw(), "phantom evaluation must not edit the inventory item")

		local applied, message = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = projected.optimizerAddedNodeIds,
			removeNodeIds = projected.optimizerRemovedNodeIds,
			jewelVariant = selected.jewelVariant,
			label = selected.label,
		})
		assert.is_true(applied, message)
		assert.is_true(build.spec ~= sourceSpec, "apply must create and select a separate native PoB tree spec")
		assert.are.equal(jewel.id, build.spec.jewels[socket.id])
		assert.is_truthy(build.spec.allocNodes[targetId])
		assertSocketEmpty(sourceSpec, socket.id, "the original spec must remain unchanged")
		assert.is_nil(sourceSpec.allocNodes[targetId], "the original allocation must remain unchanged")
	end)

	it("combines overlapping native radius providers and still rejects origin-return loops", function()
		local sourceSpec = build.spec
		local firstSocket = allocatePathToNearestSocket(sourceSpec)
		local secondSocket = allocatePathToNearestSocket(sourceSpec, { [firstSocket.id] = true })
		assert.are_not.equal(firstSocket.id, secondSocket.id)
		local firstJewel, secondJewel = newThreadOfHope(), newThreadOfHope()
		build.itemsTab:AddItem(firstJewel, true)
		build.itemsTab:AddItem(secondJewel, true)
		local radiusIndex = firstJewel.jewelRadiusIndex
		assert.are.equal(radiusIndex, secondJewel.jewelRadiusIndex)
		local firstRadius = firstSocket.nodesInRadius[radiusIndex]
		local secondRadius = secondSocket.nodesInRadius[radiusIndex]
		local expectedTargets = { }
		for nodeId, node in pairs(firstRadius or { }) do
			if secondRadius and secondRadius[nodeId] and not node.alloc and not node.connectedToStart
				and node.type ~= "Mastery" and node.type ~= "Socket" and not node.ascendancyName then
				expectedTargets[nodeId] = true
			end
		end
		assert.is_true(next(expectedTargets) ~= nil, "the selected native socket radii must overlap on an unconnected passive")

		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({ }))
		local regions = TreeSearch.BuildRegionMap(sourceSpec)
		local candidates = TreeSearch.BuildJewelCandidates(sourceSpec, 64, 2, 17)
		local selected, selectedItemsBySocket, sharedSingles, compositeCount = nil, nil, 0, 0
		for _, option in ipairs(candidates) do
			if option.jewelVariants then compositeCount = compositeCount + 1 end
			if option.jewelVariant and #option.nodeIds == 1 and expectedTargets[option.nodeIds[1]] then
				sharedSingles = sharedSingles + 1
			end
			if option.jewelCombination == "overlapping_radius_providers" and option.jewelVariants
				and #option.jewelVariants == 2 and #option.nodeIds == 1 and expectedTargets[option.nodeIds[1]] then
				local itemBySocket = { }
				for _, variant in ipairs(option.jewelVariants) do
					itemBySocket[variant.toNodeId] = variant.itemId
				end
				local hasExpectedItems = (itemBySocket[firstSocket.id] == firstJewel.id
					and itemBySocket[secondSocket.id] == secondJewel.id)
					or (itemBySocket[firstSocket.id] == secondJewel.id
					and itemBySocket[secondSocket.id] == firstJewel.id)
				if hasExpectedItems then
					selected = option
					selectedItemsBySocket = itemBySocket
					break
				end
			end
		end
		local expectedTargetCount = 0
		for _ in pairs(expectedTargets) do expectedTargetCount = expectedTargetCount + 1 end
		assert.is_truthy(selected, string.format("bounded jewel generation must preserve a two-provider overlap candidate (targets=%s; generated=%s; shared singles=%s; composites=%s; sockets=%s/%s; items=%s/%s)",
			tostring(expectedTargetCount), tostring(#candidates), tostring(sharedSingles), tostring(compositeCount),
			tostring(firstSocket.id), tostring(secondSocket.id), tostring(firstJewel.id), tostring(secondJewel.id)))

		local projected, projectionError, isolatedItems = Candidate.BuildPassiveSpec(build, selected.nodeIds, { }, {
			jewelVariants = selected.jewelVariants,
		})
		assert.is_truthy(projected, projectionError)
		local targetId = selected.nodeIds[1]
		assert.is_false(projected.nodes[targetId].connectedToStart)
		local valid, validationError = TreeSearch.ValidateCandidate(sourceSpec, selected.nodeIds, parsed, regions, { }, projected)
		assert.is_true(valid, validationError)
		assert.are.equal(selectedItemsBySocket[firstSocket.id], projected.jewels[firstSocket.id])
		assert.are.equal(selectedItemsBySocket[secondSocket.id], projected.jewels[secondSocket.id])

		-- A disconnected passive supported by two real radius providers remains
		-- legal, but those providers must not exempt a separate route that closes
		-- a cycle back to the selected class origin.
		local originLoopRoute = assert(findOriginLoopRoute(sourceSpec),
			"the loaded PoB tree must expose an alternate route from the class start to its existing allocation")
		local combinedNodeIds, combinedSeen = { }, { }
		for _, nodeId in ipairs(originLoopRoute) do
			if not combinedSeen[nodeId] then
				combinedSeen[nodeId] = true
				combinedNodeIds[#combinedNodeIds + 1] = nodeId
			end
		end
		for _, nodeId in ipairs(selected.nodeIds) do
			if not combinedSeen[nodeId] then
				combinedSeen[nodeId] = true
				combinedNodeIds[#combinedNodeIds + 1] = nodeId
			end
		end
		local loopProjection, loopProjectionError = Candidate.BuildPassiveSpec(build, combinedNodeIds, { }, {
			jewelVariants = selected.jewelVariants,
		})
		assert.is_truthy(loopProjection, loopProjectionError)
		local loopAccepted, loopError = TreeSearch.ValidateCandidate(sourceSpec, combinedNodeIds, parsed, regions, { }, loopProjection)
		assert.is_false(loopAccepted, "overlapping radius providers must not authorize a new cycle returning to class start")
		assert.is_truthy(loopError:find("One-way routing policy", 1, true), loopError)

		local isolatedBuild = { spec = projected, itemsTab = isolatedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local exactOutput, exactEnv = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_truthy(exactOutput and exactEnv, "the combined candidate must reach the exact PoB calculation")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "exact evaluation must preserve the source build")
		assertSocketEmpty(sourceSpec, firstSocket.id, "the first source socket must stay empty")
		assertSocketEmpty(sourceSpec, secondSocket.id, "the second source socket must stay empty")
		assert.is_nil(sourceSpec.allocNodes[targetId])

		local searchInputs = assert(Inputs.Parse({
			objectiveMetric = "TotalEHP",
			maxAddedPoints = "2",
			maxTotalPoints = "120",
			evaluationBudget = "64",
			seed = "17",
		}))
		local job = PhantomSim.RunPhantomSim(build, searchInputs, { cancelled = false })
		local searchStatus
		for _ = 1, 1000 do
			searchStatus = job:Step()
			if searchStatus ~= "running" then break end
		end
		assert.are.equal("feasible", job.status, job.error or "the exact PoB search should retain its feasible current build")
		assert.is_true(job.result.searchCoverage.jewels.generatedOverlappingCandidates > 0)
		assert.is_true(job.result.searchCoverage.jewels.exactOverlappingEvaluations > 0,
			"an overlapping-provider candidate must reach PhantomSim's exact PoB evaluation")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "the full optimizer job must preserve the source build")

		local applied, applyMessage = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = projected.optimizerAddedNodeIds,
			jewelVariants = selected.jewelVariants,
			label = selected.label,
		})
		assert.is_true(applied, applyMessage)
		assert.is_true(build.spec ~= sourceSpec)
		assert.are.equal(selectedItemsBySocket[firstSocket.id], build.spec.jewels[firstSocket.id])
		assert.are.equal(selectedItemsBySocket[secondSocket.id], build.spec.jewels[secondSocket.id])
		assert.is_truthy(build.spec.allocNodes[targetId])
		assertSocketEmpty(sourceSpec, firstSocket.id, "applying must preserve the original first socket")
		assertSocketEmpty(sourceSpec, secondSocket.id, "applying must preserve the original second socket")
	end)

	it("uses Intuitive Leap's native socket radius for disconnected access and rejects removing its provider", function()
		local sourceSpec = build.spec
		local socket = allocatePathToNearestSocket(sourceSpec)
		local jewel = newIntuitiveLeap()
		assert.is_truthy(jewel.jewelData.intuitiveLeapLike, "PoB must identify Intuitive Leap as a native radius provider")
		local expectedTargets = unconnectedRadiusTargets(sourceSpec, socket, jewel)
		assert.is_true(next(expectedTargets) ~= nil, "the selected socket's native Small Radius must contain disconnected passives")
		assertRadiusExceptionCandidate(jewel, expectedTargets, "Intuitive Leap", socket)
	end)

	it("uses only the selected Impossible Escape keystone radius for disconnected access", function()
		local sourceSpec = build.spec
		local socket = allocatePathToNearestSocket(sourceSpec)
		local radiusIndex = newIntuitiveLeap().jewelRadiusIndex
		local keystoneNames = { }
		for name in pairs(sourceSpec.tree.keystoneMap or { }) do keystoneNames[#keystoneNames + 1] = name end
		table.sort(keystoneNames)
		local selectedKeystone
		for _, keystoneName in ipairs(keystoneNames) do
			local keystone = sourceSpec.tree.keystoneMap[keystoneName]
			local radius = keystone and keystone.nodesInRadius and keystone.nodesInRadius[radiusIndex]
			for nodeId, node in pairs(radius or { }) do
				if node and not sourceSpec.allocNodes[nodeId] and not node.connectedToStart
					and node.type ~= "Mastery" and node.type ~= "Socket" and not node.ascendancyName then
					selectedKeystone = keystone.name or keystoneName
					break
				end
			end
			if selectedKeystone then break end
		end
		assert.is_truthy(selectedKeystone, "the loaded PoB tree must provide a keystone radius with disconnected passives")
		local jewel = newImpossibleEscape(selectedKeystone)
		local keystoneCount, expectedTargets = 0, unconnectedRadiusTargets(sourceSpec, socket, jewel)
		for _ in pairs(jewel.jewelData.impossibleEscapeKeystones or { }) do keystoneCount = keystoneCount + 1 end
		assert.are.equal(1, keystoneCount, "the selected real variant must target exactly one native keystone")
		assert.is_true(next(expectedTargets) ~= nil, "the selected keystone's native Small Radius must contain disconnected passives")
		assertRadiusExceptionCandidate(jewel, expectedTargets, "Impossible Escape", socket)
	end)
end)
