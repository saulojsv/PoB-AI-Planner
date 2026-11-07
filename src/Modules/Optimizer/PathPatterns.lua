-- Path of Building
--
-- Module: contextual mining of exact optimizer route outcomes.
-- Pattern scores are associations used only to order proposals. They never
-- prune candidates, alter gates, or replace the native PoB calculation.

local Experience = require("Modules.Optimizer.PathExperience")
local patterns = { }

local MIN_SKILL_BUILD_GROUPS = 3
local MIN_ARCHETYPE_BUILD_GROUPS = 5
local MAX_INDEX_RECORDS = 3000
local MAX_NODE_MOTIFS = 32
local MAX_EDGE_MOTIFS = 32
local EXPLORE_AFTER_FIRST_POSITIVE = 1
local EXPLORE_AFTER_LATER_POSITIVES = 3

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function clamp(value, minimum, maximum)
	return math.max(minimum, math.min(maximum, value))
end

local function baselineKey(record)
	local context = record.context or { }
	return table.concat({
		tostring(record.sourceBuildHash or ""),
		tostring(context.scenarioProfile or ""),
		tostring(context.scenarioEnemyPreset or ""),
		tostring(context.objectiveMetric or ""),
		tostring(context.classId or ""),
		tostring(context.ascendancyId or ""),
		tostring(context.skillId or ""),
		tostring(context.constraintDigest or ""),
		tostring(record.engine and record.engine.dataVersion or ""),
		tostring(record.engine and record.engine.treeVersion or ""),
	}, "\31")
end

local function sampled(values, maximum)
	if #values <= maximum then return values end
	local result = { }
	for index = 1, maximum do
		local sourceIndex = math.floor((index - 1) * (#values - 1) / math.max(maximum - 1, 1)) + 1
		result[#result + 1] = values[sourceIndex]
	end
	return result
end

local function mutationComponentMotifs(mutations)
	local motifs, seen = { }, { }
	for _, mutation in ipairs(mutations or { }) do
		if mutation.kind == "gear" then
			for _, item in ipairs(mutation.items or { }) do
				local signature = Experience.Digest({
					kind = "gear_item", slot = item.slot, itemDigest = item.itemDigest,
					catalystId = item.catalystId, catalystQuality = item.catalystQuality,
				})
				if signature and not seen[signature] then
					seen[signature] = true
					motifs[#motifs + 1] = "mutation_component:" .. signature
				end
			end
		else
			local signature = Experience.Digest(mutation)
			if signature and not seen[signature] then
				seen[signature] = true
				motifs[#motifs + 1] = "mutation_component:" .. signature
			end
		end
	end
	return motifs
end

local function routeMotifs(record)
	local motifs = { }
	local routeSignature = record.candidate and record.candidate.routeSignature
	local mutationSignature = record.candidate and record.candidate.mutationSignature
	local family = record.context and record.context.candidateFamily or ""
	if type(routeSignature) == "string" and routeSignature ~= "" then
		motifs[#motifs + 1] = { kind = "route", key = "route:" .. routeSignature }
	end
	if type(mutationSignature) == "string" and #mutationSignature == 64 then
		motifs[#motifs + 1] = { kind = "mutation", key = "mutation:" .. mutationSignature }
	end
	for _, mutationMotif in ipairs(mutationComponentMotifs(record.candidate and record.candidate.mutations)) do
		motifs[#motifs + 1] = { kind = "mutation_component", key = mutationMotif }
	end
	local canUseTreeMotifs = family == "tree" or type(mutationSignature) == "string"
	if canUseTreeMotifs then
		local mutationSuffix = type(mutationSignature) == "string" and (":mutation:" .. mutationSignature) or ""
		for _, nodeId in ipairs(sampled(record.path and record.path.addedNodeIds or { }, MAX_NODE_MOTIFS)) do
			motifs[#motifs + 1] = { kind = "node", key = "node:" .. tostring(nodeId) .. mutationSuffix }
		end
		for _, edge in ipairs(sampled(record.path and record.path.edges or { }, MAX_EDGE_MOTIFS)) do
			local first, second = tonumber(edge[1]), tonumber(edge[2])
			if isFinite(first) and isFinite(second) and first > 0 and second > 0 then
				motifs[#motifs + 1] = {
					kind = "edge",
					key = "edge:" .. tostring(math.min(first, second)) .. ":" .. tostring(math.max(first, second)) .. mutationSuffix,
				}
			end
		end
	end
	return motifs
end

local function getGroupStats(index, key)
	local stats = index[key]
	if not stats then
		stats = { groups = { }, buildGroups = 0, observations = 0, meanReward = 0 }
		index[key] = stats
	end
	return stats
end

local function addObservation(index, scope, record, reward)
	local context = record.context or { }
	local scopeKey = scope == "skill" and context.skillScopeKey or context.archetypeScopeKey
	if type(scopeKey) ~= "string" or #scopeKey ~= 64 then return end
	local family = tostring(context.candidateFamily or "")
	for _, motif in ipairs(routeMotifs(record)) do
		local key = table.concat({ scope, scopeKey, family, motif.key }, "\30")
		local stats = getGroupStats(index, key)
		local group = tostring(record.sourceBuildHash or "")
		if group ~= "" then
			local groupStats = stats.groups[group]
			if not groupStats then groupStats = { sum = 0, count = 0 }; stats.groups[group] = groupStats end
			groupStats.sum = groupStats.sum + reward
			groupStats.count = groupStats.count + 1
			stats.observations = stats.observations + 1
		end
	end
end

local function finalizeIndex(index, progressFunc)
	local supportedPatterns = 0
	local processed, total = 0, 0
	for _ in pairs(index) do total = total + 1 end
	for _, stats in pairs(index) do
		processed = processed + 1
		local sum = 0
		for _, group in pairs(stats.groups) do
			if group.count > 0 then sum = sum + group.sum / group.count end
			stats.buildGroups = stats.buildGroups + 1
		end
		stats.meanReward = stats.buildGroups > 0 and sum / stats.buildGroups or 0
		stats.groups = nil
		if stats.buildGroups >= MIN_SKILL_BUILD_GROUPS then supportedPatterns = supportedPatterns + 1 end
		if processed % 512 == 0 and type(progressFunc) == "function" then
			if progressFunc("Finalizing route evidence", processed, total) == false then return nil, "cancelled" end
		end
	end
	return supportedPatterns
end

local function calculateRewards(records, progressFunc)
	local baselineByBuild = { }
	for index, record in ipairs(records) do
		if record.outcome and record.outcome.exactCalculated == true
			and record.candidate and record.candidate.isBaseline == true
			and isFinite(record.outcome.objectiveValue) then
			baselineByBuild[baselineKey(record)] = {
				objectiveValue = record.outcome.objectiveValue,
				feasible = record.outcome.feasible == true,
				normalizedDeficit = isFinite(record.outcome.normalizedDeficit)
					and math.max(record.outcome.normalizedDeficit, 0) or 1000000,
			}
		end
		if index % 256 == 0 and type(progressFunc) == "function" then
			if progressFunc("Pairing exact baselines", index, #records) == false then return nil, "cancelled" end
		end
	end
	local rewards = { }
	for index, record in ipairs(records) do
		local outcome = record.outcome or { }
		local baseline = baselineByBuild[baselineKey(record)]
		local value = outcome.objectiveValue
		if outcome.exactCalculated == true and not (record.candidate and record.candidate.isBaseline == true)
			and baseline and isFinite(baseline.objectiveValue) and isFinite(value) then
			local relativeDelta = (value - baseline.objectiveValue) / math.max(math.abs(baseline.objectiveValue), 1)
			local candidateDeficit = isFinite(outcome.normalizedDeficit)
				and math.max(outcome.normalizedDeficit, 0) or 1000000
			local reward
			if outcome.feasible == true then
				if baseline.feasible then
					-- Once the source build already passes every hard gate, a route
					-- that lowers the selected objective must not become a positive
					-- mining signal merely because it remains feasible.
					reward = clamp(relativeDelta * 4, -1, 1)
				else
					-- Feasibility is lexicographically more important than the
					-- objective while the matched source build is infeasible.
					reward = clamp(0.75 + relativeDelta * 0.25, 0.5, 1)
				end
			elseif baseline.feasible then
				reward = -0.75 - math.min(candidateDeficit, 0.25)
			else
				-- Exact deficit reductions on an infeasible source are useful
				-- learning steps. Keep their reward below every feasible result,
				-- while allowing the exploration interleave to test them early.
				local baselineDeficit = baseline.normalizedDeficit
				local deficitImprovement = (baselineDeficit - candidateDeficit) / math.max(baselineDeficit, 0.01)
				if deficitImprovement > 0 then
					reward = clamp(deficitImprovement * 0.45, 0, 0.45)
				elseif deficitImprovement < 0 then
					reward = clamp(-0.05 - math.min(-deficitImprovement, 1) * 0.45, -0.5, -0.05)
				else
					reward = 0
				end
			end
			rewards[#rewards + 1] = { record = record, reward = reward, context = record.context or { } }
		end
		if index % 256 == 0 and type(progressFunc) == "function" then
			if progressFunc("Scoring exact outcomes", index, #records) == false then return nil, "cancelled" end
		end
	end
	return rewards
end

function patterns.BuildIndex(records, expectedEngine, progressFunc)
	local index = { }
	local compatibleRecords = { }
	for recordIndex, record in ipairs(records or { }) do
		if type(record) == "table" and record.outcome and record.outcome.exactCalculated == true
			and record.engine and expectedEngine
			and tostring(record.engine.pobVersion) == tostring(expectedEngine.pobVersion)
			and tostring(record.engine.pobBranch) == tostring(expectedEngine.pobBranch)
			and tostring(record.engine.dataVersion) == tostring(expectedEngine.dataVersion)
			and tostring(record.engine.treeVersion) == tostring(expectedEngine.treeVersion)
			and type(record.engine.manifestFingerprint) == "string"
			and #record.engine.manifestFingerprint == 64
			and record.engine.manifestFingerprint:match("^[%da-f]+$")
			and record.engine.manifestFingerprint == expectedEngine.manifestFingerprint then
			compatibleRecords[#compatibleRecords + 1] = record
		end
		if recordIndex % 256 == 0 and type(progressFunc) == "function" then
			if progressFunc("Filtering versioned experiences", recordIndex, #records) == false then
				return nil, { status = "cancelled", compatibleRecords = 0, labeledRecords = 0, patternCount = 0 }
			end
		end
	end
	if #compatibleRecords > MAX_INDEX_RECORDS then
		local recent = { }
		for indexValue = #compatibleRecords - MAX_INDEX_RECORDS + 1, #compatibleRecords do
			recent[#recent + 1] = compatibleRecords[indexValue]
		end
		compatibleRecords = recent
	end
	local rewards, rewardError = calculateRewards(compatibleRecords, progressFunc)
	if not rewards then return nil, { status = rewardError or "cancelled", compatibleRecords = #compatibleRecords, labeledRecords = 0, patternCount = 0 } end
	for indexValue, row in ipairs(rewards) do
		addObservation(index, "skill", row.record, row.reward)
		addObservation(index, "archetype", row.record, row.reward)
		if indexValue % 128 == 0 and type(progressFunc) == "function" then
			if progressFunc("Mining route motifs", indexValue, #rewards) == false then
				return nil, { status = "cancelled", compatibleRecords = #compatibleRecords, labeledRecords = #rewards, patternCount = 0 }
			end
		end
	end
	local supportedPatterns, finalizeError = finalizeIndex(index, progressFunc)
	if not supportedPatterns then return nil, { status = finalizeError or "cancelled", compatibleRecords = #compatibleRecords, labeledRecords = #rewards, patternCount = 0 } end
	return index, {
		compatibleRecords = #compatibleRecords,
		labeledRecords = #rewards,
		patternCount = supportedPatterns,
		status = #rewards > 0 and "patterns_available" or "collecting_exact_baselines",
	}
end

local function patternKey(scope, scopeKey, family, motif)
	return table.concat({ scope, scopeKey, family, motif }, "\30")
end

local function lookup(index, scope, scopeKey, family, motif, minimumGroups)
	if not scopeKey then return nil end
	local stats = index[patternKey(scope, scopeKey, family, motif)]
	if not stats or stats.buildGroups < minimumGroups then return nil end
	local confidence = stats.buildGroups / (stats.buildGroups + 4)
	return stats.meanReward * confidence, stats.buildGroups
end

local function candidateRouteSignature(baseContext, candidate, spec, family, build)
	local route = Experience.RouteForCandidate(candidate, spec)
	local context = Experience.CandidateContext(baseContext, candidate)
	local mutationSignature, _, mutationError = Experience.CandidateMutationSignature(candidate, build)
	if mutationError then return nil, route, mutationError end
	return Experience.Digest({
		engine = baseContext.engine, classId = context.classId,
		ascendancyId = context.ascendancyId, skillId = baseContext.skill.id,
		scenario = baseContext.scenarioProfile, scenarioEnemyPreset = baseContext.scenarioEnemyPreset,
		objective = baseContext.objectiveMetric,
		family = family, nodes = route.addedNodeIds,
		removed = route.removedNodeIds, edges = route.edges,
		mutationSignature = mutationSignature,
	}), route, mutationSignature, nil
end

local function scoreCandidate(index, baseContext, candidate, spec, build)
	local family = Experience.CandidateFamily(candidate)
	local context = Experience.CandidateContext(baseContext, candidate)
	local routeSignature, route, mutationSignature, mutations = candidateRouteSignature(baseContext, candidate, spec, family, build)
	if not context or not routeSignature then return nil end
	local motifs = { "route:" .. routeSignature }
	if mutationSignature then
		motifs[#motifs + 1] = "mutation:" .. mutationSignature
		for _, mutationMotif in ipairs(mutationComponentMotifs(mutations)) do motifs[#motifs + 1] = mutationMotif end
	end
	local mutationSuffix = mutationSignature and (":mutation:" .. mutationSignature) or ""
	for _, nodeId in ipairs(route.addedNodeIds) do motifs[#motifs + 1] = "node:" .. tostring(nodeId) end
	if mutationSignature then
		for indexValue = 2, #motifs do
			if motifs[indexValue]:match("^node:") then motifs[indexValue] = motifs[indexValue] .. mutationSuffix end
		end
	end
	for _, edge in ipairs(route.edges) do motifs[#motifs + 1] = "edge:" .. tostring(edge[1]) .. ":" .. tostring(edge[2]) .. mutationSuffix end
	local weighted, weightTotal, maxGroups, evidenceCount = 0, 0, 0, 0
	for _, motif in ipairs(motifs) do
		local kind = motif:match("^(%w+):")
		local skillWeight = kind == "route" and 1.2 or kind == "edge" and 0.30 or 0.10
		local broadWeight = kind == "route" and 0.45 or kind == "edge" and 0.12 or 0.04
		local skillScore, skillGroups = lookup(index, "skill", context.skillScopeKey, family, motif, MIN_SKILL_BUILD_GROUPS)
		if skillScore then
			weighted = weighted + skillScore * skillWeight
			weightTotal = weightTotal + skillWeight
			maxGroups = math.max(maxGroups, skillGroups)
			evidenceCount = evidenceCount + 1
		end
		local broadScore, broadGroups = lookup(index, "archetype", context.archetypeScopeKey, family, motif, MIN_ARCHETYPE_BUILD_GROUPS)
		if broadScore then
			weighted = weighted + broadScore * broadWeight
			weightTotal = weightTotal + broadWeight
			maxGroups = math.max(maxGroups, broadGroups)
			evidenceCount = evidenceCount + 1
		end
	end
	if weightTotal == 0 then return nil end
	return {
		score = clamp(weighted / weightTotal, -1, 1),
		buildGroups = maxGroups,
		evidenceCount = evidenceCount,
		family = family,
	}
end

-- Learned evidence may move a candidate earlier, but it must not consume the
-- whole finite evaluation budget. Keep the strongest positive candidate first,
-- then promote one unobserved proposal and repeat at a bounded cadence. Known
-- neutral/negative candidates remain in the list after those exploration slots;
-- exact PoB evaluation and hard gates still decide every result.
local function interleaveExploration(sorted, scores)
	local positive, unexplored, knownNonPositive = { }, { }, { }
	for _, row in ipairs(sorted) do
		local score = scores[row.candidate]
		if not score then
			unexplored[#unexplored + 1] = row
		elseif score.score > 0 then
			positive[#positive + 1] = row
		else
			knownNonPositive[#knownNonPositive + 1] = row
		end
	end
	if #unexplored == 0 then return sorted, 0 end
	local ordered = { }
	local positiveIndex, unexploredIndex = 1, 1
	local positiveSinceExploration, exploredOnce = 0, false
	local promotedCount = 0
	while positiveIndex <= #positive or unexploredIndex <= #unexplored do
		local stride = exploredOnce and EXPLORE_AFTER_LATER_POSITIVES or EXPLORE_AFTER_FIRST_POSITIVE
		local shouldExplore = unexploredIndex <= #unexplored
			and (positiveIndex > #positive or positiveSinceExploration >= stride)
		if shouldExplore then
			ordered[#ordered + 1] = unexplored[unexploredIndex]
			unexploredIndex = unexploredIndex + 1
			positiveSinceExploration = 0
			exploredOnce = true
			promotedCount = promotedCount + 1
		elseif positiveIndex <= #positive then
			ordered[#ordered + 1] = positive[positiveIndex]
			positiveIndex = positiveIndex + 1
			positiveSinceExploration = positiveSinceExploration + 1
		else
			ordered[#ordered + 1] = unexplored[unexploredIndex]
			unexploredIndex = unexploredIndex + 1
		end
	end
	for _, row in ipairs(knownNonPositive) do ordered[#ordered + 1] = row end
	return ordered, promotedCount
end

local function hasRankableEvidence(index)
	for key, stats in pairs(index or { }) do
		if type(key) == "string" and type(stats) == "table" then
			if key:sub(1, 6) == "skill\30" and (tonumber(stats.buildGroups) or 0) >= MIN_SKILL_BUILD_GROUPS then
				return true
			end
			if key:sub(1, 10) == "archetype\30" and (tonumber(stats.buildGroups) or 0) >= MIN_ARCHETYPE_BUILD_GROUPS then
				return true
			end
		end
	end
	return false
end

function patterns.RankCandidates(index, candidates, baseContext, spec, progressFunc, build)
	if type(candidates) ~= "table" or #candidates < 2 or type(index) ~= "table" or type(baseContext) ~= "table" then
		return candidates, { status = "insufficient_context", rankedCandidates = 0, reorderedCandidates = 0, preservedExploration = 0, promotedExploration = 0 }
	end
	-- Without enough independent exact build lineages, no candidate can receive
	-- a non-nil score. Avoid hashing every route/mutation in a large proposal pool
	-- merely to discover that the evidence index cannot rank any of them.
	if not hasRankableEvidence(index) then
		return candidates, {
			status = "collecting_independent_evidence", rankedCandidates = 0,
			reorderedCandidates = 0, preservedExploration = #candidates, promotedExploration = 0,
		}
	end
	local ranked = { }
	for indexValue, candidate in ipairs(candidates) do ranked[indexValue] = candidate end
	local groups, scores = { }, { }
	local baselineIndex
	for indexValue, candidate in ipairs(candidates) do
		if candidate.isBaselineCandidate then
			baselineIndex = indexValue
		else
			local family = Experience.CandidateFamily(candidate)
			groups[family] = groups[family] or { }
			groups[family][#groups[family] + 1] = { candidate = candidate, original = indexValue }
			local score = scoreCandidate(index, baseContext, candidate, spec, build)
			if score then scores[candidate] = score end
		end
		if indexValue % 128 == 0 and type(progressFunc) == "function" then
			if progressFunc("Ordering candidates by route evidence", indexValue, #candidates) == false then
				return candidates, { status = "cancelled", rankedCandidates = 0, reorderedCandidates = 0, preservedExploration = #candidates, promotedExploration = 0 }
			end
		end
	end
	local rankedCount, reorderedCount, explorationCount = 0, 0, 0
	local promotedExplorationCount = 0
	for _, familyRows in pairs(groups) do
		local sorted = { }
		for _, row in ipairs(familyRows) do
			sorted[#sorted + 1] = row
			if scores[row.candidate] then rankedCount = rankedCount + 1 else explorationCount = explorationCount + 1 end
		end
		table.sort(sorted, function(left, right)
			local leftScore, rightScore = scores[left.candidate], scores[right.candidate]
			if leftScore and rightScore then
				if leftScore.score ~= rightScore.score then return leftScore.score > rightScore.score end
				if leftScore.buildGroups ~= rightScore.buildGroups then return leftScore.buildGroups > rightScore.buildGroups end
			elseif leftScore or rightScore then
				local known = leftScore or rightScore
				if known.score > 0 then return leftScore ~= nil end
				if known.score < 0 then return rightScore ~= nil end
			end
			return left.original < right.original
		end)
		local withExploration, promotedExploration = interleaveExploration(sorted, scores)
		promotedExplorationCount = promotedExplorationCount + promotedExploration
		for offset, row in ipairs(familyRows) do
			local replacement = withExploration[offset]
			ranked[row.original] = replacement.candidate
			if row.candidate ~= replacement.candidate then reorderedCount = reorderedCount + 1 end
		end
	end
	if baselineIndex and ranked[baselineIndex] ~= candidates[baselineIndex] then
		for indexValue, candidate in ipairs(ranked) do
			if candidate == candidates[baselineIndex] then
				ranked[indexValue], ranked[baselineIndex] = ranked[baselineIndex], ranked[indexValue]
				break
			end
		end
	end
	return ranked, {
		status = rankedCount > 0 and "contextual_patterns_ranked" or "collecting_independent_evidence",
		rankedCandidates = rankedCount,
		reorderedCandidates = reorderedCount,
		preservedExploration = explorationCount,
		promotedExploration = promotedExplorationCount,
		baselinePositionLocked = baselineIndex ~= nil,
	}
end

patterns.MIN_SKILL_BUILD_GROUPS = MIN_SKILL_BUILD_GROUPS
patterns.MIN_ARCHETYPE_BUILD_GROUPS = MIN_ARCHETYPE_BUILD_GROUPS

return patterns
