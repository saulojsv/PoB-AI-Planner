-- Path of Building
--
-- Module: bounded, native-data synthetic rare equipment proposals.
-- Every proposal is assembled from the active PoB item-base/mod registries,
-- checked with Item:GetModSpawnWeight and recalculated by PoB before it can win.
-- The tier ceiling is conservatively derived from the three highest eligible
-- native mod-level bands in each type/group; PoB data does not expose a uniform
-- tier name for every mod family.

local t_sort = table.sort

local syntheticGear = { }
local validator = require("Modules.Optimizer.Validator")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local MAX_SYNTHETIC_CANDIDATES = 256
local MAX_BASES_PER_SLOT = 8
local MAX_AFFIX_TIERS_PER_GROUP = 3
local MAX_AFFIX_COMBINATIONS_PER_BASE = 16
local AFFIX_ROLL_PROFILES = {
	{ id = "maximum", fraction = 1, label = "rolls máximos" },
	{ id = "median", fraction = 0.5, label = "rolls médios" },
}

local slotBaseTypes = {
	["Helmet"] = { Helmet = true },
	["Body Armour"] = { ["Body Armour"] = true },
	["Gloves"] = { Gloves = true },
	["Boots"] = { Boots = true },
	["Amulet"] = { Amulet = true },
	["Belt"] = { Belt = true },
	["Ring 1"] = { Ring = true },
	["Ring 2"] = { Ring = true },
	["Ring 3"] = { Ring = true },
}

local function shallowCopy(source)
	local result = { }
	for key, value in pairs(source or { }) do result[key] = value end
	return result
end

local function countRealAffixes(affixes)
	local count = 0
	for _, affix in ipairs(affixes or { }) do
		if type(affix) == "table" and affix.modId and affix.modId ~= "None" then count = count + 1 end
	end
	return count
end

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function normalizeTag(value)
	local normalized = tostring(value or ""):lower():gsub("_", "")
	return normalized
end

local function baseFitsSlot(base, slotName)
	if not base or base.hidden then return false end
	local expected = slotBaseTypes[slotName]
	if expected then return expected[base.type] == true end
	if slotName:match("^Weapon [12]") or slotName:match("^Weapon [12] Swap$") then
		return base.weapon ~= nil or base.type == "Shield" or base.type == "Quiver"
	end
	return false
end

local function getActiveSet(itemsTab)
	return itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId])
end

local function makeProbe(baseName, itemLevel)
	local raw = table.concat({
		"Rarity: Rare",
		"Optimizer Synthetic",
		baseName,
		"--------",
		"Item Level: " .. tostring(itemLevel),
	}, "\n")
	local item = new("Item"):Item(raw)
	if not item or not item.base or item.baseName ~= baseName then return nil end
	return item
end

-- Some native bases grant sockets through an implicit mod instead of a
-- `base.socketLimit` field (for example, Unset Ring). Ask PoB's parsed item
-- about the effective selectable/socket count so legal native bases are not
-- discarded by a missing static field.
local function nativeSocketCapacity(item)
	if type(item) ~= "table" then return 0 end
	local baseLimit = tonumber(item.base and item.base.socketLimit) or 0
	local selectableCount = tonumber(item.selectableSocketCount) or 0
	local parsedCount = type(item.sockets) == "table" and #item.sockets or 0
	return math.max(baseLimit, selectableCount, parsedCount)
end

local function itemLevelFor(build, currentItem, requestedLevel)
	local level = tonumber(requestedLevel) or tonumber(currentItem and currentItem.itemLevel)
		or tonumber(build and build.characterLevel) or 100
	if not isFinite(level) then level = tonumber(build and build.characterLevel) or 100 end
	return math.max(1, math.min(100, math.floor(level)))
end

local function baseRequirementsFit(build, base)
	local requirements = base and base.req or { }
	local output = build and build.calcsTab and build.calcsTab.mainOutput or { }
	local outputKeys = { str = "Str", dex = "Dex", int = "Int" }
	for _, attribute in ipairs({ "str", "dex", "int" }) do
		local required = tonumber(requirements[attribute]) or 0
		local available = tonumber(output[outputKeys[attribute]])
		if required > 0 and (not isFinite(available) or available < required) then return false end
	end
	return true
end

local function nativeBaseDefenseValues(base)
	local armour = base and base.armour or { }
	return {
		Armour = tonumber(armour.ArmourBaseMin) or 0,
		Evasion = tonumber(armour.EvasionBaseMin) or 0,
		EnergyShield = tonumber(armour.EnergyShieldBaseMin) or 0,
		Ward = tonumber(armour.WardBaseMin) or 0,
		Block = tonumber(armour.BlockChance) or 0,
	}
end

local function basePreferenceScores(base, defenseProfile)
	local values = nativeBaseDefenseValues(base)
	local allDefenses = values.Armour + values.Evasion + values.EnergyShield + values.Ward
	local preferred
	if defenseProfile == "Armour" then preferred = values.Armour
	elseif defenseProfile == "Evasion" or defenseProfile == "SpellSuppression" then preferred = values.Evasion
	elseif defenseProfile == "EnergyShield" then preferred = values.EnergyShield
	elseif defenseProfile == "Ward" then preferred = values.Ward
	elseif defenseProfile == "Block" or defenseProfile == "SpellBlock" then preferred = values.Block
	elseif defenseProfile == "Hybrid" then preferred = allDefenses
	else preferred = 0 end
	return preferred, allDefenses
end

local function targetSocketColor(build, gem)
	local gemData = gem and (gem.gemData or (gem.gemId and build.data and build.data.gems and build.data.gems[gem.gemId]))
	local effect = gem and gem.grantedEffect
	if not (effect and effect.support) then
		local primary = gemData and gemData.grantedEffect
		local secondary = gemData and gemData.secondaryGrantedEffect
		effect = (primary and primary.support and primary)
			or (secondary and secondary.support and secondary)
			or effect or primary
	end
	local color = effect and effect.color
	return ({ [1] = "R", [2] = "G", [3] = "B", [4] = "W", R = "R", G = "G", B = "B", W = "W" })[color] or "W"
end

local function buildSocketPlan(build, targetSkill, slotName)
	local groupIndex = targetSkill and tonumber(targetSkill.groupIndex)
	local group = groupIndex and build and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	local repair = targetSkill and targetSkill.socketRepair
	for _, repairPlan in ipairs(targetSkill and targetSkill.socketRepairs or { }) do
		if repairPlan and repairPlan.slot == slotName then repair = repairPlan; break end
	end
	if repair and repair.slot == slotName then
		local colors, linkGroups = { }, { }
		for index, color in ipairs(repair.colors or { }) do colors[index] = color end
		for index, linkGroup in ipairs(repair.linkGroups or { }) do linkGroups[index] = linkGroup end
		if #colors == repair.socketCount and #linkGroups == #colors and #colors > 0 then
			return {
				groupIndex = tonumber(repair.groupIndex) or groupIndex,
				colors = colors,
				linkGroups = linkGroups,
				requiredSockets = #colors,
				linkGroup = linkGroups[1] or 0,
				repair = true,
			}
		end
		return nil
	end
	if not group or group.slot or group.source or #(group.gemList or { }) == 0 then return nil end
	for index, otherGroup in ipairs(build.skillsTab.socketGroupList) do
		if index ~= groupIndex and otherGroup.slot == slotName then
			return nil
		end
	end
	local colors = { }
	local replacement = targetSkill and targetSkill.gemVariant
	local replacementIndex = replacement and tonumber(replacement.gemIndex)
	local replacementGem = replacement and replacement.gemId and build.data and build.data.gems
		and build.data.gems[replacement.gemId]
	for index, gem in ipairs(group.gemList) do
		if index == replacementIndex and replacementGem then
			colors[#colors + 1] = targetSocketColor(build, { gemData = replacementGem })
		else
			colors[#colors + 1] = targetSocketColor(build, gem)
		end
	end
	return {
		groupIndex = groupIndex,
		slotName = slotName,
		colors = colors,
		requiredSockets = #colors,
		linkGroup = 0,
	}
end

local function eligibleBases(build, itemsTab, itemSet, slotName, seed, itemLevel, requiredSocketCount, parsed)
	local selectedId = itemSet and itemSet[slotName] and tonumber(itemSet[slotName].selItemId) or 0
	local current = selectedId and selectedId > 0 and itemsTab.items[selectedId] or nil
	local currentChoice
	if current and current.base and baseFitsSlot(current.base, slotName)
		and baseRequirementsFit(build, current.base) then
		local item = makeProbe(current.baseName, itemLevel)
		if item and nativeSocketCapacity(item) >= (requiredSocketCount or 0)
			and itemsTab.IsItemValidForSlot(itemsTab, item, slotName, itemSet) then
			currentChoice = { name = current.baseName, base = item.base, currentItemId = selectedId }
		end
	end

	local registry = build and build.data and build.data.itemBases or data and data.itemBases or { }
	local choices = { }
	local seenBases = { }
	local defenseProfile = parsed and parsed.preferences and parsed.preferences.defenseProfile or "Auto"
	local function addBase(name, base, currentItemId)
		if seenBases[name] or not baseFitsSlot(base, slotName) or not baseRequirementsFit(build, base) then return end
		local baseLevel = tonumber(base.req and base.req.level) or 0
		if baseLevel > (tonumber(build and build.characterLevel) or 100) then return end
		local item = makeProbe(name, itemLevel)
		if not item or nativeSocketCapacity(item) < (requiredSocketCount or 0)
			or not itemsTab.IsItemValidForSlot(itemsTab, item, slotName, itemSet) then return end
		seenBases[name] = true
		local preferredDefense, totalDefense = basePreferenceScores(base, defenseProfile)
		choices[#choices + 1] = {
			name = name,
			base = item.base,
			currentItemId = currentItemId,
			preferredDefense = preferredDefense,
			baseLevel = baseLevel,
			totalDefense = totalDefense,
		}
	end
	for name, base in pairs(registry) do
		if not (currentChoice and name == currentChoice.name) then addBase(name, base, nil) end
	end
	t_sort(choices, function(a, b)
		if a.preferredDefense ~= b.preferredDefense then return a.preferredDefense > b.preferredDefense end
		if a.baseLevel ~= b.baseLevel then return a.baseLevel > b.baseLevel end
		if a.totalDefense ~= b.totalDefense then return a.totalDefense > b.totalDefense end
		return a.name < b.name
	end)
	local result = { }
	-- Use up to eight bases from the native database for the selected defense
	-- profile, then retain the current base as a comparison if it fell outside
	-- that focused sample. Rotate their order by seed to avoid spending every
	-- small exact budget on the same base first; affixes are checked per base.
	local selectedCount = math.min(MAX_BASES_PER_SLOT, #choices)
	local offset = selectedCount > 0 and ((math.floor(tonumber(seed) or 1) - 1) % selectedCount) or 0
	for index = 0, selectedCount - 1 do
		result[#result + 1] = choices[((index + offset) % selectedCount) + 1]
	end
	if currentChoice and not seenBases[currentChoice.name] then
		result[#result + 1] = currentChoice
	end
	return result
end

local function hardGateTags(metricKey)
	if metricKey == "Life" then return { "life", "resource" } end
	if metricKey == "EnergyShield" then return { "energyshield", "resource" } end
	if metricKey == "Ward" then return { "ward", "resource" } end
	if metricKey == "TotalEHP" then return { "life", "energyshield", "ward", "armour", "evasion", "defences", "resistance" } end
	if type(metricKey) ~= "string" then return nil end
	if metricKey:find("MaximumHitTaken", 1, true) then
		if metricKey:find("Physical", 1, true) then return { "life", "energyshield", "ward", "armour", "defences" } end
		return { "life", "energyshield", "ward", "resistance", "defences" }
	end
	if metricKey:find("Resist", 1, true) then return { "resistance" } end
	if metricKey == "BlockChance" then return { "block" } end
	if metricKey == "SpellSuppressionChance" then return { "suppression" } end
	if metricKey == "LifeSustainMargin" or metricKey == "LifeLeechGainRate" then
		return { "life", "resource", "life_regeneration", "life_recovery" }
	end
	if metricKey == "ManaSustainMargin" or metricKey == "ManaLeechGainRate"
		or metricKey == "ManaUnreserved" or metricKey == "ManaReservedMax" then
		return { "mana", "resource", "mana_regeneration", "mana_recovery", "reservation" }
	end
	if metricKey == "LifeUnreserved" or metricKey == "LifeReservedMax" or metricKey == "LifeReservedPercentMax" then
		return { "life", "resource", "reservation" }
	end
	if metricKey == "CombinedDPS" or metricKey == "FullDPS" then
		return { "damage", "attack", "caster", "speed", "critical", "physical_damage", "elemental_damage", "chaos_damage" }
	end
	if metricKey == "FullDotDPS" or metricKey == "TotalDotDPS" then return { "damage", "dot", "elemental_damage", "chaos_damage" } end
	if metricKey == "CritChance" or metricKey == "CritMultiplier" then return { "damage", "critical" } end
	if metricKey == "Speed" or metricKey == "ActionSpeedMod" then return { "speed", "attack", "caster" } end
	if metricKey == "ImpaleDPS" then return { "damage", "physical_damage" } end
	return nil
end

local function buildPriorityProfile(build, parsed)
	local output = build and build.calcsTab and build.calcsTab.mainOutput
	local profile = {
		source = type(output) == "table" and "loaded PoB exact MAIN output plus Matrix floors" or "Matrix floors only",
		hardGates = { },
		attributeRequirements = { },
		exactBaselineAvailable = type(output) == "table",
	}
	local exactGate = type(output) == "table" and validator.Check(parsed or { hard = { } }, output) or nil
	local unmetByKey = { }
	for _, violation in ipairs(exactGate and exactGate.violations or { }) do unmetByKey[violation.key] = violation end
	for key, constraint in pairs(parsed and parsed.hard or { }) do
		local metricKey = constraint.metricKey or key
		local tags = hardGateTags(metricKey)
		if tags then
			local violation = unmetByKey[key]
			local row = { key = key, metricKey = metricKey, tags = tags, weight = 4, status = "requested" }
			if violation and isFinite(violation.actual) and isFinite(violation.required) then
				local relativeDeficit = math.abs(violation.deficit or 0) / math.max(math.abs(violation.required), 1)
				row.weight = row.weight + 6 + math.min(8, math.floor(relativeDeficit * 8))
				row.status = "exact_baseline_violation"
				row.actual = violation.actual
				row.required = violation.required
				row.deficit = violation.deficit
			end
			profile.hardGates[#profile.hardGates + 1] = row
		end
	end
	t_sort(profile.hardGates, function(a, b) return a.key < b.key end)
	local attributeNames = { Str = "strength", Dex = "dexterity", Int = "intelligence" }
	for attribute, name in pairs(attributeNames) do
		local actual = type(output) == "table" and tonumber(output[attribute]) or nil
		local required = type(output) == "table" and tonumber(output["Req" .. attribute]) or nil
		if isFinite(actual) and isFinite(required) and required > actual then
			local deficit = required - actual
			profile.attributeRequirements[attribute] = {
				name = name,
				actual = actual,
				required = required,
				deficit = deficit,
				weight = 6 + math.min(8, math.floor(deficit / math.max(required, 1) * 8)),
				status = "exact_baseline_requirement_deficit",
			}
		end
	end
	return profile
end

local function priorityTagWeights(profile)
	local weights = { }
	for _, requirement in pairs(profile and profile.attributeRequirements or { }) do
		weights.attribute = math.max(weights.attribute or 0, 50 + (tonumber(requirement.weight) or 0))
	end
	for _, gate in ipairs(profile and profile.hardGates or { }) do
		if gate.status == "exact_baseline_violation" then
			for _, tag in ipairs(gate.tags or { }) do
				local normalizedTag = normalizeTag(tag)
				weights[normalizedTag] = (weights[normalizedTag] or 0) + (tonumber(gate.weight) or 0)
			end
		end
	end
	return weights
end

local function modHasTag(mod, tag)
	for _, value in ipairs(mod and mod.modTags or { }) do
		if normalizeTag(value) == normalizeTag(tag) then return true end
	end
	for _, value in ipairs(mod and mod.tags or { }) do
		if normalizeTag(value) == normalizeTag(tag) then return true end
	end
	return false
end

local function attributeRequirementScore(mod, profile)
	local tags = { }
	for _, tag in ipairs(mod.modTags or { }) do tags[normalizeTag(tag)] = true end
	for _, tag in ipairs(mod.tags or { }) do tags[normalizeTag(tag)] = true end
	if not tags.attribute then return 0 end
	local text = tostring(mod[1] or mod.name or ""):lower()
	local allAttributes = text:find("all attribute", 1, true) ~= nil
	local names = { Str = "strength", Dex = "dexterity", Int = "intelligence" }
	local score = 0
	for attribute, requirement in pairs(profile and profile.attributeRequirements or { }) do
		if allAttributes or text:find(names[attribute], 1, true) then score = score + requirement.weight end
	end
	return math.min(score, 24)
end

local function tagScore(mod, objective, parsed, profile)
	local tags = { }
	for _, tag in ipairs(mod.modTags or { }) do tags[normalizeTag(tag)] = true end
	for _, tag in ipairs(mod.tags or { }) do tags[normalizeTag(tag)] = true end
	local score = 1
	local function add(tag, value) if tags[normalizeTag(tag)] then score = score + value end end
	local defensive = objective == "TotalEHP"
	local speed = objective == "Speed"
	if defensive then
		for _, tag in ipairs({ "life", "resource", "defences", "defence", "armour", "evasion", "energyshield", "resistance", "block", "suppression" }) do add(tag, 4) end
	else
		for _, tag in ipairs({ "damage", "attack", "caster", "speed", "critical", "physical_damage", "elemental_damage", "chaos_damage", "dot" }) do
			add(tag, speed and (tag == "speed" and 7 or 1) or 4)
		end
	end
	for _, gate in ipairs(profile and profile.hardGates or { }) do
		for _, tag in ipairs(gate.tags or { }) do
			if tags[tag] then
				score = score + gate.weight
				break
			end
		end
	end
	local preferences = parsed and parsed.preferences or { }
	local damageFocusTags = {
		Fire = { "fire", "fire_damage", "elemental_damage" },
		Cold = { "cold", "cold_damage", "elemental_damage" },
		Lightning = { "lightning", "lightning_damage", "elemental_damage" },
		PhysicalHit = { "physical_damage", "attack" },
		PhysicalImpale = { "physical_damage", "impale" },
		PhysicalDoT = { "physical_damage", "bleed", "dot" },
		ChaosPoison = { "chaos_damage", "poison", "dot" },
		Minions = { "minion", "minion_damage" },
	}
	for _, tag in ipairs(damageFocusTags[preferences.damageFocus] or { }) do add(tag, 18) end
	local defenseFocusTags = {
		Life = { "life", "resource" },
		EnergyShield = { "energyshield", "resource" },
		Hybrid = { "life", "energyshield", "resource" },
		Ward = { "ward", "resource" }, Armour = { "armour", "defences" },
		Evasion = { "evasion", "defences" }, Block = { "block" },
		SpellBlock = { "spell_block", "block" }, SpellSuppression = { "suppression" },
	}
	for _, tag in ipairs(defenseFocusTags[preferences.defenseProfile] or { }) do add(tag, 14) end
	score = score + attributeRequirementScore(mod, profile)
	for _, damageType in ipairs(parsed and parsed.conversion and parsed.conversion.route or { }) do
		add(tostring(damageType):lower() .. "_damage", 3)
	end
	return score
end

local function collectEligibleMods(item, itemLevel, objective, parsed, profile)
	local buckets = { }
	for modId, mod in pairs(item.affixes or { }) do
		if (mod.type == "Prefix" or mod.type == "Suffix") and mod.group and mod.level
			and mod.level <= itemLevel and mod.weightKey and mod.weightVal
			and not tostring(mod.affix or ""):find("Elevated", 1, true) then
			local spawnWeight = item:GetModSpawnWeight(mod)
			if spawnWeight > 0 then
				local key = mod.type .. "\0" .. tostring(mod.group)
				buckets[key] = buckets[key] or { }
				buckets[key][#buckets[key] + 1] = {
					id = modId,
					mod = mod,
					spawnWeight = spawnWeight,
					score = tagScore(mod, objective, parsed, profile),
				}
			end
		end
	end
	local eligible = { Prefix = { }, Suffix = { } }
	for _, bucket in pairs(buckets) do
		t_sort(bucket, function(a, b)
			if a.mod.level ~= b.mod.level then return a.mod.level > b.mod.level end
			return a.id < b.id
		end)
		local lastLevel, tierRank
		for _, entry in ipairs(bucket) do
			if entry.mod.level ~= lastLevel then
				tierRank = (tierRank or 0) + 1
				lastLevel = entry.mod.level
			end
			if tierRank <= MAX_AFFIX_TIERS_PER_GROUP then
				entry.tierRank = tierRank
				eligible[entry.mod.type][#eligible[entry.mod.type] + 1] = entry
			end
		end
	end
	for modType, list in pairs(eligible) do
		t_sort(list, function(a, b)
			if a.score ~= b.score then return a.score > b.score end
			if a.mod.level ~= b.mod.level then return a.mod.level > b.mod.level end
			if a.spawnWeight ~= b.spawnWeight then return a.spawnWeight > b.spawnWeight end
			return a.id < b.id
		end)
		-- Preserve a bounded representative for each exact baseline deficit before
		-- generateCombos truncates each affix side to eight entries. Ranking alone
		-- was insufficient: several high-scoring broad tags could otherwise push
		-- the only attribute repair out of that prefix. These representatives only
		-- influence proposal coverage; final acceptance remains the exact PoB gate.
		local weights = priorityTagWeights(profile)
		local priorityTags = { }
		for tag, weight in pairs(weights) do
			priorityTags[#priorityTags + 1] = { tag = tag, weight = weight }
		end
		t_sort(priorityTags, function(a, b)
			if a.weight ~= b.weight then return a.weight > b.weight end
			return a.tag < b.tag
		end)
		local selected, reordered, covered = { }, { }, { }
		for _, priority in ipairs(priorityTags) do
			if #reordered >= 8 then break end
			if not covered[priority.tag] then
				for _, entry in ipairs(list) do
					if not selected[entry.id] and modHasTag(entry.mod, priority.tag) then
						selected[entry.id] = true
						reordered[#reordered + 1] = entry
						for _, tag in ipairs(entry.mod.modTags or { }) do covered[normalizeTag(tag)] = true end
						for _, tag in ipairs(entry.mod.tags or { }) do covered[normalizeTag(tag)] = true end
						break
					end
				end
			end
		end
		for _, entry in ipairs(list) do
			if not selected[entry.id] then reordered[#reordered + 1] = entry end
		end
		eligible[modType] = reordered
	end
	return eligible
end

local function addCombo(combos, seen, prefixes, suffixes, prefixList, suffixList, priorityWeights)
	if #prefixes > 2 or #suffixes > 2 or #prefixes + #suffixes < 1 or #prefixes + #suffixes > 4 then return end
	local groups = { }
	local ids, prefixModIds, suffixModIds, score, coveredTags = { }, { }, { }, 0, { }
	for _, index in ipairs(prefixes) do
		local entry = prefixList[index]
		if not entry or groups[entry.mod.group] then return end
		groups[entry.mod.group] = true
		ids[#ids + 1] = entry.id
		prefixModIds[#prefixModIds + 1] = entry.id
		score = score + entry.score + entry.mod.level / 1000
		for _, tag in ipairs(entry.mod.modTags or { }) do coveredTags[normalizeTag(tag)] = true end
		for _, tag in ipairs(entry.mod.tags or { }) do coveredTags[normalizeTag(tag)] = true end
	end
	for _, index in ipairs(suffixes) do
		local entry = suffixList[index]
		if not entry or groups[entry.mod.group] then return end
		groups[entry.mod.group] = true
		ids[#ids + 1] = entry.id
		suffixModIds[#suffixModIds + 1] = entry.id
		score = score + entry.score + entry.mod.level / 1000
		for _, tag in ipairs(entry.mod.modTags or { }) do coveredTags[normalizeTag(tag)] = true end
		for _, tag in ipairs(entry.mod.tags or { }) do coveredTags[normalizeTag(tag)] = true end
	end
	for tag, weight in pairs(priorityWeights or { }) do
		if coveredTags[tag] then score = score + weight * 4 end
	end
	t_sort(ids)
	local signature = table.concat(ids, "|")
	if seen[signature] then return end
	seen[signature] = true
	combos[#combos + 1] = {
		prefixes = prefixes,
		suffixes = suffixes,
		prefixModIds = prefixModIds,
		suffixModIds = suffixModIds,
		modIds = ids,
		signature = signature,
		priorityCoverage = coveredTags,
		score = score,
		affixCount = #ids,
	}
end

local function exactGateCoverageScore(coveredTags, profile)
	local score = 0
	for _, gate in ipairs(profile and profile.hardGates or { }) do
		if gate.status == "exact_baseline_violation" then
			for _, tag in ipairs(gate.tags or { }) do
				if coveredTags[normalizeTag(tag)] then
					score = score + (tonumber(gate.weight) or 0)
					break
				end
			end
		end
	end
	if coveredTags.attribute then
		for _, requirement in pairs(profile and profile.attributeRequirements or { }) do
			score = score + 10 + (tonumber(requirement.weight) or 0)
		end
	end
	return score
end

local function generateCombos(eligible, limit, profile)
	local priorityWeights = priorityTagWeights(profile)
	local prefixes, suffixes = { }, { }
	for index = 1, math.min(8, #eligible.Prefix) do prefixes[index] = eligible.Prefix[index] end
	for index = 1, math.min(8, #eligible.Suffix) do suffixes[index] = eligible.Suffix[index] end
	local combos, seen = { }, { }
	for first = 1, #prefixes do
		for second = first + 1, #prefixes do
			for third = 1, #suffixes do
				for fourth = third + 1, #suffixes do
				addCombo(combos, seen, { first, second }, { third, fourth }, prefixes, suffixes, priorityWeights)
				end
			end
		end
	end
	for first = 1, #prefixes do
		for second = first + 1, #prefixes do
			for suffix = 1, #suffixes do addCombo(combos, seen, { first, second }, { suffix }, prefixes, suffixes, priorityWeights) end
		end
	end
	for prefix = 1, #prefixes do
		for first = 1, #suffixes do
			for second = first + 1, #suffixes do addCombo(combos, seen, { prefix }, { first, second }, prefixes, suffixes, priorityWeights) end
		end
	end
	for prefix = 1, #prefixes do
			for suffix = 1, #suffixes do addCombo(combos, seen, { prefix }, { suffix }, prefixes, suffixes, priorityWeights) end
	end
	for first = 1, #prefixes do
		for second = first + 1, #prefixes do addCombo(combos, seen, { first, second }, { }, prefixes, suffixes, priorityWeights) end
	end
	for first = 1, #suffixes do
		for second = first + 1, #suffixes do addCombo(combos, seen, { }, { first, second }, prefixes, suffixes, priorityWeights) end
	end
	for index = 1, #prefixes do addCombo(combos, seen, { index }, { }, prefixes, suffixes, priorityWeights) end
	for index = 1, #suffixes do addCombo(combos, seen, { }, { index }, prefixes, suffixes, priorityWeights) end
	for _, combo in ipairs(combos) do
		combo.exactGateCoverageScore = exactGateCoverageScore(combo.priorityCoverage, profile)
	end
	t_sort(combos, function(a, b)
		if a.exactGateCoverageScore ~= b.exactGateCoverageScore then
			return a.exactGateCoverageScore > b.exactGateCoverageScore
		end
		if a.affixCount ~= b.affixCount then return a.affixCount > b.affixCount end
		if a.score ~= b.score then return a.score > b.score end
		return table.concat(a.modIds, "|") < table.concat(b.modIds, "|")
	end)
	-- Preserve at least one legal combination for each high-priority deficit as
	-- well as preserving its individual affix. Otherwise the bounded combo cap
	-- can discard a useful multi-affix repair even though all its mods survived.
	local priorityTags = { }
	for tag, weight in pairs(priorityWeights) do priorityTags[#priorityTags + 1] = { tag = tag, weight = weight } end
	t_sort(priorityTags, function(a, b)
		if a.weight ~= b.weight then return a.weight > b.weight end
		return a.tag < b.tag
	end)
	local selected, reordered, covered = { }, { }, { }
	for _, priority in ipairs(priorityTags) do
		if #reordered >= limit then break end
		if not covered[priority.tag] then
			for _, combo in ipairs(combos) do
				if not selected[combo] and combo.priorityCoverage[priority.tag] then
					selected[combo] = true
					reordered[#reordered + 1] = combo
					for tag in pairs(combo.priorityCoverage) do covered[tag] = true end
					break
				end
			end
		end
	end
	for _, combo in ipairs(combos) do
		if not selected[combo] then reordered[#reordered + 1] = combo end
	end
	-- Treat the cap as a candidate cap, not an affix-set cap: every selected
	-- native affix set gets both median and maximum numeric rolls. The resulting
	-- item still goes through Craft(), native reparsing, slot validation and the
	-- exact PoB calculator before it can be returned as a route.
	local affixSetLimit = math.max(1, math.ceil(limit / #AFFIX_ROLL_PROFILES))
	local bounded = { }
	for index = 1, math.min(affixSetLimit, #reordered) do
		local combo = reordered[index]
		for _, rollProfile in ipairs(AFFIX_ROLL_PROFILES) do
			if #bounded >= limit then break end
			local variant = { }
			for key, value in pairs(combo) do variant[key] = value end
			variant.rollProfileId = rollProfile.id
			variant.rollFraction = rollProfile.fraction
			variant.rollLabel = rollProfile.label
			variant.signature = combo.signature .. "@" .. rollProfile.id
			bounded[#bounded + 1] = variant
		end
		if #bounded >= limit then break end
	end
	return bounded
end

local function validateCraftedAffixPool(item, itemLevel, expectedAffixCount)
	local groups, count = { }, 0
	local function validateSide(affixes, expectedType)
		for _, affix in ipairs(affixes or { }) do
			local modId = type(affix) == "table" and affix.modId or nil
			if modId and modId ~= "None" then
				local mod = item.affixes and item.affixes[modId]
				if not mod or mod.type ~= expectedType then
					return false, "PoB reparsed a generated affix into an incompatible prefix/suffix type"
				end
				if not mod.group or groups[mod.group] then
					return false, "Generated item contains a duplicate or missing native mod group"
				end
				if not isFinite(tonumber(mod.level)) or tonumber(mod.level) > itemLevel then
					return false, "Generated affix exceeds the requested item's native level"
				end
				if type(item.GetModSpawnWeight) ~= "function" or item:GetModSpawnWeight(mod) <= 0 then
					return false, "Generated affix is not eligible on the selected native item base"
				end
				groups[mod.group] = true
				count = count + 1
			end
		end
		return true
	end
	local ok, err = validateSide(item.prefixes, "Prefix")
	if not ok then return false, err end
	ok, err = validateSide(item.suffixes, "Suffix")
	if not ok then return false, err end
	if count ~= expectedAffixCount then
		return false, "PoB did not preserve the requested number of native eligible affixes"
	end
	return true
end

local function craftCandidate(baseName, itemLevel, combo, socketPlan)
	local item = makeProbe(baseName, itemLevel)
	if not item then return nil, "PoB could not load the selected native item base" end
	local nativeBase = item.base
	local prefixList, suffixList = { limit = #combo.prefixModIds }, { limit = #combo.suffixModIds }
	for index, modId in ipairs(combo.prefixModIds) do
		prefixList[index] = { modId = modId, range = combo.rollFraction or 0.5 }
	end
	for index, modId in ipairs(combo.suffixModIds) do
		suffixList[index] = { modId = modId, range = combo.rollFraction or 0.5 }
	end
	item.title = nil
	item.name = ""
	item.namePrefix = ""
	item.nameSuffix = ""
	item.itemLevel = itemLevel
	item.crafted = true
	item.prefixes = prefixList
	item.suffixes = suffixList
	local ok, err = pcall(item.Craft, item)
	if not ok then return nil, "PoB rejected a native mod combination: " .. tostring(err) end
	if socketPlan then
		local availableSockets = nativeSocketCapacity(item)
		if not nativeBase or availableSockets < socketPlan.requiredSockets then
			return nil, string.format("The selected native item base %s has %d sockets available; the Main Skill needs %d",
				tostring(baseName), availableSockets, socketPlan.requiredSockets)
		end
		item.sockets = { }
		for index, color in ipairs(socketPlan.colors) do
			local linkGroup = socketPlan.linkGroups and socketPlan.linkGroups[index] or socketPlan.linkGroup or 0
			item.sockets[#item.sockets + 1] = { color = color, group = linkGroup }
		end
	end
	-- BuildRaw only writes a separate base line for rare items when `title` is
	-- present. Craft() derives a generated affix name but leaves title unset, so
	-- its first raw form is ambiguous to a fresh PoB Item parser. Promote that
	-- generated name to the rare title and rebuild through the native parser;
	-- this gives the candidate the same portable raw shape as a user item.
	item.title = item.name
	local reparsed, reparseError = pcall(item.BuildAndParseRaw, item)
	if not reparsed or not item.base or item.baseName ~= baseName then
		return nil, "Path of Building could not normalize the generated rare item: " .. tostring(reparseError or "base not recognized")
	end
	local prefixCount = countRealAffixes(item.prefixes)
	local suffixCount = countRealAffixes(item.suffixes)
	if item.rarity ~= "RARE" or prefixCount > 2 or suffixCount > 2
		or prefixCount + suffixCount > 4 or prefixCount + suffixCount ~= combo.affixCount then
		return nil, "PoB did not preserve the strict four-affix rare-item limit"
	end
	local nativeAffixesValid, nativeAffixError = validateCraftedAffixPool(item, itemLevel, combo.affixCount)
	if not nativeAffixesValid then return nil, nativeAffixError end
	if socketPlan then
		if nativeSocketCapacity(item) < socketPlan.requiredSockets
			or #item.sockets ~= socketPlan.requiredSockets then
			return nil, "PoB did not preserve the requested native socket count"
		end
		for index, color in ipairs(socketPlan.colors) do
			local linkGroup = socketPlan.linkGroups and socketPlan.linkGroups[index] or socketPlan.linkGroup or 0
			if item.sockets[index].color ~= color or item.sockets[index].group ~= linkGroup then
				return nil, "PoB did not preserve the requested socket colors and single-link layout"
			end
		end
	end
	item.optimizerSynthetic = true
	item:BuildModList()
	return item
end

local function nextVirtualItemId(itemsTab, used)
	local maxId = 0
	for itemId in pairs(itemsTab.items or { }) do
		local numericId = tonumber(itemId)
		if numericId and numericId >= 1 and numericId == math.floor(numericId) and numericId > maxId then
			maxId = numericId
		end
	end
	while used[maxId + 1] or itemsTab.items[maxId + 1] or itemsTab.items[tostring(maxId + 1)] do
		maxId = maxId + 1
	end
	return maxId + 1
end

local function normalizeSocketRepairRaw(raw)
	if type(raw) ~= "string" then return nil, 0 end
	local lines, socketCount = { }, 0
	for line in raw:gmatch("[^\r\n]+") do
		if line:match("^Unique ID:") then
			-- An imported item ID identifies the source instance, not its native
			-- base, rarity, or explicit modifiers. A repair must create a disposable
			-- item instance, so ignore only this identity line.
		elseif line:match("^Sockets:") then
			socketCount = socketCount + 1
			lines[#lines + 1] = "Sockets:<REPAIRED_LAYOUT>"
		else
			lines[#lines + 1] = line
		end
	end
	return table.concat(lines, "\n"), socketCount
end

local function isSocketRepairCopy(item, entry)
	if not item or type(entry) ~= "table" or type(entry.sourceRaw) ~= "string" then return false end
	local source = new("Item"):Item(entry.sourceRaw)
	if not source or not source.base or not item.base
		or (source.rarity ~= "RARE" and source.rarity ~= "UNIQUE")
		or item.rarity ~= source.rarity or item.baseName ~= source.baseName
		or (entry.rarity and item.rarity ~= entry.rarity)
		or (entry.baseName and item.baseName ~= entry.baseName) then
		return false
	end
	local sourceNormalized, sourceSocketCount = normalizeSocketRepairRaw(source.raw)
	local candidateNormalized, candidateSocketCount = normalizeSocketRepairRaw(item.raw)
	return sourceSocketCount == 1 and candidateSocketCount == 1
		and sourceNormalized == candidateNormalized
end

local function makeSocketRepairOnlyCandidate(build, itemsTab, itemSet, slotName, repairPlan, usedIds)
	local selected = itemSet and itemSet[slotName]
	local currentId = selected and tonumber(selected.selItemId)
	local currentItem = currentId and currentId > 0 and itemsTab.items[currentId] or nil
	if not currentItem or (currentItem.rarity ~= "RARE" and currentItem.rarity ~= "UNIQUE")
		or type(currentItem.raw) ~= "string"
		or not currentItem.base or nativeSocketCapacity(currentItem) < repairPlan.socketCount then
		return nil, "The currently equipped rare or unique item cannot preserve the required native socket count"
	end
	local tokens = { }
	for index, color in ipairs(repairPlan.colors or { }) do
		local token = tostring(color)
		if index > 1 then
			local sameLink = repairPlan.linkGroups[index - 1] == repairPlan.linkGroups[index]
			tokens[#tokens + 1] = sameLink and "-" or " "
		end
		tokens[#tokens + 1] = token
	end
	local socketLine = "Sockets: " .. table.concat(tokens)
	local raw, replaced = currentItem.raw:gsub("Sockets:[^\r\n]*", socketLine, 1)
	if replaced ~= 1 then return nil, "The equipped native item has no reparsable socket line" end
	-- This is a hypothetical disposable rework. Drop the imported instance ID so
	-- the candidate cannot alias the source item's identity in PoB's item set.
	raw = raw:gsub("[\r\n]Unique ID:[^\r\n]*", "", 1)
	local item = new("Item"):Item(raw)
	if not item or not item.base or not isSocketRepairCopy(item, {
		sourceRaw = currentItem.raw, rarity = currentItem.rarity, baseName = currentItem.baseName,
	})
		or not SkillCatalog.SocketLayoutMatchesRepair(item, repairPlan) then
		return nil, "PoB did not preserve the equipped item's native identity and repaired socket/link layout"
	end
	if not itemsTab:IsItemValidForSlot(item, slotName, itemSet) then
		return nil, "PoB does not accept the repaired native item in its recorded equipment slot"
	end
	local virtualId = nextVirtualItemId(itemsTab, usedIds)
	usedIds[virtualId] = true
	item.id = virtualId
	item.optimizerSocketRepair = true
	local socketPlan = {
		groupIndex = repairPlan.groupIndex,
		colors = shallowCopy(repairPlan.colors),
		linkGroups = shallowCopy(repairPlan.linkGroups or { }),
		repair = true,
		retainedSourceAffixes = true,
		retainedSourceRarity = true,
	}
	local name = tostring(currentItem.title or currentItem.name or currentItem.baseName)
	local rarity = currentItem.rarity
	local gemVariants = { }
	for _, variant in ipairs(repairPlan.gemRemovals or { }) do
		gemVariants[#gemVariants + 1] = shallowCopy(variant)
	end
	local label = "Native socket/link repair: " .. slotName .. " / " .. name .. " (" .. rarity .. " and modifiers retained)"
	return {
		label = label,
		gemVariants = #gemVariants > 0 and gemVariants or nil,
		island = 1,
		gearVariant = {
			overrides = { [slotName] = virtualId },
			changedSlots = { slotName },
			items = { { slot = slotName, itemId = virtualId, name = name, rarity = rarity,
				synthetic = false, socketRepair = true, baseName = item.baseName, itemLevel = item.itemLevel,
				sourceItemId = currentId, retainedSourceAffixes = true, retainedSourceRarity = true } },
			generatedItems = { { tempId = virtualId, slotName = slotName, baseName = item.baseName,
				itemLevel = item.itemLevel, item = item, name = name,
				kind = "socket_repair", sourceItemId = currentId, sourceRaw = currentItem.raw,
				rarity = rarity,
				modIds = { }, affixCount = #(item.prefixes or { }) + #(item.suffixes or { }),
				socketPlan = socketPlan, retainedSourceAffixes = true, retainedSourceRarity = true } },
			syntheticSearch = true,
			socketRepair = true,
			socketRepairOnly = true,
		},
	}
end

function syntheticGear.BuildCandidates(build, limit, seed, fixedOverrides, parsed, requestedItemLevel, targetSkill)
	local candidates = { }
	local coverage = {
		possibleSlots = 0,
		possibleBases = 0,
		generatedCandidates = 0,
		generatedSingleCandidates = 0,
		generatedPairedCandidates = 0,
		generatedFourAffixCandidates = 0,
		socketBoundCandidates = 0,
		exactEvaluations = 0,
		exactSocketBoundEvaluations = 0,
		exactPairedEvaluations = 0,
		exactTripleEvaluations = 0,
		exactPairBudgetEvaluations = 0,
		exactPairBudgetPasses = 0,
		exactPairBudgetFailures = 0,
		exactTripleBudgetEvaluations = 0,
		exactTripleBudgetPasses = 0,
		exactTripleBudgetFailures = 0,
		lastExactPairBudgetTotal = nil,
		lastExactTripleBudgetTotal = nil,
		generatedCandidateLimit = 0,
		pairCandidateLimit = 0,
		pairCombinationInspections = 0,
		pairInspectionLimit = 0,
		pairInspectionLimitReached = false,
		generatedTripleCandidates = 0,
		tripleCandidateLimit = 0,
		tripleCombinationInspections = 0,
		tripleInspectionLimit = 0,
		tripleInspectionLimitReached = false,
		structuralRejections = 0,
		lastStructuralRejection = nil,
		maxAffixes = 4,
		maxBasesPerSlot = MAX_BASES_PER_SLOT,
		tierBandsPerGroup = MAX_AFFIX_TIERS_PER_GROUP,
		affixCombinationsPerBase = MAX_AFFIX_COMBINATIONS_PER_BASE,
		affixRollProfiles = { { id = "maximum", fraction = 1 }, { id = "median", fraction = 0.5 } },
		tierRanking = "highest three eligible native mod-level bands ranked by objective, Matrix hard-gate deficits, and exact PoB attribute requirements",
	}
	limit = math.min(MAX_SYNTHETIC_CANDIDATES, math.max(0, math.floor(tonumber(limit) or 0)))
	coverage.generatedCandidateLimit = limit
	local itemsTab = build and build.itemsTab
	local itemSet = getActiveSet(itemsTab)
	if limit == 0 or not itemsTab or type(itemsTab.IsItemValidForSlot) ~= "function" or not itemSet then return candidates, coverage end
	local priorityProfile = buildPriorityProfile(build, parsed)
	coverage.priorityProfile = priorityProfile
	local plans, usedIds = { }, { }
	local selectedGroup = targetSkill and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[tonumber(targetSkill.groupIndex)]
	local requireSocketedTarget = selectedGroup and not selectedGroup.slot and not selectedGroup.source
	for slotOrder, slotName in ipairs(require("Modules.Optimizer.Equipment").GetSlots(build)) do
		if not (fixedOverrides or { })[slotName] then
			local selectedId = tonumber(itemSet[slotName] and itemSet[slotName].selItemId) or 0
			local currentItem = selectedId > 0 and itemsTab.items[selectedId] or nil
			local itemLevel = itemLevelFor(build, currentItem, requestedItemLevel)
			local socketPlan = buildSocketPlan(build, targetSkill, slotName)
			-- Unbound rares are useful as internal pieces in a larger portfolio
			-- whose one socket-bearing item links the selected unlinked skill.
			-- Filter them only at the final single/pair proposal boundary below.
			local bases = eligibleBases(build, itemsTab, itemSet, slotName, seed, itemLevel,
					socketPlan and socketPlan.requiredSockets or 0, parsed)
			if #bases > 0 then coverage.possibleSlots = coverage.possibleSlots + 1 end
			for baseOrder, baseChoice in ipairs(bases) do
				coverage.possibleBases = coverage.possibleBases + 1
				local probe = makeProbe(baseChoice.name, itemLevel)
				if probe then
					local eligible = collectEligibleMods(probe, itemLevel, parsed and parsed.objective, parsed, priorityProfile)
					local combos = generateCombos(eligible,
						math.min(limit, MAX_AFFIX_COMBINATIONS_PER_BASE), priorityProfile)
					if #combos > 0 then
						local function addPlan(planSocketPlan, variantOrder)
							plans[#plans + 1] = {
								slotName = slotName,
								baseName = baseChoice.name,
								itemLevel = itemLevel,
								combos = combos,
								currentItemId = baseChoice.currentItemId,
								socketPlan = planSocketPlan,
								slotOrder = slotOrder,
								baseOrder = baseOrder,
								variantOrder = variantOrder,
							}
						end
						addPlan(socketPlan, 1)
						if requireSocketedTarget and socketPlan then
							-- Keep an unbound version as an internal portfolio piece;
							-- final proposals must still contain exactly one binding.
							addPlan(nil, 2)
						end
					end
				end
			end
		end
	end
	table.sort(plans, function(a, b)
		if a.baseOrder == b.baseOrder then
			if a.slotOrder == b.slotOrder then return a.variantOrder < b.variantOrder end
			return a.slotOrder < b.slotOrder
		end
		return a.baseOrder < b.baseOrder
	end)

	local singleCandidates = { }
	local socketRepairPlans = targetSkill and targetSkill.socketRepairs or { }
	if #socketRepairPlans == 0 and targetSkill and targetSkill.socketRepair then
		socketRepairPlans = { targetSkill.socketRepair }
	end
	coverage.socketRepairOnlyCandidatesGenerated = 0
	coverage.socketRepairOnlyCandidateRejections = { }
	for _, socketRepairPlan in ipairs(socketRepairPlans) do
		if socketRepairPlan.slot and not (fixedOverrides or { })[socketRepairPlan.slot] then
			local repairCandidate, repairError = makeSocketRepairOnlyCandidate(build, itemsTab, itemSet,
				socketRepairPlan.slot, socketRepairPlan, usedIds)
			if repairCandidate then
				singleCandidates[#singleCandidates + 1] = repairCandidate
				coverage.socketRepairOnlyCandidatesGenerated = coverage.socketRepairOnlyCandidatesGenerated + 1
			else
				coverage.socketRepairOnlyCandidateReason = coverage.socketRepairOnlyCandidateReason
					or tostring(repairError or "native socket repair proposal unavailable")
				coverage.socketRepairOnlyCandidateRejections[#coverage.socketRepairOnlyCandidateRejections + 1] = {
					slot = socketRepairPlan.slot,
					reason = tostring(repairError or "native socket repair proposal unavailable"),
				}
			end
		end
	end
	coverage.socketRepairOnlyCandidateGenerated = coverage.socketRepairOnlyCandidatesGenerated > 0
	local schedule, scheduled, scheduledTags = { }, { }, { }
	local function enqueue(plan, combo, depth)
		if not combo then return end
		scheduled[plan] = scheduled[plan] or { }
		if scheduled[plan][combo] then return end
		scheduled[plan][combo] = true
		schedule[#schedule + 1] = { plan = plan, combo = combo, depth = depth }
	end
	-- Reserve at least one native item proposal for each exact baseline deficit
	-- before filling the remaining budget round-robin. Without this global reserve,
	-- many slot/base plans could consume the entire limit with their first combo,
	-- so a valid Energy Shield or attribute repair at depth two was never tried.
	local priorityTags = { }
	for tag, weight in pairs(priorityTagWeights(priorityProfile)) do
		priorityTags[#priorityTags + 1] = { tag = tag, weight = weight }
	end
	t_sort(priorityTags, function(a, b)
		if a.weight ~= b.weight then return a.weight > b.weight end
		return a.tag < b.tag
	end)
	for _, priority in ipairs(priorityTags) do
		if not scheduledTags[priority.tag] then
			local bestPlan, bestCombo, bestDepth, bestScore
			for _, plan in ipairs(plans) do
				if not requireSocketedTarget or plan.socketPlan then
					for depth, combo in ipairs(plan.combos) do
						if not scheduled[plan] or not scheduled[plan][combo] then
							if combo.priorityCoverage[priority.tag] then
								local score = (combo.exactGateCoverageScore or 0) * 1000 + (combo.score or 0)
								if not bestScore or score > bestScore then
									bestPlan, bestCombo, bestDepth, bestScore = plan, combo, depth, score
								end
							end
						end
					end
				end
			end
			if bestPlan then
				enqueue(bestPlan, bestCombo, bestDepth)
				for tag in pairs(bestCombo.priorityCoverage) do scheduledTags[tag] = true end
			end
		end
	end
	-- Keep the original deterministic breadth-first plan rotation for the rest of
	-- the budget, after the strict-gate and exact-requirement coverage reserves.
	local depth = 1
	while true do
		local generatedAtDepth = false
		for _, plan in ipairs(plans) do
			local combo = plan.combos[depth]
			if combo then generatedAtDepth = true; enqueue(plan, combo, depth) end
		end
		if not generatedAtDepth then break end
		depth = depth + 1
	end
	for _, scheduledCandidate in ipairs(schedule) do
		if #singleCandidates >= limit then break end
		local plan, combo = scheduledCandidate.plan, scheduledCandidate.combo
		local item, craftError = craftCandidate(plan.baseName, plan.itemLevel, combo, plan.socketPlan)
		if item and not itemsTab:IsItemValidForSlot(item, plan.slotName, itemSet) then
			item = nil
			craftError = "PoB does not allow the generated native item base in the selected equipment slot"
		end
		if item then
			local virtualId = nextVirtualItemId(itemsTab, usedIds)
			usedIds[virtualId] = true
			item.id = virtualId
			local generatedItem = {
				tempId = virtualId,
				slotName = plan.slotName,
				baseName = plan.baseName,
				itemLevel = plan.itemLevel,
				item = item,
				name = tostring(item.name or item.baseName or plan.baseName),
				modIds = combo.modIds,
				affixCount = combo.affixCount,
				rollProfileId = combo.rollProfileId,
				rollFraction = combo.rollFraction,
				rollLabel = combo.rollLabel,
				socketPlan = plan.socketPlan and {
					groupIndex = plan.socketPlan.groupIndex,
					colors = shallowCopy(plan.socketPlan.colors),
					linkGroups = shallowCopy(plan.socketPlan.linkGroups or { }),
					linkGroup = plan.socketPlan.linkGroup,
					repair = plan.socketPlan.repair == true,
				} or nil,
			}
			local socketBinding = plan.socketPlan and selectedGroup and not selectedGroup.slot and not selectedGroup.source and {
				groupIndex = plan.socketPlan.groupIndex,
				slotName = plan.slotName,
				itemId = virtualId,
				socketCount = plan.socketPlan.requiredSockets,
				linkGroup = plan.socketPlan.linkGroup,
			} or nil
			local repairsSocketLayout = plan.socketPlan and plan.socketPlan.repair == true
			singleCandidates[#singleCandidates + 1] = {
				label = "Synthetic rare: " .. plan.slotName .. " / " .. plan.baseName .. " (" .. tostring(combo.affixCount)
					.. "/4 affixes; " .. tostring(combo.rollLabel or "native rolls") .. ")"
					.. (socketBinding and (" + " .. tostring(socketBinding.socketCount) .. "-socket linked skill") or "")
					.. (repairsSocketLayout and " + native socket/link repair" or ""),
				island = ((#singleCandidates + scheduledCandidate.depth - 1) % 4) + 1,
				gearVariant = {
					overrides = { [plan.slotName] = virtualId },
					changedSlots = { plan.slotName },
					items = { { slot = plan.slotName, itemId = virtualId, name = generatedItem.name,
						rarity = "RARE", synthetic = true, baseName = plan.baseName,
						itemLevel = plan.itemLevel, affixCount = combo.affixCount, modIds = combo.modIds,
						rollProfileId = combo.rollProfileId, rollFraction = combo.rollFraction, rollLabel = combo.rollLabel } },
					generatedItems = { generatedItem },
					socketBinding = socketBinding,
					syntheticSearch = true,
					socketRepair = repairsSocketLayout or nil,
				},
			}
		elseif craftError then
			coverage.lastCraftRejection = tostring(craftError):sub(1, 180)
		end
	end

	-- Pair only already-crafted native rares from different slots. Every pair is
	-- still validated as a whole item set and exact-calculated by PoB downstream.
	-- The inspection cap bounds generation work even when a slot has many affix
	-- variants; the pair quota reserves at most one quarter of the requested
	-- candidates and leaves the rest for individual-item coverage.
	local pairQuota = limit >= 2 and math.min(limit, math.max(1, math.floor(limit * 0.25))) or 0
	local pairCandidates = { }
	coverage.pairCandidateLimit = pairQuota
	coverage.pairInspectionLimit = math.min(1024, math.max(32, limit * 16))
	for leftIndex = 1, #singleCandidates - 1 do
		if #pairCandidates >= pairQuota then break end
		for rightIndex = leftIndex + 1, #singleCandidates do
			if #pairCandidates >= pairQuota then break end
			if coverage.pairCombinationInspections >= coverage.pairInspectionLimit then
				coverage.pairInspectionLimitReached = true
				break
			end
			coverage.pairCombinationInspections = coverage.pairCombinationInspections + 1
			local left = singleCandidates[leftIndex]
			local right = singleCandidates[rightIndex]
			local leftVariant = left.gearVariant
			local rightVariant = right.gearVariant
			local leftEntry = leftVariant and leftVariant.generatedItems and leftVariant.generatedItems[1]
			local rightEntry = rightVariant and rightVariant.generatedItems and rightVariant.generatedItems[1]
			local socketBinding = leftVariant and leftVariant.socketBinding or rightVariant and rightVariant.socketBinding
			local duplicateSocketBindings = leftVariant and leftVariant.socketBinding and rightVariant and rightVariant.socketBinding
			if leftEntry and rightEntry and leftEntry.slotName ~= rightEntry.slotName
				and not duplicateSocketBindings and (not requireSocketedTarget or socketBinding) then
				local overrides = { }
				for slotName, itemId in pairs(leftVariant.overrides or { }) do overrides[slotName] = itemId end
				for slotName, itemId in pairs(rightVariant.overrides or { }) do
					if overrides[slotName] == nil then overrides[slotName] = itemId end
				end
				local function itemDescription(entry)
					return {
						slot = entry.slotName, itemId = entry.tempId, name = entry.name,
						rarity = entry.item and entry.item.rarity or "RARE",
						synthetic = entry.kind == nil, socketRepair = entry.kind == "socket_repair" or nil,
						baseName = entry.baseName,
						itemLevel = entry.itemLevel, affixCount = entry.affixCount, modIds = entry.modIds,
						rollProfileId = entry.rollProfileId, rollFraction = entry.rollFraction, rollLabel = entry.rollLabel,
						socketPlan = entry.socketPlan,
					}
				end
				pairCandidates[#pairCandidates + 1] = {
					label = (leftEntry.kind == "socket_repair" or rightEntry.kind == "socket_repair")
						and ("Equipment combination + socket/link repair: " .. leftEntry.slotName .. " + " .. rightEntry.slotName)
						or ("Synthetic rare pair: " .. leftEntry.slotName .. " + " .. rightEntry.slotName),
					island = ((leftIndex + rightIndex - 2) % 4) + 1,
					gearVariant = {
						overrides = overrides,
						changedSlots = { leftEntry.slotName, rightEntry.slotName },
						items = { itemDescription(leftEntry), itemDescription(rightEntry) },
						generatedItems = { leftEntry, rightEntry },
						socketBinding = socketBinding,
						syntheticSearch = true,
						syntheticPair = true,
					},
				}
			end
		end
		if coverage.pairInspectionLimitReached then break end
	end

	-- A small, deterministic three-slot portfolio helps fill builds that start
	-- without equipment. It is a complete loadout candidate, not a factorial
	-- claim about three-way causality; the full result is still calculated by
	-- PoB. Keep this quota separate so triples cannot consume every single/pair
	-- proposal and cap combination inspection before exact calculation.
	local tripleQuota = limit >= 3 and math.min(math.max(0, limit - pairQuota - 1),
		math.max(1, math.floor(limit * 0.20))) or 0
	local tripleCandidates = { }
	coverage.tripleCandidateLimit = tripleQuota
	coverage.tripleInspectionLimit = math.min(2048, math.max(64, limit * 32))
	if tripleQuota > 0 then
		local function describeEntry(entry)
			return {
				slot = entry.slotName, itemId = entry.tempId, name = entry.name,
				rarity = entry.item and entry.item.rarity or "RARE",
				synthetic = entry.kind == nil, socketRepair = entry.kind == "socket_repair" or nil,
				baseName = entry.baseName,
				itemLevel = entry.itemLevel, affixCount = entry.affixCount, modIds = entry.modIds,
				rollProfileId = entry.rollProfileId, rollFraction = entry.rollFraction, rollLabel = entry.rollLabel,
				socketPlan = entry.socketPlan,
			}
		end
		local function makeTriple(left, middle, right)
			local singles = { left, middle, right }
			local overrides, items, entries, slots = { }, { }, { }, { }
			local socketBinding, containsSocketRepair = nil, false
			for _, proposal in ipairs(singles) do
				local variant = proposal.gearVariant
				local entry = variant and variant.generatedItems and variant.generatedItems[1]
				if not entry or overrides[entry.slotName] then return nil end
				overrides[entry.slotName] = entry.tempId
				items[#items + 1] = describeEntry(entry)
				entries[#entries + 1] = entry
				slots[#slots + 1] = entry.slotName
				if entry.kind == "socket_repair" then containsSocketRepair = true end
				if variant.socketBinding then
					if socketBinding then return nil end
					socketBinding = shallowCopy(variant.socketBinding)
				end
			end
			if requireSocketedTarget and not socketBinding then return nil end
			return {
				label = containsSocketRepair
					and ("Equipment combination + socket/link repair: " .. table.concat(slots, " + "))
					or ("Synthetic rare triple: " .. table.concat(slots, " + ")),
				island = ((#tripleCandidates) % 4) + 1,
				gearVariant = {
					overrides = overrides,
					changedSlots = shallowCopy(slots),
					items = items,
					generatedItems = entries,
					socketBinding = socketBinding,
					syntheticSearch = true,
					syntheticTriple = true,
				},
			}
		end
		for leftIndex = 1, #singleCandidates - 2 do
			if #tripleCandidates >= tripleQuota then break end
			for middleIndex = leftIndex + 1, #singleCandidates - 1 do
				if #tripleCandidates >= tripleQuota then break end
				for rightIndex = middleIndex + 1, #singleCandidates do
					if #tripleCandidates >= tripleQuota then break end
					if coverage.tripleCombinationInspections >= coverage.tripleInspectionLimit then
						coverage.tripleInspectionLimitReached = true
						break
					end
					coverage.tripleCombinationInspections = coverage.tripleCombinationInspections + 1
					local triple = makeTriple(singleCandidates[leftIndex], singleCandidates[middleIndex], singleCandidates[rightIndex])
					if triple then tripleCandidates[#tripleCandidates + 1] = triple end
				end
				if coverage.tripleInspectionLimitReached then break end
			end
			if coverage.tripleInspectionLimitReached then break end
		end
	end

	local outputSingles = { }
	for _, proposal in ipairs(singleCandidates) do
		if not requireSocketedTarget or proposal.gearVariant.socketBinding then
			outputSingles[#outputSingles + 1] = proposal
		end
	end
	local selectedPairCount = math.min(pairQuota, #pairCandidates)
	local selectedTripleCount = math.min(tripleQuota, #tripleCandidates)
	local pairIndex, tripleIndex, singleIndex = 1, 1, 1
	while #candidates < limit do
		local progressed = false
		if tripleIndex <= selectedTripleCount then
			candidates[#candidates + 1] = tripleCandidates[tripleIndex]
			tripleIndex = tripleIndex + 1
			progressed = true
		end
		if pairIndex <= selectedPairCount then
			candidates[#candidates + 1] = pairCandidates[pairIndex]
			pairIndex = pairIndex + 1
			progressed = true
		end
		if #candidates < limit and outputSingles[singleIndex] then
			candidates[#candidates + 1] = outputSingles[singleIndex]
			singleIndex = singleIndex + 1
			progressed = true
		end
		if not progressed then break end
	end
	for _, proposal in ipairs(candidates) do
		local generatedItems = proposal.gearVariant and proposal.gearVariant.generatedItems or { }
		if proposal.gearVariant and proposal.gearVariant.socketBinding then
			coverage.socketBoundCandidates = coverage.socketBoundCandidates + 1
		end
		if #generatedItems == 1 then
			coverage.generatedSingleCandidates = coverage.generatedSingleCandidates + 1
		elseif #generatedItems == 2 and proposal.gearVariant.syntheticPair then
			coverage.generatedPairedCandidates = coverage.generatedPairedCandidates + 1
		elseif #generatedItems == 3 and proposal.gearVariant.syntheticTriple then
			coverage.generatedTripleCandidates = coverage.generatedTripleCandidates + 1
		end
		local allFourAffix = #generatedItems > 0
		for _, entry in ipairs(generatedItems) do
			if entry.affixCount ~= 4 then allFourAffix = false break end
		end
		if allFourAffix then coverage.generatedFourAffixCandidates = coverage.generatedFourAffixCandidates + 1 end
	end
	coverage.generatedCandidates = #candidates
	return candidates, coverage
end

function syntheticGear.InstallIntoItemsTab(itemsTab, generatedItems)
	local remap, reservedIds = { }, { }
	local maxId = 0
	for itemId in pairs(itemsTab.items or { }) do
		local numericId = tonumber(itemId)
		if numericId and numericId >= 1 and numericId == math.floor(numericId) and numericId > maxId then maxId = numericId end
	end
	for _, entry in ipairs(generatedItems or { }) do
		local item = entry.item
		if not item or type(entry.tempId) ~= "number"
			or entry.tempId < 1 or entry.tempId ~= math.floor(entry.tempId) then
			return false, "A generated equipment candidate has invalid native item data"
		end
		local itemId = entry.tempId
		if itemsTab.items[itemId] or itemsTab.items[tostring(itemId)] or reservedIds[itemId] then
			itemId = maxId + 1
			while itemsTab.items[itemId] or itemsTab.items[tostring(itemId)] or reservedIds[itemId] do itemId = itemId + 1 end
			remap[entry.tempId] = itemId
			maxId = itemId
		end
		local copy = new("Item"):Item(item.raw)
		if entry.kind == "catalyst" then
			if not item.optimizerCatalyst or not copy.base
				or not ({ Amulet = true, Ring = true, Belt = true })[copy.base.type]
				or (entry.catalystId ~= 6 and entry.catalystId ~= 8)
				or copy.catalyst ~= entry.catalystId or copy.catalystQuality ~= 20
				or item.corrupted or type(entry.sourceItemId) ~= "number" or entry.sourceItemId < 1 then
				return false, "Path of Building could not reconstruct a legal 20% Catalyst jewelry candidate"
			end
			copy.optimizerCatalyst = true
			copy.optimizerCatalystId = entry.catalystId
			copy.optimizerCatalystQuality = 20
			copy.optimizerCatalystSourceItemId = entry.sourceItemId
		elseif entry.kind == "socket_repair" then
			if not item.optimizerSocketRepair or not isSocketRepairCopy(copy, entry)
				or not SkillCatalog.SocketLayoutMatchesRepair(copy, entry.socketPlan) then
				return false, "Path of Building could not reconstruct the socket-only rework without changing the equipped item"
			end
			copy.optimizerSocketRepair = true
			copy.optimizerSocketRepairSourceItemId = entry.sourceItemId
		else
			if not item.optimizerSynthetic or not copy.base or copy.rarity ~= "RARE" then
				return false, "Path of Building could not reconstruct the generated rare item"
			end
			local prefixCount = countRealAffixes(copy.prefixes)
			local suffixCount = countRealAffixes(copy.suffixes)
			local affixCount = prefixCount + suffixCount
			if affixCount > 4 or prefixCount > 2 or suffixCount > 2 then
				return false, "Generated rare exceeds the strict two-prefix/two-suffix limit"
			end
			if entry.socketPlan then
				local socketPlan = entry.socketPlan
				if type(socketPlan.colors) ~= "table" or #copy.sockets ~= #socketPlan.colors
					or #copy.sockets > (tonumber(copy.base.socketLimit) or 0) then
					return false, "Generated rare no longer has the certified native Main Skill socket count"
				end
				for index, color in ipairs(socketPlan.colors) do
					local socket = copy.sockets[index]
					local linkGroup = socketPlan.linkGroups and socketPlan.linkGroups[index] or socketPlan.linkGroup
					if not socket or socket.color ~= color or socket.group ~= linkGroup then
						return false, "Generated rare no longer has the certified Main Skill socket colors and link"
					end
				end
			end
			copy.optimizerSynthetic = true
		end
		copy.id = itemId
		copy:BuildModList()
		itemsTab.items[copy.id] = copy
		reservedIds[itemId] = true
	end
	return true, nil, remap
end

function syntheticGear.RemapVariantIds(gearVariant, remap)
	if type(gearVariant) ~= "table" or type(remap) ~= "table" or not next(remap) then return gearVariant end
	local result = shallowCopy(gearVariant)
	result.overrides = shallowCopy(gearVariant.overrides)
	for slotName, itemId in pairs(result.overrides) do result.overrides[slotName] = remap[itemId] or itemId end
	if type(gearVariant.socketBinding) == "table" then
		result.socketBinding = shallowCopy(gearVariant.socketBinding)
		result.socketBinding.itemId = remap[result.socketBinding.itemId] or result.socketBinding.itemId
	end
	if type(gearVariant.items) == "table" then
		result.items = { }
		for index, item in ipairs(gearVariant.items) do
			local copy = shallowCopy(item)
			copy.itemId = remap[copy.itemId] or copy.itemId
			result.items[index] = copy
		end
	end
	if type(gearVariant.generatedItems) == "table" then
		result.generatedItems = { }
		for index, item in ipairs(gearVariant.generatedItems) do
			local copy = shallowCopy(item)
			copy.tempId = remap[copy.tempId] or copy.tempId
			result.generatedItems[index] = copy
		end
	end
	return result
end

function syntheticGear.CreateValidationTab(itemsTab, generatedItems)
	local proxy = shallowCopy(itemsTab)
	setmetatable(proxy, getmetatable(itemsTab))
	proxy.items = shallowCopy(itemsTab.items)
	local ok, err, remap = syntheticGear.InstallIntoItemsTab(proxy, generatedItems)
	if not ok then return nil, err end
	return proxy, nil, remap
end

function syntheticGear.RefreshDescription(build, gearVariant)
	local generatedIds, ordinaryOverrides = { }, { }
	for _, entry in ipairs(gearVariant and gearVariant.generatedItems or { }) do generatedIds[entry.tempId] = true end
	for slotName, itemId in pairs(gearVariant and gearVariant.overrides or { }) do
		if not generatedIds[itemId] then ordinaryOverrides[slotName] = itemId end
	end
	local described = require("Modules.Optimizer.Equipment").DescribeOverrides(build, ordinaryOverrides)
	for _, entry in ipairs(gearVariant and gearVariant.generatedItems or { }) do
		described[#described + 1] = {
			slot = entry.slotName,
			itemId = entry.tempId,
			name = tostring(entry.name or entry.baseName or "Synthetic rare"):sub(1, 120),
			rarity = tostring(entry.item and entry.item.rarity or ""),
			synthetic = entry.kind == nil,
			socketRepair = entry.kind == "socket_repair" or nil,
			catalyst = entry.kind == "catalyst" and (entry.catalystName or "Catalyst") or nil,
			catalystId = entry.catalystId,
			catalystQuality = entry.catalystQuality,
			sourceItemId = entry.sourceItemId,
			baseName = entry.baseName,
			itemLevel = entry.itemLevel,
			affixCount = entry.affixCount,
			modIds = shallowCopy(entry.modIds),
			rollProfileId = entry.rollProfileId,
			rollFraction = entry.rollFraction,
			rollLabel = entry.rollLabel,
			socketCount = entry.socketPlan and #(entry.socketPlan.colors or { }) or #(entry.item and entry.item.sockets or { }),
			linkedSkill = entry.socketPlan and true or nil,
		}
	end
	gearVariant.items = described
	if gearVariant.socketBinding then
		gearVariant.socketBinding = shallowCopy(gearVariant.socketBinding)
	end
	return described
end

function syntheticGear.AddToItemsTab(itemsTab, generatedItems, overrides)
	local remap, addedIds = { }, { }
	for _, entry in ipairs(generatedItems or { }) do
		local source = entry.item
		local item = source and source.raw and new("Item"):Item(source.raw) or nil
		local validGeneratedItem = item and item.base
		if entry.kind == "catalyst" then
			validGeneratedItem = validGeneratedItem and source.optimizerCatalyst
				and ({ Amulet = true, Ring = true, Belt = true })[item.base.type]
				and (entry.catalystId == 6 or entry.catalystId == 8)
				and item.catalyst == entry.catalystId and item.catalystQuality == 20
				and not item.corrupted and type(entry.sourceItemId) == "number" and entry.sourceItemId > 0
		elseif entry.kind == "socket_repair" then
			validGeneratedItem = validGeneratedItem and source.optimizerSocketRepair
				and isSocketRepairCopy(item, entry)
				and SkillCatalog.SocketLayoutMatchesRepair(item, entry.socketPlan)
		else
			validGeneratedItem = validGeneratedItem and source.optimizerSynthetic and item.rarity == "RARE"
		end
		if not validGeneratedItem then
			for itemId in pairs(addedIds) do
				itemsTab.items[itemId] = nil
				for index = #(itemsTab.itemOrderList or { }), 1, -1 do
					if itemsTab.itemOrderList[index] == itemId then table.remove(itemsTab.itemOrderList, index) end
				end
			end
			return nil, "Path of Building could not rebuild a generated item for application"
		end
		if entry.kind == "catalyst" then
			item.optimizerCatalyst = true
			item.optimizerCatalystId = entry.catalystId
			item.optimizerCatalystQuality = 20
			item.optimizerCatalystSourceItemId = entry.sourceItemId
		elseif entry.kind == "socket_repair" then
			item.optimizerSocketRepair = true
			item.optimizerSocketRepairSourceItemId = entry.sourceItemId
		else
			item.optimizerSynthetic = true
		end
		itemsTab:AddItem(item, true)
		remap[entry.tempId] = item.id
		addedIds[item.id] = true
	end
	local mapped = { }
	for slotName, itemId in pairs(overrides or { }) do mapped[slotName] = remap[itemId] or itemId end
	return mapped, addedIds
end

function syntheticGear.RemoveAddedItems(itemsTab, addedIds)
	for itemId in pairs(addedIds or { }) do
		itemsTab.items[itemId] = nil
		for index = #(itemsTab.itemOrderList or { }), 1, -1 do
			if itemsTab.itemOrderList[index] == itemId then table.remove(itemsTab.itemOrderList, index) end
		end
	end
	if itemsTab.PopulateSlots then itemsTab:PopulateSlots() end
	itemsTab.modFlag = true
end

return syntheticGear
