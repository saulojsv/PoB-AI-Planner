-- Path of Building
--
-- Module: Optimizer Validator
-- Strict hard-gate checks against unrounded output values from the PoB engine.
--
local t_insert = table.insert

local validator = { }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function validator.Check(inputs, metrics)
	local violations = { }
	local normalizedDeficit = 0
	for key, constraint in pairs(inputs.hard) do
		local metricKey = constraint.metricKey or key
		local value = metrics[metricKey]
		if not isFinite(value) then
			t_insert(violations, {
				key = key,
				label = constraint.label or key,
				required = constraint.value,
				actual = nil,
				deficit = math.huge,
				reason = type(value) == "number" and "Exact calculation returned a non-finite metric" or "Exact calculation did not provide this metric",
			})
			normalizedDeficit = math.huge
		elseif (constraint.operator == "<=" and value > constraint.value) or (constraint.operator ~= "<=" and value < constraint.value) then
			local deficit = constraint.operator == "<=" and value - constraint.value or constraint.value - value
			local scale = math.max(math.abs(constraint.value), 1)
			t_insert(violations, {
				key = key,
				label = constraint.label or key,
				required = constraint.value,
				actual = value,
				deficit = deficit,
				reason = constraint.operator == "<=" and "Above strict maximum" or "Below strict minimum",
			})
			normalizedDeficit = normalizedDeficit + deficit / scale
		end
	end
	return {
		feasible = #violations == 0,
		violations = violations,
		normalizedDeficit = normalizedDeficit,
	}
end

-- Consume requirements resolved by PoB, including requirement modifiers,
-- Omniscience, and IgnoreAttributeRequirements. Never rebuild gem/item stat
-- formulae in the optimizer: the native Req* outputs are the authority.
function validator.CheckRequirements(output, characterLevel)
	output = output or { }
	local violations, normalizedDeficit = { }, 0
	local function check(key, label, actual, required, source)
		if not isFinite(required) or (required > 0 and not isFinite(actual)) then
			violations[#violations + 1] = { key = key, label = label, reason = "PoB did not expose finite exact use requirements", deficit = math.huge }
			normalizedDeficit = math.huge
		elseif required > 0 and actual < required then
			local name = source and (source.sourceGem and source.sourceGem.nameSpec or source.sourceItem and source.sourceItem.name)
			violations[#violations + 1] = {
				key = key, label = label, actual = actual, required = required, deficit = required - actual,
				source = name, reason = "Below PoB's exact use requirement" .. (name and (" for " .. name) or ""),
			}
			normalizedDeficit = normalizedDeficit + (required - actual) / math.max(required, 1)
		end
	end
	check("level_requirement", "Character level requirement", characterLevel, output.ReqLevel, output.ReqLevelSource)
	for _, attr in ipairs({ "Str", "Dex", "Int", "Omni" }) do
		check("attribute_requirement_" .. attr, attr .. " requirement", output[attr], output["Req" .. attr] or 0, output["Req" .. attr .. "Item"])
	end
	return { feasible = #violations == 0, violations = violations, normalizedDeficit = normalizedDeficit }
end

function validator.CheckSkillEntityLimits(skillEntityLimits, truncated)
	local violations = { }
	local normalizedDeficit = 0
	if truncated then
		t_insert(violations, {
			key = "skill_entity_limit",
			label = "Summon count limit",
			reason = "Exact skill entity limit data was truncated; candidate cannot be certified",
			deficit = math.huge,
		})
		normalizedDeficit = math.huge
	end
	for _, entity in ipairs(skillEntityLimits or { }) do
		if entity.entityType == "totem" or entity.entityType == "ballista" or entity.entityType == "minion" then
			local label = entity.entityType == "ballista" and "Ballista count" or (entity.entityType == "minion" and "Minion count" or "Totem count")
			if not isFinite(entity.count) or not isFinite(entity.limit) then
				t_insert(violations, {
					key = "skill_entity_limit",
					label = label,
					actual = entity.count,
					required = entity.limit,
					reason = "PoB did not provide a finite configured count and skill cap",
					deficit = math.huge,
				})
				normalizedDeficit = math.huge
			elseif entity.count > entity.limit then
				local deficit = entity.count - entity.limit
				t_insert(violations, {
					key = "skill_entity_limit",
					label = label,
					actual = entity.count,
					required = entity.limit,
					deficit = deficit,
					reason = tostring(entity.name or "Active skill") .. " count exceeds its exact PoB limit",
				})
				normalizedDeficit = normalizedDeficit + deficit / math.max(entity.limit, 1)
			end
		end
	end
	return { feasible = #violations == 0, violations = violations, normalizedDeficit = normalizedDeficit }
end

-- PoB's normal build output checks whether the selected skill's upfront cost
-- fits the relevant unreserved pool (including EB and hybrid cost routing).
-- Reuse those engine-owned warnings instead of reimplementing resource costs.
function validator.CheckMainSkillPayability(output, mainSkillName)
	local warnings = { }
	if type(mainSkillName) ~= "string" or mainSkillName == "" then
		return {
			status = "unsupported",
			feasible = false,
			violations = { {
				key = "main_skill_payability",
				label = "Main Skill resource cost",
				reason = "PoB did not identify the selected Main Skill for its exact cost warning",
			} },
		}
	end
	output = output or { }
	local definitions = {
		{ flag = "ManaCostWarning", list = "ManaCostWarningList", resource = "mana" },
		{ flag = "LifeCostWarning", list = "LifeCostWarningList", resource = "life" },
		{ flag = "ESCostWarning", list = "ESCostWarningList", resource = "Energy Shield" },
		{ flag = "RageCostWarning", list = "RageCostWarningList", resource = "rage" },
		{ list = "ManaPercentCostWarningList", resource = "mana percentage" },
		{ list = "LifePercentCostWarningList", resource = "life percentage" },
	}
	for _, definition in ipairs(definitions) do
		local applies = output[definition.flag] == true
		for _, name in ipairs(output[definition.list] or { }) do
			if name == mainSkillName then applies = true break end
		end
		if applies then
			warnings[#warnings + 1] = {
				key = "main_skill_payability",
				label = "Main Skill resource cost",
				resource = definition.resource,
				skill = mainSkillName,
				reason = string.format("PoB warns that %s's upfront %s cost exceeds its payable pool", mainSkillName, definition.resource),
				deficit = 1,
			}
		end
	end
	return {
		status = #warnings == 0 and "pass" or "violated",
		feasible = #warnings == 0,
		violations = warnings,
	}
end

function validator.BetterDeficit(candidate, current)
	if not current then
		return true
	end
	if candidate.normalizedDeficit ~= current.normalizedDeficit then
		return candidate.normalizedDeficit < current.normalizedDeficit
	end
	return #candidate.violations < #current.violations
end

return validator
