--
-- Module: preserve the live Analyzer counters while the native search moves
-- between exact evaluation and structural validation phases.
--
local progress = { }

local function copy(source)
	local result = { }
	for key, value in pairs(source or { }) do result[key] = value end
	return result
end

local function copyNumericCounts(source)
	local result = { }
	for key, value in pairs(source or { }) do
		local count = tonumber(value)
		if type(key) == "string" and count and count == count and count ~= math.huge and count ~= -math.huge then
			result[key] = count
		end
	end
	return result
end

local function copyFamilyPlan(source)
	if type(source) ~= "table" then return nil end
	local familyOrder = { }
	for _, family in ipairs(source.familyOrder or { }) do
		if type(family) == "string" then familyOrder[#familyOrder + 1] = family end
	end
	return {
		status = source.status,
		windowSize = tonumber(source.windowSize),
		windowFamilyDiversity = tonumber(source.windowFamilyDiversity),
		familyOrder = familyOrder,
		windowFamilyCounts = copyNumericCounts(source.windowFamilyCounts),
	}
end

function progress.Merge(job, update, phaseCoverage)
	local previous = job and job.progress or { }
	local snapshot = copy(previous)
	for key, value in pairs(update or { }) do snapshot[key] = value end
	phaseCoverage = phaseCoverage or { }
	for _, field in ipairs({
		{ name = "generatedProposals", source = "generatedCandidates" },
		{ name = "uniqueProposals", source = "uniqueCandidates" },
		{ name = "retainedProposals", source = "retainedCandidates" },
	}) do
		local current = tonumber(phaseCoverage[field.source])
		if current then
			snapshot[field.name] = current
		elseif tonumber(snapshot[field.name]) == nil then
			snapshot[field.name] = 0
		end
	end
	if type(phaseCoverage.exactEvaluationPlan) == "table" then
		snapshot.exactEvaluationPlan = copyFamilyPlan(phaseCoverage.exactEvaluationPlan)
	end
	if type(phaseCoverage.exactEvaluationsByFamily) == "table" then
		snapshot.exactEvaluationsByFamily = copyNumericCounts(phaseCoverage.exactEvaluationsByFamily)
	end
	snapshot.exactFeasibleMutations = tonumber(job and job.routePlannerExactFeasibleMutations)
		or tonumber(snapshot.exactFeasibleMutations) or 0
	if tonumber(snapshot.paretoRoutes) == nil then snapshot.paretoRoutes = 0 end
	if job then job.progress = snapshot end
	return snapshot
end

return progress
