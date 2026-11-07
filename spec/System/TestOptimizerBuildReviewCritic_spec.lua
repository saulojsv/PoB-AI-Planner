local Critic = require("Modules.Optimizer.BuildReviewCritic")
local json = require("dkjson")

describe("Optimizer local adversarial build reviewer", function()
	local profile
	local catalog

	before_each(function()
		profile = {
			character = { class = "Witch", level = 90 },
			configuredSkillEffects = {
				{ effectId = "Fireball", gemId = "Fireball", name = "Fireball" },
			},
			skillGroups = {
				{ enabled = true, slotEnabled = true, skills = {
					{ selectedMainSkill = true, effects = {
						{ effectId = "Fireball", gemId = "Fireball", name = "Fireball", selected = true },
					} },
				}, gems = { { name = "Fire Penetration", isSupport = true, enabled = true } } },
			},
			supportGemIds = { "SupportA", "SupportB" },
			allocatedNodeIds = { 1, 2, 3 },
			itemSlots = { { slot = "Weapon 1", base = "Prophecy Wand" }, { slot = "Helmet" } },
		}
		catalog = {
			{ effectId = "Fireball", gemId = "Fireball", name = "Fireball", tags = "spell, fire, projectile, grants_active_skill" },
			{ effectId = "Firestorm", gemId = "Firestorm", name = "Firestorm", tags = "spell, fire, nova" },
			{ effectId = "Frostblink", gemId = "Frostblink", name = "Frostblink", tags = "cold, movement" },
			{ effectId = "Arc", gemId = "Arc", name = "Arc", tags = "lightning, chaining" },
			{ effectId = "FireballAlt", gemId = "Fireball", name = "Fireball Alternate", tags = "spell, fire" },
		}
	end)

	it("separates observed snapshot facts from untested and diverse authored hypotheses", function()
		local result = assert(Critic.Review(profile, catalog, { }, { hypotheses = { } }))
		assert.are.equal(1, result.schemaVersion)
		assert.are.equal("adversarial_critic", result.role)
		assert.are.equal("deterministic_local_heuristic", result.runtime)
		assert.is_true(#result.facts > 0)
		assert.are.equal("observed_snapshot", result.facts[1].status)
		assert.are.equal("archived_build_profile", result.facts[1].evidence)
		local setupFact, itemFact
		for _, fact in ipairs(result.facts) do
			if fact.id == "observed:main-link-context" then setupFact = fact end
			if fact.id == "observed:item-shell" then itemFact = fact end
		end
		assert.is_truthy(setupFact and setupFact.detail:find("Fire Penetration", 1, true))
		assert.is_truthy(itemFact and itemFact.detail:find("Prophecy Wand", 1, true))
		assert.is_true(#result.independentHypotheses >= 2)
		local overlap, crossTag = false, false
		for _, hypothesis in ipairs(result.independentHypotheses) do
			assert.are.equal("untested", hypothesis.status)
			assert.are.equal("heuristic_only", hypothesis.evidenceStatus)
			assert.are.equal("exact_pob_factorial", hypothesis.requiredTest)
			assert.are.equal(4, #hypothesis.testDesign)
			if hypothesis.basis == "catalog_tag_overlap_exploration" then overlap = true end
			if hypothesis.basis == "cross_tag_diversity_exploration" then
				crossTag = true
				assert.is_truthy(hypothesis.rationale:find("context tie-break 100.000", 1, true))
			end
		end
		assert.is_true(overlap)
		assert.is_true(crossTag)
		assert.is_false(result.claims.exactCompatibility)
		assert.is_false(result.claims.exactSynergy)
		assert.is_false(result.claims.modelTrainingLabel)
		assert.is_truthy(json.encode(result))
	end)

	it("challenges every scout idea without upgrading it to a finding", function()
		local scout = { hypotheses = {
			{ id = "scout:one", effectA = { effectId = "Fireball", gemId = "Fireball" },
				effectB = { effectId = "Firestorm", gemId = "Firestorm" }, status = "untested" },
			{ id = "scout:two", effectA = { effectId = "Fireball", gemId = "Fireball" },
				effectB = { effectId = "Frostblink", gemId = "Frostblink" }, status = "untested" },
		} }
		local result = assert(Critic.Review(profile, catalog, { }, scout))
		assert.are.equal(2, #result.critiques)
		assert.are.equal(2, #result.questions)
		for _, critique in ipairs(result.critiques) do
			assert.are.equal("untested", critique.status)
			assert.is_truthy(critique.reason == "shared_tags_unverified" or critique.reason == "exploratory_pair_unverified"
				or critique.reason == "possible_weapon_context_mismatch")
			assert.are.equal("exact_pob_factorial", critique.requiredTest)
			assert.is_truthy(critique.challenge:find("quatro estados", 1, true))
		end
		assert.are.equal("scout:one", result.critiques[1].proposalId)
		assert.are.equal("unanswered", result.questions[1].status)
		assert.is_truthy(result.questions[1].question:find("Qual chave de output", 1, true))
	end)

	it("builds its independent ideas without reading the scout's idea list", function()
		local first = assert(Critic.Review(profile, catalog, { }, { hypotheses = { } }))
		local second = assert(Critic.Review(profile, catalog, { }, { hypotheses = {
			{ id = "different", effectA = { effectId = "Fireball" }, effectB = { effectId = "Arc" } },
		} }))
		assert.are.equal(#first.independentHypotheses, #second.independentHypotheses)
		for index, hypothesis in ipairs(first.independentHypotheses) do
			assert.are.equal(hypothesis.id, second.independentHypotheses[index].id)
		end
		assert.are.equal(0, #first.critiques)
		assert.are.equal(1, #second.critiques)
	end)

	it("keeps exploration deterministic while rotating low-signal ties by build context", function()
		local broadCatalog = { catalog[1] }
		for index = 1, 20 do
			broadCatalog[#broadCatalog + 1] = { effectId = "Cross" .. index, gemId = "CrossGem" .. index,
				name = "Cross " .. index, tags = "family_" .. index }
		end
		local function firstIdeas()
			local result = assert(Critic.Review(profile, broadCatalog, { }, { hypotheses = { } }))
			local ids = { }
			for index = 1, math.min(8, #result.independentHypotheses) do
				ids[index] = result.independentHypotheses[index].effectB.effectId
			end
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

	it("skips exact known relations and co-configured effects without treating them as synergy", function()
		profile.configuredSkillEffects[#profile.configuredSkillEffects + 1] = {
			effectId = "Arc", gemId = "Arc", name = "Arc",
		}
		local result = assert(Critic.Review(profile, catalog, {
			{ effectA = { effectId = "Fireball", gemId = "Fireball" }, effectB = { effectId = "Firestorm", gemId = "Firestorm" } },
		}, { hypotheses = { } }))
		for _, hypothesis in ipairs(result.independentHypotheses) do
			local left, right = hypothesis.effectA.effectId, hypothesis.effectB.effectId
			assert.is_false((left == "Fireball" and right == "Arc") or (left == "Arc" and right == "Fireball"))
			assert.is_false((left == "Fireball" and right == "Firestorm") or (left == "Firestorm" and right == "Fireball"))
		end
		assert.is_true(result.claims.exactSynergy == false)
	end)

	it("independently explores every configured skill as an anchor", function()
		profile.configuredSkillEffects[#profile.configuredSkillEffects + 1] = { effectId = "Arc", gemId = "Arc", name = "Arc" }
		for index = 1, 20 do
			catalog[#catalog + 1] = { effectId = "Extra" .. index, gemId = "ExtraGem" .. index,
				name = "Extra " .. index, tags = index % 2 == 0 and "spell, fire" or "attack, melee" }
		end
		local result = assert(Critic.Review(profile, catalog, { }, { hypotheses = { } }))
		local foundSecondaryAnchor = false
		for _, hypothesis in ipairs(result.independentHypotheses) do
			if hypothesis.effectA.effectId == "Arc" then foundSecondaryAnchor = true end
		end
		assert.is_true(foundSecondaryAnchor)
		assert.is_true(result.candidateCount > #result.independentHypotheses)
		assert.are.equal("catalog_exploration_sampled_for_review", result.candidateCountStatus)
	end)

	it("pages independently through the complete critic frontier", function()
		local wideCatalog = { catalog[1] }
		for index = 1, 29 do
			wideCatalog[#wideCatalog + 1] = { effectId = "Paged" .. index, gemId = "PagedGem" .. index,
				name = "Paged Skill " .. index, tags = index % 2 == 0 and "spell, fire" or "attack, melee" }
		end
		local cursor, seen, total, pages = nil, { }, nil, 0
		repeat
			local result = assert(Critic.Review(profile, wideCatalog, { }, { hypotheses = { } }, { limit = 5, cursor = cursor }))
			assert.are.equal("exact_factor_identity", result.page.ordering)
			total = total or result.candidateCount
			assert.are.equal(total, result.candidateCount)
			pages = pages + 1
			assert.is_true(pages < 20)
			for _, hypothesis in ipairs(result.independentHypotheses) do
				assert.is_false(seen[hypothesis.id] == true)
				seen[hypothesis.id] = true
			end
			cursor = result.page.nextCursor
			if not result.page.hasMore then break end
			assert.is_truthy(cursor)
		until false
		local observed = 0
		for _ in pairs(seen) do observed = observed + 1 end
		assert.is_true(pages > 1)
		assert.are.equal(total, observed)
	end)

	it("uses configured skill effects when the profile has no selected Main Skill group", function()
		profile.skillGroups = { }
		local result = assert(Critic.Review(profile, catalog, { }, { hypotheses = { } }))
		assert.is_true(result.candidateCount > 0)
		assert.is_true(#result.independentHypotheses > 0)
		assert.are.equal(0, #result.questions)
	end)

	it("raises a minion-cadence warning instead of assuming a damage interaction", function()
		catalog[#catalog + 1] = { effectId = "SummonZombie", gemId = "SummonZombie", name = "Summon Zombie", tags = "minion, spell" }
		local scout = require("Modules.Optimizer.BuildReviewScout").Propose(profile, catalog, { })
		local result = assert(Critic.Review(profile, catalog, { }, scout))
		local minionChallenge
		for _, row in ipairs(result.critiques) do
			if row.observedEffectIds[2] == "SummonZombie" then minionChallenge = row; break end
		end
		assert.is_truthy(minionChallenge)
		assert.is_truthy(minionChallenge.challenge:find("cadência de reposição", 1, true))
		assert.is_truthy(minionChallenge.challenge:find("coocorrência e tags não demonstram sinergia", 1, true))
		for _, row in ipairs(result.questions) do
			if row.proposalId == minionChallenge.proposalId then assert.are.equal("minion_components", row.metricScope) end
		end
	end)

	it("keeps movement and travel tag overlap out of the independent priority score", function()
		profile.configuredSkillEffects = { { effectId = "Frostblink", gemId = "Frostblink", gameId = "frostblink", name = "Frostblink" } }
		profile.skillGroups = { { skills = { { selectedMainSkill = true, effects = {
			{ effectId = "Frostblink", gemId = "Frostblink", gameId = "frostblink", name = "Frostblink", selected = true },
		} } } } }
		catalog = {
			{ effectId = "Frostblink", gemId = "Frostblink", gameId = "frostblink", name = "Frostblink", tags = "movement, travel, duration" },
			{ effectId = "MirrorArrow", gemId = "MirrorArrow", gameId = "mirror_arrow", name = "Mirror Arrow", tags = "movement, travel, duration" },
		}
		local result = assert(Critic.Review(profile, catalog, { }, { hypotheses = { } }))
		local pair
		for _, idea in ipairs(result.independentHypotheses) do
			if idea.effectA.effectId == "Frostblink" and idea.effectB.effectId == "MirrorArrow" then pair = idea; break end
		end
		assert.is_truthy(pair)
		assert.are.equal("weak_signal_tag_exploration", pair.basis)
		assert.are.same({ "duration", "movement", "travel" }, pair.sharedTags)
		assert.are.same({ }, pair.signalTags)
		assert.is_truthy(pair.rationale:find("Weak-signal tag overlap", 1, true))
	end)

	it("uses archived item context to flag a possible weapon-shell mismatch", function()
		profile.itemSlots[1].base = "Prophecy Wand"
		catalog[#catalog + 1] = { effectId = "BlastRain", gemId = "BlastRain", name = "Blast Rain of Trarthus",
			tags = "attack, projectile, bow" }
		local result = assert(Critic.Review(profile, catalog, { }, { hypotheses = {
			{ id = "scout:bow", effectA = { effectId = "Fireball", gemId = "Fireball", name = "Fireball" },
				effectB = { effectId = "BlastRain", gemId = "BlastRain", name = "Blast Rain of Trarthus" }, status = "untested" },
		} }))
		assert.are.equal("possible_weapon_context_mismatch", result.critiques[1].reason)
		assert.is_truthy(result.critiques[1].challenge:find("Prophecy Wand", 1, true))
		assert.are.equal("weapon_compatibility_and_shell", result.questions[1].metricScope)
		assert.is_truthy(result.questions[1].question:find("novo shell", 1, true))
	end)

	it("asks for an anchor only when no selected or configured effect exists", function()
		profile.configuredSkillEffects = { }
		profile.skillGroups = { }
		local result = assert(Critic.Review(profile, catalog, { }, { hypotheses = { } }))
		assert.are.equal(0, #result.independentHypotheses)
		assert.are.equal(0, result.candidateCount)
		assert.is_truthy(result.questions[1].question:find("configured active skill", 1, true))
	end)
end)
