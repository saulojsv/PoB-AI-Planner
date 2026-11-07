-- Path of Building
--
-- Module: categorical AI Route Planner v1 RunSpec and native hard-floor mapping.
-- The UI never accepts free-form metric values in this flow. PoB remains the
-- only calculator and every selected tier becomes an exact validator floor.

local routePlanner = { }

local dpsFloors = {
	TIER_1M_TO_5M = 1000000, TIER_5M_TO_10M = 5000000, TIER_10M_TO_25M = 10000000,
	TIER_25M_TO_50M = 25000000, TIER_50M_PLUS = 50000000,
}
local dpsGainModes = {
	NONE = 0,
	NO_LOSS = 0,
	GAIN_5_PERCENT = 0.05,
	GAIN_10_PERCENT = 0.10,
	GAIN_25_PERCENT = 0.25,
}
local ehpFloors = { TIER_20K_TO_50K = 20000, TIER_50K_TO_100K = 50000, TIER_100K_PLUS = 100000 }
local hitFloors = { TIER_5K_TO_10K = 5000, TIER_10K_TO_20K = 10000,
	TIER_15K_TO_25K = 15000, TIER_20K_PLUS = 20000 }
local searchModes = { SINGLE_SKILL_ONLY = true, CROSS_SKILL_COMBINATION = true }
local crossSkillModes = { SINGLE_SKILL_ONLY = true, ALLOW_COC_AND_CWC = true,
	ALLOW_SPELLSLINGER_AND_TRIGGERS = true, ALLOW_DEBUFF_PRIMERS = true }
local aggressionModes = { CONSERVATIVE_FINE_TUNE = true, BALANCED_LOCAL_SEARCH = true, AGGRESSIVE_CLUSTER_EXPANSION = true }
-- Route depth is the maximum number of new passive nodes in one proposal.
-- It is deliberately independent of graph.radius (the GNN neighborhood K).
-- The previous 2/4/6 mapping accidentally disabled progressive route bundles
-- for the default profile because PhantomSim only generated them above 5.
local aggressionPointBudgets = {
	CONSERVATIVE_FINE_TUNE = 12,
	BALANCED_LOCAL_SEARCH = 24,
	AGGRESSIVE_CLUSTER_EXPANSION = 40,
}
local damageFocuses = {
	Auto = true, PhysicalHit = true, PhysicalImpale = true, PhysicalDoT = true,
	Fire = true, Cold = true, Lightning = true, ChaosPoison = true, Minions = true,
}
local defenseProfiles = {
	Auto = true, Life = true, EnergyShield = true, Hybrid = true, Ward = true,
	Armour = true, Evasion = true, Block = true, SpellBlock = true, SpellSuppression = true,
}
local rankingPriorities = { ObjectiveFirst = true, DefenseFirst = true }
local proposalLimits = { ["10000"] = 10000, ["40000"] = 40000, ["100000"] = 100000 }
local exactEvaluationBudgets = {
	["250"] = { evaluations = 250, timeoutSeconds = 120 },
	["500"] = { evaluations = 500, timeoutSeconds = 240 },
	["1000"] = { evaluations = 1000, timeoutSeconds = 480 },
	["2500"] = { evaluations = 2500, timeoutSeconds = 900 },
	["5000"] = { evaluations = 5000, timeoutSeconds = 1800 },
	["10000"] = { evaluations = 10000, timeoutSeconds = 3600 },
}
local conversionRouteValues = {
	NONE = "",
	PHYSICAL_TO_LIGHTNING = "Physical>Lightning",
	PHYSICAL_TO_COLD = "Physical>Cold",
	PHYSICAL_TO_FIRE = "Physical>Fire",
	PHYSICAL_TO_CHAOS = "Physical>Chaos",
	PHYSICAL_TO_LIGHTNING_TO_COLD = "Physical>Lightning>Cold",
	LIGHTNING_TO_COLD = "Lightning>Cold",
	LIGHTNING_TO_FIRE = "Lightning>Fire",
	COLD_TO_FIRE = "Cold>Fire",
}
local conversionRoutes = { }
for key in pairs(conversionRouteValues) do conversionRoutes[key] = true end
local conversionMinimums = { ["50"] = true, ["75"] = true, ["100"] = true }
local defenseMetricKeys = {
	Auto = "TotalEHP", Life = "Life", EnergyShield = "EnergyShield", Hybrid = "TotalEHP",
	Ward = "Ward", Armour = "Armour", Evasion = "Evasion", Block = "BlockChance",
	SpellBlock = "SpellBlockChance", SpellSuppression = "SpellSuppressionChance",
}

local function isFinite(value)
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function requestedNodePowerStat(objective, damageFocus, defenseProfile)
	if defenseProfile ~= "Auto" then return defenseMetricKeys[defenseProfile] end
	if damageFocus == "PhysicalHit" then return "TotalDPS" end
	if damageFocus == "PhysicalImpale" then return "WithImpaleDPS" end
	if damageFocus == "PhysicalDoT" or damageFocus == "ChaosPoison" then return "TotalDot" end
	if damageFocus == "Auto" then return objective end
	-- PoB's Node Power list has no isolated per-element DPS value. Do not use
	-- CombinedDPS as if it were a Fire/Cold/Lightning-specific signal.
	return nil
end

local function inspectNodePower(build, requestedStat)
	local calcs = build and build.calcsTab
	local selectedStat = calcs and calcs.powerStat and calcs.powerStat.stat
	local ready = calcs and calcs.powerBuildFlag == false and calcs.powerBuilder == nil
	if not requestedStat or not ready or selectedStat ~= requestedStat then
		return { enabled = false, ready = ready == true, requestedStat = requestedStat,
			selectedStat = selectedStat, availableNodes = 0,
			reason = not requestedStat and "no matching native Node Power stat for this focus"
				or not ready and "native Show Node Power values are not calculated for the current build"
				or "select the matching stat in Tree > Show Node Power" }
	end
	local count = 0
	for _, node in pairs(build.spec and build.spec.nodes or { }) do
		local power = node and node.power
		if isFinite(power and (power.pathPower or power.singleStat)) then count = count + 1 end
	end
	return { enabled = count > 0, ready = true, requestedStat = requestedStat,
		selectedStat = selectedStat, availableNodes = count,
		reason = count > 0 and nil or "the selected Show Node Power stat has no calculated node values" }
end

local function choice(values, key, allowed, default)
	local value = tostring(values[key] or default or "")
	if not allowed[value] then return nil, key .. " is not a supported categorical value" end
	return value
end

local function inspectMainSkill(build, requireFullDpsSockets)
	local groupIndex = tonumber(build and build.mainSocketGroup) or 1
	local group = build and build.skillsTab and build.skillsTab.socketGroupList and build.skillsTab.socketGroupList[groupIndex]
	local skillIndex = tonumber(group and group.mainActiveSkill) or 1
	local skill = group and group.displaySkillList and group.displaySkillList[skillIndex]
	local effect = skill and (skill.activeEffect or (skill.effectList and skill.effectList[1]))
	local effectId = effect and effect.grantedEffect and effect.grantedEffect.id
	local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
	local gemId = group and SkillCatalog.CurrentMainGemId(build, groupIndex, skillIndex)
	if (not skill or not effectId) and gemId then
		local gemData = build and build.data and build.data.gems and build.data.gems[gemId]
		local nativeEffect = gemData and gemData.grantedEffect
		if SkillCatalog.IsActiveSkillGem(gemData) and nativeEffect
			and nativeEffect.support ~= true and nativeEffect.unsupported ~= true then
			local sourceGem
			for _, gem in ipairs(group and group.gemList or { }) do
				local sourceData = gem.gemData or (gem.gemId and build.data and build.data.gems and build.data.gems[gem.gemId])
				if sourceData and sourceData.id == gemId then sourceGem = gem break end
			end
			effect = { grantedEffect = nativeEffect, srcInstance = sourceGem }
			effectId = nativeEffect.id or gemData.grantedEffectId
			-- This placeholder carries only the selected native gem/effect identity;
			-- PoB must reconstruct its live skill after a legal candidate socket layout.
			skill = { activeEffect = effect }
		end
	end
	local output = build and build.calcsTab and build.calcsTab.mainOutput or { }
	local baseline = { }
	for _, key in ipairs({ "CombinedDPS", "FullDPS", "TotalEHP", "PhysicalMaximumHitTaken",
		"FireMaximumHitTaken", "ColdMaximumHitTaken", "LightningMaximumHitTaken",
		"FireResist", "ColdResist", "LightningResist", "ChaosResist" }) do
		local value = tonumber(output[key])
		if value and value == value and value ~= math.huge and value ~= -math.huge then
			baseline[key] = value
		end
	end
	local context = {
		groupIndex = groupIndex,
		skillIndex = skillIndex,
		gemId = gemId,
		effectId = effectId,
		slot = tostring(group and group.slot or ""),
		baseline = baseline,
	}
	if not group or not skill or type(effectId) ~= "string" or effectId == "" or type(gemId) ~= "string" or gemId == "" then
		context.error = "Select a loaded Main Skill with a valid active PoB effect before planning combinations"
		return context
	end
	if group.enabled == false or group.slotEnabled == false then
		context.error = "The selected Main Skill group is disabled or belongs to the inactive weapon set"
		return context
	end
	local socketEvidence = SkillCatalog.SocketGroupEvidence(build, groupIndex, group)
	context.socketEvidence = socketEvidence
	context.skill = {
		groupIndex = groupIndex,
		skillIndex = skillIndex,
		effectId = effectId,
		gemId = gemId,
		slot = tostring(socketEvidence.slot or group.slot
			or (socketEvidence.status == "granted_skill" and "PoB-granted skill" or "Unassigned")),
	}
	local skillFlags = skill.skillFlags or { }
	local minionSkill = skillFlags.minion == true or skillFlags.haveMinion == true
		or type(effect.grantedEffect.minionList) == "table"
		or (type(skill.minionList) == "table" and next(skill.minionList) ~= nil)
	context.skill.isMinion = minionSkill
	context.objectiveMetric = minionSkill and "FullDPS" or "CombinedDPS"
	local socketRepairAudit = SkillCatalog.PlanEnabledSocketRepairs(build)
	context.socketRepairAudit = socketRepairAudit
	context.socketRepairs = socketRepairAudit.repairs or { }
	context.socketWarnings = { }
	for _, repairPlan in ipairs(context.socketRepairs) do
		for _, repairedGroupIndex in ipairs(repairPlan.groupIndices or { }) do
			if tonumber(repairedGroupIndex) == groupIndex then
				context.socketRepair = repairPlan
				break
			end
		end
	end
	context.skill.socketRepairs = context.socketRepairs
	context.skill.socketRepair = context.socketRepair
	context.skill.socketEvidence = socketEvidence
	if #((socketRepairAudit and socketRepairAudit.blockers) or { }) > 0 then
		for _, blocker in ipairs(socketRepairAudit.blockers) do
			context.socketWarnings[#context.socketWarnings + 1] = {
				groupIndex = tonumber(blocker.groupIndex),
				group = tostring(blocker.group or blocker.groupIndex or "unknown"),
				slot = blocker.slot,
				reason = tostring(blocker.reason or "socket repair is unavailable"),
			}
		end
	end
	if not socketEvidence.valid and not context.socketRepair then
		local foundMainWarning = false
		for _, warning in ipairs(context.socketWarnings) do
			if warning.groupIndex == groupIndex then foundMainWarning = true break end
		end
		if not foundMainWarning then
			context.socketWarnings[#context.socketWarnings + 1] = {
				groupIndex = groupIndex,
				group = tostring(group.displayLabel or group.label or group.slot or ("Main Skill " .. groupIndex)),
				slot = group.slot,
				reason = tostring(socketEvidence.reason or "Main Skill has no native socket/link proof"),
			}
		end
	end
	if #context.socketWarnings > 0 then
		local warning = context.socketWarnings[1]
		if tonumber(warning.groupIndex) == groupIndex then
			context.socketValidationError = "The selected Main Skill is not bound to a valid native PoB item socket/link: "
				.. tostring(warning.reason)
		else
			context.socketValidationError = "Enabled skill group " .. tostring(warning.group)
				.. " is not bound to a valid native PoB item socket/link and has no legal equipment repair: "
				.. tostring(warning.reason)
		end
	end
	local fullGroupsValid, fullGroupsEvidence = SkillCatalog.ValidateFullDPSSocketGroups(build)
	context.fullDpsSocketEvidence = fullGroupsEvidence
	if requireFullDpsSockets == true and not fullGroupsValid and #context.socketRepairs == 0 then
		local violation = fullGroupsEvidence and fullGroupsEvidence.violations and fullGroupsEvidence.violations[1]
		context.fullDpsSocketValidationError = "Enabled Full DPS group " .. tostring(violation and violation.group or "unknown")
			.. " has invalid native PoB socket/link evidence: "
			.. tostring(violation and violation.reason or "socket validation failed")
	end
	if context.fullDpsSocketValidationError then context.socketValidationError = context.fullDpsSocketValidationError end
	return context
end

local function getMainSkill(build, requireFullDpsSockets, allowUnlinkedPlanning)
	local context = inspectMainSkill(build, requireFullDpsSockets)
	if not context or context.error or not context.skill then
		return nil, context and context.error or "Select a loaded Main Skill with a valid active PoB effect before planning combinations", context
	end
	if context.socketValidationError and allowUnlinkedPlanning ~= true then
		return nil, context.socketValidationError, context
	end
	return context.skill, nil, context
end

function routePlanner.Prepare(build, values)
	values = values or { }
	local err
	local searchMode
	searchMode, err = choice(values, "routePlannerSearchMode", searchModes, "SINGLE_SKILL_ONLY")
	if not searchMode then return nil, err end
	if searchMode == "CROSS_SKILL_COMBINATION" then
		return nil, "Cross-skill mutation generation is not yet certified by the native PoB candidate engine"
	end
	-- Physical socket problems are search constraints, not a reason to disable
	-- the generator. Exact PoB evaluation and Candidate.Apply still require the
	-- full native socket/link proof before a route can be approved or applied.
	local skill, skillError, skillContext = getMainSkill(build, false, true)
	if not skill and skillContext and skillContext.skill and skillContext.socketRepair
		and #((skillContext.socketRepairAudit and skillContext.socketRepairAudit.blockers) or { }) == 0 then
		-- Keep the loaded Main Skill usable as a search seed when its socket group
		-- can be made legal by a native item proposal. Exact candidate evaluation
		-- still requires the replacement item to pass PoB's socket/link checks.
		skill = skillContext.skill
		skill.socketRepair = skillContext.socketRepair
	end
	if not skill then return nil, skillError end
	local modelPackageId = tostring(values.routePlannerModelPackageId or "")
	if modelPackageId ~= "" and (#modelPackageId > 128 or not modelPackageId:match("^[%w_.%-]+$")) then
		return nil, "Selected GNN package ID is invalid"
	end
	local modelMode = modelPackageId ~= "" and "approved_gnn" or "deterministic_fallback"
	local crossSkillMode
	crossSkillMode, err = choice(values, "routePlannerCrossSkillMode", crossSkillModes, "SINGLE_SKILL_ONLY")
	if not crossSkillMode then return nil, err end
	if crossSkillMode ~= "SINGLE_SKILL_ONLY" then
		return nil, "CoC/CwC, Spellslinger, and debuff-primer mutations are unsupported until native exact activity certification is available"
	end
	local dpsTier, tierError = choice(values, "routePlannerDpsTier", dpsFloors, "TIER_10M_TO_25M")
	if not dpsTier then return nil, tierError end
	local dpsGainMode
	dpsGainMode, tierError = choice(values, "routePlannerDpsGain", dpsGainModes, "NO_LOSS")
	if not dpsGainMode then return nil, tierError end
	local ehpTier
	ehpTier, tierError = choice(values, "routePlannerEhpTier", ehpFloors, "TIER_50K_TO_100K")
	if not ehpTier then return nil, tierError end
	local elementalTier
	elementalTier, tierError = choice(values, "routePlannerElementalHitTier", hitFloors, "TIER_10K_TO_20K")
	if not elementalTier then return nil, tierError end
	local physicalTier
	physicalTier, tierError = choice(values, "routePlannerPhysicalHitTier", hitFloors, "TIER_10K_TO_20K")
	if not physicalTier then return nil, tierError end
	local elementalStrategy
	elementalStrategy, err = choice(values, "routePlannerElementalResists", { CAP_EFFECTIVE = true, OVERCAP_30_ALL = true }, "CAP_EFFECTIVE")
	if not elementalStrategy then return nil, err end
	local chaosStrategy
	chaosStrategy, err = choice(values, "routePlannerChaosResist", { POSITIVE_OR_CAP = true, CAP_EFFECTIVE = true }, "POSITIVE_OR_CAP")
	if not chaosStrategy then return nil, err end
	local mutationAggressiveness
	mutationAggressiveness, err = choice(values, "routePlannerAggressiveness", aggressionModes, "BALANCED_LOCAL_SEARCH")
	if not mutationAggressiveness then return nil, err end
	local damageFocus
	damageFocus, err = choice(values, "damageFocus", damageFocuses, "Auto")
	if not damageFocus then return nil, err end
	local defenseProfile
	defenseProfile, err = choice(values, "defenseProfile", defenseProfiles, "Auto")
	if not defenseProfile then return nil, err end
	local rankingPriority
	rankingPriority, err = choice(values, "rankingPriority", rankingPriorities, "ObjectiveFirst")
	if not rankingPriority then return nil, err end
	local conversionRouteId
	conversionRouteId, err = choice(values, "routePlannerConversionRoute", conversionRoutes, "NONE")
	if not conversionRouteId then return nil, err end
	local conversionMinimum
	conversionMinimum, err = choice(values, "routePlannerConversionMinimum", conversionMinimums, "100")
	if not conversionMinimum then return nil, err end
	local conversionRouteText = conversionRouteValues[conversionRouteId]
	local conversionRoute = { }
	for damageType in conversionRouteText:gmatch("[^>]+") do conversionRoute[#conversionRoute + 1] = damageType end
	local proposalLimitText = tostring(values.routePlannerProposalLimit or "40000")
	local proposalLimit = proposalLimits[proposalLimitText]
	if not proposalLimit then return nil, "Proposal limit must be one of 10000, 40000, or 100000" end
	local exactEvaluationBudgetText = tostring(values.routePlannerExactEvaluationBudget or "5000")
	local exactEvaluationBudget = exactEvaluationBudgets[exactEvaluationBudgetText]
	if not exactEvaluationBudget then return nil, "Exact evaluation budget must be one of 250, 500, 1000, 2500, 5000, or 10000" end
	local radius = tonumber(values.routePlannerGraphRadius or 4)
	if radius ~= 2 and radius ~= 4 and radius ~= 6 then return nil, "Graph radius must be 2, 4, or 6" end
	local scenario = tostring(values.routePlannerScenario or values.scenarioProfile or "Current")
	if scenario ~= "Current" and scenario ~= "PinnacleUnbuffed" and scenario ~= "PinnacleChassis" then
		return nil, "Scenario is not a supported categorical value"
	end
	local enemyPreset = scenario == "Current" and tostring(values.scenarioEnemyPreset or "Active") or "Pinnacle"
	if enemyPreset ~= "Active" and enemyPreset ~= "None" and enemyPreset ~= "Boss" and enemyPreset ~= "Pinnacle" and enemyPreset ~= "Uber" then
		return nil, "Enemy preset is not a supported native PoB choice"
	end
	local objective = skill.isMinion == true and "FullDPS" or "CombinedDPS"
	local baselineDps = skillContext and skillContext.baseline and tonumber(skillContext.baseline[objective])
	local dpsFloor = dpsFloors[dpsTier]
	if dpsGainMode ~= "NONE" then
		if not isFinite(baselineDps) or baselineDps <= 0 then
			return nil, "A relative DPS gain requires an exact, positive current PoB baseline for the selected skill"
		end
		local relativeDpsFloor = baselineDps * (1 + dpsGainModes[dpsGainMode])
		if relativeDpsFloor > dpsFloor then dpsFloor = relativeDpsFloor end
	end
	local nodePower = inspectNodePower(build, requestedNodePowerStat(objective, damageFocus, defenseProfile))
	local nodePowerChoice = values.routePlannerUseNodePower
	local useNodePower
	if nodePowerChoice == nil then
		useNodePower = true
	elseif nodePowerChoice == true or (type(nodePowerChoice) == "string" and nodePowerChoice:lower() == "true") then
		useNodePower = true
	elseif nodePowerChoice == false or (type(nodePowerChoice) == "string" and nodePowerChoice:lower() == "false") then
		useNodePower = false
	else
		return nil, "Show Node Power preference must be true or false"
	end
	if useNodePower then
		nodePower.requested = true
	else
		nodePower.requested = false
		nodePower.enabled = false
		nodePower.reason = "Show Node Power preference is disabled"
	end
	local runSpec = {
		schemaVersion = 1,
		modelMode = modelMode,
		modelPackageId = modelPackageId ~= "" and modelPackageId or nil,
		searchMode = searchMode,
		objectiveMetric = objective,
		skill = skill,
		scenario = { profile = scenario, enemyPreset = enemyPreset },
		targets = { dps = dpsTier, dpsGain = dpsGainMode, dpsFloor = dpsFloor,
			dpsBaseline = baselineDps, ehp = ehpTier, elementalMaxHit = elementalTier, physicalMaxHit = physicalTier },
		resistances = { elemental = elementalStrategy, chaos = chaosStrategy },
		crossSkillMode = crossSkillMode,
		mutationAggressiveness = mutationAggressiveness,
		maxAddedPoints = aggressionPointBudgets[mutationAggressiveness],
		maxTotalPoints = 130,
		graph = { radius = radius },
		preferences = { damageFocus = damageFocus, defenseProfile = defenseProfile, rankingPriority = rankingPriority },
		conversion = { routeId = conversionRouteId, routeText = conversionRouteText,
			route = conversionRoute, minPercent = tonumber(conversionMinimum) },
		nodePower = nodePower,
		budget = { minProposals = 1000, maxProposals = proposalLimit,
			maxExactEvaluations = exactEvaluationBudget.evaluations, timeoutSeconds = exactEvaluationBudget.timeoutSeconds },
	}
	local dpsKey = objective
	local floors = {
		[dpsKey] = dpsFloor,
		TotalEHP = ehpFloors[ehpTier],
		PhysicalMaximumHitTaken = hitFloors[physicalTier],
		FireMaximumHitTaken = hitFloors[elementalTier],
		ColdMaximumHitTaken = hitFloors[elementalTier],
		LightningMaximumHitTaken = hitFloors[elementalTier],
	}
	if elementalStrategy == "CAP_EFFECTIVE" then
		floors.FireResist, floors.ColdResist, floors.LightningResist = 75, 75, 75
	else
		floors.FireResistOverCap, floors.ColdResistOverCap, floors.LightningResistOverCap = 30, 30, 30
	end
	floors.ChaosResist = chaosStrategy == "CAP_EFFECTIVE" and 75 or 0
	return runSpec, floors
end

routePlanner.dpsFloors = dpsFloors
routePlanner.ehpFloors = ehpFloors
routePlanner.hitFloors = hitFloors
routePlanner.dpsGainModes = dpsGainModes
routePlanner.GetMainSkill = getMainSkill
routePlanner.InspectMainSkill = inspectMainSkill

return routePlanner
