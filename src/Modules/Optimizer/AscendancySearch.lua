-- Path of Building
--
-- Module: bounded exact-engine candidate generation for the selected base
-- class's main ascendancy and any secondary Bloodline supported by the loaded
-- PoB tree. PoB remains authoritative for allocation, legality and statistics.
-- This module only proposes notable routes; every proposal still passes through
-- Candidate, TreeSearch, and the normal exact PoB calculation.

local Candidate = require("Modules.Optimizer.Candidate")

local ascendancySearch = { }
local MAX_COMBINED_ROUTES_PER_PAIR = 8

local function sortedAscendancies(class)
	local result = { }
	for ascendClassId, ascendClass in pairs(class and class.classes or { }) do
		if type(ascendClassId) == "number" and ascendClassId > 0 and ascendClass and ascendClass.startNodeId then
			result[#result + 1] = { id = ascendClassId, data = ascendClass }
		end
	end
	table.sort(result, function(a, b) return a.id < b.id end)
	return result
end

local function sortedSecondaryAscendancies(tree)
	local result = { { id = 0, data = { id = "None", name = "No Bloodline" } } }
	for ascendClassId, ascendClass in pairs(tree and tree.alternate_ascendancies or { }) do
		if type(ascendClassId) == "number" and ascendClassId > 0 and ascendClass and ascendClass.startNodeId then
			result[#result + 1] = { id = ascendClassId, data = ascendClass }
		end
	end
	table.sort(result, function(a, b)
		if a.id == b.id then return false end
		if a.id == 0 then return true end
		if b.id == 0 then return false end
		return a.id < b.id
	end)
	return result
end

local function prioritizeSelected(list, selectedId)
	if not selectedId or selectedId == 0 then return list end
	for index, entry in ipairs(list) do
		if entry.id == selectedId then
			if index > 1 then
				table.remove(list, index)
				table.insert(list, 1, entry)
			end
			break
		end
	end
	return list
end

local function namesFor(ascendClass)
	local names = { }
	for _, key in ipairs({ "id", "name", "internalId" }) do
		local name = ascendClass and ascendClass[key]
		if type(name) == "string" and name ~= "" then names[name] = true end
	end
	return names
end

local function collectRouteNodes(node, names)
	local route = { }
	for _, pathNode in ipairs(node.path or { }) do
		if pathNode.type ~= "AscendClassStart" and not pathNode.isMultipleChoiceOption
			and pathNode.ascendancyName and names[pathNode.ascendancyName] then
			route[pathNode.id] = true
		end
	end
	return route
end

local function routeCost(route)
	local count = 0
	for _ in pairs(route) do count = count + 1 end
	return count
end

local function unionRouteCost(left, right)
	local count = routeCost(left)
	for nodeId in pairs(right) do
		if not left[nodeId] then count = count + 1 end
	end
	return count
end

local function sortedTargetNodes(spec, names)
	local targets = { }
	for _, node in pairs(spec.nodes or { }) do
		if node.path and (node.type == "Notable" or node.type == "Keystone")
			and not node.isMultipleChoiceOption and node.ascendancyName and names[node.ascendancyName] then
			targets[#targets + 1] = node
		end
	end
	table.sort(targets, function(a, b) return a.id < b.id end)
	return targets
end

local function requiredNodesForAscendancy(spec, ascendClass, requiredNodeIds)
	local required, names = { }, namesFor(ascendClass)
	for _, nodeId in ipairs(requiredNodeIds or { }) do
		local node = spec and spec.nodes and spec.nodes[tonumber(nodeId)]
		if node and node.ascendancyName and names[node.ascendancyName] then
			required[node.id] = true
		end
	end
	return required
end

local function missingRequiredCount(pathNodes, requiredNodes)
	local missing = 0
	for nodeId in pairs(requiredNodes or { }) do
		if not pathNodes[nodeId] then missing = missing + 1 end
	end
	return missing
end

local function buildRouteChoices(spec, ascendClass, control, requiredNodes)
	local result = { singles = { }, pairs = { } }
	if not spec or not ascendClass then return result end
	local names = namesFor(ascendClass)
	local targets = sortedTargetNodes(spec, names)
	local paths = { }
	for _, target in ipairs(targets) do
		if control and control.cancelled then return nil, "cancelled" end
		local path = collectRouteNodes(target, names)
		local pointCost = routeCost(path)
		if pointCost > 0 and pointCost <= 8 then
			paths[#paths + 1] = { targetIds = { target.id }, pointCost = pointCost,
				requiredMissing = missingRequiredCount(path, requiredNodes),
				label = tostring(target.dn or target.name or target.id) }
		end
	end
	table.sort(paths, function(a, b)
		if a.requiredMissing ~= b.requiredMissing then return a.requiredMissing < b.requiredMissing end
		if a.pointCost ~= b.pointCost then return a.pointCost < b.pointCost end
		return a.targetIds[1] < b.targetIds[1]
	end)
	result.singles = paths

	local routeSets = { }
	for _, target in ipairs(targets) do
		routeSets[target.id] = collectRouteNodes(target, names)
	end
	for first = 1, #targets do
		if control and control.cancelled then return nil, "cancelled" end
		local left = routeSets[targets[first].id]
		for second = first + 1, #targets do
			local right = routeSets[targets[second].id]
			local pointCost = unionRouteCost(left, right)
			if pointCost > 0 and pointCost <= 8 then
				local union = { }
				for nodeId in pairs(left) do union[nodeId] = true end
				for nodeId in pairs(right) do union[nodeId] = true end
				result.pairs[#result.pairs + 1] = {
					targetIds = { targets[first].id, targets[second].id },
					pointCost = pointCost,
					requiredMissing = missingRequiredCount(union, requiredNodes),
					label = tostring(targets[first].dn or targets[first].name or targets[first].id)
						.. " + " .. tostring(targets[second].dn or targets[second].name or targets[second].id),
				}
			end
		end
	end
	table.sort(result.pairs, function(a, b)
		if a.requiredMissing ~= b.requiredMissing then return a.requiredMissing < b.requiredMissing end
		if a.pointCost ~= b.pointCost then return a.pointCost < b.pointCost end
		if a.targetIds[1] ~= b.targetIds[1] then return a.targetIds[1] < b.targetIds[1] end
		return a.targetIds[2] < b.targetIds[2]
	end)
	return result
end

local function buildCombinedRoutes(mainRoutes, secondaryRoutes)
	local result = { }
	for _, mainRoute in ipairs(mainRoutes.singles or { }) do
		for _, secondaryRoute in ipairs(secondaryRoutes.singles or { }) do
			result[#result + 1] = { main = mainRoute, secondary = secondaryRoute,
				mainPointCost = mainRoute.pointCost, secondaryPointCost = secondaryRoute.pointCost,
				requiredMissing = (mainRoute.requiredMissing or 0) + (secondaryRoute.requiredMissing or 0) }
		end
	end
	table.sort(result, function(a, b)
		if a.requiredMissing ~= b.requiredMissing then return a.requiredMissing < b.requiredMissing end
		local totalA = a.mainPointCost + a.secondaryPointCost
		local totalB = b.mainPointCost + b.secondaryPointCost
		if totalA ~= totalB then return totalA < totalB end
		if a.mainPointCost ~= b.mainPointCost then return a.mainPointCost < b.mainPointCost end
		if a.secondaryPointCost ~= b.secondaryPointCost then return a.secondaryPointCost < b.secondaryPointCost end
		if a.main.targetIds[1] ~= b.main.targetIds[1] then return a.main.targetIds[1] < b.main.targetIds[1] end
		return a.secondary.targetIds[1] < b.secondary.targetIds[1]
	end)
	while #result > MAX_COMBINED_ROUTES_PER_PAIR do result[#result] = nil end
	return result
end

local function makeCandidate(mainAscendancy, secondaryAscendancy, mainRoute, secondaryRoute, combined)
	mainRoute = mainRoute or (combined and combined.main)
	secondaryRoute = secondaryRoute or (combined and combined.secondary)
	local mainPointCost = mainRoute and mainRoute.pointCost or 0
	local secondaryPointCost = secondaryRoute and secondaryRoute.pointCost or 0
	if mainPointCost == 0 and secondaryPointCost == 0 then return nil end
	local nodeIds = { }
	for _, nodeId in ipairs(mainRoute and mainRoute.targetIds or { }) do nodeIds[#nodeIds + 1] = nodeId end
	for _, nodeId in ipairs(secondaryRoute and secondaryRoute.targetIds or { }) do nodeIds[#nodeIds + 1] = nodeId end
	table.sort(nodeIds)
	local mainName = mainAscendancy.data.name or mainAscendancy.data.id or ("Ascendancy " .. tostring(mainAscendancy.id))
	local secondaryName = secondaryAscendancy.data.name or secondaryAscendancy.data.id
	local name = "Ascendancy " .. tostring(mainName)
	if secondaryAscendancy.id ~= 0 then name = name .. " + " .. tostring(secondaryName) end
	local routeLabels = { }
	if mainRoute then routeLabels[#routeLabels + 1] = "main: " .. mainRoute.label end
	if secondaryRoute then routeLabels[#routeLabels + 1] = "Bloodline: " .. secondaryRoute.label end
	return {
		nodeIds = nodeIds,
		ascendancyVariant = {
			ascendClassId = mainAscendancy.id,
			secondaryAscendClassId = secondaryAscendancy.id,
		},
		ascendancyPointCost = mainPointCost + secondaryPointCost,
		mainAscendancyPointCost = mainPointCost,
		secondaryAscendancyPointCost = secondaryPointCost,
		label = name .. " — " .. table.concat(routeLabels, " / "),
	}
end

local function candidateForTier(group, tier, index)
	if tier == "mainBaseline" then
		if index ~= 1 or group.secondaryAscendancy.id ~= 0 then return nil end
		return makeCandidate(group.mainAscendancy, group.secondaryAscendancy, group.mainRoutes.singles[1])
	elseif tier == "seed" then
		if index ~= 1 or group.secondaryAscendancy.id == 0 then return nil end
		return makeCandidate(group.mainAscendancy, group.secondaryAscendancy, nil, nil, group.crossRoutes[1])
	elseif tier == "cross" then
		local route = group.crossRoutes[index]
		return route and makeCandidate(group.mainAscendancy, group.secondaryAscendancy, nil, nil, route) or nil
	elseif tier == "mainSingles" then
		return makeCandidate(group.mainAscendancy, group.secondaryAscendancy, group.mainRoutes.singles[index])
	elseif tier == "secondarySingles" then
		return makeCandidate(group.mainAscendancy, group.secondaryAscendancy, nil, group.secondaryRoutes.singles[index])
	elseif tier == "mainPairs" then
		return makeCandidate(group.mainAscendancy, group.secondaryAscendancy, group.mainRoutes.pairs[index])
	elseif tier == "secondaryPairs" then
		return makeCandidate(group.mainAscendancy, group.secondaryAscendancy, nil, group.secondaryRoutes.pairs[index])
	end
	return nil
end

local function candidateKey(candidate)
	return tostring(candidate.ascendancyVariant.ascendClassId) .. ":"
		.. tostring(candidate.ascendancyVariant.secondaryAscendClassId) .. ":" .. table.concat(candidate.nodeIds, ",")
end

local function appendTier(result, groups, tier, limit, seen, firstIndex)
	local index = firstIndex or 1
	while #result < limit do
		local appended = false
		local hasCandidate = false
		for _, group in ipairs(groups) do
			local candidate = candidateForTier(group, tier, index)
			if candidate then
				hasCandidate = true
				local key = candidateKey(candidate)
				if not seen[key] then
					seen[key] = true
					result[#result + 1] = candidate
					appended = true
					if #result >= limit then break end
				end
			end
		end
		if not hasCandidate then break end
		index = index + 1
	end
end

local function buildRoot(build, classId, mainAscendancyId, secondaryAscendancyId)
	return Candidate.BuildPassiveSpec(build, { }, { }, {
		classId = classId,
		ascendClassId = mainAscendancyId,
		secondaryAscendClassId = secondaryAscendancyId,
	})
end

-- Build a bounded, deterministic proposal list. Every available main/Bloodline
-- pair is represented in the first round when the caller's quota permits; later
-- rounds add more individual and combined notable routes. Coverage explicitly
-- reports when the exact-evaluation budget truncates those pairs.
function ascendancySearch.BuildCandidates(build, classId, limit, control, onProgress, selectedAscendancyId, requiredNodeIds, selectedSecondaryAscendancyId)
	if not build or not build.spec or not build.spec.tree then
		return { }, { status = "unsupported", reason = "PoB passive tree is unavailable" }
	end
	if type(classId) ~= "number" or not build.spec.tree.classes[classId] then
		return { }, { status = "unsupported", reason = "Selected base class is unavailable in this PoB tree version" }
	end
	if type(limit) ~= "number" or limit <= 0 then return { }, { status = "budget_exhausted", ascendancies = { } } end
	local class = build.spec.tree.classes[classId]
	local ascendancies = sortedAscendancies(class)
	if selectedAscendancyId ~= nil then
		local selected = tonumber(selectedAscendancyId)
		if not selected or selected < 0 or selected ~= math.floor(selected) then
			return { }, { status = "invalid_ascendancy", baseClassId = classId,
				reason = "The selected ascendancy ID is invalid" }
		end
		if selected == 0 then
			if selectedSecondaryAscendancyId ~= nil and tonumber(selectedSecondaryAscendancyId) ~= 0 then
				return { }, { status = "invalid_secondary_ascendancy", baseClassId = classId,
					reason = "A Bloodline cannot be selected without a main ascendancy" }
			end
			return { }, { status = "preserved_no_ascendancy", baseClassId = classId,
				availableAscendancies = { }, availableSecondaryAscendancies = {
					{ ascendClassId = 0, name = "No Bloodline", available = true, individualRoutes = 0, pairedRoutes = 0 },
				}, availableCombinations = 0, generatedCandidates = 0 }
		end
		if not class.classes[selected] then
			return { }, { status = "invalid_ascendancy", baseClassId = classId,
				reason = "The selected ascendancy is unavailable to this base class" }
		end
		local filtered = { }
		for _, ascendancy in ipairs(ascendancies) do
			if ascendancy.id == selected then filtered[1] = ascendancy break end
		end
		ascendancies = filtered
		if #ascendancies == 0 then
			return { }, { status = "invalid_ascendancy", baseClassId = classId,
				reason = "The selected ascendancy is unavailable to this base class" }
		end
	end
	if #ascendancies == 0 then return { }, { status = "no_ascendancies", baseClassId = classId } end
	local currentMain = classId == build.spec.curClassId and (build.spec.curAscendClassId or 0) or 0
	local currentSecondary = classId == build.spec.curClassId and (build.spec.curSecondaryAscendClassId or 0) or 0
	prioritizeSelected(ascendancies, currentMain)
	local secondaryAscendancies
	if selectedSecondaryAscendancyId ~= nil then
		local selectedSecondary = tonumber(selectedSecondaryAscendancyId)
		if not selectedSecondary or selectedSecondary < 0 or selectedSecondary ~= math.floor(selectedSecondary) then
			return { }, { status = "invalid_secondary_ascendancy", baseClassId = classId,
				reason = "The selected Bloodline ID is invalid" }
		end
		secondaryAscendancies = { }
		for _, secondary in ipairs(sortedSecondaryAscendancies(build.spec.tree)) do
			if secondary.id == selectedSecondary then secondaryAscendancies[1] = secondary break end
		end
		if #secondaryAscendancies == 0 then
			return { }, { status = "invalid_secondary_ascendancy", baseClassId = classId,
				reason = "The selected Bloodline is unavailable in this PoB tree version" }
		end
	elseif selectedAscendancyId ~= nil then
		secondaryAscendancies = { { id = 0, data = { id = "None", name = "No Bloodline" } } }
	else
		secondaryAscendancies = prioritizeSelected(sortedSecondaryAscendancies(build.spec.tree), currentSecondary)
	end

	local rootTotal = #ascendancies
	for _, secondary in ipairs(secondaryAscendancies) do
		if secondary.id ~= 0 then rootTotal = rootTotal + 1 end
	end
	local rootProcessed = 0
	local function reportRoot(name)
		rootProcessed = rootProcessed + 1
		if onProgress then onProgress(rootProcessed, rootTotal, name) end
		return not (control and control.cancelled)
	end

	local mainRouteSets, mainCoverage = { }, { }
	for _, mainAscendancy in ipairs(ascendancies) do
		if control and control.cancelled then return { }, { status = "cancelled", ascendancies = mainCoverage } end
		local rootSpec, err = buildRoot(build, classId, mainAscendancy.id, 0)
		if rootSpec then
			local requiredNodes = requiredNodesForAscendancy(rootSpec, mainAscendancy.data, requiredNodeIds)
			local routes, routeError = buildRouteChoices(rootSpec, mainAscendancy.data, control, requiredNodes)
			if not routes then return { }, { status = "cancelled", ascendancies = mainCoverage } end
			mainRouteSets[mainAscendancy.id] = routes
			mainCoverage[#mainCoverage + 1] = {
				ascendClassId = mainAscendancy.id,
				name = mainAscendancy.data.name or mainAscendancy.data.id or ("Ascendancy " .. tostring(mainAscendancy.id)),
				available = true,
				individualRoutes = #routes.singles,
				pairedRoutes = #routes.pairs,
			}
		else
			mainCoverage[#mainCoverage + 1] = {
				ascendClassId = mainAscendancy.id,
				name = mainAscendancy.data.name or mainAscendancy.data.id or ("Ascendancy " .. tostring(mainAscendancy.id)),
				available = false,
				error = tostring(err or "PoB could not build this ascendancy root"),
			}
		end
		if not reportRoot(tostring(mainAscendancy.data.name or mainAscendancy.data.id)) then
			return { }, { status = "cancelled", ascendancies = mainCoverage }
		end
	end

	local secondaryRouteSets, secondaryCoverage = { }, { }
	for _, secondaryAscendancy in ipairs(secondaryAscendancies) do
		if secondaryAscendancy.id == 0 then
			secondaryCoverage[#secondaryCoverage + 1] = {
				ascendClassId = 0, name = "No Bloodline", available = true,
				individualRoutes = 0, pairedRoutes = 0,
			}
		end
	end
	local rootMainAscendancy
	for _, mainAscendancy in ipairs(ascendancies) do
		if mainRouteSets[mainAscendancy.id] then rootMainAscendancy = mainAscendancy break end
	end
	for _, secondaryAscendancy in ipairs(secondaryAscendancies) do
		if secondaryAscendancy.id ~= 0 then
			if control and control.cancelled then return { }, { status = "cancelled", ascendancies = mainCoverage, secondaryAscendancies = secondaryCoverage } end
			local rootSpec, err
			if rootMainAscendancy then
				rootSpec, err = buildRoot(build, classId, rootMainAscendancy.id, secondaryAscendancy.id)
			else
				err = "No valid main ascendancy is available to resolve a Bloodline root"
			end
			if rootSpec then
				local requiredNodes = requiredNodesForAscendancy(rootSpec, secondaryAscendancy.data, requiredNodeIds)
				local routes, routeError = buildRouteChoices(rootSpec, secondaryAscendancy.data, control, requiredNodes)
				if not routes then return { }, { status = "cancelled", ascendancies = mainCoverage, secondaryAscendancies = secondaryCoverage } end
				secondaryRouteSets[secondaryAscendancy.id] = routes
				secondaryCoverage[#secondaryCoverage + 1] = {
					ascendClassId = secondaryAscendancy.id,
					name = secondaryAscendancy.data.name or secondaryAscendancy.data.id or ("Bloodline " .. tostring(secondaryAscendancy.id)),
					available = true,
					individualRoutes = #routes.singles,
					pairedRoutes = #routes.pairs,
				}
			else
				secondaryCoverage[#secondaryCoverage + 1] = {
					ascendClassId = secondaryAscendancy.id,
					name = secondaryAscendancy.data.name or secondaryAscendancy.data.id or ("Bloodline " .. tostring(secondaryAscendancy.id)),
					available = false,
					error = tostring(err or "PoB could not build this Bloodline root"),
				}
			end
			if not reportRoot(tostring(secondaryAscendancy.data.name or secondaryAscendancy.data.id)) then
				return { }, { status = "cancelled", ascendancies = mainCoverage, secondaryAscendancies = secondaryCoverage }
			end
		end
	end

	local groups, groupsBySecondary, combinationCoverage = { }, { }, { }
	for _, mainAscendancy in ipairs(ascendancies) do
		local mainRoutes = mainRouteSets[mainAscendancy.id]
		if mainRoutes then
			for _, secondaryAscendancy in ipairs(secondaryAscendancies) do
				local secondaryRoutes = secondaryAscendancy.id == 0 and { singles = { }, pairs = { } }
					or secondaryRouteSets[secondaryAscendancy.id]
				if secondaryRoutes then
					local crossRoutes = secondaryAscendancy.id ~= 0 and buildCombinedRoutes(mainRoutes, secondaryRoutes) or { }
					local group = {
						mainAscendancy = mainAscendancy,
						secondaryAscendancy = secondaryAscendancy,
						mainRoutes = mainRoutes,
						secondaryRoutes = secondaryRoutes,
						crossRoutes = crossRoutes,
					}
					groups[#groups + 1] = group
					groupsBySecondary[secondaryAscendancy.id] = groupsBySecondary[secondaryAscendancy.id] or { }
					local secondaryGroups = groupsBySecondary[secondaryAscendancy.id]
					secondaryGroups[#secondaryGroups + 1] = group
					combinationCoverage[#combinationCoverage + 1] = {
						ascendClassId = mainAscendancy.id,
						secondaryAscendClassId = secondaryAscendancy.id,
						mainRoutes = #mainRoutes.singles,
						secondaryRoutes = #secondaryRoutes.singles,
						combinedRouteSamples = #crossRoutes,
					}
				end
			end
		end
	end
	-- Seed pairs in Bloodline-major order, with the prioritized main roots
	-- interleaved inside each Bloodline. A tight exact-evaluation budget then
	-- covers multiple primary ascendancies instead of spending the entire seed
	-- quota on the first main root. The ordinary baseline tier remains main-major.
	local seedGroups = { }
	for _, secondaryAscendancy in ipairs(secondaryAscendancies) do
		for _, group in ipairs(groupsBySecondary[secondaryAscendancy.id] or { }) do
			seedGroups[#seedGroups + 1] = group
		end
	end

	local result, seen = { }, { }
	-- Reserve at least one primary-only route per main ascendancy, then seed each
	-- selected Bloodline combination with one cross route. This preserves a valid
	-- no-Bloodline comparator while ensuring the secondary branch reaches exact
	-- PoB evaluation before wider route lists consume the candidate budget.
	appendTier(result, groups, "mainBaseline", limit, seen)
	appendTier(result, seedGroups, "seed", limit, seen)
	appendTier(result, groups, "mainSingles", limit, seen)
	appendTier(result, groups, "secondarySingles", limit, seen)
	appendTier(result, groups, "mainPairs", limit, seen)
	appendTier(result, groups, "secondaryPairs", limit, seen)
	appendTier(result, groups, "cross", limit, seen, 2)

	local representedMain, representedSecondary, representedCombinations, representedBloodlineCombinations = { }, { }, { }, { }
	for _, candidate in ipairs(result) do
		local variant = candidate.ascendancyVariant
		if (candidate.mainAscendancyPointCost or 0) > 0 then representedMain[variant.ascendClassId] = true end
		if (candidate.secondaryAscendancyPointCost or 0) > 0 then representedSecondary[variant.secondaryAscendClassId] = true end
		representedCombinations[tostring(variant.ascendClassId) .. ":" .. tostring(variant.secondaryAscendClassId)] = true
		if (candidate.mainAscendancyPointCost or 0) > 0 and (candidate.secondaryAscendancyPointCost or 0) > 0 then
			representedBloodlineCombinations[tostring(variant.ascendClassId) .. ":" .. tostring(variant.secondaryAscendClassId)] = true
		end
	end
	local availableMainCount, representedMainCount = 0, 0
	for _, ascendancy in ipairs(mainCoverage) do
		if ascendancy.available then availableMainCount = availableMainCount + 1 end
	end
	for _ in pairs(representedMain) do representedMainCount = representedMainCount + 1 end
	local representedSecondaryCount = 0
	local secondaryChoiceCount = 0
	for _, secondary in ipairs(secondaryCoverage) do
		if secondary.ascendClassId ~= 0 and secondary.available then
			secondaryChoiceCount = secondaryChoiceCount + 1
			if representedSecondary[secondary.ascendClassId] then representedSecondaryCount = representedSecondaryCount + 1 end
		end
	end
	local representedCombinationCount = 0
	for _ in pairs(representedCombinations) do representedCombinationCount = representedCombinationCount + 1 end
	local representedBloodlineCombinationCount = 0
	for _ in pairs(representedBloodlineCombinations) do representedBloodlineCombinationCount = representedBloodlineCombinationCount + 1 end
	local availableBloodlineCombinationCount = 0
	for _, combination in ipairs(combinationCoverage) do
		if combination.secondaryAscendClassId ~= 0 and combination.combinedRouteSamples > 0 then
			availableBloodlineCombinationCount = availableBloodlineCombinationCount + 1
		end
	end
	return result, {
		status = #result > 0 and "generated" or "no_legal_routes",
		baseClassId = classId,
		availableMainAscendancies = availableMainCount,
		representedMainAscendancies = representedMainCount,
		availableAscendancies = mainCoverage,
		availableSecondaryAscendancies = secondaryCoverage,
		combinationCoverage = combinationCoverage,
		availableCombinations = #combinationCoverage,
		representedCombinations = representedCombinationCount,
		availableBloodlines = secondaryChoiceCount,
		representedBloodlines = representedSecondaryCount,
		availableBloodlineCombinations = availableBloodlineCombinationCount,
		representedBloodlineCombinations = representedBloodlineCombinationCount,
		generatedCandidates = #result,
		budget = limit,
		secondaryAscendancySearched = representedSecondaryCount > 0,
		secondaryCombinationSearched = representedBloodlineCombinationCount > 0,
		budgetLimited = #result >= limit and (representedCombinationCount < #combinationCoverage
			or representedSecondaryCount < secondaryChoiceCount
			or representedBloodlineCombinationCount < availableBloodlineCombinationCount),
	}
end

return ascendancySearch
