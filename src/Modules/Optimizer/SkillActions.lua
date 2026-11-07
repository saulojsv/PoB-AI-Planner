-- Path of Building
--
-- Module: native skill-action classification for the optimizer.
-- Counts distinct enabled socket-group actions that need manual activation.
-- It deliberately does not infer keyboard bindings or actions per minute.
--
local skillActions = { }

local maxListedActions = 64
local maxActiveSkillEntries = 256

local function safeText(value, limit)
	local text = tostring(value or ""):gsub("[%c]", " ")
	if #text > limit then text = text:sub(1, limit) end
	return text
end

local function hasSkillType(activeSkill, name)
	local skillTypeIds = SkillType or { }
	local id = skillTypeIds[name]
	local types = activeSkill and activeSkill.skillTypes or { }
	return types[name] == true or (id ~= nil and types[id] == true)
end

local function getActivation(activeSkill)
	local data = activeSkill.skillData or { }
	if data.triggered == true or data.triggeredByAutoexertion == true
		or data.triggeredBySaviour == true or data.triggeredOnDeath == true
		or activeSkill.infoTrigger
		or hasSkillType(activeSkill, "Triggered")
		or hasSkillType(activeSkill, "InbuiltTrigger") then
		return "triggered"
	end
	if hasSkillType(activeSkill, "HasReservation") and not hasSkillType(activeSkill, "ReservationBecomesCost") then
		return "reserved"
	end
	return "manual"
end

local function isDamageAction(activeSkill)
	local flags = activeSkill.skillFlags or { }
	return hasSkillType(activeSkill, "Attack")
		or hasSkillType(activeSkill, "Damage")
		or hasSkillType(activeSkill, "DamageOverTime")
		or hasSkillType(activeSkill, "CreatesMinion")
		or flags.hit == true or flags.dot == true or flags.minion == true
		or flags.totem == true or flags.trap == true or flags.mine == true
end

local function appendViolation(audit, reason, key)
	audit.feasible = false
	audit.violations[#audit.violations + 1] = {
		key = key or "manual_action_classification",
		label = "Manual skill-action cap",
		reason = reason,
	}
	audit.status = "unsupported"
end

function skillActions.Evaluate(activeSkillList, maximum, damageMaximum)
	local constrained = maximum ~= nil or damageMaximum ~= nil
	local audit = {
		status = constrained and "pass" or "not_constrained",
		feasible = true,
		limit = maximum,
		damageLimit = damageMaximum,
		manualButtonCount = 0,
		manualDamageButtonCount = 0,
		manualUtilityButtonCount = 0,
		triggeredSkillCount = 0,
		reservedSkillCount = 0,
		actions = { },
		actionsTruncated = false,
		violations = { },
	}

	if maximum ~= nil and (type(maximum) ~= "number" or maximum ~= maximum or maximum == math.huge or maximum == -math.huge
		or maximum < 0 or maximum > 24 or maximum ~= math.floor(maximum)) then
		appendViolation(audit, "The total manual skill-action limit must be an integer from 0 to 24", "manual_button_cap")
		return audit
	end
	if damageMaximum ~= nil and (type(damageMaximum) ~= "number" or damageMaximum ~= damageMaximum
		or damageMaximum == math.huge or damageMaximum == -math.huge
		or damageMaximum < 0 or damageMaximum > 24 or damageMaximum ~= math.floor(damageMaximum)) then
		appendViolation(audit, "The manual damage-action limit must be an integer from 0 to 24", "manual_damage_button_cap")
		return audit
	end
	if type(activeSkillList) ~= "table" then
		if constrained then appendViolation(audit, "PoB did not expose its active skill list for manual-action classification") end
		audit.status = not constrained and "unavailable" or audit.status
		return audit
	end

	local seen = { }
	local unsupported = { }
	local maxActiveSkillIndex = 0
	for key in pairs(activeSkillList) do
		if type(key) == "number" then
			if key < 1 or key ~= math.floor(key) or key > maxActiveSkillEntries then
				unsupported[#unsupported + 1] = "PoB returned an invalid active-skill list index"
			else
				maxActiveSkillIndex = math.max(maxActiveSkillIndex, key)
			end
		end
	end
	for index = 1, maxActiveSkillIndex do
		local activeSkill = activeSkillList[index]
		if type(activeSkill) ~= "table" then
			unsupported[#unsupported + 1] = "PoB returned a missing or invalid active skill at index " .. tostring(index)
		else
			local group = activeSkill.socketGroup
			if type(group) ~= "table" then
				unsupported[#unsupported + 1] = "An active PoB skill has no socket-group classification"
			elseif group.enabled ~= false and group.slotEnabled ~= false and not (activeSkill.skillFlags or { }).disable then
				local effect = activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
				local effectId = effect and (effect.id or effect.name)
				if not effectId then
					unsupported[#unsupported + 1] = "An enabled socket-group skill has no stable PoB effect ID or name"
				else
					seen[group] = seen[group] or { }
					local key = tostring(effectId)
					if not seen[group][key] then
						seen[group][key] = true
						local activation = getActivation(activeSkill)
						local name = safeText(effect.name or effectId, 96)
						if activation == "triggered" then
							audit.triggeredSkillCount = audit.triggeredSkillCount + 1
						elseif activation == "reserved" then
							audit.reservedSkillCount = audit.reservedSkillCount + 1
						else
							local category = isDamageAction(activeSkill) and "damage" or "utility"
							audit.manualButtonCount = audit.manualButtonCount + 1
							if category == "damage" then
								audit.manualDamageButtonCount = audit.manualDamageButtonCount + 1
							else
								audit.manualUtilityButtonCount = audit.manualUtilityButtonCount + 1
							end
							if #audit.actions < maxListedActions then
								audit.actions[#audit.actions + 1] = {
									name = name,
									group = safeText(group.label or group.slot or "PoB skill group", 80),
									activation = activation,
									category = category,
								}
							else
								audit.actionsTruncated = true
							end
						end
					end
				end
			end
		end
	end

	if #unsupported > 0 and constrained then
		appendViolation(audit, table.concat(unsupported, "; "))
		return audit
	elseif #unsupported > 0 then
		audit.status = "unverified"
		audit.unsupported = unsupported
	end
	local normalizedDeficit = 0
	if maximum ~= nil and audit.manualButtonCount > maximum then
		audit.status = "violated"
		audit.feasible = false
		audit.violations[#audit.violations + 1] = {
			key = "manual_button_cap",
			label = "Manual skill-action cap",
			actual = audit.manualButtonCount,
			required = maximum,
			deficit = audit.manualButtonCount - maximum,
			reason = "Above strict maximum",
		}
		normalizedDeficit = normalizedDeficit + (audit.manualButtonCount - maximum) / math.max(1, maximum)
	end
	if damageMaximum ~= nil and audit.manualDamageButtonCount > damageMaximum then
		audit.status = "violated"
		audit.feasible = false
		audit.violations[#audit.violations + 1] = {
			key = "manual_damage_button_cap",
			label = "Manual damage-action cap",
			actual = audit.manualDamageButtonCount,
			required = damageMaximum,
			deficit = audit.manualDamageButtonCount - damageMaximum,
			reason = "Above strict maximum",
		}
		normalizedDeficit = normalizedDeficit + (audit.manualDamageButtonCount - damageMaximum) / math.max(1, damageMaximum)
	end
	if not audit.feasible then audit.normalizedDeficit = normalizedDeficit end
	return audit
end

return skillActions
