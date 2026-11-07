local Candidate = require("Modules.Optimizer.Candidate")
local TreeSearch = require("Modules.Optimizer.TreeSearch")

local function linkIds(node)
	local result, seen = { }, { }
	for _, field in ipairs({ "linked", "out", "connections" }) do
		for key, value in pairs(node and node[field] or { }) do
			local id = type(value) == "table" and tonumber(value.id) or tonumber(value) or tonumber(key)
			if id and not seen[id] then seen[id] = true; result[#result + 1] = id end
		end
	end
	return result
end

local function isLocalPassive(node)
	return type(node) == "table" and not node.ascendancyName
		and node.type ~= "ClassStart" and node.type ~= "AscendClassStart"
		and node.type ~= "Mastery" and node.type ~= "Socket"
		and not node.isProxy and not node.isMultipleChoiceOption
end

local function passiveDistancesFromAllocation(spec)
	local distances, queue, head = { }, { }, 1
	for rawId, node in pairs(spec.allocNodes or { }) do
		local nodeId = tonumber(rawId)
		if nodeId and node and node.type ~= "AscendClassStart" and not node.ascendancyName then
			distances[nodeId] = 0
			queue[#queue + 1] = nodeId
		end
	end
	while head <= #queue do
		local nodeId = queue[head]
		head = head + 1
		for _, otherId in ipairs(linkIds(spec.nodes[nodeId] or spec.nodes[tostring(nodeId)])) do
			local other = spec.nodes[otherId] or spec.nodes[tostring(otherId)]
			if isLocalPassive(other) and distances[otherId] == nil then
				distances[otherId] = distances[nodeId] + 1
				queue[#queue + 1] = otherId
			end
		end
	end
	return distances
end

describe("AI Planner compatible archive route proposals", function()
	it("turns a compatible tree pattern into a bounded native path without mutating the seed", function()
		newBuild()
		local spec = build.spec
		local active = { }
		for rawId, node in pairs(spec.allocNodes or { }) do
			local id = tonumber(rawId)
			if id and node and node.type ~= "AscendClassStart" and not node.ascendancyName then active[id] = true end
		end
		local target
		for rawId, node in pairs(spec.nodes or { }) do
			local id = tonumber(rawId)
			if id and isLocalPassive(node) and not active[id] then
				for _, linkedId in ipairs(linkIds(node)) do
					if active[linkedId] then target = node; break end
				end
			end
			if target then break end
		end
		assert.is_truthy(target, "the loaded native passive tree should have an unallocated local neighbor")
		local sourceSignature = Candidate.BuildSignature(build)
		local inputs = {
			search = {
				maxAddedPoints = 2,
				seed = 123,
				routePlannerRunSpec = { graph = { radius = 2 } },
			},
			branch = { partition = "class", required = { }, allowed = { }, forbidden = { } },
			preferences = { damageFocus = "Fire" },
		}
		local candidates, coverage, candidateError, cancelled = TreeSearch.BuildArchivedRouteCandidates(
			spec, inputs, { { nodeIds = { target.id }, supportCount = 2, sampleCount = 2, similarity = 0.5 } },
			1, 2, { cancelled = false }, nil, nil, 1000)
		assert.is_nil(candidateError)
		assert.is_false(cancelled == true)
		assert.are.equal(1, coverage.availablePatterns)
		assert.are.equal(1, coverage.eligiblePatterns)
		assert.are.equal(1, coverage.generatedCandidates)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "proposal generation must not mutate the seed build")
		assert.is_true(candidates[1].archivedRoutePattern)
		assert.is_true(candidates[1].archivedPatternSwap == true or #candidates[1].removeNodeIds == 0)
		assert.is_true(#candidates[1].nodeIds > 0 and #candidates[1].nodeIds <= 2)
		local containsTarget = false
		for _, nodeId in ipairs(candidates[1].nodeIds) do if nodeId == target.id then containsTarget = true end end
		assert.is_true(containsTarget, "the emitted native route should reach the compatible archive target")
	end)

	it("ignores an archive target absent from the active native tree", function()
		newBuild()
		local candidates, coverage, candidateError = TreeSearch.BuildArchivedRouteCandidates(build.spec, {
			search = { maxAddedPoints = 2, routePlannerRunSpec = { graph = { radius = 2 } } },
			branch = { partition = "class", required = { }, allowed = { }, forbidden = { } },
		}, { { nodeIds = { 2147483647 }, supportCount = 2, sampleCount = 2, similarity = 0 } },
		1, 2, { cancelled = false }, nil, nil, 1000)
		assert.is_nil(candidateError)
		assert.are.same({ }, candidates)
		assert.are.equal(1, coverage.skippedNoLocalTargets)
	end)

	it("tries a reachable nearby archive target after a higher-support target exceeds the point limit", function()
		newBuild()
		local spec = build.spec
		local distances = passiveDistancesFromAllocation(spec)
		local nearbyTarget, distantTarget
		for rawId, node in pairs(spec.nodes or { }) do
			local nodeId = tonumber(rawId)
			if nodeId and isLocalPassive(node) and (distances[nodeId] or 0) > 0 then
				if distances[nodeId] == 1 and not nearbyTarget then nearbyTarget = node end
				if distances[nodeId] == 2 and not distantTarget then distantTarget = node end
			end
		end
		assert.is_truthy(nearbyTarget, "the fixture tree should have an unallocated one-hop passive")
		assert.is_truthy(distantTarget, "the fixture tree should have an unallocated two-hop passive")
		local candidates, coverage, candidateError = TreeSearch.BuildArchivedRouteCandidates(spec, {
			search = {
				maxAddedPoints = 1,
				seed = 991,
				importedRouteMemoryEnabled = true,
				nodeEvidencePriorities = { [distantTarget.id] = 1, [nearbyTarget.id] = 0 },
				routePlannerRunSpec = { graph = { radius = 2 } },
			},
			branch = { partition = "class", required = { }, allowed = { }, forbidden = { } },
			preferences = { damageFocus = "Auto" },
		}, { { nodeIds = { distantTarget.id, nearbyTarget.id }, supportCount = 2, sampleCount = 2, similarity = 0.5 } },
		1, 1, { cancelled = false }, nil, nil, 1000)
		assert.is_nil(candidateError)
		assert.are.equal(1, coverage.generatedCandidates)
		assert.is_true(coverage.targetAttempts <= 32)
		local reachedNearbyTarget = false
		for _, nodeId in ipairs(candidates[1].nodeIds) do
			if nodeId == nearbyTarget.id then reachedNearbyTarget = true break end
		end
		assert.is_true(reachedNearbyTarget, "the route builder must try nearby observed nodes within the remaining point budget")
	end)

	it("emits bounded progressive route variants from one archived pattern", function()
		newBuild()
		local spec = build.spec
		local distances = passiveDistancesFromAllocation(spec)
		local targets = { }
		for rawId, node in pairs(spec.nodes or { }) do
			local nodeId = tonumber(rawId)
			if nodeId and isLocalPassive(node) and distances[nodeId] == 1 then
				targets[#targets + 1] = node
			end
		end
		table.sort(targets, function(left, right) return left.id < right.id end)
		assert.is_true(#targets >= 2, "the fixture tree should have two unallocated local archive targets")
		local sourceSignature = Candidate.BuildSignature(build)
		local candidates, coverage, candidateError = TreeSearch.BuildArchivedRouteCandidates(spec, {
			search = { maxAddedPoints = 2, seed = 551, routePlannerRunSpec = { graph = { radius = 2 } } },
			branch = { partition = "class", required = { }, allowed = { }, forbidden = { } },
			preferences = { damageFocus = "Auto" },
		}, { { nodeIds = { targets[1].id, targets[2].id }, supportCount = 2, sampleCount = 2, similarity = 0.5 } },
		4, 2, { cancelled = false }, nil, nil, 1000)
		assert.is_nil(candidateError)
		assert.are.equal(2, coverage.generatedCandidates,
			"one multi-target pattern should yield its one-target and two-target progressive routes")
		assert.are.equal(1, candidates[1].archivedPatternVariantIndex)
		assert.are.equal(2, candidates[2].archivedPatternVariantIndex)
		assert.is_true(#candidates[1].nodeIds < #candidates[2].nodeIds)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "route variants must not mutate the source build")
	end)

	it("merges archive lineage metadata into pair and progressive route combinations", function()
		local sources = {
			{ nodeIds = { 101 }, targetId = 101, targetRegion = "North", label = "archive A",
				archivedRoutePattern = true, archivedPatternIndex = 11, archivedPatternVariantIndex = 1,
				archivedPatternSampleCount = 4, archivedPatternSimilarity = 0.8 },
			{ nodeIds = { 202 }, targetId = 202, targetRegion = "East", label = "archive B",
				archivedRoutePattern = true, archivedPatternIndex = 22, archivedPatternVariantIndex = 2,
				archivedPatternSampleCount = 5, archivedPatternSimilarity = 0.9 },
			{ nodeIds = { 303 }, targetId = 303, targetRegion = "South", label = "archive C",
				archivedRoutePattern = true, archivedPatternIndex = 33, archivedPatternVariantIndex = 1,
				archivedPatternSampleCount = 6, archivedPatternSimilarity = 0.95 },
		}
		local combinations = TreeSearch.CombineCandidates(sources, 8, 12)
		local pair, progressive
		for _, candidate in ipairs(combinations) do
			if candidate.archivedRouteComposition == true and candidate.progressiveRouteBundle ~= true then pair = pair or candidate end
			if candidate.archivedRouteComposition == true and candidate.progressiveRouteBundle == true then progressive = progressive or candidate end
		end
		assert.is_truthy(pair, "pair candidates must keep archived-route origin")
		assert.is_truthy(progressive, "progressive portfolios must keep archived-route origin")
		assert.are.equal(2, pair.archivedPatternSourceCount)
		assert.are.equal(3, progressive.archivedPatternSourceCount)
		assert.is_true(pair.archiveDerivedPassiveRoute)
		assert.is_true(progressive.archiveDerivedPassiveRoute)
		assert.are.equal(11, pair.archivedPatternSources[1].patternIndex)
		assert.are.equal(22, pair.archivedPatternSources[2].patternIndex)
	end)
end)
