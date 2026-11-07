local SocketRepairComposer = require("Modules.Optimizer.SocketRepairComposer")

describe("AI Planner multi-slot socket repair composition", function()
	it("keeps all native slot reworks in one route candidate", function()
		local build = { itemsTab = { activeItemSet = { } } }
		local bodyPlan = { slot = "Body Armour", colors = { "G" }, linkGroups = { 0 } }
		local helmetPlan = { slot = "Helmet", colors = { "R" }, linkGroups = { 0 } }
		local route = { gearVariant = {
			overrides = { Ring = 100 },
			items = { { slot = "Ring", itemId = 100 } },
			generatedItems = { { slotName = "Ring", tempId = 100 } },
			changedSlots = { "Ring" },
			syntheticSearch = true,
		} }
		local bodyRepair = { gearVariant = {
			overrides = { ["Body Armour"] = 201 },
			items = { { slot = "Body Armour", itemId = 201, synthetic = true } },
			generatedItems = { { slotName = "Body Armour", tempId = 201 } },
			changedSlots = { "Body Armour" },
			socketRepair = true,
			socketRepairOnly = true,
		} }
		local helmetRepair = { gearVariant = {
			overrides = { Helmet = 202 },
			items = { { slot = "Helmet", itemId = 202, synthetic = true } },
			generatedItems = { { slotName = "Helmet", tempId = 202 } },
			changedSlots = { "Helmet" },
			socketRepair = true,
			socketRepairOnly = true,
		} }

		local bodyMerged = assert(SocketRepairComposer.ComposeGearVariant(build, route, bodyRepair, bodyPlan))
		local combinedRoute = { gearVariant = bodyMerged }
		local allMerged = assert(SocketRepairComposer.ComposeGearVariant(build, combinedRoute, helmetRepair, helmetPlan))
		assert.are.equal(100, allMerged.overrides.Ring)
		assert.are.equal(201, allMerged.overrides["Body Armour"])
		assert.are.equal(202, allMerged.overrides.Helmet)
		assert.are.equal(3, #allMerged.generatedItems)
		assert.are.equal(3, #allMerged.changedSlots)
		assert.is_true(allMerged.socketRepair)
		assert.is_nil(allMerged.socketRepairOnly, "a composed multi-slot route is not a repair-only seed")
	end)

	it("rejects a competing rework for a required repair slot", function()
		local build = { itemsTab = { activeItemSet = { } } }
		local route = { gearVariant = { overrides = { Helmet = 301 }, changedSlots = { "Helmet" } } }
		local repair = { gearVariant = { overrides = { Helmet = 302 } } }
		local result, reason = SocketRepairComposer.ComposeGearVariant(build, route, repair,
			{ slot = "Helmet", colors = { "R" }, linkGroups = { 0 } })
		assert.is_nil(result)
		assert.is_truthy(reason:find("replaces the slot required", 1, true))
	end)

	it("requires the generated item to match the requested native socket colors and links", function()
		local build = { itemsTab = { activeItemSet = { }, items = { } } }
		local plan = { slot = "Body Armour", colors = { "G", "R" }, linkGroups = { 0, 0 } }
		local candidate = { gearVariant = {
			overrides = { ["Body Armour"] = 401 },
			generatedItems = { { slotName = "Body Armour", tempId = 401, item = {
				sockets = { { color = "G", group = 0 }, { color = "R", group = 0 } },
			} } },
		} }
		assert.is_true(SocketRepairComposer.CandidateRepairsSocketPlan(build, candidate, plan))
		candidate.gearVariant.generatedItems[1].item.sockets[1].color = "B"
		assert.is_false(SocketRepairComposer.CandidateRepairsSocketPlan(build, candidate, plan))
	end)
end)
