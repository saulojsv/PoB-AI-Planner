-- Path of Building
--
-- Module: exact equipment overrides sourced from the active Items tab.
-- The optimizer may select existing PoB items for visible equipment slots;
-- all slot legality is delegated to ItemsTab:IsItemValidForSlot.
--
local t_sort = table.sort
local json = require("dkjson")

local equipment = { }

function equipment.IsFlaskSlot(slotName)
	return type(slotName) == "string" and slotName:match("^[Ff][Ll][Aa][Ss][Kk]%s+%d+$") ~= nil
end

-- Legacy result summaries may carry text without the original candidate's
-- structured gear fields. Text is only a fallback for an explicit PoB flask
-- slot label; item-affix descriptions are never classified by flask wording.
function equipment.DescribesFlaskMutation(text)
	if type(text) ~= "string" then return false end
	local lower = text:lower()
	for index = 1, 5 do
		local marker = "flask " .. tostring(index)
		local startAt = 1
		while true do
			local first, last = lower:find(marker, startAt, true)
			if not first then break end
			local prefix = lower:sub(1, first - 1)
			local suffix = lower:sub(last + 1)
			local prefixIsLabel = prefix == "" or prefix:match("%s+$") ~= nil
				or prefix:match("[|,;:]%s*$") ~= nil
			local suffixIsLabel = suffix == "" or suffix:match("^%s*[:=]") ~= nil
				or suffix:match("^%s*→") ~= nil or suffix:match("^%s*%-") ~= nil
				or suffix:match("^%s*%(") ~= nil
			if prefixIsLabel and suffixIsLabel then return true end
			startAt = last + 1
		end
	end
	return false
end

local function shallowCopy(source)
	local result = { }
	for key, value in pairs(source or { }) do result[key] = value end
	return result
end

local function isSupportedSlot(itemsTab, itemSet, slotName)
	local slot = itemsTab and itemsTab.slots and itemsTab.slots[slotName]
	local entry = itemSet and itemSet[slotName]
	if type(slotName) ~= "string" or not slot or slot.nodeId or type(entry) ~= "table" or entry.selItemId == nil then
		return false
	end
	if slotName:find("Abyssal Socket", 1, true) or slotName:match("^Jewel ") then return false end
	if type(slot.shown) == "function" and not slot:shown() then return false end
	return true
end

function equipment.ParseOverrides(encoded)
	local text = tostring(encoded or ""):gsub("^%s*(.-)%s*$", "%1")
	if text == "" then return { } end
	if #text > 4096 then return nil, "Equipment overrides exceed the 4096-character Matrix limit" end
	local decoded, _, decodeError = json.decode(text)
	if decodeError then return nil, "Equipment overrides are invalid JSON: " .. tostring(decodeError) end
	local decodedMeta = type(decoded) == "table" and getmetatable(decoded)
	if type(decoded) ~= "table" or type(decodedMeta) ~= "table" or decodedMeta.__jsontype ~= "object" then
		return nil, "Equipment overrides must be a JSON object mapping PoB slot names to item IDs"
	end
	local overrides, count = { }, 0
	for slotName, itemId in pairs(decoded) do
		if type(slotName) ~= "string" or #slotName < 1 or #slotName > 64 then
			return nil, "Equipment override slot names must be strings of 1 to 64 characters"
		end
		if type(itemId) ~= "number" or itemId < 1 or itemId ~= math.floor(itemId) or itemId > 2147483647 then
			return nil, "Equipment override item IDs must be positive integers"
		end
		count = count + 1
		if count > 20 then return nil, "At most 20 equipment slots can be constrained in one run" end
		overrides[slotName] = itemId
	end
	return overrides
end

function equipment.EncodeOverrides(overrides)
	local valid = { }
	for slotName, itemId in pairs(overrides or { }) do
		valid[slotName] = itemId
	end
	setmetatable(valid, { __jsontype = "object" })
	return json.encode(valid) or "{}"
end

function equipment.ActiveItemSet(itemsTab)
	return itemsTab and ((itemsTab.activeItemSet)
		or (itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId]))
end

function equipment.GetSlots(build)
	local itemsTab = build and build.itemsTab
	local itemSet = equipment.ActiveItemSet(itemsTab)
	local slots = { }
	if not itemSet then return slots end
	for slotName in pairs(itemsTab.slots or { }) do
		if isSupportedSlot(itemsTab, itemSet, slotName) then
			slots[#slots + 1] = slotName
		end
	end
	t_sort(slots)
	return slots
end

-- Route Planner proposals may improve the active build through tree routes or
-- item reworks, but a flask slot is never a candidate improvement. Check both
-- the explicit changed-slot list and the final override map so composed or
-- externally supplied proposals cannot bypass the policy.
function equipment.HasFlaskMutation(build, candidate)
	local gear = type(candidate) == "table" and candidate.gearVariant
	if type(gear) ~= "table" then return false end
	for _, slotName in ipairs(gear.changedSlots or { }) do
		if equipment.IsFlaskSlot(slotName) then return true end
	end
	for _, item in ipairs(gear.generatedItems or { }) do
		if type(item) == "table" and equipment.IsFlaskSlot(item.slotName or item.slot) then return true end
	end
	local itemSet = equipment.ActiveItemSet(build and build.itemsTab)
	for _, item in ipairs(gear.items or { }) do
		if type(item) == "table" then
			local slotName = item.slot or item.slotName
			if equipment.IsFlaskSlot(slotName) then
				local current = itemSet and itemSet[slotName]
				local currentItemId = type(current) == "table" and tonumber(current.selItemId) or 0
				if tonumber(item.itemId) ~= currentItemId then return true end
			end
		end
	end
	for slotName, itemId in pairs(gear.overrides or { }) do
		if equipment.IsFlaskSlot(slotName) then
			local current = itemSet and itemSet[slotName]
			local currentItemId = type(current) == "table" and tonumber(current.selItemId) or 0
			if tonumber(itemId) ~= currentItemId then return true end
		end
	end
	return false
end

function equipment.FilterFlaskMutations(build, candidates)
	local filtered, rejected = { }, 0
	for _, candidate in ipairs(candidates or { }) do
		if equipment.HasFlaskMutation(build, candidate) then
			rejected = rejected + 1
		else
			filtered[#filtered + 1] = candidate
		end
	end
	return filtered, rejected
end

-- Return every selected item in the active ItemSet, including native jewel
-- socket entries stored outside the visible equipment-slot table. Counts are
-- per equipped occurrence, so the same stored item ID in two slots is priced
-- twice just as the calculated build consumes two item instances.
function equipment.GetBudgetItemIds(itemsTab)
	itemsTab = itemsTab or { }
	local itemSet = equipment.ActiveItemSet(itemsTab)
	local entries = { }
	for slotName, slot in pairs(itemSet or { }) do
		local itemId = type(slot) == "table" and tonumber(slot.selItemId) or nil
		if itemId and itemId > 0 then
			local item = itemsTab.items and itemsTab.items[itemId]
			entries[#entries + 1] = {
				slot = tostring(slotName),
				itemId = itemId,
				name = tostring(item and (item.name or item.baseName or item.type) or "PoB item"),
			}
		end
	end
	table.sort(entries, function(a, b)
		if a.slot ~= b.slot then return a.slot < b.slot end
		return a.itemId < b.itemId
	end)
	return entries
end

function equipment.GetChoices(build, slotName)
	local itemsTab = build and build.itemsTab
	local itemSet = equipment.ActiveItemSet(itemsTab)
	local choices = { { label = "Keep current item", itemId = 0 } }
	if not itemsTab or not itemSet or not isSupportedSlot(itemsTab, itemSet, slotName) then return choices end
	local itemIds = { }
	for itemId in pairs(itemsTab.items or { }) do
		if type(itemId) == "number" and itemId > 0 then itemIds[#itemIds + 1] = itemId end
	end
	t_sort(itemIds)
	for _, itemId in ipairs(itemIds) do
		local item = itemsTab.items[itemId]
		if item then
			local callOk, valid = pcall(itemsTab.IsItemValidForSlot, itemsTab, item, slotName, itemSet)
			if callOk and valid == true then
				local name = tostring(item.name or item.baseName or item.type or "PoB item")
				choices[#choices + 1] = { label = name .. "  (#" .. tostring(itemId) .. ")", itemId = itemId }
			end
		end
	end
	return choices
end

local function mergeOverrides(base, additions)
	local merged = shallowCopy(base)
	for slotName, itemId in pairs(additions or { }) do merged[slotName] = itemId end
	return merged
end

equipment.MergeOverrides = mergeOverrides

local function makeInventoryCandidate(build, fixedOverrides, changes, label)
	local overrides = mergeOverrides(fixedOverrides, changes)
	local valid = equipment.Validate(build, overrides)
	if not valid then return nil end
	local changedSlots = { }
	for slotName in pairs(changes or { }) do changedSlots[#changedSlots + 1] = slotName end
	t_sort(changedSlots)
	return {
		label = label,
		island = 1,
		gearVariant = {
			overrides = overrides,
			items = equipment.DescribeOverrides(build, overrides),
			changedSlots = changedSlots,
			inventorySearch = true,
			inventoryPair = next(changes) ~= nil and next(changes, next(changes)) ~= nil,
		},
	}
end

local function itemHasRingSlotCondition(itemsTab, itemId)
	local item = itemsTab and itemsTab.items and itemsTab.items[tonumber(itemId)]
	if type(item) ~= "table" then return false end
	local parts = { tostring(item.raw or "") }
	for _, field in ipairs({ "explicitModLines", "implicitModLines", "craftedModLines", "enchantModLines" }) do
		for _, line in ipairs(item[field] or { }) do
			parts[#parts + 1] = type(line) == "table" and tostring(line.line or "") or tostring(line or "")
		end
	end
	local text = table.concat(parts, "\n"):lower()
	return text:find("left ring", 1, true) ~= nil
		or text:find("right ring", 1, true) ~= nil
		or text:find("ring slot", 1, true) ~= nil
end

local function isEquivalentRingSwap(itemsTab, itemSet, changes)
	if type(changes) ~= "table" then return false end
	local count = 0
	for slotName in pairs(changes) do
		count = count + 1
		if slotName ~= "Ring 1" and slotName ~= "Ring 2" then return false end
	end
	if count ~= 2 then return false end
	local currentFirst = tonumber(itemSet["Ring 1"] and itemSet["Ring 1"].selItemId) or 0
	local currentSecond = tonumber(itemSet["Ring 2"] and itemSet["Ring 2"].selItemId) or 0
	if currentFirst <= 0 or currentSecond <= 0 or currentFirst == currentSecond then return false end
	if tonumber(changes["Ring 1"]) ~= currentSecond or tonumber(changes["Ring 2"]) ~= currentFirst then return false end
	-- Ring-slot-conditioned items can make a left/right swap mechanically
	-- meaningful. Keep those candidates for native evaluation; otherwise this is
	-- only a permutation of the same two equipped items and cannot improve the
	-- build's calculated state.
	return not itemHasRingSlotCondition(itemsTab, currentFirst)
		and not itemHasRingSlotCondition(itemsTab, currentSecond)
end

-- Enumerate bounded alternatives from the user's existing PoB inventory. This
-- proposes single-slot replacements first, then a small sample of two-slot
-- combinations so the exact calculator can observe item synergies. It never
-- constructs synthetic items or assumes that item names imply any stat value.
function equipment.BuildCandidates(build, limit, seed, fixedOverrides, options)
	local generated, inventory = { }, { }
	local coverage = {
		possibleSingleCandidates = 0,
		possiblePairedCandidates = 0,
		generatedSingleCandidates = 0,
		generatedPairedCandidates = 0,
		symmetryEquivalentPairsSkipped = 0,
		excludedFlaskSlots = 0,
		exactEvaluations = 0,
		exactSingleEvaluations = 0,
		exactPairedEvaluations = 0,
	}
	limit = math.max(0, math.floor(tonumber(limit) or 0))
	if limit == 0 then return generated, coverage end

	local itemSet = equipment.ActiveItemSet(build and build.itemsTab)
	if not itemSet then return generated, coverage end
	local locked = fixedOverrides or { }
	local excludedSlots = options and options.excludeSlots or { }
	for slotIndex, slotName in ipairs(equipment.GetSlots(build)) do
		local excludedFlask = options and options.excludeFlasks == true and equipment.IsFlaskSlot(slotName)
		if excludedFlask then
			coverage.excludedFlaskSlots = coverage.excludedFlaskSlots + 1
		elseif not excludedSlots[slotName] and locked[slotName] == nil then
			local currentItemId = (itemSet[slotName] and itemSet[slotName].selItemId) or 0
			local alternatives = { }
			for _, choice in ipairs(equipment.GetChoices(build, slotName)) do
				if choice.itemId > 0 and choice.itemId ~= currentItemId then alternatives[#alternatives + 1] = choice end
			end
			if #alternatives > 0 then
				local offset = ((math.floor(tonumber(seed) or 1) + (slotIndex - 1) * 7 - 1) % #alternatives) + 1
				local rotated = { }
				for index = 0, #alternatives - 1 do
					rotated[#rotated + 1] = alternatives[((offset + index - 1) % #alternatives) + 1]
				end
				inventory[#inventory + 1] = { slotName = slotName, choices = rotated }
				coverage.possibleSingleCandidates = coverage.possibleSingleCandidates + #rotated
			end
		end
	end
	for first = 1, #inventory do
		for second = first + 1, #inventory do
			coverage.possiblePairedCandidates = coverage.possiblePairedCandidates
				+ (#inventory[first].choices * #inventory[second].choices)
		end
	end
	if coverage.possibleSingleCandidates == 0 then return generated, coverage end

	-- Keep sampling and exact-evaluation work bounded even when the Items tab
	-- contains thousands of imported items. Round-robin over slots prevents one
	-- heavily populated slot from consuming all proposals.
	-- In repair-reserve mode, generate a wider paired-item tail so two-slot
	-- attribute/resistance fixes can be exact-calculated after the baseline.
	-- The caller decides whether to spend that reserve; total evaluations stay
	-- inside the same user budget.
	local singleShare = options and options.repairReserve and 0.35 or 0.65
	local singleQuota = math.min(limit, math.max(1, math.floor(limit * singleShare)))
	local pairQuota = limit - singleQuota
	local poolLimit = math.min(coverage.possibleSingleCandidates, math.max(singleQuota, math.min(limit * 4, 512)))
	local sample, depth = { }, 1
	while #sample < poolLimit do
		local addedAtDepth = false
		for _, slot in ipairs(inventory) do
			local choice = slot.choices[depth]
			if choice then
				sample[#sample + 1] = { slotName = slot.slotName, choice = choice }
				addedAtDepth = true
				if #sample >= poolLimit then break end
			end
		end
		if not addedAtDepth then break end
		depth = depth + 1
	end

	local function appendSingle(proposal)
		local itemLabel = proposal.choice.label or ("item #" .. tostring(proposal.choice.itemId))
		local candidate = makeInventoryCandidate(build, locked,
			{ [proposal.slotName] = proposal.choice.itemId }, "Stored item: " .. proposal.slotName .. " / " .. itemLabel)
		if candidate then
			generated[#generated + 1] = candidate
			coverage.generatedSingleCandidates = coverage.generatedSingleCandidates + 1
		end
	end

	for index = 1, math.min(singleQuota, #sample) do appendSingle(sample[index]) end

	local pairSignatures, attempts = { }, 0
	local maxPairAttempts = math.min(5000, math.max(pairQuota * 64, 64))
	if pairQuota > 0 then
		for first = 1, #sample do
			for second = first + 1, #sample do
				if sample[first].slotName ~= sample[second].slotName then
					attempts = attempts + 1
					local a, b = sample[first], sample[second]
					local changes = { [a.slotName] = a.choice.itemId, [b.slotName] = b.choice.itemId }
					local signature = a.slotName .. ":" .. tostring(a.choice.itemId) .. "|" .. b.slotName .. ":" .. tostring(b.choice.itemId)
					if not pairSignatures[signature] then
						pairSignatures[signature] = true
						if isEquivalentRingSwap(build.itemsTab, itemSet, changes) then
							coverage.symmetryEquivalentPairsSkipped = coverage.symmetryEquivalentPairsSkipped + 1
						else
							local candidate = makeInventoryCandidate(build, locked, changes,
								"Stored item pair: " .. a.slotName .. " + " .. b.slotName)
							if candidate then
								generated[#generated + 1] = candidate
								coverage.generatedPairedCandidates = coverage.generatedPairedCandidates + 1
								if coverage.generatedPairedCandidates >= pairQuota or #generated >= limit then break end
							end
						end
					end
					if attempts >= maxPairAttempts then break end
				end
			end
			if coverage.generatedPairedCandidates >= pairQuota or #generated >= limit or attempts >= maxPairAttempts then break end
		end
	end

	-- Use any unused pair quota for more single-slot diversity when the native
	-- slot rules reject all sampled pairs or only one slot has alternatives.
	for index = singleQuota + 1, #sample do
		if #generated >= limit then break end
		appendSingle(sample[index])
	end
	return generated, coverage
end

function equipment.DescribeOverrides(build, overrides)
	local itemsTab = build and build.itemsTab
	local slots = { }
	for slotName in pairs(overrides or { }) do slots[#slots + 1] = slotName end
	t_sort(slots)
	local result = { }
	for _, slotName in ipairs(slots) do
		local itemId = overrides[slotName]
		local item = itemsTab and itemsTab.items and itemsTab.items[itemId]
		result[#result + 1] = {
			slot = tostring(slotName),
			itemId = itemId,
			name = itemId == 0 and "Remover item equipado"
				or tostring(item and (item.name or item.baseName or item.type) or "PoB item"):sub(1, 120),
			rarity = tostring(item and item.rarity or ""):sub(1, 32),
			removed = itemId == 0 or nil,
		}
	end
	return result
end

local function sameItemId(left, right)
	local leftNumber, rightNumber = tonumber(left), tonumber(right)
	if leftNumber and rightNumber then return leftNumber == rightNumber end
	return tostring(left) == tostring(right)
end

function equipment.CopyVariant(gear)
	if type(gear) ~= "table" then return nil end
	local copy = shallowCopy(gear)
	for _, field in ipairs({ "overrides", "items", "generatedItems", "changedSlots" }) do
		copy[field] = shallowCopy(gear[field])
	end
	return copy
end

-- A main-hand replacement can make the currently equipped off-hand illegal
-- (most commonly a two-handed weapon beside a shield). Let PoB's own slot
-- validator identify that conflict, then include the off-hand removal in this
-- candidate. The search must evaluate the resulting complete set; it must not
-- silently keep an impossible weapon pair or modify the source build.
function equipment.NormalizeWeaponHandConflicts(build, gear, itemsTabOverride)
	local result = equipment.CopyVariant(gear)
	if type(result) ~= "table" then return nil end
	local itemsTab = itemsTabOverride or (build and build.itemsTab)
	local itemSet = equipment.ActiveItemSet(itemsTab)
	if not itemsTab or type(itemsTab.IsItemValidForSlot) ~= "function" or not itemSet then return result end
	local overrides = shallowCopy(result.overrides)
	local weaponPairs = {
		{ main = "Weapon 1", offhand = "Weapon 2" },
		{ main = "Weapon 1 Swap", offhand = "Weapon 2 Swap" },
	}
	local clearedSlots = { }
	for _, pair in ipairs(weaponPairs) do
		local mainSlot, offhandSlot = pair.main, pair.offhand
		if overrides[mainSlot] ~= nil and overrides[offhandSlot] == nil
			and isSupportedSlot(itemsTab, itemSet, mainSlot)
			and isSupportedSlot(itemsTab, itemSet, offhandSlot) then
			local finalSet = shallowCopy(itemSet)
			for slotName, slot in pairs(itemSet) do
				if type(slot) == "table" then finalSet[slotName] = shallowCopy(slot) end
			end
			local validOverrides = true
			for slotName, itemId in pairs(overrides) do
				local slot = finalSet[slotName]
				if type(slot) ~= "table" or type(itemId) ~= "number" then
					validOverrides = false
					break
				end
				slot.selItemId = itemId
			end
			local offhandId = validOverrides and (tonumber(finalSet[offhandSlot].selItemId) or 0) or 0
			local offhandItem = offhandId > 0 and itemsTab.items and itemsTab.items[offhandId] or nil
			if offhandItem then
				local callOk, valid = pcall(itemsTab.IsItemValidForSlot, itemsTab, offhandItem, offhandSlot, finalSet)
				if callOk and valid ~= true then
					overrides[offhandSlot] = 0
					clearedSlots[#clearedSlots + 1] = offhandSlot
				end
			end
		end
	end
	if #clearedSlots == 0 then return result end
	result.overrides = overrides
	local changedSlots, seen = { }, { }
	for _, slotName in ipairs(result.changedSlots or { }) do
		if type(slotName) == "string" and not seen[slotName] then
			seen[slotName] = true
			changedSlots[#changedSlots + 1] = slotName
		end
	end
	for _, slotName in ipairs(clearedSlots) do
		if not seen[slotName] then
			seen[slotName] = true
			changedSlots[#changedSlots + 1] = slotName
		end
	end
	t_sort(changedSlots)
	result.changedSlots = changedSlots
	if type(result.label) == "string" then
		for _, slotName in ipairs(clearedSlots) do
			result.label = result.label .. " + clear incompatible " .. slotName
		end
	end
	return result
end

-- Compose two equipment changes without silently overwriting an item or a
-- generated item in the same slot. The merged state is still re-parsed and
-- checked by the native candidate rebuild before its exact PoB calculation.
function equipment.MergeVariants(first, second, options)
	options = options or { }
	if type(first) ~= "table" then return equipment.CopyVariant(second) end
	if type(second) ~= "table" then return equipment.CopyVariant(first) end
	local overrides = shallowCopy(first.overrides)
	for slotName, itemId in pairs(second.overrides or { }) do
		local existing = overrides[slotName]
		if existing ~= nil and not sameItemId(existing, itemId) then
			return nil, "Gear variants require different items in " .. tostring(slotName)
		end
		overrides[slotName] = itemId
	end
	local firstBinding, secondBinding = first.socketBinding, second.socketBinding
	if firstBinding and secondBinding
		and (firstBinding.groupIndex ~= secondBinding.groupIndex
			or firstBinding.slotName ~= secondBinding.slotName
			or not sameItemId(firstBinding.itemId, secondBinding.itemId)) then
		return nil, "Gear variants require different native skill socket bindings"
	end
	local changedSlots, changedSeen = { }, { }
	for _, source in ipairs({ first.changedSlots or { }, second.changedSlots or { } }) do
		for _, slotName in ipairs(source) do
			if type(slotName) == "string" and not changedSeen[slotName] then
				changedSeen[slotName] = true
				changedSlots[#changedSlots + 1] = slotName
			end
		end
	end
	t_sort(changedSlots)
	local function mergeEntries(field, keyFields, rejectSlotConflicts)
		local entries, seen, itemBySlot = { }, { }, { }
		for _, source in ipairs({ first[field] or { }, second[field] or { } }) do
			for _, entry in ipairs(source) do
				local parts = { }
				for _, key in ipairs(keyFields) do
					local value = type(entry) == "table" and entry[key] or nil
					parts[#parts + 1] = tostring(value or "")
				end
				local identity = table.concat(parts, "\30")
				if rejectSlotConflicts and type(entry) == "table" then
					local slotName = entry.slotName or entry.slot
					local itemId = entry.tempId or entry.itemId
					if slotName and itemId and itemBySlot[slotName] and not sameItemId(itemBySlot[slotName], itemId) then
						return nil, "Gear variants generate different items in " .. tostring(slotName)
					end
					if slotName and itemId then itemBySlot[slotName] = itemId end
				end
				if not seen[identity] then
					seen[identity] = true
					entries[#entries + 1] = entry
				end
			end
		end
		return entries
	end
	local items, itemError = mergeEntries("items", { "slot", "slotName", "itemId" }, true)
	if not items then return nil, itemError end
	local generatedItems, generatedError = mergeEntries("generatedItems", { "slotName", "slot", "tempId", "itemId" }, true)
	if not generatedItems then return nil, generatedError end
	local merged = shallowCopy(first)
	for key, value in pairs(second) do
		if merged[key] == nil then merged[key] = value end
	end
	for _, field in ipairs({ "inventorySearch", "inventoryPair", "inventoryRoutePair", "syntheticSearch",
		"syntheticPair", "syntheticTriple", "catalystSearch", "socketRepair", "requirementRepair" }) do
		merged[field] = first[field] == true or second[field] == true or nil
	end
	merged.overrides = overrides
	merged.items = options.build and equipment.DescribeOverrides(options.build, overrides) or items
	merged.generatedItems = generatedItems
	merged.changedSlots = changedSlots
	merged.socketBinding = firstBinding or secondBinding
	if first.socketRepairOnly or second.socketRepairOnly then merged.socketRepairOnly = nil end
	if merged.inventorySearch or merged.syntheticSearch or merged.catalystSearch then merged.inventoryRoutePair = true end
	return merged
end

function equipment.Validate(build, overrides, itemsTabOverride, sourceSetOverride)
	local itemsTab = itemsTabOverride or (build and build.itemsTab)
	local itemSet = sourceSetOverride or equipment.ActiveItemSet(itemsTab)
	if not itemsTab or not itemSet then return false, "The active PoB equipment set is unavailable" end
	local finalSet = shallowCopy(itemSet)
	for slotName, slot in pairs(itemSet) do
		if type(slot) == "table" then finalSet[slotName] = shallowCopy(slot) end
	end
	for slotName, itemId in pairs(overrides or { }) do
		if type(slotName) ~= "string" or type(itemId) ~= "number" or itemId < 0
			or itemId ~= math.floor(itemId) or itemId > 2147483647 then
			return false, "Equipment overrides must map slot names to nonnegative integer PoB item IDs (zero clears a slot)"
		end
		if not isSupportedSlot(itemsTab, finalSet, slotName) then
			return false, "Equipment slot is not visible in the active PoB item set: " .. tostring(slotName)
		end
		local item = itemId > 0 and itemsTab.items and itemsTab.items[itemId] or nil
		if itemId > 0 and not item then return false, "PoB item ID is unavailable in the active Items tab: " .. tostring(itemId) end
		finalSet[slotName].selItemId = itemId
	end
	if next(overrides or { }) then
		local itemSlots = { }
		for slotName in pairs(itemsTab.slots or { }) do
			if isSupportedSlot(itemsTab, finalSet, slotName) then
				local itemId = tonumber(finalSet[slotName].selItemId) or 0
				if itemId > 0 then
					local previousSlot = itemSlots[itemId]
					if previousSlot then
						local previousOriginal = itemSet[previousSlot]
						local currentOriginal = itemSet[slotName]
						local previousChanged = not previousOriginal or previousOriginal.selItemId ~= finalSet[previousSlot].selItemId
						local currentChanged = not currentOriginal or currentOriginal.selItemId ~= finalSet[slotName].selItemId
						if previousChanged or currentChanged then
							return false, string.format("PoB item #%d cannot be assigned to both %s and %s", itemId, previousSlot, slotName)
						end
					else
						itemSlots[itemId] = slotName
					end
				end
			end
		end
		for slotName in pairs(itemsTab.slots or { }) do
			if isSupportedSlot(itemsTab, finalSet, slotName) then
				local itemId = finalSet[slotName].selItemId or 0
				local item = itemId > 0 and itemsTab.items and itemsTab.items[itemId]
				if itemId > 0 and not item then
					return false, "PoB item in slot " .. slotName .. " is missing from the active Items tab"
				end
				if item then
					local callOk, valid = pcall(itemsTab.IsItemValidForSlot, itemsTab, item, slotName, finalSet)
					if not callOk or valid ~= true then
						return false, "PoB rejects item #" .. tostring(itemId) .. " for equipment slot " .. slotName
					end
				end
			end
		end
	end
	return true, nil, finalSet
end

function equipment.InstallIsolatedSet(itemsTab, itemSet)
	local activeId = itemsTab.activeItemSetId or itemSet.id
	itemsTab.itemSets = shallowCopy(itemsTab.itemSets)
	if not activeId then return false, "The active PoB item set has no ID" end
	local sourceSlots = itemsTab.slots or { }
	local isolatedSlots = { }
	for slotName, slot in pairs(sourceSlots) do
		local slotCopy = shallowCopy(slot)
		setmetatable(slotCopy, getmetatable(slot))
		if slot.controls then slotCopy.controls = shallowCopy(slot.controls) end
		isolatedSlots[slotName] = slotCopy
	end
	itemsTab.slots = isolatedSlots
	if type(itemsTab.orderedSlots) == "table" then
		local orderedSlots = { }
		for index, slot in ipairs(itemsTab.orderedSlots) do
			orderedSlots[index] = isolatedSlots[slot.slotName] or slot
		end
		itemsTab.orderedSlots = orderedSlots
	end
	itemsTab.itemSets[activeId] = itemSet
	itemsTab.activeItemSetId = activeId
	itemsTab.activeItemSet = itemSet
	for slotName, entry in pairs(itemSet) do
		local slot = isolatedSlots[slotName]
		if slot and type(entry) == "table" and entry.selItemId ~= nil then
			slot.selItemId = entry.selItemId
			slot.active = entry.active
		end
	end
	return true
end

function equipment.ApplyOverridesToSet(itemSet, overrides)
	for slotName, itemId in pairs(overrides or { }) do
		if type(itemSet[slotName]) ~= "table" then
			return false, "Equipment slot is unavailable in the active PoB item set: " .. tostring(slotName)
		end
		itemSet[slotName].selItemId = itemId
	end
	return true
end

function equipment.ApplyVariation(build, overrides, title)
	local valid, validationError, finalSet = equipment.Validate(build, overrides)
	if not valid then return false, validationError end
	if not next(overrides or { }) then return true end
	local itemsTab = build.itemsTab
	local newId = 1
	while itemsTab.itemSets and itemsTab.itemSets[newId] do newId = newId + 1 end
	finalSet.id = newId
	finalSet.title = title or "Optimizer result - selected equipment"
	itemsTab.itemSets = shallowCopy(itemsTab.itemSets)
	itemsTab.itemSets[newId] = finalSet
	itemsTab.itemSetOrderList = shallowCopy(itemsTab.itemSetOrderList)
	itemsTab.itemSetOrderList[#itemsTab.itemSetOrderList + 1] = newId
	itemsTab:SetActiveItemSet(newId)
	itemsTab:AddUndoState()
	itemsTab.modFlag = true
	return true
end

return equipment
