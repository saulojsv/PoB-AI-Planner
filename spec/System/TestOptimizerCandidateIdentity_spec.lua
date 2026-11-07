local CandidateIdentity = require("Modules.Optimizer.CandidateIdentity")

describe("Optimizer candidate semantic identity", function()
	local contextHash = assert(CandidateIdentity.HashContext({ buildSignature = "fixture", dataVersion = "3.29" }))

	local function syntheticCandidate(virtualItemId, itemRaw)
		local nativeItem = { raw = itemRaw }
		nativeItem.itemsTab = nativeItem -- mirrors the cyclic native PoB object graph
		return {
			nodeIds = { 101 },
			gearVariant = {
				overrides = { ["Ring 1"] = virtualItemId },
				items = { { slot = "Ring 1", itemId = virtualItemId, name = "Generated ring" } },
				generatedItems = { { tempId = virtualItemId, slotName = "Ring 1", baseName = "Opal Ring",
					itemLevel = 84, item = nativeItem, modIds = { "life", "resistance" }, affixCount = 2,
					rollProfileId = "median", rollFraction = 0.5 } },
				changedSlots = { "Ring 1" },
				socketBinding = { groupIndex = 1, slotName = "Ring 1", itemId = virtualItemId },
				syntheticSearch = true,
			},
		}
	end

	it("hashes cyclic native items from exact raw data and ignores run-local virtual IDs", function()
		local first, firstError = CandidateIdentity.HashCandidate(contextHash, syntheticCandidate(9001,
			"Rarity: Rare\nGenerated Opal Ring\nOpal Ring\n--------\n+80 to maximum Life"))
		local same, sameError = CandidateIdentity.HashCandidate(contextHash, syntheticCandidate(9002,
			"Rarity: Rare\nGenerated Opal Ring\nOpal Ring\n--------\n+80 to maximum Life"))
		local different = CandidateIdentity.HashCandidate(contextHash, syntheticCandidate(9003,
			"Rarity: Rare\nGenerated Opal Ring\nOpal Ring\n--------\n+81 to maximum Life"))

		assert.is_nil(firstError)
		assert.is_nil(sameError)
		assert.are.equal(first, same, "the same native item is identical even when allocated a different temporary PoB ID")
		assert.are_not.equal(first, different, "different exact native item text must remain a distinct proposal")
	end)

	it("does not silently canonicalize a generated PoB item without stable raw data", function()
		local candidate = syntheticCandidate(9004, "")
		candidate.gearVariant.generatedItems[1].item.raw = nil
		local hash, hashError = CandidateIdentity.HashCandidate(contextHash, candidate)
		assert.is_nil(hash)
		assert.are.equal("Generated PoB item has no stable native raw identity", hashError)
	end)

	it("keeps different stored inventory item IDs semantically distinct", function()
		local first = CandidateIdentity.HashCandidate(contextHash, { gearVariant = {
			overrides = { ["Ring 1"] = 41 }, changedSlots = { "Ring 1" }, items = { },
		} })
		local second = CandidateIdentity.HashCandidate(contextHash, { gearVariant = {
			overrides = { ["Ring 1"] = 42 }, changedSlots = { "Ring 1" }, items = { },
		} })
		assert.are_not.equal(first, second)
	end)

	it("merges identical applied gear when only the exact-budget family override differs", function()
		local first = {
			label = "Equipment combination",
			generationPhase = "combined",
			gearVariant = {
				overrides = { ["Boots"] = 24 },
				changedSlots = { "Boots" },
				items = { { slot = "Boots", itemId = 24, name = "Generated rare boots" } },
			},
		}
		local second = {
			label = "Synthetic rare boots",
			generationPhase = "synthetic_gear",
			plannerFamilyOverride = "equipment",
			gearVariant = {
				overrides = { ["Boots"] = 24 },
				changedSlots = { "Boots" },
				items = { { slot = "Boots", itemId = 24, name = "Generated rare boots" } },
			},
		}
		local unique, coverage = CandidateIdentity.Deduplicate({ first, second }, contextHash)

		assert.are.equal(1, #unique, "the same applied gear state should consume one exact evaluation and produce one route")
		assert.are.equal(1, coverage.duplicateCandidatesDiscarded)
		assert.are.equal(unique[1].canonicalHash, CandidateIdentity.HashCandidate(contextHash, first))
		assert.are.equal(2, #unique[1].proposalOrigins, "keep both proposal origins for diagnostics")
	end)

	it("preserves scheduled exact family and archived provenance across native candidate reconstruction", function()
		local candidate = {
			label = "Archived passive route",
			plannerFamilyOverride = "tree",
			nodeIds = { 101, 102 },
			archivedRoutePattern = true,
			archivedRouteComposition = true,
		}
		local metadata = CandidateIdentity.CaptureExactEvaluationMetadata(candidate)

		-- createSpecProxy resolves the requested nodes through PoB and may attach
		-- the socket-repair item. Reporting must still describe the scheduled
		-- passive/archive proposal rather than its mutated final representation.
		candidate.nodeIds = { }
		candidate.gearVariant = { overrides = { ["Body Armour"] = 99 } }
		candidate.plannerFamilyOverride = nil
		candidate.archivedRoutePattern = nil
		candidate.archivedRouteComposition = nil

		assert.are.equal("tree", metadata.family)
		assert.is_true(metadata.archivedRoutePattern)
		assert.is_true(metadata.archivedRouteComposition)
		assert.are.equal("equipment", CandidateIdentity.Family(candidate),
			"the test fixture must reflect the family drift caused by reconstruction")
	end)

	it("deduplicates proposals that converge after native socket repair composition", function()
		local equipmentProposal = {
			label = "Equipment boots",
			gearVariant = { overrides = { Boots = 24 }, changedSlots = { "Boots" },
				items = { { slot = "Boots", itemId = 24, name = "Rare boots" } } },
		}
		local syntheticProposal = {
			label = "Synthetic rare boots",
			plannerFamilyOverride = "equipment",
			gearVariant = { overrides = { Boots = 25 }, changedSlots = { "Boots" },
				items = { { slot = "Boots", itemId = 25, name = "Synthetic boots" } } },
		}
		local beforeComposition, firstCoverage = CandidateIdentity.Deduplicate(
			{ equipmentProposal, syntheticProposal }, contextHash)
		assert.are.equal(2, #beforeComposition, "the uncomposed proposals represent different applied gear")

		-- This is the production transition in PhantomSim: a native socket repair
		-- replaces the conflicting slot and makes both proposals the same build.
		local function repairedGear(originField)
			local gear = {
				overrides = { ["Body Armour"] = 90, Boots = 24 },
				changedSlots = { "Body Armour", "Boots" },
				items = {
					{ slot = "Body Armour", itemId = 90, name = "Native socket repair" },
					{ slot = "Boots", itemId = 24, name = "Rare boots" },
				},
				syntheticSearch = true,
			}
			if originField == "syntheticPair" then gear.items[1].modIds = { } end
			gear[originField] = true
			return gear
		end
		equipmentProposal.gearVariant = repairedGear("syntheticPair")
		equipmentProposal.plannerFamilyOverride = "equipment"
		syntheticProposal.gearVariant = repairedGear("socketRepair")
		assert.are_not.equal(CandidateIdentity.HashCandidate(contextHash, equipmentProposal),
			CandidateIdentity.HashCandidate(contextHash, syntheticProposal),
			"the first pass must keep socket-repair and pair-generation markers available")

		local afterComposition, finalCoverage = CandidateIdentity.DeduplicateAfterComposition(
			beforeComposition, contextHash, firstCoverage)
		assert.are.equal(1, #afterComposition,
			"equivalent final gear after socket repair must consume only one exact calculation")
		assert.are.equal(1, finalCoverage.postCompositionDuplicatesDiscarded)
		assert.are.equal(1, finalCoverage.duplicateCandidatesDiscarded,
			"coverage must include duplicates discarded by the post-composition pass")
		assert.are.equal(1, finalCoverage.uniqueCandidates)
		assert.are.equal(2, #afterComposition[1].proposalOrigins,
			"the exact route should retain both equipment and synthetic proposal origins")
		assert.are.equal(CandidateIdentity.HashComposedCandidate(contextHash, afterComposition[1]),
			afterComposition[1].canonicalHash, "the composed candidate must receive its new canonical hash")
	end)

	it("bounds the exact queue while preserving family order and reserved routes", function()
		local baseline = { label = "Native baseline", isBaselineCandidate = true }
		local progressive = { label = "Progressive tree route", plannerFamilyOverride = "tree",
			progressiveRouteBundle = true, nodeIds = { 101 } }
		local archived = { label = "Archived route", plannerFamilyOverride = "equipment",
			archivedRoutePattern = true }
		local proposals = {
			baseline, progressive, archived,
			{ plannerFamilyOverride = "equipment", proposalId = "equipment-1" },
			{ plannerFamilyOverride = "equipment", proposalId = "equipment-2" },
			{ plannerFamilyOverride = "skills", proposalId = "skill-1" },
			{ plannerFamilyOverride = "skills", proposalId = "skill-2" },
			{ plannerFamilyOverride = "tree", proposalId = "tree-1" },
			{ plannerFamilyOverride = "tree", proposalId = "tree-2" },
		}

		local queue, plan = CandidateIdentity.InterleaveFamilies(proposals, {
			familyOrder = { "equipment", "skills", "tree" },
			reservedCandidates = { progressive, archived },
			budget = 6,
			retentionLimit = 7,
		})

		assert.are.equal(9, plan.candidateCount, "coverage keeps the full unique proposal count")
		assert.are.equal(7, #queue, "only the bounded exact-evaluation queue remains resident")
		assert.are.equal(7, plan.retainedCandidateCount)
		assert.are.equal(7, plan.exactQueueLimit)
		assert.are.equal(2, plan.discardedBeyondRetentionLimit)
		assert.are.equal(baseline, queue[1], "the native baseline stays first")
		assert.are.equal(progressive, queue[2], "the progressive route stays reserved")
		assert.are.equal(archived, queue[3], "the archive route stays reserved")
		assert.are.equal("equipment-1", queue[4].proposalId)
		assert.are.equal("skill-1", queue[5].proposalId)
		assert.are.equal("tree-1", queue[6].proposalId,
			"round-robin family coverage remains in the exact-calculation window")
	end)

	it("never truncates the baseline and explicitly reserved candidates", function()
		local baseline = { isBaselineCandidate = true }
		local first = { plannerFamilyOverride = "tree" }
		local second = { plannerFamilyOverride = "equipment" }
		local queue, plan = CandidateIdentity.InterleaveFamilies({ baseline, first, second }, {
			reservedCandidates = { first, second }, budget = 1, retentionLimit = 1,
		})

		assert.are.equal(3, #queue)
		assert.are.equal(3, plan.retainedCandidateCount)
		assert.are.equal(0, plan.discardedBeyondRetentionLimit)
		assert.are.equal(baseline, queue[1])
		assert.are.equal(first, queue[2])
		assert.are.equal(second, queue[3])
	end)
end)
