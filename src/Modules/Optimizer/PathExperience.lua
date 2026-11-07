-- Path of Building
--
-- Module: bounded local memory of exact optimizer evaluations.
-- Only allowlisted IDs, context keys, metrics, and gate outcomes are stored;
-- imported build text, raw item lines, URLs, and user notes are never written.

local json = require("dkjson")
local sha = require("sha2")
local Version = require("Modules.Optimizer.Version")
local ConfigOptions = require("Modules.ConfigOptions")
local experience = { }

local STORE_FOLDER = "OptimizerStudies"
local STORE_FILE = "path-experiences.jsonl"
local SCHEMA_VERSION = 1
local MAX_RECORD_BYTES = 32768
local MAX_STORE_BYTES = 16777216
local MAX_STORE_RECORDS = 30000
local MAX_ROUTE_NODES = 256
local MAX_ROUTE_EDGES = 512
local MAX_VIOLATIONS = 32
local REQUIRED_ENGINE_FIELDS = { "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }

local METRIC_ALLOWLIST = {
	"CombinedDPS", "FullDPS", "FullDotDPS", "TotalDotDPS", "TotalEHP",
	"Life", "EnergyShield", "Ward", "Mana", "ManaUnreserved", "LifeUnreserved",
	"PhysicalMaximumHitTaken", "LightningMaximumHitTaken", "ColdMaximumHitTaken",
	"FireMaximumHitTaken", "ChaosMaximumHitTaken", "SpellSuppressionChance",
	"BlockChance", "SpellBlockChance", "PhysicalDamageReduction", "Armour",
	"Evasion", "LifeRegen", "EnergyShieldRegen", "ManaRegen", "LifeLeechRate",
	"EnergyShieldLeechRate", "ManaLeechRate", "ImpaleDPS", "AttackRate",
	"CastRate", "CritChance", "CritMultiplier", "ActionSpeed",
}

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function safeText(value, maximum)
	if type(value) ~= "string" or value == "" or #value > maximum or value:find("[%c]") then return nil end
	return value
end

local function positiveId(value)
	value = tonumber(value)
	if isFinite(value) and value > 0 and value == math.floor(value) and value <= 2147483647 then return value end
	return nil
end

local function nonNegativeId(value)
	value = tonumber(value)
	if isFinite(value) and value >= 0 and value == math.floor(value) and value <= 2147483647 then return value end
	return nil
end

local function sortedUniqueIds(values, maximum)
	local found, result = { }, { }
	for _, value in ipairs(values or { }) do
		local id = positiveId(value)
		if id and not found[id] then
			found[id] = true
			result[#result + 1] = id
			if #result >= maximum then break end
		end
	end
	table.sort(result)
	return result, found
end

local function canonicalValue(value, stack)
	if type(value) ~= "table" or value == json.null then
		local encoded, encodeError = json.encode(value)
		if type(encoded) ~= "string" then return nil, encodeError or "Could not encode path experience" end
		return encoded
	end
	stack = stack or { }
	if stack[value] then return nil, "Path experience contains a cyclic table" end
	stack[value] = true
	local count, maximum, isArray = 0, 0, true
	for key in pairs(value) do
		count = count + 1
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			isArray = false
		elseif key > maximum then
			maximum = key
		end
	end
	local parts = { }
	if isArray and maximum == count then
		for index = 1, count do
			local encoded, encodeError = canonicalValue(value[index], stack)
			if not encoded then stack[value] = nil return nil, encodeError end
			parts[#parts + 1] = encoded
		end
		stack[value] = nil
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = { }
	for key in pairs(value) do
		if type(key) ~= "string" then stack[value] = nil return nil, "Path experience has a non-string object key" end
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		local encodedKey, keyError = json.encode(key)
		local encodedValue, valueError = canonicalValue(value[key], stack)
		if type(encodedKey) ~= "string" or not encodedValue then
			stack[value] = nil
			return nil, keyError or valueError or "Could not encode path experience"
		end
		parts[#parts + 1] = encodedKey .. ":" .. encodedValue
	end
	stack[value] = nil
	return "{" .. table.concat(parts, ",") .. "}"
end

local function digest(value)
	local encoded, encodeError = canonicalValue(value)
	if not encoded then return nil, encodeError end
	return sha.sha256(encoded)
end

local function joinPath(left, right, separator)
	local base = tostring(left or "")
	while base:sub(-1) == "/" or base:sub(-1) == "\\" do base = base:sub(1, -2) end
	return base .. separator .. right
end

local function completeEngine(engine)
	if type(engine) ~= "table" then return false end
	for _, key in ipairs(REQUIRED_ENGINE_FIELDS) do
		if safeText(tostring(engine[key] or ""), 80) == nil then return false end
	end
	if #engine.manifestFingerprint ~= 64 or not engine.manifestFingerprint:match("^[%da-f]+$") then return false end
	return true
end

local function engineKey(engine)
	local normalized = { }
	for _, key in ipairs(REQUIRED_ENGINE_FIELDS) do normalized[key] = tostring(engine[key]) end
	return normalized
end

local function engineMatches(recordEngine, currentEngine)
	if not completeEngine(recordEngine) or not completeEngine(currentEngine) then return false end
	for _, key in ipairs(REQUIRED_ENGINE_FIELDS) do
		if tostring(recordEngine[key]) ~= tostring(currentEngine[key]) then return false end
	end
	return true
end

local function hasCandidateMutation(candidate, key)
	if key == "tree" then
		return #(candidate.nodeIds or { }) > 0 or #(candidate.removeNodeIds or { }) > 0
	elseif key == "skills" then
		return candidate.gemVariant or #(candidate.gemVariants or { }) > 0
	elseif key == "mastery" then
		return candidate.masteryVariant ~= nil
	elseif key == "tattoo" then
		return candidate.tattooVariant ~= nil
	elseif key == "timeless" then
		return candidate.timelessVariant ~= nil
	elseif key == "anoint" then
		return candidate.anointVariant ~= nil or #(candidate.anointVariants or { }) > 0
	elseif key == "jewel" then
		return candidate.jewelVariant ~= nil or #(candidate.jewelVariants or { }) > 0
	elseif key == "gear" then
		return candidate.gearVariant ~= nil
	elseif key == "ascendancy" then
		return candidate.ascendancyVariant ~= nil
	elseif key == "class" then
		return candidate.classVariant ~= nil
	elseif key == "configuration" then
		return candidate.configurationVariant ~= nil
	end
	return false
end

function experience.CandidateFamily(candidate)
	local families = { }
	for _, key in ipairs({ "ascendancy", "class", "configuration", "gear", "skills", "anoint", "jewel", "mastery", "tattoo", "timeless", "tree" }) do
		if hasCandidateMutation(candidate or { }, key) then families[#families + 1] = key end
	end
	if #families == 0 then return "baseline" end
	return table.concat(families, "+")
end

local function selectedSkill(build, targetSkill)
	local variant = targetSkill and targetSkill.gemVariant
	local skillsTab = build and build.skillsTab
	local groupIndex = targetSkill and targetSkill.groupIndex or build and build.mainSocketGroup
	local group = skillsTab and skillsTab.socketGroupList and skillsTab.socketGroupList[groupIndex]
	local skillIndex = targetSkill and (targetSkill.activeSkillIndex or targetSkill.skillIndex)
		or group and group.mainActiveSkill
	local displaySkill = group and group.displaySkillList and group.displaySkillList[skillIndex]
	local activeEffect = displaySkill and displaySkill.activeEffect
	local sourceGem = activeEffect and activeEffect.srcInstance
	local sourceGemData = sourceGem and sourceGem.gemData
	local gemId = variant and variant.gemId or targetSkill and targetSkill.gemId
		or sourceGemData and (sourceGemData.id or sourceGemData.gameId)
	local packageRows = { }
	for gemIndex, gem in ipairs(group and group.gemList or { }) do
		local data = gem.gemData
		if data and type(data.id) == "string" then
			packageRows[#packageRows + 1] = {
				socket = gemIndex, gemId = data.id,
				level = nonNegativeId(gem.level), quality = nonNegativeId(gem.quality),
				enabled = gem.enabled ~= false,
			}
		end
	end
	local supportPackageDigest = #packageRows > 0 and digest({
		groupIndex = nonNegativeId(groupIndex), skillIndex = nonNegativeId(skillIndex), gems = packageRows,
	}) or nil
	local gemData = gemId and build.data and build.data.gems and build.data.gems[gemId]
	local tags, tagSeen = { }, { }
	if type(gemData) == "table" then
		if type(gemData.tags) == "table" then
			for tag, enabled in pairs(gemData.tags) do
				if enabled and type(tag) == "string" and #tag <= 64 and not tagSeen[tag] then
					tagSeen[tag] = true
					tags[#tags + 1] = tag
				end
			end
		elseif type(gemData.tagString) == "string" then
			for tag in gemData.tagString:gmatch("[%w_%-]+") do
				if not tagSeen[tag] then tagSeen[tag] = true tags[#tags + 1] = tag end
			end
		end
	end
	table.sort(tags)
	return {
		id = safeText(tostring(gemId or "unknown"), 128) or "unknown",
		name = safeText(tostring(gemData and (gemData.name or gemData.baseTypeName) or variant and variant.nameSpec or "Unknown skill"), 128) or "Unknown skill",
		tags = tags,
		supportPackageDigest = supportPackageDigest,
	}
end

local function skillArchetypeTags(tags)
	local recognized = {
		Attack = true, Spell = true, Minion = true, Totem = true, Trap = true,
		Mine = true, Brand = true, Trigger = true, Aura = true, Curse = true,
		Fire = true, Cold = true, Lightning = true, Chaos = true, Physical = true,
		Projectile = true, Melee = true, Duration = true, Channelling = true,
		Warcry = true, Bow = true, Slam = true,
	}
	local result = { }
	for _, tag in ipairs(tags or { }) do if recognized[tag] then result[#result + 1] = tag end end
	return result
end

local function resolvedEnemyPreset(build, parsed, scenarioProfile)
	local requested = tostring(parsed and parsed.scenarioEnemyPreset or "Active")
	if requested ~= "Active" then return requested end
	if scenarioProfile ~= "Current" then return "Pinnacle" end
	local configTab = build and build.configTab
	local configSet = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	local value = configSet and configSet.input and configSet.input.enemyIsBoss
	if type(value) == "string" and value ~= "" then return value end
	local control = configTab and configTab.varControls and configTab.varControls.enemyIsBoss
	local selected = control and control.list and control.list[control.selIndex]
	if selected and type(selected.val) == "string" then return selected.val end
	for _, option in ipairs(ConfigOptions) do
		if option.var == "enemyIsBoss" then
			local default = option.list and option.list[option.defaultIndex or 1]
			if default and type(default.val) == "string" then return default.val end
		end
	end
	return "None"
end

function experience.MakeBaseContext(build, parsed, targetSkill, sourceSignature)
	local engine = Version.Snapshot(build)
	if not completeEngine(engine) then return nil, "engine_identity_incomplete" end
	local classId = nonNegativeId(build and build.spec and build.spec.curClassId)
	local ascendancyId = nonNegativeId(build and build.spec and build.spec.curAscendClassId)
	local skill = selectedSkill(build, targetSkill)
	local scenario = safeText(tostring(parsed and parsed.scenarioProfile or "Current"), 80) or "Current"
	local enemyPreset = safeText(resolvedEnemyPreset(build, parsed, scenario), 32) or "None"
	local objective = safeText(tostring(parsed and parsed.objective or ""), 96)
	if not classId or not objective then return nil, "optimizer_context_incomplete" end
	local constraintDigest = digest({
		scenarioProfile = scenario,
		scenarioEnemyPreset = enemyPreset,
		hard = parsed and parsed.hard or { },
		conversion = parsed and parsed.conversion or { },
		branch = parsed and parsed.branch or { },
		preferences = parsed and parsed.preferences or { },
		targetSkillSocketContext = targetSkill and targetSkill.unlinkedPlanning == true
			and "unlinked_planning" or "socketed_or_native",
		targetNodeIds = parsed and parsed.targetNodeIds or { },
		search = {
			generationPhase = parsed and parsed.search and parsed.search.generationPhase,
			baseClassId = parsed and parsed.search and parsed.search.baseClassId,
			ascendancyId = parsed and parsed.search and parsed.search.ascendancyId,
			searchAllClasses = parsed and parsed.search and parsed.search.searchAllClasses,
			targetSkillGroupIndex = parsed and parsed.search and parsed.search.targetSkillGroupIndex,
			targetSkillIndex = parsed and parsed.search and parsed.search.targetSkillIndex,
			targetSkillGemId = parsed and parsed.search and parsed.search.targetSkillGemId,
			addNodeIds = parsed and parsed.search and parsed.search.addNodeIds,
			removeNodeIds = parsed and parsed.search and parsed.search.removeNodeIds,
			requiredNodeIds = parsed and parsed.search and parsed.search.requiredNodeIds,
			forbiddenNodeIds = parsed and parsed.search and parsed.search.forbiddenNodeIds,
			maxTotalPoints = parsed and parsed.search and parsed.search.maxTotalPoints,
			maxAddedPoints = parsed and parsed.search and parsed.search.maxAddedPoints,
			maxManualButtons = parsed and parsed.search and parsed.search.maxManualButtons,
			maxManualDamageButtons = parsed and parsed.search and parsed.search.maxManualDamageButtons,
			searchStoredItems = parsed and parsed.search and parsed.search.searchStoredItems,
			searchSyntheticGear = parsed and parsed.search and parsed.search.searchSyntheticGear,
			currencyBudget = parsed and parsed.search and parsed.search.currencyBudget,
		},
	})
	if not constraintDigest then return nil, "optimizer_constraints_not_fingerprintable" end
	if targetSkill and targetSkill.groupIndex and skill.id == "unknown" then return nil, "selected_skill_identity_unavailable" end
	local sourceHash = type(sourceSignature) == "string" and sha.sha256(sourceSignature) or "unknown-source"
	local base = {
		engine = engineKey(engine),
		classId = classId,
		ascendancyId = ascendancyId or 0,
		level = nonNegativeId(build.characterLevel) or 1,
		skill = skill,
		scenarioProfile = scenario,
		scenarioEnemyPreset = enemyPreset,
		objectiveMetric = objective,
		constraintDigest = constraintDigest,
		sourceBuildHash = sourceHash,
	}
	base.skillScopeKey = digest({
		engine = base.engine, classId = classId, ascendancyId = base.ascendancyId,
		skillId = skill.id, scenario = scenario, scenarioEnemyPreset = enemyPreset, objective = objective,
		characterLevel = base.level, constraintDigest = constraintDigest,
		supportPackageDigest = skill.supportPackageDigest,
	})
	base.archetypeScopeKey = digest({
		engine = base.engine, classId = classId, ascendancyId = base.ascendancyId,
		tags = skillArchetypeTags(skill.tags), scenario = scenario, scenarioEnemyPreset = enemyPreset, objective = objective,
		characterLevel = base.level, constraintDigest = constraintDigest,
	})
	base.exactScopeKey = digest({
		engine = base.engine, sourceBuildHash = sourceHash, constraintDigest = constraintDigest,
		skillId = skill.id, scenario = scenario, scenarioEnemyPreset = enemyPreset, objective = objective,
	})
	return base
end

function experience.CandidateContext(baseContext, candidate)
	if type(baseContext) ~= "table" then return nil end
	candidate = candidate or { }
	local family = experience.CandidateFamily(candidate or { })
	local classId = nonNegativeId(candidate.classVariant and candidate.classVariant.classId) or baseContext.classId
	local ascendancyId = nonNegativeId(candidate.ascendancyVariant and candidate.ascendancyVariant.ascendClassId)
		or nonNegativeId(candidate.classVariant and candidate.classVariant.ascendClassId) or baseContext.ascendancyId
	return {
		family = family,
		classId = classId,
		ascendancyId = ascendancyId,
		scenarioEnemyPreset = baseContext.scenarioEnemyPreset,
		skillScopeKey = digest({ scope = baseContext.skillScopeKey, family = family, classId = classId, ascendancyId = ascendancyId }),
		archetypeScopeKey = digest({ scope = baseContext.archetypeScopeKey, family = family, classId = classId, ascendancyId = ascendancyId }),
		exactScopeKey = digest({
			scope = baseContext.exactScopeKey, family = family,
			classId = classId, ascendancyId = ascendancyId,
		}),
	}
end

local function routeForCandidate(candidate, spec)
	local added, addedSet = sortedUniqueIds(candidate and candidate.nodeIds or { }, MAX_ROUTE_NODES)
	local removed = sortedUniqueIds(candidate and candidate.removeNodeIds or { }, MAX_ROUTE_NODES)
	local active = { }
	for id in pairs(addedSet) do active[id] = true end
	for id in pairs(spec and spec.allocNodes or { }) do active[id] = true end
	local edges, edgeSeen = { }, { }
	for _, nodeId in ipairs(added) do
		local node = spec and spec.nodes and spec.nodes[nodeId]
		for _, linkedId in ipairs(node and node.linkedId or { }) do
			if active[linkedId] then
				local first, second = math.min(nodeId, linkedId), math.max(nodeId, linkedId)
				local key = tostring(first) .. ":" .. tostring(second)
				if not edgeSeen[key] then
					edgeSeen[key] = true
					edges[#edges + 1] = { first, second }
					if #edges >= MAX_ROUTE_EDGES then break end
				end
			end
		end
		if #edges >= MAX_ROUTE_EDGES then break end
	end
	table.sort(edges, function(left, right)
		if left[1] ~= right[1] then return left[1] < right[1] end
		return left[2] < right[2]
	end)
	return { addedNodeIds = added, removedNodeIds = removed, edges = edges }
end

experience.RouteForCandidate = routeForCandidate

local function itemIdentity(build, itemId, fallback)
	local numericId = positiveId(itemId)
	local item = numericId and build and build.itemsTab and build.itemsTab.items and build.itemsTab.items[numericId]
	if item and type(item.BuildRaw) == "function" then
		local callOk, raw = pcall(item.BuildRaw, item)
		if callOk and type(raw) == "string" and raw ~= "" then return sha.sha256(raw) end
	end
	local safeFallback = {
		itemId = numericId,
		kind = safeText(tostring(fallback and fallback.kind or "item"), 32) or "item",
		name = safeText(tostring(fallback and fallback.name or ""), 120),
		rarity = safeText(tostring(fallback and fallback.rarity or ""), 32),
		catalystId = positiveId(fallback and fallback.catalystId),
		catalystQuality = nonNegativeId(fallback and fallback.catalystQuality),
	}
	return digest(safeFallback)
end

local function candidateMutations(candidate, build)
	local result = { }
	for _, variant in ipairs(candidate and candidate.gemVariants or { }) do
		result[#result + 1] = {
			kind = safeText(tostring(variant.kind or "gem"), 48) or "gem",
			gemId = safeText(tostring(variant.gemId or "unknown"), 128) or "unknown",
			skillId = safeText(tostring(variant.skillId or ""), 128),
			fromGemId = safeText(tostring(variant.fromGemId or ""), 128),
			groupIndex = positiveId(variant.groupIndex), gemIndex = positiveId(variant.gemIndex),
			level = nonNegativeId(variant.level), quality = nonNegativeId(variant.quality),
		}
	end
	if candidate and candidate.gemVariant then
		local variant = candidate.gemVariant
		result[#result + 1] = {
			kind = safeText(tostring(variant.kind or "gem"), 48) or "gem",
			gemId = safeText(tostring(variant.gemId or "unknown"), 128) or "unknown",
			skillId = safeText(tostring(variant.skillId or ""), 128),
			fromGemId = safeText(tostring(variant.fromGemId or ""), 128),
			groupIndex = positiveId(variant.groupIndex), gemIndex = positiveId(variant.gemIndex),
			level = nonNegativeId(variant.level), quality = nonNegativeId(variant.quality),
		}
	end
	if candidate and candidate.gearVariant then
		local items = { }
		local changedSlots = { }
		for _, slotName in ipairs(candidate.gearVariant.changedSlots or { }) do
			local slot = safeText(tostring(slotName), 80)
			if slot then changedSlots[slot] = true end
		end
	local hasChangedSlotList = next(changedSlots) ~= nil
		for _, item in ipairs(candidate.gearVariant.items or { }) do
			local slot = safeText(tostring(item.slot or item.slotName or ""), 80)
			if slot and (not hasChangedSlotList or changedSlots[slot]) then
				items[#items + 1] = {
					slot = slot,
					itemDigest = itemIdentity(build, item.itemId, item),
					catalystId = positiveId(item.catalystId),
					catalystQuality = nonNegativeId(item.catalystQuality),
				}
			end
		end
		table.sort(items, function(left, right)
			if left.slot ~= right.slot then return left.slot < right.slot end
			return tostring(left.itemDigest or "") < tostring(right.itemDigest or "")
		end)
		result[#result + 1] = { kind = "gear", items = items }
	end
	if candidate and candidate.classVariant then
		result[#result + 1] = {
			kind = "class", classId = nonNegativeId(candidate.classVariant.classId),
			ascendancyId = nonNegativeId(candidate.classVariant.ascendClassId),
		}
	end
	if candidate and candidate.ascendancyVariant then
		result[#result + 1] = {
			kind = "ascendancy",
			mainId = nonNegativeId(candidate.ascendancyVariant.ascendClassId),
			secondaryId = nonNegativeId(candidate.ascendancyVariant.secondaryAscendClassId),
		}
	end
	if candidate and candidate.masteryVariant then
		result[#result + 1] = {
			kind = "mastery", nodeId = positiveId(candidate.masteryVariant.nodeId),
			effectId = positiveId(candidate.masteryVariant.effectId),
		}
	end
	if candidate and candidate.tattooVariant then
		result[#result + 1] = {
			kind = "tattoo", nodeId = positiveId(candidate.tattooVariant.nodeId),
			tattooId = positiveId(candidate.tattooVariant.tattooId),
		}
	end
	if candidate and candidate.timelessVariant then
		result[#result + 1] = {
			kind = "timeless_jewel", nodeId = positiveId(candidate.timelessVariant.nodeId),
			itemDigest = itemIdentity(build, candidate.timelessVariant.itemId, { kind = "timeless_jewel" }),
			seed = nonNegativeId(candidate.timelessVariant.seed),
		}
	end
	local requestedAnoints = candidate and (candidate.anointVariants or candidate.anointVariant)
	if requestedAnoints then
		local variants = type(requestedAnoints) == "table" and requestedAnoints.nodeId and { requestedAnoints } or requestedAnoints
		for _, variant in ipairs(variants or { }) do
			result[#result + 1] = {
				kind = "anoint", nodeId = positiveId(variant.nodeId),
				itemDigest = itemIdentity(build, variant.itemId, { kind = "anoint" }),
				enchantSlot = positiveId(variant.enchantSlot),
			}
		end
	end
	local requestedJewels = candidate and (candidate.jewelVariants or candidate.jewelVariant)
	if requestedJewels then
		local variants = type(requestedJewels) == "table" and requestedJewels.itemId and { requestedJewels } or requestedJewels
		for _, variant in ipairs(variants or { }) do
			result[#result + 1] = {
				kind = safeText(tostring(variant.sourceKind or "jewel"), 32) or "jewel",
				toNodeId = positiveId(variant.toNodeId),
				itemDigest = itemIdentity(build, variant.itemId, { kind = variant.sourceKind or "jewel" }),
				targetItemDigest = itemIdentity(build, variant.targetItemId, { kind = variant.sourceKind or "jewel_target" }),
			}
		end
	end
	if candidate and candidate.configurationVariant then
		local variant = candidate.configurationVariant
		result[#result + 1] = {
			kind = "configuration",
			bandit = safeText(tostring(variant.bandit or ""), 64),
			pantheonMajorGod = safeText(tostring(variant.pantheonMajorGod or ""), 64),
			pantheonMinorGod = safeText(tostring(variant.pantheonMinorGod or ""), 64),
		}
	end
	return result
end

function experience.CandidateMutationSignature(candidate, build)
	local mutations = candidateMutations(candidate, build)
	if #mutations == 0 then return nil, mutations end
	local signature, signatureError = digest(mutations)
	if not signature then return nil, nil, signatureError end
	return signature, mutations
end

local function captureMetrics(metrics, objective)
	local allowed = { }
	for _, key in ipairs(METRIC_ALLOWLIST) do allowed[key] = true end
	if type(objective) == "string" and objective:match("^[%w_%.%-]+$") then allowed[objective] = true end
	local result = { }
	for key, value in pairs(metrics or { }) do
		if allowed[key] and isFinite(value) then result[key] = value end
	end
	return result
end

local function captureViolations(violations)
	local result = { }
	for _, violation in ipairs(violations or { }) do
		local key = safeText(tostring(violation.key or "unknown"), 96)
		if key then
			result[#result + 1] = {
				key = key,
				deficit = isFinite(violation.deficit) and math.min(math.max(violation.deficit, 0), 1000000) or nil,
			}
			if #result >= MAX_VIOLATIONS then break end
		end
	end
	table.sort(result, function(left, right) return left.key < right.key end)
	return result
end

function experience.CreateRecord(build, spec, candidate, evaluation, parsed, targetSkill, sourceSignature, baseContext)
	if type(evaluation) ~= "table" or type(evaluation.metrics) ~= "table" then return nil, "exact_metrics_missing" end
	local context = baseContext
	local contextError
	if type(context) ~= "table" then context, contextError = experience.MakeBaseContext(build, parsed, targetSkill, sourceSignature) end
	if not context then return nil, contextError end
	local candidateContext = experience.CandidateContext(context, candidate)
	local route = routeForCandidate(candidate, spec)
	local mutationSignature, mutations, mutationError = experience.CandidateMutationSignature(candidate, build)
	if mutationError then return nil, mutationError end
	local routeSignature, signatureError = digest({
		engine = context.engine, classId = candidateContext.classId,
		ascendancyId = candidateContext.ascendancyId, skillId = context.skill.id,
		scenario = context.scenarioProfile, scenarioEnemyPreset = context.scenarioEnemyPreset,
		objective = context.objectiveMetric,
		family = candidateContext.family, nodes = route.addedNodeIds,
		removed = route.removedNodeIds, edges = route.edges,
		mutationSignature = mutationSignature,
	})
	if not routeSignature then return nil, signatureError end
	local deficit = evaluation.normalizedDeficit
	if not isFinite(deficit) then deficit = 1000000 end
	local record = {
		schemaVersion = SCHEMA_VERSION,
		recordType = "optimizer_path_experience",
		engine = context.engine,
		observedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
		sourceBuildHash = context.sourceBuildHash,
		context = {
			observationSource = context.observationSource == "imported_study" and "imported_study" or "active_build",
			classId = candidateContext.classId,
			ascendancyId = candidateContext.ascendancyId,
			characterLevel = context.level,
			skillId = context.skill.id,
			skillName = context.skill.name,
			skillTags = context.skill.tags,
			scenarioProfile = context.scenarioProfile,
			scenarioEnemyPreset = context.scenarioEnemyPreset,
			objectiveMetric = context.objectiveMetric,
			candidateFamily = candidateContext.family,
			constraintDigest = context.constraintDigest,
			skillScopeKey = candidateContext.skillScopeKey,
			archetypeScopeKey = candidateContext.archetypeScopeKey,
			exactScopeKey = candidateContext.exactScopeKey,
		},
		candidate = {
			isBaseline = candidate and candidate.isBaselineCandidate == true,
			routeSignature = routeSignature,
			mutationSignature = mutationSignature,
			mutations = mutations,
			passivePointsUsed = nonNegativeId(evaluation.passivePointsUsed),
		},
		path = route,
		outcome = {
			exactCalculated = true,
			feasible = evaluation.feasible == true,
			normalizedDeficit = deficit,
			objectiveValue = captureMetrics(evaluation.metrics, context.objectiveMetric)[context.objectiveMetric],
			metrics = captureMetrics(evaluation.metrics, context.objectiveMetric),
			violations = captureViolations(evaluation.violations),
		},
	}
	local fingerprintPayload = { }
	for key, value in pairs(record) do if key ~= "observedAt" then fingerprintPayload[key] = value end end
	local fingerprint, fingerprintError = digest(fingerprintPayload)
	if not fingerprint then return nil, fingerprintError end
	record.fingerprint = fingerprint
	return record
end

local function validStoredRecord(record)
	if not (type(record) == "table" and record.schemaVersion == SCHEMA_VERSION
		and record.recordType == "optimizer_path_experience"
		and completeEngine(record.engine)
		and type(record.sourceBuildHash) == "string" and #record.sourceBuildHash == 64
		and type(record.context) == "table"
		and type(record.context.skillScopeKey) == "string" and #record.context.skillScopeKey == 64
		and type(record.context.archetypeScopeKey) == "string" and #record.context.archetypeScopeKey == 64
		and type(record.context.exactScopeKey) == "string" and #record.context.exactScopeKey == 64
		and type(record.candidate) == "table" and type(record.candidate.routeSignature) == "string"
		and record.candidate.routeSignature:match("^[%da-f]+$") ~= nil and #record.candidate.routeSignature == 64
		and type(record.candidate.mutations) == "table"
		and type(record.path) == "table" and type(record.path.addedNodeIds) == "table"
		and #record.path.addedNodeIds <= MAX_ROUTE_NODES
		and type(record.path.removedNodeIds) == "table" and #record.path.removedNodeIds <= MAX_ROUTE_NODES
		and type(record.path.edges) == "table" and #record.path.edges <= MAX_ROUTE_EDGES
		and type(record.outcome) == "table" and record.outcome.exactCalculated == true
		and type(record.outcome.feasible) == "boolean"
		and type(record.outcome.metrics) == "table"
		and type(record.fingerprint) == "string" and record.fingerprint:match("^[%da-f]+$") ~= nil
		and #record.fingerprint == 64) then
		return false
	end
	if record.candidate.mutationSignature ~= nil then
		if type(record.candidate.mutationSignature) ~= "string"
			or #record.candidate.mutationSignature ~= 64
			or record.candidate.mutationSignature:match("^[%da-f]+$") == nil
			or digest(record.candidate.mutations) ~= record.candidate.mutationSignature then
			return false
		end
	end
	if record.context.observationSource ~= nil
		and record.context.observationSource ~= "active_build"
		and record.context.observationSource ~= "imported_study" then
		return false
	end
	local fingerprintPayload = { }
	for key, value in pairs(record) do
		if key ~= "fingerprint" and key ~= "observedAt" then fingerprintPayload[key] = value end
	end
	local expectedFingerprint = digest(fingerprintPayload)
	return expectedFingerprint ~= nil and expectedFingerprint == record.fingerprint
end

function experience.GetStorePath(userPath)
	if type(userPath) ~= "string" or userPath == "" then return nil, "user_path_unavailable" end
	local separator = package.config and package.config:sub(1, 1) or "\\"
	local directory = joinPath(userPath, STORE_FOLDER, separator)
	return joinPath(directory, STORE_FILE, separator), directory
end

local function missingFileError(message)
	message = tostring(message or ""):lower()
	return message:find("no such file", 1, true) ~= nil or message:find("cannot find", 1, true) ~= nil
		or message:find("system cannot find", 1, true) ~= nil
end

function experience.Open(userPath, currentEngine, progressFunc)
	local path, directoryOrError = experience.GetStorePath(userPath)
	local state = {
		path = path,
		directory = path and directoryOrError or nil,
		status = path and "empty" or "user_path_unavailable",
		records = { }, seen = { }, totalRecords = 0,
		compatibleRecords = 0, incompatibleRecords = 0,
		currentEngine = currentEngine,
	}
	if not path then return state end
	if not completeEngine(currentEngine) then state.status = "engine_identity_incomplete" return state end
	local file, openError = io.open(path, "rb")
	if not file then
		if missingFileError(openError) then return state end
		state.status = "read_error"
		state.error = tostring(openError or "Could not read path experience store"):sub(1, 240)
		return state
	end
	local size = file:seek("end") or 0
	if size > MAX_STORE_BYTES then
		file:close()
		state.status = "store_limit_exceeded"
		return state
	end
	file:seek("set", 0)
	local lineNumber = 0
	for line in file:lines() do
		lineNumber = lineNumber + 1
		if #line > MAX_RECORD_BYTES then
			file:close()
			state.status = "corrupt"
			state.error = "record_too_large:" .. tostring(lineNumber)
			state.records, state.seen = { }, { }
			return state
		end
		if line ~= "" then
			local ok, record = pcall(json.decode, line)
			if not ok or not validStoredRecord(record) then
				file:close()
				state.status = "corrupt"
				state.error = "invalid_record:" .. tostring(lineNumber)
				state.records, state.seen = { }, { }
				return state
			end
			state.totalRecords = state.totalRecords + 1
			state.seen[record.fingerprint] = true
			if engineMatches(record.engine, currentEngine) then
				state.compatibleRecords = state.compatibleRecords + 1
				if #state.records < MAX_STORE_RECORDS then state.records[#state.records + 1] = record end
			else
				state.incompatibleRecords = state.incompatibleRecords + 1
			end
			if state.totalRecords > MAX_STORE_RECORDS then
				file:close()
				state.status = "store_limit_exceeded"
				state.records, state.seen = { }, { }
				return state
			end
			if lineNumber % 256 == 0 and type(progressFunc) == "function" then
				local proceed = progressFunc(lineNumber, file:seek() or size, size)
				if proceed == false then
					file:close()
					state.status = "cancelled"
					state.records, state.seen = { }, { }
					return state
				end
			end
		end
	end
	file:close()
	state.status = state.totalRecords > 0 and "ready" or "empty"
	return state
end

function experience.AppendBatch(state, pendingRecords, createDirectory)
	if type(state) ~= "table" or not state.path then return { stored = 0, duplicates = 0, status = state and state.status or "unavailable" } end
	if state.status == "corrupt" or state.status == "store_limit_exceeded" or state.status == "read_error"
		or state.status == "engine_identity_incomplete" then
		return { stored = 0, duplicates = 0, status = state.status, error = state.error }
	end
	if type(pendingRecords) ~= "table" or #pendingRecords == 0 then return { stored = 0, duplicates = 0, status = state.status } end
	if type(createDirectory) ~= "function" then return { stored = 0, duplicates = 0, status = "directory_creator_unavailable" } end
	local separator = package.config and package.config:sub(1, 1) or "\\"
	local callOk, created, createError = pcall(createDirectory, state.directory .. separator)
	if not callOk then return { stored = 0, duplicates = 0, status = "directory_error", error = tostring(created):sub(1, 240) } end
	if not created and createError ~= "No error" then
		return { stored = 0, duplicates = 0, status = "directory_error", error = tostring(createError or "unknown"):sub(1, 240) }
	end
	local file, openError = io.open(state.path, "ab")
	if not file then return { stored = 0, duplicates = 0, status = "write_error", error = tostring(openError or "open failed"):sub(1, 240) } end
	local size = file:seek("end") or 0
	local buffer, newRows, duplicates = { }, { }, 0
	for _, record in ipairs(pendingRecords) do
		if validStoredRecord(record) and engineMatches(record.engine, state.currentEngine) then
			if state.seen[record.fingerprint] then
				duplicates = duplicates + 1
			else
				local encoded, encodeError = json.encode(record)
				if type(encoded) ~= "string" or #encoded > MAX_RECORD_BYTES then
					for _, addedRecord in ipairs(newRows) do state.seen[addedRecord.fingerprint] = nil end
					file:close()
					return { stored = 0, duplicates = duplicates, status = "record_invalid", error = tostring(encodeError or "record_too_large") }
				end
				buffer[#buffer + 1] = encoded .. "\n"
				newRows[#newRows + 1] = record
				state.seen[record.fingerprint] = true
			end
		end
	end
	local payload = table.concat(buffer)
	if state.totalRecords + #newRows > MAX_STORE_RECORDS or size + #payload > MAX_STORE_BYTES then
		for _, record in ipairs(newRows) do state.seen[record.fingerprint] = nil end
		file:close()
		state.status = "store_limit_exceeded"
		return { stored = 0, duplicates = duplicates, status = state.status }
	end
	if payload ~= "" then
		local written, writeError = file:write(payload)
		if written then written, writeError = file:flush() end
		if not written then
			for _, record in ipairs(newRows) do state.seen[record.fingerprint] = nil end
			file:close()
			return { stored = 0, duplicates = duplicates, status = "write_error", error = tostring(writeError or "write failed"):sub(1, 240) }
		end
	end
	file:close()
	for _, record in ipairs(newRows) do
		state.records[#state.records + 1] = record
		state.compatibleRecords = state.compatibleRecords + 1
	end
	state.totalRecords = state.totalRecords + #newRows
	state.status = state.totalRecords > 0 and "ready" or "empty"
	return { stored = #newRows, duplicates = duplicates, status = state.status }
end

experience.MAX_RECORD_BYTES = MAX_RECORD_BYTES
experience.MAX_STORE_BYTES = MAX_STORE_BYTES
experience.MAX_STORE_RECORDS = MAX_STORE_RECORDS
experience.CanonicalValue = canonicalValue
experience.Digest = digest

return experience
