local Inputs = require("Modules.Optimizer.Inputs")
local TreeSearch = require("Modules.Optimizer.TreeSearch")
local HierarchicalController = require("Modules.Optimizer.HierarchicalController")
local Candidate = require("Modules.Optimizer.Candidate")
local PhantomSim = require("Modules.Optimizer.PhantomSim")

describe("Optimizer hierarchical spatial controller", function()
	it("conserves every balanced and focused point plan", function()
		local plans = assert(HierarchicalController.AllocatePointPlans(17, { "SouthEast", "Hub", "NorthEast" }, 4))
		assert.are.equal(4, #plans)
		assert.are.equal("balanced", plans[1].id)
		for _, plan in ipairs(plans) do
			local allocated = 0
			for _, amount in pairs(plan.allocations) do allocated = allocated + amount end
			assert.are.equal(17, allocated)
			assert.are.equal(17, plan.allocatedPoints)
		end
		assert.are.equal("focus_hub", plans[2].id)
		assert.are.equal(17, plans[2].allocations.Hub)
		assert.are.equal("focus_northeast", plans[3].id)
		assert.are.equal("focus_southeast", plans[4].id)
		local rotationA = assert(HierarchicalController.AllocatePointPlans(2, { "Hub", "NorthEast", "SouthEast" }, 0))[1]
		local rotationB = assert(HierarchicalController.AllocatePointPlans(2, { "Hub", "NorthEast", "SouthEast" }, 1))[1]
		assert.are_not.equal(rotationA.allocations.Hub, rotationB.allocations.Hub, "seed rotation must prevent a fixed remainder-zone bias")
	end)

	it("distributes every proposal slot deterministically", function()
		local entries = { "a", "b", "c", "d" }
		local first = assert(HierarchicalController.DistributeCandidateSlots(11, entries, 3))
		local second = assert(HierarchicalController.DistributeCandidateSlots(11, entries, 3))
		assert.are.same(first, second)
		local total = 0
		for _, amount in ipairs(first) do total = total + amount end
		assert.are.equal(11, total)
		assert.are.equal(3, first[1])
		assert.are.equal(3, first[2])
		assert.are.equal(2, first[3])
		assert.are.equal(3, first[4])
	end)

	it("generates bounded native-tree zonal proposals and preserves user masks", function()
		newBuild()
		local inputs = assert(Inputs.Parse({
			allowedRegions = "Hub,NorthWest,NorthEast,SouthWest,SouthEast",
			maxAddedPoints = "12",
			seed = "7",
		}))
		local valid, inputError = Inputs.ValidateAgainstTree(inputs, build.spec.tree)
		assert.is_true(valid, inputError)
		assert.are.equal("spatial", inputs.branch.partition)
		local regionByNode, topology, topologyError = TreeSearch.BuildRegionMap(build.spec, "spatial")
		assert.is_truthy(regionByNode, topologyError)
		local proposals, err, cancelled, coverage, handled = HierarchicalController.BuildSpatialCandidates(
			build.spec, inputs, 14, 12, regionByNode, { cancelled = false })
		assert.is_true(handled)
		assert.is_nil(err)
		assert.is_false(cancelled)
		assert.are.equal("deterministic_hierarchical_spatial", coverage.mode)
		assert.is_true(coverage.budgetConserved)
		assert.are.equal(14, coverage.candidateSlots)
		assert.is_truthy(topology.partitionVersion)
		assert.is_truthy(proposals)
		assert.is_true(#proposals > 0, "native PoB graph should yield at least one reachable route")
		local tagged = 0
		for _, proposal in ipairs(proposals) do
			assert.is_true(#(proposal.nodeIds or { }) <= 12, "proposal exceeds its strict added-point budget")
			local expert = proposal.hierarchicalExpert
			if expert then
				tagged = tagged + 1
				assert.are.equal("hrl-zones-v1", expert.policyVersion)
				assert.is_true(#(proposal.nodeIds or { }) <= expert.pointBudget, "route exceeds its zonal expert proposal budget")
				assert.is_truthy(expert.zone == "Hub" or expert.zone == "NorthWest" or expert.zone == "NorthEast" or expert.zone == "SouthWest" or expert.zone == "SouthEast")
			end
			for _, duplicateExpert in ipairs(proposal.hierarchicalExperts or { }) do
				assert.are.equal("hrl-zones-v1", duplicateExpert.policyVersion)
				assert.is_true(#(proposal.nodeIds or { }) <= duplicateExpert.pointBudget, "deduplicated expert route exceeds its proposal budget")
			end
		end
		assert.is_true(tagged > 0, "at least one route must retain zonal-expert provenance")
	end)

	it("preserves zone provenance when a route is combined with a mutation", function()
		local multiRoute = TreeSearch.CombineCandidates({
			{
				nodeIds = { 90, 3 }, label = "Route NW",
				hierarchicalExpert = { policyVersion = "hrl-zones-v1", planId = "balanced", zone = "NorthWest", pointBudget = 2 },
			},
			{
				nodeIds = { 80, 4 }, label = "Route SE",
				hierarchicalExpert = { policyVersion = "hrl-zones-v1", planId = "focus_southeast", zone = "SouthEast", pointBudget = 2 },
			},
		}, 1, 4)
		assert.are.equal(1, #multiRoute)
		assert.are.equal("multi_route", multiRoute[1].hierarchicalCombinationKind)
		assert.are.equal(2, #multiRoute[1].hierarchicalExperts)

		local route = {
			nodeIds = { 90, 3 },
			removeNodeIds = { },
			label = "[NorthEast: 2 points] Route A",
			island = 1,
			hierarchicalExpert = { policyVersion = "hrl-zones-v1", planId = "balanced", zone = "NorthEast", pointBudget = 2 },
		}
		local mutation = {
			nodeIds = { },
			label = "Fireball 20/23",
			gemVariant = { groupIndex = 1, gemIndex = 1, level = 20, quality = 23 },
		}
		local combined = PhantomSim.CombineRoutesAndMutations({ route }, {
			{ key = "gems", candidates = { mutation } },
		}, 1)
		assert.are.equal(1, #combined)
		assert.is_true(combined[1].hierarchicalCombination)
		assert.are.equal("route_mutation", combined[1].hierarchicalCombinationKind)
		assert.are.equal("NorthEast", combined[1].hierarchicalExpert.zone)
		assert.are.equal("hrl-zones-v1", combined[1].hierarchicalExpert.policyVersion)
	end)

	it("preserves plural gem variants when a route is combined with a mutation", function()
		local mutation = {
			label = "Two linked support changes",
			gemVariants = {
				{ groupIndex = 1, gemIndex = 2, level = 20, quality = 20, kind = "support_swap" },
				{ groupIndex = 1, gemIndex = 3, level = 20, quality = 23, kind = "support_swap" },
			},
		}
		local combined = PhantomSim.CombineRoutesAndMutations({
			{ nodeIds = { 90, 3 }, label = "Route NW" },
		}, {
			{ key = "gems", candidates = { mutation } },
		}, 1)

		assert.are.equal(1, #combined)
		assert.are.equal(2, #combined[1].gemVariants)
		assert.are.same(mutation.gemVariants, combined[1].gemVariants)
		assert.are_not.equal(mutation.gemVariants, combined[1].gemVariants)
		for index, variant in ipairs(mutation.gemVariants) do
			assert.are_not.equal(variant, combined[1].gemVariants[index])
		end
	end)

	it("integrates zonal proposals into PhantomSim exact evaluation and reports coverage", function()
		newBuild()
		build.characterLevel = 40
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Fireball 12/0  1")
		build.mainSocketGroup = 1
		build.skillsTab.socketGroupList[1].includeInFullDPS = true
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local inputs = assert(Inputs.Parse({
			objectiveMetric = "FullDPS",
			allowedRegions = "Hub,NorthWest,NorthEast,SouthWest,SouthEast",
			maxAddedPoints = "10",
			evaluationBudget = "40",
			seed = "13",
		}))
		local job = PhantomSim.RunPhantomSim(build, inputs, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 1000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "bounded exact spatial search did not finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.is_truthy(result.searchCoverage.zones)
		assert.are.equal("deterministic_hierarchical_spatial", result.searchCoverage.zones.mode)
		assert.are.equal(10, result.searchCoverage.zones.pointBudget)
		assert.is_true(result.searchCoverage.zones.budgetConserved)
		assert.is_true(result.searchCoverage.zones.generatedCandidates > 0)
		assert.is_true(result.searchCoverage.zones.exactEvaluations > 0, "a zonal proposal must reach exact PoB evaluation")
		assert.are.equal("FullDPS", result.searchCoverage.zones.objectiveMetric)
		assert.is_truthy(result.searchCoverage.zones.baselineObjectiveValue)
		assert.is_table(result.searchCoverage.zones.zoneResults)
		local observedZoneCount = 0
		for _, zoneResult in pairs(result.searchCoverage.zones.zoneResults) do
			observedZoneCount = observedZoneCount + 1
			assert.is_true(zoneResult.exactEvaluations > 0)
			assert.is_true(zoneResult.feasibleCandidates >= 0)
		end
		assert.is_true(observedZoneCount > 0, "exact results must remain attributable to their contributing zones")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "phantom search must preserve the active source build")
	end)
end)
