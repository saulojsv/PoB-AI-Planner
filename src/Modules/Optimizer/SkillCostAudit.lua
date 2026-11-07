-- Path of Building
--
-- Module: bounded per-skill resource-cost audit from exact PoB output.
-- Rows are intentionally kept separate: alternative skills are not a combined
-- recurring-cost total unless a verified schedule explicitly models them.
local audit = { }
local calcs = require("Modules.CalcBase")

local MAX_SKILLS = 96
local MAX_SCHEDULE_SKILLS = 64

local damageCadenceKinds = {
	minion = true,
	totem = true,
	ballista = true,
	trap = true,
	mine = true,
	brand = true,
}

local resourceDefinitions = {
	{ key = "life", prefix = "Life", costKey = "LifeCost", pool = "LifeUnreserved", percentPool = "LifeUnreservedPercent", percentCostKey = "LifePercentCost", percentCostPrefix = "LifePercent" },
	{ key = "mana", prefix = "Mana", costKey = "ManaCost", pool = "ManaUnreserved", percentPool = "ManaUnreservedPercent", percentCostKey = "ManaPercentCost", percentCostPrefix = "ManaPercent" },
	{ key = "energyShield", prefix = "ES", costKey = "ESCost", pool = "EnergyShield", percentCostKey = "ESPercentCost", percentCostPrefix = "ESPercent" },
	{ key = "rage", prefix = "Rage", costKey = "RageCost", pool = "Rage" },
}

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function safeText(value, limit)
	local text = tostring(value or ""):gsub("[%c]", " ")
	if #text > limit then text = text:sub(1, limit) end
	return text
end

local function readValue(output, key, required)
	local value = output[key]
	if isFinite(value) then return value, true end
	if value ~= nil or required then return nil, false end
	return nil, true
end

local function copyViolations(violations)
	local result = { }
	for index, violation in ipairs(violations or { }) do
		if index > 16 then break end
		result[#result + 1] = {
			resource = safeText(violation.resource, 32),
			label = safeText(violation.label, 72),
			actual = isFinite(violation.actual) and violation.actual or nil,
			required = isFinite(violation.required) and violation.required or nil,
			deficit = isFinite(violation.deficit) and violation.deficit or nil,
			reason = safeText(violation.reason, 200),
		}
	end
	return result
end

local function buildResourceRows(poolOutput, skillOutput)
	local resources, exact = { }, true
	for _, definition in ipairs(resourceDefinitions) do
		local prefix = definition.prefix
		local flatHasCost = skillOutput[prefix .. "HasCost"] == true
		local percentHasCost = definition.percentCostPrefix and skillOutput[definition.percentCostPrefix .. "HasCost"] == true or false
		local upfront, upfrontExact = readValue(skillOutput, definition.costKey, flatHasCost)
		local upfrontPercent, percentExact = readValue(skillOutput, definition.percentCostKey or "", percentHasCost)
		local perSecond, rateExact = readValue(skillOutput, prefix .. "PerSecondCost", skillOutput[prefix .. "PerSecondHasCost"] == true)
		local perSecondPercent, percentRateExact = readValue(skillOutput, prefix .. "PercentPerSecondCost", skillOutput[prefix .. "PercentPerSecondHasCost"] == true)
		local observed = flatHasCost or percentHasCost
			or (upfront and upfront ~= 0) or (upfrontPercent and upfrontPercent ~= 0)
			or (perSecond and perSecond ~= 0) or skillOutput[prefix .. "PerSecondHasCost"] == true
			or (perSecondPercent and perSecondPercent ~= 0) or skillOutput[prefix .. "PercentPerSecondHasCost"] == true
		if observed then
			local pool = calcs.getSkillPayabilityPool(poolOutput, definition.costKey, definition.pool)
			resources[definition.key] = {
				upfront = upfront,
				upfrontPercent = upfrontPercent,
				perSecond = perSecond,
				perSecondPercent = perSecondPercent,
				availablePool = isFinite(pool) and pool or nil,
				availablePercent = definition.percentPool and isFinite(poolOutput[definition.percentPool]) and poolOutput[definition.percentPool] or nil,
				exact = upfrontExact and percentExact and rateExact and percentRateExact
					and ((upfront == nil or upfront <= 0) or isFinite(pool)),
			}
			if not (upfrontExact and percentExact and rateExact and percentRateExact
				and ((upfront == nil or upfront <= 0) or isFinite(pool))) then exact = false end
		end
	end
	return resources, exact
end

local function classifyPayability(violations, exactCosts)
	if not exactCosts then return "unsupported" end
	for _, violation in ipairs(violations) do
		if violation.actual == nil or violation.required == nil then return "unsupported" end
	end
	if #violations > 0 then return "violated" end
	return "pass"
end

local function buildScheduleActivity(source, row, identityValid)
	if type(source) ~= "table" or not identityValid then return nil end
	local kind = safeText(source.kind, 32)
	local unsupportedReason = source.unsupportedReason
	local damageUnsupportedReason
	if damageCadenceKinds[kind] then
		damageUnsupportedReason = unsupportedReason
		unsupportedReason = nil
	end
	return {
		identity = row.identity,
		name = row.name,
		group = row.group,
		skillPart = row.skillPart,
		count = row.count,
		kind = kind,
		hasDamage = source.hasDamage == true,
		costScheduleEligible = source.exact == true,
		exact = source.exact == true,
		triggerRate = isFinite(source.triggerRate) and source.triggerRate or nil,
		resources = type(source.resources) == "table" and source.resources or { },
		otherResourceCosts = type(source.otherResourceCosts) == "table" and source.otherResourceCosts or { },
		unsupportedReason = type(unsupportedReason) == "string" and safeText(unsupportedReason, 240) or nil,
		damageUnsupportedReason = type(damageUnsupportedReason) == "string" and safeText(damageUnsupportedReason, 240) or nil,
	}
end

function audit.Build(entries, disabledSkills, truncated, nonSocketedSkills)
	local result = {
		status = "not_required",
		exactPoBValues = true,
		aggregation = "per_skill_only",
		upfrontPayabilityStatus = "not_required",
		recurringStatus = "reported_schedule_available",
		scheduleNote = "Exact per-skill costs are reported separately. An explicit user schedule can estimate recurring resource sustain across enabled skills; it does not certify damage timing or uptime.",
		statusMeaning = "pass means exact cost rows and PoB upfront-payability checks are available; recurring sustain is only estimated after a complete explicit schedule.",
		totalEnabledSkills = 0,
		auditedSkills = 0,
		disabledSkills = tonumber(disabledSkills) or 0,
		nonSocketedSkills = tonumber(nonSocketedSkills) or 0,
		truncated = truncated == true,
		skills = { },
		scheduleActivities = { },
		scheduleTruncated = false,
		scheduleUnsupportedReason = nil,
		violations = { },
		unsupported = { },
	}
	local hasViolation, hasUnsupported = false, truncated == true
	for _, entry in ipairs(entries or { }) do
		result.totalEnabledSkills = result.totalEnabledSkills + 1
		if result.auditedSkills < MAX_SKILLS then
			local skill = entry.activeSkill or { }
			local effect = skill.activeEffect and skill.activeEffect.grantedEffect
			local name = safeText(effect and effect.name or entry.name or "Unknown skill", 96)
			local groupIndex, skillIndex = entry.groupIndex, entry.skillIndex
			local identityValid = type(groupIndex) == "number" and groupIndex >= 1 and groupIndex == math.floor(groupIndex)
				and type(skillIndex) == "number" and skillIndex >= 1 and skillIndex == math.floor(skillIndex)
			local nativeViolations = copyViolations(entry.violations)
			local resources, exactCosts = buildResourceRows(entry.poolOutput or { }, entry.skillOutput or { })
			local status = classifyPayability(nativeViolations, exactCosts)
			if not identityValid then
				status = "unsupported"
				nativeViolations[#nativeViolations + 1] = {
					label = "Skill identity",
					reason = "PoB did not expose a stable socket-group and active-skill index for this exact cost row",
				}
			end
			local row = {
				identity = table.concat({ tostring(effect and (effect.id or effect.name) or name), tostring(groupIndex or "?"), tostring(skillIndex or "?"), tostring(skill.skillPartName or "") }, "\31"),
				name = name,
				group = safeText(entry.group, 80),
				groupIndex = identityValid and groupIndex or nil,
				skillIndex = identityValid and skillIndex or nil,
				skillPart = safeText(skill.skillPartName, 64),
				count = isFinite(entry.count) and math.max(1, entry.count) or 1,
				status = status,
				exactCosts = exactCosts,
				resources = resources,
				violations = nativeViolations,
			}
			result.skills[#result.skills + 1] = row
			if result.totalEnabledSkills <= MAX_SCHEDULE_SKILLS then
				local scheduleActivity = buildScheduleActivity(entry.activityRecord, row, identityValid)
				if scheduleActivity then
					result.scheduleActivities[#result.scheduleActivities + 1] = scheduleActivity
				else
					result.scheduleUnsupportedReason = result.scheduleUnsupportedReason
						or (identityValid and "PoB did not expose a complete exact recurring-rate record for every enabled skill" or "PoB did not expose stable socket-group and skill indices for every enabled skill")
				end
			end
			result.auditedSkills = result.auditedSkills + 1
			if status == "violated" then
				hasViolation = true
				for _, violation in ipairs(nativeViolations) do
					result.violations[#result.violations + 1] = {
						skill = name,
						group = row.group,
						resource = violation.resource,
						label = violation.label,
						actual = violation.actual,
						required = violation.required,
						deficit = violation.deficit,
						reason = violation.reason,
					}
				end
			elseif status == "unsupported" then
				hasUnsupported = true
				if #result.unsupported < 8 then
					local reason = nativeViolations[1] and nativeViolations[1].reason or "PoB did not expose complete exact resource values"
					result.unsupported[#result.unsupported + 1] = name .. ": " .. reason
				end
			end
		end
	end
	if result.totalEnabledSkills > MAX_SCHEDULE_SKILLS then
		result.scheduleTruncated = true
		result.scheduleUnsupportedReason = "The enabled-skill schedule exceeds the 64-activity input limit"
	end
	if result.totalEnabledSkills > MAX_SKILLS then
		result.truncated = true
		hasUnsupported = true
		result.unsupported[#result.unsupported + 1] = "The enabled-skill list exceeded the 96-row audit limit"
		result.scheduleTruncated = true
	end
	if not result.scheduleUnsupportedReason and not result.scheduleTruncated and #result.scheduleActivities ~= result.totalEnabledSkills then
		result.scheduleUnsupportedReason = "PoB did not expose a complete recurring-rate record for every enabled skill"
	end
	if hasUnsupported then
		result.status = "unsupported"
	elseif hasViolation then
		result.status = "violated"
	elseif result.auditedSkills > 0 then
		result.status = "pass"
	end
	result.upfrontPayabilityStatus = result.status
	return result
end

-- This is an upfront cast-cost gate only. Recurring costs remain governed by
-- the separate activity-schedule contract, which needs explicit activity
-- assumptions and does not certify timing or uptime.
function audit.CheckUpfrontPayability(result)
	local checked = { status = "unsupported", feasible = false, violations = { }, normalizedDeficit = math.huge }
	if type(result) ~= "table" then
		checked.violations[1] = {
			key = "enabled_skill_payability_unsupported",
			label = "Enabled skill costs",
			reason = "PoB did not provide the exact per-skill cost audit for enabled skills",
			deficit = math.huge,
		}
		return checked
	end
	local total = tonumber(result.totalEnabledSkills)
	local audited = tonumber(result.auditedSkills)
	if not isFinite(total) or total < 0 or total ~= math.floor(total)
		or not isFinite(audited) or audited < 0 or audited ~= math.floor(audited)
		or result.truncated == true or total ~= audited then
		checked.violations[1] = {
			key = "enabled_skill_payability_unsupported",
			label = "Enabled skill costs",
			reason = "PoB's enabled-skill cost audit is missing rows or exceeded its exact audit limit",
			deficit = math.huge,
		}
		return checked
	end
	if total == 0 and result.status == "not_required" then
		return { status = "pass", feasible = true, violations = { }, normalizedDeficit = 0 }
	end
	if result.status == "pass" and #(result.violations or { }) == 0 then
		return { status = "pass", feasible = true, violations = { }, normalizedDeficit = 0 }
	end
	for _, violation in ipairs(result.violations or { }) do
		local skillName = safeText(violation.skill, 96)
		checked.violations[#checked.violations + 1] = {
			key = "enabled_skill_payability",
			label = skillName ~= "" and (skillName .. " upfront cost") or "Enabled skill upfront cost",
			skill = skillName,
			group = safeText(violation.group, 80),
			resource = safeText(violation.resource, 32),
			actual = isFinite(violation.actual) and violation.actual or nil,
			required = isFinite(violation.required) and violation.required or nil,
			deficit = isFinite(violation.deficit) and violation.deficit or nil,
			reason = safeText(violation.reason, 240),
		}
	end
	if result.status == "violated" and #checked.violations > 0 then
		checked.status = "violated"
		checked.feasible = false
		checked.normalizedDeficit = #checked.violations
		return checked
	end
	local unsupported = result.unsupported
	local reason = type(unsupported) == "table" and unsupported[1]
		or (result.status == "pass" and #(result.violations or { }) > 0 and "PoB's per-skill audit is internally inconsistent"
			or "PoB could not verify every enabled skill's exact upfront cost")
	checked.violations[#checked.violations + 1] = {
		key = "enabled_skill_payability_unsupported",
		label = "Enabled skill costs",
		reason = safeText(reason, 240),
		deficit = math.huge,
	}
	return checked
end

return audit
