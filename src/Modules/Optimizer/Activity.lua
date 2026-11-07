-- Path of Building
--
-- Module: exact activity and recurring-resource certification.
-- This module accepts only resource rates captured from PoB's own per-skill
-- calculation. It does not estimate cast schedules, recoup, flask uptime, or
-- resource recovery from guide text.
--
local activity = { }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function isPositive(value)
	return isFinite(value) and value > 0
end

local function needsDpsCertification(parsed)
	if not parsed then return false end
	if parsed.objective == "CombinedDPS" or parsed.objective == "FullDPS" or parsed.objective == "FullDotDPS" then
		return true
	end
	for key, constraint in pairs(parsed.hard or { }) do
		local metric = constraint.metricKey or key
		if metric == "CombinedDPS" or metric == "FullDPS" or metric == "FullDotDPS" then
			return true
		end
	end
	return false
end

local function normalizeRecord(record, includeCostOnly)
	if type(record) ~= "table" then return nil end
	if includeCostOnly then
		if type(record.costScheduleEligible) ~= "boolean" then return nil end
	elseif record.hasDamage ~= true then
		return nil
	end
	return record
end

local function collectRecords(mainRecord, fullRecords, includeCostOnly)
	local records, seen = { }, { }
	local function add(record)
		record = normalizeRecord(record, includeCostOnly)
		if not record then return end
		local identity = record.identity or table.concat({ tostring(record.name or "Unknown skill"), tostring(record.group or ""), tostring(record.skillPart or "") }, "\31")
		if not seen[identity] then
			seen[identity] = true
			records[#records + 1] = record
		end
	end
	add(mainRecord)
	for _, record in ipairs(fullRecords or { }) do add(record) end
	return records
end

local function copyPoBDamage(poBDamage)
	if type(poBDamage) ~= "table" then return nil end
	local copy = { }
	for source, values in pairs(poBDamage) do
		if type(source) == "string" and type(values) == "table" then
			local sourceCopy = { }
			for key, value in pairs(values) do
				if type(key) == "string" and isFinite(value) then sourceCopy[key] = value end
			end
			if next(sourceCopy) then copy[source] = sourceCopy end
		end
	end
	return next(copy) and copy or nil
end

-- Return stable identity, display metadata, and captured exact PoB damage
-- outputs. Consumers submit the identity back to EvaluateSchedule, which
-- re-resolves it against current PoB output before using any exact rates.
function activity.ListScheduleActivities(mainRecord, fullRecords, fullRecordsTruncated, includeCostOnly)
	if fullRecordsTruncated then
		return nil, includeCostOnly and "PoB's enabled-skill schedule is truncated; the schedule editor cannot cover every skill" or "PoB's captured damage activity list is truncated; the schedule editor cannot cover every record"
	end
	local records = collectRecords(mainRecord, fullRecords, includeCostOnly)
	if #records == 0 then
		return nil, includeCostOnly and "PoB did not expose any enabled-skill resource records for this scope" or "PoB did not expose any damage activity records for this scope"
	end
	local result = { }
	for _, record in ipairs(records) do
		if type(record.identity) ~= "string" or record.identity == "" then
			return nil, "PoB returned an activity without a stable identity; schedule editing is unsupported"
		end
		result[#result + 1] = {
			identity = record.identity,
			name = tostring(record.name or "Unknown skill"),
			group = tostring(record.group or ""),
			skillPart = tostring(record.skillPart or ""),
			kind = tostring(record.kind or "unknown"),
			hasDamage = record.hasDamage == true,
			resourceOnly = includeCostOnly == true,
			count = isFinite(record.count) and math.max(1, record.count) or 1,
			exact = record.exact == true,
			triggerRate = isFinite(record.triggerRate) and record.triggerRate or nil,
			unsupportedReason = type(record.unsupportedReason) == "string" and record.unsupportedReason
				or (includeCostOnly and record.exact ~= true and "PoB did not expose a complete exact recurring-resource record" or nil),
			damageUnsupportedReason = type(record.damageUnsupportedReason) == "string" and record.damageUnsupportedReason or nil,
			resources = includeCostOnly and record.resources or nil,
			otherResourceCosts = includeCostOnly and record.otherResourceCosts or nil,
			poBDamage = copyPoBDamage(record.poBDamage),
		}
	end
	return result
end

local function addUnsupported(reasons, seen, reason)
	if type(reason) ~= "string" or reason == "" or seen[reason] then return end
	seen[reason] = true
	reasons[#reasons + 1] = reason
end

function activity.Evaluate(parsed, mainRecord, fullRecords, fullRecordsTruncated, includeCostOnly)
	local records = collectRecords(mainRecord, fullRecords, includeCostOnly)

	if #records == 0 then
		if needsDpsCertification(parsed) then
			return {
				status = "unsupported", feasible = false, metrics = { }, activities = { },
				violations = { {
					key = "activity_sustain", label = "Sustained skill activity",
					reason = "PoB did not expose an exact activity record for the requested DPS output", deficit = math.huge,
				} }, normalizedDeficit = math.huge,
			}
		end
		return { status = "not_required", feasible = true, metrics = { }, activities = { }, violations = { }, normalizedDeficit = 0 }
	end

	local unsupported, unsupportedSeen, violations, metrics = { }, { }, { }, { }
	local aggregate = {
		Life = { cost = 0, leech = 0, onHit = 0, regen = nil, used = false },
		Mana = { cost = 0, leech = 0, onHit = 0, regen = nil, used = false },
		ES = { cost = 0, leech = 0, onHit = 0, regen = nil, used = false },
	}
	local summarizedActivities = { }
	local function finiteField(record, resource, key)
		local group = record.resources and record.resources[resource]
		local value = group and group[key]
		return isFinite(value) and value or nil
	end
	if fullRecordsTruncated then
		addUnsupported(unsupported, unsupportedSeen, "PoB's active FullDPS activity ledger was truncated; sustained resource use is uncertified")
	end

	for _, record in ipairs(records) do
		local name = tostring(record.name or "Unknown skill")
		if record.unsupportedReason then
			addUnsupported(unsupported, unsupportedSeen, name .. ": " .. record.unsupportedReason)
		end
		if record.exact == false then
			addUnsupported(unsupported, unsupportedSeen, name .. ": PoB did not expose a complete exact activity-cost record")
		end
		if record.kind == "triggered" and (not isFinite(record.triggerRate) or record.triggerRate <= 0) then
			addUnsupported(unsupported, unsupportedSeen, name .. ": PoB did not expose an exact positive trigger rate for its recurring cost")
		end
		local count = isFinite(record.count) and math.max(1, record.count) or 1
		local activityResources = { }
		for resource, pool in pairs(aggregate) do
			local cost = finiteField(record, resource, "cost")
			if cost == nil then
				addUnsupported(unsupported, unsupportedSeen, name .. ": PoB did not expose a finite " .. resource .. " cost rate")
			else
				-- PoB's per-second cost, leech, and on-hit outputs already describe
				-- this skill's calculated use rate. `record.count` is the configured
				-- damage-entity count (for example, 20 raging spirits), not 20 player
				-- casts per action. Scaling resource rates by it double-counts costs.
				pool.cost = pool.cost + cost
				pool.used = pool.used or cost > 0
			end
			local regen = finiteField(record, resource, "netRegen")
			if regen ~= nil then
				-- Shared passive regeneration/degen is consumed once, not once per
				-- skill. The lowest exact value is conservative if skill conditions
				-- cause the native outputs to differ.
				pool.regen = pool.regen and math.min(pool.regen, regen) or regen
			end
			local leech = finiteField(record, resource, "leech")
			local onHit = finiteField(record, resource, "onHit")
			if leech == nil or onHit == nil then
				if cost and cost > 0 then
					addUnsupported(unsupported, unsupportedSeen, name .. ": PoB did not expose finite " .. resource .. " leech/on-hit recovery")
				end
			else
				-- Leech is capped against a shared character pool. Taking the
				-- strongest per-skill native leech rate avoids counting that cap
				-- once for every skill; PoB's per-second on-hit output already
				-- includes the skill's calculated rate, so it is additive per activity.
				pool.leech = math.max(pool.leech, leech)
				pool.onHit = pool.onHit + onHit
			end
			activityResources[resource] = {
				cost = cost,
				netRegen = regen,
				leech = leech,
				onHit = onHit,
			}
		end
		for _, resource in ipairs({ "Rage", "Soul" }) do
			local cost = record.otherResourceCosts and record.otherResourceCosts[resource]
			if isPositive(cost) then
				addUnsupported(unsupported, unsupportedSeen, name .. ": PoB does not model sustained " .. resource:lower() .. " generation and spending cadence")
			end
		end
		summarizedActivities[#summarizedActivities + 1] = {
			identity = record.identity,
			name = name,
			group = record.group,
			kind = record.kind,
			count = count,
			triggerRate = record.triggerRate,
			resources = activityResources,
			poBDamage = copyPoBDamage(record.poBDamage),
			unsupportedReason = type(record.unsupportedReason) == "string" and record.unsupportedReason or nil,
			exact = record.exact == true,
		}
	end

	for resource, pool in pairs(aggregate) do
		if pool.used then
			if not isFinite(pool.regen) then
				addUnsupported(unsupported, unsupportedSeen, "PoB did not expose finite net " .. resource .. " regeneration/degen for sustained activity")
			else
				local margin = pool.regen + pool.leech + pool.onHit - pool.cost
				local metricKey = resource == "ES" and "SustainedEnergyShieldMargin" or "Sustained" .. resource .. "Margin"
				metrics[metricKey] = margin
				if margin < -0.000001 then
					violations[#violations + 1] = {
						key = "activity_sustain_" .. resource:lower(),
						label = resource == "ES" and "Energy Shield activity sustain" or resource .. " activity sustain",
						actual = margin,
						required = 0,
						deficit = -margin,
						reason = string.format("Exact PoB recovery %.6g/s is below recurring activity cost %.6g/s", pool.regen + pool.leech + pool.onHit, pool.cost),
					}
				end
			end
		end
	end

	if #unsupported > 0 then
		violations[#violations + 1] = {
			key = "activity_sustain_unsupported", label = "Sustained skill activity",
			reason = table.concat(unsupported, "; "), deficit = math.huge,
		}
		return {
			status = "unsupported", feasible = false, metrics = metrics, activities = summarizedActivities,
			unsupported = unsupported, violations = violations, normalizedDeficit = math.huge,
		}
	end
	if #violations > 0 then
		local normalizedDeficit = 0
		for _, violation in ipairs(violations) do
			normalizedDeficit = normalizedDeficit + violation.deficit / math.max(violation.required or 0, 1)
		end
		return { status = "violated", feasible = false, metrics = metrics, activities = summarizedActivities, violations = violations, normalizedDeficit = normalizedDeficit }
	end
	return { status = "pass", feasible = true, metrics = metrics, activities = summarizedActivities, violations = { }, normalizedDeficit = 0 }
end

-- Evaluate an explicit user schedule against rates captured by PoB. Schedule
-- percentages scale only recurring skill costs and on-hit recovery; shared
-- regeneration is counted once. This is a sustain estimate only: PoB's current
-- aggregate damage output is not recomputed for mutually exclusive schedules.
function activity.EvaluateSchedule(parsed, mainRecord, fullRecords, fullRecordsTruncated, schedule, costRecords)
	if type(schedule) ~= "table" then return nil, "activities must be an array of explicit schedule entries" end
	local resourceOnly = type(costRecords) == "table"
	local records = resourceOnly and collectRecords(nil, costRecords, true) or collectRecords(mainRecord, fullRecords)
	if fullRecordsTruncated then
		return nil, resourceOnly and "PoB's enabled-skill schedule is truncated; an explicit schedule cannot cover every skill" or "PoB's captured damage activity list is truncated; an explicit schedule cannot cover every record"
	end
	if #records == 0 then return nil, resourceOnly and "PoB did not expose any enabled-skill resource records for this scope" or "PoB did not expose any damage activity records for this scope" end
	if resourceOnly then
		for _, record in ipairs(records) do
			if record.costScheduleEligible ~= true then
				return nil, "PoB did not expose complete exact recurring-resource rates for " .. tostring(record.name or record.identity)
			end
		end
	end
	local scheduleCount, highestIndex = 0, 0
	for key in pairs(schedule) do
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			return nil, "activities must be a dense array"
		end
		scheduleCount = scheduleCount + 1
		if key > highestIndex then highestIndex = key end
	end
	if scheduleCount ~= highestIndex or scheduleCount < 1 or scheduleCount > 64 then
		return nil, "activities must contain 1 to 64 dense entries"
	end
	local recordByIdentity = { }
	for _, record in ipairs(records) do
		if type(record.identity) ~= "string" or record.identity == "" then
			return nil, "PoB returned an activity without a stable identity; schedule evaluation is unsupported"
		end
		recordByIdentity[record.identity] = record
	end
	local entryByIdentity, alternativeUse = { }, { }
	for index, entry in ipairs(schedule) do
		if type(entry) ~= "table" then return nil, "activities[" .. index .. "] must be an object" end
		for key in pairs(entry) do
			if key ~= "identity" and key ~= "mode" and key ~= "ratePercent" and key ~= "package" and key ~= "requires" then
				return nil, "activities[" .. index .. "] has an unsupported field: " .. tostring(key)
			end
		end
		local identity = entry.identity
		if type(identity) ~= "string" or #identity > 256 or not recordByIdentity[identity] then
			return nil, "activities[" .. index .. "] must use an identity from PoB's selected activity list"
		end
		if entryByIdentity[identity] then return nil, "Activity identity is listed more than once: " .. identity end
		local mode = entry.mode
		if mode ~= "continuous" and mode ~= "scheduled" and mode ~= "alternative" and mode ~= "setup" then
			return nil, "activities[" .. index .. "].mode must be continuous, scheduled, alternative, or setup"
		end
		local ratePercent = entry.ratePercent
		if mode == "continuous" then
			if ratePercent ~= nil and (not isFinite(ratePercent) or ratePercent ~= 100) then
				return nil, "continuous activities use a fixed ratePercent of 100"
			end
			ratePercent = 100
		elseif not isFinite(ratePercent) or ratePercent < 0 or ratePercent > 100 then
			return nil, "scheduled, alternative, and setup activities need ratePercent from 0 to 100"
		end
		local package = entry.package
		if mode == "alternative" then
			if type(package) ~= "string" or #package < 1 or #package > 48 then
				return nil, "alternative activities need a package name of 1 to 48 characters"
			end
			alternativeUse[package] = (alternativeUse[package] or 0) + ratePercent
		elseif package ~= nil then
			return nil, "package is only valid for alternative activities"
		end
		local requires, requiresSeen = { }, { }
		if entry.requires ~= nil then
			if type(entry.requires) ~= "table" then return nil, "activities[" .. index .. "].requires must be an array of PoB activity identities" end
			local requiresCount, requiresHighest = 0, 0
			for key in pairs(entry.requires) do
				if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
					return nil, "activities[" .. index .. "].requires must be a dense array"
				end
				requiresCount = requiresCount + 1
				requiresHighest = math.max(requiresHighest, key)
			end
			if requiresCount ~= requiresHighest or requiresCount < 1 or requiresCount > 8 then
				return nil, "activities[" .. index .. "].requires must contain 1 to 8 identities in a dense array"
			end
			for requiredIndex, requiredIdentity in ipairs(entry.requires) do
				if type(requiredIdentity) ~= "string" or #requiredIdentity < 1 or #requiredIdentity > 256 then
					return nil, "activities[" .. index .. "].requires[" .. requiredIndex .. "] must be a PoB activity identity"
				end
				if requiredIdentity == identity then return nil, "An activity cannot require itself: " .. tostring(identity) end
				if not recordByIdentity[requiredIdentity] then
					return nil, "activities[" .. index .. "].requires contains an identity outside the selected PoB activity list"
				end
				if requiresSeen[requiredIdentity] then return nil, "An activity dependency is listed more than once: " .. requiredIdentity end
				requiresSeen[requiredIdentity] = true
				requires[#requires + 1] = requiredIdentity
			end
		end
		entryByIdentity[identity] = { mode = mode, ratePercent = ratePercent, package = package, requires = requires }
	end
	for _, record in ipairs(records) do
		if not entryByIdentity[record.identity] then return nil, "Schedule is missing PoB activity: " .. tostring(record.name or record.identity) end
	end
	local dependencyState, dependencyCount = { }, 0
	local function visitDependencies(identity)
		if dependencyState[identity] == 1 then return false end
		if dependencyState[identity] == 2 then return true end
		dependencyState[identity] = 1
		for _, requiredIdentity in ipairs(entryByIdentity[identity].requires) do
			dependencyCount = dependencyCount + 1
			if not visitDependencies(requiredIdentity) then return false end
		end
		dependencyState[identity] = 2
		return true
	end
	for identity in pairs(entryByIdentity) do
		if not visitDependencies(identity) then return nil, "Activity dependency cycle detected; setup/payoff dependencies must form a directed acyclic graph" end
	end
	for identity, plan in pairs(entryByIdentity) do
		if plan.ratePercent > 0 then
			for _, requiredIdentity in ipairs(plan.requires) do
				if entryByIdentity[requiredIdentity].ratePercent <= 0 then
					return nil, "Active activity " .. identity .. " requires an activity with zero use rate: " .. requiredIdentity
				end
			end
		end
	end
	for package, totalUse in pairs(alternativeUse) do
		if totalUse > 100.000001 then return nil, "Alternative package " .. package .. " exceeds 100% total use" end
	end
	local scheduledRecords, zeroUseActivities = { }, { }
	local hasActiveUse = false
	for _, record in ipairs(records) do
		local plan = entryByIdentity[record.identity]
		local factor = plan.ratePercent / 100
		if factor == 0 then
			local zeroResources = { }
			for _, resource in ipairs({ "Life", "Mana", "ES" }) do
				zeroResources[resource] = { cost = 0, leech = 0, onHit = 0 }
			end
			zeroUseActivities[#zeroUseActivities + 1] = {
				identity = record.identity,
				name = tostring(record.name or "Unknown skill"),
				group = record.group,
				kind = record.kind,
				count = isFinite(record.count) and math.max(1, record.count) or 1,
				mode = plan.mode,
				ratePercent = 0,
				package = plan.package,
				requires = plan.requires,
				exact = record.exact == true,
				poBDamage = copyPoBDamage(record.poBDamage),
				resources = zeroResources,
			}
		else
			hasActiveUse = true
			local copy = { }
			for key, value in pairs(record) do copy[key] = value end
			copy.activityIdentity = record.identity
			copy.scheduledMode = plan.mode
			copy.scheduledRatePercent = plan.ratePercent
			copy.schedulePackage = plan.package
			copy.scheduleRequires = plan.requires
			copy.resources = { }
			for resource, rates in pairs(record.resources or { }) do
				local scaled = { }
				for key, value in pairs(rates) do
					if (key == "cost" or key == "leech" or key == "onHit") and isFinite(value) then
						scaled[key] = value * factor
					else
						scaled[key] = value
					end
				end
				copy.resources[resource] = scaled
			end
			copy.otherResourceCosts = { }
			for resource, rate in pairs(record.otherResourceCosts or { }) do
				copy.otherResourceCosts[resource] = isFinite(rate) and rate * factor or rate
			end
			scheduledRecords[#scheduledRecords + 1] = copy
		end
	end
	if not hasActiveUse then return nil, "At least one captured PoB activity must have a positive use rate" end
	local result = activity.Evaluate(parsed, nil, scheduledRecords, false, resourceOnly)
	result.sustainStatus = result.status
	result.sustainFeasible = result.feasible
	result.status = "sustain_estimate"
	result.feasible = nil
	result.damageScheduleCertified = false
	result.scheduleModel = {
		kind = resourceOnly and "user_supplied_average_rate_resource_only" or "user_supplied_average_rate",
		resourceRates = "PoB exact per-skill rates scaled by the supplied use percentages",
		sharedRecovery = "PoB shared regeneration counted once; shared leech uses the conservative strongest native per-skill rate",
		assumptions = true,
		damageScheduleCertified = false,
		damageScheduleNote = resourceOnly and "This scope estimates recurring resource use only. It does not calculate per-activity or combined damage, action cadence, or encounter uptime."
			or "Per-activity PoB damage outputs may be multiplied by the supplied average rate for inspection. The projections are not summed or recalculated; PoB's nonlinear DoT stacking/caps, best-source selection, culling, counts, setup/payoff timing, and encounter uptime are not certified.",
		damageProjection = resourceOnly and "not_computed_resource_only" or "linear_per_activity_only",
		damageProjectionCertified = false,
		dependencyModel = "explicit user-supplied acyclic prerequisites; only identity presence and nonzero use are checked",
		dependencyTimingCertified = false,
	}
	result.dependencyAudit = {
		status = dependencyCount > 0 and "structure_only" or "none",
		edgeCount = dependencyCount,
		activitiesWithDependencies = 0,
		nonzeroPrerequisitesChecked = true,
		timingCertified = false,
		note = "Dependency edges must form a DAG and active activities require nonzero prerequisite rates. Event order, setup duration, overlap, and sufficient cadence are not modeled.",
	}
	for index, summary in ipairs(result.activities or { }) do
		local original = scheduledRecords[index]
		local plan = entryByIdentity[original.activityIdentity]
		summary.identity = original.activityIdentity
		summary.mode = plan.mode
		summary.ratePercent = plan.ratePercent
		summary.package = plan.package
		if #plan.requires > 0 then summary.requires = plan.requires end
	end
	for _, summary in ipairs(zeroUseActivities) do result.activities[#result.activities + 1] = summary end
	for _, summary in ipairs(result.activities or { }) do
		local record = recordByIdentity[summary.identity]
		local plan = entryByIdentity[summary.identity]
		local factor = plan and plan.ratePercent / 100 or 0
		local requires = plan and plan.requires or { }
		if #requires > 0 then
			summary.requires = requires
			result.dependencyAudit.activitiesWithDependencies = result.dependencyAudit.activitiesWithDependencies + 1
		else
			summary.requires = nil
		end
		if resourceOnly then
			summary.damageUnsupportedReason = type(record and record.damageUnsupportedReason) == "string" and record.damageUnsupportedReason or nil
		else
			local projected = { }
			if plan and plan.mode ~= "setup" and factor > 0 and not (record and record.unsupportedReason) then
				for source, values in pairs(record and record.poBDamage or { }) do
					local sourceProjection = { }
					for key, value in pairs(values) do

						if isFinite(value) then sourceProjection[key] = value * factor end
					end
					if next(sourceProjection) then projected[source] = sourceProjection end
				end
			end
			local projectionStatus
			if not record or not record.poBDamage or record.unsupportedReason then
				projectionStatus = "unsupported"
			elseif not plan or factor == 0 then
				projectionStatus = "inactive"
			elseif plan.mode == "setup" then
				projectionStatus = "setup_excluded"
			elseif not next(projected) then
				projectionStatus = "unsupported"
			else
				projectionStatus = "linear_per_activity_estimate"
			end
			summary.poBDamageProjection = {
				status = projectionStatus,
				ratePercent = plan and plan.ratePercent or 0,
				raw = copyPoBDamage(record and record.poBDamage),
				perActivity = next(projected) and projected or nil,
				certified = false,
			}
		end
	end
	result.resourceOnly = resourceOnly
	if resourceOnly then
		result.damageScheduleProjection = {
			status = "not_computed_resource_only",
			method = "none",
			certified = false,
			combinedDPS = nil,
			note = result.scheduleModel.damageScheduleNote,
		}
	else
		result.damageScheduleProjection = {
			status = "per_activity_only",
			method = "PoB output fields multiplied by the supplied average activity rate",
			certified = false,
			combinedDPS = nil,
			note = result.scheduleModel.damageScheduleNote,
		}
	end
	return result
end

-- Apply the user's saved Average-use schedule to each exact optimizer candidate.
-- Only the two scopes that can describe a candidate build end to end are
-- accepted: FullDPS-included groups, or every enabled socketed skill for
-- resource-only sustain. The Main Skill scope remains an inspection tool.
function activity.EvaluateOptimizerSchedule(config, output, parsed)
	if type(config) ~= "table" or type(config.activities) ~= "table" then
		return nil, "Optimizer activity schedule is missing its typed activity rows"
	end
	if type(output) ~= "table" then return nil, "Exact PoB candidate output is unavailable for the optimizer activity schedule" end
	local scope = config.scope
	local result, err
	if scope == "full_dps" then
		result, err = activity.EvaluateSchedule(parsed or { objective = "FullDPS", hard = { } }, nil,
			output.FullDPSActivity, output.FullDPSActivityTruncated == true, config.activities)
	elseif scope == "all_enabled_skills" then
		local audit = output.OptimizerSkillCostAudit
		if type(audit) ~= "table" then return nil, "Exact PoB candidate output has no all-enabled-skill cost audit" end
		if audit.scheduleTruncated == true or type(audit.scheduleUnsupportedReason) == "string" then
			return nil, audit.scheduleUnsupportedReason or "PoB's all-enabled-skill activity list is truncated"
		end
		local records = audit.scheduleActivities
		if type(records) ~= "table" then return nil, "Exact PoB candidate output has no all-enabled-skill schedule rows" end
		result, err = activity.EvaluateSchedule(parsed or { objective = "ResourceSustain", hard = { } }, nil,
			records, false, config.activities, records)
	else
		return nil, "Optimizer activity gate scope must be Full DPS or All enabled skills"
	end
	if not result then return nil, err or "Exact PoB candidate activity schedule could not be evaluated" end
	local sustainStatus = result.sustainStatus or result.status
	result.sustainStatus = sustainStatus
	result.sustainFeasible = result.sustainFeasible == true or sustainStatus == "pass"
	result.status = sustainStatus
	result.feasible = result.sustainFeasible
	result.scope = scope
	result.optimizerScheduleApplied = true
	result.scheduleEstimate = true
	result.damageScheduleCertified = false
	return result
end

return activity
