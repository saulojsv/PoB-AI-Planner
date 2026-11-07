local FactorialStudy = require("Modules.Optimizer.FactorialStudy")

describe("Optimizer exact factorial interaction analysis", function()
	local function cell(metrics)
		return { metrics = metrics }
	end

	it("computes raw difference-in-differences from four exact metric cells", function()
		local result, err = FactorialStudy.Compute({
			baseline = cell({ CombinedDPS = 100, Life = 5000, ManaPerSecondCost = 5 }),
			factorA = cell({ CombinedDPS = 130, Life = 5200, ManaPerSecondCost = 6 }),
			factorB = cell({ CombinedDPS = 120, Life = 5100, ManaPerSecondCost = 8 }),
			combined = cell({ CombinedDPS = 170, Life = 5400, ManaPerSecondCost = 11 }),
		})
		assert.is_truthy(result, err)
		assert.are.equal("combined - factorA - factorB + baseline", result.formula)
		assert.are.equal(3, result.metricCount)
		assert.are.equal(20, result.metrics.CombinedDPS.interaction)
		assert.are.equal(30, result.metrics.CombinedDPS.factorADelta)
		assert.are.equal(100, result.metrics.Life.interaction)
		assert.are.equal(2, result.metrics.ManaPerSecondCost.interaction)
	end)

	it("keeps negative and order-independent interactions without interpreting metric direction", function()
		local forward = assert(FactorialStudy.Compute({
			baseline = cell({ CombinedDPS = 100 }),
			factorA = cell({ CombinedDPS = 140 }),
			factorB = cell({ CombinedDPS = 120 }),
			combined = cell({ CombinedDPS = 150 }),
		}))
		local swapped = assert(FactorialStudy.Compute({
			baseline = cell({ CombinedDPS = 100 }),
			factorA = cell({ CombinedDPS = 120 }),
			factorB = cell({ CombinedDPS = 140 }),
			combined = cell({ CombinedDPS = 150 }),
		}))
		assert.are.equal(-10, forward.metrics.CombinedDPS.interaction)
		assert.are.equal(forward.metrics.CombinedDPS.interaction, swapped.metrics.CombinedDPS.interaction)
	end)

	it("compares only metrics that are finite in all four cells", function()
		local result = assert(FactorialStudy.Compute({
			baseline = cell({ CombinedDPS = 100, Life = 5000, Missing = 1 }),
			factorA = cell({ CombinedDPS = 120, Life = 5100 }),
			factorB = cell({ CombinedDPS = 130, Life = 5200 }),
			combined = cell({ CombinedDPS = 160, Life = math.huge }),
		}))
		assert.are.same({ "CombinedDPS" }, result.metricKeys)
		assert.is_nil(result.metrics.Life)
	end)

	it("fails closed when one cell or every shared numeric metric is missing", function()
		local missingCell, missingError = FactorialStudy.Compute({
			baseline = cell({ CombinedDPS = 100 }),
			factorA = cell({ CombinedDPS = 110 }),
			factorB = cell({ CombinedDPS = 120 }),
		})
		assert.is_nil(missingCell)
		assert.is_truthy(missingError:find("combined", 1, true))

		local noCommon, noCommonError = FactorialStudy.Compute({
			baseline = cell({ CombinedDPS = 100 }),
			factorA = cell({ Life = 1000 }),
			factorB = cell({ CombinedDPS = 120 }),
			combined = cell({ CombinedDPS = 140 }),
		})
		assert.is_nil(noCommon)
		assert.is_truthy(noCommonError:find("common finite", 1, true))
	end)
end)
