local PhantomSim = require("Modules.Optimizer.PhantomSim")

describe("Optimizer route and mutation composition", function()
	it("keeps Single Skill gem changes in the selected Main Skill group", function()
		local baseline = { isBaselineCandidate = true, label = "baseline" }
		local mainSkillChange = { label = "selected skill", gemVariant = { groupIndex = 7, gemIndex = 1 } }
		local mainSkillSupport = { label = "selected support", gemVariants = {
			{ groupIndex = 7, gemIndex = 1 },
			{ groupIndex = 7, gemIndex = 3 },
		} }
		local offTargetSupport = { label = "other skill support", gemVariant = { groupIndex = 6, gemIndex = 3 } }
		local mixedGroups = { label = "mixed skill groups", gemVariants = {
			{ groupIndex = 7, gemIndex = 1 },
			{ groupIndex = 6, gemIndex = 3 },
		} }
		local missingGroup = { label = "unscoped gem", gemVariant = { gemIndex = 2 } }
		local candidates, coverage = PhantomSim.FilterCandidatesToSingleSkill({
			baseline, mainSkillChange, mainSkillSupport, offTargetSupport, mixedGroups, missingGroup,
		}, 7)

		assert.are.same({ baseline, mainSkillChange, mainSkillSupport }, candidates,
			"non-gem candidates and selected-group gem mutations should remain in order")
		assert.are.equal("single_skill_scope_enforced", coverage.status)
		assert.are.equal(6, coverage.generatedCandidates)
		assert.are.equal(3, coverage.retainedCandidates)
		assert.are.equal(3, coverage.rejectedCandidates)
		assert.are.equal(2, coverage.rejectedByGroup[6],
			"off-target and mixed-group mutations must both be counted")
		assert.are.equal(1, coverage.rejectionReasons.gem_variant_group_missing_or_invalid)
	end)

	it("keeps route gem variants and merges mutation slots into a canonical plural list", function()
		local route = {
			nodeIds = { 101 },
			gemVariants = {
				{ groupIndex = 1, gemIndex = 1, gemId = "main", skillId = "MainSkill", level = 20, quality = 0 },
				{ groupIndex = 1, gemIndex = 2, gemId = "support-a", skillId = "SupportA", level = 20, quality = 20, kind = "support_swap" },
			},
		}
		local mutation = {
			nodeIds = { },
			gemVariant = { groupIndex = 1, gemIndex = 3, gemId = "support-b", skillId = "SupportB", level = 20, quality = 20, kind = "support_add" },
		}
		local combined = PhantomSim.CombineRoutesAndMutations({ route }, { { candidates = { mutation } } }, 1)
		assert.are.equal(1, #combined)
		local variants = combined[1].gemVariants
		assert.is_table(variants)
		assert.is_nil(combined[1].gemVariant, "combined candidates use one canonical plural field")
		assert.are.equal(3, #variants)
		assert.are.equal("main", variants[1].gemId)
		assert.are.equal(1, variants[1].gemIndex)
		assert.are.equal("support-a", variants[2].gemId)
		assert.are.equal(2, variants[2].gemIndex)
		assert.are.equal("support-b", variants[3].gemId)
		assert.are.equal(3, variants[3].gemIndex)
		assert.is_false(variants[1] == route.gemVariants[1], "composition must copy source variant tables")
		assert.are.equal(2, #route.gemVariants, "composition must not mutate its source route")
	end)

	it("deduplicates identical slot variants and drops conflicting slot compositions", function()
		local identical = { groupIndex = 1, gemIndex = 2, gemId = "support-a", skillId = "SupportA", level = 20, quality = 20, kind = "support_swap" }
		local route = { nodeIds = { 101 }, gemVariants = { identical } }
		local sameMutation = { nodeIds = { }, gemVariants = { {
			groupIndex = 1, gemIndex = 2, gemId = "support-a", skillId = "SupportA", level = 20, quality = 20, kind = "support_swap",
		} } }
		local sameResult = PhantomSim.CombineRoutesAndMutations({ route }, { { candidates = { sameMutation } } }, 1)
		assert.are.equal(1, #sameResult)
		assert.are.equal(1, #sameResult[1].gemVariants, "identical edits to one slot should be represented once")

		local conflictingMutation = { nodeIds = { }, gemVariant = {
			groupIndex = 1, gemIndex = 2, gemId = "support-b", skillId = "SupportB", level = 20, quality = 20, kind = "support_swap",
		} }
		local conflictingResult = PhantomSim.CombineRoutesAndMutations({ route }, { { candidates = { conflictingMutation } } }, 1)
		assert.are.equal(0, #conflictingResult, "conflicting slot edits must not silently overwrite one another")
	end)

	it("preserves archived passive provenance when composing a route with an equipment mutation", function()
		local route = {
			nodeIds = { 1101, 1102 },
			label = "Archived passive pattern",
			archivedRoutePattern = true,
			archivedPatternIndex = 7,
			archivedPatternVariantIndex = 2,
			archivedPatternSupportCount = 4,
			archivedPatternSampleCount = 6,
			archivedPatternSimilarity = 0.875,
		}
		local mutation = {
			nodeIds = { },
			label = "Rare ring rework",
			gearVariant = { changedSlots = { "Ring 1" }, items = { }, overrides = { } },
		}
		local combined = PhantomSim.CombineRoutesAndMutations({ route }, {
			{ key = "equipment", candidates = { mutation } },
		}, 1)
		assert.are.equal(1, #combined)
		local candidate = combined[1]
		assert.is_true(candidate.archivedRoutePattern)
		assert.is_true(candidate.archiveDerivedPassiveRoute)
		assert.is_true(candidate.archivedRouteComposition)
		assert.are.equal(1, candidate.archivedPatternSourceCount)
		assert.are.equal(7, candidate.archivedPatternIndex)
		assert.are.equal(2, candidate.archivedPatternVariantIndex)
		assert.are.equal(4, candidate.archivedPatternSupportCount)
		assert.are.equal(6, candidate.archivedPatternSampleCount)
		assert.are.equal(0.875, candidate.archivedPatternSimilarity)
		assert.are.equal("Ring 1", candidate.gearVariant.changedSlots[1])
		assert.is_false(candidate.archivedPatternSources[1] == route,
			"the composed result must carry copied provenance, not a mutable source candidate")
	end)

	it("merges a native socket-repair item with a separate gear repair without losing either slot", function()
		local route = {
			nodeIds = { 2101 }, label = "Archived passive route",
			archivedRoutePattern = true, archivedPatternIndex = 3, archivedPatternVariantIndex = 1,
			gearVariant = {
				overrides = { ["Body Armour"] = 31 },
				items = { { slot = "Body Armour", itemId = 31, name = "Socket repair" } },
				generatedItems = { { slotName = "Body Armour", tempId = 31, kind = "socket_repair" } },
				changedSlots = { "Body Armour" }, socketRepair = true,
				socketBinding = { groupIndex = 1, slotName = "Body Armour", itemId = 31 },
			},
		}
		local mutation = {
			label = "Lightning resistance ring",
			gearVariant = {
				overrides = { ["Ring 1"] = 42 },
				items = { { slot = "Ring 1", itemId = 42, name = "Resist ring" } },
				changedSlots = { "Ring 1" }, inventorySearch = true,
			},
		}
		local combined = PhantomSim.CombineRoutesAndMutations({ route }, {
			{ key = "gear_repair", candidates = { mutation } },
		}, 1, { mergeGearVariants = true })
		assert.are.equal(1, #combined)
		local candidate = combined[1]
		assert.are.equal(31, candidate.gearVariant.overrides["Body Armour"])
		assert.are.equal(42, candidate.gearVariant.overrides["Ring 1"])
		assert.are.same({ "Body Armour", "Ring 1" }, candidate.gearVariant.changedSlots)
		assert.is_true(candidate.gearVariant.socketRepair)
		assert.is_true(candidate.gearVariant.inventorySearch)
		assert.is_true(candidate.gearVariant.inventoryRoutePair)
		assert.is_true(candidate.archivedRoutePattern)
		assert.is_true(candidate.archivedRouteComposition)
		assert.are.equal(2, #candidate.gearVariant.items)
		assert.are.equal(1, #candidate.gearVariant.generatedItems)
		local conflict = PhantomSim.CombineRoutesAndMutations({ route }, { { candidates = { {
			gearVariant = { overrides = { ["Body Armour"] = 99 }, items = { }, changedSlots = { "Body Armour" } },
		} } } }, 1, { mergeGearVariants = true })
		assert.are.equal(0, #conflict, "different items cannot silently overwrite one composed slot")
	end)

	it("builds a route-specific exact-gate repair from a native resistance item", function()
		local bodyArmour = { id = 4, name = "Socket repair armour" }
		local currentRing = { id = 1, name = "Current ring", modList = { } }
		local smallResistRing = { id = 2, name = "Small resistance ring", modList = {
			{ name = "LightningResist", type = "BASE", value = 3, flags = 0, keywordFlags = 0 },
		} }
		local largeResistRing = { id = 3, name = "Large resistance ring", modList = {
			{ name = "LightningResist", type = "BASE", value = 15, flags = 0, keywordFlags = 0 },
		} }
		local itemsTab = {
			activeItemSetId = 1,
			itemSets = { [1] = { ["Body Armour"] = { selItemId = 4 }, ["Ring 1"] = { selItemId = 1 } } },
			slots = { ["Body Armour"] = { }, ["Ring 1"] = { } },
			items = { [1] = currentRing, [2] = smallResistRing, [3] = largeResistRing, [4] = bodyArmour },
			IsItemValidForSlot = function() return true end,
		}
		itemsTab.activeItemSet = itemsTab.itemSets[1]
		local build = { itemsTab = itemsTab }
		local route = {
			nodeIds = { 2201 }, label = "Archived route with one missing resistance",
			archivedRoutePattern = true, archivedPatternIndex = 5, archivedPatternVariantIndex = 2,
			gearVariant = {
				overrides = { ["Body Armour"] = 4 },
				items = { { slot = "Body Armour", itemId = 4, name = "Socket repair armour" } },
				changedSlots = { "Body Armour" }, socketRepair = true,
				-- The source group was already assigned to Body Armour, so PoB omits
				-- socketBinding; the generated item's native plan is the proof.
				generatedItems = { { slotName = "Body Armour", tempId = 4, socketPlan = {
					groupIndex = 1, repair = true, colors = { "G", "R", "R", "R", "R", "B" },
					linkGroups = { 0, 0, 0, 0, 0, 0 },
				} } },
			},
		}
		local pool = {
			{ label = "Small ring", gearVariant = { overrides = { ["Ring 1"] = 2 }, items = {
				{ slot = "Ring 1", itemId = 2, name = smallResistRing.name },
			}, changedSlots = { "Ring 1" }, inventorySearch = true } },
			{ label = "Large ring", gearVariant = { overrides = { ["Ring 1"] = 3 }, items = {
				{ slot = "Ring 1", itemId = 3, name = largeResistRing.name },
			}, changedSlots = { "Ring 1" }, inventorySearch = true } },
		}
		local syntheticRing = {
			label = "Synthetic lightning ring",
			gearVariant = {
				overrides = { ["Ring 2"] = 12 },
				items = { { slot = "Ring 2", itemId = 12, name = "Synthetic lightning ring" } },
				changedSlots = { "Ring 2" },
				generatedItems = { { slotName = "Ring 2", tempId = 12, item = {
					modList = { { name = "LightningResist", type = "BASE", value = 8, flags = 0, keywordFlags = 0 } },
				} } },
				syntheticSearch = true,
			},
		}
		local syntheticBodyArmour = {
			label = "Synthetic socket-compatible body armour",
			gearVariant = {
				overrides = { ["Body Armour"] = 14 },
				items = { { slot = "Body Armour", itemId = 14, name = "Synthetic socket-compatible body armour" } },
				changedSlots = { "Body Armour" },
				generatedItems = { { slotName = "Body Armour", tempId = 14, socketPlan = {
					groupIndex = 1, repair = true, colors = { "G", "R", "R", "R", "R", "B" },
					linkGroups = { 0, 0, 0, 0, 0, 0 },
				}, item = {
					modList = { { name = "LightningResist", type = "BASE", value = 12, flags = 0, keywordFlags = 0 } },
				} } },
				syntheticSearch = true,
				socketRepair = true,
			},
		}
		local parsed = {
			-- The exact route result must be enough to seed a repair even when the
			-- baseline-derived hard-gate cache does not contain this metric.
			hard = { },
			search = { routePlannerRunSpec = { }, equipmentOverrides = { } },
		}
		local repairs, coverage = PhantomSim.BuildArchivedGateRepairCandidates(route,
			{ metrics = { LightningResist = 70 }, violations = {
				{ key = "LightningResist", actual = 70, required = 75, label = "Lightning resistance" },
			} }, parsed, pool, build, 4, { syntheticRing, syntheticBodyArmour })
		assert.is_true(coverage.active)
		assert.are.equal(1, #coverage.needs)
		assert.are.equal("resistance:LightningResist", coverage.needs[1].key)
		assert.are.equal(4, #repairs)
		assert.are.equal(3, repairs[1].gearVariant.overrides["Ring 1"], "native mod contribution ranks the stronger repair first")
		assert.are.equal(4, repairs[1].gearVariant.overrides["Body Armour"], "the native socket-repair item must survive composition")
		assert.are.equal(12, repairs[2].gearVariant.overrides["Ring 2"], "a native synthetic rare can be composed with an archived route")
		assert.are.equal(14, repairs[3].gearVariant.overrides["Body Armour"], "a compatible synthetic rare can replace only the socket-repair slot")
		assert.is_nil(repairs[3].gearVariant.socketBinding, "an already-slot-bound skill does not need a new synthetic binding")
		assert.are.equal(2, coverage.inventoryMutationCandidateCount)
		assert.are.equal(2, coverage.syntheticMutationCandidateCount)
		assert.are.equal(0, coverage.structuralRejections,
			"a pre-bound skill should compose using matching native socket plans without socketBinding")
		assert.is_true(repairs[1].archiveGateRepairAttempted)
		assert.are.equal("resistance:LightningResist", repairs[1].archiveGateRepairNeeds[1].key)
		assert.is_true(repairs[1].archivedRouteComposition)
		for _, slotName in ipairs(repairs[1].gearVariant.changedSlots) do
			assert.is_false(slotName:match("^Flask") ~= nil, "flask slots stay outside adaptive repairs")
		end
		local mismatchedSocketPlan = {
			label = "Wrong skill-group synthetic body armour",
			gearVariant = {
				overrides = { ["Body Armour"] = 15 },
				items = { { slot = "Body Armour", itemId = 15, name = "Wrong group socket armour" } },
				changedSlots = { "Body Armour" }, socketRepair = true, syntheticSearch = true,
				generatedItems = { { slotName = "Body Armour", tempId = 15, socketPlan = {
					groupIndex = 2, repair = true, colors = { "G", "R", "R", "R", "R", "B" },
					linkGroups = { 0, 0, 0, 0, 0, 0 },
				}, item = { modList = { { name = "LightningResist", type = "BASE", value = 12,
					flags = 0, keywordFlags = 0 } } } } },
			},
		}
		local rejected, rejectedCoverage = PhantomSim.BuildArchivedGateRepairCandidates(route,
			{ metrics = { LightningResist = 70 }, violations = {
				{ key = "LightningResist", actual = 70, required = 75 },
			} }, parsed, { }, build, 2, { mismatchedSocketPlan })
		assert.are.equal(0, #rejected, "a repair for a different skill group must not replace the item")
		assert.are.equal(1, rejectedCoverage.structuralRejectionReasons["Gear variants require different items in Body Armour"])
	end)

	it("uses multi-item synthetic portfolios to repair exact archived attribute deficits", function()
		local bodyPlan = { groupIndex = 1, repair = true, colors = { "G", "R", "R" }, linkGroups = { 0, 0, 0 } }
		local weaponPlan = { groupIndex = 2, repair = true, colors = { "B", "G", "R" }, linkGroups = { 0, 0, 0 } }
		local route = {
			archivedRoutePattern = true,
			archiveDerivedPassiveRoute = true,
			label = "Archived route",
			gearVariant = {
				overrides = { ["Body Armour"] = 4, ["Weapon 1"] = 5 },
				changedSlots = { "Body Armour", "Weapon 1" },
				socketRepair = true,
				generatedItems = {
					{ slotName = "Body Armour", tempId = 4, socketPlan = bodyPlan },
					{ slotName = "Weapon 1", tempId = 5, socketPlan = weaponPlan },
				},
			},
		}
		local syntheticPortfolio = {
			label = "Synthetic body armour, staff, and ring portfolio",
			gearVariant = {
				overrides = { ["Body Armour"] = 14, ["Weapon 1"] = 15, ["Ring 1"] = 12, ["Ring 2"] = 13, Amulet = 16 },
				changedSlots = { "Body Armour", "Weapon 1", "Ring 1", "Ring 2", "Amulet" },
				generatedItems = {
					{ slotName = "Body Armour", tempId = 14, socketPlan = bodyPlan, item = { modList = {
						{ name = "Int", type = "BASE", value = 2, flags = 0, keywordFlags = 0 },
					} } },
					{ slotName = "Weapon 1", tempId = 15, socketPlan = weaponPlan, item = { modList = {
						{ name = "Int", type = "BASE", value = 2, flags = 0, keywordFlags = 0 },
					} } },
					{ slotName = "Ring 1", tempId = 12, item = { modList = {
						{ name = "Int", type = "BASE", value = 5, flags = 0, keywordFlags = 0 },
					} } },
					{ slotName = "Ring 2", tempId = 13, item = { modList = {
						{ name = "Int", type = "BASE", value = 5, flags = 0, keywordFlags = 0 },
					} } },
					{ slotName = "Amulet", tempId = 16, item = { modList = {
						{ name = "Int", type = "BASE", value = 5, flags = 0, keywordFlags = 0 },
					} } },
				},
				items = {
					{ slot = "Body Armour", itemId = 14, name = "Socket-compatible rare armour", synthetic = true },
					{ slot = "Weapon 1", itemId = 15, name = "Socket-compatible rare staff", synthetic = true },
					{ slot = "Ring 1", itemId = 12, name = "Attribute ring", synthetic = true },
					{ slot = "Ring 2", itemId = 13, name = "Second attribute ring", synthetic = true },
					{ slot = "Amulet", itemId = 16, name = "Attribute amulet", synthetic = true },
				},
				inventoryRoutePair = true,
				syntheticSearch = true,
				syntheticTriple = true,
				socketRepair = true,
			},
		}
		local itemsTab = {
			activeItemSetId = 1,
			itemSets = { [1] = { ["Body Armour"] = { selItemId = 4 }, ["Weapon 1"] = { selItemId = 5 } } },
			slots = { ["Body Armour"] = { }, ["Weapon 1"] = { }, ["Ring 1"] = { } },
			items = { [4] = { id = 4 }, [5] = { id = 5 } },
			IsItemValidForSlot = function() return true end,
		}
		itemsTab.activeItemSet = itemsTab.itemSets[1]
		local build = { itemsTab = itemsTab }
		local parsed = { hard = { }, search = { routePlannerRunSpec = { }, equipmentOverrides = { } } }
		local repairs, coverage = PhantomSim.BuildArchivedGateRepairCandidates(route, {
			metrics = { Int = 111, ReqInt = 113 },
			requirements = { violations = {
				{ key = "attribute_requirement_Int", actual = 111, required = 113, label = "Int requirement" },
			} },
			violations = { { key = "attribute_requirement_Int", actual = 111, required = 113 } },
		}, parsed, { }, build, 2, { syntheticPortfolio })
		assert.are.equal(1, coverage.syntheticMutationCandidateCount)
		assert.are.equal(1, coverage.syntheticPortfolioCandidateCount)
		assert.are.equal(0, coverage.syntheticRejectedShapeCandidateCount)
		assert.are.equal(1, #repairs)
		assert.is_true(repairs[1].archiveGateRepairAttempted)
		assert.are.equal(14, repairs[1].gearVariant.overrides["Body Armour"])
		assert.are.equal(15, repairs[1].gearVariant.overrides["Weapon 1"])
		assert.are.equal(12, repairs[1].gearVariant.overrides["Ring 1"])
		assert.are.equal(13, repairs[1].gearVariant.overrides["Ring 2"])
		assert.are.equal(16, repairs[1].gearVariant.overrides.Amulet)
		assert.are.same({ "Amulet", "Body Armour", "Ring 1", "Ring 2", "Weapon 1" }, repairs[1].gearVariant.changedSlots)
		assert.is_true(repairs[1].gearVariant.socketRepair,
			"the exact-native socket-repair candidates must remain in the composed portfolio")
	end)

	it("reserves archive-derived direct and composed proposals inside the exact budget", function()
		local baseline = { isBaselineCandidate = true, label = "baseline" }
		local progressive = { progressiveRouteBundle = true, nodeIds = { 100 }, label = "progressive" }
		local function archiveRoute(index, composed)
			return { archivedRoutePattern = true, archiveDerivedPassiveRoute = true,
				archivedRouteComposition = composed == true, nodeIds = { index }, label = "archive " .. tostring(index) }
		end
		local directOne, directTwo = archiveRoute(101, false), archiveRoute(102, false)
		local composedOne, composedTwo, composedThree, composedFour = archiveRoute(201, true), archiveRoute(202, true),
			archiveRoute(203, true), archiveRoute(204, true)
		local equipment, skill, tree = { gearVariant = { } }, { gemVariant = { } }, { nodeIds = { 999 } }
		local coverage = { progressiveTreeReservationPosition = 3, progressiveTreeReservationStatus = "reserved",
			archivedRoutePatterns = { } }
		local ordered, plan = PhantomSim.InterleavePlannerCandidateFamilies({
			baseline, equipment, progressive, directOne, directTwo, composedOne, composedTwo, composedThree,
			composedFour, skill, tree,
		}, coverage, 40)
		assert.are.equal(baseline, ordered[1], "the exact baseline must remain first")
		assert.are.equal(progressive, ordered[2], "the progressive tree reservation must remain after baseline")
		assert.are.equal(directOne, ordered[3], "one archive route must be reserved")
		assert.are.equal(composedOne, ordered[4], "composed archive proposals must follow the direct reserve")
		assert.are.equal(composedTwo, ordered[5])
		assert.are.equal(composedThree, ordered[6])
		assert.are.equal(4, coverage.archivedRoutePatterns.reservedExactEvaluationQuota)
		assert.are.equal(1, coverage.archivedRoutePatterns.reservedDirectCandidates)
		assert.are.equal(3, coverage.archivedRoutePatterns.reservedComposedCandidates)
		assert.are.equal(4, coverage.archivedRoutePatterns.reservedExactEvaluations)
		assert.is_table(plan)
	end)

	it("reinterleaves exact evaluations after baseline gear repairs are inserted", function()
		local baseline = { isBaselineCandidate = true, label = "baseline" }
		local repairOne = { gearVariant = { items = { { slot = "Boots", itemId = 11 } } }, label = "repair one" }
		local repairTwo = { gearVariant = { items = { { slot = "Gloves", itemId = 12 } } }, label = "repair two" }
		local equipment = { gearVariant = { items = { { slot = "Helmet", itemId = 13 } } }, label = "equipment" }
		local progressive = { progressiveRouteBundle = true, nodeIds = { 700 }, label = "progressive" }
		local function archiveRoute(index, composed)
			return { archivedRoutePattern = true, archiveDerivedPassiveRoute = true,
				archivedRouteComposition = composed == true, nodeIds = { index },
				gearVariant = composed and { items = { { slot = "Ring 1", itemId = index } } } or nil,
				label = "archive " .. tostring(index) }
		end
		local direct = archiveRoute(701, false)
		local composed = archiveRoute(702, true)
		local skill = { gemVariant = { gemId = "support" }, label = "skill" }
		local tree = { nodeIds = { 703 }, label = "tree" }
		-- ReplaceScheduledWithRepairs inserts gear repairs at index 2. This
		-- reproduces the live queue after the native baseline has been evaluated.
		local repairedQueue = { baseline, repairOne, repairTwo, equipment, progressive, direct, composed, skill, tree }
		local coverage = { progressiveTreeReservationPosition = 2,
			progressiveTreeReservationStatus = "reserved", archivedRoutePatterns = { } }
		local ordered, plan = PhantomSim.InterleavePlannerCandidateFamilies(
			repairedQueue, coverage, 250, progressive)

		assert.are.equal(baseline, ordered[1], "the already-evaluated baseline must remain at index 1")
		assert.are.equal(progressive, ordered[2], "the original progressive route must be recovered by identity, not stale index")
		assert.are.equal(direct, ordered[3], "the direct archive route must retain its exact-evaluation reservation")
		assert.are.equal(composed, ordered[4], "the composed archive route must retain its exact-evaluation reservation")
		assert.are.equal(2, coverage.progressiveTreeReservationPosition)
		assert.are.equal("reserved", coverage.progressiveTreeReservationStatus)
		assert.are.equal(1, coverage.archivedRoutePatterns.reservedDirectCandidates)
		assert.are.equal(1, coverage.archivedRoutePatterns.reservedComposedCandidates)
		assert.is_true(plan.windowFamilyDiversity >= 4,
			"the post-repair exact window must include multiple mutation families")
		assert.is_true((plan.windowFamilyCounts.skills or 0) > 0)
		assert.is_true((plan.windowFamilyCounts.tree or 0) > 0)
		assert.is_true((plan.windowFamilyCounts.equipment or 0) > 0)
	end)

	it("reserves a paired progressive route after the baseline without changing remaining rank order", function()
		local baseline = { isBaselineCandidate = true, label = "baseline" }
		local highRankedRoute = { label = "other route" }
		local progressive = {
			label = "selected progressive route",
			nodeIds = { 500, 700 },
			progressiveRouteBundle = true,
			combinedTreeAscendancy = true,
			ascendancyVariant = { ascendClassId = 5, secondaryAscendClassId = 0 },
		}
		local trailingRoute = { label = "trailing route" }
		local candidates = { baseline, highRankedRoute, progressive, trailingRoute }
		local position, status = PhantomSim.PrioritizeLockedProgressiveCandidate(candidates, 5, { 700 }, 2, true)
		assert.are.equal("reserved", status)
		assert.are.equal(2, position)
		assert.are.equal(baseline, candidates[1])
		assert.are.equal(progressive, candidates[2])
		assert.are.equal(highRankedRoute, candidates[3])
		assert.are.equal(trailingRoute, candidates[4], "other ranked candidates must keep their relative order")
	end)

	it("reserves a current-ascendancy progressive tree proposal inside a combined exact budget", function()
		local baseline = { isBaselineCandidate = true, label = "current build" }
		local earlierGear = { label = "gear proposal" }
		local progressive = {
			label = "progressive passive bundle",
			nodeIds = { 101, 202, 303 },
			progressiveRouteBundle = true,
			routeCount = 3,
		}
		local laterGear = { label = "later gear proposal" }
		local candidates = { baseline, earlierGear, laterGear, progressive }
		local position, status = PhantomSim.PrioritizeProgressiveTreeCandidate(candidates, 250, true)
		assert.are.equal("reserved", status)
		assert.are.equal(2, position)
		assert.are.equal(baseline, candidates[1])
		assert.are.equal(progressive, candidates[2])
		assert.are.equal(earlierGear, candidates[3])
		assert.are.equal(laterGear, candidates[4], "other ranked proposals keep their relative order")

		local tooSmall = { baseline, progressive }
		position, status = PhantomSim.PrioritizeProgressiveTreeCandidate(tooSmall, 1, true)
		assert.is_nil(position)
		assert.are.equal("exact_budget_too_small", status)
		assert.are.equal(baseline, tooSmall[1], "a one-evaluation budget keeps baseline first")
	end)

	it("fails closed when the exact budget or selected ascendancy prerequisites cannot support a reservation", function()
		local baseline = { isBaselineCandidate = true }
		local progressive = {
			nodeIds = { 500 }, progressiveRouteBundle = true, combinedTreeAscendancy = true,
			ascendancyVariant = { ascendClassId = 5, secondaryAscendClassId = 0 },
		}
		local tooSmall = { baseline, progressive }
		local position, status = PhantomSim.PrioritizeLockedProgressiveCandidate(tooSmall, 5, { 500 }, 1, true)
		assert.is_nil(position)
		assert.are.equal("exact_budget_too_small", status)
		assert.are.equal(baseline, tooSmall[1], "a one-evaluation budget must keep the exact baseline first")
		assert.are.equal(progressive, tooSmall[2])

		local missingRequiredNode = { baseline, progressive }
		position, status = PhantomSim.PrioritizeLockedProgressiveCandidate(missingRequiredNode, 5, { 999 }, 2, true)
		assert.is_nil(position)
		assert.are.equal("no_retained_candidate", status)
		assert.are.equal(progressive, missingRequiredNode[2], "a candidate without required nodes must not be reserved")
	end)
end)
