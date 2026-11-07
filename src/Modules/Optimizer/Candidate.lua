-- Path of Building
--
-- Module: Optimizer candidate snapshots and reversible application.
--
local t_insert = table.insert
local t_sort = table.sort
local pool = require("Modules.Optimizer.Pool")
local Version = require("Modules.Optimizer.Version")
local Anoints = require("Modules.Optimizer.Anoints")
local ConfigurationChoices = require("Modules.Optimizer.ConfigurationChoices")
local Equipment = require("Modules.Optimizer.Equipment")
local SyntheticGear = require("Modules.Optimizer.SyntheticGear")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local candidate = { }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function shallowCopy(source)
	local copy = { }
	for key, value in pairs(source or { }) do copy[key] = value end
	return copy
end

local function jewelVariants(candidate)
	local variants = candidate and candidate.jewelVariants
	if type(variants) == "table" then return variants end
	if candidate and candidate.jewelVariant then return { candidate.jewelVariant } end
	return { }
end

local function validateJewelVariants(variants)
	local items, slots = { }, { }
	for _, variant in ipairs(variants or { }) do
		if type(variant) ~= "table" or type(variant.itemId) ~= "number" or variant.itemId < 1
			or variant.itemId ~= math.floor(variant.itemId) or type(variant.toNodeId) ~= "number"
			or variant.toNodeId < 1 or variant.toNodeId ~= math.floor(variant.toNodeId) then
			return false, "A combined jewel candidate contains an invalid item or destination socket"
		end
		if items[variant.itemId] then return false, "A jewel item cannot be used in more than one candidate socket" end
		items[variant.itemId] = true
		if slots[variant.toNodeId] then return false, "A combined jewel candidate assigns more than one item to the same socket" end
		slots[variant.toNodeId] = true
		if variant.fromNodeId and variant.fromNodeId > 0 then
			if variant.fromNodeId ~= math.floor(variant.fromNodeId) or slots[variant.fromNodeId] then
				return false, "A combined jewel candidate contains conflicting socket moves"
			end
			slots[variant.fromNodeId] = true
		end
	end
	return true
end

local function isClusterJewel(item)
	return item and item.type == "Jewel" and item.clusterJewel
		and item.jewelData and item.jewelData.clusterJewelValid
end

local function validateProjectedJewelVariants(sourceSpec, projectedSpec, itemsTab, variants)
	local clusterProviderSockets = { }
	for _, variant in ipairs(variants or { }) do
		if isClusterJewel(itemsTab.items[variant.itemId]) then
			clusterProviderSockets[variant.toNodeId] = true
		end
	end
	local validationBuild = shallowCopy(itemsTab.build)
	setmetatable(validationBuild, getmetatable(itemsTab.build))
	validationBuild.spec = projectedSpec
	local validationItemsTab = shallowCopy(itemsTab)
	setmetatable(validationItemsTab, getmetatable(itemsTab))
	validationItemsTab.items = itemsTab.items
	validationItemsTab.build = validationBuild

	for _, variant in ipairs(variants or { }) do
		local socket = projectedSpec.nodes[variant.toNodeId]
		local item = itemsTab.items[variant.itemId]
		if not socket or socket.type ~= "Socket" then
			return false, "A candidate jewel destination was not generated as a native PoB socket"
		end
		if not item or not item.jewelData then
			return false, "A candidate jewel item is not available in the isolated PoB item list"
		end
		if not sourceSpec.nodes[variant.toNodeId] then
			if variant.sourceKind ~= "cluster" or not isClusterJewel(item) then
				return false, "Only a native Cluster Jewel may target a generated cluster socket"
			end
			local parentedByCandidateCluster = false
			for _, subGraph in pairs(projectedSpec.subGraphs or { }) do
				if subGraph.parentSocket and clusterProviderSockets[subGraph.parentSocket.id] then
					for _, node in ipairs(subGraph.nodes or { }) do
						if node.id == variant.toNodeId then
							parentedByCandidateCluster = true
							break
						end
					end
				end
				if parentedByCandidateCluster then break end
			end
			if not parentedByCandidateCluster then
				return false, "A generated cluster socket must belong to another selected Cluster Jewel"
			end
		end
		local callOk, valid = pcall(validationItemsTab.IsItemValidForSlot, validationItemsTab, item, "Jewel " .. tostring(variant.toNodeId))
		if not callOk or valid ~= true then
			return false, "PoB rejects this jewel for its projected socket"
		end
	end
	return true
end

local function ascendancyNameSet(ascendClass)
	local names = { }
	if not ascendClass then return names end
	for _, key in ipairs({ "id", "name", "internalId" }) do
		local value = ascendClass[key]
		if value and value ~= "" then names[value] = true end
	end
	return names
end

local function nodeBelongsToSelectedAscendancy(node, selectedNames)
	return node and node.ascendancyName and selectedNames[node.ascendancyName] == true
end

local function filterUnselectedAscendancyNodes(hashList, spec, classId, ascendClassId, secondaryAscendClassId)
	local class = spec.tree.classes[classId]
	local mainAscend = class and class.classes[ascendClassId]
	local secondaryAscend = (spec.tree.alternate_ascendancies or { })[secondaryAscendClassId]
	local selectedNames = ascendancyNameSet(mainAscend)
	for name in pairs(ascendancyNameSet(secondaryAscend)) do selectedNames[name] = true end
	local filtered = { }
	for _, nodeId in ipairs(hashList or { }) do
		local node = spec.nodes[nodeId]
		if not node or not node.ascendancyName or nodeBelongsToSelectedAscendancy(node, selectedNames) then
			filtered[#filtered + 1] = nodeId
		end
	end
	return filtered
end

local function appendValue(parts, label, value, seen)
	local valueType = type(value)
	if valueType ~= "table" then
		parts[#parts + 1] = label .. "=" .. valueType .. ":" .. tostring(value)
		return
	end
	if seen[value] then
		parts[#parts + 1] = label .. "=<cycle>"
		return
	end
	seen[value] = true
	local keys = { }
	for key in pairs(value) do keys[#keys + 1] = key end
	t_sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	parts[#parts + 1] = label .. "={"
	for _, key in ipairs(keys) do
		appendValue(parts, tostring(key), value[key], seen)
	end
	parts[#parts + 1] = "}"
	seen[value] = nil
end

-- The result is tied to the exact passive, skill, gear, and configuration state
-- used by the search. This prevents applying a valid result to a build edited
-- while the coroutine was yielding to the UI.
function candidate.BuildSignature(build)
	local parts, seen = { }, { }
	appendValue(parts, "dataVersion", Version.Data(build), seen)
	appendValue(parts, "characterLevel", build.characterLevel, seen)
	appendValue(parts, "characterLevelAutoMode", build.characterLevelAutoMode, seen)
	appendValue(parts, "mainSocketGroup", build.mainSocketGroup, seen)
	appendValue(parts, "treeVersion", build.spec.treeVersion, seen)
	appendValue(parts, "class", build.spec.curClassId, seen)
	appendValue(parts, "ascendancy", build.spec.curAscendClassId, seen)
	appendValue(parts, "secondaryAscendancy", build.spec.curSecondaryAscendClassId, seen)
	local allocated = { }
	for nodeId in pairs(build.spec.allocNodes) do allocated[#allocated + 1] = nodeId end
	t_sort(allocated)
	appendValue(parts, "allocated", allocated, seen)
	appendValue(parts, "masteries", build.spec.masterySelections, seen)
	appendValue(parts, "jewels", build.spec.jewels, seen)
	local tattoos = { }
	for nodeId, node in pairs(build.spec.hashOverrides) do
		tattoos[nodeId] = { dn = node.dn, type = node.type, sd = node.sd }
	end
	appendValue(parts, "treeOverrides", tattoos, seen)
	appendValue(parts, "activeSkillSet", build.skillsTab.activeSkillSetId, seen)
	local groups = { }
	for groupIndex, group in ipairs(build.skillsTab.socketGroupList or { }) do
		local groupState = {
			enabled = group.enabled,
			slotEnabled = group.slotEnabled,
			slot = group.slot,
			source = group.source,
			-- PoB XML serializes nil as "nil" then reloads it as false. They have
			-- identical engine semantics here, so canonicalize to avoid a false
			-- source-change signal after a native save/load recovery.
			includeInFullDPS = group.includeInFullDPS == true,
			groupCount = group.groupCount,
			mainActiveSkill = group.mainActiveSkill,
			mainActiveSkillCalcs = group.mainActiveSkillCalcs,
			gems = { },
		}
		for gemIndex, gem in ipairs(group.gemList or { }) do
			groupState.gems[gemIndex] = {
				gemId = gem.gemId,
				skillId = gem.skillId,
				level = gem.level,
				quality = gem.quality,
				enabled = gem.enabled,
				count = gem.count,
				enableGlobal1 = gem.enableGlobal1,
				enableGlobal2 = gem.enableGlobal2,
				skillPart = gem.skillPart,
				skillStageCount = gem.skillStageCount,
				skillMineCount = gem.skillMineCount,
			}
		end
		groups[groupIndex] = groupState
	end
	appendValue(parts, "skillGroups", groups, seen)
	local configTab = build.configTab
	local activeConfigSet = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	appendValue(parts, "activeConfigSetId", configTab and configTab.activeConfigSetId, seen)
	appendValue(parts, "config", activeConfigSet and activeConfigSet.input or configTab and configTab.input, seen)
	appendValue(parts, "configPlaceholder", activeConfigSet and activeConfigSet.placeholder or configTab and configTab.placeholder, seen)
	appendValue(parts, "configCustomMods", activeConfigSet and activeConfigSet.customModsList, seen)
	appendValue(parts, "calcConfig", build.calcsTab and build.calcsTab.input, seen)
	local timelessData = build.timelessData or { }
	appendValue(parts, "timelessSearch", {
		jewelTypeId = timelessData.jewelType and timelessData.jewelType.id,
		conquerorTypeId = timelessData.conquerorType and timelessData.conquerorType.id,
		devotionVariant1 = timelessData.devotionVariant1,
		devotionVariant2 = timelessData.devotionVariant2,
		jewelSocketId = timelessData.jewelSocket and timelessData.jewelSocket.id,
		fallbackWeightMode = timelessData.fallbackWeightMode and timelessData.fallbackWeightMode.idx,
		socketFilter = timelessData.socketFilter == true,
		socketAllocate = timelessData.socketAllocate == true,
		socketFilterDistance = tonumber(timelessData.socketFilterDistance) or 0,
		searchList = tostring(timelessData.searchList or ""),
		searchListFallback = tostring(timelessData.searchListFallback or ""),
	}, seen)

	local itemIds = { }
	local itemSet = build.itemsTab and (build.itemsTab.activeItemSet or build.itemsTab.itemSets[build.itemsTab.activeItemSetId])
	if itemSet then
		appendValue(parts, "activeItemSetId", itemSet.id, seen)
		appendValue(parts, "secondWeaponSet", itemSet.useSecondWeaponSet == true, seen)
		local slotSignatures = { }
		for slotName, slot in pairs(itemSet) do
			if type(slot) == "table" and slot.selItemId and slot.selItemId > 0 then
				itemIds[slot.selItemId] = true
				slotSignatures[#slotSignatures + 1] = "slot=" .. tostring(slotName) .. ":"
					.. tostring(slot.selItemId) .. ":" .. tostring(slot.active)
			end
		end
		t_sort(slotSignatures)
		for _, slotSignature in ipairs(slotSignatures) do
			parts[#parts + 1] = slotSignature
		end
	end
	for _, itemId in pairs(build.spec.jewels) do
		if itemId and itemId > 0 then itemIds[itemId] = true end
	end
	-- Radius-jewel candidates may draw from unassigned items already stored in
	-- ItemsTab. Bind the result to those exact raw items so editing or removing
	-- one while the optimizer yields invalidates the stale candidate.
	local assignedJewelIds = { }
	for _, itemId in pairs(build.spec.jewels or { }) do
		if itemId and itemId > 0 then assignedJewelIds[itemId] = true end
	end
	for itemId, item in pairs(build.itemsTab and build.itemsTab.items or { }) do
		if type(itemId) == "number" and itemId > 0 and not assignedJewelIds[itemId]
			and item and item.type == "Jewel" and item.jewelData
			and ((item.jewelRadiusIndex and not item.jewelData.clusterJewelValid)
				or (item.clusterJewel and item.jewelData.clusterJewelValid)) then
			itemIds[itemId] = true
		end
	end
	local sortedItemIds = { }
	for itemId in pairs(itemIds) do sortedItemIds[#sortedItemIds + 1] = itemId end
	t_sort(sortedItemIds)
	for _, itemId in ipairs(sortedItemIds) do
		local item = build.itemsTab.items[itemId]
		parts[#parts + 1] = "item=" .. tostring(itemId) .. ":" .. tostring(item and item.BuildRaw and item:BuildRaw() or "missing")
	end
	return table.concat(parts, "\31")
end

function candidate.CloneTimelessItem(build, variant)
	local sourceItem = build.itemsTab.items[variant.itemId]
	if not sourceItem or not sourceItem.BuildRaw then
		return nil, "Timeless Jewel source item is unavailable"
	end
	local item = new("Item"):Item(sourceItem:BuildRaw())
	local seedLineFound = false
	for _, modLine in ipairs(item.explicitModLines or { }) do
		if modLine.line and modLine.line:match("%(%-?%d+%.?%d*%-%-?%d+%.?%d*%)") then
			local newLine, replacements = modLine.line:gsub("%(%-?%d+%.?%d*%-%-?%d+%.?%d*%)", tostring(variant.seed), 1)
			if replacements == 0 then break end
			modLine.line = newLine
			modLine.range = nil
			seedLineFound = true
			break
		end
	end
	if not seedLineFound then
		return nil, "This Timeless Jewel has no editable seed line"
	end
	item:BuildAndParseRaw()
	local conqueredBy = item.jewelData and item.jewelData.conqueredBy
	if not conqueredBy or tonumber(conqueredBy.id) ~= variant.seed then
		return nil, "PoB could not reconstruct the requested Timeless Jewel seed"
	end
	item.id = sourceItem.id
	return item
end

function candidate.HasMutation(resultCandidate)
	return not not (resultCandidate and ((resultCandidate.nodeIds and #resultCandidate.nodeIds > 0)
		or (resultCandidate.removeNodeIds and #resultCandidate.removeNodeIds > 0)
		or resultCandidate.classVariant or resultCandidate.ascendancyVariant or resultCandidate.jewelVariant
		or (resultCandidate.jewelVariants and #resultCandidate.jewelVariants > 0)
		or resultCandidate.masteryVariant or resultCandidate.tattooVariant or resultCandidate.timelessVariant or resultCandidate.anointVariant or resultCandidate.anointVariants or resultCandidate.gearVariant or resultCandidate.gemVariant or (type(resultCandidate.gemVariants) == "table" and #resultCandidate.gemVariants > 0) or resultCandidate.configurationVariant) or false)
end

local function validateGemVariants(build, resultCandidate)
	if resultCandidate.gemVariant and resultCandidate.gemVariants then
		return nil, "A candidate cannot mix singular and array gem-variation formats"
	end
	local variants = resultCandidate.gemVariants
	if variants == nil then
		variants = resultCandidate.gemVariant and { resultCandidate.gemVariant } or { }
	end
	if type(variants) ~= "table" then return nil, "Candidate gem variants must be an array" end
	if #variants > 12 then return nil, "A candidate may change at most 12 existing gem slots" end
	for key in pairs(variants) do
		if type(key) ~= "number" or key < 1 or key > #variants or key ~= math.floor(key) then
			return nil, "Candidate gem variants must be a dense array"
		end
	end
	local seenSlots, supportRemoveGroups = { }, { }
	local supportAddCounts, supportGameIds = { }, { }
	for _, variant in ipairs(variants) do
		if type(variant) ~= "table" or type(variant.groupIndex) ~= "number" or variant.groupIndex < 1
			or variant.groupIndex ~= math.floor(variant.groupIndex) or type(variant.gemIndex) ~= "number"
			or variant.gemIndex < 1 or variant.gemIndex ~= math.floor(variant.gemIndex)
			or type(variant.level) ~= "number" or variant.level < 1 or variant.level > 40
			or variant.level ~= math.floor(variant.level) or type(variant.quality) ~= "number"
			or variant.quality < 0 or variant.quality > 30 or variant.quality ~= math.floor(variant.quality) then
			return nil, "Candidate gem variants need valid native slots, level 1–40, and quality 0–30"
		end
		local group = build.skillsTab.socketGroupList[variant.groupIndex]
		if not group then return nil, "The selected skill group no longer exists in the active skill set" end
		local slotKey = tostring(variant.groupIndex) .. ":" .. tostring(variant.gemIndex)
		if seenSlots[slotKey] then return nil, "A candidate cannot change the same gem slot more than once" end
		seenSlots[slotKey] = true
		if variant.gemId ~= nil and (type(variant.gemId) ~= "string" or not (build.data.gems or { })[variant.gemId]) then
			return nil, "Candidate gem ID is not present in PoB's loaded gem data"
		end
		if variant.kind == "support_remove" then
			local gem = group.gemList and group.gemList[variant.gemIndex]
			local gemData = gem and (gem.gemData or (gem.gemId and build.data.gems[gem.gemId]))
			local grantedEffect = gemData and gemData.grantedEffect
			local secondaryEffect = gemData and gemData.secondaryGrantedEffect
			local isSupport = (grantedEffect and grantedEffect.support and not grantedEffect.unsupported)
				or (secondaryEffect and secondaryEffect.support and not secondaryEffect.unsupported)
			if not gem or gem.enabled ~= false or not isSupport then
				return nil, "Only an existing disabled native support gem can be removed from a socket-repair route"
			end
			if variant.gemId and variant.gemId ~= (gem.gemId or (gemData and gemData.id))
				or variant.skillId and variant.skillId ~= (gem.skillId or (gemData and gemData.grantedEffectId)) then
				return nil, "The disabled-support removal no longer matches the selected PoB gem slot"
			end
			supportRemoveGroups[variant.groupIndex] = true
		elseif variant.kind == "support_add" then
			local expectedGemIndex = #(group.gemList or { }) + (supportAddCounts[variant.groupIndex] or 0) + 1
			if variant.gemIndex ~= expectedGemIndex then
				return nil, "Support additions must fill the next PoB gem slot without gaps"
			end
			local gemData = build.data.gems[variant.gemId]
			local effect = gemData and (gemData.grantedEffect and gemData.grantedEffect.support
				and not gemData.grantedEffect.unsupported and gemData.grantedEffect
				or gemData.secondaryGrantedEffect and gemData.secondaryGrantedEffect.support
				and not gemData.secondaryGrantedEffect.unsupported and gemData.secondaryGrantedEffect)
			if not effect or not gemData.grantedEffectId then
				return nil, "Support addition must use a supported support gem from PoB's loaded gem database"
			end
			local hasActiveSkill = false
			for _, activeSkill in ipairs(group.displaySkillList or { }) do
				if activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
					and not activeSkill.activeEffect.grantedEffect.support then
					hasActiveSkill = true
					break
				end
			end
			if not hasActiveSkill then return nil, "A support can only be added to a PoB group with an active skill" end
			supportGameIds[variant.groupIndex] = supportGameIds[variant.groupIndex] or { }
			for _, sourceGem in ipairs(group.gemList or { }) do
				local sourceData = sourceGem.gemData
				if sourceData and (sourceData.grantedEffect and sourceData.grantedEffect.support
					or sourceData.secondaryGrantedEffect and sourceData.secondaryGrantedEffect.support) then
					if sourceData.gameId then supportGameIds[variant.groupIndex][sourceData.gameId] = true end
				end
			end
			if supportGameIds[variant.groupIndex][gemData.gameId] then
				return nil, "A support gem already present in this PoB group cannot be added again"
			end
			local socketValid, socketError = SkillCatalog.CanAddSupportAtSlot(build,
				variant.groupIndex, variant.gemIndex, gemData, supportAddCounts[variant.groupIndex] or 0)
			if not socketValid then return nil, socketError end
			supportGameIds[variant.groupIndex][gemData.gameId] = true
			supportAddCounts[variant.groupIndex] = (supportAddCounts[variant.groupIndex] or 0) + 1
		elseif not group.gemList or not group.gemList[variant.gemIndex] then
			return nil, "The selected gem no longer exists in the active skill set"
		end
		if variant.kind == "selected_main_skill" then
			local gemData = build.data.gems[variant.gemId]
			local canReplace, replaceError = SkillCatalog.CanReplaceGemAtSlot(build,
				variant.groupIndex, variant.gemIndex, gemData, {
					allowUnlinkedPlanning = resultCandidate.unlinkedMainSkillPlan == true
						and (resultCandidate.generationPhase == "skills" or resultCandidate.generationPhase == "tree"),
				})
			if not canReplace then return nil, replaceError end
			local activeIndex = SkillCatalog.ResolveMainSkillIndex({ gemList = {
				{ enabled = true, gemData = gemData, grantedEffect = gemData.grantedEffect,
					enableGlobal1 = true, enableGlobal2 = true },
			} }, 1, variant.skillId)
			if not activeIndex then
				return nil, "Selected Main Skill effect is not an active effect in PoB's loaded gem data"
			end
		end
	end
	for groupIndex in pairs(supportRemoveGroups) do
		if (supportAddCounts[groupIndex] or 0) > 0 then
			return nil, "A socket-repair route cannot add a support to the same group while removing an inactive support"
		end
	end
	return variants
end

local function prepareSkillSetVariation(build, variants, socketBinding)
	if #variants == 0 and not socketBinding then return nil end
	local skillsTab = build.skillsTab
	if type(skillsTab.CreateUndoState) ~= "function" or type(skillsTab.RestoreUndoState) ~= "function"
		or type(skillsTab.ProcessSocketGroup) ~= "function" or type(skillsTab.UpdateSocketGroups) ~= "function"
		or type(skillsTab.AddUndoState) ~= "function" then
		return nil, "PoB's native skill-set variation APIs are unavailable"
	end
	local sourceState = skillsTab:CreateUndoState()
	local state = shallowCopy(sourceState)
	state.skillSets = shallowCopy(sourceState.skillSets)
	state.skillSetOrderList = shallowCopy(sourceState.skillSetOrderList)
	local sourceSetId = sourceState.activeSkillSetId
	local sourceSet = sourceState.skillSets[sourceSetId]
	if not sourceSet then return nil, "The source skill set no longer exists" end
	local newSet = copyTable(sourceSet, true)
	newSet.socketGroupList = { }
	for groupIndex, sourceGroup in ipairs(sourceSet.socketGroupList or { }) do
		local groupCopy = copyTable(sourceGroup, true)
		groupCopy.gemList = { }
		for gemIndex, sourceGem in ipairs(sourceGroup.gemList or { }) do
			groupCopy.gemList[gemIndex] = copyTable(sourceGem, true)
		end
		newSet.socketGroupList[groupIndex] = groupCopy
	end
	local changedGroups, supportRemoveIndices = { }, { }
	local supportAddCounts, supportAddBaseCounts = { }, { }
	if socketBinding then
		local group = newSet.socketGroupList[socketBinding.groupIndex]
		if not group or group.source or type(socketBinding.slotName) ~= "string" or socketBinding.slotName == "" then
			return nil, "The selected Main Skill cannot be bound to this equipment socket group"
		end
		group.slot = socketBinding.slotName
		group.slotEnabled = true
		if type(group.label) == "string" then
			local base, count = group.label:gsub("%s*%(%s*unlinked%s*%)$", "")
			if count > 0 then
				local suffix = " (linked: " .. socketBinding.slotName .. ")"
				if #base + #suffix > 100 then suffix = " (linked)" end
				group.label = base .. suffix
			end
		end
		changedGroups[socketBinding.groupIndex] = true
	end
	for _, variant in ipairs(variants) do
		local group = newSet.socketGroupList[variant.groupIndex]
		if variant.kind == "support_remove" then
			if not group or not group.gemList[variant.gemIndex] then
				return nil, "The disabled support gem no longer exists in the active skill set"
			end
			supportRemoveIndices[variant.groupIndex] = supportRemoveIndices[variant.groupIndex] or { }
			supportRemoveIndices[variant.groupIndex][#supportRemoveIndices[variant.groupIndex] + 1] = variant.gemIndex
			changedGroups[variant.groupIndex] = true
		elseif variant.kind == "support_add" then
			if group and supportAddBaseCounts[variant.groupIndex] == nil then
				supportAddBaseCounts[variant.groupIndex] = #group.gemList
			end
			local expectedGemIndex = (supportAddBaseCounts[variant.groupIndex] or 0)
				+ (supportAddCounts[variant.groupIndex] or 0) + 1
			if not group or variant.gemIndex ~= expectedGemIndex then
				return nil, "PoB support additions no longer match the next available gem slots"
			end
			local gemData = build.data.gems[variant.gemId]
			if not gemData then return nil, "The selected support gem is no longer present in PoB's loaded database" end
			group.gemList[variant.gemIndex] = {
				gemId = gemData.id,
				skillId = gemData.grantedEffectId,
				nameSpec = gemData.name,
				level = variant.level,
				quality = variant.quality,
				enabled = true,
				enableGlobal1 = true,
				enableGlobal2 = true,
				count = 1,
			}
			supportAddCounts[variant.groupIndex] = (supportAddCounts[variant.groupIndex] or 0) + 1
		else
			local gem = group and group.gemList[variant.gemIndex]
			if not gem then return nil, "The selected gem no longer exists in the active skill set" end
			gem.level = variant.level
			gem.quality = variant.quality
			if variant.gemId then
				local gemData = build.data.gems[variant.gemId]
				if not gemData then return nil, "The selected gem is no longer present in PoB's loaded database" end
			gem.gemId = gemData.id
			gem.skillId = gemData.grantedEffectId
			gem.nameSpec = gemData.name
			-- Match SkillsTab's native gem-selection behavior: let the new gem data
			-- establish its own default-level context before native level validation.
			gem.gemData = gemData
			gem.grantedEffect = gemData.grantedEffect
			end
		end
		changedGroups[variant.groupIndex] = true
	end
	for groupIndex, indices in pairs(supportRemoveIndices) do
		local group = newSet.socketGroupList[groupIndex]
		t_sort(indices, function(a, b) return a > b end)
		for _, index in ipairs(indices) do
			-- PoB's mainActiveSkill fields index active skill effects, not gemList
			-- slots. Removing a disabled support does not alter either selector.
			table.remove(group.gemList, index)
		end
	end
	local nextSetId = 1
	while state.skillSets[nextSetId] do nextSetId = nextSetId + 1 end
	newSet.id = nextSetId
	newSet.title = "Optimizer result " .. tostring(#state.skillSetOrderList + 1)
	local nativeTab = shallowCopy(skillsTab)
	setmetatable(nativeTab, getmetatable(skillsTab))
	nativeTab.build = build
	nativeTab.socketGroupList = newSet.socketGroupList
	local ok, err = pcall(function()
		for groupIndex in pairs(changedGroups) do nativeTab:ProcessSocketGroup(newSet.socketGroupList[groupIndex]) end
		nativeTab:UpdateSocketGroups()
		for _, variant in ipairs(variants) do
			if variant.kind == "selected_main_skill" then
				local group = newSet.socketGroupList[variant.groupIndex]
				local activeSkillIndex = SkillCatalog.ResolveMainSkillIndex(group, variant.gemIndex, variant.skillId)
				if not activeSkillIndex then
					error("PoB could not resolve the selected Main Skill in the new skill-set variation")
				end
				group.mainActiveSkill = activeSkillIndex
				group.mainActiveSkillCalcs = activeSkillIndex
				state.activeSocketGroup = variant.groupIndex
				-- CalcsTab.input.skill_number is a socket-group index, not an
				-- active-effect index. Keep the CALCS selector aligned with the
				-- selected Main Skill group; the effect index lives on the group.
				state.activeSocketGroup2 = variant.groupIndex
			end
		end
	end)
	if not ok then return nil, "PoB could not process the selected gem variation: " .. tostring(err) end
	state.skillSets[nextSetId] = newSet
	state.skillSetOrderList[#state.skillSetOrderList + 1] = nextSetId
	state.activeSkillSetId = nextSetId
	return state, nil, sourceState
end

local hitAverageMetrics = {
	"PhysicalHitAverage", "FireHitAverage", "ColdHitAverage", "LightningHitAverage", "ChaosHitAverage",
}

local function exactHitAverage(output, key, activeSkill)
	local mainHand = type(output.MainHand) == "table" and output.MainHand[key] or nil
	local offHand = type(output.OffHand) == "table" and output.OffHand[key] or nil
	if isFinite(mainHand) and isFinite(offHand) then
		-- Match CalcOffence.combineStat("AverageDamage", "DPS"): dual-wield
		-- skills that hit with both weapons at once add the hand values; ordinary
		-- dual-wield attacks alternate hands and average them.
		local skillData = activeSkill and activeSkill.skillData
		if skillData and skillData.doubleHitsWhenDualWielding == true then return mainHand + offHand end
		return (mainHand + offHand) / 2
	end
	if isFinite(mainHand) then return mainHand end
	if isFinite(offHand) then return offHand end
	return output[key]
end

function candidate.CopyMetrics(output, definitions, activeSkill)
	local metrics = { }
	for _, definition in ipairs(definitions) do
		local value = output and output[definition.outputKey or definition.metricKey or definition.key]
		if isFinite(value) then
			metrics[definition.metricKey or definition.key] = value
		end
	end
	if output then
		for _, key in ipairs({ "Str", "Dex", "Int", "Omni", "ReqStr", "ReqDex", "ReqInt", "ReqOmni", "ReqLevel" }) do
			if isFinite(output[key]) then metrics[key] = output[key] end
		end
		for _, key in ipairs({ "SkillDPS", "TotalDPS", "TotalDotDPS", "FullDPS", "FullDotDPS", "Life", "LifeReserved", "LifeReservedPercent", "LifeUnreserved", "LifeUnreservedPercent", "LifeRecoverable", "LifeRegenRecovery", "LifePerSecondCost", "LifeLeechRate", "LifeLeechGainRate", "LifeRecoupRecoveryAvg", "Mana", "ManaReserved", "ManaReservedPercent", "ManaUnreserved", "ManaUnreservedPercent", "ManaRegenRecovery", "ManaPerSecondCost", "ManaCostPayablePool", "ManaLeechRate", "ManaLeechGainRate", "ManaRecoupRecoveryAvg", "EnergyShield", "EnergyShieldRegenRecovery", "ESPerSecondCost", "EnergyShieldLeechRate", "EnergyShieldLeechGainRate", "EnergyShieldRecoupRecoveryAvg", "Ward", "ImpaleDPS", "BleedDPS", "PoisonDPS", "PhysicalHitAverage", "FireHitAverage", "ColdHitAverage", "LightningHitAverage", "ChaosHitAverage", "Armour", "Evasion", "TriggerRateCap", "SkillTriggerRate" }) do
			if isFinite(output[key]) then metrics[key] = output[key] end
		end
		for _, key in ipairs(hitAverageMetrics) do
			local value = exactHitAverage(output, key, activeSkill)
			if isFinite(value) then metrics[key] = value end
		end
		-- These are regen-only, exact-output checks for the selected main skill.
		-- They deliberately exclude leech/on-hit recovery (exposed separately
		-- above), flasks, and ES recharge. A negative value is not proof that a
		-- hit-based build cannot sustain its skill; it means regen alone is short.
		local lifeRegen = output.NetLifeRegen or output.LifeRegenRecovery
		local lifeCost = output.LifePerSecondCost or 0
		if isFinite(lifeRegen) and isFinite(lifeCost) then
			metrics.LifeSustainMargin = lifeRegen - lifeCost
		end
		local manaMargin
		local manaCost = output.ManaPerSecondCost or 0
		local esCost = output.ESPerSecondCost or 0
		if esCost > 0 then
			local esRegen = output.NetEnergyShieldRegen or output.EnergyShieldRegenRecovery
			if isFinite(esRegen) and isFinite(esCost) then
				manaMargin = esRegen - esCost
			end
		else
			local manaRegen = output.NetManaRegen or output.ManaRegenRecovery
			if isFinite(manaRegen) and isFinite(manaCost) then
				manaMargin = manaRegen - manaCost
			end
		end
		-- If both pools pay recurring costs, the weaker regen-only margin is the
		-- limiting pool. It is not a full combat-sustain proof.
		local manaRegen = output.NetManaRegen or output.ManaRegenRecovery
		if esCost > 0 and manaCost > 0 and isFinite(manaRegen) and isFinite(manaCost) then
			manaMargin = math.min(manaMargin or math.huge, manaRegen - manaCost)
		end
		if isFinite(manaMargin) then metrics.ManaSustainMargin = manaMargin end
	end
	return metrics
end

function candidate.CopySkillDPS(output)
	local skills = { }
	local truncated = false
	for index, skill in ipairs(output and output.SkillDPS or { }) do
		if index > 64 then
			truncated = true
			break
		end
		skills[#skills + 1] = {
			name = tostring(skill.name or ""):sub(1, 120),
			dps = isFinite(skill.dps) and skill.dps or nil,
			count = isFinite(skill.count) and skill.count or nil,
			trigger = skill.trigger and tostring(skill.trigger):sub(1, 120) or nil,
			skillPart = skill.skillPart and tostring(skill.skillPart):sub(1, 120) or nil,
			source = skill.source and tostring(skill.source):sub(1, 120) or nil,
		}
	end
	return skills, truncated
end

function candidate.CopySkillEntityLimits(output)
	local limits = { }
	local truncated = false
	for index, entity in ipairs(output and output.SkillEntityLimits or { }) do
		if index > 64 then
			truncated = true
			break
		end
		limits[#limits + 1] = {
			name = tostring(entity.name or "Unknown skill"):sub(1, 120),
			entityType = (entity.entityType == "ballista" or entity.entityType == "minion") and entity.entityType or "totem",
			count = isFinite(entity.count) and entity.count or nil,
			limit = isFinite(entity.limit) and entity.limit or nil,
			limitKey = entity.limitKey and tostring(entity.limitKey):sub(1, 120) or nil,
			group = tostring(entity.group or ""):sub(1, 80),
		}
	end
	return limits, truncated
end

-- Build an isolated PassiveSpec through PoB's own allocation APIs. DeallocNode
-- removes every node whose only route depended on the removed node; AllocNode
-- repairs each requested addition along a valid path from the selected starts.
function candidate.BuildPassiveSpec(build, addNodeIds, removeNodeIds, variants)
	local sourceSpec = build and build.spec
	if not sourceSpec or not sourceSpec.CreateUndoState then return nil, "The source passive spec cannot be cloned" end
	variants = variants or { }
	local selectedJewelVariants = jewelVariants(variants)
	local gearVariant = variants.gearVariant or { }
	local gearOverrides = gearVariant.overrides or { }
	local anointVariants = variants.anointVariants or variants.anointVariant
	if anointVariants then
		local list = type(anointVariants) == "table" and anointVariants.nodeId and { anointVariants } or anointVariants
		for _, anoint in ipairs(list or { }) do
			if gearOverrides[anoint.slotName] then
				return nil, "The selected equipment item and anoint both target " .. tostring(anoint.slotName) .. "; choose one item state per slot"
			end
		end
	end
	local jewelsValid, jewelsError = validateJewelVariants(selectedJewelVariants)
	if not jewelsValid then return nil, jewelsError end
	for _, variant in ipairs(selectedJewelVariants) do
		local socket = sourceSpec.nodes[variant.toNodeId]
		local item = build.itemsTab and build.itemsTab.items and build.itemsTab.items[variant.itemId]
		if socket and socket.type ~= "Socket" then return nil, "A candidate jewel destination is not a native PoB socket" end
		if not socket and variant.sourceKind ~= "cluster" then
			return nil, "Only native Cluster Jewel candidates may target a generated cluster socket"
		end
		if not item or not item.jewelData then return nil, "A candidate jewel item is not available in the active PoB item list" end
		if variant.fromNodeId and variant.fromNodeId > 0 then
			local sourceSocket = sourceSpec.nodes[variant.fromNodeId]
			if not sourceSocket or sourceSocket.type ~= "Socket" then return nil, "A candidate jewel source is not a native PoB socket" end
		end
	end
	local itemsTabProxy = shallowCopy(build.itemsTab)
	-- CalcSetup invokes ItemsTab methods on the build while it assembles
	-- calculator warnings. The proxy owns an isolated item map but must retain
	-- the native class methods so candidate evaluation follows the normal PoB path.
	setmetatable(itemsTabProxy, getmetatable(build.itemsTab))
	itemsTabProxy.items = shallowCopy(build.itemsTab and build.itemsTab.items)
	if #(gearVariant.generatedItems or { }) > 0 then
		local installed, installError, itemIdRemap = SyntheticGear.InstallIntoItemsTab(itemsTabProxy, gearVariant.generatedItems)
		if not installed then return nil, installError end
		if itemIdRemap and next(itemIdRemap) then
			gearVariant = SyntheticGear.RemapVariantIds(gearVariant, itemIdRemap)
			variants.gearVariant = gearVariant
			gearOverrides = gearVariant.overrides or { }
		end
	end
	if next(gearOverrides) then
		gearVariant = Equipment.NormalizeWeaponHandConflicts(build, gearVariant, itemsTabProxy)
		variants.gearVariant = gearVariant
		gearOverrides = gearVariant.overrides or { }
		SyntheticGear.RefreshDescription({ itemsTab = itemsTabProxy }, gearVariant)
	end
	local cloneJewelIds = { }
	for _, itemId in pairs(sourceSpec.jewels or { }) do
		if itemId and itemId > 0 then cloneJewelIds[itemId] = true end
	end
	for _, variant in ipairs(selectedJewelVariants) do cloneJewelIds[variant.itemId] = true end
	for itemId in pairs(cloneJewelIds) do
		local item = itemsTabProxy.items[itemId]
		if item and item.jewelData then
			local itemCopy = shallowCopy(item)
			itemCopy.jewelData = shallowCopy(item.jewelData)
			itemCopy.jewelData.limitDisabled = nil
			itemCopy.jewelRadiusData = item.jewelRadiusData and copyTable(item.jewelRadiusData, true) or nil
			setmetatable(itemCopy, getmetatable(item))
			itemsTabProxy.items[itemId] = itemCopy
		end
	end
	local specBuild = shallowCopy(build)
	-- A calculation proxy may inherit shared PoB registries (including `data`)
	-- through its metatable. PassiveSpec:BuildClusterJewelGraphs reads those
	-- registries from build.data, so retain the proxy lookup chain in the isolated
	-- build snapshot instead of silently dropping inherited engine state.
	setmetatable(specBuild, getmetatable(build))
	specBuild.itemsTab = itemsTabProxy
	specBuild.treeTab = shallowCopy(build.treeTab)
	specBuild.treeTab.viewer = shallowCopy(build.treeTab and build.treeTab.viewer)
	local proxy = new("PassiveSpec"):PassiveSpec(specBuild, sourceSpec.treeVersion)
	specBuild.spec = proxy
	itemsTabProxy.build = specBuild
	local state = sourceSpec:CreateUndoState()
	state.hashList = state.hashList or { }
	state.hashOverrides = state.hashOverrides or { }
	state.masteryEffects = state.masteryEffects or { }
	state.jewels = shallowCopy(sourceSpec.jewels)
	if variants.classId ~= nil then
		if not sourceSpec.tree.classes[variants.classId] then
			return nil, "The requested base class is unavailable in this passive-tree version"
		end
		state.classId = variants.classId
		state.ascendClassId = 0
		state.secondaryAscendClassId = 0
		state.hashList = { }
		state.hashOverrides = { }
		state.masteryEffects = { }
		state.jewels = { }
	end
	local ascendancyVariant = variants.ascendancyVariant
	if not ascendancyVariant and variants.ascendClassId ~= nil then
		ascendancyVariant = {
			ascendClassId = variants.ascendClassId,
			secondaryAscendClassId = variants.secondaryAscendClassId,
		}
	end
	if ascendancyVariant then
		local classId = state.classId
		local class = sourceSpec.tree.classes[classId]
		local ascendClassId = tonumber(ascendancyVariant.ascendClassId)
		local secondaryAscendClassId = tonumber(ascendancyVariant.secondaryAscendClassId)
		if secondaryAscendClassId == nil then secondaryAscendClassId = state.secondaryAscendClassId or 0 end
		if not class or not ascendClassId or ascendClassId < 0 or ascendClassId ~= math.floor(ascendClassId) or not class.classes[ascendClassId] then
			return nil, "The requested main ascendancy is unavailable for this PoB class and tree version"
		end
		if secondaryAscendClassId < 0 or secondaryAscendClassId ~= math.floor(secondaryAscendClassId)
			or (secondaryAscendClassId ~= 0 and not (sourceSpec.tree.alternate_ascendancies or { })[secondaryAscendClassId]) then
			return nil, "The requested secondary ascendancy is unavailable in this PoB tree version"
		end
		if not sourceSpec.tree.alternate_ascendancies and secondaryAscendClassId ~= 0 then
			return nil, "This PoB tree version does not support a secondary ascendancy"
		end
		state.ascendClassId = ascendClassId
		state.secondaryAscendClassId = secondaryAscendClassId
		if variants.classId == nil then
			state.hashList = filterUnselectedAscendancyNodes(state.hashList, sourceSpec, classId, ascendClassId, secondaryAscendClassId)
		end
	end
	if variants.masteryVariant then
		state.masteryEffects[variants.masteryVariant.nodeId] = variants.masteryVariant.effectId
	end
	if variants.tattooVariant then
		local tattoo = sourceSpec.tree.tattoo and sourceSpec.tree.tattoo.nodes[variants.tattooVariant.tattooId]
		if not tattoo then return nil, "The selected tattoo is unavailable in this passive-tree version" end
		local tattooCopy = copyTable(tattoo, true)
		tattooCopy.id = variants.tattooVariant.nodeId
		state.hashOverrides[variants.tattooVariant.nodeId] = tattooCopy
	end
	if variants.timelessVariant then
		local timelessItem, err = candidate.CloneTimelessItem(build, variants.timelessVariant)
		if not timelessItem then return nil, err end
		-- Keep the existing item ID in the private ItemsTab; no active build item is changed.
		timelessItem.id = variants.timelessVariant.itemId
		itemsTabProxy.items[timelessItem.id] = timelessItem
		state.jewels[variants.timelessVariant.nodeId] = timelessItem.id
	end
	if variants.anointVariant or variants.anointVariants then
		local anointVariants = variants.anointVariants or variants.anointVariant
		local anointedItem, err = Anoints.CloneItemVariants(build, anointVariants, removeNodeIds)
		if not anointedItem then return nil, err end
		-- Same item ID is safe only inside this isolated ItemsTab snapshot.
		itemsTabProxy.items[anointedItem.id] = anointedItem
	end
	-- PoB rebuilds nested cluster graphs while importing allocated subgraph node
	-- IDs. Include newly generated path nodes before import so a child socket is
	-- allocated during the parent's native BuildSubgraph recursion; adding them
	-- only afterward would leave the child graph absent from the projection.
	local hasClusterVariant = false
	for _, variant in ipairs(selectedJewelVariants) do
		if variant.sourceKind == "cluster" then hasClusterVariant = true break end
	end
	if hasClusterVariant then
		local importedNodeIds = { }
		for _, nodeId in ipairs(state.hashList) do importedNodeIds[nodeId] = true end
		for _, nodeId in ipairs(addNodeIds or { }) do
			if not sourceSpec.nodes[nodeId] and not importedNodeIds[nodeId] then
				state.hashList[#state.hashList + 1] = nodeId
				importedNodeIds[nodeId] = true
			end
		end
	end
	for _, variant in ipairs(selectedJewelVariants) do
		if variant.fromNodeId and variant.fromNodeId > 0 then
			state.jewels[variant.fromNodeId] = variant.targetItemId > 0 and variant.targetItemId or nil
		end
		state.jewels[variant.toNodeId] = variant.itemId
	end
	proxy.jewels = shallowCopy(state.jewels)
	proxy:ImportFromNodeList(nil, state.classId, state.ascendClassId, state.secondaryAscendClassId, state.hashList, state.hashOverrides, state.masteryEffects, state.treeVersion)
	proxy.jewels = shallowCopy(state.jewels)
	proxy:BuildClusterJewelGraphs()
	if next(gearOverrides) then
		local equipmentValid, equipmentError, equipmentSet = Equipment.Validate(specBuild, gearOverrides, itemsTabProxy)
		if not equipmentValid then return nil, equipmentError end
		Equipment.InstallIsolatedSet(itemsTabProxy, equipmentSet)
	end
	if #selectedJewelVariants > 0 then
		local placementsValid, placementError = validateProjectedJewelVariants(sourceSpec, proxy, itemsTabProxy, selectedJewelVariants)
		if not placementsValid then return nil, placementError end
	end

	for _, nodeId in ipairs(removeNodeIds or { }) do
		local node = proxy.allocNodes[nodeId]
		if node then
			if node.type == "ClassStart" or node.type == "AscendClassStart" then
				return nil, "PoB class and ascendancy start nodes cannot be removed as passive mutations"
			end
			proxy:DeallocNode(node)
		end
	end
	for _, nodeId in ipairs(addNodeIds or { }) do
		local node = proxy.nodes[nodeId]
		if not node then return nil, "Passive node is unavailable in the active PoB tree: " .. tostring(nodeId) end
		if node.type == "ClassStart" or node.type == "AscendClassStart" then
			return nil, "PoB class and ascendancy start nodes are selected through the class controls"
		end
		if not proxy.allocNodes[nodeId] then
			if not node.path then return nil, "Passive node is not reachable from the selected PoB starts: " .. tostring(nodeId) end
			proxy:AllocNode(node)
			if not proxy.allocNodes[nodeId] then return nil, "PoB could not allocate the requested passive node: " .. tostring(nodeId) end
		end
	end
	local requestedAnoints = variants.anointVariants or (variants.anointVariant and { variants.anointVariant }) or { }
	for _, anointVariant in ipairs(requestedAnoints) do
		if proxy.allocNodes[tonumber(anointVariant.nodeId)] then
			return nil, "The anointed notable remains allocated on the candidate passive tree and cannot refund its point"
		end
	end
	-- Node allocation can make several requested route nodes redundant and deallocation
	-- can remove dependent nodes. Return the exact final tree diff used by the PoB engine.
	local addedNodeIds, removedNodeIds = { }, { }
	local sourceIds, sourceLease = pool.Acquire("passiveDiff")
	local projectedIds, projectedLease = pool.Acquire("passiveDiff")
	for nodeId in pairs(sourceSpec.allocNodes) do sourceIds[nodeId] = true end
	for nodeId in pairs(proxy.allocNodes) do projectedIds[nodeId] = true end
	for nodeId in pairs(proxy.allocNodes) do
		local node = proxy.allocNodes[nodeId]
		if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not sourceIds[nodeId] then
			addedNodeIds[#addedNodeIds + 1] = nodeId
		end
	end
	for nodeId in pairs(sourceSpec.allocNodes) do
		local node = sourceSpec.allocNodes[nodeId]
		if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not projectedIds[nodeId] then
			removedNodeIds[#removedNodeIds + 1] = nodeId
		end
	end
	t_sort(addedNodeIds)
	t_sort(removedNodeIds)
	pool.Release("passiveDiff", sourceIds, sourceLease)
	pool.Release("passiveDiff", projectedIds, projectedLease)
	proxy.optimizerAddedNodeIds = addedNodeIds
	proxy.optimizerRemovedNodeIds = removedNodeIds
	return proxy, nil, itemsTabProxy, variants.gearVariant
end

local function remapEvaluationSocketProofs(evaluation, itemIdRemap)
	if type(evaluation) ~= "table" or type(itemIdRemap) ~= "table" then return end
	local function remapSocket(socketInfo)
		if type(socketInfo) ~= "table" then return end
		local itemId = tonumber(socketInfo.itemId)
		local mapped = itemId and (itemIdRemap[itemId] or itemIdRemap[tostring(itemId)])
		if mapped then socketInfo.itemId = tonumber(mapped) or mapped end
	end
	remapSocket(evaluation.skillSocket)
	local proof = evaluation.skillGroupSockets
	for _, group in ipairs(type(proof) == "table" and proof.groups or { }) do
		remapSocket(group.group)
	end
	local variantProof = evaluation.skillVariantSocketProofs
	for _, group in ipairs(type(variantProof) == "table" and variantProof.groups or { }) do
		remapSocket(group.group)
	end
	local routePlannerProof = evaluation.routePlannerSocketProofs
	for _, group in ipairs(type(routePlannerProof) == "table" and routePlannerProof.groups or { }) do
		remapSocket(group.group)
	end
end

local function isExactUnlinkedSkillCheckpoint(build, resultCandidate, resultGemVariants)
	if type(resultCandidate) ~= "table" or resultCandidate.unlinkedMainSkillPlan ~= true
		or resultCandidate.generationPhase ~= "skills" or resultCandidate.requiresSocketedMainSkill == true
		or type(resultCandidate.evaluation) ~= "table" or resultCandidate.evaluation.exactCalculated ~= true
		or resultCandidate.evaluation.routePlannerSearchMode ~= nil
		or resultCandidate.gearVariant ~= nil or resultCandidate.configurationVariant ~= nil
		or resultCandidate.jewelVariant ~= nil or resultCandidate.jewelVariants ~= nil
		or resultCandidate.anointVariant ~= nil or resultCandidate.anointVariants ~= nil
		or resultCandidate.timelessVariant ~= nil or resultCandidate.timelessVariants ~= nil
		or resultCandidate.tattooVariant ~= nil or resultCandidate.classVariant ~= nil
		or resultCandidate.ascendancyVariant ~= nil or resultCandidate.clusterVariant ~= nil
		or #(resultCandidate.nodeIds or { }) > 0 or #(resultCandidate.removeNodeIds or { }) > 0
		or type(resultGemVariants) ~= "table" or #resultGemVariants ~= 1 then
		return false
	end
	local variant = resultGemVariants[1]
	local groupIndex = type(variant) == "table" and tonumber(variant.groupIndex) or nil
	local gemIndex = type(variant) == "table" and tonumber(variant.gemIndex) or nil
	if not groupIndex or groupIndex < 1 or groupIndex ~= math.floor(groupIndex)
		or not gemIndex or gemIndex < 1 or gemIndex ~= math.floor(gemIndex)
		or variant.kind ~= "selected_main_skill" then
		return false
	end
	local group = build and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	local sourceGem = group and group.gemList and group.gemList[gemIndex]
	if not group or not sourceGem or group.source or (type(group.slot) == "string" and group.slot ~= "")
		or group.enabled == false or group.slotEnabled == false
		or not (sourceGem.gemData or sourceGem.grantedEffect) then
		return false
	end
	local expectedSkillId = SkillCatalog.ResolveTargetEffectId(build, groupIndex,
		type(group.mainActiveSkill) == "number" and group.mainActiveSkill or 1, variant.gemId)
	if expectedSkillId ~= variant.skillId then return false end
	local proof = resultCandidate.evaluation.skillVariantSocketProofs
	local unlinked = type(proof) == "table" and proof.unlinkedGroup or nil
	if type(proof) ~= "table" or proof.status ~= "unlinked_planning"
		or proof.scope ~= "selected_main_skill_checkpoint"
		or type(proof.groups) ~= "table" or #proof.groups ~= 0
		or type(proof.violations) ~= "table" or #proof.violations ~= 0
		or type(unlinked) ~= "table" or tonumber(unlinked.groupIndex) ~= groupIndex
		or tonumber(unlinked.gemIndex) ~= gemIndex or unlinked.gemId ~= variant.gemId
		or unlinked.skillId ~= variant.skillId then
		return false
	end
	return true
end

function candidate.Apply(build, resultCandidate)
	if not resultCandidate or not resultCandidate.feasible then
		return false, "Only a candidate that passed every strict gate can be applied"
	end
	if not resultCandidate.sourceSignature or resultCandidate.sourceSignature ~= candidate.BuildSignature(build) then
		return false, "The build changed after this result was calculated; run the optimizer again"
	end
	local resultGemVariants, gemVariantError = validateGemVariants(build, resultCandidate)
	if not resultGemVariants then return false, gemVariantError end
	if not candidate.HasMutation(resultCandidate) then
		return true, "Current build already satisfies the selected constraints; no variation is needed"
	end
	local skillUndoCheckpointExists = type(build.skillsTab.undo) == "table" and build.skillsTab.undo[1] ~= nil
	if resultCandidate.configurationVariant then
		local valid, validationError = ConfigurationChoices.Validate(resultCandidate.configurationVariant)
		if not valid then return false, validationError end
		local configTab = build.configTab
		local activeSet = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
		if not activeSet or type(activeSet.input) ~= "table" or type(configTab.NewConfigSet) ~= "function"
			or type(configTab.SetActiveConfigSet) ~= "function" or type(configTab.configSetOrderList) ~= "table" then
			return false, "The active PoB configuration cannot create a reversible optimizer variation"
		end
	end
	if resultCandidate.tattooVariant and not build.spec.tree.tattoo.nodes[resultCandidate.tattooVariant.tattooId] then
		return false, "The selected tattoo no longer exists in this passive-tree version"
	end
	local timelessItem
	if resultCandidate.timelessVariant then
		local message
		timelessItem, message = candidate.CloneTimelessItem(build, resultCandidate.timelessVariant)
		if not timelessItem then return false, message end
	end
	local anointedItem
	local anointVariants = resultCandidate.anointVariants or resultCandidate.anointVariant
	if anointVariants then
		local message
		anointedItem, message = Anoints.CloneItemVariants(build, anointVariants, resultCandidate.removeNodeIds)
		if not anointedItem then return false, message end
	end
	local gearVariant = resultCandidate.gearVariant or { }
	local gearOverrides = gearVariant.overrides or { }
	local socketBinding = gearVariant.socketBinding
	local generatedItems = gearVariant.generatedItems or { }
	local gearValidationTab
	local finalGearSet
	if #generatedItems > 0 then
		local validationError
		local itemIdRemap
		gearValidationTab, validationError, itemIdRemap = SyntheticGear.CreateValidationTab(build.itemsTab, generatedItems)
		if not gearValidationTab then return false, validationError end
		if itemIdRemap and next(itemIdRemap) then
			gearVariant = SyntheticGear.RemapVariantIds(gearVariant, itemIdRemap)
			resultCandidate.gearVariant = gearVariant
			remapEvaluationSocketProofs(resultCandidate.evaluation, itemIdRemap)
			gearOverrides = gearVariant.overrides or { }
			socketBinding = gearVariant.socketBinding
			generatedItems = gearVariant.generatedItems or { }
		end
	end
	if next(gearOverrides) then
		local equipmentValid, equipmentError, evaluatedSet = Equipment.Validate(build, gearOverrides, gearValidationTab)
		if not equipmentValid then return false, equipmentError end
		finalGearSet = evaluatedSet
		if anointVariants then
			local list = type(anointVariants) == "table" and anointVariants.nodeId and { anointVariants } or anointVariants
			for _, anoint in ipairs(list or { }) do
				if gearOverrides[anoint.slotName] then
					return false, "The selected equipment item and anoint both target " .. tostring(anoint.slotName)
				end
			end
		end
	end
	local skillSetState, skillSetError, originalSkillState = prepareSkillSetVariation(build, resultGemVariants, socketBinding)
	if (#resultGemVariants > 0 or socketBinding) and not skillSetState then return false, skillSetError end
	if socketBinding then
		if type(socketBinding.groupIndex) ~= "number" or socketBinding.groupIndex < 1
			or socketBinding.groupIndex ~= math.floor(socketBinding.groupIndex)
			or type(socketBinding.itemId) ~= "number" or socketBinding.itemId < 1
			or socketBinding.itemId ~= math.floor(socketBinding.itemId)
			or not finalGearSet or tonumber(gearOverrides[socketBinding.slotName]) ~= socketBinding.itemId then
			return false, "The selected Main Skill socket binding is incomplete or does not match its equipment override"
		end
		local sourceGroup = build.skillsTab.socketGroupList[socketBinding.groupIndex]
		if not sourceGroup or sourceGroup.slot or sourceGroup.source then
			return false, "The selected Main Skill socket group changed after its socket plan was created"
		end
		local preparedSet = skillSetState and skillSetState.skillSets[skillSetState.activeSkillSetId]
		local groupOverride = preparedSet and preparedSet.socketGroupList[socketBinding.groupIndex]
			or shallowCopy(sourceGroup)
		groupOverride.slot = socketBinding.slotName
		groupOverride.slotEnabled = true
		local validationBuild = { skillsTab = build.skillsTab, itemsTab = gearValidationTab or build.itemsTab, data = build.data }
		local socketValid, socketInfo = SkillCatalog.ValidateSocketGroup(validationBuild,
			socketBinding.groupIndex, gearValidationTab or build.itemsTab, finalGearSet, groupOverride)
		if not socketValid then return false, socketInfo end
		if socketInfo.itemId ~= socketBinding.itemId or socketInfo.socketCount ~= socketBinding.socketCount
			or socketInfo.linkGroup ~= socketBinding.linkGroup then
			return false, "The generated Main Skill socket binding no longer matches PoB's native item sockets"
		end
	end
	local generationPhase = tostring(resultCandidate.generationPhase or ""):lower()
	local singleSkillPlannerResult = resultCandidate.evaluation
		and resultCandidate.evaluation.objective == "CombinedDPS"
		and resultCandidate.evaluation.routePlannerSearchMode == "SINGLE_SKILL_ONLY"
	if (generationPhase == "equipment" or generationPhase == "combined") and not singleSkillPlannerResult
		and (resultCandidate.requiresSocketedMainSkill == true or socketBinding ~= nil) then
		local socketProof = resultCandidate.evaluation and resultCandidate.evaluation.skillSocket
		if type(socketProof) ~= "table" or socketProof.status ~= "linked" then
			return false, "Equipment and Combined candidates require an exact PoB Main Skill socket/link proof before Apply"
		end
		local groupIndex = tonumber(socketProof.groupIndex)
		local sourceGroup = groupIndex and build.skillsTab and build.skillsTab.socketGroupList[groupIndex]
		if not sourceGroup or sourceGroup.source then
			return false, "The exact Main Skill socket proof no longer matches a manual PoB skill group"
		end
		local preparedSet = skillSetState and skillSetState.skillSets[skillSetState.activeSkillSetId]
		local groupOverride = preparedSet and preparedSet.socketGroupList[groupIndex]
			or shallowCopy(sourceGroup)
		if socketBinding then
			if socketBinding.groupIndex ~= groupIndex or socketBinding.slotName ~= socketProof.slot
				or socketBinding.itemId ~= socketProof.itemId or socketBinding.socketCount ~= socketProof.socketCount
				or socketBinding.linkGroup ~= socketProof.linkGroup then
				return false, "The exact Main Skill socket proof does not match its generated equipment binding"
			end
			groupOverride.slot = socketBinding.slotName
			groupOverride.slotEnabled = true
		elseif sourceGroup.slot ~= socketProof.slot then
			return false, "The exact Main Skill socket proof no longer matches its assigned PoB equipment slot"
		end
		local validationItemsTab = gearValidationTab or build.itemsTab
		local validationBuild = { skillsTab = build.skillsTab, itemsTab = validationItemsTab, data = build.data }
		local socketValid, socketInfo = SkillCatalog.ValidateSocketGroup(validationBuild,
			groupIndex, validationItemsTab, finalGearSet, groupOverride)
		if not socketValid then
			return false, "The exact Main Skill socket proof no longer validates against PoB's native item sockets: " .. tostring(socketInfo)
		end
		for _, key in ipairs({ "groupIndex", "slot", "itemId", "socketCount", "linkGroup" }) do
			if socketInfo[key] ~= socketProof[key] then
				return false, "The exact Main Skill socket proof changed before Apply (" .. key .. ")"
			end
		end
	end
	if (generationPhase == "equipment" or generationPhase == "combined") and not singleSkillPlannerResult
		and (resultCandidate.requiresSocketedMainSkill == true or socketBinding ~= nil) then
		local storedProof = resultCandidate.evaluation and resultCandidate.evaluation.skillGroupSockets
		if type(storedProof) ~= "table" or storedProof.status ~= "pass" or type(storedProof.groups) ~= "table" then
			return false, "Equipment and Combined candidates require exact socket/link proofs for every enabled manual Full DPS group"
		end
		local preparedSet = skillSetState and skillSetState.skillSets[skillSetState.activeSkillSetId]
		local groupOverrides = preparedSet and preparedSet.socketGroupList or nil
		if socketBinding then
			groupOverrides = groupOverrides or { }
			local boundGroup = shallowCopy(groupOverrides[socketBinding.groupIndex]
				or build.skillsTab.socketGroupList[socketBinding.groupIndex] or { })
			boundGroup.slot = socketBinding.slotName
			boundGroup.slotEnabled = true
			groupOverrides[socketBinding.groupIndex] = boundGroup
		end
		local validationItemsTab = gearValidationTab or build.itemsTab
		local validationBuild = { skillsTab = build.skillsTab, itemsTab = validationItemsTab, data = build.data }
		local groupsValid, currentProof = SkillCatalog.ValidateFullDPSSocketGroups(
			validationBuild, validationItemsTab, finalGearSet, groupOverrides)
		if not groupsValid then
			local first = currentProof.violations and currentProof.violations[1]
			return false, "An enabled Full DPS skill group no longer matches PoB's native item sockets: "
				.. tostring(first and first.reason or "socket/link validation failed")
		end
		local storedByIndex = { }
		for _, entry in ipairs(storedProof.groups) do
			local groupIndex = tonumber(entry.groupIndex)
			if not groupIndex or storedByIndex[groupIndex] or entry.status ~= "linked" or type(entry.group) ~= "table" then
				return false, "The exact Full DPS skill-group socket proof is malformed or duplicated"
			end
			storedByIndex[groupIndex] = entry
		end
		if #storedProof.groups ~= #currentProof.groups then
			return false, "The exact Full DPS skill-group socket proof no longer covers every enabled manual group"
		end
		for _, liveEntry in ipairs(currentProof.groups) do
			local stored = storedByIndex[liveEntry.groupIndex]
			if not stored then
				return false, "The exact Full DPS skill-group socket proof is missing group " .. tostring(liveEntry.groupIndex)
			end
			for _, key in ipairs({ "groupIndex", "slot", "itemId", "firstSocketIndex", "socketCount", "linkGroup" }) do
				if liveEntry.group[key] ~= stored.group[key] then
					return false, "The exact Full DPS skill-group socket proof changed before Apply (group "
						.. tostring(liveEntry.groupIndex) .. ", " .. key .. ")"
				end
			end
		end
	end
	if resultCandidate.evaluation and resultCandidate.evaluation.routePlannerSearchMode then
		local storedProof = resultCandidate.evaluation.routePlannerSocketProofs
		if type(storedProof) ~= "table" or storedProof.status ~= "pass" or type(storedProof.groups) ~= "table" then
			return false, "AI Planner routes require an exact socket/link proof for every active skill group"
		end
		local preparedSet = skillSetState and skillSetState.skillSets[skillSetState.activeSkillSetId]
		local validationItemsTab = gearValidationTab or build.itemsTab
		local validationSkillsTab = preparedSet or build.skillsTab
		local groupList = validationSkillsTab and validationSkillsTab.socketGroupList or { }
		local validationBuild = {
			skillsTab = validationSkillsTab,
			itemsTab = validationItemsTab,
			data = build.data,
			spec = build.spec,
		}
		local groupsValid, currentProof
		if singleSkillPlannerResult then
			local selectedGroupIndex = tonumber(resultCandidate.evaluation.skillSocket
				and resultCandidate.evaluation.skillSocket.groupIndex)
				or tonumber(storedProof.selectedGroupIndex)
			if storedProof.scope ~= "single_skill_preserve_existing_links"
				or not selectedGroupIndex or tonumber(storedProof.selectedGroupIndex) ~= selectedGroupIndex then
				return false, "The exact Single Skill route proof is missing its selected Main Skill or baseline-link scope"
			end
			groupsValid, currentProof = SkillCatalog.ValidatePlannerSocketGroups(
				build, validationBuild, selectedGroupIndex, validationItemsTab, finalGearSet, groupList)
		else
			groupsValid, currentProof = SkillCatalog.ValidateEnabledSocketGroups(
				validationBuild, validationItemsTab, finalGearSet, groupList)
		end
		if not groupsValid then
			local first = currentProof.violations and currentProof.violations[1]
			return false, "A required AI Planner skill group no longer matches PoB's native item sockets: "
				.. tostring(first and first.reason or "socket/link validation failed")
		end
		local storedByIndex = { }
		for _, entry in ipairs(storedProof.groups) do
			local groupIndex = tonumber(entry.groupIndex)
			if not groupIndex or storedByIndex[groupIndex] or type(entry.group) ~= "table"
				or entry.status ~= entry.group.status then
				return false, "The exact AI Planner active-skill socket proof is malformed or duplicated"
			end
			storedByIndex[groupIndex] = entry
		end
		if #storedProof.groups ~= #currentProof.groups then
			return false, "The exact AI Planner socket proof no longer covers every active skill group"
		end
		for _, liveEntry in ipairs(currentProof.groups) do
			local stored = storedByIndex[liveEntry.groupIndex]
			if not stored then
				return false, "The exact AI Planner socket proof is missing active group " .. tostring(liveEntry.groupIndex)
			end
			for _, key in ipairs({ "status", "slot", "itemId", "firstSocketIndex", "socketCount", "linkGroup",
				"sourceKind", "nodeId" }) do
				if stored.group[key] ~= nil and stored.group[key] ~= liveEntry.group[key] then
					return false, "The exact AI Planner socket proof changed before Apply (group "
						.. tostring(liveEntry.groupIndex) .. ", " .. key .. ")"
				end
			end
		end
	end
	local allowUnlinkedSkillCheckpoint = isExactUnlinkedSkillCheckpoint(build, resultCandidate, resultGemVariants)
	if #resultGemVariants > 0 and not allowUnlinkedSkillCheckpoint then
		local storedProof = resultCandidate.evaluation and resultCandidate.evaluation.skillVariantSocketProofs
		if type(storedProof) ~= "table" or storedProof.status ~= "pass" or type(storedProof.groups) ~= "table" then
			return false, "Gem-changing candidates require an exact native socket/link proof for every changed skill group"
		end
		local preparedSet = skillSetState and skillSetState.skillSets[skillSetState.activeSkillSetId]
		if not preparedSet then return false, "The candidate's exact skill-set variation is unavailable for socket validation" end
		local validationItemsTab = gearValidationTab or build.itemsTab
		local validationBuild = {
			skillsTab = preparedSet,
			itemsTab = validationItemsTab,
			data = build.data,
			spec = build.spec,
		}
		local storedByIndex, changedIndexes = { }, { }
		for _, entry in ipairs(storedProof.groups) do
			local groupIndex = tonumber(entry.groupIndex)
			if not groupIndex or storedByIndex[groupIndex] or type(entry.group) ~= "table"
				or entry.status ~= entry.group.status then
				return false, "The exact changed-gem socket proof is malformed or duplicated"
			end
			storedByIndex[groupIndex] = entry
		end
		for _, variant in ipairs(resultGemVariants) do
			local groupIndex = tonumber(variant.groupIndex)
			if not groupIndex or groupIndex < 1 or groupIndex ~= math.floor(groupIndex) then
				return false, "A changed gem variant has no valid native PoB socket-group index"
			end
			changedIndexes[groupIndex] = true
		end
		local changedCount = 0
		for groupIndex in pairs(changedIndexes) do
			changedCount = changedCount + 1
			local stored = storedByIndex[groupIndex]
			if not stored then
				return false, "The exact changed-gem socket proof is missing group " .. tostring(groupIndex)
			end
			local socketValid, socketInfo = SkillCatalog.ValidateSocketGroup(
				validationBuild, groupIndex, validationItemsTab, finalGearSet)
			if not socketValid or type(socketInfo) ~= "table"
				or (socketInfo.status ~= "linked" and socketInfo.status ~= "granted_skill") then
				return false, "A changed gem group no longer matches PoB's native item sockets: " .. tostring(socketInfo)
			end
			for _, key in ipairs({ "status", "slot", "itemId", "firstSocketIndex", "socketCount", "linkGroup",
				"sourceKind", "nodeId" }) do
				if stored.group[key] ~= nil and stored.group[key] ~= socketInfo[key] then
					return false, "The exact changed-gem socket proof changed before Apply (group "
						.. tostring(groupIndex) .. ", " .. key .. ")"
				end
			end
		end
		if changedCount ~= #storedProof.groups then
			return false, "The exact changed-gem socket proof does not cover every mutated PoB skill group"
		end
	end
	local selectedMainSkillVariant, selectedMainSkillIndex
	if skillSetState then
		local selectedSet = skillSetState.skillSets[skillSetState.activeSkillSetId]
		for _, variant in ipairs(resultGemVariants) do
			if variant.kind == "selected_main_skill" then
				selectedMainSkillVariant = variant
				local group = selectedSet and selectedSet.socketGroupList[variant.groupIndex]
				selectedMainSkillIndex = group
					and SkillCatalog.ResolveMainSkillIndex(group, variant.gemIndex, variant.skillId)
				if not selectedMainSkillIndex then
					return false, "PoB could not resolve the selected Main Skill in the prepared skill-set variation"
				end
				break
			end
		end
	end
	local treeTab = build.treeTab
	local sourceSpec = build.spec
	local appliedKinds = { }
	local resultJewelVariants = jewelVariants(resultCandidate)
	local jewelVariantsValid, jewelVariantsError = validateJewelVariants(resultJewelVariants)
	if not jewelVariantsValid then return false, jewelVariantsError end
	for _, variant in ipairs(resultJewelVariants) do
		local item = build.itemsTab and build.itemsTab.items and build.itemsTab.items[variant.itemId]
		if not item or not item.jewelData then return false, "A candidate jewel item is no longer available in the active PoB item list" end
		if variant.fromNodeId and variant.fromNodeId > 0 then
			local sourceSocket = sourceSpec.nodes[variant.fromNodeId]
			if not sourceSocket or sourceSocket.type ~= "Socket" then return false, "A candidate jewel source is no longer a native PoB socket" end
		end
	end
	local hasTreeMutation = (resultCandidate.nodeIds and #resultCandidate.nodeIds > 0)
		or (resultCandidate.removeNodeIds and #resultCandidate.removeNodeIds > 0)
		or resultCandidate.classVariant or resultCandidate.ascendancyVariant or resultCandidate.jewelVariant
		or #resultJewelVariants > 0 or resultCandidate.masteryVariant or resultCandidate.tattooVariant or resultCandidate.timelessVariant
	local projectedTreeState
	if hasTreeMutation then
		-- Use the same native PoB projection that exact evaluation used. Rebuilding
		-- an undo state from only the requested target IDs can omit connector nodes
		-- that PassiveSpec:AllocNode added along the legal path, so the applied
		-- variation may calculate different defenses from the exact preview.
		local projectionVariants = {
			classId = resultCandidate.classVariant and resultCandidate.classVariant.classId or nil,
			ascendancyVariant = resultCandidate.ascendancyVariant,
			jewelVariants = resultJewelVariants,
			masteryVariant = resultCandidate.masteryVariant,
			tattooVariant = resultCandidate.tattooVariant,
			timelessVariant = resultCandidate.timelessVariant,
			anointVariant = resultCandidate.anointVariant,
			anointVariants = resultCandidate.anointVariants,
			gearVariant = gearVariant,
		}
		local projected, projectionError = candidate.BuildPassiveSpec(build,
			resultCandidate.nodeIds, resultCandidate.removeNodeIds, projectionVariants)
		if not projected then return false, projectionError or "PoB could not reconstruct the selected passive-tree variation" end
		projectedTreeState = projected:CreateUndoState()
		if type(projectedTreeState) ~= "table" or type(projectedTreeState.hashList) ~= "table" then
			return false, "PoB could not serialize the exact projected passive-tree variation"
		end
	end
	if hasTreeMutation then
		if timelessItem then
			timelessItem.id = nil -- ItemsTab assigns a fresh ID; the source jewel stays unchanged.
			build.itemsTab:AddItem(timelessItem, true)
			build.itemsTab.modFlag = true
		end
		local state = projectedTreeState
		local newJewels = resultCandidate.classVariant and { } or copyTable(sourceSpec.jewels)
		for _, variant in ipairs(resultJewelVariants) do
			if variant.fromNodeId and variant.fromNodeId > 0 then
				newJewels[variant.fromNodeId] = variant.targetItemId > 0 and variant.targetItemId or nil
			end
			newJewels[variant.toNodeId] = variant.itemId
		end
		if resultCandidate.timelessVariant then
			newJewels[resultCandidate.timelessVariant.nodeId] = timelessItem.id
		end
		local newSpec = new("PassiveSpec"):PassiveSpec(build, sourceSpec.treeVersion)
		newSpec.jewels = newJewels
		newSpec:RestoreUndoState(state)
		newSpec:BuildClusterJewelGraphs()
		newSpec.title = "Optimizer result " .. tostring(#treeTab.specList + 1)
		t_insert(treeTab.specList, newSpec)
		treeTab:SetActiveSpec(#treeTab.specList)
		treeTab.modFlag = true
		t_insert(appliedKinds, "passive-tree variation")
	end

	if skillSetState then
		build.skillsTab:RestoreUndoState(skillSetState)
		if selectedMainSkillVariant then
			local group = build.skillsTab.socketGroupList[selectedMainSkillVariant.groupIndex]
			if group then
				group.mainActiveSkill = selectedMainSkillIndex
				group.mainActiveSkillCalcs = selectedMainSkillIndex
				build.mainSocketGroup = selectedMainSkillVariant.groupIndex
				build.calcsTab.input.skill_number = selectedMainSkillVariant.groupIndex
				-- RestoreUndoState can lose the selected display-group reference
				-- when it replaces the socket-group table. Rebind it to this native
				-- group so the next ordinary PoB frame recalculates and displays the
				-- exact skill that the optimizer just applied.
				build.skillsTab:SetDisplayGroup(group)
			end
		end
		build.skillsTab:AddUndoState()
		if not skillUndoCheckpointExists then
			-- Fresh builds may have no current Undo baseline. Preserve the exact
			-- pre-variation skill state so the native Undo action can restore it.
			table.insert(build.skillsTab.undo, 2, originalSkillState)
		end
		build.skillsTab.modFlag = true
		t_insert(appliedKinds, "skill-set variation")
	end

	if anointVariants then
		local itemsTab = build.itemsTab
		local variant = type(anointVariants) == "table" and anointVariants.nodeId and anointVariants or anointVariants[1]
		local sourceSet = itemsTab.activeItemSet or itemsTab.itemSets[itemsTab.activeItemSetId]
		local itemSet = copyTable(sourceSet)
		local newItemSetId = 1
		while itemsTab.itemSets[newItemSetId] do newItemSetId = newItemSetId + 1 end
		itemSet.id = newItemSetId
		local names = { }
		local variantList = type(anointVariants) == "table" and anointVariants.nodeId and { anointVariants } or anointVariants
		for _, anointVariant in ipairs(variantList) do
			local node = build.spec.nodes[tonumber(anointVariant.nodeId)]
			names[#names + 1] = tostring(node and node.dn or ("node " .. tostring(anointVariant.nodeId)))
		end
		itemSet.title = "Optimizer result - Anoint " .. table.concat(names, " + ")
		anointedItem.id = nil -- The source item stays in the original set and item list.
		itemsTab:AddItem(anointedItem, true)
		itemSet[variant.slotName].selItemId = anointedItem.id
		itemsTab.itemSets[newItemSetId] = itemSet
		t_insert(itemsTab.itemSetOrderList, newItemSetId)
		itemsTab:SetActiveItemSet(newItemSetId)
		itemsTab:AddUndoState()
		itemsTab.modFlag = true
		t_insert(appliedKinds, "anointed item-set variation")
	end

	if resultCandidate.configurationVariant then
		local configTab = build.configTab
		local sourceSet = configTab.configSets[configTab.activeConfigSetId]
		local newSet = configTab:NewConfigSet(nil, ConfigurationChoices.VariationTitle(resultCandidate.configurationVariant))
		-- NewConfigSet supplies PoB's current native defaults. Replace them with a
		-- deep copy of the active set so unrelated conditions and custom modifiers
		-- survive unchanged in this separately selectable configuration variation.
		newSet.input = copyTable(sourceSet.input or { })
		newSet.placeholder = copyTable(sourceSet.placeholder or { })
		newSet.customModsList = copyTable(sourceSet.customModsList or { { title = "Default", enabled = true, text = "" } })
		for key, value in pairs(resultCandidate.configurationVariant) do
			newSet.input[key] = value
			newSet.placeholder[key] = nil
		end
		t_insert(configTab.configSetOrderList, newSet.id)
		configTab:SetActiveConfigSet(newSet.id)
		configTab:AddUndoState()
		configTab.modFlag = true
		t_insert(appliedKinds, "PoB configuration variation")
	end

	if next(gearOverrides) then
		local itemsTab = build.itemsTab
		local appliedOverrides = gearOverrides
		local addedSyntheticIds
		if #generatedItems > 0 then
			local addError
			appliedOverrides, addedSyntheticIds = SyntheticGear.AddToItemsTab(itemsTab, generatedItems, gearOverrides)
			if not appliedOverrides then return false, addedSyntheticIds end
		end
		if anointVariants then
			-- The anoint branch already created a reversible item-set variation. Add
			-- selected existing items to that same variation instead of leaving an
			-- extra intermediate equipment set in the user's build.
			local activeSet = itemsTab.activeItemSet or itemsTab.itemSets[itemsTab.activeItemSetId]
			local valid, validationError, finalSet = Equipment.Validate(build, appliedOverrides)
			if not valid then
				SyntheticGear.RemoveAddedItems(itemsTab, addedSyntheticIds)
				return false, validationError
			end
			local activeId = itemsTab.activeItemSetId
			finalSet.id = activeId
			local activeTitle = tostring(activeSet and activeSet.title or "Optimizer result")
			finalSet.title = activeTitle .. " + selected equipment"
			itemsTab.itemSets[activeId] = finalSet
			itemsTab.activeItemSet = finalSet
			itemsTab:SetActiveItemSet(activeId)
			itemsTab:AddUndoState()
			itemsTab.modFlag = true
		else
			local ok, message = Equipment.ApplyVariation(build, appliedOverrides, "Optimizer result - selected equipment")
			if not ok then
				SyntheticGear.RemoveAddedItems(itemsTab, addedSyntheticIds)
				return false, message
			end
		end
		t_insert(appliedKinds, "equipment-set variation")
	end
	if socketBinding and build.skillsTab and type(build.skillsTab.UpdateSocketGroups) == "function" then
		build.skillsTab:UpdateSocketGroups()
	end
	-- Exact evaluation may use a higher (or lower) Auto level because the
	-- selected passive variation has a different point count. Sync PoB's shared
	-- character-level control before the next native output rebuild; otherwise
	-- the new tree is active but the UI can briefly calculate with the seed's
	-- old level and display values that disagree with the exact route preview.
	if build.characterLevelAutoMode == true then
		local evaluatedLevel = resultCandidate.evaluation and tonumber(resultCandidate.evaluation.characterLevel)
		if isFinite(evaluatedLevel) and evaluatedLevel >= 1 and evaluatedLevel <= 100
			and evaluatedLevel == math.floor(evaluatedLevel) then
			build.characterLevel = evaluatedLevel
			if build.controls and build.controls.characterLevel
				and type(build.controls.characterLevel.SetText) == "function" then
				build.controls.characterLevel:SetText(evaluatedLevel)
			end
			if build.configTab and type(build.configTab.BuildModList) == "function" then
				build.configTab:BuildModList()
			end
		elseif type(build.EstimatePlayerProgress) == "function" then
			-- Older feasible results may not carry a serialized exact level.
			build:EstimatePlayerProgress()
		end
	end

	build.modFlag = true
	build.buildFlag = true
	local unlinkedSupportPlan = false
	for _, variant in ipairs(resultGemVariants) do
		local group = build.skillsTab.socketGroupList[variant.groupIndex]
		if variant.kind == "support_add" and group and not group.slot then
			unlinkedSupportPlan = true
			break
		end
	end
	local message = "Applied as a new PoB " .. table.concat(appliedKinds, " and ") .. "."
	if unlinkedSupportPlan then
		message = message .. " These supports are an exact-calculated planning package, but the group has no equipment socket or link; assign a compatible item link and recalculate before treating it as playable."
	end
	return true, message
end

return candidate
