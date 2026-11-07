-- Path of Building
--
-- Module: exact, deficit-driven Catalyst proposals for existing jewelry.
-- Catalysts are only proposed after the exact baseline exposes an actionable
-- attribute or resistance deficit. PoB parses and recalculates each 20% item;
-- this module never estimates the resulting stat values.

local CatalystSearch = { }

local catalystForNeed = {
	attribute = { id = 6, name = "Intrinsic" },
	resistance = { id = 8, name = "Prismatic" },
}

local allowedJewelryTypes = { Amulet = true, Ring = true, Belt = true }

local function nextVirtualItemId(itemsTab, used)
	local maxId = 0
	for itemId in pairs(itemsTab and itemsTab.items or { }) do
		if type(itemId) == "number" and itemId > maxId then maxId = itemId end
	end
	while used[maxId + 1] do maxId = maxId + 1 end
	return maxId + 1
end

local function needsForItem(needs)
	local result, seen = { }, { }
	for _, need in ipairs(needs or { }) do
		local catalyst = catalystForNeed[need.kind]
		if catalyst and not seen[catalyst.id] then
			seen[catalyst.id] = true
			result[#result + 1] = catalyst
		end
	end
	return result
end

local function makeCatalystCandidate(build, slotName, sourceItemId, sourceItem, catalyst, used, fixedOverrides, parsed)
	local item = new("Item"):Item(sourceItem.raw)
	if not item or not item.base or not allowedJewelryTypes[item.base.type]
		or item.catalyst and item.catalyst > 0 or item.corrupted then
		return nil, "Source item is not eligible for a new Catalyst"
	end
	item.catalyst = catalyst.id
	item.catalystQuality = 20
	item:BuildAndParseRaw()
	if not item.base or item.catalyst ~= catalyst.id or item.catalystQuality ~= 20
		or not allowedJewelryTypes[item.base.type] or item.corrupted then
		return nil, "PoB could not round-trip the 20% Catalyst item"
	end
	item:BuildModList()
	item.optimizerCatalyst = true
	item.optimizerCatalystId = catalyst.id
	item.optimizerCatalystQuality = 20
	local tempId = nextVirtualItemId(build.itemsTab, used)
	used[tempId] = true
	item.id = tempId
	local entry = {
		kind = "catalyst",
		tempId = tempId,
		sourceItemId = sourceItemId,
		slotName = slotName,
		item = item,
		name = catalyst.name .. " Catalyst (20%) — " .. tostring(sourceItem.name or sourceItem.baseName or sourceItem.type),
		baseName = sourceItem.baseName,
		catalystId = catalyst.id,
		catalystName = catalyst.name,
		catalystQuality = 20,
	}
	local overrides = require("Modules.Optimizer.Equipment").MergeOverrides(fixedOverrides, { [slotName] = tempId })
	local marketBudget = parsed and parsed.search and parsed.search.currencyBudget
	local sourceQuote = marketBudget and marketBudget.quotes and marketBudget.quotes[sourceItemId]
	local hasExplicitCost = parsed and parsed.search and parsed.search.catalystCostChaos ~= nil
	local priceCovered = marketBudget == nil or (sourceQuote ~= nil and hasExplicitCost)
	return {
		label = "Requirement repair: " .. catalyst.name .. " Catalyst on " .. slotName,
		island = 1,
		gearVariant = {
			overrides = overrides,
			items = { {
				slot = slotName,
				itemId = tempId,
				name = entry.name,
				rarity = tostring(item.rarity or ""),
				catalyst = catalyst.name,
				catalystId = catalyst.id,
				catalystQuality = 20,
			} },
			changedSlots = { slotName },
			generatedItems = { entry },
			catalystSearch = true,
			catalystPriceCovered = priceCovered,
		},
	}
end

function CatalystSearch.NewCoverage()
	return {
		active = false,
		possibleCandidates = 0,
		generatedCandidates = 0,
		exactEvaluations = 0,
		pricedCandidates = 0,
		unpricedCandidates = 0,
		improvedExactEvaluations = 0,
		lastRejection = nil,
	}
end

function CatalystSearch.BuildCandidates(build, needs, limit, fixedOverrides, parsed)
	local generated, coverage = { }, CatalystSearch.NewCoverage()
	limit = math.max(0, math.floor(tonumber(limit) or 0))
	if limit == 0 or not build or not build.itemsTab then return generated, coverage end
	local equipment = require("Modules.Optimizer.Equipment")
	local itemSet = equipment.ActiveItemSet(build.itemsTab)
	if not itemSet then return generated, coverage end
	local catalysts = needsForItem(needs)
	if #catalysts == 0 then return generated, coverage end
	local used = { }
	for _, slotName in ipairs(equipment.GetSlots(build)) do
		if not (fixedOverrides or { })[slotName] then
			local sourceItemId = tonumber(itemSet[slotName] and itemSet[slotName].selItemId) or 0
			local sourceItem = sourceItemId > 0 and build.itemsTab.items[sourceItemId] or nil
			if sourceItem and sourceItem.raw and sourceItem.base and allowedJewelryTypes[sourceItem.base.type]
				and not (sourceItem.catalyst and sourceItem.catalyst > 0)
				and not (sourceItem.catalystQuality and sourceItem.catalystQuality > 0)
				and not sourceItem.corrupted then
				for _, catalyst in ipairs(catalysts) do
					coverage.possibleCandidates = coverage.possibleCandidates + 1
					if #generated < limit then
						local candidate, rejection = makeCatalystCandidate(build, slotName, sourceItemId,
							sourceItem, catalyst, used, fixedOverrides, parsed)
						if candidate then
							generated[#generated + 1] = candidate
							coverage.generatedCandidates = coverage.generatedCandidates + 1
							if candidate.gearVariant.catalystPriceCovered then
								coverage.pricedCandidates = coverage.pricedCandidates + 1
							else
								coverage.unpricedCandidates = coverage.unpricedCandidates + 1
							end
						elseif rejection then
							coverage.lastRejection = tostring(rejection):sub(1, 180)
						end
					end
				end
			end
		end
	end
	coverage.active = coverage.generatedCandidates > 0
	return generated, coverage
end

return CatalystSearch
