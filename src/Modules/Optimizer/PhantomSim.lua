-- Path of Building
--
-- Module: Phantom simulation and strict search job.
-- Each exact engine calculation runs to completion in a coroutine slice. Yields
-- occur only between completed calculations because CalcPerform has no safe
-- public checkpoint contract; interrupted Route Planner searches retain only
-- candidates that already completed exact calculation and native gates.
--
local inputsModule = require("Modules.Optimizer.Inputs")
local Ranking = require("Modules.Optimizer.Ranking")
local validator = require("Modules.Optimizer.Validator")
local treeSearch = require("Modules.Optimizer.TreeSearch")
local conversion = require("Modules.Optimizer.Conversion")
local Equipment = require("Modules.Optimizer.Equipment")
local GearRepair = require("Modules.Optimizer.GearRepair")
local SyntheticGear = require("Modules.Optimizer.SyntheticGear")
local CatalystSearch = require("Modules.Optimizer.CatalystSearch")
local MarketBudget = require("Modules.Optimizer.MarketBudget")
local Version = require("Modules.Optimizer.Version")
local breakpoints = require("Modules.Optimizer.Breakpoints")
local skillAvailability = require("Modules.Optimizer.SkillAvailability")
local candidateModule = require("Modules.Optimizer.Candidate")
local CandidateIdentity = require("Modules.Optimizer.CandidateIdentity")
local scenario = require("Modules.Optimizer.Scenario")
local configurationChoices = require("Modules.Optimizer.ConfigurationChoices")
local surrogate = require("Modules.Optimizer.Surrogate")
local SurrogateFeatures = require("Modules.Optimizer.SurrogateFeatures")
local GNNRanker = require("Modules.Optimizer.GNNRanker")
local GNNTrainingExport = require("Modules.Optimizer.GNNTrainingExport")
local PathExperience = require("Modules.Optimizer.PathExperience")
local MAX_ARCHIVED_ROUTE_PATTERNS = 24
local MAX_ARCHIVED_ROUTE_CANDIDATES = 96
local ARCHIVED_ROUTE_EXACT_BUDGET_SHARE = 0.10
local PathPatterns = require("Modules.Optimizer.PathPatterns")
local activity = require("Modules.Optimizer.Activity")
local skillActions = require("Modules.Optimizer.SkillActions")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local SocketRepairComposer = require("Modules.Optimizer.SocketRepairComposer")
local SkillCostAudit = require("Modules.Optimizer.SkillCostAudit")
local RoutePlannerProgress = require("Modules.Optimizer.RoutePlannerProgress")
local AscendancySearch = require("Modules.Optimizer.AscendancySearch")
local ClusterSearch = require("Modules.Optimizer.ClusterSearch")
local HierarchicalController = require("Modules.Optimizer.HierarchicalController")
local calcsModule = require("Modules.Calcs")

local phantomSim = { }

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function exactExtraPoints(output, env)
	if output and isFinite(output.ExtraPoints) then return output.ExtraPoints end
	-- ExtraPoints is included in PoB's MAIN output, but not its CALCULATOR output.
	-- The returned exact calculation environment still owns the authoritative
	-- player ModDB, so query that native value instead of reusing the baseline.
	local modDB = env and env.modDB
	if modDB and type(modDB.Sum) == "function" then
		local ok, value = pcall(modDB.Sum, modDB, "BASE", nil, "ExtraPoints")
		if ok and isFinite(value) then return value end
	end
	return nil
end

local function shallowCopy(source)
	local copy = { }
	for key, value in pairs(source or { }) do copy[key] = value end
	return copy
end

local function hasOmniscienceAttributeConversion(build)
	local modDB = build and build.calcsTab and build.calcsTab.mainEnv and build.calcsTab.mainEnv.modDB
	if not modDB or type(modDB.Flag) ~= "function" then return false end
	local ok, value = pcall(modDB.Flag, modDB, nil, "Omniscience")
	return ok and value == true
end

local function nodePotentialFocusMetrics(parsed, baseline)
	local preferences = parsed.preferences or { }
	local damageFocus = preferences.damageFocus or "Auto"
	local defenseProfile = preferences.defenseProfile or "Auto"
	local focusMetrics, focusNotes, seen = { }, { }, { }
	local function add(key, label, role)
		if not key or seen[key] then return end
		if not isFinite(baseline[key]) then
			focusNotes[#focusNotes + 1] = label .. " is not exposed by this exact PoB calculation"
			return
		end
		seen[key] = true
		focusMetrics[#focusMetrics + 1] = { key = key, label = label, role = role }
	end
	if damageFocus == "PhysicalImpale" then
		add("ImpaleDPS", "Impale DPS", "damage")
	elseif damageFocus == "PhysicalDoT" or damageFocus == "ChaosPoison" then
		add("TotalDotDPS", "Selected-skill DoT DPS", "damage")
	elseif damageFocus == "Auto" then
		local labels = {
			CombinedDPS = "Selected-skill DPS", FullDPS = "Full-build DPS", FullDotDPS = "Full-build DoT DPS",
			TotalEHP = "PoB EHP", Speed = "Skill rate",
		}
		add(parsed.objective, labels[parsed.objective] or tostring(parsed.objective), "objective")
	else
		-- Current PoB output exposes exact total selected-skill DPS here, but not
		-- an isolated per-element DPS metric. Keep the chosen element as context.
		add("CombinedDPS", "Selected-skill total DPS", "damage")
		focusNotes[#focusNotes + 1] = "Element focus is a preference; PoB's exact selected-skill output is not split by element in this review"
	end
	local defenseMetrics = {
		Life = { "Life", "Life" }, EnergyShield = { "EnergyShield", "Energy Shield" },
		Hybrid = { "TotalEHP", "PoB EHP" }, Ward = { "Ward", "Ward buffer" },
		Armour = { "Armour", "Armour" }, Evasion = { "Evasion", "Evasion" },
		Block = { "BlockChance", "Attack block chance" },
		SpellBlock = { "SpellBlockChance", "Spell block chance" },
		SpellSuppression = { "SpellSuppressionChance", "Spell suppression chance" },
	}
	local defense = defenseMetrics[defenseProfile]
	if defense then add(defense[1], defense[2], "defense") end
	if #focusMetrics == 0 and isFinite(baseline[parsed.objective]) then
		focusMetrics[1] = { key = parsed.objective, label = tostring(parsed.objective), role = "objective" }
	end
	return focusMetrics, focusNotes
end

local function nodeRouteDominates(first, second, focusMetrics)
	local strictlyBetter, comparable = false, 0
	for _, focus in ipairs(focusMetrics) do
		local firstDelta = first.metricDelta and first.metricDelta[focus.key]
		local secondDelta = second.metricDelta and second.metricDelta[focus.key]
		if isFinite(firstDelta) and isFinite(secondDelta) then
			comparable = comparable + 1
			if firstDelta < secondDelta then return false end
			if firstDelta > secondDelta then strictlyBetter = true end
		end
	end
	return comparable > 0 and strictlyBetter
end

local function assignNodeRouteParetoRanks(results, focusMetrics)
	local remaining = { }
	for _, entry in ipairs(results or { }) do
		if entry.exactCalculated then remaining[#remaining + 1] = entry end
	end
	local rank = 1
	while #remaining > 0 do
		local front, inFront = { }, { }
		for _, entry in ipairs(remaining) do
			local dominated = false
			for _, other in ipairs(remaining) do
				if other ~= entry and nodeRouteDominates(other, entry, focusMetrics) then
					dominated = true
					break
				end
			end
			if not dominated then
				front[#front + 1] = entry
				inFront[entry] = true
			end
		end
		if #front == 0 then break end
		for _, entry in ipairs(front) do entry.paretoRank = rank end
		local nextRemaining = { }
		for _, entry in ipairs(remaining) do
			if not inFront[entry] then nextRemaining[#nextRemaining + 1] = entry end
		end
		remaining = nextRemaining
		rank = rank + 1
	end
end

local function copyHierarchicalProvenance(source, destination, combinationKind)
	local experts, seen = { }, { }
	local function add(expert)
		if type(expert) ~= "table" or type(expert.zone) ~= "string" then return end
		local key = table.concat({ tostring(expert.policyVersion or ""), tostring(expert.planId or ""), expert.zone }, "\31")
		if seen[key] then return end
		seen[key] = true
		experts[#experts + 1] = shallowCopy(expert)
	end
	add(source.hierarchicalExpert)
	for _, expert in ipairs(source.hierarchicalExperts or { }) do add(expert) end
	if #experts > 0 then
		destination.hierarchicalExperts = experts
		if #experts == 1 then destination.hierarchicalExpert = experts[1] end
		destination.hierarchicalCombination = true
		destination.hierarchicalCombinationKind = combinationKind
	end
end

local function gemVariantsEqual(first, second, seen)
	if first == second then return true end
	if type(first) ~= type(second) or type(first) ~= "table" then return false end
	seen = seen or { }
	if seen[first] == second then return true end
	seen[first] = second
	for key, value in pairs(first) do
		if not gemVariantsEqual(value, second[key], seen) then return false end
	end
	for key in pairs(second) do
		if first[key] == nil then return false end
	end
	return true
end

local function mergeCandidateGemVariants(route, mutation)
	local variants, positionsBySlot = { }, { }
	local function append(variant)
		if type(variant) ~= "table" then return true end
		local groupIndex, gemIndex = tonumber(variant.groupIndex), tonumber(variant.gemIndex)
		local slotKey = groupIndex and gemIndex and (tostring(groupIndex) .. ":" .. tostring(gemIndex)) or nil
		local existingIndex = slotKey and positionsBySlot[slotKey]
		if existingIndex then
			if not gemVariantsEqual(variants[existingIndex], variant) then return false end
			return true
		end
		variants[#variants + 1] = shallowCopy(variant)
		if slotKey then positionsBySlot[slotKey] = #variants end
		return true
	end
	local function appendCandidate(candidate)
		if not candidate then return true end
		if type(candidate.gemVariants) == "table" then
			for _, variant in ipairs(candidate.gemVariants) do
				if not append(variant) then return false end
			end
		end
		return not candidate.gemVariant or append(candidate.gemVariant)
	end
	if not appendCandidate(route) then return nil, "route_gem_variant_conflict" end
	if not appendCandidate(mutation) then return nil, "mutation_gem_variant_conflict" end
	table.sort(variants, function(a, b)
		local groupA, groupB = tonumber(a.groupIndex) or math.huge, tonumber(b.groupIndex) or math.huge
		if groupA ~= groupB then return groupA < groupB end
		local gemA, gemB = tonumber(a.gemIndex) or math.huge, tonumber(b.gemIndex) or math.huge
		if gemA ~= gemB then return gemA < gemB end
		return tostring(a.gemId or a.skillId or "") < tostring(b.gemId or b.skillId or "")
	end)
	return #variants > 0 and variants or nil
end

local function countCandidateFlag(candidates, field)
	local count = 0
	for _, candidate in ipairs(candidates or { }) do
		if candidate[field] then count = count + 1 end
	end
	return count
end

local function matchesLockedProgressiveCandidate(candidate, ascendancyId, requiredNodeIds)
	local variant = candidate and candidate.ascendancyVariant
	if not candidate or candidate.progressiveRouteBundle ~= true or candidate.combinedTreeAscendancy ~= true
		or not variant or tonumber(variant.ascendClassId) ~= tonumber(ascendancyId) then return false end
	local allocated = { }
	for _, nodeId in ipairs(candidate.nodeIds or { }) do allocated[tonumber(nodeId) or nodeId] = true end
	for _, nodeId in ipairs(requiredNodeIds or { }) do
		if not allocated[tonumber(nodeId) or nodeId] then return false end
	end
	return true
end

local function countLockedProgressiveCandidates(candidates, ascendancyId, requiredNodeIds)
	local count = 0
	for _, candidate in ipairs(candidates or { }) do
		if matchesLockedProgressiveCandidate(candidate, ascendancyId, requiredNodeIds) then count = count + 1 end
	end
	return count
end

local function isSupportedGemData(gemData)
	return gemData and (
		(gemData.grantedEffect and gemData.grantedEffect.support and not gemData.grantedEffect.unsupported)
		or (gemData.secondaryGrantedEffect and gemData.secondaryGrantedEffect.support and not gemData.secondaryGrantedEffect.unsupported)
	)
end

local function supportedEffect(gemData)
	if not gemData then return nil end
	local effect = gemData.grantedEffect
	if effect and effect.support and not effect.unsupported then return effect end
	effect = gemData.secondaryGrantedEffect
	if effect and effect.support and not effect.unsupported then return effect end
	return nil
end

local function getCandidateGemVariants(candidate)
	if candidate and type(candidate.gemVariants) == "table" then return candidate.gemVariants end
	return candidate and candidate.gemVariant and { candidate.gemVariant } or { }
end

-- Skills-phase planning may first replace the selected Main Skill in a
-- deliberately unlinked planner group. This is a calculation checkpoint only:
-- it cannot contain equipment, tree, or other mutations, and it is never used
-- by the AI Route Planner. The later Equipment/Combined phase must create and
-- prove a legal native socket/link before its result can be accepted.
local function unlinkedMainSkillCheckpoint(candidate, targetSkill, parsed, build)
	if type(candidate) ~= "table" or type(targetSkill) ~= "table"
		or targetSkill.unlinkedPlanning ~= true or type(parsed) ~= "table"
		or type(parsed.search) ~= "table" or parsed.search.routePlannerRunSpec ~= nil
		or tostring(parsed.search.generationPhase or ""):lower() ~= "skills"
		or candidate.generationPhase ~= "skills" or candidate.requiresSocketedMainSkill == true
		or candidate.gearVariant ~= nil or candidate.jewelVariant ~= nil or candidate.jewelVariants ~= nil
		or candidate.configurationVariant ~= nil or candidate.anointVariant ~= nil or candidate.anointVariants ~= nil
		or candidate.timelessVariant ~= nil or candidate.timelessVariants ~= nil or candidate.tattooVariant ~= nil
		or candidate.classVariant ~= nil or candidate.ascendancyVariant ~= nil or candidate.clusterVariant ~= nil
		or #(candidate.nodeIds or { }) > 0 or #(candidate.removeNodeIds or { }) > 0 then
		return false
	end
	local variants = getCandidateGemVariants(candidate)
	if #variants ~= 1 then return false end
	local variant = variants[1]
	local groupIndex = tonumber(targetSkill.groupIndex)
	if type(variant) ~= "table" or variant.kind ~= "selected_main_skill"
		or not groupIndex or tonumber(variant.groupIndex) ~= groupIndex
		or type(targetSkill.gemVariant) ~= "table"
		or variant.gemId ~= targetSkill.gemVariant.gemId
		or variant.skillId ~= targetSkill.gemVariant.skillId then
		return false
	end
	local group = build and build.skillsTab and build.skillsTab.socketGroupList
		and build.skillsTab.socketGroupList[groupIndex]
	if not group or group.source or (type(group.slot) == "string" and group.slot ~= "")
		or group.enabled == false or group.slotEnabled == false then
		return false
	end
	return {
		status = "unlinked_planning",
		scope = "selected_main_skill_checkpoint",
		groups = { },
		violations = { },
		unlinkedGroup = {
			groupIndex = groupIndex,
			gemIndex = tonumber(variant.gemIndex),
			gemId = variant.gemId,
			skillId = variant.skillId,
			reason = "Skills checkpoint only; Equipment must establish and exactly validate a native item socket/link before the skill is playable",
		},
	}
end

-- A Single Skill Route Planner search may change gems only in the selected
-- Main Skill's socket group. Apply this after route/archive composition too,
-- because those candidate sources can carry gem variants of their own.
local function filterCandidatesToSingleSkill(candidates, targetGroupIndex)
	local filtered, rejectedByGroup, rejectionReasons = { }, { }, { }
	local targetIndex = tonumber(targetGroupIndex)
	local rejected = 0
	for _, candidate in ipairs(candidates or { }) do
		local rejection
		for _, variant in ipairs(getCandidateGemVariants(candidate)) do
			local groupIndex = type(variant) == "table" and tonumber(variant.groupIndex) or nil
			if not targetIndex or targetIndex < 1 or targetIndex ~= math.floor(targetIndex) then
				rejection = "selected_main_skill_group_missing"
				break
			elseif not groupIndex or groupIndex < 1 or groupIndex ~= math.floor(groupIndex) then
				rejection = "gem_variant_group_missing_or_invalid"
				break
			elseif groupIndex ~= targetIndex then
				rejection = "gem_variant_outside_selected_main_skill_group"
				break
			end
		end
		if rejection then
			rejected = rejected + 1
			rejectionReasons[rejection] = (rejectionReasons[rejection] or 0) + 1
			for _, variant in ipairs(getCandidateGemVariants(candidate)) do
				local groupIndex = type(variant) == "table" and tonumber(variant.groupIndex) or nil
				if groupIndex and groupIndex ~= targetIndex then
					rejectedByGroup[groupIndex] = (rejectedByGroup[groupIndex] or 0) + 1
				end
			end
		else
			filtered[#filtered + 1] = candidate
		end
	end
	return filtered, {
		status = "single_skill_scope_enforced",
		targetGroupIndex = targetIndex,
		generatedCandidates = #(candidates or { }),
		retainedCandidates = #filtered,
		rejectedCandidates = rejected,
		rejectedByGroup = rejectedByGroup,
		rejectionReasons = rejectionReasons,
	}
end

local function nativeSupportPriority(build, group, effect)
	-- This is only a deterministic ordering hint. The isolated CALCULATOR pass
	-- below remains the sole authority for support compatibility and feasibility.
	local nativeCalcTools = rawget(_G, "calcLib")
	local activeSkills = build.calcsTab and build.calcsTab.mainEnv and build.calcsTab.mainEnv.player
		and build.calcsTab.mainEnv.player.activeSkillList or { }
	local sawGroupSkill = false
	for _, activeSkill in ipairs(activeSkills) do
		if activeSkill.socketGroup == group then
			sawGroupSkill = true
			if nativeCalcTools and type(nativeCalcTools.canGrantedEffectSupportActiveSkill) == "function" then
				local ok, supports = pcall(nativeCalcTools.canGrantedEffectSupportActiveSkill, effect, activeSkill)
				if ok and supports then return 0 end
			end
		end
	end
	return sawGroupSkill and 1 or 2
end

local function createSameGemVariants(build, groupOrder, limit, selectedMainGem)
	local variants = { }
	for _, groupIndex in ipairs(groupOrder) do
		local group = build.skillsTab.socketGroupList[groupIndex]
		for gemIndex, gem in ipairs(group.gemList or { }) do
			if #variants >= limit then return variants end
			local isSelectedMainGemSlot = selectedMainGem
				and selectedMainGem.groupIndex == groupIndex and selectedMainGem.gemIndex == gemIndex
			if not isSelectedMainGemSlot and (groupIndex == build.mainSocketGroup or group.enabled) and gem.enabled and gem.gemData then
				local choices = { }
				for _, choice in pairs(build.data.gemsByGameId[gem.gemData.gameId] or { }) do
					if choice.grantedEffect and not choice.grantedEffect.unsupported then choices[#choices + 1] = choice end
				end
				table.sort(choices, function(a, b)
					if tostring(a.variantId) == tostring(b.variantId) then return tostring(a.id) < tostring(b.id) end
					return tostring(a.variantId) < tostring(b.variantId)
				end)
				for _, choice in ipairs(choices) do
					local qualityStats = choice.grantedEffect and choice.grantedEffect.qualityStats
						or choice.secondaryGrantedEffect and choice.secondaryGrantedEffect.qualityStats
					local qualities = qualityStats and { 20, 23 } or { gem.quality or 0 }
					local levels = { gem.level }
					if choice.naturalMaxLevel and choice.naturalMaxLevel >= 20 and gem.level ~= 21 then levels[#levels + 1] = 21 end
					for _, level in ipairs(levels) do
						for _, quality in ipairs(qualities) do
							local isSameGem = choice.id == gem.gemData.id
							if not (isSameGem and level == gem.level and quality == gem.quality) then
								variants[#variants + 1] = {
									nodeIds = { },
									gemVariant = {
										groupIndex = groupIndex,
										gemIndex = gemIndex,
										gemId = choice.id,
										skillId = choice.grantedEffectId,
										nameSpec = choice.name,
										level = level,
										quality = quality,
									},
									label = choice.name .. " " .. level .. "/" .. quality,
								}
								if #variants >= limit then return variants end
							end
						end
					end
				end
			end
		end
	end
	return variants
end

local function supportPoolSeed(seed, groupIndex, gemIndex)
	local boundedSeed = math.abs(tonumber(seed) or 0) % 2147483647
	return (boundedSeed + (tonumber(groupIndex) or 0) * 97 + (tonumber(gemIndex) or 0) * 53) % 2147483647
end

local function createSupportSwapSlots(build, groupOrder, limit, gemChoices, targetGroupIndex, seed, damageFocus)
	local supportSlots = { }
	local coverage = { eligibleGemVariants = 0, selectedGemVariants = 0, generatedCandidates = 0, truncatedSlots = 0 }
	local supportSlotCount = 0
	for _, groupIndex in ipairs(groupOrder) do
		local group = build.skillsTab.socketGroupList[groupIndex]
		if groupIndex == targetGroupIndex or group.enabled then
			for _, gem in ipairs(group.gemList or { }) do
				if gem.enabled and gem.gemData and isSupportedGemData(gem.gemData) then
					supportSlotCount = supportSlotCount + 1
				end
			end
		end
	end
	local perSlotLimit = supportSlotCount > 0 and math.min(limit, math.max(1, math.ceil(limit / supportSlotCount))) or 0
	for _, groupIndex in ipairs(groupOrder) do
		local group = build.skillsTab.socketGroupList[groupIndex]
		if groupIndex == targetGroupIndex or group.enabled then
			for gemIndex, gem in ipairs(group.gemList or { }) do
				if gem.enabled and gem.gemData and isSupportedGemData(gem.gemData) then
					local supportChoices = { }
					for _, choice in ipairs(gemChoices) do
						local effect = supportedEffect(choice)
						if choice.id ~= gem.gemData.id and choice.grantedEffectId and effect then
							supportChoices[#supportChoices + 1] = {
								gem = choice,
								priority = nativeSupportPriority(build, group, effect) * 100
									+ SkillCatalog.SupportFocusPenalty(choice, damageFocus),
							}
						end
					end
					coverage.eligibleGemVariants = coverage.eligibleGemVariants + #supportChoices
					local selectedChoices, selection = SkillCatalog.SelectSupportVariants(supportChoices,
						math.min(perSlotLimit, #supportChoices), supportPoolSeed(seed, groupIndex, gemIndex))
					if not selectedChoices then selectedChoices = { } end
					coverage.selectedGemVariants = coverage.selectedGemVariants + #selectedChoices
					if selection and selection.truncated then coverage.truncatedSlots = coverage.truncatedSlots + 1 end

					local candidatesByChoice = { }
					local maximumRounds = 0
					for _, supportChoice in ipairs(selectedChoices) do
						local choice = supportChoice.gem
						local maxLevel = choice.naturalMaxLevel or gem.level or 1
						local levels, seenLevels = { }, { }
						local function addLevel(level)
							if type(level) == "number" and level >= 1 and not seenLevels[level] then
								seenLevels[level] = true
								levels[#levels + 1] = level
							end
						end
						addLevel(math.min(gem.level or 1, maxLevel))
						if maxLevel >= 20 then addLevel(20); addLevel(21) end
						local qualityStats = choice.grantedEffect and choice.grantedEffect.qualityStats
							or choice.secondaryGrantedEffect and choice.secondaryGrantedEffect.qualityStats
						local qualities = qualityStats and { 20, 23 } or { gem.quality or 0 }
						local choiceCandidates = { }
						for _, level in ipairs(levels) do
							for _, quality in ipairs(qualities) do
								choiceCandidates[#choiceCandidates + 1] = {
									nodeIds = { },
									gemVariant = {
										groupIndex = groupIndex,
										gemIndex = gemIndex,
										gemId = choice.id,
										skillId = choice.grantedEffectId,
										nameSpec = choice.name,
										level = level,
										quality = quality,
										kind = "support_swap",
										fromGemId = gem.gemData.id,
									},
									label = "Replace " .. tostring(gem.gemData.name) .. " with " .. tostring(choice.name) .. " " .. level .. "/" .. quality,
								}
							end
						end
						candidatesByChoice[#candidatesByChoice + 1] = choiceCandidates
						maximumRounds = math.max(maximumRounds, #choiceCandidates)
					end
					local slotCandidates = { }
					for round = 1, maximumRounds do
						for _, choiceCandidates in ipairs(candidatesByChoice) do
							if choiceCandidates[round] then
								slotCandidates[#slotCandidates + 1] = choiceCandidates[round]
								if #slotCandidates >= perSlotLimit then break end
							end
						end
						if #slotCandidates >= perSlotLimit then break end
					end
					coverage.generatedCandidates = coverage.generatedCandidates + #slotCandidates
					if #slotCandidates > 0 then supportSlots[#supportSlots + 1] = slotCandidates end
				end
			end
		end
	end
	return supportSlots, coverage
end

local function legalSupportLevel(build, gemData)
	local effect = supportedEffect(gemData)
	local levels = effect and effect.levels or { }
	local maximum = math.min(tonumber(gemData and gemData.naturalMaxLevel) or #levels, #levels)
	local characterLevel = math.max(1, math.floor(tonumber(build and build.characterLevel) or 1))
	local output = build and build.calcsTab and build.calcsTab.mainOutput
	if not effect or not output or type(calcLib) ~= "table" or type(calcLib.getGemStatRequirement) ~= "function" then
		return nil
	end
	for level = maximum, 1, -1 do
		local levelData = levels[level]
		local requiredLevel = levelData and (tonumber(levelData.levelRequirement) or 1)
		if requiredLevel and requiredLevel <= characterLevel then
			local strength = calcLib.getGemStatRequirement(requiredLevel, true, gemData.reqStr)
			local dexterity = calcLib.getGemStatRequirement(requiredLevel, true, gemData.reqDex)
			local intelligence = calcLib.getGemStatRequirement(requiredLevel, true, gemData.reqInt)
			if strength <= (tonumber(output.Str) or -1) and dexterity <= (tonumber(output.Dex) or -1)
				and intelligence <= (tonumber(output.Int) or -1) then
				return level
			end
		end
	end
	return nil
end

local function createSupportAddSlots(build, limit, targetSkill, gemChoices, seed, damageFocus)
	local supportSlots = { }
	local coverage = { eligibleGemVariants = 0, selectedGemVariants = 0, generatedCandidates = 0, truncated = false }
	local groupIndex = targetSkill and targetSkill.groupIndex
	local group = groupIndex and build.skillsTab.socketGroupList[groupIndex]
	if not group or limit <= 0 or group.enabled == false or group.slotEnabled == false then return supportSlots, coverage end
	local existingGemIds = { }
	for _, instance in ipairs(group.gemList or { }) do
		if instance.gemData and isSupportedGemData(instance.gemData) then
			existingGemIds[instance.gemData.id] = true
		end
	end
	local choices, seenGemIds = { }, { }
	for _, choice in ipairs(gemChoices or { }) do
		local effect = supportedEffect(choice)
		local gemId = choice and choice.id
		if effect and gemId and not existingGemIds[gemId] and not seenGemIds[gemId]
			and choice.grantedEffectId then
			local priority = nativeSupportPriority(build, group, effect) * 100
				+ SkillCatalog.SupportFocusPenalty(choice, damageFocus)
			local level = legalSupportLevel(build, choice)
			if level then
				seenGemIds[gemId] = true
				choices[#choices + 1] = { gem = choice, priority = priority, level = level }
			end
		end
	end
	coverage.eligibleGemVariants = #choices
	local baseGemCount = #(group.gemList or { })
	-- PoE skill groups have at most six socketed gems. For assigned groups the
	-- native socket/link/color graph further limits this to a contiguous prefix.
	local maximumAddCount = math.min(5, math.max(0, 6 - baseGemCount))
	-- Rotate through every loaded support variant across reproducible seeds. The
	-- exact-evaluation budget bounds this proposal pool; no gameId-level collapse
	-- silently removes alternate gem variants.
	local choiceLimit = maximumAddCount > 0 and math.max(1, math.ceil(limit / maximumAddCount)) or 0
	local selectedChoices, selection = SkillCatalog.SelectSupportVariants(choices, math.min(choiceLimit, #choices), seed)
	if not selectedChoices then selectedChoices = { } end
	coverage.selectedGemVariants = #selectedChoices
	coverage.truncated = selection and selection.truncated or false
	choices = selectedChoices
	local maximumChoiceCount = #choices
	local qualitiesByChoice = { }
	for index = 1, maximumChoiceCount do
		local choice = choices[index]
		local qualityStats = choice.gem.grantedEffect and choice.gem.grantedEffect.qualityStats
			or choice.gem.secondaryGrantedEffect and choice.gem.secondaryGrantedEffect.qualityStats
		qualitiesByChoice[index] = qualityStats and { 20, 23 } or { 0 }
	end
	for slotOffset = 1, maximumAddCount do
		local slotIndex = baseGemCount + slotOffset
		local candidatesByChoice, maximumRounds = { }, 0
		for choiceIndex = 1, maximumChoiceCount do
			local entry = choices[choiceIndex]
			local choice = entry.gem
			local canAdd = SkillCatalog.CanAddSupportAtSlot(build, groupIndex, slotIndex, choice, slotOffset - 1)
			if canAdd then
				local choiceCandidates = { }
				for _, quality in ipairs(qualitiesByChoice[choiceIndex]) do
					local variant = {
						groupIndex = groupIndex,
						gemIndex = slotIndex,
						gemId = choice.id,
						skillId = choice.grantedEffectId,
						nameSpec = choice.name,
						level = entry.level,
						quality = quality,
						kind = "support_add",
						targetSkillId = targetSkill.gemVariant and targetSkill.gemVariant.skillId or nil,
						unlinkedSupportPlan = group.slot == nil,
					}
					choiceCandidates[#choiceCandidates + 1] = {
						nodeIds = { },
						gemVariant = variant,
						unlinkedSupportPlan = variant.unlinkedSupportPlan,
						label = "Add " .. tostring(choice.name) .. " " .. tostring(entry.level) .. "/" .. tostring(quality)
							.. (variant.unlinkedSupportPlan and " (unlinked support plan)" or ""),
					}
				end
				candidatesByChoice[#candidatesByChoice + 1] = choiceCandidates
				maximumRounds = math.max(maximumRounds, #choiceCandidates)
			end
		end
		local slotCandidates = { }
		for round = 1, maximumRounds do
			for _, choiceCandidates in ipairs(candidatesByChoice) do
				if choiceCandidates[round] then slotCandidates[#slotCandidates + 1] = choiceCandidates[round] end
			end
		end
		if #slotCandidates == 0 then break end
		coverage.generatedCandidates = coverage.generatedCandidates + #slotCandidates
		supportSlots[#supportSlots + 1] = slotCandidates
	end
	return supportSlots, coverage
end

local function createSupportCombinationVariants(build, supportSlots, limit, targetGroupIndex, kind)
	local variantsByArity = { }
	if limit <= 0 or not targetGroupIndex then return variantsByArity end
	local targetSlots = { }
	for _, slotCandidates in ipairs(supportSlots) do
		local first = slotCandidates[1]
		if first and first.gemVariant and first.gemVariant.kind == kind
			and first.gemVariant.groupIndex == targetGroupIndex then
			targetSlots[#targetSlots + 1] = slotCandidates
		end
	end
	local maximumArity = math.min(5, #targetSlots)
	if maximumArity < 2 then return variantsByArity end
	local slotCombinationsByArity = { }
	local function collectSlotCombinations(arity, firstIndex, selected, output)
		if #selected == arity then
			local combination = { }
			for index, slotIndex in ipairs(selected) do combination[index] = targetSlots[slotIndex] end
			output[#output + 1] = combination
			return
		end
		local remaining = arity - #selected
		for slotIndex = firstIndex, #targetSlots - remaining + 1 do
			selected[#selected + 1] = slotIndex
			collectSlotCombinations(arity, slotIndex + 1, selected, output)
			selected[#selected] = nil
		end
	end
	for arity = 2, maximumArity do
		local slotCombinations = { }
		if kind == "support_add" then
			-- Additions must fill consecutive unused gem indices; an arbitrary
			-- subset would create a gap and be rejected by the native SkillsTab.
			local prefix = { }
			for index = 1, arity do prefix[index] = targetSlots[index] end
			slotCombinations[1] = prefix
		else
			collectSlotCombinations(arity, 1, { }, slotCombinations)
		end
		slotCombinationsByArity[arity] = slotCombinations
		variantsByArity[arity] = { }
	end
	local strides = { 1, 3, 5, 7, 11, 13 }
	local combinationKeys = { }
	local emitted = 0
	local attemptLimit = math.min(4096, math.max(limit * 4, #targetSlots * 2))
	for attempt = 1, attemptLimit do
		local progressed = false
		for arity = 2, maximumArity do
			if emitted >= limit then break end
			local slotCombinations = slotCombinationsByArity[arity]
			local arityVariants = variantsByArity[arity]
			local combinationIndex = ((attempt - 1) % #slotCombinations) + 1
			local selectedSlots = slotCombinations[combinationIndex]
			local round = math.floor((attempt - 1) / #slotCombinations)
			local stride = strides[((round + arity + combinationIndex - 2) % #strides) + 1]
			local usedGameIds, gemVariants, names, keyParts = { }, { }, { }, { }
			local valid = true
			for offset, slotCandidates in ipairs(selectedSlots) do
				local count = #slotCandidates
				local startIndex = ((round * (arity + 1) + offset * stride + combinationIndex - 2) % count) + 1
				local selected
				for probe = 0, count - 1 do
					local choice = slotCandidates[((startIndex + probe - 1) % count) + 1]
					local gemVariant = choice and choice.gemVariant
					local gemData = gemVariant and build.data.gems[gemVariant.gemId]
					local gameId = gemData and gemData.gameId
					if gemVariant and gemVariant.kind == kind and gameId and not usedGameIds[gameId] then
						selected = choice
						usedGameIds[gameId] = true
						gemVariants[#gemVariants + 1] = gemVariant
						names[#names + 1] = tostring(gemData.name or gemData.id)
						keyParts[#keyParts + 1] = tostring(gemVariant.gemIndex) .. ":"
							.. tostring(gemData.id) .. ":" .. tostring(gemVariant.level) .. ":" .. tostring(gemVariant.quality)
						break
					end
				end
				if not selected then valid = false; break end
			end
			local key = valid and table.concat(keyParts, "|") or nil
			if valid and key and not combinationKeys[key] then
				combinationKeys[key] = true
				local adding = kind == "support_add"
				local firstVariant = gemVariants[1]
				local unlinkedPlan = adding and firstVariant.unlinkedSupportPlan or nil
				local action = "Add "
				if not adding then
					local oldNames = { }
					local group = build.skillsTab.socketGroupList[targetGroupIndex]
					for _, variant in ipairs(gemVariants) do
						local source = group and group.gemList and group.gemList[variant.gemIndex]
						oldNames[#oldNames + 1] = tostring(source and source.gemData and source.gemData.name or "support")
					end
					action = "Replace " .. table.concat(oldNames, " + ") .. " with "
				end
				local suffix = unlinkedPlan and " (unlinked support plan)" or ""
				local candidate = {
					nodeIds = { },
					gemVariants = gemVariants,
					supportCombination = true,
					supportPackageArity = arity,
					supportPackageKind = kind,
					unlinkedSupportPlan = unlinkedPlan,
					label = action .. table.concat(names, " + ") .. suffix,
				}
				arityVariants[#arityVariants + 1] = candidate
				emitted = emitted + 1
				progressed = true
			end
		end
		if emitted >= limit then break end
		if not progressed and attempt >= math.min(64, attemptLimit) then break end
	end
	return variantsByArity
end

local function createGemVariants(build, limit, targetSkill, seed, damageFocus, strictGroupIndex)
	local variants = { }
	if limit <= 0 then return variants end
	local targetGroupIndex = targetSkill and targetSkill.groupIndex
	local targetGemVariant = targetSkill and targetSkill.gemVariant
	local targetGemData = targetGemVariant and build.data.gems[targetGemVariant.gemId]
	local socketGroups = build.skillsTab.socketGroupList
	local groupOrder = { }
	if strictGroupIndex ~= nil then
		local groupIndex = tonumber(strictGroupIndex)
		if groupIndex and groupIndex >= 1 and groupIndex == math.floor(groupIndex) and socketGroups[groupIndex] then
			groupOrder[1] = groupIndex
		end
	else
		for groupIndex = 1, #socketGroups do groupOrder[#groupOrder + 1] = groupIndex end
	end
	table.sort(groupOrder, function(a, b)
		if a == b then return false end
		if a == targetGroupIndex then return true end
		if b == targetGroupIndex then return false end
		return a < b
	end)
	local regularVariants = { }
	if targetGemVariant and targetGemData then
		local effect = targetGemData.grantedEffect
		local maxLevel = math.min(tonumber(targetGemData.naturalMaxLevel) or #(effect.levels or { }), #(effect.levels or { }))
		local levels, levelSeen = { }, { }
		local function addLevel(level)
			local levelData = effect and effect.levels and effect.levels[level]
			local characterLevel = tonumber(build.characterLevel) or 1
			if type(level) == "number" and level >= 1 and level <= maxLevel and levelData
				and (tonumber(levelData.levelRequirement) or 1) <= characterLevel and not levelSeen[level] then
				levelSeen[level] = true
				levels[#levels + 1] = level
			end
		end
		addLevel(targetGemVariant.level)
		if maxLevel >= 20 then addLevel(20); addLevel(21) end
		local hasQualityStats = effect and effect.qualityStats
			or targetGemData.secondaryGrantedEffect and targetGemData.secondaryGrantedEffect.qualityStats
		local qualities = hasQualityStats and { targetGemVariant.quality, 20, 23 } or { targetGemVariant.quality }
		local seen = { }
		for _, level in ipairs(levels) do
			for _, quality in ipairs(qualities) do
				local key = tostring(level) .. ":" .. tostring(quality)
				if not seen[key] and (level ~= targetGemVariant.level or quality ~= targetGemVariant.quality) then
					seen[key] = true
					local gemVariant = shallowCopy(targetGemVariant)
					gemVariant.level = level
					gemVariant.quality = quality
					regularVariants[#regularVariants + 1] = {
						nodeIds = { },
							gemVariant = gemVariant,
							selectedMainGemProposal = true,
							label = tostring(targetGemData.name) .. " " .. tostring(level) .. "/" .. tostring(quality),
					}
				end
			end
		end
	end
	local existingGemVariants = createSameGemVariants(build, groupOrder,
		math.max(0, limit - #regularVariants), targetGemVariant)
	for _, variant in ipairs(existingGemVariants) do regularVariants[#regularVariants + 1] = variant end
	local gemChoices = { }
	for gemId, choice in pairs(build.data.gems or { }) do
		if type(gemId) == "string" and choice and isSupportedGemData(choice) then
			gemChoices[#gemChoices + 1] = choice
		end
	end
	table.sort(gemChoices, function(a, b) return tostring(a.id) < tostring(b.id) end)
	local supportSlots, swapCoverage = createSupportSwapSlots(build, groupOrder, limit, gemChoices,
		targetGroupIndex or build.mainSocketGroup, seed, damageFocus)
	local supportAddSlots, addCoverage = createSupportAddSlots(build, limit, targetSkill, gemChoices, seed, damageFocus)
	local comboQuota = limit >= 3 and math.min(limit, math.max(1, math.floor(limit * 0.35))) or 0
	local targetSwapSlotCount = 0
	for _, slotCandidates in ipairs(supportSlots) do
		local first = slotCandidates[1]
		if first and first.gemVariant and first.gemVariant.kind == "support_swap"
			and first.gemVariant.groupIndex == (targetGroupIndex or build.mainSocketGroup) then
			targetSwapSlotCount = targetSwapSlotCount + 1
		end
	end
	local canAddCombinations = #supportAddSlots >= 2
	local canSwapCombinations = targetSwapSlotCount >= 2
	local supportAddComboQuota, supportSwapComboQuota = 0, 0
	if canAddCombinations and canSwapCombinations then
		supportAddComboQuota = math.floor(comboQuota / 2)
		supportSwapComboQuota = comboQuota - supportAddComboQuota
	elseif canAddCombinations then
		supportAddComboQuota = comboQuota
	elseif canSwapCombinations then
		supportSwapComboQuota = comboQuota
	end
	local supportSwapCombos = createSupportCombinationVariants(build, supportSlots,
		supportSwapComboQuota, targetGroupIndex or build.mainSocketGroup, "support_swap")
	local supportAddCombos = createSupportCombinationVariants(build, supportAddSlots,
		supportAddComboQuota, targetGroupIndex or build.mainSocketGroup, "support_add")
	local supportVariants = { }
	local supportAddVariants = { }
	local maxRounds = limit
	for round = 1, maxRounds do
		for _, slotCandidates in ipairs(supportSlots) do
			if slotCandidates[round] then
				supportVariants[#supportVariants + 1] = slotCandidates[round]
				if #supportVariants >= limit then break end
			end
		end
		if #supportVariants >= limit then break end
	end
	for _, supportCandidate in ipairs(supportAddSlots[1] or { }) do
		supportAddVariants[#supportAddVariants + 1] = supportCandidate
		if #supportAddVariants >= limit then break end
	end
	local allSupportCombinations = { }
	local maxCombinationRound = math.max(comboQuota, 0)
	for round = 1, maxCombinationRound do
		for arity = 2, 5 do
			local swap = supportSwapCombos[arity] and supportSwapCombos[arity][round]
			local added = supportAddCombos[arity] and supportAddCombos[arity][round]
			if swap and #allSupportCombinations < comboQuota then allSupportCombinations[#allSupportCombinations + 1] = swap end
			if added and #allSupportCombinations < comboQuota then allSupportCombinations[#allSupportCombinations + 1] = added end
		end
	end
	local supportCombinationQuota = math.min(#allSupportCombinations, comboQuota)
	local supportQuota = math.min(#supportVariants + #supportAddVariants, math.floor((limit - supportCombinationQuota + 1) / 2))
	local regularQuota = math.min(#regularVariants, limit - supportCombinationQuota - supportQuota)
	local families = {
		{ candidates = allSupportCombinations, quota = supportCombinationQuota, index = 1 },
		{ candidates = supportVariants, quota = math.min(#supportVariants, math.floor(supportQuota / 2)), index = 1 },
		{ candidates = supportAddVariants, quota = supportQuota - math.min(#supportVariants, math.floor(supportQuota / 2)), index = 1 },
		{ candidates = regularVariants, quota = regularQuota, index = 1 },
	}
	local function appendFromFamilies(useQuota)
		local progressed = false
		for _, family in ipairs(families) do
			local maximum = useQuota and family.quota or #family.candidates
			if #variants < limit and family.index <= maximum then
				variants[#variants + 1] = family.candidates[family.index]
				family.index = family.index + 1
				progressed = true
			end
		end
		return progressed
	end
	while #variants < limit and appendFromFamilies(true) do end
	-- Reassign unused bounded slots when one candidate family is smaller than its quota.
	while #variants < limit and appendFromFamilies(false) do end
	if targetGemVariant then
		local prioritized, remainder = { }, { }
		for _, candidate in ipairs(variants) do
			local gemChanges = candidate.gemVariants or (candidate.gemVariant and { candidate.gemVariant }) or { }
			local targetAlreadyChanged = false
			for _, changedGem in ipairs(gemChanges) do
				if changedGem.groupIndex == targetGemVariant.groupIndex and changedGem.gemIndex == targetGemVariant.gemIndex then
					targetAlreadyChanged = true
					break
				end
			end
			if not targetAlreadyChanged then table.insert(gemChanges, 1, shallowCopy(targetGemVariant)) end
			candidate.gemVariant = nil
			candidate.gemVariants = gemChanges
			if not candidate.selectedMainGemProposal then
				candidate.label = tostring(targetGemData and targetGemData.name or "Selected Main Skill")
					.. " + " .. tostring(candidate.label or "Gem variant")
			end
			if candidate.selectedMainGemProposal then prioritized[#prioritized + 1] = candidate
			else remainder[#remainder + 1] = candidate end
		end
		for _, candidate in ipairs(remainder) do prioritized[#prioritized + 1] = candidate end
		variants = prioritized
	end
	local catalogSummary = SkillCatalog.Summary(build)
	return variants, {
		catalog = catalogSummary,
		poolSeed = tonumber(seed) or 0,
		supportSwapEligibleGemVariants = swapCoverage and swapCoverage.eligibleGemVariants or 0,
		supportSwapSelectedGemVariants = swapCoverage and swapCoverage.selectedGemVariants or 0,
		supportSwapGeneratedCandidates = swapCoverage and swapCoverage.generatedCandidates or 0,
		supportSwapTruncatedSlots = swapCoverage and swapCoverage.truncatedSlots or 0,
		supportAddEligibleGemVariants = addCoverage and addCoverage.eligibleGemVariants or 0,
		supportAddSelectedGemVariants = addCoverage and addCoverage.selectedGemVariants or 0,
		supportAddGeneratedCandidates = addCoverage and addCoverage.generatedCandidates or 0,
		supportAddTruncated = addCoverage and addCoverage.truncated or false,
	}
end

local function createBuildProxy(build, scenarioProfile, targetSkill, scenarioEnemyPreset, scenarioEnemyLevel)
	local skillTab = { }
	for key, value in pairs(build.skillsTab) do skillTab[key] = value end
	-- CalcSetup may call SkillsTab methods while it rebuilds item- and tree-granted
	-- skills. Keep the class metatable on the proxy so candidate gem changes still
	-- use the normal PoB skill-group processing path.
	setmetatable(skillTab, getmetatable(build.skillsTab))
	local function resetGroups(gemVariants, socketBinding)
		local variantsByGroup, sourceGemIndexMaps = { }, { }
		local baseTargetGem = targetSkill and targetSkill.gemVariant
		if baseTargetGem then
			variantsByGroup[baseTargetGem.groupIndex] = { [baseTargetGem.gemIndex] = baseTargetGem }
		end
		for _, variant in ipairs(gemVariants or { }) do
			variantsByGroup[variant.groupIndex] = variantsByGroup[variant.groupIndex] or { }
			variantsByGroup[variant.groupIndex][variant.gemIndex] = variant
		end
		local groups = { }
		for groupIndex, group in ipairs(build.skillsTab.socketGroupList) do
			local groupCopy = shallowCopy(group)
			if socketBinding and socketBinding.groupIndex == groupIndex then
				groupCopy.slot = socketBinding.slotName
				groupCopy.slotEnabled = true
			end
			groupCopy.gemList = { }
			local sourceGemIndexMap = { }
			sourceGemIndexMaps[groupIndex] = sourceGemIndexMap
			for gemIndex, gem in ipairs(group.gemList or { }) do
				local gemVariant = variantsByGroup[groupIndex] and variantsByGroup[groupIndex][gemIndex]
				if not (gemVariant and gemVariant.kind == "support_remove") then
					local gemCopy = shallowCopy(gem)
					if gemVariant then
						gemCopy.gemId = gemVariant.gemId or gemCopy.gemId
						gemCopy.skillId = gemVariant.skillId or gemCopy.skillId
						gemCopy.nameSpec = gemVariant.nameSpec or gemCopy.nameSpec
						if gemVariant.gemId then
							gemCopy.gemData = build.data.gems[gemVariant.gemId]
							gemCopy.grantedEffect = gemCopy.gemData and gemCopy.gemData.grantedEffect
						end
						gemCopy.level = gemVariant.level
						gemCopy.quality = gemVariant.quality
					end
					local newGemIndex = #groupCopy.gemList + 1
					sourceGemIndexMap[gemIndex] = newGemIndex
					groupCopy.gemList[newGemIndex] = gemCopy
				end
			end
			-- mainActiveSkill and mainActiveSkillCalcs index active effects rather
			-- than gemList slots. A support removal must preserve both selectors,
			-- including the valid selection placeholders on empty skill groups.
			for _, gemVariant in ipairs(gemVariants or { }) do
				if gemVariant.kind == "support_add" and gemVariant.groupIndex == groupIndex then
					if gemVariant.gemIndex ~= #groupCopy.gemList + 1 then
						error("PoB support proposal did not target the next native gem slot")
					end
					local gemData = build.data.gems[gemVariant.gemId]
					if not gemData then error("PoB support proposal is missing from the loaded gem database") end
					groupCopy.gemList[#groupCopy.gemList + 1] = {
						gemId = gemData.id,
						skillId = gemData.grantedEffectId,
						nameSpec = gemData.name,
						level = gemVariant.level,
						quality = gemVariant.quality,
						enabled = true,
						enableGlobal1 = true,
						enableGlobal2 = true,
						count = 1,
					}
				end
			end
			groups[groupIndex] = groupCopy
		end
		if targetSkill then
			local selectedGroup = groups[targetSkill.groupIndex]
			if selectedGroup then
				local targetVariant = targetSkill.gemVariant
				if targetVariant then
					local targetGemIndex = sourceGemIndexMaps[targetSkill.groupIndex]
						and sourceGemIndexMaps[targetSkill.groupIndex][targetVariant.gemIndex]
					local targetGem = targetGemIndex and selectedGroup.gemList[targetGemIndex]
					local selectedIndex = SkillCatalog.ResolveMainSkillIndex(
						selectedGroup, targetGemIndex, targetVariant.skillId)
					if not targetGem or not selectedIndex then
						error("PoB could not resolve the selected Main Skill gem/effect in the target socket group")
					end
					targetSkill.currentGemInstance = targetGem
					targetSkill.activeSkillIndex = selectedIndex
				end
				local selectedIndex = targetSkill.activeSkillIndex or targetSkill.skillIndex
				selectedGroup.mainActiveSkill = selectedIndex
				selectedGroup.mainActiveSkillCalcs = selectedIndex
			end
		end
		skillTab.socketGroupList = groups
		-- Reuse PoB's native gem requirement and socket-colour resolution. A
		-- replacement support can have different level/stat requirements and may
		-- gain a different matching-socket quality bonus from the original gem.
		for groupIndex in pairs(variantsByGroup) do
			local changedGroup = groups[groupIndex]
			if changedGroup then skillTab:ProcessSocketGroup(changedGroup) end
		end
		if skillTab.build then skillTab:UpdateSocketGroups() end
	end
	local proxy = {
		skillsTab = skillTab,
		mainSocketGroup = targetSkill and targetSkill.groupIndex or build.mainSocketGroup,
		optimizerTargetSkill = targetSkill,
	}
	setmetatable(proxy, { __index = build })
	skillTab.build = proxy
	resetGroups()
	local baselineConfiguration, configurationError = configurationChoices.ReadCurrent(build)
	if not baselineConfiguration then error(configurationError or "PoB configuration choices could not be read") end
	local configTab, itemsTab, scenarioDetails, scenarioError = scenario.Create(build, scenarioProfile, proxy, nil, baselineConfiguration, scenarioEnemyPreset, scenarioEnemyLevel)
	if not configTab then error(scenarioError or "PoB scenario could not be prepared") end
	proxy.configTab = configTab
	proxy.itemsTab = itemsTab
	return proxy, resetGroups, itemsTab, scenarioDetails
end

local function evaluateSupportSwapVariant(variant, evalBuild, env, itemsTab)
	local group = evalBuild and evalBuild.skillsTab and evalBuild.skillsTab.socketGroupList[variant.groupIndex]
	local gem = group and group.gemList and group.gemList[variant.gemIndex]
	if not gem or not isSupportedGemData(gem.gemData) then
		return { status = "unsupported", reason = "PoB could not resolve this proposal as a supported support gem" }
	end
	local socketsValid, socketEvidence = SkillCatalog.ValidateSocketGroup(evalBuild, variant.groupIndex, itemsTab)
	if not socketsValid or type(socketEvidence) ~= "table"
		or (socketEvidence.status ~= "linked" and socketEvidence.status ~= "granted_skill") then
		local reason = type(socketEvidence) == "string" and socketEvidence
			or "PoB did not certify a physical native socket/link for the changed support group"
		return {
			status = "violated", socketViolation = true, groupIndex = variant.groupIndex,
			reason = "The changed support group fails PoB's native socket/link check: " .. tostring(reason),
		}
	end
	local hasActiveSkill, groupSkillCount, supportSourceCount, appliedSourceCount = false, 0, 0, 0
	for _, activeSkill in ipairs(env and env.player and env.player.activeSkillList or { }) do
		local effectId = activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
			and activeSkill.activeEffect.grantedEffect.id
		if activeSkill.socketGroup == group and (not variant.targetSkillId or effectId == variant.targetSkillId) then
			hasActiveSkill = true
			groupSkillCount = groupSkillCount + 1
			for _, supportEffect in ipairs(activeSkill.supportList or { }) do
				if supportEffect.srcInstance == gem then supportSourceCount = supportSourceCount + 1 end
			end
			for _, effect in ipairs(activeSkill.effectList or { }) do
				if effect and effect.srcInstance == gem and effect.grantedEffect and effect.grantedEffect.support then
					appliedSourceCount = appliedSourceCount + 1
					return {
						status = "valid", gemId = gem.gemData.id, name = gem.gemData.name,
						groupSkillCount = groupSkillCount, supportSourceCount = supportSourceCount,
						appliedSourceCount = appliedSourceCount,
						kind = variant.kind,
						unlinkedPlan = variant.kind == "support_add" and group.slot == nil or nil,
					}
				end
			end
		end
	end
	if not hasActiveSkill then
		return {
			status = "unsupported", reason = "PoB did not expose an active skill for the replacement support's socket group",
			groupSkillCount = groupSkillCount, supportSourceCount = supportSourceCount,
			appliedSourceCount = appliedSourceCount,
		}
	end
	return {
		status = "violated", reason = "The replacement support did not support any active skill in its PoB socket group",
		gemId = gem.gemData.id, name = gem.gemData.name,
		groupSkillCount = groupSkillCount, supportSourceCount = supportSourceCount,
		appliedSourceCount = appliedSourceCount,
	}
end

local function evaluateSupportSwap(candidate, evalBuild, env, itemsTab)
	local checks = { }
	for _, variant in ipairs(getCandidateGemVariants(candidate)) do
		if variant.kind == "support_swap" or variant.kind == "support_add" then
			local check = evaluateSupportSwapVariant(variant, evalBuild, env, itemsTab)
			check.kind = variant.kind
			checks[#checks + 1] = check
			if check.status ~= "valid" then
				check.variants = checks
				return check
			end
		end
	end
	if #checks == 0 then return { status = "not_applicable" } end
	if #checks == 1 then return checks[1] end
	return { status = "valid", count = #checks, variants = checks }
end

local function createSpecProxy(build, sourceSpec, candidate)
	local hasTreeMutation = #(candidate.nodeIds or { }) > 0 or #(candidate.removeNodeIds or { }) > 0
		or candidate.classVariant or candidate.ascendancyVariant or candidate.jewelVariant
		or (candidate.jewelVariants and #candidate.jewelVariants > 0)
		or candidate.masteryVariant or candidate.tattooVariant or candidate.timelessVariant or candidate.anointVariant or candidate.anointVariants or candidate.gearVariant
	if not hasTreeMutation then return nil end
	local variants = {
		classId = candidate.classVariant and candidate.classVariant.classId or nil,
		ascendancyVariant = candidate.ascendancyVariant,
		jewelVariant = candidate.jewelVariant,
		jewelVariants = candidate.jewelVariants,
		masteryVariant = candidate.masteryVariant,
		tattooVariant = candidate.tattooVariant,
		timelessVariant = candidate.timelessVariant,
		anointVariant = candidate.anointVariant,
		anointVariants = candidate.anointVariants,
		gearVariant = candidate.gearVariant,
	}
	local proxy, err, itemsTabProxy, resolvedGearVariant = candidateModule.BuildPassiveSpec(build, candidate.nodeIds, candidate.removeNodeIds, variants)
	if not proxy then error(err or "PoB could not reconstruct this passive candidate") end
	if resolvedGearVariant then candidate.gearVariant = resolvedGearVariant end
	-- Store the actual final allocation delta, including dependencies removed by
	-- PoB's DeallocNode and any connector nodes selected by PoB's own path repair.
	candidate.nodeIds = proxy.optimizerAddedNodeIds or { }
	candidate.removeNodeIds = proxy.optimizerRemovedNodeIds or { }
	return proxy, itemsTabProxy
end

local function copyArchivedRouteProvenance(destination, sources)
	local patternSources, seen, sourceCount = { }, { }, 0
	for _, source in ipairs(sources or { }) do
		if source and source.archivedRoutePattern == true then
			local rows = source.archivedPatternSources
			if type(rows) ~= "table" or #rows == 0 then
				rows = { {
					patternIndex = source.archivedPatternIndex,
					variantIndex = source.archivedPatternVariantIndex,
					supportCount = source.archivedPatternSupportCount,
					sampleCount = source.archivedPatternSampleCount,
					similarity = source.archivedPatternSimilarity,
					label = source.label,
				} }
			end
			for _, row in ipairs(rows) do
				local patternIndex = tonumber(row.patternIndex)
				local variantIndex = tonumber(row.variantIndex)
				local key = patternIndex and (tostring(patternIndex) .. ":" .. tostring(variantIndex or 0))
					or ("label:" .. tostring(row.label or source.label or "archive route"))
				if not seen[key] then
					seen[key] = true
					sourceCount = sourceCount + 1
					if #patternSources < 8 then patternSources[#patternSources + 1] = shallowCopy(row) end
				end
			end
		end
	end
	if sourceCount == 0 then return false end
	destination.archivedRoutePattern = true
	destination.archiveDerivedPassiveRoute = true
	destination.archivedRouteComposition = true
	destination.archivedPatternSources = patternSources
	destination.archivedPatternSourceCount = sourceCount
	if sourceCount == 1 and patternSources[1] then
		destination.archivedPatternIndex = patternSources[1].patternIndex
		destination.archivedPatternVariantIndex = patternSources[1].variantIndex
		destination.archivedPatternSupportCount = patternSources[1].supportCount
		destination.archivedPatternSampleCount = patternSources[1].sampleCount
		destination.archivedPatternSimilarity = patternSources[1].similarity
	end
	return true
end

local function combineRoutesAndMutations(routes, mutationGroups, limit, compositionOptions)
	local combined = { }
	if limit <= 0 then return combined end
	compositionOptions = compositionOptions or { }
	local maxVariants = 0
	for _, group in ipairs(mutationGroups) do maxVariants = math.max(maxVariants, #group.candidates) end
	for variantIndex = 1, maxVariants do
		for _, route in ipairs(routes) do
			for groupIndex, group in ipairs(mutationGroups) do
				local mutation = group.candidates[variantIndex]
				if mutation then
					local mergedGemVariants, gemVariantConflict = mergeCandidateGemVariants(route, mutation)
					local mergedGear, gearError
					if compositionOptions.mergeGearVariants then
						mergedGear, gearError = Equipment.MergeVariants(route.gearVariant, mutation.gearVariant, compositionOptions)
					else
						mergedGear = Equipment.CopyVariant(mutation.gearVariant)
					end
					local gearConflict = compositionOptions.mergeGearVariants
						and (route.gearVariant ~= nil or mutation.gearVariant ~= nil) and mergedGear == nil
					if not gemVariantConflict and not gearConflict then
					local result = { nodeIds = { }, removeNodeIds = { }, label = tostring(route.label or "Native route") .. " + " .. tostring(mutation.label or "Mutation"), island = (((tonumber(route.island) or 1) + groupIndex + variantIndex - 1) % 4) + 1 }
					copyHierarchicalProvenance(route, result, "route_mutation")
					copyArchivedRouteProvenance(result, { route, mutation })
					for _, key in ipairs({ "classVariant", "ascendancyVariant", "ascendancyPointCost",
						"mainAscendancyPointCost", "secondaryAscendancyPointCost", "combinedTreeAscendancy" }) do
						if route[key] ~= nil then
							result[key] = type(route[key]) == "table" and shallowCopy(route[key]) or route[key]
						end
					end
					local seenNodeIds, seenRemovedNodeIds = { }, { }
					for _, nodeId in ipairs(route.nodeIds) do
						if not seenNodeIds[nodeId] then seenNodeIds[nodeId] = true; result.nodeIds[#result.nodeIds + 1] = nodeId end
					end
					for _, nodeId in ipairs(mutation.nodeIds or { }) do
						if not seenNodeIds[nodeId] then seenNodeIds[nodeId] = true; result.nodeIds[#result.nodeIds + 1] = nodeId end
					end
					for _, nodeId in ipairs(route.removeNodeIds or { }) do
						if not seenRemovedNodeIds[nodeId] then seenRemovedNodeIds[nodeId] = true; result.removeNodeIds[#result.removeNodeIds + 1] = nodeId end
					end
					for _, nodeId in ipairs(mutation.removeNodeIds or { }) do
						if not seenRemovedNodeIds[nodeId] then seenRemovedNodeIds[nodeId] = true; result.removeNodeIds[#result.removeNodeIds + 1] = nodeId end
					end
					for _, key in ipairs({ "ascendancyVariant", "jewelVariant", "masteryVariant", "tattooVariant", "timelessVariant", "anointVariant", "configurationVariant" }) do
						if mutation[key] then result[key] = shallowCopy(mutation[key]) end
					end
					result.gemVariants = mergedGemVariants
					-- Conflicting edits to one native gem slot are not a valid composition.
					-- Skip it instead of relying on resetGroups' last-write-wins behavior.
					if mergedGear then
						result.gearVariant = mergedGear
						result.gearVariant.inventoryRoutePair = mutation.gearVariant and mutation.gearVariant.inventorySearch == true
							or mutation.gearVariant and (mutation.gearVariant.syntheticSearch == true or mutation.gearVariant.catalystSearch == true)
							or route.gearVariant and (route.gearVariant.inventorySearch == true or route.gearVariant.syntheticSearch == true
								or route.gearVariant.catalystSearch == true) or result.gearVariant.inventoryRoutePair == true
					end
					if mutation.jewelVariants then
						result.jewelVariants = { }
						for _, variant in ipairs(mutation.jewelVariants) do
							result.jewelVariants[#result.jewelVariants + 1] = shallowCopy(variant)
						end
					end
					if mutation.jewelCombination then result.jewelCombination = mutation.jewelCombination end
					if mutation.anointVariants then
						result.anointVariants = { }
						for _, variant in ipairs(mutation.anointVariants) do
							result.anointVariants[#result.anointVariants + 1] = shallowCopy(variant)
						end
					end
					combined[#combined + 1] = result
					if #combined >= limit then return combined end
					end
				end
			end
		end
	end
	return combined
end

local function combineTreeAndAscendancyCandidates(treeRoutes, ascendancyRoutes, limit)
	local combined = { }
	if limit <= 0 or #treeRoutes == 0 or #ascendancyRoutes == 0 then return combined end
	for index = 1, limit do
		local treeRoute = treeRoutes[((index - 1) % #treeRoutes) + 1]
		local ascendancyRoute = ascendancyRoutes[(math.floor((index - 1) / #treeRoutes) % #ascendancyRoutes) + 1]
		local nodeIds, seen = { }, { }
		for _, nodeId in ipairs(ascendancyRoute.nodeIds or { }) do
			if not seen[nodeId] then seen[nodeId] = true; nodeIds[#nodeIds + 1] = nodeId end
		end
		for _, nodeId in ipairs(treeRoute.nodeIds or { }) do
			if not seen[nodeId] then seen[nodeId] = true; nodeIds[#nodeIds + 1] = nodeId end
		end
		local result = {
			nodeIds = nodeIds,
			removeNodeIds = { unpack(treeRoute.removeNodeIds or { }) },
			ascendancyVariant = shallowCopy(ascendancyRoute.ascendancyVariant),
			ascendancyPointCost = ascendancyRoute.ascendancyPointCost,
			mainAscendancyPointCost = ascendancyRoute.mainAscendancyPointCost,
			secondaryAscendancyPointCost = ascendancyRoute.secondaryAscendancyPointCost,
			label = tostring(ascendancyRoute.label or "Ascendancy route") .. " + " .. tostring(treeRoute.label or "Passive route"),
			island = treeRoute.island,
			combinedTreeAscendancy = true,
			progressiveRouteBundle = treeRoute.progressiveRouteBundle == true,
			routeCount = treeRoute.routeCount,
			cycleFilteredRouteCount = treeRoute.cycleFilteredRouteCount,
			targetIds = treeRoute.targetIds and { unpack(treeRoute.targetIds) } or nil,
			targetRegions = treeRoute.targetRegions and { unpack(treeRoute.targetRegions) } or nil,
			hierarchicalExperts = treeRoute.hierarchicalExperts and { unpack(treeRoute.hierarchicalExperts) } or nil,
			hierarchicalCombination = treeRoute.hierarchicalCombination,
			hierarchicalCombinationKind = treeRoute.hierarchicalCombinationKind,
		}
		copyArchivedRouteProvenance(result, { treeRoute })
		combined[#combined + 1] = result
	end
	return combined
end

local function prioritizeLockedProgressiveCandidate(candidates, ascendancyId, requiredNodeIds, evaluationBudget, baselineReserved)
	if (tonumber(evaluationBudget) or 0) < 2 then return nil, "exact_budget_too_small" end
	local targetPosition = baselineReserved and 2 or 1
	for index, candidate in ipairs(candidates or { }) do
		if matchesLockedProgressiveCandidate(candidate, ascendancyId, requiredNodeIds) then
			targetPosition = math.min(targetPosition, #candidates)
			if index ~= targetPosition then
				table.remove(candidates, index)
				table.insert(candidates, targetPosition, candidate)
			end
			return targetPosition, "reserved"
		end
	end
	return nil, "no_retained_candidate"
end

local function prioritizeProgressiveTreeCandidate(candidates, evaluationBudget, baselineReserved)
	if (tonumber(evaluationBudget) or 0) < 2 then return nil, "exact_budget_too_small" end
	local targetPosition = baselineReserved and 2 or 1
	for index, candidate in ipairs(candidates or { }) do
		-- A route without an explicit ascendancy variant inherits the active PoB
		-- tree and its selected ascendancy. Do not reserve an unrelated ascendancy
		-- experiment for the ordinary current-build Route Planner.
		if candidate.progressiveRouteBundle == true and not candidate.ascendancyVariant
			and #(candidate.nodeIds or { }) > 0 then
			targetPosition = math.min(targetPosition, #candidates)
			if index ~= targetPosition then
				table.remove(candidates, index)
				table.insert(candidates, targetPosition, candidate)
			end
			return targetPosition, "reserved"
		end
	end
	return nil, "no_retained_candidate"
end

local function interleavePlannerCandidateFamilies(candidates, phaseCoverage, evaluationBudget, progressiveCandidate)
	local exactBudget = math.max(0, math.floor(tonumber(evaluationBudget) or 0))
	local retentionSlack = math.max(64, math.floor(exactBudget * 0.25))
	local exactQueueLimit = exactBudget + retentionSlack
	local reservedCandidates = { }
	local reservedLookup = { }
	local progressivePosition = phaseCoverage.progressiveTreeReservationPosition
	if phaseCoverage.progressiveTreeReservationStatus == "reserved" then
		if not progressiveCandidate and type(progressivePosition) == "number" then
			local indexedCandidate = candidates[progressivePosition]
			if indexedCandidate and indexedCandidate.progressiveRouteBundle == true
				and #(indexedCandidate.nodeIds or { }) > 0 then
				progressiveCandidate = indexedCandidate
			end
		end
		local retainedProgressiveCandidate
		if progressiveCandidate and progressiveCandidate.progressiveRouteBundle == true
			and #(progressiveCandidate.nodeIds or { }) > 0 then
			for _, candidate in ipairs(candidates or { }) do
				if candidate == progressiveCandidate then retainedProgressiveCandidate = candidate; break end
			end
		end
		if retainedProgressiveCandidate and (tonumber(evaluationBudget) or 0) >= 2 then
			reservedCandidates[#reservedCandidates + 1] = retainedProgressiveCandidate
			reservedLookup[retainedProgressiveCandidate] = true
			phaseCoverage.progressiveTreeReservationStatus = "reserved"
		else
			phaseCoverage.progressiveTreeReservationPosition = nil
			phaseCoverage.progressiveTreeReservationStatus = retainedProgressiveCandidate
				and "exact_budget_too_small" or "no_retained_candidate"
		end
	end
	local socketRepairCoverage = phaseCoverage.socketRepair
	if type(socketRepairCoverage) == "table" and #(socketRepairCoverage.slots or { }) > 0
		and exactBudget >= 2 then
		for _, candidate in ipairs(candidates or { }) do
			if candidate and not candidate.isBaselineCandidate and candidate.socketRepairsComplete == true
				and not reservedLookup[candidate] then
				reservedCandidates[#reservedCandidates + 1] = candidate
				reservedLookup[candidate] = true
				socketRepairCoverage.reservedExactEvaluations = 1
				socketRepairCoverage.reservedCandidateFamily = CandidateIdentity.Family(candidate)
				break
			end
		end
		if socketRepairCoverage.reservedExactEvaluations == nil then
			socketRepairCoverage.reservedExactEvaluations = 0
			socketRepairCoverage.reservationStatus = "no_complete_repair_candidate_retained"
		else
			socketRepairCoverage.reservationStatus = "reserved_after_baseline"
		end
	end
	local archiveCoverage = phaseCoverage.archivedRoutePatterns or { }
	local archiveDirect, archiveComposed = { }, { }
	local alreadyReservedDirect, alreadyReservedComposed = 0, 0
	for _, candidate in ipairs(candidates or { }) do
		if candidate and candidate.archivedRoutePattern == true then
			local isComposed = candidate.archivedRouteComposition == true
			if reservedLookup[candidate] then
				if isComposed then alreadyReservedComposed = alreadyReservedComposed + 1
				else alreadyReservedDirect = alreadyReservedDirect + 1 end
			elseif isComposed then
				archiveComposed[#archiveComposed + 1] = candidate
			else
				archiveDirect[#archiveDirect + 1] = candidate
			end
		end
	end
	local archiveReserve = math.max(0, math.floor((tonumber(evaluationBudget) or 0)
		* ARCHIVED_ROUTE_EXACT_BUDGET_SHARE))
	local alreadyReservedArchive = alreadyReservedDirect + alreadyReservedComposed
	local remainingArchiveReserve = math.max(0, archiveReserve - alreadyReservedArchive)
	local directTarget = math.floor(archiveReserve * 0.40)
	local directCount = math.min(#archiveDirect, math.max(0, directTarget - alreadyReservedDirect), remainingArchiveReserve)
	local composedCount = math.min(#archiveComposed, math.max(0, remainingArchiveReserve - directCount))
	local unfilled = math.max(0, remainingArchiveReserve - directCount - composedCount)
	directCount = directCount + math.min(unfilled, math.max(0, #archiveDirect - directCount))
	unfilled = math.max(0, remainingArchiveReserve - directCount - composedCount)
	composedCount = composedCount + math.min(unfilled, math.max(0, #archiveComposed - composedCount))
	for index = 1, directCount do
		local candidate = archiveDirect[index]
		if candidate and not reservedLookup[candidate] then
			reservedCandidates[#reservedCandidates + 1] = candidate
			reservedLookup[candidate] = true
		end
	end
	for index = 1, composedCount do
		local candidate = archiveComposed[index]
		if candidate and not reservedLookup[candidate] then
			reservedCandidates[#reservedCandidates + 1] = candidate
			reservedLookup[candidate] = true
		end
	end
	local reservedDirectCount, reservedComposedCount = 0, 0
	for _, candidate in ipairs(reservedCandidates) do
		if candidate.archivedRoutePattern == true then
			if candidate.archivedRouteComposition == true then reservedComposedCount = reservedComposedCount + 1
			else reservedDirectCount = reservedDirectCount + 1 end
		end
	end
	archiveCoverage.reservedExactEvaluationQuota = archiveReserve
	archiveCoverage.reservedDirectCandidates = reservedDirectCount
	archiveCoverage.reservedComposedCandidates = reservedComposedCount
	archiveCoverage.reservationShare = ARCHIVED_ROUTE_EXACT_BUDGET_SHARE
	phaseCoverage.archivedRoutePatterns = archiveCoverage
	archiveCoverage.reservedExactEvaluations = reservedDirectCount + reservedComposedCount
	local interleaved, plan = CandidateIdentity.InterleaveFamilies(candidates, {
		familyOrder = { "equipment", "skills", "combined", "tree", "configuration", "other" },
		reservedCandidates = reservedCandidates,
		budget = evaluationBudget,
		retentionLimit = exactQueueLimit,
	})
	phaseCoverage.exactQueueInputCandidates = phaseCoverage.exactQueueInputCandidates or plan.candidateCount
	phaseCoverage.exactQueueRetainedCandidates = plan.retainedCandidateCount
	phaseCoverage.exactQueueLimit = plan.exactQueueLimit
	phaseCoverage.exactQueueDiscardedCandidates = (phaseCoverage.exactQueueDiscardedCandidates or 0)
		+ plan.discardedBeyondRetentionLimit
	if phaseCoverage.progressiveTreeReservationStatus == "reserved" then
		phaseCoverage.progressiveTreeReservationPosition = 2
	end
	return interleaved, plan
end

local function recordExactEvaluationFamily(counts, family)
	if type(family) ~= "string" or family == "" then family = "other" end
	counts[family] = (counts[family] or 0) + 1
end

local function buildInterruptedSearchResult(state)
	local nearMisses = { }
	for _, entry in ipairs(state.exactNearMisses or { }) do
		if entry and entry.summary then nearMisses[#nearMisses + 1] = entry.summary end
	end
	local timedOut = state.reason == "timeout"
	local interruptedMessage = timedOut and "Search time limit reached after " or "Search cancelled after "
		interruptedMessage = interruptedMessage .. tostring(state.evaluations or 0) .. " exact PoB evaluations"
	local resultBase = {
		evaluations = state.evaluations or 0,
		generationPhase = state.generationPhase,
		searchBaseline = state.searchBaseline,
		nearMisses = nearMisses,
		objectiveMetric = state.objectiveMetric,
		ranking = state.ranking,
		searchCoverage = state.searchCoverage,
		scenarioProfile = state.scenarioProfile,
		scenario = state.scenario,
		version = state.version,
		sourceSignature = state.sourceSignature,
		searchInterrupted = true,
		searchTimedOut = timedOut,
		terminationReason = timedOut and "timeout" or "user_cancelled",
		message = interruptedMessage,
	}
	if state.feasibleBest then
		state.feasibleBest.sourceSignature = state.sourceSignature
		resultBase.status = "feasible"
		resultBase.candidate = state.feasibleBest
		resultBase.evaluation = state.feasibleBest.evaluation
		resultBase.paretoFront = state.paretoFront or { }
		return resultBase
	end
	local failureBest = state.exactFailureBest or state.failureBest
	local bestObservedIdentity
	if failureBest and failureBest.selectedBaseClassName then
		bestObservedIdentity = {
			candidateLabel = tostring(failureBest.candidateLabel or "Best observed exact candidate"):sub(1, 160),
			baseClass = tostring(failureBest.selectedBaseClassName):sub(1, 80),
			ascendancy = tostring(failureBest.selectedAscendancyName or "None"):sub(1, 80),
			secondaryAscendancy = tostring(failureBest.selectedSecondaryAscendancyName or "None"):sub(1, 80),
			passivePointsUsed = isFinite(failureBest.passivePointsUsed) and failureBest.passivePointsUsed or nil,
			ascendancyPointsUsed = isFinite(failureBest.ascendancyPointsUsed) and failureBest.ascendancyPointsUsed or nil,
			secondaryAscendancyPointsUsed = isFinite(failureBest.secondaryAscendancyPointsUsed) and failureBest.secondaryAscendancyPointsUsed or nil,
			characterLevel = isFinite(failureBest.characterLevel) and failureBest.characterLevel or nil,
			ascendancyPointBudget = isFinite(failureBest.ascendancyPointBudget) and failureBest.ascendancyPointBudget or nil,
		}
	end
	resultBase.status = (state.evaluations or 0) > 0 and "no_feasible_candidate"
		or (timedOut and "timed_out" or "cancelled")
	resultBase.candidate = nil
	resultBase.bestObservedMetrics = failureBest and failureBest.metrics or { }
	resultBase.bestObservedViolations = failureBest and failureBest.violations or { }
	resultBase.bestObservedDeficit = failureBest and failureBest.normalizedDeficit
	resultBase.bestObservedIdentity = bestObservedIdentity
	resultBase.failureEvidence = state.exactFailureBest and "exact_calculation" or "structural_validation"
	return resultBase
end

local function captureActivitySustain(output, parsed)
	local schedule = parsed.search and parsed.search.activitySchedule
	if not schedule then
		return activity.Evaluate(
			parsed,
			output and output.OptimizerMainSkillActivity,
			output and output.FullDPSActivity,
			output and output.FullDPSActivityTruncated
		)
	end
	local result, err = activity.EvaluateOptimizerSchedule(schedule, output, parsed)
	if result then return result end
	local reason = tostring(err or "PoB could not evaluate the configured candidate activity schedule")
	return {
		status = "unsupported",
		feasible = false,
		normalizedDeficit = math.huge,
		metrics = { },
		activities = { },
		violations = { {
			key = "activity_sustain_unsupported",
			label = "Optimizer activity schedule",
			reason = reason,
			deficit = math.huge,
		} },
		scope = schedule.scope,
		optimizerScheduleApplied = true,
		scheduleEstimate = true,
		damageScheduleCertified = false,
	}
end

local function captureEvaluation(output, env, parsed, candidateItemsTab)
	local routePlannerSingleSkill = parsed.search and parsed.search.routePlannerRunSpec
		and parsed.search.routePlannerRunSpec.searchMode == "SINGLE_SKILL_ONLY"
		and parsed.objective == "CombinedDPS"
	local metrics = candidateModule.CopyMetrics(output, inputsModule.metricDefinitions,
		env and env.player and env.player.mainSkill)
	local rankingOrder = Ranking.OrderingMetrics(parsed.objective, parsed.preferences)
	local activitySustain = captureActivitySustain(output, parsed)
	for key, value in pairs(activitySustain.metrics or { }) do metrics[key] = value end
	local gate = validator.Check(parsed, metrics)
	local defenseRankingMetric
	if parsed.preferences and parsed.preferences.rankingPriority == "DefenseFirst" then
		defenseRankingMetric = Ranking.DefenseMetricKey(parsed.preferences.defenseProfile)
		if not isFinite(metrics[defenseRankingMetric]) then
			gate.feasible = false
			gate.normalizedDeficit = math.huge
			gate.violations[#gate.violations + 1] = {
				key = "ranking_metric",
				label = "Candidate ranking metric",
				reason = "Exact PoB calculation did not provide a finite " .. defenseRankingMetric .. " value required by Defense first ranking",
				deficit = math.huge,
			}
		end
	end
	local marketBudget = MarketBudget.Evaluate(parsed.search.currencyBudget,
		Equipment.GetBudgetItemIds(candidateItemsTab or (env and env.build and env.build.itemsTab)))
	if parsed.search.currencyBudget and candidateItemsTab then
		local pricedBudget = shallowCopy(parsed.search.currencyBudget)
		pricedBudget.quotes = shallowCopy(parsed.search.currencyBudget.quotes)
		for _, entry in ipairs(Equipment.GetBudgetItemIds(candidateItemsTab)) do
			local item = candidateItemsTab.items and candidateItemsTab.items[entry.itemId]
			if item and item.optimizerSynthetic then
				if parsed.search.syntheticItemCostChaos ~= nil then
					pricedBudget.quotes[entry.itemId] = { chaosValue = parsed.search.syntheticItemCostChaos, source = "user_synthetic_cost" }
				end
			elseif item and item.optimizerCatalyst then
				local sourceId = tonumber(item.optimizerCatalystSourceItemId)
				local sourceQuote = sourceId and pricedBudget.quotes[sourceId]
				local catalystCost = parsed.search.catalystCostChaos
				if sourceQuote and isFinite(sourceQuote.chaosValue) and catalystCost ~= nil then
					pricedBudget.quotes[entry.itemId] = {
						chaosValue = sourceQuote.chaosValue + catalystCost,
						source = "user_item_quote_plus_catalyst_cost",
					}
				end
			end
		end
		marketBudget = MarketBudget.Evaluate(pricedBudget, Equipment.GetBudgetItemIds(candidateItemsTab))
	end
	if marketBudget.enabled then
		metrics.CurrencyBudgetTotal = marketBudget.total
		metrics.CurrencyBudgetLimit = marketBudget.limit
		for _, violation in ipairs(marketBudget.violations or { }) do
			gate.violations[#gate.violations + 1] = violation
		end
		if not marketBudget.feasible then
			gate.feasible = false
			gate.normalizedDeficit = gate.normalizedDeficit + (marketBudget.normalizedDeficit or math.huge)
		end
	end
	for _, violation in ipairs(activitySustain.violations or { }) do
		gate.violations[#gate.violations + 1] = violation
	end
	if not activitySustain.feasible then
		gate.feasible = false
		gate.normalizedDeficit = gate.normalizedDeficit + (activitySustain.normalizedDeficit or math.huge)
	end
	local manualActionAudit = skillActions.Evaluate(
		env and env.player and env.player.activeSkillList,
		parsed.search.maxManualButtons,
		parsed.search.maxManualDamageButtons
	)
	for _, violation in ipairs(manualActionAudit.violations or { }) do
		gate.violations[#gate.violations + 1] = violation
	end
	if not manualActionAudit.feasible then
		gate.feasible = false
		local deficit = manualActionAudit.status == "unsupported" and math.huge or (manualActionAudit.normalizedDeficit or 0)
		gate.normalizedDeficit = gate.normalizedDeficit + deficit
	end
	local activeSkill = env and env.player and env.player.mainSkill
	local activeEffect = activeSkill and (activeSkill.activeEffect or (activeSkill.effectList and activeSkill.effectList[1]))
	local mainSkillName = activeEffect and activeEffect.grantedEffect and activeEffect.grantedEffect.name
	local mainSkillViolations = calcsModule.checkSkillPayability(output, output, activeSkill)
	local payability = {
		status = #mainSkillViolations == 0 and "pass" or "violated",
		feasible = #mainSkillViolations == 0,
		violations = mainSkillViolations,
	}
	local fullDPSPayability
	local enabledSkillsPayability
	if routePlannerSingleSkill then
		-- Single Skill's objective is the exact selected-skill CombinedDPS. Other
		-- enabled FullDPS groups are outside that objective and stay unchanged.
		fullDPSPayability = { status = "not_required", feasible = true, violations = { } }
		enabledSkillsPayability = { status = "not_required", feasible = true, violations = { } }
	else
		local fullDPSWarnings = output and output.FullDPSPayabilityWarnings
		fullDPSPayability = {
			status = type(fullDPSWarnings) == "table" and (#fullDPSWarnings == 0 and "pass" or "violated") or "unsupported",
			feasible = type(fullDPSWarnings) == "table" and #fullDPSWarnings == 0,
			violations = type(fullDPSWarnings) == "table" and fullDPSWarnings or { {
				key = "full_dps_payability",
				label = "FullDPS skill costs",
				reason = "PoB did not provide per-skill cost checks for the enabled FullDPS groups",
			} },
		}
		enabledSkillsPayability = SkillCostAudit.CheckUpfrontPayability(output and output.OptimizerSkillCostAudit)
	end
	local payabilitySeen = { }
	local payabilityViolationCount = 0
	local function addPayabilityViolation(violation, key)
		local identity = table.concat({ tostring(violation.skill or mainSkillName or ""), tostring(violation.resource or ""), tostring(violation.required or ""), tostring(violation.actual or "") }, "\31")
		if payabilitySeen[identity] then return end
		payabilitySeen[identity] = true
		local copy = shallowCopy(violation)
		if key then copy.key = key end
		gate.violations[#gate.violations + 1] = copy
		payabilityViolationCount = payabilityViolationCount + 1
	end
	for _, violation in ipairs(mainSkillViolations) do addPayabilityViolation(violation) end
	for _, violation in ipairs(fullDPSPayability.violations) do addPayabilityViolation(violation, "full_dps_skill_payability") end
	for _, violation in ipairs(enabledSkillsPayability.violations or { }) do
		addPayabilityViolation(violation, violation.key or "enabled_skill_payability")
	end
	if not payability.feasible or not fullDPSPayability.feasible or not enabledSkillsPayability.feasible then
		gate.feasible = false
		local payabilityDeficit = (payability.status == "unsupported" or fullDPSPayability.status == "unsupported"
			or enabledSkillsPayability.status == "unsupported") and math.huge or math.max(1, payabilityViolationCount)
		gate.normalizedDeficit = gate.normalizedDeficit + payabilityDeficit
	end
	local skillEntityLimits, skillEntityLimitsTruncated = candidateModule.CopySkillEntityLimits(output)
	local entityGate = validator.CheckSkillEntityLimits(skillEntityLimits, skillEntityLimitsTruncated)
	for _, violation in ipairs(entityGate.violations) do
		gate.violations[#gate.violations + 1] = violation
	end
	if not entityGate.feasible then
		gate.feasible = false
		gate.normalizedDeficit = gate.normalizedDeficit + entityGate.normalizedDeficit
	end
	local objectiveValue = metrics[parsed.objective]
	local requirementGate = validator.CheckRequirements(output, env and env.build and env.build.characterLevel)
	for _, violation in ipairs(requirementGate.violations) do gate.violations[#gate.violations + 1] = violation end
	if not requirementGate.feasible then
		gate.feasible = false
		gate.normalizedDeficit = gate.normalizedDeficit + requirementGate.normalizedDeficit
	end
	if type(objectiveValue) ~= "number" or objectiveValue ~= objectiveValue or objectiveValue == math.huge or objectiveValue == -math.huge then
		gate.feasible = false
		gate.normalizedDeficit = math.huge
		gate.violations[#gate.violations + 1] = {
			key = "objective_metric",
			label = "Optimization objective",
			reason = "Exact PoB calculation did not provide a finite value for " .. tostring(parsed.objective),
			deficit = math.huge,
		}
	end
	local conversionResult = conversion.Evaluate(activeSkill, parsed.conversion.route, parsed.conversion.minPercent)
	if not conversionResult.satisfied then
		for _, message in ipairs(conversionResult.shortfall or { "Conversion route is unsupported" }) do
			gate.violations[#gate.violations + 1] = { key = "conversion_route", label = "Conversion route", reason = message, deficit = 1 }
		end
		gate.feasible = false
		gate.normalizedDeficit = gate.normalizedDeficit + (#conversionResult.shortfall > 0 and #conversionResult.shortfall or 1)
	end
	local triggerRate = parsed.hard.SkillTriggerRate and parsed.hard.SkillTriggerRate.value or nil
	local breakpointResult = breakpoints.Evaluate(activeSkill, output or { }, triggerRate)
	if breakpointResult.status == "unsupported" or breakpointResult.status == "violated" then
		for _, message in ipairs(breakpointResult.violations) do
			gate.violations[#gate.violations + 1] = { key = "trigger_breakpoint", label = "Trigger breakpoint", reason = message, deficit = 1 }
		end
		gate.feasible = false
		gate.normalizedDeficit = gate.normalizedDeficit + math.max(1, #breakpointResult.violations)
	end
	local availabilityResult = skillAvailability.Evaluate(
		parsed,
		env and env.player,
		output and output.FullDPSSkillAvailability,
		output
	)
	if availabilityResult.status == "unsupported" or availabilityResult.status == "violated" then
		gate.violations[#gate.violations + 1] = {
			key = "skill_availability",
			label = availabilityResult.status == "violated" and "Unsustainable Trauma stacks" or "Sustained DPS availability",
			reason = availabilityResult.reason,
			deficit = availabilityResult.status == "unsupported" and math.huge or availabilityResult.normalizedDeficit,
		}
		gate.feasible = false
		gate.normalizedDeficit = gate.normalizedDeficit + (availabilityResult.status == "unsupported" and math.huge or availabilityResult.normalizedDeficit)
	end
	local scenarioValid, scenarioError = scenario.CheckOutput(parsed.scenarioProfile, output)
	if not scenarioValid then
		gate.feasible = false
		gate.normalizedDeficit = math.huge
		gate.violations[#gate.violations + 1] = {
			key = "scenario_profile", label = "Exact scenario certification", reason = scenarioError, deficit = math.huge,
		}
	end
	return {
		metrics = metrics,
		skillEntityLimits = skillEntityLimits,
		mainSkillPayability = payability,
		fullDPSPayability = fullDPSPayability,
		enabledSkillsPayability = enabledSkillsPayability,
		activitySustain = activitySustain,
		marketBudget = marketBudget,
		manualActionAudit = manualActionAudit,
		objective = parsed.objective,
		ranking = {
			priority = parsed.preferences and parsed.preferences.rankingPriority or "ObjectiveFirst",
			primaryMetric = rankingOrder[1],
			secondaryMetric = rankingOrder[2],
			tertiaryMetric = rankingOrder[3],
		},
		violations = gate.violations,
		feasible = gate.feasible,
		normalizedDeficit = gate.normalizedDeficit,
		conversion = conversionResult,
		breakpoints = breakpointResult,
		skillAvailability = availabilityResult,
		requirements = requirementGate,
		scenarioProfile = parsed.scenarioProfile or "Current",
	}
end

local function verifySelectedMainSkill(env, targetSkill)
	if not targetSkill or not targetSkill.gemVariant then return true end
	local mainSkill = env and env.player and env.player.mainSkill
	local activeEffect = mainSkill and (mainSkill.activeEffect or (mainSkill.effectList and mainSkill.effectList[1]))
	local expectedGem = targetSkill.currentGemInstance
	if not activeEffect or activeEffect.srcInstance ~= expectedGem then
		return false, "PoB exact calculation did not resolve the selected Main Skill gem instance"
	end
	local actualEffectId = activeEffect.grantedEffect and activeEffect.grantedEffect.id
	if actualEffectId ~= targetSkill.gemVariant.skillId then
		return false, "PoB exact calculation resolved a different active effect than the selected Main Skill gem"
	end
	return true
end

local function objective(evaluation, objectiveKey)
	local metrics = evaluation.metrics
	return metrics[objectiveKey] or 0, metrics.CombinedDPS or 0, metrics.TotalEHP or 0
end

local function candidateHierarchicalExperts(candidate)
	local experts, seen = { }, { }
	local function add(expert)
		if type(expert) ~= "table" or type(expert.zone) ~= "string" then return end
		local key = table.concat({ tostring(expert.policyVersion or ""), tostring(expert.planId or ""), expert.zone }, "\31")
		if seen[key] then return end
		seen[key] = true
		experts[#experts + 1] = expert
	end
	add(candidate.hierarchicalExpert)
	for _, expert in ipairs(candidate.hierarchicalExperts or { }) do add(expert) end
	return experts
end

local function recordHierarchicalEvaluation(coverage, candidate, evaluation, objectiveKey)
	local experts = candidateHierarchicalExperts(candidate)
	if #experts == 0 then return end
	coverage.exactEvaluations = (coverage.exactEvaluations or 0) + 1
	local combined = candidate.hierarchicalCombination == true
	if combined then coverage.exactCombinedEvaluations = (coverage.exactCombinedEvaluations or 0) + 1 end
	local objectiveValue = evaluation.metrics and evaluation.metrics[objectiveKey]
	for _, expert in ipairs(experts) do
		local zone = coverage.zoneResults[expert.zone]
		if not zone then
			zone = { exactEvaluations = 0, exactCombinedEvaluations = 0, feasibleCandidates = 0 }
			coverage.zoneResults[expert.zone] = zone
		end
		zone.exactEvaluations = zone.exactEvaluations + 1
		if combined then zone.exactCombinedEvaluations = zone.exactCombinedEvaluations + 1 end
		if evaluation.feasible then zone.feasibleCandidates = zone.feasibleCandidates + 1 end
		if isFinite(objectiveValue) and (not isFinite(zone.bestObjectiveValue) or objectiveValue > zone.bestObjectiveValue) then
			zone.bestObjectiveValue = objectiveValue
		end
		if isFinite(evaluation.normalizedDeficit)
			and (not isFinite(zone.bestNormalizedDeficit) or evaluation.normalizedDeficit < zone.bestNormalizedDeficit) then
			zone.bestNormalizedDeficit = evaluation.normalizedDeficit
		end
	end
end

local function finalizeHierarchicalCoverage(coverage)
	if not isFinite(coverage.baselineObjectiveValue) then return end
	for _, zone in pairs(coverage.zoneResults or { }) do
		if isFinite(zone.bestObjectiveValue) then
			zone.bestObjectiveDeltaFromBaseline = zone.bestObjectiveValue - coverage.baselineObjectiveValue
		end
	end
end

local function addToParetoFront(front, candidate, objectiveKey, preferences)
	for index = #front, 1, -1 do
		if Ranking.Dominates(front[index], candidate, objectiveKey, preferences) then return end
		if Ranking.Dominates(candidate, front[index], objectiveKey, preferences) then table.remove(front, index) end
	end
	front[#front + 1] = candidate
end

local function selectBetterFailure(evaluation, current)
	if not current or validator.BetterDeficit(evaluation, current) then return evaluation end
	return current
end

local MAX_EXACT_NEAR_MISSES = 5
local nearMissMetricKeys = {
	"CombinedDPS", "FullDPS", "TotalEHP", "Life", "EnergyShield",
	"PhysicalHitAverage", "FireHitAverage", "ColdHitAverage", "LightningHitAverage", "ChaosHitAverage",
	"ImpaleDPS", "BleedDPS", "PoisonDPS",
	"PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken",
	"FireResist", "ColdResist", "LightningResist", "ChaosResist",
}

local function summarizeExactNearMiss(build, candidate, evaluation, objective)
	local metrics, changes, violations = { }, { }, { }
	local seenMetric = { }
	local function copyMetric(key)
		local value = evaluation.metrics and evaluation.metrics[key]
		if not seenMetric[key] and isFinite(value) then metrics[key] = value; seenMetric[key] = true end
	end
	copyMetric(objective)
	for _, key in ipairs(nearMissMetricKeys) do copyMetric(key) end
	local function addChange(value)
		if #changes < 10 and type(value) == "string" and value ~= "" then changes[#changes + 1] = value end
	end
	local gear = candidate.gearVariant
	if type(gear) == "table" then
		local itemsBySlot, changedSlots, seenSlots = { }, { }, { }
		for _, item in ipairs(gear.items or { }) do
			if type(item) == "table" and type(item.slot or item.slotName) == "string" then
				itemsBySlot[item.slot or item.slotName] = item
			end
		end
		for _, slot in ipairs(gear.changedSlots or { }) do
			if type(slot) == "string" and not seenSlots[slot] then
				seenSlots[slot] = true
				changedSlots[#changedSlots + 1] = slot
			end
		end
		if #changedSlots == 0 then
			for _, item in ipairs(gear.items or { }) do
				local slot = type(item) == "table" and (item.slot or item.slotName)
				if type(slot) == "string" and not seenSlots[slot] then
					seenSlots[slot] = true
					changedSlots[#changedSlots + 1] = slot
				end
			end
		end
		for _, slot in ipairs(changedSlots) do
			local selected
			selected = itemsBySlot[slot]
			local name = selected and (selected.name or selected.baseName or selected.fullName)
			if name then
				local syntheticSuffix = selected.synthetic == true
					and selected.affixCount and (" (rare teórico; " .. tostring(selected.affixCount) .. "/4 afixos)") or ""
				addChange(tostring(slot) .. " → " .. tostring(name) .. syntheticSuffix
					.. (selected.itemId and (" (item " .. tostring(selected.itemId) .. ")") or ""))
			else
				addChange(tostring(slot) .. " → altered equipment")
			end
		end
		for _, generated in ipairs(gear.generatedItems or { }) do
			local item = generated and generated.item
			local slot = tostring(generated and (generated.slotName or generated.slot) or "equipment")
			for _, modLine in ipairs(item and item.explicitModLines or { }) do
				if type(modLine) == "table" and type(modLine.line) == "string" then
					addChange(slot .. " affix → " .. modLine.line)
				end
			end
		end
	end
	local gemVariants = getCandidateGemVariants(candidate)
	for _, variant in ipairs(gemVariants) do
		local gemData = build.data and build.data.gems and build.data.gems[variant.gemId]
		local gemName = variant.name or (gemData and gemData.name) or variant.gemId or "gem variant"
		local group = build.skillsTab and build.skillsTab.socketGroupList
			and build.skillsTab.socketGroupList[variant.groupIndex]
		local groupName = group and group.slot or ("group " .. tostring(variant.groupIndex or "?"))
		if variant.kind == "support_remove" then
			addChange("Remover suporte desativado " .. tostring(gemName) .. " do grupo " .. tostring(groupName))
		else
			addChange("Gema " .. tostring(groupName) .. " slot " .. tostring(variant.gemIndex or "?")
				.. " → " .. tostring(gemName)
				.. (variant.level and (" L" .. tostring(variant.level)) or "")
				.. (variant.quality and (" Q" .. tostring(variant.quality)) or ""))
		end
	end
	local function appendNodes(nodeIds, prefix)
		local shown = 0
		for _, nodeId in ipairs(nodeIds or { }) do
			if shown >= 4 then break end
			local node = build.spec and build.spec.nodes and build.spec.nodes[nodeId]
			addChange(prefix .. " " .. tostring(node and (node.dn or node.name) or ("node " .. tostring(nodeId))))
			shown = shown + 1
		end
		if #(nodeIds or { }) > shown then addChange(prefix .. " +" .. tostring(#nodeIds - shown) .. " more passive(s)") end
	end
	appendNodes(candidate.nodeIds, "Add")
	appendNodes(candidate.removeNodeIds, "Remove")
	local jewelVariants = candidate.jewelVariants or (candidate.jewelVariant and { candidate.jewelVariant }) or { }
	for _, variant in ipairs(jewelVariants) do
		local item = build.itemsTab and build.itemsTab.items and build.itemsTab.items[variant.itemId]
		local itemName = item and (item.nameSpec or item.name) or ("item " .. tostring(variant.itemId or "?"))
		addChange("Jewel " .. tostring(itemName) .. " → socket " .. tostring(variant.toNodeId or "?"))
	end
	if candidate.configurationVariant then
		addChange("Configuration: " .. tostring(configurationChoices.Label(candidate.configurationVariant)))
	end
	if candidate.anointVariant or candidate.anointVariants then addChange("Anoint change") end
	if candidate.masteryVariant then addChange("Mastery change") end
	if candidate.tattooVariant then addChange("Tattoo change") end
	if candidate.timelessVariant then addChange("Timeless Jewel change") end
	for index, violation in ipairs(evaluation.violations or { }) do
		if index > 5 then break end
		violations[#violations + 1] = {
			key = tostring(violation.key or violation.label or "hard_gate"),
			label = tostring(violation.label or violation.key or "Hard requirement"),
			groupIndex = tonumber(violation.groupIndex),
			group = type(violation.group) == "string" and violation.group or nil,
			reason = tostring(violation.reason or "Exact hard gate not met"):sub(1, 180),
			actual = isFinite(violation.actual) and violation.actual or nil,
			required = isFinite(violation.required) and violation.required or nil,
			operator = type(violation.operator) == "string" and violation.operator or nil,
		}
	end
	return {
		exact = evaluation.exactCalculated == true,
		feasible = false,
		label = tostring(evaluation.candidateLabel or candidate.label or "Exact candidate"):sub(1, 160),
		archiveDerivedPassiveRoute = candidate.archivedRoutePattern == true,
		normalizedDeficit = isFinite(evaluation.normalizedDeficit) and evaluation.normalizedDeficit or nil,
		metrics = metrics,
		violations = violations,
		changes = changes,
	}
end

local function rememberExactNearMiss(nearMisses, build, candidate, evaluation, objective, preferences)
	if candidate.isBaselineCandidate or not candidateModule.HasMutation(candidate) then return end
	if evaluation.exactCalculated ~= true then return end
	for _, violation in ipairs(evaluation.violations or { }) do
		-- Native metrics may still be emitted for a tree whose exact point budget
		-- changed with a configuration choice. Such a tree is not a legal route to
		-- present as a near miss; keep the diagnostic in search coverage only.
		if violation.key == "passive_point_limit" or violation.key == "passive_point_cap" then return end
	end
	local entry = {
		candidate = candidate,
		evaluation = evaluation,
		summary = summarizeExactNearMiss(build, candidate, evaluation, objective),
		progressiveTree = candidate.progressiveRouteBundle == true,
		archiveDerivedPassiveRoute = candidate.archivedRoutePattern == true,
	}
	local insertAt = #nearMisses + 1
	for index, current in ipairs(nearMisses) do
		if validator.BetterDeficit(evaluation, current.evaluation)
			or (evaluation.normalizedDeficit == current.evaluation.normalizedDeficit
				and #evaluation.violations == #current.evaluation.violations
				and Ranking.IsBetter(candidate, current.candidate, objective, preferences)) then
			insertAt = index
			break
		end
	end
	table.insert(nearMisses, insertAt, entry)
	while #nearMisses > MAX_EXACT_NEAR_MISSES do
		local reserved = { }
		local progressiveReserved = false
		local archivedRoutesReserved = 0
		for _, current in ipairs(nearMisses) do
			if not progressiveReserved and current.progressiveTree then
				reserved[current] = true
				progressiveReserved = true
			end
			if archivedRoutesReserved < 2 and current.archiveDerivedPassiveRoute then
				reserved[current] = true
				archivedRoutesReserved = archivedRoutesReserved + 1
			end
		end
		local removeAt
		for index = #nearMisses, 1, -1 do
			if not reserved[nearMisses[index]] then removeAt = index; break end
		end
		table.remove(nearMisses, removeAt or #nearMisses)
	end
end

local function getPassivePointLimit(build, characterLevel, extraPoints)
	if build.GetPassivePointLimitForLevel then
		local pointLimit = build:GetPassivePointLimitForLevel(characterLevel, extraPoints or 0)
		if type(pointLimit) == "number" and pointLimit == pointLimit and pointLimit ~= math.huge then return pointLimit end
	end
	if build.GetEstimatedLevelForPoints then
		local _, _, pointLimit = build:GetEstimatedLevelForPoints(0, extraPoints or 0)
		if type(pointLimit) == "number" and pointLimit == pointLimit and pointLimit ~= math.huge then return pointLimit end
	end
	return 99 + 23 + (extraPoints or 0)
end

local function resolveSearchPointLimit(build, extraPoints)
	local characterLevel = build.characterLevelAutoMode == true and 100 or tonumber(build.characterLevel) or 1
	characterLevel = math.max(1, math.floor(characterLevel))
	return getPassivePointLimit(build, characterLevel, extraPoints), characterLevel
end

local function countAddedMainPoints(spec, nodeIds)
	local count = 0
	for _, nodeId in ipairs(nodeIds or { }) do
		local node = spec and spec.nodes and spec.nodes[nodeId]
		if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and not node.ascendancyName then
			count = count + 1
		end
	end
	return count
end

local function candidateBelongsToPhase(candidate, generationPhase)
	local hasTreeMutation = #(candidate.nodeIds or { }) > 0 or #(candidate.removeNodeIds or { }) > 0
		or candidate.classVariant or candidate.ascendancyVariant or candidate.jewelVariant
		or #(candidate.jewelVariants or { }) > 0 or candidate.masteryVariant or candidate.tattooVariant
		or candidate.timelessVariant
	local hasGearMutation = candidate.gearVariant or candidate.anointVariant or candidate.anointVariants
	local hasSkillMutation = candidate.gemVariant or #(candidate.gemVariants or { }) > 0
	local hasConfigurationMutation = candidate.configurationVariant
	local gemVariants = getCandidateGemVariants(candidate)
	local onlyGemVariant = #gemVariants == 1 and gemVariants[1] or nil
	local hasOnlySelectedMainSkillContext = type(onlyGemVariant) == "table"
		and onlyGemVariant.kind == "selected_main_skill"
	if generationPhase == "tree" then
		-- A user-selected Main Skill is part of the tree's calculation context,
		-- not a searched support/gem mutation. Carry that identity through Apply
		-- when it differs from the currently active PoB skill, while keeping the
		-- Skills phase boundary closed to all other gem changes.
		return not hasGearMutation and (not hasSkillMutation or hasOnlySelectedMainSkillContext)
			and not hasConfigurationMutation
	elseif generationPhase == "skills" then
		return not hasTreeMutation and not hasGearMutation and not hasConfigurationMutation
	elseif generationPhase == "equipment" then
		return not hasTreeMutation and not hasSkillMutation and not hasConfigurationMutation
	end
	return generationPhase == "combined"
end

local function updateRoutePlannerProgress(job, build, parsed, candidate, evaluationCount,
	candidateCount, phaseCoverage, searchBaseline, paretoFront, candidateIndex)
	local bestRoute = job.routePlannerBestCandidate
	local feasibleMutation = candidate.evaluation and candidate.evaluation.feasible == true
		and candidateModule.HasMutation(candidate)
		and not Equipment.HasFlaskMutation(build, candidate)
	if feasibleMutation then
		job.routePlannerExactFeasibleMutations = (tonumber(job.routePlannerExactFeasibleMutations) or 0) + 1
		if Ranking.IsBetter(candidate, bestRoute, parsed.objective, parsed.preferences) then
			bestRoute = candidate
			job.routePlannerBestCandidate = candidate
		end
	end
	local progress = {
		phase = "Exact calculations",
		processed = evaluationCount,
		total = math.min(candidateCount, parsed.search.evaluationBudget),
		current = candidate.label,
		candidatesExamined = candidateIndex or phaseCoverage.candidateAttempts or 0,
		candidateAttemptTotal = candidateCount,
		exactEvaluations = evaluationCount,
		exactEvaluationBudget = parsed.search.evaluationBudget,
		generatedProposals = phaseCoverage.generatedCandidates or 0,
		uniqueProposals = phaseCoverage.uniqueCandidates or 0,
		retainedProposals = phaseCoverage.retainedCandidates or 0,
		archiveRoutesGenerated = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.generatedCandidates) or 0,
		archiveCompatibleLineages = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.compatibleBuildCount) or 0,
		archivePatternsAvailable = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.availablePatterns) or 0,
		archiveCompositionsGenerated = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.generatedComposedCandidates) or 0,
		archiveRoutesRetained = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.retainedDirectCandidates) or 0,
		archiveCompositionsRetained = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.retainedComposedCandidates) or 0,
		archiveDirectExact = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.exactDirectEvaluations) or 0,
		archiveDirectFeasible = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.exactDirectFeasible) or 0,
		archiveCompositionsExact = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.exactComposedEvaluations) or 0,
		archiveCompositionsFeasible = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.exactComposedFeasible) or 0,
		archiveGateRepairsGenerated = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.adaptiveGateRepairGenerated) or 0,
		archiveGateRepairsExact = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.adaptiveGateRepairExactEvaluations) or 0,
		archiveGateRepairsFeasible = tonumber(phaseCoverage.archivedRoutePatterns
			and phaseCoverage.archivedRoutePatterns.adaptiveGateRepairFeasible) or 0,
	}
	local paretoRouteCount = 0
	for _, route in ipairs(paretoFront) do
		if route.feasible == true and candidateModule.HasMutation(route)
			and not Equipment.HasFlaskMutation(build, route) then
			paretoRouteCount = paretoRouteCount + 1
		end
	end
	progress.paretoRoutes = paretoRouteCount
	progress.exactFeasibleMutations = tonumber(job.routePlannerExactFeasibleMutations) or 0
	if bestRoute and searchBaseline and searchBaseline.exact == true then
		local bestMetrics = bestRoute.evaluation and bestRoute.evaluation.metrics or { }
		local baselineMetrics = searchBaseline.metrics or { }
		local focusMetricKey = Ranking.DamageFocusMetricKey(parsed.preferences and parsed.preferences.damageFocus)
		local defenseMetricKey = Ranking.DefenseMetricKey(parsed.preferences and parsed.preferences.defenseProfile)
		progress.bestExactRoute = {
			label = tostring(bestRoute.label or bestRoute.evaluation.candidateLabel or "Rota aprovada"),
			objectiveKey = parsed.objective,
			objectiveValue = bestMetrics[parsed.objective],
			objectiveBaseline = baselineMetrics[parsed.objective],
			focusMetricKey = focusMetricKey,
			focusMetricValue = focusMetricKey and bestMetrics[focusMetricKey] or nil,
			focusMetricBaseline = focusMetricKey and baselineMetrics[focusMetricKey] or nil,
			defenseMetricKey = defenseMetricKey,
			defenseMetricValue = bestMetrics[defenseMetricKey],
			defenseMetricBaseline = baselineMetrics[defenseMetricKey],
			archiveDerivedPassiveRoute = bestRoute.archivedRoutePattern == true,
		}
	end
	RoutePlannerProgress.Merge(job, progress, phaseCoverage)
end

-- The native search orchestrator is close to LuaJIT's 60-upvalue limit. Keep
-- candidate-generation helpers behind one table upvalue so later validation
-- work does not make the whole PoB module unloadable.
local candidateRunHelpers = {
	countCandidateFlag = countCandidateFlag,
	candidateRepairsSocketPlan = SocketRepairComposer.CandidateRepairsSocketPlan,
	getCandidateGemVariants = getCandidateGemVariants,
	filterCandidatesToSingleSkill = filterCandidatesToSingleSkill,
	composeSocketRepairGearVariant = SocketRepairComposer.ComposeGearVariant,
	mergeCandidateGemVariants = mergeCandidateGemVariants,
	createGemVariants = createGemVariants,
	evaluateSupportSwap = evaluateSupportSwap,
	combineRoutesAndMutations = combineRoutesAndMutations,
	combineTreeAndAscendancyCandidates = combineTreeAndAscendancyCandidates,
}

local function run(build, parsed, control, job)
	-- Keep the loaded build's native output available for display-only deltas
	-- when an invalid socket/tree layout prevents an exact search-baseline
	-- candidate. This snapshot never participates in gates or ranking.
	do
		local runSpec = parsed.search and parsed.search.routePlannerRunSpec
		local output = build and build.calcsTab and build.calcsTab.mainOutput
		if runSpec and type(output) == "table" then
			local metrics = { }
			for _, key in ipairs({ "CombinedDPS", "FullDPS", "TotalDPS", "TotalEHP", "Life", "EnergyShield",
				"PhysicalMaximumHitTaken", "FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken",
				"FireResist", "ColdResist", "LightningResist", "ChaosResist", "Armour", "Evasion", "Ward",
				"BlockChance", "SpellBlockChance", "SpellSuppressionChance", "FireHitAverage", "ColdHitAverage",
				"LightningHitAverage", "PhysicalHitAverage", "ChaosHitAverage" }) do
				local value = tonumber(output[key])
				if isFinite(value) then metrics[key] = value end
			end
			if next(metrics) then
				local socketRepairRequired = type(runSpec.skill) == "table"
					and (type(runSpec.skill.socketRepair) == "table"
						or #(runSpec.skill.socketRepairs or { }) > 0)
				job.sourceBuildBaseline = {
					comparisonOnly = true,
					source = "native_loaded_build_output",
					label = "Loaded build — native PoB output (comparison only)",
					metrics = metrics,
					scenarioProfile = parsed.scenarioProfile or "Current",
					socketRepairRequired = socketRepairRequired,
				}
			end
		end
	end
	-- Keep the native proposal-building locals in a bounded scope. This function
	-- is intentionally the orchestration point for generation and exact review,
	-- but LuaJIT limits a function to 200 simultaneous locals. The proposal
	-- preparation block is large enough to exceed that limit before evaluation.
	local prepared = { }
	do
	local sourceBuild = build
	local sourceSignature = candidateModule.BuildSignature(sourceBuild)
	job.sourceSignature = sourceSignature
	local phase = {
		generation = parsed.search.generationPhase or "tree",
		nodePotentialAnalysis = parsed.search.nodePotentialAnalysis == true,
	}
	phase.tree = phase.generation == "tree"
	phase.skills = phase.generation == "skills"
	phase.equipment = phase.generation == "equipment"
	phase.combined = phase.generation == "combined"
	phase.lockedAscendancySearch = (phase.tree or phase.combined) and parsed.search.ascendancyId ~= nil
	-- The AI Route Planner has no control for changing class, main ascendancy,
	-- or Bloodline. Constrain only its ascendancy proposals to the loaded build;
	-- unlike the generic Matrix selector, this must not rebuild the current tree.
	phase.routePlannerAscendancyConstraint = (phase.tree or phase.combined)
		and parsed.search.routePlannerRunSpec ~= nil
	phase.routePlannerAscendancyId = phase.routePlannerAscendancyConstraint and (build.spec.curAscendClassId or 0) or nil
	phase.routePlannerSecondaryAscendancyId = phase.routePlannerAscendancyConstraint
		and (build.spec.curSecondaryAscendClassId or 0) or nil
	phase.searchTree = phase.tree or phase.combined
	phase.searchSkills = (phase.skills or phase.combined) and not phase.nodePotentialAnalysis
	phase.searchEquipment = (phase.equipment or phase.combined) and not phase.nodePotentialAnalysis
	local classVariant
	local selectedClassId = parsed.search.baseClassId
	if phase.tree and selectedClassId == nil then selectedClassId = build.spec.curClassId end
	if phase.lockedAscendancySearch and selectedClassId == nil then selectedClassId = build.spec.curClassId end
	if phase.tree or phase.lockedAscendancySearch or (selectedClassId ~= nil and selectedClassId ~= build.spec.curClassId) then
		local rootSpec, rootError = candidateModule.BuildPassiveSpec(build, { }, { }, {
			classId = selectedClassId,
			ascendClassId = phase.lockedAscendancySearch and parsed.search.ascendancyId or nil,
		})
		if not rootSpec then return { status = "invalid_inputs", message = rootError or "Could not create the selected class root" } end
		local classBuild = shallowCopy(build)
		classBuild.spec = rootSpec
		setmetatable(classBuild, { __index = build })
		build = classBuild
		classVariant = { classId = selectedClassId }
	end
	local treeValid, treeError = inputsModule.ValidateAgainstTree(parsed, build.spec.tree)
	if not treeValid then
		return { status = "invalid_inputs", message = treeError }
	end
	local buildInputsValid, buildInputsError = inputsModule.ValidateAgainstBuild(parsed, build.spec)
	if not buildInputsValid then return { status = "invalid_inputs", message = buildInputsError } end
	-- The active PoB output and modifier database are the source for current
	-- attributes, native Req* values, and whether attributes convert to Omni.
	-- Use them only to order potentially useful routes; every candidate is still
	-- recalculated and accepted/rejected by its own exact PoB output.
	treeSearch.ConfigureRequirementAttributeFocus(parsed,
		build.calcsTab and build.calcsTab.mainOutput,
		{ omniAttributeConversionActive = hasOmniscienceAttributeConversion(build) })
	local targetSkill
	if parsed.search.targetSkillGroupIndex then
		targetSkill = {
			groupIndex = parsed.search.targetSkillGroupIndex,
			skillIndex = parsed.search.targetSkillIndex,
			activeSkillIndex = parsed.search.targetSkillIndex,
		}
		if parsed.search.targetSkillGemId then
			local gemVariant, gemError, gemDetails = SkillCatalog.ResolveTarget(build,
				parsed.search.targetSkillGroupIndex, parsed.search.targetSkillIndex, parsed.search.targetSkillGemId,
				{ allowUnlinkedPlanning = phase.tree or phase.skills,
					allowSocketRepair = parsed.search.allowSocketRepair == true })
			if not gemVariant then return { status = "invalid_inputs", message = gemError } end
			local sourceGem = gemDetails and gemDetails.sourceGem
			targetSkill.gemVariant = gemVariant
			targetSkill.activeSkillIndex = gemDetails.activeSkillIndex
			targetSkill.unlinkedPlanning = gemDetails.unlinkedPlanning == true
			local routePlannerSkill = parsed.search.routePlannerRunSpec
				and parsed.search.routePlannerRunSpec.skill
			targetSkill.socketRepairs = routePlannerSkill and routePlannerSkill.socketRepairs
				or (gemDetails.socketRepair and { gemDetails.socketRepair } or { })
			targetSkill.socketRepair = gemDetails.socketRepair
				or (routePlannerSkill and routePlannerSkill.socketRepair)
			for _, repairPlan in ipairs(targetSkill.socketRepairs or { }) do
				for _, repairedGroupIndex in ipairs(repairPlan.groupIndices or { }) do
					if tonumber(repairedGroupIndex) == tonumber(targetSkill.groupIndex) then
						targetSkill.socketRepair = repairPlan
						break
					end
				end
			end
			targetSkill.changed = not gemDetails.sameGem
				or not sourceGem or tonumber(sourceGem.level) ~= gemVariant.level
				or tonumber(sourceGem.quality) ~= gemVariant.quality
				or parsed.search.targetSkillGroupIndex ~= build.mainSocketGroup
				or tonumber(gemDetails.group.mainActiveSkill) ~= parsed.search.targetSkillIndex
			targetSkill.label = gemVariant.nameSpec
		end
	end
	local requireSocketedMainSkill = targetSkill and (phase.equipment or phase.combined)
	local pointsUsed = build.spec:CountAllocNodes()
	local extraPoints = build.calcsTab.mainOutput and build.calcsTab.mainOutput.ExtraPoints or 0
	local totalPointLimit, pointLimitLevel = resolveSearchPointLimit(build, extraPoints)
	-- Generate up to the requested add budget even when the current tree is full;
	-- a paired removal may free points. The exact projected tree is checked later.
	local maxAddedPoints = parsed.search.maxAddedPoints
	local proposalBudget = parsed.search.proposalBudget or parsed.search.evaluationBudget
	local candidateBudget = math.max(proposalBudget, parsed.search.evaluationBudget) - 1
	local ascendancyQuota = phase.searchTree and not phase.nodePotentialAnalysis and math.min(candidateBudget, math.max(math.min(3, candidateBudget), math.floor(candidateBudget * 0.35))) or 0
	job.progress = { phase = "Preparing native ascendancy routes", processed = 0, total = 0 }
	local function ascendancyProgress(processed, total, current)
		job.progress = { phase = "Generating native ascendancy routes", processed = processed, total = total, current = current }
		coroutine.yield(job.progress)
	end
	local ascendancyCandidates, ascendancyCoverage = AscendancySearch.BuildCandidates(
		build, build.spec.curClassId, ascendancyQuota, control, ascendancyProgress,
		phase.lockedAscendancySearch and parsed.search.ascendancyId
			or phase.routePlannerAscendancyConstraint and phase.routePlannerAscendancyId or nil,
		phase.lockedAscendancySearch and parsed.search.requiredNodeIds or nil,
		phase.routePlannerAscendancyConstraint and phase.routePlannerSecondaryAscendancyId or nil
	)
	if phase.routePlannerAscendancyConstraint then
		ascendancyCoverage.routePlannerConstraint = {
			classId = build.spec.curClassId,
			mainAscendancyId = phase.routePlannerAscendancyId,
			secondaryAscendancyId = phase.routePlannerSecondaryAscendancyId,
		}
	end
	ascendancyCoverage.rejectedByProgressionBudget = 0
	-- For fixed-level builds, do not let impossible Labyrinth routes consume exact
	-- evaluation budget. Auto-level builds are checked after PoB estimates each
	-- candidate's level because their passive count can change that estimate.
	if not build.characterLevelAutoMode then
		local availableAscendancyPoints = inputsModule.AscendancyPointBudgetAtLevel(
			build.characterLevel or 1, parsed.search.ascendancyPointBudget)
		local legalRoutes = { }
		for _, candidate in ipairs(ascendancyCandidates) do
			if (candidate.mainAscendancyPointCost or 0) <= availableAscendancyPoints
				and (candidate.secondaryAscendancyPointCost or 0) <= availableAscendancyPoints then
				legalRoutes[#legalRoutes + 1] = candidate
			else
				ascendancyCoverage.rejectedByProgressionBudget = ascendancyCoverage.rejectedByProgressionBudget + 1
			end
		end
		ascendancyCandidates = legalRoutes
	end
	ascendancyCoverage.pointBudget = parsed.search.ascendancyPointBudget
	ascendancyCoverage.characterLevel = parsed.search.activeCharacterLevel or build.characterLevel or 1
	ascendancyCoverage.exactEvaluations = 0
	ascendancyCoverage.exactBloodlineEvaluations = 0
	ascendancyCoverage.exactCombinedEvaluations = 0
	ascendancyCoverage.lockedAscendancyId = phase.lockedAscendancySearch and parsed.search.ascendancyId or nil
	local treeQuota = phase.searchTree and (phase.nodePotentialAnalysis and candidateBudget
		or parsed.search.equalBudgetClassSearch == true and math.max(0, candidateBudget - ascendancyQuota)
		or math.floor(candidateBudget * 0.30)) or 0
	local anointQuota = phase.searchEquipment and math.floor(candidateBudget * 0.15) or 0
	local anointCandidates, availableAnointCandidates, anointInventoryCoverage = { }, 0, { generatedSingleCandidates = 0, generatedPairedCandidates = 0, availableSingleCandidates = 0, availablePairedCandidates = 0 }
	if phase.searchEquipment then
		anointCandidates, availableAnointCandidates, anointInventoryCoverage = treeSearch.BuildAnointCandidates(build.spec, anointQuota)
	end
	local candidateRegionMap, topologyCoverage, topologyError = treeSearch.BuildRegionMap(build.spec, parsed.branch.partition)
	if not candidateRegionMap then
		return { status = "invalid_inputs", candidate = nil, message = topologyError or "Passive-tree regions could not be resolved" }
	end
	local singleRouteQuota = phase.nodePotentialAnalysis and candidateBudget or math.floor(treeQuota * 0.62)
	local zoneCoverage = {
		mode = "not_applicable",
		exactEvaluations = 0,
		exactCombinedEvaluations = 0,
		objectiveMetric = parsed.objective,
		zoneResults = { },
	}
	local function routeProgress(done, total, expanded, targetId, zoneName, planId, operation)
		local location = targetId and ("node " .. tostring(targetId) .. "; " .. tostring(expanded or 0) .. " nodes expanded") or nil
		local scope = operation
		if zoneName then scope = tostring(planId or "plano") .. " / " .. tostring(zoneName)
		elseif not scope then scope = "rotas gerais" end
		location = scope .. (location and (" / " .. location) or "")
		local processed, boundedTotal = tonumber(done) or 0, tonumber(total) or 0
		job.progress = { phase = "Pathfinding", processed = processed, total = boundedTotal,
			counterValid = boundedTotal <= 0 or processed <= boundedTotal, current = location }
		coroutine.yield(job.progress)
	end
	local treeCandidates, treeError, pathCancelled
	local treeBudgetCoverage
	local hierarchicalCandidates, hierarchicalError, hierarchicalCancelled, hierarchicalCoverage, hierarchyHandled = { }, nil, false, nil, false
	if phase.searchTree and not phase.nodePotentialAnalysis then
		hierarchicalCandidates, hierarchicalError, hierarchicalCancelled, hierarchicalCoverage, hierarchyHandled =
			HierarchicalController.BuildSpatialCandidates(build.spec, parsed, singleRouteQuota, maxAddedPoints, candidateRegionMap, control, routeProgress)
	end
	if hierarchyHandled then
		treeCandidates = hierarchicalCandidates or { }
		treeError = hierarchicalError
		pathCancelled = hierarchicalCancelled
		zoneCoverage = hierarchicalCoverage or zoneCoverage
		zoneCoverage.exactEvaluations = zoneCoverage.exactEvaluations or 0
		zoneCoverage.exactCombinedEvaluations = zoneCoverage.exactCombinedEvaluations or 0
		zoneCoverage.objectiveMetric = parsed.objective
		zoneCoverage.zoneResults = zoneCoverage.zoneResults or { }
	else
		if phase.searchTree then
			local function baseRouteProgress(done, total, expanded, targetId)
				routeProgress(done, total, expanded, targetId, nil, nil, "rotas-base")
			end
			treeCandidates, treeError, pathCancelled = treeSearch.BuildCandidateNodes(build.spec, parsed, singleRouteQuota,
				baseRouteProgress, maxAddedPoints, control, candidateRegionMap)
		else
			treeCandidates = { }
		end
	end
	if pathCancelled then return { status = "cancelled", candidate = nil, evaluations = 0 } end
	if treeError then
		return { status = "no_feasible_candidate", message = treeError, candidate = nil }
	end
	-- Keep add-only routes inside PoB's native level/quest point ceiling by
	-- pairing them with connected, low-value leaf removals when the tree is full.
	if phase.nodePotentialAnalysis then
		-- The node-potential page is a read-only route review. Preserve routes that
		-- exceed the current level/quest ceiling so the native structural validator
		-- can report them as not evaluated with PoB's exact point-limit blocker.
		-- Ordinary optimization still pairs removals or drops routes before scoring.
		treeBudgetCoverage = {
			inputCandidates = #(treeCandidates or { }),
			outputCandidates = #(treeCandidates or { }),
			adjustedCandidates = 0,
			rejectedInsufficientRemovals = 0,
			requiredPointsFreed = 0,
			status = "node_potential_structural_review",
		}
	else
		treeCandidates, treeBudgetCoverage = treeSearch.BudgetCandidatesForPointLimit(
			build.spec, treeCandidates or { }, parsed, totalPointLimit, candidateRegionMap)
	end
	treeBudgetCoverage.pointLimit = totalPointLimit
	treeBudgetCoverage.pointLimitLevel = pointLimitLevel
	treeBudgetCoverage.levelAutoMode = build.characterLevelAutoMode == true
	treeBudgetCoverage.baselinePointCount = pointsUsed
	local archivedRouteCandidates = { }
	local archivedRouteCoverage = {
		compatibleBuildCount = tonumber(parsed.search.importedRouteCompatibleBuildCount) or 0,
		availablePatterns = tonumber(parsed.search.importedRoutePatternCount) or 0,
		reservedCandidateQuota = 0,
		consideredPatterns = 0,
		eligiblePatterns = 0,
		generatedCandidates = 0,
		generatedComposedCandidates = 0,
		retainedComposedCandidates = 0,
		exactEvaluations = 0,
		exactFeasible = 0,
		exactComposedEvaluations = 0,
		exactComposedFeasible = 0,
		exactDirectEvaluations = 0,
		exactDirectFeasible = 0,
		adaptiveGateRepairBudget = 0,
		adaptiveGateRepairGenerated = 0,
		adaptiveGateRepairRetained = 0,
		adaptiveGateRepairExactEvaluations = 0,
		adaptiveGateRepairFeasible = 0,
		adaptiveGateRepairStructuralRejections = 0,
		adaptiveGateRepairDuplicateCandidates = 0,
		adaptiveGateRepairProposalCapRejections = 0,
		adaptiveGateRepairSources = 0,
		adaptiveGateRepairActionableSources = 0,
		adaptiveGateRepairExactViolationRows = 0,
		adaptiveGateRepairNeedRows = 0,
		adaptiveGateRepairInventoryCandidates = 0,
		adaptiveGateRepairSyntheticCandidates = 0,
		adaptiveGateRepairInputSample = nil,
		adaptiveGateRepairExactPreview = { },
		adaptiveGateRepairRankedCandidates = 0,
		adaptiveGateRepairGeneratedBeforeDeduplication = 0,
		adaptiveGateRepairStatuses = { },
		adaptiveGateRepairCanonicalizationFallbacks = 0,
		adaptiveGateRepairCanonicalizationContextError = nil,
		structuralRejected = 0,
		structuralComposedRejected = 0,
		skippedNoLocalTargets = 0,
		skippedPointBudget = 0,
	}
	if phase.searchTree and parsed.search.routePlannerRunSpec
		and parsed.search.importedRouteMemoryEnabled == true
		and #(parsed.targetNodeIds or { }) == 0
		and type(parsed.search.importedRoutePatterns) == "table" then
		local patternCount = math.min(MAX_ARCHIVED_ROUTE_PATTERNS, #parsed.search.importedRoutePatterns)
		local archiveQuota = math.min(MAX_ARCHIVED_ROUTE_CANDIDATES, patternCount * 4,
			math.max(0, math.floor(parsed.search.evaluationBudget * ARCHIVED_ROUTE_EXACT_BUDGET_SHARE)))
		archivedRouteCoverage.reservedCandidateQuota = archiveQuota
		local currentLevelPointLimit = build.characterLevelAutoMode and getPassivePointLimit(build, 100, extraPoints)
			or getPassivePointLimit(build, build.characterLevel or 1, extraPoints)
		local archivePointLimit = math.min(tonumber(parsed.search.maxTotalPoints) or totalPointLimit,
			totalPointLimit, currentLevelPointLimit)
		local archiveError, archiveCancelled
		archivedRouteCandidates, archivedRouteCoverage, archiveError, archiveCancelled =
			treeSearch.BuildArchivedRouteCandidates(build.spec, parsed, parsed.search.importedRoutePatterns,
				archiveQuota, maxAddedPoints, control, routeProgress, candidateRegionMap, archivePointLimit)
		archivedRouteCoverage.compatibleBuildCount = tonumber(parsed.search.importedRouteCompatibleBuildCount) or 0
		archivedRouteCoverage.adaptiveGateRepairBudget = 0
		archivedRouteCoverage.adaptiveGateRepairGenerated = 0
		archivedRouteCoverage.adaptiveGateRepairRetained = 0
		archivedRouteCoverage.adaptiveGateRepairExactEvaluations = 0
		archivedRouteCoverage.adaptiveGateRepairFeasible = 0
		archivedRouteCoverage.adaptiveGateRepairStructuralRejections = 0
		archivedRouteCoverage.adaptiveGateRepairStructuralRejectionReasons = { }
		archivedRouteCoverage.adaptiveGateRepairDuplicateCandidates = 0
		archivedRouteCoverage.adaptiveGateRepairProposalCapRejections = 0
		archivedRouteCoverage.adaptiveGateRepairSources = 0
		archivedRouteCoverage.adaptiveGateRepairActionableSources = 0
		archivedRouteCoverage.adaptiveGateRepairExactViolationRows = 0
		archivedRouteCoverage.adaptiveGateRepairNeedRows = 0
		archivedRouteCoverage.adaptiveGateRepairInventoryCandidates = 0
		archivedRouteCoverage.adaptiveGateRepairSyntheticCandidates = 0
		archivedRouteCoverage.adaptiveGateRepairInputSample = nil
		archivedRouteCoverage.adaptiveGateRepairExactPreview = { }
		archivedRouteCoverage.adaptiveGateRepairRankedCandidates = 0
		archivedRouteCoverage.adaptiveGateRepairGeneratedBeforeDeduplication = 0
		archivedRouteCoverage.adaptiveGateRepairStatuses = { }
		archivedRouteCoverage.adaptiveGateRepairCanonicalizationFallbacks = 0
		archivedRouteCoverage.adaptiveGateRepairCanonicalizationContextError = nil
		archivedRouteCoverage.exactEvaluations = 0
		archivedRouteCoverage.exactFeasible = 0
		archivedRouteCoverage.structuralRejected = 0
		if archiveCancelled then return { status = "cancelled", candidate = nil, evaluations = 0 } end
		if archiveError then archivedRouteCoverage.error = tostring(archiveError):sub(1, 240) end
		-- Exact evaluation is scarce. Put compatible archive proposals before the
		-- generic routes so every bounded pattern gets a native PoB measurement.
		if #archivedRouteCandidates > 0 then
			local orderedTreeCandidates = { }
			for _, route in ipairs(archivedRouteCandidates) do orderedTreeCandidates[#orderedTreeCandidates + 1] = route end
			for _, route in ipairs(treeCandidates or { }) do orderedTreeCandidates[#orderedTreeCandidates + 1] = route end
			treeCandidates = orderedTreeCandidates
		end
	end
	archivedRouteCoverage.generatedCandidates = #archivedRouteCandidates
	local progressiveRoutePool = { }
	for _, route in ipairs(treeCandidates or { }) do progressiveRoutePool[#progressiveRoutePool + 1] = route end
	local progressiveRoutePoolStatus = "not_requested"
	local hasExplicitTreeTarget = #(parsed.targetNodeIds or { }) > 0
	if phase.searchTree and not phase.nodePotentialAnalysis and maxAddedPoints > 5 and not hasExplicitTreeTarget
		and treeQuota - #treeCandidates >= 3 then
		-- Exact-evaluation slots are scarce, but route proposals are cheap relative
		-- to a full PoB calculation. Build a bounded, region-balanced source pool
		-- separately, then spend only the existing combination quota on a few
		-- progressively larger portfolios. Skip this second A* pass when the
		-- tree phase cannot reserve at least three combination slots; at tiny exact
		-- budgets, broad route generation can consume the frame budget without
		-- leaving enough exact slots to compare its portfolios.
		local progressiveSourceQuota = math.min(96, math.max(#progressiveRoutePool, math.floor(candidateBudget * 3)))
		if progressiveSourceQuota > #progressiveRoutePool then
			local function progressiveRouteProgress(done, total, expanded, targetId)
				routeProgress(done, total, expanded, targetId, nil, nil, "expansão de rotas")
			end
			local broadRoutes, broadError, broadCancelled = treeSearch.BuildCandidateNodes(
				build.spec, parsed, progressiveSourceQuota, progressiveRouteProgress, maxAddedPoints, control, candidateRegionMap)
			if broadCancelled then return { status = "cancelled", candidate = nil, evaluations = 0 } end
			if broadError then return { status = "no_feasible_candidate", message = broadError, candidate = nil } end
			broadRoutes = treeSearch.BudgetCandidatesForPointLimit(
				build.spec, broadRoutes or { }, parsed, totalPointLimit, candidateRegionMap)
			local existingRouteKeys = { }
			for _, route in ipairs(progressiveRoutePool) do
				existingRouteKeys[table.concat(route.nodeIds or { }, ",")] = true
			end
			for _, route in ipairs(broadRoutes or { }) do
				local key = table.concat(route.nodeIds or { }, ",")
				if not existingRouteKeys[key] then
					existingRouteKeys[key] = true
					progressiveRoutePool[#progressiveRoutePool + 1] = route
				end
			end
			progressiveRoutePoolStatus = "bounded_region_balanced_pool"
		else
			progressiveRoutePoolStatus = "existing_candidates_sufficient"
		end
	end
	zoneCoverage.progressiveRoutePoolStatus = progressiveRoutePoolStatus
	zoneCoverage.progressiveRouteSourceCandidates = #progressiveRoutePool
	local progressiveRouteGoalsByRegion, progressiveRouteGoalIds = { }, { }
	for _, route in ipairs(progressiveRoutePool) do
		if route.targetId then
			progressiveRouteGoalIds[route.targetId] = true
			local region = tostring(route.targetRegion or "Unknown")
			progressiveRouteGoalsByRegion[region] = progressiveRouteGoalsByRegion[region] or { }
			progressiveRouteGoalsByRegion[region][route.targetId] = true
		end
	end
	local progressiveRouteGoalCount = 0
	for _ in pairs(progressiveRouteGoalIds) do progressiveRouteGoalCount = progressiveRouteGoalCount + 1 end
	local progressiveRouteGoalCoverage = { }
	for region, goals in pairs(progressiveRouteGoalsByRegion) do
		local count = 0
		for _ in pairs(goals) do count = count + 1 end
		progressiveRouteGoalCoverage[region] = count
	end
	zoneCoverage.progressiveRouteDistinctGoals = progressiveRouteGoalCount
	zoneCoverage.progressiveRouteGoalsByRegion = progressiveRouteGoalCoverage
	local removalQuota = phase.searchTree and not phase.nodePotentialAnalysis and math.min(math.floor(candidateBudget * 0.16), candidateBudget) or 0
	local removalCandidates = treeSearch.BuildRemovalCandidates(build.spec, parsed, removalQuota, candidateRegionMap)
	local configurationQuota = phase.combined and not phase.nodePotentialAnalysis and math.min(candidateBudget, math.max(math.min(3, candidateBudget), math.floor(candidateBudget * 0.15))) or 0
	local configurationCandidates, configurationCoverage, configurationError = configurationChoices.BuildCandidates(build, configurationQuota, parsed.search.seed)
	if not configurationCandidates then
		return { status = "invalid_inputs", candidate = nil, message = configurationError or "PoB configuration choices could not be enumerated" }
	end
	local clusterQuota = phase.searchTree and not phase.nodePotentialAnalysis and math.floor(candidateBudget * 0.12) or 0
	local clusterCandidates, clusterCoverage, clusterCancelled = ClusterSearch.BuildCandidates(
		build, clusterQuota, maxAddedPoints, parsed, candidateRegionMap, topologyCoverage, control,
		function(done, total, socketId, itemId)
			job.progress = {
				phase = "Generating native Cluster Jewel candidates",
				processed = done,
				total = total,
				current = "socket " .. tostring(socketId) .. "; item " .. tostring(itemId),
			}
			coroutine.yield(job.progress)
		end
	)
	if clusterCancelled then return { status = "cancelled", candidate = nil, evaluations = 0 } end
	local jewelQuota = phase.searchTree and not phase.nodePotentialAnalysis and math.floor(candidateBudget * 0.12) or 0
	local jewelCandidates = treeSearch.BuildJewelCandidates(build.spec, jewelQuota, maxAddedPoints, parsed.search.seed)
	local jewelCoverage = {
		generatedCandidates = #jewelCandidates,
		generatedPairedCandidates = 0,
		generatedOverlappingCandidates = 0,
		exactEvaluations = 0,
		exactPairedEvaluations = 0,
		exactOverlappingEvaluations = 0,
	}
	for _, jewelCandidate in ipairs(jewelCandidates) do
		if jewelCandidate.jewelVariants and #jewelCandidate.jewelVariants > 1 then
			jewelCoverage.generatedPairedCandidates = jewelCoverage.generatedPairedCandidates + 1
			if jewelCandidate.jewelCombination == "overlapping_radius_providers" then
				jewelCoverage.generatedOverlappingCandidates = jewelCoverage.generatedOverlappingCandidates + 1
			end
		end
	end
	local hasManualEdit = phase.searchTree and (#(parsed.search.addNodeIds or { }) > 0 or #(parsed.search.removeNodeIds or { }) > 0)
	local requestedAdditions = parsed.search.addNodeIds or { }
	local routedManualPath = #requestedAdditions > 0 and treeCandidates[1] and treeCandidates[1].isRequiredPath and treeCandidates[1] or nil
	local manualNodeIds = { }
	for _, nodeId in ipairs(routedManualPath and routedManualPath.nodeIds or requestedAdditions) do
		manualNodeIds[#manualNodeIds + 1] = nodeId
	end
	local manualCandidate = hasManualEdit and {
		nodeIds = manualNodeIds,
		removeNodeIds = parsed.search.removeNodeIds or { },
		label = "Requested explicit passive-tree edit",
		island = 1,
	} or nil
	local equipmentQuota = phase.searchEquipment and parsed.search.searchStoredItems and candidateBudget > 0
		and math.min(candidateBudget, math.max(1, math.floor(candidateBudget * 0.12))) or 0
	local equipmentRepairMaxQuota = phase.searchEquipment and parsed.search.searchStoredItems and candidateBudget > 0
		and math.min(candidateBudget, math.max(equipmentQuota, math.floor(candidateBudget * 0.22))) or 0
	local catalystRepairMaxQuota = phase.searchEquipment and candidateBudget > 0
		and math.min(candidateBudget, math.max(1, math.floor(candidateBudget * 0.22))) or 0
	local equipmentCandidates, equipmentCoverage = Equipment.BuildCandidates(
		build, equipmentRepairMaxQuota, parsed.search.seed, parsed.search.equipmentOverrides,
		{ repairReserve = true, excludeFlasks = parsed.search.routePlannerRunSpec ~= nil })
	local equipmentScheduledQuota = math.min(equipmentQuota, #equipmentCandidates)
	local scheduledEquipmentCandidates = { }
	local requirementRepairCoverage = GearRepair.NewCoverage()
	requirementRepairCoverage.generatedCandidates = #equipmentCandidates
	requirementRepairCoverage.initialQuota = equipmentScheduledQuota
	requirementRepairCoverage.reserveQuota = math.max(0, #equipmentCandidates - equipmentScheduledQuota)
	requirementRepairCoverage.scheduledCandidates = equipmentScheduledQuota
	local catalystCoverage = CatalystSearch.NewCoverage()
	local syntheticGearQuota = phase.searchEquipment and parsed.search.searchSyntheticGear and candidateBudget > 0
		and math.min(candidateBudget, math.max(1, math.floor(candidateBudget * 0.12))) or 0
	local syntheticGearCandidates, syntheticGearCoverage = SyntheticGear.BuildCandidates(
		build, syntheticGearQuota, parsed.search.seed, parsed.search.equipmentOverrides, parsed,
		parsed.search.syntheticItemLevel, targetSkill)
	local equipmentRouteQuota = phase.combined and parsed.search.searchStoredItems and #equipmentCandidates > 0
		and math.min(math.max(0, candidateBudget - equipmentQuota), math.floor(candidateBudget * 0.08)) or 0
	local syntheticGearRouteQuota = phase.combined and parsed.search.searchSyntheticGear and #syntheticGearCandidates > 0
		and math.min(math.max(0, candidateBudget - equipmentQuota - syntheticGearQuota), math.floor(candidateBudget * 0.08)) or 0
	local equipmentRoutes = { }
	for _, route in ipairs(treeCandidates) do
		if #(route.nodeIds or { }) > 0 or #(route.removeNodeIds or { }) > 0 then
			equipmentRoutes[#equipmentRoutes + 1] = route
		end
	end
	local gearRoutes = { }
	if phase.combined and phase.lockedAscendancySearch then
		-- A locked ascendancy is a structural part of the Combined candidate.
		-- Pair its native allocated route with equipment mutations before ordinary
		-- tree routes, so bounded route quotas cannot spend every slot on proposals
		-- that the hard ascendancy gate must reject.
		for _, route in ipairs(ascendancyCandidates) do
			if #(route.nodeIds or { }) > 0 then gearRoutes[#gearRoutes + 1] = route end
		end
	end
	for _, route in ipairs(equipmentRoutes) do gearRoutes[#gearRoutes + 1] = route end
	local equipmentRouteCandidates = candidateRunHelpers.combineRoutesAndMutations(gearRoutes,
		{ { key = "equipment", candidates = equipmentCandidates } }, equipmentRouteQuota)
	local syntheticGearRouteCandidates = candidateRunHelpers.combineRoutesAndMutations(gearRoutes,
		{ { key = "syntheticGear", candidates = syntheticGearCandidates } }, syntheticGearRouteQuota)
	equipmentCoverage.directQuota = equipmentQuota
	equipmentCoverage.repairReserveQuota = math.max(0, equipmentRepairMaxQuota - equipmentQuota)
	equipmentCoverage.routeQuota = equipmentRouteQuota
	equipmentCoverage.generatedRouteCandidates = #equipmentRouteCandidates
	equipmentCoverage.exactRouteEvaluations = 0
	syntheticGearCoverage.directQuota = syntheticGearQuota
	syntheticGearCoverage.routeQuota = syntheticGearRouteQuota
	syntheticGearCoverage.generatedRouteCandidates = #syntheticGearRouteCandidates
	syntheticGearCoverage.exactRouteEvaluations = 0
	syntheticGearCoverage.exactPairedEvaluations = 0
	syntheticGearCoverage.exactTripleEvaluations = 0
	syntheticGearCoverage.exactTripleBudgetEvaluations = 0
	syntheticGearCoverage.exactTripleBudgetPasses = 0
	syntheticGearCoverage.exactTripleBudgetFailures = 0
	local combinationQuota = phase.searchTree and not phase.nodePotentialAnalysis and math.max(0, treeQuota - #treeCandidates) or 0
	local combinedCandidates = treeSearch.CombineCandidates(progressiveRoutePool, combinationQuota, maxAddedPoints,
		build.spec, build.spec.curClass and build.spec.curClass.startNodeId)
	combinedCandidates = treeSearch.BudgetCandidatesForPointLimit(
		build.spec, combinedCandidates, parsed, totalPointLimit, candidateRegionMap)
	local ascendancyTreeCandidates = { }
	if phase.lockedAscendancySearch and not phase.nodePotentialAnalysis then
		local ascendancyTreeQuota = math.min(candidateBudget - 1, math.max(1, math.floor(candidateBudget * 0.20)))
		local ascendancyTreeRoutes = { }
		-- A fresh-class Tree search with a locked ascendancy must carry both
		-- structures into the same candidate. Previously progressive bundles
		-- were generated after the simple routes but never paired with the
		-- selected native ascendancy, so exact evaluation rejected them before
		-- PoB could score their larger passive paths. Schedule those broader
		-- bundles first in this small exact-evaluation reserve, while preserving
		-- individual routes in the remaining slots.
		for _, route in ipairs(combinedCandidates) do
			if route.progressiveRouteBundle then ascendancyTreeRoutes[#ascendancyTreeRoutes + 1] = route end
		end
		for _, route in ipairs(treeCandidates) do ascendancyTreeRoutes[#ascendancyTreeRoutes + 1] = route end
		for _, route in ipairs(combinedCandidates) do
			if not route.progressiveRouteBundle then ascendancyTreeRoutes[#ascendancyTreeRoutes + 1] = route end
		end
		ascendancyTreeCandidates = candidateRunHelpers.combineTreeAndAscendancyCandidates(ascendancyTreeRoutes, ascendancyCandidates, ascendancyTreeQuota)
		ascendancyTreeCandidates = treeSearch.BudgetCandidatesForPointLimit(
			build.spec, ascendancyTreeCandidates, parsed, totalPointLimit, candidateRegionMap)
	end
	local candidates = { }
	local baselineLabel = phase.tree and "Selected class root baseline" or "Current build"
	local baselineCandidate = { nodeIds = { }, removeNodeIds = { }, label = baselineLabel, island = 1, isBaselineCandidate = true }
	local baselineAscendancySource = phase.lockedAscendancySearch and ascendancyCandidates[1] or nil
	if baselineAscendancySource then
		local seen = { }
		for _, nodeId in ipairs(baselineAscendancySource.nodeIds or { }) do
			if not seen[nodeId] then seen[nodeId] = true; baselineCandidate.nodeIds[#baselineCandidate.nodeIds + 1] = nodeId end
		end
		for _, nodeId in ipairs(parsed.search.requiredNodeIds or { }) do
			if not seen[nodeId] then seen[nodeId] = true; baselineCandidate.nodeIds[#baselineCandidate.nodeIds + 1] = nodeId end
		end
		table.sort(baselineCandidate.nodeIds)
		baselineCandidate.ascendancyVariant = shallowCopy(baselineAscendancySource.ascendancyVariant)
		baselineCandidate.ascendancyPointCost = baselineAscendancySource.ascendancyPointCost
		baselineCandidate.mainAscendancyPointCost = baselineAscendancySource.mainAscendancyPointCost
		baselineCandidate.secondaryAscendancyPointCost = baselineAscendancySource.secondaryAscendancyPointCost
		baselineCandidate.label = "Selected class/ascendancy foundation baseline: "
			.. tostring(baselineAscendancySource.label or "native ascendancy route")
	end
	local manualCandidateFirst = manualCandidate and parsed.search.evaluationBudget == 1
		and not parsed.search.routePlannerRunSpec
	if targetSkill and targetSkill.gemVariant and targetSkill.changed and (phase.skills or phase.combined) then
		baselineCandidate.gemVariants = { shallowCopy(targetSkill.gemVariant) }
		baselineCandidate.selectedMainGemProposal = true
		baselineCandidate.label = "Selected Main Skill: " .. tostring(targetSkill.gemVariant.nameSpec or "native gem")
	end
	-- A one-evaluation explicit edit request must evaluate the requested edit,
	-- not spend its only slot on a baseline that cannot satisfy the request.
	if manualCandidateFirst then candidates[#candidates + 1] = manualCandidate end
	candidates[#candidates + 1] = baselineCandidate
	if phase.searchEquipment then
		for index = 1, equipmentScheduledQuota do
			local equipmentCandidate = equipmentCandidates[index]
			candidates[#candidates + 1] = equipmentCandidate
			scheduledEquipmentCandidates[equipmentCandidate] = true
		end
	end
	if manualCandidate and not manualCandidateFirst then candidates[#candidates + 1] = manualCandidate end
	if phase.searchEquipment then
		for _, syntheticGearCandidate in ipairs(syntheticGearCandidates) do candidates[#candidates + 1] = syntheticGearCandidate end
		for _, equipmentRouteCandidate in ipairs(equipmentRouteCandidates) do candidates[#candidates + 1] = equipmentRouteCandidate end
		for _, syntheticGearRouteCandidate in ipairs(syntheticGearRouteCandidates) do candidates[#candidates + 1] = syntheticGearRouteCandidate end
	end
	if phase.combined then
		for _, configurationCandidate in ipairs(configurationCandidates) do candidates[#candidates + 1] = configurationCandidate end
	end
	-- Give composite radius placements an early exact-evaluation slot. A single-
	-- jewel quota can otherwise crowd out overlapping-provider interactions.
	if phase.searchTree then
		for _, jewelCandidate in ipairs(jewelCandidates) do
			if jewelCandidate.jewelVariants and #jewelCandidate.jewelVariants > 1 then candidates[#candidates + 1] = jewelCandidate end
		end
	end
	-- Keep native cluster proposals near the front of the bounded exact-evaluation
	-- list so route/configuration enumeration cannot starve this item family.
	if phase.searchTree then
		for _, clusterCandidate in ipairs(clusterCandidates) do candidates[#candidates + 1] = clusterCandidate end
	end
	-- Reserve exact-evaluation opportunities early. The search list is bounded and
	-- otherwise route enumeration could consume the entire budget before item
	-- mutations are reached.
	if phase.searchEquipment then
		for _, anointCandidate in ipairs(anointCandidates) do candidates[#candidates + 1] = anointCandidate end
	end
	if phase.searchTree then
		-- A locked ascendancy is required structure for a legal tree result. Put
		-- paired tree/ascendancy proposals ahead of standalone ascendancy routes
		-- so a small exact-evaluation budget can reach the broader tree candidates.
		for _, treeCandidate in ipairs(ascendancyTreeCandidates) do candidates[#candidates + 1] = treeCandidate end
		for _, ascendancyCandidate in ipairs(ascendancyCandidates) do
			if ascendancyCandidate ~= baselineAscendancySource then candidates[#candidates + 1] = ascendancyCandidate end
		end
		-- When the user locks an ascendancy, raw passive routes cannot pass the
		-- required-node gate by themselves. Their exact-evaluation equivalents
		-- are the paired candidates above; omit these guaranteed structural
		-- rejections so the bounded evaluation budget remains available to legal
		-- route/ascendancy combinations.
		if not phase.lockedAscendancySearch then
			for _, treeCandidate in ipairs(treeCandidates) do candidates[#candidates + 1] = treeCandidate end
			for _, treeCandidate in ipairs(combinedCandidates) do candidates[#candidates + 1] = treeCandidate end
		end
		for _, removalCandidate in ipairs(removalCandidates) do candidates[#candidates + 1] = removalCandidate end
	end
	local addRemoveQuota = phase.searchTree and not phase.nodePotentialAnalysis and math.min(math.floor(candidateBudget * 0.14), candidateBudget) or 0
	local addRemoveCandidates = phase.searchTree and treeSearch.CombineAddRemoveCandidates(treeCandidates, removalCandidates, addRemoveQuota, maxAddedPoints) or { }
	addRemoveCandidates = treeSearch.BudgetCandidatesForPointLimit(
		build.spec, addRemoveCandidates, parsed, totalPointLimit, candidateRegionMap)
	for _, treeCandidate in ipairs(addRemoveCandidates) do candidates[#candidates + 1] = treeCandidate end
	local mutationGroups = { }
	local gemCandidateVariants, skillCatalogCoverage = { }, nil
	if phase.searchSkills then
		local strictRoutePlannerGemGroup = parsed.search.routePlannerRunSpec
			and parsed.search.routePlannerRunSpec.searchMode == "SINGLE_SKILL_ONLY"
			and parsed.search.routePlannerRunSpec.skill
			and parsed.search.routePlannerRunSpec.skill.groupIndex
		gemCandidateVariants, skillCatalogCoverage = candidateRunHelpers.createGemVariants(build, candidateBudget, targetSkill,
			parsed.search.seed, parsed.preferences and parsed.preferences.damageFocus, strictRoutePlannerGemGroup)
	end
	if phase.searchTree and not phase.nodePotentialAnalysis then
		mutationGroups[#mutationGroups + 1] = { key = "jewels", candidates = jewelCandidates }
		mutationGroups[#mutationGroups + 1] = { key = "masteries", candidates = treeSearch.BuildMasteryCandidates(build.spec, math.floor(candidateBudget * 0.08)) }
		mutationGroups[#mutationGroups + 1] = { key = "tattoos", candidates = treeSearch.BuildTattooCandidates(build.spec, math.floor(candidateBudget * 0.12)) }
		mutationGroups[#mutationGroups + 1] = { key = "timeless", candidates = treeSearch.BuildTimelessCandidates(build.spec, math.floor(candidateBudget * 0.08)) }
		mutationGroups[#mutationGroups + 1] = { key = "clusters", candidates = clusterCandidates }
	end
	if phase.searchEquipment then mutationGroups[#mutationGroups + 1] = { key = "anoints", candidates = anointCandidates } end
	if phase.searchSkills then
		mutationGroups[#mutationGroups + 1] = {
			key = "gems",
			candidates = gemCandidateVariants,
			coverage = skillCatalogCoverage,
		}
	end
	if phase.combined then mutationGroups[#mutationGroups + 1] = { key = "configuration", candidates = configurationCandidates } end
	local gemQuota = math.floor(candidateBudget * 0.18)
	for _, group in ipairs(mutationGroups) do
		local quota = group.key == "gems" and gemQuota or #group.candidates
		if group.key ~= "anoints" and group.key ~= "configuration" and group.key ~= "clusters" then
			for index = 1, math.min(quota, #group.candidates) do
				local mutation = group.candidates[index]
				if group.key ~= "jewels" or not (mutation.jewelVariants and #mutation.jewelVariants > 1) then
					candidates[#candidates + 1] = mutation
				end
			end
		end
	end
	if phase.combined then
		local routeMutationQuota = math.min(math.floor(candidateBudget * 0.20), proposalBudget - #candidates)
		for _, value in ipairs(candidateRunHelpers.combineRoutesAndMutations(treeCandidates, mutationGroups, routeMutationQuota)) do candidates[#candidates + 1] = value end
		local ascendancyRouteQuota = math.min(math.floor(candidateBudget * 0.20), proposalBudget - #candidates)
		for _, value in ipairs(candidateRunHelpers.combineRoutesAndMutations(treeCandidates, {
			{ key = "ascendancies", candidates = ascendancyCandidates },
		}, ascendancyRouteQuota)) do
			candidates[#candidates + 1] = value
		end
	end
	if #archivedRouteCandidates > 0 then
		local prioritized, insertedArchive = { }, false
		local archivedCandidateLookup = { }
		for _, archivedCandidate in ipairs(archivedRouteCandidates) do archivedCandidateLookup[archivedCandidate] = true end
		for _, candidate in ipairs(candidates) do
			if candidate.isBaselineCandidate then
				prioritized[#prioritized + 1] = candidate
				if not insertedArchive then
					for _, archivedCandidate in ipairs(archivedRouteCandidates) do
						prioritized[#prioritized + 1] = archivedCandidate
					end
					insertedArchive = true
				end
			elseif not archivedCandidateLookup[candidate] then
				prioritized[#prioritized + 1] = candidate
			end
		end
		if not insertedArchive then
			for _, archivedCandidate in ipairs(archivedRouteCandidates) do prioritized[#prioritized + 1] = archivedCandidate end
		end
		candidates = prioritized
	end
	if phase.tree and targetSkill and targetSkill.gemVariant and targetSkill.changed then
		-- Phantom calculations already use targetSkill.gemVariant as the selected
		-- skill. Persist that explicit user choice on each tree candidate too, so
		-- applying a route cannot leave PoB displaying/calculating the old skill.
		-- This is a fixed context input, not a searched skill/support variation.
		for _, candidate in ipairs(candidates) do
			if #candidateRunHelpers.getCandidateGemVariants(candidate) == 0 then
				candidate.gemVariants = { shallowCopy(targetSkill.gemVariant) }
				candidate.selectedMainSkillContext = true
			end
		end
	end
	local anointCandidatesGroup, gemCandidatesGroup
	for _, group in ipairs(mutationGroups) do
		if group.key == "anoints" then anointCandidatesGroup = group end
		if group.key == "gems" then gemCandidatesGroup = group end
	end
	gemCandidatesGroup = gemCandidatesGroup or { candidates = { } }
	local anointCoverage = {
		generatedCandidates = #(anointCandidatesGroup and anointCandidatesGroup.candidates or { }),
		availableCandidates = availableAnointCandidates or #(anointCandidatesGroup and anointCandidatesGroup.candidates or { }),
		generatedSingleCandidates = anointInventoryCoverage and anointInventoryCoverage.generatedSingleCandidates or 0,
		generatedPairedCandidates = anointInventoryCoverage and anointInventoryCoverage.generatedPairedCandidates or 0,
		availableSingleCandidates = anointInventoryCoverage and anointInventoryCoverage.availableSingleCandidates or 0,
		availablePairedCandidates = anointInventoryCoverage and anointInventoryCoverage.availablePairedCandidates or 0,
		generatedAnointCandidatesByCount = anointInventoryCoverage and anointInventoryCoverage.generatedAnointCandidatesByCount or { },
		availableAnointCandidatesByCount = anointInventoryCoverage and anointInventoryCoverage.availableAnointCandidatesByCount or { },
	}
	if #candidates < proposalBudget then
		local alreadyAddedGems = math.min(gemQuota, #gemCandidatesGroup.candidates)
		for index = alreadyAddedGems + 1, #gemCandidatesGroup.candidates do
			if #candidates >= proposalBudget then break end
			candidates[#candidates + 1] = gemCandidatesGroup.candidates[index]
		end
	end
	if phase.nodePotentialAnalysis then
		-- The node page is a one-factor study over the current build. Keep only
		-- the exact baseline and filtered A* routes; no gear, jewel, ascendancy,
		-- configuration, or support candidate can leak into this result.
		local routeOnlyCandidates = { baselineCandidate }
		for _, routeCandidate in ipairs(treeCandidates or { }) do
			if #(routeCandidate.nodeIds or { }) > 0 then
				if baselineCandidate.gemVariants then
					routeCandidate.gemVariants = { }
					for _, variant in ipairs(baselineCandidate.gemVariants) do routeCandidate.gemVariants[#routeCandidate.gemVariants + 1] = shallowCopy(variant) end
					routeCandidate.selectedMainGemProposal = true
				end
				routeOnlyCandidates[#routeOnlyCandidates + 1] = routeCandidate
			end
		end
		candidates = routeOnlyCandidates
	end
	if next(parsed.search.equipmentOverrides or { }) then
		for _, candidate in ipairs(candidates) do
			local gearVariant = candidate.gearVariant or { }
			gearVariant.overrides = Equipment.MergeOverrides(gearVariant.overrides, parsed.search.equipmentOverrides)
			gearVariant.items = Equipment.DescribeOverrides(build, gearVariant.overrides)
			candidate.gearVariant = gearVariant
		end
	end
	if classVariant then
		for _, candidate in ipairs(candidates) do candidate.classVariant = { classId = classVariant.classId } end
	end
	if phase.lockedAscendancySearch then
		for _, candidate in ipairs(candidates) do
			if not candidate.ascendancyVariant then
				candidate.ascendancyVariant = { ascendClassId = parsed.search.ascendancyId, secondaryAscendClassId = 0 }
			end
		end
	end
	archivedRouteCoverage.generatedComposedCandidates = candidateRunHelpers.countCandidateFlag(candidates, "archivedRouteComposition")
	prepared.sourceBuild = sourceBuild
	prepared.sourceSignature = sourceSignature
	prepared.phase = phase
	prepared.classVariant = classVariant
	prepared.treeError = treeError
	prepared.treeBudgetCoverage = treeBudgetCoverage
	prepared.targetSkill = targetSkill
	prepared.requireSocketedMainSkill = requireSocketedMainSkill
	prepared.extraPoints = extraPoints
	prepared.totalPointLimit = totalPointLimit
	prepared.maxAddedPoints = maxAddedPoints
	prepared.proposalBudget = proposalBudget
	prepared.ascendancyCoverage = ascendancyCoverage
	prepared.candidateRegionMap = candidateRegionMap
	prepared.topologyCoverage = topologyCoverage
	prepared.zoneCoverage = zoneCoverage
	prepared.archivedRouteCoverage = archivedRouteCoverage
	prepared.configurationCoverage = configurationCoverage
	prepared.clusterCoverage = clusterCoverage
	prepared.jewelCoverage = jewelCoverage
	prepared.equipmentRepairMaxQuota = equipmentRepairMaxQuota
	prepared.catalystRepairMaxQuota = catalystRepairMaxQuota
	prepared.equipmentCoverage = equipmentCoverage
	prepared.equipmentCandidates = equipmentCandidates
	prepared.equipmentScheduledQuota = equipmentScheduledQuota
	prepared.scheduledEquipmentCandidates = scheduledEquipmentCandidates
	prepared.requirementRepairCoverage = requirementRepairCoverage
	prepared.catalystCoverage = catalystCoverage
	prepared.syntheticGearCoverage = syntheticGearCoverage
	prepared.syntheticGearCandidates = syntheticGearCandidates
	prepared.candidates = candidates
	prepared.manualCandidateFirst = manualCandidateFirst
	prepared.skillCatalogCoverage = skillCatalogCoverage
	prepared.anointCoverage = anointCoverage
	end
	local sourceBuild, sourceSignature, phase, classVariant, treeError, treeBudgetCoverage, targetSkill,
		requireSocketedMainSkill, extraPoints, totalPointLimit, maxAddedPoints,
		proposalBudget, ascendancyCoverage, candidateRegionMap, topologyCoverage,
		zoneCoverage, archivedRouteCoverage, configurationCoverage, clusterCoverage,
		jewelCoverage, equipmentRepairMaxQuota, catalystRepairMaxQuota,
		equipmentCoverage, equipmentCandidates, equipmentScheduledQuota,
		scheduledEquipmentCandidates, requirementRepairCoverage, catalystCoverage,
		syntheticGearCoverage, syntheticGearCandidates, candidates, manualCandidateFirst, skillCatalogCoverage,
		anointCoverage = prepared.sourceBuild, prepared.sourceSignature, prepared.phase,
		prepared.classVariant, prepared.treeError, prepared.treeBudgetCoverage, prepared.targetSkill,
		prepared.requireSocketedMainSkill, prepared.extraPoints, prepared.totalPointLimit,
		prepared.maxAddedPoints, prepared.proposalBudget, prepared.ascendancyCoverage,
		prepared.candidateRegionMap, prepared.topologyCoverage, prepared.zoneCoverage,
		prepared.archivedRouteCoverage, prepared.configurationCoverage,
		prepared.clusterCoverage, prepared.jewelCoverage,
		prepared.equipmentRepairMaxQuota, prepared.catalystRepairMaxQuota,
		prepared.equipmentCoverage, prepared.equipmentCandidates,
		prepared.equipmentScheduledQuota, prepared.scheduledEquipmentCandidates,
		prepared.requirementRepairCoverage, prepared.catalystCoverage,
		prepared.syntheticGearCoverage, prepared.syntheticGearCandidates, prepared.candidates,
		prepared.manualCandidateFirst, prepared.skillCatalogCoverage, prepared.anointCoverage
	-- Drop the preparation table now: it also owns the original full proposal
	-- array. The exact scheduler may retain only a bounded prefix of that array.
	prepared = nil
	local flaskMutationCandidatesRejected = 0
	if parsed.search.routePlannerRunSpec then
		candidates, flaskMutationCandidatesRejected = Equipment.FilterFlaskMutations(build, candidates)
		if parsed.search.routePlannerRunSpec.searchMode == "SINGLE_SKILL_ONLY" then
			skillCatalogCoverage = skillCatalogCoverage or { }
			candidates, skillCatalogCoverage.singleSkillScope = candidateRunHelpers.filterCandidatesToSingleSkill(
				candidates, parsed.search.routePlannerRunSpec.skill and parsed.search.routePlannerRunSpec.skill.groupIndex)
		end
	end
	for _, candidate in ipairs(candidates) do
		if not candidateBelongsToPhase(candidate, phase.generation) then
			return {
				status = "error", candidate = nil,
				message = "Candidate generator crossed the " .. phase.generation .. " phase boundary: " .. tostring(candidate.label or "unnamed candidate"),
				evaluations = 0, generationPhase = phase.generation,
			}
		end
		candidate.generationPhase = phase.generation
		candidate.requiresSocketedMainSkill = requireSocketedMainSkill == true
	end
	local proposalPreparation = { generatedCandidates = #candidates, baselineReserved = false, baselineCandidateCount = 0 }
	proposalPreparation.proposedProgressiveTreeBundles = candidateRunHelpers.countCandidateFlag(candidates, "progressiveRouteBundle")
	proposalPreparation.proposedLockedProgressiveAscendancyCandidates = countLockedProgressiveCandidates(
		candidates, parsed.search.ascendancyId, parsed.search.requiredNodeIds)
	local socketRepairCoverage
	do
		local identityContextHash, identityContextError = CandidateIdentity.HashContext({
			buildSignature = sourceSignature,
			engineVersion = Version.Snapshot(sourceBuild),
			generationPhase = phase.generation,
			scenarioProfile = parsed.scenarioProfile or "Current",
			scenarioEnemyPreset = parsed.scenarioEnemyPreset,
			scenarioEnemyLevel = parsed.scenarioEnemyLevel,
			selectedMainSkill = targetSkill and targetSkill.gemVariant and {
				gemId = targetSkill.gemVariant.gemId,
				skillId = targetSkill.gemVariant.skillId,
				nameSpec = targetSkill.gemVariant.nameSpec,
			} or nil,
		})
		proposalPreparation.identityContextHash = identityContextHash
		local uniqueCandidates
		uniqueCandidates, proposalPreparation.identityCoverage = CandidateIdentity.Deduplicate(candidates, identityContextHash)
		proposalPreparation.identityContextError = identityContextError
		local identityCoverageBeforeSocketRepair = proposalPreparation.identityCoverage
		local socketRepairSpec = parsed.search.routePlannerRunSpec
			and parsed.search.routePlannerRunSpec.skill
		local socketRepairPlans = socketRepairSpec and socketRepairSpec.socketRepairs or { }
		if #socketRepairPlans == 0 and socketRepairSpec and socketRepairSpec.socketRepair then
			socketRepairPlans = { socketRepairSpec.socketRepair }
		end
		if #socketRepairPlans > 0 then
			local repairCandidateBySlot = { }
			for _, candidate in ipairs(uniqueCandidates) do
				if not candidate.isBaselineCandidate and candidate.gearVariant and candidate.gearVariant.socketRepair then
					for _, repairPlan in ipairs(socketRepairPlans) do
					if candidateRunHelpers.candidateRepairsSocketPlan(build, candidate, repairPlan) then
							repairCandidateBySlot[repairPlan.slot] = repairCandidateBySlot[repairPlan.slot] or candidate
						end
					end
				end
			end
			local repairable, rejected, composed, alreadyRepaired, gemRemovalCompositions = { }, 0, 0, 0, 0
			local rejectionReasons = { }
			local composedByFamily = { }
			local composedRepairSeedCount = 0
			for _, candidate in ipairs(uniqueCandidates) do
				if candidate.isBaselineCandidate then
					-- Preserve the exact native source baseline for comparison; active
					-- socket violations keep it out of the feasible Pareto results.
					repairable[#repairable + 1] = candidate
				else
					local originalGear = candidate.gearVariant
					local workingCandidate = shallowCopy(candidate)
					workingCandidate.gearVariant = originalGear
					local originalFamily = CandidateIdentity.Family(candidate)
					local allRepairsCovered = true
					local candidateWasComposed = false
					for _, repairPlan in ipairs(socketRepairPlans) do
						if #(repairPlan.gemRemovals or { }) > 0 then
							local repairedGemVariants, gemMergeError = candidateRunHelpers.mergeCandidateGemVariants(
								workingCandidate, { gemVariants = repairPlan.gemRemovals })
							if not repairedGemVariants then
								allRepairsCovered = false
								local reason = tostring(gemMergeError or "Disabled support cleanup conflicts with the proposal")
								rejectionReasons[reason] = (rejectionReasons[reason] or 0) + 1
								break
							end
							workingCandidate.gemVariants = repairedGemVariants
							workingCandidate.gemVariant = nil
							candidateWasComposed = true
							gemRemovalCompositions = gemRemovalCompositions + 1
						end
						if candidateRunHelpers.candidateRepairsSocketPlan(build, workingCandidate, repairPlan) then
							alreadyRepaired = alreadyRepaired + 1
						else
							local repairCandidate = repairCandidateBySlot[repairPlan.slot]
						if not repairCandidate then
							allRepairsCovered = false
							local reason = "No native socket-repair candidate for " .. tostring(repairPlan.slot)
							rejectionReasons[reason] = (rejectionReasons[reason] or 0) + 1
							break
						end
						local mergedGear, mergeStatus = candidateRunHelpers.composeSocketRepairGearVariant(
							build, workingCandidate, repairCandidate, repairPlan)
						if not mergedGear then
							allRepairsCovered = false
							local reason = tostring(mergeStatus or ("Socket repair could not be composed for " .. tostring(repairPlan.slot)))
							rejectionReasons[reason] = (rejectionReasons[reason] or 0) + 1
							break
						end
						workingCandidate.gearVariant = mergedGear
						candidateWasComposed = true
						composed = composed + 1
						composedByFamily[originalFamily] = (composedByFamily[originalFamily] or 0) + 1
					end
				end
				if allRepairsCovered then
					candidate.plannerFamilyOverride = originalFamily
					candidate.gearVariant = workingCandidate.gearVariant
					if workingCandidate.gemVariants then
						candidate.gemVariants = workingCandidate.gemVariants
						candidate.gemVariant = nil
					end
					candidate.socketRepairsComplete = true
					if candidateWasComposed then
						local repairSlots = { }
						for _, repairPlan in ipairs(socketRepairPlans) do repairSlots[#repairSlots + 1] = tostring(repairPlan.slot) end
						candidate.label = tostring(candidate.label or "Native proposal") .. " + Native socket/link repairs: "
							.. table.concat(repairSlots, ", ")
						local removedSupports = { }
						for _, repairPlan in ipairs(socketRepairPlans) do
							for _, removal in ipairs(repairPlan.gemRemovals or { }) do
								removedSupports[#removedSupports + 1] = tostring(removal.name or removal.nameSpec or "disabled support")
							end
						end
						if #removedSupports > 0 then
							candidate.label = candidate.label .. " + remove disabled support(s): " .. table.concat(removedSupports, ", ")
						end
					end
					if originalGear and originalGear.socketRepairOnly == true then
						candidate.socketRepairOnlySeed = true
						composedRepairSeedCount = composedRepairSeedCount + 1
					end
					repairable[#repairable + 1] = candidate
				else
					rejected = rejected + 1
				end
			end
		end
			local deduplicatedRepairable
			deduplicatedRepairable, proposalPreparation.identityCoverage = CandidateIdentity.DeduplicateAfterComposition(
				repairable, identityContextHash, proposalPreparation.identityCoverage)
			uniqueCandidates = deduplicatedRepairable
			local socketRepairSlots, repairCandidatesAvailable, allRepairCandidatesAvailable = { }, 0, true
			for _, repairPlan in ipairs(socketRepairPlans) do
				socketRepairSlots[#socketRepairSlots + 1] = {
					slot = repairPlan.slot,
					socketCount = repairPlan.socketCount,
					groupIndices = shallowCopy(repairPlan.groupIndices or { }),
					gemRemovalCount = #(repairPlan.gemRemovals or { }),
					removedDisabledSupports = (function()
						local names = { }
						for _, removal in ipairs(repairPlan.gemRemovals or { }) do
							names[#names + 1] = tostring(removal.name or removal.nameSpec or "disabled support")
						end
						return names
					end)(),
				}
				if repairCandidateBySlot[repairPlan.slot] then
					repairCandidatesAvailable = repairCandidatesAvailable + 1
				else
					allRepairCandidatesAvailable = false
				end
			end
			socketRepairCoverage = {
				status = #deduplicatedRepairable > 1 and "all_active_groups_repairable" or "no_compatible_repair_candidate",
				requiredSlotCount = #socketRepairPlans,
				slots = socketRepairSlots,
				generatedUniqueBeforeFilter = identityCoverageBeforeSocketRepair.uniqueCandidates,
				retainedForExactEvaluation = math.max(0, #deduplicatedRepairable - 1),
				structurallyRejected = rejected,
				repairCandidatesAvailable = repairCandidatesAvailable,
				repairCandidateAvailable = allRepairCandidatesAvailable,
				repairContextComposedCandidates = composed,
				repairContextComposedByFamily = composedByFamily,
				gemRemovalCompositions = gemRemovalCompositions,
				candidatesAlreadyRepairingSockets = alreadyRepaired,
				requiredExactRepairSeeds = composedRepairSeedCount,
				postRepairUniqueCandidates = proposalPreparation.identityCoverage.postCompositionUniqueCandidates,
				postRepairDuplicateCandidatesDiscarded = proposalPreparation.identityCoverage.postCompositionDuplicatesDiscarded,
				rejectedByReason = rejectionReasons,
			}
		end
		candidates = uniqueCandidates
		if not manualCandidateFirst then
			proposalPreparation.baselinePosition, proposalPreparation.baselineCandidateCount = CandidateIdentity.PrioritizeBaseline(candidates)
			proposalPreparation.baselineReserved = proposalPreparation.baselinePosition == 1
		end
		proposalPreparation.uniqueCandidates = #candidates
		proposalPreparation.discardedByProposalBudget = math.max(0, #candidates - proposalBudget)
		if proposalPreparation.discardedByProposalBudget > 0 then
			for index = #candidates, proposalBudget + 1, -1 do candidates[index] = nil end
		end
		proposalPreparation.retainedAfterProposalBudget = #candidates
		proposalPreparation.retainedProgressiveTreeBundles = candidateRunHelpers.countCandidateFlag(candidates, "progressiveRouteBundle")
		proposalPreparation.retainedLockedProgressiveAscendancyCandidates = countLockedProgressiveCandidates(
			candidates, parsed.search.ascendancyId, parsed.search.requiredNodeIds)
	end
	do
		local retainedScheduledEquipment = 0
		for _, candidate in ipairs(candidates) do
			if scheduledEquipmentCandidates[candidate] then retainedScheduledEquipment = retainedScheduledEquipment + 1 end
		end
		equipmentScheduledQuota = retainedScheduledEquipment
		requirementRepairCoverage.scheduledCandidates = equipmentScheduledQuota
	end
	archivedRouteCoverage.retainedComposedCandidates = candidateRunHelpers.countCandidateFlag(candidates, "archivedRouteComposition")
	archivedRouteCoverage.retainedDirectCandidates = math.max(0,
		candidateRunHelpers.countCandidateFlag(candidates, "archivedRoutePattern") - archivedRouteCoverage.retainedComposedCandidates)
	local phaseCoverage = {
		phase = phase.generation,
		generatedCandidates = proposalPreparation.generatedCandidates,
		composedCandidates = proposalPreparation.identityCoverage.composedCandidates,
		uniqueCandidates = proposalPreparation.identityCoverage.uniqueCandidates,
		duplicateCandidatesDiscarded = proposalPreparation.identityCoverage.duplicateCandidatesDiscarded,
		postCompositionUniqueCandidates = proposalPreparation.identityCoverage.postCompositionUniqueCandidates,
		postCompositionDuplicatesDiscarded = proposalPreparation.identityCoverage.postCompositionDuplicatesDiscarded,
		postCompositionCanonicalizationFallbacks = proposalPreparation.identityCoverage.postCompositionCanonicalizationFallbacks,
		discardedByProposalBudget = proposalPreparation.discardedByProposalBudget,
		proposalBudgetRetainedCandidates = proposalPreparation.retainedAfterProposalBudget,
		flaskMutationCandidatesRejected = flaskMutationCandidatesRejected,
		excludedFlaskSlots = tonumber(equipmentCoverage.excludedFlaskSlots) or 0,
		canonicalizationFallbacks = proposalPreparation.identityCoverage.canonicalizationFallbacks,
		canonicalizationContextError = proposalPreparation.identityContextError,
		gemMutationScope = skillCatalogCoverage and skillCatalogCoverage.singleSkillScope
			or { status = "not_applicable" },
		socketRepair = socketRepairCoverage,
		proposalFamilyCountsBefore = proposalPreparation.identityCoverage.proposalFamilyCountsBefore,
		proposalFamilyCountsAfter = proposalPreparation.identityCoverage.proposalFamilyCountsAfter,
		nodePower = shallowCopy(parsed.search.nodePowerCoverage or {
			status = parsed.search.useShowNodePower == true and "not_available" or "disabled",
			stat = parsed.search.nodePowerStat,
			focusStat = parsed.search.nodePowerFocusStat,
			prioritizedTargets = 0, targets = 0, reason = parsed.search.nodePowerFallbackReason,
		}),
		pointBudget = treeBudgetCoverage or { status = "unavailable" },
		retainedCandidates = #candidates,
		baselineReserved = proposalPreparation.baselineReserved,
		baselineCandidateCount = proposalPreparation.baselineCandidateCount,
		baselineEvaluated = false,
		baselineEvaluationIndex = nil,
		baselineHash = nil,
		repairPassGeneratedCandidates = 0,
		repairPassRemovedScheduledCandidates = 0,
		repairPassComposedCandidates = 0,
		repairPassUniqueCandidates = 0,
		repairPassDuplicateCandidatesDiscarded = 0,
		repairPassDiscardedByProposalBudget = 0,
		repairPassRetainedCandidates = 0,
		repairPassOrdering = "deterministic_after_baseline; not_gnn_ranked",
		generatedTreeCandidates = 0,
		archivedRoutePatterns = archivedRouteCoverage,
		generatedProgressiveTreeBundles = 0,
		proposedProgressiveTreeBundles = proposalPreparation.proposedProgressiveTreeBundles or 0,
		retainedProgressiveTreeBundles = proposalPreparation.retainedProgressiveTreeBundles or 0,
		proposedLockedProgressiveAscendancyCandidates = proposalPreparation.proposedLockedProgressiveAscendancyCandidates or 0,
		retainedLockedProgressiveAscendancyCandidates = proposalPreparation.retainedLockedProgressiveAscendancyCandidates or 0,
		progressiveTreeAscendancyReservationStatus = phase.lockedAscendancySearch and "pending" or "not_requested",
		progressiveTreeAscendancyReservationPosition = nil,
		progressiveTreeReservationStatus = phase.searchTree and "pending" or "not_requested",
		progressiveTreeReservationPosition = nil,
		exactProgressiveTreeAscendancyBundleEvaluations = 0,
		maxProgressiveRouteCount = 0,
		maxCycleFilteredRouteCount = 0,
		totalCycleFilteredRouteCount = 0,
		largestProposedTreePointCount = 0,
		exactProgressiveTreeBundleEvaluations = 0,
		progressiveTreeEvaluationSummaries = { },
		structuralTreeRejections = 0,
		structuralProgressiveTreeBundleRejections = 0,
		firstProgressiveTreeStructuralRejection = nil,
		largestExactTreePointCount = 0,
		generatedTreeAscendancyCombinations = 0,
		exactTreeAscendancyCombinations = 0,
		selectedMainSkillContextCandidates = 0,
		generatedSkillCandidates = 0,
		generatedSupportSwapCandidates = 0,
		generatedSupportCombinationCandidates = 0,
		generatedSupportAddCandidates = 0,
		generatedSupportAddCombinationCandidates = 0,
		exactSupportSwapEvaluations = 0,
		exactSupportCombinationEvaluations = 0,
		exactSupportAddEvaluations = 0,
		exactSupportAddCombinationEvaluations = 0,
		compatibleSupportSwapEvaluations = 0,
		compatibleSupportCombinationEvaluations = 0,
		compatibleSupportAddEvaluations = 0,
		compatibleSupportAddCombinationEvaluations = 0,
		rejectedSupportSwapEvaluations = 0,
		firstSupportSwapRejection = nil,
		rejectedSupportAddEvaluations = 0,
		firstSupportAddRejection = nil,
		generatedEquipmentCandidates = 0,
		rankedCandidates = 0,
		exactEvaluations = 0,
		candidateAttempts = 0,
		structuralCandidateRejections = 0,
		candidateReconstructionFailures = 0,
		exactEvaluationsByFamily = { },
		exactEvaluationPlan = nil,
		skillCatalog = skillCatalogCoverage,
		supportPackages = { swaps = { }, additions = { } },
	}
	for arity = 1, 5 do
		phaseCoverage.supportPackages.swaps[arity] = { arity = arity, generated = 0, exact = 0, compatible = 0, rejected = 0 }
		phaseCoverage.supportPackages.additions[arity] = { arity = arity, generated = 0, exact = 0, compatible = 0, rejected = 0 }
	end
	for _, candidate in ipairs(candidates) do
		local proposedTreePoints = countAddedMainPoints(build.spec, candidate.nodeIds or { })
		phaseCoverage.largestProposedTreePointCount = math.max(phaseCoverage.largestProposedTreePointCount, proposedTreePoints)
		if candidate.progressiveRouteBundle then
			phaseCoverage.generatedProgressiveTreeBundles = phaseCoverage.generatedProgressiveTreeBundles + 1
			phaseCoverage.maxProgressiveRouteCount = math.max(phaseCoverage.maxProgressiveRouteCount, candidate.routeCount or 0)
			local cycleFiltered = candidate.cycleFilteredRouteCount or 0
			phaseCoverage.maxCycleFilteredRouteCount = math.max(phaseCoverage.maxCycleFilteredRouteCount, cycleFiltered)
			phaseCoverage.totalCycleFilteredRouteCount = phaseCoverage.totalCycleFilteredRouteCount + cycleFiltered
		end
		if candidate.combinedTreeAscendancy then
			phaseCoverage.generatedTreeAscendancyCombinations = phaseCoverage.generatedTreeAscendancyCombinations + 1
		end
		if candidate.classVariant or candidate.ascendancyVariant or candidate.jewelVariant
			or #(candidate.jewelVariants or { }) > 0 or candidate.masteryVariant or candidate.tattooVariant
			or candidate.timelessVariant or #(candidate.nodeIds or { }) > 0 or #(candidate.removeNodeIds or { }) > 0 then
			phaseCoverage.generatedTreeCandidates = phaseCoverage.generatedTreeCandidates + 1
		end
		local gemVariants = candidateRunHelpers.getCandidateGemVariants(candidate)
		if candidate.selectedMainSkillContext then
			phaseCoverage.selectedMainSkillContextCandidates = phaseCoverage.selectedMainSkillContextCandidates + 1
		end
		if #gemVariants > 0 then
			if not candidate.selectedMainSkillContext then
				phaseCoverage.generatedSkillCandidates = phaseCoverage.generatedSkillCandidates + 1
			end
			local supportCount, supportAddCount = 0, 0
			for _, variant in ipairs(gemVariants) do
				if variant.kind == "support_swap" then supportCount = supportCount + 1 end
				if variant.kind == "support_add" then supportAddCount = supportAddCount + 1 end
			end
			if supportCount > 0 then
				phaseCoverage.generatedSupportSwapCandidates = phaseCoverage.generatedSupportSwapCandidates + 1
				local row = phaseCoverage.supportPackages.swaps[supportCount]
				if row then row.generated = row.generated + 1 end
			end
			if supportCount > 1 then phaseCoverage.generatedSupportCombinationCandidates = phaseCoverage.generatedSupportCombinationCandidates + 1 end
			if supportAddCount > 0 then
				phaseCoverage.generatedSupportAddCandidates = phaseCoverage.generatedSupportAddCandidates + 1
				local row = phaseCoverage.supportPackages.additions[supportAddCount]
				if row then row.generated = row.generated + 1 end
			end
			if supportAddCount > 1 then phaseCoverage.generatedSupportAddCombinationCandidates = phaseCoverage.generatedSupportAddCombinationCandidates + 1 end
		end
		if candidate.gearVariant or candidate.anointVariant or candidate.anointVariants then
			phaseCoverage.generatedEquipmentCandidates = phaseCoverage.generatedEquipmentCandidates + 1
		end
	end
	-- Contextual path evidence is mined from prior exact runs. It only orders
	-- proposals within their existing candidate family and never removes one.
	local currentEngine = Version.Snapshot(sourceBuild)
	local function pathMemoryProgress(recordsLoaded, bytePosition, totalBytes)
		if control.cancelled then return false end
		job.progress = {
			phase = "Loading path memory", processed = bytePosition, total = totalBytes,
			current = tostring(recordsLoaded) .. " records indexed",
		}
		coroutine.yield(job.progress)
		return not control.cancelled
	end
	local experienceState = PathExperience.Open(main and main.userPath, currentEngine, pathMemoryProgress)
	if experienceState.status == "cancelled" or control.cancelled then
		return { status = "cancelled", candidate = nil, evaluations = 0 }
	end
	local basePathContext, basePathContextError = PathExperience.MakeBaseContext(build, parsed, targetSkill, sourceSignature)
	local pathIndex, pathIndexSummary = PathPatterns.BuildIndex(experienceState.records, currentEngine, function(phase, processed, total)
		if control.cancelled then return false end
		job.progress = { phase = "Mining path patterns", processed = processed, total = total, current = phase }
		coroutine.yield(job.progress)
		return not control.cancelled
	end)
	pathIndexSummary = pathIndexSummary or { status = "unavailable", compatibleRecords = 0, labeledRecords = 0, patternCount = 0 }
	if pathIndexSummary.status == "cancelled" or control.cancelled then
		return { status = "cancelled", candidate = nil, evaluations = 0 }
	end
	local pathLearningCoverage = {
		status = pathIndexSummary.status,
		contextStatus = basePathContext and "ready" or (basePathContextError or "optimizer_context_incomplete"),
		storageStatus = experienceState.status,
		recordWritesEnabled = control.recordPathLearning ~= false,
		recordWritePolicy = control.recordPathLearning == false and "explicitly_disabled"
			or control.isolatedStudy and "exact_imported_study_observations" or "exact_active_build_observations",
		compatibleRecords = pathIndexSummary.compatibleRecords or 0,
		labeledRecords = pathIndexSummary.labeledRecords or 0,
		patternCount = pathIndexSummary.patternCount or 0,
		incompatibleRecords = experienceState.incompatibleRecords or 0,
		storedThisRun = 0,
		duplicatesThisRun = 0,
		rankedCandidates = 0,
		reorderedCandidates = 0,
		preservedExploration = 0,
		promotedExploration = 0,
	}
	if basePathContext then
		basePathContext.observationSource = control.isolatedStudy and "imported_study" or "active_build"
	end
	-- The neural artifact remains an optional narrow ranking hint. It is loaded
	-- from one app-owned path, never from AI-provided input.
	local surrogateLoadStatus
	if parsed.search.routePlannerRunSpec then
		surrogate.Disable()
		surrogateLoadStatus = "route_planner_uses_external_gnn_or_deterministic_fallback"
	elseif main and main.userPath then
		local loaded, loadStatus = surrogate.LoadFromUserPath(main.userPath)
		surrogateLoadStatus = loaded and "loaded" or loadStatus
	else
		surrogate.Disable()
		surrogateLoadStatus = "user_path_unavailable"
	end
	local surrogateInputs = { }
	if surrogate.enabled then
		local baselineOutput = build.calcsTab and build.calcsTab.mainOutput
		for _, candidate in ipairs(candidates) do
			local featureInput = SurrogateFeatures.FromCandidate(build, candidate, baselineOutput, parsed.objective)
			if featureInput then
				candidate.surrogateFeatures = featureInput
				surrogateInputs[#surrogateInputs + 1] = candidate
			end
		end
	end
	-- A learned policy is compatible only with the complete engine/tree identity.
	-- It may permute supported passive proposals; exact PoB still evaluates all
	-- candidates and all hard constraints after this optional ordering hint.
	local rankingStatus
	if parsed.search.routePlannerRunSpec then
		candidates, rankingStatus = GNNRanker.Rank(build, candidates, parsed, control, job)
		if parsed.search.routePlannerRunSpec.modelMode == "approved_gnn" and rankingStatus ~= "ranked" then
			return { status = "model_unavailable", message = "A rota exige um pacote GNN aprovado e compatível; o pacote não está disponível." }
		end
	else
		candidates, rankingStatus = surrogate.Rank(candidates, Version.Snapshot(build))
	end
	if control.cancelled then return { status = "cancelled", candidate = nil, evaluations = 0 } end
	local pathRanking
	candidates, pathRanking = PathPatterns.RankCandidates(pathIndex, candidates, basePathContext, build.spec,
		function(phase, processed, total)
			if control.cancelled then return false end
			job.progress = { phase = "Applying contextual path evidence", processed = processed, total = total, current = phase }
			coroutine.yield(job.progress)
			return not control.cancelled
		end, build)
	pathRanking = pathRanking or { status = "unavailable" }
	pathLearningCoverage.status = pathRanking.status ~= "insufficient_context" and pathRanking.status or pathIndexSummary.status
	pathLearningCoverage.rankedCandidates = pathRanking.rankedCandidates or 0
	pathLearningCoverage.reorderedCandidates = pathRanking.reorderedCandidates or 0
	pathLearningCoverage.preservedExploration = pathRanking.preservedExploration or 0
	pathLearningCoverage.promotedExploration = pathRanking.promotedExploration or 0
	if control.cancelled or pathLearningCoverage.status == "cancelled" then
		return { status = "cancelled", candidate = nil, evaluations = 0 }
	end
	if not manualCandidateFirst then
		proposalPreparation.baselinePosition, proposalPreparation.baselineCandidateCount = CandidateIdentity.PrioritizeBaseline(candidates)
		phaseCoverage.baselineReserved = proposalPreparation.baselinePosition == 1
		phaseCoverage.baselineCandidateCount = proposalPreparation.baselineCandidateCount or 0
		phaseCoverage.baselineHash = proposalPreparation.baselinePosition == 1 and candidates[1].canonicalHash or nil
	end
	local progressiveCandidateForExact
	if phase.lockedAscendancySearch then
		local position, status = prioritizeLockedProgressiveCandidate(
			candidates, parsed.search.ascendancyId, parsed.search.requiredNodeIds,
			parsed.search.evaluationBudget, phaseCoverage.baselineReserved)
		phaseCoverage.progressiveTreeAscendancyReservationPosition = position
		phaseCoverage.progressiveTreeAscendancyReservationStatus = status
		phaseCoverage.progressiveTreeReservationPosition = position
		phaseCoverage.progressiveTreeReservationStatus = status
		progressiveCandidateForExact = position and candidates[position] or nil
	elseif phase.searchTree and not phase.nodePotentialAnalysis then
		local position, status = prioritizeProgressiveTreeCandidate(
			candidates, parsed.search.evaluationBudget, phaseCoverage.baselineReserved)
		phaseCoverage.progressiveTreeReservationPosition = position
		phaseCoverage.progressiveTreeReservationStatus = status
		progressiveCandidateForExact = position and candidates[position] or nil
	end
	if parsed.search.routePlannerRunSpec then
		candidates, phaseCoverage.exactEvaluationPlan = interleavePlannerCandidateFamilies(
			candidates, phaseCoverage, parsed.search.evaluationBudget, progressiveCandidateForExact)
		phaseCoverage.retainedCandidates = #candidates
	end
	phaseCoverage.rankedCandidates = #candidates
	for _, candidate in ipairs(surrogateInputs) do candidate.surrogateFeatures = nil end
	surrogateInputs = nil
	local learningRankerCoverage = {
		status = rankingStatus,
		loadStatus = surrogateLoadStatus,
		active = rankingStatus == "ranked",
		rankerType = parsed.search.routePlannerRunSpec and "external_hetero_gatv2" or "local_mlp_surrogate",
		objectiveMetric = surrogate.model and surrogate.model.objectiveMetric or nil,
	}
	zoneCoverage.generatedCombinedCandidates = 0
	for _, candidate in ipairs(candidates) do
		if candidate.hierarchicalCombination then
			zoneCoverage.generatedCombinedCandidates = zoneCoverage.generatedCombinedCandidates + 1
		end
	end
	local calcs = require("Modules.Calcs")
	local proxyOk, evalBuild, resetGroups, baseItemsTab, scenarioDetails = pcall(createBuildProxy, build,
		parsed.scenarioProfile, targetSkill, parsed.scenarioEnemyPreset, parsed.scenarioEnemyLevel)
	if not proxyOk then
		return { status = "invalid_inputs", message = tostring(evalBuild) }
	end
	local calcFunc = calcs.getMiscCalculator(evalBuild, scenario.CalculationOverride(parsed.scenarioProfile))
	local baseConfigTab = evalBuild.configTab
	local feasibleBest, failureBest, exactFailureBest
	local searchBaseline
	local paretoFront = { }
	local exactNearMisses = { }
	local evaluationCount = 0
	local archiveGateRepairBudget = math.min(24, math.floor((tonumber(parsed.search.evaluationBudget) or 0) * 0.05))
	archivedRouteCoverage.adaptiveGateRepairBudget = archiveGateRepairBudget
	local archiveGateRepairScheduled = 0
	local adaptiveGateRepairQueue = { }
	-- Keep the complete structural count for proposal-cap accounting even when
	-- only a bounded exact-evaluation queue remains resident in memory.
	local uniqueCandidateProposalCount = math.max(#candidates,
		tonumber(phaseCoverage.proposalBudgetRetainedCandidates) or 0)
	local function candidateAttemptTotal()
		return uniqueCandidateProposalCount + archiveGateRepairScheduled
	end
	local seenCandidateHashes = { }
	for _, candidate in ipairs(candidates) do
		if type(candidate.canonicalHash) == "string" then seenCandidateHashes[candidate.canonicalHash] = true end
	end
	local function enqueueArchivedGateRepairs(sourceCandidate, evaluation, sourceIndex)
		if not parsed.search.routePlannerRunSpec or not phase.combined
			or not sourceCandidate or sourceCandidate.archivedRoutePattern ~= true
			or sourceCandidate.archiveGateRepairAttempted == true
			or archiveGateRepairScheduled >= archiveGateRepairBudget
			or not proposalPreparation.identityContextHash then
			return 0
		end
		local remaining = archiveGateRepairBudget - archiveGateRepairScheduled
		local repairCandidates, repairCoverage = GearRepair.BuildArchivedGateRepairCandidates(
			sourceCandidate, evaluation, parsed, equipmentCandidates, build, math.min(2, remaining),
			syntheticGearCandidates)
		if not archivedRouteCoverage.adaptiveGateRepairInputSample then
			archivedRouteCoverage.adaptiveGateRepairInputSample = {
				equipmentCandidates = repairCoverage.inputEquipmentCandidateCount or 0,
				inventoryFlagCandidates = repairCoverage.inventorySearchFlagCandidateCount or 0,
				syntheticCandidates = repairCoverage.inputSyntheticCandidateCount or 0,
				syntheticFlagCandidates = repairCoverage.syntheticSearchFlagCandidateCount or 0,
				syntheticSingleItemCandidates = repairCoverage.syntheticSingleItemCandidateCount or 0,
				syntheticPortfolioCandidates = repairCoverage.syntheticPortfolioCandidateCount or 0,
				syntheticRejectedShapeCandidates = repairCoverage.syntheticRejectedShapeCandidateCount or 0,
				syntheticPairFlagCandidates = repairCoverage.syntheticPairFlagCandidateCount or 0,
				syntheticTripleFlagCandidates = repairCoverage.syntheticTripleFlagCandidateCount or 0,
				syntheticGeneratedItemCountDistribution = repairCoverage.syntheticGeneratedItemCountDistribution or { },
				repairPoolAfterFlaskFilter = repairCoverage.repairPoolAfterFlaskFilterCount or 0,
				flaskCandidatesRejected = repairCoverage.flaskCandidatesRejected or 0,
			}
		end
		archivedRouteCoverage.adaptiveGateRepairSources = archivedRouteCoverage.adaptiveGateRepairSources + 1
		if repairCoverage.active == true then
			archivedRouteCoverage.adaptiveGateRepairActionableSources = archivedRouteCoverage.adaptiveGateRepairActionableSources + 1
		end
		archivedRouteCoverage.adaptiveGateRepairExactViolationRows = archivedRouteCoverage.adaptiveGateRepairExactViolationRows
			+ (tonumber(repairCoverage.exactViolationCount) or 0)
		archivedRouteCoverage.adaptiveGateRepairNeedRows = archivedRouteCoverage.adaptiveGateRepairNeedRows
			+ #(repairCoverage.needs or { })
		archivedRouteCoverage.adaptiveGateRepairInventoryCandidates = archivedRouteCoverage.adaptiveGateRepairInventoryCandidates
			+ (tonumber(repairCoverage.inventoryMutationCandidateCount) or 0)
		archivedRouteCoverage.adaptiveGateRepairSyntheticCandidates = archivedRouteCoverage.adaptiveGateRepairSyntheticCandidates
			+ (tonumber(repairCoverage.syntheticMutationCandidateCount) or 0)
		archivedRouteCoverage.adaptiveGateRepairRankedCandidates = archivedRouteCoverage.adaptiveGateRepairRankedCandidates
			+ (tonumber(repairCoverage.availableItemCandidates) or 0)
		archivedRouteCoverage.adaptiveGateRepairGeneratedBeforeDeduplication = archivedRouteCoverage.adaptiveGateRepairGeneratedBeforeDeduplication
			+ (tonumber(repairCoverage.generatedCandidates) or 0)
		local repairStatus = tostring(repairCoverage.status or "unknown")
		archivedRouteCoverage.adaptiveGateRepairStatuses[repairStatus] =
			(tonumber(archivedRouteCoverage.adaptiveGateRepairStatuses[repairStatus]) or 0) + 1
		archivedRouteCoverage.adaptiveGateRepairStructuralRejections =
			archivedRouteCoverage.adaptiveGateRepairStructuralRejections + (repairCoverage.structuralRejections or 0)
		for reason, count in pairs(repairCoverage.structuralRejectionReasons or { }) do
			archivedRouteCoverage.adaptiveGateRepairStructuralRejectionReasons[reason] =
				(archivedRouteCoverage.adaptiveGateRepairStructuralRejectionReasons[reason] or 0) + (tonumber(count) or 0)
		end
		local added = 0
		for _, repairCandidate in ipairs(repairCandidates) do
			if archiveGateRepairScheduled >= archiveGateRepairBudget then break end
			if candidateAttemptTotal() >= proposalBudget then
				archivedRouteCoverage.adaptiveGateRepairProposalCapRejections =
					archivedRouteCoverage.adaptiveGateRepairProposalCapRejections + 1
				break
			end
			local hash, hashError = CandidateIdentity.HashCandidate(proposalPreparation.identityContextHash, repairCandidate)
			if not hash then
				phaseCoverage.canonicalizationFallbacks = (phaseCoverage.canonicalizationFallbacks or 0) + 1
				local errorText = tostring(hashError or "Archive repair identity unavailable"):sub(1, 200)
				phaseCoverage.canonicalizationContextError = errorText
				archivedRouteCoverage.adaptiveGateRepairCanonicalizationFallbacks =
					archivedRouteCoverage.adaptiveGateRepairCanonicalizationFallbacks + 1
				archivedRouteCoverage.adaptiveGateRepairCanonicalizationContextError = errorText
				repairCandidate.canonicalizationError = errorText
				-- Preserve the bounded exact proposal without claiming semantic
				-- deduplication when inherited native route metadata contains a cycle.
				hash = CandidateIdentity.UniqueFallbackHash(proposalPreparation.identityContextHash,
					tostring(sourceIndex) .. ":" .. tostring(added + 1))
			end
			if not hash then
				phaseCoverage.canonicalizationContextError = "Archive repair fallback identity unavailable"
			elseif seenCandidateHashes[hash] then
				archivedRouteCoverage.adaptiveGateRepairDuplicateCandidates =
					archivedRouteCoverage.adaptiveGateRepairDuplicateCandidates + 1
			else
				seenCandidateHashes[hash] = true
				repairCandidate.canonicalHash = hash
				repairCandidate.generationPhase = phase.generation
				repairCandidate.requiresSocketedMainSkill = requireSocketedMainSkill == true
				adaptiveGateRepairQueue[#adaptiveGateRepairQueue + 1] = repairCandidate
				added = added + 1
				archiveGateRepairScheduled = archiveGateRepairScheduled + 1
				archivedRouteCoverage.adaptiveGateRepairGenerated =
					archivedRouteCoverage.adaptiveGateRepairGenerated + 1
				archivedRouteCoverage.adaptiveGateRepairRetained =
					archivedRouteCoverage.adaptiveGateRepairRetained + 1
				archivedRouteCoverage.generatedComposedCandidates =
					archivedRouteCoverage.generatedComposedCandidates + 1
				archivedRouteCoverage.retainedComposedCandidates =
					archivedRouteCoverage.retainedComposedCandidates + 1
				phaseCoverage.uniqueCandidates = (phaseCoverage.uniqueCandidates or 0) + 1
				phaseCoverage.retainedCandidates = (phaseCoverage.exactQueueRetainedCandidates or #candidates)
					+ archiveGateRepairScheduled
				phaseCoverage.proposalFamilyCountsAfter = phaseCoverage.proposalFamilyCountsAfter or { }
				phaseCoverage.proposalFamilyCountsAfter.combined =
					(phaseCoverage.proposalFamilyCountsAfter.combined or 0) + 1
				if type(phaseCoverage.exactEvaluationPlan) == "table" then
					phaseCoverage.exactEvaluationPlan.adaptiveGateRepairCandidates =
						(phaseCoverage.exactEvaluationPlan.adaptiveGateRepairCandidates or 0) + 1
				end
			end
		end
		return added
	end
	local pendingPathExperiences = { }
	local nextPathMemoryRetry = 0
	local MAX_PENDING_PATH_EXPERIENCES = 64
	local function flushPathExperiences(force)
		if control.recordPathLearning == false then return end
		if #pendingPathExperiences == 0 then return end
		if not force and pathLearningCoverage.exactObservations < nextPathMemoryRetry then return end
		local appended = PathExperience.AppendBatch(experienceState, pendingPathExperiences,
			type(MakeDir) == "function" and MakeDir or nil)
		if appended then
			pathLearningCoverage.storedThisRun = pathLearningCoverage.storedThisRun + (appended.stored or 0)
			pathLearningCoverage.duplicatesThisRun = pathLearningCoverage.duplicatesThisRun + (appended.duplicates or 0)
			pathLearningCoverage.storageStatus = appended.status or pathLearningCoverage.storageStatus
			if appended.error then pathLearningCoverage.storageError = appended.error end
			if not appended.error and (appended.stored or 0) + (appended.duplicates or 0) >= #pendingPathExperiences then
				pendingPathExperiences = { }
				nextPathMemoryRetry = 0
			else
				nextPathMemoryRetry = pathLearningCoverage.exactObservations + 32
			end
		end
	end
	job.flushPathLearning = function()
		flushPathExperiences(true)
		return pathLearningCoverage
	end
	local nodePotentialResults = { }
	local nodePotentialBaselineMetrics
	local nodePotentialExactRouteEvaluations = 0
	local function recordNodePotentialRoute(candidate, spec, metrics, feasible, violations, exactCalculated, reason)
		local routeNodes = { }
		for _, nodeId in ipairs(candidate.nodeIds or { }) do
			local node = build.spec.nodes[nodeId]
			routeNodes[#routeNodes + 1] = { id = nodeId, name = tostring(node and (node.dn or node.name) or ("Passive " .. tostring(nodeId))) }
		end
		nodePotentialResults[#nodePotentialResults + 1] = {
			targetId = candidate.targetId,
			label = tostring(candidate.label or "Passive route"),
			island = candidate.island,
			nodeIds = { unpack(candidate.nodeIds or { }) },
			routeNodes = routeNodes,
			pointsAdded = countAddedMainPoints(spec or build.spec, candidate.nodeIds),
			metrics = shallowCopy(metrics),
			feasible = feasible == true,
			exactCalculated = exactCalculated == true,
			reason = reason,
			violations = violations or { },
		}
	end
	local candidateArrayIndex = 1
	local candidateAttemptIndex = 0
	if parsed.search.routePlannerRunSpec then
		-- Yield once after structural generation so the UI can start the exact-
		-- evaluation deadline before the first native calculation is performed.
		RoutePlannerProgress.Merge(job, {
			phase = "Exact calculations",
			processed = 0,
			total = math.min(candidateAttemptTotal(), parsed.search.evaluationBudget),
			candidatesExamined = 0,
			candidateAttemptTotal = candidateAttemptTotal(),
			exactEvaluations = 0,
			exactEvaluationBudget = parsed.search.evaluationBudget,
		}, phaseCoverage)
		coroutine.yield(job.progress)
	end
	while candidateArrayIndex <= #candidates or #adaptiveGateRepairQueue > 0 do
		local candidate
		if #adaptiveGateRepairQueue > 0 then
			candidate = table.remove(adaptiveGateRepairQueue, 1)
		else
			candidate = candidates[candidateArrayIndex]
			candidateArrayIndex = candidateArrayIndex + 1
		end
		local exactEvaluationMetadata = CandidateIdentity.CaptureExactEvaluationMetadata(candidate)
		candidateAttemptIndex = candidateAttemptIndex + 1
		local index = candidateAttemptIndex
		if control.cancelled then
			flushPathExperiences(true)
			if parsed.search.routePlannerRunSpec then
				return buildInterruptedSearchResult({
					reason = control.cancelReason,
					feasibleBest = feasibleBest,
					failureBest = failureBest,
					exactFailureBest = exactFailureBest,
					paretoFront = paretoFront,
					exactNearMisses = exactNearMisses,
					evaluations = evaluationCount,
					generationPhase = phase.generation,
					searchBaseline = searchBaseline,
					objectiveMetric = parsed.objective,
					ranking = { priority = parsed.preferences and parsed.preferences.rankingPriority or "ObjectiveFirst",
						primaryMetric = Ranking.OrderingMetrics(parsed.objective, parsed.preferences)[1],
						secondaryMetric = Ranking.OrderingMetrics(parsed.objective, parsed.preferences)[2],
						tertiaryMetric = Ranking.OrderingMetrics(parsed.objective, parsed.preferences)[3] },
					searchCoverage = { phase = phaseCoverage, ascendancies = ascendancyCoverage, anoints = anointCoverage,
						jewels = jewelCoverage, clusters = clusterCoverage, equipment = equipmentCoverage,
						requirementRepair = requirementRepairCoverage, catalysts = catalystCoverage,
						syntheticGear = syntheticGearCoverage, configuration = configurationCoverage,
						topology = topologyCoverage, zones = zoneCoverage, learningRanker = learningRankerCoverage,
						pathLearning = pathLearningCoverage },
					scenarioProfile = parsed.scenarioProfile or "Current",
					scenario = feasibleBest and feasibleBest.evaluation and feasibleBest.evaluation.scenario
						or (failureBest and failureBest.scenario) or scenarioDetails,
					version = Version.Snapshot(sourceBuild),
					sourceSignature = sourceSignature,
				})
			end
			return { status = "cancelled", candidate = nil, evaluations = evaluationCount }
		end
		if sourceSignature ~= candidateModule.BuildSignature(sourceBuild) then
			flushPathExperiences(true)
			return { status = "stale_build", candidate = nil, evaluations = evaluationCount, message = "The build changed during optimization; run the search again" }
		end
		-- The selected budget limits exact native PoB calculations. Candidate
		-- reconstruction and structural tree rejections do not consume that budget;
		-- keep scanning the ranked queue until the exact cap or time/cancel limit.
		if evaluationCount >= parsed.search.evaluationBudget then break end
		phaseCoverage.candidateAttempts = index
		local proxyOk, specProxy, candidateItemsTab = pcall(createSpecProxy, evalBuild, build.spec, candidate)
		if not proxyOk then
			phaseCoverage.candidateReconstructionFailures = phaseCoverage.candidateReconstructionFailures + 1
			if candidate.gearVariant and candidate.gearVariant.syntheticSearch then
				syntheticGearCoverage.structuralRejections = (syntheticGearCoverage.structuralRejections or 0) + 1
				syntheticGearCoverage.lastStructuralRejection = {
					candidate = tostring(candidate.label or "Synthetic gear candidate"):sub(1, 160),
					reason = tostring(specProxy):sub(1, 240),
				}
			end
			local reconstructionFailure = {
				feasible = false,
				violations = { { key = "candidate_reconstruction", label = "Candidate reconstruction", reason = tostring(specProxy), deficit = 1 } },
				normalizedDeficit = math.huge,
				metrics = { },
			}
			candidate.feasible = false
			candidate.evaluation = reconstructionFailure
			failureBest = selectBetterFailure(reconstructionFailure, failureBest)
			RoutePlannerProgress.Merge(job, {
				phase = "Candidate reconstruction", processed = index, total = candidateAttemptTotal(),
				current = tostring(specProxy), candidatesExamined = index,
				candidateAttemptTotal = candidateAttemptTotal(), exactEvaluations = evaluationCount,
				exactEvaluationBudget = parsed.search.evaluationBudget,
			}, phaseCoverage)
			coroutine.yield(job.progress)
		else
		if candidateItemsTab then evalBuild.itemsTab = candidateItemsTab end
		resetGroups(candidateRunHelpers.getCandidateGemVariants(candidate), candidate.gearVariant and candidate.gearVariant.socketBinding)
		local candidatePointCount
		local candidateAscendancyPointCount, candidateSecondaryAscendancyPointCount
		if specProxy then
			candidatePointCount, candidateAscendancyPointCount, candidateSecondaryAscendancyPointCount = specProxy:CountAllocNodes()
		else
			candidatePointCount, candidateAscendancyPointCount, candidateSecondaryAscendancyPointCount = build.spec:CountAllocNodes()
		end
		local candidateLevel = build.characterLevel or 1
		if build.characterLevelAutoMode and build.GetEstimatedLevelForPoints then
			candidateLevel = build:GetEstimatedLevelForPoints(candidatePointCount, extraPoints)
		end
		local branchValid, branchError, candidateConstraintViolation = treeSearch.ValidateCandidate(
			build.spec, candidate.nodeIds, parsed, candidateRegionMap, candidate.removeNodeIds, specProxy, topologyCoverage, candidateLevel)
		-- A locked ascendancy needs a legal allocated route in the candidate
		-- tree. Pure gem/equipment mutations inherit an already allocated route
		-- from the source build and therefore do not carry ascendancyPointCost.
		local allocatedAscendancyPoints = (candidateAscendancyPointCount or 0)
			+ (candidateSecondaryAscendancyPointCount or 0)
		if branchValid and phase.lockedAscendancySearch and allocatedAscendancyPoints <= 0 then
			branchValid = false
			branchError = "The selected ascendancy must include an allocated native ascendancy route"
		end
		local addedNodeIds = specProxy and specProxy.optimizerAddedNodeIds or candidate.nodeIds or { }
		local addedCount = countAddedMainPoints(specProxy or build.spec, addedNodeIds)
		if branchValid and addedCount > maxAddedPoints then
			branchValid = false
			branchError = string.format("Candidate adds %d passive points, above the selected limit of %d", addedCount, maxAddedPoints)
		end
		if branchValid and candidatePointCount > parsed.search.maxTotalPoints then
			branchValid = false
			branchError = string.format("Candidate uses %d passive points, above the strict optimizer cap of %d", candidatePointCount, parsed.search.maxTotalPoints)
			candidate.pointCapViolation = {
				key = "passive_point_cap",
				label = "Strict passive-point cap",
				actual = candidatePointCount,
				required = parsed.search.maxTotalPoints,
				deficit = candidatePointCount - parsed.search.maxTotalPoints,
				reason = "Above strict maximum",
			}
		end
		local candidateLevelPointLimit = getPassivePointLimit(build, candidateLevel, extraPoints)
		if branchValid and candidatePointCount > candidateLevelPointLimit then
			branchValid = false
			branchError = string.format("Candidate uses %d passive points, above PoB's level %d limit of %d", candidatePointCount, candidateLevel, candidateLevelPointLimit)
			candidate.pointCapViolation = {
				key = "passive_point_limit",
				label = "Passive points available at selected level",
				actual = candidatePointCount,
				required = candidateLevelPointLimit,
				deficit = candidatePointCount - candidateLevelPointLimit,
				reason = "Above PoB's native level and act-quest point limit",
			}
		end
		if branchValid and candidatePointCount > totalPointLimit then
			branchValid = false
			branchError = string.format("Candidate uses %d passive points, above PoB's current limit of %d", candidatePointCount, totalPointLimit)
		end
		if not branchValid then
			phaseCoverage.structuralCandidateRejections = phaseCoverage.structuralCandidateRejections + 1
			if candidate.archivedRoutePattern then
				archivedRouteCoverage.structuralRejected = (archivedRouteCoverage.structuralRejected or 0) + 1
				if candidate.archivedRouteComposition == true then
					archivedRouteCoverage.structuralComposedRejected = (archivedRouteCoverage.structuralComposedRejected or 0) + 1
				end
			end
			if #(candidate.nodeIds or { }) > 0 or candidate.classVariant or candidate.ascendancyVariant then
				phaseCoverage.structuralTreeRejections = phaseCoverage.structuralTreeRejections + 1
				if candidate.progressiveRouteBundle then
					phaseCoverage.structuralProgressiveTreeBundleRejections = phaseCoverage.structuralProgressiveTreeBundleRejections + 1
					if not phaseCoverage.firstProgressiveTreeStructuralRejection then
						phaseCoverage.firstProgressiveTreeStructuralRejection = {
							label = tostring(candidate.label or "Progressive passive routes"):sub(1, 120),
							reason = tostring(branchError or "Rejected by passive-tree validator"):sub(1, 240),
							mainPoints = candidatePointCount,
							pointLimit = candidateLevelPointLimit,
						}
					end
				end
			end
			if candidate.gearVariant and candidate.gearVariant.syntheticSearch then
				syntheticGearCoverage.structuralRejections = (syntheticGearCoverage.structuralRejections or 0) + 1
				syntheticGearCoverage.lastStructuralRejection = {
					candidate = tostring(candidate.label or "Synthetic gear candidate"):sub(1, 160),
					reason = tostring(branchError or "Candidate tree was rejected"):sub(1, 240),
					mainAscendancyPoints = candidateAscendancyPointCount or 0,
					secondaryAscendancyPoints = candidateSecondaryAscendancyPointCount or 0,
					selectedAscendancy = tostring(specProxy and specProxy.curAscendClassName or build.spec.curAscendClassName or "None"):sub(1, 80),
				}
			end
			local treeViolation = candidate.pointCapViolation or candidateConstraintViolation or {
				key = "branch_or_point_limit", label = "Passive tree constraint", reason = branchError, deficit = 1,
			}
			candidate.pointCapViolation = nil
			local branchFailure = {
				feasible = false,
				violations = { treeViolation },
				normalizedDeficit = treeViolation.deficit and treeViolation.required and treeViolation.deficit / math.max(treeViolation.required, 1) or 1,
				metrics = { },
				passivePointsUsed = candidatePointCount,
				ascendancyPointsUsed = candidateAscendancyPointCount or 0,
				secondaryAscendancyPointsUsed = candidateSecondaryAscendancyPointCount or 0,
				strictPointCap = parsed.search.maxTotalPoints,
				selectedBaseClassName = specProxy and specProxy.curClassName or build.spec.curClassName,
				selectedAscendancyName = specProxy and specProxy.curAscendClassName or build.spec.curAscendClassName,
				selectedSecondaryAscendancyName = specProxy and specProxy.curSecondaryAscendClassName or build.spec.curSecondaryAscendClassName,
				candidateLabel = candidate.label,
				characterLevel = candidateLevel,
				ascendancyPointBudget = inputsModule.AscendancyPointBudgetAtLevel(
					candidateLevel, parsed.search.ascendancyPointBudget),
			}
			candidate.feasible = false
			candidate.evaluation = branchFailure
			failureBest = selectBetterFailure(branchFailure, failureBest)
			if phase.nodePotentialAnalysis and not candidate.isBaselineCandidate then
				recordNodePotentialRoute(candidate, specProxy or build.spec, { }, false, { treeViolation }, false, branchError)
			end
			if parsed.search.routePlannerRunSpec then
				RoutePlannerProgress.Merge(job, {
					phase = "Tree validation",
					processed = evaluationCount,
					total = math.min(candidateAttemptTotal(), parsed.search.evaluationBudget),
					current = branchError,
					candidatesExamined = index,
					candidateAttemptTotal = candidateAttemptTotal(),
					exactEvaluations = evaluationCount,
					exactEvaluationBudget = parsed.search.evaluationBudget,
				}, phaseCoverage)
			else
				job.progress = { phase = "Tree validation", processed = evaluationCount,
					total = math.min(candidateAttemptTotal(), parsed.search.evaluationBudget), current = branchError,
					candidatesExamined = index, candidateAttemptTotal = candidateAttemptTotal(),
					exactEvaluations = evaluationCount, exactEvaluationBudget = parsed.search.evaluationBudget }
			end
			coroutine.yield(job.progress)
		else
		local function setCandidateLevel(extra)
			if build.characterLevelAutoMode and build.GetEstimatedLevelForPoints then
				evalBuild.characterLevel = build:GetEstimatedLevelForPoints(candidatePointCount, extra)
			else
				evalBuild.characterLevel = build.characterLevel
			end
		end
		setCandidateLevel(extraPoints)
		local override = scenario.CalculationOverride(parsed.scenarioProfile)
		override.spec = specProxy
		override.returnEnv = true
		local candidateConfigTab = baseConfigTab
		if candidate.configurationVariant then
			local clonedConfigTab, configurationCloneError = scenario.CloneConfiguration(
				baseConfigTab, evalBuild, candidate.configurationVariant, nil, nil, parsed.scenarioEnemyPreset)
			if not clonedConfigTab then
				return { status = "error", candidate = nil, message = configurationCloneError or "PoB could not isolate the configuration candidate", evaluations = evaluationCount }
			end
			candidateConfigTab = clonedConfigTab
			evalBuild.configTab = candidateConfigTab
		end
		local autoLevelAdjusted = false
		local function calculateExactCandidate()
			-- CalcPerform can restore the proxy's item tab after a native pass.
			-- Reapply the same candidate-local item/config state before every pass,
			-- including the second calculation used to reconcile PoB-granted skills.
			evalBuild.itemsTab = candidateItemsTab or baseItemsTab
			evalBuild.configTab = candidateConfigTab
			local calcOk, calcOutput, calcEnv = pcall(calcFunc, override, true)
			local extra = calcOk and exactExtraPoints(calcOutput, calcEnv) or nil
			if calcOk and not autoLevelAdjusted and build.characterLevelAutoMode
				and type(extra) == "number" and extra == extra and extra ~= math.huge and extra ~= -math.huge
				and extra ~= extraPoints then
				setCandidateLevel(extra)
				autoLevelAdjusted = true
				evalBuild.itemsTab = candidateItemsTab or baseItemsTab
				evalBuild.configTab = candidateConfigTab
				calcOk, calcOutput, calcEnv = pcall(calcFunc, override, true)
				extra = calcOk and exactExtraPoints(calcOutput, calcEnv) or nil
			end
			return calcOk, calcOutput, calcEnv, extra
		end
		local ok, output, env, candidateExtraPoints = calculateExactCandidate()
		local grantedSkillReconciliation = { status = "unchanged", added = 0, updated = 0, disabled = 0, explodeUpdated = false }
		local function summarizeGrantSync(sync)
			if type(sync) ~= "table" then return "missing" end
			return table.concat({
				"changed=" .. tostring(sync.changed == true),
				"added=" .. tostring(tonumber(sync.added) or 0),
				"updated=" .. tostring(tonumber(sync.updated) or 0),
				"disabled=" .. tostring(tonumber(sync.disabled) or 0),
				"explode=" .. tostring(sync.explodeUpdated == true),
				"groups=" .. table.concat(sync.changedGroupSummaries or { }, ","),
			}, ";")
		end
		if ok then
			local syncOk, syncResult, syncError = pcall(SkillCatalog.ReconcileGrantedSkillGroups, evalBuild, env)
			if not syncOk or type(syncResult) ~= "table" then
				return { status = "error", candidate = nil,
					message = "PoB could not reconcile candidate granted skills: "
						.. tostring(syncOk and syncError or syncResult), evaluations = evaluationCount }
			end
			grantedSkillReconciliation = syncResult
			if syncResult.changed then
				ok, output, env, candidateExtraPoints = calculateExactCandidate()
				if not ok then
					return { status = "error", candidate = nil,
						message = "PoB exact recalculation failed after granted-skill reconciliation: " .. tostring(output),
						evaluations = evaluationCount }
				end
				local stableOk, stableResult, stableError = pcall(SkillCatalog.ReconcileGrantedSkillGroups, evalBuild, env)
				if not stableOk or type(stableResult) ~= "table" or stableResult.changed then
					return { status = "error", candidate = nil,
						message = "PoB granted-skill groups did not stabilize after exact candidate recalculation: "
							.. tostring(stableOk and (stableError or "candidate grant set changed repeatedly") or stableResult)
							.. " (candidate=" .. tostring(candidate.label or "unnamed"):sub(1, 120)
							.. "; baseline=" .. tostring(candidate.isBaselineCandidate == true)
							.. "; pass1=" .. summarizeGrantSync(syncResult)
							.. "; pass2=" .. summarizeGrantSync(stableResult) .. ")",
						evaluations = evaluationCount }
				end
			end
		end
		evalBuild.configTab = baseConfigTab
		evalBuild.itemsTab = baseItemsTab
		if not ok then
			return { status = "error", candidate = nil, message = tostring(output), evaluations = evaluationCount }
		end
		if not isFinite(candidateExtraPoints) then
			return { status = "error", candidate = nil, message = "PoB did not expose exact passive ExtraPoints for this candidate", evaluations = evaluationCount }
		end
		local selectedMainSkillValid, selectedMainSkillError = verifySelectedMainSkill(env, targetSkill)
		local exactExtraPoints = candidateExtraPoints
		local exactPointLimit = getPassivePointLimit(build, evalBuild.characterLevel,
			isFinite(exactExtraPoints) and exactExtraPoints or extraPoints)
		local evaluation
		if candidatePointCount > exactPointLimit then
			evaluation = {
				metrics = candidateModule.CopyMetrics(output, inputsModule.metricDefinitions,
					env and env.player and env.player.mainSkill),
				objective = parsed.objective,
				feasible = false,
				normalizedDeficit = (candidatePointCount - exactPointLimit) / math.max(exactPointLimit, 1),
				violations = { {
					key = "passive_point_limit", label = "Passive point limit", actual = candidatePointCount,
					required = exactPointLimit, deficit = candidatePointCount - exactPointLimit,
					reason = "Candidate exceeds PoB's exact level and act-quest passive-point budget",
				} },
			}
		else
			-- CalcPerform may restore evalBuild.itemsTab to its baseline proxy after
			-- the exact calculation completes. Keep the candidate-local snapshot
			-- captured before calculation so price coverage sees the same gear that
			-- produced the returned metrics (especially synthetic rares).
			evaluation = captureEvaluation(output, env, parsed, candidateItemsTab or baseItemsTab)
		end
		evaluation.exactCalculated = true
		evaluation.grantedSkillReconciliation = {
			status = grantedSkillReconciliation.changed and "recalculated" or grantedSkillReconciliation.status,
			added = tonumber(grantedSkillReconciliation.added) or 0,
			updated = tonumber(grantedSkillReconciliation.updated) or 0,
			disabled = tonumber(grantedSkillReconciliation.disabled) or 0,
			explodeUpdated = grantedSkillReconciliation.explodeUpdated == true,
			changedGroupCount = tonumber(grantedSkillReconciliation.changedGroupCount) or 0,
		}
		local evaluationItemsTab = candidateItemsTab or baseItemsTab
		if parsed.search.routePlannerRunSpec then
			evaluation.routePlannerSearchMode = parsed.search.routePlannerRunSpec.searchMode
			local activeSocketGroupsValid, activeSocketProof
			if parsed.search.routePlannerRunSpec.searchMode == "SINGLE_SKILL_ONLY" then
				activeSocketGroupsValid, activeSocketProof = SkillCatalog.ValidatePlannerSocketGroups(
					build, evalBuild, targetSkill and targetSkill.groupIndex, evaluationItemsTab)
			else
				activeSocketGroupsValid, activeSocketProof = SkillCatalog.ValidateEnabledSocketGroups(
					evalBuild, evaluationItemsTab, nil)
			end
			evaluation.routePlannerSocketProofs = activeSocketProof
			if not activeSocketGroupsValid then
				for _, violation in ipairs(activeSocketProof.violations or { }) do
					-- The selected Main Skill has its own strict binding check below;
					-- report secondary groups here without duplicating that violation.
					if not targetSkill or tonumber(violation.groupIndex) ~= tonumber(targetSkill.groupIndex) then
						evaluation.feasible = false
						evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + (violation.deficit or 1)
						evaluation.violations = evaluation.violations or { }
						evaluation.violations[#evaluation.violations + 1] = violation
					end
				end
			end
		end
		evaluation.skillVariantSocketProofs = SkillCatalog.ValidateChangedGemGroupSockets(
			candidate, evalBuild, evaluationItemsTab)
		local unlinkedCheckpointProof
		if evaluation.skillVariantSocketProofs.status ~= "pass" then
			unlinkedCheckpointProof = unlinkedMainSkillCheckpoint(candidate, targetSkill, parsed, evalBuild)
			if unlinkedCheckpointProof then
				evaluation.skillVariantSocketProofs = unlinkedCheckpointProof
			else
			evaluation.feasible = false
			evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + 1
			evaluation.violations = evaluation.violations or { }
			local firstViolation = evaluation.skillVariantSocketProofs.violations[1]
			evaluation.violations[#evaluation.violations + 1] = {
				key = "gem_variant_socket_link",
				label = "Native socket/link for changed gem group",
				groupIndex = firstViolation and firstViolation.groupIndex,
				reason = firstViolation and firstViolation.reason
					or "PoB did not certify every changed gem group against native item sockets",
				deficit = 1,
			}
			end
		end
		if requireSocketedMainSkill then
			local socketValid, socketResult = SkillCatalog.ValidateSocketGroup(
				evalBuild, targetSkill.groupIndex, evaluationItemsTab)
			if socketValid and (type(socketResult) ~= "table" or socketResult.status ~= "linked") then
				socketValid = false
				socketResult = "Equipment and Combined require a manually socketed Main Skill linked to an active PoB item"
			end
			local binding = candidate.gearVariant and candidate.gearVariant.socketBinding
			if socketValid and binding then
				local itemSet = require("Modules.Optimizer.Equipment").ActiveItemSet(evaluationItemsTab)
				local selected = itemSet and itemSet[binding.slotName]
				if binding.groupIndex ~= targetSkill.groupIndex or not selected
					or tonumber(selected.selItemId) ~= tonumber(binding.itemId) then
					socketValid = false
					socketResult = "The generated Main Skill socket binding does not match the candidate's active PoB item set"
				end
			end
			if not socketValid then
				if candidate.gearVariant and candidate.gearVariant.syntheticSearch then
					syntheticGearCoverage.lastSocketRejection = {
						candidate = tostring(candidate.label or "Synthetic gear candidate"):sub(1, 160),
						reason = tostring(socketResult or "Native socket validation failed"):sub(1, 240),
					}
				end
				evaluation.feasible = false
				evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + 1
				evaluation.violations = evaluation.violations or { }
				evaluation.violations[#evaluation.violations + 1] = {
					key = "skill_socket_link",
					label = "Native Main Skill socket and link",
					reason = type(socketResult) == "string" and socketResult
						or "The selected Main Skill is not fully mapped to one compatible native PoB link",
					deficit = 1,
				}
			else
				evaluation.skillSocket = socketResult
			end
			if parsed.search.routePlannerRunSpec
				and parsed.search.routePlannerRunSpec.searchMode == "SINGLE_SKILL_ONLY"
				and parsed.objective == "CombinedDPS" then
				evaluation.skillGroupSockets = { status = "not_required", scope = "selected_main_skill_only", groups = { }, violations = { } }
			else
				local groupsValid, groupsProof = SkillCatalog.ValidateFullDPSSocketGroups(
					evalBuild, evaluationItemsTab)
				evaluation.skillGroupSockets = groupsProof
				for _, violation in ipairs(groupsProof.violations or { }) do
					evaluation.feasible = false
					evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + (violation.deficit or 1)
					evaluation.violations = evaluation.violations or { }
					evaluation.violations[#evaluation.violations + 1] = violation
				end
				if not groupsValid and #((groupsProof and groupsProof.violations) or { }) == 0 then
					evaluation.feasible = false
					evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + 1
					evaluation.violations = evaluation.violations or { }
					evaluation.violations[#evaluation.violations + 1] = {
						key = "skill_group_socket_link",
						label = "Full DPS skill group socket/link",
						reason = "PoB did not certify all enabled manual Full DPS skill groups",
						deficit = 1,
					}
				end
			end
		end
		if not selectedMainSkillValid then
			evaluation.feasible = false
			evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + math.huge
			evaluation.violations = evaluation.violations or { }
			evaluation.violations[#evaluation.violations + 1] = {
				key = "selected_main_skill_identity",
				label = "Selected Main Skill identity",
				reason = selectedMainSkillError or "PoB did not certify the selected gem/effect",
				deficit = math.huge,
			}
		end
		local supportVariantCount, supportAddCount = 0, 0
		for _, variant in ipairs(candidateRunHelpers.getCandidateGemVariants(candidate)) do
			if variant.kind == "support_swap" then supportVariantCount = supportVariantCount + 1 end
			if variant.kind == "support_add" then supportAddCount = supportAddCount + 1 end
		end
		if supportVariantCount > 0 or supportAddCount > 0 then
			if supportVariantCount > 0 then
				phaseCoverage.exactSupportSwapEvaluations = phaseCoverage.exactSupportSwapEvaluations + 1
				local row = phaseCoverage.supportPackages.swaps[supportVariantCount]
				if row then row.exact = row.exact + 1 end
			end
			if supportVariantCount > 1 then
				phaseCoverage.exactSupportCombinationEvaluations = phaseCoverage.exactSupportCombinationEvaluations + 1
			end
			if supportAddCount > 0 then
				phaseCoverage.exactSupportAddEvaluations = phaseCoverage.exactSupportAddEvaluations + 1
				local row = phaseCoverage.supportPackages.additions[supportAddCount]
				if row then row.exact = row.exact + 1 end
			end
			if supportAddCount > 1 then
				phaseCoverage.exactSupportAddCombinationEvaluations = phaseCoverage.exactSupportAddCombinationEvaluations + 1
			end
			local supportCheck = candidateRunHelpers.evaluateSupportSwap(candidate, evalBuild, env, evaluationItemsTab)
			evaluation.supportCompatibility = supportCheck
			if supportCheck.status == "valid" then
				if supportVariantCount > 0 then
					phaseCoverage.compatibleSupportSwapEvaluations = phaseCoverage.compatibleSupportSwapEvaluations + 1
					local row = phaseCoverage.supportPackages.swaps[supportVariantCount]
					if row then row.compatible = row.compatible + 1 end
				end
				if supportVariantCount > 1 then
					phaseCoverage.compatibleSupportCombinationEvaluations = phaseCoverage.compatibleSupportCombinationEvaluations + 1
				end
				if supportAddCount > 0 then
					phaseCoverage.compatibleSupportAddEvaluations = phaseCoverage.compatibleSupportAddEvaluations + 1
					local row = phaseCoverage.supportPackages.additions[supportAddCount]
					if row then row.compatible = row.compatible + 1 end
				end
				if supportAddCount > 1 then
					phaseCoverage.compatibleSupportAddCombinationEvaluations = phaseCoverage.compatibleSupportAddCombinationEvaluations + 1
				end
			else
				if supportVariantCount > 0 then
					phaseCoverage.rejectedSupportSwapEvaluations = phaseCoverage.rejectedSupportSwapEvaluations + 1
					local row = phaseCoverage.supportPackages.swaps[supportVariantCount]
					if row then row.rejected = row.rejected + 1 end
					if not phaseCoverage.firstSupportSwapRejection then
						phaseCoverage.firstSupportSwapRejection = shallowCopy(supportCheck)
					end
				end
				if supportAddCount > 0 then
					phaseCoverage.rejectedSupportAddEvaluations = phaseCoverage.rejectedSupportAddEvaluations + 1
					local row = phaseCoverage.supportPackages.additions[supportAddCount]
					if row then row.rejected = row.rejected + 1 end
					if not phaseCoverage.firstSupportAddRejection then
						phaseCoverage.firstSupportAddRejection = shallowCopy(supportCheck)
					end
				end
				evaluation.feasible = false
				evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + (supportCheck.status == "unsupported" and math.huge or 1)
				if not supportCheck.socketViolation then
					evaluation.violations = evaluation.violations or { }
					evaluation.violations[#evaluation.violations + 1] = {
						key = "support_compatibility",
						label = "Native support compatibility",
						reason = supportCheck.reason,
						deficit = supportCheck.status == "unsupported" and math.huge or 1,
					}
				end
			end
		end
		local anointVariants = candidate.anointVariants or (candidate.anointVariant and { candidate.anointVariant }) or { }
		for _, anointVariant in ipairs(anointVariants) do
			local anointNodeId = tonumber(anointVariant.nodeId)
			if not anointNodeId or not env or not env.grantedPassives or not env.grantedPassives[anointNodeId] then
				evaluation.feasible = false
				evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + 1
				evaluation.violations[#evaluation.violations + 1] = {
					key = "anoint_resolution",
					label = "Native anoint resolution",
					reason = "PoB's exact calculation did not resolve every requested GrantedPassive",
					deficit = 1,
				}
			end
		end
		evaluation.scenarioProfile = parsed.scenarioProfile or "Current"
		evaluation.scenario = shallowCopy(scenarioDetails)
		evaluation.scenario.configurationVariant = candidate.configurationVariant
			and configurationChoices.Label(candidate.configurationVariant)
			or scenarioDetails.configurationVariant
		evaluation.scenario.guardSkillActive = output.GuardSkillActive
		evaluation.scenario.guardBuffsDisabledByEngine = output.OptimizerGuardBuffsDisabled
		evaluation.scenario.suppressedGuardBuffs = output.OptimizerSuppressedGuardBuffs
		evaluation.scenario.enemyLevel = env and env.enemyLevel
		evaluation.scenario.currentShock = output.CurrentShock or 0
		evaluation.scenario.currentChill = output.CurrentChill or 0
		evaluation.scenario.chargeAudit = scenario.AuditCharges(
			output, scenarioDetails.preservedConditionalAssumptions, scenarioDetails.clearedChargeState)
		local chargeAuditValid, chargeAuditError = scenario.CheckChargeAudit(parsed.scenarioProfile, evaluation.scenario.chargeAudit)
		if not chargeAuditValid then
			evaluation.feasible = false
			evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + 1
			evaluation.violations = evaluation.violations or { }
			evaluation.violations[#evaluation.violations + 1] = {
				key = "unsupported_pinnacle_charge_uptime",
				label = "Pinnacle charge uptime",
				reason = chargeAuditError,
				deficit = 1,
			}
		end
		evaluation.scenario.shockAudit = scenario.AuditShock(output, scenarioDetails.preservedConditionalAssumptions)
		local flaskAudit = scenario.AuditFlasks(
			parsed.scenarioProfile or "Current", env, specProxy or build.spec, build.itemsTab)
		evaluation.scenario.flaskAudit = flaskAudit
		if not flaskAudit.certified then
			evaluation.feasible = false
			evaluation.normalizedDeficit = (evaluation.normalizedDeficit or 0) + 1
			evaluation.violations = evaluation.violations or { }
			evaluation.violations[#evaluation.violations + 1] = {
				key = "unsupported_pinnacle_flask_exception",
				label = "Pinnacle flask exception",
				reason = flaskAudit.reason,
				deficit = 1,
			}
		end
		evaluation.passivePointsUsed = candidatePointCount
		evaluation.extraPassivePoints = isFinite(exactExtraPoints) and exactExtraPoints or nil
		evaluation.ascendancyPointsUsed = candidateAscendancyPointCount or 0
		evaluation.secondaryAscendancyPointsUsed = candidateSecondaryAscendancyPointCount or 0
		evaluation.characterLevel = tonumber(evalBuild.characterLevel) or candidateLevel
		evaluation.ascendancyPointBudget = inputsModule.AscendancyPointBudgetAtLevel(
			evaluation.characterLevel, parsed.search.ascendancyPointBudget)
		local evaluatedSpec = specProxy or build.spec
		evaluation.selectedBaseClassName = evaluatedSpec.curClassName
		evaluation.selectedAscendancyName = evaluatedSpec.curAscendClassName
		evaluation.selectedSecondaryAscendancyName = evaluatedSpec.curSecondaryAscendClassName
		evaluation.passivePointLimit = exactPointLimit
		evaluation.strictPointCap = parsed.search.maxTotalPoints
		output, env, override = nil, nil, nil
		evaluationCount = evaluationCount + 1
		phaseCoverage.exactEvaluations = evaluationCount
		recordExactEvaluationFamily(phaseCoverage.exactEvaluationsByFamily, exactEvaluationMetadata.family)
		if exactEvaluationMetadata.archivedRoutePattern then
			archivedRouteCoverage.exactEvaluations = (archivedRouteCoverage.exactEvaluations or 0) + 1
			if evaluation.feasible then archivedRouteCoverage.exactFeasible = (archivedRouteCoverage.exactFeasible or 0) + 1 end
			if exactEvaluationMetadata.archivedRouteComposition then
				archivedRouteCoverage.exactComposedEvaluations = (archivedRouteCoverage.exactComposedEvaluations or 0) + 1
				if evaluation.feasible then
					archivedRouteCoverage.exactComposedFeasible = (archivedRouteCoverage.exactComposedFeasible or 0) + 1
				end
			else
				archivedRouteCoverage.exactDirectEvaluations = (archivedRouteCoverage.exactDirectEvaluations or 0) + 1
				if evaluation.feasible then
					archivedRouteCoverage.exactDirectFeasible = (archivedRouteCoverage.exactDirectFeasible or 0) + 1
				end
			end
		end
		if candidate.archiveGateRepairAttempted == true then
			archivedRouteCoverage.adaptiveGateRepairExactEvaluations =
				archivedRouteCoverage.adaptiveGateRepairExactEvaluations + 1
			if evaluation.feasible then
				archivedRouteCoverage.adaptiveGateRepairFeasible = archivedRouteCoverage.adaptiveGateRepairFeasible + 1
			end
			if #archivedRouteCoverage.adaptiveGateRepairExactPreview < archiveGateRepairBudget then
				local exactPreview = {
					label = tostring(candidate.label or "Archived gate repair"):sub(1, 180),
					feasible = evaluation.feasible == true,
					metrics = {
						Int = evaluation.metrics and evaluation.metrics.Int,
						ReqInt = evaluation.metrics and evaluation.metrics.ReqInt,
						Str = evaluation.metrics and evaluation.metrics.Str,
						ReqStr = evaluation.metrics and evaluation.metrics.ReqStr,
						Dex = evaluation.metrics and evaluation.metrics.Dex,
						ReqDex = evaluation.metrics and evaluation.metrics.ReqDex,
						CombinedDPS = evaluation.metrics and evaluation.metrics.CombinedDPS,
						TotalEHP = evaluation.metrics and evaluation.metrics.TotalEHP,
					},
					violations = { },
					items = { },
				}
				for violationIndex, violation in ipairs(evaluation.violations or { }) do
					if violationIndex > 8 then break end
					exactPreview.violations[#exactPreview.violations + 1] = {
						key = tostring(violation.key or violation.label or "exact_gate"),
						actual = violation.actual,
						required = violation.required,
						reason = tostring(violation.reason or violation.deficit or "Rejected by exact PoB gate"):sub(1, 180),
					}
				end
				for _, entry in ipairs(candidate.gearVariant and candidate.gearVariant.generatedItems or { }) do
					local item = entry.item
					local itemPreview = {
						slot = tostring(entry.slotName or entry.slot or "unknown"),
						name = tostring(entry.name or (item and (item.name or item.baseName)) or entry.baseName or "native generated item"):sub(1, 100),
						affixCount = tonumber(entry.affixCount),
						socketRepair = entry.socketPlan and entry.socketPlan.repair == true or entry.kind == "socket_repair",
						attributeMods = { },
					}
					for _, mod in ipairs(item and item.modList or { }) do
						if type(mod) == "table" and (mod.name == "Str" or mod.name == "Dex" or mod.name == "Int"
							or mod.name == "All" or mod.name == "StrDex" or mod.name == "StrInt"
							or mod.name == "DexInt") and isFinite(mod.value) then
							itemPreview.attributeMods[#itemPreview.attributeMods + 1] = {
								stat = mod.name, value = mod.value,
							}
						end
					end
					exactPreview.items[#exactPreview.items + 1] = itemPreview
				end
				archivedRouteCoverage.adaptiveGateRepairExactPreview[#archivedRouteCoverage.adaptiveGateRepairExactPreview + 1] = exactPreview
			end
		end
		if candidate.isBaselineCandidate then
			phaseCoverage.baselineEvaluated = true
			phaseCoverage.baselineEvaluationIndex = evaluationCount
		end
		phaseCoverage.largestExactTreePointCount = math.max(phaseCoverage.largestExactTreePointCount, candidatePointCount)
		if candidate.progressiveRouteBundle then
			phaseCoverage.exactProgressiveTreeBundleEvaluations = phaseCoverage.exactProgressiveTreeBundleEvaluations + 1
			if candidate.combinedTreeAscendancy then
				phaseCoverage.exactProgressiveTreeAscendancyBundleEvaluations =
					phaseCoverage.exactProgressiveTreeAscendancyBundleEvaluations + 1
			end
			if #phaseCoverage.progressiveTreeEvaluationSummaries < 8 then
				local violationKeys = { }
				for index, violation in ipairs(evaluation.violations or { }) do
					if index > 4 then break end
					violationKeys[#violationKeys + 1] = tostring(violation.key or violation.label or "hard_gate")
				end
				phaseCoverage.progressiveTreeEvaluationSummaries[#phaseCoverage.progressiveTreeEvaluationSummaries + 1] = {
					label = tostring(candidate.label or "Progressive passive routes"):sub(1, 120),
					routeCount = candidate.routeCount,
					cycleFilteredRouteCount = candidate.cycleFilteredRouteCount or 0,
					distinctTargets = #(candidate.targetIds or { }),
					mainPoints = candidatePointCount,
					addedPoints = countAddedMainPoints(specProxy or build.spec, candidate.nodeIds or { }),
					objectiveMetric = parsed.objective,
					objectiveValue = evaluation.metrics and evaluation.metrics[parsed.objective],
					selectedAscendancy = evaluatedSpec.curAscendClassName,
					combinedTreeAscendancy = candidate.combinedTreeAscendancy == true,
					feasible = evaluation.feasible == true,
					violationCount = #(evaluation.violations or { }),
					violationKeys = violationKeys,
				}
			end
		end
		if candidate.combinedTreeAscendancy then
			phaseCoverage.exactTreeAscendancyCombinations = phaseCoverage.exactTreeAscendancyCombinations + 1
		end
		if candidate.ascendancyVariant and (candidate.ascendancyPointCost or 0) > 0 then
			ascendancyCoverage.exactEvaluations = ascendancyCoverage.exactEvaluations + 1
			if (candidate.secondaryAscendancyPointCost or 0) > 0 then
				ascendancyCoverage.exactBloodlineEvaluations = ascendancyCoverage.exactBloodlineEvaluations + 1
				if (candidate.mainAscendancyPointCost or 0) > 0 then
					ascendancyCoverage.exactCombinedEvaluations = ascendancyCoverage.exactCombinedEvaluations + 1
				end
			end
		end
		if candidate.isBaselineCandidate then
			zoneCoverage.baselineObjectiveValue = evaluation.metrics and evaluation.metrics[parsed.objective]
		end
		recordHierarchicalEvaluation(zoneCoverage, candidate, evaluation, parsed.objective)
		local clusterVariantCount = candidate.jewelVariant and candidate.jewelVariant.sourceKind == "cluster" and 1 or 0
		for _, variant in ipairs(candidate.jewelVariants or { }) do
			if variant.sourceKind == "cluster" then clusterVariantCount = clusterVariantCount + 1 end
		end
		if clusterVariantCount > 0 then
			clusterCoverage.exactEvaluations = (clusterCoverage.exactEvaluations or 0) + 1
			if candidate.jewelCombination == "parent_child_cluster" then
				clusterCoverage.nestedExactEvaluations = (clusterCoverage.nestedExactEvaluations or 0) + 1
			end
		end
		if candidate.jewelVariant or (candidate.jewelVariants and #candidate.jewelVariants > 0) then
			jewelCoverage.exactEvaluations = jewelCoverage.exactEvaluations + 1
			if candidate.jewelVariants and #candidate.jewelVariants > 1 then
				jewelCoverage.exactPairedEvaluations = jewelCoverage.exactPairedEvaluations + 1
				if candidate.jewelCombination == "overlapping_radius_providers" then
					jewelCoverage.exactOverlappingEvaluations = jewelCoverage.exactOverlappingEvaluations + 1
				end
			end
		end
		if candidate.gearVariant and candidate.gearVariant.inventorySearch then
			equipmentCoverage.exactEvaluations = equipmentCoverage.exactEvaluations + 1
			if candidate.gearVariant.inventoryRoutePair then
				equipmentCoverage.exactRouteEvaluations = equipmentCoverage.exactRouteEvaluations + 1
			end
			if candidate.gearVariant.inventoryPair then
				equipmentCoverage.exactPairedEvaluations = equipmentCoverage.exactPairedEvaluations + 1
			else
				equipmentCoverage.exactSingleEvaluations = equipmentCoverage.exactSingleEvaluations + 1
			end
		end
		if candidate.gearVariant and candidate.gearVariant.syntheticSearch then
			syntheticGearCoverage.exactEvaluations = syntheticGearCoverage.exactEvaluations + 1
			if candidate.gearVariant.socketBinding then
				syntheticGearCoverage.exactSocketBoundEvaluations = (syntheticGearCoverage.exactSocketBoundEvaluations or 0) + 1
			end
			if candidate.gearVariant.syntheticTriple then
				syntheticGearCoverage.exactTripleEvaluations = syntheticGearCoverage.exactTripleEvaluations + 1
				if evaluation.marketBudget and evaluation.marketBudget.enabled then
					syntheticGearCoverage.exactTripleBudgetEvaluations = syntheticGearCoverage.exactTripleBudgetEvaluations + 1
					syntheticGearCoverage.lastExactTripleBudgetTotal = evaluation.marketBudget.total
					if evaluation.marketBudget.withinBudget then
						syntheticGearCoverage.exactTripleBudgetPasses = syntheticGearCoverage.exactTripleBudgetPasses + 1
					else
						syntheticGearCoverage.exactTripleBudgetFailures = syntheticGearCoverage.exactTripleBudgetFailures + 1
					end
				end
			end
			if candidate.gearVariant.syntheticPair then
				syntheticGearCoverage.exactPairedEvaluations = syntheticGearCoverage.exactPairedEvaluations + 1
				if evaluation.marketBudget and evaluation.marketBudget.enabled then
					syntheticGearCoverage.exactPairBudgetEvaluations = syntheticGearCoverage.exactPairBudgetEvaluations + 1
					syntheticGearCoverage.lastExactPairBudgetTotal = evaluation.marketBudget.total
					if evaluation.marketBudget.withinBudget then
						syntheticGearCoverage.exactPairBudgetPasses = syntheticGearCoverage.exactPairBudgetPasses + 1
					else
						syntheticGearCoverage.exactPairBudgetFailures = syntheticGearCoverage.exactPairBudgetFailures + 1
					end
				end
			end
			if candidate.gearVariant.inventoryRoutePair then
				syntheticGearCoverage.exactRouteEvaluations = syntheticGearCoverage.exactRouteEvaluations + 1
			end
		end
		if candidate.gearVariant and candidate.gearVariant.catalystSearch then
			catalystCoverage.exactEvaluations = catalystCoverage.exactEvaluations + 1
			if evaluation.marketBudget and evaluation.marketBudget.enabled then
				catalystCoverage.lastExactBudgetTotal = evaluation.marketBudget.total
				if evaluation.marketBudget.withinBudget then
					catalystCoverage.exactBudgetPasses = (catalystCoverage.exactBudgetPasses or 0) + 1
				else
					catalystCoverage.exactBudgetFailures = (catalystCoverage.exactBudgetFailures or 0) + 1
				end
			end
		end
		candidate.feasible = evaluation.feasible
		local selectedTargetGroup = targetSkill and build.skillsTab and build.skillsTab.socketGroupList
			and build.skillsTab.socketGroupList[targetSkill.groupIndex]
		local socketBinding = candidate.gearVariant and candidate.gearVariant.socketBinding
		candidate.unlinkedMainSkillPlan = unlinkedCheckpointProof and selectedTargetGroup
			and not socketBinding and true or nil
		candidate.evaluation = evaluation
		local trainingContext = job.gnnTrainingContext
		if trainingContext and trainingContext.authorization and type(trainingContext.rows) == "table"
			and #trainingContext.rows < 250 then
			local ok, trainingRow = pcall(GNNTrainingExport.Collect, trainingContext, candidate, evaluation)
			if ok and trainingRow then trainingContext.rows[#trainingContext.rows + 1] = trainingRow end
		end
		if control.recordPathLearning ~= false then
			local recordOk, experienceRecord, recordError = pcall(
				PathExperience.CreateRecord, build, specProxy or build.spec, candidate,
				evaluation, parsed, targetSkill, sourceSignature, basePathContext)
			if recordOk and experienceRecord then
				pathLearningCoverage.exactObservations = (pathLearningCoverage.exactObservations or 0) + 1
				if #pendingPathExperiences < MAX_PENDING_PATH_EXPERIENCES then
					pendingPathExperiences[#pendingPathExperiences + 1] = experienceRecord
				else
					pathLearningCoverage.unpersistedExactObservations = (pathLearningCoverage.unpersistedExactObservations or 0) + 1
				end
			elseif not recordOk then
				pathLearningCoverage.recordErrors = (pathLearningCoverage.recordErrors or 0) + 1
				pathLearningCoverage.lastRecordError = tostring(experienceRecord):sub(1, 120)
			elseif recordError then
				pathLearningCoverage.recordSkips = (pathLearningCoverage.recordSkips or 0) + 1
				pathLearningCoverage.lastRecordSkip = tostring(recordError):sub(1, 120)
		end
		end
		if #pendingPathExperiences >= 32 then flushPathExperiences(false) end
		if phase.nodePotentialAnalysis then
			local metrics = shallowCopy(evaluation.metrics)
			if candidate.isBaselineCandidate then
				nodePotentialBaselineMetrics = metrics
			else
				recordNodePotentialRoute(candidate, specProxy or build.spec, metrics, evaluation.feasible,
					evaluation.violations, true)
				nodePotentialExactRouteEvaluations = nodePotentialExactRouteEvaluations + 1
			end
		end
		if candidate.gearVariant and candidate.gearVariant.syntheticSearch then
			local rejectionDetails = { }
			for _, violation in ipairs(evaluation.violations or { }) do
				rejectionDetails[#rejectionDetails + 1] = {
					key = tostring(violation.key or violation.label or "exact_gate"),
					reason = tostring(violation.reason or violation.deficit or "Rejected by exact PoB gate"):sub(1, 240),
				}
			end
			syntheticGearCoverage.lastExactEvaluation = {
				candidate = tostring(candidate.label or "Synthetic gear candidate"):sub(1, 160),
				feasible = evaluation.feasible == true,
				violations = rejectionDetails,
				CombinedDPS = evaluation.metrics and evaluation.metrics.CombinedDPS,
				TotalEHP = evaluation.metrics and evaluation.metrics.TotalEHP,
			}
		end
		candidate.label = candidate.label or (candidate.targetId and (build.spec.nodes[candidate.targetId].name or "Passive route") or "Current build")
		local selectedEquipmentCount = candidate.gearVariant and #(candidate.gearVariant.items or { }) or 0
		if selectedEquipmentCount > 0 then
			candidate.label = candidate.label .. " + " .. tostring(selectedEquipmentCount) .. " selected item" .. (selectedEquipmentCount == 1 and "" or "s")
		end
		evaluation.candidateLabel = tostring(candidate.label):sub(1, 160)
		if candidate.isBaselineCandidate then
			searchBaseline = {
				exact = true,
				label = evaluation.candidateLabel,
				feasible = evaluation.feasible == true,
				violationCount = #(evaluation.violations or { }),
				metrics = shallowCopy(evaluation.metrics or { }),
			}
		end
		if phase.searchEquipment then GearRepair.RecordExact(requirementRepairCoverage, candidate, evaluation) end
		if phase.searchEquipment and candidate.isBaselineCandidate and not requirementRepairCoverage.baselineEvaluated then
			requirementRepairCoverage.baselineEvaluated = true
			local repairPool = { }
			for _, proposal in ipairs(equipmentCandidates) do repairPool[#repairPool + 1] = proposal end
			local needs = GearRepair.NeedsFromEvaluation(evaluation, parsed)
			local catalystCandidates
			catalystCandidates, catalystCoverage = CatalystSearch.BuildCandidates(
				build, needs, math.max(equipmentRepairMaxQuota, catalystRepairMaxQuota), parsed.search.equipmentOverrides, parsed)
			for _, proposal in ipairs(catalystCandidates) do repairPool[#repairPool + 1] = proposal end
			if parsed.search.routePlannerRunSpec then
				local safeRepairPool, rejectedRepairPool = Equipment.FilterFlaskMutations(build, repairPool)
				repairPool = safeRepairPool
				flaskMutationCandidatesRejected = flaskMutationCandidatesRejected + rejectedRepairPool
				phaseCoverage.flaskMutationCandidatesRejected = flaskMutationCandidatesRejected
			end
			requirementRepairCoverage.generatedCandidates = #repairPool
			local repairCandidates, repairActive = GearRepair.Activate(
				requirementRepairCoverage, evaluation, parsed, repairPool, build.itemsTab,
				math.max(equipmentRepairMaxQuota, catalystRepairMaxQuota))
			if repairActive then
				local repairPassCandidates, repairPass = CandidateIdentity.ReplaceScheduledWithRepairs(
					candidates, scheduledEquipmentCandidates, repairCandidates,
					proposalPreparation.identityContextHash, proposalBudget)
				if parsed.search.routePlannerRunSpec then
					local safeRepairCandidates, rejectedRepairs = Equipment.FilterFlaskMutations(build, repairPassCandidates)
					repairPassCandidates = safeRepairCandidates
					flaskMutationCandidatesRejected = flaskMutationCandidatesRejected + rejectedRepairs
					phaseCoverage.flaskMutationCandidatesRejected = flaskMutationCandidatesRejected
				end
				candidates = repairPassCandidates
				if parsed.search.routePlannerRunSpec then
					-- The baseline is already evaluated here. Gear-requirement repairs
					-- are inserted immediately after it, so restore the exact-budget
					-- family/archive reservations before the next candidate is selected.
					candidates, phaseCoverage.exactEvaluationPlan = interleavePlannerCandidateFamilies(
						candidates, phaseCoverage, parsed.search.evaluationBudget, progressiveCandidateForExact)
					progressiveCandidateForExact = phaseCoverage.progressiveTreeReservationStatus == "reserved"
						and candidates[phaseCoverage.progressiveTreeReservationPosition or 0] or nil
					phaseCoverage.rankedCandidates = #candidates
					phaseCoverage.repairPassOrdering = "baseline_then_family_interleaved; not_gnn_ranked"
				end
				phaseCoverage.repairPassGeneratedCandidates = #repairCandidates
				phaseCoverage.repairPassRemovedScheduledCandidates = repairPass.removedScheduledCandidates
				phaseCoverage.repairPassComposedCandidates = repairPass.composedCandidates
				phaseCoverage.repairPassUniqueCandidates = repairPass.newUniqueCandidates
				phaseCoverage.repairPassDuplicateCandidatesDiscarded = repairPass.duplicateCandidatesDiscarded
				phaseCoverage.repairPassDiscardedByProposalBudget = repairPass.discardedByProposalBudget
				phaseCoverage.repairPassRetainedCandidates = repairPass.retainedRepairCandidates
				phaseCoverage.retainedCandidates = #candidates
				equipmentScheduledQuota = repairPass.retainedRepairCandidates
				local selectedInventoryCount = 0
				for _, proposal in ipairs(repairPass.retainedRepairCandidateList) do
					if proposal.gearVariant and proposal.gearVariant.inventorySearch then selectedInventoryCount = selectedInventoryCount + 1 end
				end
				equipmentCoverage.directQuota = selectedInventoryCount
				requirementRepairCoverage.activated = true
				requirementRepairCoverage.scheduledCandidates = equipmentScheduledQuota
			else
				requirementRepairCoverage.scheduledCandidates = equipmentScheduledQuota
			end
		end
		if evaluation.feasible then candidate.sourceSignature = sourceSignature end
		if evaluation.feasible and Ranking.IsBetter(candidate, feasibleBest, parsed.objective, parsed.preferences) then
			feasibleBest = candidate
		end
		if evaluation.feasible then addToParetoFront(paretoFront, candidate, parsed.objective, parsed.preferences) end
		if not evaluation.feasible then
			failureBest = selectBetterFailure(evaluation, failureBest)
			exactFailureBest = selectBetterFailure(evaluation, exactFailureBest)
			rememberExactNearMiss(exactNearMisses, build, candidate, evaluation,
				parsed.objective, parsed.preferences)
			enqueueArchivedGateRepairs(candidate, evaluation, index)
		end
		if parsed.search.routePlannerRunSpec then
			updateRoutePlannerProgress(job, build, parsed, candidate, evaluationCount,
				candidateAttemptTotal(), phaseCoverage, searchBaseline, paretoFront, index)
		else
			job.progress = { phase = "Exact calculations", processed = evaluationCount,
				total = math.min(candidateAttemptTotal(), parsed.search.evaluationBudget), current = candidate.label }
		end
		coroutine.yield(job.progress)
		end
		end
	end
	flushPathExperiences(true)
	local trainingContext = job.gnnTrainingContext
	if trainingContext and type(trainingContext.rows) == "table" and #trainingContext.rows > 0
		and not (control and control.cancelled) then
		local exported, exportError = GNNTrainingExport.Export(trainingContext, control, job)
		job.gnnTrainingExportStatus = exported and { status = "exported", rows = exported.rows,
			fileName = exported.fileName, sha256 = exported.sha256 }
			or { status = "failed", rows = #trainingContext.rows, message = tostring(exportError or "local export failed") }
	elseif trainingContext and trainingContext.authorization then
		job.gnnTrainingExportStatus = { status = "empty", rows = 0,
			message = "No exact candidate passed the export certification filter" }
	end
	finalizeHierarchicalCoverage(zoneCoverage)
	if phase.nodePotentialAnalysis then
		local objectiveBaseline = nodePotentialBaselineMetrics and nodePotentialBaselineMetrics[parsed.objective]
		local selectedGemData = targetSkill and targetSkill.gemVariant and build.data and build.data.gems
			and build.data.gems[targetSkill.gemVariant.gemId]
		local selectedSkillName = selectedGemData and selectedGemData.name
		local selectedSkillTags = selectedGemData and selectedGemData.tagString
		for _, entry in ipairs(nodePotentialResults) do
			entry.objective = parsed.objective
			entry.exactCalculated = entry.exactCalculated == true
			entry.objectiveBaseline = objectiveBaseline
			local objectiveValue = entry.metrics[parsed.objective]
			if isFinite(objectiveBaseline) and isFinite(objectiveValue) then
				entry.objectiveDelta = objectiveValue - objectiveBaseline
			end
			entry.metricDelta = { }
			for _, key in ipairs({ parsed.objective, "CombinedDPS", "FullDPS", "FullDotDPS", "TotalDotDPS", "TotalEHP", "Life", "EnergyShield", "Ward", "ImpaleDPS", "Armour", "Evasion", "SpellSuppressionChance", "SpellBlockChance", "BlockChance" }) do
				local before, after = nodePotentialBaselineMetrics and nodePotentialBaselineMetrics[key], entry.metrics[key]
				if isFinite(before) and isFinite(after) then entry.metricDelta[key] = after - before end
			end
		end
		local focusMetrics, focusNotes = nodePotentialFocusMetrics(parsed, nodePotentialBaselineMetrics or { })
		assignNodeRouteParetoRanks(nodePotentialResults, focusMetrics)
		return {
			status = "node_potential_complete",
			candidate = nil,
			generationPhase = phase.generation,
			evaluations = evaluationCount,
			exactRouteEvaluations = nodePotentialExactRouteEvaluations,
			baselineMetrics = nodePotentialBaselineMetrics or { },
			results = nodePotentialResults,
			objective = parsed.objective,
			preferences = shallowCopy(parsed.preferences),
			focusMetrics = focusMetrics,
			focusNotes = focusNotes,
			skillName = selectedSkillName,
			skillTags = selectedSkillTags,
			version = Version.Snapshot(sourceBuild),
			sourceSignature = sourceSignature,
			searchCoverage = { phase = phaseCoverage, topology = topologyCoverage, pathLearning = pathLearningCoverage },
		}
	end
	local nearMisses = { }
	for _, entry in ipairs(exactNearMisses) do nearMisses[#nearMisses + 1] = entry.summary end
	if feasibleBest then
		feasibleBest.sourceSignature = sourceSignature
		return {
			status = "feasible", candidate = feasibleBest, evaluation = feasibleBest.evaluation,
			paretoFront = paretoFront, evaluations = evaluationCount,
			nearMisses = nearMisses,
			ranking = feasibleBest.evaluation.ranking,
			objectiveMetric = parsed.objective,
			generationPhase = phase.generation,
			searchBaseline = searchBaseline,
			searchCoverage = { phase = phaseCoverage, ascendancies = ascendancyCoverage, anoints = anointCoverage, jewels = jewelCoverage, clusters = clusterCoverage, equipment = equipmentCoverage, requirementRepair = requirementRepairCoverage, catalysts = catalystCoverage, syntheticGear = syntheticGearCoverage, configuration = configurationCoverage, topology = topologyCoverage, zones = zoneCoverage, learningRanker = learningRankerCoverage, pathLearning = pathLearningCoverage },
			scenarioProfile = parsed.scenarioProfile or "Current", scenario = feasibleBest.evaluation.scenario,
		}
	end
	-- Structural deficits and exact-calculation deficits use different scales.
	-- A rejected route with a unit structural penalty must not hide a calculated
	-- candidate's actual resource/availability failure (possibly unsupported).
	-- Prefer the most informative exact evidence once any legal route reached
	-- PoB. This affects the failure report only, never selection or feasibility.
	failureBest = exactFailureBest or failureBest
	local bestObservedIdentity
	if failureBest and failureBest.selectedBaseClassName then
		bestObservedIdentity = {
			candidateLabel = tostring(failureBest.candidateLabel or "Best observed exact candidate"):sub(1, 160),
			baseClass = tostring(failureBest.selectedBaseClassName):sub(1, 80),
			ascendancy = tostring(failureBest.selectedAscendancyName or "None"):sub(1, 80),
			secondaryAscendancy = tostring(failureBest.selectedSecondaryAscendancyName or "None"):sub(1, 80),
			passivePointsUsed = isFinite(failureBest.passivePointsUsed) and failureBest.passivePointsUsed or nil,
			ascendancyPointsUsed = isFinite(failureBest.ascendancyPointsUsed) and failureBest.ascendancyPointsUsed or nil,
			secondaryAscendancyPointsUsed = isFinite(failureBest.secondaryAscendancyPointsUsed) and failureBest.secondaryAscendancyPointsUsed or nil,
			characterLevel = isFinite(failureBest.characterLevel) and failureBest.characterLevel or nil,
			ascendancyPointBudget = isFinite(failureBest.ascendancyPointBudget) and failureBest.ascendancyPointBudget or nil,
		}
	end
	return {
		status = "no_feasible_candidate",
		candidate = nil,
		evaluations = evaluationCount,
		generationPhase = phase.generation,
		searchBaseline = searchBaseline,
		bestObservedMetrics = failureBest and failureBest.metrics or { },
		bestObservedViolations = failureBest and failureBest.violations or { },
		bestObservedDeficit = failureBest and failureBest.normalizedDeficit,
		nearMisses = nearMisses,
		bestObservedIdentity = bestObservedIdentity,
		ranking = {
			priority = parsed.preferences and parsed.preferences.rankingPriority or "ObjectiveFirst",
			primaryMetric = Ranking.OrderingMetrics(parsed.objective, parsed.preferences)[1],
			secondaryMetric = Ranking.OrderingMetrics(parsed.objective, parsed.preferences)[2],
			tertiaryMetric = Ranking.OrderingMetrics(parsed.objective, parsed.preferences)[3],
		},
		objectiveMetric = parsed.objective,
		failureEvidence = exactFailureBest and "exact_calculation" or "structural_validation",
		searchCoverage = { phase = phaseCoverage, ascendancies = ascendancyCoverage, anoints = anointCoverage, jewels = jewelCoverage, clusters = clusterCoverage, equipment = equipmentCoverage, requirementRepair = requirementRepairCoverage, catalysts = catalystCoverage, syntheticGear = syntheticGearCoverage, configuration = configurationCoverage, topology = topologyCoverage, zones = zoneCoverage, learningRanker = learningRankerCoverage, pathLearning = pathLearningCoverage },
		message = "No feasible candidate found within the search budget",
		scenarioProfile = parsed.scenarioProfile or "Current",
		scenario = failureBest and failureBest.scenario or scenarioDetails,
	}
end

function phantomSim.RunPhantomSim(buildState, parsedInputs, control)
	local job = {
		status = "running",
		progress = { phase = "Initializing", processed = 0, total = parsedInputs.search.evaluationBudget },
		control = control or { cancelled = false },
	}
	job.coroutine = coroutine.create(function()
		return run(buildState, parsedInputs, job.control, job)
	end)
	function job:Step()
		if self.status ~= "running" then return self.status, self.result end
		local ok, value = coroutine.resume(self.coroutine)
		if not ok then
			if type(self.flushPathLearning) == "function" then pcall(self.flushPathLearning) end
			self.status = "error"
			self.error = value
		elseif coroutine.status(self.coroutine) == "dead" then
			local flushOk, coverage
			if type(self.flushPathLearning) == "function" then
				flushOk, coverage = pcall(self.flushPathLearning)
			end
			self.flushPathLearning = nil
			if type(value) == "table" then
				value.sourceSignature = value.sourceSignature or self.sourceSignature
				if type(self.sourceBuildBaseline) == "table" then
					value.sourceBuildBaseline = value.sourceBuildBaseline or self.sourceBuildBaseline
				end
			end
			self.result = value
			if type(value) == "table" and flushOk and type(coverage) == "table" then
				value.searchCoverage = value.searchCoverage or { }
				value.searchCoverage.pathLearning = value.searchCoverage.pathLearning or coverage
			end
			self.status = value and value.status or "error"
		else
			self.progress = value or self.progress
		end
		return self.status, self.result
	end
	function job:Cancel(reason)
		self.control.cancelled = true
		self.control.cancelReason = reason or "user_cancelled"
	end
	return job
end

phantomSim.CountAddedMainPoints = countAddedMainPoints
phantomSim.CombineRoutesAndMutations = combineRoutesAndMutations
phantomSim.MergeGearVariants = Equipment.MergeVariants
phantomSim.BuildArchivedGateRepairCandidates = GearRepair.BuildArchivedGateRepairCandidates
phantomSim.BuildInterruptedSearchResult = buildInterruptedSearchResult
phantomSim.FilterCandidatesToSingleSkill = filterCandidatesToSingleSkill
phantomSim.ResolveSearchPointLimit = resolveSearchPointLimit
phantomSim.PrioritizeLockedProgressiveCandidate = prioritizeLockedProgressiveCandidate
phantomSim.PrioritizeProgressiveTreeCandidate = prioritizeProgressiveTreeCandidate
phantomSim.InterleavePlannerCandidateFamilies = interleavePlannerCandidateFamilies

return phantomSim
