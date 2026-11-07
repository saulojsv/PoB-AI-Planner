-- Path of Building
--
-- Module: Native active-skill gem choices for the AI Planner.
-- This module reads the already-loaded PoB gem database and never creates a
-- second source of game rules. Exact calculation and hard gates remain native.

local catalog = { }
local Version = require("Modules.Optimizer.Version")
local repairCapacityCache = setmetatable({ }, { __mode = "k" })

local function normalize(value)
	return tostring(value or ""):lower():gsub("^%s*(.-)%s*$", "%1")
end

local function isGrantedSkillGroup(group)
	local source = group and group.source
	return source ~= nil and source ~= ""
end

local function activeSkillGem(gemData)
	local effect = gemData and gemData.grantedEffect
	return effect ~= nil
		and effect.unsupported ~= true
		and effect.support ~= true
		and gemData.tags ~= nil
		and gemData.tags.grants_active_skill == true
end

local function declaresActiveSkillGem(gemData)
	return type(gemData) == "table" and type(gemData.tags) == "table"
		and gemData.tags.grants_active_skill == true
end

local function activeGemExclusionReason(gemData)
	local effect = gemData and gemData.grantedEffect
	if not effect then return "missing_granted_effect" end
	if effect.unsupported == true then return "unsupported_by_pob" end
	if effect.support == true then return "support_effect_not_main_skill" end
	return "active_skill_effect_not_selectable"
end

local function sortedExcludedActiveGemRows(build)
	local rows = { }
	for gemId, gemData in pairs(build and build.data and build.data.gems or { }) do
		if declaresActiveSkillGem(gemData) and not activeSkillGem(gemData) then
			rows[#rows + 1] = {
				id = tostring(gemData.id or gemId),
				name = tostring(gemData.name or ""),
				variantId = tostring(gemData.variantId or ""),
				gameId = tostring(gemData.gameId or ""),
				effectId = tostring(gemData.grantedEffect and gemData.grantedEffect.id or gemData.grantedEffectId or ""),
				tags = tostring(gemData.tagString or ""),
				reason = activeGemExclusionReason(gemData),
			}
		end
	end
	table.sort(rows, function(a, b)
		local left, right = a.name:lower(), b.name:lower()
		if left ~= right then return left < right end
		if a.variantId ~= b.variantId then return a.variantId < b.variantId end
		return a.id < b.id
	end)
	return rows
end

local function sortedGemRows(build, query)
	local rows = { }
	local needle = normalize(query)
	for gemId, gemData in pairs(build and build.data and build.data.gems or { }) do
		if activeSkillGem(gemData) then
			local name = tostring(gemData.name or "")
			local gameId = tostring(gemData.gameId or "")
			local variantId = tostring(gemData.variantId or "")
			if needle == "" or name:lower():find(needle, 1, true)
				or variantId:lower():find(needle, 1, true) or gameId:lower():find(needle, 1, true) then
				rows[#rows + 1] = {
					id = tostring(gemData.id or gemId),
					name = name,
					variantId = variantId,
					gameId = gameId,
					tags = tostring(gemData.tagString or ""),
					color = gemData.grantedEffect.color,
					maximumLevel = tonumber(gemData.naturalMaxLevel) or #(gemData.grantedEffect.levels or { }),
					levelRequirement = gemData.grantedEffect.levels and gemData.grantedEffect.levels[1]
						and tonumber(gemData.grantedEffect.levels[1].levelRequirement) or 1,
				}
			end
		end
	end
	table.sort(rows, function(a, b)
		local left, right = a.name:lower(), b.name:lower()
		if left ~= right then return left < right end
		if a.variantId ~= b.variantId then return a.variantId < b.variantId end
		return a.id < b.id
	end)
	return rows
end

function catalog.ListActive(build, query, limit)
	if not build or not build.data or type(build.data.gems) ~= "table" then
		return nil, "PoB's loaded active-skill gem database is unavailable"
	end
	local rows = sortedGemRows(build, query)
	local boundedLimit = tonumber(limit) or 100
	if boundedLimit ~= math.floor(boundedLimit) or boundedLimit < 1 or boundedLimit > 1000 then
		return nil, "Skill-gem result limit must be an integer from 1 to 1000"
	end
	local result = { }
	for index = 1, math.min(#rows, boundedLimit) do result[index] = rows[index] end
	return {
		query = tostring(query or ""),
		count = #result,
		available = #rows,
		truncated = #rows > #result,
		gems = result,
		source = "loaded_pob_gem_database",
	}
end

function catalog.IsActiveSkillGem(gemData)
	return activeSkillGem(gemData)
end

local function activeGemInstance(build, groupIndex, skillIndex)
	local group = build and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false then
		return nil, nil, "Select an enabled PoB socket group for the Main Skill"
	end
	local selectedSkill = group.displaySkillList and group.displaySkillList[skillIndex]
	if selectedSkill and selectedSkill.activeEffect then
		local activeEffect = selectedSkill.activeEffect
		local sourceGem = activeEffect.srcInstance
		if sourceGem then
			for gemIndex, gem in ipairs(group.gemList or { }) do
				local gemData = gem.gemData or (gem.gemId and build.data and build.data.gems and build.data.gems[gem.gemId])
				if gem == sourceGem and gemData and activeSkillGem(gemData) then
					return group, gemIndex, nil, gem
				end
			end
		end
		local effectId = activeEffect.grantedEffect and activeEffect.grantedEffect.id
		for gemIndex, gem in ipairs(group.gemList or { }) do
			local gemData = gem.gemData or (gem.gemId and build.data and build.data.gems and build.data.gems[gem.gemId])
			if gem.enabled ~= false and gemData and activeSkillGem(gemData) then
				if effectId == gemData.grantedEffectId then return group, gemIndex, nil, gem end
				for _, grantedEffect in ipairs(gemData.grantedEffectList or { }) do
					if effectId == grantedEffect.id then return group, gemIndex, nil, gem end
				end
			end
		end
	end

	-- An incompatible primary socket can prevent PoB from constructing the
	-- displaySkillList even though the XML still identifies one unambiguous
	-- active gem in the selected group. Retain that native gem identity so a
	-- disposable item rework can restore the socket and let PoB build the skill
	-- normally during exact candidate calculation. Never infer between multiple
	-- active gems when PoB has not resolved the selected effect.
	local candidateIndex, candidateGem
	for gemIndex, gem in ipairs(group.gemList or { }) do
		local gemData = gem.gemData or (gem.gemId and build.data and build.data.gems and build.data.gems[gem.gemId])
		if gem.enabled ~= false and activeSkillGem(gemData) then
			if candidateGem then return nil, nil, "The selected socket group has multiple unresolved active skill gems" end
			candidateIndex, candidateGem = gemIndex, gem
		end
	end
	if candidateGem then return group, candidateIndex, nil, candidateGem end
	return nil, nil, "The selected socket group has no replaceable active skill gem"
end

local function socketCompatible(build, groupIndex, gemIndex, group, gemData)
	if type(group.slot) ~= "string" or group.slot == "" then
		local currentGem = group.gemList and group.gemList[gemIndex]
		if currentGem and currentGem.gemData and currentGem.gemData.id == gemData.id then
			-- An unassigned AI Planner seed may be evaluated as the native current
			-- Main Skill, but it cannot be replaced by a different gem until a real
			-- PoB item socket is selected.
			return true
		end
		return false, "Assign the target skill group to a PoB equipment slot before optimizing its Main Skill gem"
	end
	local itemsTab = build.itemsTab
	local itemSets = itemsTab and itemsTab.itemSets or { }
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemSets[itemsTab.activeItemSetId])
	local selected = itemSet and itemSet[group.slot]
	local itemId = selected and tonumber(selected.selItemId)
	local item = itemId and itemId > 0 and itemsTab.items and itemsTab.items[itemId]
	if not item or type(item.sockets) ~= "table" then
		local currentGem = group.gemList and group.gemList[gemIndex]
		if currentGem and currentGem.gemData and currentGem.gemData.id == gemData.id then return true end
		return false, "The target PoB equipment slot has no item with native socket data"
	end
	local socketOffset = 0
	for currentGroupIndex, currentGroup in ipairs(build.skillsTab.socketGroupList or { }) do
		if currentGroup.slot == group.slot then
			if currentGroupIndex == groupIndex then break end
			socketOffset = socketOffset + #(currentGroup.gemList or { })
		end
	end
	local socket = item.sockets[socketOffset + gemIndex]
	if item.sockets.colourAlwaysMatches then return true end
	if not socket then return false, "The selected active gem does not map to a native socket on its PoB item" end
	local colors = { [1] = "R", [2] = "G", [3] = "B", [4] = "W", R = "R", G = "G", B = "B", W = "W" }
	local requiredColor = colors[gemData.grantedEffect.color]
	if not requiredColor then
		return false, "PoB did not provide a supported native socket color for " .. tostring(gemData.name or gemData.id)
	end
	local socketColor = tostring(socket.color or ""):upper()
	if socketColor ~= requiredColor and socketColor ~= "W" then
		return false, string.format("Selected gem %s needs a %s socket but PoB item slot %s provides %s at that position",
			tostring(gemData.name or gemData.id), requiredColor, group.slot, socketColor ~= "" and socketColor or "no socket")
	end
	return true
end

function catalog.CanReplaceGemAtSlot(build, groupIndex, gemIndex, gemData, options)
	local group = build and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false then
		return false, "Select an enabled PoB socket group for the Main Skill"
	end
	if type(gemIndex) ~= "number" or gemIndex < 1 or gemIndex ~= math.floor(gemIndex)
		or not group.gemList or not group.gemList[gemIndex] then
		return false, "The selected socket group no longer contains the requested gem slot"
	end
	if not activeSkillGem(gemData) then
		return false, "Replacement must be a supported active skill gem from PoB's loaded gem database"
	end
	local compatible, compatibility = socketCompatible(build, groupIndex, gemIndex, group, gemData)
	if not compatible and type(options) == "table" and options.allowUnlinkedPlanning == true
		and not isGrantedSkillGroup(group) and (type(group.slot) ~= "string" or group.slot == "") then
		return true, { linked = false, status = "unlinked_planning" }
	end
	return compatible, compatibility
end

local function supportEffect(gemData)
	local effect = gemData and gemData.grantedEffect
	if effect and effect.support and not effect.unsupported then return effect end
	effect = gemData and gemData.secondaryGrantedEffect
	if effect and effect.support and not effect.unsupported then return effect end
	return nil
end

function catalog.CanReplaceSupportAtSlot(build, groupIndex, gemIndex, gemData)
	local group = build and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false then
		return false, "Select an enabled PoB socket group before replacing a support"
	end
	local currentGem = group.gemList and group.gemList[gemIndex]
	if type(gemIndex) ~= "number" or gemIndex < 1 or gemIndex ~= math.floor(gemIndex) or not currentGem then
		return false, "The selected socket group no longer contains the requested support slot"
	end
	local currentData = currentGem.gemData or (currentGem.gemId and build.data and build.data.gems[currentGem.gemId])
	if not supportEffect(currentData) then
		return false, "The selected slot does not currently contain a supported PoB support gem"
	end
	local effect = supportEffect(gemData)
	if not effect then
		return false, "Replacement must be a supported support gem from PoB's loaded gem database"
	end
	if type(group.slot) ~= "string" or group.slot == "" then
		if isGrantedSkillGroup(group) then return false, "A PoB-granted skill group cannot replace a socketed support" end
		return true, { linked = false, status = "unlinked_planning_group" }
	end
	local itemsTab = build.itemsTab
	local itemSets = itemsTab and itemsTab.itemSets or { }
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemSets[itemsTab.activeItemSetId])
	local slotEntry = itemSet and itemSet[group.slot]
	local itemId = slotEntry and tonumber(slotEntry.selItemId)
	local item = itemId and itemId > 0 and itemsTab.items and itemsTab.items[itemId]
	if not item or type(item.sockets) ~= "table" then
		return false, "The target PoB equipment slot has no item with native socket data"
	end
	local socketOffset = 0
	for currentGroupIndex, currentGroup in ipairs(build.skillsTab.socketGroupList or { }) do
		if currentGroup.slot == group.slot then
			if currentGroupIndex == groupIndex then break end
			socketOffset = socketOffset + #(currentGroup.gemList or { })
		end
	end
	local socketIndex = socketOffset + gemIndex
	local socket = item.sockets[socketIndex]
	if not socket then return false, "The selected support slot does not map to a native PoB item socket" end
	if item.sockets.colourAlwaysMatches then return true, { linked = true, socketIndex = socketIndex, linkGroup = socket.group } end
	local colors = { [1] = "R", [2] = "G", [3] = "B", [4] = "W", R = "R", G = "G", B = "B", W = "W" }
	local requiredColor = colors[effect.color]
	if not requiredColor then
		return false, "PoB did not provide a supported socket color for " .. tostring(gemData.name or gemData.id)
	end
	local socketColor = tostring(socket.color or ""):upper()
	if socketColor ~= requiredColor and socketColor ~= "W" then
		return false, string.format("Replacement support %s needs a %s socket but PoB item slot %s has %s at position %d",
			tostring(gemData.name or gemData.id), requiredColor, group.slot,
			socketColor ~= "" and socketColor or "uncolored", socketIndex)
	end
	return true, { linked = true, socketIndex = socketIndex, linkGroup = socket.group }
end

local function sortedSupportRows(build, query)
	local rows = { }
	local needle = normalize(query)
	for gemId, gemData in pairs(build and build.data and build.data.gems or { }) do
		local effect = supportEffect(gemData)
		if effect then
			local name = tostring(gemData.name or "")
			local gameId = tostring(gemData.gameId or "")
			local variantId = tostring(gemData.variantId or "")
			local effectId = tostring(effect.id or gemData.grantedEffectId or "")
			if needle == "" or name:lower():find(needle, 1, true)
				or variantId:lower():find(needle, 1, true) or gameId:lower():find(needle, 1, true)
				or effectId:lower():find(needle, 1, true) then
				rows[#rows + 1] = {
					id = tostring(gemData.id or gemId),
					name = name,
					variantId = variantId,
					gameId = gameId,
					effectId = effectId,
					tags = tostring(gemData.tagString or ""),
					color = effect.color,
					maximumLevel = math.min(tonumber(gemData.naturalMaxLevel) or #(effect.levels or { }), #(effect.levels or { })),
					levelRequirement = effect.levels and effect.levels[1]
						and tonumber(effect.levels[1].levelRequirement) or 1,
				}
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
		if a.variantId ~= b.variantId then return a.variantId < b.variantId end
		return a.id < b.id
	end)
	return rows
end

local function boundedGemRows(build, rows, query, limit, label)
	if not build or not build.data or type(build.data.gems) ~= "table" then
		return nil, "PoB's loaded " .. label .. " gem database is unavailable"
	end
	local boundedLimit = tonumber(limit) or 100
	if boundedLimit ~= math.floor(boundedLimit) or boundedLimit < 1 or boundedLimit > 1000 then
		return nil, label .. " gem result limit must be an integer from 1 to 1000"
	end
	local result = { }
	for index = 1, math.min(#rows, boundedLimit) do result[index] = rows[index] end
	return {
		query = tostring(query or ""),
		count = #result,
		available = #rows,
		truncated = #rows > #result,
		gems = result,
		source = "loaded_pob_gem_database",
	}
end

local function supportedActiveEffects(gemData)
	local effects, seen = { }, { }
	local candidates = gemData and gemData.grantedEffectList
	if type(candidates) ~= "table" then
		candidates = { gemData and gemData.grantedEffect, gemData and gemData.secondaryGrantedEffect }
	end
	for _, effect in ipairs(candidates) do
		if effect and not effect.support and not effect.unsupported and effect.id ~= nil then
			local effectId = tostring(effect.id)
			if not seen[effectId] then
				seen[effectId] = true
				effects[#effects + 1] = effect
			end
		end
	end
	return effects
end

local function activeEffectRows(build, query)
	local rows, seen = { }, { }
	local needle = normalize(query)
	for gemId, gemData in pairs(build and build.data and build.data.gems or { }) do
		if activeSkillGem(gemData) then
			for _, effect in ipairs(supportedActiveEffects(gemData)) do
				local effectId = tostring(effect.id)
				local name = tostring(gemData.name or "")
				local gameId = tostring(gemData.gameId or "")
				local variantId = tostring(gemData.variantId or "")
				local effectName = tostring(effect.name or effectId)
				if needle == "" or name:lower():find(needle, 1, true)
					or variantId:lower():find(needle, 1, true) or gameId:lower():find(needle, 1, true)
					or effectName:lower():find(needle, 1, true) or effectId:lower():find(needle, 1, true) then
					local row = {
						gemId = tostring(gemData.id or gemId),
						name = name,
						variantId = variantId,
						gameId = gameId,
						effectId = effectId,
						effectName = effectName,
						tags = tostring(gemData.tagString or ""),
						color = effect.color,
					}
					local key = table.concat({ row.gemId, row.effectId }, "\31")
					if not seen[key] then
						seen[key] = true
						rows[#rows + 1] = row
					end
				end
			end
		end
	end
	table.sort(rows, function(a, b)
			if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
			if a.variantId ~= b.variantId then return a.variantId < b.variantId end
			if a.gemId ~= b.gemId then return a.gemId < b.gemId end
			return a.effectId < b.effectId
		end)
	return rows
end

function catalog.ListSupports(build, query, limit)
	return boundedGemRows(build, sortedSupportRows(build, query), query, limit, "support")
end

function catalog.ListActiveEffects(build, query, limit)
	if not build or not build.data or type(build.data.gems) ~= "table" then
		return nil, "PoB's loaded active-skill gem database is unavailable"
	end
	local rows = activeEffectRows(build, query)
	local boundedLimit = tonumber(limit) or 100
	if boundedLimit ~= math.floor(boundedLimit) or boundedLimit < 1 or boundedLimit > 1000 then
		return nil, "Active-skill effect result limit must be an integer from 1 to 1000"
	end
	local result = { }
	for index = 1, math.min(#rows, boundedLimit) do result[index] = rows[index] end
	return {
		query = tostring(query or ""),
		count = #result,
		available = #rows,
		truncated = #rows > #result,
		effects = result,
		source = "loaded_pob_gem_database",
		game = "Path of Exile 1",
	}
end

-- Local build-learning work needs the complete finite catalog loaded by this
-- PoB process. Keep the bounded MCP lookup above separate from this internal
-- API so a UI/tool response cap cannot silently omit skill variants.
function catalog.ListAllActiveEffects(build, query)
	if not build or not build.data or type(build.data.gems) ~= "table" then
		return nil, "PoB's loaded active-skill gem database is unavailable"
	end
	local rows = activeEffectRows(build, query)
	return {
		query = tostring(query or ""),
		count = #rows,
		available = #rows,
		truncated = false,
		effects = rows,
		source = "loaded_pob_gem_database",
		game = "Path of Exile 1",
	}
end

function catalog.Summary(build)
	if not build or not build.data or type(build.data.gems) ~= "table" then
		return nil, "PoB's loaded gem database is unavailable"
	end
	local activeGems = sortedGemRows(build, "")
	local activeEffects = activeEffectRows(build, "")
	local supports = sortedSupportRows(build, "")
	local excludedActiveGems = sortedExcludedActiveGemRows(build)
	local activeGameIds, supportGameIds, supportEffects = { }, { }, { }
	local declaredActiveSkillGemRecords, unsupportedActiveSkillGemRecords, missingActiveSkillGemEffects = 0, 0, 0
	for _, gemData in pairs(build.data.gems) do
		if declaresActiveSkillGem(gemData) then
			declaredActiveSkillGemRecords = declaredActiveSkillGemRecords + 1
			local reason = activeGemExclusionReason(gemData)
			if reason == "unsupported_by_pob" then unsupportedActiveSkillGemRecords = unsupportedActiveSkillGemRecords + 1 end
			if reason == "missing_granted_effect" then missingActiveSkillGemEffects = missingActiveSkillGemEffects + 1 end
		end
	end
	for _, row in ipairs(activeGems) do
		if row.gameId ~= "" then activeGameIds[row.gameId] = true end
	end
	for _, row in ipairs(supports) do
		if row.gameId ~= "" then supportGameIds[row.gameId] = true end
		if row.effectId ~= "" then supportEffects[row.effectId] = true end
	end
	local function countKeys(values)
		local count = 0
		for _ in pairs(values) do count = count + 1 end
		return count
	end
	local snapshot = Version.Snapshot(build)
	return {
		game = "Path of Exile 1",
		source = "loaded_pob_gem_database",
		evaluationStatus = "catalog_only",
		exactEvaluated = false,
		dataVersion = snapshot.dataVersion,
		treeVersion = snapshot.treeVersion,
		pobVersion = snapshot.pobVersion,
		version = snapshot,
		versionIdentityStatus = snapshot.dataVersion and "tree_compatibility_key" or "unavailable",
		dataVersionSource = "PoB tree compatibility key; no independent gem-data version is exposed",
		counts = {
			activeGemEntries = #activeGems,
			declaredActiveSkillGemRecords = declaredActiveSkillGemRecords,
			selectableActiveSkillGemRecords = #activeGems,
			excludedActiveSkillGemRecords = #excludedActiveGems,
			unsupportedActiveSkillGemRecords = unsupportedActiveSkillGemRecords,
			activeSkillGemRecordsMissingEffect = missingActiveSkillGemEffects,
			activeSkillEffects = #activeEffects,
			activeGameIds = countKeys(activeGameIds),
			supportGemVariants = #supports,
			supportEffects = countKeys(supportEffects),
			supportGameIds = countKeys(supportGameIds),
		},
	}
end

local function displayTags(tagString)
	local tags = setmetatable({ }, { __jsontype = "array" })
	for tag in tostring(tagString or ""):gmatch("[^,]+") do
		tag = tag:gsub("^%s*(.-)%s*$", "%1")
		if tag ~= "" then tags[#tags + 1] = tag end
	end
	table.sort(tags)
	return tags
end

local function catalogRows(rows)
	local result = setmetatable({ }, { __jsontype = "array" })
	for index, source in ipairs(rows) do
		local row = { }
		for key, value in pairs(source) do
			if key == "tags" then
				row.tags = displayTags(value)
			else
				row[key] = value
			end
		end
		result[index] = row
	end
	return result
end

local function countDisplayTags(rows)
	local counts = { }
	for _, row in ipairs(rows) do
		for _, tag in ipairs(displayTags(row.tags)) do
			counts[tag] = (counts[tag] or 0) + 1
		end
	end
	return counts
end

function catalog.CoverageReport(build)
	local summary, summaryError = catalog.Summary(build)
	if not summary then return nil, summaryError end
	local activeGems = sortedGemRows(build, "")
	local activeEffects = activeEffectRows(build, "")
	local supports = sortedSupportRows(build, "")
	local excludedActiveGems = sortedExcludedActiveGemRows(build)
	local includedRecords, loadedRecords, unsupportedEffectRecords = { }, 0, 0
	for gemId, gemData in pairs(build.data.gems) do
		loadedRecords = loadedRecords + 1
		if activeSkillGem(gemData) or supportEffect(gemData) then
			includedRecords[tostring(gemId)] = true
		end
		local hasUnsupportedEffect = gemData and (
			(gemData.grantedEffect and gemData.grantedEffect.unsupported == true)
			or (gemData.secondaryGrantedEffect and gemData.secondaryGrantedEffect.unsupported == true))
		for _, effect in ipairs(gemData and gemData.grantedEffectList or { }) do
			if effect and effect.unsupported == true then hasUnsupportedEffect = true break end
		end
		if hasUnsupportedEffect then unsupportedEffectRecords = unsupportedEffectRecords + 1 end
	end
	local includedCount = 0
	for _ in pairs(includedRecords) do includedCount = includedCount + 1 end
	local counts = { }
	for key, value in pairs(summary.counts) do counts[key] = value end
	counts.loadedGemRecords = loadedRecords
	counts.includedGemRecords = includedCount
	counts.nonSelectableGemRecords = math.max(0, loadedRecords - includedCount)
	counts.recordsWithUnsupportedEffects = unsupportedEffectRecords
	counts.declaredActiveSkillGemRecords = summary.counts.declaredActiveSkillGemRecords
	counts.selectableActiveSkillGemRecords = summary.counts.selectableActiveSkillGemRecords
	counts.excludedActiveSkillGemRecords = summary.counts.excludedActiveSkillGemRecords
	counts.unsupportedActiveSkillGemRecords = summary.counts.unsupportedActiveSkillGemRecords
	counts.activeSkillGemRecordsMissingEffect = summary.counts.activeSkillGemRecordsMissingEffect
	return {
		schema = "pob-skill-catalog-coverage",
		schemaVersion = 2,
		game = summary.game,
		source = summary.source,
		evaluationStatus = "catalog_only",
		exactEvaluated = false,
		combinationCoverage = "not_evaluated",
		version = summary.version,
		versionIdentityStatus = summary.versionIdentityStatus,
		dataVersionSource = summary.dataVersionSource,
		counts = counts,
		tagCoverage = {
			semantics = "Overlapping tag counts from PoB tagString; one gem/effect may count under multiple tags.",
			activeGemVariants = countDisplayTags(activeGems),
			activeSkillEffects = countDisplayTags(activeEffects),
			supportGemVariants = countDisplayTags(supports),
			excludedActiveSkillGemVariants = countDisplayTags(excludedActiveGems),
		},
		catalogs = {
			activeGemVariants = catalogRows(activeGems),
			activeSkillEffects = catalogRows(activeEffects),
			supportGemVariants = catalogRows(supports),
			excludedActiveSkillGemVariants = catalogRows(excludedActiveGems),
		},
	}
end

-- Select a deterministic, rotating sample from every native priority bucket.
-- Repeating the search with different seeds walks the full gem catalog instead
-- of permanently truncating to the alphabetically first supports. This affects
-- proposal order only; PoB's exact calculator and legality checks stay decisive.
local supportFocusTerms = {
	PhysicalHit = { "physical", "attack", "melee" },
	PhysicalImpale = { "impale", "physical" },
	PhysicalDoT = { "bleed", "physical", "damage over time" },
	Fire = { "fire", "elemental" },
	Cold = { "cold", "elemental" },
	Lightning = { "lightning", "elemental" },
	ChaosPoison = { "chaos", "poison" },
	Minions = { "minion" },
}

function catalog.SupportFocusPenalty(gemData, damageFocus)
	local terms = supportFocusTerms[tostring(damageFocus or "Auto")]
	if not terms then return 0 end
	local effect = gemData and (gemData.grantedEffect or gemData.secondaryGrantedEffect)
	local text = table.concat({
		tostring(gemData and gemData.name or ""),
		tostring(gemData and gemData.baseName or ""),
		tostring(gemData and gemData.variantId or ""),
		tostring(gemData and gemData.tagString or ""),
		tostring(gemData and gemData.grantedEffectId or ""),
		tostring(effect and effect.name or ""),
		tostring(effect and effect.id or ""),
	}, " "):lower()
	for tag, enabled in pairs(gemData and gemData.tags or { }) do
		if enabled == true then text = text .. " " .. tostring(tag):lower() end
	end
	for _, term in ipairs(terms) do
		if text:find(term, 1, true) then return 0 end
	end
	return 1
end

function catalog.SelectSupportVariants(choices, limit, seed)
	local boundedLimit = tonumber(limit) or 0
	if boundedLimit ~= math.floor(boundedLimit) or boundedLimit < 0 then
		return nil, "Support candidate limit must be a non-negative integer"
	end
	local boundedSeed = tonumber(seed) or 0
	if boundedSeed ~= math.floor(boundedSeed) or math.abs(boundedSeed) > 2147483647 then
		return nil, "Support candidate seed must be a signed 32-bit integer"
	end
	local buckets, priorities = { }, { }
	for _, choice in ipairs(choices or { }) do
		local priority = tonumber(choice.priority) or 0
		if not buckets[priority] then
			buckets[priority] = { }
			priorities[#priorities + 1] = priority
		end
		buckets[priority][#buckets[priority] + 1] = choice
	end
	table.sort(priorities)
	for _, priority in ipairs(priorities) do
		table.sort(buckets[priority], function(a, b)
			local left = tostring(a.gem and (a.gem.variantId or a.gem.id) or a.id or "")
			local right = tostring(b.gem and (b.gem.variantId or b.gem.id) or b.id or "")
			if left ~= right then return left < right end
			return tostring(a.gem and a.gem.id or a.id or "") < tostring(b.gem and b.gem.id or b.id or "")
		end)
	end
	local selected, bucketOffsets = { }, { }
	for bucketIndex, priority in ipairs(priorities) do
		local bucket = buckets[priority]
		bucketOffsets[bucketIndex] = #bucket > 0 and ((math.abs(boundedSeed) + bucketIndex - 1) % #bucket) or 0
	end
	-- Priority is a native legality/compatibility signal, not a diversity label.
	-- Exhaust the highest-priority bucket before admitting lower-priority choices;
	-- seed rotation still prevents one alphabetic prefix from monopolizing it.
	for bucketIndex, priority in ipairs(priorities) do
		local bucket = buckets[priority]
		local take = math.min(#bucket, boundedLimit - #selected)
		for index = 1, take do
			local selectedIndex = ((bucketOffsets[bucketIndex] + index - 1) % #bucket) + 1
			selected[#selected + 1] = bucket[selectedIndex]
		end
		if #selected >= boundedLimit then break end
	end
	return selected, {
		available = #(choices or { }),
		selected = #selected,
		truncated = #selected < #(choices or { }),
		seed = boundedSeed,
	}
end

-- Validate the complete physical socket group against the exact item-set view
-- used for a candidate. This is intentionally separate from the provisional
-- support-search path: Equipment-phase winners must be socketed and linked.
local function validateGrantedSkillGroup(build, group, groupIndex, itemsTabOverride, itemSetOverride)
	local source = type(group.source) == "string" and group.source or ""
	local skill = group.gemList and group.gemList[1]
	local skillId = skill and skill.skillId
	if not skillId then return false, "The PoB-granted skill group has no native skill identity" end

	local itemIdText, itemName = source:match("^Item:(%d+):(.+)$")
	if itemIdText then
		local itemId = tonumber(itemIdText)
		local itemsTab = itemsTabOverride or (build and build.itemsTab)
		local itemSet = itemSetOverride or (itemsTab and (itemsTab.activeItemSet
			or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId]))
		local slotName = group.slot
		local slot = type(slotName) == "string" and itemsTab and itemsTab.slots and itemsTab.slots[slotName]
		if not itemId or itemId < 1 or itemId ~= math.floor(itemId) or not slot then
			return false, "The PoB item-granted skill points to an invalid or unavailable native slot"
		end
		if not itemSet then return false, "The PoB item-granted skill has no active item set to validate against" end
		local activeWeaponSet = itemSet.useSecondWeaponSet and 2 or 1
		if slot.weaponSet and slot.weaponSet ~= activeWeaponSet then
			return false, "The PoB item-granted skill belongs to the inactive weapon set"
		end

		local equippedItemId
		if slot.nodeId then
			local spec = build and build.spec
			if not spec or not spec.allocNodes or not spec.allocNodes[slot.nodeId] then
				return false, "The PoB item-granted skill jewel socket is not connected and allocated"
			end
			equippedItemId = spec.jewels and tonumber(spec.jewels[slot.nodeId])
		else
			local entry = itemSet[slotName]
			equippedItemId = entry and tonumber(entry.selItemId)
		end
		if equippedItemId ~= itemId then
			return false, "The PoB item-granted skill source is not the item currently equipped in its declared slot"
		end

		local item = itemsTab.items and itemsTab.items[itemId]
		if not item then return false, "The PoB item-granted skill source item is missing from the active item collection" end
		local expectedSource = item.modSource
		if type(expectedSource) == "string" then
			if source ~= expectedSource then
				return false, "The PoB item-granted skill source no longer matches the equipped item's native identity"
			end
		elseif type(item.name) == "string" and item.name ~= itemName then
			return false, "The PoB item-granted skill source name no longer matches the equipped item"
		end
		if type(item.grantedSkills) ~= "table" then
			return false, "The equipped PoB item does not expose native granted-skill data"
		end
		for _, grantedSkill in ipairs(item.grantedSkills) do
			if grantedSkill.source == source and grantedSkill.skillId == skillId then
				return true, {
					status = "granted_skill",
					sourceKind = "item",
					groupIndex = groupIndex,
					slot = slotName,
					itemId = itemId,
					source = source,
					skillId = skillId,
				}
			end
		end
		return false, "The equipped PoB item does not grant the skill recorded in this group"
	end

	if source:match("^Item:") then
		return false, "The PoB item-granted skill has a malformed native item source"
	end
	local nodeIdText = source:match("^Tree:(%d+)$")
	if nodeIdText then
		local nodeId = tonumber(nodeIdText)
		local node = build and build.spec and build.spec.allocNodes and build.spec.allocNodes[nodeId]
		if not node then return false, "The PoB tree-granted skill source node is not allocated" end
		for _, grantedSkill in ipairs(node.grantedSkills or { }) do
			if grantedSkill.source == source and grantedSkill.skillId == skillId then
				return true, { status = "granted_skill", sourceKind = "tree", groupIndex = groupIndex, nodeId = nodeId }
			end
		end
		return false, "The allocated PoB tree node does not grant the skill recorded in this group"
	end
	if source == "Explode" and type(group.explodeSources) == "table" and #group.explodeSources > 0 then
		return true, { status = "granted_skill", sourceKind = "explode", groupIndex = groupIndex }
	end
	return false, "The PoB-granted skill source is not recognized by the native build model"
end

-- Candidate.Apply validates the exact route against a disposable equipment set
-- before changing the user's active build. Item-granted skill groups in that
-- preflight must point at the candidate's equipped item, not the source build's
-- item object. Rebind only from the exact socket proof and PoB's native grant
-- table; the normal socket validator still performs the final certification.
function catalog.RebindPlannerGrantedSkillGroups(build, proof, itemsTabOverride, itemSetOverride, groupOverrides)
	if type(proof) ~= "table" or type(proof.groups) ~= "table" or type(groupOverrides) ~= "table" then
		return false, "The exact planner socket proof or candidate skill groups are unavailable"
	end
	local itemsTab = itemsTabOverride or (build and build.itemsTab)
	local itemSet = itemSetOverride or (itemsTab and (itemsTab.activeItemSet
		or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId]))
	if not itemsTab or not itemSet then
		return false, "The candidate item set is unavailable for granted-skill rebinding"
	end
	for _, entry in ipairs(proof.groups) do
		local detail = entry and entry.group
		if entry and entry.status == "granted_skill" and type(detail) == "table"
			and detail.sourceKind == "item" then
			local groupIndex = tonumber(entry.groupIndex or detail.groupIndex)
			local itemId = tonumber(detail.itemId)
			local slotName = detail.slot
			local source = detail.source
			local skillId = detail.skillId
			if not groupIndex or groupIndex < 1 or groupIndex ~= math.floor(groupIndex)
				or not itemId or itemId < 1 or itemId ~= math.floor(itemId)
				or type(slotName) ~= "string" or slotName == ""
				or type(source) ~= "string" or not source:match("^Item:")
				or type(skillId) ~= "string" or skillId == "" then
				return false, "The exact item-granted skill proof is missing its native item, slot, source, or skill identity"
			end
			local slot = itemsTab.slots and itemsTab.slots[slotName]
			if not slot or slot.nodeId then
				return false, "The exact item-granted skill proof points to an unsupported or unavailable jewel slot"
			end
			local equipped = itemSet[slotName]
			if tonumber(equipped and equipped.selItemId) ~= itemId then
				return false, "The exact item-granted skill proof no longer matches the candidate equipment slot"
			end
			local item = itemsTab.items and itemsTab.items[itemId]
			if not item or item.modSource ~= source or type(item.grantedSkills) ~= "table" then
				return false, "The exact item-granted skill proof no longer matches PoB's native item data"
			end
			local nativeGrant
			for _, grant in ipairs(item.grantedSkills) do
				if grant.source == source and grant.skillId == skillId then
					nativeGrant = grant
					break
				end
			end
			if not nativeGrant then
				return false, "The candidate item no longer grants the exact skill certified by PoB"
			end
			while #groupOverrides < groupIndex do
				groupOverrides[#groupOverrides + 1] = { enabled = false, slotEnabled = false, gemList = { } }
			end
			local group = groupOverrides[groupIndex]
			if type(group) ~= "table" then
				group = { }
				groupOverrides[groupIndex] = group
			end
			local gem = group.gemList and group.gemList[1] or { }
			local gemId = build and build.data and build.data.gemForSkill and build.data.gemForSkill[skillId]
			local gemData = gemId and build.data.gems and build.data.gems[gemId]
			local skillData = build and build.data and build.data.skills and build.data.skills[skillId]
			gem.skillId = skillId
			gem.gemId = gemData and gemData.id or gem.gemId
			gem.nameSpec = (gemData and gemData.name) or (skillData and skillData.name) or gem.nameSpec
			gem.gemData = gemData or gem.gemData
			gem.grantedEffect = (gemData and gemData.grantedEffect) or skillData or gem.grantedEffect
			gem.fromItem = true
			gem.enabled = true
			group.gemList = { gem }
			group.source = source
			group.sourceItem = item
			group.sourceNode = nil
			group.slot = slotName
			group.enabled = true
			group.slotEnabled = true
			group.noSupports = nativeGrant.noSupports
		end
	end
	return true
end

-- Candidate calculations run in CALCULATOR mode, which computes the exact
-- grants for the candidate item/tree state but deliberately does not rewrite
-- the Skills tab. Reconcile only the isolated candidate proxy so stale groups
-- from the source build cannot contribute ghost skills after an item swap.
-- Group positions are kept stable because Main Skill and gem-variant proofs
-- refer to them by index.
function catalog.ReconcileGrantedSkillGroups(build, env)
	local skillsTab = build and build.skillsTab
	local groups = skillsTab and skillsTab.socketGroupList
	if type(groups) ~= "table" or type(env) ~= "table" then
		return nil, "PoB did not expose candidate skill groups and calculation environment"
	end
	local result = { changed = false, added = 0, updated = 0, disabled = 0, explodeUpdated = false }
	local changedGroups = { }
	local changedFieldsByGroup = { }
	local seen = { }
	local function assign(target, key, value)
		if target[key] ~= value then
			target[key] = value
			return true
		end
		return false
	end
	local function sameNativeReference(field, first, second, stableSource)
		if first == second then return true end
		if type(first) ~= "table" or type(second) ~= "table" then return false end
		if field == "sourceItem" then
			local firstId, secondId = tonumber(first.id), tonumber(second.id)
			local firstSource, secondSource = tostring(first.modSource or ""), tostring(second.modSource or "")
			if firstId ~= nil and secondId ~= nil then
				return firstId == secondId and firstSource == secondSource
			end
			-- Some native grants carry a lightweight source descriptor without a
			-- numeric item id. Its nonempty modSource is still a stable identity
			-- across CalcPerform's disposable environments.
			return firstSource ~= "" and firstSource == secondSource
		end
		if field == "sourceNode" then
			local firstId = tonumber(first.id or first.nodeId)
			local secondId = tonumber(second.id or second.nodeId)
			if firstId ~= nil and secondId ~= nil then return firstId == secondId end
			local stableNodeId = tonumber(tostring(stableSource or ""):match("^Tree:(%d+)$"))
			return stableNodeId ~= nil
				and (firstId == nil or firstId == stableNodeId)
				and (secondId == nil or secondId == stableNodeId)
		end
		return false
	end
	local function assignNativeReference(target, key, value)
		local changed = not sameNativeReference(key, target[key], value, target.source)
		target[key] = value
		return changed
	end
	local function normalizedGrantLevel(grantedSkill)
		local data = build.data or { }
		local gemId = data.gemForSkill and data.gemForSkill[grantedSkill.skillId]
		local gemData = gemId and data.gems and data.gems[gemId]
		local grantedEffect = data.skills and data.skills[grantedSkill.skillId]
		if gemData or grantedEffect then
			local instance = { level = grantedSkill.level, gemData = gemData }
			if not gemData then instance.grantedEffect = grantedEffect end
			if calcLib and type(calcLib.validateGemLevel) == "function" then
				local ok = pcall(calcLib.validateGemLevel, instance)
				if ok and instance.level ~= nil then return instance.level end
			end
		end
		return grantedSkill.level
	end
	local function normalizedGrantName(grantedSkill)
		local data = build.data or { }
		local gemId = data.gemForSkill and data.gemForSkill[grantedSkill.skillId]
		local gemData = gemId and data.gems and data.gems[gemId]
		-- SkillsTab:ProcessSocketGroup canonicalizes nameSpec to gemData.name for
		-- grants that map back to a normal gem. Use the same value here; otherwise
		-- a missing or legacy grant name is written on every reconciliation pass,
		-- then immediately replaced by ProcessSocketGroup, so no candidate can
		-- reach a stable exact calculation.
		local skillData = data.skills and data.skills[grantedSkill.skillId]
		return gemData and gemData.name or (skillData and skillData.name) or grantedSkill.nameSpec
	end
	local function grantKey(source, slot, skillId)
		return table.concat({ tostring(source or ""), tostring(slot or ""), tostring(skillId or "") }, "\31")
	end
	local function processGroup(group, index)
		if type(skillsTab.ProcessSocketGroup) == "function" then
			local ok, err = pcall(skillsTab.ProcessSocketGroup, skillsTab, group)
			if not ok then return false, "PoB could not rebuild granted skill group " .. tostring(index) .. ": " .. tostring(err) end
		end
		return true
	end
	local function ensureGrantGroup(grantedSkill)
		local source = grantedSkill and grantedSkill.source
		local slotName = grantedSkill and grantedSkill.slotName
		local skillId = grantedSkill and grantedSkill.skillId
		if type(source) ~= "string" or source == "" or type(skillId) ~= "string" or skillId == "" then
			return nil, "PoB returned a granted skill without a native source or skill identity"
		end
		local key = grantKey(source, slotName, skillId)
		local group, groupIndex
		for index, candidate in ipairs(groups) do
			if candidate and candidate.source ~= "Explode"
				and grantKey(candidate.source, candidate.slot, candidate.gemList and candidate.gemList[1] and candidate.gemList[1].skillId) == key
				and not seen[candidate] then
				group, groupIndex = candidate, index
				break
			end
		end
		local isNew = false
		if not group then
			group = { label = "", enabled = true, gemList = { }, source = source, slot = slotName }
			groups[#groups + 1] = group
			groupIndex = #groups
			isNew = true
			result.added = result.added + 1
		end
		seen[group] = true
		local changed = isNew
		local changedFields = { }
		if isNew then changedFields[#changedFields + 1] = "newGroup" end
		local function assignAndTrack(target, field, value)
			local fieldChanged = assign(target, field, value)
			if fieldChanged then changedFields[#changedFields + 1] = field end
			return fieldChanged
		end
		local function assignNativeAndTrack(field, value)
			local fieldChanged = assignNativeReference(group, field, value)
			if fieldChanged then changedFields[#changedFields + 1] = field end
			return fieldChanged
		end
		changed = assignAndTrack(group, "source", source) or changed
		changed = assignAndTrack(group, "slot", slotName) or changed
		changed = assignNativeAndTrack("sourceItem", grantedSkill.sourceItem) or changed
		changed = assignNativeAndTrack("sourceNode", grantedSkill.sourceNode) or changed
		changed = assignAndTrack(group, "noSupports", grantedSkill.noSupports) or changed
		local gem = group.gemList and group.gemList[1]
		if not gem then
			gem = { quality = 0, enabled = true }
			changed = true
			changedFields[#changedFields + 1] = "gem"
		end
		local gemFields = {
			"fromItem", "gemId", "skillId", "nameSpec", "level", "enableGlobal1",
			"noSupports", "triggered", "triggerChance",
		}
		local gemValues = {
			fromItem = grantedSkill.sourceItem ~= nil,
			gemId = nil,
			skillId = skillId,
			nameSpec = normalizedGrantName(grantedSkill),
			level = normalizedGrantLevel(grantedSkill),
			enableGlobal1 = true,
			noSupports = grantedSkill.noSupports,
			triggered = grantedSkill.triggered,
			triggerChance = grantedSkill.triggerChance,
		}
		for _, field in ipairs(gemFields) do changed = assignAndTrack(gem, field, gemValues[field]) or changed end
		if not group.gemList or #group.gemList ~= 1 or group.gemList[1] ~= gem then
			group.gemList = { gem }
			changed = true
			changedFields[#changedFields + 1] = "gemList"
		end
		if changed then
			result.updated = result.updated + (isNew and 0 or 1)
			changedGroups[groupIndex] = group
			changedFieldsByGroup[groupIndex] = changedFields
		end
		return group, groupIndex
	end

	for _, grantedSkill in ipairs(env.grantedSkills or { }) do
		local group, groupIndexOrError = ensureGrantGroup(grantedSkill)
		if not group then return nil, groupIndexOrError end
		local ok, err = processGroup(group, groupIndexOrError)
		if not ok then return nil, err end
	end

	local staleGroups = { }
	for index, group in ipairs(groups) do
		if group and type(group.source) == "string" and group.source ~= "" and group.source ~= "Explode"
			and not seen[group] then
			staleGroups[#staleGroups + 1] = { index = index, group = group }
		end
	end
	for _, row in ipairs(staleGroups) do
		local group = row.group
		local changed = assign(group, "enabled", false)
		if type(group.gemList) == "table" and #group.gemList > 0 then
			group.gemList = { }
			changed = true
		end
		if type(group.displaySkillList) == "table" and #group.displaySkillList > 0 then
			group.displaySkillList = { }
			changed = true
		end
		if type(group.displaySkillListCalcs) == "table" and #group.displaySkillListCalcs > 0 then
			group.displaySkillListCalcs = { }
			changed = true
		end
		changed = assignNativeReference(group, "sourceItem", nil) or changed
		changed = assignNativeReference(group, "sourceNode", nil) or changed
		changed = assign(group, "explodeSources", nil) or changed
		if changed then
			result.disabled = result.disabled + 1
			changedGroups[row.index] = group
		end
	end

	local explodeSources = env.explodeSources or { }
	local explodeGroup, explodeIndex
	for index, group in ipairs(groups) do
		if group and group.source == "Explode" then explodeGroup, explodeIndex = group, index; break end
	end
	if #explodeSources == 0 then
		if explodeGroup then
			local changed = assign(explodeGroup, "enabled", false)
			if type(explodeGroup.gemList) == "table" and #explodeGroup.gemList > 0 then
				explodeGroup.gemList = { }
				changed = true
			end
			if type(explodeGroup.displaySkillList) == "table" and #explodeGroup.displaySkillList > 0 then
				explodeGroup.displaySkillList = { }
				changed = true
			end
			if type(explodeGroup.displaySkillListCalcs) == "table" and #explodeGroup.displaySkillListCalcs > 0 then
				explodeGroup.displaySkillListCalcs = { }
				changed = true
			end
			changed = assign(explodeGroup, "explodeSources", nil) or changed
			if changed then result.explodeUpdated = true; changedGroups[explodeIndex] = explodeGroup end
		end
	elseif not explodeGroup then
		explodeGroup = { label = "On Kill Monster Explosion", enabled = true, gemList = { }, source = "Explode", noSupports = true }
		groups[#groups + 1] = explodeGroup
		explodeIndex = #groups
		result.added = result.added + 1
		result.explodeUpdated = true
		changedGroups[explodeIndex] = explodeGroup
	else
		local oldGemsBySource = { }
		for _, gem in ipairs(explodeGroup.gemList or { }) do
			if gem.explodeSource then
				local sourceId = gem.explodeSource.modSource or gem.explodeSource.id
				if sourceId ~= nil then oldGemsBySource[sourceId] = gem end
			end
		end
		local rebuiltGems, sameSourceOrder = { }, true
		for _, source in ipairs(explodeSources) do
			local sourceId = source.modSource or source.id
			local gem = sourceId ~= nil and oldGemsBySource[sourceId] or nil
			if not gem then
				sameSourceOrder = false
				gem = { skillId = "EnemyExplode", quality = 0, enabled = true, level = 1,
					triggered = true, explodeSource = source }
			end
			gem.explodeSource = source
			rebuiltGems[#rebuiltGems + 1] = gem
		end
		local changed = not sameSourceOrder
		if #rebuiltGems ~= #(explodeGroup.gemList or { }) then
			changed = true
		else
			for index, gem in ipairs(rebuiltGems) do
				local existing = explodeGroup.gemList[index]
				local sourceId = gem.explodeSource and (gem.explodeSource.modSource or gem.explodeSource.id)
				local existingId = existing and existing.explodeSource
					and (existing.explodeSource.modSource or existing.explodeSource.id)
				if gem ~= existing or sourceId ~= existingId then changed = true; break end
			end
		end
		local sameExplodeSources = #explodeSources == #(explodeGroup.explodeSources or { })
		if sameExplodeSources then
			for index, source in ipairs(explodeSources) do
				local sourceId = source.modSource or source.id
				local oldSource = explodeGroup.explodeSources[index]
				local oldSourceId = oldSource and (oldSource.modSource or oldSource.id)
				if sourceId ~= oldSourceId then sameExplodeSources = false; break end
			end
		end
		explodeGroup.explodeSources = explodeSources
		changed = not sameExplodeSources or changed
		changed = assign(explodeGroup, "noSupports", true) or changed
		if changed then
			explodeGroup.gemList = rebuiltGems
			result.explodeUpdated = true
			changedGroups[explodeIndex] = explodeGroup
		end
	end

	for index, group in pairs(changedGroups) do
		if group.source == "Explode" or (#(group.gemList or { }) > 0) then
			local ok, err = processGroup(group, index)
			if not ok then return nil, err end
		end
	end
	if next(changedGroups) and type(skillsTab.UpdateSocketGroups) == "function" then
		local ok, err = pcall(skillsTab.UpdateSocketGroups, skillsTab)
		if not ok then return nil, "PoB could not refresh candidate skill sockets: " .. tostring(err) end
	end
	result.changed = next(changedGroups) ~= nil
	result.status = result.changed and "changed" or "unchanged"
	result.changedGroupCount = 0
	result.changedGroupSummaries = { }
	for index, group in pairs(changedGroups) do
		result.changedGroupCount = result.changedGroupCount + 1
		local gem = group.gemList and group.gemList[1]
		result.changedGroupSummaries[#result.changedGroupSummaries + 1] = table.concat({
			tostring(index), tostring(group.source or "manual"), tostring(group.slot or ""),
			tostring(gem and gem.skillId or ""), tostring(gem and gem.nameSpec or ""),
			"fields=" .. table.concat(changedFieldsByGroup[index] or { }, "+"),
		}, ":"):sub(1, 180)
	end
	table.sort(result.changedGroupSummaries)
	return result
end

function catalog.ValidateSocketGroup(build, groupIndex, itemsTabOverride, itemSetOverride, groupOverride, socketGroupsOverride)
	local groups = socketGroupsOverride or (build and build.skillsTab and build.skillsTab.socketGroupList) or { }
	local group = groupOverride or groups[groupIndex]
	if not group then return false, "The selected PoB socket group no longer exists" end
	if group.enabled == false or group.slotEnabled == false then
		return false, "The selected PoB skill group is disabled"
	end
	if isGrantedSkillGroup(group) then
		return validateGrantedSkillGroup(build, group, groupIndex, itemsTabOverride, itemSetOverride)
	end
	if type(group.slot) ~= "string" or group.slot == "" then
		return false, "The selected manual Main Skill group has no equipment socket"
	end
	local itemsTab = itemsTabOverride or (build and build.itemsTab)
	local itemSet = itemSetOverride or (itemsTab and (itemsTab.activeItemSet
		or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId]))
	local slot = itemsTab and itemsTab.slots and itemsTab.slots[group.slot]
	if not slot or not itemSet then return false, "The selected skill group points to an unavailable equipment slot" end
	local activeWeaponSet = itemSet.useSecondWeaponSet and 2 or 1
	if slot.weaponSet and slot.weaponSet ~= activeWeaponSet then
		return false, "The selected skill group is assigned to the inactive weapon set"
	end
	local entry = itemSet[group.slot]
	local itemId = entry and tonumber(entry.selItemId)
	local item = itemId and itemId > 0 and itemsTab.items and itemsTab.items[itemId]
	if not item or type(item.sockets) ~= "table" then
		return false, "The selected skill group's equipped PoB item has no native socket data"
	end
	local socketOffset = 0
	for currentIndex, currentGroup in ipairs(groups) do
		local currentSlot = currentGroup.slot and itemsTab.slots[currentGroup.slot]
		local currentGroupActive = currentGroup.enabled ~= false and currentGroup.slotEnabled ~= false
			and not isGrantedSkillGroup(currentGroup)
			and not (currentSlot and currentSlot.weaponSet and currentSlot.weaponSet ~= activeWeaponSet)
		if currentGroup.slot == group.slot and currentGroupActive then
			if currentIndex == groupIndex then break end
			socketOffset = socketOffset + #(currentGroup.gemList or { })
		end
	end
	if #(group.gemList or { }) == 0 then return false, "The selected PoB skill group has no gems to socket" end
	local expectedLinkGroup
	local colorMap = { [1] = "R", [2] = "G", [3] = "B", [4] = "W", R = "R", G = "G", B = "B", W = "W" }
	for gemIndex, gem in ipairs(group.gemList) do
		local socketIndex = socketOffset + gemIndex
		local socket = item.sockets[socketIndex]
		if not socket or socket.group == nil then
			return false, string.format("PoB item %s has no native socket at the selected group's gem %d", group.slot, gemIndex)
		end
		if expectedLinkGroup == nil then
			expectedLinkGroup = socket.group
		elseif socket.group ~= expectedLinkGroup then
			return false, "The Main Skill and its supports span more than one native item link group"
		end
		local gemData = gem.gemData or (gem.gemId and build.data and build.data.gems and build.data.gems[gem.gemId])
		local effect = gem.grantedEffect
		if not (effect and effect.support) then
			effect = (gemData and supportEffect(gemData)) or effect or (gemData and gemData.grantedEffect)
		end
		-- Match SkillsTab:OptimiseSockets, which treats effects without an RGB
		-- color as white. This keeps the validator aligned with PoB's own socket
		-- display and avoids inventing a separate color rule for special gems.
		local requiredColor = colorMap[effect and effect.color] or "W"
		if not item.sockets.colourAlwaysMatches then
			local socketColor = tostring(socket.color or ""):upper()
			if socketColor ~= requiredColor and socketColor ~= "W" then
				return false, string.format("Gem %s needs a %s socket but PoB item slot %s has %s at position %d",
					tostring(gemData and gemData.name or gem.nameSpec or gem.gemId), requiredColor, group.slot,
					socketColor ~= "" and socketColor or "no socket", socketIndex)
			end
		end
	end
	return true, {
		status = "linked",
		groupIndex = groupIndex,
		slot = group.slot,
		itemId = itemId,
		firstSocketIndex = socketOffset + 1,
		socketCount = #group.gemList,
		linkGroup = expectedLinkGroup,
	}
end

local function isEnabledSocketGroup(build, group, itemsTab, itemSet)
	if not group or group.enabled == false or group.slotEnabled == false
		or type(group.gemList) ~= "table" or #group.gemList == 0 then
		return false
	end
	if not isGrantedSkillGroup(group) and type(group.slot) == "string" and itemsTab and itemsTab.slots then
		local slot = itemsTab.slots[group.slot]
		local activeWeaponSet = itemSet and itemSet.useSecondWeaponSet and 2 or 1
		if slot and slot.weaponSet and slot.weaponSet ~= activeWeaponSet then return false end
	end
	return true
end

-- Certify every populated skill group that is active in the selected item set.
-- PoB can calculate configured supports even when the item's physical socket
-- colors or links cannot host them, so this proof is required before a route is
-- considered playable.
function catalog.ValidateEnabledSocketGroups(build, itemsTabOverride, itemSetOverride, groupOverrides)
	local itemsTab = itemsTabOverride or (build and build.itemsTab)
	local itemSet = itemSetOverride or (itemsTab and (itemsTab.activeItemSet
		or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId]))
	local sourceGroups = build and build.skillsTab and build.skillsTab.socketGroupList or { }
	local groups = groupOverrides or sourceGroups
	local validationBuild = build
	if groupOverrides and build and build.skillsTab and groupOverrides ~= sourceGroups then
		local skillsTab = { socketGroupList = groupOverrides }
		setmetatable(skillsTab, { __index = build.skillsTab })
		validationBuild = { skillsTab = skillsTab, itemsTab = itemsTab, data = build.data, spec = build.spec }
		setmetatable(validationBuild, { __index = build })
	end
	local proof = { status = "pass", scope = "all_enabled_active_groups", groups = { }, violations = { } }
	for groupIndex, group in ipairs(groups) do
		if isEnabledSocketGroup(validationBuild, group, itemsTab, itemSet) then
			local ok, valid, detail = pcall(catalog.ValidateSocketGroup,
				validationBuild, groupIndex, itemsTab, itemSet, group, groups)
			local status = type(detail) == "table" and detail.status or nil
			if ok and valid == true and (status == "linked" or status == "granted_skill") then
				proof.groups[#proof.groups + 1] = {
					groupIndex = groupIndex,
					label = tostring(group.displayLabel or group.label or group.slot or ("Skill group " .. groupIndex)),
					status = status,
					group = detail,
				}
			else
				local reason = ok and type(detail) == "string" and detail
					or (not ok and tostring(valid))
					or "PoB did not certify this active skill group against native item sockets"
				local label = tostring(group.displayLabel or group.label or group.slot or ("Skill group " .. groupIndex))
				proof.status = "invalid"
				proof.groups[#proof.groups + 1] = {
					groupIndex = groupIndex,
					label = label,
					status = "invalid",
					reason = tostring(reason),
				}
				proof.violations[#proof.violations + 1] = {
					key = "active_skill_socket_link",
					label = "Active skill group socket/link",
					groupIndex = groupIndex,
					group = label,
					slot = group.slot,
					reason = tostring(reason),
					deficit = 1,
				}
			end
		end
	end
	return #proof.violations == 0, proof
end

local function plannerSocketGroupIdentity(group)
	if type(group) ~= "table" then return nil end
	local gemIds = { }
	for _, gem in ipairs(group.gemList or { }) do
		local gemData = gem.gemData
		gemIds[#gemIds + 1] = tostring(gem.gemId or (gemData and gemData.id) or gem.nameSpec or "")
	end
	-- PoB rebuilds item- and tree-granted groups while applying equipment and
	-- passive variants. Their source references can legitimately change even
	-- when the same playable group remains. Match the stable gameplay identity:
	-- assigned equipment slot plus ordered gem IDs. Callers retain duplicate
	-- identities as separate entries so two source groups cannot collapse into
	-- one proof.
	return table.concat({ tostring(group.slot or ""), table.concat(gemIds, ",") }, "\31")
end

-- Single-skill route planning must require the selected Main Skill's exact
-- socket proof, while preserving every other skill group that was already
-- playable in the source build. Pre-existing broken secondary groups remain
-- visible diagnostics, but cannot make every unrelated Main Skill route fail.
function catalog.ValidatePlannerSocketGroups(sourceBuild, candidateBuild, selectedGroupIndex,
	itemsTabOverride, itemSetOverride, groupOverrides)
	local selectedIndex = tonumber(selectedGroupIndex)
	local proof = {
		status = "pass",
		scope = "single_skill_preserve_existing_links",
		selectedGroupIndex = selectedIndex,
		groups = { },
		violations = { },
		ignoredInvalidBaselineGroups = 0,
	}
	if not selectedIndex or selectedIndex < 1 or selectedIndex ~= math.floor(selectedIndex) then
		proof.status = "invalid"
		proof.violations[1] = { key = "active_skill_socket_link", label = "Selected Main Skill socket/link",
			reason = "Single-skill route proof has no valid selected group index", deficit = 1 }
		return false, proof
	end
	local _, baselineProof = catalog.ValidateEnabledSocketGroups(sourceBuild)
	local _, candidateProof = catalog.ValidateEnabledSocketGroups(candidateBuild,
		itemsTabOverride, itemSetOverride, groupOverrides)
	local sourceGroups = sourceBuild and sourceBuild.skillsTab and sourceBuild.skillsTab.socketGroupList or { }
	local candidateGroups = groupOverrides or (candidateBuild and candidateBuild.skillsTab
		and candidateBuild.skillsTab.socketGroupList) or { }
	local baselineByIdentity = { }
	local baselineInvalid = { }
	for _, entry in ipairs(baselineProof and baselineProof.groups or { }) do
		local group = sourceGroups[tonumber(entry.groupIndex)]
		local identity = plannerSocketGroupIdentity(group)
		if entry.status == "linked" or entry.status == "granted_skill" then
			if tonumber(entry.groupIndex) ~= selectedIndex and identity then
				baselineByIdentity[identity] = baselineByIdentity[identity] or { }
				baselineByIdentity[identity][#baselineByIdentity[identity] + 1] = entry
			end
		elseif tonumber(entry.groupIndex) ~= selectedIndex then
			baselineInvalid[tonumber(entry.groupIndex)] = true
		end
	end
	local candidateByIdentity = { }
	local candidateByIndex = { }
	for _, entry in ipairs(candidateProof and candidateProof.groups or { }) do
		local groupIndex = tonumber(entry.groupIndex)
		local group = groupIndex and candidateGroups[groupIndex]
		local identity = plannerSocketGroupIdentity(group)
		candidateByIndex[groupIndex] = entry
		if identity then
			candidateByIdentity[identity] = candidateByIdentity[identity] or { }
			candidateByIdentity[identity][#candidateByIdentity[identity] + 1] = entry
		end
	end
	local selectedEntry = candidateByIndex[selectedIndex]
	if selectedEntry and (selectedEntry.status == "linked" or selectedEntry.status == "granted_skill") then
		proof.groups[#proof.groups + 1] = selectedEntry
	else
		local reason = selectedEntry and selectedEntry.reason or "The selected Main Skill group is not active in the candidate"
		proof.status = "invalid"
		proof.violations[#proof.violations + 1] = {
			key = "active_skill_socket_link",
			label = "Selected Main Skill socket/link",
			groupIndex = selectedIndex,
			reason = tostring(reason),
			deficit = 1,
		}
	end
	local baselineIdentities = { }
	for identity in pairs(baselineByIdentity) do baselineIdentities[#baselineIdentities + 1] = identity end
	table.sort(baselineIdentities)
	for _, identity in ipairs(baselineIdentities) do
		local candidateEntries = candidateByIdentity[identity] or { }
		for _, baselineEntry in ipairs(baselineByIdentity[identity]) do
			local candidateIndex
			for index, entry in ipairs(candidateEntries) do
				if entry.status == "linked" or entry.status == "granted_skill" then
					candidateIndex = index
					break
				end
			end
			candidateIndex = candidateIndex or (#candidateEntries > 0 and 1 or nil)
			local candidateEntry = candidateIndex and table.remove(candidateEntries, candidateIndex) or nil
			if not candidateEntry or (candidateEntry.status ~= "linked" and candidateEntry.status ~= "granted_skill") then
				proof.status = "invalid"
				proof.violations[#proof.violations + 1] = {
					key = "active_skill_socket_link",
					label = "Previously linked secondary skill group",
					groupIndex = baselineEntry.groupIndex,
					group = baselineEntry.label,
					reason = candidateEntry and candidateEntry.reason
						or "A skill group that was linked in the source build is missing from the candidate",
					deficit = 1,
				}
			else
				proof.groups[#proof.groups + 1] = candidateEntry
			end
		end
	end
	for _ in pairs(baselineInvalid) do proof.ignoredInvalidBaselineGroups = proof.ignoredInvalidBaselineGroups + 1 end
	return #proof.violations == 0, proof
end

-- Normalize the native group validator result for profiles and model inputs.
-- The PoB calculation can apply a support that is not physically usable, so
-- callers must keep calculator application separate from playability.
function catalog.SocketGroupEvidence(build, groupIndex, group)
	local callOk, valid, detail = pcall(catalog.ValidateSocketGroup, build, groupIndex, nil, nil, group)
	local result = { valid = callOk and valid == true, status = "unknown" }
	if callOk and valid == true and type(detail) == "table" then
		result.status = tostring(detail.status or "unknown")
		result.slot = detail.slot
		result.itemId = detail.itemId
		result.firstSocketIndex = detail.firstSocketIndex
		result.socketCount = detail.socketCount
		result.linkGroup = detail.linkGroup
	elseif callOk and type(detail) == "string" then
		result.status = "invalid"
		result.reason = detail:sub(1, 240)
	else
		result.reason = "native_socket_validation_unavailable"
	end
	if group and (group.enabled == false or group.slotEnabled == false) then
		result.valid = false
		result.status = "disabled"
	end
	return result
end

-- The calculator may apply a support in an enabled group whose physical item
-- sockets have the wrong color or link. Exact DPS therefore does not prove
-- that a changed gem package is playable. Check every mutated group against
-- the candidate's native item-set clone before accepting its exact result.
function catalog.ValidateChangedGemGroupSockets(candidate, build, itemsTab)
	local proof = { status = "pass", scope = "changed_gem_groups", groups = { }, violations = { } }
	local variants = type(candidate) == "table" and candidate.gemVariants or nil
	if type(variants) ~= "table" then
		variants = type(candidate) == "table" and candidate.gemVariant and { candidate.gemVariant } or { }
	end
	local groupIndices = { }
	for _, variant in ipairs(variants) do
		local groupIndex = tonumber(variant and variant.groupIndex)
		if not groupIndex or groupIndex < 1 or groupIndex ~= math.floor(groupIndex) then
			proof.status = "invalid"
			proof.violations[#proof.violations + 1] = {
				groupIndex = groupIndex,
				reason = "A changed gem variant has no valid native PoB socket-group index",
			}
		else
			groupIndices[groupIndex] = true
		end
	end
	local orderedIndices = { }
	for groupIndex in pairs(groupIndices) do orderedIndices[#orderedIndices + 1] = groupIndex end
	table.sort(orderedIndices)
	for _, groupIndex in ipairs(orderedIndices) do
		local callOk, valid, detail = pcall(catalog.ValidateSocketGroup, build, groupIndex, itemsTab)
		if not callOk or valid ~= true or type(detail) ~= "table"
			or (detail.status ~= "linked" and detail.status ~= "granted_skill") then
			proof.status = "invalid"
			local reason = callOk and type(detail) == "string" and detail
				or (not callOk and tostring(valid))
				or "PoB did not return a valid physical socket/link proof for the changed gem group"
			proof.violations[#proof.violations + 1] = { groupIndex = groupIndex, reason = tostring(reason) }
		else
			proof.groups[#proof.groups + 1] = {
				groupIndex = groupIndex,
				status = detail.status,
				group = detail,
			}
		end
	end
	return proof
end

local function alternateNativeSocketCapacity(build, itemsTab, itemSet, slotName)
	if not itemsTab or type(itemsTab.IsItemValidForSlot) ~= "function" then return 0 end
	local registry = build and build.data and build.data.itemBases or data and data.itemBases or { }
	if type(registry) ~= "table" then return 0 end
	local output = build and build.calcsTab and build.calcsTab.mainOutput or { }
	local characterLevel = tonumber(build and build.characterLevel) or 1
	local weapon1Slot = slotName == "Weapon 2" and "Weapon 1"
		or slotName == "Weapon 2 Swap" and "Weapon 1 Swap"
	local weapon1Entry = weapon1Slot and itemSet and itemSet[weapon1Slot]
	local weapon1 = weapon1Entry and tonumber(weapon1Entry.selItemId) and tonumber(weapon1Entry.selItemId) > 0
		and itemsTab.items and itemsTab.items[tonumber(weapon1Entry.selItemId)] or nil
	local cacheKey = table.concat({ tostring(slotName), tostring(characterLevel),
		tostring(output.Str or ""), tostring(output.Dex or ""), tostring(output.Int or ""),
		tostring(itemSet and itemSet.useSecondWeaponSet == true), tostring(weapon1 and weapon1.base and weapon1.base.type or "") }, "\30")
	local byKey = repairCapacityCache[registry]
	if not byKey then byKey = { }; repairCapacityCache[registry] = byKey end
	if byKey[cacheKey] ~= nil then return byKey[cacheKey] end
	local maximum = 0
	for _, base in pairs(registry) do
		local capacity = tonumber(base and base.socketLimit) or 0
		local requirements = base and base.req or { }
		local meetsRequirements = (tonumber(requirements.level) or 0) <= characterLevel
		for _, attribute in ipairs({ "Str", "Dex", "Int" }) do
			local required = tonumber(requirements[attribute:lower()]) or 0
			local available = tonumber(output[attribute])
			if required > 0 and (not available or available ~= available or available < required) then
				meetsRequirements = false
				break
			end
		end
		if meetsRequirements and capacity > maximum then
			local probe = { type = base.type, base = base }
			local callOk, valid = pcall(itemsTab.IsItemValidForSlot, itemsTab, probe, slotName, itemSet)
			if callOk and valid == true then maximum = capacity end
		end
	end
	byKey[cacheKey] = maximum
	return maximum
end

-- Build a native socket layout for a replacement item when the selected manual
-- skill group is already attached to a real item but its current sockets or
-- links cannot host the loaded gem package. The plan includes every manual
-- group on that slot so replacing the item does not silently break another
-- skill group. It describes a disposable candidate only; the active item is
-- never edited here.
function catalog.PlanSocketRepair(build, groupIndex, groupOverride, itemsTabOverride, itemSetOverride, groupOverrides)
	local groups = groupOverrides or (build and build.skillsTab and build.skillsTab.socketGroupList) or { }
	local group = groupOverride or groups[groupIndex]
	if not group or isGrantedSkillGroup(group) or type(group.slot) ~= "string" or group.slot == ""
		or group.enabled == false or group.slotEnabled == false then
		return nil
	end
	local slotName = group.slot
	if slotName:match("^[Ff][Ll][Aa][Ss][Kk]%s+%d+$") then return nil end
	local itemsTab = itemsTabOverride or build.itemsTab
	local itemSet = itemSetOverride or (itemsTab and (itemsTab.activeItemSet
		or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId]))
	if not itemsTab or not itemsTab.slots or not itemsTab.slots[slotName] or not itemSet then return nil end
	local activeWeaponSet = itemSet.useSecondWeaponSet and 2 or 1
	local slotInfo = itemsTab.slots[slotName]
	if slotInfo.weaponSet and slotInfo.weaponSet ~= activeWeaponSet then return nil end
	local itemEntry = itemSet[slotName]
	local itemId = itemEntry and tonumber(itemEntry.selItemId)
	local currentItem = itemId and itemId > 0 and itemsTab.items and itemsTab.items[itemId]
	-- Imported uniques can retain a valid native socket list while PoB has no
	-- base metadata object for that item instance. That is still enough to
	-- identify a broken link; the replacement itself must come from a compatible
	-- native base in the item registry and pass the exact slot/socket checks.
	if not currentItem or type(currentItem.sockets) ~= "table" then return nil end
	local currentSocketCapacity = math.min(6, math.max(
		tonumber(currentItem.base and currentItem.base.socketLimit) or 0,
		tonumber(currentItem.selectableSocketCount) or 0,
		#currentItem.sockets))
	-- A planner must be able to rework the item base as well as its socket
	-- layout. The equipped base can be limited to one or four sockets while a
	-- legal alternate native base in this same slot supports the selected link.
	-- Candidate generation still checks requirements, slot legality, native
	-- mod weights, and the final parsed socket layout before PoB calculates it.
	local socketCapacity = math.max(currentSocketCapacity,
		alternateNativeSocketCapacity(build, itemsTab, itemSet, slotName))
	if socketCapacity < 1 then return nil end
	local socketColors = { [1] = "R", [2] = "G", [3] = "B", [4] = "W", R = "R", G = "G", B = "B", W = "W" }
	local socketEntries, groupIndices, removableDisabledSupports = { }, { }, { }
	local nextLinkGroup = 0
	local selectedGroupIncluded = false
	for currentIndex, currentGroup in ipairs(groups) do
		-- Disabled groups and groups from the inactive weapon set do not consume
		-- physical sockets in the current PoB state. Counting them can push an
		-- otherwise repairable six-link over the six-socket limit and disable the
		-- route generator even though those gems are not part of this calculation.
		if currentGroup and currentGroup.slot == slotName
			and currentGroup.enabled ~= false and currentGroup.slotEnabled ~= false
			and not isGrantedSkillGroup(currentGroup) then
			local gemList = currentGroup.gemList
			if type(gemList) ~= "table" or #gemList == 0 then
				-- PoB may retain an empty group after its last gem was removed.
				-- It consumes no physical sockets and must not block a repair for
				-- another populated group on the same item.
				if currentIndex == groupIndex then return nil end
			else
				groupIndices[#groupIndices + 1] = currentIndex
				if currentIndex == groupIndex then selectedGroupIncluded = true end
				for gemIndex, gem in ipairs(gemList) do
					local gemData = gem.gemData or (gem.gemId and build.data and build.data.gems and build.data.gems[gem.gemId])
					local effect = gem.grantedEffect
					if not (effect and effect.support) then
						effect = (gemData and supportEffect(gemData)) or effect or (gemData and gemData.grantedEffect)
					end
					local entry = {
						groupIndex = currentIndex,
						gemIndex = gemIndex,
						gem = gem,
						gemData = gemData,
						color = socketColors[effect and effect.color] or "W",
						linkGroup = nextLinkGroup,
					}
					socketEntries[#socketEntries + 1] = entry
					local disabledSupport = gem.enabled == false and supportEffect(gemData)
					if disabledSupport then removableDisabledSupports[#removableDisabledSupports + 1] = entry end
				end
				nextLinkGroup = nextLinkGroup + 1
			end
		elseif currentGroup and currentGroup.slot == slotName and isGrantedSkillGroup(currentGroup) then
			-- Item-granted skill groups do not consume the normal socket layout.
		end
	end
	if not selectedGroupIncluded or #socketEntries == 0 then return nil end
	local removed, removedCount = { }, 0
	if #socketEntries > socketCapacity then
		table.sort(removableDisabledSupports, function(a, b)
			if a.groupIndex == b.groupIndex then return a.gemIndex > b.gemIndex end
			return a.groupIndex > b.groupIndex
		end)
		for _, entry in ipairs(removableDisabledSupports) do
			if #socketEntries - removedCount <= socketCapacity then break end
			removed[tostring(entry.groupIndex) .. ":" .. tostring(entry.gemIndex)] = entry
			removedCount = removedCount + 1
		end
	end
	if #socketEntries - removedCount > socketCapacity then return nil end
	local colors, linkGroups, gemRemovals = { }, { }, { }
	for _, entry in ipairs(socketEntries) do
		local key = tostring(entry.groupIndex) .. ":" .. tostring(entry.gemIndex)
		if removed[key] then
			local gem = entry.gem
			local gemData = entry.gemData
			gemRemovals[#gemRemovals + 1] = {
				kind = "support_remove",
				groupIndex = entry.groupIndex,
				gemIndex = entry.gemIndex,
				gemId = gemData and gemData.id or gem.gemId,
				skillId = gem.skillId or (gemData and gemData.grantedEffectId),
				nameSpec = gem.nameSpec or (gemData and gemData.name),
				name = gem.nameSpec or (gemData and gemData.name) or "disabled support",
				level = tonumber(gem.level) or 1,
				quality = tonumber(gem.quality) or 0,
				disabledSupport = true,
			}
		else
			colors[#colors + 1] = entry.color
			linkGroups[#linkGroups + 1] = entry.linkGroup
		end
	end
	table.sort(gemRemovals, function(a, b)
		if a.groupIndex == b.groupIndex then return a.gemIndex > b.gemIndex end
		return a.groupIndex < b.groupIndex
	end)
	return {
		status = "native_item_rework_required",
		groupIndex = groupIndex,
		groupIndices = groupIndices,
		slot = slotName,
		socketCount = #colors,
		colors = colors,
		linkGroups = linkGroups,
		gemRemovals = gemRemovals,
		reason = "A native item rework with compatible socket colors and links is required",
	}
end

-- Collect one native item-rework plan per invalid equipment slot. A plan from
-- PlanSocketRepair includes every active manual group on that slot so fixing a
-- Main Skill cannot leave another enabled skill physically unusable.
function catalog.PlanEnabledSocketRepairs(build)
	local valid, evidence = catalog.ValidateEnabledSocketGroups(build)
	local repairs, repairsBySlot, blockers = { }, { }, { }
	local groups = build and build.skillsTab and build.skillsTab.socketGroupList or { }
	for _, violation in ipairs(evidence.violations or { }) do
		local groupIndex = tonumber(violation.groupIndex)
		local group = groupIndex and groups[groupIndex]
		local slot = group and group.slot
		local plan = slot and repairsBySlot[slot]
		if not plan then
			plan = group and catalog.PlanSocketRepair(build, groupIndex, group) or nil
			if plan then
				repairsBySlot[plan.slot] = plan
				repairs[#repairs + 1] = plan
			end
		end
		if not plan then
			blockers[#blockers + 1] = {
				groupIndex = groupIndex,
				group = violation.group,
				slot = slot,
				reason = violation.reason,
			}
		end
	end
	table.sort(repairs, function(a, b)
		if a.groupIndex == b.groupIndex then return tostring(a.slot) < tostring(b.slot) end
		return a.groupIndex < b.groupIndex
	end)
	return {
		status = #blockers == 0 and (#repairs > 0 and "repairable" or "pass") or "blocked",
		valid = valid,
		evidence = evidence,
		repairs = repairs,
		repairsBySlot = repairsBySlot,
		blockers = blockers,
	}
end

function catalog.SocketLayoutMatchesRepair(item, repairPlan)
	if type(item) ~= "table" or type(item.sockets) ~= "table" or type(repairPlan) ~= "table"
		or type(repairPlan.colors) ~= "table" or type(repairPlan.linkGroups) ~= "table"
		or #repairPlan.colors == 0 or #repairPlan.colors ~= #repairPlan.linkGroups then
		return false
	end
	if #item.sockets < #repairPlan.colors then return false end
	local expectedToActual, actualToExpected = { }, { }
	for index, expectedColor in ipairs(repairPlan.colors) do
		local socket = item.sockets[index]
		if not socket then return false end
		local actualColor = tostring(socket.color or ""):upper()
		if actualColor ~= expectedColor and actualColor ~= "W" then return false end
		local expectedGroup, actualGroup = repairPlan.linkGroups[index], socket.group
		if actualGroup == nil then return false end
		if expectedToActual[expectedGroup] ~= nil and expectedToActual[expectedGroup] ~= actualGroup then return false end
		if actualToExpected[actualGroup] ~= nil and actualToExpected[actualGroup] ~= expectedGroup then return false end
		expectedToActual[expectedGroup] = actualGroup
		actualToExpected[actualGroup] = expectedGroup
	end
	return true
end

-- Return provenance and physical-legality evidence for one support relationship.
-- `activeSupportSet` means the exact PoB calculation applied the effect. It does
-- not by itself mean that the public build has a legal socket/link arrangement.
function catalog.SupportEvidence(build, groupIndex, group, support, activeSupportSet,
		itemFingerprintsBySlot, socketEvidence)
	local sourceGem = support and support.srcInstance
	local grantedEffect = support and support.grantedEffect
	local origin = support and support.origin
	if origin ~= "socketed_gem" and origin ~= "item_granted" and origin ~= "imbued" then
		if sourceGem then origin = "socketed_gem"
		elseif grantedEffect and grantedEffect.fromItem then origin = "item_granted"
		else origin = "granted_unknown" end
	end
	local sourceSlot = origin == "item_granted" and tostring(support.sourceSlot or "") or nil
	if origin == "imbued" and group and type(group.slot) == "string" then sourceSlot = group.slot end
	local sourceFingerprint = sourceSlot and itemFingerprintsBySlot and itemFingerprintsBySlot[sourceSlot] or nil
	local groupEnabled = group ~= nil and group.enabled ~= false and group.slotEnabled ~= false
	local groupValid = type(socketEvidence) == "table" and socketEvidence.valid == true
	local calculatorApplied = type(activeSupportSet) == "table" and activeSupportSet[support] == true
	local configured = support ~= nil and support.enabled ~= false and support.superseded ~= true
		and (sourceGem == nil or sourceGem.enabled ~= false)
	local sourceInTargetGroup = false
	if sourceGem and group then
		for _, candidate in ipairs(group.gemList or { }) do
			if candidate == sourceGem then sourceInTargetGroup = true; break end
		end
	end
	local socketState, linkState, playableActive = "not_applicable", "not_applicable", false
	if origin == "socketed_gem" then
		if not sourceGem then
			socketState, linkState = "unknown", "unknown"
		elseif not sourceInTargetGroup then
			socketState, linkState = "invalid", "not_same_skill_group"
		elseif not groupValid then
			socketState, linkState = "invalid", "invalid"
		else
			socketState, linkState = "matched", "validated_link"
		end
		playableActive = configured and calculatorApplied and groupEnabled and groupValid
			and sourceGem ~= nil and sourceInTargetGroup
	elseif origin == "item_granted" then
		if sourceSlot and sourceSlot ~= "" and sourceSlot == (group and group.slot or "")
			and sourceFingerprint and groupValid then
			socketState, linkState = "not_applicable", "verified_item_local"
			playableActive = configured and calculatorApplied and groupEnabled
		else
			linkState = calculatorApplied and sourceSlot and sourceSlot ~= "" and "cross_slot_unverified" or "unknown"
		end
	elseif origin == "imbued" then
		local imbuedEffect = group and group.slot and build and build.skillsTab and build.skillsTab.imbuedSupportBySlot
			and build.skillsTab.imbuedSupportBySlot[group.slot]
		local imbuedVerified = group and group.imbuedSupport and imbuedEffect and grantedEffect
			and tostring(imbuedEffect.id or "") == tostring(grantedEffect.id or "")
		if imbuedVerified and groupValid then
			linkState = "verified_imbued_slot"
			playableActive = configured and calculatorApplied and groupEnabled
		else
			linkState = "unknown"
		end
	else
		socketState, linkState = "unknown", "unknown"
	end
	return {
		origin = origin,
		sourceSlot = sourceSlot,
		sourceItemFingerprint = sourceFingerprint,
		configured = configured,
		calculatorApplied = calculatorApplied,
		active = calculatorApplied,
		-- matchesSocket can be stale when an item is equipped after a group is pasted.
		-- The native group validator checks every physical socket color and link.
		socketMatched = sourceGem ~= nil and sourceInTargetGroup and groupValid or false,
		socketState = socketState,
		linkState = linkState,
		groupState = groupEnabled and (groupValid and "active" or "invalid") or "inactive",
		playableActive = playableActive,
	}
end

-- Exact-build candidates can replace an item that hosts a non-main skill too.
-- Certify every enabled manual group that contributes to Full DPS against the
-- candidate item set; a valid Main Skill link alone is not sufficient proof.
function catalog.ValidateFullDPSSocketGroups(build, itemsTabOverride, itemSetOverride, groupOverrides)
	local result = { status = "pass", groups = { }, violations = { } }
	local groups = build and build.skillsTab and build.skillsTab.socketGroupList or { }
	for groupIndex, sourceGroup in ipairs(groups) do
		local group = groupOverrides and groupOverrides[groupIndex] or sourceGroup
		if group and not isGrantedSkillGroup(group) and group.includeInFullDPS == true
			and group.enabled ~= false and group.slotEnabled ~= false then
			local label = tostring(group.displayLabel or group.label or group.slot or ("Skill group " .. groupIndex))
		local valid, socketInfo = catalog.ValidateSocketGroup(
				build, groupIndex, itemsTabOverride, itemSetOverride, group, groupOverrides or groups)
			if valid and type(socketInfo) == "table" and socketInfo.status == "linked" then
				result.groups[#result.groups + 1] = {
					groupIndex = groupIndex,
					label = label,
					status = "linked",
					group = socketInfo,
				}
			else
				local reason = type(socketInfo) == "string" and socketInfo
					or "PoB could not certify this enabled Full DPS group against native item sockets"
				local violation = {
					key = "skill_group_socket_link",
					label = "Full DPS skill group socket/link",
					groupIndex = groupIndex,
					group = label,
					reason = reason,
					deficit = 1,
				}
				result.violations[#result.violations + 1] = violation
				result.groups[#result.groups + 1] = {
					groupIndex = groupIndex,
					label = label,
					status = "violated",
					reason = reason,
				}
			end
		end
	end
	if #result.violations > 0 then result.status = "violated" end
	return #result.violations == 0, result
end

-- Adding a support is legal only when PoB can map the new entry to a real
-- socket in this exact link. An unassigned, manually-created Main Skill is a
-- useful planning seed, so it may carry provisional supports for exact PoB
-- calculations; it remains explicitly unlinked and is never certified as
-- equipment-ready by this helper.
function catalog.CanAddSupportAtSlot(build, groupIndex, gemIndex, gemData, priorSupportAdds)
	local group = build and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false then
		return false, "Select an enabled PoB socket group before adding a support"
	end
	local hasActiveSkill = false
	for _, activeSkill in ipairs(group.displaySkillList or { }) do
		if activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
			and not activeSkill.activeEffect.grantedEffect.support
			and not activeSkill.activeEffect.grantedEffect.unsupported then
			hasActiveSkill = true
			break
		end
	end
	if not hasActiveSkill then return false, "A support can only be added to a PoB group with an active skill" end
	priorSupportAdds = tonumber(priorSupportAdds) or 0
	if priorSupportAdds < 0 or priorSupportAdds ~= math.floor(priorSupportAdds)
		or type(gemIndex) ~= "number" or gemIndex < 1 or gemIndex ~= math.floor(gemIndex)
		or not group.gemList or gemIndex ~= #group.gemList + priorSupportAdds + 1 then
		return false, "A support can only be added to the next unused PoB gem slot"
	end
	local effect = supportEffect(gemData)
	if not effect then
		return false, "Added gem must be a supported support gem from PoB's loaded database"
	end
	if not group.slot then
		if isGrantedSkillGroup(group) then
			return false, "A PoB-granted skill group without an equipment slot cannot accept a planning support"
		end
		return true, { linked = false, reason = "unlinked_support_plan" }
	end
	local itemsTab = build.itemsTab
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId])
	local slotEntry = itemSet and itemSet[group.slot]
	local item = slotEntry and tonumber(slotEntry.selItemId) and tonumber(slotEntry.selItemId) > 0
		and itemsTab.items[tonumber(slotEntry.selItemId)] or nil
	if not item or type(item.sockets) ~= "table" then
		return false, "The target PoB item has no native socket data for the added support"
	end
	local socketOffset = 0
	for currentGroupIndex, currentGroup in ipairs(build.skillsTab.socketGroupList or { }) do
		if currentGroup.slot == group.slot then
			if currentGroupIndex == groupIndex then break end
			socketOffset = socketOffset + #(currentGroup.gemList or { })
		end
	end
	local previousSocket = item.sockets[socketOffset + #group.gemList + priorSupportAdds]
	local targetSocket = item.sockets[socketOffset + gemIndex]
	if not previousSocket or not targetSocket then
		return false, "The target PoB item has no additional native socket for this support"
	end
	if previousSocket.group ~= targetSocket.group then
		return false, "The target PoB socket is not linked to the Main Skill's native socket group"
	end
	if item.sockets.colourAlwaysMatches then return true, { linked = true } end
	local colors = { [1] = "R", [2] = "G", [3] = "B", [4] = "W", R = "R", G = "G", B = "B", W = "W" }
	local requiredColor = colors[effect.color]
	local socketColor = tostring(targetSocket.color or ""):upper()
	if not requiredColor then
		return false, "PoB did not provide a supported socket color for " .. tostring(gemData.name or gemData.id)
	end
	if socketColor ~= requiredColor and socketColor ~= "W" then
		return false, string.format("Support %s needs a %s socket but the next socket in %s is %s",
			tostring(gemData.name or gemData.id), requiredColor, group.slot,
			socketColor ~= "" and socketColor or "uncolored")
	end
	return true, { linked = true }
end

-- Mirrors CalcSetup's native active-skill ordering for one socket group. The
-- result is used only to choose the requested Main Skill; the exact calculation
-- later verifies that it resolved back to the selected gem/effect identity.
function catalog.ResolveMainSkillIndex(group, gemIndex, effectId)
	if type(group) ~= "table" or type(group.gemList) ~= "table" then return nil end
	local activeSkillIndex = 0
	local selectedIndex
	for currentGemIndex, instance in ipairs(group.gemList) do
		if instance.enabled and (instance.gemData or instance.grantedEffect) then
			local effects = instance.gemData and instance.gemData.grantedEffectList
			if type(effects) ~= "table" then effects = { instance.grantedEffect or (instance.gemData and instance.gemData.grantedEffect) } end
			for effectIndex, effect in ipairs(effects) do
				if effect and not effect.support and not effect.unsupported
					and (not effect.hasGlobalEffect or instance["enableGlobal" .. tostring(effectIndex)]) then
					activeSkillIndex = activeSkillIndex + 1
					if currentGemIndex == gemIndex and (effectId == nil or effect.id == effectId) and not selectedIndex then
						selectedIndex = activeSkillIndex
					end
				end
			end
		end
	end
	return selectedIndex
end

local function targetEffectId(gemData, sourceGem, selectedSkill)
	local sameGem = sourceGem and sourceGem.gemData and sourceGem.gemData.id == gemData.id
	local selectedEffect = selectedSkill and selectedSkill.activeEffect and selectedSkill.activeEffect.grantedEffect
	local effectId = sameGem and selectedEffect and selectedEffect.id or gemData.grantedEffectId
	if effectId == nil then
		for _, effect in ipairs(gemData.grantedEffectList or { }) do
			if effect and not effect.support and not effect.unsupported then effectId = effect.id break end
		end
	end
	return effectId
end

-- Return the exact active-effect identity that ResolveTarget will evaluate for
-- this gem. When it is already installed, preserve PoB's selected effect (for
-- example the Vaal skill); for a proposed replacement use the gem's declared
-- primary effect, matching ResolveTarget's replacement behavior.
function catalog.ResolveTargetEffectId(build, groupIndex, skillIndex, gemId)
	if type(gemId) ~= "string" or #gemId < 1 or #gemId > 100 then
		return nil, "targetSkillGemId must be an internal gem ID from PoB's loaded gem database"
	end
	local gemData = build and build.data and build.data.gems and build.data.gems[gemId]
	if not activeSkillGem(gemData) then
		return nil, "Selected Main Skill gem must be a supported active skill from PoB's loaded gem database"
	end
	local group, _, _, sourceGem = activeGemInstance(build, groupIndex, skillIndex)
	local selectedSkill = group and group.displaySkillList and group.displaySkillList[skillIndex]
	local effectId = targetEffectId(gemData, sourceGem, selectedSkill)
	if effectId == nil then return nil, "PoB did not provide a supported active effect for the selected gem" end
	return tostring(effectId)
end

function catalog.ResolveTarget(build, groupIndex, skillIndex, gemId, options)
	if type(gemId) ~= "string" or #gemId < 1 or #gemId > 100 then
		return nil, "targetSkillGemId must be an internal gem ID from PoB's loaded gem database"
	end
	local gemData = build and build.data and build.data.gems and build.data.gems[gemId]
	if not activeSkillGem(gemData) then
		return nil, "Selected Main Skill gem must be a supported active skill from PoB's loaded gem database"
	end
	local group, gemIndex, sourceError, sourceGem = activeGemInstance(build, groupIndex, skillIndex)
	if not group then return nil, sourceError end
	local selectedSkill = group.displaySkillList and group.displaySkillList[skillIndex]
	local sourceGemData = sourceGem and (sourceGem.gemData
		or (sourceGem.gemId and build.data and build.data.gems and build.data.gems[sourceGem.gemId]))
	local sameGem = sourceGemData and sourceGemData.id == gemData.id
	if sameGem == nil and sourceGem then
		sameGem = sourceGemData and sourceGemData.id == gemData.id
	end
	local repairAllowed = sameGem == true and type(options) == "table" and options.allowSocketRepair == true
	local socketRepair
	if not selectedSkill or not selectedSkill.activeEffect then
		if repairAllowed then socketRepair = catalog.PlanSocketRepair(build, groupIndex, group) end
		if not socketRepair then return nil, "Select an active PoB skill in the target socket group" end
	end
	local socketValid, socketDetails = catalog.CanReplaceGemAtSlot(build, groupIndex, gemIndex, gemData, options)
	local socketError = socketDetails
	if repairAllowed then
		local groupEvidence = catalog.SocketGroupEvidence(build, groupIndex, group)
		if not groupEvidence.valid and not socketRepair then
			socketRepair = catalog.PlanSocketRepair(build, groupIndex, group)
		end
		if socketRepair then socketValid = true end
	end
	if not socketValid then return nil, socketError end
	local unlinkedPlanning = type(options) == "table" and options.allowUnlinkedPlanning == true
		and not isGrantedSkillGroup(group) and (type(group.slot) ~= "string" or group.slot == "")
	local effect = gemData.grantedEffect
	local maximumLevel = math.min(tonumber(gemData.naturalMaxLevel) or #(effect.levels or { }), #(effect.levels or { }))
	local characterLevel = tonumber(build.characterLevel) or 1
	local selectedLevel
	for level = maximumLevel, 1, -1 do
		local levelData = effect.levels[level]
		if levelData and (tonumber(levelData.levelRequirement) or 1) <= characterLevel then
			selectedLevel = level
			break
		end
	end
	if not selectedLevel then
		local minimumRequirement
		for _, levelData in ipairs(effect.levels or { }) do
			local requirement = levelData and tonumber(levelData.levelRequirement)
			if requirement and (minimumRequirement == nil or requirement < minimumRequirement) then
				minimumRequirement = requirement
			end
		end
		if minimumRequirement then
			return nil, string.format("%s requires character level %d; the active PoB character is level %d",
				tostring(gemData.name or "Selected Main Skill gem"), minimumRequirement, characterLevel)
		end
		return nil, "Selected Main Skill gem has no level data compatible with the active PoB character level " .. tostring(characterLevel)
	end
	local selectedEffectId = targetEffectId(gemData, sourceGem, selectedSkill)
	if not selectedEffectId then
		return nil, "PoB did not provide a supported active effect for the selected gem"
	end
	local sourceLevel = sameGem and tonumber(sourceGem.level) or nil
	-- Preserve the already-loaded native gem state as the search baseline, even
	-- when it is an over-levelled/corrupted gem above its natural maximum. PoB
	-- can import and calculate these existing gems, while replacement proposals
	-- still use the selected gem's legal native level range above.
	if sourceLevel and sourceLevel >= 1 and sourceLevel <= 40 and sourceLevel == math.floor(sourceLevel) then
		selectedLevel = sourceLevel
	end
	local sourceQuality = sameGem and tonumber(sourceGem.quality) or nil
	if not sourceQuality or sourceQuality < 0 or sourceQuality > 30 or sourceQuality ~= math.floor(sourceQuality) then
		sourceQuality = 0
	end
	local variant = {
		groupIndex = groupIndex,
		gemIndex = gemIndex,
		gemId = gemData.id,
		skillId = selectedEffectId,
		nameSpec = gemData.name,
		level = selectedLevel,
		quality = sameGem and sourceQuality or 0,
		kind = "selected_main_skill",
	}
	return variant, nil, {
		group = group,
		sourceGem = sourceGem,
		sourceGemId = sourceGem and sourceGem.gemData and sourceGem.gemData.id,
		sameGem = sameGem == true,
		unlinkedPlanning = unlinkedPlanning,
		socketRepair = socketRepair,
		activeSkillIndex = sameGem and skillIndex or 1,
	}
end

function catalog.CurrentMainGemId(build, groupIndex, skillIndex)
	local _, _, _, sourceGem = activeGemInstance(build, groupIndex, skillIndex)
	if sourceGem and sourceGem.gemData then return sourceGem.gemData.id end

	-- During native XML load, socket groups can be rebuilt before PoB resolves
	-- displaySkillList. If there is exactly one enabled active-skill gem, its
	-- identity is still unambiguous from the loaded gem database and can safely
	-- anchor the Planner context. Multiple active gems remain unresolved here;
	-- never guess which one the user intended.
	local group = build and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false then return nil end
	local candidate
	for _, gem in ipairs(group.gemList or { }) do
		local gemData = gem.gemData or (gem.gemId and build.data and build.data.gems and build.data.gems[gem.gemId])
		if gem.enabled ~= false and activeSkillGem(gemData) then
			if candidate then return nil end
			candidate = gemData.id
		end
	end
	return candidate
end

return catalog
