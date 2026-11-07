-- Path of Building
--
-- Module: Trigger and server breakpoint certification.
-- CalcTriggers models supported cooldown recovery and server-tick rounding.
-- Event-driven triggers can expose only a cooldown ceiling, so this adapter
-- refuses to mistake that ceiling for the rate of incoming game events.
--
local breakpoints = { }
local EventTriggerModel = require("Modules.Optimizer.EventTriggerModel")

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function breakpoints.Evaluate(activeSkill, output, requiredRate)
	local result = { status = "not_required", violations = { }, triggerRate = output.SkillTriggerRate, cap = output.TriggerRateCap }
	if not requiredRate or requiredRate <= 0 then
		return result
	end
	local eventTriggerReason = EventTriggerModel.GetUnsupportedReason(activeSkill)
	if eventTriggerReason then
		return { status = "unsupported", violations = { eventTriggerReason }, triggerRate = output.SkillTriggerRate, cap = output.TriggerRateCap }
	end
	if not isFinite(output.SkillTriggerRate) then
		return { status = "unsupported", violations = { "CalcTriggers did not expose an exact effective trigger rate for this skill" } }
	end
	result.status = "valid"
	if output.SkillTriggerRate + 0.0000001 < requiredRate then
		result.status = "violated"
		result.violations[1] = string.format("Trigger rate %.4g/s is below %.4g/s", output.SkillTriggerRate, requiredRate)
	end
	-- TriggerRateCap is not always expressed in the same domain as
	-- SkillTriggerRate. Trigger Bots multiply the effective spell rate by two,
	-- and some skills multiply it by hits/overlaps per trigger. CalcTriggers has
	-- already applied cooldown/tick limits before those explicit multipliers;
	-- comparing the final rate to the per-trigger cap rejects valid builds.
	return result
end

return breakpoints
