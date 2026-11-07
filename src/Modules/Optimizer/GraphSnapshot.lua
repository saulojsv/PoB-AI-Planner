-- Path of Building
--
-- Module: privacy-limited, versioned native build/proposal projection for GNN IPC.
-- Raw PoB XML and raw item text never cross the process boundary.

local snapshot = { }
local Version = require("Modules.Optimizer.Version")
local SurrogateFeatures = require("Modules.Optimizer.SurrogateFeatures")

local function sortedIds(set)
	local result = { }
	for id, present in pairs(set or { }) do if present then result[#result + 1] = tonumber(id) end end
	table.sort(result)
	return result
end

local function linkedNodeIds(node)
	local result, seen = { }, { }
	for key, value in pairs(node and (node.out or node.connections) or { }) do
		local id = type(value) == "table" and tonumber(value.id or value[1] or key) or tonumber(value) or tonumber(key)
		if id and id > 0 and id ~= tonumber(node.id) and not seen[id] then
			seen[id] = true
			result[#result + 1] = id
		end
	end
	table.sort(result)
	return result
end

local function localTree(build, candidates, radius)
	local spec = build.spec
	local distances, queue, head = { }, { }, 1
	local function seed(nodeId)
		nodeId = tonumber(nodeId)
		if nodeId and spec.nodes[nodeId] and distances[nodeId] == nil then
			distances[nodeId] = 0
			queue[#queue + 1] = nodeId
		end
	end
	for nodeId, allocated in pairs(spec.allocNodes or { }) do if allocated then seed(nodeId) end end
	for _, candidate in ipairs(candidates or { }) do
		for _, nodeId in ipairs(candidate.nodeIds or { }) do seed(nodeId) end
		for _, nodeId in ipairs(candidate.removeNodeIds or { }) do seed(nodeId) end
	end
	while head <= #queue do
		local nodeId = queue[head]
		head = head + 1
		local distance = distances[nodeId]
		if distance < radius then
			for _, linkedId in ipairs(linkedNodeIds(spec.nodes[nodeId])) do
				if spec.nodes[linkedId] and distances[linkedId] == nil then
					distances[linkedId] = distance + 1
					queue[#queue + 1] = linkedId
				end
			end
		end
	end
	local nodes, edges = { }, { }
	local nodeSet = { }
	for nodeId in pairs(distances) do
		local node = spec.nodes[nodeId]
		if node and not node.isProxy then
			nodeSet[nodeId] = true
			local category = node.type or (node.isKeystone and "keystone") or (node.isNotable and "notable") or "passive"
			nodes[#nodes + 1] = { id = nodeId, allocated = spec.allocNodes and spec.allocNodes[nodeId] == true, category = tostring(category) }
		end
	end
	table.sort(nodes, function(left, right) return left.id < right.id end)
	for _, row in ipairs(nodes) do
		for _, linkedId in ipairs(linkedNodeIds(spec.nodes[row.id])) do
			if nodeSet[linkedId] and row.id < linkedId then edges[#edges + 1] = { source = row.id, target = linkedId } end
		end
	end
	return nodes, edges
end

local function buildItemsAndGroups(build)
	local items, groups = { }, { }
	local itemsTab = build.itemsTab
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId]) or { }
	for slotName, slot in pairs(itemSet) do
		local itemId = type(slot) == "table" and tonumber(slot.selItemId)
		local item = itemId and itemId > 0 and itemsTab.items and itemsTab.items[itemId]
		if item then
			local fingerprint = SurrogateFeatures.ItemFingerprint(item)
			if fingerprint then
				items[#items + 1] = { slot = tostring(slotName), base = tostring(item.base and item.base.name or item.baseName or item.type or "unknown"),
					rarity = tostring(item.rarity or "unknown"), fingerprint = fingerprint }
			end
		end
	end
	table.sort(items, function(left, right) return left.slot < right.slot end)
	for groupIndex, group in ipairs(build.skillsTab and build.skillsTab.socketGroupList or { }) do
		if groupIndex > 48 then break end
		local row = { index = groupIndex, slot = tostring(group.slot or "Unassigned"), enabled = group.enabled ~= false,
			includedInFullDPS = group.includeInFullDPS == true, gems = { } }
		for _, gem in ipairs(group.gemList or { }) do
			if #row.gems >= 32 then break end
			local data = gem.gemData
			local effect = gem.grantedEffect or (data and data.grantedEffect)
			local id = gem.gemId or data and data.id
			local effectId = gem.skillId or data and data.grantedEffectId or effect and effect.id
			if id and effectId then
				row.gems[#row.gems + 1] = { gemId = tostring(id), effectId = tostring(effectId),
					level = math.max(1, math.min(100, tonumber(gem.level) or 1)),
					quality = math.max(0, math.min(100, tonumber(gem.quality) or 0)),
					origin = effect and effect.fromItem and "item_granted" or "socketed_gem",
					support = effect and effect.support == true }
			end
		end
		groups[#groups + 1] = row
	end
	return items, groups
end

local function proposalFamily(candidate)
	if candidate.isBaselineCandidate then return "baseline" end
	if candidate.triggerVariant or candidate.crossSkillVariant or candidate.secondarySkill then return "cross_skill" end
	if candidate.gearVariant then return candidate.nodeIds and #candidate.nodeIds > 0 and "hybrid" or "equipment" end
	if candidate.jewelVariant or candidate.jewelVariants or candidate.jewelCombination then return "jewel" end
	if candidate.gemVariant or candidate.gemVariants or candidate.configurationVariant then return "skill" end
	if candidate.nodeIds or candidate.removeNodeIds then return "tree" end
	return "other"
end

local function proposalsFor(build, candidates)
	local result = { }
	for index, candidate in ipairs(candidates or { }) do
		local allocated = build.spec.allocNodes or { }
		local added = { }
		local removed = { }
		for _, id in ipairs(candidate.nodeIds or { }) do
			id = tonumber(id)
			if id and not allocated[id] then added[#added + 1] = id end
		end
		for _, id in ipairs(candidate.removeNodeIds or { }) do
			id = tonumber(id)
			if id and allocated[id] then removed[#removed + 1] = id end
		end
		local family = proposalFamily(candidate)
		local tokens = { "family:" .. family }
		if candidate.ascendancyVariant then tokens[#tokens + 1] = "mutation:ascendancy" end
		if candidate.masteryVariant then tokens[#tokens + 1] = "mutation:mastery" end
		if candidate.tattooVariant then tokens[#tokens + 1] = "mutation:tattoo" end
		if candidate.timelessVariant then tokens[#tokens + 1] = "mutation:timeless" end
		for _, variant in ipairs(candidate.gemVariants or { }) do
			if variant.gemId then tokens[#tokens + 1] = "gem:" .. tostring(variant.gemId) end
			if variant.skillId then tokens[#tokens + 1] = "effect:" .. tostring(variant.skillId) end
		end
		local changedSlots = candidate.gearVariant and candidate.gearVariant.changedSlots or { }
		for _, slot in ipairs(changedSlots) do tokens[#tokens + 1] = "item-slot:" .. tostring(slot) end
		for _, item in ipairs(candidate.gearVariant and candidate.gearVariant.items or { }) do
			local described = type(item.item) == "table" and item.item or item
			local fingerprint = SurrogateFeatures.ItemFingerprint(described)
			if fingerprint then tokens[#tokens + 1] = "candidate-item:" .. fingerprint end
			local base = described and (described.base and described.base.name or described.baseName or described.type)
			if type(base) == "string" and base ~= "" and #base <= 120 then tokens[#tokens + 1] = "candidate-base:" .. base end
		end
		for _, jewel in ipairs(candidate.jewelVariants or (candidate.jewelVariant and { candidate.jewelVariant }) or { }) do
			if jewel.nodeId then tokens[#tokens + 1] = "jewel-node:" .. tostring(jewel.nodeId) end
			if jewel.jewelType then tokens[#tokens + 1] = "jewel-type:" .. tostring(jewel.jewelType) end
		end
		local numeric = { #added, #removed, #(candidate.gemVariants or { }), #(candidate.jewelVariants or { }), #changedSlots }
		result[index] = { proposalId = "p" .. tostring(index), family = family,
			addedNodeIds = added, removedNodeIds = removed, changedItemSlots = changedSlots,
			featureTokens = tokens, numericFeatures = numeric }
	end
	return result
end

function snapshot.Create(build, candidates, runSpec)
	if type(build) ~= "table" or type(build.spec) ~= "table" then return nil, "build is unavailable" end
	local current = Version.Snapshot(build)
	local engine = { }
	for _, key in ipairs({ "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }) do
		local value = current[key]
		if value == nil or tostring(value) == "" then return nil, "engine fingerprint is incomplete: " .. key end
		engine[key] = tostring(value)
	end
	local skill = runSpec and runSpec.skill
	if not skill then return nil, "RunSpec has no native selected skill" end
	local nodes, edges = localTree(build, candidates, runSpec.graph.radius)
	local items, groups = buildItemsAndGroups(build)
	local output = build.calcsTab and build.calcsTab.mainOutput or { }
	local metrics = { }
	for _, key in ipairs({ "CombinedDPS", "FullDPS", "FullDotDPS", "TotalEHP", "PhysicalMaximumHitTaken",
		"FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken", "FireResist", "ColdResist",
		"LightningResist", "ChaosResist" }) do
		local value = tonumber(output[key])
		if value and value == value and value ~= math.huge and value ~= -math.huge then metrics[key] = value end
	end
	return {
		schemaVersion = 1, engine = engine, skill = skill,
		scenario = { profile = runSpec.scenario.profile, enemyPreset = runSpec.scenario.enemyPreset },
		passiveNodes = nodes, passiveEdges = edges, items = items, skillGroups = groups,
		baselineMetrics = metrics,
	}, proposalsFor(build, candidates)
end

return snapshot
