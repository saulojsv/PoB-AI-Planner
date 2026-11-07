-- Path of Building
--
-- Module: Deterministic passive-tree path repair.
-- A* runs over the selected tree graph. Forbidden regions are removed from new
-- routes; already allocated nodes remain valid starting points for the build.
--
local t_insert = table.insert
local t_sort = table.sort
local Anoints = require("Modules.Optimizer.Anoints")
local SpatialZones = require("Modules.Optimizer.SpatialZones")
local Inputs = require("Modules.Optimizer.Inputs")

local treeSearch = { }
local MAX_ARCHIVED_ROUTE_TARGET_ATTEMPTS = 32
local MAX_ARCHIVED_ROUTE_VARIANTS_PER_PATTERN = 4
local timelessTypeByConqueror = {
	vaal = 1,
	karui = 2,
	maraketh = 3,
	templar = 4,
	eternal = 5,
	kalguur = 6,
	abyss_murderous = 7,
	abyss_searching = 8,
	abyss_hypnotic = 9,
	abyss_ghastly = 10,
	abyss_special = 11,
}

local function lower(value)
	return tostring(value or ""):lower()
end

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

-- Convert exact PoB use requirements and explicit attribute floors into a
-- proposal-ordering hint. This never certifies a route: every candidate is
-- still recalculated and gated against the same native PoB output.
function treeSearch.ConfigureRequirementAttributeFocus(inputs, exactOutput, exactContext)
	if type(inputs) ~= "table" or type(inputs.search) ~= "table" then return { } end
	local focused = { }
	inputs.search.omniAttributeConversionActive = exactContext and exactContext.omniAttributeConversionActive == true or false
	for _, attribute in ipairs({ "Str", "Dex", "Int", "Omni" }) do
		local current = exactOutput and exactOutput[attribute]
		local required = exactOutput and exactOutput["Req" .. attribute]
		local floor = inputs.hard and inputs.hard[attribute]
		local floorNeedsRoute = floor and (not isFinite(current) or current < floor.value)
		local nativeRequirementNeedsRoute = isFinite(current) and isFinite(required) and required > current
		if floorNeedsRoute or nativeRequirementNeedsRoute then focused[attribute] = true end
	end
	inputs.search.requirementAttributes = focused
	return focused
end

local function showNodePowerPerPoint(node, inputs)
	local search = inputs and inputs.search or { }
	if search.useShowNodePower ~= true or type(search.nodePowerStat) ~= "string"
		or search.nodePowerStat == "" or search.nodePowerStat ~= search.nodePowerFocusStat then return nil end
	local power = node and node.power
	local value = power and (isFinite(power.pathPower) and power.pathPower or power.singleStat)
	if not isFinite(value) or value <= 0 then return nil end
	local pointCost = tonumber(node.pathDist) or tonumber(power.distance) or 1
	return value / math.max(1, pointCost)
end

local function nodePotentialPreferenceScore(node, inputs, nodePowerNormalizer)
	local text = lower((node.dn or "") .. " " .. (node.name or ""))
	local score = 0
	local function addTerms(terms)
		for _, entry in ipairs(terms or { }) do
			if text:find(entry[1], 1, true) then score = score + entry[2] end
		end
	end
	local damageTerms = {
		PhysicalHit = { { "physical damage", 50 }, { "physical", 25 }, { "attack damage", 20 }, { "attack speed", 15 }, { "accuracy", 8 } },
		PhysicalImpale = { { "impale", 70 }, { "physical damage", 45 }, { "physical", 20 }, { "attack speed", 12 } },
		PhysicalDoT = { { "physical damage over time", 70 }, { "damage over time multiplier", 35 }, { "bleed", 30 }, { "physical damage", 15 } },
		Fire = { { "fire damage", 55 }, { "fire", 30 }, { "elemental damage", 20 }, { "elemental", 8 } },
		Cold = { { "cold damage", 55 }, { "cold", 30 }, { "elemental damage", 20 }, { "elemental", 8 } },
		Lightning = { { "lightning damage", 55 }, { "lightning", 30 }, { "elemental damage", 20 }, { "elemental", 8 } },
		ChaosPoison = { { "poison", 55 }, { "chaos damage", 40 }, { "chaos", 22 }, { "damage over time", 15 } },
		Minions = { { "minion damage", 60 }, { "minion", 35 }, { "minions", 35 } },
	}
	local preferences = inputs.preferences or { }
	addTerms(damageTerms[preferences.damageFocus])
	local attributeTerms = {
		Str = { { "strength", 250 }, { "all attributes", 220 } },
		Dex = { { "dexterity", 250 }, { "all attributes", 220 } },
		Int = { { "intelligence", 250 }, { "all attributes", 220 } },
		-- CalcPerform converts attribute modifiers to Omniscience when PoB's
		-- native Omniscience flag is active. Attribute text is a route hint only;
		-- the candidate's exact PoB output decides whether it adds Omniscience.
		Omni = { { "omniscience", 250 } },
		OmniConvertedAttributes = {
			{ "all attributes", 240 }, { "strength", 180 },
			{ "dexterity", 180 }, { "intelligence", 180 },
		},
	}
	for attribute in pairs(inputs.search and inputs.search.requirementAttributes or { }) do
		addTerms(attributeTerms[attribute])
		if attribute == "Omni" and inputs.search.omniAttributeConversionActive then
			addTerms(attributeTerms.OmniConvertedAttributes)
		end
	end
	local defenseTerms = {
		Life = { { "maximum life", 45 }, { "life", 24 }, { "life recovery", 10 }, { "life regeneration", 10 } },
		EnergyShield = { { "maximum energy shield", 45 }, { "energy shield", 25 }, { "es recharge", 10 } },
		Hybrid = { { "maximum life", 24 }, { "life", 12 }, { "maximum energy shield", 24 }, { "energy shield", 12 } },
		Ward = { { "ward", 50 } },
		Armour = { { "armour", 50 }, { "armour and evasion", 30 }, { "defences", 10 } },
		Evasion = { { "evasion", 50 }, { "armour and evasion", 30 }, { "defences", 10 } },
		Block = { { "block chance", 45 }, { "attack block", 35 }, { "shield block", 30 } },
		SpellBlock = { { "spell block", 50 }, { "block chance", 20 } },
		SpellSuppression = { { "spell suppression", 50 }, { "suppression", 35 } },
	}
	addTerms(defenseTerms[preferences.defenseProfile])
	local powerPerPoint = showNodePowerPerPoint(node, inputs)
	if powerPerPoint and nodePowerNormalizer and nodePowerNormalizer > 0 then
		score = score + math.floor(80 * math.min(1, powerPerPoint / nodePowerNormalizer))
	end
	return score
end

local function importedNodeEvidencePriority(node, inputs)
	local search = inputs and inputs.search
	if not search or (search.nodePotentialAnalysis ~= true and search.importedRouteMemoryEnabled ~= true) then return 0 end
	local priorities = search.nodeEvidencePriorities
	local value = type(priorities) == "table" and tonumber(priorities[node and node.id]) or nil
	if not isFinite(value) then return 0 end
	return math.max(0, math.min(1, value))
end

local function importedEdgeEvidencePriority(nodeA, nodeB, inputs)
	local search = inputs and inputs.search
	if not search or (search.nodePotentialAnalysis ~= true and search.importedRouteMemoryEnabled ~= true) then return 0 end
	local left, right = tonumber(nodeA), tonumber(nodeB)
	if not left or not right or left == right then return 0 end
	if left > right then left, right = right, left end
	local priorities = search.edgeEvidencePriorities
	local value = type(priorities) == "table" and tonumber(priorities[tostring(left) .. ":" .. tostring(right)]) or nil
	if not isFinite(value) then return 0 end
	return math.max(0, math.min(1, value))
end

local function prioritizeNodePotentialTargets(targets, regionByNode, inputs)
	local byRegion, regions = { }, { }
	local powerNormalizer, poweredTargets = 0, 0
	for _, node in ipairs(targets) do
		local powerPerPoint = showNodePowerPerPoint(node, inputs)
		if powerPerPoint then
			poweredTargets = poweredTargets + 1
			powerNormalizer = math.max(powerNormalizer, powerPerPoint)
		end
		local region = tostring(regionByNode[node.id] or "Unknown")
		if not byRegion[region] then
			byRegion[region] = { }
			regions[#regions + 1] = region
		end
		byRegion[region][#byRegion[region] + 1] = node
	end
	local search = inputs and inputs.search or { }
	search.nodePowerCoverage = {
		status = poweredTargets > 0 and "used" or search.useShowNodePower == true and "unavailable" or "disabled",
		stat = search.nodePowerStat,
		focusStat = search.nodePowerFocusStat,
		prioritizedTargets = poweredTargets,
		targets = #targets,
		reason = poweredTargets > 0 and nil or search.nodePowerFallbackReason,
	}
	t_sort(regions)
	for _, region in ipairs(regions) do
		t_sort(byRegion[region], function(a, b)
			local scoreA, scoreB = nodePotentialPreferenceScore(a, inputs, powerNormalizer), nodePotentialPreferenceScore(b, inputs, powerNormalizer)
			if scoreA ~= scoreB then return scoreA > scoreB end
			-- Imported exact-engine builds contribute only a weak, descriptive
			-- tie-break after the native preference score, in the ordinary tree
			-- search and Node Potential. Under a bounded quota this can change which
			-- legal proposal is evaluated earlier; the exact PoB output still owns
			-- every metric and hard gate.
			local evidenceA, evidenceB = importedNodeEvidencePriority(a, inputs), importedNodeEvidencePriority(b, inputs)
			if evidenceA ~= evidenceB then return evidenceA > evidenceB end
			local priorityA = a.type == "Keystone" and 1 or a.type == "Notable" and 2 or 3
			local priorityB = b.type == "Keystone" and 1 or b.type == "Notable" and 2 or 3
			if priorityA ~= priorityB then return priorityA < priorityB end
			return a.id < b.id
		end)
	end
	-- Round-robin class regions so the exact budget does not silently spend its
	-- first evaluations on the lowest node IDs in one side of the tree. The seed
	-- rotates the starting region reproducibly; exact PoB deltas rank outcomes.
	local ordered, cursors = { }, { }
	for _, region in ipairs(regions) do cursors[region] = 1 end
	local offset = #regions > 0 and ((tonumber(inputs.search.seed) or 1) % #regions) or 0
	local remaining = #targets
	while remaining > 0 do
		local added = false
		for index = 1, #regions do
			local region = regions[((index + offset - 1) % #regions) + 1]
			local node = byRegion[region][cursors[region]]
			if node then
				ordered[#ordered + 1] = node
				cursors[region] = cursors[region] + 1
				remaining = remaining - 1
				added = true
			end
		end
		if not added then break end
	end
	return ordered
end

local function buildRegionMap(spec)
	local tree = spec.tree
	local queue, distance, owner = { }, { }, { }
	for classId, class in pairs(tree.classes or { }) do
		local start = class.startNodeId and spec.nodes[class.startNodeId]
		if start then
			distance[start.id] = 0
			owner[start.id] = classId
			queue[#queue + 1] = start
		end
	end
	local cursor = 1
	while cursor <= #queue do
		local node = queue[cursor]
		cursor = cursor + 1
		local nextDistance = distance[node.id] + 1
		for _, linked in ipairs(node.linked or { }) do
			local other = spec.nodes[linked.id]
			if other then
				local oldDistance = distance[other.id]
				if not oldDistance or nextDistance < oldDistance or (nextDistance == oldDistance and owner[node.id] < owner[other.id]) then
					distance[other.id] = nextDistance
					owner[other.id] = owner[node.id]
					queue[#queue + 1] = other
				end
			end
		end
	end
	local regionByNode = { }
	for id, classId in pairs(owner) do
		local class = tree.classes[classId]
		regionByNode[id] = class and class.name or "Unknown"
	end
	return regionByNode
end

local function heapLess(a, b)
	if a.f ~= b.f then return a.f < b.f end
	if a.tie ~= b.tie then return a.tie < b.tie end
	if a.g ~= b.g then return a.g < b.g end
	return a.id < b.id
end

local function heapPush(heap, value)
	local index = #heap + 1
	heap[index] = value
	while index > 1 do
		local parent = math.floor(index / 2)
		if not heapLess(value, heap[parent]) then break end
		heap[index] = heap[parent]
		index = parent
	end
	heap[index] = value
end

local function heapPop(heap)
	local root = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		local index = 1
		while index * 2 <= #heap do
			local child = index * 2
			if child + 1 <= #heap and heapLess(heap[child + 1], heap[child]) then child = child + 1 end
			if not heapLess(heap[child], last) then break end
			heap[index] = heap[child]
			index = child
		end
		heap[index] = last
	end
	return root
end

local function heuristic(node, goals, maxEdgeLength)
	if not node.x or not node.y or maxEdgeLength <= 0 then
		return 0
	end
	local best = math.huge
	for id, goal in pairs(goals) do
		if goal and goal.x and goal.y then
			local dx, dy = node.x - goal.x, node.y - goal.y
			local estimate = math.sqrt(dx * dx + dy * dy) / maxEdgeLength
			if estimate < best then best = estimate end
		end
	end
	return best == math.huge and 0 or best
end

local function findMaxEdgeLength(spec)
	local maxEdgeLength = 0
	for _, node in pairs(spec.nodes) do
		if node.x and node.y then
			for _, linked in ipairs(node.linked or { }) do
				if linked.x and linked.y then
					local dx, dy = node.x - linked.x, node.y - linked.y
					maxEdgeLength = math.max(maxEdgeLength, math.sqrt(dx * dx + dy * dy))
				end
			end
		end
	end
	return maxEdgeLength > 0 and maxEdgeLength or 1
end

local function findPath(spec, seedNodes, goals, regionByNode, forbidden, allowed, blockedNodeIds, tieSeed, maxEdgeLength, control, progressFunc, progressDone, progressTotal, maxCost, inputs)
	local open, gScore, cameFrom, closed = { }, { }, { }, { }
	maxEdgeLength = maxEdgeLength or findMaxEdgeLength(spec)
	local starts = { }
	for _, source in pairs(seedNodes) do
		if source and spec.nodes[source.id] and not starts[source.id] then
			starts[source.id] = true
			gScore[source.id] = 0
			heapPush(open, { id = source.id, g = 0, f = heuristic(source, goals, maxEdgeLength), tie = (source.id + tieSeed) % 997 })
		end
	end
	local reached
	local expanded = 0
	while #open > 0 do
		if control and control.cancelled then return nil, nil, "cancelled" end
		local current = heapPop(open)
		-- A*'s f score is an admissible lower bound on the number of new
		-- passive points needed to reach any goal. Stop as soon as no route
		-- can fit the remaining point budget instead of exploring the whole tree.
		if maxCost and current.f > maxCost then break end
		if not closed[current.id] then
			closed[current.id] = true
			expanded = expanded + 1
			if progressFunc and expanded % 128 == 0 then
				progressFunc(progressDone or 0, progressTotal or 0, expanded)
				if control and control.cancelled then return nil, nil, "cancelled" end
			end
			if goals[current.id] then
				reached = current.id
				break
			end
			local node = spec.nodes[current.id]
			for _, linked in ipairs(node and node.linked or { }) do
				local other = spec.nodes[linked.id]
				if other and not closed[other.id] then
					local isSeed = starts[other.id]
					local region = lower(regionByNode[other.id])
					local blocked = blockedNodeIds[other.id] or forbidden[region] or (next(allowed) and not allowed[region])
					-- Match PassiveSpec:BuildAllDependsAndPaths: class starts,
					-- ascendancy starts/nodes, and masteries are not traversable
					-- additions on a main-tree route. Selected allocated roots
					-- remain valid seeds, and can connect back to the main tree.
					local canTraverse = node.type ~= "Mastery" and (isSeed or (
						other.type ~= "ClassStart" and other.type ~= "AscendClassStart"
						and other.type ~= "Mastery" and not other.ascendancyName
					))
					if canTraverse and (isSeed or not blocked) then
						local tentative = current.g + (isSeed and 0 or 1)
						if not gScore[other.id] or tentative < gScore[other.id] then
							gScore[other.id] = tentative
							cameFrom[other.id] = current.id
							local h = heuristic(other, goals, maxEdgeLength)
							-- Imported exact-engine builds can nudge only an equal-cost
							-- A* tie. This changes route order, never point cost, topology,
							-- region filtering, or final PoB feasibility.
							local tie = ((other.id * 31) + tieSeed) % 997
							local edgePriority = importedEdgeEvidencePriority(current.id, other.id, inputs)
							if edgePriority > 0 then tie = tie - math.floor(edgePriority * 64) end
							heapPush(open, { id = other.id, g = tentative, f = tentative + h, tie = tie })
						end
					end
				end
			end
		end
	end
	if not reached then return nil end
	local route, cursor = { }, reached
	while cursor and not starts[cursor] do
		table.insert(route, 1, spec.nodes[cursor])
		cursor = cameFrom[cursor]
	end
	return route, reached
end

-- For broad route pools, run one bounded multi-source shortest-path field per
-- tie island instead of allocating a fresh A* frontier for every passive goal.
-- Entering an allocated seed costs zero; each proposed node costs one point.
local function buildPathField(spec, seedNodes, regionByNode, forbidden, allowed, blockedNodeIds,
	tieSeed, maxCost, inputs, control, progressFunc)
	local open, distance, cameFrom, closed, starts = { }, { }, { }, { }, { }
	local orderedSeeds = { }
	for _, source in pairs(seedNodes or { }) do
		if source and spec.nodes[source.id] and not starts[source.id] then
			starts[source.id] = true
			orderedSeeds[#orderedSeeds + 1] = source
		end
	end
	t_sort(orderedSeeds, function(left, right) return left.id < right.id end)
	for _, source in ipairs(orderedSeeds) do
		distance[source.id] = 0
		heapPush(open, { id = source.id, g = 0, f = 0, tie = (source.id + tieSeed) % 997 })
	end
	local expanded = 0
	while #open > 0 do
		if control and control.cancelled then return nil, "cancelled" end
		local current = heapPop(open)
		if maxCost and current.g > maxCost then break end
		if not closed[current.id] then
			closed[current.id] = true
			expanded = expanded + 1
			if progressFunc and expanded % 128 == 0 then
				progressFunc(expanded)
				if control and control.cancelled then return nil, "cancelled" end
			end
			local node = spec.nodes[current.id]
			for _, linked in ipairs(node and node.linked or { }) do
				local other = spec.nodes[linked.id]
				if other and not closed[other.id] then
					local isSeed = starts[other.id]
					local region = lower(regionByNode[other.id])
					local blocked = blockedNodeIds[other.id] or forbidden[region] or (next(allowed) and not allowed[region])
					local canTraverse = node.type ~= "Mastery" and (isSeed or (
						other.type ~= "ClassStart" and other.type ~= "AscendClassStart"
						and other.type ~= "Mastery" and not other.ascendancyName
					))
					if canTraverse and (isSeed or not blocked) then
						local tentative = current.g + (isSeed and 0 or 1)
						if (not maxCost or tentative <= maxCost)
							and (not distance[other.id] or tentative < distance[other.id]) then
							distance[other.id] = tentative
							cameFrom[other.id] = current.id
							local tie = ((other.id * 31) + tieSeed) % 997
							local edgePriority = importedEdgeEvidencePriority(current.id, other.id, inputs)
							if edgePriority > 0 then tie = tie - math.floor(edgePriority * 64) end
							heapPush(open, { id = other.id, g = tentative, f = tentative, tie = tie })
						end
					end
				end
			end
		end
	end
	return { starts = starts, distance = distance, cameFrom = cameFrom, expanded = expanded }
end

local function routeFromPathField(spec, field, targetId)
	if not field or field.distance[targetId] == nil then return nil end
	local route, cursor, steps = { }, targetId, 0
	while cursor and not field.starts[cursor] do
		local node = spec.nodes[cursor]
		local parent = field.cameFrom[cursor]
		if not node or not parent then return nil end
		t_insert(route, 1, node)
		cursor = parent
		steps = steps + 1
		if steps > field.expanded then return nil end
	end
	if not cursor then return nil end
	return route
end

local function regionSet(values)
	local set = { }
	for _, value in ipairs(values or { }) do set[lower(value)] = true end
	return set
end

local function countSet(values)
	local count = 0
	for _ in pairs(values or { }) do count = count + 1 end
	return count
end

local function canonicalNodeKey(values)
	local nodeIds = { }
	for _, nodeId in ipairs(values or { }) do nodeIds[#nodeIds + 1] = nodeId end
	t_sort(nodeIds)
	return table.concat(nodeIds, ",")
end

local function idSet(values)
	local set = { }
	for _, value in ipairs(values or { }) do set[value] = true end
	return set
end

local function isMainTreeRouteNode(nodeId, node, spec)
	return node and node.type ~= "AscendClassStart" and node.type ~= "Mastery"
		and not node.ascendancyName and not node.isMultipleChoiceOption and not node.expansionSkill
		and (not spec or not spec.tree or not spec.tree.nodes or spec.tree.nodes[nodeId] ~= nil)
end

-- Count independent cycles in the biconnected blocks that contain the selected
-- class start. The Oracle rule forbids a route loop returning to that origin;
-- unrelated cycles elsewhere in an allocated branch or a radius-only island
-- are not origin loops and must not be rejected by this policy.
local function countOriginCycleRank(allocated, spec, originNodeId)
	local clusterNodeIds = { }
	for _, subGraph in pairs(spec and spec.subGraphs or { }) do
		for _, node in ipairs(subGraph.nodes or { }) do
			if node and node.id then clusterNodeIds[node.id] = true end
		end
	end
	local adjacency = { }
	for nodeId, node in pairs(allocated or { }) do
		if not clusterNodeIds[nodeId] and isMainTreeRouteNode(nodeId, node, spec) then
			adjacency[nodeId] = { }
		end
	end
	local edgeId = 0
	for nodeId, node in pairs(allocated or { }) do
		if adjacency[nodeId] then
			for _, linked in ipairs(node.linked or { }) do
				local linkedId = linked and linked.id
				if linkedId and linkedId > nodeId and adjacency[linkedId] then
					edgeId = edgeId + 1
					adjacency[nodeId][#adjacency[nodeId] + 1] = { id = edgeId, to = linkedId }
					adjacency[linkedId][#adjacency[linkedId] + 1] = { id = edgeId, to = nodeId }
				end
			end
		end
	end
	if not adjacency[originNodeId] then return 0 end

	local discovery, low, edgeStack = { }, { }, { }
	local clock, originCycleRank = 0, 0
	local function countBlock(stopEdgeId)
		local vertices, blockEdges = { }, 0
		repeat
			local edge = table.remove(edgeStack)
			if not edge then break end
			blockEdges = blockEdges + 1
			vertices[edge.first] = true
			vertices[edge.second] = true
			if edge.id == stopEdgeId then break end
		until false
		if vertices[originNodeId] then
			local vertexCount = 0
			for _ in pairs(vertices) do vertexCount = vertexCount + 1 end
			originCycleRank = originCycleRank + math.max(0, blockEdges - vertexCount + 1)
		end
	end
	local function visit(nodeId, parentEdgeId)
		clock = clock + 1
		discovery[nodeId], low[nodeId] = clock, clock
		for _, edge in ipairs(adjacency[nodeId]) do
			if not discovery[edge.to] then
				edge.first, edge.second = nodeId, edge.to
				edgeStack[#edgeStack + 1] = edge
				visit(edge.to, edge.id)
				low[nodeId] = math.min(low[nodeId], low[edge.to])
				if low[edge.to] >= discovery[nodeId] then countBlock(edge.id) end
			elseif edge.id ~= parentEdgeId and discovery[edge.to] < discovery[nodeId] then
				edge.first, edge.second = nodeId, edge.to
				edgeStack[#edgeStack + 1] = edge
				low[nodeId] = math.min(low[nodeId], discovery[edge.to])
			end
		end
	end
	visit(originNodeId, nil)
	return originCycleRank
end

-- PoB models radius-only passive access on the node itself and ties it to an
-- allocated, socketed jewel. Trust that native marker only after confirming
-- the provider socket/item and the exact native radius/keystone set again.
-- This keeps arbitrary disconnected allocations illegal while allowing
-- Intuitive Leap, Thread of Hope, and Impossible Escape candidates.
local function hasNativeRadiusProvider(spec, node)
	if not spec or not node then return false end
	for _, socket in ipairs(node.intuitiveLeapLikesAffecting or { }) do
		if socket and socket.alloc and spec.allocNodes[socket.id] then
			local itemId = spec.jewels and spec.jewels[socket.id]
			local item = itemId and itemId > 0 and spec.build and spec.build.itemsTab and spec.build.itemsTab.items[itemId]
			local jewelData = item and item.jewelData
			local radiusIndex = item and item.jewelRadiusIndex
			if jewelData and radiusIndex and not jewelData.limitDisabled then
				local inRadius = false
				if jewelData.intuitiveLeapLike and not (jewelData.intuitiveLeapKeystoneOnly and node.type ~= "Keystone") then
					local radius = socket.nodesInRadius and socket.nodesInRadius[radiusIndex]
					inRadius = radius and radius[node.id] or false
				end
				for keystoneName in pairs(jewelData.impossibleEscapeKeystones or { }) do
					local keystone = spec.tree and spec.tree.keystoneMap and spec.tree.keystoneMap[keystoneName]
					local radius = keystone and keystone.nodesInRadius and keystone.nodesInRadius[radiusIndex]
					if radius and radius[node.id] then inRadius = true break end
				end
				if inRadius then return true end
			end
		end
	end
	return false
end


function treeSearch.BuildRegionMap(spec, partition)
	if partition == "spatial" then
		return SpatialZones.Build(spec)
	end
	return buildRegionMap(spec)
end

function treeSearch.BuildVirtualParentSocketMap(spec)
	local parentSocketByNode = { }
	for _, subGraph in pairs(spec and spec.subGraphs or { }) do
		local parentSocket = subGraph.parentSocket
		if parentSocket and parentSocket.id then
			for _, node in ipairs(subGraph.nodes or { }) do
				if node and node.id then parentSocketByNode[node.id] = parentSocket.id end
			end
		end
	end
	return parentSocketByNode
end

-- Native cluster jewels add virtual node IDs that are intentionally absent
-- from the versioned base-tree region map. Inherit the containing cluster
-- socket's region for those nodes; spatial layouts prefer native coordinates
-- and fall back to the same parent socket when a virtual node has no position.
function treeSearch.ResolveNodeRegion(spec, nodeId, partition, regionByNode, metadata, parentSocketByNode)
	parentSocketByNode = parentSocketByNode or treeSearch.BuildVirtualParentSocketMap(spec)
	local visited = { }
	local function resolve(id)
		if visited[id] then return nil end
		visited[id] = true
		local parentId = parentSocketByNode[id]
		local node = spec and spec.nodes and spec.nodes[id]
		if partition == "spatial" and node then
			local region = SpatialZones.Classify(node.x, node.y, metadata)
			if region then return region end
		end
		if parentId then return resolve(parentId) end
		return regionByNode and regionByNode[id] or nil
	end
	return resolve(nodeId)
end

function treeSearch.ValidateCandidate(spec, nodeIds, inputs, regionByNode, removeNodeIds, candidateSpec, topologyMetadata, characterLevel)
	local branch = inputs.branch or { }
	local partition = branch.partition or "class"
	local partitionMetadata, regionError = topologyMetadata, nil
	if not regionByNode then regionByNode, partitionMetadata, regionError = treeSearch.BuildRegionMap(spec, partition) end
	if not regionByNode then return false, regionError or "Passive-tree regions could not be resolved" end
	local selectionSpec = candidateSpec or spec
	local virtualParents = treeSearch.BuildVirtualParentSocketMap(selectionSpec)
	local function candidateRegion(nodeId)
		return treeSearch.ResolveNodeRegion(selectionSpec, nodeId, partition, regionByNode, partitionMetadata, virtualParents)
	end
	local allocated = candidateSpec and candidateSpec.allocNodes or { }
	local removed = { }
	for _, nodeId in ipairs(removeNodeIds or { }) do removed[nodeId] = true end
	if not candidateSpec then
		for nodeId, node in pairs(spec.allocNodes or { }) do
			if node and not removed[nodeId] then allocated[nodeId] = node end
		end
		for _, nodeId in ipairs(nodeIds or { }) do
			allocated[nodeId] = spec.nodes[nodeId]
		end
	end

	local classStartIds, expectedClassStart = { }, selectionSpec.curClass and selectionSpec.curClass.startNodeId
	if not expectedClassStart and selectionSpec.tree and selectionSpec.tree.classes and selectionSpec.curClassId then
		expectedClassStart = selectionSpec.tree.classes[selectionSpec.curClassId] and selectionSpec.tree.classes[selectionSpec.curClassId].startNodeId
	end
	local selectedAscendStarts = { }
	for _, ascendClass in pairs({ selectionSpec.curAscendClass, selectionSpec.curSecondaryAscendClass }) do
		if ascendClass and ascendClass.startNodeId then selectedAscendStarts[ascendClass.startNodeId] = true end
	end
	local selectedClassStartCount = 0
	for nodeId, node in pairs(allocated) do
		if node and node.type == "ClassStart" then
			classStartIds[#classStartIds + 1] = nodeId
			if nodeId == expectedClassStart or not expectedClassStart then selectedClassStartCount = selectedClassStartCount + 1 end
		end
	end
	if #classStartIds ~= 1 or selectedClassStartCount ~= 1 then
		return false, "Candidate must contain exactly the selected class start node"
	end
	local selectedStartId = expectedClassStart or classStartIds[1]
	local baselineCycles = countOriginCycleRank(spec.allocNodes, spec, selectedStartId)
	local candidateCycles = countOriginCycleRank(allocated, selectionSpec, selectedStartId)
	if candidateCycles > baselineCycles then
		return false, string.format(
			"One-way routing policy forbids new cycles returning to class start %s: candidate adds %d origin cycle(s) (baseline %d, candidate %d)",
			tostring(selectedStartId),
			candidateCycles - baselineCycles, baselineCycles, candidateCycles
		)
	end
	for nodeId, node in pairs(allocated) do
		if node and node.type == "AscendClassStart" and not selectedAscendStarts[nodeId] then
			return false, "Candidate contains an ascendancy start that is not selected in PoB"
		end
		if candidateSpec and node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
			and node.connectedToStart == false and not hasNativeRadiusProvider(selectionSpec, node) then
			return false, "Candidate contains a passive disconnected from every selected PoB start: " .. tostring(nodeId)
		end
	end
	local selectedAscendancies, mainAscendancyPoints, secondaryAscendancyPoints = { }, 0, 0
	local function addSelectedAscendancy(ascendClass)
		if not ascendClass then return end
		-- Regular ascendancies normally use the same id and display name. Bloodline
		-- nodes store the compact id (e.g. "Delirious"), while their selector
		-- displays the longer name (e.g. "Delirious Bloodline"). Accept both
		-- native fields so the solver follows the same selected roots as PoB.
		if ascendClass.id then selectedAscendancies[ascendClass.id] = true end
		if ascendClass.name then selectedAscendancies[ascendClass.name] = true end
		if ascendClass.internalId then selectedAscendancies[ascendClass.internalId] = true end
	end
	addSelectedAscendancy(selectionSpec.curAscendClass)
	addSelectedAscendancy(selectionSpec.curSecondaryAscendClass)
	for _, node in pairs(allocated) do
		-- Ascendancy start nodes identify the selected subclass but do not spend
		-- one of its eight passive points. PoB includes their ascendancyName, so
		-- counting every named node would reject a legal eight-point tree as nine.
		if node and node.type ~= "AscendClassStart" and node.ascendancyName and not node.isMultipleChoiceOption then
			if not selectedAscendancies[node.ascendancyName] then
				return false, "Candidate allocates an ascendancy node that is not selected in PoB: " .. tostring(node.ascendancyName)
			end
			if selectionSpec.tree.secondaryAscendNameMap and selectionSpec.tree.secondaryAscendNameMap[node.ascendancyName] then
				secondaryAscendancyPoints = secondaryAscendancyPoints + 1
			else
				mainAscendancyPoints = mainAscendancyPoints + 1
			end
		end
	end
	if mainAscendancyPoints > 8 or secondaryAscendancyPoints > 8 then
		return false, "Candidate exceeds PoB's eight-point limit for a selected ascendancy"
	end
	local search = inputs.search or { }
	local levelForBudget = tonumber(characterLevel or search.activeCharacterLevel) or 100
	local availableBudget = Inputs.AscendancyPointBudgetAtLevel(levelForBudget, search.ascendancyPointBudget)
	if mainAscendancyPoints > availableBudget then
		return false, string.format("Candidate uses %d primary ascendancy points, above the level %d progression ceiling of %d", mainAscendancyPoints, levelForBudget, availableBudget), {
			key = "ascendancy_point_budget",
			label = "Primary ascendancy points available",
			actual = mainAscendancyPoints,
			required = availableBudget,
			operator = "<=",
			reason = "Above the conservative level-based Labyrinth progression ceiling; lower the configured cap if fewer Labyrinths are complete",
		}
	end
	if secondaryAscendancyPoints > availableBudget then
		return false, string.format("Candidate uses %d secondary ascendancy points, above the level %d progression ceiling of %d", secondaryAscendancyPoints, levelForBudget, availableBudget), {
			key = "secondary_ascendancy_point_budget",
			label = "Secondary ascendancy points available",
			actual = secondaryAscendancyPoints,
			required = availableBudget,
			operator = "<=",
			reason = "Above the conservative level-based Labyrinth progression ceiling; lower the configured cap if fewer Labyrinths are complete",
		}
	end

	local forbidden, allowed = regionSet(branch.forbidden), regionSet(branch.allowed)
	if partition == "spatial" and next(allowed) and not forbidden.hub then
		-- The central hub remains normal, point-costed transit for a selected
		-- spatial zone. It is never a free link or an additional class origin.
		allowed.hub = true
	end
	local requiredNodes, forbiddenNodes = idSet(inputs.search and inputs.search.requiredNodeIds), idSet(inputs.search and inputs.search.forbiddenNodeIds)
	for _, nodeId in ipairs(nodeIds or { }) do
		if not allocated[nodeId] then
			return false, "Requested passive addition is not connected or was rejected by the PoB tree: " .. tostring(nodeId)
		end
	end
	for _, nodeId in ipairs(inputs.targetNodeIds or { }) do
		if not allocated[nodeId] then
			return false, "Candidate omits the requested target passive node " .. tostring(nodeId)
		end
	end
	for _, nodeId in ipairs((inputs.search and inputs.search.addNodeIds) or { }) do
		if not allocated[nodeId] then
			return false, "Requested passive addition is not connected or was rejected by the PoB tree: " .. tostring(nodeId)
		end
	end
	for nodeId in pairs(requiredNodes) do
		if not allocated[nodeId] then return false, "Candidate omits required passive node " .. tostring(nodeId) end
	end
	for nodeId in pairs(forbiddenNodes) do
		if allocated[nodeId] then return false, "Candidate allocates forbidden passive node " .. tostring(nodeId) end
	end
	for _, nodeId in ipairs((inputs.search and inputs.search.removeNodeIds) or { }) do
		if allocated[nodeId] then return false, "Candidate retains explicitly removed passive node " .. tostring(nodeId) end
	end

	local allRegions = { }
	for id, node in pairs(allocated) do
		if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not node.ascendancyName then
			local regionName = candidateRegion(id)
			if not regionName then
				if next(forbidden) or next(allowed) or #(branch.required or { }) > 0 then
					return false, "Could not resolve the passive-tree region for allocated node " .. tostring(id)
				end
			else
				local region = lower(regionName)
				allRegions[region] = true
				if forbidden[region] then
					return false, "Candidate retains an allocation in forbidden region " .. tostring(regionName)
				end
				if next(allowed) and not allowed[region] then
					return false, "Candidate retains an allocation outside the allowed branch at " .. tostring(regionName)
				end
			end
		end
	end
	for _, required in ipairs(branch.required or { }) do
		if not allRegions[lower(required)] then
			return false, "Candidate does not pass through required region " .. required
		end
	end
	return true
end

function treeSearch.BuildRemovalCandidates(spec, inputs, limit, regionByNode)
	local candidates = { }
	if limit <= 0 then return candidates end
	local partition = inputs.branch and inputs.branch.partition or "class"
	local partitionMetadata, regionError
	if not regionByNode then regionByNode, partitionMetadata, regionError = treeSearch.BuildRegionMap(spec, partition) end
	if not regionByNode then return candidates, regionError or "Passive-tree regions could not be resolved" end
	local required, forbiddenNodes = { }, { }
	for _, id in ipairs(inputs.search and inputs.search.requiredNodeIds or { }) do required[id] = true end
	for _, id in ipairs(inputs.search and inputs.search.forbiddenNodeIds or { }) do forbiddenNodes[id] = true end
	local forbidden, allowed = regionSet(inputs.branch.forbidden), regionSet(inputs.branch.allowed)
	if partition == "spatial" and next(allowed) and not forbidden.hub then allowed.hub = true end
	local requested = inputs.search and inputs.search.removeNodeIds or { }
	local function addRemoval(ids, label, priority)
		if #candidates >= limit then return end
		local seen, unique = { }, { }
		for _, id in ipairs(ids) do
			local node = spec.allocNodes[id]
			if node and not seen[id] and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not required[id] then
				seen[id] = true
				unique[#unique + 1] = id
			end
		end
		if #unique > 0 then
			t_sort(unique)
			candidates[#candidates + 1] = { nodeIds = { }, removeNodeIds = unique, label = label, removalPriority = priority or 0 }
		end
	end
	addRemoval(requested, "Requested passive removal", -2)
	local invalidBranch = { }
	for id, node in pairs(spec.allocNodes or { }) do
		if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			local region = lower(regionByNode[id])
			if forbidden[region] or (next(allowed) and not allowed[region]) or forbiddenNodes[id] then
				invalidBranch[#invalidBranch + 1] = id
			end
		end
	end
	if #invalidBranch > 1 then addRemoval(invalidBranch, "Remove allocations outside selected branch filters", -1) end
	local nodes = { }
	for id, node in pairs(spec.allocNodes or { }) do
		if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not required[id] then
			local region = lower(regionByNode[id])
			local blocked = forbidden[region] or forbiddenNodes[id] or (next(allowed) and not allowed[region])
			local priority = blocked and 0 or 1
			nodes[#nodes + 1] = { id = id, node = node, priority = priority, degree = #(node.depends or { }) }
		end
	end
	t_sort(nodes, function(a, b)
		if a.priority ~= b.priority then return a.priority < b.priority end
		if a.degree ~= b.degree then return a.degree < b.degree end
		return a.id < b.id
	end)
	local pointCap = inputs.search and inputs.search.maxTotalPoints
	if type(pointCap) == "number" and spec.CountAllocNodes then
		local pointsUsed = spec:CountAllocNodes()
		local pointsToTrim = math.max(0, pointsUsed - pointCap)
		if pointsToTrim > 0 then
			local trimIds = { }
			for _, entry in ipairs(nodes) do
				if not entry.node.ascendancyName and not entry.node.isMultipleChoiceOption then
					trimIds[#trimIds + 1] = entry.id
					if #trimIds >= pointsToTrim then break end
				end
			end
			if #trimIds > 0 then
				addRemoval(trimIds, string.format("Remove %d passive points to meet the strict cap", pointsToTrim), -0.5)
			end
		end
	end
	local seen = { }
	for _, candidate in ipairs(candidates) do for _, id in ipairs(candidate.removeNodeIds) do seen[id] = true end end
	for _, entry in ipairs(nodes) do
		if #candidates >= limit then break end
		if not seen[entry.id] then addRemoval({ entry.id }, "Remove " .. tostring(entry.node.dn or entry.node.name or entry.id), entry.priority) end
	end
	return candidates
end

-- Keep generated passive routes inside PoB's current level/quest point ceiling.
-- A full source tree needs a connected set of low-value leaf removals paired
-- with additions; otherwise every useful route is structurally rejected before
-- the exact calculator can score it.
function treeSearch.BudgetCandidatesForPointLimit(spec, candidates, inputs, pointLimit, regionByNode)
	inputs = inputs or { }
	local output = { }
	local coverage = {
		inputCandidates = #(candidates or { }), outputCandidates = 0,
		adjustedCandidates = 0, rejectedInsufficientRemovals = 0,
		requiredPointsFreed = 0,
	}
	if type(spec) ~= "table" or type(spec.allocNodes) ~= "table" or type(spec.nodes) ~= "table"
		or type(spec.CountAllocNodes) ~= "function" or not isFinite(tonumber(pointLimit)) then
		for _, candidate in ipairs(candidates or { }) do output[#output + 1] = candidate end
		coverage.outputCandidates = #output
		coverage.status = "unsupported_context"
		return output, coverage
	end
	pointLimit = math.max(0, math.floor(tonumber(pointLimit)))
	local active, adjacency = { }, { }
	for rawId, node in pairs(spec.allocNodes) do
		local nodeId = tonumber(rawId)
		if nodeId and node and node.type ~= "AscendClassStart" and not node.ascendancyName then active[nodeId] = node end
	end
	for rawId, node in pairs(spec.nodes) do
		local nodeId = tonumber(rawId)
		if nodeId and node then
			adjacency[nodeId] = adjacency[nodeId] or { }
			for _, field in ipairs({ "linked", "out", "connections" }) do
				for key, value in pairs(node[field] or { }) do
					local otherId = type(value) == "table" and tonumber(value.id) or tonumber(value) or tonumber(key)
					if otherId and otherId > 0 and otherId == math.floor(otherId) then
						adjacency[nodeId][otherId] = true
						adjacency[otherId] = adjacency[otherId] or { }
						adjacency[otherId][nodeId] = true
					end
				end
			end
		end
	end
	local currentCount = select(1, spec:CountAllocNodes()) or 0
	local search = inputs and inputs.search or { }
	local branch = inputs and inputs.branch or { }
	local requiredRegions = regionSet(branch.required)
	local forbiddenRegions = regionSet(branch.forbidden)
	local allowedRegions = regionSet(branch.allowed)
	for _, candidate in ipairs(candidates or { }) do
		local existingRemovals, removalSet = { }, { }
		local removedCount, addedCount = 0, 0
		for _, rawId in ipairs(candidate.removeNodeIds or { }) do
			local nodeId = tonumber(rawId)
			local node = nodeId and active[nodeId]
			if node and not removalSet[nodeId] then
				removalSet[nodeId] = true
				existingRemovals[#existingRemovals + 1] = nodeId
				if node.type ~= "AscendClassStart" and not node.ascendancyName then removedCount = removedCount + 1 end
			end
		end
		local addedSet = { }
		for _, rawId in ipairs(candidate.nodeIds or { }) do
			local nodeId = tonumber(rawId)
			local node = nodeId and (spec.nodes[nodeId] or spec.nodes[tostring(nodeId)])
			if nodeId and node and not active[nodeId] and not addedSet[nodeId]
				and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not node.ascendancyName then
				addedSet[nodeId] = true
				addedCount = addedCount + 1
			end
		end
		local pointsToFree = math.max(0, currentCount - removedCount + addedCount - pointLimit)
		if pointsToFree == 0 then
			output[#output + 1] = candidate
		else
			local working, protected = { }, { }
			for nodeId in pairs(active) do if not removalSet[nodeId] then working[nodeId] = true end end
			for _, key in ipairs({ "requiredNodeIds", "addNodeIds", "targetNodeIds" }) do
				for _, rawId in ipairs(search[key] or inputs and inputs[key] or { }) do
					local nodeId = tonumber(rawId)
					if nodeId then protected[nodeId] = true end
				end
			end
			for _, rawId in ipairs(candidate.targetIds or { candidate.targetId }) do
				local nodeId = tonumber(rawId)
				if nodeId then protected[nodeId] = true end
			end
			for addedId in pairs(addedSet) do
				for activeId in pairs(adjacency[addedId] or { }) do
					if active[activeId] then protected[activeId] = true end
				end
			end
		for nodeId in pairs(active) do
				local region = lower(regionByNode and regionByNode[nodeId])
				if requiredRegions[region] then protected[nodeId] = true end
			end
			for nodeId, itemId in pairs(spec.jewels or { }) do
				if tonumber(itemId) and tonumber(itemId) > 0 then protected[tonumber(nodeId)] = true end
			end
			local selected = { }
			for _ = 1, pointsToFree do
				local leaves = { }
				for nodeId in pairs(working) do
					local node = active[nodeId]
					local removable = node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
						and node.type ~= "Mastery" and node.type ~= "Socket" and not node.ascendancyName
						and not node.isMultipleChoiceOption and not node.isProxy and not protected[nodeId]
					if removable then
						local degree = 0
						for neighborId in pairs(adjacency[nodeId] or { }) do if working[neighborId] then degree = degree + 1 end end
						if degree <= 1 then
							local region = lower(regionByNode and regionByNode[nodeId])
						local outsideBranch = forbiddenRegions[region] or (next(allowedRegions) and not allowedRegions[region])
						leaves[#leaves + 1] = { id = nodeId, node = node, priority = outsideBranch and 0 or 1 }
						end
					end
				end
				t_sort(leaves, function(left, right)
					if left.priority ~= right.priority then return left.priority < right.priority end
					local leftType = left.node.type == "Keystone" and 3 or left.node.type == "Notable" and 2 or 1
					local rightType = right.node.type == "Keystone" and 3 or right.node.type == "Notable" and 2 or 1
					if leftType ~= rightType then return leftType < rightType end
					local leftEvidence = importedNodeEvidencePriority(left.node, inputs)
					local rightEvidence = importedNodeEvidencePriority(right.node, inputs)
					if leftEvidence ~= rightEvidence then return leftEvidence < rightEvidence end
					local leftPreference = nodePotentialPreferenceScore(left.node, inputs)
					local rightPreference = nodePotentialPreferenceScore(right.node, inputs)
					if leftPreference ~= rightPreference then return leftPreference < rightPreference end
					return left.id < right.id
				end)
				if #leaves == 0 then break end
				local chosen = leaves[1].id
				working[chosen] = nil
				selected[#selected + 1] = chosen
			end
			if #selected < pointsToFree then
				coverage.rejectedInsufficientRemovals = coverage.rejectedInsufficientRemovals + 1
				coverage.lastRejection = {
					label = tostring(candidate.label or "Passive candidate"):sub(1, 120),
					pointsToFree = pointsToFree, removableLeaves = #selected,
				}
			else
				local budgeted = { }
				for key, value in pairs(candidate) do budgeted[key] = value end
				budgeted.removeNodeIds = existingRemovals
				for _, nodeId in ipairs(selected) do
					budgeted.removeNodeIds[#budgeted.removeNodeIds + 1] = nodeId
					removalSet[nodeId] = true
				end
				budgeted.pointBudgetReplacements = pointsToFree
				budgeted.pointBudgetLimit = pointLimit
				budgeted.label = tostring(candidate.label or "Passive route")
					.. string.format("; replace %d leaf point%s", pointsToFree, pointsToFree == 1 and "" or "s")
				output[#output + 1] = budgeted
				coverage.adjustedCandidates = coverage.adjustedCandidates + 1
				coverage.requiredPointsFreed = coverage.requiredPointsFreed + pointsToFree
			end
		end
	end
	coverage.outputCandidates = #output
	coverage.status = coverage.rejectedInsufficientRemovals > 0 and "partial" or "ready"
	return output, coverage
end

function treeSearch.CombineAddRemoveCandidates(additions, removals, limit, maxAddedPoints)
	local combined = { }
	if limit <= 0 then return combined end
	for _, addition in ipairs(additions or { }) do
		for _, removal in ipairs(removals or { }) do
			if #addition.nodeIds <= maxAddedPoints then
				local removeSet, valid = { }, true
				for _, id in ipairs(removal.removeNodeIds or { }) do removeSet[id] = true end
				for _, id in ipairs(addition.nodeIds or { }) do if removeSet[id] then valid = false break end end
				if valid then
					local removeIds = { }
					for _, id in ipairs(removal.removeNodeIds or { }) do removeIds[#removeIds + 1] = id end
					combined[#combined + 1] = {
						nodeIds = { unpack(addition.nodeIds or { }) },
						removeNodeIds = removeIds,
						label = (addition.label or "Add passive route") .. " + " .. (removal.label or "Remove passive route"),
						island = addition.island,
					}
					if #combined >= limit then return combined end
				end
			end
		end
	end
	return combined
end

local function isOptimizerRadiusJewel(item)
	return item and item.type == "Jewel" and item.jewelRadiusIndex and item.jewelData
		and not item.jewelData.clusterJewelValid
end

local function radiusAllocatableNodes(spec, socket, item)
	local result, seen = { }, { }
	local radiusIndex = item and item.jewelRadiusIndex
	local jewelData = item and item.jewelData
	if not radiusIndex or not jewelData then return result end
	local function addNodes(nodes, keystoneOnly)
		for nodeId in pairs(nodes or { }) do
			local node = spec.nodes[nodeId]
			if node and not node.alloc and not seen[nodeId]
				and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and node.type ~= "Mastery" and node.type ~= "Socket"
				and not node.ascendancyName and not node.isProxy and not node.isMultipleChoiceOption and not node.isTattoo
				and (not keystoneOnly or node.type == "Keystone") then
				seen[nodeId] = true
				result[#result + 1] = node
			end
		end
	end
	if jewelData.intuitiveLeapLike and socket and socket.nodesInRadius then
		addNodes(socket.nodesInRadius[radiusIndex], jewelData.intuitiveLeapKeystoneOnly)
	end
	for keystoneName in pairs(jewelData.impossibleEscapeKeystones or { }) do
		local keystone = spec.tree and spec.tree.keystoneMap and spec.tree.keystoneMap[keystoneName]
		if keystone and keystone.nodesInRadius then addNodes(keystone.nodesInRadius[radiusIndex]) end
	end
	t_sort(result, function(a, b)
			local priorityA = a.type == "Keystone" and 1 or a.type == "Notable" and 2 or 3
			local priorityB = b.type == "Keystone" and 1 or b.type == "Notable" and 2 or 3
			if priorityA ~= priorityB then return priorityA < priorityB end
			return a.id < b.id
		end)
	return result
end

local function sampleIndex(sample, sampleCount, totalCount, offset)
	if totalCount <= 1 then return 1 end
	return ((offset + math.floor((sample - 1) * totalCount / sampleCount)) % totalCount) + 1
end

local function combineRadiusPlacementCandidates(placements, limit, maxAddedPoints)
	local combined, targetCandidates, targetIds = { }, { }, { }
	if limit <= 0 then return combined end
	for index, candidate in ipairs(placements or { }) do
		local variant = candidate.jewelVariant
		if variant and variant.sourceKind == "inventory" and not variant.fromNodeId
			and type(variant.itemId) == "number" and type(variant.toNodeId) == "number"
			and #(candidate.nodeIds or { }) == 1 then
			local targetId = candidate.nodeIds[1]
			if not targetCandidates[targetId] then
				targetCandidates[targetId] = { }
				targetIds[#targetIds + 1] = targetId
			end
			targetCandidates[targetId][#targetCandidates[targetId] + 1] = index
		end
	end
	t_sort(targetIds)
	local seen = { }
	local function addCombined(first, second, overlapping)
		local firstVariant, secondVariant = first.jewelVariant, second.jewelVariant
		if firstVariant.itemId == secondVariant.itemId or firstVariant.toNodeId == secondVariant.toNodeId then return end
		local nodeIds, nodeSet = { }, { }
		for _, source in ipairs({ first.nodeIds or { }, second.nodeIds or { } }) do
			for _, nodeId in ipairs(source) do
				if not nodeSet[nodeId] then
					nodeSet[nodeId] = true
					nodeIds[#nodeIds + 1] = nodeId
				end
			end
		end
		if #nodeIds == 0 or #nodeIds > maxAddedPoints then return end
		local forwardKey = table.concat({
			tostring(firstVariant.itemId), tostring(firstVariant.toNodeId), tostring(first.nodeIds[1] or 0),
			tostring(secondVariant.itemId), tostring(secondVariant.toNodeId), tostring(second.nodeIds[1] or 0),
		}, ":")
		local reverseKey = table.concat({
			tostring(secondVariant.itemId), tostring(secondVariant.toNodeId), tostring(second.nodeIds[1] or 0),
			tostring(firstVariant.itemId), tostring(firstVariant.toNodeId), tostring(first.nodeIds[1] or 0),
		}, ":")
		local key = forwardKey < reverseKey and forwardKey or reverseKey
		if seen[key] then return end
		seen[key] = true
		combined[#combined + 1] = {
			nodeIds = nodeIds,
			jewelVariants = { firstVariant, secondVariant },
			label = tostring(first.label or "Radius jewel") .. " + " .. tostring(second.label or "Radius jewel"),
			jewelCombination = overlapping and "overlapping_radius_providers" or "paired_radius_providers",
		}
	end
	-- Prefer interactions where two independent native jewel radii grant the
	-- same disconnected passive. This explicitly exercises overlap semantics
	-- while keeping candidate generation bounded and deterministic.
	local overlapScans, overlapScanLimit = 0, math.min(8192, #placements * (#placements - 1) / 2)
	local overlapScanLimitReached = false
	for _, targetId in ipairs(targetIds) do
		local indexes = targetCandidates[targetId]
		for left = 1, #indexes do
			for right = left + 1, #indexes do
				overlapScans = overlapScans + 1
				if overlapScans > overlapScanLimit then overlapScanLimitReached = true break end
				addCombined(placements[indexes[left]], placements[indexes[right]], true)
				if #combined >= limit then return combined end
			end
			if overlapScanLimitReached then break end
		end
		if overlapScanLimitReached then break end
	end
	-- Fill any remaining quota with distinct-target pairs, still using a bounded
	-- scan so large inventories cannot turn candidate setup into an O(n^2) hang.
	local scans, scanLimit = 0, math.min(8192, #placements * (#placements - 1) / 2)
	for left = 1, #placements do
		for right = left + 1, #placements do
			scans = scans + 1
			if scans > scanLimit then return combined end
			local first, second = placements[left], placements[right]
			if first.nodeIds[1] ~= second.nodeIds[1] then
				addCombined(first, second, false)
				if #combined >= limit then return combined end
			end
		end
	end
	return combined
end

function treeSearch.BuildJewelCandidates(spec, limit, maxAddedPoints, seed)
	local sockets, moveCandidates, placementCandidates = { }, { }, { }
	if limit <= 0 then return { } end
	maxAddedPoints = math.max(0, tonumber(maxAddedPoints) or 0)
	for id, node in pairs(spec.allocNodes or { }) do
		if node.type == "Socket" then sockets[#sockets + 1] = id end
	end
	t_sort(sockets)
	for _, fromId in ipairs(sockets) do
		local itemId = spec.jewels[fromId]
		local fromItem = itemId and spec.build.itemsTab.items[itemId]
		local fromIsCluster = fromItem and fromItem.jewelData and fromItem.jewelData.clusterJewelValid
		if itemId and itemId > 0 and not fromIsCluster then
			for _, toId in ipairs(sockets) do
				if toId ~= fromId then
					local targetItemId = spec.jewels[toId] or 0
					local targetItem = targetItemId > 0 and spec.build.itemsTab.items[targetItemId]
					local targetIsCluster = targetItem and targetItem.jewelData and targetItem.jewelData.clusterJewelValid
					if not targetIsCluster and not (targetItemId > 0 and fromId > toId) then
						moveCandidates[#moveCandidates + 1] = {
							nodeIds = { },
							jewelVariant = { fromNodeId = fromId, toNodeId = toId, itemId = itemId, targetItemId = targetItemId },
							label = "Jewel socket " .. tostring(fromId) .. " → " .. tostring(toId),
						}
					end
				end
			end
		end
	end

	local usedItems, inventoryJewels = { }, { }
	for _, itemId in pairs(spec.jewels or { }) do if itemId and itemId > 0 then usedItems[itemId] = true end end
	for itemId, item in pairs(spec.build.itemsTab and spec.build.itemsTab.items or { }) do
		if type(itemId) == "number" and itemId > 0 and not usedItems[itemId] and isOptimizerRadiusJewel(item) then
			inventoryJewels[#inventoryJewels + 1] = { id = itemId, item = item }
		end
	end
	t_sort(inventoryJewels, function(a, b) return a.id < b.id end)

	local placementPairs = { }
	for _, jewel in ipairs(inventoryJewels) do
		for _, socketId in ipairs(sockets) do
			local socket = spec.allocNodes[socketId]
			local targetItemId = spec.jewels[socketId] or 0
			local targetItem = targetItemId > 0 and spec.build.itemsTab.items[targetItemId]
			local targetIsCluster = targetItem and targetItem.jewelData and targetItem.jewelData.clusterJewelValid
			if socket and socket.isJewelSocket and socket.nodesInRadius and not targetIsCluster then
				placementPairs[#placementPairs + 1] = {
					jewel = jewel,
					socket = socket,
					targetItemId = targetItemId,
					targets = radiusAllocatableNodes(spec, socket, jewel.item),
				}
			end
		end
	end
	local combinationLimit = #inventoryJewels > 1 and math.min(16, math.floor(limit / 4)) or 0
	local singleLimit = limit
	local placementLimit = #placementPairs > 0 and math.ceil(singleLimit / 2) or 0
	local moveLimit = singleLimit - placementLimit
	local sampledPlacementPairs = { }
	local sampleCount = math.min(placementLimit, #placementPairs)
	for index = 1, sampleCount do
		sampledPlacementPairs[index] = sampleIndex(index, sampleCount, #placementPairs, (tonumber(seed) or 0) % #placementPairs)
	end
	local targetPairIndexes, overlapTargetsByPair = { }, { }
	local overlapPairCount = math.min(#sampledPlacementPairs, 64)
	local overlapPairIndexes = { }
	for sampleIndexValue = 1, overlapPairCount do
		local sampledIndex = sampleIndex(sampleIndexValue, overlapPairCount, #sampledPlacementPairs, (tonumber(seed) or 0) % #sampledPlacementPairs)
		overlapPairIndexes[sampledPlacementPairs[sampledIndex]] = true
	end
	for pairIndex, pair in ipairs(placementPairs) do
		if overlapPairIndexes[pairIndex] then
			for _, target in ipairs(pair.targets) do
				local owners = targetPairIndexes[target.id]
				if not owners then owners = { }; targetPairIndexes[target.id] = owners end
				owners[#owners + 1] = pairIndex
			end
		end
	end
	for targetId, owners in pairs(targetPairIndexes) do
		local firstIndex = owners[1]
		local firstPair = firstIndex and placementPairs[firstIndex]
		for ownerIndex = 2, #owners do
			local secondIndex = owners[ownerIndex]
			local secondPair = placementPairs[secondIndex]
			if firstPair and firstPair.jewel.id ~= secondPair.jewel.id and firstPair.socket.id ~= secondPair.socket.id then
				overlapTargetsByPair[firstIndex] = overlapTargetsByPair[firstIndex] or { }
				overlapTargetsByPair[secondIndex] = overlapTargetsByPair[secondIndex] or { }
				overlapTargetsByPair[firstIndex][targetId] = true
				overlapTargetsByPair[secondIndex][targetId] = true
				break
			end
		end
	end

	-- Reserve part of the bounded jewel quota for new radius-jewel placements,
	-- while preserving some opportunities to move already installed jewels.
	for index = 1, math.min(moveLimit, #moveCandidates) do moveCandidates[index].jewelCoverage = "installed_move" end
	for index = 1, sampleCount do
		local pairIndex = sampledPlacementPairs[index]
		local pair = placementPairs[pairIndex]
		local quota = math.floor(placementLimit / math.min(placementLimit, #placementPairs))
		if index <= placementLimit % math.min(placementLimit, #placementPairs) then quota = quota + 1 end
		local targetIds = pair.targets
		local baseVariant = {
			toNodeId = pair.socket.id,
			itemId = pair.jewel.id,
			targetItemId = pair.targetItemId,
			sourceKind = "inventory",
		}
		if #targetIds > 0 and maxAddedPoints > 0 then
			local itemHasRadiusStats = not pair.jewel.item.jewelData.intuitiveLeapLike
				and not next(pair.jewel.item.jewelData.impossibleEscapeKeystones or { })
			local includePlacementOnly = itemHasRadiusStats and quota > 1
			if includePlacementOnly then
				placementCandidates[#placementCandidates + 1] = {
					nodeIds = { }, jewelVariant = baseVariant,
					label = tostring(pair.jewel.item.name or "Radius jewel") .. " in socket " .. tostring(pair.socket.id),
				}
			end
			local targetQuota = math.max(1, quota - (includePlacementOnly and 1 or 0))
			local take = math.min(targetQuota, #targetIds)
			local offset = (tonumber(seed) or 0) % #targetIds
			local prioritized, remaining = { }, { }
			for _, target in ipairs(targetIds) do
				if overlapTargetsByPair[pairIndex] and overlapTargetsByPair[pairIndex][target.id] then
					prioritized[#prioritized + 1] = target
				else
					remaining[#remaining + 1] = target
				end
			end
			local selectedTargets, selectedTargetIds = { }, { }
			local overlapTake = math.min(take, #prioritized)
			for targetIndex = 1, overlapTake do
				local target = prioritized[sampleIndex(targetIndex, overlapTake, #prioritized, offset)]
				selectedTargets[#selectedTargets + 1] = target
				selectedTargetIds[target.id] = true
			end
			local remainingTake = math.min(take - #selectedTargets, #remaining)
			for targetIndex = 1, remainingTake do
				local target = remaining[sampleIndex(targetIndex, remainingTake, #remaining, offset)]
				if not selectedTargetIds[target.id] then
					selectedTargets[#selectedTargets + 1] = target
					selectedTargetIds[target.id] = true
				end
			end
			for _, target in ipairs(selectedTargets) do
				placementCandidates[#placementCandidates + 1] = {
					nodeIds = { target.id },
					jewelVariant = {
						toNodeId = pair.socket.id,
						itemId = pair.jewel.id,
						targetItemId = pair.targetItemId,
						sourceKind = "inventory",
					},
					label = tostring(pair.jewel.item.name or "Radius jewel") .. " in socket " .. tostring(pair.socket.id) .. " + " .. tostring(target.dn or target.name or target.id),
				}
			end
		elseif quota > 0 then
			placementCandidates[#placementCandidates + 1] = {
				nodeIds = { }, jewelVariant = baseVariant,
				label = tostring(pair.jewel.item.name or "Radius jewel") .. " in socket " .. tostring(pair.socket.id),
			}
		end
	end

	local singleCandidates = { }
	local moveIndex, placementIndex = 1, 1
	while #singleCandidates < singleLimit and (moveIndex <= math.min(moveLimit, #moveCandidates) or placementIndex <= #placementCandidates) do
		if placementIndex <= #placementCandidates and #singleCandidates < singleLimit then
			singleCandidates[#singleCandidates + 1] = placementCandidates[placementIndex]
			placementIndex = placementIndex + 1
		end
		if moveIndex <= math.min(moveLimit, #moveCandidates) and #singleCandidates < singleLimit then
			singleCandidates[#singleCandidates + 1] = moveCandidates[moveIndex]
			moveIndex = moveIndex + 1
		end
	end
	local candidates = combineRadiusPlacementCandidates(placementCandidates, combinationLimit, maxAddedPoints)
	for _, single in ipairs(singleCandidates) do
		if #candidates >= limit then break end
		candidates[#candidates + 1] = single
	end
	return candidates
end

function treeSearch.BuildTimelessCandidates(spec, limit)
	local candidates, jewels = { }, { }
	if limit <= 0 then return candidates end
	for nodeId, itemId in pairs(spec.jewels) do
		local item = spec.build.itemsTab.items[itemId]
		local conqueredBy = item and item.jewelData and item.jewelData.conqueredBy
		local typeId = conqueredBy and conqueredBy.conqueror and timelessTypeByConqueror[conqueredBy.conqueror.type]
		if typeId and type(conqueredBy.id) == "number" and spec.allocNodes[nodeId] then
			jewels[#jewels + 1] = { nodeId = nodeId, itemId = itemId, item = item, typeId = typeId, currentSeed = conqueredBy.id }
		end
	end
	t_sort(jewels, function(a, b) return a.nodeId < b.nodeId end)
	if #jewels == 0 then return candidates end
	local data = spec.build.data
	local perJewel = math.max(1, math.floor(limit / #jewels))
	for _, jewel in ipairs(jewels) do
		local seedMin = data.timelessJewelSeedMin[jewel.typeId]
		local seedMax = data.timelessJewelSeedMax[jewel.typeId]
		if seedMin and seedMax then
			local scale = jewel.typeId == 5 and 20 or 1 -- Elegant Hubris stores its seed in twentieths.
			for sample = 1, perJewel do
				local normalizedSeed = seedMin + math.floor((seedMax - seedMin) * sample / (perJewel + 1))
				local seed = normalizedSeed * scale
				if seed ~= jewel.currentSeed then
					candidates[#candidates + 1] = {
						nodeIds = { },
						timelessVariant = { nodeId = jewel.nodeId, itemId = jewel.itemId, seed = seed },
						label = (jewel.item.name or "Timeless Jewel") .. " seed " .. tostring(seed),
					}
					if #candidates >= limit then return candidates end
				end
			end
		end
	end
	return candidates
end

function treeSearch.BuildAnointCandidates(spec, limit)
	return Anoints.BuildCandidates(spec, limit)
end

function treeSearch.BuildMasteryCandidates(spec, limit)
	local candidates = { }
	if limit <= 0 then return candidates end
	for nodeId, selectedEffect in pairs(spec.masterySelections) do
		local node = spec.nodes[nodeId]
		for _, option in ipairs(node and node.masteryEffects or { }) do
			if option.effect ~= selectedEffect and spec.tree.masteryEffects[option.effect] then
				candidates[#candidates + 1] = {
					nodeIds = { },
					masteryVariant = { nodeId = nodeId, effectId = option.effect },
					label = (node.name or "Mastery") .. " mastery option",
				}
				if #candidates >= limit then return candidates end
			end
		end
	end
	return candidates
end

function treeSearch.BuildTattooCandidates(spec, limit)
	local candidates = { }
	if limit <= 0 then return candidates end
	local tattooCount = 0
	for _, override in pairs(spec.hashOverrides) do
		if override.isTattoo then tattooCount = tattooCount + 1 end
	end
	for nodeId, allocatedNode in pairs(spec.allocNodes) do
		local baseNode = spec.tree.nodes[nodeId]
		if baseNode and baseNode.type ~= "ClassStart" and baseNode.type ~= "AscendClassStart" then
			local nodeName = baseNode.dn or baseNode.name or ""
			local nodeValue = baseNode.sd and baseNode.sd[1] or ""
			local linkedCount = baseNode.linkedId and #baseNode.linkedId or 0
			for tattooId, tattoo in pairs(spec.tree.tattoo and spec.tree.tattoo.nodes or { }) do
				local targetType = tostring(tattoo.targetType or "")
				local targetTypePattern = targetType:gsub("^Small ", "")
				local matches = (targetTypePattern ~= "" and nodeName:match(targetTypePattern))
					or (tattoo.targetValue and tattoo.targetValue ~= "" and nodeValue:match(tattoo.targetValue))
					or (targetType == "Small Attribute" and (nodeName == "Intelligence" or nodeName == "Strength" or nodeName == "Dexterity"))
					or (targetType == "Keystone" and baseNode.type == "Keystone")
				local isLegacy = tattoo.legacy == true
				if matches and (tattoo.MinimumConnected or 0) <= linkedCount and not isLegacy and tattoo.dn ~= allocatedNode.dn then
					if tattooCount < 50 or allocatedNode.isTattoo then
						candidates[#candidates + 1] = {
							nodeIds = { },
							tattooVariant = { nodeId = nodeId, tattooId = tattooId },
							label = (tattoo.dn or "Tattoo") .. " on " .. nodeName,
						}
						if #candidates >= limit then return candidates end
					end
				end
			end
		end
	end
	return candidates
end

function treeSearch.BuildCandidateNodes(spec, inputs, limit, progressFunc, maxAddedPoints, control, suppliedRegionMap)
	if limit <= 0 then return { } end
	local partition = inputs.branch and inputs.branch.partition or "class"
	local regionByNode, partitionMetadata, regionError = suppliedRegionMap, nil, nil
	if not regionByNode then regionByNode, partitionMetadata, regionError = treeSearch.BuildRegionMap(spec, partition) end
	if not regionByNode then return { }, regionError or "Passive-tree regions could not be resolved" end
	local maxEdgeLength = findMaxEdgeLength(spec)
	local pointLimit = maxAddedPoints or inputs.search.maxAddedPoints
	local forbidden = regionSet(inputs.branch.forbidden)
	local allowed = regionSet(inputs.branch.allowed)
	if partition == "spatial" and next(allowed) and not forbidden.hub then allowed.hub = true end
	local blockedNodeIds = idSet(inputs.search and inputs.search.removeNodeIds)
	for nodeId in pairs(idSet(inputs.search and inputs.search.forbiddenNodeIds)) do blockedNodeIds[nodeId] = true end
	local seeds = { }
	for nodeId, node in pairs(spec.allocNodes) do
		-- Ascendancy paths are a separate eight-point graph. They may not act as
		-- shortcuts or seed nodes for routes in the main passive tree.
		if not blockedNodeIds[nodeId] and node.type ~= "AscendClassStart" and not node.ascendancyName then
			seeds[#seeds + 1] = node
		end
	end
	local addedForWaypoints, addedWaypointOrder = { }, { }
	local function appendRoute(route)
		for _, node in ipairs(route or { }) do
			if not spec.allocNodes[node.id] and not addedForWaypoints[node.id] then
				addedForWaypoints[node.id] = node
				addedWaypointOrder[#addedWaypointOrder + 1] = node.id
				seeds[#seeds + 1] = node
			end
		end
	end
	local required = inputs.branch.required or { }
	for index, regionName in ipairs(required) do
		if control and control.cancelled then return { }, nil, true end
		local remainingPoints = pointLimit - countSet(addedForWaypoints)
		if remainingPoints < 0 then
			return { }, "Required regions exceed the selected passive-point limit", false
		end
		local goals = { }
		for id, regionNameForNode in pairs(regionByNode) do
			local node = spec.nodes[id]
			if lower(regionNameForNode) == lower(regionName) and node
				and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and node.type ~= "Mastery"
				and not node.ascendancyName and not node.isProxy and not node.isMultipleChoiceOption then
				goals[id] = node
			end
		end
		local route, _, pathStatus = findPath(spec, seeds, goals, regionByNode, forbidden, allowed, blockedNodeIds, index, maxEdgeLength, control, progressFunc, 0, #required, remainingPoints, inputs)
		if pathStatus == "cancelled" then return { }, nil, true end
		if not route then
			return { }, "Required region is unreachable within the passive-point limit and selected branch filters: " .. regionName
		end
		appendRoute(route)
	end
	-- Explicitly requested additions and hard-required node IDs are mandatory
	-- waypoints. Route each through the same filtered A* graph used for ordinary
	-- targets, then include those connector nodes in every generated candidate.
	local mandatoryNodeIds, mandatorySeen = { }, { }
	for _, key in ipairs({ "addNodeIds", "requiredNodeIds" }) do
		for _, nodeId in ipairs(inputs.search and inputs.search[key] or { }) do
			if not mandatorySeen[nodeId] and not spec.allocNodes[nodeId] then
				mandatorySeen[nodeId] = true
				local node = spec.nodes[nodeId]
				local assignedToLockedAscendancy = inputs.search and inputs.search.ascendancyId ~= nil
					and node and node.ascendancyName
				if not assignedToLockedAscendancy then mandatoryNodeIds[#mandatoryNodeIds + 1] = nodeId end
			end
		end
	end
	t_sort(mandatoryNodeIds)
	for index, nodeId in ipairs(mandatoryNodeIds) do
		if control and control.cancelled then return { }, nil, true end
		local target = spec.nodes[nodeId]
		if not target then return { }, "Required passive node is unavailable: " .. tostring(nodeId) end
		local region = lower(regionByNode[nodeId])
		if forbidden[region] or (next(allowed) and not allowed[region]) then
			return { }, "Required passive node is outside the selected branch filters: " .. tostring(nodeId)
		end
		local route, pathStatus
		if hasNativeRadiusProvider(spec, target) then
			route = { target }
		else
			local ignored
			route, ignored, pathStatus = findPath(spec, seeds, { [nodeId] = target }, regionByNode, forbidden, allowed, blockedNodeIds,
				(inputs.search.seed + index * 65537) % 2147483647, maxEdgeLength, control, progressFunc, index, #mandatoryNodeIds,
				pointLimit - countSet(addedForWaypoints), inputs)
		end
		if pathStatus == "cancelled" then return { }, nil, true end
		if not route then return { }, "Required passive node is unreachable within the selected point budget: " .. tostring(nodeId) end
		appendRoute(route)
	end

	local targets = { }
	local requestedTargetId = inputs.targetNodeIds and inputs.targetNodeIds[1]
	if requestedTargetId then
		local target = spec.nodes[requestedTargetId]
		if not target then return { }, "Target node is unavailable in the active passive spec: " .. tostring(requestedTargetId) end
		local region = lower(regionByNode[requestedTargetId])
		if target.ascendancyName then return { }, "Direct target routing is limited to the main passive tree; ascendancy points need an allocated ascendancy path" end
		if forbidden[region] or (next(allowed) and not allowed[region]) then
			return { }, "Target node is outside the allowed branch filters: " .. tostring(requestedTargetId)
		end
		if not target.alloc and not addedForWaypoints[requestedTargetId] then targets[1] = target end
	else
		for id, node in pairs(spec.nodes) do
			local region = lower(regionByNode[id])
			local inAllowed = not next(allowed) or allowed[region]
			if not node.alloc and not addedForWaypoints[id] and not blockedNodeIds[id] and inAllowed and not forbidden[region]
				and not node.ascendancyName and not node.isProxy and not node.isMultipleChoiceOption
				and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and node.type ~= "Mastery"
				and node.type ~= "Socket" and not node.isTattoo then
				targets[#targets + 1] = node
			end
		end
	end
	t_sort(targets, function(a, b)
		local priorityA = a.type == "Keystone" and 1 or a.type == "Notable" and 2 or 3
		local priorityB = b.type == "Keystone" and 1 or b.type == "Notable" and 2 or 3
		if priorityA ~= priorityB then return priorityA < priorityB end
		return a.id < b.id
	end)
	-- Region round-robin is useful even when no explicit damage/defence focus is
	-- set: small route pools must not inherit a bias from passive node IDs. The
	-- preference scores only order proposals; PoB remains the metric and gate.
	if inputs.search then
		targets = prioritizeNodePotentialTargets(targets, regionByNode, inputs)
	end

	local candidates, seenCandidates = { }, { }
	if next(addedForWaypoints) then
		local nodeIds = { unpack(addedWaypointOrder) }
		local routeKey = canonicalNodeKey(nodeIds)
		seenCandidates[routeKey] = true
		candidates[1] = { nodeIds = nodeIds, isRequiredPath = true, label = "Required passive path", island = 1 }
		if #candidates >= limit then return candidates end
	end
	local remainingRoutePoints = pointLimit - countSet(addedForWaypoints)
	local useSharedPathFields = not requestedTargetId and #targets >= 128 and limit >= 128
	-- Interleave route islands by target. Target-major iteration filled small
	-- exact-evaluation budgets with four tie variants of the first notable,
	-- starving other branches and making later multi-route combinations narrow.
	-- Island-major iteration exposes distinct goals before alternate connectors.
	for island = 1, 4 do
		local sharedField
		if useSharedPathFields then
			if control and control.cancelled then return { }, nil, true end
			local fieldTieSeed = (inputs.search.seed + island * 104729) % 2147483647
			local function fieldProgress(expanded)
				if progressFunc then
					progressFunc((island - 1) * #targets, #targets * 4, expanded)
				end
			end
			local pathStatus
			sharedField, pathStatus = buildPathField(spec, seeds, regionByNode, forbidden, allowed,
				blockedNodeIds, fieldTieSeed, remainingRoutePoints, inputs, control, fieldProgress)
			if pathStatus == "cancelled" then return { }, nil, true end
		end
		for index, target in ipairs(targets) do
			if control and control.cancelled then return { }, nil, true end
			local processed = (island - 1) * #targets + index
			if progressFunc and processed % 8 == 0 then progressFunc(processed, #targets * 4, 0, target.id) end
			if #candidates >= limit then return candidates end
			local route, pathStatus
			if hasNativeRadiusProvider(spec, target) then
				route = { target }
			elseif sharedField then
				route = routeFromPathField(spec, sharedField, target.id)
			else
				local goals = { [target.id] = target }
				-- Explicit target routing and small route pools retain target-specific A*.
				local tieSeed = (inputs.search.seed + index * 7919 + island * 104729) % 2147483647
				local ignored
				route, ignored, pathStatus = findPath(spec, seeds, goals, regionByNode, forbidden, allowed, blockedNodeIds, tieSeed, maxEdgeLength, control, progressFunc, processed, #targets * 4, remainingRoutePoints, inputs)
			end
			if pathStatus == "cancelled" then return { }, nil, true end
			if route then
				local nodeSet, nodeIds = { }, { unpack(addedWaypointOrder) }
				for _, nodeId in ipairs(nodeIds) do nodeSet[nodeId] = true end
				for _, node in ipairs(route) do
					if not nodeSet[node.id] and not spec.allocNodes[node.id] then
						nodeSet[node.id] = true
						nodeIds[#nodeIds + 1] = node.id
					end
				end
				if #nodeIds > 0 and #nodeIds <= (maxAddedPoints or inputs.search.maxAddedPoints) then
					-- Preserve A*'s seed-to-target order. PassiveSpec:AllocNode needs
					-- each requested node to be reachable from the current allocation;
					-- only the deduplication key is canonicalized numerically.
					local routeKey = canonicalNodeKey(nodeIds)
					if not seenCandidates[routeKey] then
						seenCandidates[routeKey] = true
						candidates[#candidates + 1] = {
							nodeIds = nodeIds,
							targetId = target.id,
							targetRegion = regionByNode[target.id],
							routePointCost = #nodeIds,
							label = target.dn or target.name or ("Passive " .. tostring(target.id)),
							island = island,
						}
					end
				end
			end
		end
	end
	if requestedTargetId and #candidates == 0 and #targets > 0 then
		return { }, "Target node could not be reached within the selected branch and passive-point budget: " .. tostring(requestedTargetId)
	end
	return candidates
end

-- Turn bounded, exact-compatible archive trees into route proposals for the
-- active build. Only their passive-node patterns are reused; the active build's
-- gear, gems, ascendancy, level, and scenario remain the calculation seed.
-- Every returned route is a native path from the current allocation and still
-- passes the ordinary candidate validator and exact PoB calculation.
function treeSearch.BuildArchivedRouteCandidates(spec, inputs, routePatterns, limit, maxAddedPoints, control,
	progressFunc, suppliedRegionMap, candidatePointLimit)
	local candidates, coverage = { }, {
		availablePatterns = type(routePatterns) == "table" and #routePatterns or 0,
		consideredPatterns = 0,
		eligiblePatterns = 0,
		generatedCandidates = 0,
		skippedNoLocalTargets = 0,
		skippedPointBudget = 0,
		targetAttempts = 0,
		skippedUnreachableTargets = 0,
		targetsOmittedByAttemptLimit = 0,
		radius = nil,
	}
	if limit <= 0 or type(routePatterns) ~= "table" or #routePatterns == 0 then return candidates, coverage end
	local search = inputs and inputs.search or { }
	local runSpec = search.routePlannerRunSpec
	if type(runSpec) ~= "table" then return candidates, coverage end
	local radius = tonumber(runSpec.graph and runSpec.graph.radius) or 4
	if radius ~= 2 and radius ~= 4 and radius ~= 6 then radius = 4 end
	coverage.radius = radius
	local pointLimit = tonumber(maxAddedPoints or search.maxAddedPoints) or 0
	if pointLimit < 1 then return candidates, coverage end
	local partition = inputs.branch and inputs.branch.partition or "class"
	local regionByNode, partitionMetadata, regionError = suppliedRegionMap, nil, nil
	if not regionByNode then regionByNode, partitionMetadata, regionError = treeSearch.BuildRegionMap(spec, partition) end
	if not regionByNode then return candidates, coverage, regionError or "Passive-tree regions could not be resolved" end
	local forbidden = regionSet(inputs.branch and inputs.branch.forbidden)
	local allowed = regionSet(inputs.branch and inputs.branch.allowed)
	if partition == "spatial" and next(allowed) and not forbidden.hub then allowed.hub = true end
	local blockedNodeIds = idSet(search.removeNodeIds)
	for nodeId in pairs(idSet(search.forbiddenNodeIds)) do blockedNodeIds[nodeId] = true end
	local baseSeeds, seedSeen, activeMain = { }, { }, { }
	for rawId, node in pairs(spec.allocNodes or { }) do
		local nodeId = tonumber(rawId)
		if nodeId and node and node.type ~= "AscendClassStart" and not node.ascendancyName then
			activeMain[nodeId] = true
			if not blockedNodeIds[nodeId] and not seedSeen[nodeId] then
				seedSeen[nodeId] = true
				baseSeeds[#baseSeeds + 1] = node
			end
		end
	end
	if #baseSeeds == 0 then return candidates, coverage end
	local maxEdgeLength = findMaxEdgeLength(spec)
	local function mainTreeNode(node)
		return type(node) == "table" and not node.ascendancyName and node.type ~= "AscendClassStart"
			and node.type ~= "Mastery" and node.type ~= "Socket" and not node.isProxy and not node.isMultipleChoiceOption
	end
	local function nodeRegionAllowed(nodeId)
		local region = lower(regionByNode[nodeId])
		return not forbidden[region] and (not next(allowed) or allowed[region])
	end
	local function connectionIds(node)
		local ids, seen = { }, { }
		for _, field in ipairs({ "linked", "out", "connections" }) do
			for key, value in pairs(node and node[field] or { }) do
				local otherId = type(value) == "table" and tonumber(value.id) or tonumber(value) or tonumber(key)
				if otherId and otherId > 0 and otherId == math.floor(otherId) and not seen[otherId] then
					seen[otherId] = true
					ids[#ids + 1] = otherId
				end
			end
		end
		return ids
	end
	-- Compute native hop distance from any currently allocated main-tree node.
	-- Radius limits which archive nodes may become goals; pathfinding itself still
	-- chooses the legal, point-costed connector path.
	local distance, queue, head = { }, { }, 1
	for nodeId in pairs(activeMain) do
		if not blockedNodeIds[nodeId] then
			distance[nodeId] = 0
			queue[#queue + 1] = nodeId
		end
	end
	while head <= #queue do
		local nodeId = queue[head]
		head = head + 1
		local nextDistance = distance[nodeId] + 1
		if nextDistance <= radius then
			local node = spec.nodes[nodeId] or spec.nodes[tostring(nodeId)]
			for _, otherId in ipairs(connectionIds(node)) do
				local other = otherId and (spec.nodes[otherId] or spec.nodes[tostring(otherId)])
				if otherId and mainTreeNode(other) and not blockedNodeIds[otherId] and nodeRegionAllowed(otherId)
					and distance[otherId] == nil then
					distance[otherId] = nextDistance
					queue[#queue + 1] = otherId
				end
			end
		end
	end
	local seenCandidates = { }
	local adjacency = { }
	for rawId, node in pairs(spec.nodes or { }) do
		local nodeId = tonumber(rawId)
		if nodeId and mainTreeNode(node) then
			adjacency[nodeId] = adjacency[nodeId] or { }
			for _, otherId in ipairs(connectionIds(node)) do
				local other = otherId and (spec.nodes[otherId] or spec.nodes[tostring(otherId)])
				if otherId and mainTreeNode(other) then
					adjacency[nodeId][otherId] = true
					adjacency[otherId] = adjacency[otherId] or { }
					adjacency[otherId][nodeId] = true
				end
			end
		end
	end
	for patternIndex, pattern in ipairs(routePatterns) do
		if control and control.cancelled then return { }, coverage, nil, true end
		if #candidates >= limit then break end
		coverage.consideredPatterns = coverage.consideredPatterns + 1
		local targets, targetSeen = { }, { }
		for _, rawId in ipairs(type(pattern) == "table" and pattern.nodeIds or { }) do
			local nodeId = tonumber(rawId)
			local node = nodeId and (spec.nodes[nodeId] or spec.nodes[tostring(nodeId)])
			if nodeId and nodeId > 0 and nodeId == math.floor(nodeId) and node and mainTreeNode(node)
				and not activeMain[nodeId] and not targetSeen[nodeId] and not blockedNodeIds[nodeId]
				and nodeRegionAllowed(nodeId) and (distance[nodeId] or math.huge) <= radius then
				targetSeen[nodeId] = true
				targets[#targets + 1] = node
			end
		end
		if #targets == 0 then
			coverage.skippedNoLocalTargets = coverage.skippedNoLocalTargets + 1
		else
			coverage.eligiblePatterns = coverage.eligiblePatterns + 1
			t_sort(targets, function(left, right)
				local distanceLeft = tonumber(distance[left.id]) or math.huge
				local distanceRight = tonumber(distance[right.id]) or math.huge
				if distanceLeft ~= distanceRight then return distanceLeft < distanceRight end
				local supportLeft = importedNodeEvidencePriority(left, inputs)
				local supportRight = importedNodeEvidencePriority(right, inputs)
				if supportLeft ~= supportRight then return supportLeft > supportRight end
				local preferenceLeft = nodePotentialPreferenceScore(left, inputs)
				local preferenceRight = nodePotentialPreferenceScore(right, inputs)
				if preferenceLeft ~= preferenceRight then return preferenceLeft > preferenceRight end
				local priorityLeft = left.type == "Keystone" and 1 or left.type == "Notable" and 2 or 3
				local priorityRight = right.type == "Keystone" and 1 or right.type == "Notable" and 2 or 3
				if priorityLeft ~= priorityRight then return priorityLeft < priorityRight end
				return left.id < right.id
			end)
			local seeds = { unpack(baseSeeds) }
			local addedNodeIds, addedSet, targetIds, targetRegions = { }, { }, { }, { }
			local routeVariants = { }
			local targetAttemptLimit = math.min(#targets, MAX_ARCHIVED_ROUTE_TARGET_ATTEMPTS)
			coverage.targetsOmittedByAttemptLimit = coverage.targetsOmittedByAttemptLimit + (#targets - targetAttemptLimit)
			for targetIndex = 1, targetAttemptLimit do
				if control and control.cancelled then return { }, coverage, nil, true end
				local target = targets[targetIndex]
				local remaining = pointLimit - #addedNodeIds
				if remaining <= 0 then break end
				coverage.targetAttempts = coverage.targetAttempts + 1
				local addedCountBeforeTarget = #addedNodeIds
				local route, _, pathStatus = findPath(spec, seeds, { [target.id] = target }, regionByNode, forbidden, allowed,
					blockedNodeIds, ((tonumber(search.seed) or 0) + patternIndex * 65537 + targetIndex * 7919) % 2147483647,
					maxEdgeLength, control, progressFunc, targetIndex, #targets, remaining, inputs)
				if pathStatus == "cancelled" then return { }, coverage, nil, true end
				if route then
					local routeAdds, routeSeen = { }, { }
					for _, node in ipairs(route) do
						if node and not activeMain[node.id] and not addedSet[node.id] and not routeSeen[node.id] then
							routeSeen[node.id] = true
							routeAdds[#routeAdds + 1] = node
						end
					end
					if #routeAdds <= remaining and (routeSeen[target.id] or addedSet[target.id] or activeMain[target.id]) then
						for _, node in ipairs(routeAdds) do
							addedSet[node.id] = true
							addedNodeIds[#addedNodeIds + 1] = node.id
							seeds[#seeds + 1] = node
						end
						targetIds[#targetIds + 1] = target.id
						targetRegions[#targetRegions + 1] = regionByNode[target.id]
						if #addedNodeIds > addedCountBeforeTarget then
							local variant = { nodeIds = { }, targetIds = { }, targetRegions = { } }
						for _, nodeId in ipairs(addedNodeIds) do variant.nodeIds[#variant.nodeIds + 1] = nodeId end
						for _, targetId in ipairs(targetIds) do variant.targetIds[#variant.targetIds + 1] = targetId end
						for _, region in ipairs(targetRegions) do variant.targetRegions[#variant.targetRegions + 1] = region end
						variant.targetId = variant.targetIds[#variant.targetIds]
						variant.targetRegion = variant.targetRegions[#variant.targetRegions]
						routeVariants[#routeVariants + 1] = variant
						end
					else
						coverage.skippedPointBudget = coverage.skippedPointBudget + 1
						coverage.skippedUnreachableTargets = coverage.skippedUnreachableTargets + 1
					end
				else
					coverage.skippedUnreachableTargets = coverage.skippedUnreachableTargets + 1
				end
			end
			local generatedVariantsForPattern = 0
			for variantIndex, variant in ipairs(routeVariants) do
				if generatedVariantsForPattern >= MAX_ARCHIVED_ROUTE_VARIANTS_PER_PATTERN or #candidates >= limit then break end
				local routeNodeIds = variant.nodeIds
				local removeNodeIds = { }
				local pointLimitForCandidate = tonumber(candidatePointLimit) or tonumber(search.maxTotalPoints) or math.huge
				local currentPointCount = spec.CountAllocNodes and select(1, spec:CountAllocNodes()) or 0
				local pointsToFree = math.max(0, currentPointCount + #routeNodeIds - pointLimitForCandidate)
				if pointsToFree > 0 then
					local protected, working = { }, { }
					for nodeId in pairs(activeMain) do working[nodeId] = true end
					for _, key in ipairs({ "requiredNodeIds", "addNodeIds", "targetNodeIds" }) do
						for _, nodeId in ipairs(search[key] or inputs[key] or { }) do
							nodeId = tonumber(nodeId)
							if nodeId then protected[nodeId] = true end
						end
					end
					for _, nodeId in ipairs(pattern.nodeIds or { }) do
						nodeId = tonumber(nodeId)
						if nodeId then protected[nodeId] = true end
					end
					for _, addedId in ipairs(routeNodeIds) do
						for activeId in pairs(adjacency[addedId] or { }) do
							if activeMain[activeId] then protected[activeId] = true end
						end
					end
					for _, requiredRegion in ipairs(inputs.branch and inputs.branch.required or { }) do
						for nodeId in pairs(activeMain) do
							if lower(regionByNode[nodeId]) == lower(requiredRegion) then protected[nodeId] = true end
						end
					end
					local jewelSockets = spec.jewels or { }
					for nodeId, itemId in pairs(jewelSockets) do
						if tonumber(itemId) and tonumber(itemId) > 0 then protected[tonumber(nodeId)] = true end
					end
					for _ = 1, pointsToFree do
						local leaves = { }
						for nodeId in pairs(working) do
							local node = spec.nodes[nodeId] or spec.nodes[tostring(nodeId)]
							local removableType = node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
								and node.type ~= "Mastery" and node.type ~= "Socket" and not node.ascendancyName
								and not node.isMultipleChoiceOption and not node.isProxy
							if removableType and not protected[nodeId] then
								local degree = 0
								for neighborId in pairs(adjacency[nodeId] or { }) do
									if working[neighborId] then degree = degree + 1 end
								end
								if degree <= 1 then leaves[#leaves + 1] = { id = nodeId, node = node } end
							end
						end
						if #leaves == 0 then break end
						t_sort(leaves, function(left, right)
							local leftType = left.node.type == "Keystone" and 3 or left.node.type == "Notable" and 2 or 1
							local rightType = right.node.type == "Keystone" and 3 or right.node.type == "Notable" and 2 or 1
							if leftType ~= rightType then return leftType < rightType end
						local leftEvidence = importedNodeEvidencePriority(left.node, inputs)
						local rightEvidence = importedNodeEvidencePriority(right.node, inputs)
						if leftEvidence ~= rightEvidence then return leftEvidence < rightEvidence end
						local leftPreference = nodePotentialPreferenceScore(left.node, inputs)
						local rightPreference = nodePotentialPreferenceScore(right.node, inputs)
						if leftPreference ~= rightPreference then return leftPreference < rightPreference end
						return left.id < right.id
						end)
						local chosen = leaves[1].id
						working[chosen] = nil
						removeNodeIds[#removeNodeIds + 1] = chosen
					end
					if #removeNodeIds < pointsToFree then removeNodeIds = { } end
				end
				if pointsToFree == 0 or #removeNodeIds >= pointsToFree then
					local key = canonicalNodeKey(routeNodeIds) .. "|remove:" .. canonicalNodeKey(removeNodeIds)
					if not seenCandidates[key] then
						seenCandidates[key] = true
						local candidate = {
						nodeIds = routeNodeIds,
						removeNodeIds = removeNodeIds,
						label = string.format("Archive pattern %d route %d (%d targets, %d added points)",
							patternIndex, variantIndex, #variant.targetIds, #routeNodeIds),
						targetId = variant.targetId,
						targetIds = variant.targetIds,
						targetRegions = variant.targetRegions,
						targetRegion = variant.targetRegion,
						archivedRoutePattern = true,
						archivedPatternIndex = patternIndex,
						archivedPatternVariantIndex = variantIndex,
						archivedPatternSupportCount = tonumber(pattern.supportCount) or 0,
						archivedPatternSampleCount = tonumber(pattern.sampleCount) or 0,
						archivedPatternSimilarity = tonumber(pattern.similarity) or 0,
						island = ((patternIndex + variantIndex - 2) % 4) + 1,
					}
						if #removeNodeIds > 0 then
							candidate.label = candidate.label .. string.format("; replace %d leaf points", #removeNodeIds)
							candidate.archivedPatternSwap = true
						end
						candidates[#candidates + 1] = candidate
						generatedVariantsForPattern = generatedVariantsForPattern + 1
					else
						coverage.skippedPointBudget = coverage.skippedPointBudget + 1
					end
				else
					coverage.skippedPointBudget = coverage.skippedPointBudget + 1
				end
				end
			end
		end
	coverage.generatedCandidates = #candidates
	return candidates, coverage
end

local function mergeHierarchicalExperts(first, second)
	local experts, seen = { }, { }
	local function addFrom(candidate)
		local function add(expert)
			if type(expert) ~= "table" or type(expert.zone) ~= "string" then return end
			local key = table.concat({ tostring(expert.policyVersion or ""), tostring(expert.planId or ""), expert.zone }, "\31")
			if seen[key] then return end
			seen[key] = true
			local copy = { }
			for field, value in pairs(expert) do copy[field] = value end
			experts[#experts + 1] = copy
		end
		if candidate then
			add(candidate.hierarchicalExpert)
			for _, expert in ipairs(candidate.hierarchicalExperts or { }) do add(expert) end
		end
	end
	addFrom(first)
	addFrom(second)
	return experts
end

local function mergeArchivedRouteProvenance(destination, sources)
	local patternSources, seen = { }, { }
	local sourceCount = 0
	for _, source in ipairs(sources or { }) do
		if source and source.archivedRoutePattern == true then
			local rows = source.archivedPatternSources
			if type(rows) ~= "table" or #rows == 0 then
				rows = { {
					patternIndex = source.archivedPatternIndex,
					variantIndex = source.archivedPatternVariantIndex,
					supportCount = source.archivedPatternSupportCount,
					sampleCount = source.archivedPatternSampleCount,
					similarity = source.archivedPatternSimilarity,
					label = source.label,
				} }
			end
			for _, row in ipairs(rows) do
				local patternIndex = tonumber(row.patternIndex)
				local variantIndex = tonumber(row.variantIndex)
				local key = patternIndex and (tostring(patternIndex) .. ":" .. tostring(variantIndex or 0))
					or ("label:" .. tostring(row.label or source.label or "archive route"))
				if not seen[key] then
					seen[key] = true
					sourceCount = sourceCount + 1
					if #patternSources < 8 then
						local rowCopy = { }
						for field, value in pairs(row) do rowCopy[field] = value end
						patternSources[#patternSources + 1] = rowCopy
					end
				end
			end
		end
	end
	if sourceCount == 0 then return false end
	destination.archivedRoutePattern = true
	destination.archiveDerivedPassiveRoute = true
	destination.archivedRouteComposition = true
	destination.archivedPatternSources = patternSources
	destination.archivedPatternSourceCount = sourceCount
	if sourceCount == 1 and patternSources[1] then
		destination.archivedPatternIndex = patternSources[1].patternIndex
		destination.archivedPatternVariantIndex = patternSources[1].variantIndex
		destination.archivedPatternSupportCount = patternSources[1].supportCount
		destination.archivedPatternSampleCount = patternSources[1].sampleCount
		destination.archivedPatternSimilarity = patternSources[1].similarity
	end
	return true
end

function treeSearch.CombineCandidates(candidates, limit, maxAddedPoints, topologySpec, originNodeId)
	local combinations = { }
	if limit <= 0 then return combinations end
	local maximumPoints = tonumber(maxAddedPoints) or math.huge
	local cycleOrigin = originNodeId or (topologySpec and topologySpec.curClass and topologySpec.curClass.startNodeId)
	local baselineAllocated, baselineOriginCycleRank = nil, nil
	if topologySpec and cycleOrigin then
		baselineAllocated = { }
		for nodeId, node in pairs(topologySpec.allocNodes or { }) do baselineAllocated[nodeId] = node end
		baselineOriginCycleRank = countOriginCycleRank(baselineAllocated, topologySpec, cycleOrigin)
	end
	local seenCombinations = { }
	local function appendCombination(candidate)
		local key = canonicalNodeKey(candidate.nodeIds)
		if seenCombinations[key] then return false end
		seenCombinations[key] = true
		combinations[#combinations + 1] = candidate
		return true
	end
	-- Keep some exact slots for two-route comparisons, then reserve the rest
	-- for progressively larger route bundles. Pair-only enumeration repeatedly
	-- combined the same first route and could never build broad tree proposals.
	local pairQuota = math.min(limit, math.max(1, math.floor(limit * 0.25)))
	for first = 1, #candidates do
		for second = first + 1, #candidates do
			local nodeIds, seen = { }, { }
			for _, nodeId in ipairs(candidates[first].nodeIds) do
				seen[nodeId] = true
				nodeIds[#nodeIds + 1] = nodeId
			end
			for _, nodeId in ipairs(candidates[second].nodeIds) do
				if not seen[nodeId] then
					seen[nodeId] = true
					nodeIds[#nodeIds + 1] = nodeId
				end
			end
			if #nodeIds > math.max(#candidates[first].nodeIds, #candidates[second].nodeIds) and #nodeIds <= maximumPoints then
				local firstName = candidates[first].label or "route"
				local secondName = candidates[second].label or "route"
				local combination = {
					nodeIds = nodeIds,
					label = "Combined passive routes " .. firstName .. " + " .. secondName,
					island = ((first + second - 1) % 4) + 1,
				}
				mergeArchivedRouteProvenance(combination, { candidates[first], candidates[second] })
				local experts = mergeHierarchicalExperts(candidates[first], candidates[second])
				if #experts > 0 then
					combination.hierarchicalExperts = experts
					combination.hierarchicalCombination = true
					combination.hierarchicalCombinationKind = "multi_route"
				end
				appendCombination(combination)
				if #combinations >= pairQuota then break end
			end
		end
		if #combinations >= pairQuota then break end
	end
	if #combinations >= limit then return combinations end

	-- Build route portfolios from distinct target goals. Choose one candidate
	-- per goal (different A* tie variants of the same goal are not independent
	-- coverage), then round-robin class regions so an early exact budget does
	-- not spend every progressive slot on one side of the tree.
	local routeByGoal, routeGoals, routesByRegion, regionOrder = { }, { }, { }, { }
	for _, candidate in ipairs(candidates) do
		if type(candidate.nodeIds) == "table" and #candidate.nodeIds > 0 then
			local goalKey = candidate.targetId and ("target:" .. tostring(candidate.targetId)) or ("path:" .. canonicalNodeKey(candidate.nodeIds))
			if not routeByGoal[goalKey] then
				routeByGoal[goalKey] = candidate
				routeGoals[#routeGoals + 1] = goalKey
				local region = tostring(candidate.targetRegion or "Unknown")
				if not routesByRegion[region] then
					routesByRegion[region] = { }
					regionOrder[#regionOrder + 1] = region
				end
				routesByRegion[region][#routesByRegion[region] + 1] = goalKey
			end
		end
	end
	local routeOrder = { }
	t_sort(regionOrder)
	local regionCursor = { }
	for _, region in ipairs(regionOrder) do regionCursor[region] = 1 end
	while #routeOrder < #routeGoals do
		local added = false
		for _, region in ipairs(regionOrder) do
			local goalKey = routesByRegion[region][regionCursor[region]]
			if goalKey then
				routeOrder[#routeOrder + 1] = goalKey
				regionCursor[region] = regionCursor[region] + 1
				added = true
			end
		end
		if not added then break end
	end
	local thresholds
	if maximumPoints >= 40 then
		-- Large fresh-tree searches should spend their few exact bundle slots on
		-- substantially different coverage, including one candidate at the full
		-- legal ceiling when the route pool can construct it.
		thresholds = {
			math.max(3, math.ceil(maximumPoints * 0.50)),
			math.max(4, math.ceil(maximumPoints * 0.75)),
			maximumPoints,
		}
	else
		thresholds = {
			math.max(2, math.ceil(maximumPoints * 0.25)),
			math.max(3, math.ceil(maximumPoints * 0.50)),
			math.max(4, math.ceil(maximumPoints * 0.75)),
			maximumPoints,
		}
	end
	local seenProgressive = { }
	for island = 1, 4 do
		if #combinations >= limit then break end
		local nodeIds, nodeSet, targetIds, targetRegions, lastEmittedCount = { }, { }, { }, { }, 0
		local archivedRoutes = { }
		local routeCount = 0
		local cycleFilteredRouteCount = 0
		local allocated = { }
		for nodeId, node in pairs(baselineAllocated or { }) do
			allocated[nodeId] = node
			nodeSet[nodeId] = true
		end
		local start = #routeOrder > 0 and ((island - 1) % #routeOrder) + 1 or 1
		for offset = 0, #routeOrder - 1 do
			if #combinations >= limit then break end
			if #nodeIds >= maximumPoints then break end
			local goalKey = routeOrder[((start + offset - 1) % #routeOrder) + 1]
			local route = routeByGoal[goalKey]
			local added = false
			local cycleStopped = false
			for _, nodeId in ipairs(route.nodeIds) do
				if not nodeSet[nodeId] then
					-- A route prefix remains connected to the already allocated class
					-- tree. Truncate at the exact point ceiling instead of discarding a
					-- portfolio merely because its last connector would overshoot it.
					if #nodeIds >= maximumPoints then break end
					nodeSet[nodeId] = true
					nodeIds[#nodeIds + 1] = nodeId
					if baselineOriginCycleRank ~= nil then
						allocated[nodeId] = topologySpec.nodes and topologySpec.nodes[nodeId]
						local cycleRank = countOriginCycleRank(allocated, topologySpec, cycleOrigin)
						if cycleRank > baselineOriginCycleRank then
							allocated[nodeId] = nil
						nodeSet[nodeId] = nil
						table.remove(nodeIds)
						cycleStopped = true
						cycleFilteredRouteCount = cycleFilteredRouteCount + 1
						break
						end
					end
					added = true
				end
			end
			if added then
				routeCount = routeCount + 1
				if route.archivedRoutePattern == true then archivedRoutes[#archivedRoutes + 1] = route end
				if route.targetId and nodeSet[route.targetId] then
					targetIds[#targetIds + 1] = route.targetId
					targetRegions[#targetRegions + 1] = route.targetRegion
				end
			end
			local crossedThreshold = false
			if routeCount >= 3 then
				for _, threshold in ipairs(thresholds) do
					if #nodeIds >= threshold and threshold > lastEmittedCount then
						crossedThreshold = true
						lastEmittedCount = threshold
					end
				end
			end
			local isFinalRoute = offset == #routeOrder - 1 or #nodeIds >= maximumPoints or cycleStopped
			if routeCount >= 3 and (crossedThreshold or isFinalRoute) and #nodeIds <= maximumPoints then
				local progressive = {
					nodeIds = { unpack(nodeIds) },
					label = string.format("Progressive passive routes (%d routes, %d points)", routeCount, #nodeIds),
					island = island,
					progressiveRouteBundle = true,
					routeCount = routeCount,
					cycleFilteredRouteCount = cycleFilteredRouteCount,
					targetIds = { unpack(targetIds) },
					targetRegions = { unpack(targetRegions) },
				}
				mergeArchivedRouteProvenance(progressive, archivedRoutes)
				local key = canonicalNodeKey(nodeIds)
				if not seenProgressive[key] then
					seenProgressive[key] = true
					local experts = { }
					for _, goal in ipairs(targetIds) do
						local expert = goal and routeByGoal["target:" .. tostring(goal)]
						if expert then
							for _, merged in ipairs(mergeHierarchicalExperts(expert, nil)) do experts[#experts + 1] = merged end
						end
					end
					if #experts > 0 then
						progressive.hierarchicalExperts = experts
						progressive.hierarchicalCombination = true
						progressive.hierarchicalCombinationKind = "progressive_multi_route"
					end
					appendCombination(progressive)
				end
			end
		end
	end
	return combinations
end

return treeSearch
