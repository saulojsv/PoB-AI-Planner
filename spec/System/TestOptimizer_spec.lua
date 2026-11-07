local Inputs = require("Modules.Optimizer.Inputs")
local Validator = require("Modules.Optimizer.Validator")
local Conversion = require("Modules.Optimizer.Conversion")
local Breakpoints = require("Modules.Optimizer.Breakpoints")
local SkillAvailability = require("Modules.Optimizer.SkillAvailability")
local Pool = require("Modules.Optimizer.Pool")
local TreeSearch = require("Modules.Optimizer.TreeSearch")
local Candidate = require("Modules.Optimizer.Candidate")
local CalcBase = require("Modules.CalcBase")
local Activity = require("Modules.Optimizer.Activity")
local SkillActions = require("Modules.Optimizer.SkillActions")
local MCPBridge = require("Modules.Optimizer.MCPBridge")

local function traumaSkill(name, configuredStacks, maximumStacks, extraTraumaChance)
	return {
		activeEffect = { grantedEffect = { name = name } },
		baseSkillModList = {
			Flag = function(_, _, flag) return flag == "HasTrauma" end,
		},
		skillModList = {
			Sum = function(_, _, _, stat)
				if stat == "Multiplier:TraumaStacks" then return configuredStacks end
				if stat == "Multiplier:TraumaStacksMax" then return maximumStacks or 0 end
				if stat == "ExtraTrauma" then return extraTraumaChance or 0 end
				return 0
			end,
		},
	}
end

local function activityRecord(name, identity, costs, regen, leech, onHit, kind)
	local resources = { }
	for _, resource in ipairs({ "Life", "Mana", "ES" }) do
		resources[resource] = {
			cost = (costs and costs[resource]) or 0,
			netRegen = (regen and regen[resource]) or 0,
			leech = (leech and leech[resource]) or 0,
			onHit = (onHit and onHit[resource]) or 0,
		}
	end
	return {
		identity = identity,
		name = name,
		group = identity,
		count = 1,
		kind = kind or "manual",
		hasDamage = true,
		exact = true,
		triggerRate = kind == "triggered" and 2 or nil,
		resources = resources,
		otherResourceCosts = { },
	}
end

describe("Optimizer strict contracts", function()
	it("parses Matrix values and canonical conversion routes", function()
		local parsed, err = Inputs.Parse({
			CombinedDPS = "10000000",
			SpellSuppressionChance = "100",
			conversionRoute = "physical -> lightning -> cold",
			conversionMin = "100",
			targetNodeIds = "12345",
			maxAddedPoints = "4",
			evaluationBudget = "64",
			seed = "9",
		})
		assert.is_nil(err)
		assert.are.equal(10000000, parsed.hard.CombinedDPS.value)
		assert.are.equal(100, parsed.hard.SpellSuppressionChance.value)
		assert.are.same({ "Physical", "Lightning", "Cold" }, parsed.conversion.route)
		assert.are.equal(4, parsed.search.maxAddedPoints)
		assert.are.equal("CombinedDPS", parsed.objective)
		assert.are.same({ 12345 }, parsed.targetNodeIds)
	end)

	it("accepts a bounded 100k structural proposal pool and rejects larger limits", function()
		local parsed, err = Inputs.Parse({ proposalBudget = "100000", evaluationBudget = "250" })
		assert.is_truthy(parsed, err)
		assert.are.equal(100000, parsed.search.proposalBudget)
		assert.are.equal(250, parsed.search.evaluationBudget)
		assert.is_nil(Inputs.Parse({ proposalBudget = "100001" }))
		assert.is_nil(Inputs.Parse({ proposalBudget = "40000.5" }))
	end)

	it("parses damage and defense preferences plus exact Life, ES, Ward and Impale floors", function()
		local parsed, err = Inputs.Parse({
			damageFocus = "physicalimpale",
			defenseProfile = "EnergyShield",
			generationPhase = "combined",
			nodePotentialAnalysis = "true",
			evaluationBudget = "4",
			maxAddedPoints = "2",
			Life = "5000",
			EnergyShield = "2000",
			Ward = "300",
			ImpaleDPS = "1000000",
		})
		assert.is_truthy(parsed, err)
		assert.are.equal("PhysicalImpale", parsed.preferences.damageFocus)
		assert.are.equal("EnergyShield", parsed.preferences.defenseProfile)
		assert.is_true(parsed.search.nodePotentialAnalysis)
		assert.are.equal(5000, parsed.hard.Life.value)
		assert.are.equal(2000, parsed.hard.EnergyShield.value)
		assert.are.equal(300, parsed.hard.Ward.value)
		assert.are.equal(1000000, parsed.hard.ImpaleDPS.value)
		assert.are.equal(">=", parsed.hard.Ward.operator)
		local metrics = Candidate.CopyMetrics({ Life = 5000, EnergyShield = 2000, Ward = 300, ImpaleDPS = 1000000 }, Inputs.metricDefinitions)
		assert.are.equal(5000, metrics.Life)
		assert.are.equal(2000, metrics.EnergyShield)
		assert.are.equal(300, metrics.Ward)
		assert.are.equal(1000000, metrics.ImpaleDPS)
	end)

	it("enforces Strength, Dexterity, and Intelligence floors from native exact PoB outputs", function()
		local parsed, err = Inputs.Parse({ Str = "155", Dex = "80", Int = "200" })
		assert.is_truthy(parsed, err)
		assert.are.equal("Str", parsed.hard.Str.metricKey)
		assert.are.equal("Dex", parsed.hard.Dex.metricKey)
		assert.are.equal("Int", parsed.hard.Int.metricKey)

		local below = Candidate.CopyMetrics({ Str = 154, Dex = 80, Int = 201 }, Inputs.metricDefinitions)
		local failed = Validator.Check(parsed, below)
		assert.is_false(failed.feasible)
		assert.are.equal(1, #failed.violations)
		assert.are.equal("Str", failed.violations[1].key)
		assert.are.equal(154, failed.violations[1].actual)

		local atBoundary = Candidate.CopyMetrics({ Str = 155, Dex = 80, Int = 200 }, Inputs.metricDefinitions)
		assert.is_true(Validator.Check(parsed, atBoundary).feasible, "exact boundary values satisfy inclusive hard floors")
		local missing = Candidate.CopyMetrics({ Dex = 80, Int = 200 }, Inputs.metricDefinitions)
		assert.is_false(Validator.Check(parsed, missing).feasible, "missing exact output must fail closed")
		local invalid = Inputs.Parse({ Int = "NaN" })
		assert.is_nil(invalid)
	end)

	it("enforces an Omniscience floor from the exact native PoB output", function()
		local parsed, err = Inputs.Parse({ Omni = "301" })
		assert.is_truthy(parsed, err)
		assert.are.equal("Omni", parsed.hard.Omni.metricKey)

		local below = Candidate.CopyMetrics({ Omni = 300.99 }, Inputs.metricDefinitions)
		local failed = Validator.Check(parsed, below)
		assert.is_false(failed.feasible)
		assert.are.equal(1, #failed.violations)
		assert.are.equal("Omni", failed.violations[1].key)
		assert.are.equal(300.99, failed.violations[1].actual)

		local atBoundary = Candidate.CopyMetrics({ Omni = 301 }, Inputs.metricDefinitions)
		assert.is_true(Validator.Check(parsed, atBoundary).feasible, "exact boundary values satisfy inclusive hard floors")
		local missing = Candidate.CopyMetrics({ }, Inputs.metricDefinitions)
		assert.is_false(Validator.Check(parsed, missing).feasible, "missing exact PoB output must fail closed")
		assert.is_nil(Inputs.Parse({ Omni = "Infinity" }))
	end)

	it("rejects unsupported focus values and node analysis outside the current-build Combined phase", function()
		local parsed, err = Inputs.Parse({ damageFocus = "ColdDotMaybe" })
		assert.is_nil(parsed)
		assert.is_truthy(err:find("Damage focus", 1, true))
		parsed, err = Inputs.Parse({ nodePotentialAnalysis = "true", generationPhase = "tree" })
		assert.is_nil(parsed)
		assert.is_truthy(err:find("Combined phase", 1, true))
	end)

	it("defaults to a 120-point optimizer ceiling and supports endgame caps through 130", function()
		assert.are.equal(120, assert(Inputs.Parse({ })).search.maxTotalPoints)
		assert.are.equal(118, assert(Inputs.Parse({ maxTotalPoints = "118" })).search.maxTotalPoints)
		assert.are.equal(120, assert(Inputs.Parse({ maxTotalPoints = "120" })).search.maxTotalPoints)
		assert.are.equal(123, assert(Inputs.Parse({ maxTotalPoints = "123" })).search.maxTotalPoints)
		assert.are.equal(130, assert(Inputs.Parse({ maxTotalPoints = "130" })).search.maxTotalPoints)
		assert.is_nil(Inputs.Parse({ maxTotalPoints = "131" }))
		assert.is_nil(Inputs.Parse({ maxTotalPoints = "2.5" }))
		assert.is_nil(Inputs.Parse({ maxTotalPoints = "0" }))
	end)

	it("allows a full 120-point fresh-tree search while rejecting values above the strict tree cap", function()
		assert.are.equal(120, assert(Inputs.Parse({ maxAddedPoints = "120" })).search.maxAddedPoints)
		local parsed, err = Inputs.Parse({ maxAddedPoints = "121" })
		assert.is_nil(parsed)
		assert.is_truthy(err:find("Maximum added points per proposal", 1, true))
	end)

	it("caps ascendancy-point assumptions by PoE level progression and accepts safer lower caps", function()
		assert.are.equal(0, Inputs.MaxAscendancyPointBudget(1))
		assert.are.equal(2, Inputs.MaxAscendancyPointBudget(33))
		assert.are.equal(4, Inputs.MaxAscendancyPointBudget(40))
		assert.are.equal(6, Inputs.MaxAscendancyPointBudget(50))
		assert.are.equal(8, Inputs.MaxAscendancyPointBudget(68))
		assert.is_nil(assert(Inputs.Parse({ })).search.ascendancyPointBudget)
		assert.is_nil(assert(Inputs.Parse({ ascendancyPointBudget = "Auto" })).search.ascendancyPointBudget)
		assert.are.equal(4, assert(Inputs.Parse({ ascendancyPointBudget = "4" })).search.ascendancyPointBudget)
		assert.is_nil(Inputs.Parse({ ascendancyPointBudget = "3" }))
		assert.is_nil(Inputs.Parse({ ascendancyPointBudget = "9" }))
		local parsed = assert(Inputs.Parse({ ascendancyPointBudget = "2" }))
		local valid, err = Inputs.ValidateBuild({ characterLevel = 1, spec = { allocNodes = { } }, skillsTab = { } }, parsed)
		assert.is_false(valid)
		assert.is_truthy(err:find("level 1 progression ceiling of 0", 1, true))
		parsed = assert(Inputs.Parse({ }))
		valid, err = Inputs.ValidateBuild({ characterLevel = 1, mainSocketGroup = 1,
			spec = { allocNodes = { } }, skillsTab = { socketGroupList = {
				{ enabled = true, slotEnabled = true, displaySkillList = { { activeEffect = { } } } },
			} } }, parsed)
		assert.is_true(valid, err)
		assert.are.equal(0, parsed.search.activeAscendancyPointBudget)
	end)

	it("parses an optional bounded manual-skill-button limit", function()
		assert.is_nil(assert(Inputs.Parse({ })).search.maxManualButtons)
		assert.are.equal(0, assert(Inputs.Parse({ maxManualButtons = "0" })).search.maxManualButtons)
		assert.are.equal(2, assert(Inputs.Parse({ maxManualButtons = "2" })).search.maxManualButtons)
		assert.are.equal(24, assert(Inputs.Parse({ maxManualButtons = "24" })).search.maxManualButtons)
		for _, value in ipairs({ "-1", "2.5", "25", "1e309", "many" }) do
			assert.is_nil(Inputs.Parse({ maxManualButtons = value }), "accepted manual button cap " .. value)
		end
	end)

	it("parses an optional bounded damage-action limit independently of total manual actions", function()
		assert.is_nil(assert(Inputs.Parse({ })).search.maxManualDamageButtons)
		assert.are.equal(2, assert(Inputs.Parse({ maxManualDamageButtons = "2" })).search.maxManualDamageButtons)
		assert.are.equal(0, assert(Inputs.Parse({ maxManualDamageButtons = "0" })).search.maxManualDamageButtons)
		for _, value in ipairs({ "-1", "2.5", "25", "1e309", "many" }) do
			assert.is_nil(Inputs.Parse({ maxManualDamageButtons = value }), "accepted manual damage-action cap " .. value)
		end
	end)

	it("parses only the supported exact PoB scenario profiles", function()
		assert.are.equal("Current", assert(Inputs.Parse({ })).scenarioProfile)
		assert.are.equal("PinnacleUnbuffed", assert(Inputs.Parse({ scenarioProfile = "pinnacleunbuffed" })).scenarioProfile)
		assert.are.equal("PinnacleChassis", assert(Inputs.Parse({ scenarioProfile = "pinnaclechassis" })).scenarioProfile)
		assert.are.equal("Active", assert(Inputs.Parse({ })).scenarioEnemyPreset)
		assert.are.equal("Uber", assert(Inputs.Parse({ scenarioEnemyPreset = "uBeR" })).scenarioEnemyPreset)
		assert.are.equal("Boss", assert(Inputs.Parse({ scenarioEnemyPreset = "Boss" })).scenarioEnemyPreset)
		assert.are.equal("Uber", assert(Inputs.Parse({ scenarioProfile = "PinnacleUnbuffed", scenarioEnemyPreset = "Uber" })).scenarioEnemyPreset)
		assert.is_nil(assert(Inputs.Parse({ })).scenarioEnemyLevel)
		assert.are.equal(85, assert(Inputs.Parse({ scenarioEnemyLevel = "85" })).scenarioEnemyLevel)
		assert.are.equal(68, assert(Inputs.Parse({ scenarioEnemyLevel = 68 })).scenarioEnemyLevel)
		assert.is_nil(Inputs.Parse({ scenarioEnemyPreset = "Nightmare" }))
		assert.is_nil(Inputs.Parse({ scenarioProfile = "PinnacleChassis", scenarioEnemyPreset = "Boss" }))
		for _, level in ipairs({ "0", "86", "1.5", "many", "1e309" }) do
			assert.is_nil(Inputs.Parse({ scenarioEnemyLevel = level }), "accepted PoB enemy level " .. level)
		end
		local legacy = assert(Inputs.Parse({ scenarioProfile = " ", objectiveMetric = "" }))
		assert.are.equal("Current", legacy.scenarioProfile)
		assert.are.equal("CombinedDPS", legacy.objective)
		assert.is_nil(Inputs.Parse({ scenarioProfile = "Approximate Pinnacle" }))
	end)

	it("parses explicit tree edits and rejects conflicting node constraints", function()
		local parsed = assert(Inputs.Parse({ addNodeIds = "10, 11", removeNodeIds = "12", requiredNodeIds = "10", forbiddenNodeIds = "13" }))
		assert.are.same({ 10, 11 }, parsed.search.addNodeIds)
		assert.are.same({ 12 }, parsed.search.removeNodeIds)
		assert.are.same({ 10 }, parsed.search.requiredNodeIds)
		assert.are.same({ 13 }, parsed.search.forbiddenNodeIds)
		assert.is_nil(Inputs.Parse({ addNodeIds = "10", removeNodeIds = "10" }))
		assert.is_nil(Inputs.Parse({ requiredNodeIds = "10", forbiddenNodeIds = "10" }))
		assert.is_nil(Inputs.Parse({ addNodeIds = "x" }))
	end)

	it("parses the visually selected base class and Main Skill indexes", function()
		local parsed = assert(Inputs.Parse({ baseClassId = "4", targetSkillGroupIndex = "2", targetSkillIndex = "3" }))
		assert.are.equal(4, parsed.search.baseClassId)
		assert.are.equal(2, parsed.search.targetSkillGroupIndex)
		assert.are.equal(3, parsed.search.targetSkillIndex)
		local valid, err = Inputs.ValidateAgainstTree(parsed, { classes = { [4] = { name = "Witch" } } })
		assert.is_true(valid, err)
		assert.is_nil(Inputs.Parse({ targetSkillGroupIndex = "2" }))
		assert.is_nil(Inputs.Parse({ targetSkillGroupIndex = "0", targetSkillIndex = "1" }))
		assert.is_nil(Inputs.Parse({ baseClassId = "4.5" }))

		local build = {
			spec = { allocNodes = { }, curClassId = 2 },
			skillsTab = { socketGroupList = {
				{ enabled = true, slotEnabled = true, displaySkillList = { { activeEffect = nil } } },
				{ enabled = true, slotEnabled = true, displaySkillList = { { activeEffect = nil }, { activeEffect = nil }, { activeEffect = { } } } },
			} },
		}
		local skillValid, skillError = Inputs.ValidateBuild(build, parsed)
		assert.is_true(skillValid, skillError)
		local invalidSelectedSkill = assert(Inputs.Parse({ objectiveMetric = "FullDPS", targetSkillGroupIndex = "2", targetSkillIndex = "4" }))
		local invalidSkillValid = Inputs.ValidateBuild(build, invalidSelectedSkill)
		assert.is_false(invalidSkillValid)
		local mutation = assert(Inputs.Parse({ baseClassId = "4", addNodeIds = "101" }))
		local mutationValid, mutationError = Inputs.ValidateAgainstBuild(mutation, build.spec)
		assert.is_false(mutationValid)
		assert.is_truthy(mutationError:find("cannot be combined", 1, true))
	end)

	it("parses ordered generation phases and rejects cross-phase Matrix mutations", function()
		assert.are.equal("combined", assert(Inputs.Parse({ })).search.generationPhase, "legacy direct parser callers retain the prior mixed search")
		for _, phase in ipairs({ "tree", "skills", "equipment", "combined" }) do
			assert.are.equal(phase, assert(Inputs.Parse({ generationPhase = phase })).search.generationPhase)
		end
		assert.is_nil(Inputs.Parse({ generationPhase = "neural" }))
		assert.is_nil(Inputs.Parse({ generationPhase = "tree", removeNodeIds = "123" }))
		assert.is_nil(Inputs.Parse({ generationPhase = "skills", addNodeIds = "123" }))
		assert.is_nil(Inputs.Parse({ generationPhase = "equipment", requiredRegions = "Witch" }))
		assert.is_nil(Inputs.Parse({ generationPhase = "skills", searchAllClasses = true }))

		local alternateClassTree = assert(Inputs.Parse({ generationPhase = "tree", baseClassId = "4", addNodeIds = "101" }))
		local validFoundation, foundationError = Inputs.ValidateAgainstBuild(alternateClassTree, { allocNodes = { }, curClassId = 2, nodes = { } })
		assert.is_true(validFoundation, foundationError)
		local alternateClassSkills = assert(Inputs.Parse({ generationPhase = "skills", baseClassId = "4" }))
		local validSkills, skillsError = Inputs.ValidateAgainstBuild(alternateClassSkills, { allocNodes = { }, curClassId = 2, nodes = { } })
		assert.is_false(validSkills)
		assert.is_truthy(skillsError:find("only available in the tree foundation", 1, true))
	end)

	it("parses the strict all-class search toggle and rejects conflicting direction", function()
		assert.is_true(assert(Inputs.Parse({ searchAllClasses = true })).search.searchAllClasses)
		assert.is_true(assert(Inputs.Parse({ searchAllClasses = "true" })).search.searchAllClasses)
		assert.is_false(assert(Inputs.Parse({ searchAllClasses = false })).search.searchAllClasses)
		assert.is_false(assert(Inputs.Parse({ searchAllClasses = "false" })).search.searchAllClasses)
		assert.is_nil(Inputs.Parse({ searchAllClasses = "yes" }))
		assert.is_nil(Inputs.Parse({ searchAllClasses = true, baseClassId = "4" }))
	end)

	it("requires a supported optimization objective and an enabled Main Skill", function()
		local invalidObjective = Inputs.Parse({ objectiveMetric = "unrounded display DPS" })
		assert.is_nil(invalidObjective)
		local valid, err = Inputs.ValidateBuild({ spec = { }, skillsTab = { socketGroupList = { } }, mainSocketGroup = 1 })
		assert.is_false(valid)
		assert.is_truthy(err:find("Main Skill", 1, true))
		local ready, readyError = Inputs.ValidateBuild({
			spec = { },
			mainSocketGroup = 1,
			skillsTab = { socketGroupList = { { enabled = true, slotEnabled = true, mainActiveSkill = 1, displaySkillList = { { activeEffect = { } } } } } },
		})
		assert.is_true(ready, readyError)
	end)

	it("allows full-build or defensive objectives without Main Skill but requires it for skill-specific gates", function()
		local buildWithoutMainSkill = {
			spec = { },
			skillsTab = { socketGroupList = { { enabled = true, slotEnabled = true, includeInFullDPS = true } } },
		}
		local fullDps = assert(Inputs.Parse({ objectiveMetric = "FullDPS" }))
		local fullValid, fullError = Inputs.ValidateBuild(buildWithoutMainSkill, fullDps)
		assert.is_true(fullValid, fullError)
		local defense = assert(Inputs.Parse({ objectiveMetric = "TotalEHP", TotalEHP = "100000" }))
		local defenseValid, defenseError = Inputs.ValidateBuild(buildWithoutMainSkill, defense)
		assert.is_true(defenseValid, defenseError)
		local triggerFloor = assert(Inputs.Parse({ objectiveMetric = "FullDPS", SkillTriggerRate = "6" }))
		local triggerValid, triggerError = Inputs.ValidateBuild(buildWithoutMainSkill, triggerFloor)
		assert.is_false(triggerValid)
		assert.is_truthy(triggerError:find("Main Skill", 1, true))
		local conversion = assert(Inputs.Parse({ objectiveMetric = "FullDPS", conversionRoute = "Physical>Cold" }))
		local conversionValid, conversionError = Inputs.ValidateBuild(buildWithoutMainSkill, conversion)
		assert.is_false(conversionValid)
		assert.is_truthy(conversionError:find("Main Skill", 1, true))
	end)

	it("supports selected-skill and full-build hit and DoT objectives", function()
		for _, metric in ipairs({ "FullDPS", "FullDotDPS" }) do
			local parsed = assert(Inputs.Parse({ objectiveMetric = metric, [metric] = "1000" }))
			assert.are.equal(metric, parsed.objective)
			local metrics = Candidate.CopyMetrics({ [metric] = 999 }, Inputs.metricDefinitions)
			assert.is_false(Validator.Check(parsed, metrics).feasible)
		end
		local fullParsed = assert(Inputs.Parse({ objectiveMetric = "FullDPS" }))
		local hasOutput, outputError = Inputs.ValidateObjective({
			skillsTab = { socketGroupList = { { includeInFullDPS = false, enabled = true, slotEnabled = true } } },
			calcsTab = { mainOutput = { FullDPS = 0 } },
		}, fullParsed)
		assert.is_false(hasOutput)
		assert.is_truthy(outputError:find("enable Include in Full DPS", 1, true))
		local hasDot, dotError = Inputs.ValidateObjective({
			skillsTab = { socketGroupList = { { includeInFullDPS = true, enabled = true, slotEnabled = true } } },
			calcsTab = { mainOutput = { FullDotDPS = 0 } },
		}, assert(Inputs.Parse({ objectiveMetric = "FullDotDPS" })))
		assert.is_false(hasDot)
		assert.is_truthy(dotError:find("FullDotDPS is 0", 1, true))
	end)

	it("rejects malformed route and impossible region filters", function()
		local malformed = Inputs.Parse({ conversionRoute = "Physical,Cold" })
		assert.is_nil(malformed)
		local wrongOrder = Inputs.Parse({ conversionRoute = "Cold>Physical" })
		assert.is_nil(wrongOrder)
		local parsed = assert(Inputs.Parse({ requiredRegions = "Witch", allowedRegions = "Ranger" }))
		local valid, err = Inputs.ValidateAgainstTree(parsed, { classes = { [1] = { name = "Witch" }, [2] = { name = "Ranger" } } })
		assert.is_false(valid)
		assert.is_truthy(err:find("outside the allowed", 1, true))
		local invalidTarget = assert(Inputs.Parse({ targetNodeIds = "999" }))
		local targetValid, targetError = Inputs.ValidateAgainstTree(invalidTarget, { classes = { }, nodes = { } })
		assert.is_false(targetValid)
		assert.is_truthy(targetError:find("does not exist", 1, true))
	end)

	it("rejects 9.9M DPS for 10M and 98% suppression for 100%", function()
		local parsed = assert(Inputs.Parse({ CombinedDPS = "10000000", SpellSuppressionChance = "100" }))
		local failed = Validator.Check(parsed, { CombinedDPS = 9900000, SpellSuppressionChance = 98 })
		assert.is_false(failed.feasible)
		assert.are.equal(2, #failed.violations)
		local passed = Validator.Check(parsed, { CombinedDPS = 10000000, SpellSuppressionChance = 100 })
		assert.is_true(passed.feasible)
	end)

	it("gates each resistance-overcap floor against the exact PoB output independently", function()
		local parsed = assert(Inputs.Parse({
			FireResistOverCap = "20",
			ColdResistOverCap = "35",
			LightningResistOverCap = "15",
			ChaosResistOverCap = "0",
		}))
		local nativeOutput = {
			FireResistOverCap = 20.5,
			ColdResistOverCap = 35.25,
			LightningResistOverCap = 15,
			ChaosResistOverCap = 0,
		}
		local metrics = Candidate.CopyMetrics(nativeOutput, Inputs.metricDefinitions)
		assert.are.equal(20.5, metrics.FireResistOverCap)
		assert.are.equal(35.25, metrics.ColdResistOverCap)
		assert.are.equal(15, metrics.LightningResistOverCap)
		assert.are.equal(0, metrics.ChaosResistOverCap)
		assert.is_true(Validator.Check(parsed, metrics).feasible)

		metrics.LightningResistOverCap = 14.99
		local failed = Validator.Check(parsed, metrics)
		assert.is_false(failed.feasible)
		assert.are.equal(1, #failed.violations)
		assert.are.equal("LightningResistOverCap", failed.violations[1].key)
		assert.are.equal(14.99, failed.violations[1].actual)
		assert.are.equal(15, failed.violations[1].required)
	end)

	it("supports exact upper bounds for life and mana reservation", function()
		local parsed = assert(Inputs.Parse({ ManaReservedMax = "800", LifeReservedPercentMax = "49" }))
		assert.are.equal("<=", parsed.hard.ManaReservedMax.operator)
		assert.are.equal("ManaReserved", parsed.hard.ManaReservedMax.metricKey)
		local failed = Validator.Check(parsed, { ManaReserved = 801, LifeReservedPercent = 50 })
		assert.is_false(failed.feasible)
		assert.are.equal("Above strict maximum", failed.violations[1].reason)
		local passed = Validator.Check(parsed, { ManaReserved = 800, LifeReservedPercent = 49 })
		assert.is_true(passed.feasible)
	end)

	it("rejects native attribute and level deficits and honors Omniscience requirements", function()
		local failed = Validator.CheckRequirements({ ReqLevel = 68, ReqStr = 155, Str = 154 }, 67)
		assert.is_false(failed.feasible)
		assert.are.equal(2, #failed.violations)
		assert.are.equal("level_requirement", failed.violations[1].key)
		local omni = Validator.CheckRequirements({ ReqLevel = 1, ReqOmni = 200, Omni = 199 }, 90)
		assert.is_false(omni.feasible)
		assert.are.equal("attribute_requirement_Omni", omni.violations[1].key)
		assert.is_true(Validator.CheckRequirements({ ReqLevel = 1, ReqOmni = 200, Omni = 200 }, 90).feasible)
		-- Native IgnoreAttributeRequirements resolves the Req* values to zero.
		assert.is_true(Validator.CheckRequirements({ ReqLevel = 1, ReqStr = 0, Str = 0 }, 90).feasible)
		assert.is_false(Validator.CheckRequirements({ }, 90).feasible)
	end)

	it("rejects non-finite inputs and non-finite exact metrics", function()
		assert.is_nil(Inputs.Parse({ CombinedDPS = "1e309" }))
		local parsed = assert(Inputs.Parse({ CombinedDPS = "100" }))
		local result = Validator.Check(parsed, { CombinedDPS = math.huge })
		assert.is_false(result.feasible)
		assert.are.equal("Exact calculation returned a non-finite metric", result.violations[1].reason)
	end)

	it("uses the exact skill conversion table and refuses unsupported trigger floors", function()
		local result = Conversion.Evaluate({ conversionTable = {
			Physical = { conversion = { Lightning = 1 } },
			Lightning = { conversion = { Cold = 1 } },
		} }, { "Physical", "Lightning", "Cold" }, 100)
		assert.is_true(result.satisfied)
		assert.are.equal(2, #result.edges)
		local unsupported = Breakpoints.Evaluate({ skillFlags = { } }, { }, 1)
		assert.are.equal("unsupported", unsupported.status)
	end)

	it("compares effective trigger rates without confusing Trigger Bot rate with cooldown cap", function()
		local triggerBots = Breakpoints.Evaluate({ skillFlags = { } }, {
			SkillTriggerRate = 15.13,
			TriggerRateCap = 7.57575757576,
		}, 15)
		assert.are.equal("valid", triggerBots.status)
		assert.are.equal(15.13, triggerBots.triggerRate)
		assert.are.equal(7.57575757576, triggerBots.cap)

		local belowFloor = Breakpoints.Evaluate({ skillFlags = { } }, {
			SkillTriggerRate = 14.99,
			TriggerRateCap = 7.57575757576,
		}, 15)
		assert.are.equal("violated", belowFloor.status)
		assert.are.equal(1, #belowFloor.violations)
	end)

	it("does not certify event-driven trigger cadence from a cooldown ceiling", function()
		local EventTriggerModel = require("Modules.Optimizer.EventTriggerModel")
		local eventTriggers = {
			{ name = "Cast when Damage Taken", data = { triggeredByDamageTaken = 528 }, reason = "incoming damage-event cadence" },
			{ name = "Cast when Stunned", data = { chanceToTriggerOnStun = 100 }, reason = "stun-event cadence" },
			{ name = "Cast on Ward Break", data = { chanceToTriggerOnWardBreak = 100 }, reason = "Ward-break event cadence" },
		}
		for _, trigger in ipairs(eventTriggers) do
			local activeSkill = {
				triggeredBy = { grantedEffect = { name = trigger.name } },
				skillData = trigger.data,
			}
			local reason = assert(EventTriggerModel.GetUnsupportedReason(activeSkill))
			assert.is_truthy(reason:find(trigger.reason, 1, true), trigger.name .. " must explain its missing event model")
			local result = Breakpoints.Evaluate(activeSkill, { SkillTriggerRate = 100, TriggerRateCap = 100 }, 50)
			assert.are.equal("unsupported", result.status, trigger.name .. " cooldown cap is not its event frequency")
		end
		local cooldownTrigger = Breakpoints.Evaluate({ triggeredBy = { grantedEffect = { name = "Cast On Critical Strike" } } }, {
			SkillTriggerRate = 2,
			TriggerRateCap = 3,
		}, 1)
		assert.are.equal("valid", cooldownTrigger.status, "supported cooldown-driven CoC rate remains certifiable")
	end)

	it("refuses sustained-DPS certification when the selected skill is Vaal", function()
		local vaalType = SkillType and SkillType.Vaal or "Vaal"
		local result = SkillAvailability.Evaluate({ objective = "CombinedDPS", hard = { } }, {
			mainSkill = { skillTypes = { [vaalType] = true }, activeEffect = { grantedEffect = { name = "Vaal Cold Snap" } } },
			activeSkillList = { },
		})
		assert.are.equal("unsupported", result.status)
		assert.is_false(result.feasible)
		assert.are.same({ "Vaal Cold Snap" }, result.unsupportedSkills)
	end)

	it("checks only enabled Vaal modes included in FullDPS", function()
		local vaalType = SkillType and SkillType.Vaal or "Vaal"
		local vaalEffect = { name = "Vaal Cold Snap" }
		local gem = {
			enabled = true,
			gemData = { vaalGem = true, grantedEffectList = { vaalEffect } },
			enableGlobal1 = true,
		}
		local activeSkill = {
			skillTypes = { [vaalType] = true },
			activeEffect = { grantedEffect = vaalEffect },
			socketGroup = { includeInFullDPS = true, enabled = true, gemList = { gem } },
		}
		local parsed = { objective = "FullDPS", hard = { } }
		assert.are.equal("unsupported", SkillAvailability.Evaluate(parsed, { activeSkillList = { activeSkill } }).status)
		activeSkill.socketGroup.includeInFullDPS = false
		assert.are.equal("valid", SkillAvailability.Evaluate(parsed, { activeSkillList = { activeSkill } }).status)
		activeSkill.socketGroup.includeInFullDPS = true
		gem.enableGlobal1 = false
		assert.are.equal("valid", SkillAvailability.Evaluate(parsed, { activeSkillList = { activeSkill } }).status)
	end)

	it("honors hard DPS floors even when the search objective is defensive", function()
		local vaalType = SkillType and SkillType.Vaal or "Vaal"
		local result = SkillAvailability.Evaluate({ objective = "TotalEHP", hard = {
			FullDotDPS = { metricKey = "FullDotDPS", value = 1000000 },
		} }, {
			activeSkillList = { {
				skillTypes = { [vaalType] = true },
				activeEffect = { grantedEffect = { name = "Vaal Cold Snap" } },
				socketGroup = { includeInFullDPS = true, enabled = true, gemList = { } },
			} },
		})
		assert.are.equal("unsupported", result.status)
		assert.are.same({ "FullDotDPS" }, result.metrics)
	end)

	it("does not gate Vaal availability for a non-DPS objective", function()
		local vaalType = SkillType and SkillType.Vaal or "Vaal"
		local result = SkillAvailability.Evaluate({ objective = "TotalEHP", hard = { } }, {
			mainSkill = { skillTypes = { [vaalType] = true } }, activeSkillList = { },
		})
		assert.are.equal("not_required", result.status)
		assert.is_true(result.feasible)
	end)

	it("fails closed for sustained DPS through an unsupported Ward-break loop", function()
		local activeSkill = {
			activeEffect = { grantedEffect = { name = "Blade Blast of Unloading" } },
			socketGroup = {
				includeInFullDPS = true,
				enabled = true,
				slotEnabled = true,
				gemList = { { enabled = true, gemData = { variantId = "SupportCastOnWardBreak" } } },
			},
		}
		local parsed = { objective = "FullDPS", hard = { } }
		local rejected = SkillAvailability.Evaluate(parsed, { activeSkillList = { activeSkill } })
		assert.are.equal("unsupported", rejected.status)
		assert.is_false(rejected.feasible)
		assert.is_truthy(rejected.reason:find("Ward%-break and Ward%-refill cadence"))

		activeSkill.socketGroup.includeInFullDPS = false
		assert.are.equal("valid", SkillAvailability.Evaluate(parsed, { activeSkillList = { activeSkill } }).status)
		assert.are.equal("not_required", SkillAvailability.Evaluate({ objective = "TotalEHP", hard = { } }, {
			mainSkill = activeSkill,
			activeSkillList = { activeSkill },
		}).status)
	end)

	it("certifies selected Trauma only at or below PoB's exact sustainable limit", function()
		local parsed = { objective = "CombinedDPS", hard = { } }
		local player = { mainSkill = traumaSkill("Boneshatter", 23.1495732), activeSkillList = { } }
		local atLimit = SkillAvailability.Evaluate(parsed, player, nil, { SustainableTrauma = 23.1495732 })
		assert.are.equal("valid", atLimit.status)
		local overLimit = traumaSkill("Boneshatter", 30)
		player.mainSkill = overLimit
		local rejected = SkillAvailability.Evaluate(parsed, player, nil, { SustainableTrauma = 23.1495732 })
		assert.are.equal("violated", rejected.status)
		assert.is_false(rejected.feasible)
		assert.are.equal(1, #rejected.unsustainableTraumaSkills)
		assert.are.equal(30, rejected.unsustainableTraumaSkills[1].configuredStacks)
		assert.are.equal(23.1495732, rejected.unsustainableTraumaSkills[1].sustainableStacks)
	end)

	it("rejects Complex Trauma when the next hit reaches its PoB reset threshold", function()
		local parsed = { objective = "CombinedDPS", hard = { } }
		local selectedOutput = { SustainableTrauma = 9.06984, Repeats = 1 }
		local player = { mainSkill = traumaSkill("Boneshatter of Complex Trauma", 9, 10), activeSkillList = { } }
		local rejected = SkillAvailability.Evaluate(parsed, player, nil, selectedOutput)
		assert.are.equal("violated", rejected.status)
		assert.is_false(rejected.feasible)
		assert.are.equal(1, #rejected.traumaResetRisks)
		assert.are.equal(10, rejected.traumaResetRisks[1].resetThreshold)
		assert.are.equal(1, rejected.traumaResetRisks[1].maximumTraumaPerUse)
		assert.is_truthy(rejected.reason:find("reset threshold 10", 1, true))
		local bothGates = SkillAvailability.Evaluate(parsed, player, nil, { SustainableTrauma = 8, Repeats = 1 })
		assert.is_truthy(bothGates.reason:find("exceeds PoB's sustainable limit 8", 1, true))
		assert.is_truthy(bothGates.reason:find("reset threshold 10", 1, true))

		player.mainSkill = traumaSkill("Boneshatter of Complex Trauma", 8, 10)
		local belowReset = SkillAvailability.Evaluate(parsed, player, nil, selectedOutput)
		assert.are.equal("valid", belowReset.status)
		assert.are.equal(0, #belowReset.traumaResetRisks)
	end)

	it("uses possible bonus Trauma and every repeat when checking a reset cap", function()
		local parsed = { objective = "CombinedDPS", hard = { } }
		local player = { mainSkill = traumaSkill("Boneshatter of Complex Trauma", 8, 10, 1), activeSkillList = { } }
		local extraTrauma = SkillAvailability.Evaluate(parsed, player, nil, { SustainableTrauma = 9.5, Repeats = 1 })
		assert.are.equal("violated", extraTrauma.status)
		assert.are.equal(2, extraTrauma.traumaResetRisks[1].maximumTraumaPerUse)

		player.mainSkill = traumaSkill("Boneshatter of Complex Trauma", 8, 10)
		local repeated = SkillAvailability.Evaluate(parsed, player, nil, { SustainableTrauma = 9.5, Repeats = 2 })
		assert.are.equal("violated", repeated.status)
		assert.are.equal(2, repeated.traumaResetRisks[1].maximumTraumaPerUse)
	end)

	it("certifies FullDPS Trauma from PoB's per-skill output and fails closed if it is missing", function()
		local activeSkill = traumaSkill("Boneshatter", 30)
		activeSkill.socketGroup = { includeInFullDPS = true, enabled = true, slotEnabled = true, gemList = { } }
		local player = { activeSkillList = { activeSkill } }
		local parsed = { objective = "FullDPS", hard = { } }
		local exactOutput = { { name = "Boneshatter", configuredStacks = 30, sustainableStacks = 23.1495732,
			maximumStacks = 0, extraTraumaChance = 0, repeats = 1 } }
		local rejected = SkillAvailability.Evaluate(parsed, player, exactOutput)
		assert.are.equal("violated", rejected.status)
		assert.are.equal("Boneshatter", rejected.unsustainableTraumaSkills[1].name)
		assert.are.equal("unsupported", SkillAvailability.Evaluate(parsed, player).status)
		local missingResetMetadata = { { name = "Boneshatter", configuredStacks = 8, sustainableStacks = 9,
			maximumStacks = 10 } }
		assert.are.equal("unsupported", SkillAvailability.Evaluate(parsed, player, missingResetMetadata).status)
		activeSkill.socketGroup.includeInFullDPS = false
		assert.are.equal("valid", SkillAvailability.Evaluate(parsed, player).status)
	end)

	it("does not apply Trauma availability checks to non-DPS objectives", function()
		local result = SkillAvailability.Evaluate({ objective = "TotalEHP", hard = { } }, {
			mainSkill = traumaSkill("Boneshatter", 30), activeSkillList = { },
		})
		assert.are.equal("not_required", result.status)
		assert.is_true(result.feasible)
	end)

	it("finds a connected route and excludes forbidden regions", function()
		local a = { id = 1, x = 0, y = 0, type = "ClassStart", linked = { } }
		local b = { id = 2, x = 1, y = 0, type = "Normal", linked = { } }
		local c = { id = 3, x = 2, y = 0, type = "Notable", linked = { } }
		a.linked = { b }
		b.linked = { a, c }
		c.linked = { b }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = { [1] = a, [2] = b, [3] = c },
			allocNodes = { [1] = a },
			jewels = { }, masterySelections = { }, hashOverrides = { },
		}
		local parsed = { branch = { required = { }, allowed = { "Witch" }, forbidden = { } }, search = { seed = 1, maxAddedPoints = 3 } }
		local candidates = TreeSearch.BuildCandidateNodes(spec, parsed, 1)
		assert.are.equal(1, #candidates)
		assert.are.equal(2, candidates[1].nodeIds[1])
		assert.are.equal(3, candidates[1].nodeIds[2])
		assert.is_true(TreeSearch.ValidateCandidate(spec, candidates[1].nodeIds, parsed))
		parsed.targetNodeIds = { 3 }
		local targetCandidates = TreeSearch.BuildCandidateNodes(spec, parsed, 1)
		assert.are.equal(1, #targetCandidates)
		assert.are.equal(3, targetCandidates[1].targetId)
		assert.are.same({ 2, 3 }, targetCandidates[1].nodeIds)
		parsed.branch.forbidden = { "Witch" }
		assert.is_false(TreeSearch.ValidateCandidate(spec, candidates[1].nodeIds, parsed))
	end)

	it("uses compatible imported edge patterns only to break equal-cost tree-route ties", function()
		local start = { id = 1, type = "ClassStart", linked = { } }
		local leftA = { id = 2, type = "Normal", linked = { } }
		local rightA = { id = 3, type = "Normal", linked = { } }
		local leftB = { id = 4, type = "Normal", linked = { } }
		local rightB = { id = 5, type = "Normal", linked = { } }
		local target = { id = 6, type = "Notable", linked = { } }
		start.linked = { leftA, rightA }
		leftA.linked, rightA.linked = { start, leftB }, { start, rightB }
		leftB.linked, rightB.linked = { leftA, target }, { rightA, target }
		target.linked = { leftB, rightB }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = { [1] = start, [2] = leftA, [3] = rightA, [4] = leftB, [5] = rightB, [6] = target },
			allocNodes = { [1] = start },
		}
		local parsed = assert(Inputs.Parse({ targetNodeIds = "6", maxAddedPoints = "3", seed = "13" }))
		local baseline = assert(TreeSearch.BuildCandidateNodes(spec, parsed, 1, nil, 3))
		assert.are.same({ 2, 4, 6 }, baseline[1].nodeIds, "the deterministic unassisted tie should retain its stable route")

		parsed.search.edgeEvidencePriorities = { ["1:3"] = 1, ["3:5"] = 1, ["5:6"] = 1 }
		parsed.search.importedRouteMemoryEnabled = false
		local optedOut = assert(TreeSearch.BuildCandidateNodes(spec, parsed, 1, nil, 3))
		assert.are.same(baseline[1].nodeIds, optedOut[1].nodeIds, "stored evidence must be inert when the user disables it")

		parsed.search.importedRouteMemoryEnabled = true
		local observed = assert(TreeSearch.BuildCandidateNodes(spec, parsed, 1, nil, 3))
		assert.are.same({ 3, 5, 6 }, observed[1].nodeIds, "compatible observed edges may win only the equal-cost path tie")
		assert.is_true(TreeSearch.ValidateCandidate(spec, observed[1].nodeIds, parsed), "the observed route still has to be legal and connected")
	end)

	it("interleaves distinct passive goals and builds a legal progressive route bundle", function()
		local start = { id = 1, x = 0, y = 0, type = "ClassStart", linked = { } }
		local fire = { id = 2, x = 1, y = -1, type = "Notable", dn = "Fire Damage", linked = { } }
		local life = { id = 3, x = 1, y = 0, type = "Notable", dn = "Maximum Life", linked = { } }
		local cast = { id = 4, x = 1, y = 1, type = "Notable", dn = "Cast Speed", linked = { } }
		start.linked = { fire, life, cast }
		fire.linked, life.linked, cast.linked = { start }, { start }, { start }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = start.id } } },
			nodes = { [1] = start, [2] = fire, [3] = life, [4] = cast },
			allocNodes = { [start.id] = start },
			jewels = { }, masterySelections = { }, hashOverrides = { },
		}
		local parsed = assert(Inputs.Parse({ maxAddedPoints = "6", seed = "19" }))
		local regionByNode = TreeSearch.BuildRegionMap(spec)
		local routes = TreeSearch.BuildCandidateNodes(spec, parsed, 3, nil, 6, nil, regionByNode)
		assert.are.equal(3, #routes)
		assert.are.same({ 2, 3, 4 }, { routes[1].targetId, routes[2].targetId, routes[3].targetId },
			"A small route quota must inspect distinct targets before tie variants of one target")
		local combined = TreeSearch.CombineCandidates(routes, 4, 6)
		local progressive
		for _, candidate in ipairs(combined) do
			if candidate.progressiveRouteBundle then progressive = candidate break end
		end
		assert.is_truthy(progressive, "The reserved combination quota should include a multi-goal route portfolio")
		assert.are.equal(3, progressive.routeCount)
		assert.are.same({ 2, 3, 4 }, progressive.nodeIds)
		assert.is_true(TreeSearch.ValidateCandidate(spec, progressive.nodeIds, parsed, regionByNode))
	end)

	it("uses a shared bounded path field for large route pools and validates every generated target", function()
		local start = { id = 1, type = "ClassStart", linked = { } }
		local nodes = { [start.id] = start }
		for index = 1, 192 do
			local nodeId = index + 1
			local node = { id = nodeId, type = index == 192 and "Notable" or "Normal", linked = { start } }
			nodes[nodeId] = node
			start.linked[#start.linked + 1] = node
		end
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = start.id } } },
			nodes = nodes,
			allocNodes = { [start.id] = start },
			jewels = { }, masterySelections = { }, hashOverrides = { },
		}
		local parsed = assert(Inputs.Parse({ maxAddedPoints = "1", seed = "19" }))
		local expandedCallbacks = 0
		local candidates = TreeSearch.BuildCandidateNodes(spec, parsed, 150, function(_, _, expanded)
			if (expanded or 0) > 0 then expandedCallbacks = expandedCallbacks + 1 end
		end, 1)
		assert.are.equal(150, #candidates)
		assert.is_true(expandedCallbacks > 0,
			"the shared field must yield during large-tree expansion so progress and cancellation remain responsive")
		local targets = { }
		for _, candidate in ipairs(candidates) do
			assert.are.equal(1, #candidate.nodeIds)
			assert.are.equal(candidate.nodeIds[1], candidate.targetId)
			assert.is_nil(targets[candidate.targetId], "the bounded pool must deduplicate target routes")
			targets[candidate.targetId] = true
			assert.is_true(TreeSearch.ValidateCandidate(spec, candidate.nodeIds, parsed),
				"shared-field routes still require native tree connectivity")
		end
	end)

	it("keeps a full-tree passive route within the native point ceiling using safe leaf exchanges", function()
		local nodes = { }
		local function add(node) nodes[node.id] = node; return node end
		local start = add({ id = 1, type = "ClassStart", linked = { } })
		local routeAnchor = add({ id = 2, type = "Normal", linked = { } })
		local lowValueLeaf = add({ id = 3, type = "Normal", linked = { } })
		local otherBranch = add({ id = 4, type = "Normal", linked = { } })
		local otherBranchLink = add({ id = 5, type = "Normal", linked = { } })
		local otherBranchLeaf = add({ id = 6, type = "Normal", linked = { } })
		local firstAdded = add({ id = 7, type = "Normal", linked = { } })
		local secondAdded = add({ id = 8, type = "Notable", linked = { } })
		start.linked = { routeAnchor, otherBranch }
		routeAnchor.linked = { start, lowValueLeaf, firstAdded }
		lowValueLeaf.linked = { routeAnchor }
		otherBranch.linked = { start, otherBranchLink }
		otherBranchLink.linked = { otherBranch, otherBranchLeaf }
		otherBranchLeaf.linked = { otherBranchLink }
		firstAdded.linked = { routeAnchor, secondAdded }
		secondAdded.linked = { firstAdded }
		local spec = {
			nodes = nodes,
			allocNodes = { [1] = start, [2] = routeAnchor, [3] = lowValueLeaf,
				[4] = otherBranch, [5] = otherBranchLink, [6] = otherBranchLeaf },
			jewels = { },
			CountAllocNodes = function() return 6, 0, 0 end,
		}
		local candidate = { nodeIds = { 7, 8 }, label = "progressive route", progressiveRouteBundle = true }
		local inputs = { branch = { required = { }, allowed = { }, forbidden = { } }, search = { }, preferences = { } }
		local budgeted, coverage = TreeSearch.BudgetCandidatesForPointLimit(spec, { candidate }, inputs, 6)
		assert.are.equal(1, #budgeted)
		assert.are.equal(1, coverage.adjustedCandidates)
		assert.are.equal(2, #budgeted[1].removeNodeIds)
	assert.is_false(budgeted[1].removeNodeIds[1] == 2 or budgeted[1].removeNodeIds[2] == 2,
			"the route's existing anchor must not be removed")
		assert.are.equal(6, budgeted[1].pointBudgetLimit)
		assert.is_true(budgeted[1].label:find("replace 2 leaf points", 1, true) ~= nil)
		assert.are.equal(0, #(candidate.removeNodeIds or { }), "budgeting must not mutate the source proposal")
	end)

	it("truncates a progressive route at the exact point ceiling without breaking connectivity", function()
		local nodes = { }
		local function add(node) nodes[node.id] = node; return node end
		local start = add({ id = 1, type = "ClassStart", x = 0, y = 0, linked = { } })
		for branch = 0, 2 do
			local firstId = 2 + branch * 2
			local first = add({ id = firstId, type = "Normal", x = branch + 1, y = branch, linked = { } })
			local target = add({ id = firstId + 1, type = "Notable", x = branch + 2, y = branch, linked = { } })
			start.linked[#start.linked + 1] = first
			first.linked = { start, target }
			target.linked = { first }
		end
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = start.id } } },
			nodes = nodes,
			allocNodes = { [start.id] = start },
			jewels = { }, masterySelections = { }, hashOverrides = { },
		}
		local routes = {
			{ targetId = 3, targetRegion = "Witch", nodeIds = { 2, 3 }, label = "Fire" },
			{ targetId = 5, targetRegion = "Witch", nodeIds = { 4, 5 }, label = "Life" },
			{ targetId = 7, targetRegion = "Witch", nodeIds = { 6, 7 }, label = "Cast" },
		}
		local parsed = assert(Inputs.Parse({ maxAddedPoints = "5" }))
		local combined = TreeSearch.CombineCandidates(routes, 4, 5)
		local progressive
		for _, candidate in ipairs(combined) do
			if candidate.progressiveRouteBundle then progressive = candidate break end
		end
		assert.is_truthy(progressive)
		assert.are.equal(5, #progressive.nodeIds)
		assert.are.equal(3, progressive.routeCount)
		assert.is_true(TreeSearch.ValidateCandidate(spec, progressive.nodeIds, parsed))
	end)

	it("filters a route that closes a new class-origin loop while keeping later branches", function()
		local nodes = { }
		local function add(node) nodes[node.id] = node; return node end
		local start = add({ id = 1, type = "ClassStart", x = 0, y = 0, linked = { } })
		local loopA = add({ id = 2, type = "Normal", x = 1, y = 0, linked = { } })
		local loopB = add({ id = 3, type = "Normal", x = 1, y = 1, linked = { } })
		loopA.linked, loopB.linked = { start, loopB }, { start, loopA }
		start.linked = { loopA, loopB }
		local routeNodeIds = { }
		for branch = 0, 2 do
			local firstId = 4 + branch * 2
			local first = add({ id = firstId, type = "Normal", x = branch + 1, y = branch + 2, linked = { } })
			local target = add({ id = firstId + 1, type = "Notable", x = branch + 2, y = branch + 2, linked = { } })
			start.linked[#start.linked + 1] = first
			first.linked = { start, target }
			target.linked = { first }
			routeNodeIds[#routeNodeIds + 1] = { firstId, firstId + 1 }
		end
		local spec = {
			tree = { nodes = nodes, classes = { [1] = { name = "Witch", startNodeId = start.id } } },
			nodes = nodes,
			allocNodes = { [start.id] = start },
			curClass = { name = "Witch", startNodeId = start.id },
			jewels = { }, masterySelections = { }, hashOverrides = { },
		}
		local routes = {
			{ targetId = 2, targetRegion = "Witch", nodeIds = { 2 }, label = "Loop A" },
			{ targetId = 3, targetRegion = "Witch", nodeIds = { 3 }, label = "Loop B" },
		}
		for index, path in ipairs(routeNodeIds) do
			routes[#routes + 1] = { targetId = path[2], targetRegion = "Witch", nodeIds = path, label = "Branch " .. index }
		end
		local parsed = assert(Inputs.Parse({ maxAddedPoints = "5" }))
		local combined = TreeSearch.CombineCandidates(routes, 4, 5, spec, start.id)
		local progressive
		for _, candidate in ipairs(combined) do
			if candidate.progressiveRouteBundle then progressive = candidate break end
		end
		assert.is_truthy(progressive)
		assert.is_true(progressive.cycleFilteredRouteCount > 0)
		assert.is_false(table.concat(progressive.nodeIds, ","):find(",2,3,", 1, true) ~= nil)
		assert.is_true(TreeSearch.ValidateCandidate(spec, progressive.nodeIds, parsed))
	end)

	it("builds a complete spatial partition and routes through the costed hub into the selected quadrant", function()
		local nodes = { }
		local function addNode(node)
		nodes[node.id] = node
		return node
		end
		local start = addNode({ id = 1, x = 0, y = 0, type = "ClassStart", linked = { } })
		local otherStart = addNode({ id = 1000, x = -100, y = 0, type = "ClassStart", linked = { } })
		local previous = start
		for index = 1, 20 do
			local node = addNode({
				id = index + 1,
				x = -14 * index,
				y = -14 * index,
				type = index == 20 and "Notable" or "Normal",
				linked = { },
			})
			previous.linked[#previous.linked + 1] = node
			node.linked[#node.linked + 1] = previous
			previous = node
		end
		local northEast = addNode({ id = 2001, x = 300, y = -300, type = "Notable", linked = { } })
		local southWest = addNode({ id = 2002, x = -300, y = 300, type = "Notable", linked = { } })
		local southEast = addNode({ id = 2003, x = 300, y = 300, type = "Notable", linked = { } })
		local spec = {
			tree = { version = "fixture", nodes = nodes, classes = {
				[1] = { name = "Scion", startNodeId = start.id },
				[2] = { name = "Witch", startNodeId = otherStart.id },
			} },
			treeVersion = "fixture",
			nodes = nodes,
			allocNodes = { [start.id] = start },
			curClass = { name = "Scion", startNodeId = start.id },
			curClassId = 1,
		}
		local regions, coverage = TreeSearch.BuildRegionMap(spec, "spatial")
		assert.is_truthy(regions)
		assert.are.equal("spatial-v1", coverage.partitionVersion)
		assert.are.equal(25, coverage.totalNodeCount)
		assert.are.equal(25, coverage.assignedNodeCount)
		assert.are.equal(0, coverage.unassignedNodeCount)
		assert.are.equal("Hub", regions[start.id])
		assert.are.equal("NorthWest", regions[21])
		assert.are.equal("NorthEast", regions[northEast.id])
		assert.are.equal("SouthWest", regions[southWest.id])
		assert.are.equal("SouthEast", regions[southEast.id])

		local parsed = assert(Inputs.Parse({ allowedRegions = "NW", targetNodeIds = "21", maxAddedPoints = "24" }))
		local validTree, treeError = Inputs.ValidateAgainstTree(parsed, spec.tree)
		assert.is_true(validTree, treeError)
		assert.are.equal("spatial", parsed.branch.partition)
		assert.are.same({ "NorthWest" }, parsed.branch.allowed)
		local candidates, pathError = TreeSearch.BuildCandidateNodes(spec, parsed, 1, nil, 24, nil, regions)
		assert.is_nil(pathError)
		assert.are.equal(1, #candidates)
		assert.is_true(#candidates[1].nodeIds > 7, "the selected quadrant path should pay for its hub connectors")
		for _, nodeId in ipairs(candidates[1].nodeIds) do
			assert.is_true(regions[nodeId] == "Hub" or regions[nodeId] == "NorthWest", "route escaped its spatial mask at node " .. tostring(nodeId))
		end
		assert.is_true(TreeSearch.ValidateCandidate(spec, candidates[1].nodeIds, parsed, regions))

		local mixed = assert(Inputs.Parse({ allowedRegions = "Witch, NW" }))
		local validMixed, mixedError = Inputs.ValidateAgainstTree(mixed, spec.tree)
		assert.is_false(validMixed)
		assert.is_truthy(mixedError:find("not both", 1, true))
	end)

	it("preserves A-star allocation order when node IDs sort before their connectors", function()
		local start = { id = 1, x = 0, y = 0, type = "ClassStart", linked = { } }
		local connector = { id = 90, x = 1, y = 0, type = "Normal", linked = { } }
		local target = { id = 3, x = 2, y = 0, type = "Notable", linked = { } }
		start.linked = { connector }
		connector.linked = { start, target }
		target.linked = { connector }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = { [1] = start, [3] = target, [90] = connector },
			allocNodes = { [1] = start },
		}
		local parsed = assert(Inputs.Parse({ targetNodeIds = "3", maxAddedPoints = "2" }))
		local candidates = TreeSearch.BuildCandidateNodes(spec, parsed, 1, nil, 2)
		assert.are.same({ 90, 3 }, candidates[1].nodeIds)
		assert.is_true(TreeSearch.ValidateCandidate(spec, candidates[1].nodeIds, parsed))
		local valid, err = TreeSearch.ValidateCandidate(spec, { 90 }, parsed)
		assert.is_false(valid)
		assert.is_truthy(err:find("omits the requested target", 1, true))
	end)

	it("does not route through another class start node", function()
		local start = { id = 1, x = 0, y = 0, type = "ClassStart", linked = { } }
		local foreignStart = { id = 2, x = 1, y = 0, type = "ClassStart", linked = { } }
		local connector = { id = 90, x = 1, y = 1, type = "Normal", linked = { } }
		local target = { id = 3, x = 2, y = 0, type = "Notable", linked = { } }
		start.linked = { foreignStart, connector }
		foreignStart.linked = { start, target }
		connector.linked = { start, target }
		target.linked = { foreignStart, connector }
		local spec = {
			tree = { classes = {
				[1] = { name = "Witch", startNodeId = 1 },
				[2] = { name = "Marauder", startNodeId = 2 },
			} },
			nodes = { [1] = start, [2] = foreignStart, [3] = target, [90] = connector },
			allocNodes = { [1] = start },
		}
		local parsed = assert(Inputs.Parse({ targetNodeIds = "3", maxAddedPoints = "2" }))
		local candidates = TreeSearch.BuildCandidateNodes(spec, parsed, 1, nil, 2)
		assert.are.same({ 90, 3 }, candidates[1].nodeIds)
		assert.is_true(TreeSearch.ValidateCandidate(spec, candidates[1].nodeIds, parsed))
	end)

	it("rejects newly closed main-tree cycles but preserves cycles already in the source build", function()
		local start = { id = 1, type = "ClassStart", linked = { } }
		local first = { id = 2, type = "Normal", linked = { } }
		local closing = { id = 3, type = "Normal", linked = { } }
		start.linked, first.linked, closing.linked = { first, closing }, { start, closing }, { start, first }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = { [1] = start, [2] = first, [3] = closing },
			allocNodes = { [1] = start, [2] = first },
		}
		local parsed = assert(Inputs.Parse({ }))
		local regions = { [1] = "Witch", [2] = "Witch", [3] = "Witch", [4] = "Witch" }
		local invalid, reason = TreeSearch.ValidateCandidate(spec, { 3 }, parsed, regions)
		assert.is_false(invalid)
		assert.is_truthy(reason:lower():find("one-way routing policy", 1, true))
		assert.is_truthy(reason:find("adds 1 origin cycle", 1, true))

		local tail = { id = 4, type = "Normal", linked = { closing } }
		closing.linked[#closing.linked + 1] = tail
		spec.nodes[4] = tail
		spec.allocNodes[3] = closing
		local valid, legacyReason = TreeSearch.ValidateCandidate(spec, { 4 }, parsed, regions)
		assert.is_true(valid, legacyReason)
	end)

	it("allows a newly closed branch cycle when it does not return to the selected class start", function()
		local start = { id = 1, type = "ClassStart", linked = { } }
		local connector = { id = 2, type = "Normal", linked = { } }
		local first = { id = 3, type = "Normal", linked = { } }
		local closing = { id = 4, type = "Normal", linked = { } }
		start.linked = { connector }
		connector.linked = { start, first, closing }
		first.linked = { connector, closing }
		closing.linked = { connector, first }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = { [1] = start, [2] = connector, [3] = first, [4] = closing },
			allocNodes = { [1] = start, [2] = connector, [3] = first },
		}
		local parsed = assert(Inputs.Parse({ }))
		local regions = { [1] = "Witch", [2] = "Witch", [3] = "Witch", [4] = "Witch" }
		local valid, reason = TreeSearch.ValidateCandidate(spec, { 4 }, parsed, regions)
		assert.is_true(valid, reason)
	end)

	it("detects a second origin loop in a separate biconnected block sharing only the class start", function()
		local start = { id = 1, type = "ClassStart", linked = { } }
		local firstA = { id = 2, type = "Normal", linked = { } }
		local firstB = { id = 3, type = "Normal", linked = { } }
		local secondA = { id = 4, type = "Normal", linked = { } }
		local secondB = { id = 5, type = "Normal", linked = { } }
		start.linked = { firstA, firstB, secondA, secondB }
		firstA.linked, firstB.linked = { start, firstB }, { firstA, start }
		secondA.linked, secondB.linked = { start, secondB }, { secondA, start }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = { [1] = start, [2] = firstA, [3] = firstB, [4] = secondA, [5] = secondB },
			allocNodes = { [1] = start, [2] = firstA, [3] = firstB },
		}
		local parsed = assert(Inputs.Parse({ }))
		local regions = { [1] = "Witch", [2] = "Witch", [3] = "Witch", [4] = "Witch", [5] = "Witch" }
		local valid, reason = TreeSearch.ValidateCandidate(spec, { 4, 5 }, parsed, regions)
		assert.is_false(valid)
		assert.is_truthy(reason:find("adds 1 origin cycle", 1, true))
	end)

	it("allows a disconnected native-radius cycle that does not return to the class start", function()
		local start = { id = 1, type = "ClassStart", linked = { } }
		local connector = { id = 2, type = "Normal", linked = { } }
		local socket = { id = 3, type = "Socket", alloc = true, linked = { }, nodesInRadius = { } }
		local first = { id = 4, type = "Notable", connectedToStart = false, linked = { } }
		local second = { id = 5, type = "Notable", connectedToStart = false, linked = { } }
		local third = { id = 6, type = "Notable", connectedToStart = false, linked = { } }
		start.linked, connector.linked, socket.linked = { connector }, { start, socket }, { connector }
		first.linked, second.linked, third.linked = { second, third }, { first, third }, { first, second }
		local radius = { [4] = first, [5] = second, [6] = third }
		socket.nodesInRadius[1] = radius
		first.intuitiveLeapLikesAffecting = { socket }
		second.intuitiveLeapLikesAffecting = { socket }
		third.intuitiveLeapLikesAffecting = { socket }
		local jewel = { jewelRadiusIndex = 1, jewelData = { intuitiveLeapLike = true } }
		local itemBuild = { itemsTab = { items = { [77] = jewel } } }
		local nodes = { [1] = start, [2] = connector, [3] = socket, [4] = first, [5] = second, [6] = third }
		local tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } }, keystoneMap = { } }
		local sourceSpec = {
			tree = tree, nodes = nodes, allocNodes = { [1] = start, [2] = connector, [3] = socket },
			jewels = { }, build = itemBuild,
		}
		local candidateSpec = {
			tree = tree, nodes = nodes,
			allocNodes = { [1] = start, [2] = connector, [3] = socket, [4] = first, [5] = second, [6] = third },
			jewels = { [3] = 77 }, build = itemBuild,
		}
		local parsed = assert(Inputs.Parse({ }))
		local regions = { [1] = "Witch", [2] = "Witch", [3] = "Witch", [4] = "Witch", [5] = "Witch", [6] = "Witch" }
		local valid, reason = TreeSearch.ValidateCandidate(sourceSpec, { 4, 5, 6 }, parsed, regions, nil, candidateSpec)
		assert.is_true(valid, reason)
	end)

	it("routes target nodes around explicit removals and requires the removal", function()
		local start = { id = 1, x = 0, y = 0, type = "ClassStart", linked = { } }
		local removed = { id = 2, x = 1, y = 0, type = "Normal", linked = { }, alloc = true }
		local connector = { id = 90, x = 1, y = 1, type = "Normal", linked = { } }
		local target = { id = 3, x = 2, y = 0, type = "Notable", linked = { } }
		start.linked = { removed, connector }
		removed.linked = { start, target }
		connector.linked = { start, target }
		target.linked = { removed, connector }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = { [1] = start, [2] = removed, [3] = target, [90] = connector },
			allocNodes = { [1] = start, [2] = removed },
		}
		local parsed = assert(Inputs.Parse({ targetNodeIds = "3", removeNodeIds = "2", maxAddedPoints = "2" }))
		local candidates = TreeSearch.BuildCandidateNodes(spec, parsed, 1, nil, 2)
		assert.are.same({ 90, 3 }, candidates[1].nodeIds)
		local valid = TreeSearch.ValidateCandidate(spec, candidates[1].nodeIds, parsed)
		assert.is_false(valid)
		local validAfterRemoval = TreeSearch.ValidateCandidate(spec, candidates[1].nodeIds, parsed, nil, { 2 })
		assert.is_true(validAfterRemoval)
		assert.is_nil(Inputs.Parse({ targetNodeIds = "2", removeNodeIds = "2" }))
	end)

	it("routes mandatory node IDs through the active PoB tree", function()
		local start = { id = 1, x = 0, y = 0, type = "ClassStart", linked = { } }
		local connector = { id = 2, x = 1, y = 0, type = "Normal", linked = { } }
		local required = { id = 3, x = 2, y = 0, type = "Notable", linked = { } }
		start.linked = { connector }
		connector.linked = { start, required }
		required.linked = { connector }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = { [1] = start, [2] = connector, [3] = required },
			allocNodes = { [1] = start },
			curClass = { startNodeId = 1 }, curClassId = 1,
		}
		local parsed = assert(Inputs.Parse({ requiredNodeIds = "3", maxAddedPoints = "2", evaluationBudget = "8" }))
		local candidates = TreeSearch.BuildCandidateNodes(spec, parsed, 4, nil, 2)
		assert.are.equal(1, #candidates)
		assert.are.same({ 2, 3 }, candidates[1].nodeIds)
		assert.is_true(TreeSearch.ValidateCandidate(spec, candidates[1].nodeIds, parsed))
	end)

	it("validates the complete projected tree, including removals and class starts", function()
		local start = { id = 1, type = "ClassStart", linked = { } }
		local localNode = { id = 2, type = "Normal", linked = { } }
		local blockedNode = { id = 3, type = "Normal", linked = { } }
		local foreignStart = { id = 4, type = "ClassStart", linked = { } }
		local foreignAscend = { id = 5, type = "AscendClassStart", linked = { } }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 }, [2] = { name = "Ranger", startNodeId = 4 } } },
			nodes = { [1] = start, [2] = localNode, [3] = blockedNode, [4] = foreignStart, [5] = foreignAscend },
			allocNodes = { [1] = start, [2] = localNode, [3] = blockedNode },
			curClass = { startNodeId = 1 }, curClassId = 1,
		}
		local parsed = assert(Inputs.Parse({ forbiddenRegions = "Ranger" }))
		local regions = { [1] = "Witch", [2] = "Witch", [3] = "Ranger" }
		assert.is_false(TreeSearch.ValidateCandidate(spec, { }, parsed, regions))
		assert.is_true(TreeSearch.ValidateCandidate(spec, { }, parsed, regions, { 3 }))
		spec.allocNodes[4] = foreignStart
		assert.is_false(TreeSearch.ValidateCandidate(spec, { }, assert(Inputs.Parse({ })), regions))
		spec.allocNodes[4] = nil
		spec.allocNodes[5] = foreignAscend
		assert.is_false(TreeSearch.ValidateCandidate(spec, { }, assert(Inputs.Parse({ })), regions))
	end)

	it("enforces PoB's selected ascendancy roots and eight-point cap", function()
		local nodes = { }
		local classStart = { id = 1, type = "ClassStart" }
		local ascendStart = { id = 2, type = "AscendClassStart", ascendancyName = "Witch Ascendancy" }
		local bloodlineStart = { id = 3, type = "AscendClassStart", ascendancyName = "Delirious", isBloodline = true }
		nodes[1], nodes[2], nodes[3] = classStart, ascendStart, bloodlineStart
		local allocated = { [1] = classStart, [2] = ascendStart }
		for id = 10, 17 do
			local node = { id = id, type = "Notable", ascendancyName = "Witch Ascendancy" }
			nodes[id], allocated[id] = node, node
		end
		allocated[3] = bloodlineStart
		for id = 20, 27 do
			local node = { id = id, type = "Notable", ascendancyName = "Delirious", isBloodline = true }
			nodes[id], allocated[id] = node, node
		end
		local spec = {
			tree = {
				classes = { [1] = { name = "Witch", startNodeId = 1 } },
				secondaryAscendNameMap = { Delirious = { name = "Delirious Bloodline", ascendClassId = 1 } },
			},
			nodes = nodes,
			allocNodes = allocated,
			curClass = { startNodeId = 1 }, curClassId = 1,
			curAscendClass = { name = "Witch Ascendancy", startNodeId = 2 },
			curSecondaryAscendClass = { id = "Delirious", name = "Delirious Bloodline", startNodeId = 3 },
		}
		local regions = { [1] = "Witch", [2] = "Witch", [3] = "Witch" }
		local parsed = assert(Inputs.Parse({ }))
		local valid = TreeSearch.ValidateCandidate(spec, { }, parsed, regions)
		assert.is_true(valid)
		local levelRejected, levelError, levelViolation = TreeSearch.ValidateCandidate(spec, { }, parsed, regions, { }, nil, nil, 1)
		assert.is_false(levelRejected)
		assert.is_truthy(levelError:find("level 1 progression ceiling of 0", 1, true))
		assert.are.equal("ascendancy_point_budget", levelViolation.key)
		local extraPoint = { id = 18, type = "Notable", ascendancyName = "Witch Ascendancy" }
		nodes[18], allocated[18] = extraPoint, extraPoint
		local invalid, err = TreeSearch.ValidateCandidate(spec, { }, parsed, regions)
		assert.is_false(invalid)
		assert.is_truthy(err:find("eight-point limit", 1, true))
		nodes[18], allocated[18] = nil, nil
		local extraBloodlinePoint = { id = 28, type = "Notable", ascendancyName = "Delirious", isBloodline = true }
		nodes[28], allocated[28] = extraBloodlinePoint, extraBloodlinePoint
		local invalidBloodline, bloodlineError = TreeSearch.ValidateCandidate(spec, { }, parsed, regions)
		assert.is_false(invalidBloodline)
		assert.is_truthy(bloodlineError:find("eight-point limit", 1, true))
	end)

	it("combines additions and removals while preserving each requested mutation", function()
		local combined = TreeSearch.CombineAddRemoveCandidates({
			{ nodeIds = { 20, 21 }, label = "damage route", island = 2 },
		}, {
			{ removeNodeIds = { 30, 31 }, label = "defensive cleanup" },
		}, 1, 3)
		assert.are.equal(1, #combined)
		assert.are.same({ 20, 21 }, combined[1].nodeIds)
		assert.are.same({ 30, 31 }, combined[1].removeNodeIds)
		assert.are.equal(0, #TreeSearch.CombineAddRemoveCandidates({ { nodeIds = { 30 } } }, { { removeNodeIds = { 30 } } }, 1, 1))
	end)

	it("proposes deterministic main-tree point trimming while excluding ascendancy points", function()
		local spec = { allocNodes = { } }
		for nodeId = 1, 5 do
			spec.allocNodes[nodeId] = { id = nodeId, type = "Notable", depends = { } }
		end
		spec.allocNodes[20] = { id = 20, type = "Notable", ascendancyName = "Slayer", depends = { } }
		function spec:CountAllocNodes() return 5, 1, 0 end
		local inputs = {
			branch = { required = { }, allowed = { }, forbidden = { } },
			search = { maxTotalPoints = 3, requiredNodeIds = { }, forbiddenNodeIds = { }, removeNodeIds = { } },
		}
		local regions = { [1] = "Scion", [2] = "Scion", [3] = "Scion", [4] = "Scion", [5] = "Scion", [20] = "Duelist" }
		local candidates = TreeSearch.BuildRemovalCandidates(spec, inputs, 8, regions)
		assert.are.same({ 1, 2 }, candidates[1].removeNodeIds)
		assert.is_truthy(candidates[1].label:find("strict cap", 1, true))
	end)

	it("observes cancellation before beginning passive path search", function()
		local start = { id = 1, type = "ClassStart", linked = { } }
		local nextNode = { id = 2, type = "Normal", linked = { } }
		start.linked = { nextNode }
		nextNode.linked = { start }
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = { [1] = start, [2] = nextNode },
			allocNodes = { [1] = start },
		}
		local parsed = { branch = { required = { }, allowed = { }, forbidden = { } }, search = { seed = 1, maxAddedPoints = 1 } }
		local candidates, err, cancelled = TreeSearch.BuildCandidateNodes(spec, parsed, 1, nil, 1, { cancelled = true })
		assert.are.same({ }, candidates)
		assert.is_nil(err)
		assert.is_true(cancelled)
	end)

	it("prunes routes that cannot fit the point budget and skips an empty route quota", function()
		local nodes = { }
		for id = 1, 64 do
			nodes[id] = { id = id, x = id, y = 0, type = id == 1 and "ClassStart" or id == 64 and "Notable" or "Normal", linked = { } }
			if id > 1 then
				nodes[id].linked[#nodes[id].linked + 1] = nodes[id - 1]
				nodes[id - 1].linked[#nodes[id - 1].linked + 1] = nodes[id]
			end
		end
		local spec = {
			tree = { classes = { [1] = { name = "Witch", startNodeId = 1 } } },
			nodes = nodes,
			allocNodes = { [1] = nodes[1] },
		}
		local parsed = {
			branch = { required = { }, allowed = { }, forbidden = { } },
			search = { seed = 1, maxAddedPoints = 1 },
			targetNodeIds = { 64 },
		}
		local maxExpanded = 0
		local candidates, err = TreeSearch.BuildCandidateNodes(spec, parsed, 1, function(_, _, expanded)
			maxExpanded = math.max(maxExpanded, expanded or 0)
		end, 1)
		assert.are.equal(0, #candidates)
		assert.is_truthy(err:find("point budget", 1, true))
		assert.are.equal(0, maxExpanded)
		assert.are.same({ }, TreeSearch.BuildCandidateNodes(spec, parsed, 0, nil, 1))
	end)

	it("combines connected routes within the point limit", function()
		local combined = TreeSearch.CombineCandidates({
			{
				nodeIds = { 90, 3 }, targetId = 3, label = "A",
				hierarchicalExpert = { policyVersion = "hrl-zones-v1", planId = "balanced", zone = "NorthWest", pointBudget = 2 },
			},
			{
				nodeIds = { 80, 4 }, targetId = 4, label = "B",
				hierarchicalExpert = { policyVersion = "hrl-zones-v1", planId = "focus_southeast", zone = "SouthEast", pointBudget = 2 },
			},
		}, 1, 4)
		assert.are.equal(1, #combined)
		assert.are.same({ 90, 3, 80, 4 }, combined[1].nodeIds)
		assert.are.equal("Combined passive routes A + B", combined[1].label)
		assert.is_true(combined[1].hierarchicalCombination)
		assert.are.equal("multi_route", combined[1].hierarchicalCombinationKind)
		assert.are.equal(2, #combined[1].hierarchicalExperts)
		assert.are.equal("NorthWest", combined[1].hierarchicalExperts[1].zone)
		assert.are.equal("SouthEast", combined[1].hierarchicalExperts[2].zone)
		assert.are.equal(0, #TreeSearch.CombineCandidates({
			{ nodeIds = { 90, 3 } }, { nodeIds = { 80, 4 } },
		}, 1, 3))
	end)

	it("samples valid Timeless Jewel seeds without mutating the source item", function()
		local item = { name = "Glorious Vanity", jewelData = { conqueredBy = { id = 500, conqueror = { type = "vaal" } } } }
		local spec = {
			build = {
				data = { timelessJewelSeedMin = { [1] = 100 }, timelessJewelSeedMax = { [1] = 8000 } },
				itemsTab = { items = { [9] = item } },
			},
			jewels = { [10] = 9 },
			allocNodes = { [10] = true },
		}
		local candidates = TreeSearch.BuildTimelessCandidates(spec, 2)
		assert.are.equal(2, #candidates)
		assert.is_true(candidates[1].timelessVariant.seed ~= item.jewelData.conqueredBy.id)
		assert.are.equal(500, item.jewelData.conqueredBy.id)
	end)

	it("recycles only valid optimizer-owned table leases", function()
		local value, lease = Pool.Acquire("test")
		value.retained = true
		Pool.Release("test", value, lease)
		local reused, nextLease = Pool.Acquire("test")
		assert.are.equal(value, reused)
		assert.is_nil(reused.retained)
		assert.is_false(pcall(Pool.Release, "test", reused, lease))
		Pool.Release("test", reused, nextLease)
	end)

	it("does not classify the unchanged current build as an applicable mutation", function()
		assert.is_false(Candidate.HasMutation({ nodeIds = { } }))
		assert.is_true(Candidate.HasMutation({ nodeIds = { 123 } }))
		assert.is_true(Candidate.HasMutation({ nodeIds = { }, removeNodeIds = { 123 } }))
		assert.is_true(Candidate.HasMutation({ nodeIds = { }, anointVariant = { nodeId = 123 } }))
		assert.is_true(Candidate.HasMutation({ nodeIds = { }, anointVariants = { { nodeId = 123 }, { nodeId = 456 } } }))
	end)

	it("preserves finite exact PoB outputs needed to audit candidate rebuild parity", function()
		local metrics = Candidate.CopyMetrics({ TotalEHP = 95.32, Life = 146, EnergyShield = 12, CombinedDPS = math.huge, FullDPS = 121, FullDotDPS = 94 }, Inputs.metricDefinitions)
		assert.are.equal(95.32, metrics.TotalEHP)
		assert.are.equal(146, metrics.Life)
		assert.are.equal(12, metrics.EnergyShield)
		assert.are.equal(121, metrics.FullDPS)
		assert.are.equal(94, metrics.FullDotDPS)
		assert.is_nil(metrics.CombinedDPS)
		assert.are.equal(75, Candidate.CopyMetrics({ LifeReserved = 75, ManaUnreserved = 84 }, Inputs.metricDefinitions).LifeReserved)
	end)

	it("copies bounded PoB FullDPS skill components for read-only MCP snapshots", function()
		local output = { SkillDPS = { { name = "Ball Lightning", dps = 22, count = 1, trigger = "Spellslinger", skillPart = "bolts" } } }
		local breakdown, truncated = Candidate.CopySkillDPS(output)
		assert.is_false(truncated)
		assert.are.equal(1, #breakdown)
		assert.are.equal("Ball Lightning", breakdown[1].name)
		assert.are.equal(22, breakdown[1].dps)
		assert.are.equal("Spellslinger", breakdown[1].trigger)
		local large = { SkillDPS = { } }
		for index = 1, 65 do large.SkillDPS[index] = { name = string.rep("x", 130), dps = index } end
		local bounded, wasTruncated = Candidate.CopySkillDPS(large)
		assert.are.equal(64, #bounded)
		assert.is_true(wasTruncated)
		assert.are.equal(120, #bounded[1].name)
	end)

	it("rejects configured totem counts above exact PoB skill caps", function()
		local limits, truncated = Candidate.CopySkillEntityLimits({ SkillEntityLimits = {
			{ name = "Storm Burst of Repulsion", entityType = "totem", count = 5, limit = 4, group = "Weapon 1" },
		} })
		assert.is_false(truncated)
		local invalid = Validator.CheckSkillEntityLimits(limits, truncated)
		assert.is_false(invalid.feasible)
		assert.are.equal("skill_entity_limit", invalid.violations[1].key)
		assert.are.equal(5, invalid.violations[1].actual)
		assert.are.equal(4, invalid.violations[1].required)
		local valid = Validator.CheckSkillEntityLimits({
			{ name = "Storm Burst", entityType = "totem", count = 3, limit = 3 },
			{ name = "Artillery Ballista", entityType = "ballista", count = 4, limit = 5 },
		})
		assert.is_true(valid.feasible)
		local unknown = Validator.CheckSkillEntityLimits({ { name = "Totem", entityType = "totem", count = 5 } })
		assert.is_false(unknown.feasible)
		local cut = Validator.CheckSkillEntityLimits({ }, true)
		assert.is_false(cut.feasible)
	end)

	it("rejects configured minion counts above PoB's exact minion cap", function()
		local limits, truncated = Candidate.CopySkillEntityLimits({ SkillEntityLimits = {
			{ name = "Summon Raging Spirit", entityType = "minion", count = 22, limit = 20, limitKey = "ActiveRagingSpiritLimit", group = "6L Summon raging spirit" },
		} })
		assert.is_false(truncated)
		assert.are.equal("minion", limits[1].entityType)
		assert.are.equal("ActiveRagingSpiritLimit", limits[1].limitKey)
		local invalid = Validator.CheckSkillEntityLimits(limits, truncated)
		assert.is_false(invalid.feasible)
		assert.are.equal(2, invalid.violations[1].actual - invalid.violations[1].required)
		assert.are.equal("Minion count", invalid.violations[1].label)
		assert.is_true(Validator.CheckSkillEntityLimits({
			{ name = "Summon Raging Spirit", entityType = "minion", count = 20, limit = 20 },
			{ name = "Raise Spectre", entityType = "minion", count = 4, limit = 4 },
		}, false).feasible)
		assert.is_false(Validator.CheckSkillEntityLimits({
			{ name = "Summon Raging Spirit", entityType = "minion", count = 20 },
		}, false).feasible)
	end)

	it("uses PoB's effective minion count for inactive conditional item grants", function()
		local Calcs = require("Modules.Calcs")
		local dervishSkill = {
			socketGroup = { enabled = true, slotEnabled = true, label = "Weapon 1", gemList = { } },
			skillFlags = { minion = true },
			activeEffect = { grantedEffect = { id = "ManifestDancingDervishes", name = "Manifest Dancing Dervishes" } },
			minionList = { "UniqueAnimatedWeapon" },
		}
		local data = { minions = { UniqueAnimatedWeapon = {
			name = "Dancing Dervish", limit = "ActiveAnimatedWeaponLimit",
		} } }
		local inactive = Calcs.getActiveSkillEntityLimits({ dervishSkill }, { ActiveAnimatedWeaponLimit = 0 }, data)
		assert.are.equal(1, #inactive)
		assert.are.equal(0, inactive[1].count,
			"a granted skill instance is not a manifested minion while its trigger is inactive")
		assert.are.equal(0, inactive[1].limit)
		assert.is_true(Validator.CheckSkillEntityLimits(inactive, false).feasible)

		local active = Calcs.getActiveSkillEntityLimits({ dervishSkill }, { ActiveAnimatedWeaponLimit = 2 }, data)
		assert.are.equal(2, active[1].count,
			"the exact PoB output is the effective minion count when the conditional grant is active")
		assert.are.equal(2, active[1].limit)
		assert.is_true(Validator.CheckSkillEntityLimits(active, false).feasible)
	end)

	it("uses PoB selected-skill cost warnings without blocking unrelated utility costs", function()
		local unaffordable = Validator.CheckMainSkillPayability({
			ManaCostWarning = true,
			ManaCostWarningList = { "Cold Snap of Power", "Flesh Offering" },
			ManaPercentCostWarningList = { "Zealotry" },
		}, "Cold Snap of Power")
		assert.are.equal("violated", unaffordable.status)
		assert.is_false(unaffordable.feasible)
		assert.are.equal(1, #unaffordable.violations)
		assert.are.equal("mana", unaffordable.violations[1].resource)

		local optionalUtility = Validator.CheckMainSkillPayability({
			ManaCostWarningList = { "Flesh Offering", "Zealotry" },
			ManaPercentCostWarningList = { "Zealotry" },
		}, "Cold Snap of Power")
		assert.are.equal("pass", optionalUtility.status)
		assert.is_true(optionalUtility.feasible)

		local percentageCost = Validator.CheckMainSkillPayability({
			ManaPercentCostWarningList = { "Blood Rage", "Blessing" },
		}, "Blessing")
		assert.are.equal("violated", percentageCost.status)
		assert.are.equal("mana percentage", percentageCost.violations[1].resource)

		local missingSkill = Validator.CheckMainSkillPayability({ }, nil)
		assert.are.equal("unsupported", missingSkill.status)
		assert.is_false(missingSkill.feasible)
	end)

	it("checks upfront and percentage skill costs against PoB's exact payable pools", function()
		local skill = { activeEffect = { grantedEffect = { name = "Storm Burst" } }, skillData = { } }
		local poolOutput = {
			ManaCostPayablePool = 2978,
			ManaUnreserved = 4,
			EnergyShield = 2974,
			LifeUnreserved = 4912,
			LifeUnreservedPercent = 75,
			ManaUnreservedPercent = 2,
			Life = 5000,
			Mana = 4000,
		}
		local payable = CalcBase.checkSkillPayability(poolOutput, {
			ManaCost = 84, LifeCost = 84, ESCost = 0, ManaPercentCost = 0,
		}, skill)
		assert.are.equal(0, #payable)
		local insufficient = CalcBase.checkSkillPayability({
			ManaCostPayablePool = -45,
			ManaUnreserved = -45,
			LifeUnreserved = 100,
			Life = 100,
		}, { ManaCost = 33 }, skill)
		assert.are.equal(1, #insufficient)
		assert.are.equal("mana", insufficient[1].resource)
		assert.are.equal(78, insufficient[1].deficit)
		local reservationWindow = CalcBase.checkSkillPayability({
			ManaCostPayablePool = 10, ManaUnreserved = 10, Mana = 100,
			LifeUnreserved = 100, Life = 100,
		}, { ManaCost = 30 }, { skillData = { ManaReservedPercent = 20 } })
		assert.are.equal(0, #reservationWindow)
		local percentShortfall = CalcBase.checkSkillPayability({
			LifeUnreservedPercent = 98,
		}, { LifePercentCost = 100 }, skill)
		assert.are.equal(1, #percentShortfall)
		assert.are.equal("life percentage", percentShortfall[1].resource)
	end)

	it("derives regen-only life and mana-or-ES margins from exact PoB outputs", function()
		local metrics = Candidate.CopyMetrics({
			LifeRegenRecovery = 690,
			LifePerSecondCost = 334,
			ManaRegenRecovery = 36.8,
			ManaPerSecondCost = 0,
			EnergyShieldRegenRecovery = 0,
			ESPerSecondCost = 334,
		}, Inputs.metricDefinitions)
		assert.are.equal(356, metrics.LifeSustainMargin)
		assert.are.equal(-334, metrics.ManaSustainMargin)
		local manaOnly = Candidate.CopyMetrics({ ManaRegenRecovery = 40, ManaPerSecondCost = 25 }, Inputs.metricDefinitions)
		assert.are.equal(15, manaOnly.ManaSustainMargin)
		local withBuildDegen = Candidate.CopyMetrics({
			LifeRegenRecovery = 1000,
			NetLifeRegen = 500,
			LifePerSecondCost = 100,
			ManaRegenRecovery = 100,
			NetManaRegen = 80,
			ManaPerSecondCost = 20,
		}, Inputs.metricDefinitions)
		assert.are.equal(400, withBuildDegen.LifeSustainMargin)
		assert.are.equal(60, withBuildDegen.ManaSustainMargin)
	end)

	it("keeps regen-only resource margins separate from PoB leech and on-hit recovery", function()
		local metrics = Candidate.CopyMetrics({
			NetLifeRegen = -141.34,
			LifePerSecondCost = 0,
			LifeLeechGainRate = 1349.430028,
			ManaRegenRecovery = 18.1,
			ManaPerSecondCost = 42.885333333333,
			ManaLeechGainRate = 176.869964,
			EnergyShieldLeechGainRate = 0,
		}, Inputs.metricDefinitions)
		assert.are.equal(-141.34, metrics.LifeSustainMargin)
		assert.are.equal(1349.430028, metrics.LifeLeechGainRate)
		assert.is_true(metrics.ManaSustainMargin < 0)
		assert.are.equal(176.869964, metrics.ManaLeechGainRate)
		assert.are.equal(0, metrics.EnergyShieldLeechGainRate)
	end)

	it("rejects a damage skill whose exact recurring cost exceeds combat recovery", function()
		local fireball = activityRecord("Fireball", "fireball", { Mana = 6.6666666667 }, { Mana = 1.7 })
		local result = Activity.Evaluate({ objective = "CombinedDPS", hard = { } }, fireball, { }, false)
		assert.are.equal("violated", result.status)
		assert.is_false(result.feasible)
		assert.are.equal(-4.9666666667, result.metrics.SustainedManaMargin)
		assert.are.equal("activity_sustain_mana", result.violations[1].key)
	end)

	it("applies a user-supplied activity rate to exact PoB skill costs without certifying DPS uptime", function()
		local fireball = activityRecord("Fireball", "fireball", { Mana = 6.6666666667 }, { Mana = 1.7 })
		fireball.poBDamage = { player = { TotalDPS = 100000, TotalDotDPS = 12000 } }
		local result = assert(Activity.EvaluateSchedule({ objective = "CombinedDPS", hard = { } }, nil, { fireball }, false, {
			{ identity = "fireball", mode = "setup", ratePercent = 25 },
		}))
		assert.are.equal("sustain_estimate", result.status)
		assert.are.equal("pass", result.sustainStatus)
		assert.is_true(result.sustainFeasible)
		assert.is_nil(result.feasible, "A sustain-only estimate must not report overall build feasibility")
		assert.is_true(math.abs(0.033333333325 - result.metrics.SustainedManaMargin) < 1e-9)
		assert.is_false(result.scheduleModel.damageScheduleCertified)
		assert.is_true(result.scheduleModel.assumptions)
		assert.are.equal("setup", result.activities[1].mode)
		assert.are.equal(25, result.activities[1].ratePercent)
		assert.are.equal("setup_excluded", result.activities[1].poBDamageProjection.status)
		assert.is_nil(result.activities[1].poBDamageProjection.perActivity)
		assert.is_false(result.damageScheduleProjection.certified)
		assert.is_nil(result.damageScheduleProjection.combinedDPS)
	end)

	it("estimates resources for every enabled skill without mixing utility cadence into damage", function()
		local fireball = activityRecord("Fireball", "fireball-enabled", { Mana = 2 }, { Mana = 3 })
		fireball.costScheduleEligible = true
		local utility = activityRecord("Summon Example", "utility-enabled", { Mana = 4 }, { Mana = 3 }, nil, nil, "minion")
		utility.hasDamage = false
		utility.poBDamage = nil
		utility.unsupportedReason = nil
		utility.damageUnsupportedReason = "PoB does not certify summon replacement cadence"
		utility.costScheduleEligible = true
		local result = assert(Activity.EvaluateSchedule({ objective = "ResourceSustain", hard = { } }, nil, { fireball, utility }, false, {
			{ identity = "fireball-enabled", mode = "scheduled", ratePercent = 50 },
			{ identity = "utility-enabled", mode = "setup", ratePercent = 25 },
		}, { fireball, utility }))
		assert.are.equal("sustain_estimate", result.status)
		assert.are.equal("pass", result.sustainStatus)
		assert.is_true(result.resourceOnly)
		assert.is_true(math.abs(1 - result.metrics.SustainedManaMargin) < 1e-9)
		assert.are.equal("not_computed_resource_only", result.damageScheduleProjection.status)
		assert.is_nil(result.damageScheduleProjection.combinedDPS)
		assert.is_nil(result.activities[1].poBDamageProjection)
		local utilitySummary
		for _, summary in ipairs(result.activities) do if summary.identity == "utility-enabled" then utilitySummary = summary end end
		assert.is_truthy(utilitySummary)
		assert.are.equal("PoB does not certify summon replacement cadence", utilitySummary.damageUnsupportedReason)
		local incomplete = { fireball, { identity = "incomplete", name = "Incomplete utility", costScheduleEligible = false } }
		local rejected, rejectError = Activity.EvaluateSchedule({ objective = "ResourceSustain", hard = { } }, nil, { }, false, {
			{ identity = "fireball-enabled", mode = "continuous" },
			{ identity = "incomplete", mode = "continuous" },
		}, incomplete)
		assert.is_nil(rejected)
		assert.is_truthy(rejectError:find("complete exact recurring-resource rates", 1, true))
	end)

	it("bounds mutually exclusive activity packages and requires complete unique PoB identities", function()
		local first = activityRecord("Skill A", "skill-a", { Mana = 6 }, { Mana = 10 })
		local second = activityRecord("Skill B", "skill-b", { Mana = 5 }, { Mana = 10 })
		first.poBDamage = { player = { TotalDPS = 1000, TotalDotDPS = 200 } }
		second.poBDamage = { minion = { TotalDPS = 500 } }
		local result = assert(Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { first, second }, false, {
			{ identity = "skill-a", mode = "alternative", package = "clear-or-boss", ratePercent = 60 },
			{ identity = "skill-b", mode = "alternative", package = "clear-or-boss", ratePercent = 40 },
		}))
		assert.are.equal("sustain_estimate", result.status)
		assert.are.equal("pass", result.sustainStatus)
		assert.are.equal(4.4, result.metrics.SustainedManaMargin)
		assert.is_false(result.damageScheduleCertified)
		assert.are.equal("linear_per_activity_estimate", result.activities[1].poBDamageProjection.status)
		assert.are.equal(600, result.activities[1].poBDamageProjection.perActivity.player.TotalDPS)
		assert.are.equal(120, result.activities[1].poBDamageProjection.perActivity.player.TotalDotDPS)
		assert.are.equal(200, result.activities[2].poBDamageProjection.perActivity.minion.TotalDPS)
		assert.is_nil(result.damageScheduleProjection.combinedDPS, "separate per-skill projections must not be summed into a fabricated DPS")
		assert.is_truthy(result.scheduleModel.damageScheduleNote:find("not summed", 1, true))
		local overBudget, overError = Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { first, second }, false, {
			{ identity = "skill-a", mode = "alternative", package = "one", ratePercent = 60 },
			{ identity = "skill-b", mode = "alternative", package = "one", ratePercent = 50 },
		})
		assert.is_nil(overBudget)
		assert.is_truthy(overError:find("exceeds 100%", 1, true))
		local missing, missingError = Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { first, second }, false, {
			{ identity = "skill-a", mode = "continuous" },
		})
		assert.is_nil(missing)
		assert.is_truthy(missingError:find("missing PoB activity", 1, true))
		local unknown, unknownError = Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { first }, false, {
			{ identity = "not-from-pob", mode = "continuous" },
		})
		assert.is_nil(unknown)
		assert.is_truthy(unknownError:find("identity from PoB", 1, true))
	end)

	it("does not require event cadence data for an explicitly unused activity", function()
		local active = activityRecord("Self-cast", "active", { Mana = 0 }, { Mana = 0 })
		local inactive = activityRecord("Triggered alternate", "unused-trigger", { Mana = 4 }, { Mana = 0 }, nil, nil, "triggered")
		inactive.triggerRate = nil
		local result = assert(Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { active, inactive }, false, {
			{ identity = "active", mode = "continuous" },
			{ identity = "unused-trigger", mode = "alternative", package = "unused", ratePercent = 0 },
		}))
		assert.are.equal("pass", result.sustainStatus)
		assert.are.equal(2, #result.activities)
		assert.are.equal(0, result.activities[2].ratePercent)
		assert.are.equal(0, result.activities[2].resources.Mana.cost)
	end)

	it("validates explicit setup and payoff prerequisites without certifying timing", function()
		local setup = activityRecord("Exposure Setup", "setup-activity", { Mana = 0 }, { Mana = 2 })
		local payoff = activityRecord("Main Attack", "payoff-activity", { Mana = 0 }, { Mana = 2 })
		payoff.poBDamage = { player = { TotalDPS = 500 } }
		local result = assert(Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { setup, payoff }, false, {
			{ identity = "setup-activity", mode = "setup", ratePercent = 25 },
			{ identity = "payoff-activity", mode = "continuous", requires = { "setup-activity" } },
		}))
		assert.are.equal("structure_only", result.dependencyAudit.status)
		assert.are.equal(1, result.dependencyAudit.edgeCount)
		assert.are.equal(1, result.dependencyAudit.activitiesWithDependencies)
		assert.is_false(result.dependencyAudit.timingCertified)
		assert.are.same({ "setup-activity" }, result.activities[2].requires)
		assert.is_false(result.scheduleModel.dependencyTimingCertified)
		assert.is_nil(result.damageScheduleProjection.combinedDPS)

		local inactivePrerequisite, inactiveError = Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { setup, payoff }, false, {
			{ identity = "setup-activity", mode = "setup", ratePercent = 0 },
			{ identity = "payoff-activity", mode = "continuous", requires = { "setup-activity" } },
		})
		assert.is_nil(inactivePrerequisite)
		assert.is_truthy(inactiveError:find("zero use rate", 1, true))

		local cycle, cycleError = Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { setup, payoff }, false, {
			{ identity = "setup-activity", mode = "setup", ratePercent = 25, requires = { "payoff-activity" } },
			{ identity = "payoff-activity", mode = "continuous", requires = { "setup-activity" } },
		})
		assert.is_nil(cycle)
		assert.is_truthy(cycleError:find("dependency cycle", 1, true))

		local unknown, unknownError = Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { setup, payoff }, false, {
			{ identity = "setup-activity", mode = "setup", ratePercent = 25 },
			{ identity = "payoff-activity", mode = "continuous", requires = { "not-in-this-scope" } },
		})
		assert.is_nil(unknown)
		assert.is_truthy(unknownError:find("outside the selected PoB activity list", 1, true))

		local duplicate, duplicateError = Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { setup, payoff }, false, {
			{ identity = "setup-activity", mode = "setup", ratePercent = 25 },
			{ identity = "payoff-activity", mode = "continuous", requires = { "setup-activity", "setup-activity" } },
		})
		assert.is_nil(duplicate)
		assert.is_truthy(duplicateError:find("listed more than once", 1, true))

		local sparse, sparseError = Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { setup, payoff }, false, {
			{ identity = "setup-activity", mode = "setup", ratePercent = 25 },
			{ identity = "payoff-activity", mode = "continuous", requires = { [2] = "setup-activity" } },
		})
		assert.is_nil(sparse)
		assert.is_truthy(sparseError:find("dense array", 1, true))
	end)

	it("preserves raw PoB damage but withholds projections for unsupported activity cadence", function()
		local minion = activityRecord("Summon Example", "summon-example", { Mana = 0 }, { Mana = 10 }, nil, nil, "minion")
		minion.unsupportedReason = "PoB does not certify summon replacement cadence"
		minion.poBDamage = { minion = { TotalDPS = 250 } }
		local result = assert(Activity.EvaluateSchedule({ objective = "FullDPS", hard = { } }, nil, { minion }, false, {
			{ identity = "summon-example", mode = "scheduled", ratePercent = 50 },
		}))
		assert.are.equal("unsupported", result.sustainStatus)
		assert.are.equal("unsupported", result.activities[1].poBDamageProjection.status)
		assert.are.equal(250, result.activities[1].poBDamageProjection.raw.minion.TotalDPS)
		assert.is_nil(result.activities[1].poBDamageProjection.perActivity)
	end)

	it("combines included skill costs conservatively without double-counting shared leech caps", function()
		local first = activityRecord("Skill A", "group-a", { Mana = 6 }, { Mana = 2 }, { Mana = 2 }, { Mana = 1 })
		local second = activityRecord("Skill B", "group-b", { Mana = 5 }, { Mana = 1 }, { Mana = 3 }, { Mana = 2 })
		local result = Activity.Evaluate({ objective = "FullDPS", hard = { } }, first, { first, second }, false)
		assert.are.equal("violated", result.status)
		-- Costs sum to 11; shared regen uses the lower exact 1; capped leech
		-- uses max(2, 3); independently triggered on-hit recovery sums to 3.
		assert.are.equal(-4, result.metrics.SustainedManaMargin)
		assert.are.equal(2, #result.activities)
	end)

	it("fails closed for unsupported activity cadence and incomplete native rate records", function()
		local minion = activityRecord("Summon Raging Spirit", "minion", { Mana = 0 }, { Mana = 0 }, nil, nil, "minion")
		minion.unsupportedReason = "PoB does not certify summon replacement cadence"
		local unsupportedMinion = Activity.Evaluate({ objective = "FullDPS", hard = { } }, nil, { minion }, false)
		assert.are.equal("unsupported", unsupportedMinion.status)
		assert.is_false(unsupportedMinion.feasible)
		assert.is_truthy(unsupportedMinion.violations[1].reason:find("replacement cadence", 1, true))

		local missingRates = activityRecord("Fireball", "fireball", { Mana = 3 }, { Mana = 5 })
		missingRates.exact = false
		local incomplete = Activity.Evaluate({ objective = "CombinedDPS", hard = { } }, missingRates, { }, false)
		assert.are.equal("unsupported", incomplete.status)
		assert.is_truthy(incomplete.violations[1].reason:find("exact activity-cost record", 1, true))

		local missingTrigger = activityRecord("Triggered Spell", "triggered", { Mana = 3 }, { Mana = 5 }, nil, nil, "triggered")
		missingTrigger.triggerRate = nil
		assert.are.equal("unsupported", Activity.Evaluate({ objective = "CombinedDPS", hard = { } }, missingTrigger, { }, false).status)
	end)

	it("reports no activity requirement for a non-DPS request with no damage records", function()
		local result = Activity.Evaluate({ objective = "TotalEHP", hard = { } }, nil, { }, false)
		assert.are.equal("not_required", result.status)
		assert.is_true(result.feasible)
	end)

	it("counts distinct manual skill actions while excluding triggered and persistent-reservation skills", function()
		local damageGroup = { label = "Main damage", enabled = true, slotEnabled = true }
		local utilityGroup = { label = "Utility", enabled = true, slotEnabled = true }
		local reservedGroup = { label = "Auras", enabled = true, slotEnabled = true }
		local triggeredGroup = { label = "Triggered", enabled = true, slotEnabled = true }
		local function activeSkill(group, id, name, types, data)
			return {
				socketGroup = group,
				activeEffect = { grantedEffect = { id = id, name = name } },
				skillTypes = types or { },
				skillData = data or { },
				skillFlags = { },
			}
		end
		local result = SkillActions.Evaluate({
			activeSkill(damageGroup, "fireball", "Fireball", { [SkillType.Spell] = true, [SkillType.Damage] = true }),
			activeSkill(damageGroup, "fireball", "Fireball alternate part", { [SkillType.Spell] = true, [SkillType.Damage] = true }),
			activeSkill(utilityGroup, "flame-dash", "Flame Dash", { [SkillType.Spell] = true, [SkillType.Movement] = true }),
			activeSkill(reservedGroup, "grace", "Grace", { [SkillType.HasReservation] = true }),
			activeSkill(reservedGroup, "divine-blessing", "Divine Blessing", { [SkillType.HasReservation] = true, [SkillType.ReservationBecomesCost] = true }),
			activeSkill(triggeredGroup, "triggered-spell", "Triggered Spell", { [SkillType.Triggered] = true }),
		}, 3)
		assert.are.equal("pass", result.status)
		assert.is_true(result.feasible)
		assert.are.equal(3, result.manualButtonCount)
		assert.are.equal(1, result.manualDamageButtonCount)
		assert.are.equal(2, result.manualUtilityButtonCount)
		assert.are.equal(1, result.reservedSkillCount)
		assert.are.equal(1, result.triggeredSkillCount)
		assert.are.equal(3, #result.actions)
	end)

	it("rejects an exact manual-button overage and fails closed without PoB action data", function()
		local function action(id)
			return {
				socketGroup = { label = id, enabled = true, slotEnabled = true },
				activeEffect = { grantedEffect = { id = id, name = id } },
				skillTypes = { [SkillType.Spell] = true, [SkillType.Damage] = true },
				skillData = { }, skillFlags = { },
			}
		end
		local over = SkillActions.Evaluate({ action("A"), action("B"), action("C") }, 2)
		assert.are.equal("violated", over.status)
		assert.is_false(over.feasible)
		assert.are.equal(3, over.violations[1].actual)
		assert.are.equal(2, over.violations[1].required)
		local missing = SkillActions.Evaluate(nil, 2)
		assert.are.equal("unsupported", missing.status)
		assert.is_false(missing.feasible)
		assert.is_nil(missing.violations[1].deficit, "Unsupported audit payload must remain JSON-safe")
		assert.is_truthy(require("dkjson").encode(missing), "Unsupported audit must serialize as MCP JSON")
		assert.are.equal("unavailable", SkillActions.Evaluate(nil, nil).status)
	end)

	it("enforces the damage-action cap separately from the total manual-action cap", function()
		local function action(id, damage)
			return {
				socketGroup = { label = id, enabled = true, slotEnabled = true },
				activeEffect = { grantedEffect = { id = id, name = id } },
				skillTypes = damage and { [SkillType.Spell] = true, [SkillType.Damage] = true }
					or { [SkillType.Spell] = true, [SkillType.Movement] = true },
				skillData = { }, skillFlags = { },
			}
		end
		local actions = { action("Fireball", true), action("Arc", true), action("Flame Dash", false) }
		local damageOnly = SkillActions.Evaluate(actions, nil, 2)
		assert.are.equal("pass", damageOnly.status)
		assert.is_true(damageOnly.feasible)
		assert.are.equal(3, damageOnly.manualButtonCount)
		assert.are.equal(2, damageOnly.manualDamageButtonCount)
		local over = SkillActions.Evaluate(actions, 3, 1)
		assert.are.equal("violated", over.status)
		assert.is_false(over.feasible)
		assert.are.equal("manual_damage_button_cap", over.violations[1].key)
		assert.are.equal(2, over.violations[1].actual)
		assert.are.equal(1, over.violations[1].required)
		assert.is_truthy(over.normalizedDeficit > 0)
		local unsupported = SkillActions.Evaluate(nil, nil, 2)
		assert.are.equal("unsupported", unsupported.status)
		assert.is_false(unsupported.feasible)
		assert.is_truthy(require("dkjson").encode(unsupported), "Damage-cap audit must remain JSON-safe")
	end)

	it("fails closed when the active-skill list is sparse or lacks socket-group identity", function()
		local function fireball()
			return {
				socketGroup = { label = "Main", enabled = true, slotEnabled = true },
				activeEffect = { grantedEffect = { id = "fireball", name = "Fireball" } },
				skillTypes = { [SkillType.Spell] = true, [SkillType.Damage] = true },
				skillData = { }, skillFlags = { },
			}
		end
		local sparse = { [1] = fireball(), [3] = fireball() }
		local sparseAudit = SkillActions.Evaluate(sparse, nil, 2)
		assert.are.equal("unsupported", sparseAudit.status)
		assert.is_false(sparseAudit.feasible)
		assert.are.equal(2, sparseAudit.manualDamageButtonCount, "entries after a hole must not be silently skipped")

		local missingGroup = fireball()
		missingGroup.socketGroup = nil
		local missingGroupAudit = SkillActions.Evaluate({ missingGroup }, nil, 2)
		assert.are.equal("unsupported", missingGroupAudit.status)
		assert.is_false(missingGroupAudit.feasible)
		assert.is_truthy(missingGroupAudit.violations[1].reason:find("socket-group", 1, true))
		assert.is_truthy(require("dkjson").encode(missingGroupAudit), "Unclassified action audit must remain JSON-safe")
	end)

	it("keeps non-finite optimizer deficits out of MCP JSON status", function()
		local previousJobs = MCPBridge.jobs
		MCPBridge.jobs = {
			["nonfinite-deficit-test"] = {
				job = {
					status = "no_feasible_candidate",
					result = {
						status = "no_feasible_candidate",
						bestObservedDeficit = math.huge,
						bestObservedViolations = { {
							key = "manual_button_cap", label = "Manual skill-button cap", reason = "Unsupported action identity",
							actual = math.huge, required = 0, deficit = math.huge,
						} },
					},
				},
			},
		}
		local ok, responseOrError = pcall(function()
			local response, requestError = MCPBridge:CallLocal("optimizer_status", { jobId = "nonfinite-deficit-test" })
			assert.is_nil(requestError)
			assert.is_nil(response.bestObservedDeficit)
			assert.is_nil(response.bestObservedViolations[1].actual)
			assert.is_nil(response.bestObservedViolations[1].deficit)
			assert.is_truthy(require("dkjson").encode(response))
		end)
		MCPBridge.jobs = previousJobs
		assert.is_true(ok, responseOrError)
	end)

	it("sanitizes nested gem, equipment and sustain details in optimizer MCP status", function()
		local previousJobs = MCPBridge.jobs
		local cyclic = { marker = "safe" }
		cyclic.self = cyclic
		local typedEmptyObject = setmetatable({ }, { __jsontype = "object" })
		local unsupportedThread = coroutine.create(function() end)
		MCPBridge.jobs = {
			["nested-json-status-test"] = {
				job = {
					status = "feasible",
					progress = { phase = "Exact calculations", processed = 2, total = 2 },
					result = {
						status = "feasible",
						evaluations = 2,
						searchCoverage = cyclic,
						candidate = {
							feasible = true, label = "Fireball 21/20 + support",
							nodeIds = { },
							gemVariants = { { gemId = "Fireball", level = 21, quality = 20, kind = "active" } },
							gearVariant = { items = { [101] = { name = "Helmet", engineObject = unsupportedThread, loop = cyclic } } },
							evaluation = {
								metrics = { CombinedDPS = 1234, Poisoned = math.huge },
								violations = { },
								objective = "CombinedDPS",
								activitySustain = { status = "unsupported", normalizedDeficit = math.huge,
									metrics = { ManaSustainMargin = 4 }, evidence = cyclic },
								skillAvailability = { status = "unsupported", normalizedDeficit = math.huge, evidence = cyclic, emptySummary = typedEmptyObject },
								requirements = { status = "unsupported", evidence = cyclic },
								passivePointsUsed = 8,
							},
						},
					paretoFront = { },
				},
			},
		}
		}
		local ok, responseOrError = pcall(function()
			local response, requestError = MCPBridge:CallLocal("optimizer_status", { jobId = "nested-json-status-test" })
			assert.is_nil(requestError)
			assert.are.equal("Fireball", response.best.gemVariants[1].gemId)
			assert.are.equal(21, response.best.gemVariants[1].level)
			assert.are.equal("Helmet", response.best.gearVariant.items["101"].name)
			assert.is_nil(response.best.gearVariant.items["101"].engineObject)
			assert.is_nil(response.best.gearVariant.items["101"].loop.self, "cycles are dropped from nested PoB objects")
			assert.is_nil(response.best.skillAvailability.normalizedDeficit, "non-finite nested gates are omitted")
			assert.are.equal("object", getmetatable(response.best.skillAvailability.emptySummary).__jsontype,
				"an empty JSON object must not be converted to an array")
			assert.are.equal("{}", require("dkjson").encode(response.best.skillAvailability.emptySummary))
			assert.are.equal(4, response.best.activitySustain.metrics.ManaSustainMargin)
			assert.is_truthy(require("dkjson").encode(response), "the complete optimizer status must remain serializable")
		end)
		MCPBridge.jobs = previousJobs
		assert.is_true(ok, responseOrError)
	end)

	it("exposes bounded class-search progress and per-class exact outcomes through MCP", function()
		local previousJobs = MCPBridge.jobs
		local classSearch = {
			mode = "equal_per_class_exact_evaluation_budget",
			classCount = 7,
			totalBudget = 14,
			usedBudget = 14,
			unusedBudget = 0,
			exhaustive = false,
			results = {
				{
					classId = 1, class = "Marauder", status = "feasible", quota = 2, evaluations = 2, objectiveValue = 10,
					bestCandidate = {
						mainAscendancy = "Chieftain", bloodline = "Bloodline Test", mainAscendancyPoints = 4,
						bloodlinePoints = 4, passivePointsUsed = 80, passivePointLimit = 120, objectiveValue = 10,
					},
					ascendancyCoverage = {
						status = "generated", availableMainAscendancies = 3, representedMainAscendancies = 2,
						availableBloodlines = 12, representedBloodlines = 2, availableBloodlineCombinations = 36,
						representedBloodlineCombinations = 1, exactEvaluations = 2, exactBloodlineEvaluations = 1,
						exactCombinedEvaluations = 1, budgetLimited = true,
					},
				},
				{ classId = 2, class = "Ranger", status = "no_feasible_candidate", quota = 2, evaluations = 2, bestObservedDeficit = 1 },
			},
		}
		MCPBridge.jobs = {
			["class-search-status-test"] = {
				job = {
					status = "feasible",
					result = {
						status = "feasible",
						evaluations = 14,
						message = "Bounded equal-budget class search",
						classSearch = classSearch,
						candidate = { feasible = true, label = "Witch — route", nodeIds = { 101 }, classVariant = { classId = 3 }, evaluation = {
							metrics = { CombinedDPS = 1200, TotalEHP = 8000 }, violations = { }, objective = "CombinedDPS", passivePointsUsed = 44,
							selectedBaseClassName = "Witch", selectedAscendancyName = "Elementalist",
						} },
						paretoFront = { },
					},
				},
			},
		}
		local ok, responseOrError = pcall(function()
			local response, requestError = MCPBridge:CallLocal("optimizer_status", { jobId = "class-search-status-test" })
			assert.is_nil(requestError)
			assert.are.equal(7, response.classSearch.classCount)
			assert.are.equal(14, response.classSearch.totalBudget)
			assert.are.equal(2, response.classSearch.results[1].quota)
			assert.are.equal("Chieftain", response.classSearch.results[1].bestCandidate.mainAscendancy)
			assert.are.equal("Bloodline Test", response.classSearch.results[1].bestCandidate.bloodline)
			assert.are.equal(1, response.classSearch.results[1].ascendancyCoverage.exactCombinedEvaluations)
			assert.are.equal("Witch", response.best.selectedBaseClassName)
			assert.is_truthy(require("dkjson").encode(response), "per-class search status must remain JSON-safe")
		end)
		MCPBridge.jobs = previousJobs
		assert.is_true(ok, responseOrError)
	end)

	it("exposes exact mutation details and search coverage for anoint optimizer results over MCP", function()
		local previousJobs = MCPBridge.jobs
		MCPBridge.jobs = {
			["anoint-status-test"] = {
				job = {
					status = "complete",
					result = {
						status = "feasible",
						evaluations = 8,
						searchCoverage = {
							phase = { supportPackages = {
								additions = {
									{ arity = 1, generated = 0, exact = 0, compatible = 0, rejected = 0 },
									{ arity = 2, generated = 4, exact = 3, compatible = 2, rejected = 1 },
									{ arity = 3, generated = 2, exact = 2, compatible = 1, rejected = 1 },
									{ arity = 4, generated = 0, exact = 0, compatible = 0, rejected = 0 },
									{ arity = 5, generated = 0, exact = 0, compatible = 0, rejected = 0 },
								},
								swaps = {
									{ arity = 1, generated = 0, exact = 0, compatible = 0, rejected = 0 },
									{ arity = 2, generated = 1, exact = 1, compatible = 1, rejected = 0 },
									{ arity = 3, generated = 0, exact = 0, compatible = 0, rejected = 0 },
									{ arity = 4, generated = 0, exact = 0, compatible = 0, rejected = 0 },
									{ arity = 5, generated = 0, exact = 0, compatible = 0, rejected = 0 },
								},
							} },
							anoints = { generatedCandidates = 3, availableCandidates = 27 },
							configuration = { totalCombinations = 180, generatedCandidates = 15, generatedMultiChoiceCandidates = 0 },
							topology = { partitionVersion = "spatial-v1", treeVersion = "3_29", totalNodeCount = 2872, assignedNodeCount = 2872 },
							zones = { mode = "deterministic_hierarchical_spatial", pointBudget = 12, budgetConserved = true, exactEvaluations = 2 },
						},
						candidate = {
							feasible = true,
							label = "Anoint Acrimony on Amulet",
							nodeIds = { },
							removeNodeIds = { },
							hierarchicalExpert = { policyVersion = "hrl-zones-v1", planId = "focus_northeast", zone = "NorthEast", pointBudget = 12 },
							anointVariant = { nodeId = 25970, slotName = "Amulet", itemId = 4, enchantSlot = 1 },
							anointVariants = nil,
							configurationVariant = { bandit = "Oak", pantheonMajorGod = "TheBrineKing", pantheonMinorGod = "Gruthkul" },
							evaluation = { metrics = { TotalEHP = 1000 }, violations = { }, objective = "TotalEHP", passivePointsUsed = 20, extraPassivePoints = 0 },
						},
						paretoFront = { },
					},
				},
			},
		}
		local ok, responseOrError = pcall(function()
			local response, requestError = MCPBridge:CallLocal("optimizer_status", { jobId = "anoint-status-test" })
			assert.is_nil(requestError)
			assert.are.equal(1, response.searchCoverage.phase.supportPackages.additions[3].compatible)
			assert.are.equal(3, response.searchCoverage.anoints.generatedCandidates)
			assert.are.equal(27, response.searchCoverage.anoints.availableCandidates)
			assert.are.equal("spatial-v1", response.searchCoverage.topology.partitionVersion)
			assert.are.equal(2872, response.searchCoverage.topology.assignedNodeCount)
			assert.are.equal("deterministic_hierarchical_spatial", response.searchCoverage.zones.mode)
			assert.are.equal(2, response.searchCoverage.zones.exactEvaluations)
			assert.are.equal("hrl-zones-v1", response.best.hierarchicalExpert.policyVersion)
			assert.are.equal("NorthEast", response.best.hierarchicalExpert.zone)
			assert.are.equal(25970, response.best.anointVariant.nodeId)
			assert.are.equal("Amulet", response.best.anointVariant.slotName)
			assert.is_nil(response.best.anointVariants, "single-anoint result shape must remain backward compatible")
			local pair = {
				{ nodeId = 25970, slotName = "Amulet", itemId = 4, enchantSlot = 1 },
				{ nodeId = 12345, slotName = "Amulet", itemId = 4, enchantSlot = 2 },
			}
			MCPBridge.jobs["anoint-status-test"].job.result.candidate.anointVariants = pair
			local pairResponse, pairError = MCPBridge:CallLocal("optimizer_status", { jobId = "anoint-status-test" })
			assert.is_nil(pairError)
			assert.are.same(pair, pairResponse.best.anointVariants, "paired anoints must remain visible through the local MCP result")
			assert.are.equal("Oak", response.best.configurationVariant.bandit)
			assert.are.equal(0, response.best.extraPassivePoints, "zero native extra points must survive MCP serialization")
			assert.are.equal(180, response.searchCoverage.configuration.totalCombinations)
			assert.is_truthy(require("dkjson").encode(response), "anoint result summary must remain MCP JSON-safe")
		end)
		MCPBridge.jobs = previousJobs
		assert.is_true(ok, responseOrError)
	end)

	it("invalidates an optimizer result when the source build changes", function()
		local build = {
			data = { version = "test" },
			characterLevel = 90,
			characterLevelAutoMode = false,
			mainSocketGroup = 1,
			spec = {
				treeVersion = "test-tree", curClassId = 1, curAscendClassId = 0,
				curSecondaryAscendClassId = 0, allocNodes = { [11] = true },
				masterySelections = { }, jewels = { }, hashOverrides = { },
			},
			skillsTab = { activeSkillSetId = 1, socketGroupList = { { includeInFullDPS = false, groupCount = 1, gemList = { } } } },
			configTab = { input = { enemyLevel = 84 } },
			calcsTab = { input = { skill_number = 1 } },
			timelessData = { },
			itemsTab = { activeItemSetId = 1, itemSets = { }, items = { } },
		}
		local before = Candidate.BuildSignature(build)
		build.spec.allocNodes[12] = true
		assert.is_false(before == Candidate.BuildSignature(build))
		local afterAllocation = Candidate.BuildSignature(build)
		build.characterLevelAutoMode = true
		assert.is_false(afterAllocation == Candidate.BuildSignature(build))
		local afterLevelMode = Candidate.BuildSignature(build)
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		assert.is_false(afterLevelMode == Candidate.BuildSignature(build))
		local afterFullDPSSelection = Candidate.BuildSignature(build)
		build.skillsTab.socketGroupList[1].groupCount = 2
		assert.is_false(afterFullDPSSelection == Candidate.BuildSignature(build))
	end)
end)
