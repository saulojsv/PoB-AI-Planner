local CatalystSearch = require("Modules.Optimizer.CatalystSearch")
local Candidate = require("Modules.Optimizer.Candidate")
local Calcs = require("Modules.Calcs")
local Inputs = require("Modules.Optimizer.Inputs")
local Equipment = require("Modules.Optimizer.Equipment")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local json = require("dkjson")

local function runToCompletion(parsed)
	local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
	local status, result = "running", nil
	for _ = 1, 1000 do
		status, result = job:Step()
		if status ~= "running" then break end
	end
	assert.is_true(status ~= "running", "Catalyst repair evaluation should complete")
	assert.is_true(status ~= "error", result and result.message or job.error)
	return result
end

describe("Optimizer exact Catalyst repairs", function()
	it("parses a manual total price for a 20% Catalyst and rejects invalid amounts", function()
		local parsed = assert(Inputs.Parse({ catalystCostChaos = "2.75" }))
		assert.are.equal(2.75, parsed.search.catalystCostChaos)
		assert.is_nil(Inputs.Parse({ catalystCostChaos = "-1" }))
		assert.is_nil(Inputs.Parse({ catalystCostChaos = "1000000001" }))
	end)

	it("round-trips a 20% Intrinsic Catalyst through exact PoB calculation and applies it as a reversible item variation", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local source = new("Item"):Item("Rarity: Rare\nCatalyst Attribute Source\nAmber Amulet\n--------\nItem Level: 86\n{tags:jewellery_attribute}+30 to Strength")
		build.itemsTab:AddItem(source, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = source.id
		build.itemsTab.slots.Amulet:SetSelItemId(source.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		build.itemsTab:ResetUndo()
		local sourceSignature = Candidate.BuildSignature(build)
		local baselineStrength = build.calcsTab.mainOutput.Str
		local proposals, coverage = CatalystSearch.BuildCandidates(build,
			{ { key = "attribute:Str", kind = "attribute", stat = "Str", metricKey = "Str", deficit = 1 } },
			4, { }, Inputs.Parse({}))
		assert.is_true(coverage.active)
		assert.are.equal(1, #proposals, "only the currently equipped eligible jewelry item should be transformed")
		local proposal = proposals[1]
		local entry = proposal.gearVariant.generatedItems[1]
		assert.are.equal("catalyst", entry.kind)
		assert.are.equal(6, entry.catalystId, "Intrinsic is PoB's native Catalyst ID")
		assert.are.equal(20, entry.catalystQuality)
		assert.is_truthy(entry.item.raw:find("Catalyst: Intrinsic", 1, true))
		assert.is_truthy(entry.item.raw:find("CatalystQuality: 20", 1, true))
		assert.is_nil(build.itemsTab.items[entry.tempId], "phantom Catalyst candidates must stay out of the active Items tab")

		local projected, projectionError, projectedItems = Candidate.BuildPassiveSpec(build, { }, { }, {
			gearVariant = proposal.gearVariant,
		})
		assert.is_truthy(projected, projectionError)
		local projectedBuild = { spec = projected, itemsTab = projectedItems }
		setmetatable(projectedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(projectedBuild)
		local output = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_true(output.Str > baselineStrength, "PoB's exact calculation should apply Catalyst scaling to the native amulet attribute")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "candidate calculation must preserve the source build")

		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { },
			removeNodeIds = { },
			gearVariant = proposal.gearVariant,
		})
		assert.is_true(applied, applyError)
		local selectedId = build.itemsTab.activeItemSet.Amulet.selItemId
		assert.are_not.equal(source.id, selectedId)
		assert.are.equal(6, build.itemsTab.items[selectedId].catalyst)
		assert.are.equal(20, build.itemsTab.items[selectedId].catalystQuality)
		build.calcsTab:BuildOutput()
		assert.is_true(build.calcsTab.mainOutput.Str > baselineStrength)
		build.itemsTab:Undo()
		assert.are.equal(source.id, build.itemsTab.activeItemSet.Amulet.selItemId)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "undo must restore the exact source state")
		newBuild()
	end)

	it("respects locked and already-catalyzed jewelry", function()
		newBuild()
		local amulet = new("Item"):Item("Rarity: Rare\nCatalyst Locked\nAmber Amulet\n--------\n+30 to maximum Life")
		local ring = new("Item"):Item("Rarity: Rare\nCatalyst Already Applied\nIron Ring\n--------\nCatalyst: Prismatic\nCatalystQuality: 20\n+20% to Fire Resistance")
		build.itemsTab:AddItem(amulet, true)
		build.itemsTab:AddItem(ring, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = amulet.id
		build.itemsTab.activeItemSet["Ring 1"].selItemId = ring.id
		build.itemsTab.slots.Amulet:SetSelItemId(amulet.id)
		build.itemsTab.slots["Ring 1"]:SetSelItemId(ring.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		local proposals = CatalystSearch.BuildCandidates(build,
			{ { key = "resistance:FireResist", kind = "resistance", stat = "FireResist", metricKey = "FireResist", deficit = 1 } },
			4, { Amulet = amulet.id }, assert(Inputs.Parse({})))
		assert.are.equal(0, #proposals, "locked and already-catalyzed jewelry must not be transformed")
		newBuild()
	end)

	it("uses a 20% Prismatic Catalyst for exact resistance deficits", function()
		newBuild()
		local ring = new("Item"):Item("Rarity: Rare\nCatalyst Resistance Source\nRuby Ring\n--------\nItem Level: 86\n{tags:jewellery_resistance}+20% to Fire Resistance")
		build.itemsTab:AddItem(ring, true)
		build.itemsTab.activeItemSet["Ring 1"].selItemId = ring.id
		build.itemsTab.slots["Ring 1"]:SetSelItemId(ring.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		local before = build.calcsTab.mainOutput.FireResist
		local proposals, coverage = CatalystSearch.BuildCandidates(build,
			{ { key = "resistance:FireResist", kind = "resistance", stat = "FireResist", metricKey = "FireResist", deficit = 1 } },
			2, { }, assert(Inputs.Parse({})))
		assert.is_true(coverage.active)
		assert.are.equal(1, #proposals)
		local entry = proposals[1].gearVariant.generatedItems[1]
		assert.are.equal(8, entry.catalystId, "Prismatic is PoB's native Catalyst ID")
		assert.is_truthy(entry.item.raw:find("Catalyst: Prismatic", 1, true))
		local projected, projectionError, projectedItems = Candidate.BuildPassiveSpec(build, { }, { }, {
			gearVariant = proposals[1].gearVariant,
		})
		assert.is_truthy(projected, projectionError)
		local projectedBuild = { spec = projected, itemsTab = projectedItems }
		setmetatable(projectedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(projectedBuild)
		local output = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_true(output.FireResist > before, "PoB's exact calculation should apply Catalyst scaling to the native resistance mod")
		newBuild()
	end)

	it("runs only after the exact attribute deficit and includes Catalyst investment in the strict item budget", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local amulet = new("Item"):Item("Rarity: Rare\nCatalyst Budget Source\nAmber Amulet\n--------\nItem Level: 86\n{tags:jewellery_attribute}+30 to Strength")
		local armour = new("Item"):Item("Rarity: Rare\nCatalyst Budget Requirement\nAstral Plate\n--------\nItem Level: 86\n+100 to maximum Life")
		build.itemsTab:AddItem(amulet, true)
		build.itemsTab:AddItem(armour, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = amulet.id
		build.itemsTab.activeItemSet["Body Armour"].selItemId = armour.id
		build.itemsTab.slots.Amulet:SetSelItemId(amulet.id)
		build.itemsTab.slots["Body Armour"]:SetSelItemId(armour.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		assert.is_true(build.calcsTab.mainOutput.ReqStr > build.calcsTab.mainOutput.Str,
			"the exact native armor requirement must activate the Catalyst repair pass")
		local prices = { }
		for _, entry in ipairs(Equipment.GetBudgetItemIds(build.itemsTab)) do
			prices[tostring(entry.itemId)] = entry.itemId == amulet.id and 5 or 0
		end
		local sourceSignature = Candidate.BuildSignature(build)
		local values = {
			objectiveMetric = "TotalEHP",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			evaluationBudget = "2",
			searchStoredItems = false,
			currencyBudgetAmount = "8",
			currencyBudgetUnit = "Chaos",
			currencyBudgetMode = "Trade",
			marketQuotesJson = assert(json.encode({ source = "manual", quotes = { } })),
			manualItemPricesJson = assert(json.encode(prices)),
			catalystCostChaos = "2",
		}
		local priced = runToCompletion(assert(Inputs.Parse(values)))
		assert.are.equal("no_feasible_candidate", priced.status,
			"the build must still fail the unsatisfied exact item requirement; no fallback is returned")
		assert.are.equal(1, priced.searchCoverage.catalysts.generatedCandidates)
		assert.are.equal(1, priced.searchCoverage.catalysts.exactEvaluations)
		assert.are.equal(1, priced.searchCoverage.catalysts.exactBudgetPasses)
		assert.are.equal(7, priced.searchCoverage.catalysts.lastExactBudgetTotal,
			"the Catalyst candidate is priced as the source jewelry quote plus the explicit Catalyst investment")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))

		values.catalystCostChaos = nil
		local unpriced = runToCompletion(assert(Inputs.Parse(values)))
		assert.are.equal("no_feasible_candidate", unpriced.status)
		assert.are.equal(1, unpriced.searchCoverage.catalysts.exactBudgetFailures,
			"a strict budget must reject an unpriced Catalyst instead of treating it as free")
		assert.are.equal(1, unpriced.searchCoverage.catalysts.unpricedCandidates)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
		newBuild()
	end)
end)
