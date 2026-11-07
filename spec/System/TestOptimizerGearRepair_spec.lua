local GearRepair = require("Modules.Optimizer.GearRepair")

describe("Optimizer exact-feedback local gear repair", function()
	it("targets only exact actionable attribute and configured resistance deficits", function()
		local parsed = { hard = {
			FireResist = { metricKey = "FireResist", value = 75, label = "Fire resistance" },
			FullDPS = { metricKey = "FullDPS", value = 1000000, label = "Full DPS" },
		} }
		local evaluation = {
			metrics = { Str = 100, ReqStr = 120, Dex = 70, ReqDex = 70, FireResist = 65, FullDPS = 900000 },
			requirements = { violations = {
				{ key = "attribute_requirement_Str", actual = 100, required = 120, deficit = 20, label = "Strength requirement" },
				{ key = "attribute_requirement_Dex", actual = 70, required = 70, deficit = 0, label = "Dexterity requirement" },
				{ key = "level_requirement", actual = 67, required = 68, deficit = 1, label = "Character level requirement" },
			} },
		}
		local needs = GearRepair.NeedsFromEvaluation(evaluation, parsed)
		assert.are.equal(2, #needs)
		assert.are.equal("attribute:Str", needs[1].key)
		assert.are.equal(20, needs[1].deficit)
		assert.are.equal("resistance:FireResist", needs[2].key)
		assert.are.equal(10, needs[2].deficit)
	end)

	it("uses exact candidate gate violations when baseline hard-gate cache is empty", function()
		local evaluation = {
			metrics = { LightningResist = 74 },
			violations = {
				{ key = "LightningResist", actual = 74, required = 75, label = "Lightning resistance" },
			},
		}
		local needs = GearRepair.NeedsFromEvaluation(evaluation, { hard = { } })
		assert.are.equal(1, #needs)
		assert.are.equal("resistance:LightningResist", needs[1].key)
		assert.are.equal(1, needs[1].deficit)
	end)

	it("ranks stored replacements by native unconditional item modifiers and keeps unscored options", function()
		local strengthItem = new("Item"):Item("Rarity: Rare\nRepair Strength\nAmber Amulet\n--------\n+35 to Strength")
		local utilityItem = new("Item"):Item("Rarity: Rare\nRepair Utility\nAmber Amulet\n--------\n+40 to maximum Life")
		local itemsTab = { items = { [1] = utilityItem, [2] = strengthItem } }
		local candidates = {
			{ label = "Unscored local option", gearVariant = { inventorySearch = true, changedSlots = { "Amulet" }, overrides = { Amulet = 1 } } },
			{ label = "Strength local option", gearVariant = { inventorySearch = true, changedSlots = { "Amulet" }, overrides = { Amulet = 2 } } },
		}
		local ranked = GearRepair.RankCandidates(candidates, itemsTab, {
			{ kind = "attribute", stat = "Str", metricKey = "Str", deficit = 30 },
		})
		assert.are.equal("Strength local option", ranked[1].label:match("Local requirement repair: (.+)"))
		assert.are.equal("Unscored local option", ranked[2].label)
		assert.is_true(ranked[1].requirementRepair)
		assert.is_false(ranked[2].requirementRepair)
	end)

	it("ranks generated native rares by their parsed unconditional repair modifiers", function()
		local syntheticItem = { modList = {
			{ name = "LightningResist", type = "BASE", value = 12, flags = 0, keywordFlags = 0 },
		} }
		local candidate = {
			label = "Synthetic rare ring",
			gearVariant = {
				syntheticSearch = true,
				changedSlots = { "Ring 2" },
				generatedItems = { { slotName = "Ring 2", tempId = 41, item = syntheticItem } },
			},
		}
		local ranked = GearRepair.RankCandidates({ candidate }, nil, {
			{ kind = "resistance", stat = "LightningResist", metricKey = "LightningResist", deficit = 1 },
		})
		assert.are.equal(candidate, ranked[1])
		assert.is_true(ranked[1].requirementRepair)
		assert.is_true(ranked[1].requirementRepairScore > 0)
	end)

	it("records improvement and cleared target deficits only from exact result metrics", function()
		local coverage = GearRepair.NewCoverage()
		coverage.active = true
		coverage.baselineNeeds = {
			{ kind = "attribute", stat = "Str", metricKey = "Str", requiredMetricKey = "ReqStr", required = 120 },
		}
		coverage.baselineDeficit = 20 / 120
		local candidate = { label = "Stored amulet", gearVariant = { inventorySearch = true } }
		GearRepair.RecordExact(coverage, candidate, { metrics = { Str = 120, ReqStr = 120 } })
		assert.are.equal(1, coverage.exactCandidateEvaluations)
		assert.are.equal(1, coverage.improvedExactEvaluations)
		assert.are.equal(1, coverage.fullyRepairedExactEvaluations)
		assert.are.equal(0, coverage.bestRemainingDeficit)
		assert.are.equal("Stored amulet", coverage.bestCandidate)
		GearRepair.RecordExact(coverage, {
			label = "Passive route plus amulet",
			gearVariant = { inventorySearch = true, inventoryRoutePair = true },
		}, { metrics = { Str = 120, ReqStr = 120 } })
		assert.are.equal(1, coverage.exactCandidateEvaluations,
			"route-plus-item exploration is later than the local repair-first phase")
	end)

	it("keeps unsupported post-candidate metrics out of JSON-facing coverage", function()
		local coverage = GearRepair.NewCoverage()
		coverage.active = true
		coverage.baselineNeeds = {
			{ kind = "resistance", stat = "FireResist", metricKey = "FireResist", required = 75 },
		}
		coverage.baselineDeficit = 0.2
		GearRepair.RecordExact(coverage, { gearVariant = { inventorySearch = true } }, { metrics = { } })
		assert.are.equal(1, coverage.unsupportedExactEvaluations)
		assert.is_nil(coverage.bestRemainingDeficit)
		assert.is_nil(coverage.bestRemainingValues)
	end)
end)
