-- Path of Building
--
-- Module: bounded candidates for native Cluster Jewel expansion graphs.
-- Every virtual node and path is produced by PassiveSpec:BuildClusterJewelGraphs;
-- this module only proposes a legal socket/item pair and a target node.

local Candidate = require("Modules.Optimizer.Candidate")
local TreeSearch = require("Modules.Optimizer.TreeSearch")
local t_sort = table.sort
local t_sqrt = math.sqrt
local clusterSearch = { }

local function lower(value)
	return tostring(value or ""):lower()
end

local function copyTable(source)
	local copy = { }
	for key, value in pairs(source or { }) do copy[key] = value end
	return copy
end

local function sampleIndex(sample, sampleCount, totalCount, offset)
	if totalCount <= 1 then return 1 end
	return ((offset + math.floor((sample - 1) * totalCount / sampleCount)) % totalCount) + 1
end

local function pathCost(node)
	if not node or type(node.path) ~= "table" then return nil end
	local cost = 0
	for _, pathNode in ipairs(node.path) do
		if not pathNode.alloc and pathNode.type ~= "ClassStart" and pathNode.type ~= "AscendClassStart" then
			cost = cost + 1
		end
	end
	return cost
end

local function isCluster(item)
	return item and item.type == "Jewel" and item.clusterJewel
		and item.jewelData and item.jewelData.clusterJewelValid
end

local function hasNestedSocketPotential(item)
	if not isCluster(item) or item.clusterJewel.size == "Small" then return false end
	local jewelData = item.jewelData
	local socketCount = tonumber(jewelData.clusterJewelSocketCountOverride or jewelData.clusterJewelSocketCount) or 0
	return socketCount > 0
end

-- Replacing an installed parent is safe only when none of its generated graph
-- is in use. This keeps existing allocations and nested jewels intact until a
-- full subtree-remapping solver can prove an equivalent replacement.
local function canReplaceInstalledCluster(spec, socketId)
	local foundGraph = false
	for _, subGraph in pairs(spec.subGraphs or { }) do
		if subGraph.parentSocket and subGraph.parentSocket.id == socketId then
			foundGraph = true
			for _, node in ipairs(subGraph.nodes or { }) do
				if node.alloc then return false end
				if node.type == "Socket" and (tonumber(spec.jewels[node.id]) or 0) > 0 then return false end
			end
		end
	end
	return foundGraph
end

local function canEquipAt(build, item, socket, projectedSpec)
	local itemsTab = build.itemsTab
	if not itemsTab or type(itemsTab.IsItemValidForSlot) ~= "function" then return false end
	local itemTabProxy = copyTable(itemsTab)
	setmetatable(itemTabProxy, getmetatable(itemsTab))
	local buildProxy = copyTable(build)
	setmetatable(buildProxy, getmetatable(build))
	buildProxy.spec = projectedSpec or build.spec
	itemTabProxy.build = buildProxy
	local ok, valid = pcall(itemTabProxy.IsItemValidForSlot, itemTabProxy, item, "Jewel " .. tostring(socket.id))
	return ok and valid == true
end

local function pathNodeIds(node, sourceSpec)
	local ids, seen = { }, { }
	for _, pathNode in ipairs(node and node.path or { }) do
		if pathNode and pathNode.id and not seen[pathNode.id]
			and pathNode.type ~= "ClassStart" and pathNode.type ~= "AscendClassStart"
			and not (sourceSpec.allocNodes and sourceSpec.allocNodes[pathNode.id]) then
			seen[pathNode.id] = true
			ids[#ids + 1] = pathNode.id
		end
	end
	return ids
end

local function mergePathNodeIds(firstNode, secondNode, sourceSpec)
	local ids = pathNodeIds(firstNode, sourceSpec)
	local seen = { }
	for _, nodeId in ipairs(ids) do seen[nodeId] = true end
	for _, nodeId in ipairs(pathNodeIds(secondNode, sourceSpec)) do
		if not seen[nodeId] then
			seen[nodeId] = true
			ids[#ids + 1] = nodeId
		end
	end
	return ids
end

local function isAllowedRegion(name, branch)
	local region = lower(name)
	local allowed, forbidden = { }, { }
	for _, value in ipairs(branch.allowed or { }) do allowed[lower(value)] = true end
	for _, value in ipairs(branch.forbidden or { }) do forbidden[lower(value)] = true end
	if lower(branch.partition) == "spatial" and next(allowed) and not forbidden.hub then
		allowed.hub = true -- Hub transit remains point-costed by PoB.
	end
	return not forbidden[region] and (not next(allowed) or allowed[region])
end

local function collectTargets(projected, subGraph, inputs, regionByNode, spatialMetadata)
	local targetNodes = { }
	local virtualParents = TreeSearch.BuildVirtualParentSocketMap(projected)
	for _, node in ipairs(subGraph.nodes or { }) do
		local cost = pathCost(node)
		local region = TreeSearch.ResolveNodeRegion(projected, node.id,
			inputs.branch and inputs.branch.partition or "class", regionByNode, spatialMetadata, virtualParents)
		if cost and cost > 0 and node.expansionSkill and node.type ~= "Socket" and node.type ~= "Mastery"
			and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not node.ascendancyName
			and not node.isProxy and not node.isMultipleChoiceOption and not node.alloc
			and isAllowedRegion(region, inputs.branch or { }) then
			targetNodes[#targetNodes + 1] = { node = node, cost = cost }
		end
	end
	t_sort(targetNodes, function(a, b)
		local function priority(node)
			return node.type == "Keystone" and 1 or node.type == "Notable" and 2 or 3
		end
		local priorityA, priorityB = priority(a.node), priority(b.node)
		if priorityA ~= priorityB then return priorityA < priorityB end
		if a.cost ~= b.cost then return a.cost < b.cost end
		return a.node.id < b.node.id
	end)
	return targetNodes
end

local function addNestedCandidates(build, sourceSpec, parentProjected, parentVariant, parentItem, inventory,
		inputs, regionByNode, spatialMetadata, forbiddenNodeIds, maxAddedPoints, nestedCandidates, nestedLimit,
		projectionState, coverage, control)
	for _, parentGraph in pairs(parentProjected.subGraphs or { }) do
		if parentGraph.parentSocket and parentGraph.parentSocket.id == parentVariant.toNodeId then
			local nestedSockets = { }
			for _, node in ipairs(parentGraph.nodes or { }) do
				if node.type == "Socket" and node.expansionJewel and node.expansionJewel.size < 2 then
					nestedSockets[#nestedSockets + 1] = node
				end
			end
			t_sort(nestedSockets, function(a, b) return a.id < b.id end)
			coverage.nestedAvailableSockets = coverage.nestedAvailableSockets + #nestedSockets
			for _, nestedSocket in ipairs(nestedSockets) do
				for _, childJewel in ipairs(inventory) do
					if #nestedCandidates >= nestedLimit or projectionState.count >= projectionState.limit then return false end
					if control and control.cancelled then return true end
					if childJewel.id ~= parentVariant.itemId and canEquipAt(build, childJewel.item, nestedSocket, parentProjected) then
						local childVariant = {
							toNodeId = nestedSocket.id,
							itemId = childJewel.id,
							targetItemId = 0,
							sourceKind = "cluster",
						}
						local pair = { parentVariant, childVariant }
						local socketPath = pathNodeIds(nestedSocket, sourceSpec)
						local projectionOk, childProjection = pcall(Candidate.BuildPassiveSpec, build, socketPath, { }, {
							jewelVariants = pair,
						})
						projectionState.count = projectionState.count + 1
						coverage.nestedProjectedPlacements = coverage.nestedProjectedPlacements + 1
						if not projectionOk or not childProjection then
							coverage.invalidProjections = coverage.invalidProjections + 1
						else
							for _, childGraph in pairs(childProjection.subGraphs or { }) do
								if childGraph.parentSocket and childGraph.parentSocket.id == nestedSocket.id then
									local targets = collectTargets(childProjection, childGraph, inputs, regionByNode, spatialMetadata)
									for _, target in ipairs(targets) do
										if target.cost <= maxAddedPoints and not forbiddenNodeIds[target.node.id] then
											coverage.nestedAvailableTargets = coverage.nestedAvailableTargets + 1
											nestedCandidates[#nestedCandidates + 1] = {
											nodeIds = mergePathNodeIds(nestedSocket, target.node, sourceSpec),
											jewelVariants = { parentVariant, childVariant },
											jewelCombination = "parent_child_cluster",
											label = string.format("%s + %s; nested target %s (+%d points)",
												tostring(parentItem.name or parentItem.baseName or "Cluster Jewel"),
												tostring(childJewel.item.name or childJewel.item.baseName or "Cluster Jewel"),
												tostring(target.node.dn or target.node.name or target.node.id), target.cost),
										}
										coverage.nestedGeneratedCandidates = coverage.nestedGeneratedCandidates + 1
										if #nestedCandidates >= nestedLimit then return false end
									end
								end
								break
							end
							end
						end
					end
				end
			end
		end
	end
	return false
end

function clusterSearch.BuildCandidates(build, limit, maxAddedPoints, inputs, regionByNode, spatialMetadata, control, progressFunc)
	local candidates = { }
	local coverage = {
		inventoryItems = 0,
		allocatedExpansionSockets = 0,
		availablePlacements = 0,
		replaceableClusterSockets = 0,
		replacementPlacements = 0,
		projectedPlacements = 0,
		availableTargets = 0,
		generatedCandidates = 0,
		exactEvaluations = 0,
		nestedAvailableSockets = 0,
		nestedProjectedPlacements = 0,
		nestedAvailableTargets = 0,
		nestedGeneratedCandidates = 0,
		nestedExactEvaluations = 0,
		invalidProjections = 0,
	}
	if limit <= 0 or not build or not build.spec or not build.itemsTab then return candidates, coverage end
	maxAddedPoints = math.max(0, tonumber(maxAddedPoints) or 0)
	if maxAddedPoints == 0 then return candidates, coverage end
	inputs = inputs or { branch = { partition = "class" }, search = { } }
	local spec = build.spec
	local usedItems, inventory, sockets = { }, { }, { }
	local forbiddenNodeIds = { }
	for _, nodeId in ipairs(inputs.search and inputs.search.forbiddenNodeIds or { }) do
		forbiddenNodeIds[nodeId] = true
	end
	for _, itemId in pairs(spec.jewels or { }) do
		if itemId and itemId > 0 then usedItems[itemId] = true end
	end
	for itemId, item in pairs(build.itemsTab.items or { }) do
		if type(itemId) == "number" and itemId > 0 and not usedItems[itemId] and isCluster(item) then
			inventory[#inventory + 1] = { id = itemId, item = item }
		end
	end
	t_sort(inventory, function(a, b) return a.id < b.id end)
	coverage.inventoryItems = #inventory
	for nodeId, node in pairs(spec.allocNodes or { }) do
		if node and node.type == "Socket" and node.expansionJewel then
			sockets[#sockets + 1] = nodeId
		end
	end
	t_sort(sockets)
	coverage.allocatedExpansionSockets = #sockets
	if #inventory == 0 or #sockets == 0 then return candidates, coverage end

	local placements = { }
	local replaceableSockets = { }
	for _, socketId in ipairs(sockets) do
		local itemId = spec.jewels[socketId] or 0
		local item = itemId > 0 and build.itemsTab.items[itemId]
		if isCluster(item) and canReplaceInstalledCluster(spec, socketId) then
			replaceableSockets[socketId] = true
			coverage.replaceableClusterSockets = coverage.replaceableClusterSockets + 1
		end
	end
	for _, jewel in ipairs(inventory) do
		for _, socketId in ipairs(sockets) do
			local socket = spec.allocNodes[socketId]
			local currentItemId = spec.jewels[socketId] or 0
			local currentItem = currentItemId > 0 and build.itemsTab.items[currentItemId]
			local currentIsCluster = isCluster(currentItem)
			local replaceable = currentIsCluster and replaceableSockets[socketId]
			if socket and (not currentIsCluster or replaceable) and canEquipAt(build, jewel.item, socket) then
				placements[#placements + 1] = {
					jewel = jewel,
					socket = socket,
					targetItemId = currentItemId,
					replacedItem = currentIsCluster and currentItem or nil,
					replacesCluster = currentIsCluster,
				}
				if currentIsCluster then coverage.replacementPlacements = coverage.replacementPlacements + 1 end
			end
		end
	end
	coverage.availablePlacements = #placements
	if #placements == 0 then return candidates, coverage end

	local placementCount = math.min(#placements, math.max(1, math.ceil(t_sqrt(limit))))
	local targetsPerPlacement = math.max(1, math.ceil(limit / placementCount))
	local outerCandidates, nestedCandidates = { }, { }
	local nestedCandidateLimit = math.min(limit, math.max(1, math.floor(limit / 2)))
	local projectionState = { count = 0, limit = math.min(64, math.max(1, limit * 4)) }
	local seed = tonumber(inputs.search and inputs.search.seed) or 0
	local offset = seed % #placements
	local placementOrder, seenPlacements = { }, { }
	for placementIndex, placement in ipairs(placements) do
		if hasNestedSocketPotential(placement.jewel.item) then
			placementOrder[#placementOrder + 1] = placementIndex
			seenPlacements[placementIndex] = true
			break
		end
	end
	for step = 0, #placements - 1 do
		local placementIndex = ((offset + step) % #placements) + 1
		if not seenPlacements[placementIndex] then
			placementOrder[#placementOrder + 1] = placementIndex
			seenPlacements[placementIndex] = true
		end
	end
	for sample = 1, placementCount do
		if control and control.cancelled then return candidates, coverage, true end
		local placement = placements[placementOrder[sample]]
		local variant = {
			toNodeId = placement.socket.id,
			itemId = placement.jewel.id,
			targetItemId = placement.targetItemId,
			sourceKind = "cluster",
			replacesCluster = placement.replacesCluster,
		}
		local ok, projected, projectionError = pcall(Candidate.BuildPassiveSpec, build, { }, { }, {
			jewelVariant = variant,
		})
		if not ok or not projected then
			coverage.invalidProjections = coverage.invalidProjections + 1
		else
			coverage.projectedPlacements = coverage.projectedPlacements + 1
			for _, subGraph in pairs(projected.subGraphs or { }) do
				if subGraph.parentSocket and subGraph.parentSocket.id == placement.socket.id then
					local targetNodes = collectTargets(projected, subGraph, inputs, regionByNode, spatialMetadata)
					local validTargets = { }
					for _, target in ipairs(targetNodes) do
						if target.cost <= maxAddedPoints and not forbiddenNodeIds[target.node.id] then
							validTargets[#validTargets + 1] = target
						end
					end
					coverage.availableTargets = coverage.availableTargets + #validTargets
					local take = math.min(targetsPerPlacement, #validTargets, limit - #outerCandidates)
					for targetIndex = 1, take do
						local target = validTargets[sampleIndex(targetIndex, take, #validTargets, seed % #validTargets)]
						outerCandidates[#outerCandidates + 1] = {
							nodeIds = { target.node.id },
							jewelVariant = variant,
							label = placement.replacesCluster
								and string.format("Replace %s with %s in cluster socket %s + %s (+%d points)",
									tostring(placement.replacedItem.name or placement.replacedItem.baseName or "Cluster Jewel"),
									tostring(placement.jewel.item.name or placement.jewel.item.baseName or "Cluster Jewel"),
									tostring(placement.socket.id), tostring(target.node.dn or target.node.name or target.node.id), target.cost)
								or string.format("%s in cluster socket %s + %s (+%d points)",
									tostring(placement.jewel.item.name or placement.jewel.item.baseName or "Cluster Jewel"),
									tostring(placement.socket.id), tostring(target.node.dn or target.node.name or target.node.id), target.cost),
						}
					end
					local cancelled = addNestedCandidates(build, spec, projected, variant, placement.jewel.item, inventory,
						inputs, regionByNode, spatialMetadata, forbiddenNodeIds, maxAddedPoints, nestedCandidates,
						nestedCandidateLimit, projectionState, coverage, control)
					if cancelled then return candidates, coverage, true end
				end
			end
		end
		if progressFunc then progressFunc(sample, placementCount, placement.socket.id, placement.jewel.id) end
	end
	for _, candidate in ipairs(nestedCandidates) do
		if #candidates >= limit then break end
		candidates[#candidates + 1] = candidate
	end
	for _, candidate in ipairs(outerCandidates) do
		if #candidates >= limit then break end
		candidates[#candidates + 1] = candidate
	end
	coverage.generatedCandidates = #candidates
	coverage.truncated = coverage.availablePlacements > placementCount or coverage.availableTargets > #outerCandidates
		or coverage.nestedAvailableTargets > coverage.nestedGeneratedCandidates
	return candidates, coverage
end

return clusterSearch
