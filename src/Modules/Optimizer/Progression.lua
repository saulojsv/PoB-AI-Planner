-- Path of Building
--
-- Module: Read-only authoring and exact-engine evaluation of leveling stages.
-- Each stage starts from native PoB sets and may contain bounded tree, item,
-- gem, and hard-floor proposals. All candidates remain isolated from the build.
--
local Calcs = require("Modules.Calcs")
local Candidate = require("Modules.Optimizer.Candidate")
local Scenario = require("Modules.Optimizer.Scenario")
local Validator = require("Modules.Optimizer.Validator")
local Inputs = require("Modules.Optimizer.Inputs")
local Activity = require("Modules.Optimizer.Activity")
local Equipment = require("Modules.Optimizer.Equipment")
local TreeSearch = require("Modules.Optimizer.TreeSearch")
local Conversion = require("Modules.Optimizer.Conversion")
local Breakpoints = require("Modules.Optimizer.Breakpoints")
local SkillAvailability = require("Modules.Optimizer.SkillAvailability")
local Version = require("Modules.Optimizer.Version")
local dkjson = require("dkjson")

local progression = { }
local expectedLevels = { 12, 28, 68, 90 }
local MAX_COMPARISON_PLANS = 4
local campaignUnknowns = {
	{ key = "quest_progress_and_rewards", reason = "Quest completion and reward history are not recorded in the PoB build." },
	{ key = "gem_vendor_and_drop_availability", reason = "Loaded PoB gem data does not certify class-specific quest or vendor availability." },
	{ key = "item_acquisition_and_crafting", reason = "PoB item legality does not prove the item was acquired or crafted by this checkpoint." },
	{ key = "ascendancy_unlock_timing", reason = "PoB ascendancy data does not prove the Labyrinth quest was completed by this checkpoint." },
}
local allowedStageFields = {
	level = true, treeSpecIndex = true, itemSetId = true,
	skillSetId = true, configSetId = true, mainSocketGroup = true, mainSkillIndex = true,
	addNodeIds = true, removeNodeIds = true, equipmentOverrides = true,
	gemVariants = true, hardConstraints = true, conversion = true, requiredTriggerRate = true,
}

local metricDefinitionByKey = { }
for _, definition in ipairs(Inputs.metricDefinitions) do metricDefinitionByKey[definition.key] = definition end

local function shallowCopy(source)
	local copy = { }
	for key, value in pairs(source or { }) do copy[key] = value end
	return copy
end

local function copyArray(source)
	local copy = { }
	for index, value in ipairs(source or { }) do copy[index] = value end
	return copy
end

local function campaignAuditSnapshot()
	local unverified = { }
	for index, item in ipairs(campaignUnknowns) do
		unverified[index] = { key = item.key, status = "unknown", reason = item.reason }
	end
	return {
		status = "not_certified",
		exactPoBScope = "legality_and_metrics_only",
		unverified = unverified,
	}
end

local function copyStage(stage)
	local copy = shallowCopy(stage)
	copy.addNodeIds = copyArray(stage.addNodeIds)
	copy.removeNodeIds = copyArray(stage.removeNodeIds)
	copy.gemVariants = { }
	for index, variant in ipairs(stage.gemVariants or { }) do copy.gemVariants[index] = shallowCopy(variant) end
	copy.equipmentOverrides = shallowCopy(stage.equipmentOverrides)
	copy.hardConstraints = { }
	for index, constraint in ipairs(stage.hardConstraints or { }) do copy.hardConstraints[index] = shallowCopy(constraint) end
	copy.conversion = stage.conversion and {
		route = copyArray(stage.conversion.route),
		minimumPercent = stage.conversion.minimumPercent,
	} or nil
	return copy
end

local isInteger, finite, safeText

local function sortedLinkedTargetNodes(spec, node, targetIds)
	local linked = { }
	for _, other in ipairs(node.linked or { }) do
		if other and targetIds[other.id] and spec.nodes[other.id] then
			linked[#linked + 1] = other.id
		end
	end
	table.sort(linked)
	return linked
end

local function orderedTargetTreeNodes(spec)
	local class = spec and spec.curClass
	local start = class and class.startNodeId and spec.nodes[class.startNodeId]
	if not start then return nil, "Selected PoB tree has no native class-start node" end
	local targetIds, expected = { }, 0
	for nodeId, node in pairs(spec.allocNodes or { }) do
		if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not node.ascendancyName then
			targetIds[nodeId] = true
			expected = expected + 1
		end
	end
	local ordered, seen = { }, { [start.id] = true }
	local queue, cursor = { start.id }, 1
	while cursor <= #queue do
		local node = spec.nodes[queue[cursor]]
		cursor = cursor + 1
		for _, nodeId in ipairs(sortedLinkedTargetNodes(spec, node, targetIds)) do
			if not seen[nodeId] then
				seen[nodeId] = true
				queue[#queue + 1] = nodeId
				ordered[#ordered + 1] = nodeId
			end
		end
	end
	if #ordered ~= expected then
		return nil, string.format("Selected tree has %d main-tree passives, but only %d are reachable as one native allocated path; generated progression refuses to drop disconnected nodes", expected, #ordered)
	end
	return ordered, targetIds
end

local function nativeActLabel(act)
	if act >= 1 and act <= 10 then return "Act " .. tostring(act) end
	if act == 11 then return "Epilogue / maps" end
	return "PoB stage " .. tostring(act)
end

-- Use PoB's own level/quest method as the single source for both the notes
-- schedule and progression previews. This is a legality schedule, not a quest
-- unlock or item-acquisition certificate.
local function buildNativeActSchedule(build, extraPoints)
	if not build or type(build.GetPassivePointLimitForLevel) ~= "function" then
		return nil, "PoB's native level and act-quest point-limit function is unavailable"
	end
	local stages = { }
	for level = 1, 100 do
		local pointLimit, act = build:GetPassivePointLimitForLevel(level, extraPoints)
		if not finite(pointLimit) or pointLimit < 0 or pointLimit ~= math.floor(pointLimit)
			or not finite(act) or act < 1 or act ~= math.floor(act) then
			return nil, "PoB returned an invalid native progression point limit at level " .. tostring(level)
		end
		local stage = stages[#stages]
		if not stage or stage.act ~= act then
			stage = {
				act = act,
				actLabel = nativeActLabel(act),
				firstLevel = level,
				lastLevel = level,
				firstPointLimit = pointLimit,
				lastPointLimit = pointLimit,
			}
			stages[#stages + 1] = stage
		else
			stage.lastLevel = level
			stage.lastPointLimit = pointLimit
		end
	end
	return stages
end

progression.BuildNativeActSchedule = buildNativeActSchedule

local function stageGemVariants(build, skillSetId, level)
	local skillSet = build.skillsTab.skillSets[skillSetId]
	local variants, overLimit = { }, 0
	for groupIndex, group in ipairs(skillSet.socketGroupList or { }) do
		for gemIndex, gem in ipairs(group.gemList or { }) do
			local effect = gem.grantedEffect or gem.gemData and gem.gemData.grantedEffect
			local levels = effect and effect.levels
			local currentLevel = math.max(1, math.floor(tonumber(gem.level) or 1))
			local maximumLevel = math.min(currentLevel, #(levels or { }))
			local legalLevel = 0
			for candidateLevel = 1, maximumLevel do
				local levelData = levels[candidateLevel]
				if levelData and (tonumber(levelData.levelRequirement) or 1) <= level then
					legalLevel = candidateLevel
				end
			end
			if legalLevel > 0 and legalLevel < currentLevel then
				if #variants < 12 then
					variants[#variants + 1] = {
						groupIndex = groupIndex, gemIndex = gemIndex,
						level = legalLevel, quality = math.max(0, math.min(30, math.floor(tonumber(gem.quality) or 0))),
					}
				else
					overLimit = overLimit + 1
				end
			end
		end
	end
	if overLimit > 0 then
		return nil, string.format("Stage %d needs %d gem level reductions, exceeding the exact evaluator's 12-slot per-stage bound", level, #variants + overLimit)
	end
	return variants
end

-- Derive a reproducible campaign skeleton from the selected endgame tree. The
-- BFS order only determines which already-planned passives arrive first; it is
-- not an optimizer score. Every checkpoint is recalculated and may fail its
-- native point, attribute, gem, item, resource, or hard-metric gates.
function progression.GenerateStages(build, treeSpecIndex)
	if not build or not build.spec or not build.treeTab or not build.skillsTab or not build.itemsTab or not build.configTab then
		return nil, "Open a complete PoB build before generating campaign checkpoints"
	end
	treeSpecIndex = treeSpecIndex or build.treeTab.activeSpec
	if not isInteger(treeSpecIndex, 1) or not build.treeTab.specList[treeSpecIndex] then
		return nil, "treeSpecIndex must reference a saved native PoB tree spec"
	end
	local targetSpec = build.treeTab.specList[treeSpecIndex]
	if targetSpec.curClassId ~= build.spec.curClassId then
		return nil, "Select a target tree whose native class matches the active build class before generating campaign checkpoints"
	end
	if type(build.GetPassivePointLimitForLevel) ~= "function" then
		return nil, "PoB's native level-to-passive-point limit is unavailable"
	end
	local treeOrder, targetIdsOrError = orderedTargetTreeNodes(targetSpec)
	if not treeOrder then return nil, targetIdsOrError end
	local mainPoints = select(1, targetSpec:CountAllocNodes())
	if #treeOrder ~= mainPoints then
		return nil, "Generated main-tree path does not match PoB's native allocated passive-point count"
	end
	local itemSetId = build.itemsTab.activeItemSetId
	local skillSetId = build.skillsTab.activeSkillSetId
	local configSetId = build.configTab.activeConfigSetId
	local skillSet = build.skillsTab.skillSets[skillSetId]
	if not skillSet or not build.itemsTab.itemSets[itemSetId] or not build.configTab.configSets[configSetId] then
		return nil, "Active PoB item, skill, or configuration set is unavailable"
	end
	local mainSocketGroup = build.mainSocketGroup or 1
	local mainGroup = skillSet.socketGroupList[mainSocketGroup]
	if not mainGroup then return nil, "Active Main Skill socket group is unavailable in the selected native skill set" end
	local mainSkillIndex = mainGroup.mainActiveSkill or mainGroup.mainActiveSkillCalcs or 1
	local output = build.calcsTab and build.calcsTab.mainOutput
	local extraPoints = output and tonumber(output.ExtraPoints)
	if not finite(extraPoints) then
		return nil, "PoB has not produced exact ExtraPoints for the active configuration; calculate the build before generation"
	end
	local actSchedule, actScheduleError = buildNativeActSchedule(build, extraPoints)
	if not actSchedule then return nil, actScheduleError end
	local stages, summaries = { }, { }
	for index, level in ipairs(expectedLevels) do
		local pointLimit, act = build:GetPassivePointLimitForLevel(level, extraPoints)
		if not finite(pointLimit) or pointLimit < 0 or pointLimit ~= math.floor(pointLimit)
			or not finite(act) or act < 1 or act ~= math.floor(act) then
			return nil, "PoB returned an invalid passive point limit for level " .. level
		end
		local actRange
		for _, range in ipairs(actSchedule) do
			if level >= range.firstLevel and level <= range.lastLevel then actRange = range; break end
		end
		if not actRange or actRange.act ~= act then
			return nil, "PoB's native act schedule disagrees with its checkpoint result at level " .. tostring(level)
		end
		local keepCount = math.min(#treeOrder, math.floor(pointLimit))
		local keep = { }
		for position = 1, keepCount do keep[treeOrder[position]] = true end
		local removeNodeIds = { }
		for nodeId in pairs(targetIdsOrError) do
			if not keep[nodeId] then removeNodeIds[#removeNodeIds + 1] = nodeId end
		end
		for nodeId, node in pairs(targetSpec.allocNodes or { }) do
			if node and node.ascendancyName and node.type ~= "AscendClassStart" then
				removeNodeIds[#removeNodeIds + 1] = nodeId
			end
		end
		table.sort(removeNodeIds)
		local gemVariants, gemError = stageGemVariants(build, skillSetId, level)
		if not gemVariants then return nil, gemError end
		stages[index] = {
			level = level, treeSpecIndex = treeSpecIndex, itemSetId = itemSetId,
			skillSetId = skillSetId, configSetId = configSetId,
			mainSocketGroup = mainSocketGroup, mainSkillIndex = mainSkillIndex,
			removeNodeIds = removeNodeIds, gemVariants = gemVariants,
		}
		summaries[index] = {
			level = level, act = act, actLabel = actRange.actLabel, pointLimit = math.floor(pointLimit),
			plannedMainTreePoints = keepCount, removedTreeNodes = #removeNodeIds,
			gemLevelReductions = #gemVariants,
		}
	end
	local valid, validationError = progression.ValidateStages(build, stages)
	if not valid then return nil, "Generated campaign checkpoints failed native input validation: " .. tostring(validationError) end
	local activeSkill = (mainGroup.displaySkillListCalcs or mainGroup.displaySkillList or { })[mainSkillIndex]
	local activeEffect = activeSkill and (activeSkill.activeEffect or activeSkill.effectList and activeSkill.effectList[1])
	return {
		stages = stages,
		treeSpecIndex = treeSpecIndex,
		classId = targetSpec.curClassId,
		className = safeText(targetSpec.curClassName or "Unknown", 80),
		treeVersion = safeText(targetSpec.treeVersion or "", 40),
		dataVersion = Version.Data(build),
		mainSkill = safeText(activeEffect and activeEffect.grantedEffect and activeEffect.grantedEffect.name or "", 100),
		checkpoints = summaries,
		actSchedule = actSchedule,
		campaignAvailability = "not_certified",
		campaignAudit = campaignAuditSnapshot(),
		limitations = {
			"Passive order is deterministic BFS over the selected final tree; it is not a claim of an optimal leveling route.",
			"PoB recalculation checks level, points, attributes, item/gem requirements, payability, sustain, and requested hard gates.",
			"Quest unlock timing, gem/vendor availability, item acquisition, and campaign crafting are not certified by loaded PoB data.",
			"Ascendancy allocations are removed from generated checkpoints because this module has no authoritative quest-unlock schedule.",
		},
	}
end

isInteger = function(value, minimum)
	return type(value) == "number" and value == math.floor(value) and value >= (minimum or 0)
end

finite = function(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

safeText = function(value, limit)
	local text = tostring(value or ""):gsub("[%c]", " "):gsub("%s+", " "):match("^%s*(.-)%s*$")
	if #text > limit then return text:sub(1, limit) end
	return text
end

local function sortedKeys(source)
	local keys = { }
	for key in pairs(source or { }) do keys[#keys + 1] = key end
	table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
	return keys
end

local function setEntries(order, sets, activeId, describe)
	local result, seen = { }, { }
	for _, id in ipairs(order or { }) do
		local set = sets and sets[id]
		if set then
			seen[id] = true
			local entry = describe(id, set)
			entry.active = id == activeId
			result[#result + 1] = entry
		end
	end
	for _, id in ipairs(sortedKeys(sets)) do
		local set = sets[id]
		if not seen[id] and set then
			local entry = describe(id, set)
			entry.active = id == activeId
			result[#result + 1] = entry
		end
	end
	return result
end

local function listSkills(skillSet)
	local groups = { }
	for groupIndex, group in ipairs(skillSet and skillSet.socketGroupList or { }) do
		local gems = { }
		local activeSkills = { }
		for skillIndex, activeSkill in ipairs(group.displaySkillListCalcs or group.displaySkillList or { }) do
			local effect = activeSkill.activeEffect or activeSkill.effectList and activeSkill.effectList[1]
			activeSkills[#activeSkills + 1] = {
				index = skillIndex,
				name = safeText(effect and effect.grantedEffect and effect.grantedEffect.name or "Unknown active skill", 100),
			}
		end
		for gemIndex, gem in ipairs(group.gemList or { }) do
			if gemIndex > 12 then break end
			gems[#gems + 1] = {
				index = gemIndex,
				name = safeText(gem.nameSpec or gem.grantedEffect and gem.grantedEffect.name, 80),
				level = gem.level,
				quality = gem.quality,
				enabled = gem.enabled ~= false,
			}
		end
		groups[#groups + 1] = {
			index = groupIndex,
			label = safeText(group.label or "", 80),
			slot = safeText(group.slot or "", 48),
			enabled = group.enabled ~= false,
			mainActiveSkill = group.mainActiveSkill or 1,
			activeSkills = activeSkills,
			gems = gems,
		}
	end
	return groups
end

function progression.ListOptions(build)
	if not build or not build.spec or not build.treeTab then return nil, "Open a PoB build before listing progression loadouts" end
	local treeSpecs = { }
	for index, spec in ipairs(build.treeTab.specList or { }) do
		local points = spec:CountAllocNodes()
		treeSpecs[#treeSpecs + 1] = {
			index = index,
			title = safeText(spec.title or "Default", 100),
			treeVersion = safeText(spec.treeVersion or "", 40),
			class = safeText(spec.curClassName or "Unknown", 80),
			ascendancy = safeText(spec.curAscendClassName or "None", 80),
			passivePoints = points,
			active = index == build.treeTab.activeSpec,
		}
	end
	local baseClasses = { }
	for classId, class in pairs(build.spec.tree and build.spec.tree.classes or { }) do
		baseClasses[#baseClasses + 1] = {
			id = classId,
			name = safeText(class.name or "Unknown", 80),
			startNodeId = class.startNodeId,
		}
	end
	table.sort(baseClasses, function(a, b)
		if type(a.id) == "number" and type(b.id) == "number" then return a.id < b.id end
		return tostring(a.id) < tostring(b.id)
	end)
	local items = setEntries(build.itemsTab and build.itemsTab.itemSetOrderList, build.itemsTab and build.itemsTab.itemSets,
		build.itemsTab and build.itemsTab.activeItemSetId, function(id, set)
			return { id = id, title = safeText(set.title or "Default", 100), secondWeaponSet = set.useSecondWeaponSet == true }
		end)
	local skills = setEntries(build.skillsTab and build.skillsTab.skillSetOrderList, build.skillsTab and build.skillsTab.skillSets,
		build.skillsTab and build.skillsTab.activeSkillSetId, function(id, set)
			return { id = id, title = safeText(set.title or "Default", 100), groups = listSkills(set) }
		end)
	local configs = setEntries(build.configTab and build.configTab.configSetOrderList, build.configTab and build.configTab.configSets,
		build.configTab and build.configTab.activeConfigSetId, function(id, set)
			return { id = id, title = safeText(set.title or "Default", 100) }
		end)
	return {
		dataVersion = Version.Data(build),
		active = {
			treeSpecIndex = build.treeTab.activeSpec,
			baseClassId = build.spec.curClassId,
			itemSetId = build.itemsTab and build.itemsTab.activeItemSetId,
			skillSetId = build.skillsTab and build.skillsTab.activeSkillSetId,
			configSetId = build.configTab and build.configTab.activeConfigSetId,
			mainSocketGroup = build.mainSocketGroup,
		},
		requiredLevels = { 12, 28, 68, 90 },
		baseClasses = baseClasses,
		treeSpecs = treeSpecs,
		itemSets = items,
		skillSets = skills,
		configSets = configs,
		certificationScope = "Exact PoB evaluation of the selected native loadouts plus isolated stage proposals for passives, existing items, loaded gems, hard metrics, conversion, and supported trigger rates. Quest-unlock timing and item acquisition are not inferred.",
		stageProposalLimits = {
			passiveNodesPerAction = 64,
			gemSlots = 12,
			equipmentSlots = 20,
			hardConstraints = 32,
			comparisonPlans = MAX_COMPARISON_PLANS,
		},
		comparisonObjectives = shallowCopy(Inputs.objectives),
	}
end

local function idExists(order, sets, id)
	if type(sets) ~= "table" or sets[id] == nil then return false end
	if type(order) ~= "table" then return true end
	for _, listedId in ipairs(order) do if listedId == id then return true end end
	return false
end

local function resolvedMainGroupIndex(build, stage)
	local groups = build.skillsTab.skillSets[stage.skillSetId].socketGroupList or { }
	local index = stage.mainSocketGroup
	if index == nil then
		index = build.mainSocketGroup
		if not groups[index] then index = 1 end
	end
	return index
end

local function resolvedMainSkillIndex(build, stage)
	if stage.mainSkillIndex ~= nil then return stage.mainSkillIndex end
	local skillSet = build.skillsTab.skillSets[stage.skillSetId]
	local group = skillSet and skillSet.socketGroupList[resolvedMainGroupIndex(build, stage)]
	return group and (group.mainActiveSkill or group.mainActiveSkillCalcs or 1) or 1
end

local function validateDenseArray(values, maximum, label)
	if values == nil then return true end
	if type(values) ~= "table" then return false, label .. " must be an array" end
	local count, highest = 0, 0
	for key in pairs(values) do
		if not isInteger(key, 1) or key > maximum then return false, label .. " must be a dense array with at most " .. maximum .. " entries" end
		count = count + 1
		highest = math.max(highest, key)
	end
	if count ~= highest then return false, label .. " must be a dense array" end
	return true
end

local function validateNodeChanges(spec, stage, stageIndex)
	local addOk, addError = validateDenseArray(stage.addNodeIds, 64, "stages[" .. stageIndex .. "].addNodeIds")
	if not addOk then return false, addError end
	local removeOk, removeError = validateDenseArray(stage.removeNodeIds, 200, "stages[" .. stageIndex .. "].removeNodeIds")
	if not removeOk then return false, removeError end
	local added, removed = { }, { }
	for _, pair in ipairs({ { stage.addNodeIds or { }, added, "addNodeIds" }, { stage.removeNodeIds or { }, removed, "removeNodeIds" } }) do
		for _, nodeId in ipairs(pair[1]) do
			local node = spec.nodes[nodeId]
			if not isInteger(nodeId, 1) or not node then
				return false, "stages[" .. stageIndex .. "]." .. pair[3] .. " references a node outside its selected PoB tree"
			end
			if node.type == "ClassStart" or node.type == "AscendClassStart" then
				return false, "stages[" .. stageIndex .. "]." .. pair[3] .. " cannot mutate PoB class or ascendancy start nodes"
			end
			if pair[2][nodeId] then return false, "stages[" .. stageIndex .. "]." .. pair[3] .. " contains a duplicate node ID" end
			pair[2][nodeId] = true
		end
	end
	for nodeId in pairs(added) do
		if removed[nodeId] then return false, "A stage passive node cannot be both added and removed: " .. tostring(nodeId) end
	end
	return true
end

local function validateStageInputs(build, stage, stageIndex)
	local skillSet = build.skillsTab.skillSets[stage.skillSetId]
	local variantsOk, variantsError = validateDenseArray(stage.gemVariants, 12, "stages[" .. stageIndex .. "].gemVariants")
	if not variantsOk then return false, variantsError end
	local seenGems = { }
	for _, variant in ipairs(stage.gemVariants or { }) do
		if type(variant) ~= "table" then return false, "Stage gem variants must be objects" end
		for key in pairs(variant) do
			if key ~= "groupIndex" and key ~= "gemIndex" and key ~= "gemId" and key ~= "level" and key ~= "quality" then
				return false, "Stage gem variant has an unsupported field: " .. tostring(key)
			end
		end
		if not isInteger(variant.groupIndex, 1) or not isInteger(variant.gemIndex, 1)
			or not isInteger(variant.level, 1) or variant.level > 40
			or not isInteger(variant.quality, 0) or variant.quality > 30 then
			return false, "Stage gem variant needs valid group/gem indices, level 1–40, and quality 0–30"
		end
		local selectedGroup = skillSet.socketGroupList[variant.groupIndex]
		local gem = selectedGroup and selectedGroup.gemList and selectedGroup.gemList[variant.gemIndex]
		if not gem then return false, "Stage gem variant references a missing native PoB gem slot" end
		if variant.gemId ~= nil and (type(variant.gemId) ~= "string" or #variant.gemId < 1 or #variant.gemId > 100) then
			return false, "Stage gem variant gemId must be a loaded PoB gem ID string"
		end
		local gemData = variant.gemId and build.data and build.data.gems and build.data.gems[variant.gemId] or gem.gemData
		if variant.gemId ~= nil and not gemData then
			return false, "Stage gem variant references a gem outside PoB's loaded gem data"
		end
		if not gemData or not gemData.grantedEffect or gemData.grantedEffect.unsupported then
			return false, "PoB cannot resolve the requested stage gem through its loaded skill data"
		end
		local key = tostring(variant.groupIndex) .. ":" .. tostring(variant.gemIndex)
		if seenGems[key] then return false, "A stage may change each gem slot at most once" end
		seenGems[key] = true
	end

	if stage.equipmentOverrides ~= nil then
		if type(stage.equipmentOverrides) ~= "table" then return false, "Stage equipmentOverrides must map native PoB slot names to item IDs" end
		local count = 0
		for slotName, itemId in pairs(stage.equipmentOverrides) do
			if type(slotName) ~= "string" or #slotName < 1 or #slotName > 64 or not isInteger(itemId, 1) then
				return false, "Stage equipmentOverrides must map native slot names to positive integer item IDs"
			end
			count = count + 1
		end
		if count > 20 then return false, "A stage may override at most 20 native equipment slots" end
	end

	local constraintsOk, constraintsError = validateDenseArray(stage.hardConstraints, 32, "stages[" .. stageIndex .. "].hardConstraints")
	if not constraintsOk then return false, constraintsError end
	local seenConstraints = { }
	for _, constraint in ipairs(stage.hardConstraints or { }) do
		if type(constraint) ~= "table" then return false, "Stage hard constraints must be objects" end
		for key in pairs(constraint) do
			if key ~= "key" and key ~= "value" then return false, "Stage hard constraint has an unsupported field: " .. tostring(key) end
		end
		local definition = metricDefinitionByKey[constraint.key]
		if not definition or not finite(constraint.value) then
			return false, "Stage hard constraints must use a native Matrix metric key and a finite number"
		end
		if seenConstraints[constraint.key] then return false, "A stage may constrain each metric only once" end
		seenConstraints[constraint.key] = true
	end

	if stage.conversion ~= nil then
		local conversion = stage.conversion
		if type(conversion) ~= "table" then return false, "Stage conversion must be an object" end
		for key in pairs(conversion) do
			if key ~= "route" and key ~= "minimumPercent" then return false, "Stage conversion has an unsupported field: " .. tostring(key) end
		end
		local routeOk, routeError = validateDenseArray(conversion.route, 5, "stages[" .. stageIndex .. "].conversion.route")
		if not routeOk then return false, routeError end
		if #(conversion.route or { }) < 2 then return false, "Stage conversion route needs at least two native damage types" end
		local damageTypes, seenTypes = { Physical = true, Lightning = true, Cold = true, Fire = true, Chaos = true }, { }
		for _, damageType in ipairs(conversion.route) do
			if not damageTypes[damageType] or seenTypes[damageType] then return false, "Stage conversion route contains an invalid or repeated damage type" end
			seenTypes[damageType] = true
		end
		local minimumPercent = conversion.minimumPercent
		if minimumPercent ~= nil and (not finite(minimumPercent) or minimumPercent < 0 or minimumPercent > 100) then
			return false, "Stage conversion minimumPercent must be from 0 to 100"
		end
	end
	if stage.requiredTriggerRate ~= nil and (not finite(stage.requiredTriggerRate) or stage.requiredTriggerRate < 0 or stage.requiredTriggerRate > 1000) then
		return false, "Stage requiredTriggerRate must be from 0 to 1000 per second"
	end
	return true
end

function progression.ValidateStages(build, stages, baseClassId)
	if type(stages) ~= "table" then return false, "stages must be an array of four explicit PoB loadouts" end
	if baseClassId ~= nil and (not isInteger(baseClassId, 1) or not (build and build.spec and build.spec.tree and build.spec.tree.classes[baseClassId])) then
		return false, "baseClassId must reference one of the native PoB classes in the selected tree version"
	end
	local count, highest = 0, 0
	for key in pairs(stages) do
		if not isInteger(key, 1) or key > 4 then return false, "stages must contain exactly four dense entries" end
		count = count + 1
		highest = math.max(highest, key)
	end
	if count ~= 4 or highest ~= 4 then return false, "stages must contain exactly four dense entries for levels 12, 28, 68, and 90" end
	for index, stage in ipairs(stages) do
		if type(stage) ~= "table" then return false, "stages[" .. index .. "] must be an object" end
		for key in pairs(stage) do
			if not allowedStageFields[key] then return false, "stages[" .. index .. "] has an unsupported field: " .. tostring(key) end
		end
		if stage.level ~= expectedLevels[index] then
			return false, "stages[" .. index .. "].level must be " .. expectedLevels[index]
		end
		if not isInteger(stage.treeSpecIndex, 1) or not (build.treeTab.specList or { })[stage.treeSpecIndex] then
			return false, "stages[" .. index .. "].treeSpecIndex must reference a saved native PoB tree spec"
		end
		if not isInteger(stage.itemSetId, 0) or not idExists(build.itemsTab.itemSetOrderList, build.itemsTab.itemSets, stage.itemSetId) then
			return false, "stages[" .. index .. "].itemSetId must reference a saved native PoB item set"
		end
		if not isInteger(stage.skillSetId, 0) or not idExists(build.skillsTab.skillSetOrderList, build.skillsTab.skillSets, stage.skillSetId) then
			return false, "stages[" .. index .. "].skillSetId must reference a saved native PoB skill set"
		end
		if not isInteger(stage.configSetId, 0) or not idExists(build.configTab.configSetOrderList, build.configTab.configSets, stage.configSetId) then
			return false, "stages[" .. index .. "].configSetId must reference a saved native PoB config set"
		end
		local skillSet = build.skillsTab.skillSets[stage.skillSetId]
		local groups = skillSet and skillSet.socketGroupList or { }
		local mainGroupIndex = resolvedMainGroupIndex(build, stage)
		if not isInteger(mainGroupIndex, 1) or not groups[mainGroupIndex] then
			return false, "stages[" .. index .. "].mainSocketGroup must reference a group in its selected skill set"
		end
		local mainGroup = groups[mainGroupIndex]
		local mainSkillIndex = stage.mainSkillIndex or mainGroup.mainActiveSkill or mainGroup.mainActiveSkillCalcs or 1
		if not isInteger(mainSkillIndex, 1) then
			return false, "stages[" .. index .. "].mainSkillIndex must be a positive integer"
		end
		if mainGroup.enabled == false or #(mainGroup.gemList or { }) == 0 then
			return false, "stages[" .. index .. "] must select an enabled socket group containing a skill gem"
		end
		local selectedSpec = build.treeTab.specList[stage.treeSpecIndex]
		if baseClassId ~= nil and not (selectedSpec.tree and selectedSpec.tree.classes and selectedSpec.tree.classes[baseClassId]) then
			return false, "baseClassId is unavailable in the PoB tree version selected for stage " .. index
		end
		if baseClassId ~= nil and #(stage.removeNodeIds or { }) > 0 then
			return false, "A generated class-root stage cannot remove nodes from an empty starting tree"
		end
		local nodesValid, nodeError = validateNodeChanges(selectedSpec, stage, index)
		if not nodesValid then return false, nodeError end
		local stageInputsValid, stageInputError = validateStageInputs(build, stage, index)
		if not stageInputsValid then return false, stageInputError end
	end
	return true
end

function progression.ValidatePlans(build, plans, objective, baseClassId)
	if type(plans) ~= "table" then return false, "plans must contain two to four explicit campaign proposals" end
	local count, highest = 0, 0
	for key in pairs(plans) do
		if not isInteger(key, 1) or key > MAX_COMPARISON_PLANS then
			return false, "plans must contain a dense array of at most four proposals"
		end
		count = count + 1
		highest = math.max(highest, key)
	end
	if count < 2 or count > MAX_COMPARISON_PLANS or highest ~= count then
		return false, "plans must contain two to four dense campaign proposals"
	end
	if type(objective) ~= "string" or not Inputs.objectives[objective] then
		return false, "objective must be a supported PoB optimizer objective"
	end
	local labels = { }
	for index, plan in ipairs(plans) do
		if type(plan) ~= "table" then return false, "plans[" .. index .. "] must be an object" end
		for key in pairs(plan) do
			if key ~= "label" and key ~= "stages" then
				return false, "plans[" .. index .. "] has an unsupported field: " .. tostring(key)
			end
		end
		local label = plan.label
		if type(label) ~= "string" or label == "" or #label > 80 or label:find("[%c]")
			or label:find("^%s*$") then
			return false, "plans[" .. index .. "].label must be visible text of at most 80 characters"
		end
		local normalized = label:lower():gsub("%s+", " "):match("^%s*(.-)%s*$")
		if labels[normalized] then return false, "Campaign proposal labels must be unique" end
		labels[normalized] = true
		local valid, validationError = progression.ValidateStages(build, plan.stages, baseClassId)
		if not valid then return false, "plans[" .. index .. "]: " .. tostring(validationError) end
	end
	return true
end

local function primitiveMap(source)
	local result = { }
	for _, key in ipairs(sortedKeys(source)) do
		local value = source[key]
		if type(key) == "string" or type(key) == "number" then
			if type(value) == "string" or type(value) == "number" or type(value) == "boolean" then
				result[#result + 1] = { key = tostring(key), value = value }
			end
		end
	end
	return result
end

local function treeFingerprint(spec)
	local allocated, mastery, jewels, overrides = { }, { }, { }, { }
	for id in pairs(spec.allocNodes or { }) do allocated[#allocated + 1] = id end
	for id, effect in pairs(spec.masterySelections or { }) do mastery[#mastery + 1] = { id, effect } end
	for id, itemId in pairs(spec.jewels or { }) do jewels[#jewels + 1] = { id, itemId } end
	for id, node in pairs(spec.hashOverrides or { }) do
		overrides[#overrides + 1] = { id = id, dn = node.dn, type = node.type, sd = node.sd }
	end
	table.sort(allocated)
	table.sort(mastery, function(a, b) return a[1] < b[1] end)
	table.sort(jewels, function(a, b) return a[1] < b[1] end)
	table.sort(overrides, function(a, b) return a.id < b.id end)
	return {
		title = spec.title, treeVersion = spec.treeVersion, classId = spec.curClassId,
		ascendClassId = spec.curAscendClassId, secondaryAscendClassId = spec.curSecondaryAscendClassId,
		allocated = allocated, mastery = mastery, jewels = jewels, overrides = overrides,
	}
end

local function itemFingerprint(itemsTab, itemSetId)
	local set = itemsTab.itemSets[itemSetId]
	local slots, items, seenItems = { }, { }, { }
	for _, slotName in ipairs(sortedKeys(set)) do
		local slot = set[slotName]
		if type(slot) == "table" then
			slots[#slots + 1] = { slot = tostring(slotName), itemId = slot.selItemId, active = slot.active }
			local itemId = slot.selItemId
			local item = itemId and itemId > 0 and itemsTab.items[itemId]
			if item and not seenItems[itemId] then
				seenItems[itemId] = true
				local mods = { }
				for _, groupName in ipairs({ "implicitModLines", "explicitModLines", "craftedModLines", "eldritchModLines", "crucibleModLines" }) do
					for _, line in ipairs(item[groupName] or { }) do mods[#mods + 1] = line.line or "" end
				end
				items[#items + 1] = {
					id = itemId, fields = primitiveMap(item), name = item.name, rarity = item.rarity, type = item.type,
					base = item.base and item.base.name or nil, mods = mods,
					jewelData = primitiveMap(item.jewelData),
				}
			end
		end
	end
	table.sort(items, function(a, b) return a.id < b.id end)
	return { title = set.title, useSecondWeaponSet = set.useSecondWeaponSet, slots = slots, items = items }
end

local function skillFingerprint(skillSet)
	local groups = { }
	for _, group in ipairs(skillSet.socketGroupList or { }) do
		local gems = { }
		for _, gem in ipairs(group.gemList or { }) do
			gems[#gems + 1] = primitiveMap(gem)
		end
		groups[#groups + 1] = { fields = primitiveMap(group), gems = gems }
	end
	return { title = skillSet.title, groups = groups }
end

local function configFingerprint(configSet)
	local custom = { }
	for index, entry in ipairs(configSet.customModsList or { }) do
		custom[index] = { title = entry.title, enabled = entry.enabled, text = entry.text }
	end
	return {
		title = configSet.title,
		input = primitiveMap(configSet.input),
		placeholder = primitiveMap(configSet.placeholder),
		customModsList = custom,
	}
end

local function sourceSignature(build, stages, baseClassId)
	local sources = { build = Candidate.BuildSignature(build), baseClassId = baseClassId, stages = { } }
	local seen = { tree = { }, item = { }, skill = { }, config = { } }
	for index, stage in ipairs(stages) do
		local treeId, itemId, skillId, configId = stage.treeSpecIndex, stage.itemSetId, stage.skillSetId, stage.configSetId
		local treeSpec = build.treeTab.specList[treeId]
		local itemSet = build.itemsTab.itemSets[itemId]
		local skillSet = build.skillsTab.skillSets[skillId]
		local configSet = build.configTab.configSets[configId]
		if not treeSpec or not itemSet or not skillSet or not configSet then
			return nil, "A selected PoB tree, item, skill, or config set was removed during the audit"
		end
		local record = {
			treeSpecIndex = treeId, itemSetId = itemId, skillSetId = skillId, configSetId = configId,
			mainSocketGroup = resolvedMainGroupIndex(build, stage),
			mainSkillIndex = resolvedMainSkillIndex(build, stage),
			proposal = copyStage(stage),
		}
		if not seen.tree[treeId] then seen.tree[treeId] = treeFingerprint(treeSpec) end
			if not seen.item[itemId] then seen.item[itemId] = itemFingerprint(build.itemsTab, itemId) end
			if not seen.skill[skillId] then seen.skill[skillId] = skillFingerprint(skillSet) end
			if not seen.config[configId] then seen.config[configId] = configFingerprint(configSet) end
		sources.stages[index] = record
	end
	sources.selectedData = seen
	local encoded, err = dkjson.encode(sources)
	if type(encoded) ~= "string" then return nil, err or "Could not fingerprint selected progression loadouts" end
	return encoded
end

local function cloneSkillTab(source, proxyBuild, skillSetId, gemVariants)
	local selected = source.skillSets[skillSetId]
	if not selected then return nil, "The selected PoB skill set is unavailable" end
	local variantBySlot = { }
	for _, variant in ipairs(gemVariants or { }) do
		variantBySlot[tostring(variant.groupIndex) .. ":" .. tostring(variant.gemIndex)] = variant
	end
	local skillTab = shallowCopy(source)
	setmetatable(skillTab, getmetatable(source))
	local groups = { }
	for groupIndex, group in ipairs(selected.socketGroupList or { }) do
		local groupCopy = shallowCopy(group)
		groupCopy.gemList = { }
		for gemIndex, gem in ipairs(group.gemList or { }) do groupCopy.gemList[gemIndex] = shallowCopy(gem) end
		for gemIndex, gemCopy in ipairs(groupCopy.gemList) do
			local variant = variantBySlot[tostring(groupIndex) .. ":" .. tostring(gemIndex)]
			if variant then
				local gemData = variant.gemId and proxyBuild.data.gems[variant.gemId] or gemCopy.gemData
				gemCopy.gemData = gemData
				gemCopy.grantedEffect = gemData and gemData.grantedEffect
				gemCopy.gemId = gemData and gemData.id or gemCopy.gemId
				gemCopy.skillId = gemData and gemData.grantedEffectId or gemCopy.skillId
				gemCopy.nameSpec = gemData and gemData.name or gemCopy.nameSpec
				gemCopy.level = variant.level
				gemCopy.quality = variant.quality
			end
		end
		groups[groupIndex] = groupCopy
	end
	local selectedCopy = shallowCopy(selected)
	selectedCopy.socketGroupList = groups
	skillTab.skillSets = shallowCopy(source.skillSets)
	skillTab.skillSets[skillSetId] = selectedCopy
	skillTab.socketGroupList = groups
	skillTab.activeSkillSetId = skillSetId
	skillTab.imbuedSupportBySlot = shallowCopy(source.imbuedSupportBySlot)
	skillTab.build = proxyBuild
	return skillTab
end

local function skillName(activeSkill)
	if not activeSkill then return nil end
	local effect = activeSkill.activeEffect or (activeSkill.effectList and activeSkill.effectList[1])
	return effect and effect.grantedEffect and effect.grantedEffect.name or nil
end

local function evaluateStage(build, stage, baseClassId)
	local selectedSpec = build.treeTab.specList[stage.treeSpecIndex]
	local proxy = shallowCopy(build)
	setmetatable(proxy, { __index = build })
	proxy.treeTab = shallowCopy(build.treeTab)
	proxy.treeTab.activeSpec = stage.treeSpecIndex
	proxy.spec = selectedSpec
	proxy.characterLevel = stage.level
	proxy.characterLevelAutoMode = false
	local mainGroupIndex = resolvedMainGroupIndex(build, stage)
	proxy.mainSocketGroup = mainGroupIndex
	proxy.itemsTab = Scenario.CloneItemsTab(build.itemsTab, stage.itemSetId, false)
	if not proxy.itemsTab then error("PoB could not clone the selected item set") end
	proxy.itemsTab.build = proxy
	proxy.skillsTab = cloneSkillTab(build.skillsTab, proxy, stage.skillSetId, stage.gemVariants)
	if not proxy.skillsTab then error("PoB could not clone the selected skill set") end
	local selectedGroup = proxy.skillsTab.socketGroupList[mainGroupIndex]
	local mainSkillIndex = resolvedMainSkillIndex(build, stage)
	selectedGroup.mainActiveSkill = mainSkillIndex
	selectedGroup.mainActiveSkillCalcs = mainSkillIndex
	selectedGroup.optimizerRequestedMainSkillIndex = mainSkillIndex
	proxy.calcsTab = shallowCopy(build.calcsTab)
	setmetatable(proxy.calcsTab, getmetatable(build.calcsTab))
	proxy.calcsTab.input = shallowCopy(build.calcsTab.input)
	proxy.calcsTab.mainOutput, proxy.calcsTab.mainEnv = nil, nil
	proxy.calcsTab.build = proxy
	local configTab, configError = Scenario.CloneConfiguration(build.configTab, proxy, nil, nil, stage.configSetId)
	if not configTab then error(configError or "PoB could not clone the selected config set") end
	proxy.configTab = configTab
	local validationRootSpec = selectedSpec
	if baseClassId ~= nil then
		local rootSpec, rootError = Candidate.BuildPassiveSpec(proxy, { }, { }, { classId = baseClassId })
		if not rootSpec then error(rootError or "PoB could not construct the selected class-root stage") end
		validationRootSpec = rootSpec
	end
	local candidateVariants = { }
	if baseClassId ~= nil then candidateVariants.classId = baseClassId end
	if next(stage.equipmentOverrides or { }) then
		candidateVariants.gearVariant = { overrides = stage.equipmentOverrides }
	end
	local spec, specError, itemsTab = Candidate.BuildPassiveSpec(proxy, stage.addNodeIds, stage.removeNodeIds, candidateVariants)
	if not spec then error(specError or "PoB could not clone the selected passive tree") end
	local treeInput = {
		branch = { partition = "class", required = { }, allowed = { }, forbidden = { } },
		search = {
			addNodeIds = stage.addNodeIds or { }, removeNodeIds = stage.removeNodeIds or { },
			requiredNodeIds = { }, forbiddenNodeIds = { },
		},
		targetNodeIds = { },
	}
	local treeValid, treeError = TreeSearch.ValidateCandidate(
		validationRootSpec, stage.addNodeIds, treeInput, nil, stage.removeNodeIds, spec)
	if not treeValid then error("Stage tree proposal failed native structural validation: " .. tostring(treeError)) end
	proxy.spec = spec
	proxy.itemsTab = itemsTab
	proxy.itemsTab.build = proxy
	proxy.spec.build.itemsTab = proxy.itemsTab
	proxy.spec.build.skillsTab = proxy.skillsTab
	proxy.spec.build.configTab = proxy.configTab
	local _, output, env = Calcs.getMiscCalculator(proxy)
	if type(output) ~= "table" or type(env) ~= "table" then error("PoB's exact calculator did not return a stage output and environment") end
	local extraPoints = output.ExtraPoints
	if not finite(extraPoints) and env.modDB and type(env.modDB.Sum) == "function" then
		local ok, value = pcall(env.modDB.Sum, env.modDB, "BASE", nil, "ExtraPoints")
		if ok and finite(value) then extraPoints = value end
	end
	if not finite(extraPoints) then error("PoB did not expose exact ExtraPoints for this stage configuration") end
	local passivePoints = spec:CountAllocNodes()
	local pointLimit, act = proxy:GetPassivePointLimitForLevel(stage.level, extraPoints)
	if not finite(pointLimit) or pointLimit < 0 or pointLimit ~= math.floor(pointLimit)
		or not finite(act) or act < 1 or act ~= math.floor(act) then
		error("PoB returned an invalid native act/passive-point result for stage level " .. tostring(stage.level))
	end
	local requirementCheck = Validator.CheckRequirements(output, stage.level)
	local violations, warnings = { }, { }
	for _, violation in ipairs(requirementCheck.violations or { }) do violations[#violations + 1] = violation end
	local hard = { }
	for _, constraint in ipairs(stage.hardConstraints or { }) do
		local definition = metricDefinitionByKey[constraint.key]
		hard[constraint.key] = {
			operator = definition.operator or ">=", metricKey = definition.metricKey or definition.key,
			value = constraint.value, label = definition.label,
		}
	end
	local metrics = Candidate.CopyMetrics(output, Inputs.metricDefinitions)
	local hardCheck = Validator.Check({ hard = hard }, metrics)
	for _, violation in ipairs(hardCheck.violations or { }) do violations[#violations + 1] = violation end
	if passivePoints > pointLimit then
		violations[#violations + 1] = {
			key = "passive_point_limit", label = "Native passive points at level " .. stage.level,
			actual = passivePoints, required = pointLimit, deficit = passivePoints - pointLimit,
			reason = "Tree exceeds PoB's level and act-quest passive point limit",
		}
	end
	local activeSkill = env.player and env.player.mainSkill
	local mainSkill = skillName(activeSkill)
	if selectedGroup.optimizerResolvedMainSkillIndex ~= mainSkillIndex
		or type(mainSkill) ~= "string" or mainSkill == "" then
		violations[#violations + 1] = {
			key = "main_skill", label = "Selected progression skill",
			reason = "PoB could not resolve the requested Main Skill index from this stage's selected skill set", deficit = 1,
		}
	end
	local payability = Validator.CheckMainSkillPayability(output, mainSkill)
	for _, violation in ipairs(payability.violations or { }) do violations[#violations + 1] = violation end
	local objective = finite(output.FullDPS) and output.FullDPS > 0 and "FullDPS" or "CombinedDPS"
	local sustain = Activity.Evaluate({ objective = objective, hard = { } }, output.OptimizerMainSkillActivity,
		output.FullDPSActivity, output.FullDPSActivityTruncated)
	if sustain.status == "violated" then
		for _, violation in ipairs(sustain.violations or { }) do violations[#violations + 1] = violation end
	elseif sustain.status == "unsupported" then
		warnings[#warnings + 1] = {
			key = "activity_sustain_unsupported",
			detail = table.concat(sustain.unsupported or { "PoB could not certify activity sustain" }, "; "),
		}
	elseif sustain.status == "not_required" then
		warnings[#warnings + 1] = { key = "activity_sustain_not_required", detail = "No PoB damage activity was available for sustain certification." }
	end
	if payability.status == "unsupported" then
		warnings[#warnings + 1] = { key = "main_skill_payability_unsupported", detail = "PoB could not certify the selected skill's upfront resource cost." }
	end
	local activeSkillAvailability = SkillAvailability.Evaluate(
		{ objective = objective, hard = hard }, env.player,
		output.FullDPSSkillAvailability, output)
	if activeSkillAvailability.status == "violated" then
		for _, violation in ipairs(activeSkillAvailability.violations or { }) do violations[#violations + 1] = violation end
	elseif activeSkillAvailability.status == "unsupported" then
		warnings[#warnings + 1] = {
			key = "damage_availability_unsupported",
			detail = safeText(activeSkillAvailability.reason or "PoB could not certify sustained damage availability", 300),
		}
	end
	local conversionResult = Conversion.Evaluate(activeSkill, stage.conversion and stage.conversion.route,
		stage.conversion and stage.conversion.minimumPercent or 100)
	if not conversionResult.satisfied then
		for _, shortfall in ipairs(conversionResult.shortfall or { "Exact PoB conversion did not satisfy the requested stage route" }) do
			violations[#violations + 1] = { key = "conversion", label = "Stage damage conversion", reason = shortfall, deficit = 1 }
		end
	end
	local triggerResult = Breakpoints.Evaluate(activeSkill, output, stage.requiredTriggerRate)
	if triggerResult.status == "violated" then
		for _, detail in ipairs(triggerResult.violations or { }) do
			violations[#violations + 1] = { key = "trigger_breakpoint", label = "Stage server breakpoint", reason = detail, deficit = 1 }
		end
	elseif triggerResult.status == "unsupported" then
		warnings[#warnings + 1] = {
			key = "trigger_breakpoint_unsupported",
			detail = safeText(table.concat(triggerResult.violations or { "PoB could not certify the stage trigger breakpoint" }, "; "), 300),
		}
	end
	local status = #violations > 0 and "failed" or (#warnings > 0 and "uncertified" or "passed")
	return {
		level = stage.level,
		status = status,
		legal = #requirementCheck.violations == 0 and passivePoints <= pointLimit,
		certified = status == "passed",
		campaignAudit = campaignAuditSnapshot(),
		loadout = {
			treeSpecIndex = stage.treeSpecIndex,
			treeTitle = baseClassId ~= nil and (safeText(spec.curClassName or "Selected class", 80) .. " native root") or safeText(selectedSpec.title or "Default", 100),
			treeVersion = safeText(selectedSpec.treeVersion or "", 40), itemSetId = stage.itemSetId,
			itemSetTitle = safeText(proxy.itemsTab.activeItemSet.title or "Default", 100),
			skillSetId = stage.skillSetId, skillSetTitle = safeText(proxy.skillsTab.skillSets[stage.skillSetId].title or "Default", 100),
			configSetId = stage.configSetId, configSetTitle = safeText(proxy.configTab.configSets[stage.configSetId].title or "Default", 100),
			mainSocketGroup = mainGroupIndex, mainSkillIndex = mainSkillIndex, mainSkill = safeText(mainSkill or "", 100),
			classId = spec.curClassId, className = safeText(spec.curClassName or spec.curClass and spec.curClass.name or "Unknown", 80),
			treeAddedNodeIds = copyArray(spec.optimizerAddedNodeIds),
			treeRemovedNodeIds = copyArray(spec.optimizerRemovedNodeIds),
			gemChanges = copyStage({ gemVariants = stage.gemVariants }).gemVariants,
			equipmentOverrides = shallowCopy(stage.equipmentOverrides),
		},
		passivePoints = {
			used = passivePoints, limit = pointLimit, extraPoints = extraPoints,
			act = act, actLabel = nativeActLabel(act),
		},
		requirements = requirementCheck,
		hardConstraints = hardCheck,
		mainSkillPayability = payability,
		activitySustain = sustain,
		damageAvailability = activeSkillAvailability,
		conversion = conversionResult,
		serverBreakpoint = triggerResult,
		metrics = metrics,
		violations = violations,
		warnings = warnings,
		exactEngine = true,
	}
end

local function runStages(job)
	for index, stage in ipairs(job.stages) do
		if job.cancelRequested then job.status = "cancelled" return end
		job.progress = { phase = "PoB exact calculation", currentStage = index, totalStages = 4, completedStages = #job.results }
		local ok, result = pcall(evaluateStage, job.build, stage, job.baseClassId)
		if ok then
			job.results[index] = result
		else
			job.results[index] = {
				level = stage.level, status = "error", certified = false, legal = false,
				message = safeText(result, 400), exactEngine = false, calculationAttempted = true,
			}
		end
		job.progress.completedStages = #job.results
		if index < #job.stages then coroutine.yield(job.progress) end
	end
	job.status = "completed"
	job.completedAt = os.time()
end

function progression.Start(build, stages, jobId, baseClassId)
	local valid, validationError = progression.ValidateStages(build, stages, baseClassId)
	if not valid then return nil, validationError end
	local signature, signatureError = sourceSignature(build, stages, baseClassId)
	if not signature then return nil, signatureError end
	local stageCopies = { }
	for index, stage in ipairs(stages) do
		stageCopies[index] = copyStage(stage)
		stageCopies[index].mainSocketGroup = resolvedMainGroupIndex(build, stage)
		stageCopies[index].mainSkillIndex = resolvedMainSkillIndex(build, stage)
	end
	local job = {
		jobId = jobId,
		build = build,
		baseClassId = baseClassId,
		stages = stageCopies,
		sourceSignature = signature,
		status = "running",
		results = { },
		progress = { phase = "Queued", currentStage = 1, totalStages = 4, completedStages = 0 },
		startedAt = os.time(),
		readOnly = true,
		activeBuildPreserved = true,
	}
	job.thread = coroutine.create(runStages)
	return job
end

function progression.StartComparison(build, plans, objective, jobId, baseClassId)
	local valid, validationError = progression.ValidatePlans(build, plans, objective, baseClassId)
	if not valid then return nil, validationError end
	local planJobs = { }
	for index, plan in ipairs(plans) do
		local planJob, startError = progression.Start(build, plan.stages,
			tostring(jobId) .. "-plan-" .. tostring(index), baseClassId)
		if not planJob then return nil, "Campaign proposal " .. index .. " could not start: " .. tostring(startError) end
		planJobs[index] = {
			label = safeText(plan.label, 80),
			job = planJob,
		}
	end
	local job = {
		kind = "comparison",
		jobId = jobId,
		build = build,
		baseClassId = baseClassId,
		objective = objective,
		plans = planJobs,
		status = "running",
		currentPlanIndex = 1,
		completedPlans = 0,
		progress = { phase = "Queued", currentPlan = 1, totalPlans = #planJobs, currentStage = 1, totalStages = 4, completedStages = 0 },
		startedAt = os.time(),
		readOnly = true,
		activeBuildPreserved = true,
	}
	return job
end

function progression.StepComparison(job, activeBuild)
	if not job or job.kind ~= "comparison" or job.status ~= "running" then return end
	if job.cancelRequested then
		local current = job.plans[job.currentPlanIndex]
		if current and current.job.status == "running" then
			current.job.cancelRequested = true
			progression.Step(current.job, activeBuild)
		end
		job.status = "cancelled"
		job.completedAt = os.time()
		return
	end
	if activeBuild ~= job.build then
		local current = job.plans[job.currentPlanIndex]
		if current and current.job.status == "running" then progression.Step(current.job, activeBuild) end
		job.status = "stale_build"
		job.error = "The active PoB build changed while campaign proposals were being compared"
		job.completedAt = os.time()
		return
	end
	local plan = job.plans[job.currentPlanIndex]
	if not plan then
		job.status = "completed"
		job.completedAt = os.time()
		return
	end
	progression.Step(plan.job, activeBuild)
	if plan.job.status ~= "running" then
		if plan.job.status ~= "completed" then
			job.status = plan.job.status
			job.error = plan.job.error
			job.completedAt = os.time()
			return
		end
		job.completedPlans = job.completedPlans + 1
		job.currentPlanIndex = job.currentPlanIndex + 1
		if job.currentPlanIndex > #job.plans then
			job.status = "completed"
			job.completedAt = os.time()
			job.progress = {
				phase = "PoB exact comparison complete", currentPlan = #job.plans,
				totalPlans = #job.plans, currentStage = 4, totalStages = 4,
				completedStages = 4, completedPlans = job.completedPlans,
			}
		else
			job.progress = {
				phase = "PoB exact comparison", currentPlan = job.currentPlanIndex,
				totalPlans = #job.plans, currentStage = 1, totalStages = 4,
				completedStages = 0, completedPlans = job.completedPlans,
			}
		end
	else
		local innerProgress = plan.job.progress or { }
		job.progress = {
			phase = "PoB exact comparison",
			currentPlan = job.currentPlanIndex,
			totalPlans = #job.plans,
			currentStage = innerProgress.currentStage or 1,
			totalStages = 4,
			completedStages = innerProgress.completedStages or #plan.job.results,
			completedPlans = job.completedPlans,
			label = plan.label,
		}
	end
end

local function summarizeComparisonPlan(plan, objective, referenceResults)
	local summary = progression.Summary(plan.job)
	local strictPass, failedStages, uncertifiedStages = summary.exactEngine, 0, 0
	local objectiveValues, objectiveMinimum, objectiveTotal, metricMissing = { }, nil, 0, false
	local objectiveDeltas = { }
	for index, result in ipairs(summary.results or { }) do
		if result.status ~= "passed" or result.legal ~= true or #(result.violations or { }) > 0 then strictPass = false end
		if result.status == "failed" or result.status == "error" then failedStages = failedStages + 1 end
		if result.status == "uncertified" or result.status == "error" or result.exactEngine ~= true then uncertifiedStages = uncertifiedStages + 1 end
		local value = result.metrics and result.metrics[objective]
		if finite(value) then
			objectiveValues[index] = value
			objectiveMinimum = objectiveMinimum and math.min(objectiveMinimum, value) or value
			objectiveTotal = objectiveTotal + value
			local reference = referenceResults and referenceResults[index]
			local referenceValue = reference and reference.metrics and reference.metrics[objective]
			if finite(referenceValue) then objectiveDeltas[index] = value - referenceValue end
		else
			metricMissing = true
			strictPass = false
		end
	end
	local mean = #objectiveValues == #expectedLevels and objectiveTotal / #objectiveValues or nil
	return {
		label = plan.label,
		status = summary.status,
		exactEngine = summary.exactEngine,
		strictlyPassedAllStages = strictPass and #summary.results == #expectedLevels,
		failedStages = failedStages,
		uncertifiedStages = uncertifiedStages,
		objectiveMetric = objective,
		objectiveValuesByStage = objectiveValues,
		objectiveFloor = objectiveMinimum,
		objectiveMean = mean,
		objectiveMetricMissing = metricMissing,
		objectiveDeltasFromReference = objectiveDeltas,
		stages = summary.results,
		campaignAudit = summary.campaignAudit,
		readOnly = true,
		activeBuildPreserved = summary.activeBuildPreserved,
	}
end

local function comparisonPlanComesBefore(left, right)
	if left.strictlyPassedAllStages ~= right.strictlyPassedAllStages then return left.strictlyPassedAllStages end
	if left.failedStages ~= right.failedStages then return left.failedStages < right.failedStages end
	if left.uncertifiedStages ~= right.uncertifiedStages then return left.uncertifiedStages < right.uncertifiedStages end
	if left.objectiveFloor ~= right.objectiveFloor then
		if left.objectiveFloor == nil then return false end
		if right.objectiveFloor == nil then return true end
		return left.objectiveFloor > right.objectiveFloor
	end
	if left.objectiveMean ~= right.objectiveMean then
		if left.objectiveMean == nil then return false end
		if right.objectiveMean == nil then return true end
		return left.objectiveMean > right.objectiveMean
	end
	return left.inputIndex < right.inputIndex
end

function progression.SummaryComparison(job)
	if not job or job.kind ~= "comparison" then return nil end
	local reference = job.plans[1]
	local referenceSummary = reference and progression.Summary(reference.job)
	local referenceResults = referenceSummary and referenceSummary.results
	local alternatives = { }
	for index, plan in ipairs(job.plans or { }) do
		local result = summarizeComparisonPlan(plan, job.objective, index == 1 and nil or referenceResults)
		result.inputIndex = index
		alternatives[index] = result
	end
	local ranked = { }
	if job.status == "completed" then
		for index, alternative in ipairs(alternatives) do ranked[index] = alternative end
		table.sort(ranked, comparisonPlanComesBefore)
	end
	local best = ranked[1]
	local passing = { }
	for _, alternative in ipairs(ranked) do
		if alternative.strictlyPassedAllStages then passing[#passing + 1] = alternative end
	end
	local exactEngine = job.status == "completed"
	if exactEngine then
		for _, alternative in ipairs(alternatives) do
			if alternative.exactEngine ~= true then exactEngine = false break end
		end
	end
	return {
		jobId = job.jobId,
		kind = "campaign_route_comparison",
		status = job.status,
		resultStatus = job.status ~= "completed" and job.status
			or (#passing > 0 and "at_least_one_plan_passed_all_engine_gates" or "no_plan_passed_all_engine_gates"),
		progress = job.progress,
		objectiveMetric = job.objective,
		comparisonReference = reference and reference.label or nil,
		alternatives = alternatives,
		ranking = ranked,
		exactEngine = exactEngine,
		bestEnginePassingPlan = job.status == "completed" and #passing > 0 and passing[1].label or nil,
		bestObservedPlan = job.status == "completed" and best and best.label or nil,
		candidateDelivered = false,
		campaignAvailability = "not_certified",
		campaignAudit = campaignAuditSnapshot(),
		readOnly = true,
		activeBuildPreserved = true,
		startedAt = job.startedAt,
		completedAt = job.completedAt,
	}
end

function progression.Step(job, activeBuild)
	if job and job.kind == "comparison" then return progression.StepComparison(job, activeBuild) end
	if not job or job.status ~= "running" then return end
	if job.cancelRequested then
		job.status = "cancelled"
		job.completedAt = os.time()
		return
	end
	if activeBuild ~= job.build then
		job.status = "stale_build"
		job.error = "The active PoB build changed while the progression audit was yielding"
		job.completedAt = os.time()
		return
	end
	local signatureOk, signature, signatureError = pcall(sourceSignature, job.build, job.stages, job.baseClassId)
	if not signatureOk or not signature or signature ~= job.sourceSignature then
		job.status = "stale_build"
		job.error = signatureOk and (signatureError or "A selected PoB tree, item, skill, or config set changed during the audit")
			or "Could not verify the selected PoB loadouts after a build change"
		job.completedAt = os.time()
		return
	end
	local ok, value = coroutine.resume(job.thread, job)
	if not ok then
		job.status = "failed"
		job.error = safeText(value, 400)
		job.completedAt = os.time()
	elseif coroutine.status(job.thread) == "dead" and job.status == "running" then
		job.status = "completed"
		job.completedAt = os.time()
	else
		job.progress = value or job.progress
	end
end

function progression.Summary(job)
	if not job then return nil end
	if job.kind == "comparison" then return progression.SummaryComparison(job) end
	local exactEngine = #job.results == #job.stages and #job.stages == #expectedLevels
	if exactEngine then
		for _, result in ipairs(job.results) do
			if result.exactEngine ~= true then exactEngine = false break end
		end
	end
	return {
		jobId = job.jobId,
		baseClassId = job.baseClassId,
		status = job.status,
		progress = job.progress,
		completedStages = #job.results,
		totalStages = 4,
		results = job.results,
		error = job.error,
		readOnly = true,
		activeBuildPreserved = true,
		exactEngine = exactEngine,
		campaignAudit = campaignAuditSnapshot(),
		startedAt = job.startedAt,
		completedAt = job.completedAt,
	}
end

function progression.Cancel(job)
	if not job then return false end
	if job.status == "running" then
		job.cancelRequested = true
		if job.kind == "comparison" then
			local current = job.plans and job.plans[job.currentPlanIndex]
			if current and current.job then progression.Cancel(current.job) end
		end
		return true
	end
	return false
end

return progression
