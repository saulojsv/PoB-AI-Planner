-- Path of Building
--
-- Module: Event-driven trigger certification boundaries.
-- CalcTriggers can calculate cooldown ceilings for these triggers, but the
-- engine does not simulate the incoming events that determine their cadence.
-- Keep those exact ceilings distinct from a certified effective event rate.
--
local eventTriggerModel = { }

local eventReasons = {
	["cast when damage taken"] = "PoB exposes the CWDT threshold and cooldown cap, but it does not simulate incoming damage-event cadence; trigger-rate and sustained-activity requirements are uncertified",
	["cast when stunned"] = "PoB exposes the stun-trigger setup, but it does not simulate stun-event cadence; trigger-rate and sustained-activity requirements are uncertified",
	["cast on ward break"] = "PoB exposes Ward Break trigger configuration, but it does not simulate Ward-break event cadence; trigger-rate and sustained-activity requirements are uncertified",
}

local function isSet(value)
	return value ~= nil and value ~= false and value ~= 0
end

function eventTriggerModel.GetUnsupportedReason(activeSkill)
	if type(activeSkill) ~= "table" then return nil end
	local triggeredBy = activeSkill.triggeredBy
	local effect = triggeredBy and triggeredBy.grantedEffect
	local name = effect and effect.name
	if type(name) == "string" then
		local reason = eventReasons[name:lower()]
		if reason then return reason end
	end

	local skillData = activeSkill.skillData or { }
	if isSet(skillData.triggeredByDamageTaken) then
		return eventReasons["cast when damage taken"]
	elseif isSet(skillData.chanceToTriggerOnStun) or isSet(skillData.triggeredByStun) then
		return eventReasons["cast when stunned"]
	elseif isSet(skillData.chanceToTriggerOnWardBreak) or isSet(skillData.triggeredByWardBreak) then
		return eventReasons["cast on ward break"]
	end
	return nil
end

return eventTriggerModel
