local Inputs = require("Modules.Optimizer.Inputs")
local Ranking = require("Modules.Optimizer.Ranking")
local Candidate = require("Modules.Optimizer.Candidate")

describe("Optimizer exact ranking preferences", function()
	it("defaults to the legacy objective-first ordering and rejects unknown priorities", function()
		local parsed = assert(Inputs.Parse({ objectiveMetric = "CombinedDPS" }))
		assert.are.equal("ObjectiveFirst", parsed.preferences.rankingPriority)
		assert.is_nil(Inputs.Parse({ rankingPriority = "WeightedGuess" }))
	end)

	it("requires the selected exact PoB defense metric when defense is primary", function()
		local parsed = assert(Inputs.Parse({
			objectiveMetric = "TotalEHP",
			defenseProfile = "Life",
			rankingPriority = "DefenseFirst",
		}))
		local build = { spec = { }, skillsTab = { }, calcsTab = { mainOutput = { Life = 5000 } } }
		assert.is_true(Inputs.ValidateBuild(build, parsed))
		build.calcsTab.mainOutput.Life = nil
		local valid, message = Inputs.ValidateBuild(build, parsed)
		assert.is_false(valid)
		assert.is_truthy(message:find("finite exact Life", 1, true))
	end)

	it("chooses objective or selected defense lexicographically after feasibility", function()
		local highDamage = { nodeIds = { 1, 2 }, evaluation = { metrics = { CombinedDPS = 1000, Life = 4500, TotalEHP = 7000 } } }
		local highLife = { nodeIds = { 1, 2, 3 }, evaluation = { metrics = { CombinedDPS = 900, Life = 5000, TotalEHP = 6500 } } }
		assert.is_true(Ranking.IsBetter(highDamage, highLife, "CombinedDPS", { rankingPriority = "ObjectiveFirst" }))
		assert.is_true(Ranking.IsBetter(highLife, highDamage, "CombinedDPS", { rankingPriority = "DefenseFirst", defenseProfile = "Life" }))
		assert.is_false(Ranking.IsBetter(highDamage, highLife, "CombinedDPS", { rankingPriority = "DefenseFirst", defenseProfile = "Life" }))
	end)

	it("uses the selected defense as an exact tie-breaker when DPS remains primary", function()
		local moreEnergyShield = { nodeIds = { 1, 2 }, evaluation = { metrics = { CombinedDPS = 1000, EnergyShield = 12000, TotalEHP = 50000 } } }
		local lessEnergyShield = { nodeIds = { 1, 2, 3 }, evaluation = { metrics = { CombinedDPS = 1000, EnergyShield = 10000, TotalEHP = 60000 } } }
		local preferences = { rankingPriority = "ObjectiveFirst", defenseProfile = "EnergyShield" }
		assert.is_true(Ranking.IsBetter(moreEnergyShield, lessEnergyShield, "CombinedDPS", preferences))
		assert.is_true(Ranking.Dominates(moreEnergyShield, lessEnergyShield, "CombinedDPS", preferences),
			"the selected ES pool, rather than a fixed EHP proxy, defines the defense axis")
	end)

	it("ranks the selected elemental focus by exact native per-hit output", function()
		local fireFocused = { nodeIds = { 1 }, evaluation = { metrics = {
			CombinedDPS = 900, FireHitAverage = 300, EnergyShield = 12000,
		} } }
		local totalDpsFocused = { nodeIds = { 1, 2 }, evaluation = { metrics = {
			CombinedDPS = 1000, FireHitAverage = 250, EnergyShield = 12000,
		} } }
		local preferences = { rankingPriority = "DefenseFirst", defenseProfile = "EnergyShield", damageFocus = "Fire" }
		assert.are.equal("FireHitAverage", Ranking.DamageFocusMetricKey("Fire"))
		assert.is_nil(Ranking.DamageFocusMetricKey("Auto"))
		assert.is_true(Ranking.IsBetter(fireFocused, totalDpsFocused, "CombinedDPS", preferences),
			"Defense-first ranks by exact Energy Shield, then exact Fire average hit, then total DPS")
		assert.is_false(Ranking.Dominates(fireFocused, totalDpsFocused, "CombinedDPS", preferences),
			"the Pareto front preserves the total-DPS versus Fire-hit trade-off")
		assert.is_false(Ranking.Dominates(totalDpsFocused, fireFocused, "CombinedDPS", preferences))
	end)

	it("uses the chosen defensive pool in the Pareto front, not a fixed EHP proxy", function()
		local highLife = { nodeIds = { 1, 2 }, evaluation = { metrics = { CombinedDPS = 100, Life = 5000, TotalEHP = 8000 } } }
		local lowLifeHighEhp = { nodeIds = { 1, 2 }, evaluation = { metrics = { CombinedDPS = 90, Life = 4000, TotalEHP = 9000 } } }
		assert.is_true(Ranking.Dominates(highLife, lowLifeHighEhp, "CombinedDPS", {
			rankingPriority = "DefenseFirst", defenseProfile = "Life",
		}))
		assert.is_false(Ranking.Dominates(highLife, lowLifeHighEhp, "CombinedDPS", { rankingPriority = "ObjectiveFirst" }))
	end)

	it("maps Auto and Hybrid to PoB EHP and Ward to the exact Ward output", function()
		assert.are.equal("TotalEHP", Ranking.DefenseMetricKey("Auto"))
		assert.are.equal("TotalEHP", Ranking.DefenseMetricKey("Hybrid"))
		assert.are.equal("Ward", Ranking.DefenseMetricKey("Ward"))
		assert.are.equal("Armour", Ranking.DefenseMetricKey("Armour"))
		assert.are.equal("Evasion", Ranking.DefenseMetricKey("Evasion"))
		assert.are.equal("BlockChance", Ranking.DefenseMetricKey("Block"))
		assert.are.equal("SpellBlockChance", Ranking.DefenseMetricKey("SpellBlock"))
		assert.are.equal("SpellSuppressionChance", Ranking.DefenseMetricKey("SpellSuppression"))
	end)

	it("accepts exact hard floors for the displayed defensive layers", function()
		local parsed, parseError = Inputs.Parse({
			objectiveMetric = "FullDPS", defenseProfile = "Armour", rankingPriority = "DefenseFirst",
			Armour = "25000", Evasion = "18000", BlockChance = "50",
			SpellBlockChance = "40", SpellSuppressionChance = "100",
		})
		assert.is_truthy(parsed, parseError)
		local build = { spec = { }, skillsTab = { }, calcsTab = { mainOutput = {
			Armour = 25000, Evasion = 18000, BlockChance = 50, SpellBlockChance = 40, SpellSuppressionChance = 100,
		} } }
		assert.is_true(Inputs.ValidateBuild(build, parsed))
		build.calcsTab.mainOutput.Armour = nil
		local valid, message = Inputs.ValidateBuild(build, parsed)
		assert.is_false(valid)
		assert.is_truthy(message:find("finite exact Armour", 1, true))
	end)

	it("copies every new defensive floor from native PoB output without presentation rounding", function()
		local output = assert(build.calcsTab and build.calcsTab.mainOutput, "HeadlessWrapper must expose native PoB calculations")
		local metrics = Candidate.CopyMetrics(output, Inputs.metricDefinitions)
		for _, key in ipairs({ "Armour", "Evasion", "BlockChance", "SpellBlockChance", "SpellSuppressionChance" }) do
			assert.is_true(type(output[key]) == "number" and output[key] == output[key], "PoB output missing finite " .. key)
			assert.are.equal(output[key], metrics[key], "optimizer metric must preserve native PoB precision for " .. key)
		end
	end)

	it("copies exact native damage-focus outputs without treating them as DPS floors", function()
		local output = { FireHitAverage = 12345.678901, ColdHitAverage = 2345.678901,
			LightningHitAverage = 345.678901, PhysicalHitAverage = 45678.901234, ChaosHitAverage = 56.789012 }
		local metrics = Candidate.CopyMetrics(output, Inputs.metricDefinitions)
		for key, value in pairs(output) do
			assert.are.equal(value, metrics[key], "focus ranking must preserve exact native output " .. key)
		end
		assert.is_nil(Inputs.objectives.FireHitAverage, "per-hit output is not advertised as a DPS objective")
	end)

	it("reads exact weapon hit averages and matches PoB's dual-wield aggregation", function()
		local output = {
			MainHand = { PhysicalHitAverage = 900, FireHitAverage = 300 },
			OffHand = { PhysicalHitAverage = 500, FireHitAverage = 100 },
		}
		local alternating = Candidate.CopyMetrics(output, Inputs.metricDefinitions, { skillData = { } })
		assert.are.equal(700, alternating.PhysicalHitAverage)
		assert.are.equal(200, alternating.FireHitAverage)
		local doubleHit = Candidate.CopyMetrics(output, Inputs.metricDefinitions,
			{ skillData = { doubleHitsWhenDualWielding = true } })
		assert.are.equal(1400, doubleHit.PhysicalHitAverage)
		assert.are.equal(400, doubleHit.FireHitAverage)
		local oneHand = Candidate.CopyMetrics({ MainHand = { FireHitAverage = 123.456 } },
			Inputs.metricDefinitions, { skillData = { } })
		assert.are.equal(123.456, oneHand.FireHitAverage)
	end)
end)
