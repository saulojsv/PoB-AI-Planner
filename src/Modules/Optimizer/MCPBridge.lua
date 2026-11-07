-- Path of Building
--
-- Module: Local Path of Building MCP bridge.
-- The MCP child process reaches this bridge over an authenticated loopback
-- socket. Requests are handled on the normal PoB UI thread and can only call
-- the typed operations below; this is not a Lua console or file server.
--
local socket = require("socket")
local json = require("dkjson")
local Inputs = require("Modules.Optimizer.Inputs")
local TreeSearch = require("Modules.Optimizer.TreeSearch")
local Candidate = require("Modules.Optimizer.Candidate")
local Validator = require("Modules.Optimizer.Validator")
local Calcs = require("Modules.Calcs")
local ClassRoots = require("Modules.Optimizer.ClassRoots")
local Activity = require("Modules.Optimizer.Activity")
local SkillActions = require("Modules.Optimizer.SkillActions")
local StudyRecords = require("Modules.Optimizer.StudyRecords")
local StudyBuilds = require("Modules.Optimizer.StudyBuilds")
local TrainingData = require("Modules.Optimizer.TrainingData")
local Surrogate = require("Modules.Optimizer.Surrogate")
local Version = require("Modules.Optimizer.Version")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local Progression = require("Modules.Optimizer.Progression")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local CatalogCoverage = require("Modules.Optimizer.CatalogCoverage")
local SkillSeed = require("Modules.Optimizer.SkillSeed")
local FactorialStudy = require("Modules.Optimizer.FactorialStudy")
local RelationGraph = require("Modules.Optimizer.RelationGraph")
local StudyContext = require("Modules.Optimizer.StudyContext")
local BuildReadiness = require("Modules.Optimizer.BuildReadiness")
local KnowledgeRegistry = require("Modules.Optimizer.KnowledgeRegistry")
local skillItemStudyEngine

-- Native Ask AI dispatch is usable without a TCP listener. Its job registry
-- belongs to the in-process tool layer, not the optional companion transport.
local bridge = { jobs = { }, nextJob = 0 }
-- One endpoint file per live PoB listener. A single shared file made the last
-- launched window silently replace the endpoint for every other PoB window.
local endpointFilePrefix = "pob-optimizer-mcp-instance-"
local healthFilePrefix = "pob-optimizer-mcp-health-"
local maxRequestBytes = 65536
local maxResponseBytes = 262144
local maxClients = 8
local maxJobs = 8
local maxStudyBuilds = 8
local maxFactorialJobs = 8
local maxConcurrentStudyImports = 2
local studyImportTimeout = 90
-- Bump this when the companion requires a new, non-backwards-compatible
-- build/activity snapshot contract. This token-free heartbeat lets it detect
-- a live old PoB process before attempting current-source QA.
-- Contract v4 adds native item socket/link topology. Contract v5 adds a
-- verified calculation-content identity; older processes remain read-only.
local snapshotContractVersion = 5

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function tempPath(fileName)
	local directory = os.getenv("TEMP") or os.getenv("TMP") or "."
	local separator = package.config and package.config:sub(1, 1) or "\\"
	if directory:sub(-1) == "/" or directory:sub(-1) == "\\" then
		return directory .. fileName
	end
	return directory .. separator .. fileName
end

local function currentBuild()
	if not main or main.mode ~= "BUILD" then return nil end
	local build = main.modes and main.modes.BUILD
	return build and build.spec and build or nil
end

local function boundedText(value, limit)
	local text = tostring(value or "")
	if #text > limit then return text:sub(1, limit) .. "…" end
	return text
end

local function jsonArray(values)
	return setmetatable(values or { }, { __jsontype = "array" })
end

-- Optimizer result detail tables can carry PoB-only objects, cycles or
-- non-finite diagnostic values (for example an unsupported availability
-- estimate). Keep the typed MCP response serializable without changing the
-- authoritative exact evaluation or its feasibility decision.
local function jsonSafeCopy(value, depth, stack, budget)
	local valueType = type(value)
	if valueType == "nil" then return nil end
	if valueType == "boolean" then return value end
	if valueType == "number" then return isFinite(value) and value or nil end
	if valueType == "string" then return #value > 1024 and value:sub(1, 1024) or value end
	if valueType ~= "table" then return nil end

	depth = depth or 0
	stack = stack or { }
	budget = budget or { remaining = 4096 }
	if depth >= 12 or budget.remaining <= 0 or stack[value] then return nil end
	budget.remaining = budget.remaining - 1
	stack[value] = true

	local sourceMeta = getmetatable(value)
	local sourceArray = type(sourceMeta) == "table" and sourceMeta.__jsontype == "array"
	local sourceObject = type(sourceMeta) == "table" and sourceMeta.__jsontype == "object"
	local count, maximum, denseArray = 0, 0, true
	for key in pairs(value) do
		count = count + 1
		if type(key) ~= "number" or key < 1 or key ~= math.floor(key) then
			denseArray = false
		elseif key > maximum then
			maximum = key
		end
	end
	denseArray = sourceArray or (not sourceObject and denseArray and maximum == count)
	local copy = { }
	if denseArray then
		local length = math.min(maximum, 512)
		for index = 1, length do
			local item = jsonSafeCopy(rawget(value, index), depth + 1, stack, budget)
			copy[index] = item == nil and json.null or item
			if budget.remaining <= 0 then
				for remaining = index + 1, length do copy[remaining] = json.null end
				break
			end
		end
		setmetatable(copy, { __jsontype = "array" })
	else
		local written = 0
		for key, item in pairs(value) do
			if written >= 512 or budget.remaining <= 0 then
				copy._truncated = true
				break
			end
			local safeKey
			if type(key) == "string" and #key <= 128 then
				safeKey = key
			elseif type(key) == "number" and isFinite(key) then
				safeKey = tostring(key)
			end
			if safeKey then
				local safeValue = jsonSafeCopy(item, depth + 1, stack, budget)
				if safeValue ~= nil then
					copy[safeKey] = safeValue
					written = written + 1
				end
			end
		end
		if sourceObject then setmetatable(copy, { __jsontype = "object" }) end
	end
	stack[value] = nil
	return copy
end

local function skillName(activeSkill)
	if not activeSkill then return nil end
	local effect = activeSkill.activeEffect or (activeSkill.effectList and activeSkill.effectList[1])
	return effect and effect.grantedEffect and effect.grantedEffect.name or nil
end

local function exactMetrics(output)
	local metrics = Candidate.CopyMetrics(output, Inputs.metricDefinitions)
	for _, key in ipairs({ "SkillDPS", "TotalDPS", "FullDPS", "FullDotDPS", "Life", "LifeReservedPercent", "LifeUnreservedPercent", "LifeRecoverable", "LifeRegenRecovery", "LifePerSecondCost", "LifeLeechRate", "LifeLeechGainRate", "LifeRecoupRecoveryAvg", "Mana", "ManaReservedPercent", "ManaUnreservedPercent", "ManaRegenRecovery", "ManaPerSecondCost", "ManaCostPayablePool", "ManaLeechRate", "ManaLeechGainRate", "ManaRecoupRecoveryAvg", "EnergyShield", "EnergyShieldRegenRecovery", "ESPerSecondCost", "EnergyShieldLeechRate", "EnergyShieldLeechGainRate", "EnergyShieldRecoupRecoveryAvg", "Armour", "Evasion", "CWDTThreshold", "SelfHitDamage", "TriggerRateCap", "SkillTriggerRate" }) do
		local value = output and output[key]
		if isFinite(value) then metrics[key] = value end
	end
	for _, key in ipairs({ "MineThrowCount", "MineLayingSpeed", "MineLayingTime" }) do
		local value = output and output[key]
		if isFinite(value) then metrics[key] = value end
	end
	return metrics
end

local function fullDPSBreakdown(output)
	return Candidate.CopySkillDPS(output)
end

local function skillEntityLimits(output)
	return Candidate.CopySkillEntityLimits(output)
end

local function fullDPSPayability(output)
	local warnings = output and output.FullDPSPayabilityWarnings
	if type(warnings) ~= "table" then
		return { status = "unsupported", feasible = false, violations = { { key = "full_dps_payability", reason = "PoB did not provide per-skill FullDPS cost checks" } } }
	end
	local violations = { }
	local truncated = false
	for index, warning in ipairs(warnings) do
		if index > 32 then truncated = true break end
		violations[#violations + 1] = {
			key = "full_dps_skill_payability",
			label = boundedText(warning.label or "FullDPS skill cost", 100),
			resource = boundedText(warning.resource or "", 40),
			skill = boundedText(warning.skill or "", 120),
			actual = isFinite(warning.actual) and warning.actual or nil,
			required = isFinite(warning.required) and warning.required or nil,
			deficit = isFinite(warning.deficit) and warning.deficit or nil,
			reason = boundedText(warning.reason or "", 200),
		}
	end
	return { status = #violations == 0 and "pass" or "violated", feasible = #violations == 0, violations = violations, truncated = truncated }
end

local function getSkillGroups(build)
	local groups = { }
	local itemFingerprintsBySlot = { }
	local itemsTab = build.itemsTab
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets and itemsTab.itemSets[itemsTab.activeItemSetId])
	for slotName, slot in pairs(itemSet or { }) do
		local itemId = type(slot) == "table" and tonumber(slot.selItemId)
		local item = itemId and itemId > 0 and itemsTab.items and itemsTab.items[itemId]
		if type(slotName) == "string" and item then
			itemFingerprintsBySlot[slotName] = StudyBuilds.ItemFingerprint(item)
		end
	end
	for groupIndex, group in ipairs(build.skillsTab.socketGroupList or { }) do
		if #groups < 48 then
			local result = {
				groupIndex = groupIndex,
				label = boundedText(group.displayLabel or group.label or "", 100),
				enabled = group.enabled ~= false,
				slotEnabled = group.slotEnabled ~= false,
				includeInFullDPS = group.includeInFullDPS == true,
				slot = boundedText(group.slot or "", 40),
				source = boundedText(group.source or "", 40),
				mainActiveSkill = group.mainActiveSkill or 1,
				groupCount = group.groupCount or 1,
				selectedMainGroup = build.mainSocketGroup == groupIndex,
				supportProfileVersion = 2,
				socketValidation = SkillCatalog.SocketGroupEvidence(build, groupIndex, group),
				gems = { },
				skills = { },
			}
			for gemIndex, gem in ipairs(group.gemList or { }) do
				if gemIndex <= 12 then
					local gemData = gem.gemData
					local effect = gem.grantedEffect or (gemData and gemData.grantedEffect)
					result.gems[#result.gems + 1] = {
						gemIndex = gemIndex,
						gemId = boundedText(gem.gemId or (gemData and gemData.id) or "", 100),
						gameId = boundedText(gemData and gemData.gameId or "", 100),
						variantId = boundedText(gemData and gemData.variantId or "", 120),
						skillId = boundedText(gem.skillId or (gemData and gemData.grantedEffectId) or "", 100),
						name = boundedText((gemData and gemData.name) or (effect and effect.name) or gem.nameSpec or "Unknown gem", 120),
						level = tonumber(gem.level) or 1,
						quality = tonumber(gem.quality) or 0,
						enabled = gem.enabled ~= false,
						count = tonumber(gem.count) or 1,
						isSupport = not not (effect and effect.support),
					socketMatched = result.socketValidation.valid == true,
					}
				end
			end
			for skillIndex, activeSkill in ipairs(group.displaySkillList or { }) do
				if skillIndex > 12 then break end
				local activeEffect = activeSkill.activeEffect
				if not activeEffect and activeSkill.effectList and #activeSkill.effectList == 1 then activeEffect = activeSkill.effectList[1] end
				local activeSupportSet = { }
				for _, effectInstance in ipairs(activeSkill.effectList or { }) do
					if effectInstance.grantedEffect and effectInstance.grantedEffect.support then activeSupportSet[effectInstance] = true end
				end
				local skillResult = {
					skillIndex = skillIndex,
					name = boundedText(activeSkill.name or activeEffect and activeEffect.grantedEffect and activeEffect.grantedEffect.name or "", 120),
					selectedMainSkill = build.mainSocketGroup == groupIndex and (group.mainActiveSkill or 1) == skillIndex,
					supportProfileVersion = 2,
					supports = { },
				}
				for supportIndex, support in ipairs(activeSkill.supportList or { }) do
					if supportIndex > 64 then break end
					local grantedEffect = support.grantedEffect
					if grantedEffect and grantedEffect.support then
						local sourceGem = support.srcInstance
						local gemData = support.gemData or sourceGem and sourceGem.gemData
						local evidence = SkillCatalog.SupportEvidence(build, groupIndex, group, support,
							activeSupportSet, itemFingerprintsBySlot, result.socketValidation)
						local origin = evidence.origin
						local sourceSlot = boundedText(evidence.sourceSlot or "", 40)
						local targetEffectId = activeEffect and activeEffect.grantedEffect and activeEffect.grantedEffect.id or ""
						skillResult.supports[#skillResult.supports + 1] = {
							gemId = boundedText(sourceGem and (sourceGem.gemId or gemData and gemData.id) or gemData and gemData.id or "", 160),
							gameId = boundedText(gemData and gemData.gameId or "", 200),
							variantId = boundedText(gemData and gemData.variantId or "", 200),
							skillId = boundedText(gemData and gemData.grantedEffectId or grantedEffect.id or "", 180),
							effectId = boundedText(grantedEffect.id or "", 180),
							name = boundedText(grantedEffect.name or gemData and gemData.name or "", 120),
							level = tonumber(support.level) or 1,
							quality = tonumber(support.quality) or 0,
							origin = origin,
							sourceSlot = sourceSlot,
							sourceItemFingerprint = evidence.sourceItemFingerprint,
							targetGroupIndex = groupIndex,
							targetSkillIndex = skillIndex,
							targetEffectId = boundedText(targetEffectId, 180),
							configured = evidence.configured,
							calculatorApplied = evidence.calculatorApplied,
							active = evidence.active,
							socketMatched = evidence.socketMatched,
							socketState = evidence.socketState,
							linkState = evidence.linkState,
							groupState = evidence.groupState,
							playableActive = evidence.playableActive,
							supportProfileVersion = 2,
						}
					end
				end
				table.sort(skillResult.supports, function(left, right)
					if left.effectId ~= right.effectId then return left.effectId < right.effectId end
					if left.origin ~= right.origin then return left.origin < right.origin end
					return tostring(left.sourceSlot or "") < tostring(right.sourceSlot or "")
				end)
				result.skills[#result.skills + 1] = skillResult
			end
			groups[#groups + 1] = result
		end
	end
	return groups
end

local function parseNodeIdList(values, label)
	if values == nil then return { } end
	if type(values) ~= "table" or #values > 24 then return nil, label .. " must be an array of at most 24 positive node IDs" end
	local result, seen = { }, { }
	for index, value in ipairs(values) do
		local nodeId = tonumber(value)
		if not isFinite(nodeId) or nodeId < 1 or nodeId ~= math.floor(nodeId) or nodeId > 2147483647 then
			return nil, label .. " contains an invalid positive integer node ID at index " .. tostring(index)
		end
		if seen[nodeId] then return nil, label .. " contains duplicate node ID " .. tostring(nodeId) end
		seen[nodeId] = true
		result[#result + 1] = nodeId
	end
	for key in pairs(values) do
		if type(key) ~= "number" or key < 1 or key > #values or key ~= math.floor(key) then return nil, label .. " must be a dense array" end
	end
	return result
end

local function metricDelta(baseline, candidate)
	local delta = { }
	for key, value in pairs(candidate or { }) do
		if isFinite(value) and isFinite(baseline and baseline[key]) then delta[key] = value - baseline[key] end
	end
	return delta
end

local function copyFiniteMetrics(metrics)
	local copy, count = { }, 0
	for key, value in pairs(metrics or { }) do
		if type(key) == "string" and #key <= 80 and isFinite(value) and count < 128 then
			copy[key] = value
			count = count + 1
		end
	end
	return copy
end


bridge.importedRouteMemorySummary = function(evidence)
	if type(evidence) ~= "table" then return nil end
	local allowedStatuses = { ready = true, no_archive = true, no_compatible_builds = true, single_build_only = true,
		scan_limit_reached = true, unavailable = true, disabled = true }
	local allowedReasons = { class_specific_prior_disabled_for_all_class_comparison = true }
	local nodes, edges = evidence.nodes, evidence.edges
	local nodeCount, edgeCount = 0, 0
	if type(nodes) == "table" then for _ in pairs(nodes) do nodeCount = nodeCount + 1 end end
	if type(edges) == "table" then for _ in pairs(edges) do edgeCount = edgeCount + 1 end end
	return {
		status = allowedStatuses[evidence.status] and evidence.status or "unavailable",
		reason = allowedReasons[evidence.reason] and evidence.reason or nil,
		compatibleBuildCount = math.max(0, math.floor(tonumber(evidence.compatibleBuildCount) or 0)),
		nodeCount = nodeCount,
		edgeCount = edgeCount,
		proposalOrderingOnly = true,
		readOnly = true,
	}
end

local function getPassivePointLimit(build, pointsUsed, extraPoints)
	local characterLevel = tonumber(build.characterLevel) or 1
	if build.characterLevelAutoMode and build.GetEstimatedLevelForPoints then
		characterLevel = build:GetEstimatedLevelForPoints(pointsUsed, extraPoints or 0)
	end
	if build.GetPassivePointLimitForLevel then
		local pointLimit = build:GetPassivePointLimitForLevel(characterLevel, extraPoints or 0)
		if isFinite(pointLimit) then return pointLimit end
	end
	if build.GetEstimatedLevelForPoints then
		local _, _, pointLimit = build:GetEstimatedLevelForPoints(pointsUsed, extraPoints or 0)
		if isFinite(pointLimit) then return pointLimit end
	end
	return 99 + 23 + (extraPoints or 0)
end

local function exactPassiveExtraPoints(build, output, env, fallbackExtraPoints)
	if output and isFinite(output.ExtraPoints) then return output.ExtraPoints end
	-- CALCULATOR output omits ExtraPoints; its isolated environment still carries
	-- the exact candidate modDB value. Use the main output only as a final fallback.
	local modDB = env and env.modDB
	if modDB and type(modDB.Sum) == "function" then
		local ok, value = pcall(modDB.Sum, modDB, "BASE", nil, "ExtraPoints")
		if ok and isFinite(value) then return value end
	end
	if isFinite(fallbackExtraPoints) then return fallbackExtraPoints end
	local mainOutput = build and build.calcsTab and build.calcsTab.mainOutput
	if mainOutput and isFinite(mainOutput.ExtraPoints) then return mainOutput.ExtraPoints end
	return nil
end

local function getActiveSkills(build)
	local skills = { }
	for groupIndex, group in ipairs(build.skillsTab.socketGroupList or { }) do
		if group.enabled ~= false and group.slotEnabled ~= false then
			for skillIndex, activeSkill in ipairs(group.displaySkillList or { }) do
				local effects = { }
				for _, effect in ipairs(activeSkill.effectList or { }) do
					if effect.grantedEffect then effects[#effects + 1] = boundedText(effect.grantedEffect.name, 96) end
				end
				skills[#skills + 1] = {
					groupIndex = groupIndex,
					skillIndex = skillIndex,
					name = skillName(activeSkill) or "Unknown active skill",
					effects = effects,
					isSelectedMain = build.mainSocketGroup == groupIndex and (group.mainActiveSkill or 1) == skillIndex,
				}
			end
		end
	end
	return skills
end

local nativeDamageTypeOrder = { "Physical", "Lightning", "Cold", "Fire", "Chaos" }

local function parseNativeTagString(tagString)
	local tags = { }
	for tag in tostring(tagString or ""):gmatch("[^,]+") do
		tag = tag:match("^%s*(.-)%s*$")
		if tag ~= "" then tags[#tags + 1] = tag end
	end
	return tags
end

local function skillEffect(activeSkill)
	return activeSkill and (activeSkill.activeEffect or (activeSkill.effectList and activeSkill.effectList[1]))
end

local function nativeEffectTypes(grantedEffect)
	local effectTypes = grantedEffect and grantedEffect.skillTypes
	local enum = SkillType
	if type(effectTypes) ~= "table" or type(enum) ~= "table" then return { }, "unsupported" end
	local nameById = { }
	for name, id in pairs(enum) do
		if type(name) == "string" and type(id) == "number" then nameById[id] = name end
	end
	local names, unmapped = { }, false
	for id, enabled in pairs(effectTypes) do
		if enabled then
			local name = nameById[id]
			if name then names[#names + 1] = name else unmapped = true end
		end
	end
	table.sort(names)
	return names, #names > 0 and not unmapped and "exact" or "unsupported"
end

local function exactDamageEdges(conversionTable, fieldName)
	local edges = { }
	if type(conversionTable) ~= "table" then return edges end
	for sourceIndex = 1, #nativeDamageTypeOrder - 1 do
		local sourceType = nativeDamageTypeOrder[sourceIndex]
		local source = conversionTable[sourceType]
		local values = source and source[fieldName]
		if type(values) == "table" then
			for targetIndex = sourceIndex + 1, #nativeDamageTypeOrder do
				local targetType = nativeDamageTypeOrder[targetIndex]
				local fraction = values[targetType]
				if isFinite(fraction) and fraction > 0 then
					edges[#edges + 1] = {
						from = sourceType,
						to = targetType,
						fraction = fraction,
						percent = fraction * 100,
					}
				end
			end
		end
	end
	return edges
end

local function getMainSkillMechanics(build, activeSkill, groupIndex, skillIndex)
	local result = {
		status = "unavailable",
		groupIndex = groupIndex,
		skillIndex = skillIndex,
		tags = { },
		conversion = { status = "unsupported", converted = { }, gainedAs = { } },
	}
	if not activeSkill then
		result.reason = "No active Main Skill is selected in PoB"
		return result
	end

	local activeEffect = skillEffect(activeSkill)
	local grantedEffect = activeEffect and activeEffect.grantedEffect
	local gemInstance = activeEffect and activeEffect.srcInstance
	local gemData = gemInstance and gemInstance.gemData
	local effectId = grantedEffect and grantedEffect.id
	local group = build.skillsTab and build.skillsTab.socketGroupList and build.skillsTab.socketGroupList[groupIndex]
	if not gemData and group then
		for _, candidate in ipairs(group.gemList or { }) do
			local candidateData = candidate.gemData
			if candidateData and (candidate == gemInstance or candidateData.grantedEffectId == effectId) then
				gemInstance, gemData = candidate, candidateData
				break
			end
			if candidateData and effectId then
				for _, candidateEffect in ipairs(candidateData.grantedEffectList or { }) do
					if candidateEffect.id == effectId then
						gemInstance, gemData = candidate, candidateData
						break
					end
				end
				if gemData then break end
			end
		end
	end

	local tagString = gemData and gemData.tagString or (grantedEffect and grantedEffect.tagString) or ""
	local effectTypes, effectTypeStatus = nativeEffectTypes(grantedEffect)
	result.status = "resolved"
	result.name = skillName(activeSkill) or (grantedEffect and grantedEffect.name) or "Unknown active skill"
	result.effect = {
		id = boundedText(effectId or "", 120),
		name = boundedText(grantedEffect and grantedEffect.name or "", 120),
	}
	result.gem = gemData and {
		id = boundedText(gemData.id or (gemInstance and gemInstance.gemId) or "", 120),
		name = boundedText(gemData.name or "", 120),
		gameId = boundedText(gemData.gameId or "", 160),
		variantId = boundedText(gemData.variantId or "", 120),
		tagString = boundedText(tagString, 240),
		tags = parseNativeTagString(tagString),
	} or nil
	-- Keep `tags` for existing consumers; the nested field names its gem-level
	-- source explicitly. `effectTypes` belongs to the selected active effect and
	-- can differ for multi-skill gems such as Vaal variants.
	result.tags = result.gem and result.gem.tags or parseNativeTagString(tagString)
	result.effectTypes = effectTypes
	result.effectTypeStatus = effectTypeStatus
	result.effectTypeSource = "loaded PoB grantedEffect.skillTypes/SkillType"

	local calculatedSkill = build.calcsTab and build.calcsTab.mainEnv
		and build.calcsTab.mainEnv.player and build.calcsTab.mainEnv.player.mainSkill
	local calculatedEffect = skillEffect(calculatedSkill)
	local calculatedEffectId = calculatedEffect and calculatedEffect.grantedEffect and calculatedEffect.grantedEffect.id
	local conversionTable = calculatedSkill and calculatedSkill.conversionTable
	if effectId and calculatedEffectId == effectId and type(conversionTable) == "table" then
		result.conversion = {
			status = "exact",
			source = "PoB CalcOffence active-skill conversionTable",
			converted = exactDamageEdges(conversionTable, "conversion"),
			gainedAs = exactDamageEdges(conversionTable, "gain"),
		}
		for damageType, row in pairs(conversionTable) do
			if type(row) == "table" and isFinite(row.mult) then
				result.conversion.remaining = result.conversion.remaining or { }
				result.conversion.remaining[#result.conversion.remaining + 1] = {
					damageType = damageType,
					fraction = row.mult,
					percent = row.mult * 100,
				}
			end
		end
		table.sort(result.conversion.remaining, function(a, b)
			for index, damageType in ipairs(nativeDamageTypeOrder) do
				if a.damageType == damageType then return true end
				if b.damageType == damageType then return false end
			end
			return a.damageType < b.damageType
		end)
	else
		result.conversion.reason = calculatedSkill and "PoB's calculated Main Skill does not match the selected skill effect" or "PoB's exact Main Skill calculation output is unavailable"
		if not calculatedSkill then result.conversion.status = "unsupported" else result.conversion.status = "mismatch" end
	end
	return result
end

local nativeSkillOutputFields = {
	"TotalDPS", "TotalDot", "DotDPS", "TotalPoisonDPS", "PoisonDPS", "TotalBleedDPS", "BleedDPS",
	"TotalIgniteDPS", "IgniteDPS", "ImpaleDPS", "WithImpaleDPS", "AverageHit", "AverageDamage",
	"TotalMin", "TotalMax", "Speed", "HitSpeed", "HitChance", "CritChance", "CritMultiplier",
	"Cooldown", "TrapCooldown", "MineThrowCount", "MineLayingSpeed", "MineLayingTime", "TrapThrowingSpeed", "TotemPlacementSpeed",
}

local nativeSkillDisplayKeys = {
	"Speed", "HitSpeed", "HitChance", "CritChance", "CritMultiplier", "AverageHit", "AverageDamage",
	"TotalDPS", "TotalDot", "PoisonDPS", "TotalPoisonDPS", "BleedDPS", "TotalBleedDPS",
	"IgniteDPS", "TotalIgniteDPS", "ImpaleDPS", "WithImpaleDPS", "Cooldown", "TrapCooldown",
	"MineThrowCount", "MineLayingSpeed", "MineLayingTime", "TrapThrowingTime", "TotemPlacementTime", "CastTime", "AttackTime",
}

local nativeDamageRowFields = { "source", "base", "inc", "more", "convSrc", "total", "convDst", "gainDst" }
local nativeDamageBucketValueFields = { "baseMin", "baseMax", "hitAverage", "criticalAverage" }

local function copyNativeDamageBucket(output, breakdown, damageType)
	local bucket = { damageType = damageType }
	for field, outputKey in pairs({
		baseMin = damageType .. "MinBase",
		baseMax = damageType .. "MaxBase",
		hitAverage = damageType .. "HitAverage",
		criticalAverage = damageType .. "CritAverage",
	}) do
		local value = output and output[outputKey]
		if isFinite(value) then bucket[field] = value end
	end

	local section = breakdown and breakdown[damageType]
	local rows = section and section.damageTypes
	local copiedRows = jsonArray()
	local truncated = false
	for index, row in ipairs(type(rows) == "table" and rows or { }) do
		if index > 8 then
			truncated = true
			break
		end
		if type(row) == "table" then
			local copied = { }
			for _, field in ipairs(nativeDamageRowFields) do
				if type(row[field]) == "string" then copied[field] = boundedText(row[field], 180) end
			end
			copiedRows[#copiedRows + 1] = copied
		end
	end
	bucket.displayRows = copiedRows
	bucket.displayRowsTruncated = truncated
	return bucket
end

local function copyNativeSkillActorBreakdown(actor, actorKind)
	if type(actor) ~= "table" or type(actor.output) ~= "table" then
		return { status = "unsupported", actor = actorKind, reason = "PoB did not expose this calculated actor output" }
	end
	local output = actor.output
	local breakdown = actor.breakdown
	local result = {
		status = type(breakdown) == "table" and "exact" or "unsupported",
		actor = actorKind,
		name = boundedText(skillName(actor.mainSkill) or (actor.minionData and actor.minionData.name) or "", 120),
		numericSource = "PoB CalcOffence active-skill output; copied without recomputation",
		displaySource = "PoB native breakdown strings; presentation values may be rounded",
		numericOutput = { },
		damageTypes = jsonArray(),
		displayGroups = jsonArray(),
		displayGroupsTruncated = false,
	}
	local effect = skillEffect(actor.mainSkill)
	local effectId = effect and effect.grantedEffect and effect.grantedEffect.id
	if effectId then result.effectId = boundedText(effectId, 120) end
	for _, field in ipairs(nativeSkillOutputFields) do
		local value = output[field]
		if isFinite(value) then result.numericOutput[field] = value end
	end
	for _, damageType in ipairs(nativeDamageTypeOrder) do
		result.damageTypes[#result.damageTypes + 1] = copyNativeDamageBucket(output, breakdown, damageType)
	end
	if type(breakdown) ~= "table" then
		result.reason = "PoB has no native CalcOffence display breakdown for this actor"
		return result
	end
	for index, key in ipairs(nativeSkillDisplayKeys) do
		if index > 24 then
			result.displayGroupsTruncated = true
			break
		end
		local sourceLines = breakdown[key]
		if type(sourceLines) == "table" then
			local copiedLines = jsonArray()
			local truncated = false
			for lineIndex, line in ipairs(sourceLines) do
				if lineIndex > 12 then truncated = true break end
				if type(line) == "string" then copiedLines[#copiedLines + 1] = boundedText(line, 180) end
			end
			if #copiedLines > 0 then
				result.displayGroups[#result.displayGroups + 1] = {
					key = key,
					lines = copiedLines,
					truncated = truncated,
				}
			end
		end
	end
	return result
end

local function copyNumericSkillDamage(actor, actorKind)
	if type(actor) ~= "table" or type(actor.output) ~= "table" then
		return { status = "unsupported", actor = actorKind, reason = "PoB did not expose this calculated actor output" }
	end
	local effect = skillEffect(actor.mainSkill)
	local effectId = effect and effect.grantedEffect and effect.grantedEffect.id
	local result = {
		status = "unsupported",
		actor = actorKind,
		name = boundedText(skillName(actor.mainSkill) or (actor.minionData and actor.minionData.name) or "", 120),
		effectId = effectId and boundedText(effectId, 120) or nil,
		numericOutput = { },
		damageTypes = jsonArray(),
		source = "PoB CalcOffence actor output; values copied without recomputation",
	}
	for _, field in ipairs(nativeSkillOutputFields) do
		local value = actor.output[field]
		if isFinite(value) then result.numericOutput[field] = value end
	end
	local numericValueCount = 0
	for _, damageType in ipairs(nativeDamageTypeOrder) do
		local bucket = copyNativeDamageBucket(actor.output, nil, damageType)
		bucket.displayRows = nil
		bucket.displayRowsTruncated = nil
		for _, field in ipairs(nativeDamageBucketValueFields) do
			if isFinite(bucket[field]) then numericValueCount = numericValueCount + 1 end
		end
		result.damageTypes[#result.damageTypes + 1] = bucket
	end
	if numericValueCount > 0 then result.status = "exact" end
	if result.status ~= "exact" then result.reason = "PoB did not expose numeric per-type damage outputs for this actor" end
	return result
end

local function compareNumericSkillDamage(baselineActor, candidateActor, actorKind, expectedEffectId)
	local baseline = copyNumericSkillDamage(baselineActor, actorKind)
	local candidate = copyNumericSkillDamage(candidateActor, actorKind)
	local result = {
		status = "unsupported",
		actor = actorKind,
		baseline = baseline,
		candidate = candidate,
		delta = jsonArray(),
	}
	if baseline.status ~= "exact" or candidate.status ~= "exact" then
		result.reason = baseline.reason or candidate.reason or "PoB did not expose both exact actor outputs"
		return result
	end
	local baselineEffectId = baseline.effectId and tostring(baseline.effectId) or nil
	local candidateEffectId = candidate.effectId and tostring(candidate.effectId) or nil
	if not baselineEffectId or not candidateEffectId then
		result.reason = "PoB did not identify both calculated active-skill effects"
		return result
	end
	if expectedEffectId and (baselineEffectId ~= tostring(expectedEffectId) or candidateEffectId ~= tostring(expectedEffectId)) then
		result.status = "mismatch"
		result.reason = "The exact actor outputs do not match the selected active-skill effect"
		return result
	end
	if baselineEffectId ~= candidateEffectId then
		result.status = "mismatch"
		result.reason = "PoB resolved different active-skill effects for the baseline and candidate"
		return result
	end
	for index, damageType in ipairs(nativeDamageTypeOrder) do
		local before = baseline.damageTypes[index]
		local after = candidate.damageTypes[index]
		local delta = { damageType = damageType }
		for _, field in ipairs(nativeDamageBucketValueFields) do
			if isFinite(before[field]) and isFinite(after[field]) then
				delta[field] = after[field] - before[field]
			end
		end
		result.delta[#result.delta + 1] = delta
	end
	result.status = "exact"
	result.deltaSource = "candidate minus baseline from matching exact PoB actor outputs"
	return result
end

local function getMainSkillBreakdown(build, activeSkill, groupIndex, skillIndex)
	local mainEnv = build.calcsTab and build.calcsTab.mainEnv
	local player = mainEnv and mainEnv.player
	local calculatedSkill = player and player.mainSkill
	local selectedEffect = skillEffect(activeSkill)
	local calculatedEffect = skillEffect(calculatedSkill)
	local selectedEffectId = selectedEffect and selectedEffect.grantedEffect and selectedEffect.grantedEffect.id
	local calculatedEffectId = calculatedEffect and calculatedEffect.grantedEffect and calculatedEffect.grantedEffect.id
	local result = {
		status = "unsupported",
		groupIndex = groupIndex,
		skillIndex = skillIndex,
		source = "PoB CalcOffence native mainEnv; no formulas are reconstructed",
		numericAuthority = "numericOutput and exactMetrics are copied from PoB output",
		displayCaveat = "displayGroups and displayRows are formatted PoB text and can be rounded",
	}
	if selectedEffectId then result.selectedEffectId = boundedText(selectedEffectId, 120) end
	if not player or not calculatedSkill or not selectedEffectId then
		result.reason = "PoB did not expose the selected Main Skill's calculated environment"
		return result
	end
	if calculatedEffectId ~= selectedEffectId then
		result.status = "mismatch"
		result.reason = "PoB's calculated Main Skill effect does not match the selected socketed effect"
		return result
	end
	local playerBreakdown = copyNativeSkillActorBreakdown(player, "player")
	result.player = playerBreakdown
	if playerBreakdown.status ~= "exact" then
		result.reason = playerBreakdown.reason
		return result
	end
	if mainEnv.minion then
		result.minion = copyNativeSkillActorBreakdown(mainEnv.minion, "minion")
	end
	result.status = "exact"
	return result
end

local function getActiveItems(build)
	local items, slots = { }, { }
	local itemsTab = build.itemsTab
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets[itemsTab.activeItemSetId])
	if not itemSet then return items end
	for slotName, slot in pairs(itemSet) do
		if type(slot) == "table" and slot.selItemId and slot.selItemId > 0 then
			local item = itemsTab.items[slot.selItemId]
			if item then
				local itemInfo = items[slot.selItemId]
				if not itemInfo then
					local sockets = { }
					for socketIndex, socket in ipairs(item.sockets or { }) do
						sockets[#sockets + 1] = {
							index = socketIndex,
							color = boundedText(socket.color or "", 8),
							linkGroup = isFinite(socket.group) and socket.group or nil,
						}
					end
					itemInfo = {
						id = slot.selItemId,
						name = boundedText(item.name or item.title or "Unknown item", 128),
						base = boundedText(item.base and item.base.name or "", 96),
						type = boundedText(item.type or "", 48),
						rarity = item.rarity,
						itemFingerprint = StudyBuilds.ItemFingerprint(item),
						sockets = sockets,
						socketColorsAlwaysMatch = item.sockets and item.sockets.colourAlwaysMatches == true or false,
						mods = { },
					}
					for _, groupName in ipairs({ "implicitModLines", "explicitModLines", "craftedModLines", "eldritchModLines" }) do
						for _, line in ipairs(item[groupName] or { }) do
							if line.line and #itemInfo.mods < 24 then itemInfo.mods[#itemInfo.mods + 1] = boundedText(line.line, 200) end
						end
					end
					items[slot.selItemId] = itemInfo
				end
				slots[#slots + 1] = { slot = boundedText(slotName, 40), itemId = slot.selItemId, active = slot.active ~= false }
			end
		end
	end
	table.sort(slots, function(a, b) return a.slot < b.slot end)
	return items, slots
end

local function getAvailableItems(build)
	local itemsTab = build.itemsTab
	local itemSet = itemsTab and (itemsTab.activeItemSet or itemsTab.itemSets[itemsTab.activeItemSetId])
	local items, itemIds, truncated = { }, { }, false
	for itemId in pairs(itemsTab and itemsTab.items or { }) do itemIds[#itemIds + 1] = itemId end
	table.sort(itemIds)
	for index, itemId in ipairs(itemIds) do
		if index > 300 then truncated = true break end
		local item = itemsTab.items[itemId]
		local validSlots = { }
		if itemSet then
			for slotName, slot in pairs(itemSet) do
				-- ItemSet also stores jewel socket URLs under numeric node IDs.
				-- Those records are metadata, not equip slots, and the native
				-- validator expects a textual slot name.
				if type(slotName) == "string" and itemsTab.slots[slotName] and type(slot) == "table"
					and itemsTab:IsItemValidForSlot(item, slotName, itemSet) then
					validSlots[#validSlots + 1] = slotName
				end
			end
		end
		table.sort(validSlots)
		items[#items + 1] = {
			id = itemId,
			name = boundedText(item.name or item.title or "Unknown item", 128),
			base = boundedText(item.base and item.base.name or "", 96),
			type = boundedText(item.type or "", 48),
			rarity = item.rarity,
			validActiveSetSlots = validSlots,
		}
	end
	return items, truncated
end

local function getClassInfo(build)
	local spec = build.spec
	local class = spec.curClass or (spec.tree.classes and spec.tree.classes[spec.curClassId])
	-- The name maps are keyed by ascendancy name, not the selected numeric ID.
	-- PassiveSpec already holds the exact selected PoB class objects.
	local ascendancy = spec.curAscendClass
	local secondary = spec.curSecondaryAscendClass
	return {
		classId = spec.curClassId,
		class = spec.curClassName or class and class.name or "Unknown",
		ascendancyId = spec.curAscendClassId,
		ascendancy = spec.curAscendClassId and spec.curAscendClassId ~= 0 and ascendancy and ascendancy.name or "None",
		secondaryAscendancyId = spec.curSecondaryAscendClassId,
		secondaryAscendancy = spec.curSecondaryAscendClassId and spec.curSecondaryAscendClassId ~= 0 and secondary and secondary.name or "None",
	}
end

local function getClassOptions(tree)
	local options = { }
	for classId, class in pairs(tree.classes or { }) do
		local ascendancies = { }
		for ascendancyId, ascendancy in pairs(class.classes or { }) do
			ascendancies[#ascendancies + 1] = { id = ascendancyId, name = boundedText(ascendancy.name or "", 80) }
		end
		table.sort(ascendancies, function(a, b) return a.id < b.id end)
		options[#options + 1] = { id = classId, name = boundedText(class.name or "", 80), ascendancies = ascendancies }
	end
	table.sort(options, function(a, b) return a.id < b.id end)
	return options
end

local function getConfiguration(build)
	local configTab = build.configTab
	local configSet = configTab and configTab.configSets and configTab.configSets[configTab.activeConfigSetId]
	local source = configTab and configTab.input or configSet and configSet.input or { }
	local values, count = { }, 0
	for key, value in pairs(source) do
		if count >= 128 then break end
		if type(key) == "string" and #key <= 100 and (type(value) == "string" or type(value) == "number" or type(value) == "boolean") then
			if type(value) ~= "string" or #value <= 240 then
				values[key] = value
				count = count + 1
			end
		end
	end
	local customModifiers = { }
	for index, block in ipairs(configSet and configSet.customModsList or { }) do
		if index > 16 then break end
		customModifiers[#customModifiers + 1] = {
			enabled = block.enabled ~= false,
			title = boundedText(block.title or "", 80),
			text = boundedText(block.text or "", 1200),
		}
	end
	return {
		activeConfigSetId = configTab and configTab.activeConfigSetId or nil,
		title = boundedText(configSet and configSet.title or "", 80),
		values = values,
		customModifiers = customModifiers,
	}
end

local function getSnapshot(build)
	build = build or currentBuild()
	if not build then return nil, "Open a PoB build to use the local MCP tools" end
	local classInfo = getClassInfo(build)
	local allocatedNodes = { }
	local allocatedNodeIds = { }
	for id, node in pairs(build.spec.allocNodes) do
		allocatedNodeIds[#allocatedNodeIds + 1] = id
		allocatedNodes[#allocatedNodes + 1] = {
			id = id,
			name = boundedText(node.dn or node.name or "", 120),
			type = boundedText(node.type or "", 32),
		}
	end
	table.sort(allocatedNodes, function(a, b) return a.id < b.id end)
	table.sort(allocatedNodeIds)
	local output = build.calcsTab and build.calcsTab.mainOutput or { }
	local mainEnv = build.calcsTab and build.calcsTab.mainEnv
	local manualActionAudit = SkillActions.Evaluate(mainEnv and mainEnv.player and mainEnv.player.activeSkillList, nil)
	local metrics = exactMetrics(output)
	local activityObjective = (isFinite(output.FullDPS) and output.FullDPS > 0) and "FullDPS" or "CombinedDPS"
	local activitySustain = Activity.Evaluate({ objective = activityObjective, hard = { } },
		output.OptimizerMainSkillActivity, output.FullDPSActivity, output.FullDPSActivityTruncated)
	for key, value in pairs(activitySustain.metrics or { }) do metrics[key] = value end
	local fullDPSComponents, fullDPSBreakdownTruncated = fullDPSBreakdown(output)
	local activeSkillEntityLimits, activeSkillEntityLimitsTruncated = skillEntityLimits(output)
	local items, slots = getActiveItems(build)
	local availableItems, availableItemsTruncated = getAvailableItems(build)
	local activeGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	local mainSkillIndex = activeGroup and (activeGroup.mainActiveSkill or 1) or 1
	local mainSkill = activeGroup and activeGroup.displaySkillList and activeGroup.displaySkillList[mainSkillIndex]
	local mainSkillMechanics = getMainSkillMechanics(build, mainSkill, build.mainSocketGroup, mainSkillIndex)
	local calcsOutput = build.calcsTab and build.calcsTab.calcsOutput
	local calcsSkill = build.calcsTab and build.calcsTab.calcsEnv
		and build.calcsTab.calcsEnv.player and build.calcsTab.calcsEnv.player.mainSkill
	local calcsGroupIndex = build.calcsTab and build.calcsTab.input and build.calcsTab.input.skill_number
	local calcsGroup = calcsGroupIndex and build.skillsTab and build.skillsTab.socketGroupList[calcsGroupIndex]
	local calculationView = {
		mode = "CALCS",
		source = "PoB CalcsTab CALCS output; separate from the main build calculation",
		status = type(calcsOutput) == "table" and "available" or "unavailable",
		mainSkill = skillName(calcsSkill),
		socketGroupIndex = calcsGroupIndex,
		skillIndex = calcsGroup and calcsGroup.mainActiveSkillCalcs or nil,
		exactMetrics = exactMetrics(calcsOutput),
	}
	if isFinite(calcsSkill and calcsSkill.activeMineCount) then
		calculationView.activeMineCount = calcsSkill.activeMineCount
	end
	local mainSkillBreakdown = getMainSkillBreakdown(build, mainSkill, build.mainSocketGroup, mainSkillIndex)
	local mainSkillPayability = Validator.CheckMainSkillPayability(output, skillName(mainSkill))
	local treeVersion = build.spec.treeVersion
	local extraPoints = isFinite(output.ExtraPoints) and output.ExtraPoints or 0
	local pointLimit = getPassivePointLimit(build, build.spec:CountAllocNodes(), extraPoints)
	local classStartNodeId = build.spec.curClass and build.spec.curClass.startNodeId
	local ascendancyStartNodeIds, disconnectedNodeIds = { }, { }
	for _, ascendClass in pairs({ build.spec.curAscendClass, build.spec.curSecondaryAscendClass }) do
		if ascendClass and ascendClass.startNodeId then ascendancyStartNodeIds[#ascendancyStartNodeIds + 1] = ascendClass.startNodeId end
	end
	table.sort(ascendancyStartNodeIds)
	for id, node in pairs(build.spec.allocNodes or { }) do
		if node and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" and node.connectedToStart == false then
			disconnectedNodeIds[#disconnectedNodeIds + 1] = id
		end
	end
	table.sort(disconnectedNodeIds)
	return {
		connected = true,
		buildReadiness = BuildReadiness.Evaluate(build),
		supportFeatureSchemaVersion = 2,
		dataVersion = Version.Data(build),
		treeVersion = treeVersion,
		characterLevel = build.characterLevel,
		class = classInfo,
		classStartNodeId = classStartNodeId,
		ascendancyStartNodeIds = ascendancyStartNodeIds,
		classOptions = getClassOptions(build.spec.tree),
		mainSkill = skillName(mainSkill),
		mainSkillMechanics = mainSkillMechanics,
		calculationView = calculationView,
		mainSkillBreakdown = mainSkillBreakdown,
		optimizerPreferences = {
			damageFocus = build.optimizerTab and build.optimizerTab.textValues and build.optimizerTab.textValues.damageFocus or "Auto",
			defenseProfile = build.optimizerTab and build.optimizerTab.textValues and build.optimizerTab.textValues.defenseProfile or "Auto",
			rankingPriority = build.optimizerTab and build.optimizerTab.textValues and build.optimizerTab.textValues.rankingPriority or "ObjectiveFirst",
		},
		configuration = getConfiguration(build),
		mainSkillPayability = mainSkillPayability,
		requirements = Validator.CheckRequirements(output, build.characterLevel),
		fullDPSPayability = fullDPSPayability(output),
		skillCostAudit = output.OptimizerSkillCostAudit or {
			status = "unsupported",
			exactPoBValues = false,
			aggregation = "per_skill_only",
			upfrontPayabilityStatus = "unsupported",
			recurringStatus = "unsupported",
			skills = { },
			violations = { },
			reason = "PoB did not expose the exact per-skill cost audit for this calculation",
		},
		activitySustain = activitySustain,
		manualActionAudit = manualActionAudit,
		mainSocketGroup = build.mainSocketGroup,
		passivePointsUsed = build.spec:CountAllocNodes(),
		passivePointLimit = pointLimit,
		allocatedNodeIds = allocatedNodeIds,
		allocatedNodes = allocatedNodes,
		disconnectedAllocatedNodeIds = disconnectedNodeIds,
		masterySelections = build.spec.masterySelections,
		activeSkills = getActiveSkills(build),
		skillGroups = getSkillGroups(build),
		itemSetId = build.itemsTab.activeItemSetId,
		items = items,
		availableItems = availableItems,
		availableItemsTruncated = availableItemsTruncated,
		equippedSlots = slots,
		exactMetrics = metrics,
		fullDPSBreakdown = fullDPSComponents,
		fullDPSBreakdownTruncated = fullDPSBreakdownTruncated,
		activeSkillEntityLimits = activeSkillEntityLimits,
		activeSkillEntityLimitsTruncated = activeSkillEntityLimitsTruncated,
	}
end

local comparisonRegistry
local studyBuildIndex

local function resolveBuildReference(studyId, errorContext, comparisonId)
	if studyId ~= nil and comparisonId ~= nil then
		return nil, "Provide either studyId or comparisonId, not both"
	end
	if comparisonId ~= nil then
		if type(comparisonId) ~= "string" or #comparisonId < 1 or #comparisonId > 96 then
			return nil, "comparisonId must be a valid local comparison ID"
		end
		if not comparisonRegistry then return nil, "Local PoB comparison builds are unavailable" end
		local registry, registryError = comparisonRegistry()
		if not registry then return nil, registryError end
		local entry = registry.byId[comparisonId]
		local index = entry and studyBuildIndex(registry.compareTab, entry)
		if not index then
			if entry then
				registry.byId[comparisonId] = nil
				registry.idByEntry[entry] = nil
			end
			return nil, "The local comparison entry was removed or belongs to a different active build"
		end
		return entry, {
			referenceType = "native_comparison",
			comparisonId = comparisonId,
			label = boundedText(entry.label or entry.buildName or "Comparison build", 120),
			index = index,
		}
	end
	if studyId == nil then
		local build = currentBuild()
		if not build then return nil, "Open a PoB build to " .. errorContext end
		return build, nil
	end
	if type(studyId) ~= "string" or #studyId < 1 or #studyId > 96 then return nil, "studyId must be a valid imported build study ID" end
	local record = bridge.studyBuilds and bridge.studyBuilds[studyId]
	if not record or not record.entry or not record.compareTab then return nil, "Unknown public build study" end
	local stillPresent = false
	for _, entry in ipairs(record.compareTab.compareEntries or { }) do
		if entry == record.entry then stillPresent = true break end
	end
	if not stillPresent then
		bridge.studyBuilds[studyId] = nil
		return nil, "The comparison entry was removed from PoB"
	end
	return record.entry, record
end

local function resolveParamsBuild(params, errorContext)
	return resolveBuildReference(params.studyId, errorContext, params.comparisonId)
end

local function experimentSource(source)
	if not source then return { type = "active_build" } end
	if source.referenceType == "native_comparison" then
		return {
			type = "native_comparison_build",
			comparisonId = source.comparisonId,
			label = source.label,
			index = source.index,
		}
	end
	return {
		type = "public_build_study",
		studyId = source.id,
		provider = source.provider,
		sourceUrl = boundedText(source.url, 2048),
		label = boundedText(source.label, 100),
		importedAt = source.importedAt,
	}
end

local function getPassiveNode(params)
	local build, sourceOrError = resolveParamsBuild(params, "inspect its passive tree")
	if not build then return nil, sourceOrError end
	local nodeId = tonumber(params and params.nodeId)
	if not nodeId or nodeId ~= math.floor(nodeId) then return nil, "nodeId must be an integer" end
	local node = build.spec.nodes[nodeId]
	if not node then return nil, "The node does not exist in the active passive tree" end
	local regionByNode = TreeSearch.BuildRegionMap(build.spec)
	local links = { }
	for _, other in ipairs(node.linked or { }) do
		links[#links + 1] = {
			id = other.id,
			name = boundedText(other.dn or other.name or "", 120),
			type = boundedText(other.type or "", 32),
			allocated = not not build.spec.allocNodes[other.id],
		}
	end
	table.sort(links, function(a, b) return a.id < b.id end)
	local stats = { }
	for _, value in ipairs(node.sd or { }) do stats[#stats + 1] = boundedText(value, 240) end
	return {
		id = node.id,
		name = boundedText(node.dn or node.name or "", 120),
		type = boundedText(node.type or "", 32),
		allocated = not not build.spec.allocNodes[node.id],
		isActiveBuild = build == currentBuild(),
		buildReference = experimentSource(sourceOrError),
		treeVersion = build.spec.treeVersion,
		region = boundedText(node.ascendancyName or regionByNode[node.id] or "Passive tree", 80),
		stats = stats,
		neighbors = links,
	}
end

local function searchPassiveNodes(params)
	local build, sourceOrError = resolveParamsBuild(params, "search its passive tree")
	if not build then return nil, sourceOrError end
	local query = tostring(params.query or ""):match("^%s*(.-)%s*$")
	if #query < 2 or #query > 100 then return nil, "query must contain between 2 and 100 characters" end
	local regionFilter = tostring(params.region or ""):lower()
	if #regionFilter > 80 then return nil, "region filter is too long" end
	local limit = tonumber(params.limit) or 30
	if not isFinite(limit) or limit ~= math.floor(limit) or limit < 1 or limit > 100 then return nil, "limit must be an integer between 1 and 100" end
	query = query:lower()
	local regionByNode = TreeSearch.BuildRegionMap(build.spec)
	local matches = { }
	for nodeId, node in pairs(build.spec.nodes) do
		if not node.isProxy and node.type ~= "ClassStart" and node.type ~= "AscendClassStart" then
			local region = tostring(node.ascendancyName or regionByNode[nodeId] or "")
			if regionFilter == "" or region:lower():find(regionFilter, 1, true) then
				local nodeName = tostring(node.dn or node.name or "")
				local score
				if nodeName:lower():find(query, 1, true) then
					score = 0
				else
					for _, stat in ipairs(node.sd or { }) do
						if tostring(stat):lower():find(query, 1, true) then score = 1 break end
					end
				end
				if score then matches[#matches + 1] = { id = nodeId, name = nodeName, type = node.type, allocated = not not build.spec.allocNodes[nodeId], region = region, stats = node.sd or { }, score = score } end
			end
		end
	end
	table.sort(matches, function(a, b) if a.score ~= b.score then return a.score < b.score end return a.id < b.id end)
	local results = { }
	for index = 1, math.min(limit, #matches) do
		local match = matches[index]
		local stats = { }
		for statIndex = 1, math.min(12, #match.stats) do stats[statIndex] = boundedText(match.stats[statIndex], 240) end
		results[index] = { id = match.id, name = boundedText(match.name, 120), type = boundedText(match.type, 32), allocated = match.allocated, region = boundedText(match.region, 80), stats = stats }
	end
	return { query = params.query, region = params.region, treeVersion = build.spec.treeVersion,
		isActiveBuild = build == currentBuild(), buildReference = experimentSource(sourceOrError),
		totalMatches = #matches, truncated = #matches > #results, nodes = results }
end

local function resolveStudyBuild(params)
	return resolveParamsBuild(params, "evaluate a passive-tree change")
end

local function activityForOutput(output)
	local objective = (isFinite(output and output.FullDPS) and output.FullDPS > 0) and "FullDPS" or "CombinedDPS"
	return Activity.Evaluate({ objective = objective, hard = { } },
		output and output.OptimizerMainSkillActivity, output and output.FullDPSActivity, output and output.FullDPSActivityTruncated)
end

local function evaluateActivitySchedule(params)
	local build, referenceOrError = resolveParamsBuild(params, "evaluate a skill activity schedule")
	if not build then return nil, referenceOrError end
	local output = build.calcsTab and build.calcsTab.mainOutput
	if type(output) ~= "table" then return nil, "PoB has no current calculation output for the active build" end
	local scope = params.scope or "full_dps"
	if scope ~= "main_skill" and scope ~= "full_dps" and scope ~= "all_enabled_skills" then return nil, "scope must be main_skill, full_dps, or all_enabled_skills" end
	local mainRecord, fullRecords, truncated, costRecords
	if scope == "main_skill" then
		mainRecord = output.OptimizerMainSkillActivity
		fullRecords, truncated = { }, false
	elseif scope == "all_enabled_skills" then
		local audit = output.OptimizerSkillCostAudit
		if type(audit) ~= "table" then return nil, "PoB did not expose its enabled-skill cost audit" end
		if type(audit.scheduleUnsupportedReason) == "string" and audit.scheduleUnsupportedReason ~= "" then return nil, audit.scheduleUnsupportedReason end
		costRecords, truncated = audit.scheduleActivities, audit.scheduleTruncated == true
		fullRecords = { }
	else
		fullRecords, truncated = output.FullDPSActivity, output.FullDPSActivityTruncated
	end
	local objective = scope == "main_skill" and "CombinedDPS" or scope == "all_enabled_skills" and "ResourceSustain" or "FullDPS"
	local result, scheduleError = Activity.EvaluateSchedule({ objective = objective, hard = { } }, mainRecord, fullRecords, truncated, params.activities, costRecords)
	if not result then return nil, scheduleError end
	result.scope = scope
	result.readOnly = true
	result.isActiveBuild = build == currentBuild()
	result.buildReference = experimentSource(referenceOrError)
	result.activeBuildPreserved = true
	result.exactPoBActivityRates = true
	result.damageScheduleCertified = false
	return result
end

local function allocatedNodeIds(spec)
	local ids = { }
	for id in pairs(spec.allocNodes or { }) do ids[#ids + 1] = id end
	table.sort(ids)
	return ids
end

local function evaluatePassiveDelta(params, recordExperiment)
	local build, studySource = resolveStudyBuild(params)
	if not build then return nil, studySource end
	local addNodeIds, addError = parseNodeIdList(params.addNodeIds, "addNodeIds")
	if not addNodeIds then return nil, addError end
	local removeNodeIds, removeError = parseNodeIdList(params.removeNodeIds, "removeNodeIds")
	if not removeNodeIds then return nil, removeError end
	if #addNodeIds + #removeNodeIds == 0 then return nil, "Provide at least one passive node to add or remove" end
	if recordExperiment and #addNodeIds + #removeNodeIds ~= 1 then
		return nil, "A recorded experiment must change exactly one passive node so the result remains one-factor"
	end
	local label = params.label
	if recordExperiment then
		if label ~= nil and (type(label) ~= "string" or #label > 120 or label:find("[%c]")) then
			return nil, "label must be plain text of at most 120 characters"
		end
		label = label and label:match("^%s*(.-)%s*$") or ""
	end
	local addSet, removeSet = { }, { }
	for _, nodeId in ipairs(addNodeIds) do addSet[nodeId] = true end
	for _, nodeId in ipairs(removeNodeIds) do
		if addSet[nodeId] then return nil, "A passive node cannot be added and removed in the same request: " .. tostring(nodeId) end
		removeSet[nodeId] = true
	end
	local parsed = Inputs.Parse({ })
	local validTree, treeError = Inputs.ValidateAgainstTree(parsed, build.spec.tree)
	if not validTree then return nil, treeError end
	local validBuild, buildError = Inputs.ValidateAgainstBuild(parsed, build.spec)
	if not validBuild then return nil, buildError end
	for _, nodeId in ipairs(addNodeIds) do
		local node = build.spec.nodes[nodeId]
		if not node then return nil, "Passive node does not exist in the active PoB tree: " .. tostring(nodeId) end
		if node.type == "Mastery" or node.type == "Socket" or node.isProxy or node.isMultipleChoiceOption or node.isTattoo
			or node.type == "ClassStart" or node.type == "AscendClassStart" then
			return nil, "Node addition requires its typed PoB control or a supported node type: " .. tostring(nodeId)
		end
	end
	for _, nodeId in ipairs(removeNodeIds) do
		if not build.spec.allocNodes[nodeId] then return nil, "Node selected for removal is not allocated: " .. tostring(nodeId) end
	end
	local proxy, proxyError = Candidate.BuildPassiveSpec(build, addNodeIds, removeNodeIds)
	if not proxy then return nil, proxyError end
	local validCandidate, candidateError = TreeSearch.ValidateCandidate(build.spec, proxy.optimizerAddedNodeIds, parsed,
		TreeSearch.BuildRegionMap(build.spec), proxy.optimizerRemovedNodeIds, proxy)
	if not validCandidate then return nil, candidateError end
	local sourceSignature = Candidate.BuildSignature(build)
	local currentOutput = build.calcsTab and build.calcsTab.mainOutput or { }
	local calcFunc, baselineOutput, baselineEnv = Calcs.getMiscCalculator(build)
	local candidateOutput, candidateEnv = calcFunc({ spec = proxy, returnEnv = true })
	local baselineExtraPoints = exactPassiveExtraPoints(build, baselineOutput, baselineEnv, currentOutput.ExtraPoints)
	local extraPoints = exactPassiveExtraPoints(build, candidateOutput, candidateEnv, baselineExtraPoints)
	if not isFinite(extraPoints) then return nil, "PoB did not expose exact passive ExtraPoints for the candidate" end
	local pointLimit = getPassivePointLimit(build, proxy:CountAllocNodes(), extraPoints)
	if proxy:CountAllocNodes() > pointLimit then return nil, "The projected tree exceeds PoB's exact passive-point limit" end
	local signatureOk, afterSignature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or afterSignature ~= sourceSignature then return nil, "The source build changed during the isolated passive comparison" end
	local baselineMetrics = exactMetrics(baselineOutput)
	local candidateMetrics = exactMetrics(candidateOutput)
	local mainGroup = build.skillsTab and build.skillsTab.socketGroupList[build.mainSocketGroup]
	local mainSkill = mainGroup and mainGroup.displaySkillList and mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
	local baselineRequirements = Validator.CheckRequirements(baselineOutput, build.characterLevel)
	local candidateRequirements = Validator.CheckRequirements(candidateOutput, build.characterLevel)
	local baselinePayability = Validator.CheckMainSkillPayability(baselineOutput, skillName(mainSkill))
	local candidatePayability = Validator.CheckMainSkillPayability(candidateOutput, skillName(mainSkill))
	local baselineActivity = activityForOutput(baselineOutput)
	local candidateActivity = activityForOutput(candidateOutput)
	local mainEffect = skillEffect(mainSkill)
	local mainEffectId = mainEffect and mainEffect.grantedEffect and mainEffect.grantedEffect.id
	local mainSkillDamageComparison = {
		status = "unsupported",
		name = skillName(mainSkill),
		source = "Exact baseline and candidate environments from Calcs.getMiscCalculator",
	}
	if baselineEnv and candidateEnv and mainSkill and mainEffectId then
		mainSkillDamageComparison.player = compareNumericSkillDamage(baselineEnv.player, candidateEnv.player, "player", mainEffectId)
		mainSkillDamageComparison.status = mainSkillDamageComparison.player.status
		mainSkillDamageComparison.reason = mainSkillDamageComparison.player.reason
		if baselineEnv.minion or candidateEnv.minion then
			mainSkillDamageComparison.minion = compareNumericSkillDamage(baselineEnv.minion, candidateEnv.minion, "minion")
		end
	else
		mainSkillDamageComparison.reason = "PoB did not expose matching baseline/candidate environments for the selected Main Skill"
	end
	local result = {
		readOnly = true,
		activeBuildPreserved = true,
		isActiveBuild = build == currentBuild(),
		buildReference = experimentSource(studySource),
		dataVersion = Version.Data(build),
		treeVersion = build.spec.treeVersion,
		addedNodeIds = proxy.optimizerAddedNodeIds,
		removedNodeIds = proxy.optimizerRemovedNodeIds,
		classStartNodeId = build.spec.curClass and build.spec.curClass.startNodeId,
		ascendancyStartNodeIds = getSnapshot(build).ascendancyStartNodeIds,
		passivePointsUsed = proxy:CountAllocNodes(),
		passivePointLimit = pointLimit,
		baselineMetrics = baselineMetrics,
		candidateMetrics = candidateMetrics,
		metricDelta = metricDelta(baselineMetrics, candidateMetrics),
		mainSkillDamageComparison = mainSkillDamageComparison,
	}
	if recordExperiment then
		local snapshot, snapshotError = getSnapshot(build)
		if not snapshot then return nil, snapshotError end
		snapshot.exactMetrics = baselineMetrics
		snapshot.availableItems = nil
		snapshot.availableItemsTruncated = nil
		snapshot.classOptions = nil
		snapshot.requirements = baselineRequirements
		snapshot.mainSkillPayability = baselinePayability
		snapshot.activitySustain = baselineActivity
		local useRequirementsFeasible = baselineRequirements.feasible and candidateRequirements.feasible
			and baselinePayability.feasible and candidatePayability.feasible
		local record = {
			kind = "passive_node_pair",
			label = label ~= "" and label or "One-node passive comparison",
			source = experimentSource(studySource),
			engine = {
				pobVersion = launch and launch.versionNumber or nil,
				pobBranch = Version.Branch(),
				dataVersion = Version.Data(build),
				treeVersion = build.spec.treeVersion,
				manifestFingerprint = launch and launch.manifestFingerprint or nil,
				lookupTableStatus = "not_audited",
			},
			buildState = snapshot,
			experiment = {
				unit = "one_passive_node",
				label = label ~= "" and label or nil,
				addedNodeIds = proxy.optimizerAddedNodeIds,
				removedNodeIds = proxy.optimizerRemovedNodeIds,
				passivePointsUsed = proxy:CountAllocNodes(),
				passivePointLimit = pointLimit,
				allocatedNodeIds = allocatedNodeIds(proxy),
			},
			baseline = {
				metrics = baselineMetrics,
				requirements = baselineRequirements,
				mainSkillPayability = baselinePayability,
				activitySustain = baselineActivity,
			},
			candidate = {
				metrics = candidateMetrics,
				requirements = candidateRequirements,
				mainSkillPayability = candidatePayability,
				activitySustain = candidateActivity,
				passivePointsUsed = proxy:CountAllocNodes(),
				allocatedNodeIds = allocatedNodeIds(proxy),
			},
			metricDelta = result.metricDelta,
			mainSkillDamageComparison = result.mainSkillDamageComparison,
			admission = {
				exactCalculated = true,
				useRequirementsFeasible = useRequirementsFeasible,
				activityStatus = candidateActivity.status,
				activityRatesFeasible = candidateActivity.status == "pass",
				activitySustainCertified = false,
				scenarioConditionsCertified = false,
				lookupTablesCertified = false,
				trainingEligible = false,
			},
		}
		local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
		if not stored then return nil, storeError end
		result.recordId = stored.recordId
		result.storeFile = stored.storeFile
		result.recorded = stored.duplicate ~= true
		result.duplicate = stored.duplicate == true
	end
	return result
end

local function sameNodeSet(actual, expected)
	if type(actual) ~= "table" or type(expected) ~= "table" or #actual ~= #expected then return false end
	local expectedSet = { }
	for _, nodeId in ipairs(expected) do expectedSet[nodeId] = true end
	for _, nodeId in ipairs(actual) do
		if not expectedSet[nodeId] then return false end
		expectedSet[nodeId] = nil
	end
	return next(expectedSet) == nil
end

local function buildFactorialPassiveSpec(build, nodeIds)
	if type(nodeIds) ~= "table" or #nodeIds < 1 or #nodeIds > 2 then
		return nil, "A factorial cell must add one or two declared passive nodes"
	end
	local addSet = { }
	for _, nodeId in ipairs(nodeIds) do
		local node = build.spec.nodes[nodeId]
		if not node then return nil, "Passive node does not exist in the selected PoB tree: " .. tostring(nodeId) end
		if build.spec.allocNodes[nodeId] then return nil, "Factorial passive node is already allocated: " .. tostring(nodeId) end
		if node.type == "Mastery" or node.type == "Socket" or node.isProxy or node.isMultipleChoiceOption
			or node.isTattoo or node.type == "ClassStart" or node.type == "AscendClassStart" or node.ascendancyName then
			return nil, "Factorial factors currently require ordinary passive nodes; use the typed PoB operation for masteries, sockets, class starts, or ascendancy nodes"
		end
		if addSet[nodeId] then return nil, "Factorial passive factors must use two distinct nodes" end
		addSet[nodeId] = true
	end
	local parsed = Inputs.Parse({ })
	local validTree, treeError = Inputs.ValidateAgainstTree(parsed, build.spec.tree)
	if not validTree then return nil, treeError end
	local validBuild, buildError = Inputs.ValidateAgainstBuild(parsed, build.spec)
	if not validBuild then return nil, buildError end
	local proxy, proxyError = Candidate.BuildPassiveSpec(build, nodeIds, { })
	if not proxy then return nil, proxyError end
	if not sameNodeSet(proxy.optimizerAddedNodeIds, nodeIds) or #(proxy.optimizerRemovedNodeIds or { }) > 0 then
		return nil, "This factorial study accepts only directly connected nodes; PoB path repair would add or remove extra passives"
	end
	local validCandidate, candidateError = TreeSearch.ValidateCandidate(build.spec, proxy.optimizerAddedNodeIds,
		parsed, TreeSearch.BuildRegionMap(build.spec), proxy.optimizerRemovedNodeIds, proxy)
	if not validCandidate then return nil, candidateError end
	return proxy
end

local function exactFactorialCell(build, output, env, spec, fallbackExtraPoints)
	if type(output) ~= "table" then return nil, "PoB did not expose an exact metric output" end
	local metrics = exactMetrics(output)
	local requirements = Validator.CheckRequirements(output, build.characterLevel)
	local mainGroup = build.skillsTab and build.skillsTab.socketGroupList[build.mainSocketGroup]
	local mainSkill = mainGroup and mainGroup.displaySkillList and mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
	local payability = Validator.CheckMainSkillPayability(output, skillName(mainSkill))
	local sustain = activityForOutput(output)
	local pointsUsed = spec and spec:CountAllocNodes() or build.spec:CountAllocNodes()
	local extraPoints = exactPassiveExtraPoints(build, output, env, fallbackExtraPoints)
	if not isFinite(extraPoints) then return nil, "PoB did not expose exact passive ExtraPoints for this factorial cell" end
	local pointLimit = getPassivePointLimit(build, pointsUsed, extraPoints)
	if pointsUsed > pointLimit then return nil, "The factorial cell exceeds PoB's exact passive-point limit" end
	return {
		metrics = metrics,
		requirements = requirements,
		mainSkillPayability = payability,
		activitySustain = sustain,
		passivePointsUsed = pointsUsed,
		passivePointLimit = pointLimit,
		extraPassivePoints = extraPoints,
	}
end

local function runPassiveFactorialStudy(job)
	local calcFunc, baselineOutput, baselineEnv = Calcs.getMiscCalculator(job.build)
	if type(calcFunc) ~= "function" or type(baselineOutput) ~= "table" then error("PoB exact baseline calculation is unavailable") end
	local baseline, baselineError = exactFactorialCell(job.build, baselineOutput, baselineEnv)
	if not baseline then error("PoB exact baseline cell could not be captured: " .. tostring(baselineError)) end
	job.cells.baseline = baseline
	job.completedCells = 1
	job.progress = { phase = "Exact PoB calculation", currentCell = "baseline", completedCells = 1, totalCells = 4 }
	coroutine.yield(job.progress)

	local nodesByCell = {
		factorA = { job.factorANodeId },
		factorB = { job.factorBNodeId },
		combined = { job.factorANodeId, job.factorBNodeId },
	}
	for _, cellName in ipairs({ "factorA", "factorB", "combined" }) do
		if job.cancelRequested then job.status = "cancelled" return end
		local proxy, proxyError = buildFactorialPassiveSpec(job.build, nodesByCell[cellName])
		if not proxy then error(cellName .. " cell is not a legal one-node factor: " .. tostring(proxyError)) end
		local candidateOutput, candidateEnv = calcFunc({ spec = proxy, returnEnv = true })
		if type(candidateOutput) ~= "table" then error("PoB returned no exact output for the " .. cellName .. " cell") end
		local candidate, candidateError = exactFactorialCell(job.build, candidateOutput, candidateEnv, proxy,
			baseline.extraPassivePoints)
		if not candidate then error("PoB exact " .. cellName .. " cell could not be captured: " .. tostring(candidateError)) end
		job.cells[cellName] = candidate
		job.completedCells = job.completedCells + 1
		job.progress = { phase = "Exact PoB calculation", currentCell = cellName, completedCells = job.completedCells, totalCells = 4 }
		coroutine.yield(job.progress)
	end

	local unchanged, afterSignature = pcall(Candidate.BuildSignature, job.build)
	if not unchanged or afterSignature ~= job.sourceSignature then
		error("The source build changed during the read-only factorial study")
	end
	local interaction, interactionError = FactorialStudy.Compute(job.cells)
	if not interaction then error(interactionError) end
	local snapshot, snapshotError = getSnapshot(job.build)
	if not snapshot then error(snapshotError or "The PoB source snapshot is unavailable") end
	snapshot.exactMetrics = job.cells.baseline.metrics
	snapshot.availableItems = nil
	snapshot.availableItemsTruncated = nil
	snapshot.classOptions = nil
	snapshot.requirements = job.cells.baseline.requirements
	snapshot.mainSkillPayability = job.cells.baseline.mainSkillPayability
	snapshot.activitySustain = job.cells.baseline.activitySustain
	local allRequirementsFeasible, allActivityRatesFeasible = true, true
	for _, cellName in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
		local cell = job.cells[cellName]
		allRequirementsFeasible = allRequirementsFeasible and cell.requirements.feasible == true and cell.mainSkillPayability.feasible == true
		allActivityRatesFeasible = allActivityRatesFeasible and cell.activitySustain.status == "pass"
	end
	local combined = job.cells.combined
	local record = {
		kind = "passive_factorial_interaction",
		label = job.label ~= "" and job.label or "Two-node passive factorial study",
		source = experimentSource(job.studySource),
		engine = {
			pobVersion = launch and launch.versionNumber or nil,
			pobBranch = Version.Branch(),
			dataVersion = Version.Data(job.build),
			treeVersion = job.build.spec.treeVersion,
			manifestFingerprint = launch and launch.manifestFingerprint or nil,
			lookupTableStatus = "not_audited",
		},
		buildState = snapshot,
		experiment = {
			unit = "four_cell_passive_factorial",
			factorialSchemaVersion = 1,
			formula = interaction.formula,
			factorA = { operation = "add_passive_node", nodeId = job.factorANodeId },
			factorB = { operation = "add_passive_node", nodeId = job.factorBNodeId },
			changedVariables = { "passiveNodeA", "passiveNodeB" },
		},
		baseline = {
			metrics = job.cells.baseline.metrics,
			requirements = job.cells.baseline.requirements,
			mainSkillPayability = job.cells.baseline.mainSkillPayability,
			activitySustain = job.cells.baseline.activitySustain,
		},
		candidate = {
			metrics = combined.metrics,
			requirements = combined.requirements,
			mainSkillPayability = combined.mainSkillPayability,
			activitySustain = combined.activitySustain,
			passivePointsUsed = combined.passivePointsUsed,
		},
		factorial = {
			formula = interaction.formula,
			cells = {
				factorA = { metrics = job.cells.factorA.metrics, passivePointsUsed = job.cells.factorA.passivePointsUsed },
				factorB = { metrics = job.cells.factorB.metrics, passivePointsUsed = job.cells.factorB.passivePointsUsed },
			},
			interaction = interaction.metrics,
			metricCount = interaction.metricCount,
		},
		metricDelta = metricDelta(job.cells.baseline.metrics, combined.metrics),
		admission = {
			exactCalculated = true,
			useRequirementsFeasible = allRequirementsFeasible,
			activityStatus = combined.activitySustain.status,
			activityRatesFeasible = allActivityRatesFeasible,
			activitySustainCertified = false,
			scenarioConditionsCertified = false,
			lookupTablesCertified = false,
			trainingEligible = false,
		},
	}
	local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
	if not stored then error(storeError or "PoB could not store the factorial study") end
	job.result = {
		status = "exact_factorial_recorded",
		readOnly = true,
		activeBuildPreserved = true,
		isActiveBuild = job.build == currentBuild(),
		buildReference = experimentSource(job.studySource),
		factorANodeId = job.factorANodeId,
		factorBNodeId = job.factorBNodeId,
		formula = interaction.formula,
		cells = job.cells,
		interaction = interaction.metrics,
		interactionMetricCount = interaction.metricCount,
		recordId = stored.recordId,
		storeFile = stored.storeFile,
		recorded = stored.duplicate ~= true,
		duplicate = stored.duplicate == true,
		trainingEligible = false,
	}
	job.status = "completed"
	job.completedAt = os.time()
end

local function shallowClone(source)
	local clone = { }
	for key, value in pairs(source or { }) do clone[key] = value end
	return setmetatable(clone, getmetatable(source))
end

local function cloneTriggeredDefinition(definition)
	if type(definition) ~= "table" then return definition end
	local cloned = shallowClone(definition)
	if type(definition.levels) == "table" then
		cloned.levels = { }
		for level, levelData in pairs(definition.levels) do cloned.levels[level] = shallowClone(levelData) end
	end
	if type(definition.grantedEffect) == "table" then
		cloned.grantedEffect = shallowClone(definition.grantedEffect)
		if type(definition.grantedEffect.levels) == "table" then
			cloned.grantedEffect.levels = { }
			for level, levelData in pairs(definition.grantedEffect.levels) do
				cloned.grantedEffect.levels[level] = shallowClone(levelData)
			end
		end
	end
	return cloned
end

local function buildSkillSupportProxy(build, job, changeSkill, changeSupport)
	local skillsTab = shallowClone(build.skillsTab)
	local groups = { }
	for groupIndex, sourceGroup in ipairs(build.skillsTab.socketGroupList or { }) do
		local group = shallowClone(sourceGroup)
		group.gemList = { }
		for gemIndex, sourceGem in ipairs(sourceGroup.gemList or { }) do
			group.gemList[gemIndex] = shallowClone(sourceGem)
		end
		groups[groupIndex] = group
	end
	skillsTab.socketGroupList = groups
	local proxy = shallowClone(build)
	proxy.skillsTab = skillsTab
	setmetatable(proxy, { __index = build })
	skillsTab.build = proxy
	local proxyData = shallowClone(build.data)
	proxyData.gems = shallowClone(build.data and build.data.gems)
	proxyData.skills = shallowClone(build.data and build.data.skills)
	proxy.data = proxyData
	local group = groups[job.groupIndex]
	if not group then return nil, "The selected PoB skill group disappeared while cloning the study build" end
	local skillGem = group.gemList[job.skillGemIndex]
	local supportGem = group.gemList[job.supportGemIndex]
	if not skillGem or not supportGem then return nil, "The selected skill or support slot disappeared while cloning the study build" end
	if changeSkill then
		local gemData = proxyData.gems[job.alternateSkillGemId]
		skillGem.gemId = gemData.id
		skillGem.skillId = gemData.grantedEffectId
		skillGem.nameSpec = gemData.name
		skillGem.gemData = gemData
		skillGem.grantedEffect = gemData.grantedEffect
	end
	if changeSupport then
		local gemData = proxyData.gems[job.alternateSupportGemId]
		supportGem.gemId = gemData.id
		supportGem.skillId = gemData.grantedEffectId
		supportGem.nameSpec = gemData.name
		supportGem.gemData = gemData
		supportGem.grantedEffect = gemData.grantedEffect
	end
	-- Include the replacement definitions in this isolated copy as well: a
	-- triggered replacement gem can exercise the same native cost reset during
	-- ProcessSocketGroup as a triggered source gem.
	local clonedTriggeredGems, clonedTriggeredSkills = { }, { }
	for _, candidateGroup in ipairs(groups) do
		for _, gem in ipairs(candidateGroup.gemList or { }) do
			if gem.triggered then
				if gem.gemId and proxyData.gems[gem.gemId] and not clonedTriggeredGems[gem.gemId] then
					proxyData.gems[gem.gemId] = cloneTriggeredDefinition(proxyData.gems[gem.gemId])
					clonedTriggeredGems[gem.gemId] = true
				elseif gem.skillId and proxyData.skills[gem.skillId] and not clonedTriggeredSkills[gem.skillId] then
					proxyData.skills[gem.skillId] = cloneTriggeredDefinition(proxyData.skills[gem.skillId])
					clonedTriggeredSkills[gem.skillId] = true
				end
			end
		end
	end
	if type(skillsTab.ProcessSocketGroup) ~= "function" then
		return nil, "PoB's native socket-group processor is unavailable for the isolated skill study"
	end
	for _, candidateGroup in ipairs(groups) do skillsTab:ProcessSocketGroup(candidateGroup) end
	if type(skillsTab.UpdateSocketGroups) == "function" then skillsTab:UpdateSocketGroups() end
	local activeEffectId = changeSkill and job.alternateSkillEffectId or job.sourceSkillEffectId
	local activeSkillIndex = SkillCatalog.ResolveMainSkillIndex(group, job.skillGemIndex, activeEffectId)
	if not activeSkillIndex then
		return nil, "PoB did not resolve the requested Main Skill effect after processing the isolated socket group"
	end
	group.mainActiveSkill = activeSkillIndex
	proxy.mainSocketGroup = job.groupIndex
	return proxy, group
end

local function selectedSkillAndSupport(env, group, effectId, supportGemIndex, groupIndex, includeContext)
	local matches = { }
	for _, activeSkill in ipairs(env and env.player and env.player.activeSkillList or { }) do
		local activeEffect = activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
		if activeSkill.socketGroup == group and activeEffect and activeEffect.id == effectId then
			matches[#matches + 1] = activeSkill
		end
	end
	if #matches ~= 1 then
		return nil, "PoB did not expose one unambiguous active skill for the requested effect"
	end
	local activeSkill = matches[1]
	if env.player.mainSkill ~= activeSkill then
		return nil, "PoB calculated a different Main Skill from the requested skill/support interaction"
	end
	local supportGem = group.gemList and group.gemList[supportGemIndex]
	if not supportGem then return nil, "The requested support gem instance is missing from the calculated socket group" end
	local applied = false
	for _, effect in ipairs(activeSkill.effectList or { }) do
		if effect and effect.srcInstance == supportGem and effect.grantedEffect and effect.grantedEffect.support then
			applied = true
			break
		end
	end
	if not applied then return nil, "PoB did not apply the selected support to the requested active skill" end
	local activeEffect = activeSkill.activeEffect.grantedEffect
	local result = {
		name = boundedText(activeEffect.name or "", 120),
		effectId = tostring(activeEffect.id or ""),
		gemId = tostring(activeSkill.activeEffect.srcInstance and activeSkill.activeEffect.srcInstance.gemData
			and activeSkill.activeEffect.srcInstance.gemData.id or ""),
		supportGemId = tostring(supportGem.gemData and supportGem.gemData.id or supportGem.gemId or ""),
		supportName = boundedText(supportGem.gemData and supportGem.gemData.name or supportGem.nameSpec or "", 120),
		supportApplied = true,
	}
	if includeContext then
		local skillGemIndex
		for index, gem in ipairs(group.gemList or { }) do
			if activeSkill.activeEffect.srcInstance == gem then skillGemIndex = index break end
		end
		local appliedSupportIds, appliedSupportEffects, socketedSupportIds = { }, { }, { }
		for _, gem in ipairs(group.gemList or { }) do
			local gemData = gem.gemData or { }
			local definition = gem.grantedEffect or gemData.grantedEffect
			if definition and definition.support then
				local gemId = tostring(gemData.id or gem.gemId or "")
				if gemId ~= "" then socketedSupportIds[#socketedSupportIds + 1] = gemId end
			end
		end
		for _, effect in ipairs(activeSkill.effectList or { }) do
			if effect and effect.srcInstance and effect.grantedEffect and effect.grantedEffect.support then
				local gemData = effect.srcInstance.gemData or { }
				local gemId = tostring(gemData.id or effect.srcInstance.gemId or "")
				local effectId = tostring(effect.grantedEffect.id or "")
				if gemId ~= "" and effectId ~= "" then
					appliedSupportIds[#appliedSupportIds + 1] = gemId
					appliedSupportEffects[#appliedSupportEffects + 1] = effectId
				end
			end
		end
		result.isMainSkill = true
		result.groupIndex = groupIndex
		result.gemIndex = skillGemIndex
		result.level = tonumber(activeSkill.activeEffect.srcInstance and activeSkill.activeEffect.srcInstance.level)
		result.quality = tonumber(activeSkill.activeEffect.srcInstance and activeSkill.activeEffect.srcInstance.quality) or 0
		result.supportLevel = tonumber(supportGem.level) or 1
		result.supportQuality = tonumber(supportGem.quality) or 0
		result.supportGemIds = appliedSupportIds
		result.supportEffectIds = appliedSupportEffects
		result.socketedSupportGemIds = socketedSupportIds
	end
	return result
end

local function evaluateSkillSupportCell(build, job, cellName, changeSkill, changeSupport)
	local evaluationBuild, group
	if cellName == "baseline" then
		evaluationBuild = build
		group = build.skillsTab.socketGroupList[job.groupIndex]
	else
		local proxy, proxyGroupOrError = buildSkillSupportProxy(build, job, changeSkill, changeSupport)
		if not proxy then return nil, proxyGroupOrError end
		evaluationBuild, group = proxy, proxyGroupOrError
	end
	local socketStatus = "unlinked_planning_group"
	if group.slot and group.slot ~= "" then
		local valid, socketDetails = SkillCatalog.ValidateSocketGroup(evaluationBuild, job.groupIndex)
		if not valid then return nil, "The " .. cellName .. " cell fails PoB's native socket/link validation: " .. tostring(socketDetails) end
		socketStatus = "native_linked_group"
	elseif group.source then
		return nil, "A PoB-granted skill group cannot be used for a skill/support gem replacement study"
	end
	local calcFunc, initialOutput, initialEnv = Calcs.getMiscCalculator(evaluationBuild)
	if type(calcFunc) ~= "function" or type(initialOutput) ~= "table" or type(initialEnv) ~= "table" then
		return nil, "PoB did not provide a fresh exact calculation environment for the " .. cellName .. " cell"
	end
	local output, env = initialOutput, initialEnv
	local skillEffectId = (changeSkill and job.alternateSkillEffectId) or job.sourceSkillEffectId
	local selected, selectedError = selectedSkillAndSupport(env, group, skillEffectId,
		job.supportGemIndex, job.groupIndex, true)
	if not selected then return nil, "The " .. cellName .. " cell is not an exact applied skill/support pair: " .. tostring(selectedError) end
	local metrics = exactMetrics(output)
	local skill = env.player.mainSkill
	local payability = Validator.CheckMainSkillPayability(output, skillName(skill))
	local cell = {
		metrics = metrics,
		dps = Candidate.CopySkillDPS(output),
		requirements = Validator.CheckRequirements(output, evaluationBuild.characterLevel),
		mainSkillPayability = payability,
		activitySustain = activityForOutput(output),
		selectedSkill = selected,
		socketStatus = socketStatus,
		exactCalculated = true,
		evaluationMethod = "calcs_getMiscCalculator",
		evidenceContext = {
			schemaVersion = 1,
			buildSignatureAlgorithm = "sha256",
			buildSignatureVersion = 1,
			buildSignature = job.sourceBuildSignature,
			scenarioSignature = job.scenarioSignature,
			engine = {
				pobVersion = job.engine.pobVersion,
				pobBranch = job.engine.pobBranch,
				dataVersion = job.engine.dataVersion,
				treeVersion = job.engine.treeVersion,
				manifestFingerprint = job.engine.manifestFingerprint,
			},
		},
	}
	-- Keep only compact exact output in the coroutine job. The calculator env and
	-- cloned build leave scope before the next UI-frame yield.
	return cell
end

local skillSupportFactorialJobSummary
local runSkillSupportFactorialStudy

local function startSkillSupportFactorialStudy(params)
	local allowed = {
		groupIndex = true, skillGemIndex = true, skillGemId = true, skillEffectId = true,
		supportGemIndex = true, supportGemId = true, label = true, studyId = true, comparisonId = true,
	}
	for key in pairs(params or { }) do
		if not allowed[key] then return nil, "Unsupported record_skill_support_factorial_experiment field: " .. tostring(key) end
	end
	for _, key in ipairs({ "groupIndex", "skillGemIndex", "supportGemIndex" }) do
		local value = params[key]
		if not isFinite(value) or value < 1 or value ~= math.floor(value) or value > 100 then
			return nil, key .. " must be a positive PoB skill group/gem index"
		end
	end
	for _, key in ipairs({ "skillGemId", "skillEffectId", "supportGemId" }) do
		if type(params[key]) ~= "string" or #params[key] < 1 or #params[key] > 120 then
			return nil, key .. " must be an exact gem/effect ID from the selected PoB skill snapshot"
		end
	end
	if params.skillGemIndex == params.supportGemIndex then return nil, "The Main Skill and support factors must use distinct gem slots" end
	if params.label ~= nil and (type(params.label) ~= "string" or #params.label > 120 or params.label:find("[%c]")) then
		return nil, "label must be plain text of at most 120 characters"
	end
	local build, studySource = resolveStudyBuild(params)
	if not build then return nil, studySource end
	for _, qaJob in pairs(bridge.qaJobs or { }) do
		if qaJob.status == "running" then return nil, "A local PoB QA suite is running", "busy" end
	end
	for _, progressionJob in pairs(bridge.progressionJobs or { }) do
		if progressionJob.status == "running" then return nil, "A progression audit is already running", "busy" end
	end
	for _, factorialJob in pairs(bridge.factorialJobs or { }) do
		if factorialJob.status == "running" then return nil, "A factorial study is already running", "busy" end
	end
	local activeOptimizer = currentBuild() and currentBuild().optimizerTab
	if activeOptimizer and ((activeOptimizer.job and activeOptimizer.job.status == "running")
		or (activeOptimizer.classRootJob and activeOptimizer.classRootJob.status == "running")) then
		return nil, "An optimizer or class-root search is already running", "busy"
	end
	local group = build.skillsTab and build.skillsTab.socketGroupList[params.groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false then return nil, "Select an enabled PoB skill group" end
	if build.mainSocketGroup ~= params.groupIndex then return nil, "The factorial study must target PoB's currently selected Main Skill group" end
	local skillGem = group.gemList and group.gemList[params.skillGemIndex]
	local supportGem = group.gemList and group.gemList[params.supportGemIndex]
	if not skillGem or not supportGem then return nil, "The requested Main Skill or support slot is missing from the selected PoB group" end
	local sourceSkillData = skillGem.gemData or (skillGem.gemId and build.data.gems[skillGem.gemId])
	local sourceSupportData = supportGem.gemData or (supportGem.gemId and build.data.gems[supportGem.gemId])
	local alternateSkillData = build.data.gems[params.skillGemId]
	local alternateSupportData = build.data.gems[params.supportGemId]
	if not SkillCatalog.IsActiveSkillGem(sourceSkillData) or not SkillCatalog.IsActiveSkillGem(alternateSkillData) then
		return nil, "Both Main Skill factor values must be supported active gems from PoB's loaded database"
	end
	if not sourceSupportData or not alternateSupportData then return nil, "Both support factor values must come from PoB's loaded gem database" end
	local sourceSkillEffect = group.displaySkillList and group.displaySkillList[group.mainActiveSkill or 1]
	local sourceEffect = sourceSkillEffect and sourceSkillEffect.activeEffect and sourceSkillEffect.activeEffect.grantedEffect
	-- The source effect comes from the selected native gem instance. The public
	-- skillEffectId selects an effect of the replacement gem, validated below;
	-- requiring both IDs to match makes any genuine skill change impossible.
	if not sourceEffect or type(sourceEffect.id) ~= "string" or sourceEffect.id == "" then
		return nil, "PoB did not expose the currently selected Main Skill effect"
	end
	local sourceSkillInstance = sourceSkillEffect.activeEffect.srcInstance
	local resolvedSkillIndex
	for gemIndex, gem in ipairs(group.gemList) do if gem == sourceSkillInstance then resolvedSkillIndex = gemIndex break end end
	if not resolvedSkillIndex then return nil, "PoB could not map the selected Main Skill effect to one gem slot" end
	if resolvedSkillIndex ~= params.skillGemIndex then return nil, "skillGemIndex must identify the gem currently supplying PoB's selected Main Skill" end
	local currentSkillId = sourceSkillData.id or skillGem.gemId
	local currentSupportId = sourceSupportData.id or supportGem.gemId
	if params.skillGemId == currentSkillId then return nil, "skillGemId must change the Main Skill factor" end
	if params.supportGemId == currentSupportId then return nil, "supportGemId must change the support factor" end
	if not group.slot or group.slot == "" then
		if group.source then return nil, "A PoB-granted group cannot be used for this replacement study" end
	else
		local skillSlotValid, skillSlotError = SkillCatalog.CanReplaceGemAtSlot(build, params.groupIndex,
			params.skillGemIndex, alternateSkillData)
		if not skillSlotValid then return nil, skillSlotError end
		local supportSlotValid, supportSlotError = SkillCatalog.CanReplaceSupportAtSlot(build, params.groupIndex,
			params.supportGemIndex, alternateSupportData)
		if not supportSlotValid then return nil, supportSlotError end
	end
	local sourceSkillLevel, sourceSkillQuality = tonumber(skillGem.level) or 1, tonumber(skillGem.quality) or 0
	local sourceSupportLevel, sourceSupportQuality = tonumber(supportGem.level) or 1, tonumber(supportGem.quality) or 0
	local function effectForSupport(gemData)
		local effect = gemData.grantedEffect
		if effect and effect.support then return effect end
		effect = gemData.secondaryGrantedEffect
		return effect and effect.support and effect or nil
	end
	local alternateSkillEffect
	for _, effect in ipairs(alternateSkillData.grantedEffectList or { alternateSkillData.grantedEffect }) do
		if effect and not effect.support and not effect.unsupported and tostring(effect.id) == params.skillEffectId then
			alternateSkillEffect = effect
			break
		end
	end
	if not alternateSkillEffect then return nil, "skillEffectId is not an active effect granted by skillGemId" end
	local alternateSupportEffect = effectForSupport(alternateSupportData)
	if not alternateSupportEffect then return nil, "supportGemId is not a supported PoB support gem" end
	if not alternateSkillEffect.levels or not alternateSkillEffect.levels[sourceSkillLevel]
		or not alternateSupportEffect.levels or not alternateSupportEffect.levels[sourceSupportLevel] then
		return nil, "The alternative gem does not provide the source gem's exact level; factorial cells cannot isolate gem identity"
	end
	if sourceSkillQuality < 0 or sourceSkillQuality > 30 or sourceSupportQuality < 0 or sourceSupportQuality > 30 then
		return nil, "PoB source gem quality is outside the supported exact range"
	end
	local selectedSourceEffectId = tostring(sourceEffect.id)
	if not sourceEffect.levels or not sourceEffect.levels[sourceSkillLevel] then
		return nil, "The source Main Skill does not expose the exact current gem level in PoB data"
	end
	local sourceSupportEffect = effectForSupport(sourceSupportData)
	if not sourceSupportEffect or not sourceSupportEffect.levels or not sourceSupportEffect.levels[sourceSupportLevel] then
		return nil, "The source support does not expose the exact current gem level in PoB data"
	end
	local calcSignatureOk, sourceSignature = pcall(Candidate.BuildSignature, build)
	if not calcSignatureOk or type(sourceSignature) ~= "string" then return nil, "Could not fingerprint the selected PoB build" end
	local sourceBuildSignature, buildSignatureError = StudyContext.BuildSignature(sourceSignature)
	if not sourceBuildSignature then return nil, buildSignatureError end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(getConfiguration(build))
	if not scenarioSignature then return nil, scenarioError end
	local engine, engineError = skillItemStudyEngine(build)
	if not engine then return nil, engineError end
	bridge.factorialJobs = bridge.factorialJobs or { }
	local jobCount = 0
	for jobId, job in pairs(bridge.factorialJobs) do
		jobCount = jobCount + 1
		if jobCount >= maxFactorialJobs and job.status ~= "running" then bridge.factorialJobs[jobId] = nil; jobCount = jobCount - 1 end
	end
	if jobCount >= maxFactorialJobs then return nil, "The factorial study history is full; wait for a completed study to be pruned", "busy" end
	bridge.nextFactorialJob = (bridge.nextFactorialJob or 0) + 1
	local jobId = "pob-skill-support-factorial-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextFactorialJob)
	local sourceParams = { }
	if params.studyId ~= nil then sourceParams.studyId = params.studyId end
	if params.comparisonId ~= nil then sourceParams.comparisonId = params.comparisonId end
	local job = {
		studyKind = "skill_support", jobId = jobId, build = build, activeBuild = currentBuild(),
		sourceParams = sourceParams, studySource = studySource, sourceSignature = sourceSignature,
		sourceBuildSignature = sourceBuildSignature, scenarioSignature = scenarioSignature, engine = engine,
		groupIndex = params.groupIndex, skillGemIndex = params.skillGemIndex, supportGemIndex = params.supportGemIndex,
		sourceSkillGemId = currentSkillId, sourceSupportGemId = currentSupportId,
		alternateSkillGemId = params.skillGemId, alternateSkillEffectId = params.skillEffectId,
		alternateSupportGemId = params.supportGemId, sourceSkillEffectId = selectedSourceEffectId,
		sourceSkillLevel = sourceSkillLevel, sourceSkillQuality = sourceSkillQuality,
		sourceSupportLevel = sourceSupportLevel, sourceSupportQuality = sourceSupportQuality,
		label = (params.label or ""):match("^%s*(.-)%s*$"), cells = { }, completedCells = 0,
		status = "running", progress = { phase = "Queued", currentCell = "baseline", completedCells = 0, totalCells = 4 },
		startedAt = os.time(), readOnly = true, activeBuildPreserved = true,
	}
	job.thread = coroutine.create(runSkillSupportFactorialStudy)
	bridge.factorialJobs[jobId] = job
	return skillSupportFactorialJobSummary(job)
end

skillSupportFactorialJobSummary = function(job)
	return {
		jobId = job.jobId, status = job.status, progress = job.progress,
		completedCells = job.completedCells or 0, totalCells = 4,
		groupIndex = job.groupIndex, skillGemIndex = job.skillGemIndex, supportGemIndex = job.supportGemIndex,
		skillGemId = job.alternateSkillGemId, skillEffectId = job.alternateSkillEffectId,
		supportGemId = job.alternateSupportGemId,
		isActiveBuild = job.build == currentBuild(), buildReference = experimentSource(job.studySource),
		readOnly = true, activeBuildPreserved = true, error = job.error,
		result = job.status == "completed" and job.result or nil,
	}
end

runSkillSupportFactorialStudy = function(job)
	local cells = {
		{ name = "baseline", skill = false, support = false },
		{ name = "factorA", skill = true, support = false },
		{ name = "factorB", skill = false, support = true },
		{ name = "combined", skill = true, support = true },
	}
	for _, spec in ipairs(cells) do
		if job.cancelRequested then job.status = "cancelled" return end
		local cell, cellError = evaluateSkillSupportCell(job.build, job, spec.name, spec.skill, spec.support)
		if not cell then error("The " .. spec.name .. " skill/support cell failed exact PoB validation: " .. tostring(cellError)) end
		job.cells[spec.name] = cell
		job.completedCells = job.completedCells + 1
		job.progress = { phase = "Exact PoB calculation", currentCell = spec.name,
			completedCells = job.completedCells, totalCells = 4 }
		coroutine.yield(job.progress)
	end
	local unchanged, afterSignature = pcall(Candidate.BuildSignature, job.build)
	if not unchanged or afterSignature ~= job.sourceSignature then error("The selected PoB build changed during the read-only factorial study") end
	local unchangedScenario, afterScenarioSignature = pcall(StudyContext.ScenarioSignature, getConfiguration(job.build))
	if not unchangedScenario or afterScenarioSignature ~= job.scenarioSignature then
		error("The selected PoB scenario changed during the read-only skill/support factorial study")
	end
	local interaction, interactionError = FactorialStudy.Compute(job.cells)
	if not interaction then error(interactionError) end
	local snapshot, snapshotError = getSnapshot(job.build)
	if not snapshot then error(snapshotError or "The PoB source snapshot is unavailable") end
	local snapshotScenarioSignature, snapshotScenarioError = StudyContext.ScenarioSignature(snapshot.configuration)
	if not snapshotScenarioSignature or snapshotScenarioSignature ~= job.scenarioSignature then
		error(snapshotScenarioError or "The PoB snapshot scenario does not match the exact factorial source")
	end
	snapshot.exactMetrics = job.cells.baseline.metrics
	snapshot.availableItems = nil
	snapshot.availableItemsTruncated = nil
	snapshot.classOptions = nil
	snapshot.requirements = job.cells.baseline.requirements
	snapshot.mainSkillPayability = job.cells.baseline.mainSkillPayability
	snapshot.activitySustain = job.cells.baseline.activitySustain
	local allRequirementsFeasible, allActivityRatesFeasible = true, true
	for _, cellName in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
		local cell = job.cells[cellName]
		allRequirementsFeasible = allRequirementsFeasible and cell.requirements.feasible == true
			and cell.mainSkillPayability.feasible == true
		allActivityRatesFeasible = allActivityRatesFeasible and cell.activitySustain.status == "pass"
	end
	local baseGroup = job.build.skillsTab.socketGroupList[job.groupIndex]
	local socketStatus = baseGroup.slot and baseGroup.slot ~= "" and "native_linked_group" or "unlinked_planning_group"
	local function gemSummary(gemId, level, quality)
		local gemData = job.build.data.gems[gemId]
		return { gemId = gemId, name = boundedText(gemData and gemData.name or gemId, 120), level = level, quality = quality }
	end
	local factorA = {
		operation = "replace_selected_main_skill_gem", groupIndex = job.groupIndex, gemIndex = job.skillGemIndex,
		before = gemSummary(job.sourceSkillGemId, job.sourceSkillLevel, job.sourceSkillQuality),
		after = gemSummary(job.alternateSkillGemId, job.sourceSkillLevel, job.sourceSkillQuality),
		sourceEffectId = job.sourceSkillEffectId, effectId = job.alternateSkillEffectId,
	}
	local factorB = {
		operation = "replace_support_gem", groupIndex = job.groupIndex, gemIndex = job.supportGemIndex,
		before = gemSummary(job.sourceSupportGemId, job.sourceSupportLevel, job.sourceSupportQuality),
		after = gemSummary(job.alternateSupportGemId, job.sourceSupportLevel, job.sourceSupportQuality),
	}
	local source = experimentSource(job.studySource)
	source.buildSignatureAlgorithm = "sha256"
	source.buildSignatureVersion = 1
	source.buildSignature = job.sourceBuildSignature
	source.scenarioSignature = job.scenarioSignature
	local record = {
		kind = "skill_support_factorial_interaction",
		label = job.label ~= "" and job.label or "Skill and support four-cell interaction study",
		source = source,
		engine = {
			pobVersion = job.engine.pobVersion,
			pobBranch = job.engine.pobBranch, dataVersion = job.engine.dataVersion,
			treeVersion = job.engine.treeVersion,
			manifestFingerprint = job.engine.manifestFingerprint,
			lookupTableStatus = "not_audited",
		},
		buildState = snapshot,
		experiment = {
			unit = "four_cell_skill_support_factorial", factorialSchemaVersion = 1,
			formula = interaction.formula, factorA = factorA, factorB = factorB,
			changedVariables = { "selectedMainSkillGem", "supportGem" },
			socketStatus = socketStatus,
		},
		baseline = {
			metrics = job.cells.baseline.metrics, requirements = job.cells.baseline.requirements,
			mainSkillPayability = job.cells.baseline.mainSkillPayability,
			activitySustain = job.cells.baseline.activitySustain,
			selectedSkill = job.cells.baseline.selectedSkill, skillDPS = job.cells.baseline.dps,
		},
		candidate = {
			metrics = job.cells.combined.metrics, requirements = job.cells.combined.requirements,
			mainSkillPayability = job.cells.combined.mainSkillPayability,
			activitySustain = job.cells.combined.activitySustain,
			selectedSkill = job.cells.combined.selectedSkill, skillDPS = job.cells.combined.dps,
		},
		factorial = {
			formula = interaction.formula, cells = job.cells, interaction = interaction.metrics,
			metricCount = interaction.metricCount,
		},
		metricDelta = metricDelta(job.cells.baseline.metrics, job.cells.combined.metrics),
		admission = {
			exactCalculated = true, useRequirementsFeasible = allRequirementsFeasible,
			activityStatus = job.cells.combined.activitySustain.status,
			activityRatesFeasible = allActivityRatesFeasible,
			activitySustainCertified = false, scenarioConditionsCertified = false,
			lookupTablesCertified = false, trainingEligible = false,
		},
	}
	local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
	if not stored then error(storeError or "PoB could not store the skill/support factorial study") end
	job.result = {
		status = "exact_skill_support_factorial_recorded", readOnly = true, activeBuildPreserved = true,
		isActiveBuild = job.build == currentBuild(), buildReference = experimentSource(job.studySource),
		groupIndex = job.groupIndex, skillGemIndex = job.skillGemIndex, supportGemIndex = job.supportGemIndex,
		skillGemId = job.alternateSkillGemId, skillEffectId = job.alternateSkillEffectId,
		supportGemId = job.alternateSupportGemId, socketStatus = socketStatus,
		formula = interaction.formula, cells = job.cells, interaction = interaction.metrics,
		interactionMetricCount = interaction.metricCount, recordId = stored.recordId,
		storeFile = stored.storeFile, recorded = stored.duplicate ~= true, duplicate = stored.duplicate == true,
		trainingEligible = false,
	}
	job.status = "completed"
	job.completedAt = os.time()
end

local function cancelSkillSupportFactorialStudy(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_skill_support_factorial_cancel field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_skill_support_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "skill_support" then return nil, "Unknown skill/support factorial study job" end
	if job.status == "running" then job.cancelRequested = true; job.status = "cancelled"; job.completedAt = os.time(); job.thread = nil end
	return skillSupportFactorialJobSummary(job)
end

local function getSkillSupportFactorialStudyStatus(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_skill_support_factorial_status field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_skill_support_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "skill_support" then return nil, "Unknown skill/support factorial study job" end
	return skillSupportFactorialJobSummary(job)
end

-- Exact four-cell study for two active skill gems in separate Full DPS groups.
-- It deliberately rejects groups whose activity cannot be tied back to native
-- PoB's exact calculator output; the graph remains quarantined and report-only.
local skillSkillFactorialJobSummary
local runSkillSkillFactorialStudy

local function activeEffectForGem(gemData, effectId)
	if type(gemData) ~= "table" or type(effectId) ~= "string" then return nil end
	for _, effect in ipairs(gemData.grantedEffectList or { gemData.grantedEffect }) do
		if effect and not effect.support and not effect.unsupported and tostring(effect.id) == effectId then return effect end
	end
end

local function skillSkillSource(build, groupIndex, gemIndex)
	local group = build.skillsTab and build.skillsTab.socketGroupList and build.skillsTab.socketGroupList[groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false or group.includeInFullDPS ~= true then
		return nil, "Each skill factor must use an enabled socket group included in PoB Full DPS"
	end
	if not group.slot or group.slot == "" or group.source then
		return nil, "Skill×skill studies require two ordinary linked equipment socket groups"
	end
	local valid, details = SkillCatalog.ValidateSocketGroup(build, groupIndex)
	if not valid or not details or details.status ~= "linked" then
		return nil, "The selected socket group fails native PoB link validation: " .. tostring(details or "link proof unavailable")
	end
	local selected = group.displaySkillList and group.displaySkillList[group.mainActiveSkill or 1]
	local sourceGem = selected and selected.activeEffect and selected.activeEffect.srcInstance
	local resolvedIndex
	for index, gem in ipairs(group.gemList or { }) do if gem == sourceGem then resolvedIndex = index break end end
	if not selected or not resolvedIndex or resolvedIndex ~= gemIndex then
		return nil, "skillGemIndex must identify the active effect currently selected in its Full DPS group"
	end
	local gemData = sourceGem.gemData or (sourceGem.gemId and build.data.gems[sourceGem.gemId])
	if not SkillCatalog.IsActiveSkillGem(gemData) then return nil, "The source factor is not a loaded PoE 1 active-skill gem" end
	local effect = selected.activeEffect and selected.activeEffect.grantedEffect
	local level, quality = tonumber(sourceGem.level) or 1, tonumber(sourceGem.quality) or 0
	if not effect or type(effect.id) ~= "string" or effect.id == "" or not effect.levels or not effect.levels[level] then
		return nil, "PoB did not resolve the current skill effect and exact gem level"
	end
	if quality < 0 or quality > 30 then return nil, "PoB source gem quality is outside the supported exact range" end
	return {
		group = group, groupIndex = groupIndex, gemIndex = gemIndex,
		gem = sourceGem, gemData = gemData, effect = effect,
		gemId = tostring(gemData.id or sourceGem.gemId or ""), effectId = tostring(effect.id),
		level = level, quality = quality,
	}
end

local function startSkillSkillFactorialStudy(params)
	local allowed = {
		groupAIndex = true, skillGemAIndex = true, skillGemAId = true, skillEffectAId = true,
		groupBIndex = true, skillGemBIndex = true, skillGemBId = true, skillEffectBId = true,
		label = true, studyId = true, comparisonId = true,
	}
	for key in pairs(params or { }) do
		if not allowed[key] then return nil, "Unsupported record_skill_skill_factorial_experiment field: " .. tostring(key) end
	end
	for _, key in ipairs({ "groupAIndex", "skillGemAIndex", "groupBIndex", "skillGemBIndex" }) do
		local value = params[key]
		if not isFinite(value) or value < 1 or value ~= math.floor(value) or value > 100 then
			return nil, key .. " must be a positive PoB group/gem index"
		end
	end
	if params.groupAIndex == params.groupBIndex then return nil, "Skill×skill factors must occupy distinct socket groups" end
	for _, key in ipairs({ "skillGemAId", "skillEffectAId", "skillGemBId", "skillEffectBId" }) do
		if type(params[key]) ~= "string" or #params[key] < 1 or #params[key] > 120 then
			return nil, key .. " must be an exact loaded PoB gem/effect ID"
		end
	end
	if params.label ~= nil and (type(params.label) ~= "string" or #params.label > 120 or params.label:find("[%c]")) then
		return nil, "label must be plain text of at most 120 characters"
	end
	local build, studySource = resolveStudyBuild(params)
	if not build then return nil, studySource end
	for _, qaJob in pairs(bridge.qaJobs or { }) do if qaJob.status == "running" then return nil, "A local PoB QA suite is running", "busy" end end
	for _, progressionJob in pairs(bridge.progressionJobs or { }) do if progressionJob.status == "running" then return nil, "A progression audit is already running", "busy" end end
	for _, factorialJob in pairs(bridge.factorialJobs or { }) do if factorialJob.status == "running" then return nil, "A factorial study is already running", "busy" end end
	local activeOptimizer = currentBuild() and currentBuild().optimizerTab
	if activeOptimizer and ((activeOptimizer.job and activeOptimizer.job.status == "running")
		or (activeOptimizer.classRootJob and activeOptimizer.classRootJob.status == "running")) then
		return nil, "An optimizer or class-root search is already running", "busy"
	end
	local sourceA, sourceAError = skillSkillSource(build, params.groupAIndex, params.skillGemAIndex)
	if not sourceA then return nil, "factor A is invalid: " .. tostring(sourceAError) end
	local sourceB, sourceBError = skillSkillSource(build, params.groupBIndex, params.skillGemBIndex)
	if not sourceB then return nil, "factor B is invalid: " .. tostring(sourceBError) end
	local alternateA = build.data.gems[params.skillGemAId]
	local alternateB = build.data.gems[params.skillGemBId]
	if not SkillCatalog.IsActiveSkillGem(alternateA) or not SkillCatalog.IsActiveSkillGem(alternateB) then
		return nil, "Both replacement values must be supported PoE 1 active-skill gems in PoB's loaded database"
	end
	if params.skillGemAId == sourceA.gemId or params.skillGemBId == sourceB.gemId then
		return nil, "Each replacement gem must differ from its source gem"
	end
	local effectA, effectB = activeEffectForGem(alternateA, params.skillEffectAId), activeEffectForGem(alternateB, params.skillEffectBId)
	if not effectA then return nil, "skillEffectAId is not an active effect granted by skillGemAId" end
	if not effectB then return nil, "skillEffectBId is not an active effect granted by skillGemBId" end
	if not effectA.levels or not effectA.levels[sourceA.level] or not effectB.levels or not effectB.levels[sourceB.level] then
		return nil, "Each replacement gem must provide its source gem's exact level so the factorial isolates gem identity"
	end
	for _, source in ipairs({ sourceA, sourceB }) do
		local valid, replaceError = SkillCatalog.CanReplaceGemAtSlot(build, source.groupIndex, source.gemIndex,
			source == sourceA and alternateA or alternateB)
		if not valid then return nil, replaceError end
	end
	local signatureOk, sourceSignature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or type(sourceSignature) ~= "string" then return nil, "Could not fingerprint the selected PoB source build" end
	local sourceBuildSignature, buildSignatureError = StudyContext.BuildSignature(sourceSignature)
	if not sourceBuildSignature then return nil, buildSignatureError end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(getConfiguration(build))
	if not scenarioSignature then return nil, scenarioError end
	local engine, engineError = skillItemStudyEngine(build)
	if not engine then return nil, engineError end
	bridge.factorialJobs = bridge.factorialJobs or { }
	local jobCount = 0
	for jobId, job in pairs(bridge.factorialJobs) do
		jobCount = jobCount + 1
		if jobCount >= maxFactorialJobs and job.status ~= "running" then bridge.factorialJobs[jobId] = nil; jobCount = jobCount - 1 end
	end
	if jobCount >= maxFactorialJobs then return nil, "The factorial study history is full; wait for a completed study to be pruned", "busy" end
	bridge.nextFactorialJob = (bridge.nextFactorialJob or 0) + 1
	local jobId = "pob-skill-skill-factorial-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextFactorialJob)
	local sourceParams = { }
	if params.studyId ~= nil then sourceParams.studyId = params.studyId end
	if params.comparisonId ~= nil then sourceParams.comparisonId = params.comparisonId end
	local job = {
		studyKind = "skill_skill", jobId = jobId, build = build, activeBuild = currentBuild(),
		sourceParams = sourceParams, studySource = studySource, sourceSignature = sourceSignature,
		sourceBuildSignature = sourceBuildSignature, scenarioSignature = scenarioSignature, engine = engine,
		groupAIndex = sourceA.groupIndex, skillGemAIndex = sourceA.gemIndex,
		groupBIndex = sourceB.groupIndex, skillGemBIndex = sourceB.gemIndex,
		sourceSkillAGemId = sourceA.gemId, sourceSkillAEffectId = sourceA.effectId,
		sourceSkillALevel = sourceA.level, sourceSkillAQuality = sourceA.quality,
		alternateSkillAGemId = params.skillGemAId, alternateSkillAEffectId = params.skillEffectAId,
		sourceSkillBGemId = sourceB.gemId, sourceSkillBEffectId = sourceB.effectId,
		sourceSkillBLevel = sourceB.level, sourceSkillBQuality = sourceB.quality,
		alternateSkillBGemId = params.skillGemBId, alternateSkillBEffectId = params.skillEffectBId,
		label = (params.label or ""):match("^%s*(.-)%s*$"), cells = { }, completedCells = 0,
		status = "running", progress = { phase = "Queued", currentCell = "baseline", completedCells = 0, totalCells = 4 },
		startedAt = os.time(), readOnly = true, activeBuildPreserved = true,
	}
	job.thread = coroutine.create(runSkillSkillFactorialStudy)
	bridge.factorialJobs[jobId] = job
	return skillSkillFactorialJobSummary(job)
end

skillSkillFactorialJobSummary = function(job)
	return {
		jobId = job.jobId, status = job.status, progress = job.progress,
		completedCells = job.completedCells or 0, totalCells = 4,
		groupAIndex = job.groupAIndex, skillGemAIndex = job.skillGemAIndex,
		groupBIndex = job.groupBIndex, skillGemBIndex = job.skillGemBIndex,
		isActiveBuild = job.build == currentBuild(), buildReference = experimentSource(job.studySource),
		readOnly = true, activeBuildPreserved = true, error = job.error,
		result = job.status == "completed" and job.result or nil,
	}
end

local function cloneSkillSkillBuild(build, job, changeA, changeB)
	local skillsTab = shallowClone(build.skillsTab)
	local groups = { }
	for groupIndex, sourceGroup in ipairs(build.skillsTab.socketGroupList or { }) do
		local group = shallowClone(sourceGroup)
		group.gemList = { }
		for gemIndex, sourceGem in ipairs(sourceGroup.gemList or { }) do group.gemList[gemIndex] = shallowClone(sourceGem) end
		groups[groupIndex] = group
	end
	skillsTab.socketGroupList = groups
	local proxy = shallowClone(build)
	proxy.skillsTab = skillsTab
	setmetatable(proxy, { __index = build })
	skillsTab.build = proxy
	local proxyData = shallowClone(build.data)
	proxyData.gems = shallowClone(build.data and build.data.gems)
	proxyData.skills = shallowClone(build.data and build.data.skills)
	proxy.data = proxyData
	local function apply(groupIndex, gemIndex, gemId, effectId, changed)
		local group = groups[groupIndex]
		local gem = group and group.gemList[gemIndex]
		if not group or not gem then return nil, "A skill factor slot disappeared while cloning the source" end
		if changed then
			local gemData = proxyData.gems[gemId]
			if not gemData then return nil, "A replacement skill gem disappeared from PoB's loaded database" end
			gem.gemId, gem.skillId, gem.nameSpec = gemData.id, gemData.grantedEffectId, gemData.name
			gem.gemData, gem.grantedEffect = gemData, gemData.grantedEffect
		end
		local effectIndex = SkillCatalog.ResolveMainSkillIndex(group, gemIndex, effectId)
		if not effectIndex then return nil, "PoB did not resolve the exact requested skill effect in the isolated group" end
		group.mainActiveSkill = effectIndex
		return group
	end
	local groupA, errorA = apply(job.groupAIndex, job.skillGemAIndex,
		changeA and job.alternateSkillAGemId or job.sourceSkillAGemId,
		changeA and job.alternateSkillAEffectId or job.sourceSkillAEffectId, changeA)
	if not groupA then return nil, errorA end
	local groupB, errorB = apply(job.groupBIndex, job.skillGemBIndex,
		changeB and job.alternateSkillBGemId or job.sourceSkillBGemId,
		changeB and job.alternateSkillBEffectId or job.sourceSkillBEffectId, changeB)
	if not groupB then return nil, errorB end
	local clonedTriggeredGems, clonedTriggeredSkills = { }, { }
	for _, group in ipairs(groups) do
		for _, gem in ipairs(group.gemList or { }) do
			if gem.triggered then
				if gem.gemId and proxyData.gems[gem.gemId] and not clonedTriggeredGems[gem.gemId] then
					proxyData.gems[gem.gemId] = cloneTriggeredDefinition(proxyData.gems[gem.gemId])
					clonedTriggeredGems[gem.gemId] = true
				elseif gem.skillId and proxyData.skills[gem.skillId] and not clonedTriggeredSkills[gem.skillId] then
					proxyData.skills[gem.skillId] = cloneTriggeredDefinition(proxyData.skills[gem.skillId])
					clonedTriggeredSkills[gem.skillId] = true
				end
			end
		end
	end
	if type(skillsTab.ProcessSocketGroup) ~= "function" then return nil, "PoB's native socket-group processor is unavailable" end
	for _, group in ipairs(groups) do skillsTab:ProcessSocketGroup(group) end
	if type(skillsTab.UpdateSocketGroups) == "function" then skillsTab:UpdateSocketGroups() end
	for _, spec in ipairs({
		{ groupIndex = job.groupAIndex, gemIndex = job.skillGemAIndex, effectId = changeA and job.alternateSkillAEffectId or job.sourceSkillAEffectId },
		{ groupIndex = job.groupBIndex, gemIndex = job.skillGemBIndex, effectId = changeB and job.alternateSkillBEffectId or job.sourceSkillBEffectId },
	}) do
		local group = groups[spec.groupIndex]
		local effectIndex = SkillCatalog.ResolveMainSkillIndex(group, spec.gemIndex, spec.effectId)
		if not effectIndex then return nil, "PoB did not retain a requested skill effect after native socket processing" end
		group.mainActiveSkill = effectIndex
	end
	proxy.mainSocketGroup = build.mainSocketGroup
	return proxy, groups[job.groupAIndex], groups[job.groupBIndex]
end

local function skillSupportSnapshot(build, group, activeSkill)
	local socketed, applied = { }, { }
	for _, gem in ipairs(group.gemList or { }) do
		local gemData = gem.gemData or (gem.gemId and build.data.gems[gem.gemId])
		local effect = gemData and (gem.grantedEffect or gemData.grantedEffect)
		if gem.enabled ~= false and effect and effect.support then
			socketed[#socketed + 1] = tostring(gemData.id or gem.gemId or "")
		end
	end
	for _, effect in ipairs(activeSkill.effectList or { }) do
		local granted = effect and effect.grantedEffect
		local instance = effect and effect.srcInstance
		if granted and granted.support and instance then
			local data = instance.gemData or (instance.gemId and build.data.gems[instance.gemId]) or { }
			applied[#applied + 1] = tostring(data.id or instance.gemId or "") .. "\0" .. tostring(granted.id or "")
		end
	end
	table.sort(socketed)
	table.sort(applied)
	return socketed, applied
end

local function exactFullDPSkill(env, output, build, group, groupIndex, gemIndex, expectedGemId, expectedEffectId, factorLabel)
	local matches = { }
	local sourceSlotGem = group and group.gemList and group.gemList[gemIndex]
	for _, activeSkill in ipairs(env and env.player and env.player.activeSkillList or { }) do
		local activeEffect = activeSkill.activeEffect
		local sourceGem = activeEffect and activeEffect.srcInstance
		local granted = activeEffect and activeEffect.grantedEffect
		if activeSkill.socketGroup == group and sourceGem and sourceGem == sourceSlotGem and granted
			and tostring(sourceGem.gemData and sourceGem.gemData.id or sourceGem.gemId or "") == tostring(expectedGemId)
			and tostring(granted.id or "") == tostring(expectedEffectId) then
			matches[#matches + 1] = activeSkill
		end
	end
	if #matches ~= 1 then return nil, "PoB did not expose one unambiguous active skill for factor " .. factorLabel end
	local activeSkill = matches[1]
	if not group.includeInFullDPS or group.enabled == false or group.slotEnabled == false then
		return nil, "PoB does not include factor " .. factorLabel .. " in native Full DPS"
	end
	if output.FullDPSActivityTruncated == true or type(output.FullDPSActivity) ~= "table" then
		return nil, "PoB's Full DPS activity proof is missing or truncated"
	end
	local effect = activeSkill.activeEffect.grantedEffect
	local groupName = group.label or group.slot or ""
	local activityIdentity = table.concat({ tostring(effect.id or effect.name or "Unknown skill"), tostring(groupName), tostring(activeSkill.skillPartName or "") }, "\31")
	local activityCount = 0
	for _, activity in ipairs(output.FullDPSActivity) do
		if activity.identity == activityIdentity and activity.sourceGemIndex == gemIndex then activityCount = activityCount + 1 end
	end
	if activityCount ~= 1 then return nil, "PoB Full DPS output does not uniquely prove the selected source gem for factor " .. factorLabel end
	local sourceGem = activeSkill.activeEffect.srcInstance
	local socketed, applied = skillSupportSnapshot(build, group, activeSkill)
	return {
		name = boundedText(effect.name or "", 120), effectId = tostring(effect.id or ""),
		gemId = tostring(sourceGem.gemData and sourceGem.gemData.id or sourceGem.gemId or ""),
		groupIndex = groupIndex, gemIndex = gemIndex,
		level = tonumber(sourceGem.level), quality = tonumber(sourceGem.quality) or 0,
		fullDPSIncluded = true, fullDPSActivityIdentity = activityIdentity, fullDPSActivityGemIndex = gemIndex,
		socketedSupportGemIds = socketed, appliedSupportPairs = applied,
	}
end

local function evaluateSkillSkillCell(job, cellName, changeA, changeB)
	local evaluationBuild, groupA, groupB = cloneSkillSkillBuild(job.build, job, changeA, changeB)
	if not evaluationBuild then return nil, groupA end
	for index, group in ipairs({ groupA, groupB }) do
		local groupIndex = index == 1 and job.groupAIndex or job.groupBIndex
		local valid, details = SkillCatalog.ValidateSocketGroup(evaluationBuild, groupIndex)
		if not valid or not details or details.status ~= "linked" then
			return nil, "The " .. cellName .. " cell fails native PoB socket/link validation: " .. tostring(details or "proof unavailable")
		end
	end
	local calcFunc, output, env = Calcs.getMiscCalculator(evaluationBuild)
	if type(calcFunc) ~= "function" or type(output) ~= "table" or type(env) ~= "table" then
		return nil, "PoB did not provide a fresh exact calculation environment for the " .. cellName .. " cell"
	end
	local skillA, skillAError = exactFullDPSkill(env, output, evaluationBuild, groupA, job.groupAIndex, job.skillGemAIndex,
		changeA and job.alternateSkillAGemId or job.sourceSkillAGemId,
		changeA and job.alternateSkillAEffectId or job.sourceSkillAEffectId, "A")
	if not skillA then return nil, skillAError end
	local skillB, skillBError = exactFullDPSkill(env, output, evaluationBuild, groupB, job.groupBIndex, job.skillGemBIndex,
		changeB and job.alternateSkillBGemId or job.sourceSkillBGemId,
		changeB and job.alternateSkillBEffectId or job.sourceSkillBEffectId, "B")
	if not skillB then return nil, skillBError end
	local expectedLevelA, expectedQualityA = job.sourceSkillALevel, job.sourceSkillAQuality
	local expectedLevelB, expectedQualityB = job.sourceSkillBLevel, job.sourceSkillBQuality
	if skillA.level ~= expectedLevelA or skillA.quality ~= expectedQualityA or skillB.level ~= expectedLevelB or skillB.quality ~= expectedQualityB then
		return nil, "The " .. cellName .. " cell changed a factor gem's exact level or quality"
	end
	if skillA.socketedSupportGemIds == nil or skillB.socketedSupportGemIds == nil then return nil, "PoB did not expose the unchanged support context" end
	local selectedSkill = env.player and env.player.mainSkill
	local skillLabel = skillName(selectedSkill)
	local cell = {
		metrics = exactMetrics(output), dps = Candidate.CopySkillDPS(output),
		requirements = Validator.CheckRequirements(output, evaluationBuild.characterLevel),
		mainSkillPayability = Validator.CheckMainSkillPayability(output, skillLabel),
		activitySustain = activityForOutput(output), selectedSkills = { factorA = skillA, factorB = skillB },
		socketStatus = "native_linked_groups", exactCalculated = true,
		evaluationMethod = "calcs_getMiscCalculator",
		evidenceContext = {
			schemaVersion = 1, buildSignatureAlgorithm = "sha256", buildSignatureVersion = 1,
			buildSignature = job.sourceBuildSignature, scenarioSignature = job.scenarioSignature, engine = job.engine,
		},
	}
	return cell
end

local function recordSkillSkillFactorial(job)
	local interaction, interactionError = FactorialStudy.Compute(job.cells)
	if not interaction then error(interactionError) end
	local unchanged, afterSignature = pcall(Candidate.BuildSignature, job.build)
	if not unchanged or afterSignature ~= job.sourceSignature then error("The selected PoB source build changed during the read-only skill×skill study") end
	local unchangedScenario, afterScenario = pcall(StudyContext.ScenarioSignature, getConfiguration(job.build))
	if not unchangedScenario or afterScenario ~= job.scenarioSignature then error("The selected PoB scenario changed during the read-only skill×skill study") end
	local snapshot, snapshotError = getSnapshot(job.build)
	if not snapshot then error(snapshotError or "The PoB source snapshot is unavailable") end
	local snapshotScenario, snapshotScenarioError = StudyContext.ScenarioSignature(snapshot.configuration)
	if not snapshotScenario or snapshotScenario ~= job.scenarioSignature then error(snapshotScenarioError or "The source snapshot scenario does not match the exact factorial study") end
	snapshot.exactMetrics = job.cells.baseline.metrics
	snapshot.availableItems, snapshot.availableItemsTruncated, snapshot.classOptions = nil, nil, nil
	snapshot.requirements = job.cells.baseline.requirements
	snapshot.mainSkillPayability = job.cells.baseline.mainSkillPayability
	snapshot.activitySustain = job.cells.baseline.activitySustain
	local socketStatus = "native_linked_groups"
	local function gemSummary(gemId, effectId, level, quality)
		local gemData = job.build.data.gems[gemId]
		return { gemId = gemId, name = boundedText(gemData and gemData.name or gemId, 120), effectId = effectId, level = level, quality = quality }
	end
	local factorA = {
		operation = "replace_full_dps_skill_gem", groupIndex = job.groupAIndex, gemIndex = job.skillGemAIndex,
		before = gemSummary(job.sourceSkillAGemId, job.sourceSkillAEffectId, job.sourceSkillALevel, job.sourceSkillAQuality),
		after = gemSummary(job.alternateSkillAGemId, job.alternateSkillAEffectId, job.sourceSkillALevel, job.sourceSkillAQuality),
		socketedSupportGemIds = job.cells.baseline.selectedSkills.factorA.socketedSupportGemIds,
	}
	local factorB = {
		operation = "replace_full_dps_skill_gem", groupIndex = job.groupBIndex, gemIndex = job.skillGemBIndex,
		before = gemSummary(job.sourceSkillBGemId, job.sourceSkillBEffectId, job.sourceSkillBLevel, job.sourceSkillBQuality),
		after = gemSummary(job.alternateSkillBGemId, job.alternateSkillBEffectId, job.sourceSkillBLevel, job.sourceSkillBQuality),
		socketedSupportGemIds = job.cells.baseline.selectedSkills.factorB.socketedSupportGemIds,
	}
	local source = experimentSource(job.studySource)
	source.buildSignatureAlgorithm, source.buildSignatureVersion = "sha256", 1
	source.buildSignature, source.scenarioSignature = job.sourceBuildSignature, job.scenarioSignature
	local allRequirementsFeasible, allActivityRatesFeasible = true, true
	for _, name in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
		local cell = job.cells[name]
		allRequirementsFeasible = allRequirementsFeasible and cell.requirements.feasible == true and cell.mainSkillPayability.feasible == true
		allActivityRatesFeasible = allActivityRatesFeasible and cell.activitySustain.status == "pass"
	end
	local record = {
		kind = "skill_skill_factorial_interaction", label = job.label ~= "" and job.label or "Two-skill Full DPS interaction study",
		source = source, engine = job.engine, buildState = snapshot,
		experiment = {
			unit = "four_cell_skill_skill_factorial", factorialSchemaVersion = 1,
			formula = interaction.formula, factorA = factorA, factorB = factorB,
			changedVariables = { "fullDPSSkillGemA", "fullDPSSkillGemB" }, socketStatus = socketStatus,
		},
		baseline = {
			metrics = job.cells.baseline.metrics, requirements = job.cells.baseline.requirements,
			mainSkillPayability = job.cells.baseline.mainSkillPayability,
			activitySustain = job.cells.baseline.activitySustain,
			selectedSkills = job.cells.baseline.selectedSkills,
		},
		candidate = {
			metrics = job.cells.combined.metrics, requirements = job.cells.combined.requirements,
			mainSkillPayability = job.cells.combined.mainSkillPayability,
			activitySustain = job.cells.combined.activitySustain,
			selectedSkills = job.cells.combined.selectedSkills,
		},
		factorial = { formula = interaction.formula, cells = job.cells, interaction = interaction.metrics, metricCount = interaction.metricCount },
		metricDelta = metricDelta(job.cells.baseline.metrics, job.cells.combined.metrics),
		admission = {
			exactCalculated = true, useRequirementsFeasible = allRequirementsFeasible,
			activityStatus = job.cells.combined.activitySustain.status,
			activityRatesFeasible = allActivityRatesFeasible, activitySustainCertified = false,
			scenarioConditionsCertified = false, lookupTablesCertified = false, trainingEligible = false,
		},
	}
	local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
	if not stored then error(storeError or "PoB could not store the skill×skill factorial study") end
	job.result = {
		status = "exact_skill_skill_factorial_recorded", readOnly = true, activeBuildPreserved = true,
		isActiveBuild = job.build == currentBuild(), buildReference = experimentSource(job.studySource),
		groupAIndex = job.groupAIndex, skillGemAIndex = job.skillGemAIndex,
		groupBIndex = job.groupBIndex, skillGemBIndex = job.skillGemBIndex,
		formula = interaction.formula, cells = job.cells, interaction = interaction.metrics,
		interactionMetricCount = interaction.metricCount, recordId = stored.recordId,
		storeFile = stored.storeFile, recorded = stored.duplicate ~= true, duplicate = stored.duplicate == true,
		trainingEligible = false,
	}
end

runSkillSkillFactorialStudy = function(job)
	local cells = {
		{ name = "baseline", a = false, b = false },
		{ name = "factorA", a = true, b = false },
		{ name = "factorB", a = false, b = true },
		{ name = "combined", a = true, b = true },
	}
	for _, spec in ipairs(cells) do
		if job.cancelRequested then job.status = "cancelled" return end
		local cell, cellError = evaluateSkillSkillCell(job, spec.name, spec.a, spec.b)
		if not cell then error("The " .. spec.name .. " skill×skill cell failed exact PoB validation: " .. tostring(cellError)) end
		job.cells[spec.name] = cell
		job.completedCells = job.completedCells + 1
		job.progress = { phase = "Exact PoB Full DPS calculation", currentCell = spec.name, completedCells = job.completedCells, totalCells = 4 }
		coroutine.yield(job.progress)
	end
	recordSkillSkillFactorial(job)
end

local function cancelSkillSkillFactorialStudy(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_skill_skill_factorial_cancel field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_skill_skill_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "skill_skill" then return nil, "Unknown skill×skill factorial study job" end
	if job.status == "running" then job.cancelRequested = true; job.status = "cancelled"; job.completedAt = os.time(); job.thread = nil end
	return skillSkillFactorialJobSummary(job)
end

local function getSkillSkillFactorialStudyStatus(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_skill_skill_factorial_status field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_skill_skill_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "skill_skill" then return nil, "Unknown skill×skill factorial study job" end
	return skillSkillFactorialJobSummary(job)
end

local passiveSupportFactorialJobSummary
local runPassiveSupportFactorialStudy

local function startPassiveSupportFactorialStudy(params)
	local allowed = {
		groupIndex = true, skillGemIndex = true, supportGemIndex = true, supportGemId = true,
		nodeId = true, label = true, studyId = true, comparisonId = true,
	}
	for key in pairs(params or { }) do
		if not allowed[key] then return nil, "Unsupported record_passive_support_factorial_experiment field: " .. tostring(key) end
	end
	for _, key in ipairs({ "groupIndex", "skillGemIndex", "supportGemIndex" }) do
		local value = params[key]
		if not isFinite(value) or value < 1 or value ~= math.floor(value) or value > 100 then
			return nil, key .. " must be a positive PoB skill group/gem index"
		end
	end
	if not isFinite(params.nodeId) or params.nodeId < 1 or params.nodeId ~= math.floor(params.nodeId)
		or params.nodeId > 2147483647 then return nil, "nodeId must be an exact positive passive node ID from the selected PoB tree" end
	if type(params.supportGemId) ~= "string" or #params.supportGemId < 1 or #params.supportGemId > 120 then
		return nil, "supportGemId must be an exact loaded PoB support gem ID"
	end
	if params.label ~= nil and (type(params.label) ~= "string" or #params.label > 120 or params.label:find("[%c]")) then
		return nil, "label must be plain text of at most 120 characters"
	end
	if params.studyId ~= nil and params.comparisonId ~= nil then return nil, "Provide either studyId or comparisonId, not both" end
	local build, studySource = resolveStudyBuild(params)
	if not build then return nil, studySource end
	for _, qaJob in pairs(bridge.qaJobs or { }) do
		if qaJob.status == "running" then return nil, "A local PoB QA suite is running", "busy" end
	end
	for _, progressionJob in pairs(bridge.progressionJobs or { }) do
		if progressionJob.status == "running" then return nil, "A progression audit is already running", "busy" end
	end
	for _, factorialJob in pairs(bridge.factorialJobs or { }) do
		if factorialJob.status == "running" then return nil, "A factorial study is already running", "busy" end
	end
	local activeOptimizer = currentBuild() and currentBuild().optimizerTab
	if activeOptimizer and ((activeOptimizer.job and activeOptimizer.job.status == "running")
		or (activeOptimizer.classRootJob and activeOptimizer.classRootJob.status == "running")) then
		return nil, "An optimizer or class-root search is already running", "busy"
	end
	local group = build.skillsTab and build.skillsTab.socketGroupList[params.groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false then return nil, "Select an enabled PoB skill group" end
	if build.mainSocketGroup ~= params.groupIndex then return nil, "The factorial study must target PoB's currently selected Main Skill group" end
	local skillGem = group.gemList and group.gemList[params.skillGemIndex]
	local supportGem = group.gemList and group.gemList[params.supportGemIndex]
	if not skillGem or not supportGem then return nil, "The requested Main Skill or support slot is missing from the selected PoB group" end
	if params.skillGemIndex == params.supportGemIndex then return nil, "The Main Skill and support must occupy distinct PoB gem slots" end
	local selectedEntry = group.displaySkillList and group.displaySkillList[group.mainActiveSkill or 1]
	local sourceEffect = selectedEntry and selectedEntry.activeEffect and selectedEntry.activeEffect.grantedEffect
	local sourceInstance = selectedEntry and selectedEntry.activeEffect and selectedEntry.activeEffect.srcInstance
	local resolvedSkillIndex
	for index, gem in ipairs(group.gemList) do if gem == sourceInstance then resolvedSkillIndex = index break end end
	if not sourceEffect or type(sourceEffect.id) ~= "string" or resolvedSkillIndex ~= params.skillGemIndex then
		return nil, "skillGemIndex must identify the gem currently supplying PoB's selected Main Skill"
	end
	local sourceSkillData = skillGem.gemData or (skillGem.gemId and build.data.gems[skillGem.gemId])
	if not SkillCatalog.IsActiveSkillGem(sourceSkillData) then return nil, "The selected Main Skill must be a loaded active gem from PoB's database" end
	local sourceSupportData = supportGem.gemData or (supportGem.gemId and build.data.gems[supportGem.gemId])
	local alternateSupportData = build.data and build.data.gems and build.data.gems[params.supportGemId]
	local function supportEffect(gemData)
		local effect = gemData and gemData.grantedEffect
		if effect and effect.support then return effect end
		effect = gemData and gemData.secondaryGrantedEffect
		return effect and effect.support and effect or nil
	end
	local sourceSupportEffect = supportEffect(sourceSupportData)
	local alternateSupportEffect = supportEffect(alternateSupportData)
	if not sourceSupportEffect or not alternateSupportEffect then return nil, "Both support factor values must be supported gems from PoB's loaded database" end
	local currentSupportId = tostring(sourceSupportData.id or supportGem.gemId or "")
	local alternateSupportId = tostring(alternateSupportData.id or params.supportGemId)
	if currentSupportId == alternateSupportId then return nil, "supportGemId must change the selected support factor" end
	for index, otherGem in ipairs(group.gemList) do
		if index ~= params.supportGemIndex then
			local otherData = otherGem.gemData or (otherGem.gemId and build.data.gems[otherGem.gemId])
			local otherEffect = supportEffect(otherData)
			if otherEffect and tostring(otherData.id or otherGem.gemId or "") == alternateSupportId then
				return nil, "The replacement support already occupies another slot; the factorial factor must identify one support slot uniquely"
			end
		end
	end
	local skillLevel = tonumber(skillGem.level) or 1
	local supportLevel = tonumber(supportGem.level) or 1
	local skillQuality = tonumber(skillGem.quality) or 0
	local supportQuality = tonumber(supportGem.quality) or 0
	if not sourceEffect.levels or not sourceEffect.levels[skillLevel]
		or not sourceSupportEffect.levels or not sourceSupportEffect.levels[supportLevel]
		or not alternateSupportEffect.levels or not alternateSupportEffect.levels[supportLevel] then
		return nil, "PoB data must expose the exact current Main Skill and support gem levels for every factorial cell"
	end
	if skillQuality < 0 or skillQuality > 30 or supportQuality < 0 or supportQuality > 30 then
		return nil, "PoB source gem quality is outside the supported exact range"
	end
	if group.slot and group.slot ~= "" then
		local valid, details = SkillCatalog.ValidateSocketGroup(build, params.groupIndex)
		if not valid then return nil, "The selected skill group fails PoB's native socket/link validation: " .. tostring(details) end
		local replaceable, replaceError = SkillCatalog.CanReplaceSupportAtSlot(build, params.groupIndex,
			params.supportGemIndex, alternateSupportData)
		if not replaceable then return nil, replaceError end
	elseif group.source then
		return nil, "A PoB-granted skill group cannot be used for a passive/support factorial study"
	end
	local passiveSpec, passiveError = buildFactorialPassiveSpec(build, { params.nodeId })
	if not passiveSpec then return nil, "The passive factor is not a directly connected legal one-node addition: " .. tostring(passiveError) end
	local calcSignatureOk, sourceSignature = pcall(Candidate.BuildSignature, build)
	if not calcSignatureOk or type(sourceSignature) ~= "string" then return nil, "Could not fingerprint the selected PoB build" end
	local sourceBuildSignature, sourceBuildSignatureError = StudyContext.BuildSignature(sourceSignature)
	if not sourceBuildSignature then return nil, sourceBuildSignatureError end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(getConfiguration(build))
	if not scenarioSignature then return nil, scenarioError end
	local engine = {
		pobVersion = launch and launch.versionNumber or nil, pobBranch = Version.Branch(),
		dataVersion = Version.Data(build), treeVersion = build.spec.treeVersion,
		manifestFingerprint = launch and launch.manifestFingerprint or nil,
	}
	for _, key in ipairs({ "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }) do
		if engine[key] == nil or tostring(engine[key]) == "" then
			return nil, "Exact " .. key .. " identity is unavailable for a versioned passive/support study"
		end
	end
	bridge.factorialJobs = bridge.factorialJobs or { }
	local jobCount = 0
	for jobId, job in pairs(bridge.factorialJobs) do
		jobCount = jobCount + 1
		if jobCount >= maxFactorialJobs and job.status ~= "running" then bridge.factorialJobs[jobId] = nil; jobCount = jobCount - 1 end
	end
	if jobCount >= maxFactorialJobs then return nil, "The factorial study history is full; wait for a completed study to be pruned", "busy" end
	bridge.nextFactorialJob = (bridge.nextFactorialJob or 0) + 1
	local jobId = "pob-passive-support-factorial-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextFactorialJob)
	local sourceParams = { }
	if params.studyId ~= nil then sourceParams.studyId = params.studyId end
	if params.comparisonId ~= nil then sourceParams.comparisonId = params.comparisonId end
	local job = {
		studyKind = "passive_support", jobId = jobId, build = build, activeBuild = currentBuild(),
		sourceParams = sourceParams, studySource = studySource, sourceSignature = sourceSignature,
		sourceBuildSignature = sourceBuildSignature, scenarioSignature = scenarioSignature, engine = engine,
		groupIndex = params.groupIndex, skillGemIndex = params.skillGemIndex, supportGemIndex = params.supportGemIndex,
		sourceSkillGemId = tostring(sourceSkillData.id or skillGem.gemId or ""),
		sourceSkillEffectId = tostring(sourceEffect.id), sourceSupportGemId = currentSupportId,
		alternateSupportGemId = alternateSupportId, sourceSkillLevel = skillLevel, sourceSkillQuality = skillQuality,
		sourceSupportLevel = supportLevel, sourceSupportQuality = supportQuality, nodeId = params.nodeId,
		label = (params.label or ""):match("^%s*(.-)%s*$"), cells = { }, completedCells = 0,
		status = "running", progress = { phase = "Queued", currentCell = "baseline", completedCells = 0, totalCells = 4 },
		startedAt = os.time(), readOnly = true, activeBuildPreserved = true,
	}
	job.thread = coroutine.create(runPassiveSupportFactorialStudy)
	bridge.factorialJobs[jobId] = job
	return passiveSupportFactorialJobSummary(job)
end

passiveSupportFactorialJobSummary = function(job)
	return {
		jobId = job.jobId, status = job.status, progress = job.progress,
		completedCells = job.completedCells or 0, totalCells = 4,
		groupIndex = job.groupIndex, skillGemIndex = job.skillGemIndex, supportGemIndex = job.supportGemIndex,
		supportGemId = job.alternateSupportGemId, nodeId = job.nodeId,
		isActiveBuild = job.build == currentBuild(), buildReference = experimentSource(job.studySource),
		readOnly = true, activeBuildPreserved = true, error = job.error,
		result = job.status == "completed" and job.result or nil,
	}
end

local function evaluatePassiveSupportCell(job, cellName, addNode, changeSupport, baselineExtraPoints, prepared)
	local evaluationBuild, group, calcFunc, output, env
	if prepared then
		evaluationBuild, group, calcFunc = prepared.build, prepared.group, prepared.calcFunc
		output, env = prepared.output, prepared.env
	else
		evaluationBuild, group = job.build, job.build.skillsTab.socketGroupList[job.groupIndex]
		if changeSupport then
			local proxy, proxyGroupOrError = buildSkillSupportProxy(job.build, job, false, true)
			if not proxy then return nil, proxyGroupOrError end
			evaluationBuild, group = proxy, proxyGroupOrError
		end
	end
	local socketStatus = "unlinked_planning_group"
	if group.slot and group.slot ~= "" then
		local valid, details = SkillCatalog.ValidateSocketGroup(evaluationBuild, job.groupIndex)
		if not valid then return nil, "PoB native link/socket validation failed: " .. tostring(details) end
		socketStatus = "native_linked_group"
	elseif group.source then
		return nil, "A PoB-granted group cannot be used for this factorial study"
	end
	if not prepared then
		calcFunc, output, env = Calcs.getMiscCalculator(evaluationBuild)
	end
	if type(calcFunc) ~= "function" then
		return nil, "PoB did not provide the exact calculation function for the " .. cellName .. " cell"
	end
	local spec
	if addNode then
		local specError
		spec, specError = buildFactorialPassiveSpec(evaluationBuild, { job.nodeId })
		if not spec then return nil, "The " .. cellName .. " passive factor is no longer legal: " .. tostring(specError) end
		output, env = calcFunc({ spec = spec, returnEnv = true })
		if type(output) ~= "table" or type(env) ~= "table" then return nil, "PoB returned no exact output/environment for the " .. cellName .. " cell" end
	elseif type(output) ~= "table" or type(env) ~= "table" then
		return nil, "PoB did not provide a fresh exact calculation environment for the " .. cellName .. " cell"
	end
	local selected, selectedError = selectedSkillAndSupport(env, group, job.sourceSkillEffectId,
		job.supportGemIndex, job.groupIndex, true)
	if not selected then return nil, "The " .. cellName .. " cell failed exact Main Skill/support identity: " .. tostring(selectedError) end
	local expectedSupport = changeSupport and job.alternateSupportGemId or job.sourceSupportGemId
	if selected.supportGemId ~= expectedSupport then return nil, "PoB calculated a different support gem in the selected factor slot" end
	local cell, cellError = exactFactorialCell(evaluationBuild, output, env, spec, baselineExtraPoints)
	if not cell then return nil, cellError end
	cell.dps = Candidate.CopySkillDPS(output)
	cell.selectedSkill = selected
	cell.socketStatus = socketStatus
	cell.nodeId = job.nodeId
	cell.nodeAllocated = addNode == true
	cell.addedNodeIds = spec and spec.optimizerAddedNodeIds or { }
	cell.exactCalculated = true
	cell.evaluationMethod = "calcs_getMiscCalculator"
	cell.evidenceContext = {
		schemaVersion = 1, buildSignatureAlgorithm = "sha256", buildSignatureVersion = 1,
		buildSignature = job.sourceBuildSignature, scenarioSignature = job.scenarioSignature,
		engine = job.engine,
	}
	return cell, { build = evaluationBuild, group = group, calcFunc = calcFunc }
end

runPassiveSupportFactorialStudy = function(job)
	local sourceCalcFunc, sourceOutput, sourceEnv = Calcs.getMiscCalculator(job.build)
	if type(sourceCalcFunc) ~= "function" or type(sourceOutput) ~= "table" or type(sourceEnv) ~= "table" then
		error("PoB exact source calculation is unavailable")
	end
	local sourceGroup = job.build.skillsTab.socketGroupList[job.groupIndex]
	local sourceEvaluator = { build = job.build, group = sourceGroup, calcFunc = sourceCalcFunc,
		output = sourceOutput, env = sourceEnv }
	local supportEvaluator
	local cells = {
		{ name = "baseline", node = false, support = false },
		{ name = "factorA", node = true, support = false },
		{ name = "factorB", node = false, support = true },
		{ name = "combined", node = true, support = true },
	}
	for _, cellSpec in ipairs(cells) do
		if job.cancelRequested then job.status = "cancelled" return end
		local baselineExtra = job.cells.baseline and job.cells.baseline.extraPassivePoints or nil
		local evaluator
		if cellSpec.name == "baseline" or cellSpec.name == "factorA" then evaluator = sourceEvaluator
		elseif cellSpec.name == "combined" then evaluator = supportEvaluator end
		local cell, nextEvaluator = evaluatePassiveSupportCell(job, cellSpec.name, cellSpec.node,
			cellSpec.support, baselineExtra, evaluator)
		if not cell then error("The " .. cellSpec.name .. " passive/support cell failed exact PoB validation: " .. tostring(nextEvaluator)) end
		if cellSpec.name == "baseline" then
			sourceEvaluator.output = nil
			sourceEvaluator.env = nil
		elseif cellSpec.name == "factorB" then
			supportEvaluator = nextEvaluator
		elseif cellSpec.name == "combined" then
			supportEvaluator = nil
		end
		job.cells[cellSpec.name] = cell
		job.completedCells = job.completedCells + 1
		job.progress = { phase = "Exact PoB calculation", currentCell = cellSpec.name,
			completedCells = job.completedCells, totalCells = 4 }
		coroutine.yield(job.progress)
	end
	local unchanged, afterSignature = pcall(Candidate.BuildSignature, job.build)
	if not unchanged or afterSignature ~= job.sourceSignature then error("The selected PoB build changed during the read-only passive/support study") end
	local interaction, interactionError = FactorialStudy.Compute(job.cells)
	if not interaction then error(interactionError) end
	local snapshot, snapshotError = getSnapshot(job.build)
	if not snapshot then error(snapshotError or "The PoB source snapshot is unavailable") end
	snapshot.exactMetrics = job.cells.baseline.metrics
	snapshot.availableItems = nil
	snapshot.availableItemsTruncated = nil
	snapshot.classOptions = nil
	snapshot.requirements = job.cells.baseline.requirements
	snapshot.mainSkillPayability = job.cells.baseline.mainSkillPayability
	snapshot.activitySustain = job.cells.baseline.activitySustain
	local allRequirementsFeasible, allActivityRatesFeasible = true, true
	for _, cellName in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
		local cell = job.cells[cellName]
		allRequirementsFeasible = allRequirementsFeasible and cell.requirements.feasible == true
			and cell.mainSkillPayability.feasible == true
		allActivityRatesFeasible = allActivityRatesFeasible and cell.activitySustain.status == "pass"
	end
	local baseGroup = job.build.skillsTab.socketGroupList[job.groupIndex]
	local socketStatus = baseGroup.slot and baseGroup.slot ~= "" and "native_linked_group" or "unlinked_planning_group"
	local function gemSummary(gemId)
		local gemData = job.build.data.gems[gemId]
		return { gemId = gemId, name = boundedText(gemData and gemData.name or gemId, 120),
			level = job.sourceSupportLevel, quality = job.sourceSupportQuality }
	end
	local source = experimentSource(job.studySource)
	source.buildSignatureAlgorithm = "sha256"
	source.buildSignatureVersion = 1
	source.buildSignature = job.sourceBuildSignature
	source.scenarioSignature = job.scenarioSignature
	local record = {
		kind = "passive_support_factorial_interaction",
		label = job.label ~= "" and job.label or "Passive node and support four-cell interaction study",
		source = source,
		engine = {
			pobVersion = job.engine.pobVersion, pobBranch = job.engine.pobBranch,
			dataVersion = job.engine.dataVersion, treeVersion = job.engine.treeVersion,
			manifestFingerprint = job.engine.manifestFingerprint, lookupTableStatus = "not_audited",
		},
		buildState = snapshot,
		experiment = {
			unit = "four_cell_passive_support_factorial", factorialSchemaVersion = 1,
			formula = interaction.formula,
			factorA = { operation = "add_passive_node", nodeId = job.nodeId },
			factorB = {
				operation = "replace_support_gem", groupIndex = job.groupIndex,
				skillGemIndex = job.skillGemIndex, gemIndex = job.supportGemIndex,
				before = gemSummary(job.sourceSupportGemId), after = gemSummary(job.alternateSupportGemId),
			},
			changedVariables = { "passiveNode", "supportGem" }, socketStatus = socketStatus,
		},
		baseline = {
			metrics = job.cells.baseline.metrics, requirements = job.cells.baseline.requirements,
			mainSkillPayability = job.cells.baseline.mainSkillPayability,
			activitySustain = job.cells.baseline.activitySustain, selectedSkill = job.cells.baseline.selectedSkill,
		},
		candidate = {
			metrics = job.cells.combined.metrics, requirements = job.cells.combined.requirements,
			mainSkillPayability = job.cells.combined.mainSkillPayability,
			activitySustain = job.cells.combined.activitySustain, selectedSkill = job.cells.combined.selectedSkill,
			passivePointsUsed = job.cells.combined.passivePointsUsed,
		},
		factorial = { formula = interaction.formula, cells = job.cells,
			interaction = interaction.metrics, metricCount = interaction.metricCount },
		metricDelta = metricDelta(job.cells.baseline.metrics, job.cells.combined.metrics),
		admission = {
			exactCalculated = true, useRequirementsFeasible = allRequirementsFeasible,
			activityStatus = job.cells.combined.activitySustain.status,
			activityRatesFeasible = allActivityRatesFeasible, activitySustainCertified = false,
			scenarioConditionsCertified = false, lookupTablesCertified = false, trainingEligible = false,
		},
	}
	local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
	if not stored then error(storeError or "PoB could not store the passive/support factorial study") end
	job.result = {
		status = "exact_passive_support_factorial_recorded", readOnly = true, activeBuildPreserved = true,
		isActiveBuild = job.build == currentBuild(), buildReference = experimentSource(job.studySource),
		groupIndex = job.groupIndex, skillGemIndex = job.skillGemIndex, supportGemIndex = job.supportGemIndex,
		skillGemId = job.sourceSkillGemId, skillEffectId = job.sourceSkillEffectId,
		supportGemId = job.alternateSupportGemId, nodeId = job.nodeId, socketStatus = socketStatus,
		formula = interaction.formula, cells = job.cells, interaction = interaction.metrics,
		interactionMetricCount = interaction.metricCount, recordId = stored.recordId,
		storeFile = stored.storeFile, recorded = stored.duplicate ~= true, duplicate = stored.duplicate == true,
		trainingEligible = false,
	}
	job.status = "completed"
	job.completedAt = os.time()
end

local function cancelPassiveSupportFactorialStudy(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_passive_support_factorial_cancel field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_passive_support_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "passive_support" then return nil, "Unknown passive/support factorial study job" end
	if job.status == "running" then job.cancelRequested = true; job.status = "cancelled"; job.completedAt = os.time(); job.thread = nil end
	return passiveSupportFactorialJobSummary(job)
end

local function getPassiveSupportFactorialStudyStatus(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_passive_support_factorial_status field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_passive_support_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "passive_support" then return nil, "Unknown passive/support factorial study job" end
	return passiveSupportFactorialJobSummary(job)
end

local function factorialJobSummary(job)
	return {
		jobId = job.jobId,
		status = job.status,
		progress = job.progress,
		completedCells = job.completedCells or 0,
		totalCells = 4,
		factorANodeId = job.factorANodeId,
		factorBNodeId = job.factorBNodeId,
		isActiveBuild = job.build == currentBuild(),
		buildReference = experimentSource(job.studySource),
		readOnly = true,
		activeBuildPreserved = true,
		error = job.error,
		result = job.status == "completed" and job.result or nil,
	}
end

local function masteryEffectStats(tree, effectId)
	local effect = tree.masteryEffects[effectId]
	local stats = { }
	for _, stat in ipairs(effect and (effect.stats or effect.sd) or { }) do
		if type(stat) == "string" and #stats < 6 then stats[#stats + 1] = stat end
	end
	return boundedText(table.concat(stats, "; "), 240)
end

local function evaluateMasteryExperiment(params)
	local build, studySource = resolveParamsBuild(params, "compare a mastery effect")
	if not build then return nil, studySource end
	local nodeId, effectId = tonumber(params.masteryNodeId), tonumber(params.effectId)
	if not isFinite(nodeId) or nodeId ~= math.floor(nodeId) or nodeId < 1 or nodeId > 2147483647 then
		return nil, "masteryNodeId must be a positive PoB passive-tree node ID"
	end
	if not isFinite(effectId) or effectId ~= math.floor(effectId) or effectId < 1 or effectId > 2147483647 then
		return nil, "effectId must be a positive PoB mastery-effect ID"
	end
	if params.label ~= nil and (type(params.label) ~= "string" or #params.label > 120 or params.label:find("[%c]")) then
		return nil, "label must be plain text of at most 120 characters"
	end
	local label = params.label and params.label:match("^%s*(.-)%s*$") or ""
	local spec = build.spec
	local node = spec.nodes[nodeId]
	if not node or node.type ~= "Mastery" then return nil, "masteryNodeId must identify a native PoB Mastery node" end
	if not spec.allocNodes[nodeId] then return nil, "The mastery node must already be allocated in the selected build" end
	local beforeEffectId = tonumber(spec.masterySelections and spec.masterySelections[nodeId])
	if not beforeEffectId or not spec.tree.masteryEffects[beforeEffectId] then
		return nil, "The allocated mastery node has no valid currently selected effect"
	end
	if beforeEffectId == effectId then return nil, "The requested mastery effect is already selected; no experiment would occur" end
	local isOption = false
	for _, option in ipairs(node.masteryEffects or { }) do
		if tonumber(option.effect) == effectId then isOption = true break end
	end
	if not isOption or not spec.tree.masteryEffects[effectId] then
		return nil, "effectId is not an option on this native PoB mastery node"
	end
	for otherNodeId, selectedEffectId in pairs(spec.masterySelections or { }) do
		if tonumber(otherNodeId) ~= nodeId and tonumber(selectedEffectId) == effectId then
			return nil, "PoB already uses this mastery effect on another allocated mastery node"
		end
	end
	local sourceSignature = Candidate.BuildSignature(build)
	local proxy, proxyError = Candidate.BuildPassiveSpec(build, { }, { }, {
		masteryVariant = { nodeId = nodeId, effectId = effectId },
	})
	if not proxy then return nil, proxyError end
	if not proxy.allocNodes[nodeId] or tonumber(proxy.masterySelections[nodeId]) ~= effectId then
		return nil, "PoB could not reproduce the requested mastery effect in an isolated passive spec"
	end
	local calcFunc, baselineOutput = Calcs.getMiscCalculator(build)
	local candidateOutput = calcFunc({ spec = proxy })
	local signatureOk, afterSignature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or afterSignature ~= sourceSignature then
		return nil, "The source build changed during the isolated mastery comparison"
	end
	local baselineMetrics = exactMetrics(baselineOutput)
	local candidateMetrics = exactMetrics(candidateOutput)
	local mainGroup = build.skillsTab and build.skillsTab.socketGroupList[build.mainSocketGroup]
	local mainSkill = mainGroup and mainGroup.displaySkillList and mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
	local baselineRequirements = Validator.CheckRequirements(baselineOutput, build.characterLevel)
	local candidateRequirements = Validator.CheckRequirements(candidateOutput, build.characterLevel)
	local baselinePayability = Validator.CheckMainSkillPayability(baselineOutput, skillName(mainSkill))
	local candidatePayability = Validator.CheckMainSkillPayability(candidateOutput, skillName(mainSkill))
	local baselineActivity = activityForOutput(baselineOutput)
	local candidateActivity = activityForOutput(candidateOutput)
	local result = {
		readOnly = true,
		activeBuildPreserved = true,
		isActiveBuild = build == currentBuild(),
		buildReference = experimentSource(studySource),
		masteryNodeId = nodeId,
		masteryNodeName = boundedText(node.dn or node.name or "Mastery", 120),
		beforeEffectId = beforeEffectId,
		afterEffectId = effectId,
		beforeEffectStats = masteryEffectStats(spec.tree, beforeEffectId),
		afterEffectStats = masteryEffectStats(spec.tree, effectId),
		baselineMetrics = baselineMetrics,
		candidateMetrics = candidateMetrics,
		metricDelta = metricDelta(baselineMetrics, candidateMetrics),
	}
	local snapshot, snapshotError = getSnapshot(build)
	if not snapshot then return nil, snapshotError end
	snapshot.exactMetrics = baselineMetrics
	snapshot.availableItems = nil
	snapshot.availableItemsTruncated = nil
	snapshot.classOptions = nil
	snapshot.requirements = baselineRequirements
	snapshot.mainSkillPayability = baselinePayability
	snapshot.activitySustain = baselineActivity
	local useRequirementsFeasible = baselineRequirements.feasible and candidateRequirements.feasible
		and baselinePayability.feasible and candidatePayability.feasible
	local record = {
		kind = "mastery_effect_pair",
		label = label ~= "" and label or "One-mastery-effect comparison",
		source = experimentSource(studySource),
		engine = {
			pobVersion = launch and launch.versionNumber or nil,
			pobBranch = Version.Branch(),
			dataVersion = Version.Data(build),
			treeVersion = spec.treeVersion,
			manifestFingerprint = launch and launch.manifestFingerprint or nil,
			lookupTableStatus = "not_audited",
		},
		buildState = snapshot,
		experiment = {
			unit = "one_mastery_effect",
			changedParameter = "masteryEffect",
			masteryNodeId = nodeId,
			before = { effectId = beforeEffectId },
			after = { effectId = effectId },
		},
		baseline = {
			metrics = baselineMetrics,
			requirements = baselineRequirements,
			mainSkillPayability = baselinePayability,
			activitySustain = baselineActivity,
		},
		candidate = {
			metrics = candidateMetrics,
			requirements = candidateRequirements,
			mainSkillPayability = candidatePayability,
			activitySustain = candidateActivity,
		},
		metricDelta = result.metricDelta,
		admission = {
			exactCalculated = true,
			useRequirementsFeasible = useRequirementsFeasible,
			activityStatus = candidateActivity.status,
			activityRatesFeasible = candidateActivity.status == "pass",
			activitySustainCertified = false,
			scenarioConditionsCertified = false,
			lookupTablesCertified = false,
			trainingEligible = false,
		},
	}
	local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
	if not stored then return nil, storeError end
	result.recordId = stored.recordId
	result.storeFile = stored.storeFile
	result.recorded = stored.duplicate ~= true
	result.duplicate = stored.duplicate == true
	return result
end

local function applyPassiveDelta(params)
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before applying a passive-tree change" end
	local addNodeIds, addError = parseNodeIdList(params.addNodeIds, "addNodeIds")
	if not addNodeIds then return nil, addError end
	local removeNodeIds, removeError = parseNodeIdList(params.removeNodeIds, "removeNodeIds")
	if not removeNodeIds then return nil, removeError end
	if #addNodeIds + #removeNodeIds == 0 then return nil, "Provide at least one passive node to add or remove" end
	local parsed = Inputs.Parse({ })
	local validTree, treeError = Inputs.ValidateAgainstTree(parsed, build.spec.tree)
	if not validTree then return nil, treeError end
	local validBuild, buildError = Inputs.ValidateAgainstBuild(parsed, build.spec)
	if not validBuild then return nil, buildError end
	local proxy, proxyError = Candidate.BuildPassiveSpec(build, addNodeIds, removeNodeIds)
	if not proxy then return nil, proxyError end
	local validCandidate, candidateError = TreeSearch.ValidateCandidate(build.spec, proxy.optimizerAddedNodeIds, parsed,
		TreeSearch.BuildRegionMap(build.spec), proxy.optimizerRemovedNodeIds, proxy)
	if not validCandidate then return nil, candidateError end
	local calcFunc, baselineOutput, baselineEnv = Calcs.getMiscCalculator(build)
	local candidateOutput, candidateEnv = calcFunc({ spec = proxy, returnEnv = true })
	local baselineExtraPoints = exactPassiveExtraPoints(build, baselineOutput, baselineEnv)
	local extraPoints = exactPassiveExtraPoints(build, candidateOutput, candidateEnv, baselineExtraPoints)
	if not isFinite(extraPoints) then return nil, "PoB did not expose exact passive ExtraPoints for the requested tree" end
	local pointLimit = getPassivePointLimit(build, proxy:CountAllocNodes(), extraPoints)
	if proxy:CountAllocNodes() > pointLimit then return nil, "The requested tree exceeds PoB's exact passive-point limit" end
	local candidate = {
		feasible = true,
		sourceSignature = Candidate.BuildSignature(build),
		nodeIds = proxy.optimizerAddedNodeIds,
		removeNodeIds = proxy.optimizerRemovedNodeIds,
		evaluation = { metrics = exactMetrics(candidateOutput) },
	}
	local applied, applyError = Candidate.Apply(build, candidate)
	if not applied then return nil, applyError end
	return {
		applied = true,
		newVariation = #candidate.nodeIds > 0 or #candidate.removeNodeIds > 0,
		addedNodeIds = candidate.nodeIds,
		removedNodeIds = candidate.removeNodeIds,
		passivePointsUsed = proxy:CountAllocNodes(),
		passivePointLimit = pointLimit,
		metrics = candidate.evaluation.metrics,
		message = applyError or "Applied as a new PoB passive-tree variation after exact calculation.",
	}
end

local function getStudyItemState(build, itemId)
	if not itemId or itemId == 0 then return { itemId = 0 } end
	local item = build.itemsTab and build.itemsTab.items[itemId]
	if not item then return nil, "The selected PoB item disappeared before its exact study snapshot was captured" end
	local rawOk, rawItem = pcall(function()
		if item.BuildRaw then return item:BuildRaw() end
		return item.raw
	end)
	if not rawOk or type(rawItem) ~= "string" or rawItem == "" then
		return nil, "PoB did not provide a reproducible raw item snapshot for this study"
	end
	if #rawItem > 16000 then return nil, "The selected item exceeds the 16 KiB study snapshot limit" end
	return {
		itemId = itemId,
		name = boundedText(item.name or item.title or "Unknown item", 128),
		base = boundedText(item.base and item.base.name or "", 96),
		rarity = boundedText(item.rarity or "", 32),
		poBItemText = rawItem,
	}
end

local function evaluateItemSwap(params, recordExperiment)
	local build, studySource = resolveParamsBuild(params, "evaluate an item swap")
	if not build then return nil, studySource end
	if recordExperiment and params.label ~= nil
		and (type(params.label) ~= "string" or #params.label > 120 or params.label:find("[%z\1-\31\127]")) then
		return nil, "label must be plain text up to 120 characters"
	end
	local slotName, itemId = params.slot, tonumber(params.itemId)
	local itemSet = build.itemsTab and (build.itemsTab.activeItemSet or build.itemsTab.itemSets[build.itemsTab.activeItemSetId])
	if type(slotName) ~= "string" or #slotName > 64 or not itemSet or not itemSet[slotName] then return nil, "slot must be an existing slot in the active PoB item set" end
	if not isFinite(itemId) or itemId ~= math.floor(itemId) or itemId < 0 then return nil, "itemId must be a non-negative integer; use 0 to test an empty slot" end
	local item = itemId > 0 and build.itemsTab.items[itemId] or nil
	if itemId > 0 and not item then return nil, "itemId does not exist in the current PoB item list" end
	if item and not build.itemsTab:IsItemValidForSlot(item, slotName, itemSet) then return nil, "PoB does not allow this item in the requested slot" end
	local currentItemId = tonumber(itemSet[slotName].selItemId) or 0
	if recordExperiment and currentItemId == itemId then return nil, "The requested item is already equipped in this slot; no item experiment would occur" end
	local sourceSignature = Candidate.BuildSignature(build)
	local calcFunc, baselineOutput = Calcs.getMiscCalculator(build)
	local candidateOutput = calcFunc({ repSlotName = slotName, repItem = item })
	local signatureOk, afterSignature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or afterSignature ~= sourceSignature then
		return nil, "The source build changed during the isolated item comparison"
	end
	local baselineMetrics = exactMetrics(baselineOutput)
	local candidateMetrics = exactMetrics(candidateOutput)
	local result = {
		readOnly = true,
		activeBuildPreserved = true,
		isActiveBuild = build == currentBuild(),
		buildReference = experimentSource(studySource),
		slot = slotName,
		currentItemId = currentItemId,
		itemId = itemId,
		itemName = item and boundedText(item.name or item.title or "", 120) or nil,
		baselineMetrics = baselineMetrics,
		candidateMetrics = candidateMetrics,
		metricDelta = metricDelta(baselineMetrics, candidateMetrics),
	}
	if recordExperiment then
		local snapshot, snapshotError = getSnapshot(build)
		if not snapshot then return nil, snapshotError end
		snapshot.exactMetrics = baselineMetrics
		snapshot.availableItems = nil
		snapshot.availableItemsTruncated = nil
		snapshot.classOptions = nil
		local beforeItem, beforeError = getStudyItemState(build, currentItemId)
		if not beforeItem then return nil, beforeError end
		local afterItem, afterError = getStudyItemState(build, itemId)
		if not afterItem then return nil, afterError end
		local baselineRequirements = Validator.CheckRequirements(baselineOutput, build.characterLevel)
		local candidateRequirements = Validator.CheckRequirements(candidateOutput, build.characterLevel)
		local mainGroup = build.skillsTab and build.skillsTab.socketGroupList[build.mainSocketGroup]
		local mainSkill = mainGroup and mainGroup.displaySkillList and mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
		local baselinePayability = Validator.CheckMainSkillPayability(baselineOutput, skillName(mainSkill))
		local candidatePayability = Validator.CheckMainSkillPayability(candidateOutput, skillName(mainSkill))
		local baselineActivity = activityForOutput(baselineOutput)
		local candidateActivity = activityForOutput(candidateOutput)
		snapshot.requirements = baselineRequirements
		snapshot.mainSkillPayability = baselinePayability
		snapshot.activitySustain = baselineActivity
		local record = {
			kind = "item_slot_pair",
			label = boundedText(params.label or "One-slot item comparison", 120),
			source = experimentSource(studySource),
			engine = {
				pobVersion = launch and launch.versionNumber or nil,
				pobBranch = Version.Branch(),
				dataVersion = Version.Data(build),
				treeVersion = build.spec.treeVersion,
				manifestFingerprint = launch and launch.manifestFingerprint or nil,
				lookupTableStatus = "not_audited",
			},
			buildState = snapshot,
			experiment = { unit = "one_item_slot", slot = slotName, before = beforeItem, after = afterItem },
			baseline = {
				metrics = baselineMetrics,
				requirements = baselineRequirements,
				mainSkillPayability = baselinePayability,
				activitySustain = baselineActivity,
			},
			candidate = {
				metrics = candidateMetrics,
				requirements = candidateRequirements,
				mainSkillPayability = candidatePayability,
				activitySustain = candidateActivity,
			},
			metricDelta = result.metricDelta,
			admission = {
				exactCalculated = true,
				useRequirementsFeasible = baselineRequirements.feasible and candidateRequirements.feasible
					and baselinePayability.feasible and candidatePayability.feasible,
				activityStatus = candidateActivity.status,
				activityRatesFeasible = candidateActivity.status == "pass",
				activitySustainCertified = false,
				scenarioConditionsCertified = false,
				lookupTablesCertified = false,
				trainingEligible = false,
			},
		}
		local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
		if not stored then return nil, storeError end
		result.recordId = stored.recordId
		result.storeFile = stored.storeFile
		result.recorded = stored.duplicate ~= true
		result.duplicate = stored.duplicate == true
	end
	return result
end

local function selectedSkillIdentity(env, group, effectId, groupIndex)
	local matches = { }
	for _, activeSkill in ipairs(env and env.player and env.player.activeSkillList or { }) do
		local activeEffect = activeSkill.activeEffect and activeSkill.activeEffect.grantedEffect
		if activeSkill.socketGroup == group and activeEffect and tostring(activeEffect.id) == tostring(effectId) then
			matches[#matches + 1] = activeSkill
		end
	end
	if #matches ~= 1 then return nil, "PoB did not expose one unambiguous active skill for the requested effect" end
	local activeSkill = matches[1]
	if env.player.mainSkill ~= activeSkill then return nil, "PoB calculated a different Main Skill from the requested skill/item interaction" end
	local sourceGem = activeSkill.activeEffect.srcInstance
	local sourceGemIndex
	for index, gem in ipairs(group.gemList or { }) do
		if gem == sourceGem then sourceGemIndex = index break end
	end
	if not sourceGemIndex then return nil, "PoB's selected Main Skill is not sourced by a gem in the requested socket group" end
	local supportGemIds, seen = { }, { }
	local supportEffectIds, seenEffects = { }, { }
	for _, effect in ipairs(activeSkill.effectList or { }) do
		local support = effect and effect.grantedEffect and effect.grantedEffect.support
		local instance = effect and effect.srcInstance
		local gemId = support and instance and instance.gemData and instance.gemData.id
		if gemId and not seen[gemId] then supportGemIds[#supportGemIds + 1] = tostring(gemId); seen[gemId] = true end
		local supportId = support and effect.grantedEffect and effect.grantedEffect.id
		if supportId and not seenEffects[supportId] then supportEffectIds[#supportEffectIds + 1] = tostring(supportId); seenEffects[supportId] = true end
	end
	table.sort(supportGemIds)
	table.sort(supportEffectIds)
	local activeEffect = activeSkill.activeEffect.grantedEffect
	return {
		name = boundedText(activeEffect.name or "", 120),
		effectId = tostring(activeEffect.id or ""),
		gemId = tostring(sourceGem and sourceGem.gemData and sourceGem.gemData.id or ""),
		groupIndex = groupIndex,
		gemIndex = sourceGemIndex,
		supportGemIds = supportGemIds,
		supportEffectIds = supportEffectIds,
		isMainSkill = true,
	}
end

local function sameStringArray(left, right)
	if type(left) ~= "table" or type(right) ~= "table" then return false end
	if #left ~= #right then return false end
	for index, value in ipairs(left) do if tostring(value) ~= tostring(right[index]) then return false end end
	return true
end

local function socketedSupportGemIds(build, group)
	local ids, seen = { }, { }
	for _, gem in ipairs(group and group.gemList or { }) do
		local gemData = gem.gemData or (gem.gemId and build.data.gems[gem.gemId])
		local grantedEffect = gemData and gemData.grantedEffect
		local gemId = gemData and (gemData.id or gem.gemId)
		if gem.enabled ~= false and grantedEffect and grantedEffect.support and gemId and not seen[gemId] then
			ids[#ids + 1] = tostring(gemId)
			seen[gemId] = true
		end
	end
	table.sort(ids)
	return ids
end

skillItemStudyEngine = function(build)
	local engine = {
		pobVersion = launch and launch.versionNumber or nil,
		pobBranch = Version.Branch(),
		dataVersion = Version.Data(build),
		treeVersion = build and build.spec and build.spec.treeVersion or nil,
		manifestFingerprint = launch and launch.manifestFingerprint or nil,
	}
	for _, key in ipairs({ "pobVersion", "pobBranch", "dataVersion", "treeVersion", "manifestFingerprint" }) do
		if type(engine[key]) ~= "string" and type(engine[key]) ~= "number" then
			return nil, "Exact " .. key .. " identity is unavailable for a versioned skill/item study"
		end
		if tostring(engine[key]) == "" then return nil, "Exact " .. key .. " identity is unavailable for a versioned skill/item study" end
	end
	return engine
end

local function evaluateSkillItemSlotCell(build, job, cellName, changeSkill, changeItem)
	local evaluationBuild, group = build, build.skillsTab.socketGroupList[job.groupIndex]
	if changeSkill then
		local proxy, proxyGroupOrError = buildSkillSupportProxy(build, job, true, false)
		if not proxy then return nil, proxyGroupOrError end
		evaluationBuild, group = proxy, proxyGroupOrError
	end
	local socketValid, socketDetails = SkillCatalog.ValidateSocketGroup(evaluationBuild, job.groupIndex)
	if not socketValid or not socketDetails or socketDetails.status ~= "linked" then
		return nil, "The " .. cellName .. " cell no longer has an exact native linked Main Skill group: " .. tostring(socketDetails or "link proof unavailable")
	end
	local itemId = changeItem and job.alternateItemId or job.sourceItemId
	local replacementItem = itemId > 0 and build.itemsTab.items[itemId] or nil
	if itemId > 0 and not replacementItem then return nil, "The selected study item disappeared before exact calculation" end
	local override
	if changeItem then override = { repSlotName = job.slot, repItem = replacementItem } end
	local calcFunc, output, env = Calcs.getMiscCalculator(evaluationBuild, override)
	if type(calcFunc) ~= "function" or type(output) ~= "table" or type(env) ~= "table" then
		return nil, "PoB did not provide an exact calculation environment for the " .. cellName .. " skill/item cell"
	end
	local effectId = changeSkill and job.alternateSkillEffectId or job.sourceSkillEffectId
	local selected, selectedError = selectedSkillIdentity(env, group, effectId, job.groupIndex)
	if not selected then return nil, "The " .. cellName .. " cell is not the requested exact Main Skill: " .. tostring(selectedError) end
	local expectedGemId = changeSkill and job.alternateSkillGemId or job.sourceSkillGemId
	if selected.groupIndex ~= job.groupIndex or selected.gemIndex ~= job.skillGemIndex
		or tostring(selected.gemId) ~= tostring(expectedGemId) then
		return nil, "The " .. cellName .. " cell did not calculate the exact selected skill gem and socket identity"
	end
	selected.socketedSupportGemIds = socketedSupportGemIds(evaluationBuild, group)
	if not sameStringArray(selected.socketedSupportGemIds, job.socketedSupportGemIds) then
		return nil, "The " .. cellName .. " cell changed the exact socketed support-gem context"
	end
	local expectedItemId = changeItem and job.alternateItemId or job.sourceItemId
	local evaluatedItem = env.player and env.player.itemList and env.player.itemList[job.slot]
	local evaluatedItemId = evaluatedItem and tonumber(evaluatedItem.id) or 0
	if evaluatedItemId ~= expectedItemId then
		return nil, "The " .. cellName .. " cell did not calculate the requested item instance in slot " .. tostring(job.slot)
	end
	local skill = env.player.mainSkill
	return {
		metrics = exactMetrics(output),
		dps = Candidate.CopySkillDPS(output),
		requirements = Validator.CheckRequirements(output, evaluationBuild.characterLevel),
		mainSkillPayability = Validator.CheckMainSkillPayability(output, skillName(skill)),
		activitySustain = activityForOutput(output),
		selectedSkill = selected,
		selectedItem = { slot = job.slot, itemId = evaluatedItemId },
		socketStatus = "native_linked_group",
		exactCalculated = true,
		evaluationMethod = "calcs_getMiscCalculator",
		evidenceContext = {
			schemaVersion = 1,
			buildSignatureAlgorithm = "sha256",
			buildSignatureVersion = 1,
			buildSignature = job.sourceBuildSignature,
			scenarioSignature = job.scenarioSignature,
			engine = {
				pobVersion = job.engine.pobVersion, pobBranch = job.engine.pobBranch,
				dataVersion = job.engine.dataVersion, treeVersion = job.engine.treeVersion,
				manifestFingerprint = job.engine.manifestFingerprint,
			},
		},
	}
end

local skillItemFactorialJobSummary
local runSkillItemFactorialStudy

local function startSkillItemSlotFactorialStudy(params)
	local allowed = {
		groupIndex = true, skillGemIndex = true, skillGemId = true, skillEffectId = true,
		slot = true, itemId = true, label = true, studyId = true, comparisonId = true,
	}
	for key in pairs(params or { }) do
		if not allowed[key] then return nil, "Unsupported record_skill_item_slot_factorial_experiment field: " .. tostring(key) end
	end
	for _, key in ipairs({ "groupIndex", "skillGemIndex" }) do
		local value = params[key]
		if not isFinite(value) or value < 1 or value ~= math.floor(value) or value > 100 then
			return nil, key .. " must be a positive PoB skill group/gem index"
		end
	end
	if type(params.skillGemId) ~= "string" or #params.skillGemId < 1 or #params.skillGemId > 120
		or type(params.skillEffectId) ~= "string" or #params.skillEffectId < 1 or #params.skillEffectId > 120 then
		return nil, "skillGemId and skillEffectId must be exact loaded PoB IDs from the gem catalog"
	end
	if type(params.slot) ~= "string" or params.slot == "" or #params.slot > 64 or params.slot:find("[%c]") then
		return nil, "slot must be an exact equipment slot name from the active PoB item set"
	end
	if not isFinite(params.itemId) or params.itemId < 0 or params.itemId ~= math.floor(params.itemId) then
		return nil, "itemId must be a non-negative PoB item ID; use 0 for an empty slot"
	end
	if params.label ~= nil and (type(params.label) ~= "string" or #params.label > 120 or params.label:find("[%c]")) then
		return nil, "label must be plain text of at most 120 characters"
	end
	if params.studyId ~= nil and params.comparisonId ~= nil then return nil, "Provide either studyId or comparisonId, not both" end
	local build, studySource = resolveStudyBuild(params)
	if not build then return nil, studySource end
	for _, qaJob in pairs(bridge.qaJobs or { }) do
		if qaJob.status == "running" then return nil, "A local PoB QA suite is running", "busy" end
	end
	for _, progressionJob in pairs(bridge.progressionJobs or { }) do
		if progressionJob.status == "running" then return nil, "A progression audit is already running", "busy" end
	end
	for _, factorialJob in pairs(bridge.factorialJobs or { }) do
		if factorialJob.status == "running" then return nil, "A factorial study is already running", "busy" end
	end
	local activeOptimizer = currentBuild() and currentBuild().optimizerTab
	if activeOptimizer and ((activeOptimizer.job and activeOptimizer.job.status == "running")
		or (activeOptimizer.classRootJob and activeOptimizer.classRootJob.status == "running")) then
		return nil, "An optimizer or class-root search is already running", "busy"
	end
	local group = build.skillsTab and build.skillsTab.socketGroupList[params.groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false or group.source then return nil, "Select an enabled manual PoB skill group" end
	if build.mainSocketGroup ~= params.groupIndex then return nil, "The factorial study must target PoB's currently selected Main Skill group" end
	local linked, linkDetails = SkillCatalog.ValidateSocketGroup(build, params.groupIndex)
	if not linked or not linkDetails or linkDetails.status ~= "linked" then
		return nil, "A skill/item interaction study requires the selected Main Skill to be natively socketed and linked: " .. tostring(linkDetails or "link proof unavailable")
	end
	local skillGem = group.gemList and group.gemList[params.skillGemIndex]
	local sourceSkillData = skillGem and (skillGem.gemData or (skillGem.gemId and build.data.gems[skillGem.gemId]))
	local alternateSkillData = build.data.gems[params.skillGemId]
	if not SkillCatalog.IsActiveSkillGem(sourceSkillData) or not SkillCatalog.IsActiveSkillGem(alternateSkillData) then
		return nil, "Both skill factor values must be supported active gems in PoB's loaded database"
	end
	local selectedEntry = group.displaySkillList and group.displaySkillList[group.mainActiveSkill or 1]
	local sourceEffect = selectedEntry and selectedEntry.activeEffect and selectedEntry.activeEffect.grantedEffect
	local sourceInstance = selectedEntry and selectedEntry.activeEffect and selectedEntry.activeEffect.srcInstance
	local resolvedGemIndex
	for index, gem in ipairs(group.gemList or { }) do if gem == sourceInstance then resolvedGemIndex = index break end end
	if not sourceEffect or not sourceEffect.id or resolvedGemIndex ~= params.skillGemIndex then
		return nil, "skillGemIndex must identify the gem currently supplying PoB's selected Main Skill"
	end
	local sourceSkillId = tostring(sourceSkillData.id or skillGem.gemId or "")
	if sourceSkillId == params.skillGemId then return nil, "skillGemId must change the Main Skill factor" end
	local alternateEffect
	for _, effect in ipairs(alternateSkillData.grantedEffectList or { alternateSkillData.grantedEffect }) do
		if effect and not effect.support and not effect.unsupported and tostring(effect.id) == params.skillEffectId then alternateEffect = effect break end
	end
	if not alternateEffect then return nil, "skillEffectId is not an active effect granted by skillGemId" end
	local level, quality = tonumber(skillGem.level) or 1, tonumber(skillGem.quality) or 0
	if not sourceEffect.levels or not sourceEffect.levels[level] or not alternateEffect.levels or not alternateEffect.levels[level] then
		return nil, "The source and alternate Main Skill must both provide the exact current gem level"
	end
	if quality < 0 or quality > 30 then return nil, "PoB source gem quality is outside the supported exact range" end
	local slot = build.itemsTab and build.itemsTab.slots and build.itemsTab.slots[params.slot]
	local itemSet = build.itemsTab and (build.itemsTab.activeItemSet or build.itemsTab.itemSets[build.itemsTab.activeItemSetId])
	local slotState = itemSet and itemSet[params.slot]
	if not slot or not slotState then return nil, "slot must identify an existing equipment slot in the active PoB item set" end
	local slotShownOk, slotShown = pcall(slot.shown or function() return not slot.inactive end)
	if not slotShownOk or not slotShown then
		return nil, "slot must be active and shown in PoB's currently selected weapon/item-set state"
	end
	if params.slot == group.slot or (params.slot:match("^Weapon") and tostring(group.slot):match("^Weapon")) then
		return nil, "The item factor cannot replace the selected skill's socket item or its paired weapon-set slot; use a separate equipment slot"
	end
	local sourceItemId = tonumber(slotState.selItemId) or 0
	if sourceItemId == params.itemId then return nil, "The requested item is already selected in this slot; no item factor would occur" end
	local alternateItem = params.itemId > 0 and build.itemsTab.items[params.itemId] or nil
	if params.itemId > 0 and not alternateItem then return nil, "itemId does not exist in the current PoB item list" end
	if alternateItem and not build.itemsTab:IsItemValidForSlot(alternateItem, params.slot, itemSet) then
		return nil, "PoB does not allow the selected item in the requested slot"
	end
	if params.itemId > 0 then
		for otherSlotName, otherSlot in pairs(build.itemsTab.slots or { }) do
			local otherState = itemSet[otherSlotName]
			if otherSlotName ~= params.slot and type(otherState) == "table"
				and tonumber(otherState.selItemId) == params.itemId then
				local otherShownOk, otherShown = pcall(otherSlot.shown or function() return not otherSlot.inactive end)
				if not otherShownOk then
					return nil, "PoB could not confirm whether the selected item is already equipped in another active slot"
				end
				if otherShown then
					return nil, "The selected PoB item instance is already equipped in another active slot"
				end
			end
		end
	end
	local sourceEffectId = tostring(sourceEffect.id)
	if not sourceEffect.levels[level] then return nil, "The selected source Main Skill has no exact level row in PoB data" end
	if not group.gemList[params.skillGemIndex] then return nil, "skillGemIndex does not exist in the selected group" end
	local replacementValid, replacementError = SkillCatalog.CanReplaceGemAtSlot(build, params.groupIndex, params.skillGemIndex, alternateSkillData)
	if not replacementValid then return nil, replacementError end
	local beforeItem, beforeError = getStudyItemState(build, sourceItemId)
	if not beforeItem then return nil, beforeError end
	local afterItem, afterError = getStudyItemState(build, params.itemId)
	if not afterItem then return nil, afterError end
	if beforeItem.poBItemText == afterItem.poBItemText then
		return nil, "The item factor must change the exact PoB item contents, not only its item-list ID"
	end
	if (beforeItem.poBItemText and #beforeItem.poBItemText > 8192) or (afterItem.poBItemText and #afterItem.poBItemText > 8192) then
		return nil, "The two item snapshots exceed the 8 KiB per-item reproducibility limit for a four-cell study"
	end
	local signatureOk, sourceSignature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or type(sourceSignature) ~= "string" then return nil, "Could not fingerprint the selected PoB build" end
	local sourceBuildSignature, buildSignatureError = StudyContext.BuildSignature(sourceSignature)
	if not sourceBuildSignature then return nil, buildSignatureError end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(getConfiguration(build))
	if not scenarioSignature then return nil, scenarioError end
	local engine, engineError = skillItemStudyEngine(build)
	if not engine then return nil, engineError end
	local selectedSocketedSupportGemIds = socketedSupportGemIds(build, group)
	bridge.factorialJobs = bridge.factorialJobs or { }
	local jobCount = 0
	for jobId, factorialJob in pairs(bridge.factorialJobs) do
		jobCount = jobCount + 1
		if jobCount >= maxFactorialJobs and factorialJob.status ~= "running" then bridge.factorialJobs[jobId] = nil; jobCount = jobCount - 1 end
	end
	if jobCount >= maxFactorialJobs then return nil, "The factorial study history is full; wait for a completed study to be pruned", "busy" end
	bridge.nextFactorialJob = (bridge.nextFactorialJob or 0) + 1
	local jobId = "pob-skill-item-slot-factorial-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextFactorialJob)
	local sourceParams = { }
	if params.studyId ~= nil then sourceParams.studyId = params.studyId end
	if params.comparisonId ~= nil then sourceParams.comparisonId = params.comparisonId end
	local job = {
		studyKind = "skill_item_slot", jobId = jobId, build = build, activeBuild = currentBuild(),
		sourceParams = sourceParams, studySource = studySource, sourceSignature = sourceSignature,
		sourceBuildSignature = sourceBuildSignature, scenarioSignature = scenarioSignature, engine = engine,
		groupIndex = params.groupIndex, skillGemIndex = params.skillGemIndex, supportGemIndex = params.skillGemIndex,
		socketedSupportGemIds = selectedSocketedSupportGemIds,
		sourceSkillGemId = sourceSkillId, sourceSkillEffectId = sourceEffectId,
		alternateSkillGemId = params.skillGemId, alternateSkillEffectId = params.skillEffectId,
		sourceSkillLevel = level, sourceSkillQuality = quality,
		slot = params.slot, sourceItemId = sourceItemId, alternateItemId = params.itemId,
		beforeItem = beforeItem, afterItem = afterItem,
		label = (params.label or ""):match("^%s*(.-)%s*$"), cells = { }, completedCells = 0,
		status = "running", progress = { phase = "Queued", currentCell = "baseline", completedCells = 0, totalCells = 4 },
		startedAt = os.time(), readOnly = true, activeBuildPreserved = true,
	}
	job.thread = coroutine.create(runSkillItemFactorialStudy)
	bridge.factorialJobs[jobId] = job
	return skillItemFactorialJobSummary(job)
end

skillItemFactorialJobSummary = function(job)
	return {
		jobId = job.jobId, status = job.status, progress = job.progress,
		completedCells = job.completedCells or 0, totalCells = 4,
		groupIndex = job.groupIndex, skillGemIndex = job.skillGemIndex,
		skillGemId = job.alternateSkillGemId, skillEffectId = job.alternateSkillEffectId,
		slot = job.slot, itemId = job.alternateItemId,
		isActiveBuild = job.build == currentBuild(), buildReference = experimentSource(job.studySource),
		readOnly = true, activeBuildPreserved = true, error = job.error,
		result = job.status == "completed" and job.result or nil,
	}
end

runSkillItemFactorialStudy = function(job)
	local cells = {
		{ name = "baseline", skill = false, item = false },
		{ name = "factorA", skill = true, item = false },
		{ name = "factorB", skill = false, item = true },
		{ name = "combined", skill = true, item = true },
	}
	for _, spec in ipairs(cells) do
		if job.cancelRequested then job.status = "cancelled" return end
		local cell, cellError = evaluateSkillItemSlotCell(job.build, job, spec.name, spec.skill, spec.item)
		if not cell then error("The " .. spec.name .. " skill/item cell failed exact PoB validation: " .. tostring(cellError)) end
		local sourceStillMatches, currentSourceSignature = pcall(Candidate.BuildSignature, job.build)
		if not sourceStillMatches or currentSourceSignature ~= job.sourceSignature then
			error("The selected PoB source build changed during the " .. spec.name .. " exact cell")
		end
		job.cells[spec.name] = cell
		job.completedCells = job.completedCells + 1
		job.progress = { phase = "Exact PoB calculation", currentCell = spec.name,
			completedCells = job.completedCells, totalCells = 4 }
		coroutine.yield(job.progress)
	end
	local unchanged, afterSignature = pcall(Candidate.BuildSignature, job.build)
	if not unchanged or afterSignature ~= job.sourceSignature then error("The selected PoB build changed during the read-only skill/item factorial study") end
	local interaction, interactionError = FactorialStudy.Compute(job.cells)
	if not interaction then error(interactionError) end
	local snapshot, snapshotError = getSnapshot(job.build)
	if not snapshot then error(snapshotError or "The PoB source snapshot is unavailable") end
	local snapshotScenarioSignature, snapshotScenarioError = StudyContext.ScenarioSignature(snapshot.configuration)
	if not snapshotScenarioSignature or snapshotScenarioSignature ~= job.scenarioSignature then
		error(snapshotScenarioError or "The selected PoB scenario changed during the exact skill/item study")
	end
	snapshot.exactMetrics = job.cells.baseline.metrics
	snapshot.availableItems = nil
	snapshot.availableItemsTruncated = nil
	snapshot.classOptions = nil
	snapshot.requirements = job.cells.baseline.requirements
	snapshot.mainSkillPayability = job.cells.baseline.mainSkillPayability
	snapshot.activitySustain = job.cells.baseline.activitySustain
	local requirementsFeasible, activityRatesFeasible = true, true
	for _, cellName in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
		local cell = job.cells[cellName]
		requirementsFeasible = requirementsFeasible and cell.requirements.feasible == true
			and cell.mainSkillPayability.feasible == true
		activityRatesFeasible = activityRatesFeasible and cell.activitySustain.status == "pass"
	end
	local function gemSummary(gemId)
		local gemData = job.build.data.gems[gemId]
		return { gemId = gemId, name = boundedText(gemData and gemData.name or gemId, 120),
			level = job.sourceSkillLevel, quality = job.sourceSkillQuality }
	end
	local source = experimentSource(job.studySource)
	source.buildSignatureAlgorithm = "sha256"
	source.buildSignatureVersion = 1
	source.buildSignature = job.sourceBuildSignature
	source.scenarioSignature = job.scenarioSignature
	local record = {
		kind = "skill_item_slot_factorial_interaction",
		label = job.label ~= "" and job.label or "Main Skill and item slot four-cell interaction study",
		source = source,
		engine = {
			pobVersion = job.engine.pobVersion,
			pobBranch = job.engine.pobBranch,
			dataVersion = job.engine.dataVersion,
			treeVersion = job.engine.treeVersion,
			manifestFingerprint = job.engine.manifestFingerprint,
			lookupTableStatus = "not_audited",
		},
		buildState = snapshot,
		experiment = {
			unit = "four_cell_skill_item_slot_factorial", factorialSchemaVersion = 1,
			formula = interaction.formula,
			factorA = {
				operation = "replace_selected_main_skill_gem", groupIndex = job.groupIndex, gemIndex = job.skillGemIndex,
				before = gemSummary(job.sourceSkillGemId), after = gemSummary(job.alternateSkillGemId),
				sourceEffectId = job.sourceSkillEffectId, effectId = job.alternateSkillEffectId,
				socketedSupportGemIds = job.socketedSupportGemIds,
			},
			factorB = { operation = "replace_item_in_slot", slot = job.slot,
				before = job.beforeItem, after = job.afterItem },
			changedVariables = { "selectedMainSkillGem", "itemSlot" },
			socketStatus = "native_linked_group",
		},
		baseline = {
			metrics = job.cells.baseline.metrics, requirements = job.cells.baseline.requirements,
			mainSkillPayability = job.cells.baseline.mainSkillPayability, activitySustain = job.cells.baseline.activitySustain,
			selectedSkill = job.cells.baseline.selectedSkill, selectedItem = job.cells.baseline.selectedItem,
			skillDPS = job.cells.baseline.dps,
		},
		candidate = {
			metrics = job.cells.combined.metrics, requirements = job.cells.combined.requirements,
			mainSkillPayability = job.cells.combined.mainSkillPayability, activitySustain = job.cells.combined.activitySustain,
			selectedSkill = job.cells.combined.selectedSkill, selectedItem = job.cells.combined.selectedItem,
			skillDPS = job.cells.combined.dps,
		},
		factorial = { formula = interaction.formula, cells = job.cells, interaction = interaction.metrics, metricCount = interaction.metricCount },
		metricDelta = metricDelta(job.cells.baseline.metrics, job.cells.combined.metrics),
		admission = {
			exactCalculated = true, useRequirementsFeasible = requirementsFeasible,
			activityStatus = job.cells.combined.activitySustain.status, activityRatesFeasible = activityRatesFeasible,
			activitySustainCertified = false, scenarioConditionsCertified = false,
			lookupTablesCertified = false, trainingEligible = false,
		},
	}
	local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
	if not stored then error(storeError or "PoB could not store the skill/item factorial study") end
	job.result = {
		status = "exact_skill_item_slot_factorial_recorded", readOnly = true, activeBuildPreserved = true,
		isActiveBuild = job.build == currentBuild(), buildReference = experimentSource(job.studySource),
		groupIndex = job.groupIndex, skillGemIndex = job.skillGemIndex, skillGemId = job.alternateSkillGemId,
		skillEffectId = job.alternateSkillEffectId, slot = job.slot, itemId = job.alternateItemId,
		socketStatus = "native_linked_group", formula = interaction.formula,
		cells = job.cells, interaction = interaction.metrics, interactionMetricCount = interaction.metricCount,
		recordId = stored.recordId, storeFile = stored.storeFile,
		recorded = stored.duplicate ~= true, duplicate = stored.duplicate == true, trainingEligible = false,
	}
	job.status = "completed"
	job.completedAt = os.time()
end

local function cancelSkillItemSlotFactorialStudy(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_skill_item_slot_factorial_cancel field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_skill_item_slot_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "skill_item_slot" then return nil, "Unknown skill/item factorial study job" end
	if job.status == "running" then job.cancelRequested = true; job.status = "cancelled"; job.completedAt = os.time(); job.thread = nil end
	return skillItemFactorialJobSummary(job)
end

local function getSkillItemSlotFactorialStudyStatus(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_skill_item_slot_factorial_status field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_skill_item_slot_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "skill_item_slot" then return nil, "Unknown skill/item factorial study job" end
	return skillItemFactorialJobSummary(job)
end

local passiveItemSlotFactorialJobSummary
local runPassiveItemSlotFactorialStudy

local function evaluatePassiveItemSlotFactorialCell(build, job, calcFunc, baselineOutput, baselineEnv, cellName, addNode, replaceItem)
	local spec = build.spec
	if addNode then
		local proxy, proxyError = buildFactorialPassiveSpec(build, { job.nodeId })
		if not proxy then return nil, "The " .. cellName .. " passive factor is no longer legal: " .. tostring(proxyError) end
		spec = proxy
	end
	local itemId = replaceItem and job.alternateItemId or job.sourceItemId
	local item = itemId > 0 and build.itemsTab.items[itemId] or nil
	if itemId > 0 and not item then return nil, "The selected item disappeared before the " .. cellName .. " exact calculation" end
	local output, env
	if cellName == "baseline" then
		output, env = baselineOutput, baselineEnv
	else
		local override = { spec = spec, returnEnv = true }
		if replaceItem then
			override.repSlotName = job.slot
			override.repItem = item
		end
		output, env = calcFunc(override)
	end
	if type(output) ~= "table" or type(env) ~= "table" then
		return nil, "PoB did not provide an exact output and fresh environment for the " .. cellName .. " passive/item cell"
	end
	local cell, cellError = exactFactorialCell(build, output, env, spec,
		job.cells.baseline and job.cells.baseline.extraPassivePoints)
	if not cell then return nil, cellError end
	local group = build.skillsTab.socketGroupList[job.groupIndex]
	local socketValid, socketDetails = SkillCatalog.ValidateSocketGroup(build, job.groupIndex)
	if not socketValid or not socketDetails or socketDetails.status ~= "linked" then
		return nil, "The " .. cellName .. " cell no longer has an exact linked Main Skill group: " .. tostring(socketDetails or "link proof unavailable")
	end
	local selectedSkill, skillError = selectedSkillIdentity(env, group, job.sourceSkillEffectId, job.groupIndex)
	if not selectedSkill then return nil, "The " .. cellName .. " cell did not preserve the exact Main Skill: " .. tostring(skillError) end
	if tostring(selectedSkill.gemId) ~= job.sourceSkillGemId or selectedSkill.gemIndex ~= job.sourceSkillGemIndex
		or tostring(selectedSkill.effectId) ~= job.sourceSkillEffectId then
		return nil, "The " .. cellName .. " cell changed the selected Main Skill identity"
	end
	selectedSkill.socketedSupportGemIds = socketedSupportGemIds(build, group)
	if not sameStringArray(selectedSkill.socketedSupportGemIds, job.socketedSupportGemIds) then
		return nil, "The " .. cellName .. " cell changed the socketed support context"
	end
	local evaluatedItem = env.player and env.player.itemList and env.player.itemList[job.slot]
	local evaluatedItemId = evaluatedItem and tonumber(evaluatedItem.id) or 0
	if evaluatedItemId ~= itemId then
		return nil, "The " .. cellName .. " cell did not calculate the requested PoB item in slot " .. tostring(job.slot)
	end
	cell.selectedSkill = selectedSkill
	cell.selectedItem = { slot = job.slot, itemId = evaluatedItemId }
	cell.nodeId = job.nodeId
	cell.nodeAllocated = not not spec.allocNodes[job.nodeId]
	cell.addedNodeIds = addNode and { unpack(spec.optimizerAddedNodeIds or { }) } or { }
	cell.socketStatus = "native_linked_group"
	cell.exactCalculated = true
	cell.evaluationMethod = "calcs_getMiscCalculator"
	cell.evidenceContext = {
		schemaVersion = 1,
		buildSignatureAlgorithm = "sha256",
		buildSignatureVersion = 1,
		buildSignature = job.sourceBuildSignature,
		scenarioSignature = job.scenarioSignature,
		engine = {
			pobVersion = job.engine.pobVersion, pobBranch = job.engine.pobBranch,
			dataVersion = job.engine.dataVersion, treeVersion = job.engine.treeVersion,
			manifestFingerprint = job.engine.manifestFingerprint,
		},
	}
	return cell
end

runPassiveItemSlotFactorialStudy = function(job)
	local calcFunc, baselineOutput, baselineEnv = Calcs.getMiscCalculator(job.build)
	if type(calcFunc) ~= "function" or type(baselineOutput) ~= "table" or type(baselineEnv) ~= "table" then
		error("PoB exact baseline calculation is unavailable for the passive/item study")
	end
	local cells = {
		{ name = "baseline", node = false, item = false },
		{ name = "factorA", node = true, item = false },
		{ name = "factorB", node = false, item = true },
		{ name = "combined", node = true, item = true },
	}
	for _, cellSpec in ipairs(cells) do
		if job.cancelRequested then job.status = "cancelled" return end
		local cell, cellError = evaluatePassiveItemSlotFactorialCell(job.build, job, calcFunc,
			baselineOutput, baselineEnv, cellSpec.name, cellSpec.node, cellSpec.item)
		if not cell then error("The " .. cellSpec.name .. " passive/item cell failed exact PoB validation: " .. tostring(cellError)) end
		local signatureOk, signature = pcall(Candidate.BuildSignature, job.build)
		if not signatureOk or signature ~= job.sourceSignature then
			error("The selected PoB source build changed during the " .. cellSpec.name .. " passive/item exact cell")
		end
		job.cells[cellSpec.name] = cell
		job.completedCells = job.completedCells + 1
		job.progress = { phase = "Exact PoB calculation", currentCell = cellSpec.name,
			completedCells = job.completedCells, totalCells = 4 }
		coroutine.yield(job.progress)
	end
	local unchanged, afterSignature = pcall(Candidate.BuildSignature, job.build)
	if not unchanged or afterSignature ~= job.sourceSignature then
		error("The source build changed during the read-only passive/item factorial study")
	end
	local interaction, interactionError = FactorialStudy.Compute(job.cells)
	if not interaction then error(interactionError) end
	local snapshot, snapshotError = getSnapshot(job.build)
	if not snapshot then error(snapshotError or "The PoB source snapshot is unavailable") end
	local snapshotScenarioSignature, snapshotScenarioError = StudyContext.ScenarioSignature(snapshot.configuration)
	if not snapshotScenarioSignature or snapshotScenarioSignature ~= job.scenarioSignature then
		error(snapshotScenarioError or "The selected PoB scenario changed during the passive/item study")
	end
	snapshot.exactMetrics = job.cells.baseline.metrics
	snapshot.availableItems = nil
	snapshot.availableItemsTruncated = nil
	snapshot.classOptions = nil
	snapshot.requirements = job.cells.baseline.requirements
	snapshot.mainSkillPayability = job.cells.baseline.mainSkillPayability
	snapshot.activitySustain = job.cells.baseline.activitySustain
	local requirementsFeasible, activityRatesFeasible = true, true
	for _, cellName in ipairs({ "baseline", "factorA", "factorB", "combined" }) do
		local cell = job.cells[cellName]
		requirementsFeasible = requirementsFeasible and cell.requirements.feasible == true
			and cell.mainSkillPayability.feasible == true
		activityRatesFeasible = activityRatesFeasible and cell.activitySustain.status == "pass"
	end
	local source = experimentSource(job.studySource)
	source.buildSignatureAlgorithm = "sha256"
	source.buildSignatureVersion = 1
	source.buildSignature = job.sourceBuildSignature
	source.scenarioSignature = job.scenarioSignature
	local record = {
		kind = "passive_item_slot_factorial_interaction",
		label = job.label ~= "" and job.label or "Passive node and item slot four-cell interaction study",
		source = source,
		engine = {
			pobVersion = job.engine.pobVersion, pobBranch = job.engine.pobBranch,
			dataVersion = job.engine.dataVersion, treeVersion = job.engine.treeVersion,
			manifestFingerprint = job.engine.manifestFingerprint,
			lookupTableStatus = "not_audited",
		},
		buildState = snapshot,
		experiment = {
			unit = "four_cell_passive_item_slot_factorial", factorialSchemaVersion = 1,
			formula = interaction.formula,
			factorA = { operation = "add_passive_node", nodeId = job.nodeId },
			factorB = { operation = "replace_item_in_slot", slot = job.slot,
				before = job.beforeItem, after = job.afterItem },
			changedVariables = { "passiveNode", "itemSlot" },
			socketStatus = "native_linked_group",
		},
		baseline = {
			metrics = job.cells.baseline.metrics, requirements = job.cells.baseline.requirements,
			mainSkillPayability = job.cells.baseline.mainSkillPayability, activitySustain = job.cells.baseline.activitySustain,
			selectedSkill = job.cells.baseline.selectedSkill, selectedItem = job.cells.baseline.selectedItem,
		},
		candidate = {
			metrics = job.cells.combined.metrics, requirements = job.cells.combined.requirements,
			mainSkillPayability = job.cells.combined.mainSkillPayability, activitySustain = job.cells.combined.activitySustain,
			selectedSkill = job.cells.combined.selectedSkill, selectedItem = job.cells.combined.selectedItem,
			passivePointsUsed = job.cells.combined.passivePointsUsed,
		},
		factorial = { formula = interaction.formula, cells = job.cells,
			interaction = interaction.metrics, metricCount = interaction.metricCount },
		metricDelta = metricDelta(job.cells.baseline.metrics, job.cells.combined.metrics),
		admission = {
			exactCalculated = true, useRequirementsFeasible = requirementsFeasible,
			activityStatus = job.cells.combined.activitySustain.status,
			activityRatesFeasible = activityRatesFeasible,
			activitySustainCertified = false, scenarioConditionsCertified = false,
			lookupTablesCertified = false, trainingEligible = false,
		},
		trainingEligible = false,
		quarantined = true,
		quarantine = { status = "pending_review", reasons = { "factorial_training_schema_unsupported" } },
	}
	local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
	if not stored then error(storeError or "PoB could not store the passive/item factorial study") end
	job.result = {
		status = "exact_passive_item_slot_factorial_recorded", readOnly = true,
		activeBuildPreserved = true, isActiveBuild = job.build == currentBuild(),
		buildReference = experimentSource(job.studySource),
		nodeId = job.nodeId, slot = job.slot, itemId = job.alternateItemId,
		socketStatus = "native_linked_group", formula = interaction.formula,
		cells = job.cells, interaction = interaction.metrics, interactionMetricCount = interaction.metricCount,
		recordId = stored.recordId, storeFile = stored.storeFile,
		recorded = stored.duplicate ~= true, duplicate = stored.duplicate == true,
		trainingEligible = false,
	}
	job.status = "completed"
	job.completedAt = os.time()
end

local function startPassiveItemSlotFactorialStudy(params)
	local allowed = { nodeId = true, slot = true, itemId = true, label = true, studyId = true, comparisonId = true }
	for key in pairs(params or { }) do
		if not allowed[key] then return nil, "Unsupported record_passive_item_slot_factorial_experiment field: " .. tostring(key) end
	end
	if not isFinite(params.nodeId) or params.nodeId < 1 or params.nodeId ~= math.floor(params.nodeId) or params.nodeId > 2147483647 then
		return nil, "nodeId must be a positive native PoB passive node ID"
	end
	if type(params.slot) ~= "string" or params.slot == "" or #params.slot > 64 or params.slot:find("[%c]") then
		return nil, "slot must be an exact equipment slot name from the active PoB item set"
	end
	if not isFinite(params.itemId) or params.itemId < 0 or params.itemId ~= math.floor(params.itemId) then
		return nil, "itemId must be a non-negative PoB item ID; use 0 for an empty slot"
	end
	if params.label ~= nil and (type(params.label) ~= "string" or #params.label > 120 or params.label:find("[%c]")) then
		return nil, "label must be plain text of at most 120 characters"
	end
	if params.studyId ~= nil and params.comparisonId ~= nil then return nil, "Provide either studyId or comparisonId, not both" end
	local build, studySource = resolveStudyBuild(params)
	if not build then return nil, studySource end
	if not build.spec then return nil, "The selected PoB build has no passive tree to study" end
	for _, qaJob in pairs(bridge.qaJobs or { }) do
		if qaJob.status == "running" then return nil, "A local PoB QA suite is running", "busy" end
	end
	for _, progressionJob in pairs(bridge.progressionJobs or { }) do
		if progressionJob.status == "running" then return nil, "A progression audit is already running", "busy" end
	end
	for _, factorialJob in pairs(bridge.factorialJobs or { }) do
		if factorialJob.status == "running" then return nil, "A factorial study is already running", "busy" end
	end
	local activeOptimizer = currentBuild() and currentBuild().optimizerTab
	if activeOptimizer and ((activeOptimizer.job and activeOptimizer.job.status == "running")
		or (activeOptimizer.classRootJob and activeOptimizer.classRootJob.status == "running")) then
		return nil, "An optimizer or class-root search is already running", "busy"
	end
	local _, nodeError = buildFactorialPassiveSpec(build, { params.nodeId })
	if nodeError then return nil, "The passive factor is not a legal direct one-node addition: " .. nodeError end
	local groupIndex = build.mainSocketGroup
	local group = groupIndex and build.skillsTab and build.skillsTab.socketGroupList[groupIndex]
	if not group or group.enabled == false or group.slotEnabled == false or group.source then
		return nil, "Select an enabled manual PoB Main Skill group"
	end
	local linked, linkDetails = SkillCatalog.ValidateSocketGroup(build, groupIndex)
	if not linked or not linkDetails or linkDetails.status ~= "linked" then
		return nil, "A passive/item interaction study requires a natively linked Main Skill: " .. tostring(linkDetails or "link proof unavailable")
	end
	local selectedEntry = group.displaySkillList and group.displaySkillList[group.mainActiveSkill or 1]
	local sourceEffect = selectedEntry and selectedEntry.activeEffect and selectedEntry.activeEffect.grantedEffect
	local sourceInstance = selectedEntry and selectedEntry.activeEffect and selectedEntry.activeEffect.srcInstance
	local sourceGemIndex
	for index, gem in ipairs(group.gemList or { }) do if gem == sourceInstance then sourceGemIndex = index break end end
	local sourceGemData = sourceInstance and (sourceInstance.gemData or (sourceInstance.gemId and build.data.gems[sourceInstance.gemId]))
	if not sourceEffect or not sourceEffect.id or not sourceGemIndex or not SkillCatalog.IsActiveSkillGem(sourceGemData) then
		return nil, "PoB did not expose an exact selected active Main Skill gem/effect for the interaction study"
	end
	local slot = build.itemsTab and build.itemsTab.slots and build.itemsTab.slots[params.slot]
	local itemSet = build.itemsTab and (build.itemsTab.activeItemSet or build.itemsTab.itemSets[build.itemsTab.activeItemSetId])
	local slotState = itemSet and itemSet[params.slot]
	if not slot or not slotState then return nil, "slot must identify an existing equipment slot in the active PoB item set" end
	local shownOk, shown = pcall(slot.shown or function() return not slot.inactive end)
	if not shownOk or not shown then return nil, "slot must be active and shown in PoB's currently selected weapon/item-set state" end
	if params.slot == group.slot or (params.slot:match("^Weapon") and tostring(group.slot):match("^Weapon")) then
		return nil, "The item factor cannot replace the selected Main Skill socket item or paired weapon-set slot"
	end
	local sourceItemId = tonumber(slotState.selItemId) or 0
	if sourceItemId == params.itemId then return nil, "The requested item is already selected in this slot; no item factor would occur" end
	local alternateItem = params.itemId > 0 and build.itemsTab.items[params.itemId] or nil
	if params.itemId > 0 and not alternateItem then return nil, "itemId does not exist in the current PoB item list" end
	if alternateItem and not build.itemsTab:IsItemValidForSlot(alternateItem, params.slot, itemSet) then
		return nil, "PoB does not allow the selected item in the requested slot"
	end
	if params.itemId > 0 then
		for otherSlotName, otherSlot in pairs(build.itemsTab.slots or { }) do
			local otherState = itemSet[otherSlotName]
			if otherSlotName ~= params.slot and type(otherState) == "table" and tonumber(otherState.selItemId) == params.itemId then
				local otherShownOk, otherShown = pcall(otherSlot.shown or function() return not otherSlot.inactive end)
				if not otherShownOk then return nil, "PoB could not confirm whether the selected item is already equipped elsewhere" end
				if otherShown then return nil, "The selected PoB item instance is already equipped in another active slot" end
			end
		end
	end
	local beforeItem, beforeError = getStudyItemState(build, sourceItemId)
	if not beforeItem then return nil, beforeError end
	local afterItem, afterError = getStudyItemState(build, params.itemId)
	if not afterItem then return nil, afterError end
	if beforeItem.poBItemText == afterItem.poBItemText then return nil, "The item factor must change the exact PoB item contents, not only its item-list ID" end
	if (beforeItem.poBItemText and #beforeItem.poBItemText > 8192) or (afterItem.poBItemText and #afterItem.poBItemText > 8192) then
		return nil, "The item snapshots exceed the 8 KiB per-item reproducibility limit for a four-cell study"
	end
	local signatureOk, sourceSignature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or type(sourceSignature) ~= "string" then return nil, "Could not fingerprint the selected PoB build" end
	local sourceBuildSignature, buildSignatureError = StudyContext.BuildSignature(sourceSignature)
	if not sourceBuildSignature then return nil, buildSignatureError end
	local scenarioSignature, scenarioError = StudyContext.ScenarioSignature(getConfiguration(build))
	if not scenarioSignature then return nil, scenarioError end
	local engine, engineError = skillItemStudyEngine(build)
	if not engine then return nil, engineError end
	bridge.factorialJobs = bridge.factorialJobs or { }
	local jobCount = 0
	for jobId, factorialJob in pairs(bridge.factorialJobs) do
		jobCount = jobCount + 1
		if jobCount >= maxFactorialJobs and factorialJob.status ~= "running" then bridge.factorialJobs[jobId] = nil; jobCount = jobCount - 1 end
	end
	if jobCount >= maxFactorialJobs then return nil, "The factorial study history is full; wait for a completed study to be pruned", "busy" end
	bridge.nextFactorialJob = (bridge.nextFactorialJob or 0) + 1
	local jobId = "pob-passive-item-factorial-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextFactorialJob)
	local sourceParams = { }
	if params.studyId ~= nil then sourceParams.studyId = params.studyId end
	if params.comparisonId ~= nil then sourceParams.comparisonId = params.comparisonId end
	local job = {
		studyKind = "passive_item_slot", jobId = jobId, build = build, activeBuild = currentBuild(),
		sourceParams = sourceParams, studySource = studySource, sourceSignature = sourceSignature,
		sourceBuildSignature = sourceBuildSignature, scenarioSignature = scenarioSignature, engine = engine,
		nodeId = params.nodeId, groupIndex = groupIndex, sourceSkillGemId = tostring(sourceGemData.id or sourceInstance.gemId or ""),
		sourceSkillGemIndex = sourceGemIndex, sourceSkillEffectId = tostring(sourceEffect.id),
		socketedSupportGemIds = socketedSupportGemIds(build, group), slot = params.slot,
		sourceItemId = sourceItemId, alternateItemId = params.itemId, beforeItem = beforeItem, afterItem = afterItem,
		label = (params.label or ""):match("^%s*(.-)%s*$"), cells = { }, completedCells = 0,
		status = "running", progress = { phase = "Queued", currentCell = "baseline", completedCells = 0, totalCells = 4 },
		startedAt = os.time(), readOnly = true, activeBuildPreserved = true,
	}
	job.thread = coroutine.create(runPassiveItemSlotFactorialStudy)
	bridge.factorialJobs[jobId] = job
	return passiveItemSlotFactorialJobSummary(job)
end

passiveItemSlotFactorialJobSummary = function(job)
	return {
		jobId = job.jobId, status = job.status, progress = job.progress,
		completedCells = job.completedCells or 0, totalCells = 4,
		nodeId = job.nodeId, slot = job.slot, itemId = job.alternateItemId,
		isActiveBuild = job.build == currentBuild(), buildReference = experimentSource(job.studySource),
		readOnly = true, activeBuildPreserved = true, error = job.error,
		result = job.status == "completed" and job.result or nil,
	}
end

local function cancelPassiveItemSlotFactorialStudy(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_passive_item_slot_factorial_cancel field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_passive_item_slot_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "passive_item_slot" then return nil, "Unknown passive/item factorial study job" end
	if job.status == "running" then job.cancelRequested = true; job.status = "cancelled"; job.completedAt = os.time(); job.thread = nil end
	return passiveItemSlotFactorialJobSummary(job)
end

local function getPassiveItemSlotFactorialStudyStatus(params)
	for key in pairs(params or { }) do if key ~= "jobId" then return nil, "Unsupported record_passive_item_slot_factorial_status field: " .. tostring(key) end end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then return nil, "jobId must be returned by record_passive_item_slot_factorial_experiment" end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind ~= "passive_item_slot" then return nil, "Unknown passive/item factorial study job" end
	return passiveItemSlotFactorialJobSummary(job)
end

local function evaluateGemSwap(params, recordExperiment)
	local build, studySource = resolveParamsBuild(params, "evaluate a gem change")
	if not build then return nil, studySource end
	local groupIndex, gemIndex = tonumber(params.groupIndex), tonumber(params.gemIndex)
	if not isFinite(groupIndex) or groupIndex ~= math.floor(groupIndex) or groupIndex < 1
		or not isFinite(gemIndex) or gemIndex ~= math.floor(gemIndex) or gemIndex < 1 then
		return nil, "groupIndex and gemIndex must be positive integers from the PoB skill snapshot"
	end
	local sourceGroup = build.skillsTab.socketGroupList[groupIndex]
	local sourceGem = sourceGroup and sourceGroup.gemList and sourceGroup.gemList[gemIndex]
	if not sourceGem then return nil, "The requested gem slot does not exist in the PoB skill set" end
	local sourceGemId = sourceGem.gemId or (sourceGem.gemData and sourceGem.gemData.id)
	local sourceLevel = tonumber(sourceGem.level) or 1
	local sourceQuality = tonumber(sourceGem.quality) or 0
	local requestedGemId = params.gemId
	local level, quality = tonumber(params.level), tonumber(params.quality)
	if recordExperiment then
		requestedGemId = requestedGemId or sourceGemId
		level = level or sourceLevel
		quality = quality or sourceQuality
	else
		if type(requestedGemId) ~= "string" then return nil, "gemId must be a supported gem ID from this PoB data version" end
	end
	if not isFinite(level) or level ~= math.floor(level) or level < 1 or level > 40 then return nil, "level must be an integer from 1 to 40" end
	if not isFinite(quality) or quality ~= math.floor(quality) or quality < 0 or quality > 23 then return nil, "quality must be an integer from 0 to 23" end
	if type(requestedGemId) ~= "string" or #requestedGemId < 1 or #requestedGemId > 100 then return nil, "gemId must be a supported gem ID from this PoB data version" end
	local gemData = build.data.gems[requestedGemId]
	if not gemData or not gemData.grantedEffect or gemData.grantedEffect.unsupported then return nil, "gemId is not a supported gem in this PoB data version" end
	if not gemData.grantedEffect.levels or not gemData.grantedEffect.levels[level] then return nil, "Requested gem level is unavailable for this PoB gem" end
	local sourceGemData = sourceGem.gemData or (sourceGemId and build.data.gems[sourceGemId])
	local sourceEffect = sourceGem.grantedEffect or (sourceGemData and sourceGemData.grantedEffect)
	if not sourceEffect or sourceEffect.unsupported then
		return nil, "The selected PoB gem slot has no supported native granted effect"
	end
	local sourceIsSupport = sourceEffect.support == true
	local slotCompatible, slotDetails
	if sourceIsSupport then
		slotCompatible, slotDetails = SkillCatalog.CanReplaceSupportAtSlot(build, groupIndex, gemIndex, gemData)
	else
		slotCompatible, slotDetails = SkillCatalog.CanReplaceGemAtSlot(build, groupIndex, gemIndex, gemData, {
			allowUnlinkedPlanning = true,
		})
	end
	if not slotCompatible then return nil, slotDetails end
	local socketStatus = type(slotDetails) == "table"
		and (slotDetails.status or (slotDetails.linked == false and "unlinked" or "linked")) or "linked"
	local changedParameters = { }
	if requestedGemId ~= sourceGemId then changedParameters[#changedParameters + 1] = "gemId" end
	if level ~= sourceLevel then changedParameters[#changedParameters + 1] = "level" end
	if quality ~= sourceQuality then changedParameters[#changedParameters + 1] = "quality" end
	if recordExperiment and #changedParameters ~= 1 then
		return nil, "A recorded gem experiment must change exactly one of gemId, level, or quality"
	end
	local label = params.label
	if recordExperiment then
		if label ~= nil and (type(label) ~= "string" or #label > 120 or label:find("[%c]")) then
			return nil, "label must be plain text of at most 120 characters"
		end
		label = label and label:match("^%s*(.-)%s*$") or ""
	end
	local sourceSignature = Candidate.BuildSignature(build)
	local mainSkillGemIndex, mainSkillEffectId
	if tonumber(build.mainSocketGroup) == groupIndex then
		local mainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
		local selectedSkill = mainGroup and mainGroup.displaySkillList
			and mainGroup.displaySkillList[mainGroup.mainActiveSkill or 1]
		local selectedEffect = skillEffect(selectedSkill)
		local selectedInstance = selectedEffect and selectedEffect.srcInstance
		mainSkillEffectId = selectedEffect and selectedEffect.grantedEffect
			and selectedEffect.grantedEffect.id
		for index, instance in ipairs(mainGroup and mainGroup.gemList or { }) do
			if instance == selectedInstance then mainSkillGemIndex = index break end
		end
		if not selectedEffect or not mainSkillEffectId or not mainSkillGemIndex then
			return nil, "PoB could not map the selected Main Skill effect to a socketed gem; refusing an ambiguous gem comparison"
		end
		if mainSkillGemIndex == gemIndex and requestedGemId ~= sourceGemId and not sourceIsSupport then
			mainSkillEffectId = gemData.grantedEffectId
		end
	end
	local skillTab = { }
	for key, value in pairs(build.skillsTab) do skillTab[key] = value end
	setmetatable(skillTab, getmetatable(build.skillsTab))
	local groups = { }
	for currentGroupIndex, group in ipairs(build.skillsTab.socketGroupList) do
		local groupCopy = { }
		for key, value in pairs(group) do groupCopy[key] = value end
		groupCopy.gemList = { }
		for currentGemIndex, gem in ipairs(group.gemList or { }) do
			local gemCopy = { }
			for key, value in pairs(gem) do gemCopy[key] = value end
			if currentGroupIndex == groupIndex and currentGemIndex == gemIndex then
				gemCopy.gemId = gemData.id
				gemCopy.skillId = gemData.grantedEffectId
				gemCopy.nameSpec = gemData.name
				gemCopy.gemData = gemData
				gemCopy.grantedEffect = gemData.grantedEffect
				gemCopy.level = level
				gemCopy.quality = quality
			end
			groupCopy.gemList[currentGemIndex] = gemCopy
		end
		if currentGroupIndex == tonumber(build.mainSocketGroup) and mainSkillGemIndex then
			local resolvedMainSkill = SkillCatalog.ResolveMainSkillIndex(groupCopy,
				mainSkillGemIndex, mainSkillEffectId)
			if not resolvedMainSkill and mainSkillGemIndex == gemIndex and not sourceIsSupport then
				resolvedMainSkill = SkillCatalog.ResolveMainSkillIndex(groupCopy, mainSkillGemIndex)
			end
			if not resolvedMainSkill then
				return nil, "PoB could not resolve the selected Main Skill effect after the candidate gem change"
			end
			groupCopy.mainActiveSkill = resolvedMainSkill
		end
		groups[currentGroupIndex] = groupCopy
	end
	skillTab.socketGroupList = groups
	local buildProxy = { }
	for key, value in pairs(build) do buildProxy[key] = value end
	buildProxy.skillsTab = skillTab
	setmetatable(buildProxy, { __index = build })
	skillTab.build = buildProxy
	for _, group in ipairs(groups) do skillTab:ProcessSocketGroup(group) end
	local _, baselineOutput = Calcs.getMiscCalculator(build)
	local candidateCalc, _, candidateEnv = Calcs.getMiscCalculator(buildProxy)
	local candidateOutput = candidateCalc()
	local candidateMainSkill = candidateEnv and candidateEnv.player and candidateEnv.player.mainSkill
	if mainSkillGemIndex then
		local selectedEffect = skillEffect(candidateMainSkill)
		local expectedGem = groups[build.mainSocketGroup]
			and groups[build.mainSocketGroup].gemList[mainSkillGemIndex]
		if not selectedEffect or selectedEffect.srcInstance ~= expectedGem then
			return nil, "PoB exact calculation selected a different Main Skill gem than the requested candidate"
		end
		if mainSkillEffectId and selectedEffect.grantedEffect
			and selectedEffect.grantedEffect.id ~= mainSkillEffectId then
			return nil, "PoB exact calculation selected a different Main Skill effect than the requested candidate"
		end
	end
	local signatureOk, afterSignature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or afterSignature ~= sourceSignature then
		return nil, "The source build changed during the isolated gem comparison"
	end
	local baselineMetrics = exactMetrics(baselineOutput)
	local candidateMetrics = exactMetrics(candidateOutput)
	local baselineRequirements = Validator.CheckRequirements(baselineOutput, build.characterLevel)
	local candidateRequirements = Validator.CheckRequirements(candidateOutput, buildProxy.characterLevel)
	local baselineMainGroup = build.skillsTab.socketGroupList[build.mainSocketGroup]
	local baselineMainSkill = baselineMainGroup and baselineMainGroup.displaySkillList
		and baselineMainGroup.displaySkillList[baselineMainGroup.mainActiveSkill or 1]
	local result = {
		readOnly = true,
		activeBuildPreserved = true,
		isActiveBuild = build == currentBuild(),
		buildReference = experimentSource(studySource),
		groupIndex = groupIndex,
		gemIndex = gemIndex,
		socketStatus = socketStatus,
		previousGemId = sourceGemId,
		gemId = gemData.id,
		gemName = boundedText(gemData.name, 120),
		baselineRequirements = baselineRequirements,
		candidateRequirements = candidateRequirements,
		selectedSkill = candidateMainSkill and {
			name = boundedText(skillName(candidateMainSkill) or "", 120),
			gemId = boundedText(candidateMainSkill.activeEffect and candidateMainSkill.activeEffect.srcInstance
				and (candidateMainSkill.activeEffect.srcInstance.gemId
					or candidateMainSkill.activeEffect.srcInstance.gemData
					and candidateMainSkill.activeEffect.srcInstance.gemData.id) or "", 120),
			effectId = boundedText(candidateMainSkill.activeEffect
				and candidateMainSkill.activeEffect.grantedEffect
				and candidateMainSkill.activeEffect.grantedEffect.id or "", 120),
		},
		level = level,
		quality = quality,
		baselineMetrics = baselineMetrics,
		candidateMetrics = candidateMetrics,
		metricDelta = metricDelta(baselineMetrics, candidateMetrics),
	}
	if recordExperiment then
		local snapshot, snapshotError = getSnapshot(build)
		if not snapshot then return nil, snapshotError end
		snapshot.exactMetrics = baselineMetrics
		snapshot.availableItems = nil
		snapshot.availableItemsTruncated = nil
		snapshot.classOptions = nil
		snapshot.requirements = baselineRequirements
		local baselinePayability = Validator.CheckMainSkillPayability(baselineOutput, skillName(baselineMainSkill))
		local candidatePayability = Validator.CheckMainSkillPayability(candidateOutput, skillName(candidateMainSkill))
		local baselineActivity = activityForOutput(baselineOutput)
		local candidateActivity = activityForOutput(candidateOutput)
		snapshot.mainSkillPayability = baselinePayability
		snapshot.activitySustain = baselineActivity
		local oldGem = {
			gemId = sourceGemId,
			level = sourceLevel,
			quality = sourceQuality,
		}
		local newGem = {
			gemId = gemData.id,
			name = boundedText(gemData.name, 120),
			level = level,
			quality = quality,
			gameId = boundedText(gemData.gameId or "", 100),
			skillId = boundedText(gemData.grantedEffectId or "", 100),
		}
		local record = {
			kind = "gem_variant_pair",
			label = label ~= "" and label or "One-parameter gem comparison",
			source = experimentSource(studySource),
			engine = {
				pobVersion = launch and launch.versionNumber or nil,
				pobBranch = Version.Branch(),
				dataVersion = Version.Data(build),
				treeVersion = build.spec.treeVersion,
				manifestFingerprint = launch and launch.manifestFingerprint or nil,
				lookupTableStatus = "not_audited",
			},
			buildState = snapshot,
			experiment = {
				unit = "one_gem_parameter",
				changedParameter = changedParameters[1],
				groupIndex = groupIndex,
				gemIndex = gemIndex,
				socketStatus = socketStatus,
				before = oldGem,
				after = newGem,
			},
			baseline = {
				metrics = baselineMetrics,
				requirements = baselineRequirements,
				mainSkillPayability = baselinePayability,
				activitySustain = baselineActivity,
				gem = oldGem,
			},
			candidate = {
				metrics = candidateMetrics,
				requirements = candidateRequirements,
				mainSkillPayability = candidatePayability,
				activitySustain = candidateActivity,
				gem = newGem,
			},
			metricDelta = result.metricDelta,
			admission = {
				exactCalculated = true,
				useRequirementsFeasible = baselineRequirements.feasible and candidateRequirements.feasible
					and baselinePayability.feasible and candidatePayability.feasible,
				activityStatus = candidateActivity.status,
				activityRatesFeasible = candidateActivity.status == "pass",
				activitySustainCertified = false,
				scenarioConditionsCertified = false,
				lookupTablesCertified = false,
				trainingEligible = false,
			},
		}
		local stored, storeError = StudyRecords.Append(record, main and main.userPath, MakeDir)
		if not stored then return nil, storeError end
		result.recordId = stored.recordId
		result.storeFile = stored.storeFile
		result.recorded = stored.duplicate ~= true
		result.duplicate = stored.duplicate == true
	end
	return result
end

local function applyGemVariant(params)
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before applying a gem change" end
	local groupIndex, gemIndex = tonumber(params.groupIndex), tonumber(params.gemIndex)
	local group = groupIndex and build.skillsTab.socketGroupList[groupIndex]
	local gem = group and group.gemList and group.gemList[gemIndex]
	if not gem then return nil, "groupIndex and gemIndex must identify an existing gem in the active PoB skill set" end
	local gemId = params.gemId or gem.gemId
	if type(gemId) ~= "string" or #gemId == 0 then return nil, "A supported gemId is required for this socket" end
	local probe = {
		groupIndex = groupIndex,
		gemIndex = gemIndex,
		gemId = gemId,
		level = params.level,
		quality = params.quality,
	}
	local evaluation, evalError = evaluateGemSwap(probe)
	if not evaluation then return nil, evalError end
	local gemData = build.data.gems[gemId]
	local candidate = {
		feasible = true,
		sourceSignature = Candidate.BuildSignature(build),
		gemVariant = {
			groupIndex = groupIndex,
			gemIndex = gemIndex,
			gemId = gemData.id,
			skillId = gemData.grantedEffectId,
			nameSpec = gemData.name,
			level = tonumber(params.level),
			quality = tonumber(params.quality),
		},
		evaluation = { metrics = evaluation.candidateMetrics },
	}
	local applied, applyError = Candidate.Apply(build, candidate)
	if not applied then return nil, applyError end
	return {
		applied = true,
		newVariation = true,
		groupIndex = groupIndex,
		gemIndex = gemIndex,
		gemId = gemData.id,
		level = candidate.gemVariant.level,
		quality = candidate.gemVariant.quality,
		metrics = candidate.evaluation.metrics,
		requirements = evaluation.candidateRequirements,
		baselineMetrics = evaluation.baselineMetrics,
		metricDelta = evaluation.metricDelta,
		message = "Applied as a new PoB skill-set variation after exact calculation.",
	}
end

local function setBuildLevel(params)
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before changing its level" end
	local level = tonumber(params.level)
	if not isFinite(level) or level ~= math.floor(level) or level < 1 or level > 100 then return nil, "level must be an integer between 1 and 100" end
	local previous = build.characterLevel
	build.characterLevel = level
	build.characterLevelAutoMode = false
	if build.controls.characterLevel then build.controls.characterLevel:SetText(level) end
	if build.controls.levelScalingButton then build.controls.levelScalingButton.label = "Manual" end
	build.configTab:BuildModList()
	build.modFlag = true
	build.buildFlag = true
	return { previousLevel = previous, level = level, recalculationPending = true }
end

local function selectMainSkill(params)
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before selecting a Main Skill" end
	local groupIndex, skillIndex = tonumber(params.groupIndex), tonumber(params.skillIndex)
	if not groupIndex or groupIndex ~= math.floor(groupIndex) or not skillIndex or skillIndex ~= math.floor(skillIndex) then
		return nil, "groupIndex and skillIndex must be integers from pob.list_active_skills"
	end
	local group = build.skillsTab.socketGroupList[groupIndex]
	local skill = group and group.displaySkillList and group.displaySkillList[skillIndex]
	if not group or group.enabled == false or group.slotEnabled == false or not skill or not skill.activeEffect then
		return nil, "The requested skill is not an enabled active skill in the current build"
	end
	local previous = { groupIndex = build.mainSocketGroup, skillIndex = (build.skillsTab.socketGroupList[build.mainSocketGroup] or { }).mainActiveSkill }
	group.mainActiveSkill = skillIndex
	build.mainSocketGroup = groupIndex
	build:RefreshSkillSelectControls(build.controls, groupIndex, "")
	build.skillsTab:AddUndoState()
	build.modFlag = true
	build.buildFlag = true
	return { selected = { groupIndex = groupIndex, skillIndex = skillIndex, name = skillName(skill) }, previous = previous, recalculationPending = true }
end

local function createOptimizerSkillSeed(params)
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before creating an optimizer skill seed" end
	local gemId = params.gemId
	if type(gemId) ~= "string" or #gemId < 1 or #gemId > 100 or gemId:find("[%c]") then
		return nil, "gemId must be an internal active-skill ID from pob.list_optimizer_skill_gems"
	end
	local optimizerTab = build.optimizerTab
	local baseClassId = tonumber(params.baseClassId)
	if params.baseClassId ~= nil then
		if not baseClassId or baseClassId ~= math.floor(baseClassId) or not (build.spec.tree.classes or { })[baseClassId] then
			return nil, "baseClassId must identify a native PoB class in the active tree"
		end
	end
	local result, seedError = SkillSeed.Create(build, gemId, baseClassId)
	if not result then return nil, seedError end
	if optimizerTab and optimizerTab.textValues then
		if baseClassId ~= nil then
			optimizerTab.textValues.baseClassId = tostring(baseClassId)
			optimizerTab.textValues.searchAllClasses = false
		end
		optimizerTab.textValues.generationPhase = "tree"
		optimizerTab.textValues.targetSkillGroupIndex = tostring(result.groupIndex)
		optimizerTab.textValues.targetSkillIndex = tostring(result.skillIndex)
		optimizerTab.textValues.targetSkillGemId = result.gemId
		optimizerTab.result = nil
		optimizerTab.modFlag = true
		optimizerTab.statusMessage = result.message .. " Select the Tree phase and run the exact optimizer."
	end
	result.baseClassId = baseClassId or (optimizerTab and optimizerTab.textValues and tonumber(optimizerTab.textValues.baseClassId))
	return result
end

local function setConfigOptions(params)
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before changing configuration" end
	if type(params.values) ~= "table" or #params.values > 0 then return nil, "values must be a map of existing PoB configuration option names to values" end
	local configTab = build.configTab
	local configSet = configTab.configSets[configTab.activeConfigSetId]
	local previous, accepted = { }, { }
	local count = 0
	for key, value in pairs(params.values) do
		count = count + 1
		if count > 24 then return nil, "At most 24 configuration options can be changed at once" end
		local control = configTab.varControls[key]
		local oldValue = configSet.input[key]
		if oldValue == nil and control then
			-- Unchecked native checkboxes commonly have no stored input entry.
			-- Resolve their effective prior value with the same default/placeholder
			-- rules used by ConfigTab, so MCP edits preserve accurate undo metadata.
			oldValue = configTab:GetDefaultState(key)
		end
		if not control or oldValue == nil then return nil, "Unknown or unset PoB configuration option: " .. tostring(key) end
		local oldType, newType = type(oldValue), type(value)
		if oldType ~= newType then return nil, "Configuration value type does not match PoB option " .. tostring(key) end
		if newType == "number" then
			if not isFinite(value) or math.abs(value) > 1000000 then return nil, "Numeric configuration value is out of range for " .. tostring(key) end
		elseif newType == "string" then
			if #value > 160 or value:find("[%z\1-\8\11\12\14-\31]") then return nil, "Text configuration value is too long or contains control characters" end
		elseif newType ~= "boolean" then
			return nil, "Only primitive PoB configuration values can be changed"
		end
		if control.list then
			local allowed = false
			for _, entry in ipairs(control.list) do if entry.val == value then allowed = true break end end
			if not allowed then return nil, "Value is not one of the available PoB choices for " .. tostring(key) end
		end
		previous[key] = oldValue
		accepted[key] = value
	end
	if count == 0 then return nil, "Provide at least one PoB configuration option" end
	for key, value in pairs(accepted) do configSet.input[key] = value end
	configTab:AddUndoState()
	configTab:UpdateControls()
	configTab:BuildModList()
	configTab.modFlag = true
	build.buildFlag = true
	return { changed = accepted, previous = previous, recalculationPending = true }
end

local function equipExistingItem(params)
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before changing equipment" end
	local itemSet = build.itemsTab.itemSets[build.itemsTab.activeItemSetId]
	local slotName, itemId = params.slot, tonumber(params.itemId)
	if type(slotName) ~= "string" or #slotName > 64 or not itemSet or not itemSet[slotName] then return nil, "slot must be an existing slot in the active PoB item set" end
	if not itemId or itemId ~= math.floor(itemId) or itemId < 0 then return nil, "itemId must be a non-negative integer; use 0 to clear the slot" end
	local item = itemId > 0 and build.itemsTab.items[itemId]
	if itemId > 0 and not item then return nil, "itemId does not exist in the current PoB item list" end
	if item and not build.itemsTab:IsItemValidForSlot(item, slotName, itemSet) then return nil, "PoB does not allow this item in the requested slot" end
	local previous = itemSet[slotName].selItemId or 0
	if previous == itemId then return { slot = slotName, itemId = itemId, changed = false } end
	local slot = build.itemsTab.slots[slotName]
	if not slot then return nil, "The requested item slot is not available in the active set" end
	slot:SetSelItemId(itemId)
	build.itemsTab:PopulateSlots()
	build.itemsTab:AddUndoState()
	build.itemsTab.modFlag = true
	build.buildFlag = true
	return { slot = slotName, previousItemId = previous, itemId = itemId, itemName = item and boundedText(item.name, 120) or nil, recalculationPending = true }
end

local function selectClassAscendancy(params)
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before changing class or ascendancy" end
	local spec, tree = build.spec, build.spec.tree
	local className = params.className or spec.curClassName
	local classId = tree.classNameMap[className]
	if not classId then return nil, "Unknown PoB base class: " .. tostring(className) end
	if classId ~= spec.curClassId and spec:CountAllocNodes() > 0 and not spec:IsClassConnected(classId) then
		return nil, "This class is not connected to the current passive tree. The PoB UI requires a tree path or reset before switching classes."
	end
	local class = tree.classes[classId]
	local ascendancyId
	local ascendancyName = params.ascendancyName or "None"
	for id, ascendancy in pairs(class.classes or { }) do
		if ascendancy.name == ascendancyName then ascendancyId = id break end
	end
	if ascendancyId == nil then return nil, "Ascendancy is not available to " .. tostring(className) end
	local previous = { class = spec.curClassName, ascendancy = spec.curAscendClassName, secondaryAscendancy = spec.curSecondaryAscendClassName or "None" }
	if classId ~= spec.curClassId then
		spec:SelectClass(classId)
		if tree.alternate_ascendancies then spec:SelectSecondaryAscendClass(0) end
	end
	if ascendancyId ~= spec.curAscendClassId then spec:SelectAscendClass(ascendancyId) end
	local secondaryName = params.secondaryAscendancyName
	if secondaryName ~= nil then
		local secondaryId
		if secondaryName == "None" or secondaryName == "" then
			secondaryId = 0
		else
			for id, entry in pairs(tree.secondaryAscendNameMap or { }) do
				local ascendClass = entry.ascendClass
				if ascendClass and (ascendClass.name == secondaryName or ascendClass.id == secondaryName) then
					secondaryId = entry.ascendClassId
					break
				end
			end
		end
		if secondaryId == nil then return nil, "Secondary ascendancy is not available in this PoB tree version: " .. tostring(secondaryName) end
		if secondaryId ~= (spec.curSecondaryAscendClassId or 0) then spec:SelectSecondaryAscendClass(secondaryId) end
	end
	spec:AddUndoState()
	spec:SetWindowTitleWithBuildClass()
	build:UpdateClassDropdowns()
	build.buildFlag = true
	return { class = spec.curClassName, ascendancy = spec.curAscendClassName, secondaryAscendancy = spec.curSecondaryAscendClassName or "None", previous = previous, recalculationPending = true }
end

local function candidateSummary(candidate, index, baselineMetrics)
	local evaluation = candidate and candidate.evaluation or { }
	local metrics, violations = { }, { }
	for key, value in pairs(evaluation.metrics or { }) do
		if isFinite(value) then metrics[key] = value end
	end
	for _, violation in ipairs(evaluation.violations or { }) do
		local safe = { key = violation.key, label = violation.label, reason = violation.reason }
		if isFinite(violation.actual) then safe.actual = violation.actual end
		if isFinite(violation.required) then safe.required = violation.required end
		if isFinite(violation.deficit) then safe.deficit = violation.deficit end
		if type(violation.missingItems) == "table" then safe.missingItems = violation.missingItems end
		violations[#violations + 1] = safe
	end
	local sourceBudget = evaluation.marketBudget
	local sourceBinding = candidate and candidate.gearVariant and candidate.gearVariant.socketBinding
	local socketBinding = sourceBinding and {
		groupIndex = sourceBinding.groupIndex,
		slotName = boundedText(sourceBinding.slotName or "", 40),
		itemId = sourceBinding.itemId,
		socketCount = sourceBinding.socketCount,
		linkGroup = sourceBinding.linkGroup,
	} or nil
	local sourceSkillSocket = evaluation.skillSocket
	local skillSocket = type(sourceSkillSocket) == "table" and {
		status = boundedText(sourceSkillSocket.status or "", 32),
		groupIndex = sourceSkillSocket.groupIndex,
		slot = boundedText(sourceSkillSocket.slot or "", 40),
		itemId = sourceSkillSocket.itemId,
		socketCount = sourceSkillSocket.socketCount,
		linkGroup = sourceSkillSocket.linkGroup,
	} or nil
	local marketBudget = sourceBudget and sourceBudget.enabled and {
		status = sourceBudget.status,
		mode = sourceBudget.mode,
		unit = sourceBudget.unit,
		league = sourceBudget.league,
		source = sourceBudget.source,
		provider = sourceBudget.provider,
		total = isFinite(sourceBudget.total) and sourceBudget.total or nil,
		limit = isFinite(sourceBudget.limit) and sourceBudget.limit or sourceBudget.amount,
		itemCount = sourceBudget.itemCount,
		pricedItemCount = sourceBudget.pricedItemCount,
		missingItems = sourceBudget.missingItems,
	} or nil
	return {
		index = index,
		label = boundedText(candidate and candidate.label or "", 180),
		feasible = candidate and candidate.feasible or false,
		generationPhase = boundedText(candidate and candidate.generationPhase or "", 32),
		requiresSocketedMainSkill = candidate and candidate.requiresSocketedMainSkill == true or false,
		unlinkedMainSkillPlan = candidate and candidate.unlinkedMainSkillPlan == true or false,
		addedNodeIds = candidate and candidate.nodeIds or { },
		removedNodeIds = candidate and candidate.removeNodeIds or { },
		classVariant = candidate and candidate.classVariant or nil,
		ascendancyVariant = candidate and candidate.ascendancyVariant or nil,
		anointVariant = candidate and candidate.anointVariant or nil,
		anointVariants = candidate and candidate.anointVariants or nil,
		gearVariant = candidate and candidate.gearVariant and {
			overrides = candidate.gearVariant.overrides or { },
			items = candidate.gearVariant.items or { },
			socketBinding = socketBinding,
			inventorySearch = candidate.gearVariant.inventorySearch == true,
			inventoryPair = candidate.gearVariant.inventoryPair == true,
			inventoryRoutePair = candidate.gearVariant.inventoryRoutePair == true,
		} or nil,
		jewelVariant = candidate and candidate.jewelVariant or nil,
		jewelVariants = candidate and candidate.jewelVariants or nil,
		jewelCombination = candidate and candidate.jewelCombination or nil,
		hierarchicalExpert = candidate and candidate.hierarchicalExpert or nil,
		hierarchicalExperts = candidate and candidate.hierarchicalExperts or nil,
		masteryVariant = candidate and candidate.masteryVariant or nil,
		tattooVariant = candidate and candidate.tattooVariant or nil,
		timelessVariant = candidate and candidate.timelessVariant or nil,
		gemVariant = candidate and candidate.gemVariant or nil,
		gemVariants = candidate and candidate.gemVariants or nil,
		configurationVariant = candidate and candidate.configurationVariant or nil,
		metrics = metrics,
		metricDeltaFromSearchBaseline = type(baselineMetrics) == "table" and metricDelta(baselineMetrics, metrics) or nil,
		marketBudget = marketBudget,
		mainSkillPayability = evaluation.mainSkillPayability,
		enabledSkillsPayability = evaluation.enabledSkillsPayability,
		skillSocket = skillSocket,
		fullDPSPayability = evaluation.fullDPSPayability,
		activitySustain = evaluation.activitySustain,
		manualActionAudit = evaluation.manualActionAudit,
		skillAvailability = evaluation.skillAvailability,
		requirements = evaluation.requirements,
		skillEntityLimits = evaluation.skillEntityLimits or { },
		violations = violations,
		objective = evaluation.objective,
		objectiveValue = evaluation.objective and metrics[evaluation.objective] or nil,
		passivePointsUsed = evaluation.passivePointsUsed,
		extraPassivePoints = isFinite(evaluation.extraPassivePoints) and evaluation.extraPassivePoints or nil,
		passivePointLimit = evaluation.passivePointLimit,
		strictPointCap = evaluation.strictPointCap,
		ascendancyPointsUsed = evaluation.ascendancyPointsUsed,
		secondaryAscendancyPointsUsed = evaluation.secondaryAscendancyPointsUsed,
		characterLevel = evaluation.characterLevel,
		ascendancyPointBudget = evaluation.ascendancyPointBudget,
		selectedBaseClassName = boundedText(evaluation.selectedBaseClassName or "", 80),
		selectedAscendancyName = boundedText(evaluation.selectedAscendancyName or "", 100),
		selectedSecondaryAscendancyName = boundedText(evaluation.selectedSecondaryAscendancyName or "None", 100),
		scenarioProfile = evaluation.scenarioProfile,
		scenario = evaluation.scenario,
	}
end

local function findJob(jobId)
	if type(jobId) ~= "string" then return nil end
	return bridge.jobs and bridge.jobs[jobId]
end

local function trimJobHistory(limit)
	local completed, count = { }, 0
	for id, record in pairs(bridge.jobs) do
		count = count + 1
		if record.job.status ~= "running" then completed[#completed + 1] = id end
	end
	table.sort(completed)
	for _, id in ipairs(completed) do
		if count <= limit then break end
		bridge.jobs[id], count = nil, count - 1
	end
	return count <= limit
end

local buildSiteHosts = {
	Maxroll = "maxroll.gg",
	PoBCodes = "pob.codes",
	POBBin = "pobb.in",
	pastebin = "pastebin.com",
	pastebinProxy = "pastebinp.com",
	rentry = "rentry.co",
	PoEDB = "poedb.tw",
}

local function findPublicBuildProvider(url)
	if type(url) ~= "string" or #url < 12 or #url > 2048 or url:find("[%c%s]") then
		return nil
	end
	local authority = url:match("^https://([^/%?#]+)$") or url:match("^https://([^/%?#]+)[/%?#]")
	if not authority or authority:find("@", 1, true) or authority:find(":", 1, true) then return nil end
	local host = authority:lower()
	for _, site in ipairs(buildSites and buildSites.websiteList or { }) do
		if buildSiteHosts[site.id] == host and site.matchURL and site.regexURL
			and url:match(site.matchURL) and url:match(site.regexURL) then
			return site
		end
	end
	return nil
end

local function isPoeNinjaBuildURL(url)
	if type(url) ~= "string" then return false end
	local authority = url:match("^https://([^/%?#]+)$") or url:match("^https://([^/%?#]+)[/%?#]")
	return authority ~= nil and not authority:find("@", 1, true) and not authority:find(":", 1, true)
		and authority:lower() == "poe.ninja"
end

local function countEntries(values, predicate)
	local count = 0
	for _, value in pairs(values or { }) do
		if not predicate or predicate(value) then count = count + 1 end
	end
	return count
end

studyBuildIndex = function(compareTab, entry)
	for index, value in ipairs(compareTab and compareTab.compareEntries or { }) do
		if value == entry then return index end
	end
	return nil
end

-- Native PoB comparison entries are the safe route for studying a build that
-- the user imported in the application (including a local PoB code). IDs are
-- scoped to the active Build object and point to entry identity, never to a
-- mutable array index. Synchronization drops removed entries and resets the
-- registry when the active build/CompareTab changes.
comparisonRegistry = function(build)
	build = build or currentBuild()
	if not build then return nil, "Open a PoB build before listing comparison builds" end
	local compareTab = build.compareTab
	if not compareTab or type(compareTab.compareEntries) ~= "table" then
		return nil, "PoB comparison builds are not available for the active build"
	end
	if bridge.comparisonOwner ~= build or bridge.comparisonTab ~= compareTab then
		bridge.comparisonOwner = build
		bridge.comparisonTab = compareTab
		bridge.comparisonEntriesById = { }
		bridge.comparisonIdByEntry = setmetatable({ }, { __mode = "k" })
	end
	bridge.comparisonEntriesById = bridge.comparisonEntriesById or { }
	bridge.comparisonIdByEntry = bridge.comparisonIdByEntry or setmetatable({ }, { __mode = "k" })
	local present = setmetatable({ }, { __mode = "k" })
	for _, entry in ipairs(compareTab.compareEntries) do
		if type(entry) == "table" then
			present[entry] = true
			local id = bridge.comparisonIdByEntry[entry]
			if not id then
				bridge.nextComparisonId = (bridge.nextComparisonId or 0) + 1
				id = "pob-comparison-" .. tostring(bridge.nextComparisonId)
				bridge.comparisonIdByEntry[entry] = id
			end
			bridge.comparisonEntriesById[id] = entry
		end
	end
	for id, entry in pairs(bridge.comparisonEntriesById) do
		if not present[entry] then
			bridge.comparisonEntriesById[id] = nil
			bridge.comparisonIdByEntry[entry] = nil
		end
	end
	return {
		build = build,
		compareTab = compareTab,
		byId = bridge.comparisonEntriesById,
		idByEntry = bridge.comparisonIdByEntry,
	}
end

local function listComparisonBuilds()
	local registry, registryError = comparisonRegistry()
	if not registry then return nil, registryError end
	local entries = { }
	for index, entry in ipairs(registry.compareTab.compareEntries) do
		local output = entry.calcsTab and entry.calcsTab.mainOutput or { }
		local activeGroup = entry.skillsTab and entry.skillsTab.socketGroupList[entry.mainSocketGroup]
		local mainSkill = activeGroup and activeGroup.displaySkillList
			and activeGroup.displaySkillList[activeGroup.mainActiveSkill or 1]
		local id = registry.idByEntry[entry]
		entries[#entries + 1] = {
			comparisonId = id,
			index = index,
			label = boundedText(entry.label or entry.buildName or "Comparison build", 120),
			selectedInCompareTab = registry.compareTab.activeCompareIndex == index,
			characterLevel = entry.characterLevel,
			class = getClassInfo(entry),
			dataVersion = Version.Data(entry),
			treeVersion = entry.spec and entry.spec.treeVersion,
			mainSkill = skillName(mainSkill),
			passivePointsUsed = entry.spec and entry.spec:CountAllocNodes() or nil,
			exactMetrics = exactMetrics(output),
		}
	end
	return {
		activeBuildPreserved = true,
		count = #entries,
		entries = jsonArray(entries),
	}
end

local function getComparisonBuildSnapshot(params)
	local comparisonId = params and params.comparisonId
	if type(comparisonId) ~= "string" or #comparisonId < 1 or #comparisonId > 96 then
		return nil, "comparisonId must be a valid local comparison ID"
	end
	local registry, registryError = comparisonRegistry()
	if not registry then return nil, registryError end
	local entry = registry.byId[comparisonId]
	local index = entry and studyBuildIndex(registry.compareTab, entry)
	if not index then
		if entry then
			registry.byId[comparisonId] = nil
			registry.idByEntry[entry] = nil
		end
		return nil, "The local comparison entry was removed or belongs to a different active build"
	end
	local snapshot, snapshotError = getSnapshot(entry)
	if not snapshot then return nil, snapshotError end
	snapshot.isActiveBuild = false
	snapshot.comparison = {
		id = comparisonId,
		label = boundedText(entry.label or entry.buildName or "Comparison build", 120),
		index = index,
		selectedInCompareTab = registry.compareTab.activeCompareIndex == index,
	}
	return snapshot
end

-- Read one imported build's selected skill effect through PoB's own isolated
-- calculator. The active build and native Compare selection are never edited.
local function analyzeComparisonSkill(params)
	local studyId, comparisonId = params and params.studyId, params and params.comparisonId
	if (studyId == nil) == (comparisonId == nil) then
		return nil, "Provide exactly one imported studyId or native comparisonId"
	end
	local groupIndex, skillIndex = tonumber(params.groupIndex), tonumber(params.skillIndex)
	if not isFinite(groupIndex) or groupIndex ~= math.floor(groupIndex) or groupIndex < 1
		or not isFinite(skillIndex) or skillIndex ~= math.floor(skillIndex) or skillIndex < 1 then
		return nil, "groupIndex and skillIndex must be positive integers from the imported build's skill list"
	end
	local build, source = resolveBuildReference(studyId, "analyze an imported skill", comparisonId)
	if not build then return nil, source end
	if not source then return nil, "This operation only analyzes an explicitly imported or native comparison build" end
	local reference = experimentSource(source)
	local function unsupported(reason)
		return { status = "unsupported", exactCalculated = false, readOnly = true,
			reason = reason, source = reference, buildReference = reference, isActiveBuild = false }
	end
	local group = build.skillsTab and build.skillsTab.socketGroupList and build.skillsTab.socketGroupList[groupIndex]
	local selectedSkill = group and group.displaySkillList and group.displaySkillList[skillIndex]
	if not group or not selectedSkill then return nil, "The requested skill group or active-skill effect does not exist" end
	if group.enabled == false or group.slotEnabled == false then
		return nil, "The requested socket group is disabled in the imported PoB build"
	end
	local beforeSignature = Candidate.BuildSignature(currentBuild())
	local sourceSignature = Candidate.BuildSignature(build)
	local compareTab
	if source.referenceType == "native_comparison" then
		local registry, registryError = comparisonRegistry()
		if not registry then return nil, registryError end
		compareTab = registry.compareTab
	end
	local compareIndex = compareTab and compareTab.activeCompareIndex
	local skillTab = { }
	for key, value in pairs(build.skillsTab) do skillTab[key] = value end
	setmetatable(skillTab, getmetatable(build.skillsTab))
	local groups = { }
	for index, original in ipairs(build.skillsTab.socketGroupList) do
		local copy = { }
		for key, value in pairs(original) do copy[key] = value end
		copy.gemList = { }
		for gemIndex, originalGem in ipairs(original.gemList or { }) do
			local gemCopy = { }
			for key, value in pairs(originalGem) do gemCopy[key] = value end
			copy.gemList[gemIndex] = gemCopy
		end
		if index == groupIndex then copy.mainActiveSkill = skillIndex end
		groups[index] = copy
	end
	skillTab.socketGroupList = groups
	local proxy = { }
	for key, value in pairs(build) do proxy[key] = value end
	proxy.skillsTab = skillTab
	proxy.mainSocketGroup = groupIndex
	setmetatable(proxy, { __index = build })
	skillTab.build = proxy
	for _, candidateGroup in ipairs(groups) do skillTab:ProcessSocketGroup(candidateGroup) end
	local ok, calcFn, initialOutput, initialEnv = pcall(Calcs.getMiscCalculator, proxy)
	if not ok or type(calcFn) ~= "function" then
		return unsupported("PoB could not construct an isolated exact calculation for this imported skill")
	end
	local calcOk, output = pcall(calcFn)
	if not calcOk or type(output or initialOutput) ~= "table" then
		return unsupported("PoB could not complete an isolated exact calculation for this imported skill")
	end
	output = output or initialOutput or { }
	proxy.calcsTab = { mainOutput = output, mainEnv = initialEnv }
	local snapshotOk, snapshot = pcall(getSnapshot, proxy)
	local afterSignatureOk, afterSignature = pcall(Candidate.BuildSignature, currentBuild())
	local sourceSignatureOk, afterSourceSignature = pcall(Candidate.BuildSignature, build)
	if not afterSignatureOk or afterSignature ~= beforeSignature
		or not sourceSignatureOk or afterSourceSignature ~= sourceSignature
		or (compareTab and compareTab.activeCompareIndex ~= compareIndex) then
		return nil, "Read-only skill analysis detected an active/imported build or Compare selection change; result discarded"
	end
	if not snapshotOk or type(snapshot) ~= "table" then
		return unsupported("PoB calculated the skill, but its exact mechanics snapshot could not be isolated")
	end
	local mechanics = getMainSkillMechanics(proxy, selectedSkill, groupIndex, skillIndex)
	local selectedEffect = skillEffect(selectedSkill)
	return {
		status = "exact",
		exactCalculated = true,
		readOnly = true,
		source = reference,
		buildReference = reference,
		isActiveBuild = false,
		target = { groupIndex = groupIndex, skillIndex = skillIndex,
			name = skillName(selectedSkill), skillId = selectedSkill.skillId,
			effectId = selectedEffect and selectedEffect.grantedEffect and selectedEffect.grantedEffect.id,
			effectName = selectedEffect and selectedEffect.grantedEffect and selectedEffect.grantedEffect.name },
		metrics = exactMetrics(output),
		mechanics = mechanics,
		requirements = Validator.CheckRequirements(output, build.characterLevel),
	}
end

local function completeStudyImport(record, xmlText, resolvedUrl, importError)
	if record.status ~= "running" then return end
	if os.time() - record.startedAt > studyImportTimeout then
		record.status = "timed_out"
		record.error = "PoB's native build download exceeded the 90-second study limit"
		record.completedAt = os.time()
		return
	end
	if importError or type(xmlText) ~= "string" or xmlText == "" then
		record.status = "failed"
		record.error = boundedText(importError or "PoB's native importer returned an empty build", 300)
		record.completedAt = os.time()
		return
	end
	if currentBuild() ~= record.primaryBuild then
		record.status = "failed"
		record.error = "The active PoB build changed while the public build was downloading"
		record.completedAt = os.time()
		return
	end
	local signatureOk, currentSignature = pcall(Candidate.BuildSignature, record.primaryBuild)
	if not signatureOk or currentSignature ~= record.primarySignature then
		record.status = "failed"
		record.error = "The active PoB build was edited while the public build was downloading"
		record.completedAt = os.time()
		return
	end
	if countEntries(bridge.studyBuilds) >= maxStudyBuilds then
		record.status = "failed"
		record.error = "The comparison study limit is full; remove a study build first"
		record.completedAt = os.time()
		return
	end

	local compareTab = record.compareTab
	local oldCount = #compareTab.compareEntries
	local oldSelection = compareTab.activeCompareIndex or 0
	record.previousSelection = oldSelection
	local importOk, imported = pcall(compareTab.ImportBuild, compareTab, xmlText, record.label)
	if not importOk or imported ~= true or #compareTab.compareEntries ~= oldCount + 1 then
		record.status = "failed"
		record.error = "PoB could not load the public build as a comparison entry"
		record.completedAt = os.time()
		return
	end
	local entry = compareTab.compareEntries[oldCount + 1]
	record.importedEntry = entry
	local function restoreComparisonSelection()
		compareTab.activeCompareIndex = oldSelection
		if compareTab.UpdateBuildSelector then compareTab:UpdateBuildSelector() end
		if compareTab.controls and compareTab.controls.compareBuildSelect then
			compareTab.controls.compareBuildSelect.selIndex = oldSelection
		end
	end
	restoreComparisonSelection()
	if not entry or not entry.calcsTab or not entry.calcsTab.mainOutput then
		compareTab:RemoveBuild(oldCount + 1)
		record.importedEntry = nil
		restoreComparisonSelection()
		record.status = "failed"
		record.error = "PoB did not produce exact calculation output for the imported build"
		record.completedAt = os.time()
		return
	end
	local afterOk, afterSignature = pcall(Candidate.BuildSignature, record.primaryBuild)
	if currentBuild() ~= record.primaryBuild or not afterOk or afterSignature ~= record.primarySignature then
		compareTab:RemoveBuild(oldCount + 1)
		record.importedEntry = nil
		restoreComparisonSelection()
		record.status = "failed"
		record.error = "The active PoB build changed while PoB was loading the comparison"
		record.completedAt = os.time()
		return
	end
	local archive, archiveError = StudyBuilds.ArchiveXML(entry, xmlText, main and main.userPath, {
		type = "public_build_study",
		provider = record.provider,
		reference = resolvedUrl or record.url,
		label = record.label,
		claimedLeague = record.claimedLeague,
	}, MakeDir)
	if not archive then
		compareTab:RemoveBuild(oldCount + 1)
		record.importedEntry = nil
		restoreComparisonSelection()
		record.status = "failed"
		record.error = "PoB calculated the imported build, but it could not be saved to the local learning archive: "
			.. boundedText(archiveError, 220)
		record.completedAt = os.time()
		return
	end

	bridge.nextStudy = (bridge.nextStudy or 0) + 1
	local studyId = "pob-study-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextStudy)
	bridge.studyBuilds[studyId] = {
		id = studyId,
		entry = entry,
		compareTab = compareTab,
		primaryBuild = record.primaryBuild,
		provider = record.provider,
		url = resolvedUrl or record.url,
		label = record.label,
		importedAt = os.time(),
		claimedLeague = record.claimedLeague,
		archive = archive,
	}
	record.importedEntry = nil
	record.previousSelection = nil
	record.studyId = studyId
	record.status = "complete"
	record.completedAt = os.time()
end

local function expireStudyImport(record)
	if record and record.status == "running" and os.time() - record.startedAt > studyImportTimeout then
		record.status = "timed_out"
		record.error = "PoB's native build download exceeded the 90-second study limit"
		record.completedAt = os.time()
	end
	return record
end

local function beginStudyImport(params)
	local primaryBuild = currentBuild()
	if not primaryBuild then return nil, "Open a PoB build before importing a study build" end
	bridge.studyJobs = bridge.studyJobs or { }
	bridge.studyBuilds = bridge.studyBuilds or { }
	local url = params.url
	if isPoeNinjaBuildURL(url) then
		return nil, "PoE Ninja build/profile endpoints are not available for third-party use. Import the build through PoB's native UI or provide a local PoB export, then inspect it with list_comparison_builds."
	end
	local provider = findPublicBuildProvider(url)
	if not provider then return nil, "Use an HTTPS build URL from a site recognized by PoB's native importer" end
	local compareTab = primaryBuild.compareTab
	if not compareTab or type(compareTab.ImportBuild) ~= "function" then return nil, "PoB comparison builds are not available for the active build" end
	if countEntries(bridge.studyBuilds) >= maxStudyBuilds then return nil, "The comparison study limit is full; remove a study build first" end
	if countEntries(bridge.studyJobs, function(record) return record.status == "running" end) >= maxConcurrentStudyImports then
		return nil, "Two public build imports are already running; wait for one to finish"
	end
	local signatureOk, signature = pcall(Candidate.BuildSignature, primaryBuild)
	if not signatureOk then return nil, "Could not capture the active build state before import" end
	local label = params.label
	if label ~= nil and (type(label) ~= "string" or #label > 80 or label:find("[%c]")) then
		return nil, "label must be plain text of at most 80 characters"
	end
	label = label and label:match("^%s*(.-)%s*$") or ""
	if label == "" then label = provider.label .. " study" end
	local claimedLeague = params.league
	if claimedLeague ~= nil and (type(claimedLeague) ~= "string" or #claimedLeague > 80 or claimedLeague:find("[%c]")) then
		return nil, "league must be plain text of at most 80 characters"
	end
	claimedLeague = claimedLeague and claimedLeague:match("^%s*(.-)%s*$") or ""
	if claimedLeague == "" then claimedLeague = nil end
	bridge.nextStudyJob = (bridge.nextStudyJob or 0) + 1
	local jobId = "pob-import-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextStudyJob)
	local record = {
		jobId = jobId,
		status = "running",
		startedAt = os.time(),
		primaryBuild = primaryBuild,
		primarySignature = signature,
		compareTab = compareTab,
		provider = provider.label,
		url = url,
		label = label,
		claimedLeague = claimedLeague,
	}
	bridge.studyJobs[jobId] = record
	local ok, err = pcall(ImportBuild, url, function(xmlText, resolvedUrl, importError)
		local callbackOk, callbackError = pcall(completeStudyImport, record, xmlText, resolvedUrl, importError)
		if not callbackOk and record.status == "running" then
			local entryIndex = studyBuildIndex(record.compareTab, record.importedEntry)
			if entryIndex then pcall(record.compareTab.RemoveBuild, record.compareTab, entryIndex) end
			if record.previousSelection then
				record.compareTab.activeCompareIndex = record.previousSelection
				if record.compareTab.UpdateBuildSelector then pcall(record.compareTab.UpdateBuildSelector, record.compareTab) end
			end
			record.status = "failed"
			record.error = boundedText(callbackError, 300)
			record.completedAt = os.time()
		end
	end, { followRedirects = false })
	if not ok then
		record.status = "failed"
		record.error = boundedText(err, 300)
		record.completedAt = os.time()
	end
	return {
		jobId = jobId,
		status = record.status,
		provider = record.provider,
		label = record.label,
		activeBuildPreserved = true,
		studyId = record.studyId,
		error = record.error,
	}
end

local function classRootsSummary(jobId, record)
	local job = record and record.job
	local result = job and job.result
	local rows = result and result.results or job and job.results or { }
	local summary = { jobId = jobId, status = job and job.status or "unknown", progress = job and job.progress, exactEngine = true, rootOnly = true, results = { } }
	for _, row in ipairs(rows) do
		local metrics = { }
		for key, value in pairs(row.metrics or { }) do
			if isFinite(value) then metrics[key] = value end
		end
		local violations = { }
		for _, violation in ipairs(row.violations or { }) do
			violations[#violations + 1] = { key = violation.key, label = violation.label, reason = boundedText(violation.reason or "", 200) }
		end
		summary.results[#summary.results + 1] = {
			classId = row.classId,
			class = row.class,
			status = row.status,
			passivePoints = row.passivePoints or 0,
			baseline = row.baseline,
			metrics = metrics,
			violations = violations,
			reason = row.reason and boundedText(row.reason, 200) or nil,
		}
	end
	return summary
end

local function getStudyRecordVersions()
	local build = currentBuild()
	if not build then return nil, "Open a PoB build to compare study-record versions" end
	return Version.Snapshot(build)
end

local function listStudyRecords(params)
	local versions, versionError = getStudyRecordVersions()
	if not versions then return nil, versionError end
	local path, pathError = StudyRecords.GetStorePath(main and main.userPath)
	if not path then return nil, pathError end
	local result, listError = StudyRecords.List(path, params.limit, versions.dataVersion, versions.treeVersion,
		versions.pobVersion, versions.pobBranch, versions.manifestFingerprint)
	if not result then return nil, listError end
	result.currentDataVersion = versions.dataVersion
	result.currentTreeVersion = versions.treeVersion
	result.currentManifestFingerprint = versions.manifestFingerprint
	result.trainingReadiness = result.trainingReadiness or TrainingData.Summary(TrainingData.Prepare({ }, versions))
	result.storeFile = "OptimizerStudies/paired-experiments.jsonl"
	return result
end

local function exportStudyDataset()
	local versions, versionError = getStudyRecordVersions()
	if not versions then return nil, versionError end
	local result, exportError = StudyRecords.ExportTrainingDataset(main and main.userPath, versions, MakeDir)
	if not result then return nil, exportError end
	result.currentDataVersion = versions.dataVersion
	result.currentTreeVersion = versions.treeVersion
	result.storeFile = "OptimizerStudies/paired-experiments.jsonl"
	return result
end

local function getStudyRecord(params)
	local versions, versionError = getStudyRecordVersions()
	if not versions then return nil, versionError end
	local path, pathError = StudyRecords.GetStorePath(main and main.userPath)
	if not path then return nil, pathError end
	local record, readError = StudyRecords.ReadById(path, params.recordId, versions.dataVersion, versions.treeVersion,
		versions.pobVersion, versions.pobBranch, versions.manifestFingerprint)
	if not record then return nil, readError end
	return StudyRecords.RedactForAI(record)
end

local function clearManagedTrainingDirectory(relativePath)
	if relativePath ~= "OptimizerStudies/TrainingDatasets" and relativePath ~= "OptimizerModels" then
		return nil, "Refusing to remove a directory outside the managed training-artifact allowlist"
	end
	if type(main and main.userPath) ~= "string" or main.userPath == "" then
		return nil, "PoB's configured user-data directory is unavailable"
	end
	local separator = package.config and package.config:sub(1, 1) or "\\"
	local relative = relativePath:gsub("/", separator)
	local base = main.userPath:gsub("[/\\]+$", "")
	local directory = base .. separator .. relative
	if type(NewFileSearch) == "function" then
		local searchOk, matches = pcall(NewFileSearch, directory .. separator .. "*", true)
		if not searchOk then return nil, "Could not inspect managed training artifacts: " .. tostring(matches) end
		if not matches then return true end -- no derived files exist; an empty folder is harmless
	end
	if type(RemoveDir) ~= "function" then return nil, "PoB's recursive directory remover is unavailable" end
	local removeOk, removed, removeError = pcall(RemoveDir, directory, true)
	if not removeOk then return nil, tostring(removed) end
	if not removed then return nil, tostring(removeError or "native directory removal failed") end
	return true
end

local function deleteStudyRecord(params)
	for key in pairs(params or { }) do
		if key ~= "recordId" and key ~= "confirm" then return nil, "Unsupported delete_study_record field: " .. tostring(key) end
	end
	if params.confirm ~= true then return nil, "confirm=true is required after an explicit user request to delete this local study record" end
	local path, pathError = StudyRecords.GetStorePath(main and main.userPath)
	if not path then return nil, pathError end
	Surrogate.Disable()
	return StudyRecords.DeleteById(path, params.recordId, clearManagedTrainingDirectory)
end

local function pruneStudyRecords(params)
	for key in pairs(params or { }) do
		if key ~= "olderThanDays" and key ~= "confirm" then return nil, "Unsupported prune_study_records field: " .. tostring(key) end
	end
	if params.confirm ~= true then return nil, "confirm=true is required after an explicit user request to prune local study records" end
	local path, pathError = StudyRecords.GetStorePath(main and main.userPath)
	if not path then return nil, pathError end
	Surrogate.Disable()
	return StudyRecords.PruneOlderThan(path, params.olderThanDays, clearManagedTrainingDirectory)
end

local function getSynergyGraph(params)
	for key in pairs(params or { }) do if key ~= "limit" then return nil, "Unsupported get_synergy_graph field: " .. tostring(key) end end
	local limit = params.limit == nil and 25 or params.limit
	if not isFinite(limit) or limit ~= math.floor(limit) or limit < 1 or limit > 25 then
		return nil, "limit must be an integer from 1 to 25"
	end
	local versions, versionError = getStudyRecordVersions()
	if not versions then return nil, versionError end
	local path, pathError = StudyRecords.GetStorePath(main and main.userPath)
	if not path then return nil, pathError end
	local listed, listError = StudyRecords.List(path, limit, versions.dataVersion, versions.treeVersion,
		versions.pobVersion, versions.pobBranch, versions.manifestFingerprint)
	if not listed then return nil, listError end
	local fullRecords = { }
	for _, summary in ipairs(listed.records or { }) do
		local record, readError = StudyRecords.ReadById(path, summary.recordId, versions.dataVersion, versions.treeVersion,
			versions.pobVersion, versions.pobBranch, versions.manifestFingerprint)
		if not record then return nil, "Could not load exact synergy evidence " .. tostring(summary.recordId) .. ": " .. tostring(readError) end
		fullRecords[#fullRecords + 1] = record
	end
	local result, graphError = RelationGraph.Build(fullRecords, versions, limit)
	if not result then return nil, graphError end
	result.currentDataVersion = versions.dataVersion
	result.currentTreeVersion = versions.treeVersion
	result.currentPobVersion = versions.pobVersion
	result.currentPobBranch = versions.pobBranch
	result.currentManifestFingerprint = versions.manifestFingerprint
	result.totalStoredRecords = listed.totalRecords
	result.storeFile = "OptimizerStudies/paired-experiments.jsonl"
	return result
end

local qaSuiteNames = {
	integration = true,
	planner = true,
	build = true,
	optimizer_smoke = true,
}

local function qaIsRunning(suite)
	for _, record in pairs(bridge.qaJobs or { }) do
		if record.status == "running" and (suite == nil or record.suite == suite) then return true end
	end
	return false
end

function bridge:IsQARunning()
	return qaIsRunning("optimizer_smoke")
end

local function qaSummary(jobId, record)
	local checks = { }
	for _, check in ipairs(record.checks or { }) do
		checks[#checks + 1] = {
			name = check.name,
			status = check.status,
			detail = boundedText(check.detail or "", 240),
		}
	end
	local progress = record.optimizerJob and record.optimizerJob.progress
	local result = {
		jobId = jobId,
		suite = record.suite,
		status = record.status,
		readOnly = true,
		activeBuildPreserved = true,
		checks = checks,
		progress = progress and {
			phase = boundedText(progress.phase or "", 80),
			processed = progress.processed or 0,
			total = progress.total or 0,
		} or nil,
	}
	if record.error then result.error = boundedText(record.error, 300) end
	if record.exactEvaluations then result.exactEvaluations = record.exactEvaluations end
	if record.exactMetric then result.exactMetric = record.exactMetric end
	return result
end

local function finishQASuite(record, status, message)
	record.status = status
	record.completedAt = os.time()
	if message then record.error = boundedText(message, 300) end
	if record.optimizerJob and record.optimizerJob.status == "running" and status ~= "passed" then
		record.optimizerJob:Cancel()
	end
end

local function appendQACheck(record, name, status, detail)
	record.checks[#record.checks + 1] = { name = name, status = status, detail = boundedText(detail or "", 240) }
	if status == "fail" then finishQASuite(record, "failed", detail) end
end

local function runQAStep(record)
	local build = record.build
	if currentBuild() ~= build then
		finishQASuite(record, "failed", "The active PoB build changed during read-only QA")
		return
	end
	local signatureOk, signature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or signature ~= record.sourceSignature then
		finishQASuite(record, "failed", "The active PoB build changed during read-only QA")
		return
	end

	if record.optimizerJob then
		local ok, status, result = pcall(function()
			local jobStatus, jobResult = record.optimizerJob:Step()
			return jobStatus, jobResult
		end)
		if not ok then
			finishQASuite(record, "failed", "Exact optimizer smoke raised an error: " .. tostring(status))
			return
		end
		if status == "running" then return end
		if record.cancelRequested or status == "cancelled" then
			finishQASuite(record, "cancelled")
			return
		end
		if status ~= "feasible" or not result or result.status ~= "feasible" or not result.candidate or not result.evaluation then
			local violation = result and result.bestObservedViolations and result.bestObservedViolations[1]
			finishQASuite(record, "failed", violation and (violation.reason or violation.label) or ("Exact optimizer smoke ended as " .. tostring(status)))
			return
		end
		if Candidate.HasMutation(result.candidate) then
			finishQASuite(record, "failed", "One-evaluation smoke selected a mutation; no candidate was applied")
			return
		end
		local candidateValue = result.evaluation.metrics and result.evaluation.metrics.TotalEHP
		local tolerance = math.max(1, math.abs(record.baselineTotalEHP or 0)) * 1e-9
		if not isFinite(candidateValue) or math.abs(candidateValue - record.baselineTotalEHP) > tolerance then
			finishQASuite(record, "failed", "No-op candidate TotalEHP did not match the active PoB calculation")
			return
		end
		record.exactEvaluations = result.evaluations or 1
		record.exactMetric = { name = "TotalEHP", value = candidateValue, matchesCurrentPoB = true, tolerance = tolerance }
		appendQACheck(record, "One exact no-op optimizer candidate", "pass", "Candidate matched current PoB TotalEHP within 1e-9; active tree and build signature were unchanged")
		finishQASuite(record, "passed")
		return
	end

	local checks = {
		{
			name = "Active build and native AI Planner tab",
			run = function()
				return build.spec ~= nil and build.optimizerTab ~= nil, "PoB Build, PassiveSpec, and native AI Planner tab are loaded"
			end,
		},
		{
			name = "Selected PoB class start and passive connectivity",
			run = function()
				local parsed, parseError = Inputs.Parse({ })
				if not parsed then return false, parseError end
				local valid, reason = TreeSearch.ValidateCandidate(build.spec, { }, parsed,
					TreeSearch.BuildRegionMap(build.spec), { }, build.spec)
				return valid, reason or "Allocated passives connect to the single class start selected in PoB"
			end,
		},
		{
			name = "Exact PoB calculation output",
			run = function()
				local output = build.calcsTab and build.calcsTab.mainOutput
				return type(output) == "table" and next(output) ~= nil, "The active build has native PoB calculation output"
			end,
		},
		{
			name = "Matrix and passive-tree version validation",
			run = function()
				local parsed, parseError = Inputs.Parse({ })
				if not parsed then return false, parseError end
				local valid, treeError = Inputs.ValidateAgainstTree(parsed, build.spec.tree)
				return valid, treeError or ("Default Matrix parsed for PoB tree " .. tostring(build.spec.treeVersion or "unknown"))
			end,
		},
	}
	if record.suite == "integration" then
		table.insert(checks, 1, {
			name = "Authenticated loopback MCP listener and companion endpoint",
			run = function()
				local endpoint = bridge:GetEndpointStatus()
				local listenerReady = bridge.listener ~= nil and bridge.port ~= nil and bridge.token ~= nil
				local ready = listenerReady and endpoint.status == "published"
				return ready, ready and endpoint.message or endpoint.message
			end,
		})
	elseif record.suite == "planner" then
		table.insert(checks, {
			name = "Selected Main Skill objective contract",
			run = function()
				local parsed = Inputs.Parse({ })
				local valid, reason = Inputs.ValidateBuild(build, parsed)
				return valid, valid and "Default selected-skill objective has a valid enabled Main Skill" or ("Warning: " .. tostring(reason))
			end,
		})
		table.insert(checks, {
			name = "Native skill tags and exact damage-conversion provenance",
			warningOnFailure = true,
			run = function()
				local snapshot, snapshotError = getSnapshot(build)
				if not snapshot then return false, snapshotError end
				local mechanics = snapshot.mainSkillMechanics
				if type(mechanics) ~= "table" or mechanics.status ~= "resolved" then
					return false, mechanics and mechanics.reason or "PoB did not resolve the selected Main Skill"
				end
				if not mechanics.gem or #(mechanics.tags or { }) == 0 then
					return false, "The selected skill has no resolved loaded-gem tag list; granted skills need an exact tagged-gem source before this check can certify them"
				end
				if mechanics.effectTypeStatus ~= "exact" then
					return false, "PoB did not expose a complete native skill-type list for the selected active effect"
				end
				local breakdown = snapshot.mainSkillBreakdown
				if type(breakdown) ~= "table" or breakdown.status ~= "exact" or type(breakdown.player) ~= "table" then
					return false, breakdown and breakdown.reason or "PoB did not expose the selected Main Skill's native CalcOffence breakdown"
				end
				if not mechanics.conversion or mechanics.conversion.status ~= "exact" then
					return false, mechanics.conversion and mechanics.conversion.reason or "PoB did not expose the matching exact conversion table"
				end
				local converted = #(mechanics.conversion.converted or { })
				local gainedAs = #(mechanics.conversion.gainedAs or { })
				return true, string.format("%s resolved to %d loaded gem tags, %d native active-effect skill types, %d exact CalcOffence damage buckets, %d conversion edges, and %d gained-as edges",
					tostring(mechanics.name), #mechanics.tags, #mechanics.effectTypes, #(breakdown.player.damageTypes or { }), converted, gainedAs)
			end,
		})
	elseif record.suite == "build" then
		table.insert(checks, {
			name = "Exact live build snapshot",
			run = function()
				local snapshot, snapshotError = getSnapshot(build)
				if not snapshot then return false, snapshotError end
				local count = 0
				for _, value in pairs(snapshot.exactMetrics or { }) do if isFinite(value) then count = count + 1 end end
				return count > 0, string.format("Read %d finite metrics from local PoB output", count)
			end,
		})
		table.insert(checks, {
			name = "Native recurring activity sustain",
			warningOnFailure = true,
			run = function()
				local snapshot, snapshotError = getSnapshot(build)
				if not snapshot then return false, snapshotError end
				local audit = snapshot.activitySustain
				if type(audit) ~= "table" then return false, "PoB did not provide an activity-sustain audit" end
				if audit.feasible then
					if audit.status == "not_required" then
						return true, "No recurring damage activity is active; sustain was not required by the PoB activity ledger"
					end
					return true, "PoB's exact recurring activity rates are covered by the captured recovery"
				end
				local reasons = { }
				for _, violation in ipairs(audit.violations or { }) do
					if type(violation.reason) == "string" and violation.reason ~= "" then
						reasons[#reasons + 1] = violation.reason
					elseif violation.actual ~= nil and violation.required ~= nil then
						reasons[#reasons + 1] = string.format("%s is %s; required %s", tostring(violation.label or violation.key), tostring(violation.actual), tostring(violation.required))
					end
				end
				if #reasons == 0 then
					for _, reason in ipairs(audit.unsupported or { }) do
						if type(reason) == "string" and reason ~= "" then reasons[#reasons + 1] = reason end
					end
				end
				if #reasons == 0 then reasons[1] = "PoB could not certify the configured recurring activity" end
				return false, string.format("PoB activity ledger status %s: %s", tostring(audit.status or "unknown"), table.concat(reasons, "; "))
			end,
		})
		table.insert(checks, {
			name = "Native per-skill upfront and recurring costs",
			warningOnFailure = true,
			run = function()
				local snapshot, snapshotError = getSnapshot(build)
				if not snapshot then return false, snapshotError end
				local audit = snapshot.skillCostAudit
				if type(audit) ~= "table" or type(audit.skills) ~= "table" then
					return false, "PoB did not provide a structured per-skill resource-cost audit"
				end
				if audit.status == "pass" or audit.status == "not_required" then
					return true, string.format("Exact per-skill costs and native upfront-payability checks are available for %d enabled skills; the all-enabled-skills schedule estimates recurring resources only from explicit user rates and does not certify damage or uptime", tonumber(audit.auditedSkills) or 0)
				end
				local reasons = { }
				for _, violation in ipairs(audit.violations or { }) do
					local label = tostring(violation.skill or "Skill")
					local detail = violation.reason or violation.label or violation.resource
					if detail then reasons[#reasons + 1] = label .. ": " .. tostring(detail) end
					if #reasons >= 5 then break end
				end
				if #reasons == 0 then reasons[1] = audit.reason or table.concat(audit.unsupported or { "PoB could not certify every enabled skill cost" }, "; ") end
				return false, string.format("Per-skill cost audit status %s: %s", tostring(audit.status or "unknown"), table.concat(reasons, "; "))
			end,
		})
	end

	local check = checks[record.checkCursor]
	if not check then
		if record.suite == "optimizer_smoke" then
			-- No-op search has one exact evaluation and no route/gem mutation. The
			-- current Matrix point ceiling and PoB's native legal limit stay separate.
			local pointCount = build.spec:CountAllocNodes()
			local matrix, parseError = Inputs.Parse({
				maxAddedPoints = "0",
				maxTotalPoints = tostring(math.max(1, math.min(120, pointCount))),
				evaluationBudget = "1",
				objectiveMetric = "TotalEHP",
				seed = "19",
				scenarioProfile = "Current",
			})
			if not matrix then finishQASuite(record, "failed", parseError) return end
			if pointCount > matrix.search.maxTotalPoints then
				finishQASuite(record, "failed", "Active tree exceeds the strict 120-point optimizer ceiling used by this smoke suite")
				return
			end
			local validBuild, buildError = Inputs.ValidateBuild(build, matrix)
			if not validBuild then finishQASuite(record, "failed", buildError) return end
			local validTree, treeError = Inputs.ValidateAgainstTree(matrix, build.spec.tree)
			if not validTree then finishQASuite(record, "failed", treeError) return end
			local validObjective, objectiveError = Inputs.ValidateObjective(build, matrix)
			if not validObjective then finishQASuite(record, "failed", objectiveError) return end
			local output = build.calcsTab and build.calcsTab.mainOutput or { }
			if not isFinite(output.TotalEHP) then finishQASuite(record, "failed", "PoB did not expose finite TotalEHP for the no-op optimizer smoke") return end
			record.baselineTotalEHP = output.TotalEHP
			record.optimizerJob = PhantomSim.RunPhantomSim(build, matrix)
			record.phase = "exact_optimizer"
			return
		end
		local hasWarning = false
		for _, entry in ipairs(record.checks) do if entry.status == "warning" then hasWarning = true end end
		finishQASuite(record, hasWarning and "passed_with_warnings" or "passed")
		return
	end
	local ok, passed, detail = pcall(check.run)
	if not ok then
		appendQACheck(record, check.name, "fail", tostring(passed))
	elseif passed then
		appendQACheck(record, check.name, "pass", detail)
	else
		local warning = check.warningOnFailure or (record.suite == "planner" and check.name == "Selected Main Skill objective contract")
		appendQACheck(record, check.name, warning and "warning" or "fail", detail or "Check failed")
	end
	record.checkCursor = record.checkCursor + 1
end

local function startQASuite(params)
	local suite = params.suite
	if type(suite) ~= "string" or not qaSuiteNames[suite] then return nil, "suite must be one of integration, planner, build, or optimizer_smoke" end
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before starting local QA" end
	if qaIsRunning() then return nil, "A local QA suite is already running", "busy" end
	for _, job in pairs(bridge.progressionJobs or { }) do
		if job.status == "running" then return nil, "A read-only progression audit is running", "busy" end
	end
	for _, job in pairs(bridge.factorialJobs or { }) do
		if job.status == "running" then return nil, "A read-only factorial study is running", "busy" end
	end
	if suite == "optimizer_smoke" then
		local optimizerJob = build.optimizerTab and build.optimizerTab.job
		local classRootsJob = build.optimizerTab and build.optimizerTab.classRootJob
		if (optimizerJob and optimizerJob.status == "running") or (classRootsJob and classRootsJob.status == "running") then
			return nil, "Finish or cancel the current optimizer job before running the optimizer smoke suite", "busy"
		end
	end
	bridge.qaJobs = bridge.qaJobs or { }
	local count = 0
	for _ in pairs(bridge.qaJobs) do count = count + 1 end
	if count >= 8 then
		for jobId, record in pairs(bridge.qaJobs) do
			if record.status ~= "running" then
				bridge.qaJobs[jobId] = nil
				count = count - 1
				if count < 8 then break end
			end
		end
	end
	if count >= 8 then return nil, "The local QA history is full; wait for completed entries to be pruned", "busy" end
	bridge.nextQAJob = (bridge.nextQAJob or 0) + 1
	local jobId = "pob-qa-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextQAJob)
	bridge.qaJobs[jobId] = {
		jobId = jobId,
		suite = suite,
		status = "running",
		build = build,
		sourceSignature = Candidate.BuildSignature(build),
		checks = { },
		checkCursor = 1,
		startedAt = os.time(),
	}
	return { jobId = jobId, suite = suite, status = "running", readOnly = true, activeBuildPreserved = true }
end

local function progressionBusy(build)
	if qaIsRunning() then return "A local PoB QA suite is running" end
	for _, job in pairs(bridge.progressionJobs or { }) do
		if job.status == "running" then return "A progression audit is already running" end
	end
	for _, job in pairs(bridge.factorialJobs or { }) do
		if job.status == "running" then return "A factorial study is already running" end
	end
	local optimizerTab = build and build.optimizerTab
	if optimizerTab then
		if optimizerTab.job and optimizerTab.job.status == "running" then return "An optimizer job is already running" end
		if optimizerTab.classRootJob and optimizerTab.classRootJob.status == "running" then return "A class-root comparison is already running" end
	end
	return nil
end

local function startPassiveFactorialStudy(params)
	local allowed = {
		factorANodeId = true, factorBNodeId = true, label = true, studyId = true, comparisonId = true,
	}
	for key in pairs(params or { }) do
		if not allowed[key] then return nil, "Unsupported record_passive_factorial_experiment field: " .. tostring(key) end
	end
	local function validFactorNodeId(value, label)
		if not isFinite(value) or value < 1 or value ~= math.floor(value) or value > 2147483647 then
			return nil, label .. " must be a positive native PoB passive node ID"
		end
		return value
	end
	local factorANodeId, factorAError = validFactorNodeId(params.factorANodeId, "factorANodeId")
	if not factorANodeId then return nil, factorAError end
	local factorBNodeId, factorBError = validFactorNodeId(params.factorBNodeId, "factorBNodeId")
	if not factorBNodeId then return nil, factorBError end
	if factorANodeId == factorBNodeId then return nil, "factorA and factorB must be different passive nodes" end
	if params.label ~= nil and (type(params.label) ~= "string" or #params.label > 120 or params.label:find("[%c]")) then
		return nil, "label must be plain text of at most 120 characters"
	end
	local build, studySource = resolveStudyBuild(params)
	if not build then return nil, studySource end
	if not build.spec then return nil, "The selected PoB build has no passive tree to study" end
	local busyMessage = progressionBusy(currentBuild())
	if busyMessage then return nil, busyMessage, "busy" end
	local _, factorAValidationError = buildFactorialPassiveSpec(build, { factorANodeId })
	if factorAValidationError then return nil, "factorA is not a legal one-node addition: " .. factorAValidationError end
	local _, factorBValidationError = buildFactorialPassiveSpec(build, { factorBNodeId })
	if factorBValidationError then return nil, "factorB is not a legal one-node addition: " .. factorBValidationError end
	local _, combinedValidationError = buildFactorialPassiveSpec(build, { factorANodeId, factorBNodeId })
	if combinedValidationError then return nil, "combined cell is not a legal two-node addition: " .. combinedValidationError end
	local signatureOk, sourceSignature = pcall(Candidate.BuildSignature, build)
	if not signatureOk or type(sourceSignature) ~= "string" then
		return nil, "Could not fingerprint the selected source build for a read-only factorial study"
	end
	bridge.factorialJobs = bridge.factorialJobs or { }
	local jobCount = 0
	for jobId, job in pairs(bridge.factorialJobs) do
		jobCount = jobCount + 1
		if jobCount >= maxFactorialJobs and job.status ~= "running" then
			bridge.factorialJobs[jobId] = nil
			jobCount = jobCount - 1
		end
	end
	if jobCount >= maxFactorialJobs then return nil, "The factorial study history is full; wait for a completed study to be pruned", "busy" end
	bridge.nextFactorialJob = (bridge.nextFactorialJob or 0) + 1
	local jobId = "pob-factorial-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextFactorialJob)
	local sourceParams = { }
	if params.studyId ~= nil then sourceParams.studyId = params.studyId end
	if params.comparisonId ~= nil then sourceParams.comparisonId = params.comparisonId end
	local job = {
		jobId = jobId,
		build = build,
		activeBuild = currentBuild(),
		sourceParams = sourceParams,
		studySource = studySource,
		sourceSignature = sourceSignature,
		factorANodeId = factorANodeId,
		factorBNodeId = factorBNodeId,
		label = (params.label or ""):match("^%s*(.-)%s*$"),
		cells = { },
		completedCells = 0,
		status = "running",
		progress = { phase = "Queued", currentCell = "baseline", completedCells = 0, totalCells = 4 },
		startedAt = os.time(),
		readOnly = true,
		activeBuildPreserved = true,
	}
	job.thread = coroutine.create(runPassiveFactorialStudy)
	bridge.factorialJobs[jobId] = job
	return factorialJobSummary(job)
end

local function cancelPassiveFactorialStudy(params)
	for key in pairs(params or { }) do
		if key ~= "jobId" then return nil, "Unsupported record_passive_factorial_cancel field: " .. tostring(key) end
	end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then
		return nil, "jobId must be returned by record_passive_factorial_experiment"
	end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind == "skill_support" or job.studyKind == "skill_skill"
		or job.studyKind == "skill_item_slot" or job.studyKind == "passive_item_slot" then return nil, "Unknown passive factorial study job" end
	if job.status == "running" then
		job.cancelRequested = true
		job.status = "cancelled"
		job.completedAt = os.time()
		job.thread = nil
	end
	return factorialJobSummary(job)
end

local function getPassiveFactorialStudyStatus(params)
	for key in pairs(params or { }) do
		if key ~= "jobId" then return nil, "Unsupported record_passive_factorial_status field: " .. tostring(key) end
	end
	if type(params.jobId) ~= "string" or #params.jobId < 1 or #params.jobId > 96 then
		return nil, "jobId must be returned by record_passive_factorial_experiment"
	end
	local job = bridge.factorialJobs and bridge.factorialJobs[params.jobId]
	if not job or job.studyKind == "skill_support" or job.studyKind == "skill_skill"
		or job.studyKind == "skill_item_slot" or job.studyKind == "passive_item_slot" then return nil, "Unknown passive factorial study job" end
	return factorialJobSummary(job)
end

local function stepPassiveFactorialStudies()
	if qaIsRunning() then return end
	for _, job in pairs(bridge.progressionJobs or { }) do
		if job.status == "running" then return end
	end
	local active = currentBuild()
	if active and active.optimizerTab then
		local optimizerTab = active.optimizerTab
		if (optimizerTab.job and optimizerTab.job.status == "running")
			or (optimizerTab.classRootJob and optimizerTab.classRootJob.status == "running") then return end
	end
	for _, job in pairs(bridge.factorialJobs or { }) do
		if job.status == "running" then
			if job.cancelRequested then
				job.status = "cancelled"
				job.completedAt = os.time()
				job.thread = nil
				return
			end
		if active ~= job.activeBuild then
				job.status = "stale_build"
				job.error = "The active PoB build changed while the factorial study was yielding"
				job.completedAt = os.time()
				job.thread = nil
				return
			end
			local sourceBuild, sourceError = resolveStudyBuild(job.sourceParams)
			if sourceBuild ~= job.build then
				job.status = "stale_build"
				job.error = sourceError or "The selected comparison build changed while the factorial study was yielding"
				job.completedAt = os.time()
				job.thread = nil
				return
			end
			local signatureOk, signature = pcall(Candidate.BuildSignature, job.build)
			if not signatureOk or signature ~= job.sourceSignature then
				job.status = "stale_build"
				job.error = "The selected PoB source build changed while the factorial study was yielding"
				job.completedAt = os.time()
				job.thread = nil
				return
			end
			local ok, progress = coroutine.resume(job.thread, job)
			if not ok then
				job.status = "failed"
				job.error = boundedText(progress, 400)
				job.completedAt = os.time()
			elseif coroutine.status(job.thread) == "dead" and job.status == "running" then
				job.status = "completed"
				job.completedAt = os.time()
			else
				job.progress = progress or job.progress
			end
			return
		end
	end
end

local function startProgressionAudit(params)
	for key in pairs(params or { }) do
		if key ~= "stages" and key ~= "baseClassId" then return nil, "Unsupported progression_start field: " .. tostring(key) end
	end
	if params.baseClassId ~= nil and (type(params.baseClassId) ~= "number" or params.baseClassId ~= math.floor(params.baseClassId)
		or params.baseClassId < 1 or params.baseClassId > 2147483647) then
		return nil, "baseClassId must be a positive integer from the native progression_options class list"
	end
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before auditing progression loadouts" end
	local busyMessage = progressionBusy(build)
	if busyMessage then return nil, busyMessage, "busy" end
	bridge.progressionJobs = bridge.progressionJobs or { }
	local count = 0
	for jobId, job in pairs(bridge.progressionJobs) do
		count = count + 1
		if count >= 8 and job.status ~= "running" then bridge.progressionJobs[jobId] = nil count = count - 1 end
	end
	if count >= 8 then return nil, "The progression audit history is full; wait for an entry to finish", "busy" end
	bridge.nextProgressionJob = (bridge.nextProgressionJob or 0) + 1
	local jobId = "pob-progression-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextProgressionJob)
	local job, startError = Progression.Start(build, params.stages, jobId, params.baseClassId)
	if not job then return nil, startError end
	bridge.progressionJobs[jobId] = job
	return Progression.Summary(job)
end

local function startProgressionComparison(params)
	for key in pairs(params or { }) do
		if key ~= "plans" and key ~= "objective" and key ~= "baseClassId" then
			return nil, "Unsupported progression_compare field: " .. tostring(key)
		end
	end
	if params.baseClassId ~= nil and (type(params.baseClassId) ~= "number" or params.baseClassId ~= math.floor(params.baseClassId)
		or params.baseClassId < 1 or params.baseClassId > 2147483647) then
		return nil, "baseClassId must be a positive integer from the native progression_options class list"
	end
	if type(params.objective) ~= "string" or not Inputs.objectives[params.objective] then
		return nil, "objective must be one of the supported exact PoB progression objectives"
	end
	local build = currentBuild()
	if not build then return nil, "Open a PoB build before comparing campaign proposals" end
	local busyMessage = progressionBusy(build)
	if busyMessage then return nil, busyMessage, "busy" end
	bridge.progressionJobs = bridge.progressionJobs or { }
	local count = 0
	for jobId, job in pairs(bridge.progressionJobs) do
		count = count + 1
		if count >= 8 and job.status ~= "running" then bridge.progressionJobs[jobId] = nil count = count - 1 end
	end
	if count >= 8 then return nil, "The progression audit history is full; wait for an entry to finish", "busy" end
	bridge.nextProgressionJob = (bridge.nextProgressionJob or 0) + 1
	local jobId = "pob-progression-compare-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextProgressionJob)
	local job, startError = Progression.StartComparison(build, params.plans, params.objective, jobId, params.baseClassId)
	if not job then return nil, startError end
	bridge.progressionJobs[jobId] = job
	return Progression.Summary(job)
end

local function stepProgressionJobs()
	for _, job in pairs(bridge.progressionJobs or { }) do
		if job.status == "running" then
			Progression.Step(job, currentBuild())
			-- One exact stage calculation is the maximum work for one completed UI frame.
			return
		end
	end
end

local function runQASuiteStep()
	for jobId, record in pairs(bridge.qaJobs or { }) do
		if record.status == "running" then
			local ok, err = pcall(runQAStep, record)
			if not ok then finishQASuite(record, "failed", "QA suite raised an error: " .. tostring(err)) end
			-- Keep one bounded QA unit per frame; the optimizer coroutine itself
			-- yields after one pathfinding slice or exact PoB calculation.
			return
		end
	end
end

local function writeHealthFile(self)
	if not self.healthPath then return end
	local now = socket.gettime()
	if now - (self.lastHealthWrite or 0) < 0.5 then return end
	self.lastHealthWrite = now
	local contents = json.encode({
		protocol = "pob-mcp-health-1",
		snapshotContractVersion = snapshotContractVersion,
		instanceId = self.instanceId,
		port = self.port,
		state = self.listener and "running" or "stopped",
		pollCount = self.pollCount or 0,
		frameCount = self.frameCount or 0,
		timestampMs = math.floor(now * 1000),
	})
	local ok = pcall(function()
		local file = io.open(self.healthPath, "w")
		if not file then return end
		file:write(contents)
		file:close()
	end)
	if not ok then self.healthWriteFailed = true end
end

local function writeEndpointFile(self, destination)
	if not self.listener or not self.port or not self.token or not self.instanceId or not destination then
		return false, "The authenticated MCP listener is not ready"
	end
	local encoded, encodeError = json.encode({
		host = "127.0.0.1",
		port = self.port,
		token = self.token,
		protocol = "pob-mcp-1",
		instanceId = self.instanceId,
	})
	if type(encoded) ~= "string" then return false, tostring(encodeError or "Could not encode MCP endpoint metadata") end
	local file, fileError = io.open(destination, "wb")
	if not file then return false, tostring(fileError or "Could not write MCP endpoint metadata") end
	local wrote, writeError = file:write(encoded)
	local closed, closeError = file:close()
	if not wrote or not closed then
		return false, tostring(writeError or closeError or "Could not complete MCP endpoint metadata write")
	end
	return true
end

local function ensureEndpointPublished(self)
	if not self.listener or not self.endpointPath then return end
	local now = socket.gettime()
	if now < (self.nextEndpointPublishCheck or 0) then return end
	self.nextEndpointPublishCheck = now + 5
	local existing = io.open(self.endpointPath, "rb")
	if existing then
		existing:close()
		return
	end
	local temporaryPath = self.endpointPath .. ".tmp"
	local published = writeEndpointFile(self, temporaryPath)
	if not published then
		pcall(os.remove, temporaryPath)
		return
	end
	local moved = os.rename(temporaryPath, self.endpointPath)
	if not moved then pcall(os.remove, temporaryPath) end
end

local function searchLocalKnowledge(params)
	for key in pairs(params) do
		if key ~= "query" and key ~= "knowledgeScope" then
			return nil, "Unsupported search_local_knowledge field: " .. tostring(key)
		end
	end
	if type(params.query) ~= "string" or params.query == "" or #params.query > KnowledgeRegistry.MAX_QUERY_BYTES then
		return nil, "query must be non-empty text up to " .. tostring(KnowledgeRegistry.MAX_QUERY_BYTES) .. " bytes"
	end
	local selectedScope = params.knowledgeScope
	if type(selectedScope) ~= "string" then return nil, "knowledgeScope is required" end
	local allowlistedScope = false
	for _, source in ipairs(KnowledgeRegistry.ListSources()) do
		if source.knowledgeScope == selectedScope then allowlistedScope = true break end
	end
	if not allowlistedScope then return nil, "knowledgeScope is not in the local PoE 1 documentation allowlist" end
	local build = currentBuild()
	if not build then
		return { status = "blocked", results = { }, reason = "active_build_required", readOnly = true, modelUsed = false }
	end
	local context = {
		game = "poe1",
		patch = Version.Data(build),
		engine = Version.Snapshot(build),
		knowledgeScope = selectedScope,
		usageScope = "local_retrieval",
	}
	return KnowledgeRegistry.Search(params.query, context)
end

local studyMethodHandlers = {
	import_build_url = function(params) return beginStudyImport(params) end,
	list_study_records = function(params) return listStudyRecords(params) end,
	export_study_dataset = function() return exportStudyDataset() end,
	get_study_record = function(params) return getStudyRecord(params) end,
	delete_study_record = deleteStudyRecord,
	prune_study_records = pruneStudyRecords,
	get_synergy_graph = function(params) return getSynergyGraph(params) end,
	search_local_knowledge = searchLocalKnowledge,
	list_active_skills = function(params)
		for key in pairs(params) do
			if key ~= "studyId" and key ~= "comparisonId" then return nil, "Unsupported list_active_skills field: " .. tostring(key) end
		end
		local build, sourceOrError = resolveStudyBuild(params)
		if not build then return nil, sourceOrError end
		local source = sourceOrError
		return {
			mainSocketGroup = build.mainSocketGroup, skills = getActiveSkills(build), skillGroups = getSkillGroups(build),
			isActiveBuild = build == currentBuild(), buildReference = experimentSource(source),
			readOnly = build ~= currentBuild(),
		}
	end,
	record_passive_support_factorial_experiment = function(params) return startPassiveSupportFactorialStudy(params) end,
	record_passive_support_factorial_status = function(params) return getPassiveSupportFactorialStudyStatus(params) end,
	record_passive_support_factorial_cancel = function(params) return cancelPassiveSupportFactorialStudy(params) end,
	record_skill_skill_factorial_experiment = function(params) return startSkillSkillFactorialStudy(params) end,
	record_skill_skill_factorial_status = function(params) return getSkillSkillFactorialStudyStatus(params) end,
	record_skill_skill_factorial_cancel = function(params) return cancelSkillSkillFactorialStudy(params) end,
}

local function getOperationCapabilities()
	return {
		contractVersion = 1,
		passiveSupportFactorial = {
			start = type(studyMethodHandlers.record_passive_support_factorial_experiment) == "function",
			status = type(studyMethodHandlers.record_passive_support_factorial_status) == "function",
			cancel = type(studyMethodHandlers.record_passive_support_factorial_cancel) == "function",
		},
		skillSkillFactorial = {
			start = type(studyMethodHandlers.record_skill_skill_factorial_experiment) == "function",
			status = type(studyMethodHandlers.record_skill_skill_factorial_status) == "function",
			cancel = type(studyMethodHandlers.record_skill_skill_factorial_cancel) == "function",
		},
	}
end

local executeDependencies = {
	analyzeComparisonSkill = analyzeComparisonSkill,
	applyGemVariant = applyGemVariant,
	applyPassiveDelta = applyPassiveDelta,
	boundedText = boundedText,
	bridge = bridge,
	cancelPassiveFactorialStudy = cancelPassiveFactorialStudy,
	cancelPassiveItemSlotFactorialStudy = cancelPassiveItemSlotFactorialStudy,
	cancelSkillItemSlotFactorialStudy = cancelSkillItemSlotFactorialStudy,
	cancelSkillSupportFactorialStudy = cancelSkillSupportFactorialStudy,
	Candidate = Candidate,
	candidateSummary = candidateSummary,
	CatalogCoverage = CatalogCoverage,
	classRootsSummary = classRootsSummary,
	copyFiniteMetrics = copyFiniteMetrics,
	createOptimizerSkillSeed = createOptimizerSkillSeed,
	currentBuild = currentBuild,
	equipExistingItem = equipExistingItem,
	evaluateActivitySchedule = evaluateActivitySchedule,
	evaluateGemSwap = evaluateGemSwap,
	evaluateItemSwap = evaluateItemSwap,
	evaluateMasteryExperiment = evaluateMasteryExperiment,
	evaluatePassiveDelta = evaluatePassiveDelta,
	expireStudyImport = expireStudyImport,
	findJob = findJob,
	finishQASuite = finishQASuite,
	getComparisonBuildSnapshot = getComparisonBuildSnapshot,
	getOperationCapabilities = getOperationCapabilities,
	getPassiveFactorialStudyStatus = getPassiveFactorialStudyStatus,
	getPassiveItemSlotFactorialStudyStatus = getPassiveItemSlotFactorialStudyStatus,
	getPassiveNode = getPassiveNode,
	getSkillItemSlotFactorialStudyStatus = getSkillItemSlotFactorialStudyStatus,
	getSkillSupportFactorialStudyStatus = getSkillSupportFactorialStudyStatus,
	getSnapshot = getSnapshot,
	Inputs = Inputs,
	isFinite = isFinite,
	jsonSafeCopy = jsonSafeCopy,
	listComparisonBuilds = listComparisonBuilds,
	maxJobs = maxJobs,
	metricDelta = metricDelta,
	Progression = Progression,
	progressionBusy = progressionBusy,
	qaSummary = qaSummary,
	resolveBuildReference = resolveBuildReference,
	searchPassiveNodes = searchPassiveNodes,
	selectClassAscendancy = selectClassAscendancy,
	selectMainSkill = selectMainSkill,
	setBuildLevel = setBuildLevel,
	setConfigOptions = setConfigOptions,
	SkillCatalog = SkillCatalog,
	skillName = skillName,
	startPassiveFactorialStudy = startPassiveFactorialStudy,
	startPassiveItemSlotFactorialStudy = startPassiveItemSlotFactorialStudy,
	startProgressionAudit = startProgressionAudit,
	startProgressionComparison = startProgressionComparison,
	startQASuite = startQASuite,
	startSkillItemSlotFactorialStudy = startSkillItemSlotFactorialStudy,
	startSkillSupportFactorialStudy = startSkillSupportFactorialStudy,
	studyBuildIndex = studyBuildIndex,
	StudyBuilds = StudyBuilds,
	studyMethodHandlers = studyMethodHandlers,
	trimJobHistory = trimJobHistory,
	Version = Version,
}

local function execute(method, params)
	local analyzeComparisonSkill = executeDependencies.analyzeComparisonSkill
	local applyGemVariant = executeDependencies.applyGemVariant
	local applyPassiveDelta = executeDependencies.applyPassiveDelta
	local boundedText = executeDependencies.boundedText
	local bridge = executeDependencies.bridge
	local cancelPassiveFactorialStudy = executeDependencies.cancelPassiveFactorialStudy
	local cancelPassiveItemSlotFactorialStudy = executeDependencies.cancelPassiveItemSlotFactorialStudy
	local cancelSkillItemSlotFactorialStudy = executeDependencies.cancelSkillItemSlotFactorialStudy
	local cancelSkillSupportFactorialStudy = executeDependencies.cancelSkillSupportFactorialStudy
	local Candidate = executeDependencies.Candidate
	local candidateSummary = executeDependencies.candidateSummary
	local CatalogCoverage = executeDependencies.CatalogCoverage
	local classRootsSummary = executeDependencies.classRootsSummary
	local copyFiniteMetrics = executeDependencies.copyFiniteMetrics
	local createOptimizerSkillSeed = executeDependencies.createOptimizerSkillSeed
	local currentBuild = executeDependencies.currentBuild
	local equipExistingItem = executeDependencies.equipExistingItem
	local evaluateActivitySchedule = executeDependencies.evaluateActivitySchedule
	local evaluateGemSwap = executeDependencies.evaluateGemSwap
	local evaluateItemSwap = executeDependencies.evaluateItemSwap
	local evaluateMasteryExperiment = executeDependencies.evaluateMasteryExperiment
	local evaluatePassiveDelta = executeDependencies.evaluatePassiveDelta
	local expireStudyImport = executeDependencies.expireStudyImport
	local findJob = executeDependencies.findJob
	local finishQASuite = executeDependencies.finishQASuite
	local getComparisonBuildSnapshot = executeDependencies.getComparisonBuildSnapshot
	local getOperationCapabilities = executeDependencies.getOperationCapabilities
	local getPassiveFactorialStudyStatus = executeDependencies.getPassiveFactorialStudyStatus
	local getPassiveItemSlotFactorialStudyStatus = executeDependencies.getPassiveItemSlotFactorialStudyStatus
	local getPassiveNode = executeDependencies.getPassiveNode
	local getSkillItemSlotFactorialStudyStatus = executeDependencies.getSkillItemSlotFactorialStudyStatus
	local getSkillSupportFactorialStudyStatus = executeDependencies.getSkillSupportFactorialStudyStatus
	local getSnapshot = executeDependencies.getSnapshot
	local Inputs = executeDependencies.Inputs
	local isFinite = executeDependencies.isFinite
	local jsonSafeCopy = executeDependencies.jsonSafeCopy
	local listComparisonBuilds = executeDependencies.listComparisonBuilds
	local maxJobs = executeDependencies.maxJobs
	local metricDelta = executeDependencies.metricDelta
	local Progression = executeDependencies.Progression
	local progressionBusy = executeDependencies.progressionBusy
	local qaSummary = executeDependencies.qaSummary
	local resolveBuildReference = executeDependencies.resolveBuildReference
	local searchPassiveNodes = executeDependencies.searchPassiveNodes
	local selectClassAscendancy = executeDependencies.selectClassAscendancy
	local selectMainSkill = executeDependencies.selectMainSkill
	local setBuildLevel = executeDependencies.setBuildLevel
	local setConfigOptions = executeDependencies.setConfigOptions
	local SkillCatalog = executeDependencies.SkillCatalog
	local skillName = executeDependencies.skillName
	local startPassiveFactorialStudy = executeDependencies.startPassiveFactorialStudy
	local startPassiveItemSlotFactorialStudy = executeDependencies.startPassiveItemSlotFactorialStudy
	local startProgressionAudit = executeDependencies.startProgressionAudit
	local startProgressionComparison = executeDependencies.startProgressionComparison
	local startQASuite = executeDependencies.startQASuite
	local startSkillItemSlotFactorialStudy = executeDependencies.startSkillItemSlotFactorialStudy
	local startSkillSupportFactorialStudy = executeDependencies.startSkillSupportFactorialStudy
	local studyBuildIndex = executeDependencies.studyBuildIndex
	local StudyBuilds = executeDependencies.StudyBuilds
	local studyMethodHandlers = executeDependencies.studyMethodHandlers
	local trimJobHistory = executeDependencies.trimJobHistory
	local Version = executeDependencies.Version
	params = type(params) == "table" and params or { }
	local studyHandler = studyMethodHandlers[method]
	if studyHandler then return studyHandler(params) end
	if method == "ping" then
		return {
			connected = true,
			app = "Path of Building Community Fork",
			protocol = "pob-mcp-1",
			buildOpen = currentBuild() ~= nil,
			operationCapabilities = getOperationCapabilities(),
		}
	elseif method == "connection_health" then
		return bridge:GetConnectionHealth()
	elseif method == "prepare_ask_ai_qa" then
		if not currentBuild() then return nil, "Open a PoB build before preparing Ask AI QA" end
		if not main.optimizerAI then return nil, "The native Ask AI client is unavailable" end
		return main.optimizerAI:PrepareQA()
	elseif method == "qa_start" then
		return startQASuite(params)
	elseif method == "qa_status" then
		local record = bridge.qaJobs and bridge.qaJobs[params.jobId]
		if not record then return nil, "Unknown local QA job" end
		return qaSummary(params.jobId, record)
	elseif method == "qa_cancel" then
		local record = bridge.qaJobs and bridge.qaJobs[params.jobId]
		if not record then return nil, "Unknown local QA job" end
		if record.status == "running" then
			if record.optimizerJob and record.optimizerJob.status == "running" then
				record.optimizerJob:Cancel()
				record.cancelRequested = true
			else
				finishQASuite(record, "cancelled")
			end
		end
		local summary = qaSummary(params.jobId, record)
		if record.cancelRequested then summary.status = "cancellation_requested" end
		return summary
	elseif method == "get_build_snapshot" then
		return getSnapshot()
	elseif method == "list_comparison_builds" then
		return listComparisonBuilds()
	elseif method == "get_comparison_build_snapshot" then
		return getComparisonBuildSnapshot(params)
	elseif method == "analyze_comparison_skill" then
		return analyzeComparisonSkill(params)
	elseif method == "skill_catalog_coverage" then
		if next(params) ~= nil then return nil, "skill_catalog_coverage does not accept arguments" end
		local build = currentBuild()
		if not build then return nil, "Open a PoB build to inspect its loaded skill catalog" end
		local summary, summaryError = SkillCatalog.Summary(build)
		if not summary then return nil, summaryError or "The loaded PoE1 skill catalog summary is unavailable" end
		return {
			status = "catalog_only",
			exactEvaluated = false,
			readOnly = true,
			game = summary.game,
			source = summary.source,
			dataVersion = summary.dataVersion or (summary.version and summary.version.dataVersion),
			treeVersion = summary.treeVersion or (summary.version and summary.version.treeVersion),
			pobVersion = summary.pobVersion or (summary.version and summary.version.pobVersion),
			counts = summary.counts,
		}
	elseif method == "export_skill_catalog_coverage" then
		if next(params) ~= nil then return nil, "export_skill_catalog_coverage does not accept arguments" end
		local build = currentBuild()
		if not build then return nil, "Open a PoB build to export its loaded skill catalog" end
		return CatalogCoverage.Export(main and main.userPath, build, MakeDir)
	elseif method == "progression_options" then
		return Progression.ListOptions(currentBuild())
	elseif method == "progression_generate" then
		local build = currentBuild()
		for key in pairs(params or { }) do
			if key ~= "treeSpecIndex" then return nil, "Unsupported progression_generate field: " .. tostring(key) end
		end
		if params.treeSpecIndex ~= nil and (type(params.treeSpecIndex) ~= "number"
			or params.treeSpecIndex ~= math.floor(params.treeSpecIndex) or params.treeSpecIndex < 1) then
			return nil, "treeSpecIndex must be a positive native PoB tree-spec index"
		end
		return Progression.GenerateStages(build, params.treeSpecIndex)
	elseif method == "progression_start" then
		return startProgressionAudit(params)
	elseif method == "progression_compare" then
		return startProgressionComparison(params)
	elseif method == "progression_status" then
		local job = bridge.progressionJobs and bridge.progressionJobs[params.jobId]
		if not job then return nil, "Unknown progression audit job" end
		return Progression.Summary(job)
	elseif method == "progression_cancel" then
		local job = bridge.progressionJobs and bridge.progressionJobs[params.jobId]
		if not job then return nil, "Unknown progression audit job" end
		if not Progression.Cancel(job) then return Progression.Summary(job) end
		local summary = Progression.Summary(job)
		summary.cancelRequested = true
		return summary
	elseif method == "import_build_status" then
		local record = bridge.studyJobs and bridge.studyJobs[params.jobId]
		if not record then return nil, "Unknown public build import job" end
		expireStudyImport(record)
		return {
			jobId = record.jobId,
			status = record.status,
			provider = record.provider,
			label = record.label,
			studyId = record.studyId,
			claimedLeague = record.claimedLeague,
			archiveStatus = record.archive and record.archive.storageStatus or nil,
			archiveObservationId = record.archive and record.archive.observationId or nil,
			buildReviewStatus = record.archive and record.archive.buildReview and record.archive.buildReview.status or "pending",
			buildReviewHypotheses = record.archive and record.archive.buildReview and record.archive.buildReview.hypothesisCount or 0,
			buildReviewChallenges = record.archive and record.archive.buildReview and record.archive.buildReview.challengeCount or 0,
			error = record.error,
			activeBuildPreserved = true,
		}
	elseif method == "get_study_build_snapshot" then
		local record = bridge.studyBuilds and bridge.studyBuilds[params.studyId]
		if not record then return nil, "Unknown public build study" end
		if not studyBuildIndex(record.compareTab, record.entry) then
			bridge.studyBuilds[params.studyId] = nil
			return nil, "The comparison entry was removed from PoB"
		end
		local snapshot, snapshotError = getSnapshot(record.entry)
		if not snapshot then return nil, snapshotError end
		snapshot.isActiveBuild = false
		snapshot.study = {
			id = record.id,
			label = record.label,
			provider = record.provider,
			sourceUrlRedacted = type(record.url) == "string" and record.url ~= "",
			importedAt = record.importedAt,
			claimedLeague = record.claimedLeague,
			archive = record.archive and {
				observationId = record.archive.observationId,
				xmlSha256 = record.archive.xmlSha256,
				lineageSha256 = record.archive.lineageSha256,
				relativeRoot = record.archive.relativeRoot,
				configuredEffectCount = record.archive.configuredEffectCount,
				availableEffectCount = record.archive.availableEffectCount,
				trainingStatus = record.archive.trainingStatus,
				buildReviewStatus = record.archive.buildReview and record.archive.buildReview.status or "pending",
				buildReviewHypotheses = record.archive.buildReview and record.archive.buildReview.hypothesisCount or 0,
				buildReviewChallenges = record.archive.buildReview and record.archive.buildReview.challengeCount or 0,
			} or nil,
		}
		return snapshot
	elseif method == "remove_study_build" then
		local record = bridge.studyBuilds and bridge.studyBuilds[params.studyId]
		if not record then return nil, "Unknown public build study" end
		local index = studyBuildIndex(record.compareTab, record.entry)
		if not index then
			bridge.studyBuilds[params.studyId] = nil
			return { studyId = params.studyId, removed = false, message = "The comparison entry was already removed from PoB" }
		end
		record.compareTab:RemoveBuild(index)
		bridge.studyBuilds[params.studyId] = nil
		for _, optimizerRecord in pairs(bridge.jobs or { }) do
			if optimizerRecord.kind == "optimizer_study" and optimizerRecord.studyId == params.studyId
				and optimizerRecord.job and optimizerRecord.job.status == "running" then
				optimizerRecord.staleError = "The imported study was removed while optimization was running; no result can be applied."
				optimizerRecord.job:Cancel()
			end
		end
		return { studyId = params.studyId, removed = true, activeBuildPreserved = true }
	elseif method == "get_passive_node" then
		return getPassiveNode(params)
	elseif method == "search_passive_nodes" then
		return searchPassiveNodes(params)
	elseif method == "evaluate_passive_delta" then
		return evaluatePassiveDelta(params)
	elseif method == "record_passive_experiment" then
		return evaluatePassiveDelta(params, true)
	elseif method == "record_passive_factorial_experiment" then
		return startPassiveFactorialStudy(params)
	elseif method == "record_passive_factorial_status" then
		return getPassiveFactorialStudyStatus(params)
	elseif method == "record_passive_factorial_cancel" then
		return cancelPassiveFactorialStudy(params)
	elseif method == "record_skill_support_factorial_experiment" then
		return startSkillSupportFactorialStudy(params)
	elseif method == "record_skill_support_factorial_status" then
		return getSkillSupportFactorialStudyStatus(params)
	elseif method == "record_skill_support_factorial_cancel" then
		return cancelSkillSupportFactorialStudy(params)
	elseif method == "record_skill_item_slot_factorial_experiment" then
		return startSkillItemSlotFactorialStudy(params)
	elseif method == "record_skill_item_slot_factorial_status" then
		return getSkillItemSlotFactorialStudyStatus(params)
	elseif method == "record_skill_item_slot_factorial_cancel" then
		return cancelSkillItemSlotFactorialStudy(params)
	elseif method == "record_passive_item_slot_factorial_experiment" then
		return startPassiveItemSlotFactorialStudy(params)
	elseif method == "record_passive_item_slot_factorial_status" then
		return getPassiveItemSlotFactorialStudyStatus(params)
	elseif method == "record_passive_item_slot_factorial_cancel" then
		return cancelPassiveItemSlotFactorialStudy(params)
	elseif method == "record_gem_experiment" then
		return evaluateGemSwap(params, true)
	elseif method == "record_mastery_experiment" then
		return evaluateMasteryExperiment(params)
	elseif method == "record_item_experiment" then
		return evaluateItemSwap(params, true)
	elseif method == "apply_passive_delta" then
		return applyPassiveDelta(params)
	elseif method == "evaluate_item_swap" then
		return evaluateItemSwap(params)
	elseif method == "evaluate_activity_schedule" then
		return evaluateActivitySchedule(params)
	elseif method == "evaluate_gem_swap" then
		return evaluateGemSwap(params)
	elseif method == "apply_gem_variant" then
		return applyGemVariant(params)
	elseif method == "list_optimizer_skill_gems" then
		local build = currentBuild()
		if not build then return nil, "Open a PoB build to search its loaded active-skill gem database" end
		local query = tostring(params.query or ""):gsub("^%s*(.-)%s*$", "%1")
		if #query < 2 or #query > 100 or query:find("[%c]") then
			return nil, "Gem search query must contain 2 to 100 printable characters"
		end
		local limit = tonumber(params.limit) or 40
		if limit ~= math.floor(limit) or limit < 1 or limit > 100 then
			return nil, "Gem search result limit must be an integer from 1 to 100"
		end
		local groupIndex, skillIndex = tonumber(params.groupIndex), tonumber(params.skillIndex)
		if (groupIndex == nil) ~= (skillIndex == nil) then
			return nil, "groupIndex and skillIndex must be supplied together from pob.list_active_skills"
		end
		if groupIndex and (groupIndex < 1 or groupIndex ~= math.floor(groupIndex)
			or skillIndex < 1 or skillIndex ~= math.floor(skillIndex)) then
			return nil, "groupIndex and skillIndex must be positive integers from pob.list_active_skills"
		end
		local result, catalogError = SkillCatalog.ListActive(build, query, limit)
		if not result then return nil, catalogError end
		if groupIndex then
			for _, gem in ipairs(result.gems) do
				local variant, compatibilityError = SkillCatalog.ResolveTarget(build, groupIndex, skillIndex, gem.id)
				gem.socketCompatible = variant ~= nil
				if not gem.socketCompatible then gem.socketReason = compatibilityError end
			end
			result.socketGroupIndex = groupIndex
			result.activeSkillIndex = skillIndex
		end
		return result
	elseif method == "set_build_level" then
		return setBuildLevel(params)
	elseif method == "select_main_skill" then
		return selectMainSkill(params)
	elseif method == "create_optimizer_skill_seed" then
		return createOptimizerSkillSeed(params)
	elseif method == "set_config_options" then
		return setConfigOptions(params)
	elseif method == "equip_existing_item" then
		return equipExistingItem(params)
	elseif method == "select_class_ascendancy" then
		return selectClassAscendancy(params)
	elseif method == "get_pending_ai_request" then
		return bridge:GetPendingUserRequest()
	elseif method == "complete_ai_request" then
		return bridge:CompleteUserRequest(params.requestId, params.status, params.message)
	elseif method == "class_roots_start" then
		local build = currentBuild()
		if not build then return nil, "Open a PoB build before comparing class roots" end
		local progressionConflict = progressionBusy(build)
		if progressionConflict then return nil, progressionConflict, "busy" end
		if bridge.activeJobId and findJob(bridge.activeJobId) and findJob(bridge.activeJobId).job.status == "running" then
			return nil, "An optimizer job is already running", "busy"
		end
		if bridge.activeClassRootsJobId then
			local existing = bridge.jobs and bridge.jobs[bridge.activeClassRootsJobId]
			if existing and existing.job.status == "running" then return nil, "A class-root comparison is already running", "busy" end
		end
		if not trimJobHistory(maxJobs - 1) then return nil, "The local job history is full of running jobs", "busy" end
		local ok, jobOrError = build.optimizerTab:StartClassRootComparison()
		if not ok then return nil, jobOrError end
		bridge.nextJob = (bridge.nextJob or 0) + 1
		local jobId = "pob-roots-" .. tostring(os.time()) .. "-" .. tostring(bridge.nextJob)
		bridge.jobs[jobId] = { job = jobOrError, build = build, kind = "class_roots" }
		bridge.activeClassRootsJobId = jobId
		return { jobId = jobId, status = "running", exactEngine = true, rootOnly = true }
	elseif method == "class_roots_status" then
		local record = findJob(params.jobId)
		if not record or record.kind ~= "class_roots" then return nil, "Unknown class-root comparison job" end
		local build = currentBuild()
		if not build or build ~= record.build then return nil, "The active PoB build changed during class-root comparison" end
		return classRootsSummary(params.jobId, record)
	elseif method == "class_roots_cancel" then
		local record = findJob(params.jobId)
		if not record or record.kind ~= "class_roots" then return nil, "Unknown class-root comparison job" end
		record.job:Cancel()
		return { jobId = params.jobId, status = "cancellation_requested" }
	elseif method == "optimizer_start" then
		for key in pairs(params) do
			if key ~= "matrix" and key ~= "studyId" then return nil, "Unsupported optimizer_start field: " .. tostring(key) end
		end
		if type(params.matrix) ~= "table" then return nil, "matrix must be an object of typed optimizer inputs" end
		if params.studyId ~= nil and (type(params.studyId) ~= "string" or #params.studyId < 1 or #params.studyId > 96) then
			return nil, "studyId must be a valid imported build study ID"
		end
		local activeBuild = currentBuild()
		if not activeBuild then return nil, "Open a PoB build to start optimization" end
		local build, studyRecord = activeBuild, nil
		if params.studyId then
			local resolved, reference = resolveBuildReference(params.studyId, "start isolated optimization")
			if not resolved then return nil, reference end
			build, studyRecord = resolved, reference
		end
		local progressionConflict = progressionBusy(activeBuild)
		if progressionConflict then return nil, progressionConflict, "busy" end
		if bridge.activeJobId and findJob(bridge.activeJobId) and findJob(bridge.activeJobId).job.status == "running" then
			return nil, "An optimizer job is already running", "busy"
		end
		for _, existing in pairs(bridge.jobs or { }) do
			if existing.kind == "optimizer_study" and existing.job and existing.job.status == "running" then
				return nil, "An isolated build-study optimizer job is already running", "busy"
			end
		end
		local activeTab = activeBuild.optimizerTab
		if not activeTab then return nil, "The active PoB build has no initialized AI Planner tab" end
		if activeTab.job and activeTab.job.status == "running" then return nil, "An optimizer job is already running", "busy" end
		if activeTab.classRootJob and activeTab.classRootJob.status == "running" then return nil, "A class-root comparison is already running", "busy" end
		if not trimJobHistory(maxJobs - 1) then return nil, "The local job history is full of running jobs", "busy" end
		local worker, control = activeTab, nil
		local activeSignature
		if studyRecord then
			if type(activeTab.CreateIsolatedStudyWorker) ~= "function" then
				return nil, "This PoB AI Planner version cannot create an isolated study optimizer worker"
			end
			worker, progressionConflict = activeTab:CreateIsolatedStudyWorker(build)
			if not worker then return nil, progressionConflict end
			control = { cancelled = false, isolatedStudy = true, recordPathLearning = true }
			activeSignature = Candidate.BuildSignature(activeBuild)
		end
		local targetTab = worker
		-- optimizer_start is a typed API request, not an implicit submission of
		-- the UI's last-saved Matrix. A sparse request must not inherit stale hard
		-- gates (for example, a previous conversion route) from that UI state.
		local ok, jobOrError = worker:StartOptimizer(params.matrix, control, { resetUnspecifiedMatrixFields = true })
		if not ok then return nil, jobOrError end
		local routeMemory = bridge.importedRouteMemorySummary(targetTab.nodeEvidence)
		bridge.nextJob = (bridge.nextJob or 0) + 1
		local jobId = (studyRecord and "pob-study-" or "pob-") .. tostring(os.time()) .. "-" .. tostring(bridge.nextJob)
		local jobRecord = { job = jobOrError, tab = targetTab, build = build, kind = studyRecord and "optimizer_study" or "optimizer",
			importedRouteMemory = routeMemory }
		if studyRecord then
			jobRecord.studyId = params.studyId
			jobRecord.studyRecord = studyRecord
			jobRecord.sourceSignature = Candidate.BuildSignature(build)
			jobRecord.activeBuild = activeBuild
			jobRecord.activeSignature = activeSignature
			jobRecord.nextFreshnessCheck = 0
			bridge.jobs[jobId] = jobRecord
			return {
				jobId = jobId, status = "running", exactEngine = true, isolatedStudyReadOnly = true,
				importedRouteMemory = routeMemory,
				sourceBuild = { type = "public_build_study", studyId = params.studyId, label = boundedText(studyRecord.label or "Imported build", 120) },
			}
		end
		bridge.jobs[jobId] = jobRecord
		bridge.activeJobId = jobId
		return { jobId = jobId, status = "running", exactEngine = true, isolatedStudyReadOnly = false,
			importedRouteMemory = routeMemory, sourceBuild = { type = "active_build" } }
	elseif method == "optimizer_status" then
		local record = findJob(params.jobId)
		if not record then return nil, "Unknown optimizer job" end
		local job = record.job
		local result = job.result
		local summary = {
			jobId = params.jobId,
			status = record.staleError and "stale_build" or job.status,
			progress = job.progress,
			evaluations = result and result.evaluations or nil,
			message = result and result.message or job.error,
			scenarioProfile = result and result.scenarioProfile or nil,
			scenario = result and (result.scenario or (result.evaluation and result.evaluation.scenario)) or nil,
			searchCoverage = result and result.searchCoverage or nil,
			ranking = result and result.ranking or nil,
			importedRouteMemory = record.importedRouteMemory,
		}
		if record.kind == "optimizer_study" then
			summary.isolatedStudyReadOnly = true
			summary.sourceBuild = { type = "public_build_study", studyId = record.studyId, label = boundedText(record.studyRecord.label or "Imported build", 120) }
			if record.staleError then summary.message = record.staleError end
		else
			summary.isolatedStudyReadOnly = false
			summary.sourceBuild = { type = "active_build" }
		end
		if result and type(result.searchBaseline) == "table" and result.searchBaseline.exact == true then
			local baseline = result.searchBaseline
			summary.searchBaseline = {
				exact = true,
				label = boundedText(baseline.label or "search baseline", 160),
				feasible = baseline.feasible == true,
				violationCount = math.max(0, math.floor(tonumber(baseline.violationCount) or 0)),
				metrics = copyFiniteMetrics(baseline.metrics),
			}
			local observedMetrics = result.status == "feasible"
				and result.candidate and result.candidate.evaluation and result.candidate.evaluation.metrics
				or result.failureEvidence == "exact_calculation" and result.bestObservedMetrics
			local metricChanges = metricDelta(baseline.metrics, observedMetrics)
			if next(metricChanges) then
				local observedIdentity = result.bestObservedIdentity or { }
				local candidateLabel = result.status == "feasible"
					and result.candidate and result.candidate.evaluation and result.candidate.evaluation.candidateLabel
					or observedIdentity.candidateLabel or "best observed exact candidate"
				summary.baselineComparison = {
					exact = true,
					candidateLabel = boundedText(candidateLabel, 160),
					candidateFeasible = result.status == "feasible",
					metricDelta = copyFiniteMetrics(metricChanges),
				}
			end
		end
		if job.classes and job.totalBudget then
			summary.classSearch = {
				mode = "equal_per_class_exact_evaluation_budget",
				classCount = #job.classes,
				totalBudget = job.totalBudget,
				completedClasses = #(job.classResults or { }),
				currentClass = job.currentClass and job.currentClass.name or nil,
				currentClassBudget = job.currentQuota,
				exhaustive = false,
			}
		elseif result and result.classSearch then
			summary.classSearch = result.classSearch
		end
		if result and result.status == "feasible" then
			local baselineMetrics = result.searchBaseline and result.searchBaseline.metrics
			summary.best = candidateSummary(result.candidate, 0, baselineMetrics)
			summary.alternatives = { }
			local alternativeIndex = 0
			for _, candidate in ipairs(result.paretoFront or { }) do
				if candidate ~= result.candidate then
					alternativeIndex = alternativeIndex + 1
					summary.alternatives[#summary.alternatives + 1] = candidateSummary(candidate, alternativeIndex, baselineMetrics)
				end
			end
		elseif result then
			if result.failureEvidence == "exact_calculation" or result.failureEvidence == "structural_validation" then
				summary.failureEvidence = result.failureEvidence
			end
			if type(result.bestObservedIdentity) == "table" then
				local identity = result.bestObservedIdentity
				summary.bestObservedIdentity = {
					candidateLabel = boundedText(identity.candidateLabel or "", 160),
					baseClass = boundedText(identity.baseClass or "", 80),
					ascendancy = boundedText(identity.ascendancy or "None", 80),
					secondaryAscendancy = boundedText(identity.secondaryAscendancy or "None", 80),
				}
				if isFinite(identity.passivePointsUsed) then summary.bestObservedIdentity.passivePointsUsed = identity.passivePointsUsed end
				if isFinite(identity.ascendancyPointsUsed) then summary.bestObservedIdentity.ascendancyPointsUsed = identity.ascendancyPointsUsed end
				if isFinite(identity.secondaryAscendancyPointsUsed) then summary.bestObservedIdentity.secondaryAscendancyPointsUsed = identity.secondaryAscendancyPointsUsed end
				if isFinite(identity.characterLevel) then summary.bestObservedIdentity.characterLevel = identity.characterLevel end
				if isFinite(identity.ascendancyPointBudget) then summary.bestObservedIdentity.ascendancyPointBudget = identity.ascendancyPointBudget end
			end
			summary.bestObservedViolations = { }
			for _, violation in ipairs(result.bestObservedViolations or { }) do
				local safe = { key = violation.key, label = violation.label, reason = violation.reason }
				if isFinite(violation.actual) then safe.actual = violation.actual end
				if isFinite(violation.required) then safe.required = violation.required end
				if isFinite(violation.deficit) then safe.deficit = violation.deficit end
				summary.bestObservedViolations[#summary.bestObservedViolations + 1] = safe
			end
			if isFinite(result.bestObservedDeficit) then
				summary.bestObservedDeficit = result.bestObservedDeficit
			end
			if type(result.bestObservedMetrics) == "table" then
				summary.bestObservedMetrics = { }
				local metricCount = 0
				for key, value in pairs(result.bestObservedMetrics) do
					if type(key) == "string" and #key <= 80 and isFinite(value) and metricCount < 128 then
						summary.bestObservedMetrics[key] = value
						metricCount = metricCount + 1
					end
				end
			end
		end
		return jsonSafeCopy(summary)
	elseif method == "optimizer_cancel" then
		local record = findJob(params.jobId)
		if not record then return nil, "Unknown optimizer job" end
		record.job:Cancel()
		return { jobId = params.jobId, status = "cancellation_requested" }
	elseif method == "optimizer_apply" then
		local record = findJob(params.jobId)
		if not record then return nil, "Unknown optimizer job" end
		if record.kind == "optimizer_study" then
			return nil, "Imported build-study optimizer results are read-only and cannot be applied to the active build; rerun optimization on the active build to create a variation."
		end
		local result = record.job.result
		if not result or result.status ~= "feasible" then return nil, "The job has no candidate that passed every hard gate" end
		local requestedIndex = tonumber(params.candidateIndex) or 0
		if requestedIndex ~= math.floor(requestedIndex) or requestedIndex < 0 then return nil, "candidateIndex must be a non-negative integer" end
		local selected = requestedIndex == 0 and result.candidate or nil
		if requestedIndex > 0 then
			local seen = 0
			for _, candidate in ipairs(result.paretoFront or { }) do
				if candidate ~= result.candidate then
					seen = seen + 1
					if seen == requestedIndex then selected = candidate break end
				end
			end
		end
		if not selected then return nil, "Candidate index is outside the returned Pareto alternatives" end
		local build = currentBuild()
		if not build or build ~= record.build then return nil, "The active PoB build changed; start a new optimizer job" end
		if not Candidate.HasMutation(selected) then
			return { applied = false, newVariation = false, message = "The best candidate is the current build; no variation was created", candidate = candidateSummary(selected, requestedIndex, result.searchBaseline and result.searchBaseline.metrics) }
		end
		local ok, message = record.tab:ApplyCandidate(selected)
		if not ok then return nil, message end
		return { applied = true, newVariation = true, message = message or "Applied as a new variation", candidate = candidateSummary(selected, requestedIndex, result.searchBaseline and result.searchBaseline.metrics) }
	end
	return nil, "Unsupported local PoB MCP operation"
end

-- In-process counterpart to the loopback MCP transport. The native ChatGPT
-- client calls this only with its own closed tool allowlist, on the UI thread.
function bridge:CallLocal(method, params)
	local ok, result, message = pcall(execute, method, params)
	if not ok then return nil, boundedText(result, 500) end
	if result == nil then return nil, boundedText(message or "PoB rejected the typed request", 500) end
	return result
end

function bridge:QueueUserRequest(build, prompt)
	if not self.listener then return nil, "Local MCP bridge is unavailable" end
	if currentBuild() ~= build then return nil, "The requested build is not the active PoB build" end
	if type(prompt) ~= "string" then return nil, "Request text must be a string" end
	prompt = prompt:gsub("\r", ""):gsub("%z", "")
	if #prompt > 4096 then return nil, "Request text is limited to 4096 bytes" end
	if not prompt:match("%S") then return nil, "Enter a request before queuing it" end
	self.userRequests = self.userRequests or { }
	local activeCount = 0
	for _, request in ipairs(self.userRequests) do
		if request.status == "pending" or request.status == "processing" then activeCount = activeCount + 1 end
	end
	if activeCount >= 8 then return nil, "The local AI request queue is full (8 active requests)" end
	self.nextUserRequest = (self.nextUserRequest or 0) + 1
	local requestId = "ai-" .. tostring(os.time()) .. "-" .. tostring(self.nextUserRequest)
	local group = build.skillsTab.socketGroupList[build.mainSocketGroup]
	local skill = group and group.displaySkillList and group.displaySkillList[group.mainActiveSkill or 1]
	local class = build.spec.curClass
	local request = {
		id = requestId,
		prompt = prompt,
		status = "pending",
		createdAt = os.time(),
		signature = Candidate.BuildSignature(build),
		build = build,
		context = {
			name = boundedText(build.buildName or "Unnamed build", 120),
		dataVersion = Version.Data(build),
			treeVersion = boundedText(build.spec.treeVersion or "", 40),
			class = class and boundedText(class.name or "", 80) or "Unknown",
			ascendancy = boundedText(build.spec.curAscendClassName or "None", 80),
			secondaryAscendancy = boundedText(build.spec.curSecondaryAscendClassName or "None", 80),
			level = build.characterLevel,
			mainSkill = boundedText(skillName(skill) or "Not selected", 120),
		},
	}
	self.userRequests[#self.userRequests + 1] = request
	while #self.userRequests > 24 do
		local removable
		for index, item in ipairs(self.userRequests) do
			if item.status ~= "pending" and item.status ~= "processing" then removable = index break end
		end
		if not removable then break end
		table.remove(self.userRequests, removable)
	end
	return requestId
end

function bridge:GetUserRequestStatus(requestId, build)
	for _, request in ipairs(self.userRequests or { }) do
		if request.id == requestId then
			if request.status == "pending" and os.time() >= (request.nextSignatureCheck or 0) then
				request.nextSignatureCheck = os.time() + 2
				if currentBuild() ~= build or Candidate.BuildSignature(build) ~= request.signature then
					request.status = "stale"
					request.message = "The active build changed before the AI request was completed."
				end
			elseif request.status == "processing" and request.build ~= currentBuild() then
				request.status = "stale"
				request.message = "The active PoB build was replaced while the AI request was processing."
			elseif request.status == "processing" then
				request.buildChanged = request.buildChanged == true or Candidate.BuildSignature(request.build) ~= request.signature
			end
			return { id = request.id, status = request.status, message = request.message, context = request.context,
				buildChanged = request.buildChanged == true }
		end
	end
	return nil
end

function bridge:GetPendingUserRequest()
	if not currentBuild() then return nil, "Open a PoB build before retrieving AI requests" end
	local stale = { }
	for _, request in ipairs(self.userRequests or { }) do
		if request.status == "processing" and os.time() - (request.claimedAt or 0) > 120 then
			request.status = "pending"
		end
		if request.status == "pending" then
			if request.build ~= currentBuild() or Candidate.BuildSignature(request.build) ~= request.signature then
				request.status = "stale"
				request.message = "The active build changed before the request was retrieved."
				stale[#stale + 1] = request.id
			else
				request.status = "processing"
				request.claimedAt = os.time()
				request.claimedSignature = Candidate.BuildSignature(request.build)
				return { pending = true, requestId = request.id, prompt = request.prompt, buildContext = request.context, status = request.status }
			end
		end
	end
	return { pending = false, staleRequestIds = stale }
end

function bridge:CompleteUserRequest(requestId, status, message)
	if type(requestId) ~= "string" or #requestId > 80 then return nil, "requestId must be a short AI request ID" end
	if status ~= "completed" and status ~= "failed" then return nil, "status must be completed or failed" end
	if type(message) ~= "string" or #message > 4096 then return nil, "message must be text of at most 4096 bytes" end
	for _, request in ipairs(self.userRequests or { }) do
		if request.id == requestId then
			if request.status ~= "processing" then return nil, "The request is not currently being processed" end
			if request.build ~= currentBuild() then
				request.status = "stale"
				request.message = "The active PoB build was replaced before the AI response was returned."
				return nil, request.message
			end
			request.completedSignature = Candidate.BuildSignature(request.build)
			request.buildChanged = request.buildChanged == true or request.completedSignature ~= request.signature
			request.status = status
			request.message = message
			request.completedAt = os.time()
			return { requestId = request.id, status = request.status, completedAt = request.completedAt }
		end
	end
	return nil, "Unknown or expired AI request ID"
end

local function closeClient(client)
	pcall(function() client.socket:close() end)
	client.closed = true
end

local function encodeResponse(response)
	local responseId = type(response) == "table" and response.id or nil
	if type(responseId) ~= "string" and not isFinite(responseId) then responseId = nil end
	local function encodeFailure(message)
		local fallback = { id = responseId, ok = false, error = boundedText(message, 300) }
		local fallbackOk, fallbackText = pcall(json.encode, fallback)
		if fallbackOk and type(fallbackText) == "string" then return fallbackText end
		return '{"ok":false,"error":"Could not encode MCP bridge response"}'
	end
	local ok, encoded, encodeError = pcall(json.encode, response)
	if not ok or type(encoded) ~= "string" then
		encoded = encodeFailure("Could not encode MCP bridge response: " .. tostring(encodeError or encoded or "unknown encoder error"))
	end
	if #encoded > maxResponseBytes then encoded = encodeFailure("Response exceeded local bridge size limit") end
	return encoded .. "\n"
end

local function processRequest(client, request)
	local response = { id = request and request.id, ok = false }
	if type(request) ~= "table" or request.token ~= bridge.token then
		response.error = "Unauthorized local bridge request"
	else
		local ok, result, message, errorCode = pcall(execute, request.method, request.params)
		if not ok then
			response.error = boundedText(result, 500)
		elseif result == nil then
			response.error = boundedText(message or "Request failed", 500)
			response.code = errorCode
		else
			response.ok = true
			response.result = result
		end
	end
	client.output = encodeResponse(response)
	client.outputPosition = 1
	client.readyToClose = false
end

local function updateClient(client)
	if client.closed then return end
	if client.output then
		local sent, err, last = client.socket:send(client.output, client.outputPosition)
		if sent then
			client.outputPosition = sent + 1
		elseif err == "timeout" then
			client.outputPosition = (last or (client.outputPosition - 1)) + 1
		elseif err == "closed" then
			closeClient(client)
			return
		end
		if client.outputPosition > #client.output then closeClient(client) end
		return
	end
	local data, err, partial = client.socket:receive("*a")
	if data then client.input = client.input .. data end
	if partial and #partial > 0 then client.input = client.input .. partial end
	if #client.input > maxRequestBytes then
		client.output = encodeResponse({ id = nil, ok = false, error = "Request exceeded local bridge size limit" })
		client.outputPosition = 1
		return
	end
	local newline = client.input:find("\n", 1, true)
	if newline then
		local requestText = client.input:sub(1, newline - 1)
		local request, _, decodeError = json.decode(requestText)
		if not request then
			client.output = encodeResponse({ id = nil, ok = false, error = boundedText(decodeError or "Invalid JSON request", 300) })
			client.outputPosition = 1
		else
			-- Read the request on this frame, but dispatch it on the next one.
			-- That lets the active PoB mode finish recalculating inputs received in
			-- the same frame before a snapshot or exact edit observes the build.
			client.pendingRequest = request
		end
	elseif err == "closed" then
		client.output = encodeResponse({ id = nil, ok = false, error = "Incomplete local bridge request" })
		client.outputPosition = 1
	end
end

function bridge:Start()
	if self.listener then return true end
	self.status = "Starting local bridge"
	local listener, listenError = socket.tcp()
	if not listener then
		self.status = "MCP offline: " .. tostring(listenError)
		return false, self.status
	end
	listener:setoption("reuseaddr", true)
	local bound, bindError = listener:bind("127.0.0.1", 0)
	if not bound then
		listener:close()
		self.status = "MCP offline: " .. tostring(bindError)
		return false, self.status
	end
	local listening, listenErr = listener:listen(maxClients)
	if not listening then
		listener:close()
		self.status = "MCP offline: " .. tostring(listenErr)
		return false, self.status
	end
	listener:settimeout(0)
	local _, port = listener:getsockname()
	if not port then
		listener:close()
		self.status = "MCP offline: no loopback port"
		return false, self.status
	end
	math.randomseed(os.time() + math.floor(socket.gettime() * 1000000) % 2147483647)
	local tokenParts = { }
	for index = 1, 8 do tokenParts[index] = string.format("%04x", math.random(0, 65535)) end
	self.token = table.concat(tokenParts)
	self.listener = listener
	self.port = port
	self.instanceId = string.format("pob-%d-%d", port, math.floor(socket.gettime() * 1000))
	self.endpointPath = tempPath(endpointFilePrefix .. tostring(port) .. ".json")
	self.healthPath = tempPath(healthFilePrefix .. tostring(port) .. ".json")
	self.clients = { }
	self.jobs = self.jobs or { }
	self.qaJobs = self.qaJobs or { }
	self.studyJobs = self.studyJobs or { }
	self.studyBuilds = self.studyBuilds or { }
	self.nextJob = self.nextJob or 0
	self.pollCount = 0
	self.frameCount = 0
	self.lastHealthWrite = 0
	self.nextEndpointPublishCheck = 0
	local published, publishError = writeEndpointFile(self, self.endpointPath)
	if not published then
		listener:close()
		self.listener = nil
		self.status = "MCP offline: could not publish local endpoint (" .. tostring(publishError) .. ")"
		return false, self.status
	end
	self.status = "Ready on loopback port " .. tostring(port)
	return true
end

function bridge:GetStatus()
	return self.status or "Not started"
end

function bridge:GetEndpointStatus()
	if not self.listener then return { status = "offline", message = "The local MCP listener is not active" } end
	if not self.endpointPath then return { status = "missing", message = "Per-instance companion endpoint metadata is not configured" } end
	local file = io.open(self.endpointPath, "rb")
	if not file then return { status = "missing", message = "Per-instance companion endpoint metadata is missing" } end
	local contents = file:read("*a") or ""
	file:close()
	local ok, endpoint = pcall(json.decode, contents)
	if not ok or type(endpoint) ~= "table" then
		return { status = "invalid", message = "Per-instance companion endpoint metadata is unreadable" }
	end
	local matches = endpoint.host == "127.0.0.1" and endpoint.port == self.port
		and endpoint.protocol == "pob-mcp-1" and endpoint.instanceId == self.instanceId and endpoint.token == self.token
	if not matches then return { status = "mismatch", message = "Companion endpoint metadata does not match this PoB listener" } end
	return { status = "published", message = "Authenticated per-instance companion endpoint is published" }
end

function bridge:GetConnectionHealth()
	local endpointStatus = self:GetEndpointStatus()
	if not self.listener then
		return { status = "offline", companionEndpointStatus = endpointStatus.status, companionEndpointMessage = endpointStatus.message, snapshotContractVersion = snapshotContractVersion, ageMs = nil, pollCount = self.pollCount or 0, frameCount = self.frameCount or 0 }
	end
	if not self.lastCompletedFrameAt then
		return { status = "unknown", companionEndpointStatus = endpointStatus.status, companionEndpointMessage = endpointStatus.message, snapshotContractVersion = snapshotContractVersion, ageMs = nil, pollCount = self.pollCount or 0, frameCount = self.frameCount or 0 }
	end
	local ageMs = math.max(0, math.floor((socket.gettime() - self.lastCompletedFrameAt) * 1000))
	return {
		status = ageMs <= 2000 and "fresh" or "stale",
		companionEndpointStatus = endpointStatus.status,
		companionEndpointMessage = endpointStatus.message,
		snapshotContractVersion = snapshotContractVersion,
		ageMs = ageMs,
		pollCount = self.pollCount or 0,
		frameCount = self.frameCount or 0,
	}
end

function bridge:StepQASuites()
	runQASuiteStep()
end

function bridge:StepProgressionJobs()
	stepProgressionJobs()
end

function bridge:StepFactorialJobs()
	stepPassiveFactorialStudies()
end

function bridge:IsStudyOptimizerRunning()
	for _, record in pairs(self.jobs or { }) do
		if record.kind == "optimizer_study" and record.job and record.job.status == "running" then return true end
	end
	return false
end

function bridge:StepOptimizerJobs()
	local now = socket.gettime()
	for _, record in pairs(self.jobs or { }) do
		if record.kind == "optimizer_study" and record.job and record.job.status == "running" then
			if now >= (record.nextFreshnessCheck or 0) then
				record.nextFreshnessCheck = now + 0.25
				if not record.staleError then
					local activeBuild = currentBuild()
					if activeBuild ~= record.activeBuild then
						record.staleError = "The active PoB build changed during isolated optimization; no candidate can be applied."
					elseif Candidate.BuildSignature(activeBuild) ~= record.activeSignature then
						record.staleError = "The active PoB build changed during isolated optimization; no candidate can be applied."
					elseif Candidate.BuildSignature(record.build) ~= record.sourceSignature then
						record.staleError = "The imported comparison build changed during optimization; rerun against the updated source."
					elseif self.studyBuilds[record.studyId] ~= record.studyRecord
						or not studyBuildIndex(record.studyRecord.compareTab, record.studyRecord.entry) then
						record.staleError = "The imported study was removed during optimization; no result can be applied."
					end
				end
			end
			if record.staleError and not record.cancellationRequested then
				record.cancellationRequested = true
				record.job:Cancel()
			end
			record.job:Step()
			-- A single bounded exact job advances per UI poll. The coroutine yields
			-- at the optimizer's safe work boundaries, preserving frame responsiveness.
			return
		end
	end
end

function bridge:Poll()
	if not self.listener then
		self:StepQASuites()
		self:StepProgressionJobs()
		self:StepFactorialJobs()
		self:StepOptimizerJobs()
		return
	end
	self.pollCount = (self.pollCount or 0) + 1
	ensureEndpointPublished(self)
	for _, client in ipairs(self.clients or { }) do
		if client.pendingRequest and not client.closed then
			local request = client.pendingRequest
			client.pendingRequest = nil
			processRequest(client, request)
		end
	end
	for _, record in pairs(self.studyJobs or { }) do expireStudyImport(record) end
	local studyJobCount = 0
	for _ in pairs(self.studyJobs or { }) do studyJobCount = studyJobCount + 1 end
	if studyJobCount > 16 then
		for jobId, record in pairs(self.studyJobs) do
			if record.status ~= "running" then self.studyJobs[jobId] = nil studyJobCount = studyJobCount - 1 end
			if studyJobCount <= 16 then break end
		end
	end
	local accepted, acceptError = self.listener:accept()
	if accepted then
		if #self.clients >= maxClients then
			accepted:settimeout(0)
			local response = encodeResponse({ ok = false, error = "PoB MCP bridge is at its local connection limit" })
			pcall(function() accepted:send(response) end)
			accepted:close()
		else
			accepted:settimeout(0)
			self.clients[#self.clients + 1] = { socket = accepted, input = "" }
		end
	elseif acceptError ~= "timeout" and acceptError ~= "closed" then
		self.status = "MCP bridge accept error: " .. tostring(acceptError)
	end
	local liveClients = { }
	for _, client in ipairs(self.clients) do
		updateClient(client)
		if not client.closed then liveClients[#liveClients + 1] = client end
	end
	self.clients = liveClients
	self:StepQASuites()
	self:StepProgressionJobs()
	self:StepFactorialJobs()
	self:StepOptimizerJobs()
	trimJobHistory(maxJobs)
end

function bridge:FrameComplete()
	if not self.listener then return end
	self.frameCount = (self.frameCount or 0) + 1
	self.lastCompletedFrameAt = socket.gettime()
	writeHealthFile(self)
end

function bridge:Stop()
	for _, record in pairs(self.jobs or { }) do
		if record.kind == "optimizer_study" and record.job and record.job.status == "running" then
			record.job:Cancel()
		end
	end
	for _, job in pairs(self.progressionJobs or { }) do
		if job.status == "running" then
			Progression.Cancel(job)
			job.status = "cancelled"
			job.thread = nil
		end
	end
	self.progressionJobs = { }
	for _, job in pairs(self.factorialJobs or { }) do
		if job.status == "running" then
			job.cancelRequested = true
			job.status = "cancelled"
			job.completedAt = os.time()
			job.thread = nil
		end
	end
	self.factorialJobs = { }
	for _, client in ipairs(self.clients or { }) do closeClient(client) end
	self.clients = { }
	if self.listener then pcall(function() self.listener:close() end) end
	self.listener = nil
	if self.endpointPath then
		local file = io.open(self.endpointPath, "r")
		if file then
			local contents = file:read("*a")
			file:close()
			local ok, endpoint = pcall(json.decode, contents or "")
			if ok and type(endpoint) == "table" and endpoint.token == self.token and endpoint.port == self.port then
				os.remove(self.endpointPath)
			end
		end
		pcall(os.remove, self.endpointPath .. ".tmp")
	end
	if self.healthPath then
		local file = io.open(self.healthPath, "r")
		if file then
			local contents = file:read("*a")
			file:close()
			local ok, health = pcall(json.decode, contents or "")
			if ok and type(health) == "table" and health.port == self.port then os.remove(self.healthPath) end
		end
	end
	self.status = "Stopped"
end

return bridge
