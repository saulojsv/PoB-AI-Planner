local StudyBuilds = require("Modules.Optimizer.StudyBuilds")

describe("Optimizer build-ingestion scope classification", function()
	it("keeps old PoE tree versions outside optimizer scope without calling them native failures", function()
		local scope = StudyBuilds.ClassifyTargetScope("unused", {
			engine = { treeVersion = "3_23" },
			mainSkill = { gameId = "Game/Fireball", variantId = "Fireball" },
		})
		assert.are.equal("out_of_target_scope", scope.status)
		assert.are.equal("tree_not_in_3_24_to_3_29", scope.reason)
		assert.is_nil(scope.eligibility)
	end)

	it("keeps incomplete scope evidence unclassified so its native build can still be archived", function()
		local scope = StudyBuilds.ClassifyTargetScope("unused", nil)
		assert.are.equal("unclassified", scope.status)
		assert.are.equal("profile_invalid", scope.reason)
		assert.is_nil(scope.eligibility)
	end)
end)
