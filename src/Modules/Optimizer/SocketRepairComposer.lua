--
-- Module: compose native socket/link item repairs into isolated optimizer candidates.
-- This lives outside PhantomSim.run to keep LuaJIT's function-upvalue limit bounded.
--

local Equipment = require("Modules.Optimizer.Equipment")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")

local composer = { }

local function shallowCopy(source)
	local copy = { }
	for key, value in pairs(source or { }) do copy[key] = value end
	return copy
end

local function appendUniqueGearEntries(destination, source, keyFields)
	local seen = { }
	local function keyFor(entry)
		if type(entry) ~= "table" then return tostring(entry) end
		local parts = { }
		for _, field in ipairs(keyFields) do parts[#parts + 1] = tostring(entry[field] or "") end
		return table.concat(parts, "\30")
	end
	for _, entry in ipairs(destination) do seen[keyFor(entry)] = true end
	for _, entry in ipairs(source or { }) do
		local key = keyFor(entry)
		if not seen[key] then
			seen[key] = true
			destination[#destination + 1] = entry
		end
	end
	return destination
end

function composer.CandidateRepairsSocketPlan(build, candidate, repairPlan)
	local gear = candidate and candidate.gearVariant
	local itemId = gear and gear.overrides and tonumber(gear.overrides[repairPlan.slot])
	if not itemId then return false end
	local itemSet = Equipment.ActiveItemSet(build and build.itemsTab)
	local current = itemSet and itemSet[repairPlan.slot]
	if current and tonumber(current.selItemId) == itemId then return false end
	for _, generated in ipairs(gear.generatedItems or { }) do
		if generated and generated.slotName == repairPlan.slot and tonumber(generated.tempId) == itemId then
			return SkillCatalog.SocketLayoutMatchesRepair(generated.item, repairPlan)
		end
	end
	local items = build and build.itemsTab and build.itemsTab.items or { }
	local item = items[itemId] or items[tostring(itemId)]
	return SkillCatalog.SocketLayoutMatchesRepair(item, repairPlan)
end

function composer.ComposeGearVariant(build, candidate, repairCandidate, repairPlan)
	local repairGear = repairCandidate and repairCandidate.gearVariant
	if type(repairGear) ~= "table" or type(repairGear.overrides) ~= "table"
		or type(repairPlan) ~= "table" or type(repairPlan.slot) ~= "string" then
		return nil, "A native socket-repair candidate is unavailable"
	end
	if composer.CandidateRepairsSocketPlan(build, candidate, repairPlan) then
		return candidate.gearVariant, "already_repaired"
	end
	local currentGear = candidate and candidate.gearVariant
	local repairItemId = tonumber(repairGear.overrides[repairPlan.slot])
	if not repairItemId then return nil, "The socket-repair item has no native slot override" end
	if type(currentGear) == "table" then
		local conflictingItemId = tonumber((currentGear.overrides or { })[repairPlan.slot])
		if conflictingItemId and conflictingItemId ~= repairItemId then
			return nil, "The proposal replaces the slot required for the active skill socket repair"
		end
		for _, entry in ipairs(currentGear.generatedItems or { }) do
			if tostring(entry.slotName or entry.slot) == repairPlan.slot
				and tonumber(entry.tempId or entry.itemId) ~= repairItemId then
				return nil, "The proposal generates a different item in the slot required for the active skill socket repair"
			end
		end
		for _, slotName in ipairs(currentGear.changedSlots or { }) do
			if tostring(slotName) == repairPlan.slot and conflictingItemId ~= repairItemId then
				return nil, "The proposal independently changes the slot required for the active skill socket repair"
			end
		end
		local repairBinding, candidateBinding = repairGear.socketBinding, currentGear.socketBinding
		if repairBinding and candidateBinding
			and (repairBinding.groupIndex ~= candidateBinding.groupIndex
				or repairBinding.slotName ~= candidateBinding.slotName
				or repairBinding.itemId ~= candidateBinding.itemId) then
			return nil, "The proposal and socket repair require different native skill bindings"
		end
	end

	local merged = shallowCopy(repairGear)
	for key, value in pairs(currentGear or { }) do
		if key ~= "overrides" and key ~= "items" and key ~= "generatedItems" and key ~= "changedSlots" then
			merged[key] = value
		end
	end
	merged.overrides = shallowCopy(repairGear.overrides)
	for slotName, itemId in pairs((currentGear and currentGear.overrides) or { }) do
		if slotName ~= repairPlan.slot or tonumber(itemId) == repairItemId then
			merged.overrides[slotName] = itemId
		end
	end
	merged.items = appendUniqueGearEntries(shallowCopy(repairGear.items or { }),
		(currentGear and currentGear.items) or { }, { "slot", "slotName", "itemId" })
	merged.generatedItems = appendUniqueGearEntries(shallowCopy(repairGear.generatedItems or { }),
		(currentGear and currentGear.generatedItems) or { }, { "slotName", "tempId" })
	merged.changedSlots = appendUniqueGearEntries(shallowCopy(repairGear.changedSlots or { }),
		(currentGear and currentGear.changedSlots) or { }, { "slotName" })
	local seenChangedSlots = { }
	for _, slotName in ipairs(merged.changedSlots) do
		if type(slotName) == "string" then seenChangedSlots[slotName] = true end
	end
	local function addChangedSlot(slotName)
		slotName = type(slotName) == "string" and slotName or nil
		if slotName and not seenChangedSlots[slotName] then
			seenChangedSlots[slotName] = true
			merged.changedSlots[#merged.changedSlots + 1] = slotName
		end
	end
	for _, entry in ipairs(merged.generatedItems) do addChangedSlot(entry.slotName or entry.slot) end
	for _, item in ipairs(merged.items) do
		if type(item) == "table" and item.synthetic == true then addChangedSlot(item.slot or item.slotName) end
	end
	addChangedSlot(repairPlan.slot)
	merged.socketRepair = true
	merged.socketRepairOnly = nil
	return merged, "composed"
end

return composer
