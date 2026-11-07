-- Path of Building
--
-- Module: deterministic hierarchical passive-point controller.
-- It is the rule-based HRL bootstrap: each point plan is budget-conserving,
-- zonal experts only propose routes, and the normal PoB validator remains the
-- sole authority for legality and exact build metrics. No popularity signal or
-- learned score is used here.
--
local t_insert = table.insert
local t_sort = table.sort
local SpatialZones = require("Modules.Optimizer.SpatialZones")
local TreeSearch = require("Modules.Optimizer.TreeSearch")

local controller = { policyVersion = "hrl-zones-v1" }
local orderedZones = SpatialZones.RegionNames()

local function lower(value)
	return tostring(value or ""):lower()
end

local function shallowCopy(source)
	local result = { }
	for key, value in pairs(source or { }) do result[key] = value end
	return result
end

local function positiveInteger(value)
	return type(value) == "number" and value == math.floor(value) and value >= 0 and value <= 120
end

local zoneRank = { }
for index, name in ipairs(orderedZones) do zoneRank[name] = index end

function controller.AllocatePointPlans(totalPoints, zones, seed)
	if not positiveInteger(totalPoints) then
		return nil, "Hierarchical point budget must be an integer from 0 to 120"
	end
	local seen, activeZones = { }, { }
	for _, zoneName in ipairs(zones or { }) do
		local canonical = SpatialZones.CanonicalRegionName(zoneName)
		if canonical and not seen[canonical] then
			seen[canonical] = true
			activeZones[#activeZones + 1] = canonical
		end
	end
	t_sort(activeZones, function(first, second)
		return (zoneRank[first] or math.huge) < (zoneRank[second] or math.huge)
	end)
	if #activeZones == 0 then return nil, "No permitted spatial zone is available to the hierarchical controller" end

	local plans, planKeys = { }, { }
	local function appendPlan(id, strategy, budgets)
		local keyParts, allocated = { }, 0
		for _, zoneName in ipairs(activeZones) do
			local budget = budgets[zoneName] or 0
			allocated = allocated + budget
			keyParts[#keyParts + 1] = zoneName .. "=" .. tostring(budget)
		end
		local key = table.concat(keyParts, "|")
		if allocated ~= totalPoints or planKeys[key] then return end
		planKeys[key] = true
		plans[#plans + 1] = {
			id = id,
			strategy = strategy,
			pointBudget = totalPoints,
			allocatedPoints = allocated,
			allocations = budgets,
		}
	end

	local balanced = { }
	local baseShare = math.floor(totalPoints / #activeZones)
	local remainder = totalPoints - baseShare * #activeZones
	local rotation = (#activeZones > 0 and math.floor(tonumber(seed) or 0) % #activeZones) or 0
	for index, zoneName in ipairs(activeZones) do balanced[zoneName] = baseShare end
	for offset = 1, remainder do
		local index = ((rotation + offset - 1) % #activeZones) + 1
		balanced[activeZones[index]] = balanced[activeZones[index]] + 1
	end
	appendPlan("balanced", "balanced", balanced)

	for _, zoneName in ipairs(activeZones) do
		local focused = { }
		for _, name in ipairs(activeZones) do focused[name] = name == zoneName and totalPoints or 0 end
		appendPlan("focus_" .. lower(zoneName), "single_zone_focus", focused)
	end
	return plans
end

function controller.DistributeCandidateSlots(totalSlots, entries, seed)
	if type(totalSlots) ~= "number" or totalSlots ~= math.floor(totalSlots) or totalSlots < 0 then
		return nil, "Candidate slots must be a non-negative integer"
	end
	local quotas = { }
	for index = 1, #(entries or { }) do quotas[index] = 0 end
	if totalSlots == 0 or #quotas == 0 then return quotas end
	local baseShare = math.floor(totalSlots / #quotas)
	local remainder = totalSlots - baseShare * #quotas
	for index = 1, #quotas do quotas[index] = baseShare end
	local rotation = math.floor(tonumber(seed) or 0) % #quotas
	for offset = 1, remainder do
		local index = ((rotation + offset - 1) % #quotas) + 1
		quotas[index] = quotas[index] + 1
	end
	return quotas
end

local function regionSet(regions)
	local result = { }
	for _, name in ipairs(regions or { }) do
		local canonical = SpatialZones.CanonicalRegionName(name)
		if canonical then result[lower(canonical)] = canonical end
	end
	return result
end

local function contains(values)
	for _, value in ipairs(values or { }) do
		if value ~= nil and value ~= "" then return true end
	end
	return false
end

local function supportsZonalSearch(inputs)
	local branch = inputs.branch or { }
	local search = inputs.search or { }
	return branch.partition == "spatial"
		and not (inputs.targetNodeIds and inputs.targetNodeIds[1])
		and not contains(branch.required)
		and not contains(search.addNodeIds)
		and not contains(search.removeNodeIds)
		and not contains(search.requiredNodeIds)
		and not contains(search.forbiddenNodeIds)
end

local function availableTargetZones(inputs)
	local allowed = regionSet(inputs.branch and inputs.branch.allowed)
	local forbidden = regionSet(inputs.branch and inputs.branch.forbidden)
	local zones = { }
	for _, zoneName in ipairs(orderedZones) do
		local key = lower(zoneName)
		if not forbidden[key] and (not next(allowed) or allowed[key]) then
			zones[#zones + 1] = zoneName
		end
	end
	return zones
end

local function candidateKey(candidate)
	local ids = { }
	for _, nodeId in ipairs(candidate.nodeIds or { }) do ids[#ids + 1] = nodeId end
	t_sort(ids)
	return table.concat(ids, ",")
end

local function appendInterleaved(destination, general, zonal, limit)
	local seen = { }
	local generalIndex, zonalIndex = 1, 1
	local takeGeneral = true
	while #destination < limit and (general[generalIndex] or zonal[zonalIndex]) do
		local source
		if takeGeneral then
			source = general[generalIndex]
			generalIndex = generalIndex + (source and 1 or 0)
		else
			source = zonal[zonalIndex]
			zonalIndex = zonalIndex + (source and 1 or 0)
		end
		if not source then
			if takeGeneral then source = zonal[zonalIndex]; zonalIndex = zonalIndex + (source and 1 or 0)
			else source = general[generalIndex]; generalIndex = generalIndex + (source and 1 or 0) end
		end
		if source then
			local key = candidateKey(source)
			local existing = seen[key]
			if existing then
				if source.hierarchicalExpert then
					existing.hierarchicalExperts = existing.hierarchicalExperts or { }
					existing.hierarchicalExperts[#existing.hierarchicalExperts + 1] = source.hierarchicalExpert
				end
			else
				seen[key] = source
				t_insert(destination, source)
			end
		end
		takeGeneral = not takeGeneral
	end
end

-- Generates exact-search proposals, not approvals. Each point plan conserves
-- the supplied incremental point budget; the global candidate validator later
-- checks the union of multi-zone paths against the same total cap.
function controller.BuildSpatialCandidates(spec, inputs, candidateLimit, pointBudget, regionByNode, control, progressFunc)
	local coverage = {
		policyVersion = controller.policyVersion,
		mode = "not_applicable",
		pointBudget = pointBudget,
		pointPlans = { },
		experts = { },
		zoneResults = { },
		generatedCandidates = 0,
		generalCandidates = 0,
		zonalCandidates = 0,
		exactEvaluations = 0,
		exactCombinedEvaluations = 0,
	}
	if not supportsZonalSearch(inputs) or candidateLimit < 3 or not positiveInteger(pointBudget) then
		return nil, nil, false, coverage, false
	end
	local zones = availableTargetZones(inputs)
	if #zones == 0 then return nil, "No permitted spatial zone is available to the hierarchical controller", false, coverage, true end
	local plans, planError = controller.AllocatePointPlans(pointBudget, zones, inputs.search.seed)
	if not plans then return nil, planError, false, coverage, false end
	coverage.mode = "deterministic_hierarchical_spatial"
	coverage.pointPlans = plans
	coverage.activeZones = zones

	local zonalSlotBudget = math.floor(candidateLimit / 2)
	local generalSlotBudget = candidateLimit - zonalSlotBudget
	if zonalSlotBudget == 0 then return nil, nil, false, coverage, false end
	local function generalProgress(done, total, expanded, targetId)
		if progressFunc then progressFunc(done, total, expanded, targetId, nil, nil, "rotas gerais") end
	end
	local generalCandidates, generalError, generalCancelled = TreeSearch.BuildCandidateNodes(
		spec, inputs, generalSlotBudget, generalProgress, pointBudget, control, regionByNode)
	if generalCancelled then return { }, nil, true, coverage, true end
	if generalError then return nil, generalError, false, coverage, false end
	coverage.generalCandidates = #generalCandidates

	local experts = { }
	for planIndex, plan in ipairs(plans) do
		for zoneIndex, zoneName in ipairs(zones) do
			local expertBudget = plan.allocations[zoneName] or 0
			if expertBudget > 0 then
				experts[#experts + 1] = {
					planIndex = planIndex,
					planId = plan.id,
					zone = zoneName,
					zoneIndex = zoneIndex,
					pointBudget = expertBudget,
				}
			end
		end
	end
	-- Reserve one route slot per permitted zone for the balanced point plan
	-- before spending remaining slots on focused plans. Tiny budgets still make
	-- deterministic progress, while ordinary budgets do not starve whole zones.
	local quotas = { }
	for index = 1, #experts do quotas[index] = 0 end
	local remainingSlots = zonalSlotBudget
	local balancedIndexes = { }
	local focusedIndexes = { }
	for index, expert in ipairs(experts) do
		if expert.planId == "balanced" then balancedIndexes[#balancedIndexes + 1] = index
		else focusedIndexes[#focusedIndexes + 1] = index end
	end
	local startIndex = (#balancedIndexes > 0 and (math.floor(tonumber(inputs.search.seed) or 0) % #balancedIndexes)) or 0
	for offset = 1, #balancedIndexes do
		if remainingSlots <= 0 then break end
		local index = ((startIndex + offset - 1) % #balancedIndexes) + 1
		quotas[balancedIndexes[index]] = 1
		remainingSlots = remainingSlots - 1
	end
	if remainingSlots > 0 and #focusedIndexes > 0 then
		local focusEntries = { }
		for _, index in ipairs(focusedIndexes) do focusEntries[#focusEntries + 1] = experts[index] end
		local focusQuotas, quotaError = controller.DistributeCandidateSlots(remainingSlots, focusEntries, inputs.search.seed)
		if not focusQuotas then return nil, quotaError, false, coverage, true end
		for index, quota in ipairs(focusQuotas) do quotas[focusedIndexes[index]] = quota end
	end
	local zonalCandidates = { }
	for expertIndex, expert in ipairs(experts) do
		local quota = quotas[expertIndex] or 0
		expert.candidateQuota = quota
		expert.generatedCandidates = 0
		if quota > 0 then
			local expertInputs = shallowCopy(inputs)
			expertInputs.branch = shallowCopy(inputs.branch)
			-- `required` guides this expert toward a zone while preserving the
			-- user's hard allow/deny filters and the source tree's existing nodes.
			expertInputs.branch.required = { expert.zone }
			expertInputs.search = shallowCopy(inputs.search)
			expertInputs.search.seed = ((tonumber(inputs.search.seed) or 0) + expert.planIndex * 104729 + expert.zoneIndex * 7919) % 2147483647
			local function expertProgress(done, total, expanded, targetId)
				if progressFunc then progressFunc(done, total, expanded, targetId, expert.zone, expert.planId,
					string.format("plano %d/%d", expert.planIndex, #plans)) end
			end
			local generated, expertError, cancelled = TreeSearch.BuildCandidateNodes(
				spec, expertInputs, quota, expertProgress, expert.pointBudget, control, regionByNode)
			if cancelled then return { }, nil, true, coverage, true end
			expert.generatedCandidates = #generated
			if expertError then expert.error = tostring(expertError):sub(1, 240) end
			for _, candidate in ipairs(generated or { }) do
				candidate.hierarchicalExpert = {
					policyVersion = controller.policyVersion,
					planId = expert.planId,
					strategy = plans[expert.planIndex].strategy,
					zone = expert.zone,
					pointBudget = expert.pointBudget,
				}
				candidate.label = string.format("[%s: %s points] %s", expert.zone, expert.pointBudget, candidate.label or "Passive route")
				zonalCandidates[#zonalCandidates + 1] = candidate
			end
		end
		coverage.experts[#coverage.experts + 1] = expert
	end
	local result = { }
	appendInterleaved(result, generalCandidates, zonalCandidates, candidateLimit)
	coverage.zonalCandidates = #zonalCandidates
	coverage.generatedCandidates = #result
	coverage.candidateSlots = candidateLimit
	coverage.budgetConserved = true
	for _, plan in ipairs(plans) do
		if plan.allocatedPoints ~= pointBudget then coverage.budgetConserved = false break end
	end
	coverage.scheduledExpertSlots = 0
	for _, expert in ipairs(coverage.experts) do coverage.scheduledExpertSlots = coverage.scheduledExpertSlots + (expert.candidateQuota or 0) end
	return result, nil, false, coverage, true
end

return controller
