local Activity = require("Modules.Optimizer.Activity")

local function minionRecord()
	return {
		identity = "srs-main",
		name = "Summon Raging Spirit",
		group = "6L SRS",
		kind = "minion",
		hasDamage = true,
		exact = true,
		count = 20,
		resources = {
			Life = { cost = 374.64, netRegen = 421.7, leech = 0, onHit = 0 },
			Mana = { cost = 0, netRegen = 0, leech = 0, onHit = 0 },
			ES = { cost = 374.64, netRegen = 0, leech = 0, onHit = 0 },
		},
		otherResourceCosts = { },
		unsupportedReason = "PoB's damage snapshot does not certify minion replacement cadence",
	}
end

describe("Optimizer activity resource rates", function()
	it("does not multiply PoB per-second resource rates by minion entity count", function()
		local result = Activity.Evaluate({ objective = "FullDPS", hard = { } }, nil, { minionRecord() }, false)

		assert.are.equal("unsupported", result.status,
			"minion damage cadence remains uncertified even when the resource arithmetic is exact")
		assert.is_true(math.abs(47.06 - result.metrics.SustainedLifeMargin) < 1e-9)
		assert.is_true(math.abs(-374.64 - result.metrics.SustainedEnergyShieldMargin) < 1e-9)
		assert.are.equal(20, result.activities[1].count,
			"entity count remains available for damage context and is not discarded")
	end)

	it("scales explicit minion resource schedules by use rate, not entity count", function()
		local record = minionRecord()
		record.unsupportedReason = nil
		record.damageUnsupportedReason = "PoB does not certify minion replacement cadence"
		record.costScheduleEligible = true
		record.resources.ES.netRegen = 421.7
		local result, err = Activity.EvaluateSchedule({ objective = "ResourceSustain", hard = { } }, nil,
			{ record }, false, {
				{ identity = "srs-main", mode = "scheduled", ratePercent = 50 },
			}, { record })

		assert.is_truthy(result, err)
		assert.are.equal("pass", result.sustainStatus)
		assert.is_true(math.abs(234.38 - result.metrics.SustainedLifeMargin) < 1e-9)
		assert.is_true(math.abs(234.38 - result.metrics.SustainedEnergyShieldMargin) < 1e-9)
		assert.is_false(result.damageScheduleCertified)
	end)
end)
