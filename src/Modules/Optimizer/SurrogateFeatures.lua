-- Path of Building
--
-- Module: shared, popularity-free feature projection for the optional single
-- hidden-layer MLP. Version 6 uses socket/link-validated support provenance and
-- item source context. It never evaluates or certifies a build.

local features = { }
local sha = require("sha2")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")

local numericNames = { "level", "allocatedPointCount", "baselineObjective", "baselineTotalEHP", "pointDelta" }
local FEATURE_POLICY = "exact-pair-build-context-lineage-engine-manifest-v6"

local function finite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function positiveId(value)
	value = tonumber(value)
	if finite(value) and value > 0 and value == math.floor(value) then return value end
	return nil
end

local function safeCategory(value, maxLength)
	if type(value) ~= "string" or value == "" or #value > (maxLength or 128) or value:find("[%c]") then return nil end
	return value
end

local function sortedIds(values)
	local result, seen = { }, { }
	if type(values) ~= "table" then return result end
	for _, value in pairs(values) do
		local id = positiveId(value)
		if id and not seen[id] then
			seen[id] = true
			result[#result + 1] = id
		end
	end
	table.sort(result)
	return result
end

local function addToken(tokenSet, token)
	if type(token) == "string" and token ~= "" then tokenSet[token] = true end
end

local function addSupportContext(tokenSet, support)
	if type(support) ~= "table" or support.supportProfileVersion ~= 2 or support.playableActive ~= true then return end
	local origin = safeCategory(support.origin, 32)
	local effectId = safeCategory(support.effectId, 180)
	local gameId = safeCategory(support.gameId, 200)
	local gemId = safeCategory(support.gemId, 160)
	local variantId = safeCategory(support.variantId, 200)
	local sourceSlot = safeCategory(support.sourceSlot, 64)
	local sourceFingerprint = safeCategory(support.sourceItemFingerprint, 64)
	local targetEffectId = safeCategory(support.targetEffectId, 180)
	if origin then addToken(tokenSet, "support-origin:" .. origin) end
	if effectId then addToken(tokenSet, "support-effect:" .. effectId) end
	if gameId then addToken(tokenSet, "support-game:" .. gameId) end
	if gemId then addToken(tokenSet, "support-variant:" .. gemId) end
	if variantId then addToken(tokenSet, "support-variant-name:" .. variantId) end
	if sourceSlot then addToken(tokenSet, "support-source-slot:" .. sourceSlot) end
	if targetEffectId then addToken(tokenSet, "support-target-effect:" .. targetEffectId) end
	local targetGroupIndex = positiveId(support.targetGroupIndex)
	local targetSkillIndex = positiveId(support.targetSkillIndex)
	if targetGroupIndex and targetGroupIndex <= 48 then
		addToken(tokenSet, "support-target-group:" .. tostring(targetGroupIndex))
	end
	if targetSkillIndex and targetSkillIndex <= 12 then
		addToken(tokenSet, "support-target-skill-index:" .. tostring(targetSkillIndex))
	end
	if sourceFingerprint and #sourceFingerprint == 64 and sourceFingerprint:match("^[%da-fA-F]+$") then
		addToken(tokenSet, "support-source-item:" .. sourceFingerprint:lower())
	end
	local level, quality = tonumber(support.level), tonumber(support.quality)
	if finite(level) and level >= 1 and level <= 100 then addToken(tokenSet, "support-level:" .. tostring(level)) end
	if finite(quality) and quality >= 0 and quality <= 100 then addToken(tokenSet, "support-quality:" .. tostring(quality)) end
end

-- Hash PoB's canonical item serialization so different rolls, enchants,
-- sockets, corruption and variant selections remain distinct. Raw item text is
-- never emitted as a model feature.
function features.ItemFingerprint(item)
	if type(item) ~= "table" then return nil end
	local raw
	if type(item.BuildRaw) == "function" then
		local ok, built = pcall(item.BuildRaw, item)
		if ok and type(built) == "string" and built ~= "" then raw = built end
	end
	if not raw then
		local fields = { tostring(item.rarity or ""), tostring(item.title or item.name or ""),
			tostring(item.baseName or item.type or item.base and item.base.name or "") }
		for _, field in ipairs({ "enchantModLines", "scourgeModLines", "implicitModLines", "explicitModLines",
			"craftedModLines", "eldritchModLines", "crucibleModLines" }) do
			for _, line in ipairs(item[field] or { }) do
				local text = type(line) == "table" and (line.line or line.modId) or line
				if type(text) == "string" then fields[#fields + 1] = field .. ":" .. text end
			end
		end
		for socketIndex, socket in ipairs(item.sockets or { }) do
			fields[#fields + 1] = "socket:" .. tostring(socketIndex) .. ":" .. tostring(socket.color or "") .. ":" .. tostring(socket.group or "")
		end
		raw = table.concat(fields, "\n")
	end
	raw = raw:gsub("\r\n", "\n"):gsub("\r", "\n")
	return sha.sha256(raw)
end

local function addBuildContext(tokenSet, skillGroups, itemSlots)
	for groupIndex, group in ipairs(type(skillGroups) == "table" and skillGroups or { }) do
		if groupIndex > 48 then break end
		local slot = safeCategory(group.slot, 64)
		if slot then addToken(tokenSet, "skill-group-slot:" .. slot) end
		addToken(tokenSet, "skill-group:enabled:" .. tostring(group.enabled == true))
		addToken(tokenSet, "skill-group:slot-enabled:" .. tostring(group.slotEnabled == true))
		addToken(tokenSet, "skill-group:full-dps:" .. tostring(group.includeInFullDPS == true))
		if group.selectedMainGroup == true then addToken(tokenSet, "selected-main-skill-group") end
		local socketValidation = type(group.socketValidation) == "table" and group.socketValidation or { }
		if group.supportProfileVersion == 2 and type(socketValidation.valid) == "boolean" then
			addToken(tokenSet, "support-profile:v2")
			local validationStatus = safeCategory(socketValidation.status, 32) or "unknown"
			addToken(tokenSet, "skill-group-socket-validation:" .. validationStatus)
		else
			addToken(tokenSet, "support-profile:legacy-unknown")
		end
		for gemIndex, gem in ipairs(type(group.gems) == "table" and group.gems or { }) do
			if gemIndex > 32 then break end
			local enabled = group.supportProfileVersion == 2 and socketValidation.valid == true
				and gem.enabled == true and gem.socketMatched == true
			if enabled then
				local family = gem.isSupport == true and "support" or "active-gem"
				local gameId = safeCategory(gem.gameId, 200)
				local gemId = safeCategory(gem.gemId, 160)
				local skillId = safeCategory(gem.skillId, 180)
				if gameId then addToken(tokenSet, family .. ":game:" .. gameId) end
				if gemId then addToken(tokenSet, family .. ":variant:" .. gemId) end
				if skillId and gem.isSupport ~= true then addToken(tokenSet, "configured-skill-effect:" .. skillId) end
				if slot then addToken(tokenSet, family .. ":slot:" .. slot) end
				local level, quality = tonumber(gem.level), tonumber(gem.quality)
				if finite(level) and level >= 1 and level <= 100 then
					addToken(tokenSet, family .. ":level:" .. tostring(level))
				end
				if finite(quality) and quality >= 0 and quality <= 100 then
					addToken(tokenSet, family .. ":quality:" .. tostring(quality))
				end
			end
		end
		for skillIndex, skill in ipairs(type(group.skills) == "table" and group.skills or { }) do
			if skillIndex > 12 then break end
			if skill.supportProfileVersion == 2 then
				addToken(tokenSet, "skill-support-profile:v2")
				if skill.selectedMainSkill == true then addToken(tokenSet, "main-skill-support-profile:v2") end
				for supportIndex, support in ipairs(type(skill.supports) == "table" and skill.supports or { }) do
					if supportIndex > 64 then break end
					addSupportContext(tokenSet, support)
				end
			end
		end
	end
	for index, item in ipairs(type(itemSlots) == "table" and itemSlots or { }) do
		if index > 80 then break end
		local slot = safeCategory(item.slot, 64)
		local base = safeCategory(item.base, 120)
		local rarity = safeCategory(item.rarity, 40)
		local itemFingerprint = safeCategory(item.itemFingerprint, 64)
		if slot and base then addToken(tokenSet, "equipped-item-base:" .. slot .. ":" .. base) end
		if slot and rarity then addToken(tokenSet, "equipped-item-rarity:" .. slot .. ":" .. rarity) end
		if slot and itemFingerprint and #itemFingerprint == 64 and itemFingerprint:match("^[%da-fA-F]+$") then
			addToken(tokenSet, "equipped-item-fingerprint:" .. slot .. ":" .. itemFingerprint:lower())
		end
	end
end

local function buildInput(classId, ascendancyId, mainSkill, level, allocatedNodeIds, masterySelections,
		addedNodeIds, removedNodeIds, baselineMetrics, objective, skillGroups, itemSlots)
	classId = positiveId(classId)
	ascendancyId = tonumber(ascendancyId) or 0
	if not classId or not finite(ascendancyId) or ascendancyId < 0 or ascendancyId ~= math.floor(ascendancyId) then return nil end
	mainSkill = safeCategory(mainSkill, 128)
	if not mainSkill or not finite(level) or level < 1 or level > 100 then return nil end
	objective = safeCategory(objective, 96)
	if not objective or type(baselineMetrics) ~= "table" then return nil end
	local baselineObjective = baselineMetrics[objective]
	local baselineTotalEHP = baselineMetrics.TotalEHP
	if not finite(baselineObjective) or not finite(baselineTotalEHP) then return nil end
	allocatedNodeIds = sortedIds(allocatedNodeIds)
	addedNodeIds = sortedIds(addedNodeIds)
	removedNodeIds = sortedIds(removedNodeIds)
	if #allocatedNodeIds == 0 or #addedNodeIds + #removedNodeIds ~= 1 then return nil end

	local tokenSet = { }
	addToken(tokenSet, "class:" .. tostring(classId))
	addToken(tokenSet, "ascendancy:" .. tostring(ascendancyId))
	addToken(tokenSet, "skill:" .. mainSkill)
	for _, nodeId in ipairs(allocatedNodeIds) do addToken(tokenSet, "allocated-node:" .. tostring(nodeId)) end
	for _, nodeId in ipairs(addedNodeIds) do addToken(tokenSet, "added-node:" .. tostring(nodeId)) end
	for _, nodeId in ipairs(removedNodeIds) do addToken(tokenSet, "removed-node:" .. tostring(nodeId)) end

	local masteryList = { }
	if type(masterySelections) == "table" then
		for key, value in pairs(masterySelections) do
			local nodeId, effectId
			if type(value) == "table" then
				nodeId = positiveId(value.nodeId or value.id or key)
				effectId = positiveId(value.effectId or value.effect)
			else
				nodeId, effectId = positiveId(key), positiveId(value)
			end
			if nodeId and effectId then masteryList[#masteryList + 1] = { nodeId = nodeId, effectId = effectId } end
		end
	end
	table.sort(masteryList, function(left, right)
		if left.nodeId ~= right.nodeId then return left.nodeId < right.nodeId end
		return left.effectId < right.effectId
	end)
	for _, mastery in ipairs(masteryList) do
		addToken(tokenSet, "mastery:" .. tostring(mastery.nodeId) .. ":" .. tostring(mastery.effectId))
	end
	addBuildContext(tokenSet, skillGroups, itemSlots)

	local tokens = { }
	for token in pairs(tokenSet) do tokens[#tokens + 1] = token end
	table.sort(tokens)
	local changedNodeIds = { }
	for _, nodeId in ipairs(addedNodeIds) do changedNodeIds[#changedNodeIds + 1] = nodeId end
	for _, nodeId in ipairs(removedNodeIds) do changedNodeIds[#changedNodeIds + 1] = nodeId end
	table.sort(changedNodeIds)
	return {
		featurePolicy = FEATURE_POLICY,
		objectiveMetric = objective,
		classId = classId,
		ascendancyId = ascendancyId,
		mainSkill = mainSkill,
		changedNodeIds = changedNodeIds,
		tokens = tokens,
		numeric = {
			level,
			#allocatedNodeIds,
			baselineObjective,
			baselineTotalEHP,
			#addedNodeIds - #removedNodeIds,
		},
		numericNames = numericNames,
	}
end

function features.FromStudyRow(rowFeatures, objective)
	if type(rowFeatures) ~= "table" or rowFeatures.kind ~= "passive_node_pair"
		or type(rowFeatures.experiment) ~= "table" or rowFeatures.experiment.unit ~= "one_passive_node" then return nil end
	local experiment = rowFeatures.experiment
	return buildInput(rowFeatures.classId, rowFeatures.ascendancyId or 0, rowFeatures.mainSkill,
		rowFeatures.characterLevel, rowFeatures.allocatedNodeIds, rowFeatures.masterySelections,
		experiment.addedNodeIds, experiment.removedNodeIds, rowFeatures.baselineMetrics, objective,
		rowFeatures.skillGroups, rowFeatures.itemSlots)
end

local function mainSkillName(build)
	local skillsTab = build and build.skillsTab
	local group = skillsTab and skillsTab.socketGroupList and skillsTab.socketGroupList[build.mainSocketGroup]
	local activeSkill = group and group.displaySkillList and group.displaySkillList[group.mainActiveSkill or 1]
	local effect = activeSkill and (activeSkill.activeEffect or (activeSkill.effectList and activeSkill.effectList[1]))
	return effect and effect.grantedEffect and effect.grantedEffect.name or nil
end

local function allocatedIds(spec)
	local result = { }
	for nodeId, allocated in pairs(spec and spec.allocNodes or { }) do
		if allocated then result[#result + 1] = nodeId end
	end
	table.sort(result)
	return result
end

local function liveSkillGroups(build, itemFingerprintsBySlot)
	local groups = { }
	for groupIndex, group in ipairs(build.skillsTab and build.skillsTab.socketGroupList or { }) do
		if groupIndex > 48 then break end
		local socketValidation = SkillCatalog.SocketGroupEvidence(build, groupIndex, group)
		local row = {
			groupIndex = groupIndex,
			slot = group.slot,
			enabled = group.enabled ~= false,
			slotEnabled = group.slotEnabled ~= false,
			includeInFullDPS = group.includeInFullDPS == true,
			selectedMainGroup = build.mainSocketGroup == groupIndex,
			supportProfileVersion = 2,
			socketValidation = socketValidation,
			gems = { },
			skills = { },
		}
		for gemIndex, gem in ipairs(group.gemList or { }) do
			if gemIndex > 32 then break end
			local data = gem.gemData
			local effect = gem.grantedEffect or data and data.grantedEffect
			row.gems[#row.gems + 1] = {
				gemId = tostring(gem.gemId or data and data.id or ""),
				gameId = tostring(data and data.gameId or ""),
				skillId = tostring(gem.skillId or data and data.grantedEffectId or ""),
				level = tonumber(gem.level) or 1,
				quality = tonumber(gem.quality) or 0,
				enabled = gem.enabled ~= false,
				isSupport = effect and effect.support == true or false,
				socketMatched = socketValidation.valid == true,
			}
		end
		for skillIndex, activeSkill in ipairs(group.displaySkillList or { }) do
			if skillIndex > 12 then break end
			local activeEffect = activeSkill.activeEffect
			if not activeEffect and activeSkill.effectList and #activeSkill.effectList == 1 then activeEffect = activeSkill.effectList[1] end
			local activeSupportSet = { }
			for _, effectInstance in ipairs(activeSkill.effectList or { }) do
				if effectInstance.grantedEffect and effectInstance.grantedEffect.support then activeSupportSet[effectInstance] = true end
			end
			local skillRow = {
				skillIndex = skillIndex,
				selectedMainSkill = build.mainSocketGroup == groupIndex and (group.mainActiveSkill or 1) == skillIndex,
				supportProfileVersion = 2,
				supports = { },
			}
			for supportIndex, support in ipairs(activeSkill.supportList or { }) do
				if supportIndex > 64 then break end
				local grantedEffect = support.grantedEffect
				if grantedEffect and grantedEffect.support then
					local sourceGem = support.srcInstance
					local gemData = support.gemData or sourceGem and sourceGem.gemData
					local evidence = SkillCatalog.SupportEvidence(build, groupIndex, group, support,
						activeSupportSet, itemFingerprintsBySlot, socketValidation)
					local origin = evidence.origin
					local sourceSlot = evidence.sourceSlot
					local sourceFingerprint = evidence.sourceItemFingerprint
					local targetEffectId = activeEffect and activeEffect.grantedEffect and activeEffect.grantedEffect.id or ""
					skillRow.supports[#skillRow.supports + 1] = {
						gemId = tostring(sourceGem and (sourceGem.gemId or gemData and gemData.id) or gemData and gemData.id or ""),
						gameId = tostring(gemData and gemData.gameId or ""),
						variantId = tostring(gemData and gemData.variantId or ""),
						skillId = tostring(gemData and gemData.grantedEffectId or grantedEffect.id or ""),
						effectId = tostring(grantedEffect.id or ""),
						level = tonumber(support.level) or 1,
						quality = tonumber(support.quality) or 0,
						origin = origin,
						sourceSlot = sourceSlot,
						sourceItemFingerprint = sourceFingerprint,
						targetGroupIndex = groupIndex,
						targetSkillIndex = skillIndex,
						targetEffectId = tostring(targetEffectId),
						configured = evidence.configured,
						calculatorApplied = evidence.calculatorApplied,
						active = evidence.active,
						socketMatched = evidence.socketMatched,
						socketState = evidence.socketState,
						linkState = evidence.linkState,
						groupState = evidence.groupState,
						playableActive = evidence.playableActive,
						supportProfileVersion = 2,
					}
				end
			end
			table.sort(skillRow.supports, function(left, right)
				if left.effectId ~= right.effectId then return left.effectId < right.effectId end
				if left.origin ~= right.origin then return left.origin < right.origin end
				return tostring(left.sourceSlot or "") < tostring(right.sourceSlot or "")
			end)
			row.skills[#row.skills + 1] = skillRow
		end
		groups[#groups + 1] = row
	end
	return groups
end

local function liveItemSlots(build)
	local result, fingerprintsBySlot = { }, { }
	local itemsTab = build and build.itemsTab
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId])
	for slotName, slot in pairs(itemSet or { }) do
		local itemId = type(slot) == "table" and tonumber(slot.selItemId)
		local item = itemId and itemId > 0 and itemsTab.items and itemsTab.items[itemId]
		if type(slotName) == "string" and item then
			local fingerprint = features.ItemFingerprint(item)
			fingerprintsBySlot[slotName] = fingerprint
			result[#result + 1] = { slot = slotName, base = item.base and item.base.name or item.baseName or item.type,
				rarity = item.rarity, itemFingerprint = fingerprint }
		end
	end
	table.sort(result, function(left, right) return tostring(left.slot) < tostring(right.slot) end)
	return result, fingerprintsBySlot
end

local function hasOtherMutation(candidate)
	return candidate.classVariant or candidate.ascendancyVariant or candidate.jewelVariant
		or (candidate.jewelVariants and #candidate.jewelVariants > 0) or candidate.masteryVariant
		or candidate.tattooVariant or candidate.timelessVariant or candidate.anointVariant
		or (candidate.anointVariants and #candidate.anointVariants > 0) or candidate.gearVariant
		or candidate.gemVariant or candidate.gemVariants or candidate.configurationVariant
end

function features.FromCandidate(build, candidate, baselineOutput, objective)
	if type(build) ~= "table" or type(candidate) ~= "table" or type(build.spec) ~= "table"
		or candidate.isBaselineCandidate or hasOtherMutation(candidate) then return nil end
	local spec = build.spec
	local addedNodeIds = sortedIds(candidate.nodeIds)
	local removedNodeIds = sortedIds(candidate.removeNodeIds)
	if #addedNodeIds + #removedNodeIds ~= 1 then return nil end
	local nodeId = addedNodeIds[1] or removedNodeIds[1]
	local node = spec.nodes and spec.nodes[nodeId]
	if not node or node.isProxy or node.type == "Mastery" or node.type == "Socket" or node.type == "ClassStart"
		or node.type == "AscendClassStart" then return nil end
	local baselineMetrics = { }
	if type(baselineOutput) == "table" then
		baselineMetrics[objective] = baselineOutput[objective]
		baselineMetrics.TotalEHP = baselineOutput.TotalEHP
	end
	local itemSlots, itemFingerprintsBySlot = liveItemSlots(build)
	return buildInput(spec.curClassId, spec.curAscendClassId or 0, mainSkillName(build),
		tonumber(build.characterLevel) or 0, allocatedIds(spec), spec.masterySelections,
		addedNodeIds, removedNodeIds, baselineMetrics, objective,
		liveSkillGroups(build, itemFingerprintsBySlot), itemSlots)
end

local HASH_MODULUS = 2147483647

function features.HashToken(token, dimension)
	local hash = 0
	for index = 1, #token do hash = (hash * 131 + token:byte(index)) % HASH_MODULUS end
	return (hash % dimension) + 1
end

function features.Vector(featureInput, model)
	if type(featureInput) ~= "table" or type(model) ~= "table" or type(model.featureDimension) ~= "number"
		or model.featureDimension < 1 or model.featureDimension > 4096 then return nil end
	local size = model.featureDimension + #numericNames
	local vector = { }
	for index = 1, size do vector[index] = 0 end
	for _, token in ipairs(featureInput.tokens or { }) do
		if type(token) ~= "string" then return nil end
		local index = features.HashToken(token, model.featureDimension)
		vector[index] = vector[index] + 1
	end
	local mean, scale = model.numericMean, model.numericScale
	if type(mean) ~= "table" or type(scale) ~= "table" then return nil end
	for index, value in ipairs(featureInput.numeric or { }) do
		if index > #numericNames or not finite(value) or not finite(mean[index]) or not finite(scale[index]) or scale[index] <= 0 then return nil end
		vector[model.featureDimension + index] = math.max(-8, math.min(8, (value - mean[index]) / scale[index]))
	end
	if #featureInput.numeric ~= #numericNames then return nil end
	return vector
end

features.numericNames = numericNames
features.FEATURE_POLICY = FEATURE_POLICY
features.HASH_MODULUS = HASH_MODULUS

return features
