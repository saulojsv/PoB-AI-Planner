local Inputs = require("Modules.Optimizer.Inputs")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local Candidate = require("Modules.Optimizer.Candidate")
local json = require("dkjson")

local function runOneExactCandidate(textValues)
	local parsed, parseError = Inputs.Parse(textValues)
	assert(parsed, parseError)
	local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
	local status, result = "running", nil
	for _ = 1, 3000 do
		status, result = job:Step()
		if status ~= "running" then break end
	end
	assert(status ~= "running", "the single-candidate market gate should complete")
	assert(status ~= "error", result and result.message or job.error)
	return result
end

describe("Optimizer market budget exact candidate integration", function()
	it("gates an exact PoB candidate and preserves the source build", function()
		newBuild()
		build.characterLevel = 100
		build.characterLevelAutoMode = false
		local amulet = new("Item"):Item("Rarity: Rare\nBudget Gate Amulet\nAmber Amulet\n--------\n+30 to maximum Life\n+20% to Fire Resistance")
		build.itemsTab:AddItem(amulet, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = amulet.id
		build.itemsTab.slots.Amulet:SetSelItemId(amulet.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local quoteSnapshot = assert(json.encode({ source = "manual", quotes = { } }))
		local itemPrices = assert(json.encode({ [tostring(amulet.id)] = 5 }))
		local values = {
			objectiveMetric = "TotalEHP",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			evaluationBudget = "1",
			searchStoredItems = false,
			currencyBudgetUnit = "Chaos",
			currencyBudgetMode = "Trade",
			marketQuotesJson = quoteSnapshot,
			manualItemPricesJson = itemPrices,
		}

		values.currencyBudgetAmount = "4.99"
		local overBudget = runOneExactCandidate(values)
		assert(overBudget.status == "no_feasible_candidate")
		assert(overBudget.evaluations == 1)
		assert(overBudget.candidate == nil, "a failed cost floor must not return a fallback candidate")
		local costViolation = false
		for _, violation in ipairs(overBudget.bestObservedViolations or { }) do
			if violation.key == "currency_budget" then costViolation = true end
		end
		assert(costViolation, "the exact candidate should report the estimated cost deficit")
		assert(sourceSignature == Candidate.BuildSignature(build), "phantom budget evaluation must preserve the active PoB build")

		values.currencyBudgetAmount = "5"
		local atLimit = runOneExactCandidate(values)
		local failureDetails = { }
		for _, violation in ipairs(atLimit.bestObservedViolations or { }) do
			failureDetails[#failureDetails + 1] = tostring(violation.key) .. ": " .. tostring(violation.reason)
		end
		assert(atLimit.status == "feasible", tostring(atLimit.message) .. "; " .. table.concat(failureDetails, "; "))
		assert(atLimit.evaluations == 1)
		assert(atLimit.candidate.evaluation.marketBudget.withinBudget)
		assert(atLimit.candidate.evaluation.marketBudget.total == 5)
		assert(sourceSignature == Candidate.BuildSignature(build), "a feasible cost evaluation must also preserve the active PoB build")
		newBuild()
	end)

	it("requires explicit synthetic gear cost for a strict currency budget", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local amulet = new("Item"):Item("Rarity: Rare\nSynthetic Budget Source\nAmber Amulet\n--------\nItem Level: 86\n+30 to maximum Life\n+20% to Fire Resistance")
		build.itemsTab:AddItem(amulet, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = amulet.id
		build.itemsTab.slots.Amulet:SetSelItemId(amulet.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local values = {
			objectiveMetric = "TotalEHP",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			evaluationBudget = "2",
			searchStoredItems = false,
			searchSyntheticGear = true,
			syntheticItemLevel = "86",
			currencyBudgetUnit = "Chaos",
			currencyBudgetMode = "Trade",
			currencyBudgetAmount = "10",
			marketQuotesJson = assert(json.encode({ source = "manual", quotes = { } })),
			manualItemPricesJson = assert(json.encode({ [tostring(amulet.id)] = 50 })),
			syntheticItemCostChaos = "5",
		}
		local priced = runOneExactCandidate(values)
		assert(priced.status == "feasible", tostring(priced.message))
		assert(priced.candidate.gearVariant.syntheticSearch, "the priced rare must be the candidate that passes the budget")
		assert(priced.candidate.evaluation.marketBudget.withinBudget)
		assert(priced.candidate.evaluation.marketBudget.total == 5)
		assert(priced.searchCoverage.syntheticGear.exactEvaluations == 1)
		assert(sourceSignature == Candidate.BuildSignature(build), "synthetic market evaluation must preserve the active build")

		values.syntheticItemCostChaos = nil
		local unpriced = runOneExactCandidate(values)
		assert(unpriced.status == "no_feasible_candidate")
		assert(unpriced.candidate == nil, "an unpriced synthetic item must not be returned as fallback")
		assert(unpriced.searchCoverage.syntheticGear.exactEvaluations == 1,
			"the unpriced synthetic item must reach the exact gate and be rejected")
		assert(sourceSignature == Candidate.BuildSignature(build), "an unpriced synthetic search must preserve the active build")
		newBuild()
	end)
end)
