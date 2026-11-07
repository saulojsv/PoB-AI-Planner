-- Path of Building
--
-- Module: bounded, exact-feedback repair ordering for local equipment.
-- Native item modifiers are used only to rank proposals. Candidate approval
-- and all reported attributes/resistances still come from CalcPerform output.
--
local t_sort = table.sort

local validator = require("Modules.Optimizer.Validator")
local Equipment = require("Modules.Optimizer.Equipment")

local gearRepair = { }

local attributeTargets = {
	Str = { Str = true, StrDex = true, StrInt = true, All = true },
	Dex = { Dex = true, StrDex = true, DexInt = true, All = true },
	Int = { Int = true, StrInt = true, DexInt = true, All = true },
	Omni = { Omni = true, Str = true, Dex = true, Int = true, StrDex = true, StrInt = true, DexInt = true, All = true },
}

local MAX_ARCHIVED_SYNTHETIC_REPAIR_ITEMS = 12

local resistanceTargets = {
	FireResist = { FireResist = true, ElementalResist = true, AllResist = true },
	ColdResist = { ColdResist = true, ElementalResist = true, AllResist = true },
	LightningResist = { LightningResist = true, ElementalResist = true, AllResist = true },
	ChaosResist = { ChaosResist = true, AllResist = true },
}

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function resistanceStat(metricKey)
	if type(metricKey) ~= "string" then return nil end
	for stat in pairs(resistanceTargets) do
		if metricKey == stat or metricKey == stat .. "OverCap" then return stat end
	end
	return nil
end

local function attributeStat(requirementKey)
	if type(requirementKey) ~= "string" then return nil end
	local stat = requirementKey:match("^attribute_requirement_(.+)$")
	if stat == "Str" or stat == "Dex" or stat == "Int" or stat == "Omni" then return stat end
	return nil
end

-- Only actionable deficits with exact actual/required values become repair
-- targets. Missing or unsupported metrics never activate this heuristic.
function gearRepair.NeedsFromEvaluation(evaluation, parsed)
	local needs, seen = { }, { }
	local requirements = evaluation and evaluation.requirements
	for _, violation in ipairs(requirements and requirements.violations or { }) do
		local stat = attributeStat(violation.key)
		if stat and isFinite(violation.actual) and isFinite(violation.required) and violation.required > violation.actual then
			local key = "attribute:" .. stat
			if not seen[key] then
				seen[key] = true
				needs[#needs + 1] = {
					key = key, kind = "attribute", stat = stat, metricKey = stat,
					requiredMetricKey = "Req" .. stat,
					actual = violation.actual, required = violation.required,
					deficit = violation.required - violation.actual,
					label = violation.label or (stat .. " requirement"),
				}
			end
		end
	end
	local function addResistanceNeed(violation)
		local constraint = parsed and parsed.hard and parsed.hard[violation.key]
		local metricKey = constraint and (constraint.metricKey or violation.key) or violation.key
		local stat = resistanceStat(metricKey) or resistanceStat(violation.key)
		if stat and isFinite(violation.actual) and isFinite(violation.required) and violation.actual < violation.required then
			local key = "resistance:" .. metricKey
			if not seen[key] then
				seen[key] = true
				needs[#needs + 1] = {
					key = key, kind = "resistance", stat = stat, metricKey = metricKey,
					actual = violation.actual, required = violation.required,
					deficit = violation.required - violation.actual,
					label = violation.label or metricKey,
				}
			end
		end
	end
	-- Exact route evaluations already carry the gate's own `actual` and
	-- `required` values. Prefer those records so route-specific misses can be
	-- repaired even if the baseline-derived hard-gate cache is incomplete.
	for _, violation in ipairs(evaluation and evaluation.violations or { }) do addResistanceNeed(violation) end
	local resistanceGate = evaluation and evaluation.metrics and validator.Check(parsed or { hard = { } }, evaluation.metrics)
	for _, violation in ipairs(resistanceGate and resistanceGate.violations or { }) do addResistanceNeed(violation) end
	t_sort(needs, function(a, b)
		if a.kind ~= b.kind then return a.kind == "attribute" end
		return a.key < b.key
	end)
	return needs
end

local function contributionForItem(item, need)
	local modList = item and item.modList
	if type(modList) ~= "table" then return 0 end
	local targets = need.kind == "attribute" and attributeTargets[need.stat] or resistanceTargets[need.stat]
	if not targets then return 0 end
	local total = 0
	for _, mod in ipairs(modList) do
		-- Avoid evaluating conditions, skill flags, or per-stat formulae outside
		-- the native calculation context. This is a ranking hint, never a gate.
		if type(mod) == "table" and type(mod.name) == "string" and targets[mod.name] and mod.type == "BASE"
			and mod[1] == nil and (mod.flags == nil or mod.flags == 0)
			and (mod.keywordFlags == nil or mod.keywordFlags == 0)
			and isFinite(mod.value) and mod.value > 0 then
			total = total + mod.value
		end
	end
	return total
end

local function candidateScore(candidate, itemsTab, needs)
	local gear = candidate and candidate.gearVariant
	if not gear then return 0 end
	if gear.catalystSearch == true then
		-- Catalyst proposals are generated only for exact baseline deficits, so
		-- place them ahead of generic stored-item alternatives in the same bounded
		-- repair reserve. The exact engine and all hard gates still decide value.
		return 100 + #(gear.generatedItems or { })
	end
	local score = 0
	local repairItems = { }
	if gear.inventorySearch == true then
		for _, slotName in ipairs(gear.changedSlots or { }) do
			local itemId = gear.overrides and gear.overrides[slotName]
			local item = itemId and itemsTab and itemsTab.items and itemsTab.items[itemId]
			if item then repairItems[#repairItems + 1] = item end
		end
	elseif gear.syntheticSearch == true then
		-- Generated single items and bounded item portfolios contain their parsed
		-- native Item/modList rows. Use every member to rank a bounded repair; the
		-- candidate is still reparsed and exact-calculated before acceptance.
		for _, entry in ipairs(gear.generatedItems or { }) do
			if type(entry) == "table" and type(entry.item) == "table" then
				repairItems[#repairItems + 1] = entry.item
			end
		end
	else
		return 0
	end
	for _, item in ipairs(repairItems) do
		for _, need in ipairs(needs or { }) do
			local contribution = contributionForItem(item, need)
			if contribution > 0 then
				score = score + math.min(contribution, need.deficit) / math.max(need.deficit, 1)
			end
		end
	end
	return score
end

local function sameItemId(left, right)
	local leftNumber, rightNumber = tonumber(left), tonumber(right)
	if leftNumber and rightNumber then return leftNumber == rightNumber end
	return tostring(left) == tostring(right)
end

local function socketRepairPlanForItem(gear, slotName, itemId)
	for _, entry in ipairs(gear and gear.generatedItems or { }) do
		if type(entry) == "table" and (entry.slotName or entry.slot) == slotName
			and sameItemId(entry.tempId or entry.itemId, itemId)
			and type(entry.socketPlan) == "table" and entry.socketPlan.repair == true then
			return entry.socketPlan
		end
	end
	return nil
end

local function socketRepairPlansMatch(first, second)
	if type(first) ~= "table" or type(second) ~= "table"
		or first.repair ~= true or second.repair ~= true
		or first.groupIndex == nil or first.groupIndex ~= second.groupIndex then
		return false
	end
	for _, field in ipairs({ "colors", "linkGroups" }) do
		local firstValues, secondValues = first[field], second[field]
		if type(firstValues) ~= "table" or type(secondValues) ~= "table"
			or #firstValues == 0 or #firstValues ~= #secondValues then
			return false
		end
		for index, value in ipairs(firstValues) do
			if value ~= secondValues[index] then return false end
		end
	end
	return true
end

local function replacementKeepsSocketedSkill(sourceGear, mutationGear, slotName, sourceItemId, mutationItemId)
	if sourceGear.socketRepair ~= true or mutationGear.socketRepair ~= true or mutationGear.syntheticSearch ~= true then
		return false
	end
	local sourcePlan = socketRepairPlanForItem(sourceGear, slotName, sourceItemId)
	local mutationPlan = socketRepairPlanForItem(mutationGear, slotName, mutationItemId)
	if not mutationPlan then return false end
	local sourceBinding = sourceGear.socketBinding
	local mutationBinding = mutationGear.socketBinding
	if type(mutationBinding) == "table" and (mutationBinding.groupIndex ~= mutationPlan.groupIndex
		or mutationBinding.slotName ~= slotName or mutationBinding.itemId == nil
		or not sameItemId(mutationBinding.itemId, mutationItemId)) then
		return false
	end
	if type(sourceBinding) == "table" then
		if sourceBinding.groupIndex == nil or sourceBinding.slotName ~= slotName
			or (sourceBinding.itemId ~= nil and not sameItemId(sourceBinding.itemId, sourceItemId))
			or mutationPlan.groupIndex ~= sourceBinding.groupIndex then
			return false
		end
		return not sourcePlan or socketRepairPlansMatch(sourcePlan, mutationPlan)
	end
	-- Already-bound skill groups omit socketBinding. The two generated native
	-- plans must then prove the same group, socket colors, and link topology.
	return socketRepairPlansMatch(sourcePlan, mutationPlan)
end

local function mergeArchivedRepairVariants(routeGear, mutationGear, build)
	local route = Equipment.CopyVariant(routeGear) or { }
	local mutation = Equipment.CopyVariant(mutationGear) or { }
	local replacedSlots = { }
	for slotName, mutationItemId in pairs(mutation.overrides or { }) do
		local routeItemId = route.overrides and route.overrides[slotName]
		if routeItemId ~= nil and not sameItemId(routeItemId, mutationItemId) then
			if not replacementKeepsSocketedSkill(route, mutation, slotName, routeItemId, mutationItemId) then
				return nil, "Gear variants require different items in " .. tostring(slotName)
			end
			replacedSlots[slotName] = true
		end
	end
	if next(replacedSlots) == nil then
		return Equipment.MergeVariants(route, mutation, { build = build })
	end
	for slotName in pairs(replacedSlots) do route.overrides[slotName] = nil end
	local function withoutSlots(entries, slotField)
		local kept = { }
		for _, entry in ipairs(entries or { }) do
			local slotName = type(entry) == "table" and (entry[slotField] or entry.slot)
			if not slotName or not replacedSlots[slotName] then kept[#kept + 1] = entry end
		end
		return kept
	end
	route.items = withoutSlots(route.items, "slot")
	route.generatedItems = withoutSlots(route.generatedItems, "slotName")
	if type(route.socketBinding) == "table" and replacedSlots[route.socketBinding.slotName] then
		route.socketBinding = nil
	end
	local hasRemainingSocketRepair = false
	for _, entry in ipairs(route.generatedItems or { }) do
		if type(entry) == "table" and ((entry.socketPlan and entry.socketPlan.repair == true)
			or entry.kind == "socket_repair") then
			hasRemainingSocketRepair = true
			break
		end
	end
	route.socketRepair = hasRemainingSocketRepair and true or nil
	route.socketRepairOnly = nil
	-- Do not rebuild item descriptions from the source Items tab here: replacement
	-- items have temporary native PoB IDs installed only in the disposable clone.
	return Equipment.MergeVariants(route, mutation)
end

-- Stable deterministic ranking. Unscored and unique/conditional items remain
-- in the proposal set and can still win after their full exact calculation.
function gearRepair.RankCandidates(candidates, itemsTab, needs)
	local ranked = { }
	for index, candidate in ipairs(candidates or { }) do
		local score = candidateScore(candidate, itemsTab, needs)
		candidate.requirementRepairScore = score
		candidate.requirementRepair = score > 0
		ranked[#ranked + 1] = { index = index, score = score, candidate = candidate }
	end
	t_sort(ranked, function(a, b)
		if a.score ~= b.score then return a.score > b.score end
		return a.index < b.index
	end)
	local result = { }
	for index, row in ipairs(ranked) do
		local candidate = row.candidate
		if row.score > 0 then
			candidate.label = "Local requirement repair: " .. tostring(candidate.label or "stored item replacement")
		end
		result[index] = candidate
	end
	return result
end

function gearRepair.NewCoverage()
	return {
		active = false,
		maxPasses = 1,
		baselineNeeds = { },
		exactCandidateEvaluations = 0,
		improvedExactEvaluations = 0,
		fullyRepairedExactEvaluations = 0,
		unsupportedExactEvaluations = 0,
		bestRemainingDeficit = nil,
		bestCandidate = nil,
	}
end

local function exactNeedMetrics(metrics, needs)
	local total, rows = 0, { }
	for _, need in ipairs(needs or { }) do
		local actual = metrics and metrics[need.metricKey]
		local required = need.required
		if need.kind == "attribute" then
			required = metrics and metrics[need.requiredMetricKey] or required
		end
		if not isFinite(actual) or not isFinite(required) then
			total = math.huge
			rows[#rows + 1] = {
				key = need.key, label = need.label,
				actual = isFinite(actual) and actual or nil,
				required = isFinite(required) and required or nil,
				status = "unsupported",
			}
		else
			local deficit = math.max(0, required - actual)
			rows[#rows + 1] = { key = need.key, label = need.label, actual = actual, required = required, deficit = deficit }
			if total ~= math.huge then total = total + deficit / math.max(math.abs(required), 1) end
		end
	end
	return total, rows
end

function gearRepair.Activate(coverage, evaluation, parsed, candidates, itemsTab, activeCandidates)
	local needs = gearRepair.NeedsFromEvaluation(evaluation, parsed)
	coverage.baselineNeeds = needs
	coverage.baselineDeficit, coverage.baselineValues = exactNeedMetrics(evaluation and evaluation.metrics, needs)
	coverage.active = #needs > 0
	if not coverage.active then return { }, false end
	local ranked = gearRepair.RankCandidates(candidates, itemsTab, needs)
	local selected = { }
	for index = 1, math.min(#ranked, math.max(0, activeCandidates or #ranked)) do
		local candidate = ranked[index]
		if candidate.gearVariant then candidate.gearVariant.requirementRepair = true end
		selected[#selected + 1] = candidate
	end
	coverage.availableCandidates = #ranked
	coverage.scheduledCandidates = #selected
	return selected, true
end

-- An archived passive route can introduce a hard-gate miss even when the
-- baseline passes. Use the exact near-miss metrics to rank compatible stored
-- item fixes, then carry the failed route and socket-repair item into a new
-- candidate for a fresh native calculation.
function gearRepair.BuildArchivedGateRepairCandidates(routeCandidate, evaluation, parsed, equipmentCandidates, build, limit, syntheticCandidates)
	local repairs, coverage = { }, {
		active = false,
		needs = { },
		exactViolationCount = #(evaluation and evaluation.violations or { }),
		inputEquipmentCandidateCount = #(equipmentCandidates or { }),
		inputSyntheticCandidateCount = #(syntheticCandidates or { }),
		inventoryMutationCandidateCount = 0,
		syntheticMutationCandidateCount = 0,
		inventorySearchFlagCandidateCount = 0,
		syntheticSearchFlagCandidateCount = 0,
		syntheticSingleItemCandidateCount = 0,
		syntheticPortfolioCandidateCount = 0,
		syntheticRejectedShapeCandidateCount = 0,
		syntheticPairFlagCandidateCount = 0,
		syntheticTripleFlagCandidateCount = 0,
		syntheticGeneratedItemCountDistribution = { },
		availableItemCandidates = 0,
		repairPoolAfterFlaskFilterCount = 0,
		generatedCandidates = 0,
		structuralRejections = 0,
		structuralRejectionReasons = { },
		status = "not_applicable",
		flaskCandidatesRejected = 0,
	}
	if type(routeCandidate) ~= "table" or routeCandidate.archivedRoutePattern ~= true
		or routeCandidate.archiveGateRepairAttempted == true or (tonumber(limit) or 0) <= 0 then
		return repairs, coverage
	end
	coverage.status = "no_eligible_inventory_candidates"
	local repairPool = { }
	for _, candidate in ipairs(equipmentCandidates or { }) do
		if candidate and candidate.gearVariant and candidate.gearVariant.inventorySearch == true then
			coverage.inventorySearchFlagCandidateCount = coverage.inventorySearchFlagCandidateCount + 1
			local copy = { }
			for key, value in pairs(candidate) do copy[key] = value end
			copy.gearVariant = Equipment.CopyVariant(candidate.gearVariant)
			repairPool[#repairPool + 1] = copy
		end
	end
	coverage.inventoryMutationCandidateCount = #repairPool
	for _, candidate in ipairs(syntheticCandidates or { }) do
		local gear = candidate and candidate.gearVariant
		if gear and gear.syntheticSearch == true then
			coverage.syntheticSearchFlagCandidateCount = coverage.syntheticSearchFlagCandidateCount + 1
			local generatedItemCount = #(gear.generatedItems or { })
			local countKey = tostring(generatedItemCount)
			coverage.syntheticGeneratedItemCountDistribution[countKey] =
				(coverage.syntheticGeneratedItemCountDistribution[countKey] or 0) + 1
			if gear.syntheticPair == true then
				coverage.syntheticPairFlagCandidateCount = coverage.syntheticPairFlagCandidateCount + 1
			end
			if gear.syntheticTriple == true then
				coverage.syntheticTripleFlagCandidateCount = coverage.syntheticTripleFlagCandidateCount + 1
			end
			local validPortfolio = generatedItemCount >= 1
				and generatedItemCount <= MAX_ARCHIVED_SYNTHETIC_REPAIR_ITEMS
				and not (gear.syntheticPair == true and generatedItemCount < 2)
				and not (gear.syntheticTriple == true and generatedItemCount < 3)
				and not (gear.syntheticPair == true and gear.syntheticTriple == true)
			if validPortfolio then
				if generatedItemCount == 1 then
					coverage.syntheticSingleItemCandidateCount = coverage.syntheticSingleItemCandidateCount + 1
				else
					coverage.syntheticPortfolioCandidateCount = coverage.syntheticPortfolioCandidateCount + 1
				end
				local copy = { }
				for key, value in pairs(candidate) do copy[key] = value end
				copy.gearVariant = Equipment.CopyVariant(gear)
				repairPool[#repairPool + 1] = copy
				coverage.syntheticMutationCandidateCount = coverage.syntheticMutationCandidateCount + 1
			else
				coverage.syntheticRejectedShapeCandidateCount = coverage.syntheticRejectedShapeCandidateCount + 1
			end
		end
	end
	if parsed and parsed.search and parsed.search.routePlannerRunSpec then
		local safe, rejected = Equipment.FilterFlaskMutations(build, repairPool)
		repairPool = safe
		coverage.flaskCandidatesRejected = rejected
	end
	coverage.repairPoolAfterFlaskFilterCount = #repairPool
	local repairCoverage = gearRepair.NewCoverage()
	local rankedRepairs, active = gearRepair.Activate(repairCoverage, evaluation, parsed, repairPool,
		build and build.itemsTab, #repairPool)
	coverage.active = active == true
	coverage.needs = repairCoverage.baselineNeeds or { }
	coverage.availableItemCandidates = repairCoverage.availableCandidates or 0
	if not active then
		coverage.status = "no_actionable_exact_gate_deficit"
		return repairs, coverage
	end
	coverage.status = #repairPool > 0 and "repair_candidates_ranked" or "no_eligible_inventory_candidates"
	for _, mutation in ipairs(rankedRepairs or { }) do
		if #repairs >= limit then break end
		local mergedGear, mergeError = mergeArchivedRepairVariants(routeCandidate.gearVariant, mutation.gearVariant, build)
		if mergedGear then
			local candidate = { }
			for key, value in pairs(routeCandidate) do candidate[key] = value end
			candidate.nodeIds = { }
			for _, nodeId in ipairs(routeCandidate.nodeIds or { }) do candidate.nodeIds[#candidate.nodeIds + 1] = nodeId end
			candidate.removeNodeIds = { }
			for _, nodeId in ipairs(routeCandidate.removeNodeIds or { }) do candidate.removeNodeIds[#candidate.removeNodeIds + 1] = nodeId end
			candidate.gearVariant = mergedGear
			candidate.evaluation = nil
			candidate.feasible = nil
			candidate.sourceSignature = nil
			candidate.canonicalHash = nil
			candidate.archiveGateRepairAttempted = true
			candidate.archiveGateRepairNeeds = { }
			for _, need in ipairs(coverage.needs) do
				candidate.archiveGateRepairNeeds[#candidate.archiveGateRepairNeeds + 1] = {
					key = need.key, label = need.label, actual = need.actual,
					required = need.required, deficit = need.deficit,
				}
			end
			candidate.archivedRoutePattern = true
			candidate.archiveDerivedPassiveRoute = true
			candidate.archivedRouteComposition = true
			candidate.plannerFamilyOverride = "combined"
			candidate.label = "Reparo de rota arquivada: " .. tostring(routeCandidate.label or "rota")
				.. " + " .. tostring(mutation.label or "ajuste de equipamento")
			repairs[#repairs + 1] = candidate
		else
			coverage.structuralRejections = coverage.structuralRejections + 1
			local reason = tostring(mergeError or "Unknown gear composition rejection"):sub(1, 180)
			coverage.structuralRejectionReasons[reason] = (coverage.structuralRejectionReasons[reason] or 0) + 1
		end
	end
	coverage.generatedCandidates = #repairs
	if #repairs > 0 then
		coverage.status = "generated"
	elseif coverage.structuralRejections > 0 then
		coverage.status = "all_compositions_rejected"
	end
	return repairs, coverage
end

function gearRepair.RecordExact(coverage, candidate, evaluation)
	if not coverage or not coverage.active or not (candidate and candidate.gearVariant
		and (candidate.gearVariant.inventorySearch or candidate.gearVariant.catalystSearch))
		or candidate.gearVariant.inventoryRoutePair then return end
	coverage.exactCandidateEvaluations = coverage.exactCandidateEvaluations + 1
	local deficit, values = exactNeedMetrics(evaluation and evaluation.metrics, coverage.baselineNeeds)
	if not isFinite(deficit) then
		coverage.unsupportedExactEvaluations = coverage.unsupportedExactEvaluations + 1
		return
	end
	if deficit < (coverage.baselineDeficit or math.huge) then
		coverage.improvedExactEvaluations = coverage.improvedExactEvaluations + 1
	end
	if deficit <= 1e-10 then coverage.fullyRepairedExactEvaluations = coverage.fullyRepairedExactEvaluations + 1 end
	if coverage.bestRemainingDeficit == nil or deficit < coverage.bestRemainingDeficit then
		coverage.bestRemainingDeficit = deficit
		coverage.bestRemainingValues = values
		coverage.bestCandidate = tostring(candidate.label or "Local item candidate"):sub(1, 160)
	end
end

return gearRepair
