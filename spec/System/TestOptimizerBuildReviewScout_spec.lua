local Scout = require("Modules.Optimizer.BuildReviewScout")

local function newProfile()
	return {
		configuredSkillEffects = {
			{ effectId = "fireball", gemId = "Metadata/Items/Gems/SkillGemFireball", name = "Fireball" },
		},
		skillGroups = {
			{
				groupIndex = 1,
				selectedMainGroup = true,
				skills = {
					{
						skillIndex = 1,
						name = "Fireball",
						selectedMainSkill = true,
						effects = {
							{ effectId = "fireball", gemId = "Metadata/Items/Gems/SkillGemFireball",
								gameId = "fireball", variantId = "", name = "Fireball", selected = true },
							{ effectId = "fireball_alt", gemId = "Metadata/Items/Gems/SkillGemFireball",
								gameId = "fireball", variantId = "transfigured", name = "Fireball of Meteors", selected = false },
						},
					},
				},
			},
		},
	}
end

local function newCatalog()
	return {
		effects = {
			{ effectId = "fireball", gemId = "Metadata/Items/Gems/SkillGemFireball", gameId = "fireball",
				variantId = "", effectName = "Fireball", tags = "spell, fire, projectile" },
			{ effectId = "fireball_alt", gemId = "Metadata/Items/Gems/SkillGemFireballTransfigured",
				gameId = "fireball", variantId = "transfigured", effectName = "Fireball of Meteors",
				tags = "spell, fire, projectile" },
			{ effectId = "ice_nova", gemId = "Metadata/Items/Gems/SkillGemIceNova", gameId = "ice_nova",
				variantId = "", effectName = "Ice Nova", tags = "spell, cold, nova" },
			{ effectId = "vaal_spark", gemId = "Metadata/Items/Gems/SkillGemVaalSpark", gameId = "spark",
				variantId = "vaal", effectName = "Vaal Spark", tags = "spell, lightning, projectile" },
			{ effectId = "spectral_helix", gemId = "Metadata/Items/Gems/SkillGemSpectralHelix",
				gameId = "spectral_helix", variantId = "", effectName = "Spectral Helix", tags = "attack, melee" },
			-- A repeated catalog row must not create a second experiment.
			{ effectId = "vaal_spark", gemId = "Metadata/Items/Gems/SkillGemVaalSpark", gameId = "spark",
				variantId = "vaal", effectName = "Vaal Spark", tags = "spell, lightning, projectile" },
		},
	}
end

local function hypothesisByEffect(result, effectId)
	for _, hypothesis in ipairs(result.hypotheses) do
		if hypothesis.effectB.effectId == effectId then return hypothesis end
	end
	return nil
end

local function hypothesisByPair(result, leftEffectId, rightEffectId)
	for _, hypothesis in ipairs(result.hypotheses) do
		if hypothesis.effectA.effectId == leftEffectId and hypothesis.effectB.effectId == rightEffectId then return hypothesis end
		if hypothesis.effectA.effectId == rightEffectId and hypothesis.effectB.effectId == leftEffectId then return hypothesis end
	end
	return nil
end

describe("AI Planner deterministic build review scout", function()
	it("produces stable hypotheses independent of catalog row order", function()
		local profile = newProfile()
		local catalog = newCatalog()
		local knownPairs = { { leftEffectId = "ice_nova", rightEffectId = "fireball" } }
		local first = Scout.Propose(profile, catalog, knownPairs)
		local reversed = newCatalog()
		local flipped = { }
		for index = #reversed.effects, 1, -1 do flipped[#flipped + 1] = reversed.effects[index] end
		local second = Scout.Propose(profile, { effects = flipped }, knownPairs)

		assert.are.equal(1, first.schemaVersion)
		assert.are.equal("opportunity_scout", first.role)
		assert.are.equal(first.candidateCount, second.candidateCount)
		assert.are.equal(#first.hypotheses, first.candidateCount)
		for index, hypothesis in ipairs(first.hypotheses) do
			assert.are.equal(hypothesis.id, second.hypotheses[index].id)
			assert.are.equal(hypothesis.status, "untested")
			assert.are.equal("exact_pob_factorial", hypothesis.requiredTest.type)
			assert.are.same({ "baseline", "factorA", "factorB", "combined" }, hypothesis.requiredTest.cells)
		end
	end)

	it("keeps exploration deterministic while rotating low-signal ties by build context", function()
		local profile = newProfile()
		profile.itemSlots = { { slot = "Weapon 1", base = "Prophecy Wand" } }
		local catalog = { effects = { newCatalog().effects[1] } }
		for index = 1, 20 do
			catalog.effects[#catalog.effects + 1] = { effectId = "cross_" .. index, gemId = "CrossGem" .. index,
				name = "Cross " .. index, tags = "family_" .. index }
		end
		local function firstIdeas()
			local result = Scout.Propose(profile, catalog, { })
			local ids = { }
			for index = 1, math.min(8, #result.hypotheses) do ids[index] = result.hypotheses[index].effectB.effectId end
			return table.concat(ids, ",")
		end
		local first = firstIdeas()
		assert.are.equal(first, firstIdeas())
		local changedContext
		for index = 1, 8 do
			profile.itemSlots[1].base = "Context Wand " .. index
			if firstIdeas() ~= first then changedContext = true; break end
		end
		assert.is_true(changedContext)
	end)

	it("excludes self, same-base variants, duplicate rows, and known pairs", function()
		local result = Scout.Propose(newProfile(), newCatalog(), {
			{ leftEffectId = "ice_nova", rightEffectId = "fireball" },
		})
		assert.are.equal(2, result.candidateCount)
		assert.is_nil(hypothesisByEffect(result, "fireball"))
		assert.is_nil(hypothesisByEffect(result, "ice_nova"))
		assert.is_nil(hypothesisByEffect(result, "fireball_alt"))
		assert.is_truthy(hypothesisByEffect(result, "vaal_spark"))
		assert.is_truthy(hypothesisByEffect(result, "spectral_helix"))
		local ids = { }
		for _, hypothesis in ipairs(result.hypotheses) do
			assert.is_false(ids[hypothesis.id] == true)
			ids[hypothesis.id] = true
			assert.are.equal("fireball", hypothesis.effectA.effectId)
			assert.is_truthy(hypothesis.factorIds.anchor:find("fireball", 1, true))
			assert.is_truthy(hypothesis.factorIds.candidate:find(hypothesis.effectB.effectId, 1, true))
		end
	end)

	it("preserves transfigured identity when paired with a different base skill", function()
		local profile = newProfile()
		profile.configuredSkillEffects[#profile.configuredSkillEffects + 1] = {
			effectId = "ice_nova", gemId = "Metadata/Items/Gems/SkillGemIceNova", gameId = "ice_nova", name = "Ice Nova",
		}
		local result = Scout.Propose(profile, newCatalog(), { })
		local transfigured = assert(hypothesisByPair(result, "ice_nova", "fireball_alt"))
		assert.are.equal("Metadata/Items/Gems/SkillGemFireballTransfigured", transfigured.effectB.gemId)
		assert.are.equal("fireball", transfigured.effectB.gameId)
		assert.are.equal("transfigured", transfigured.effectB.variantId)
		assert.are.equal("weak_signal_overlap", transfigured.reason.method)
		assert.is_truthy(#transfigured.reason.sharedTags > 0)
		assert.are.same({ }, transfigured.reason.signalTags)
		local exploratory = assert(hypothesisByPair(result, "fireball", "spectral_helix"))
		assert.are.equal("exploratory", exploratory.reason.method)
		assert.are.same({ }, exploratory.reason.sharedTags)
		assert.are.equal(100, exploratory.relevanceScore)
		assert.is_truthy(exploratory.reason.summary:find("context tie-break 100.000", 1, true))
	end)

	it("keeps movement and travel tag overlap as context rather than a ranking signal", function()
		local profile = newProfile()
		profile.configuredSkillEffects = { { effectId = "frostblink", gemId = "Frostblink", gameId = "frostblink", name = "Frostblink" } }
		profile.skillGroups[1].skills[1].effects = {
			{ effectId = "frostblink", gemId = "Frostblink", gameId = "frostblink", name = "Frostblink", selected = true },
		}
		local result = Scout.Propose(profile, { effects = {
			{ effectId = "frostblink", gemId = "Frostblink", gameId = "frostblink", name = "Frostblink", tags = "movement, travel, duration" },
			{ effectId = "mirror_arrow", gemId = "MirrorArrow", gameId = "mirror_arrow", name = "Mirror Arrow", tags = "movement, travel, duration" },
		} }, { })
		local pair = assert(hypothesisByPair(result, "frostblink", "mirror_arrow"))
		assert.are.equal("weak_signal_overlap", pair.reason.method)
		assert.are.same({ "duration", "movement", "travel" }, pair.reason.sharedTags)
		assert.are.same({ }, pair.reason.signalTags)
		assert.are.equal(100, pair.relevanceScore)
	end)

	it("prioritizes the selected main skill before configured utility anchors", function()
		local profile = newProfile()
		profile.configuredSkillEffects[#profile.configuredSkillEffects + 1] = {
			effectId = "frostblink", gemId = "Metadata/Items/Gems/SkillGemFrostblink", name = "Frostblink",
		}
		local catalog = newCatalog()
		catalog.effects[#catalog.effects + 1] = { effectId = "frostblink", gemId = "Metadata/Items/Gems/SkillGemFrostblink",
			gameId = "frostblink", variantId = "", effectName = "Frostblink", tags = "spell, movement, blink, travel" }
		catalog.effects[#catalog.effects + 1] = { effectId = "rune_blast", gemId = "Metadata/Items/Gems/SkillGemRuneBlast",
			gameId = "rune_blast", variantId = "", effectName = "Rune Blast of Teleportation", tags = "spell, movement, blink, travel" }
		local result = Scout.Propose(profile, catalog, { })
		assert.are.equal("fireball", result.hypotheses[1].effectA.effectId)
		assert.is_true(result.hypotheses[1].relevanceScore >= 100)
		assert.is_truthy(result.hypotheses[1].reason.summary:find("Selected main skill anchor", 1, true))
	end)

	it("uses every configured effect as an anchor, not only the selected Main Skill", function()
		local profile = newProfile()
		profile.configuredSkillEffects[#profile.configuredSkillEffects + 1] = {
			effectId = "ice_nova", gemId = "Metadata/Items/Gems/SkillGemIceNova", gameId = "ice_nova", name = "Ice Nova",
		}
		local result = Scout.Propose(profile, newCatalog(), { })
		assert.is_truthy(hypothesisByPair(result, "ice_nova", "spectral_helix"))
		assert.is_nil(hypothesisByPair(result, "fireball", "ice_nova"))
		assert.are.equal(2, result.facts[#result.facts].value)
		assert.are.equal(result.candidateCount, result.proposedCount)
	end)

	it("counts the full configured-anchor frontier while bounding materialized review proposals", function()
		local profile = newProfile()
		profile.configuredSkillEffects[#profile.configuredSkillEffects + 1] = {
			effectId = "anchor_two", gemId = "AnchorTwo", name = "Anchor Two",
		}
		local rows = { }
		for index = 1, 2048 do
			rows[#rows + 1] = { effectId = "Catalog" .. index, gemId = "Gem" .. index,
				name = "Catalog " .. index, tags = index % 2 == 0 and "spell, fire" or "attack, melee" }
		end
		local result = Scout.Propose(profile, rows, { })
		assert.are.equal(512, result.proposedCount)
		assert.is_true(result.candidateCount > result.proposedCount)
		assert.are.equal(result.candidateCount - result.proposedCount, result.unreviewedCandidateCount)
		assert.are.equal("diverse_frontier_sampled", result.candidateCountStatus)
	end)

	it("pages through the complete ranked frontier without duplicate or omitted candidates", function()
		local profile = newProfile()
		profile.configuredSkillEffects[#profile.configuredSkillEffects + 1] = {
			effectId = "anchor_two", gemId = "AnchorTwo", name = "Anchor Two",
		}
		local rows = { }
		for index = 1, 540 do
			rows[#rows + 1] = { effectId = "PageCatalog" .. index, gemId = "PageGem" .. index,
				name = "Page Catalog " .. index, tags = index % 2 == 0 and "spell, fire" or "attack, melee" }
		end
		local cursor, seen, total, pages = nil, { }, nil, 0
		repeat
			local page = Scout.ProposePage(profile, rows, { }, cursor, 37)
			assert.are.equal("complete_frontier_cursor_page", page.candidateCountStatus)
			assert.is_true(page.proposedCount <= 37)
			if page.page.hasMore then assert.are.equal(37, page.proposedCount) end
			total = total or page.candidateCount
			assert.are.equal(total, page.candidateCount)
			pages = pages + 1
			assert.is_true(pages < 100)
			for _, hypothesis in ipairs(page.hypotheses) do
				assert.is_false(seen[hypothesis.id] == true)
				seen[hypothesis.id] = true
			end
			cursor = page.page.nextCursor
			if not page.page.hasMore then break end
			assert.is_truthy(cursor)
		until false
		local observed = 0
		for _ in pairs(seen) do observed = observed + 1 end
		assert.is_true(pages > 1)
		assert.are.equal(total, observed)
	end)

	it("separates archive observations from exact PoB conclusions", function()
		local result = Scout.Propose(newProfile(), newCatalog(), { })
		assert.are.equal("archive_observation", result.facts[1].kind)
		assert.are.equal("observed", result.facts[1].status)
		assert.are.equal("exact_pob_validation", result.facts[4].kind)
		assert.are.equal("not_supplied", result.facts[4].status)
		assert.are.equal(0, result.facts[4].value)
		assert.are.equal("co_observed_unverified", result.facts[3].status)
		assert.are_not.equal("synergy", result.facts[3].status)
	end)

	it("responds to critique and question IDs without verifying hypotheses", function()
		local proposal = Scout.Propose(newProfile(), newCatalog(), { })
		local firstHypothesis = proposal.hypotheses[1]
		local response = Scout.Respond(newProfile(), proposal, {
			critiques = { { id = "critique-1", proposalId = firstHypothesis.id, challenge = "Test assumptions", reason = "shared_tags_unverified" } },
			questions = { { id = "question-1", question = "Which scenario?" } },
		})
		assert.are.equal("opportunity_scout", response.role)
		assert.are.equal(2, #response.responses)
		assert.are.equal("critique-1", response.responses[1].targetId)
		assert.are.equal("question-1", response.responses[2].targetId)
		for _, item in ipairs(response.responses) do
			assert.are.equal("unverified", item.status)
			assert.are.equal("untested", item.hypothesisStatus)
			assert.are.equal("no_exact_factorial_result", item.evidence)
		end
		assert.is_truthy(response.responses[1].response:find("A aceita que a sobreposição de tags", 1, true))
		assert.is_truthy(response.responses[2].response:find("A deixa o objetivo", 1, true))
		assert.are.equal("untested", firstHypothesis.status)
		assert.are.equal(0, #Scout.Respond(newProfile(), proposal, nil).responses)
	end)

	it("continues from configured effects when the Main Skill selection is absent", function()
		local profile = newProfile()
		profile.skillGroups[1].skills[1].effects[1].selected = false
		local result = Scout.Propose(profile, newCatalog(), { })
		assert.is_true(result.candidateCount > 0)
		assert.are.equal("configured_effects_without_selected_main", result.facts[5].status)
		assert.are.equal("missing", result.facts[2].status)
	end)
end)
