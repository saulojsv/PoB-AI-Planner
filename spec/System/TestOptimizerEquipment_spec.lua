local Equipment = require("Modules.Optimizer.Equipment")
local Inputs = require("Modules.Optimizer.Inputs")
local Candidate = require("Modules.Optimizer.Candidate")
local Calcs = require("Modules.Calcs")
local PhantomSim = require("Modules.Optimizer.PhantomSim")
local SyntheticGear = require("Modules.Optimizer.SyntheticGear")
local SkillCatalog = require("Modules.Optimizer.SkillCatalog")
local SkillSeed = require("Modules.Optimizer.SkillSeed")
local RoutePlanner = require("Modules.Optimizer.RoutePlanner")
local json = require("dkjson")

describe("Optimizer exact equipment choices", function()
	it("distinguishes flask slot swaps from equipment mods that mention flask mechanics", function()
		assert.is_true(Equipment.DescribesFlaskMutation("Flask 5 → Progenesis"))
		assert.is_true(Equipment.DescribesFlaskMutation("Staff + Flask 5 → Progenesis"))
		assert.is_false(Equipment.DescribesFlaskMutation("Staff + flask"),
			"a bare flask word is not proof of a flask-slot change")
		assert.is_false(Equipment.DescribesFlaskMutation("Forbidden flask upgrade"),
			"unstructured prose cannot classify a flask-slot mutation")
		assert.is_false(Equipment.DescribesFlaskMutation("Belt affix → 20% increased Flask Effect Duration"),
			"a flask-related affix on reworked equipment is not a flask-slot replacement")
		assert.is_false(Equipment.DescribesFlaskMutation("Belt affix → 40% increased Flask Life Recovery rate"),
			"recovery-rate affixes on gear are not flask-slot replacements")
		assert.is_false(Equipment.DescribesFlaskMutation("Belt: Recover Life when you use a Flask"),
			"a flask condition on an item description is not a flask-slot replacement")
		assert.is_false(Equipment.DescribesFlaskMutation("Belt affix → Magic Utility Flasks cannot be Used"),
			"a flask-use restriction on a belt is still a belt rework")
	end)

	it("parses bounded equipment mappings and rejects malformed or unsafe IDs", function()
		local parsed = assert(Inputs.Parse({ requiredItemsJson = '{"Amulet":17,"Ring 1":29}' }))
		assert.are.same({ Amulet = 17, ["Ring 1"] = 29 }, parsed.search.equipmentOverrides)
		assert.is_true(parsed.search.searchStoredItems, "stored-item exploration is enabled by default")
		assert.is_false(assert(Inputs.Parse({ searchStoredItems = false })).search.searchStoredItems)
		assert.is_false(assert(Inputs.Parse({ searchStoredItems = "false" })).search.searchStoredItems)
		assert.is_nil(Inputs.Parse({ searchStoredItems = "sometimes" }))
		assert.are.same({ }, assert(Inputs.Parse({ requiredItemsJson = "{}" })).search.equipmentOverrides)
		assert.are.equal("{}", Equipment.EncodeOverrides({ }), "clearing the last item must retain JSON object form")
		assert.are.same({ }, assert(Inputs.Parse({ requiredItemsJson = Equipment.EncodeOverrides({ }) })).search.equipmentOverrides)
		assert.is_nil(Inputs.Parse({ requiredItemsJson = "[]" }))
		assert.is_nil(Inputs.Parse({ requiredItemsJson = '{"Amulet":0}' }))
		assert.is_nil(Inputs.Parse({ requiredItemsJson = '{"Amulet":"17"}' }))
		assert.is_nil(Inputs.Parse({ requiredItemsJson = "not-json" }))
	end)

	it("evaluates an existing item in an isolated PoB set and applies it as an undoable variation", function()
		newBuild()
		local baseAmulet = new("Item"):Item("Rarity: Rare\nEquipment Matrix Base\nAmber Amulet\n--------\n+30 to maximum Life\n+20% to Fire Resistance")
		local replacementAmulet = new("Item"):Item("Rarity: Rare\nEquipment Matrix Candidate\nAmber Amulet\n--------\n+80 to maximum Life\n+35% to Fire Resistance")
		build.itemsTab:AddItem(baseAmulet, true)
		build.itemsTab:AddItem(replacementAmulet, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = baseAmulet.id
		build.itemsTab.slots.Amulet:SetSelItemId(baseAmulet.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.itemsTab:AddUndoState()
		build.calcsTab:BuildOutput()

		local sourceSetId = build.itemsTab.activeItemSetId
		local sourceSignature = Candidate.BuildSignature(build)
		local sourceLife = build.calcsTab.mainOutput.Life
		local overrides = { Amulet = replacementAmulet.id }
		local parsed = assert(Inputs.Parse({ objectiveMetric = "TotalEHP", requiredItemsJson = json.encode(overrides) }))
		local valid, validationError = Inputs.ValidateBuild(build, parsed)
		assert.is_true(valid, validationError)
		local projected, projectionError, isolatedItems = Candidate.BuildPassiveSpec(build, { }, { }, {
			gearVariant = { overrides = parsed.search.equipmentOverrides },
		})
		assert.is_truthy(projected, projectionError)
		assert.are.equal(replacementAmulet.id, isolatedItems.activeItemSet.Amulet.selItemId)
		assert.are.equal(baseAmulet.id, build.itemsTab.activeItemSet.Amulet.selItemId, "phantom evaluation must leave the active PoB set untouched")

		local isolatedBuild = { spec = projected, itemsTab = isolatedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local output, env = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_truthy(output and output.Life)
		assert.is_truthy(env)
		assert.is_true(output.Life > sourceLife, "PoB's native life output must reflect the selected replacement amulet")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))

		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { },
			removeNodeIds = { },
			gearVariant = { overrides = overrides },
		})
		assert.is_true(applied, applyError)
		assert.are_not.equal(sourceSetId, build.itemsTab.activeItemSetId)
		assert.are.equal(replacementAmulet.id, build.itemsTab.activeItemSet.Amulet.selItemId)
		assert.are.equal(baseAmulet.id, build.itemsTab.itemSets[sourceSetId].Amulet.selItemId)
		build.itemsTab:Undo()
		assert.are.equal(sourceSetId, build.itemsTab.activeItemSetId)
		assert.are.equal(baseAmulet.id, build.itemsTab.activeItemSet.Amulet.selItemId)
		newBuild()
	end)

	it("uses native PoB slot rules to reject an item assigned to the wrong slot", function()
		local itemSet = { id = 1, Amulet = { selItemId = 1 }, Helmet = { selItemId = 0 } }
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = itemSet,
			itemSets = { [1] = itemSet },
			items = { [1] = { type = "Amulet" }, [2] = { type = "Ring" } },
			slots = { Amulet = { }, Helmet = { } },
			IsItemValidForSlot = function(_, item, slotName)
				return item.type == slotName
			end,
		}
		local valid, reason = Equipment.Validate({ itemsTab = itemsTab }, { Amulet = 2 })
		assert.is_false(valid)
		assert.is_truthy(reason:find("PoB rejects", 1, true))
		assert.are.equal(1, itemSet.Amulet.selItemId, "validation must never mutate the source item set")
		assert.is_false(Equipment.Validate({ itemsTab = itemsTab }, { Amulet = "1" }))
	end)

	it("clears a natively incompatible off-hand for main-hand reworks without mutating the source set", function()
		local itemSet = {
			id = 1,
			["Weapon 1"] = { selItemId = 3 },
			["Weapon 2"] = { selItemId = 1 },
		}
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = itemSet,
			itemSets = { [1] = itemSet },
			items = {
				[1] = { type = "Shield", base = { type = "Shield" }, name = "Current shield" },
				[2] = { type = "Weapon", base = { type = "Two Handed Sword", weapon = { } }, name = "Two-handed sword" },
				[3] = { type = "Weapon", base = { type = "One Handed Sword", weapon = { } }, name = "Current sword" },
			},
			slots = {
				["Weapon 1"] = { shown = function() return true end },
				["Weapon 2"] = { shown = function() return true end },
			},
			IsItemValidForSlot = function(self, item, slotName, proposedSet)
				if slotName == "Weapon 1" then return item.base and item.base.weapon ~= nil end
				if slotName == "Weapon 2" then
					local mainId = proposedSet["Weapon 1"].selItemId or 0
					local mainItem = self.items[mainId]
					if mainItem and mainItem.base.type == "Two Handed Sword" then return false end
					return item.type == "Shield"
				end
				return false
			end,
		}
		local build = { itemsTab = itemsTab }
		local candidate = {
			label = "Two-handed weapon rework",
			gearVariant = {
				label = "Two-handed weapon rework",
				overrides = { ["Weapon 1"] = 2 },
				changedSlots = { "Weapon 1" },
				items = { { slot = "Weapon 1", itemId = 2, name = "Two-handed sword" } },
			},
		}

		local normalized = Equipment.NormalizeWeaponHandConflicts(build, candidate.gearVariant)
		assert.are.equal(2, normalized.overrides["Weapon 1"])
		assert.are.equal(0, normalized.overrides["Weapon 2"], "the illegal shield must be explicitly removed from this candidate")
		assert.are.same({ "Weapon 1", "Weapon 2" }, normalized.changedSlots)
		assert.is_truthy(normalized.label:find("Weapon 2", 1, true))
		local valid, validationError, proposedSet = Equipment.Validate(build, normalized.overrides)
		assert.is_true(valid, validationError)
		assert.are.equal(0, proposedSet["Weapon 2"].selItemId)
		assert.are.equal(1, itemSet["Weapon 2"].selItemId, "search must leave the loaded shield equipped on the source build")

		local explicitlyLocked = Equipment.NormalizeWeaponHandConflicts(build, {
			overrides = { ["Weapon 1"] = 2, ["Weapon 2"] = 1 },
			changedSlots = { "Weapon 1", "Weapon 2" },
		})
		assert.are.equal(1, explicitlyLocked.overrides["Weapon 2"], "an explicit off-hand selection must never be silently discarded")
		assert.is_false(Equipment.Validate(build, explicitlyLocked.overrides), "PoB remains authoritative when both conflicting items are explicitly selected")
	end)

	it("does not reuse one stored item identity in two equipment slots", function()
		local itemSet = { id = 1, ["Flask 1"] = { selItemId = 0 }, ["Flask 5"] = { selItemId = 0 } }
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = itemSet,
			itemSets = { [1] = itemSet },
			items = { [1] = { type = "Flask", name = "Progenesis" } },
			slots = { ["Flask 1"] = { }, ["Flask 5"] = { } },
			IsItemValidForSlot = function(_, item, slotName)
				return item.type == "Flask" and slotName:match("^Flask %d$") ~= nil
			end,
		}
		local valid, reason = Equipment.Validate({ itemsTab = itemsTab }, { ["Flask 1"] = 1, ["Flask 5"] = 1 })
		assert.is_false(valid)
		assert.is_truthy(reason:find("cannot be assigned to both", 1, true))
		assert.are.equal(0, itemSet["Flask 1"].selItemId)
		assert.are.equal(0, itemSet["Flask 5"].selItemId)
	end)

	it("lists only items accepted by PoB's native slot validator", function()
		local itemSet = { id = 1, Amulet = { selItemId = 1 }, Helmet = { selItemId = 0 } }
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = itemSet,
			itemSets = { [1] = itemSet },
			items = {
				[1] = { type = "Amulet", name = "Valid amulet" },
				[2] = { type = "Ring", name = "Invalid ring" },
			},
			slots = { Amulet = { }, Helmet = { } },
			IsItemValidForSlot = function(_, item, slotName)
				return item.type == slotName
			end,
		}
		local choices = Equipment.GetChoices({ itemsTab = itemsTab }, "Amulet")
		assert.are.equal(2, #choices, "Keep current plus exactly one native-compatible item")
		assert.are.equal(1, choices[2].itemId)
	end)

	it("samples balanced single-item and paired inventory proposals while preserving locked slots", function()
		local itemSet = {
			id = 1,
			Amulet = { selItemId = 1 },
			Helmet = { selItemId = 3 },
		}
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = itemSet,
			itemSets = { [1] = itemSet },
			items = {
				[1] = { type = "Amulet", name = "Current amulet" },
				[2] = { type = "Amulet", name = "Replacement amulet" },
				[3] = { type = "Helmet", name = "Current helmet" },
				[4] = { type = "Helmet", name = "Replacement helmet" },
			},
			slots = { Amulet = { }, Helmet = { } },
			IsItemValidForSlot = function(_, item, slotName)
				return item.type == slotName
			end,
		}
		local candidates, coverage = Equipment.BuildCandidates({ itemsTab = itemsTab }, 4, 1, { })
		assert.are.equal(3, #candidates)
		assert.are.equal(2, coverage.generatedSingleCandidates)
		assert.are.equal(1, coverage.generatedPairedCandidates)
		assert.are.equal(2, coverage.possibleSingleCandidates)
		assert.are.equal(1, coverage.possiblePairedCandidates)
		assert.is_true(candidates[3].gearVariant.inventoryPair)
		assert.are.equal(2, candidates[3].gearVariant.overrides.Amulet)
		assert.are.equal(4, candidates[3].gearVariant.overrides.Helmet)

		local locked, lockedCoverage = Equipment.BuildCandidates({ itemsTab = itemsTab }, 4, 1, { Amulet = 2 })
		assert.are.equal(1, #locked)
		assert.are.equal(1, lockedCoverage.generatedSingleCandidates)
		assert.are.equal(2, locked[1].gearVariant.overrides.Amulet)
		assert.are.equal(4, locked[1].gearVariant.overrides.Helmet)
	end)

	it("skips a mechanically equivalent swap of the two currently equipped rings", function()
		local itemSet = {
			id = 1,
			["Ring 1"] = { selItemId = 1 },
			["Ring 2"] = { selItemId = 2 },
			Amulet = { selItemId = 4 },
		}
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = itemSet,
			itemSets = { [1] = itemSet },
			items = {
				[1] = { type = "Ring", name = "Equipped ring 1", raw = "Rarity: Rare\\nEquipped ring 1\\nTwo-Stone Ring" },
				[2] = { type = "Ring", name = "Equipped ring 2", raw = "Rarity: Rare\\nEquipped ring 2\\nTwo-Stone Ring" },
				[3] = { type = "Ring", name = "Alternative ring", raw = "Rarity: Rare\\nAlternative ring\\nTwo-Stone Ring" },
				[4] = { type = "Amulet", name = "Equipped amulet" },
				[5] = { type = "Amulet", name = "Alternative amulet" },
			},
			slots = { ["Ring 1"] = { }, ["Ring 2"] = { }, Amulet = { } },
			IsItemValidForSlot = function(_, item, slotName)
				return item.type == (slotName:match("^Ring") and "Ring" or slotName)
			end,
		}
		local candidates, coverage = Equipment.BuildCandidates({ itemsTab = itemsTab }, 12, 1, { })
		assert.are.equal(1, coverage.symmetryEquivalentPairsSkipped)
		assert.is_true(coverage.generatedPairedCandidates > 0,
			"useful combinations with a genuinely different ring or amulet must remain available")
		local usefulPair = false
		for _, candidate in ipairs(candidates) do
			assert.is_false(candidate.gearVariant.overrides["Ring 1"] == 2
				and candidate.gearVariant.overrides["Ring 2"] == 1,
				"the exact pair of already equipped rings must not reappear in swapped slots")
			if candidate.gearVariant.overrides["Ring 1"] == 3
				and candidate.gearVariant.overrides.Amulet == 5 then usefulPair = true end
		end
		assert.is_true(usefulPair, "a real ring + amulet combination should still be generated")
		newBuild()
	end)

	it("keeps a ring swap for exact evaluation when an equipped ring has slot-specific mods", function()
		local itemSet = { id = 1, ["Ring 1"] = { selItemId = 1 }, ["Ring 2"] = { selItemId = 2 } }
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = itemSet,
			itemSets = { [1] = itemSet },
			items = {
				[1] = { type = "Ring", raw = "Rarity: Unique\\nSpecial Ring\\nLeft Ring Slot: +1 to Level of Socketed Gems" },
				[2] = { type = "Ring", raw = "Rarity: Rare\\nOrdinary Ring" },
			},
			slots = { ["Ring 1"] = { }, ["Ring 2"] = { } },
			IsItemValidForSlot = function(_, item) return item.type == "Ring" end,
		}
		local candidates, coverage = Equipment.BuildCandidates({ itemsTab = itemsTab }, 8, 1, { })
		assert.are.equal(0, coverage.symmetryEquivalentPairsSkipped)
		local swapped = false
		for _, candidate in ipairs(candidates) do
			local overrides = candidate.gearVariant.overrides
			if overrides["Ring 1"] == 2 and overrides["Ring 2"] == 1 then swapped = true end
		end
		assert.is_true(swapped, "slot-sensitive ring mechanics must remain eligible for exact PoB calculation")
		newBuild()
	end)

	it("keeps every flask slot out of AI Planner item and composed-route proposals", function()
		local itemSet = {
			id = 1,
			Amulet = { selItemId = 5 },
			["Flask 1"] = { selItemId = 1 },
			["Flask 5"] = { selItemId = 3 },
		}
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = itemSet,
			itemSets = { [1] = itemSet },
			items = {
				[1] = { type = "Flask", name = "Current flask 1" },
				[2] = { type = "Flask", name = "Alternate flask 1" },
				[3] = { type = "Flask", name = "Current flask 5" },
				[4] = { type = "Flask", name = "Alternate flask 5" },
				[5] = { type = "Amulet", name = "Current amulet" },
				[6] = { type = "Amulet", name = "Reworked amulet" },
			},
			slots = { Amulet = { }, ["Flask 1"] = { }, ["Flask 5"] = { } },
			IsItemValidForSlot = function(_, item, slotName)
				if slotName == "Amulet" then return item.type == "Amulet" end
				return item.type == "Flask" and slotName:match("^Flask %d$") ~= nil
			end,
		}
		local build = { itemsTab = itemsTab }
		local candidates, coverage = Equipment.BuildCandidates(build, 8, 7, { }, {
			repairReserve = true,
			excludeFlasks = true,
		})
		assert.are.equal(2, coverage.excludedFlaskSlots)
		assert.are.equal(1, #candidates, "only the non-flask amulet rework remains eligible")
		assert.are.same({ "Amulet" }, candidates[1].gearVariant.changedSlots)
		assert.is_false(Equipment.HasFlaskMutation(build, candidates[1]))

		local route = { nodeIds = { 123 }, label = "Improved passive route" }
		local flaskSwap = { gearVariant = { changedSlots = { "Flask 5" }, overrides = { ["Flask 5"] = 4 } } }
		local flaskOverrideWithoutChangedSlots = { gearVariant = { overrides = { ["Flask 1"] = 2 } } }
		local flaskItemsWithoutOverrides = { gearVariant = { items = { { slot = "Flask 5", itemId = 4 } } } }
		local unchangedFlaskReference = { gearVariant = { overrides = { ["Flask 5"] = 3 } } }
		assert.is_true(Equipment.HasFlaskMutation(build, flaskSwap))
		assert.is_true(Equipment.HasFlaskMutation(build, flaskOverrideWithoutChangedSlots),
			"a composed candidate cannot omit changedSlots to bypass the flask restriction")
		assert.is_true(Equipment.HasFlaskMutation(build, flaskItemsWithoutOverrides),
			"a candidate cannot hide a flask replacement in its item description")
		assert.is_false(Equipment.HasFlaskMutation(build, unchangedFlaskReference),
			"referencing the currently equipped flask without changing it is allowed")
		local safeCandidates, rejected = Equipment.FilterFlaskMutations(build,
			{ route, candidates[1], flaskSwap, flaskOverrideWithoutChangedSlots, flaskItemsWithoutOverrides, unchangedFlaskReference })
		assert.are.equal(3, rejected)
		assert.are.equal(3, #safeCandidates)
		assert.are.equal(route, safeCandidates[1])
		assert.are.equal(candidates[1], safeCandidates[2])
	end)

	it("filters a paired proposal that tries to equip the same stored item twice", function()
		local itemSet = { id = 1, ["Flask 1"] = { selItemId = 0 }, ["Flask 5"] = { selItemId = 0 } }
		local itemsTab = {
			activeItemSetId = 1,
			activeItemSet = itemSet,
			itemSets = { [1] = itemSet },
			items = { [1] = { type = "Flask", name = "Progenesis" } },
			slots = { ["Flask 1"] = { }, ["Flask 5"] = { } },
			IsItemValidForSlot = function(_, item, slotName)
				return item.type == "Flask" and slotName:match("^Flask %d$") ~= nil
			end,
		}
		local candidates, coverage = Equipment.BuildCandidates({ itemsTab = itemsTab }, 4, 1, { })
		assert.are.equal(2, #candidates, "each slot may select the item once, but the paired duplicate must be discarded")
		assert.are.equal(1, coverage.possiblePairedCandidates)
		assert.are.equal(0, coverage.generatedPairedCandidates)
		assert.are.equal(0, itemSet["Flask 1"].selItemId)
		assert.are.equal(0, itemSet["Flask 5"].selItemId)
	end)

	it("sends stored-item candidates through the exact PoB search budget without mutating the source", function()
		newBuild()
		local baseAmulet = new("Item"):Item("Rarity: Rare\nInventory Search Base\nAmber Amulet\n--------\n+30 to maximum Life\n+20% to Fire Resistance")
		local replacementAmulet = new("Item"):Item("Rarity: Rare\nInventory Search Candidate\nAmber Amulet\n--------\n+80 to maximum Life\n+35% to Fire Resistance")
		local baseHelmet = new("Item"):Item("Rarity: Rare\nInventory Search Helmet Base\nIron Hat\n--------\n+30 to maximum Life\n+20% to Fire Resistance")
		local replacementHelmet = new("Item"):Item("Rarity: Rare\nInventory Search Helmet Candidate\nIron Hat\n--------\n+80 to maximum Life\n+35% to Fire Resistance")
		build.itemsTab:AddItem(baseAmulet, true)
		build.itemsTab:AddItem(replacementAmulet, true)
		build.itemsTab:AddItem(baseHelmet, true)
		build.itemsTab:AddItem(replacementHelmet, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = baseAmulet.id
		build.itemsTab.slots.Amulet:SetSelItemId(baseAmulet.id)
		build.itemsTab.activeItemSet.Helmet.selItemId = baseHelmet.id
		build.itemsTab.slots.Helmet:SetSelItemId(baseHelmet.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			objectiveMetric = "TotalEHP",
			maxAddedPoints = "5",
			evaluationBudget = "40",
			searchStoredItems = true,
		}))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 3000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "bounded equipment search should finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.is_true(result.evaluations <= 40, "stored-item search must obey the exact-evaluation budget")
		assert.is_true(result.searchCoverage.equipment.generatedSingleCandidates > 0)
		assert.is_true(result.searchCoverage.equipment.exactSingleEvaluations > 0,
			"at least one existing-item proposal must reach the exact PoB calculator")
		assert.is_true(result.searchCoverage.equipment.generatedPairedCandidates > 0,
			"two-slot equipment combinations must be generated from the existing inventory")
		assert.is_true(result.searchCoverage.equipment.exactPairedEvaluations > 0,
			"at least one paired replacement must reach the exact PoB calculator")
		assert.is_true(result.searchCoverage.equipment.generatedRouteCandidates > 0,
			"an equipment replacement must be composed with a connected passive route")
		assert.is_true(result.searchCoverage.equipment.exactRouteEvaluations > 0,
			"a route-plus-item proposal must reach the exact PoB calculator")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "phantom gear exploration must preserve the active build")
		newBuild()
	end)

	it("keeps the Equipment phase tree- and gem-fixed while exact-calculating stored items", function()
		newBuild()
		local baseAmulet = new("Item"):Item("Rarity: Rare\nPhased Equipment Base\nAmber Amulet\n--------\n+30 to maximum Life\n+20% to Fire Resistance")
		local replacementAmulet = new("Item"):Item("Rarity: Rare\nPhased Equipment Candidate\nAmber Amulet\n--------\n+80 to maximum Life\n+35% to Fire Resistance")
		build.itemsTab:AddItem(baseAmulet, true)
		build.itemsTab:AddItem(replacementAmulet, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = baseAmulet.id
		build.itemsTab.slots.Amulet:SetSelItemId(baseAmulet.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			generationPhase = "equipment",
			objectiveMetric = "TotalEHP",
			evaluationBudget = "16",
			maxAddedPoints = "0",
			searchStoredItems = true,
		}))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 3000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "equipment-only search should finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.are.equal("equipment", result.generationPhase)
		assert.is_true(result.searchCoverage.phase.generatedEquipmentCandidates > 0)
		assert.is_true(result.searchCoverage.equipment.exactEvaluations > 0, "an existing item must reach exact PoB calculation")
		assert.are.equal(0, result.searchCoverage.phase.generatedTreeCandidates)
		assert.are.equal(0, result.searchCoverage.phase.generatedSkillCandidates)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "equipment search must preserve the source build")
		newBuild()
	end)

	it("uses the first exact baseline to activate a bounded local attribute-repair reserve", function()
		newBuild()
		build.characterLevel = 100
		build.characterLevelAutoMode = false
		local deficient = new("Item"):Item("Rarity: Rare\nRequirement Repair Source\nAstral Plate\n--------\nItem Level: 86\n+100 to maximum Life")
		local replacement = new("Item"):Item("Rarity: Rare\nRequirement Repair Candidate\nAstral Plate\n--------\nItem Level: 86\n+200 to Strength")
		build.itemsTab:AddItem(deficient, true)
		build.itemsTab:AddItem(replacement, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = deficient.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(deficient.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		assert.is_true(build.calcsTab.mainOutput.ReqStr > build.calcsTab.mainOutput.Str,
			"the fixture must expose a native PoB Strength requirement deficit")
		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({ objectiveMetric = "TotalEHP", evaluationBudget = "40", searchStoredItems = true }))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 3000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "single-pass requirement repair should finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		local repair = result.searchCoverage.requirementRepair
		assert.is_true(repair.active, "the exact baseline should activate attribute repair")
		assert.is_true(repair.generatedCandidates > 0)
		assert.is_true(repair.exactCandidateEvaluations > 0, "stored equipment proposals must be exact-calculated")
		assert.is_true(repair.improvedExactEvaluations > 0, "the native exact result should record the better attribute candidate")
		assert.is_true(repair.fullyRepairedExactEvaluations > 0, "the replacement should clear the exact attribute requirement")
		assert.is_true(result.evaluations <= 40, "repair reserve must remain inside the user evaluation budget")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "local repair exploration must preserve the active build")
		newBuild()
	end)

	it("generates legal four-affix native rares, exact-calculates them in isolation, and applies a reversible item-set variation", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local sourceAmulet = new("Item"):Item("Rarity: Rare\nSynthetic Gear Source\nAmber Amulet\n--------\nItem Level: 86\n+30 to maximum Life\n+20% to Fire Resistance")
		build.itemsTab:AddItem(sourceAmulet, true)
		build.itemsTab.activeItemSet.Amulet.selItemId = sourceAmulet.id
		build.itemsTab.slots.Amulet:SetSelItemId(sourceAmulet.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		-- Fixture setup is the user's pre-search state; establish it as the
		-- undo baseline so the final assertion exercises only optimizer apply.
		build.itemsTab:ResetUndo()
		local sourceSetId = build.itemsTab.activeItemSetId
		local sourceSignature = Candidate.BuildSignature(build)
		local parsed = assert(Inputs.Parse({
			objectiveMetric = "TotalEHP",
			searchSyntheticGear = true,
			syntheticItemLevel = "86",
			syntheticItemCostChaos = "12.5",
			evaluationBudget = "40",
		}))
		assert.is_true(parsed.search.searchSyntheticGear)
		assert.are.equal(86, parsed.search.syntheticItemLevel)
		assert.are.equal(12.5, parsed.search.syntheticItemCostChaos)
		assert.is_nil(Inputs.Parse({ searchSyntheticGear = "sometimes" }))
		assert.is_nil(Inputs.Parse({ syntheticItemLevel = "101" }))
		assert.is_nil(Inputs.Parse({ syntheticItemCostChaos = "-1" }))

		local excludedSlots = { }
		for _, slotName in ipairs(Equipment.GetSlots(build)) do
			if slotName ~= "Amulet" then excludedSlots[slotName] = true end
		end
		local generated, coverage = SyntheticGear.BuildCandidates(build, 24, 1, excludedSlots, parsed, 86)
		assert.is_true(coverage.possibleSlots > 0)
		assert.is_true(#generated > 0, "native item data should produce at least one legal rare proposal")
		assert.are.equal(8, coverage.maxBasesPerSlot)
		assert.are.equal(3, coverage.tierBandsPerGroup)
		assert.are.equal(16, coverage.affixCombinationsPerBase)
		local seenRollProfiles = { }
		for _, candidate in ipairs(generated) do
			for _, generatedEntry in ipairs(candidate.gearVariant.generatedItems or { }) do
				local generatedItem = generatedEntry.item
				assert.is_truthy(generatedEntry.rollProfileId)
				assert.is_true(generatedEntry.rollFraction == 0.5 or generatedEntry.rollFraction == 1,
					"a synthetic rare must use an explicit native median or maximum affix roll")
				seenRollProfiles[generatedEntry.rollProfileId] = true
				assert.is_truthy(generatedItem.base)
				assert.are.equal(generatedEntry.baseName, generatedItem.baseName,
					"the selected base name must survive PoB's native rare-item parser")
				assert.is_true(build.itemsTab:IsItemValidForSlot(generatedItem, generatedEntry.slotName,
					build.itemsTab.activeItemSet), "each generated base must be equipable in its recorded native slot")
				local groups = { }
				for _, side in ipairs({ { generatedItem.prefixes, "Prefix" }, { generatedItem.suffixes, "Suffix" } }) do
					for _, affix in ipairs(side[1] or { }) do
						if affix.modId and affix.modId ~= "None" then
							local nativeMod = assert(generatedItem.affixes[affix.modId], "every affix must resolve in PoB's native mod table")
							assert.are.equal(side[2], nativeMod.type, "prefix and suffix placements must match the native mod type")
							assert.is_true(nativeMod.level <= generatedEntry.itemLevel, "an affix cannot exceed the selected item level")
							assert.is_true(generatedItem:GetModSpawnWeight(nativeMod) > 0,
								"every affix must be spawnable on this exact native item base")
							assert.is_nil(groups[nativeMod.group], "a rare item cannot use two affixes from the same native mod group")
							groups[nativeMod.group] = true
						end
					end
				end
			end
		end
		assert.is_true(seenRollProfiles.maximum, "the expanded pool must include maximum native affix rolls")
		assert.is_true(seenRollProfiles.median, "the expanded pool must retain median native affix rolls for comparison")
		local proposal = generated[1]
		local entry = proposal.gearVariant.generatedItems[1]
		assert.is_truthy(entry.item.raw)
		assert.are.equal("RARE", entry.item.rarity)
		assert.is_true(entry.affixCount <= 4)
		assert.is_nil(build.itemsTab.items[entry.tempId], "phantom generation must not add the proposed item to the active Items tab")
		local rebuilt = new("Item"):Item(entry.item.raw)
		assert.is_truthy(rebuilt.base, "generated raw must reconstruct its native base")
		assert.are.equal("RARE", rebuilt.rarity)
		local function countRealAffixes(affixes)
			local count = 0
			for _, affix in ipairs(affixes or { }) do
				if affix.modId and affix.modId ~= "None" then count = count + 1 end
			end
			return count
		end
		local prefixCount = countRealAffixes(rebuilt.prefixes)
		local suffixCount = countRealAffixes(rebuilt.suffixes)
		assert.is_true(prefixCount <= 2 and suffixCount <= 2 and prefixCount + suffixCount == entry.affixCount,
			"generated raw must preserve its legal affix count")

		local projected, projectionError, projectedItems = Candidate.BuildPassiveSpec(build, { }, { }, {
			gearVariant = proposal.gearVariant,
		})
		assert.is_truthy(projected, projectionError)
		assert.is_true(projectedItems.items[entry.tempId].optimizerSynthetic)
		assert.are.equal(sourceAmulet.id, build.itemsTab.activeItemSet.Amulet.selItemId)
		local isolatedBuild = { spec = projected, itemsTab = projectedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local output = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_truthy(output and output.Life, "generated item must reach the exact PoB calculation")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))

		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { },
			removeNodeIds = { },
			gearVariant = proposal.gearVariant,
		})
		assert.is_true(applied, applyError)
		assert.are_not.equal(sourceSetId, build.itemsTab.activeItemSetId)
		local generatedId = build.itemsTab.activeItemSet.Amulet.selItemId
		assert.are_not.equal(sourceAmulet.id, generatedId)
		assert.is_true(build.itemsTab.items[generatedId].optimizerSynthetic)
		build.calcsTab:BuildOutput()
		assert.is_truthy(build.calcsTab.mainOutput.Life)
		build.itemsTab:Undo()
		assert.are.equal(sourceSetId, build.itemsTab.activeItemSetId)
		assert.are.equal(sourceAmulet.id, build.itemsTab.activeItemSet.Amulet.selItemId)
		assert.are.equal(sourceAmulet.id, build.itemsTab.itemSets[sourceSetId].Amulet.selItemId)
		newBuild()
	end)

	it("remaps colliding temporary synthetic item IDs throughout an isolated gear variant", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local parsed = assert(Inputs.Parse({ searchSyntheticGear = true, syntheticItemLevel = "86", evaluationBudget = "8" }))
		local generated = SyntheticGear.BuildCandidates(build, 2, 1, { }, parsed, 86)
		assert.is_true(#generated > 0, "native item data should create a remappable synthetic gear proposal")
		local proposal = generated[1]
		local gearVariant = proposal.gearVariant
		local entry = gearVariant.generatedItems[1]
		local collidingItem = build.itemsTab.items[entry.tempId]
		if not collidingItem then
			collidingItem = new("Item"):Item("Rarity: Rare\nReserved Temporary ID\nAmber Amulet\n--------\n+10 to maximum Life")
			collidingItem.id = entry.tempId
			build.itemsTab.items[entry.tempId] = collidingItem
		end
		local validationTab, validationError, remap = SyntheticGear.CreateValidationTab(build.itemsTab, gearVariant.generatedItems)
		assert.is_truthy(validationTab, validationError)
		assert.is_truthy(remap and remap[entry.tempId], "a generated item that collides with an existing native ID must receive a free validation ID")
		local remappedId = remap[entry.tempId]
		assert.are_not.equal(entry.tempId, remappedId)
		assert.are.equal(collidingItem, build.itemsTab.items[entry.tempId], "ID repair must not replace the source item")
		assert.is_true(validationTab.items[remappedId].optimizerSynthetic)
		local variant = SyntheticGear.RemapVariantIds({
			overrides = { Amulet = entry.tempId },
			socketBinding = { itemId = entry.tempId },
			items = { { itemId = entry.tempId } },
			generatedItems = { { tempId = entry.tempId, item = entry.item } },
		}, remap)
		assert.are.equal(remappedId, variant.overrides.Amulet)
		assert.are.equal(remappedId, variant.socketBinding.itemId)
		assert.are.equal(remappedId, variant.items[1].itemId)
		assert.are.equal(remappedId, variant.generatedItems[1].tempId)
		assert.are.equal(entry.tempId, gearVariant.overrides[entry.slotName], "ID repair must leave the original proposal reusable")
		local sourceSignature = Candidate.BuildSignature(build)
		local applied, applyError = Candidate.Apply(build, {
			feasible = true, sourceSignature = sourceSignature, nodeIds = { }, removeNodeIds = { }, gearVariant = gearVariant,
		})
		assert.is_true(applied, applyError)
		local equippedId = build.itemsTab.activeItemSet[entry.slotName].selItemId
		assert.are_not.equal(entry.tempId, equippedId, "Apply must install the generated item under a free native PoB ID")
		assert.is_true(build.itemsTab.items[equippedId].optimizerSynthetic)
		assert.are.equal(collidingItem, build.itemsTab.items[entry.tempId], "Apply must retain the item that owned the colliding ID")
		build.itemsTab:Undo()
		newBuild()
	end)

	it("generates and applies a bounded pair of legal synthetic rares across separate slots", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.calcsTab:BuildOutput()
		build.itemsTab:ResetUndo()
		local sourceSignature = Candidate.BuildSignature(build)
		local sourceSetId = build.itemsTab.activeItemSetId
		local parsed = assert(Inputs.Parse({
			generationPhase = "equipment",
			objectiveMetric = "TotalEHP",
			searchStoredItems = false,
			searchSyntheticGear = true,
			syntheticItemLevel = "86",
			syntheticItemCostChaos = "5",
			currencyBudgetAmount = "10",
			currencyBudgetUnit = "Chaos",
			currencyBudgetMode = "Trade",
			marketQuotesJson = assert(json.encode({ source = "manual", quotes = { } })),
			maxAddedPoints = "0",
			evaluationBudget = "40",
		}))
		local generated, coverage = SyntheticGear.BuildCandidates(build, 4, 19, { }, parsed, 86)
		assert.is_true((coverage.generatedPairedCandidates or 0) > 0,
			"bounded synthetic generation must combine distinct item slots when the quota permits")
		local pair
		for _, proposal in ipairs(generated) do
			if proposal.gearVariant and proposal.gearVariant.syntheticPair then pair = proposal; break end
		end
		assert.is_truthy(pair, "the candidate list must contain a paired synthetic rare proposal")
		assert.are.equal(2, #pair.gearVariant.generatedItems)
		assert.are.equal(1, coverage.pairCandidateLimit)
		assert.is_true(coverage.pairCombinationInspections <= coverage.pairInspectionLimit,
			"pair enumeration must respect its independent inspection bound")
		local first, second = pair.gearVariant.generatedItems[1], pair.gearVariant.generatedItems[2]
		assert.are_not.equal(first.slotName, second.slotName, "a pair must cover two distinct native equipment slots")
		assert.are.equal(2, #pair.gearVariant.items)
		for _, entry in ipairs(pair.gearVariant.generatedItems) do
			assert.is_truthy(entry.item and entry.item.raw)
			assert.is_nil(build.itemsTab.items[entry.tempId], "paired phantom generation must not mutate the active Items tab")
		end
		local projected, projectionError, projectedItems = Candidate.BuildPassiveSpec(build, { }, { }, {
			gearVariant = pair.gearVariant,
		})
		assert.is_truthy(projected, projectionError)
		for _, entry in ipairs(pair.gearVariant.generatedItems) do
			assert.are.equal(entry.tempId, projectedItems.activeItemSet[entry.slotName].selItemId)
			assert.is_true(projectedItems.items[entry.tempId].optimizerSynthetic)
		end
		local isolatedBuild = { spec = projected, itemsTab = projectedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local output = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_truthy(output and output.Life, "both generated items must reach the exact PoB calculator")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 3000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "bounded synthetic-pair search should finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		assert.is_true(result.searchCoverage.syntheticGear.generatedPairedCandidates > 0)
		assert.is_true(result.searchCoverage.syntheticGear.exactPairedEvaluations > 0,
			"a synthetic rare pair must reach the exact evaluation and report its coverage")
		assert.is_true(result.searchCoverage.syntheticGear.exactPairBudgetPasses > 0,
			"a 5-Chaos manual price per rare must pass a 10-Chaos cap when the pair total is exactly 10")
		assert.are.equal(10, result.searchCoverage.syntheticGear.lastExactPairBudgetTotal,
			"the strict market gate must charge each generated item in the pair")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "full pair search must preserve the source build")

		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { },
			removeNodeIds = { },
			gearVariant = pair.gearVariant,
		})
		assert.is_true(applied, applyError)
		assert.are_not.equal(sourceSetId, build.itemsTab.activeItemSetId)
		for _, entry in ipairs(pair.gearVariant.generatedItems) do
			local itemId = build.itemsTab.activeItemSet[entry.slotName].selItemId
			assert.is_true(build.itemsTab.items[itemId].optimizerSynthetic)
		end
		build.calcsTab:BuildOutput()
		assert.is_truthy(build.calcsTab.mainOutput.Life)
		build.itemsTab:Undo()
		assert.are.equal(sourceSetId, build.itemsTab.activeItemSetId)
		newBuild()
	end)

	it("generates, exact-calculates, budgets, and applies a bounded three-item rare portfolio", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		build.calcsTab:BuildOutput()
		build.itemsTab:ResetUndo()
		local sourceSignature = Candidate.BuildSignature(build)
		local sourceSetId = build.itemsTab.activeItemSetId
		local parsed = assert(Inputs.Parse({
			generationPhase = "equipment",
			objectiveMetric = "TotalEHP",
			searchStoredItems = false,
			searchSyntheticGear = true,
			syntheticItemLevel = "86",
			syntheticItemCostChaos = "5",
			currencyBudgetAmount = "15",
			currencyBudgetUnit = "Chaos",
			currencyBudgetMode = "Trade",
			marketQuotesJson = assert(json.encode({ source = "manual", quotes = { } })),
			maxAddedPoints = "0",
			evaluationBudget = "48",
		}))
		local proposals, coverage = SyntheticGear.BuildCandidates(build, 6, 23, { }, parsed, 86)
		assert.are.equal(1, coverage.tripleCandidateLimit)
		assert.is_true((coverage.generatedTripleCandidates or 0) > 0,
			"the bounded quota should retain at least one three-slot portfolio when native slots permit it")
		local triple
		for _, proposal in ipairs(proposals) do
			if proposal.gearVariant and proposal.gearVariant.syntheticTriple then triple = proposal break end
		end
		assert.is_truthy(triple)
		assert.are.equal(3, #triple.gearVariant.generatedItems)
		assert.are.equal(3, #triple.gearVariant.items)
		local seenSlots = { }
		for _, entry in ipairs(triple.gearVariant.generatedItems) do
			assert.is_false(seenSlots[entry.slotName] == true, "a portfolio must use three distinct native slots")
			seenSlots[entry.slotName] = true
			assert.is_truthy(entry.item and entry.item.raw)
			assert.is_nil(build.itemsTab.items[entry.tempId], "phantom triple generation must preserve the source item table")
		end
		local projected, projectionError, projectedItems = Candidate.BuildPassiveSpec(build, { }, { }, {
			gearVariant = triple.gearVariant,
		})
		assert.is_truthy(projected, projectionError)
		for _, entry in ipairs(triple.gearVariant.generatedItems) do
			assert.are.equal(entry.tempId, projectedItems.activeItemSet[entry.slotName].selItemId)
			assert.is_true(projectedItems.items[entry.tempId].optimizerSynthetic)
		end
		local isolatedBuild = { spec = projected, itemsTab = projectedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local exactOutput = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_truthy(exactOutput and exactOutput.Life, "the full three-item loadout must reach PoB's exact calculator")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))

		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 3000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "bounded three-item search should finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		local searchCoverage = assert(result.searchCoverage.syntheticGear)
		assert.is_true(searchCoverage.generatedTripleCandidates > 0)
		assert.is_true(searchCoverage.exactTripleEvaluations > 0,
			"a generated triple must reach the exact PoB evaluator")
		assert.is_true(searchCoverage.exactTripleBudgetPasses > 0,
			"three user-priced rares at 5 Chaos each must pass a strict 15-Chaos budget")
		assert.are.equal(15, searchCoverage.lastExactTripleBudgetTotal,
			"the strict market gate must charge all three generated items")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build), "the exact triple search must preserve the source build")

		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = sourceSignature,
			nodeIds = { },
			removeNodeIds = { },
			gearVariant = triple.gearVariant,
		})
		assert.is_true(applied, applyError)
		assert.are_not.equal(sourceSetId, build.itemsTab.activeItemSetId)
		for _, entry in ipairs(triple.gearVariant.generatedItems) do
			local itemId = build.itemsTab.activeItemSet[entry.slotName].selItemId
			assert.is_true(build.itemsTab.items[itemId].optimizerSynthetic)
		end
		build.calcsTab:BuildOutput()
		assert.is_truthy(build.calcsTab.mainOutput.Life)
		build.itemsTab:Undo()
		assert.are.equal(sourceSetId, build.itemsTab.activeItemSetId)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build))
		newBuild()
	end)

	it("ranks synthetic rares toward strict Matrix deficits and exact PoB gem attributes", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local seed, seedError = SkillSeed.Create(build, "Metadata/Items/Gems/SkillGemFireball")
		assert.is_truthy(seed, seedError)
		local group = assert(build.skillsTab.socketGroupList[seed.groupIndex])
		group.gemList[1].level = 20
		build.skillsTab:ProcessSocketGroup(group)
		build.skillsTab:UpdateSocketGroups()
		build.calcsTab:BuildOutput()
		local exactOutput = assert(build.calcsTab.mainOutput)
		assert.is_true(exactOutput.ReqInt > exactOutput.Int,
			"fixture must contain a real PoB-calculated Intelligence requirement deficit")

		local parsed, parseError = Inputs.Parse({
			generationPhase = "equipment", objectiveMetric = "CombinedDPS",
			Life = "3000", EnergyShield = "1000", FireResist = "75", ColdResist = "75",
			LightningResist = "75", ChaosResist = "0", CombinedDPS = "10000",
			searchStoredItems = false, searchSyntheticGear = true, maxAddedPoints = "0",
			maxTotalPoints = "120", evaluationBudget = "100", syntheticItemLevel = "86",
		})
		assert.is_truthy(parsed, parseError)
		local proposals, coverage = SyntheticGear.BuildCandidates(build, 20, 21102026, { }, parsed, 86)
		assert.is_true(#proposals > 0)
		local profile = assert(coverage.priorityProfile,
			"synthetic proposals must expose their bounded priority evidence")
		assert.is_true(profile.exactBaselineAvailable)
		assert.are.equal("exact_baseline_requirement_deficit", profile.attributeRequirements.Int.status)
		assert.are.equal(exactOutput.Int, profile.attributeRequirements.Int.actual)
		assert.are.equal(exactOutput.ReqInt, profile.attributeRequirements.Int.required)
		local hardByKey = { }
		for _, gate in ipairs(profile.hardGates) do hardByKey[gate.key] = gate end
		assert.are.equal("exact_baseline_violation", hardByKey.Life.status)
		assert.are.equal("exact_baseline_violation", hardByKey.FireResist.status)
		assert.are.equal("exact_baseline_violation", hardByKey.EnergyShield.status)
		assert.is_true(hardByKey.Life.weight > 4,
			"a hard floor already missed by the exact PoB baseline must outrank a generic damage tag")
		local esProbe = new("Item"):Item(table.concat({ "Rarity: Rare", "Priority Coverage Probe", "Heavy Belt", "--------", "Item Level: 86" }, "\n"))
		local esAffix = esProbe.affixes and esProbe.affixes.IncreasedEnergyShield12
		assert.is_truthy(esAffix, "the native belt mod registry must expose its tier-12 Energy Shield affix")
		assert.is_true(esProbe:GetModSpawnWeight(esAffix) > 0,
			"the native Heavy Belt base must permit the Energy Shield affix at this item level")

		local sawIntelligence, sawLife, sawEnergyShield, sawResistance = false, false, false, false
		for _, proposal in ipairs(proposals) do
			for _, entry in ipairs(proposal.gearVariant and proposal.gearVariant.generatedItems or { }) do
				local raw = tostring(entry.item and entry.item.raw or "")
				if raw:find("Intelligence", 1, true) or raw:find("all Attributes", 1, true) then sawIntelligence = true end
				if raw:find("maximum Life", 1, true) then sawLife = true end
				if raw:find("maximum Energy Shield", 1, true) then sawEnergyShield = true end
				if raw:find("Resistance", 1, true) then sawResistance = true end
			end
		end
		assert.is_true(sawIntelligence, "the candidate pool must retain a native affix that repairs the exact gem attribute deficit")
		assert.is_true(sawLife, "the candidate pool must retain a native affix for a missed hard Life floor")
		assert.is_true(sawEnergyShield, "the candidate pool must normalize PoB's energy_shield tag and retain a native affix for a missed Energy Shield floor")
		assert.is_true(sawResistance, "the candidate pool must retain native resistance affixes for missed resistance floors")
		newBuild()
	end)

	it("samples native item bases toward the selected defense while retaining only base-legal affixes", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local armour, itemError = new("Item"):Item(table.concat({
			"Rarity: Rare", "Base Preference Seed", "Astral Plate", "--------", "Item Level: 86",
			"+200 to Strength", "+200 to Intelligence",
		}, "\n"))
		assert.is_truthy(armour and armour.base, itemError)
		build.itemsTab:AddItem(armour, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = armour.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(armour.id)
		build.itemsTab:PopulateSlots()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local parsed, parseError = Inputs.Parse({
			objectiveMetric = "TotalEHP", defenseProfile = "EnergyShield",
			searchSyntheticGear = true, syntheticItemLevel = "86", evaluationBudget = "40",
		})
		assert.is_truthy(parsed, parseError)
		local excludedSlots = { }
		for _, slotName in ipairs(Equipment.GetSlots(build)) do
			if slotName ~= "Body Armour" then excludedSlots[slotName] = true end
		end
		local proposals, coverage = SyntheticGear.BuildCandidates(build, 32, 2077, excludedSlots, parsed, 86)
		assert.is_true(coverage.possibleBases > 1,
			"a selected defensive profile should search native alternatives to the equipped base")
		local sawEnergyShieldBase = false
		for _, proposal in ipairs(proposals) do
			for _, entry in ipairs(proposal.gearVariant and proposal.gearVariant.generatedItems or { }) do
				if entry.slotName == "Body Armour" then
					local base = assert(entry.item and entry.item.base)
					assert.are.equal("Body Armour", base.type,
						"the native base family must match the equipment slot")
					local baseArmour = base.armour or { }
					if (tonumber(baseArmour.EnergyShieldBaseMin) or 0) > 0 then sawEnergyShieldBase = true end
					for _, side in ipairs({ entry.item.prefixes or { }, entry.item.suffixes or { } }) do
						for _, affix in ipairs(side) do
							if affix.modId and affix.modId ~= "None" then
								local mod = assert(entry.item.affixes[affix.modId])
								assert.is_true(entry.item:GetModSpawnWeight(mod) > 0,
									"each attribute must exist and be spawnable on the exact selected native base")
							end
						end
					end
				end
			end
		end
		assert.is_true(sawEnergyShieldBase,
			"Energy Shield focus should include a native ES base even when the equipped base is Armour-focused")
		newBuild()
	end)

	it("turns an unlinked selected Main Skill into a native linked synthetic-equipment result", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local seed, seedError = SkillSeed.Create(build, gemId)
		assert.is_truthy(seed, seedError)
		assert.is_false(seed.linked, "an empty equipment set must not fabricate a socket assignment")
		local groupIndex = seed.groupIndex
		local linkedBefore, unlinkedReason = SkillCatalog.ValidateSocketGroup(build, groupIndex)
		assert.is_false(linkedBefore)
		assert.is_truthy(unlinkedReason:find("no equipment socket", 1, true))
		local targetGemId = "Metadata/Items/Gems/SkillGemArc"
		local alternateColorGemId = "Metadata/Items/Gems/SkillGemCleave"
		local alternateColorVariant, _, alternateColorDetails = SkillCatalog.ResolveTarget(
			build, groupIndex, seed.skillIndex, alternateColorGemId, { allowUnlinkedPlanning = true })
		assert.is_truthy(alternateColorVariant, "Tree/Skills must resolve loaded active gems for an unlinked planning seed")
		assert.is_true(alternateColorDetails.unlinkedPlanning)
		local colorProposals = SyntheticGear.BuildCandidates(build, 2, 1, { }, nil, 86, {
			groupIndex = groupIndex,
			gemVariant = alternateColorVariant,
		})
		assert.is_true(#colorProposals > 0, "the requested skill color must produce a native socketed item proposal")
		assert.are.equal("R", colorProposals[1].gearVariant.generatedItems[1].item.sockets[1].color,
			"socket generation must follow the selected replacement gem's loaded PoB color, not the old seed gem")

		local tab = build.optimizerTab
		local customMods = build.configTab.configSets[build.configTab.activeConfigSetId].customModsList
		customMods[1].text = "Regenerate 100 Mana per second"
		customMods[#customMods + 1] = { text = "+200 to all Attributes" }
		build.configTab:BuildModList()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		local uninstalledEquipment = assert(Inputs.Parse({
			generationPhase = "equipment",
			objectiveMetric = "CombinedDPS",
			targetSkillGroupIndex = tostring(groupIndex),
			targetSkillIndex = tostring(seed.skillIndex),
			targetSkillGemId = targetGemId,
			searchSyntheticGear = true,
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			evaluationBudget = "16",
		}))
		local prematureValid, prematureError = Inputs.ValidateBuild(build, uninstalledEquipment)
		assert.is_false(prematureValid, "an equipment result cannot score a replacement skill it would not apply")
		assert.is_truthy(prematureError:find("Apply the selected Main Skill in the Skills phase first", 1, true))

		local skillStarted, skillStartError = tab:StartOptimizer({
			generationPhase = "skills",
			objectiveMetric = "CombinedDPS",
			targetSkillGroupIndex = tostring(groupIndex),
			targetSkillIndex = tostring(seed.skillIndex),
			targetSkillGemId = targetGemId,
			searchSyntheticGear = false,
			searchStoredItems = false,
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			evaluationBudget = "8",
			seed = "1",
		})
		assert.is_true(skillStarted, skillStartError)
		for _ = 1, 10000 do
			if not tab.job or tab.job.status ~= "running" then break end
			tab:Tick()
		end
		assert.is_nil(tab.job, "the Skills checkpoint must finish within its bounded exact-calculation budget")
		assert.are.equal("feasible", tab.result and tab.result.status, tostring(tab.statusMessage))
		assert.is_true(tab.result.candidate.unlinkedMainSkillPlan,
			"an exact unlinked Skills result must disclose that it is a planning checkpoint")
		local sourceItemSetId = build.itemsTab.activeItemSetId
		local sourceBodyArmourId = build.itemsTab.activeItemSet["Body Armour"]
			and build.itemsTab.activeItemSet["Body Armour"].selItemId
		local skillsApplied, skillsApplyError = tab:ApplyCandidate(tab.result.candidate)
		assert.is_true(skillsApplied, skillsApplyError)
		assert.are.equal(sourceItemSetId, build.itemsTab.activeItemSetId,
			"a gem-only planning candidate must not create or change the active item set")
		assert.are.equal(sourceBodyArmourId, build.itemsTab.activeItemSet["Body Armour"]
			and build.itemsTab.activeItemSet["Body Armour"].selItemId,
			"a gem-only planning candidate must not fabricate or change equipment")
		assert.is_truthy(tab.statusMessage:find("remains an unlinked planner group", 1, true))
		assert.is_nil(build.skillsTab.socketGroupList[groupIndex].slot,
			"the applied Skills checkpoint remains explicitly unlinked until Equipment succeeds")
		assert.are.equal(targetGemId, build.skillsTab.socketGroupList[groupIndex].gemList[1].gemId)
		assert.are.equal(targetGemId, build.skillsTab.socketGroupList[groupIndex].gemList[1].gemData.id,
			"the active gem instance must match the reversible skill-set variation")
		main.popups[1].controls.yes:Click()
		assert.are.equal("equipment", tab.textValues.generationPhase)
		-- Headless fresh builds have no loaded targetVersion, so their outer
		-- Build:OnFrame exits before the native rebuild block. Exercise the exact
		-- cache invalidation and PoB recalculation performed by that block.
		wipeGlobalCache()
		build.skillsTab:UpdateSocketGroups()
		build.calcsTab:BuildOutput()
		local activeGemId = SkillCatalog.CurrentMainGemId(build, groupIndex, seed.skillIndex)
		local activeGroup = build.skillsTab.socketGroupList[groupIndex]
		local displayDetails = { "main=" .. tostring(activeGroup.mainActiveSkill), "requestedIndex=" .. tostring(seed.skillIndex) }
		for index, skill in ipairs(activeGroup.displaySkillList or { }) do
			local source = skill.activeEffect and skill.activeEffect.srcInstance
			displayDetails[#displayDetails + 1] = tostring(index) .. ":" .. tostring(source and source.gemData and source.gemData.id)
		end
		local nativeMainSkill = build.calcsTab.mainEnv and build.calcsTab.mainEnv.player
			and build.calcsTab.mainEnv.player.mainSkill
		local nativeMainGemId = nativeMainSkill and nativeMainSkill.activeEffect
			and nativeMainSkill.activeEffect.srcInstance and nativeMainSkill.activeEffect.srcInstance.gemData
			and nativeMainSkill.activeEffect.srcInstance.gemData.id
		assert.are.equal(targetGemId, activeGemId,
			"PoB's selected active effect must resolve to the gem installed by the Skills checkpoint ("
				.. "skillSet=" .. tostring(build.skillsTab.activeSkillSetId)
				.. ",group=" .. tostring(groupIndex)
				.. ",gemData=" .. tostring(activeGroup.gemList[1].gemData.id)
				.. ",mainOutputGem=" .. tostring(nativeMainGemId)
				.. "," .. table.concat(displayDetails, ",") .. "; current=" .. tostring(activeGemId) .. ")")

		local parsed = assert(Inputs.Parse({
			generationPhase = "equipment",
			objectiveMetric = "CombinedDPS",
			targetSkillGroupIndex = tostring(groupIndex),
			targetSkillIndex = tostring(seed.skillIndex),
			targetSkillGemId = targetGemId,
			searchStoredItems = false,
			searchSyntheticGear = true,
			syntheticItemLevel = "86",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			evaluationBudget = "48",
			seed = "1",
		}))
		local valid, validationError = Inputs.ValidateBuild(build, parsed)
		assert.is_true(valid, validationError)
		local resolvedTargetGem = assert(SkillCatalog.ResolveTarget(build, groupIndex, seed.skillIndex, targetGemId))
		local targetSkill = { groupIndex = groupIndex, gemVariant = resolvedTargetGem }
		local generated, coverage = SyntheticGear.BuildCandidates(build, 4, 1, { }, parsed, 86, targetSkill)
		assert.is_true(coverage.generatedCandidates > 0,
			"PoB's native item bases should provide a socketable rare candidate (slots="
				.. tostring(coverage.possibleSlots) .. ", bases=" .. tostring(coverage.possibleBases)
				.. ", rejection=" .. tostring(coverage.lastCraftRejection or "none") .. ")")
		local function assertGeneratedSlotsAreMarked(candidates)
			for _, candidate in ipairs(candidates or { }) do
				local gear = candidate.gearVariant or { }
				local changed = { }
				for _, slotName in ipairs(gear.changedSlots or { }) do changed[slotName] = true end
				for _, entry in ipairs(gear.generatedItems or { }) do
					assert.is_true(changed[entry.slotName] == true,
						"every generated item slot must be listed as changed for accurate composed-route details: "
							.. tostring(entry.slotName))
				end
			end
		end
		assertGeneratedSlotsAreMarked(generated)
		local portfolioProposals, portfolioCoverage = SyntheticGear.BuildCandidates(build, 6, 23, { }, parsed, 86, targetSkill)
		assert.is_true((portfolioCoverage.generatedTripleCandidates or 0) > 0,
			"a selected unlinked Main Skill must be retained when generating a three-item portfolio (singles="
				.. tostring(portfolioCoverage.generatedSingleCandidates) .. ", slots=" .. tostring(portfolioCoverage.possibleSlots)
				.. ", bases=" .. tostring(portfolioCoverage.possibleBases) .. ", triples="
				.. tostring(portfolioCoverage.generatedTripleCandidates) .. ", triple inspections="
				.. tostring(portfolioCoverage.tripleCombinationInspections) .. ", rejection="
				.. tostring(portfolioCoverage.lastCraftRejection or "none") .. ")")
		assertGeneratedSlotsAreMarked(portfolioProposals)
		local socketedTriple
		for _, candidate in ipairs(portfolioProposals) do
			if candidate.gearVariant and candidate.gearVariant.syntheticTriple then socketedTriple = candidate break end
		end
		assert.is_truthy(socketedTriple and socketedTriple.gearVariant.socketBinding,
			"a triple for an unlinked Main Skill must include one native socket binding")
		assert.are.equal(groupIndex, socketedTriple.gearVariant.socketBinding.groupIndex)
		local socketBoundItems = 0
		local tripleSlots = { }
		for _, entry in ipairs(socketedTriple.gearVariant.generatedItems) do
			assert.is_false(tripleSlots[entry.slotName] == true, "a triple must not repeat an equipment slot")
			tripleSlots[entry.slotName] = true
			if entry.socketPlan then socketBoundItems = socketBoundItems + 1 end
		end
		assert.are.equal(1, socketBoundItems, "exactly one item in the triple may bind the selected skill")
		local proposal = generated[1]
		local binding = proposal.gearVariant.socketBinding
		assert.is_truthy(binding, "a selected unlinked Main Skill requires an explicit item binding")
		assert.are.equal(groupIndex, binding.groupIndex)
		local generatedItem
		for _, entry in ipairs(proposal.gearVariant.generatedItems) do
			if entry.slotName == binding.slotName then generatedItem = entry break end
		end
		assert.is_truthy(generatedItem, "the socket binding must name one generated item in the complete set")
		assert.are.equal(1, #generatedItem.item.sockets)
		assert.are.equal("B", generatedItem.item.sockets[1].color)
		assert.are.equal(0, generatedItem.item.sockets[1].group)
		local normalized = new("Item"):Item(generatedItem.item.raw)
		assert.are.equal(1, #normalized.sockets, "the native raw item must preserve its generated socket")
		assert.are.equal(0, normalized.sockets[1].group)
		local projected, projectionError, projectedItems = Candidate.BuildPassiveSpec(build, { }, { }, {
			gearVariant = proposal.gearVariant,
		})
		assert.is_truthy(projected, projectionError)
		assert.are.equal(generatedItem.tempId, projectedItems.activeItemSet[binding.slotName].selItemId)

		tab:OpenEquipmentChoices()
		local equipmentPopup = main.popups[1]
		equipmentPopup.controls.prepareGear:Click()
		assert.are.equal("equipment", tab.textValues.generationPhase)
		assert.is_true(tab.textValues.searchSyntheticGear)
		main:ClosePopup()
		local sourceSignature = Candidate.BuildSignature(build)
		local started, startError = tab:StartOptimizer({
			generationPhase = "equipment",
			objectiveMetric = "CombinedDPS",
			targetSkillGroupIndex = tostring(groupIndex),
			targetSkillIndex = tostring(seed.skillIndex),
			targetSkillGemId = targetGemId,
			searchStoredItems = false,
			searchSyntheticGear = true,
			syntheticItemLevel = "86",
			maxAddedPoints = "0",
			maxTotalPoints = "120",
			evaluationBudget = "48",
			seed = "1",
		})
		assert.is_true(started, startError)
		for _ = 1, 10000 do
			if not tab.job or tab.job.status ~= "running" then break end
			tab:Tick()
		end
		local result = tab.result
		local status = result and result.status
		local bestObserved = { }
	for _, violation in ipairs(result and result.bestObservedViolations or { }) do
		bestObserved[#bestObserved + 1] = tostring(violation.key or violation.label)
			.. ": " .. tostring(violation.reason or violation.deficit)
	end
		local syntheticCoverage = result and result.searchCoverage and result.searchCoverage.syntheticGear or { }
		assert.is_true((syntheticCoverage.exactTripleEvaluations or 0) > 0,
			"the selected unlinked Main Skill triple must reach the exact PoB pipeline")
		local socketRejection = syntheticCoverage.lastSocketRejection
		local exactEvaluation = syntheticCoverage.lastExactEvaluation
		local exactRejection = exactEvaluation and exactEvaluation.violations and exactEvaluation.violations[1]
		assert.are.equal("feasible", status,
		(result and result.message or "a valid socketed exact-PoB candidate was not found")
			.. (#bestObserved > 0 and ("; best observed: " .. table.concat(bestObserved, " | ")) or "")
			.. ("; exact synthetic evaluations=" .. tostring(syntheticCoverage.exactEvaluations or 0))
			.. (socketRejection and ("; synthetic socket rejection: " .. tostring(socketRejection.reason)) or "")
			.. (exactEvaluation and ("; synthetic feasible=" .. tostring(exactEvaluation.feasible)
				.. (exactRejection and ("; exact rejection: " .. tostring(exactRejection.key) .. " / " .. tostring(exactRejection.reason)) or "")) or ""))
		assert.is_truthy(result.candidate and result.candidate.gearVariant.socketBinding)
		assertGeneratedSlotsAreMarked({ result.candidate })
		assert.is_truthy(result.candidate.evaluation.skillSocket)
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
			"phantom socket binding and calculation must not mutate the active PoB build")

		local applied, applyError = tab:ApplyCandidate(result.candidate)
		assert.is_true(applied, applyError)
		local appliedGroup = build.skillsTab.socketGroupList[groupIndex]
		assert.are.equal(result.candidate.gearVariant.socketBinding.slotName, appliedGroup.slot)
		assert.is_truthy(appliedGroup.label:find("(linked: " .. result.candidate.gearVariant.socketBinding.slotName .. ")", 1, true),
			"a verified equipment binding must replace the stale unlinked planning label")
		assert.falsy(appliedGroup.label:find("unlinked", 1, true))
		local activeItem = build.itemsTab.activeItemSet[appliedGroup.slot]
		local equipped = build.itemsTab.items[activeItem.selItemId]
		assert.is_truthy(equipped and #equipped.sockets >= 1)
		local validLink, linkDetails = SkillCatalog.ValidateSocketGroup(build, groupIndex)
		assert.is_true(validLink, type(linkDetails) == "string" and linkDetails or "applied skill must map to a native item link")
		build.calcsTab:BuildOutput()
		assert.is_truthy(build.calcsTab.mainOutput and build.calcsTab.mainOutput.CombinedDPS,
			"the normal PoB output must recalculate the applied, socketed skill")

		build.itemsTab:Undo()
		build.skillsTab:Undo()
		assert.is_nil(build.skillsTab.socketGroupList[groupIndex].slot,
			"the generated equipment binding must reverse with the native skill-set undo")
		newBuild()
	end)

	it("generates a replacement item that repairs an already-bound Main Skill socket layout", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local seed = assert(SkillSeed.Create(build, gemId))
		local item = new("Item"):Item("Rarity: Rare\nSocket Repair Seed\nVaal Regalia\nSockets: R\n--------\n+80 to maximum Life")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = item.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		local group = build.skillsTab.socketGroupList[seed.groupIndex]
		group.slot = "Body Armour"
		build.skillsTab:ProcessSocketGroup(group)
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local repairPlan = assert(SkillCatalog.PlanSocketRepair(build, seed.groupIndex, group))
		assert.are.same({ "B" }, repairPlan.colors)
		assert.are.same({ 0 }, repairPlan.linkGroups)
		local variant, resolveError, details = SkillCatalog.ResolveTarget(build, seed.groupIndex,
			seed.skillIndex, gemId, { allowSocketRepair = true })
		assert.is_truthy(variant, resolveError)
		assert.are.equal("native_item_rework_required", details.socketRepair.status)
		local candidates = SyntheticGear.BuildCandidates(build, 4, 1, { }, nil, 86, {
			groupIndex = seed.groupIndex,
			gemVariant = variant,
			socketRepair = details.socketRepair,
		})
		local repairedCandidate, retainedAffixesRepair
		for _, candidate in ipairs(candidates) do
			local generated = candidate.gearVariant and candidate.gearVariant.generatedItems
			for _, entry in ipairs(generated or { }) do
				if entry.slotName == "Body Armour" and entry.socketPlan then
					repairedCandidate = candidate
					assert.is_nil(candidate.gearVariant.socketBinding,
						"an existing skill group keeps its equipment-slot binding")
					assert.is_true(SkillCatalog.SocketLayoutMatchesRepair(entry.item, repairPlan))
					if candidate.gearVariant.socketRepairOnly then
						retainedAffixesRepair = candidate
						assert.is_truthy(entry.item.raw:find("+80 to maximum Life", 1, true),
							"the guaranteed first repair proposal must retain the equipped rare's native affixes")
						assert.are.equal(item.baseName, entry.item.baseName)
					end
				end
			end
		end
		assert.is_truthy(repairedCandidate,
			"the combined proposal pool should include a native rare with the required socket colors and links")
		assert.is_truthy(retainedAffixesRepair,
			"the pool should reserve a socket-only native rework that preserves the equipped rare's affixes")
		assert.are.equal("R", item.sockets[1].color,
			"searching a repair must leave the source item's socket color unchanged")
		newBuild()
	end)

	it("repairs the implicit native socket on an Unset Ring", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local seed = assert(SkillSeed.Create(build, gemId))
		local item = new("Item"):Item(table.concat({
			"Rarity: Rare", "Ring Socket Repair Seed", "Unset Ring", "Sockets: G", "--------",
			"+80 to maximum Life",
		}, "\n"))
		assert.is_truthy(item and item.base)
		assert.is_true(#item.sockets == 1 or item.selectableSocketCount == 1,
			"PoB's Unset Ring implicit must provide one parsed native socket")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Ring 2"].selItemId = item.id
		build.itemsTab.slots["Ring 2"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		local group = assert(build.skillsTab.socketGroupList[seed.groupIndex])
		group.slot = "Ring 2"
		build.skillsTab:ProcessSocketGroup(group)
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()

		local repairPlan = assert(SkillCatalog.PlanSocketRepair(build, seed.groupIndex, group))
		assert.are.same({ "B" }, repairPlan.colors)
		local candidates, coverage = SyntheticGear.BuildCandidates(build, 16, 1, { }, nil, 86, {
			groupIndex = seed.groupIndex,
			socketRepairs = { repairPlan },
		})
		assert.is_true(coverage.socketRepairOnlyCandidateGenerated,
			tostring(coverage.socketRepairOnlyCandidateReason or "native implicit socket repair was not generated"))
		local repaired
		for _, candidate in ipairs(candidates) do
			if candidate.gearVariant and candidate.gearVariant.socketRepairOnly then
				for _, entry in ipairs(candidate.gearVariant.generatedItems or { }) do
					if entry.slotName == "Ring 2" then repaired = entry.item end
				end
			end
		end
		assert.is_truthy(repaired, "the repair pool must include a disposable rework of the equipped Unset Ring")
		assert.is_true(SkillCatalog.SocketLayoutMatchesRepair(repaired, repairPlan))
		assert.is_truthy(repaired.raw:find("+80 to maximum Life", 1, true),
			"the one-socket repair must retain the source ring's native affixes")
		assert.are.equal("G", item.sockets[1].color, "the live build's ring must remain unchanged")
		newBuild()
	end)

	it("repairs an equipped unique item without replacing its rarity or modifiers", function()
		newBuild()
		build.spec:SelectClass(assert(build.spec.tree.classNameMap.Duelist))
		build.characterLevel = 95
		build.characterLevelAutoMode = false
		build.skillsTab:PasteSocketGroup("Slot: Body Armour\nCyclone of Tumult 20/20 1\nAwakened Brutality 5/20 1\nAwakened Melee Physical Damage 5/20 1\nInfused Channelling 20/20 1\nLifetap 20/20 1\nMaim 20/20 1")
		build.mainSocketGroup = 1
		local item = new("Item"):Item("Rarity: Unique\nFoulborn Gruthkul's Pelt\nWyrmscale Doublet\nSockets: R-R-B-G-R-R\n--------\nUnique ID: 803cebd1b9e263ebdc5d2a25730cd818ddb744e36223caaad5b088ba963f5346")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = item.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		local group = build.skillsTab.socketGroupList[1]
		group.slot = "Body Armour"
		build.skillsTab:ProcessSocketGroup(group)
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		build.itemsTab:ResetUndo()
		local sourceSignature = Candidate.BuildSignature(build)
		local sourceRaw = item.raw
		local _, _, context = RoutePlanner.GetMainSkill(build)
		assert.is_table(context and context.socketRepair,
			"the incompatible six-socket Main Skill should produce a native repair plan")

		local candidates, coverage = SyntheticGear.BuildCandidates(build, 1, 1, { }, nil, 83, context.skill)
		assert.is_true(coverage.socketRepairOnlyCandidateGenerated,
			tostring(coverage.socketRepairOnlyCandidateReason or "unique socket repair was not generated"))
		local candidate = assert(candidates[1], "the bounded generator should return the reserved socket-only proposal")
		assert.is_true(candidate.gearVariant.socketRepairOnly)
		assert.are_not.equal(item.id, candidate.gearVariant.overrides["Body Armour"],
			"the disposable repaired item must not reuse the equipped item's identity")
		local entry = assert(candidate.gearVariant.generatedItems[1])
		assert.are.equal("socket_repair", entry.kind)
		assert.are.equal("UNIQUE", entry.item.rarity)
		assert.are.equal(item.baseName, entry.item.baseName)
		assert.is_false(candidate.gearVariant.items[1].synthetic)
		assert.is_true(candidate.gearVariant.items[1].socketRepair)
		assert.is_true(entry.item.optimizerSocketRepair)
		assert.is_false(entry.item.optimizerSynthetic == true,
			"a socket-only rework must not be mislabeled or priced as a synthetic rare")
		assert.is_true(SkillCatalog.SocketLayoutMatchesRepair(entry.item, context.socketRepair))
		local function socketIndependentRaw(raw)
			local lines = { }
			for line in raw:gmatch("[^\r\n]+") do
				if not line:match("^Unique ID:") then
					lines[#lines + 1] = line:match("^Sockets:") and "Sockets:<layout>" or line
				end
			end
			return table.concat(lines, "\n")
		end
		assert.are.equal(socketIndependentRaw(sourceRaw), socketIndependentRaw(entry.item.raw),
			"only sockets/links and the disposable item-instance ID may change")

		local validationTab, validationError = SyntheticGear.CreateValidationTab(build.itemsTab, candidate.gearVariant.generatedItems)
		assert.is_truthy(validationTab, validationError)
		local validationItem = validationTab.items[entry.tempId]
		assert.is_true(validationItem.optimizerSocketRepair)
		assert.is_false(validationItem.optimizerSynthetic == true)
		local validGear, gearError = Equipment.Validate(build, candidate.gearVariant.overrides, validationTab)
		assert.is_true(validGear, gearError)

		local projected, projectionError, projectedItems = Candidate.BuildPassiveSpec(build, { }, { }, {
			gearVariant = candidate.gearVariant,
		})
		assert.is_truthy(projected, projectionError)
		assert.are.equal(entry.tempId, projectedItems.activeItemSet["Body Armour"].selItemId)
		local isolatedBuild = { spec = projected, itemsTab = projectedItems }
		setmetatable(isolatedBuild, { __index = build })
		local exactCalc = Calcs.getMiscCalculator(isolatedBuild)
		local output = exactCalc({ spec = projected, returnEnv = true }, true)
		assert.is_true(type(output) == "table" and (output.CombinedDPS or 0) > 0,
			"the repaired unique must reach native PoB calculation with the selected Main Skill")
		local applied, applyError = Candidate.Apply(build, {
			feasible = true, sourceSignature = sourceSignature, nodeIds = { }, removeNodeIds = { },
			gearVariant = candidate.gearVariant,
		})
		assert.is_true(applied, applyError)
		local appliedId = tonumber(build.itemsTab.activeItemSet["Body Armour"].selItemId)
		local appliedItem = build.itemsTab.items[appliedId]
		assert.are_not.equal(item.id, appliedId)
		assert.are.equal("UNIQUE", appliedItem.rarity)
		assert.is_true(appliedItem.optimizerSocketRepair)
		assert.is_true(SkillCatalog.SocketLayoutMatchesRepair(appliedItem, context.socketRepair))
		assert.are.equal(sourceRaw, item.raw, "applying a route must preserve the source unique")
		build.calcsTab:BuildOutput()
		assert.is_true((build.calcsTab.mainOutput.CombinedDPS or 0) > 0,
			"the user-selected repair must recalculate in the normal PoB build")
		build.itemsTab:Undo()
		assert.are.equal(item.id, tonumber(build.itemsTab.activeItemSet["Body Armour"].selItemId),
			"the socket-repair variation must be reversible through PoB undo")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
			"search and exact calculation must leave the equipped unique and active build unchanged")
		assert.are.equal(sourceRaw, item.raw, "the source unique's socket colors must remain unchanged")
		newBuild()
	end)

	it("keeps tree routes in the exact budget when a Main Skill needs a native socket repair", function()
		newBuild()
		build.characterLevel = 90
		build.characterLevelAutoMode = false
		local gemId = "Metadata/Items/Gems/SkillGemFireball"
		local seed = assert(SkillSeed.Create(build, gemId))
		local item = new("Item"):Item("Rarity: Rare\nSocket Repair Route Seed\nVaal Regalia\nSockets: R\n--------\n+80 to maximum Life")
		build.itemsTab:AddItem(item, true)
		build.itemsTab.activeItemSet["Body Armour"].selItemId = item.id
		build.itemsTab.slots["Body Armour"]:SetSelItemId(item.id)
		build.itemsTab:PopulateSlots()
		local group = build.skillsTab.socketGroupList[seed.groupIndex]
		group.slot = "Body Armour"
		build.skillsTab:ProcessSocketGroup(group)
		build.skillsTab:UpdateSocketGroups()
		build:SyncLoadouts()
		build.calcsTab:BuildOutput()
		local sourceSignature = Candidate.BuildSignature(build)
		local runSpec, prepareError = RoutePlanner.Prepare(build, {
			routePlannerProposalLimit = "10000",
			routePlannerExactEvaluationBudget = "250",
			routePlannerUseNodePower = "false",
		})
		assert.is_table(runSpec, prepareError)
		assert.is_table(runSpec.skill.socketRepair,
			"the loaded Main Skill should be recoverable through a legal disposable native socket repair")
		local parsed = assert(Inputs.Parse({
			generationPhase = "combined",
			objectiveMetric = "CombinedDPS",
			targetSkillGroupIndex = tostring(seed.groupIndex),
			targetSkillIndex = tostring(seed.skillIndex),
			targetSkillGemId = gemId,
			maxAddedPoints = "4",
			maxTotalPoints = "130",
			evaluationBudget = "32",
			proposalBudget = "1000",
			timeoutSeconds = "120",
			searchStoredItems = true,
			searchSyntheticGear = true,
		}))
		parsed.search.routePlannerRunSpec = runSpec
		parsed.search.allowSocketRepair = true
		local job = PhantomSim.RunPhantomSim(build, parsed, { cancelled = false })
		local status, result = "running", nil
		for _ = 1, 4000 do
			status, result = job:Step()
			if status ~= "running" then break end
		end
		assert.is_true(status ~= "running", "the bounded socket-repair route search should finish")
		assert.is_true(status ~= "error", result and result.message or job.error)
		local phase = assert(result.searchCoverage and result.searchCoverage.phase)
		local repairCoverage = assert(phase.socketRepair)
		assert.is_true(repairCoverage.repairContextComposedByFamily.tree > 0,
			"native tree routes must inherit the legal socket repair instead of being filtered out")
		assert.is_true(phase.exactEvaluationPlan.windowFamilyCounts.tree > 0,
			"the exact-evaluation plan must reserve slots for the tree family")
		assert.is_true(phase.exactEvaluationsByFamily.tree > 0,
			"at least one composed passive route must reach the exact PoB calculator")
		assert.are.equal(sourceSignature, Candidate.BuildSignature(build),
			"composing the native socket repair must leave the loaded build unchanged")
		for _, route in ipairs(result.paretoFront or { }) do
			if #(route.nodeIds or { }) > 0 then
				assert.is_truthy(route.gearVariant and route.gearVariant.socketRepair,
					"any returned tree route must include the exact socket repair used by PoB")
			end
		end
		newBuild()
	end)

	it("keeps a non-first Main Skill group aligned with the native PoB selectors", function()
		newBuild()
		build.characterLevel = 20
		build.characterLevelAutoMode = false
		local fireballId = "Metadata/Items/Gems/SkillGemFireball"
		local firstSeed = assert(SkillSeed.Create(build, fireballId))
		local secondSeed = assert(SkillSeed.Create(build, fireballId))
		assert.are.equal(1, firstSeed.groupIndex)
		assert.are.equal(2, secondSeed.groupIndex)

		local arcId = "Metadata/Items/Gems/SkillGemArc"
		local variant, resolveError = SkillCatalog.ResolveTarget(build, secondSeed.groupIndex, secondSeed.skillIndex,
			arcId, { allowUnlinkedPlanning = true })
		assert.is_truthy(variant, resolveError)
		local applied, applyError = Candidate.Apply(build, {
			feasible = true,
			sourceSignature = Candidate.BuildSignature(build),
			generationPhase = "skills",
			unlinkedMainSkillPlan = true,
			gemVariants = { variant },
			nodeIds = { },
			removeNodeIds = { },
		})
		assert.is_true(applied, applyError)
		assert.are.equal(2, build.mainSocketGroup)
		assert.are.equal(2, build.calcsTab.input.skill_number,
			"the Calcs selector must store the socket-group index, not the active-effect index")
		assert.are.equal(build.skillsTab.socketGroupList[2], build.skillsTab.displayGroup,
			"the Skills tab display group must be rebound after restoring the new skill-set variation")

		wipeGlobalCache()
		build.skillsTab:UpdateSocketGroups()
		build.calcsTab:BuildOutput()
		assert.are.equal(arcId, SkillCatalog.CurrentMainGemId(build, 2, secondSeed.skillIndex))
		local mainSkill = build.calcsTab.mainEnv.player.mainSkill
		assert.are.equal(arcId, mainSkill.activeEffect.srcInstance.gemData.id,
			"the exact PoB output must follow the selected second skill group")
		assert.are.equal(fireballId, SkillCatalog.CurrentMainGemId(build, 1, firstSeed.skillIndex),
			"applying the second-group replacement must leave the first group intact")
		newBuild()
	end)
end)
