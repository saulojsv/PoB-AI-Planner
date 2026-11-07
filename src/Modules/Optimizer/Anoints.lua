-- Path of Building
--
-- Module: Native anoint candidate generation and isolated item mutations.
-- Keep legality aligned with ItemsTab:isAnointable and NotableDBControl's
-- recipe filter; PoB's exact calculator remains responsible for the result.
--
local t_insert = table.insert
local t_remove = table.remove
local t_sort = table.sort
local t_floor = math.floor

local anoints = { }

local function capacity(item)
	if item.canHaveFourEnchants then return 4 end
	if item.canHaveThreeEnchants then return 3 end
	if item.canHaveTwoEnchants then return 2 end
	return 1
end

local function isAnointable(item)
	local base = item and item.base
	return base ~= nil and not base.cannotBeAnointed and base.subType ~= "Talisman"
		and (item.canBeAnointed or base.type == "Amulet")
end

local function anointNames(item)
	local result = { }
	for _, field in ipairs({ "enchantModLines", "scourgeModLines", "implicitModLines", "explicitModLines", "crucibleModLines" }) do
		local modList = item[field]
		for _, mod in ipairs(modList or { }) do
			local name = mod.line and mod.line:match("^Allocates (.+)$")
			if name then result[#result + 1] = name end
		end
	end
	return result
end

local function isAnointLine(modLine)
	return modLine and modLine.line and modLine.line:match("^Allocates .+") ~= nil
end

local function canReplaceAnointsWithinCapacity(item, slots, addedCount)
	local replaced = { }
	for _, slotIndex in ipairs(slots) do
		if slotIndex <= #(item.enchantModLines or { }) and isAnointLine(item.enchantModLines[slotIndex]) then
			replaced[slotIndex] = true
		end
	end
	local replacedCount = 0
	for _ in pairs(replaced) do replacedCount = replacedCount + 1 end
	return #anointNames(item) - replacedCount + addedCount <= capacity(item)
end

local function combinationCount(count, choose)
	if choose < 0 or choose > count then return 0 end
	choose = math.min(choose, count - choose)
	local result = 1
	for index = 1, choose do
		result = result * (count - choose + index) / index
	end
	return t_floor(result + 0.5)
end

local makeAnointVariant
local appendRemoval

local function buildSlotPatterns(item, addedCount)
	local result = { }
	local maxCapacity = capacity(item)
	local existingSlotCount = math.min(#(item.enchantModLines or { }), maxCapacity)
	local maxAppended = math.min(addedCount, maxCapacity - existingSlotCount)
	for appendedCount = 0, maxAppended do
		local replacedSlotCount = addedCount - appendedCount
		if replacedSlotCount <= existingSlotCount then
			local selected = { }
			local function chooseExisting(startIndex, remaining)
				if remaining == 0 then
					local slots = { }
					for _, slotIndex in ipairs(selected) do slots[#slots + 1] = slotIndex end
					-- Appended positions are always the contiguous suffix after the
					-- current enchant array. CloneItemVariants validates this same
					-- sequence before each insert.
					for offset = 1, appendedCount do
						slots[#slots + 1] = existingSlotCount + offset
					end
					if canReplaceAnointsWithinCapacity(item, slots, addedCount) then
						result[#result + 1] = slots
					end
					return
				end
				local lastStart = existingSlotCount - remaining + 1
				for slotIndex = startIndex, lastStart do
					selected[#selected + 1] = slotIndex
					chooseExisting(slotIndex + 1, remaining - 1)
					selected[#selected] = nil
				end
			end
			chooseExisting(1, replacedSlotCount)
		end
	end
	return result
end

local function unrankCombination(values, choose, rank)
	local result = { }
	local nextIndex = 1
	local count = #values
	for position = 1, choose do
		local lastIndex = count - (choose - position)
		for valueIndex = nextIndex, lastIndex do
			local completions = combinationCount(count - valueIndex, choose - position)
			if rank > completions then
				rank = rank - completions
			else
				result[#result + 1] = values[valueIndex]
				nextIndex = valueIndex + 1
				break
			end
		end
	end
	return result
end

local function sampleCombinationPools(pools, targetCount, arity)
	local result = { }
	local totalCount = 0
	for _, pool in ipairs(pools) do totalCount = totalCount + pool.count end
	local sampleCount = math.min(targetCount, totalCount)
	if sampleCount <= 0 then return result end
	local poolIndex, poolStart, poolEnd = 1, 1, pools[1].count
	for sampleIndex = 1, sampleCount do
		local rank = sampleCount == totalCount and sampleIndex
			or t_floor((sampleIndex - 0.5) * totalCount / sampleCount) + 1
		while rank > poolEnd do
			poolStart = poolEnd + 1
			poolIndex = poolIndex + 1
			poolEnd = poolStart + pools[poolIndex].count - 1
		end
		local pool = pools[poolIndex]
		local combination = unrankCombination(pool.nodes, arity, rank - poolStart + 1)
		local variants, removals, labels = { }, { }, { }
		for index, node in ipairs(combination) do
			variants[index] = makeAnointVariant(node, pool.itemEntry, pool.slots[index])
			appendRemoval(removals, pool.allocatedNodes, node.id)
			labels[index] = tostring(node.dn)
		end
		t_sort(removals)
		result[#result + 1] = {
			nodeIds = { },
			removeNodeIds = removals,
			anointVariants = variants,
			label = "Anoint " .. table.concat(labels, " + ") .. " on " .. pool.itemEntry.slotName
				.. (#removals > 0 and " and refund paid passive points" or ""),
		}
	end
	return result
end

local function allocateCombinationQuotas(arities, availableByCount, quota)
	local result = { }
	for _, arity in ipairs(arities) do result[arity] = 0 end
	local remaining = quota
	while remaining > 0 do
		local advanced = false
		for _, arity in ipairs(arities) do
			if result[arity] < availableByCount[arity] then
				result[arity] = result[arity] + 1
				remaining = remaining - 1
				advanced = true
				if remaining == 0 then break end
			end
		end
		if not advanced then break end
	end
	return result
end

local function samplePool(pool, count, target)
	local result = { }
	if count <= 0 or target <= 0 then return result end
	if count <= target then
		for index = 1, count do result[#result + 1] = pool[index] end
		return result
	end
	for index = 1, target do
		local sampledIndex = t_floor((index - 0.5) * count / target) + 1
		result[#result + 1] = pool[sampledIndex]
	end
	return result
end

makeAnointVariant = function(node, itemEntry, slotIndex)
	return {
		nodeId = node.id,
		slotName = itemEntry.slotName,
		itemId = itemEntry.itemId,
		enchantSlot = slotIndex,
	}
end

appendRemoval = function(removals, allocatedNodes, nodeId)
	if allocatedNodes[nodeId] then removals[#removals + 1] = nodeId end
end

function anoints.BuildCandidates(spec, limit)
	local candidates, equippedItems = { }, { }
	if limit <= 0 then return candidates, 0 end
	local build = spec and spec.build
	local itemsTab = build and build.itemsTab
	local activeSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId])
	if not itemsTab or not activeSet then return candidates, 0 end

	local equipped = { }
	for slotName, slot in pairs(itemsTab.slots or { }) do
		local itemId = slot.selItemId
		if not slot.nodeId and slot.active ~= false and type(itemId) == "number" and itemId > 0
			and activeSet[slotName] and activeSet[slotName].selItemId == itemId then
			local item = itemsTab.items[itemId]
			if isAnointable(item) then
				equipped[#equipped + 1] = { slotName = slotName, itemId = itemId, item = item }
			end
		end
	end
	t_sort(equipped, function(a, b) return a.slotName < b.slotName end)

	local nodes = { }
	local allocatedNodes = spec.allocNodes or { }
	local nativeTree = spec.tree
	for nodeId, node in pairs(nativeTree and nativeTree.nodes or { }) do
		-- This is the same legality predicate used by NotableDBControl's ANOINT mode.
		local mappedNode = nativeTree.notableMap and nativeTree.notableMap[tostring(node.dn or ""):lower()]
		if node.recipe and #node.recipe >= 1 and mappedNode and mappedNode.id == nodeId then
			nodes[#nodes + 1] = node
		end
	end
	t_sort(nodes, function(a, b)
		local an, bn = tostring(a.dn or ""), tostring(b.dn or "")
		if an:lower() == bn:lower() then return a.id < b.id end
		return an:lower() < bn:lower()
	end)

	for _, equippedItem in ipairs(equipped) do
		local existing = { }
		for _, name in ipairs(anointNames(equippedItem.item)) do existing[name] = true end
		equippedItems[#equippedItems + 1] = {
			item = equippedItem,
			existing = existing,
		}
	end

	local pool = { }	-- Single-anoint proposals retain the long-standing deterministic coverage.
	-- Interleave gear slots before sampling so a multi-anoint item or a long
	-- notable list cannot consume the entire exact-evaluation quota by itself.
	for _, node in ipairs(nodes) do
		for _, equippedItem in ipairs(equippedItems) do
			local itemEntry = equippedItem.item
			if not equippedItem.existing[node.dn] then
				for _, slots in ipairs(buildSlotPatterns(itemEntry.item, 1)) do
					local slotIndex = slots[1]
					if canReplaceAnointsWithinCapacity(itemEntry.item, { slotIndex }, 1) then
						local removeNodeIds = allocatedNodes[node.id] and { node.id } or { }
						pool[#pool + 1] = {
							nodeIds = { },
							removeNodeIds = removeNodeIds,
							anointVariant = makeAnointVariant(node, itemEntry, slotIndex),
							label = "Anoint " .. tostring(node.dn) .. " on " .. itemEntry.slotName
								.. (#removeNodeIds > 0 and " and refund its passive point" or ""),
						}
					end
				end
			end
		end
	end

	-- Enumerate only compact item/slot descriptors. Combination spaces are
	-- counted exactly, then sampled by rank up to the search quota; the solver
	-- never materializes O(nodes^3) or O(nodes^4) candidate objects.
	local combinationPools, availableByCount, arities = { }, { }, { }
	for _, equippedItem in ipairs(equippedItems) do
		local itemEntry = equippedItem.item
		local eligibleNodes = { }
		for _, node in ipairs(nodes) do
			if not equippedItem.existing[node.dn] then eligibleNodes[#eligibleNodes + 1] = node end
		end
		for arity = 2, capacity(itemEntry.item) do
			local slotPatterns = buildSlotPatterns(itemEntry.item, arity)
			if #eligibleNodes >= arity and #slotPatterns > 0 then
				if not availableByCount[arity] then
					availableByCount[arity] = 0
					combinationPools[arity] = { }
					arities[#arities + 1] = arity
				end
			local nodeCombinationCount = combinationCount(#eligibleNodes, arity)
				for _, slots in ipairs(slotPatterns) do
					local count = nodeCombinationCount
					combinationPools[arity][#combinationPools[arity] + 1] = {
						nodes = eligibleNodes,
						allocatedNodes = allocatedNodes,
						itemEntry = itemEntry,
						slots = slots,
						count = count,
					}
					availableByCount[arity] = availableByCount[arity] + count
				end
			end
		end
	end
	t_sort(arities)

	local totalCombinationCount = 0
	for _, arity in ipairs(arities) do totalCombinationCount = totalCombinationCount + availableByCount[arity] end
	local candidateTarget = math.min(limit, #pool + totalCombinationCount)
	local combinationQuota = 0
	if totalCombinationCount > 0 and candidateTarget > 0 then
		if #pool == 0 or candidateTarget == #pool + totalCombinationCount then
			combinationQuota = math.min(totalCombinationCount, candidateTarget)
		elseif limit > 1 then
			combinationQuota = math.min(totalCombinationCount,
				math.max(1, #arities, t_floor(limit * 0.40)), limit - 1)
		end
	end
	local singleQuota = math.min(#pool, candidateTarget - combinationQuota)
	local spareQuota = candidateTarget - combinationQuota - singleQuota
	if spareQuota > 0 then
		local extraCombinations = math.min(spareQuota, totalCombinationCount - combinationQuota)
		combinationQuota = combinationQuota + extraCombinations
		spareQuota = spareQuota - extraCombinations
		if spareQuota > 0 then singleQuota = singleQuota + math.min(spareQuota, #pool - singleQuota) end
	end
	local candidatesByCount = { [1] = samplePool(pool, #pool, singleQuota) }
	local quotasByCount = allocateCombinationQuotas(arities, availableByCount, combinationQuota)
	for _, arity in ipairs(arities) do
		candidatesByCount[arity] = sampleCombinationPools(combinationPools[arity], quotasByCount[arity], arity)
	end
	-- Interleave arities so a small downstream exact-evaluation budget still
	-- sees single, pair, triple, and quad alternatives before one family dominates.
	local candidateArities = { 1 }
	for _, arity in ipairs(arities) do candidateArities[#candidateArities + 1] = arity end
	for index = 1, limit do
		for _, arity in ipairs(candidateArities) do
			local value = candidatesByCount[arity][index]
			if value then candidates[#candidates + 1] = value end
		end
	end
	local generatedByCount = { [1] = 0 }
	for _, value in ipairs(candidates) do
		if value.anointVariants then
			local arity = #value.anointVariants
			generatedByCount[arity] = (generatedByCount[arity] or 0) + 1
		elseif value.anointVariant then
			generatedByCount[1] = generatedByCount[1] + 1
		end
	end
	local availableTotal = #pool
	for _, count in pairs(availableByCount) do availableTotal = availableTotal + count end
	return candidates, availableTotal, {
		availableSingleCandidates = #pool,
		availablePairedCandidates = availableByCount[2] or 0,
		generatedSingleCandidates = generatedByCount[1],
		generatedPairedCandidates = generatedByCount[2] or 0,
		availableAnointCandidatesByCount = { [1] = #pool, [2] = availableByCount[2] or 0,
			[3] = availableByCount[3] or 0, [4] = availableByCount[4] or 0 },
		generatedAnointCandidatesByCount = { [1] = generatedByCount[1], [2] = generatedByCount[2] or 0,
			[3] = generatedByCount[3] or 0, [4] = generatedByCount[4] or 0 },
	}
end

function anoints.CloneItemVariants(build, variants, requestedRemovals)
	if type(variants) ~= "table" then return nil, "At least one native anoint is required" end
	if variants.nodeId then variants = { variants } end
	if #variants == 0 then return nil, "At least one native anoint is required" end
	local normalized, seenNodes, seenSlots = { }, { }, { }
	local itemId, slotName
	for _, variant in ipairs(variants) do
		if type(variant) ~= "table" then return nil, "Anoint candidate entry must be a table" end
		local currentItemId = tonumber(variant.itemId)
		local currentSlotName = variant.slotName
		local nodeId = tonumber(variant.nodeId)
		local slotIndex = tonumber(variant.enchantSlot) or 1
		if not currentItemId or currentItemId < 1 or currentItemId ~= math.floor(currentItemId)
			or type(currentSlotName) ~= "string" or currentSlotName == ""
			or not nodeId or nodeId < 1 or nodeId ~= math.floor(nodeId)
			or slotIndex < 1 or slotIndex ~= math.floor(slotIndex) then
			return nil, "Anoint candidate contains an invalid item, node, or enchant slot"
		end
		if itemId and (itemId ~= currentItemId or slotName ~= currentSlotName) then
			return nil, "All anoints in one candidate must target the same equipped item"
		end
		if seenNodes[nodeId] then return nil, "A notable cannot be anointed twice on the same item" end
		if seenSlots[slotIndex] then return nil, "Each anoint must use a distinct enchant slot" end
		itemId, slotName = currentItemId, currentSlotName
		seenNodes[nodeId], seenSlots[slotIndex] = true, true
		normalized[#normalized + 1] = { nodeId = nodeId, enchantSlot = slotIndex }
	end
	t_sort(normalized, function(a, b) return a.enchantSlot < b.enchantSlot end)

	local itemsTab = build and build.itemsTab
	local sourceItem = itemsTab and itemsTab.items and itemsTab.items[itemId]
	local slot = itemsTab and slotName and itemsTab.slots and itemsTab.slots[slotName]
	local activeSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId])
	if not sourceItem or not sourceItem.BuildRaw or not slot or slot.nodeId or slot.selItemId ~= sourceItem.id
		or not activeSet or not activeSet[slotName] or activeSet[slotName].selItemId ~= sourceItem.id then
		return nil, "The selected anoint item is no longer equipped in the active item set"
	end
	if not isAnointable(sourceItem) then
		return nil, "The selected equipped item cannot be anointed by PoB"
	end
	local nativeTree = build.spec and build.spec.tree
	local requestedRemovalSet = { }
	for _, removedNodeId in ipairs(requestedRemovals or { }) do
		local numericNodeId = tonumber(removedNodeId)
		if numericNodeId then requestedRemovalSet[numericNodeId] = true end
	end
	for _, variant in ipairs(normalized) do
		local nodeId = variant.nodeId
		local node = nativeTree and nativeTree.nodes and nativeTree.nodes[nodeId]
		local mappedNode = node and nativeTree.notableMap and nativeTree.notableMap[tostring(node.dn or ""):lower()]
		if not node or not node.recipe or #node.recipe < 1 or not mappedNode or mappedNode.id ~= nodeId then
			return nil, "The requested passive is not in PoB's native anointable notable list"
		end
		if build.spec.allocNodes[nodeId] and not requestedRemovalSet[nodeId] then
			return nil, "The requested anoint is already allocated on the passive tree"
		end
		for _, name in ipairs(anointNames(sourceItem)) do
			if name == node.dn then return nil, "The requested notable is already anointed on this item" end
		end
	end
	local replacedAnointSlots = { }
	for _, variant in ipairs(normalized) do
		local modLine = sourceItem.enchantModLines and sourceItem.enchantModLines[variant.enchantSlot]
		if isAnointLine(modLine) then replacedAnointSlots[variant.enchantSlot] = true end
	end
	local replacedAnointCount = 0
	for _ in pairs(replacedAnointSlots) do replacedAnointCount = replacedAnointCount + 1 end
	if #anointNames(sourceItem) - replacedAnointCount + #normalized > capacity(sourceItem) then
		return nil, "The requested anoints exceed this item's native enchantment capacity"
	end
	local plannedEnchantCount = #(sourceItem.enchantModLines or { })
	for _, variant in ipairs(normalized) do
		local maxAllowedSlot = math.min(capacity(sourceItem), plannedEnchantCount + 1)
		if variant.enchantSlot > maxAllowedSlot then
			return nil, "The requested anoint slot is unavailable on this item"
		end
		plannedEnchantCount = math.max(plannedEnchantCount, variant.enchantSlot)
	end

	local item = new("Item"):Item(sourceItem:BuildRaw())
	for _, variant in ipairs(normalized) do
		local slotIndex = variant.enchantSlot
		local maxAllowedSlot = math.min(capacity(item), #(item.enchantModLines or { }) + 1)
		if slotIndex > maxAllowedSlot then
			return nil, "The requested anoint slot is unavailable on this item"
		end
		local node = nativeTree.nodes[variant.nodeId]
		if #item.enchantModLines >= slotIndex then t_remove(item.enchantModLines, slotIndex) end
		t_insert(item.enchantModLines, slotIndex, { crafted = true, line = "Allocates " .. node.dn })
	end
	item:BuildAndParseRaw()
	local parsedNames = { }
	for _, name in ipairs(anointNames(item)) do parsedNames[name] = true end
	if #anointNames(item) > capacity(item) then
		return nil, "PoB parsed more anoints than this item can legally support"
	end
	for _, variant in ipairs(normalized) do
		local node = nativeTree.nodes[variant.nodeId]
		if not parsedNames[node.dn] then
			return nil, "PoB did not preserve every requested anoint while parsing the cloned item"
		end
	end
	item.id = sourceItem.id
	return item
end

function anoints.CloneItem(build, variant, requestedRemovals)
	return anoints.CloneItemVariants(build, variant, requestedRemovals)
end

function anoints.IsAnointableItem(item)
	return isAnointable(item)
end

return anoints
