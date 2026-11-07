-- Path of Building
--
-- Module: deterministic, local opportunity scout for archived build reviews.
-- Catalog co-occurrence and tag overlap only help select experiments; they do
-- not establish compatibility, performance, or synergy.

local scout = { }

local MAX_SKILL_GROUPS = 48
local MAX_SKILLS_PER_GROUP = 32
local MAX_EFFECTS_PER_SKILL = 64
local MAX_PROFILE_EFFECTS = 512
local MAX_CATALOG_EFFECTS = 2048
local MAX_KNOWN_PAIRS = 50000
local MAX_CRITIQUE_ITEMS = 4096
local MAX_SCOUT_PROPOSALS = 512
local MAX_SCOUT_PAGE_SIZE = 50
local MAX_TAG_BYTES = 4096
local LOW_SIGNAL_TAGS = {
	active_skill = true, grants_active_skill = true, skill = true, support = true,
	vaal = true, gem = true, spell = true, attack = true, aoe = true, duration = true,
	aura = true, buff = true, curse = true, guard = true, movement = true,
	reservation = true, stance = true, travel = true, warcry = true,
}

local function cleanId(value, maximum)
	if type(value) ~= "string" or value == "" or #value > (maximum or 200) or value:find("[%c]") then
		return nil
	end
	return value
end

local function cleanName(value, maximum)
	if type(value) ~= "string" or value == "" or #value > (maximum or 160) or value:find("[%c]") then return nil end
	return value
end

local function safeIndex(value, fallback)
	local number = tonumber(value)
	if type(number) ~= "number" or number ~= number or number < 1 or number > 1000000
		or number ~= math.floor(number) then return fallback end
	return number
end

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function arrayLength(value, maximum)
	if type(value) ~= "table" then return nil end
	local count, largest = 0, 0
	for key in pairs(value) do
		if type(key) == "number" then
			if key < 1 or key ~= math.floor(key) or key > maximum then return nil end
			count = count + 1
			if key > largest then largest = key end
		end
	end
	if count > maximum or count ~= largest then return nil end
	return count
end

local function escaped(value)
	return (tostring(value or ""):gsub("([^%w_%.%-])", function(character)
		return string.format("%%%02X", string.byte(character))
	end))
end

local function factorId(effect)
	return table.concat({ "skill", escaped(effect.gemId), escaped(effect.gameId),
		escaped(effect.variantId), escaped(effect.effectId) }, ":")
end

local function pairKey(left, right)
	if type(left) ~= "string" or left == "" or type(right) ~= "string" or right == "" or left == right then return nil end
	if left > right then left, right = right, left end
	return left .. "\31" .. right
end

local function factorPairKey(left, right)
	if type(left) ~= "string" or type(right) ~= "string" or left == "" or right == "" or left == right then return nil end
	if right < left then left, right = right, left end
	return left .. "\31" .. right
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
	parts[#parts + 1] = tostring(character.classId or character.class or "")
	parts[#parts + 1] = tostring(character.ascendancyId or character.ascendancy or "")
	parts[#parts + 1] = tostring(tonumber(character.level) or 0)
	local configured, supports, items = { }, { }, { }
	for _, effect in ipairs(profile and profile.configuredSkillEffects or { }) do
		if type(effect) == "table" then configured[#configured + 1] = factorId(effect) end
	end
	for _, gemId in ipairs(profile and profile.supportGemIds or { }) do supports[#supports + 1] = tostring(gemId) end
	for _, item in ipairs(profile and profile.itemSlots or { }) do
		items[#items + 1] = table.concat({ tostring(item.slot or ""), tostring(item.base or ""), tostring(item.name or "") }, "\31")
	end
	for _, group in ipairs({ configured, supports, items }) do
		table.sort(group)
		for _, value in ipairs(group) do parts[#parts + 1] = value end
	end
	return stableHash(table.concat(parts, "\30"))
end

local function diversityRank(seed, anchor, effect)
	return stableHash(tostring(seed) .. "\30" .. factorId(anchor) .. "\30" .. factorId(effect))
end

local function pairFromRow(row)
	if type(row) ~= "table" then return nil end
	local left = row.leftEffectId or row.effectIdA or row.anchorEffectId
	local right = row.rightEffectId or row.effectIdB or row.candidateEffectId
	if type(row.effectA) == "table" then left = left or row.effectA.effectId end
	if type(row.effectB) == "table" then right = right or row.effectB.effectId end
	if type(row.effects) == "table" then
		left = left or type(row.effects[1]) == "table" and row.effects[1].effectId
		right = right or type(row.effects[2]) == "table" and row.effects[2].effectId
	end
	return pairKey(cleanId(left, 180), cleanId(right, 180))
end

local function collectKnownPairs(knownPairs)
	local result, count = { }, 0
	if knownPairs == nil then return result, 0 end
	if type(knownPairs) ~= "table" then return nil, 0 end
	for key, value in pairs(knownPairs) do
		count = count + 1
		if count > MAX_KNOWN_PAIRS then return nil, count end
		local keyValue
		if type(key) == "number" then
			keyValue = pairFromRow(value)
		elseif value == true and type(key) == "string" then
			local boundary = key:find("\31", 1, true)
			if boundary then keyValue = pairKey(cleanId(key:sub(1, boundary - 1), 180), cleanId(key:sub(boundary + 1), 180)) end
		elseif type(value) == "table" then
			keyValue = pairFromRow(value)
		end
		if keyValue then result[keyValue] = true end
	end
	return result, count
end

local function mainEffect(profile)
	if type(profile) ~= "table" then return nil, "profile_missing" end
	local groupCount = arrayLength(profile.skillGroups, MAX_SKILL_GROUPS)
	if not groupCount then return nil, "skill_groups_invalid" end
	local candidates = { }
	for groupIndex = 1, groupCount do
		local group = profile.skillGroups[groupIndex]
		if type(group) == "table" then
			local skillCount = arrayLength(group.skills or { }, MAX_SKILLS_PER_GROUP)
			if not skillCount then return nil, "skills_invalid" end
			for skillIndex = 1, skillCount do
				local skill = group.skills[skillIndex]
				if type(skill) == "table" and skill.selectedMainSkill == true then
					local effectCount = arrayLength(skill.effects or { }, MAX_EFFECTS_PER_SKILL)
					if not effectCount then return nil, "selected_effects_invalid" end
					for effectIndex = 1, effectCount do
						local effect = skill.effects[effectIndex]
						if type(effect) == "table" and effect.selected == true then
							local effectId = cleanId(effect.effectId, 180)
							local gemId = cleanId(effect.gemId, 180)
							if effectId and gemId then
								candidates[#candidates + 1] = {
									effectId = effectId,
									gemId = gemId,
									gameId = cleanId(effect.gameId, 200) or "",
									variantId = cleanId(effect.variantId, 200) or "",
									name = cleanName(effect.name, 160) or effectId,
									groupIndex = safeIndex(group.groupIndex, groupIndex),
									skillIndex = safeIndex(skill.skillIndex, skillIndex),
									effectIndex = effectIndex,
								}
							end
						end
					end
				end
			end
		end
	end
	if #candidates == 0 then return nil, "selected_main_effect_missing" end
	table.sort(candidates, function(left, right)
		if left.groupIndex ~= right.groupIndex then return left.groupIndex < right.groupIndex end
		if left.skillIndex ~= right.skillIndex then return left.skillIndex < right.skillIndex end
		if left.effectId ~= right.effectId then return left.effectId < right.effectId end
		if left.gemId ~= right.gemId then return left.gemId < right.gemId end
		if left.gameId ~= right.gameId then return left.gameId < right.gameId end
		if left.variantId ~= right.variantId then return left.variantId < right.variantId end
		if left.effectIndex ~= right.effectIndex then return left.effectIndex < right.effectIndex end
		return left.name < right.name
	end)
	return candidates[1]
end

local function collectAnchors(profile)
	local main, mainStatus = mainEffect(profile)
	if not main and mainStatus ~= "selected_main_effect_missing" then return nil, mainStatus end
	local configured = profile and profile.configuredSkillEffects or { }
	local configuredCount = arrayLength(configured, MAX_PROFILE_EFFECTS)
	if not configuredCount then return nil, "configured_effects_invalid" end
	local anchors, seen = { }, { }
	local function add(effect, selectedMain)
		if type(effect) ~= "table" then return end
		local row = {
			effectId = cleanId(effect.effectId, 180),
			gemId = cleanId(effect.gemId, 180),
			gameId = cleanId(effect.gameId, 200) or "",
			variantId = cleanId(effect.variantId, 200) or "",
			name = cleanName(effect.name or effect.effectName, 160) or cleanId(effect.effectId, 180),
			selectedMain = selectedMain == true,
		}
		if not row.effectId or not row.gemId then return end
		local identity = table.concat({ row.gemId, row.effectId }, "\31")
		if seen[identity] then
			if selectedMain then seen[identity].selectedMain = true end
			return
		end
		seen[identity] = row
		anchors[#anchors + 1] = row
	end
	if main then add(main, true) end
	for index = 1, configuredCount do add(configured[index], false) end
	if #anchors == 0 then return nil, "configured_skill_effect_missing" end
	table.sort(anchors, function(left, right)
		if left.selectedMain ~= right.selectedMain then return left.selectedMain end
		if left.effectId ~= right.effectId then return left.effectId < right.effectId end
		if left.gemId ~= right.gemId then return left.gemId < right.gemId end
		if left.gameId ~= right.gameId then return left.gameId < right.gameId end
		return left.variantId < right.variantId
	end)
	return anchors, main and "selected_main_plus_configured_effects" or "configured_effects_without_selected_main"
end

local function profileEffectCount(profile)
	if type(profile) ~= "table" then return 0 end
	local count = arrayLength(profile.configuredSkillEffects or { }, MAX_PROFILE_EFFECTS)
	return count or 0
end

local function catalogRows(catalogEffects)
	local rows = catalogEffects
	if type(rows) == "table" and type(rows.effects) == "table" then rows = rows.effects end
	local count = arrayLength(rows, MAX_CATALOG_EFFECTS)
	if not count then return nil, "catalog_effects_invalid" end
	local normalized = { }
	for index = 1, count do
		local row = rows[index]
		if type(row) == "table" then
			local effectId = cleanId(row.effectId, 180)
			local gemId = cleanId(row.gemId, 180)
			if effectId and gemId then
				normalized[#normalized + 1] = {
					effectId = effectId,
					gemId = gemId,
					gameId = cleanId(row.gameId, 200) or "",
					variantId = cleanId(row.variantId, 200) or "",
					name = cleanName(row.effectName or row.name, 160) or effectId,
					tags = row.tags,
				}
			end
		end
	end
	table.sort(normalized, function(left, right)
		local leftId, rightId = factorId(left), factorId(right)
		if leftId ~= rightId then return leftId < rightId end
		if left.name:lower() ~= right.name:lower() then return left.name:lower() < right.name:lower() end
		return tostring(left.tags or "") < tostring(right.tags or "")
	end)
	local unique, seen = { }, { }
	for _, row in ipairs(normalized) do
		local id = factorId(row)
		if not seen[id] then seen[id] = true; unique[#unique + 1] = row end
	end
	return unique
end

local function tagSet(value)
	local result = { }
	if type(value) == "string" and #value <= MAX_TAG_BYTES then
		for token in value:gmatch("[%w_%-]+") do
			local normalized = token:lower()
			if normalized ~= "" then result[normalized] = true end
		end
	elseif type(value) == "table" then
		local count = arrayLength(value, 128)
		if count then
			for index = 1, count do
				local token = cleanName(value[index], 80)
				if token and token ~= "" then result[token:lower()] = true end
			end
		end
	end
	return result
end

local function sortedSharedTags(left, right)
	local shared = { }
	for tag in pairs(left) do if right[tag] then shared[#shared + 1] = tag end end
	table.sort(shared)
	return shared
end

local function signalTags(sharedTags)
	local result = { }
	for _, tag in ipairs(sharedTags) do if not LOW_SIGNAL_TAGS[tag] then result[#result + 1] = tag end end
	return result
end

local function catalogTagFrequencies(catalog)
	local frequency = { }
	for _, effect in ipairs(catalog) do
		for tag in pairs(tagSet(effect.tags)) do frequency[tag] = (frequency[tag] or 0) + 1 end
	end
	return frequency
end

local function tagRarity(tag, frequency, effectCount)
	local share = math.log((effectCount + 1) / ((frequency[tag] or 0) + 1))
	return share * (LOW_SIGNAL_TAGS[tag] and 0.15 or 1)
end

local function relevanceScore(sharedSignalTags, frequency, effectCount, selectedMainAnchor)
	local score = 0
	for _, tag in ipairs(sharedSignalTags) do score = score + tagRarity(tag, frequency, effectCount) end
	if selectedMainAnchor then score = score + 100 end
	return math.floor(score * 1000 + 0.5) / 1000
end

local function candidateLess(left, right)
	if left.relevanceScore ~= right.relevanceScore then return left.relevanceScore > right.relevanceScore end
	local leftTagCount = tonumber(left.signalTagCount) or #(left.reason and left.reason.signalTags or { })
	local rightTagCount = tonumber(right.signalTagCount) or #(right.reason and right.reason.signalTags or { })
	if leftTagCount ~= rightTagCount then return leftTagCount > rightTagCount end
	if left.diversityRank ~= right.diversityRank then return (left.diversityRank or 0) < (right.diversityRank or 0) end
	local leftAnchor = left.effectA and left.effectA.effectId or left.effectAEffectId or ""
	local rightAnchor = right.effectA and right.effectA.effectId or right.effectAEffectId or ""
	if leftAnchor ~= rightAnchor then return leftAnchor < rightAnchor end
	local leftName = left.effectB and tostring(left.effectB.name or ""):lower() or tostring(left.effectBName or "")
	local rightName = right.effectB and tostring(right.effectB.name or ""):lower() or tostring(right.effectBName or "")
	if leftName ~= rightName then return leftName < rightName end
	local leftEffect = left.effectB and left.effectB.effectId or left.effectBEffectId or ""
	local rightEffect = right.effectB and right.effectB.effectId or right.effectBEffectId or ""
	if leftEffect ~= rightEffect then return leftEffect < rightEffect end
	local leftGem = left.effectB and left.effectB.gemId or left.effectBGemId or ""
	local rightGem = right.effectB and right.effectB.gemId or right.effectBGemId or ""
	if leftGem ~= rightGem then return leftGem < rightGem end
	return left.id < right.id
end

local function pageCursor(candidate)
	return {
		relevanceScore = candidate.relevanceScore,
		signalTagCount = #(candidate.reason and candidate.reason.signalTags or { }),
		diversityRank = candidate.diversityRank,
		effectAEffectId = candidate.effectA and candidate.effectA.effectId or "",
		effectBName = candidate.effectB and tostring(candidate.effectB.name or ""):lower() or "",
		effectBEffectId = candidate.effectB and candidate.effectB.effectId or "",
		effectBGemId = candidate.effectB and candidate.effectB.gemId or "",
		id = candidate.id,
	}
end

local function normalizePageOptions(options)
	if options == nil then return nil end
	if type(options) ~= "table" then return nil, "page_options_invalid" end
	local limit = tonumber(options.limit)
	if not limit then limit = 20 end
	if limit ~= math.floor(limit) or limit < 1 or limit > MAX_SCOUT_PAGE_SIZE then return nil, "page_size_invalid" end
	local cursor = options.cursor
	if cursor ~= nil then
		if type(cursor) ~= "table" or not isFinite(tonumber(cursor.relevanceScore))
			or not isFinite(tonumber(cursor.diversityRank)) or not cleanId(cursor.id, 2048)
			or not cleanId(cursor.effectAEffectId, 180) or not cleanId(cursor.effectBEffectId, 180)
			or not cleanId(cursor.effectBGemId, 180) or type(cursor.effectBName) ~= "string"
			or #cursor.effectBName > 160 or cursor.effectBName:find("[%c]")
			or not isFinite(tonumber(cursor.signalTagCount)) or tonumber(cursor.signalTagCount) < 0
			or tonumber(cursor.signalTagCount) > 10000
			or tonumber(cursor.signalTagCount) ~= math.floor(tonumber(cursor.signalTagCount)) then
			return nil, "page_cursor_invalid"
		end
		cursor = {
			relevanceScore = tonumber(cursor.relevanceScore),
			signalTagCount = tonumber(cursor.signalTagCount),
			diversityRank = tonumber(cursor.diversityRank),
			effectAEffectId = cursor.effectAEffectId,
			effectBName = cursor.effectBName,
			effectBEffectId = cursor.effectBEffectId,
			effectBGemId = cursor.effectBGemId,
			id = cursor.id,
		}
	end
	return { limit = limit, cursor = cursor }
end

local function insertPageCandidate(target, candidate, limit)
	target[#target + 1] = candidate
	if #target > limit * 2 then
		table.sort(target, candidateLess)
		for index = #target, limit + 1, -1 do target[index] = nil end
	end
end

local function insertFrontier(target, candidate, limit)
	target[#target + 1] = candidate
	if #target > limit * 2 then
		table.sort(target, candidateLess)
		for index = #target, limit + 1, -1 do target[index] = nil end
	end
end

local function publicEffect(effect)
	return {
		effectId = effect.effectId,
		gemId = effect.gemId,
		gameId = effect.gameId,
		variantId = effect.variantId,
		name = effect.name,
	}
end

local function factsFor(profile, anchor, anchorStatus, pairCount, anchorCount)
	local configuredCount = profileEffectCount(profile)
	local mainFact = {
		id = "selected-main-skill",
		kind = "archive_observation",
		status = anchor and anchor.selectedMain and "observed" or "missing",
		evidence = "selected_effect_in_profile_snapshot",
	}
	if anchor and anchor.selectedMain then
		mainFact.effectId = anchor.effectId
		mainFact.gemId = anchor.gemId
		mainFact.variantId = anchor.variantId
		mainFact.gameId = anchor.gameId
		mainFact.name = anchor.name
	end
	return {
		{ id = "configured-effect-count", kind = "archive_observation", status = "observed",
			value = configuredCount, evidence = "profile_configured_skill_effects" },
		mainFact,
		{ id = "known-pair-count", kind = "archive_observation", status = "co_observed_unverified",
			value = pairCount or 0, evidence = "co_observation_is_not_synergy" },
		{ id = "exact-pob-conclusions", kind = "exact_pob_validation", status = "not_supplied",
			value = 0, evidence = "scout_has_no_exact_calculation_result" },
		{ id = "anchor-resolution", kind = "input_validation", status = anchor and anchor.selectedMain and "resolved" or (anchorStatus or "missing"),
			evidence = anchor and anchor.selectedMain and "selectedMainSkill_and_selected_effect" or "configured_skill_effects_fallback" },
		{ id = "exploration-anchor-count", kind = "archive_observation", status = "observed",
			value = tonumber(anchorCount) or 0, evidence = "configured_effects_used_as_exploration_anchors" },
	}
end

local function emptyResult(profile, anchor, anchorStatus, pairCount, inputStatus, anchorCount)
	local facts = factsFor(profile, anchor, anchorStatus, pairCount, anchorCount)
	if inputStatus then
		facts[#facts + 1] = { id = "scout-input", kind = "input_validation", status = inputStatus }
	end
	return { schemaVersion = 1, role = "opportunity_scout", facts = facts, hypotheses = { }, candidateCount = 0 }
end

function scout.Propose(profile, catalogEffects, knownPairs, options)
	local known, pairCount = collectKnownPairs(knownPairs)
	if not known then return emptyResult(profile, nil, "known_pairs_invalid", pairCount, "known_pairs_limit_or_shape_exceeded") end
	local pagination, paginationError = normalizePageOptions(options)
	if options ~= nil and not pagination then return emptyResult(profile, nil, "page_options_invalid", pairCount, paginationError) end
	if type(profile) ~= "table" then return emptyResult(nil, nil, "profile_missing", pairCount, "profile_invalid") end
	local anchors, anchorStatus = collectAnchors(profile)
	if not anchors then return emptyResult(profile, nil, anchorStatus, pairCount, "skill_exploration_anchors_unavailable") end
	local anchor = anchors[1]
	local catalog, catalogError = catalogRows(catalogEffects)
	if not catalog then return emptyResult(profile, anchor, anchorStatus, pairCount, catalogError, #anchors) end
	local tagFrequency = catalogTagFrequencies(catalog)
	local seed = contextSeed(profile)
	local configuredPairs = { }
	local configured = profile.configuredSkillEffects or { }
	for left = 1, #configured do
		for right = left + 1, #configured do
			local key = pairKey(configured[left].effectId, configured[right].effectId)
			if key then configuredPairs[key] = true end
		end
	end
	local perAnchorLimit = math.max(1, math.ceil(MAX_SCOUT_PROPOSALS / #anchors))
	local buckets, candidateCount, seenCandidates = { }, 0, { }
	local pageCandidates, pageCandidateAfterCount = { }, 0
	for anchorIndex, currentAnchor in ipairs(anchors) do
		local anchorTags, fallbackAnchorTags, fallbackFound = { }, { }, false
		for _, row in ipairs(catalog) do
			if row.effectId == currentAnchor.effectId and row.gemId == currentAnchor.gemId then
				local tags = tagSet(row.tags)
				if row.gemId == currentAnchor.gemId and row.variantId == currentAnchor.variantId then
					anchorTags = tags
					fallbackFound = true
					break
				elseif not fallbackFound then
					fallbackAnchorTags = tags
					fallbackFound = true
				end
			end
		end
		if not fallbackFound then anchorTags = fallbackAnchorTags end
		local bucket = { overlap = { }, exploratory = { } }
		buckets[anchorIndex] = bucket
		for _, row in ipairs(catalog) do
			-- The same PoB effect cannot be both factors, even through another gem record.
			if row.effectId ~= currentAnchor.effectId and row.gemId ~= currentAnchor.gemId
				and (currentAnchor.gameId == "" or row.gameId == "" or row.gameId ~= currentAnchor.gameId) then
				local identity = factorId(row)
				local pair = pairKey(currentAnchor.effectId, row.effectId)
				local factorPair = factorPairKey(factorId(currentAnchor), identity)
				if factorPair and not seenCandidates[factorPair] and not known[pair] and not configuredPairs[pair] then
					seenCandidates[factorPair] = true
					candidateCount = candidateCount + 1
					local candidateTags = tagSet(row.tags)
					local sharedTags = sortedSharedTags(anchorTags, candidateTags)
					local sharedSignalTags = signalTags(sharedTags)
					local score = relevanceScore(sharedSignalTags, tagFrequency, #catalog, currentAnchor.selectedMain)
					local reason
					if #sharedSignalTags > 0 then
						reason = { method = "shared_catalog_tags", sharedTags = sharedTags, signalTags = sharedSignalTags, relevanceScore = score,
							summary = string.format("%sPriority %.3f from higher-signal shared PoB tags (%s); compatibility and benefit remain unverified.",
								currentAnchor.selectedMain and "Selected main skill anchor. " or "Configured-skill anchor. ", score, table.concat(sharedSignalTags, ", ")) }
					elseif #sharedTags > 0 then
						reason = { method = "weak_signal_overlap", sharedTags = sharedTags, signalTags = { }, relevanceScore = score,
							summary = string.format("%sWeak-signal tag overlap (%s) is retained as role context; context tie-break %.3f; no compatibility or benefit is inferred.",
								currentAnchor.selectedMain and "Selected main skill anchor. " or "Configured-skill anchor. ", table.concat(sharedTags, ", "), score) }
					else
						reason = { method = "exploratory", sharedTags = { }, signalTags = { }, relevanceScore = score,
							summary = string.format("%sExploratory cross-skill candidate (context tie-break %.3f); no shared tags or verified synergy.",
								currentAnchor.selectedMain and "Selected main skill anchor. " or "Configured-skill anchor. ", score) }
					end
					local anchorFactorId, candidateFactorId = factorId(currentAnchor), identity
					local id = "skill-pair:" .. escaped(anchorFactorId) .. ":" .. escaped(candidateFactorId)
					local hypothesis = {
						id = id,
						status = "untested",
						effectA = publicEffect(currentAnchor),
						effectB = publicEffect(row),
						factorIds = { anchor = anchorFactorId, candidate = candidateFactorId },
						reason = reason,
						relevanceScore = score,
						diversityRank = diversityRank(seed, currentAnchor, row),
						requiredTest = { type = "exact_pob_factorial",
							cells = { "baseline", "factorA", "factorB", "combined" } },
					}
					if pagination then
						if not pagination.cursor or candidateLess(pagination.cursor, hypothesis) then
							pageCandidateAfterCount = pageCandidateAfterCount + 1
							insertPageCandidate(pageCandidates, hypothesis, pagination.limit)
						end
					else
						local target = #sharedSignalTags > 0 and bucket.overlap or bucket.exploratory
						insertFrontier(target, hypothesis, perAnchorLimit)
					end
				end
			end
		end
	end
	local hypotheses = { }
	if pagination then
		hypotheses = pageCandidates
		table.sort(hypotheses, candidateLess)
		for index = #hypotheses, pagination.limit + 1, -1 do hypotheses[index] = nil end
	else
		local maxDepth = math.max(perAnchorLimit, 0)
		for depth = 1, maxDepth do
			for anchorIndex = 1, #buckets do
				local bucket = buckets[anchorIndex]
				for _, category in ipairs({ "overlap", "exploratory" }) do
					local hypothesis = bucket[category][depth]
					if hypothesis and #hypotheses < MAX_SCOUT_PROPOSALS then hypotheses[#hypotheses + 1] = hypothesis end
				end
			end
		end
	end
	table.sort(hypotheses, candidateLess)
	local result = {
		schemaVersion = 1,
		role = "opportunity_scout",
		facts = factsFor(profile, anchor, anchorStatus, pairCount, #anchors),
		hypotheses = hypotheses,
		candidateCount = candidateCount,
		proposedCount = #hypotheses,
		candidateCountStatus = pagination and "complete_frontier_cursor_page"
			or (candidateCount > #hypotheses and "diverse_frontier_sampled" or "all_current_candidates_materialized"),
		unreviewedCandidateCount = math.max(0, candidateCount - #hypotheses),
	}
	if pagination then
		local hasMore = pageCandidateAfterCount > #hypotheses
		result.page = { limit = pagination.limit, hasMore = hasMore, cursor = pagination.cursor,
			nextCursor = hasMore and #hypotheses > 0 and pageCursor(hypotheses[#hypotheses]) or nil,
			remainingAfterCursor = pageCandidateAfterCount,
			ordering = "relevance_then_tag_signal_then_context_hash_then_identity" }
	end
	return result
end

function scout.ProposePage(profile, catalogEffects, knownPairs, cursor, limit)
	return scout.Propose(profile, catalogEffects, knownPairs, { cursor = cursor, limit = limit })
end

local function critiqueRows(critique)
	if type(critique) ~= "table" then return { } end
	local rows, seen, count = { }, { }, 0
	local sources = { }
	if type(critique.critiques) == "table" then sources[#sources + 1] = { kind = "challenge", rows = critique.critiques } end
	if type(critique.questions) == "table" then sources[#sources + 1] = { kind = "question", rows = critique.questions } end
	if cleanId(critique.id, 180) then sources[#sources + 1] = { kind = "challenge", rows = { critique } } end
	for _, source in ipairs(sources) do
		local length = arrayLength(source.rows or { }, MAX_CRITIQUE_ITEMS)
		if length then
			for index = 1, length do
				local row = source.rows[index]
				local id = type(row) == "table" and cleanId(row.id, 180) or nil
				if id and not seen[id] then
					count = count + 1
					if count > MAX_CRITIQUE_ITEMS then break end
					seen[id] = true
					rows[#rows + 1] = { id = id, kind = source.kind,
						proposalId = type(row.proposalId) == "string" and cleanId(row.proposalId, 220) or nil,
						reason = type(row.reason) == "string" and cleanId(row.reason, 100) or nil,
						metricScope = type(row.metricScope) == "string" and cleanId(row.metricScope, 100) or nil }
				end
			end
		end
	end
	table.sort(rows, function(left, right) return left.id < right.id end)
	return rows
end

function scout.Respond(profile, proposal, critique)
	local responses = { }
	for _, row in ipairs(critiqueRows(critique)) do
		local responseText
		if row.kind == "challenge" then
			responseText = row.reason == "possible_weapon_context_mismatch"
				and "A aceita o alerta de arma: manterá o item set como condição do teste; se a skill não for elegível, marcará essa célula como incompatível. Um chassis diferente exige outro teste com árvore, itens e custos recalculados."
				or row.reason == "shared_tags_unverified"
				and "A aceita que a sobreposição de tags é só uma pista. Primeiro verificará links/supports e os outputs exactos das quatro células; sem isso, não declara melhoria."
				or "A aceita que a ideia é exploratória. Primeiro verificará função da skill, links e custos nas quatro células; não atribui benefício por diferença de tags."
		elseif row.metricScope == "minion_components" then
			responseText = "A mantém aberta a escolha de actor e componente; só aceita FullDPS quando os grupos estão incluídos, sem inferir cadência de invocação ou reposição."
		elseif row.metricScope == "utility_resources" then
			responseText = "A separa utilidade/defesa de dano e propõe conferir reservas e payability exactas antes de incluir a skill numa combinação."
		else
			responseText = "A deixa o objetivo e a métrica por escolher. Comparará a saída nativa seleccionada com as quatro células e não somará grupos ausentes do FullDPS."
		end
		responses[#responses + 1] = {
			id = "scout-response:" .. escaped(row.id),
			targetId = row.id,
			proposalId = row.proposalId,
			status = "unverified",
			response = responseText,
			evidence = "no_exact_factorial_result",
			hypothesisStatus = "untested",
		}
	end
	return { role = "opportunity_scout", responses = responses }
end

return scout
