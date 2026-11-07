-- Path of Building
--
-- Module: deterministic, local adversarial reviewer for build-learning ideas.
-- This is a product runtime role, not an LLM. It reports profile observations
-- separately from exploratory hypotheses and never certifies build viability.

local critic = { }

local MAX_INDEPENDENT_HYPOTHESES = 16
local MAX_INDEPENDENT_PAGE_SIZE = 50

local function encodePageCursor(value)
	return (tostring(value or ""):gsub(".", function(character) return string.format("%02x", string.byte(character)) end))
end

local function decodePageCursor(value)
	if type(value) ~= "string" or value == "" or #value > 4096 or #value % 2 ~= 0 or value:find("[^%x]") then return nil end
	return (value:gsub("(%x%x)", function(byte) return string.char(tonumber(byte, 16)) end))
end
local GENERIC_TAGS = {
	active_skill = true, grants_active_skill = true, skill = true, support = true,
	vaal = true, gem = true, spell = true, attack = true,
}
local LOW_SIGNAL_TAGS = {
	aoe = true, aura = true, buff = true, curse = true, duration = true, guard = true,
	movement = true, reservation = true, stance = true, travel = true, warcry = true,
}

local function text(value, maximum)
	if value == nil then return "" end
	local result = tostring(value):gsub("[%c]", " "):gsub("^%s*(.-)%s*$", "%1")
	if maximum and #result > maximum then result = result:sub(1, maximum) end
	return result
end

local function sortedKeysCount(values)
	local count = 0
	for _ in pairs(values or { }) do count = count + 1 end
	return count
end

local function effectId(effect)
	if type(effect) ~= "table" then return "" end
	return text(effect.effectId or effect.id, 180)
end

local function effectIdentity(effect)
	return table.concat({ text(effect.gemId, 180), effectId(effect) }, "\31")
end

local function copyEffect(effect)
	return {
		effectId = effectId(effect),
		gemId = text(effect.gemId, 180),
		name = text(effect.name or effect.effectName, 120),
		gameId = text(effect.gameId, 180),
		variantId = text(effect.variantId, 180),
	}
end

local function findMainEffect(profile)
	for _, group in ipairs(profile.skillGroups or { }) do
		for _, skill in ipairs(group.skills or { }) do
			if skill.selectedMainSkill == true then
				for _, effect in ipairs(skill.effects or { }) do
					if effect.selected == true and effectId(effect) ~= "" then return effect end
				end
				for _, effect in ipairs(skill.effects or { }) do
					if effectId(effect) ~= "" then return effect end
				end
			end
		end
	end
	return nil
end

local function collectAnchorEffects(profile)
	local anchors, seen = { }, { }
	local function add(effect, selectedMain)
		if type(effect) ~= "table" or effectId(effect) == "" then return end
		local row = copyEffect(effect)
		if row.gemId == "" then return end
		row.selectedMain = selectedMain == true
		local key = effectIdentity(row)
		if seen[key] then
			if selectedMain then seen[key].selectedMain = true end
			return
		end
		seen[key] = row
		anchors[#anchors + 1] = row
	end
	for _, group in ipairs(profile.skillGroups or { }) do
		for _, skill in ipairs(group.skills or { }) do
			if skill.selectedMainSkill == true then
				local found = false
				for _, effect in ipairs(skill.effects or { }) do
					if effect.selected == true then add(effect, true); found = true end
				end
				if not found then
					for _, effect in ipairs(skill.effects or { }) do
						if effectId(effect) ~= "" then add(effect, true); break end
					end
				end
			end
		end
	end
	for _, effect in ipairs(profile.configuredSkillEffects or { }) do add(effect, false) end
	table.sort(anchors, function(left, right)
		if left.selectedMain ~= right.selectedMain then return left.selectedMain end
		if left.effectId ~= right.effectId then return left.effectId < right.effectId end
		if left.gemId ~= right.gemId then return left.gemId < right.gemId end
		if left.gameId ~= right.gameId then return left.gameId < right.gameId end
		return left.variantId < right.variantId
	end)
	return anchors
end

local function catalogByIdentity(catalogEffects)
	local byEffect, byIdentity = { }, { }
	for _, effect in ipairs(catalogEffects or { }) do
		local id = effectId(effect)
		if id ~= "" then
			byEffect[id] = byEffect[id] or effect
			byIdentity[effectIdentity(effect)] = effect
		end
	end
	return byEffect, byIdentity
end

local function findCatalogEffect(effect, byEffect, byIdentity)
	if type(effect) ~= "table" then return nil end
	return byIdentity[effectIdentity(effect)] or byEffect[effectId(effect)]
end

local function tagsFor(effect, catalogEffect)
	local raw = text((catalogEffect and (catalogEffect.tags or catalogEffect.tagString))
		or effect and (effect.tags or effect.tagString), 1000):lower()
	local tags = { }
	for tag in raw:gmatch("[%w_]+") do
		if not GENERIC_TAGS[tag] then tags[tag] = true end
	end
	return tags
end

local function sharedTagLists(left, right)
	local shared, signal = { }, { }
	for tag in pairs(left) do
		if right[tag] then
			shared[#shared + 1] = tag
			if not LOW_SIGNAL_TAGS[tag] then signal[#signal + 1] = tag end
		end
	end
	table.sort(shared)
	table.sort(signal)
	return shared, signal
end

local function tagFrequencies(catalogEffects)
	local frequency, count = { }, 0
	for _, effect in ipairs(catalogEffects or { }) do
		count = count + 1
		for tag in pairs(tagsFor(effect, effect)) do frequency[tag] = (frequency[tag] or 0) + 1 end
	end
	return frequency, count
end

local function relevanceScore(signalTags, frequency, effectCount, selectedMainAnchor)
	local score = 0
	for _, tag in ipairs(signalTags) do
		score = score + math.log((effectCount + 1) / ((frequency[tag] or 0) + 1))
	end
	if selectedMainAnchor then score = score + 100 end
	return math.floor(score * 1000 + 0.5) / 1000
end

local function stableHash(value)
	local hash = 17
	value = tostring(value or "")
	for index = 1, #value do hash = (hash * 131 + value:byte(index)) % 2147483647 end
	return hash
end

local function contextSeed(profile)
	local parts = { }
	local character = profile and profile.character or { }
	parts[#parts + 1] = text(character.classId or character.class, 64)
	parts[#parts + 1] = text(character.ascendancyId or character.ascendancy, 80)
	parts[#parts + 1] = tostring(tonumber(character.level) or 0)
	local configured = { }
	for _, effect in ipairs(profile and profile.configuredSkillEffects or { }) do
		configured[#configured + 1] = effectIdentity(effect)
	end
	table.sort(configured)
	for _, identity in ipairs(configured) do parts[#parts + 1] = identity end
	local supports = { }
	for _, gemId in ipairs(profile and profile.supportGemIds or { }) do supports[#supports + 1] = text(gemId, 180) end
	table.sort(supports)
	for _, gemId in ipairs(supports) do parts[#parts + 1] = gemId end
	local items = { }
	for _, item in ipairs(profile and profile.itemSlots or { }) do
		items[#items + 1] = table.concat({ text(item.slot, 48), text(item.base, 100), text(item.name, 100) }, "\31")
	end
	table.sort(items)
	for _, item in ipairs(items) do parts[#parts + 1] = item end
	return stableHash(table.concat(parts, "\30"))
end

local function diversityRank(seed, anchor, effect)
	return stableHash(tostring(seed) .. "\30" .. effectIdentity(anchor) .. "\30" .. effectIdentity(effect))
end

local function candidateLess(left, right)
	if left.relevanceScore ~= right.relevanceScore then return left.relevanceScore > right.relevanceScore end
	if left.overlap ~= right.overlap then return left.overlap > right.overlap end
	if effectId(left.anchor) ~= effectId(right.anchor) then return effectId(left.anchor) < effectId(right.anchor) end
	if left.diversityRank ~= right.diversityRank then return (left.diversityRank or 0) < (right.diversityRank or 0) end
	if effectId(left.effect) ~= effectId(right.effect) then return effectId(left.effect) < effectId(right.effect) end
	return text(left.effect.gemId, 180) < text(right.effect.gemId, 180)
end

local function insertFrontier(target, row, limit)
	target[#target + 1] = row
	if #target > limit * 2 then
		table.sort(target, candidateLess)
		for index = #target, limit + 1, -1 do target[index] = nil end
	end
end

local function pairKey(left, right)
	local a, b = effectIdentity(left), effectIdentity(right)
	if a == "\31" or b == "\31" then return "" end
	if b < a then a, b = b, a end
	return a .. "\30" .. b
end

local function markKnownPair(knownPairs, seen)
	local function add(left, right)
		if type(left) == "table" and type(right) == "table" then
			local key = pairKey(left, right)
			if key ~= "" then seen[key] = true end
		end
	end
	for _, pair in ipairs(knownPairs or { }) do
		if type(pair) == "table" then
			local left = pair.effectA or pair.factorA or pair.left or pair.before
			local right = pair.effectB or pair.factorB or pair.right or pair.after
			if type(left) ~= "table" and pair.sourceEffectId then
				left = { effectId = pair.sourceEffectId, gemId = pair.sourceGemId }
			end
			if type(right) ~= "table" and pair.effectId then
				right = { effectId = pair.effectId, gemId = pair.gemId }
			end
			add(left, right)
		end
	end
end

local function selectedEffectRows(profile)
	local rows, seen = { }, { }
	for _, effect in ipairs(profile.configuredSkillEffects or { }) do
		local id = effectId(effect)
		if id ~= "" then
			local identity = effectIdentity(effect)
			if not seen[identity] then
				seen[identity] = true
				rows[#rows + 1] = copyEffect(effect)
			end
		end
	end
	table.sort(rows, function(a, b)
			if a.effectId ~= b.effectId then return a.effectId < b.effectId end
			return a.gemId < b.gemId
		end)
	return rows
end

local function snapshotSetupContext(profile)
	local mainGroup, mainSkill
	for _, group in ipairs(profile.skillGroups or { }) do
		for _, skill in ipairs(group.skills or { }) do
			if skill.selectedMainSkill == true then mainGroup, mainSkill = group, skill; break end
		end
		if mainGroup then break end
	end
	local supports, items = { }, { }
	if mainGroup then
		for _, gem in ipairs(mainGroup.gems or { }) do
			if gem.isSupport == true and gem.enabled ~= false and text(gem.name, 100) ~= "" then
				supports[#supports + 1] = text(gem.name, 100)
			end
		end
	end
	table.sort(supports)
	local occupiedSlots = #(profile.itemSlots or { })
	for _, item in ipairs(profile.itemSlots or { }) do
		local slot = text(item.slot, 48)
		local normalizedSlot = slot:lower()
		if normalizedSlot:find("weapon", 1, true) or normalizedSlot == "body armour" or normalizedSlot == "amulet" then
			local label = text(item.name, 72)
			local base = text(item.base, 72)
			if slot ~= "" and (label ~= "" or base ~= "") then
				items[#items + 1] = slot .. ": " .. (label ~= "" and label or base)
			end
		end
	end
	table.sort(items)
	local skillName = "main group not identified"
	if mainSkill then
		for _, effect in ipairs(mainSkill.effects or { }) do
			if effect.selected == true then skillName = text(effect.name or effect.effectId, 100); break end
		end
	end
	return { mainGroupIndex = mainGroup and tonumber(mainGroup.groupIndex), mainSkill = skillName,
		supports = supports, items = items, occupiedSlots = occupiedSlots }
end

local function contextSummary(profile)
	local context = snapshotSetupContext(profile)
	local setup = context.mainSkill
	if #context.supports > 0 then setup = setup .. " com " .. table.concat(context.supports, ", ") end
	local gear = (context.occupiedSlots > 0 and tostring(context.occupiedSlots) .. " slots registados; " or "")
		.. (#context.items > 0 and table.concat(context.items, "; ") or "armas não identificadas")
	return setup, gear
end

local function candidateWeaponContext(profile, candidateTags)
	local weaponHints = {
		bow = { "bow" }, staff = { "staff", "stave" }, sword = { "sword" }, axe = { "axe" },
		mace = { "mace" }, claw = { "claw" }, dagger = { "dagger" }, wand = { "wand" },
		sceptre = { "sceptre", "scepter" }, spear = { "spear" },
	}
	local observed = { }
	for _, item in ipairs(profile.itemSlots or { }) do
		local slot = text(item.slot, 48):lower()
		if slot:find("weapon", 1, true) then
			local identity = (text(item.name, 100) .. " " .. text(item.base, 100)):lower()
			for weapon, hints in pairs(weaponHints) do
				for _, hint in ipairs(hints) do
					if identity:find(hint, 1, true) then observed[weapon] = true end
				end
			end
		end
	end
	for weapon in pairs(weaponHints) do
		if candidateTags[weapon] and not observed[weapon] then return weapon end
	end
	return nil
end

local function observedFacts(profile, mainEffect)
	local configured = selectedEffectRows(profile)
	local enabledGroups, selectedSkillCount = 0, 0
	for _, group in ipairs(profile.skillGroups or { }) do
		if group.enabled ~= false and group.slotEnabled ~= false then enabledGroups = enabledGroups + 1 end
		for _, skill in ipairs(group.skills or { }) do
			for _, effect in ipairs(skill.effects or { }) do
				if effect.selected == true then selectedSkillCount = selectedSkillCount + 1; break end
			end
		end
	end
	local mainCopy = mainEffect and copyEffect(mainEffect) or nil
	local setup, gear = contextSummary(profile)
	local facts = {
		{
			id = "observed:configured-skill-effects",
			kind = "configured_skill_effects",
			value = configured,
			count = #configured,
			evidence = "archived_build_profile",
			status = "observed_snapshot",
		},
		{
			id = "observed:enabled-skill-groups",
			kind = "enabled_skill_groups",
			value = enabledGroups,
			evidence = "archived_build_profile",
			status = "observed_snapshot",
		},
		{
			id = "observed:selected-skill-count",
			kind = "selected_effect_count_by_groups",
			value = selectedSkillCount,
			evidence = "archived_build_profile",
			status = "observed_snapshot",
		},
		{
			id = "observed:support-gem-count",
			kind = "configured_support_gem_count",
			value = #(profile.supportGemIds or { }),
			evidence = "archived_build_profile",
			status = "observed_snapshot",
		},
		{
			id = "observed:allocated-node-count",
			kind = "allocated_passive_node_count",
			value = #(profile.allocatedNodeIds or { }),
			evidence = "archived_build_profile",
			status = "observed_snapshot",
		},
		{
			id = "observed:item-slot-count",
			kind = "configured_item_slot_count",
			value = #(profile.itemSlots or { }),
			evidence = "archived_build_profile",
			status = "observed_snapshot",
		},
		{
			id = "observed:main-link-context",
			kind = "main_skill_and_support_setup",
			detail = setup,
			value = setup,
			evidence = "archived_skill_group_and_support_gems",
			status = "observed_snapshot",
		},
		{
			id = "observed:item-shell",
			kind = "item_slot_context",
			detail = gear,
			value = gear,
			evidence = "archived_item_slot_names_and_bases",
			status = "observed_snapshot",
		},
	}
	if mainCopy then
		facts[#facts + 1] = {
			id = "observed:selected-main-skill",
			kind = "selected_main_skill_effect",
			value = mainCopy,
			evidence = "archived_build_profile",
			status = "observed_snapshot",
		}
	end
	if type(profile.character) == "table" then
		if profile.character.class then
			facts[#facts + 1] = { id = "observed:class", kind = "character_class", value = text(profile.character.class, 64),
				evidence = "archived_build_profile", status = "observed_snapshot" }
		end
		if profile.character.ascendancy then
			facts[#facts + 1] = { id = "observed:ascendancy", kind = "character_ascendancy", value = text(profile.character.ascendancy, 80),
				evidence = "archived_build_profile", status = "observed_snapshot" }
		end
		if tonumber(profile.character.level) then
			facts[#facts + 1] = { id = "observed:level", kind = "character_level", value = tonumber(profile.character.level),
				evidence = "archived_build_profile", status = "observed_snapshot" }
		end
	end
	return facts
end

local function independentIdeas(profile, catalogEffects, knownPairs, pageOptions)
	local anchors = collectAnchorEffects(profile)
	if #anchors == 0 then return { }, 0, nil end
	local byEffect, byIdentity = catalogByIdentity(catalogEffects)
	local tagFrequency, catalogCount = tagFrequencies(catalogEffects)
	local seed = contextSeed(profile)
	local known = { }
	markKnownPair(knownPairs, known)
	local observed = { }
	local configured = profile.configuredSkillEffects or { }
	for index = 1, #configured do
		for other = index + 1, #configured do
			local key = pairKey(configured[index], configured[other])
			if key ~= "" then observed[key] = true end
		end
	end
	local perAnchorLimit = math.max(1, math.ceil(MAX_INDEPENDENT_HYPOTHESES / #anchors))
	local buckets, seenPairs, allCandidateCount = { }, { }, 0
	local pageRows, pageCandidateAfterCount = { }, 0
	for anchorIndex, anchor in ipairs(anchors) do
		local anchorCatalog = findCatalogEffect(anchor, byEffect, byIdentity)
		local anchorTags = tagsFor(anchor, anchorCatalog)
		local bucket = { overlaps = { }, broadExploration = { } }
		buckets[anchorIndex] = bucket
		local unique = { }
		for _, candidate in ipairs(catalogEffects or { }) do
			local candidateId = effectId(candidate)
			local candidateIdentity = effectIdentity(candidate)
			if candidateId ~= "" and candidateIdentity ~= effectIdentity(anchor)
				and candidate.gemId ~= anchor.gemId
				and (text(anchor.gameId, 180) == "" or text(candidate.gameId, 180) == ""
					or text(candidate.gameId, 180) ~= text(anchor.gameId, 180))
				and not unique[candidateIdentity] then
				unique[candidateIdentity] = true
				local key = pairKey(anchor, candidate)
				if key ~= "" and not known[key] and not observed[key] and not seenPairs[key] then
					seenPairs[key] = true
					allCandidateCount = allCandidateCount + 1
					local candidateTags = tagsFor(candidate, candidate)
					local sharedTags, signalTags = sharedTagLists(anchorTags, candidateTags)
					local overlap = #signalTags
					local row = { effect = candidate, anchor = anchor, overlap = overlap, key = key,
						sharedTags = sharedTags, signalTags = signalTags,
						relevanceScore = relevanceScore(signalTags, tagFrequency, catalogCount, anchor.selectedMain),
						diversityRank = diversityRank(seed, anchor, candidate) }
					if pageOptions then
						if not pageOptions.cursor or row.key > pageOptions.cursor then
							pageCandidateAfterCount = pageCandidateAfterCount + 1
							pageRows[#pageRows + 1] = row
							if #pageRows > pageOptions.limit * 2 then
								table.sort(pageRows, function(a, b) return a.key < b.key end)
								for index = #pageRows, pageOptions.limit + 1, -1 do pageRows[index] = nil end
							end
						end
					else
						local target = overlap > 0 and bucket.overlaps or bucket.broadExploration
						insertFrontier(target, row, perAnchorLimit)
					end
				end
			end
		end
		table.sort(bucket.overlaps, function(a, b)
			return candidateLess(a, b)
		end)
		table.sort(bucket.broadExploration, function(a, b)
			return candidateLess(a, b)
		end)
	end
	local selected = { }
	if pageOptions then
		selected = pageRows
		table.sort(selected, function(a, b) return a.key < b.key end)
		for index = #selected, pageOptions.limit + 1, -1 do selected[index] = nil end
	else
		for depth = 1, perAnchorLimit do
			for anchorIndex = 1, #buckets do
				local bucket = buckets[anchorIndex]
				for _, category in ipairs({ "overlaps", "broadExploration" }) do
					local row = bucket[category][depth]
					if row and #selected < MAX_INDEPENDENT_HYPOTHESES then selected[#selected + 1] = row end
				end
			end
		end
	end
	local ideas = { }
	local setupContext, gearContext = contextSummary(profile)
	for index, row in ipairs(selected) do
		local candidate = row.effect
		local rationale
		if row.overlap > 0 then
			rationale = string.format("%sIndependent priority %.3f from higher-signal shared PoB tag(s) (%s); the archived main setup is %s and its item shell is %s. Tags do not prove compatibility or synergy.",
				row.anchor.selectedMain and "Selected main skill anchor. " or "Configured-skill anchor. ", row.relevanceScore,
				table.concat(row.signalTags, ", "), setupContext, gearContext)
		elseif #row.sharedTags > 0 then
			rationale = string.format("%sWeak-signal tag overlap (%s) is recorded as role context; context tie-break %.3f; the archived main setup is %s and its item shell is %s. No compatibility or synergy is implied.",
				row.anchor.selectedMain and "Selected main skill anchor. " or "Configured-skill anchor. ", table.concat(row.sharedTags, ", "),
				row.relevanceScore, setupContext, gearContext)
		else
			rationale = string.format("%sIndependent cross-tag exploration; context tie-break %.3f; the archived main setup is %s and its item shell is %s. No compatibility or synergy is implied.",
				row.anchor.selectedMain and "Selected main skill anchor. " or "Configured-skill anchor. ", row.relevanceScore,
				setupContext, gearContext)
		end
		ideas[#ideas + 1] = {
			id = "critic:interaction:" .. effectId(row.anchor) .. ":" .. effectId(candidate) .. ":" .. text(candidate.gemId, 180),
			kind = "cross_skill_interaction",
			authorRole = "adversarial_critic",
			effectA = copyEffect(row.anchor),
			effectB = copyEffect(candidate),
			ordinal = index,
			basis = row.overlap > 0 and "catalog_tag_overlap_exploration"
				or (#row.sharedTags > 0 and "weak_signal_tag_exploration" or "cross_tag_diversity_exploration"),
			sharedTags = row.sharedTags,
			signalTags = row.signalTags,
			rationale = rationale,
			status = "untested",
			evidenceStatus = "heuristic_only",
			pageCursor = pageOptions and row.key or nil,
			requiredTest = "exact_pob_factorial",
			testDesign = { "baseline", "effect_a_only", "effect_b_only", "effect_a_and_b" },
		}
	end
	local page = pageOptions and {
		limit = pageOptions.limit,
		hasMore = pageCandidateAfterCount > #selected,
		cursor = pageOptions.cursorToken,
		nextCursor = pageCandidateAfterCount > #selected and #selected > 0 and encodePageCursor(selected[#selected].key) or nil,
		remainingAfterCursor = pageCandidateAfterCount,
		ordering = "exact_factor_identity",
	} or nil
	return ideas, allCandidateCount, anchors, page
end

local function proposalsFrom(scoutProposal)
	if type(scoutProposal) ~= "table" then return { } end
	return scoutProposal.hypotheses or scoutProposal.proposals or scoutProposal.ideas or { }
end

local function pairReviewText(profile, factorA, factorB, proposal, byEffect, byIdentity)
	local leftCatalog = findCatalogEffect(factorA, byEffect, byIdentity)
	local rightCatalog = findCatalogEffect(factorB, byEffect, byIdentity)
	local leftTags, rightTags = tagsFor(factorA, leftCatalog), tagsFor(factorB, rightCatalog)
	local combinedTags = { }
	for tag in pairs(leftTags) do if rightTags[tag] then combinedTags[#combinedTags + 1] = tag end end
	table.sort(combinedTags)
	local allTags = { }
	for tag in pairs(leftTags) do allTags[tag] = true end
	for tag in pairs(rightTags) do allTags[tag] = true end
	local leftName = text(factorA and (factorA.name or factorA.effectId), 120)
	local rightName = text(factorB and (factorB.name or factorB.effectId), 120)
	local basis = text(proposal and proposal.reason and proposal.reason.method, 80)
	local setupContext, gearContext = contextSummary(profile)
	local possibleWeaponMismatch = candidateWeaponContext(profile, rightTags)
	local reason
	if possibleWeaponMismatch then
		reason = "A candidata tem a tag PoB '" .. possibleWeaponMismatch .. "', mas os itens deste snapshot não mostram essa arma (" .. gearContext
			.. "). É um alerta heurístico, não uma rejeição; confirme os requisitos da skill e teste com o mesmo item set."
	elseif allTags.minion then
		reason = "A etiqueta de minion não determina actor, escala ou cadência de reposição; o FullDPS e os grupos incluídos no PoB precisam ser verificados."
	elseif allTags.mine or allTags.trap or allTags.totem then
		reason = "Tags de mine/trap/totem não certificam colocação, acionamento nem uptime sustentado; a saída exacta pode ser só componente por uso."
	elseif allTags.movement or allTags.guard or allTags.aura or allTags.reservation then
		reason = "Uma skill utilitária pode contribuir para defesa ou reserva sem somar DPS; é preciso verificar payability e o objetivo correto."
	elseif #combinedTags > 0 then
		reason = "As tags partilhadas sugerem uma família mecânica comum, mas não provam links compatíveis, contribuição positiva nem uma interação causal."
	else
		reason = "A proposta é exploratória e sem tags partilhadas; pode representar papéis diferentes, mas slots, recursos e benefício ainda são desconhecidos."
	end
	local signal = basis == "shared_catalog_tags" and "sobreposição de tags" or "exploração de cruzamento"
	local challenge = string.format("A sugeriu %s + %s por %s. O setup principal arquivado é %s. %s coocorrência e tags não demonstram sinergia. Compare os quatro estados com o mesmo engine, cenário, árvore, itens e links.",
		leftName, rightName, signal, setupContext, reason)
	local metricQuestion
	local metricScope
	if allTags.minion then
		metricQuestion = "Qual actor e componente nativo de minion será medido, e o FullDPS inclui ambos os grupos?"
		metricScope = "minion_components"
	elseif possibleWeaponMismatch then
		metricQuestion = "A skill é elegível com a arma arquivada? O teste mantém o mesmo item set ou exige novo shell com árvore e equipamento recalculados?"
		metricScope = "weapon_compatibility_and_shell"
	elseif allTags.movement or allTags.guard or allTags.aura or allTags.reservation then
		metricQuestion = "O objetivo desta candidata é utilidade/defesa ou dano? Qual output exacto e qual recurso/reserva definem sucesso?"
		metricScope = "utility_resources"
	else
		metricQuestion = "O sucesso significa melhorar a skill A, somar um grupo FullDPS incluído ou revelar uma interação? Qual chave de output do PoB decide?"
		metricScope = "primary_or_full_dps"
	end
	local question = string.format("Para %s + %s: %s Itens arquivados: %s. Confirme grupos/socket links legais e custos pagáveis no mesmo cenário.",
		leftName, rightName, metricQuestion, gearContext)
	local reviewBasis = possibleWeaponMismatch and "possible_weapon_context_mismatch"
		or (#combinedTags > 0 and "shared_tags_unverified" or "exploratory_pair_unverified")
	return challenge, question, reviewBasis, metricScope
end

local function critiqueProposals(proposals, catalogEffects, profile)
	local critiques, questions = { }, { }
	local byEffect, byIdentity = catalogByIdentity(catalogEffects)
	for index, proposal in ipairs(proposals) do
		if type(proposal) == "table" then
			local proposalId = text(proposal.id, 512)
			if proposalId == "" then proposalId = "scout:proposal:" .. tostring(index) end
			local factorA = proposal.effectA or proposal.factorA or proposal.skillA
			local factorB = proposal.effectB or proposal.factorB or proposal.skillB
			local identity = factorA and effectId(factorA) or "unknown"
			local other = factorB and effectId(factorB) or "unknown"
			local challengeText, questionText, reviewBasis, metricScope = pairReviewText(profile, factorA, factorB, proposal, byEffect, byIdentity)
			local critique = {
				-- Keep the local discussion identifier short enough for Scout's
				-- response validator. The full proposal ID remains in proposalId.
				id = "critic:challenge:" .. tostring(index),
				proposalId = proposalId,
				challenge = challengeText,
				reason = reviewBasis,
				observedEffectIds = { identity, other },
				status = "untested",
				requiredTest = "exact_pob_factorial",
				testDesign = { "baseline", "effect_a_only", "effect_b_only", "effect_a_and_b" },
			}
			critiques[#critiques + 1] = critique
			questions[#questions + 1] = {
				id = "critic:question:" .. tostring(index),
				proposalId = proposalId,
				observedEffectIds = { identity, other },
				question = questionText,
				metricScope = metricScope,
				status = "unanswered",
			}
		end
	end
	return critiques, questions
end

function critic.Review(profile, catalogEffects, knownPairs, scoutProposal, options)
	if type(profile) ~= "table" then return nil, "A structural PoB build profile is required" end
	if type(catalogEffects) ~= "table" then return nil, "The loaded PoB active-skill catalog is required" end
	local pagination
	if options ~= nil then
		if type(options) ~= "table" then return nil, "Page options are invalid" end
		local limit = tonumber(options.limit) or 20
		local cursor = options.cursor
		if limit ~= math.floor(limit) or limit < 1 or limit > MAX_INDEPENDENT_PAGE_SIZE
			or cursor ~= nil and not decodePageCursor(cursor) then
			return nil, "Page size or cursor is invalid"
		end
		if options.skipIndependent ~= nil and type(options.skipIndependent) ~= "boolean" then return nil, "Page skip flag is invalid" end
		pagination = { limit = limit, cursor = cursor and decodePageCursor(cursor) or nil, cursorToken = cursor,
			skipIndependent = options.skipIndependent == true }
	end
	local independentHypotheses, candidateCount, anchors, page
	if pagination and pagination.skipIndependent then
		independentHypotheses, candidateCount, anchors, page = { }, 0, collectAnchorEffects(profile), {
			limit = pagination.limit, hasMore = false, cursor = pagination.cursorToken, nextCursor = nil,
			remainingAfterCursor = 0, ordering = "complete" }
	else
		independentHypotheses, candidateCount, anchors, page = independentIdeas(profile, catalogEffects, knownPairs, pagination)
	end
	local critiques, questions = critiqueProposals(proposalsFrom(scoutProposal), catalogEffects, profile)
	if not anchors or #anchors == 0 then
		questions[#questions + 1] = {
			id = "critic:question:main-skill",
			question = "Which configured active skill or enabled PoB socket group can anchor cross-skill exploration?",
			status = "unanswered",
		}
	end
	local facts = observedFacts(profile, findMainEffect(profile))
	return {
		schemaVersion = 1,
		role = "adversarial_critic",
		facts = facts,
		independentHypotheses = independentHypotheses,
		candidateCount = candidateCount,
		candidateCountStatus = #independentHypotheses < candidateCount and "catalog_exploration_sampled_for_review" or "all_current_candidates_reviewed",
		page = page,
		critiques = critiques,
		questions = questions,
		runtime = "deterministic_local_heuristic",
		claims = { exactCompatibility = false, exactSynergy = false, modelTrainingLabel = false },
	}
end

return critic
