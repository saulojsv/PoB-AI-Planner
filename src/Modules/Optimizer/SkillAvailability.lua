-- Path of Building
--
-- Module: sustained-damage availability certification.
-- PoB's exact damage result is necessary but not always sufficient to certify
-- continuous DPS. Vaal soul uptime and Cast on Ward Break's break/refill cadence
-- are not modeled. Trauma is gated against PoB's sustainable stack count and,
-- for skills with a reset cap, against the worst-case trauma gained by the next
-- attack sequence. Keep PoB's calculation untouched and gate only DPS
-- objectives and hard DPS floors that consume the affected skill.
--
local availability = { }

local function isVaal(activeSkill)
	local skillTypes = activeSkill and activeSkill.skillTypes
	if type(skillTypes) ~= "table" then return false end
	local vaalType = SkillType and SkillType.Vaal or "Vaal"
	return skillTypes[vaalType] == true or skillTypes.Vaal == true
end

local function skillName(activeSkill)
	local activeEffect = activeSkill and activeSkill.activeEffect
	local grantedEffect = activeEffect and activeEffect.grantedEffect
	return grantedEffect and grantedEffect.name or "Unknown skill"
end

local function isEnabledVaalVariant(activeSkill, group)
	local effect = activeSkill and activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
	if not effect then return false end
	for _, gem in ipairs(group and group.gemList or { }) do
		local gemData = gem.gemData
		if gem.enabled ~= false and gemData and gemData.vaalGem then
			local vaalList = gemData.grantedEffectList or { }
			if effect == vaalList[1] then return gem.enableGlobal1 == true end
			if effect == vaalList[2] then return gem.enableGlobal2 == true end
		end
	end
	-- Item/tree granted skills can have no matching socketed Vaal gem. The active
	-- skill list is the engine's authoritative set; keep such a skill included.
	return true
end

local function requestsMetric(parsed, metric)
	if parsed.objective == metric then return true end
	for key, constraint in pairs(parsed.hard or { }) do
		if (constraint.metricKey or key) == metric then return true end
	end
	return false
end

local function hasTrauma(activeSkill)
	local modList = activeSkill and (activeSkill.baseSkillModList or activeSkill.skillModList)
	return modList and type(modList.Flag) == "function" and modList:Flag(nil, "HasTrauma") or false
end

local function finiteNumber(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function readTraumaState(activeSkill, sustainable, exactOutput)
	local modList = activeSkill and activeSkill.skillModList
	if not modList or type(modList.Sum) ~= "function" then
		return nil, "PoB did not expose the calculated skill modifiers needed to certify Trauma stacks"
	end
	if not finiteNumber(sustainable) then
		return nil, "PoB did not expose a finite sustainable Trauma stack limit for " .. skillName(activeSkill)
	end
	local configured = modList:Sum("BASE", activeSkill.skillCfg, "Multiplier:TraumaStacks")
	if not finiteNumber(configured) then
		return nil, "PoB did not expose a finite configured Trauma stack count for " .. skillName(activeSkill)
	end
	local maximum = modList:Sum("BASE", activeSkill.skillCfg, "Multiplier:TraumaStacksMax")
	local extraChance = modList:Sum("BASE", activeSkill.skillCfg, "ExtraTrauma")
	local repeats = exactOutput and exactOutput.Repeats
	if not finiteNumber(maximum) or maximum < 0 or not finiteNumber(extraChance) then
		return nil, "PoB did not expose valid Trauma reset-cap modifiers for " .. skillName(activeSkill)
	end
	if maximum > 0 and (not finiteNumber(repeats) or repeats <= 0) then
		return nil, "PoB did not expose a finite repeat count needed to certify the Trauma reset cap for " .. skillName(activeSkill)
	end
	return {
		name = skillName(activeSkill),
		configuredStacks = configured,
		sustainableStacks = sustainable,
		maximumStacks = maximum,
		extraTraumaChance = extraChance,
		repeats = repeats or 1,
	}
end

local function addTraumaResetRisk(state, resetRisks)
	if state.maximumStacks <= 0 then return 0 end
	-- ExtraTrauma is a chance to grant one additional stack. Any positive chance
	-- means a hit can grant two, so strict certification uses that possible
	-- outcome instead of its average. Repeats are rounded up to cover every hit
	-- in the attack sequence. This avoids approving a DPS snapshot that reaches
	-- the skill's explicit lose-all-trauma threshold on the next use.
	local traumaPerHit = 1 + (state.extraTraumaChance > 0 and 1 or 0)
	local maximumPerUse = math.ceil(state.repeats - 0.000001) * traumaPerHit
	local reachingValue = state.configuredStacks + maximumPerUse
	if reachingValue < state.maximumStacks - 0.000001 then return 0 end
	state.maximumTraumaPerUse = maximumPerUse
	state.resetThreshold = state.maximumStacks
	state.resetMargin = reachingValue - state.maximumStacks
	state.resetReason = string.format(
		"Configured Trauma %.6g can reach the reset threshold %.6g on the next skill use (up to %.6g Trauma per use)",
		state.configuredStacks, state.maximumStacks, maximumPerUse)
	resetRisks[#resetRisks + 1] = state
	return (math.max(state.resetMargin, 0) + 1) / math.max(state.maximumStacks, 1)
end

local function isEnabledFullDpsSkill(activeSkill)
	local group = activeSkill and activeSkill.socketGroup
	return group and group.includeInFullDPS and group.enabled ~= false and group.slotEnabled ~= false
end

local function hasWardBreakSupport(activeSkill)
	for _, support in ipairs(activeSkill and activeSkill.supportList or { }) do
		local effect = support.grantedEffect or support.activeEffect and support.activeEffect.grantedEffect
		if effect and (effect.id == "SupportCastOnWardBreak" or effect.name == "Cast on Ward Break") then
			return true
		end
	end

	-- Some exact-output contexts omit supportList. The socket group still carries
	-- PoB's parsed gem data, so use it as a conservative fallback.
	local group = activeSkill and activeSkill.socketGroup
	for _, gem in ipairs(group and group.gemList or { }) do
		local gemData = gem.gemData
		if gem.enabled ~= false and gemData and (gemData.variantId == "SupportCastOnWardBreak"
			or gemData.grantedEffectId == "SupportCastOnWardBreak" or gemData.name == "Cast on Ward Break") then
			return true
		end
	end
	return false
end

function availability.Evaluate(parsed, player, fullDpsSkillAvailability, selectedOutput)
	parsed = parsed or { }
	local requestsSelectedDps = requestsMetric(parsed, "CombinedDPS")
	local requestsFullDps = requestsMetric(parsed, "FullDPS") or requestsMetric(parsed, "FullDotDPS")
	if not requestsSelectedDps and not requestsFullDps then
		return { status = "not_required", feasible = true, metrics = { } }
	end

	local requestedMetrics = { }
	if requestsSelectedDps then requestedMetrics[#requestedMetrics + 1] = "CombinedDPS" end
	if requestsFullDps then
		if requestsMetric(parsed, "FullDPS") then requestedMetrics[#requestedMetrics + 1] = "FullDPS" end
		if requestsMetric(parsed, "FullDotDPS") then requestedMetrics[#requestedMetrics + 1] = "FullDotDPS" end
	end

	local unsupported = { }
	local unsustainableTrauma = { }
	local traumaResetRisks = { }
	local seenVaal = { }
	local seenWardBreakGroups = { }
	local hasVaal = false
	local normalizedDeficit = 0
	local function addVaal(activeSkill)
		if not isVaal(activeSkill) then return end
		hasVaal = true
		local name = skillName(activeSkill)
		if not seenVaal[name] then
			seenVaal[name] = true
			unsupported[#unsupported + 1] = name
		end
	end
	local function addTrauma(activeSkill, sustainable, exactOutput)
		if not hasTrauma(activeSkill) then return end
	local state, err = readTraumaState(activeSkill, sustainable, exactOutput)
		if not state then
			unsupported[#unsupported + 1] = err
			return
		end
		if state.configuredStacks > state.sustainableStacks + 0.000001 then
			state.excessStacks = state.configuredStacks - state.sustainableStacks
			state.reason = string.format("Configured Trauma %.6g exceeds PoB's sustainable limit %.6g", state.configuredStacks, state.sustainableStacks)
			unsustainableTrauma[#unsustainableTrauma + 1] = state
			normalizedDeficit = normalizedDeficit + state.excessStacks / math.max(state.sustainableStacks, 1)
		end
		normalizedDeficit = normalizedDeficit + addTraumaResetRisk(state, traumaResetRisks)
	end
	local function addWardBreak(activeSkill)
		if not hasWardBreakSupport(activeSkill) then return end
		local group = activeSkill.socketGroup or activeSkill
		if seenWardBreakGroups[group] then return end
		seenWardBreakGroups[group] = true
		unsupported[#unsupported + 1] = "PoB does not simulate Ward-break and Ward-refill cadence for " .. skillName(activeSkill) .. " with Cast on Ward Break"
	end

	if requestsSelectedDps then
		if not player or not player.mainSkill then
			return {
				status = "unsupported",
				feasible = false,
				metrics = requestedMetrics,
				unsupportedSkills = { },
				reason = "PoB did not expose the selected skill needed to certify CombinedDPS availability",
			}
		end
		addVaal(player.mainSkill)
		addTrauma(player.mainSkill, selectedOutput and selectedOutput.SustainableTrauma, selectedOutput)
		addWardBreak(player.mainSkill)
	end

	if requestsFullDps then
		if not player or type(player.activeSkillList) ~= "table" then
			return {
				status = "unsupported",
				feasible = false,
				metrics = requestedMetrics,
				unsupportedSkills = { },
				reason = "PoB did not expose its active skills needed to certify full-build DPS availability",
			}
		end
		for _, activeSkill in ipairs(player.activeSkillList) do
			local group = activeSkill.socketGroup
			if isEnabledFullDpsSkill(activeSkill) and isEnabledVaalVariant(activeSkill, group) then
				addVaal(activeSkill)
			end
			if isEnabledFullDpsSkill(activeSkill) then
				addWardBreak(activeSkill)
			end
		end

		local traumaRecords = fullDpsSkillAvailability
		if type(traumaRecords) == "table" then
			for _, record in ipairs(traumaRecords) do
				if not finiteNumber(record.configuredStacks) or not finiteNumber(record.sustainableStacks)
					or not finiteNumber(record.maximumStacks) or record.maximumStacks < 0
					or not finiteNumber(record.extraTraumaChance)
					or not finiteNumber(record.repeats) or record.repeats <= 0 then
					unsupported[#unsupported + 1] = "PoB returned invalid Trauma availability data for " .. tostring(record.name or "an included skill")
				else
					local state = {
						name = record.name or "Included skill",
						configuredStacks = record.configuredStacks,
						sustainableStacks = record.sustainableStacks,
						maximumStacks = record.maximumStacks,
						extraTraumaChance = record.extraTraumaChance,
						repeats = record.repeats,
					}
					if state.configuredStacks > state.sustainableStacks + 0.000001 then
						state.excessStacks = state.configuredStacks - state.sustainableStacks
						state.reason = string.format("Configured Trauma %.6g exceeds PoB's sustainable limit %.6g", state.configuredStacks, state.sustainableStacks)
						unsustainableTrauma[#unsustainableTrauma + 1] = state
						normalizedDeficit = normalizedDeficit + state.excessStacks / math.max(state.sustainableStacks, 1)
					end
					normalizedDeficit = normalizedDeficit + addTraumaResetRisk(state, traumaResetRisks)
				end
			end
		else
			-- The internal metadata is created by PoB's FullDPS pass. If it is
			-- absent while an included skill uses Trauma, fail closed instead of
			-- certifying a total that may contain unsustainable configured stacks.
			for _, activeSkill in ipairs(player.activeSkillList) do
				if isEnabledFullDpsSkill(activeSkill) and hasTrauma(activeSkill) then
					unsupported[#unsupported + 1] = "PoB did not expose exact FullDPS Trauma availability for " .. skillName(activeSkill)
				end
			end
		end
	end

	if #unsupported > 0 then
		local reasons = { }
		if hasVaal then
			reasons[#reasons + 1] = "PoB calculates Vaal damage but does not model soul generation or soul-gain prevention; sustained DPS availability is uncertified"
		end
		for _, reason in ipairs(unsupported) do
			if reason:find("PoB did not expose", 1, true) or reason:find("PoB returned invalid", 1, true)
				or reason:find("PoB does not simulate", 1, true) then
				reasons[#reasons + 1] = reason
			end
		end
		return {
			status = "unsupported",
			feasible = false,
			metrics = requestedMetrics,
			unsupportedSkills = unsupported,
			unsustainableTraumaSkills = unsustainableTrauma,
			normalizedDeficit = math.huge,
			reason = #reasons > 0 and table.concat(reasons, "; ") or "Continuous DPS availability is not certified",
		}
	end

	if #unsustainableTrauma > 0 then
		local reasons = { }
		for _, state in ipairs(unsustainableTrauma) do
			reasons[#reasons + 1] = state.name .. ": " .. state.reason
		end
		for _, state in ipairs(traumaResetRisks) do
			reasons[#reasons + 1] = state.name .. ": " .. state.resetReason
		end
		return {
			status = "violated",
			feasible = false,
			metrics = requestedMetrics,
			unsupportedSkills = { },
			unsustainableTraumaSkills = unsustainableTrauma,
			traumaResetRisks = traumaResetRisks,
			normalizedDeficit = normalizedDeficit,
			reason = table.concat(reasons, "; "),
		}
	end

	if #traumaResetRisks > 0 then
		local reasons = { }
		for _, state in ipairs(traumaResetRisks) do
			reasons[#reasons + 1] = state.name .. ": " .. state.resetReason
		end
		return {
			status = "violated",
			feasible = false,
			metrics = requestedMetrics,
			unsupportedSkills = { },
			unsustainableTraumaSkills = { },
			traumaResetRisks = traumaResetRisks,
			normalizedDeficit = normalizedDeficit,
			reason = table.concat(reasons, "; "),
		}
	end

	return { status = "valid", feasible = true, metrics = { }, unsustainableTraumaSkills = { }, traumaResetRisks = { } }
end

return availability
